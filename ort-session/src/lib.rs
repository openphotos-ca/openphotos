use anyhow::{anyhow, Context, Result};
use log::{info, warn};
use ort::session::{
    builder::{GraphOptimizationLevel, SessionBuilder},
    Session,
};
use rknn_runtime::{coreml_compute_units_from_env_or_default, AiBackend, CoremlComputeUnits};
use std::path::Path;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ArtifactSupport {
    pub cuda: bool,
    pub coreml: bool,
    pub directml: bool,
    pub migraphx: bool,
}

impl ArtifactSupport {
    pub const fn compiled() -> Self {
        Self {
            cuda: cfg!(feature = "cuda"),
            coreml: cfg!(feature = "coreml"),
            directml: cfg!(feature = "directml"),
            migraphx: cfg!(feature = "migraphx"),
        }
    }

    pub fn auto_backend(self) -> AiBackend {
        if cfg!(target_vendor = "apple") && cfg!(target_arch = "aarch64") && self.coreml {
            AiBackend::Coreml
        } else if cfg!(target_os = "windows") && self.directml {
            AiBackend::Directml
        } else if cfg!(target_os = "linux") && self.cuda {
            AiBackend::Cuda
        } else if cfg!(target_os = "linux") && self.migraphx {
            AiBackend::Migraphx
        } else {
            AiBackend::Cpu
        }
    }

    pub fn supports_backend(self, backend: AiBackend) -> bool {
        match backend {
            AiBackend::Auto | AiBackend::Cpu => true,
            AiBackend::Coreml => {
                cfg!(target_vendor = "apple") && cfg!(target_arch = "aarch64") && self.coreml
            }
            AiBackend::Cuda => cfg!(target_os = "linux") && self.cuda,
            AiBackend::Directml => cfg!(target_os = "windows") && self.directml,
            AiBackend::Migraphx => cfg!(target_os = "linux") && self.migraphx,
            AiBackend::Rk3588Hybrid => false,
        }
    }

    pub fn supported_backends(self) -> Vec<AiBackend> {
        let mut backends = vec![AiBackend::Cpu];
        for backend in [
            AiBackend::Cuda,
            AiBackend::Coreml,
            AiBackend::Directml,
            AiBackend::Migraphx,
        ] {
            if self.supports_backend(backend) {
                backends.push(backend);
            }
        }
        backends
    }

    pub fn describe(self) -> String {
        self.supported_backends()
            .into_iter()
            .map(|backend| backend.as_str().to_string())
            .collect::<Vec<_>>()
            .join(",")
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProviderConfig {
    pub backend: AiBackend,
    pub device_id: i32,
    pub coreml_compute_units: CoremlComputeUnits,
    pub artifact_support: ArtifactSupport,
}

impl ProviderConfig {
    pub fn new(backend: AiBackend, device_id: i32) -> Self {
        Self {
            backend,
            device_id,
            coreml_compute_units: coreml_compute_units_from_env_or_default(),
            artifact_support: ArtifactSupport::compiled(),
        }
    }

    pub fn with_coreml_compute_units(mut self, units: CoremlComputeUnits) -> Self {
        self.coreml_compute_units = units;
        self
    }
}

#[derive(Debug, Clone, Copy)]
pub enum SessionOptimizationLevel {
    Disable,
    Level1,
    Level2,
    Level3,
}

impl SessionOptimizationLevel {
    fn into_ort(self) -> GraphOptimizationLevel {
        match self {
            Self::Disable => GraphOptimizationLevel::Disable,
            Self::Level1 => GraphOptimizationLevel::Level1,
            Self::Level2 => GraphOptimizationLevel::Level2,
            Self::Level3 => GraphOptimizationLevel::Level3,
        }
    }
}

#[derive(Debug)]
pub struct SessionTuning {
    pub optimization_level: SessionOptimizationLevel,
    pub intra_threads: Option<usize>,
}

impl Default for SessionTuning {
    fn default() -> Self {
        Self {
            optimization_level: SessionOptimizationLevel::Level3,
            intra_threads: None,
        }
    }
}

pub struct SessionWithBackend {
    pub session: Session,
    pub backend: AiBackend,
}

pub fn build_session_from_file(
    model_path: &Path,
    provider: ProviderConfig,
    tuning: SessionTuning,
) -> Result<SessionWithBackend> {
    let requested = provider.backend;
    let resolved = resolve_backend(provider);
    info!(
        "[ORT] loading model={} requested_backend={} resolved_backend={} device_id={} coreml_compute_units={} compiled_backends={}",
        model_path.display(),
        requested.as_str(),
        resolved.as_str(),
        provider.device_id,
        provider.coreml_compute_units.as_str(),
        provider.artifact_support.describe()
    );

    if resolved == AiBackend::Coreml && provider.device_id != 0 {
        info!(
            "[ORT] AI_DEVICE_ID={} ignored for backend=coreml model={}",
            provider.device_id,
            model_path.display()
        );
    }

    match try_build_session(
        model_path,
        resolved,
        provider.device_id,
        provider.coreml_compute_units,
        &tuning,
    ) {
        Ok(session) => {
            info!(
                "[ORT] activated backend={} model={}",
                resolved.as_str(),
                model_path.display()
            );
            Ok(SessionWithBackend {
                session,
                backend: resolved,
            })
        }
        Err(err) if resolved.is_ort_gpu() => {
            warn!(
                "[ORT] backend {} unavailable for {} on device {}: {}. Falling back to CPU.",
                resolved.as_str(),
                model_path.display(),
                provider.device_id,
                err
            );
            let session = try_build_session(
                model_path,
                AiBackend::Cpu,
                provider.device_id,
                provider.coreml_compute_units,
                &tuning,
            )
            .with_context(|| {
                format!(
                    "failed to build CPU fallback ONNX session for {}",
                    model_path.display()
                )
            })?;
            info!("[ORT] activated backend=cpu model={}", model_path.display());
            Ok(SessionWithBackend {
                session,
                backend: AiBackend::Cpu,
            })
        }
        Err(err) => Err(err).with_context(|| {
            format!(
                "failed to build ONNX Runtime session for {}",
                model_path.display()
            )
        }),
    }
}

fn resolve_backend(provider: ProviderConfig) -> AiBackend {
    let requested = provider.backend;
    if requested == AiBackend::Auto {
        return provider.artifact_support.auto_backend();
    }
    if requested.is_ort_gpu() && !provider.artifact_support.supports_backend(requested) {
        warn!(
            "[ORT] requested backend {} is not supported by this artifact/platform; using CPU.",
            requested.as_str()
        );
        return AiBackend::Cpu;
    }
    requested
}

fn try_build_session(
    model_path: &Path,
    backend: AiBackend,
    _device_id: i32,
    _coreml_compute_units: CoremlComputeUnits,
    tuning: &SessionTuning,
) -> Result<Session> {
    #[allow(unused_mut)]
    let mut builder = create_builder(tuning)?;

    match backend {
        AiBackend::Auto => unreachable!("auto must be resolved before session creation"),
        AiBackend::Cpu => {}
        AiBackend::Coreml => {
            #[cfg(feature = "coreml")]
            {
                use ort::execution_providers::coreml::{
                    CoreMLComputeUnits as OrtCoreMLComputeUnits, CoreMLExecutionProvider,
                };

                let compute_units = match _coreml_compute_units {
                    CoremlComputeUnits::All => OrtCoreMLComputeUnits::All,
                    CoremlComputeUnits::CpuAndGpu => OrtCoreMLComputeUnits::CPUAndGPU,
                    CoremlComputeUnits::CpuAndNeuralEngine => {
                        OrtCoreMLComputeUnits::CPUAndNeuralEngine
                    }
                    CoremlComputeUnits::CpuOnly => OrtCoreMLComputeUnits::CPUOnly,
                };
                builder = builder.with_execution_providers([CoreMLExecutionProvider::default()
                    .with_compute_units(compute_units)
                    .build()])?;
            }
            #[cfg(not(feature = "coreml"))]
            {
                return Err(anyhow!(
                    "CoreML backend requested but this artifact was built without CoreML support"
                ));
            }
        }
        AiBackend::Cuda => {
            #[cfg(feature = "cuda")]
            {
                use ort::execution_providers::CUDAExecutionProvider;

                builder = builder.with_execution_providers([CUDAExecutionProvider::default()
                    .with_device_id(_device_id)
                    .build()])?;
            }
            #[cfg(not(feature = "cuda"))]
            {
                return Err(anyhow!(
                    "CUDA backend requested but this artifact was built without CUDA support"
                ));
            }
        }
        AiBackend::Directml => {
            #[cfg(feature = "directml")]
            {
                use ort::execution_providers::DirectMLExecutionProvider;

                builder = builder.with_parallel_execution(false)?;
                builder = builder.with_memory_pattern(false)?;
                builder =
                    builder.with_execution_providers([DirectMLExecutionProvider::default()
                        .with_device_id(_device_id)
                        .build()])?;
            }
            #[cfg(not(feature = "directml"))]
            {
                return Err(anyhow!(
                    "DirectML backend requested but this artifact was built without DirectML support"
                ));
            }
        }
        AiBackend::Migraphx => {
            #[cfg(feature = "migraphx")]
            {
                use ort::execution_providers::MIGraphXExecutionProvider;

                builder =
                    builder.with_execution_providers([MIGraphXExecutionProvider::default()
                        .with_device_id(_device_id)
                        .build()])?;
            }
            #[cfg(not(feature = "migraphx"))]
            {
                return Err(anyhow!(
                    "MIGraphX backend requested but this artifact was built without MIGraphX support"
                ));
            }
        }
        AiBackend::Rk3588Hybrid => {
            return Err(anyhow!("RK3588 backend does not use ONNX Runtime sessions"));
        }
    }

    builder
        .commit_from_file(model_path)
        .with_context(|| format!("failed to load ONNX model {}", model_path.display()))
}

fn create_builder(tuning: &SessionTuning) -> Result<SessionBuilder> {
    let _ = ort::init()
        .commit()
        .or_else(|_| Ok::<bool, ort::Error>(false))?;

    let mut builder = SessionBuilder::new()?;
    builder = builder.with_optimization_level(tuning.optimization_level.into_ort())?;
    if let Some(intra_threads) = tuning.intra_threads {
        builder = builder.with_intra_threads(intra_threads)?;
    }
    Ok(builder)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn compiled_support_always_includes_cpu() {
        let support = ArtifactSupport::compiled();
        assert!(support.supported_backends().contains(&AiBackend::Cpu));
    }

    #[test]
    fn auto_backend_matches_compiled_artifact() {
        let support = ArtifactSupport::compiled();
        let expected = if cfg!(target_os = "windows") && cfg!(feature = "directml") {
            AiBackend::Directml
        } else if cfg!(target_vendor = "apple")
            && cfg!(target_arch = "aarch64")
            && cfg!(feature = "coreml")
        {
            AiBackend::Coreml
        } else if cfg!(target_os = "linux") && cfg!(feature = "cuda") {
            AiBackend::Cuda
        } else if cfg!(target_os = "linux") && cfg!(feature = "migraphx") {
            AiBackend::Migraphx
        } else {
            AiBackend::Cpu
        };
        assert_eq!(support.auto_backend(), expected);
    }

    #[test]
    fn unsupported_gpu_backend_resolves_to_cpu() {
        let resolved = resolve_backend(ProviderConfig {
            backend: AiBackend::Directml,
            device_id: 0,
            coreml_compute_units: CoremlComputeUnits::All,
            artifact_support: ArtifactSupport {
                cuda: false,
                coreml: false,
                directml: false,
                migraphx: false,
            },
        });
        assert_eq!(resolved, AiBackend::Cpu);
    }

    #[test]
    fn artifact_support_is_platform_scoped() {
        let support = ArtifactSupport {
            cuda: true,
            coreml: true,
            directml: true,
            migraphx: true,
        };

        assert!(support.supports_backend(AiBackend::Cpu));

        if cfg!(target_vendor = "apple") && cfg!(target_arch = "aarch64") {
            assert!(support.supports_backend(AiBackend::Coreml));
            assert!(!support.supports_backend(AiBackend::Cuda));
            assert!(!support.supports_backend(AiBackend::Directml));
            assert!(!support.supports_backend(AiBackend::Migraphx));
        } else if cfg!(target_os = "windows") {
            assert!(support.supports_backend(AiBackend::Directml));
            assert!(!support.supports_backend(AiBackend::Coreml));
            assert!(!support.supports_backend(AiBackend::Cuda));
            assert!(!support.supports_backend(AiBackend::Migraphx));
        } else if cfg!(target_os = "linux") {
            assert!(support.supports_backend(AiBackend::Cuda));
            assert!(support.supports_backend(AiBackend::Migraphx));
            assert!(!support.supports_backend(AiBackend::Coreml));
            assert!(!support.supports_backend(AiBackend::Directml));
        } else {
            assert!(!support.supports_backend(AiBackend::Cuda));
            assert!(!support.supports_backend(AiBackend::Coreml));
            assert!(!support.supports_backend(AiBackend::Directml));
            assert!(!support.supports_backend(AiBackend::Migraphx));
        }
    }
}
