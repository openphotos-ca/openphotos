use anyhow::Result;
use rknn_runtime::{runtime_override_from_env, AiBackend, CoremlComputeUnits};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone)]
pub struct AiRuntimeConfig {
    pub backend: AiBackend,
    pub device_id: i32,
    pub coreml_compute_units: CoremlComputeUnits,
    pub rknn_model_root: PathBuf,
    pub runtime_lib_override: Option<PathBuf>,
}

impl AiRuntimeConfig {
    pub fn from_args(
        model_root: impl AsRef<Path>,
        ai_backend_raw: &str,
        ai_device_id: i32,
        rknn_model_root_override: Option<&str>,
    ) -> Result<Self> {
        let model_root = model_root.as_ref();
        let backend = AiBackend::parse(ai_backend_raw)?;
        let coreml_compute_units = std::env::var("AI_COREML_COMPUTE_UNITS")
            .map(|raw| CoremlComputeUnits::parse(&raw))
            .unwrap_or(Ok(CoremlComputeUnits::All))?;
        let rknn_model_root = rknn_model_root_override
            .map(PathBuf::from)
            .unwrap_or_else(|| model_root.join("rk3588"));

        Ok(Self {
            backend,
            device_id: ai_device_id,
            coreml_compute_units,
            rknn_model_root,
            runtime_lib_override: runtime_override_from_env(),
        })
    }

    pub fn rknn_model_file(&self, relative_path: impl AsRef<Path>) -> PathBuf {
        self.rknn_model_root.join(relative_path)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_rknn_root_under_model_root() {
        let config = AiRuntimeConfig::from_args("models", "cpu", 0, None).unwrap();
        assert_eq!(config.backend, AiBackend::Cpu);
        assert_eq!(config.device_id, 0);
        assert_eq!(config.coreml_compute_units, CoremlComputeUnits::All);
        assert_eq!(
            config.rknn_model_root,
            PathBuf::from("models").join("rk3588")
        );
    }

    #[test]
    fn accepts_explicit_rknn_root() {
        let config =
            AiRuntimeConfig::from_args("models", "rk3588-hybrid", 2, Some("/tmp/rknn")).unwrap();
        assert_eq!(config.backend, AiBackend::Rk3588Hybrid);
        assert_eq!(config.device_id, 2);
        assert_eq!(config.coreml_compute_units, CoremlComputeUnits::All);
        assert_eq!(config.rknn_model_root, PathBuf::from("/tmp/rknn"));
        assert_eq!(
            config.rknn_model_file("face/det_10g.rknn"),
            PathBuf::from("/tmp/rknn/face/det_10g.rknn")
        );
    }

    #[test]
    fn resolves_clip_artifacts_under_default_root() {
        let config = AiRuntimeConfig::from_args("/srv/models", "rk3588-hybrid", 0, None).unwrap();
        assert_eq!(
            config.rknn_model_file("clip-vit-base-patch32/visual.rknn"),
            PathBuf::from("/srv/models/rk3588/clip-vit-base-patch32/visual.rknn")
        );
        assert_eq!(
            config.rknn_model_file("clip-vit-base-patch32/textual.rknn"),
            PathBuf::from("/srv/models/rk3588/clip-vit-base-patch32/textual.rknn")
        );
    }

    #[test]
    fn rejects_unknown_ai_backend() {
        let err = AiRuntimeConfig::from_args("models", "gpu", 0, None).unwrap_err();
        assert!(
            err.to_string().contains("unsupported AI backend"),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn accepts_auto_backend() {
        let config = AiRuntimeConfig::from_args("models", "auto", 1, None).unwrap();
        assert_eq!(config.backend, AiBackend::Auto);
        assert_eq!(config.device_id, 1);
        assert_eq!(config.coreml_compute_units, CoremlComputeUnits::All);
    }

    #[test]
    fn parses_coreml_compute_units_from_env() {
        let _guard = env_lock();
        std::env::set_var("AI_COREML_COMPUTE_UNITS", "cpu-and-gpu");
        let config = AiRuntimeConfig::from_args("models", "coreml", 0, None).unwrap();
        assert_eq!(config.backend, AiBackend::Coreml);
        assert_eq!(config.coreml_compute_units, CoremlComputeUnits::CpuAndGpu);
    }

    #[test]
    fn rejects_invalid_coreml_compute_units() {
        let _guard = env_lock();
        std::env::set_var("AI_COREML_COMPUTE_UNITS", "gpu-only");
        let err = AiRuntimeConfig::from_args("models", "coreml", 0, None).unwrap_err();
        assert!(
            err.to_string().contains("AI_COREML_COMPUTE_UNITS"),
            "unexpected error: {err}"
        );
    }

    fn env_lock() -> EnvGuard {
        static LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
        let guard = LOCK.lock().unwrap();
        std::env::remove_var("AI_COREML_COMPUTE_UNITS");
        EnvGuard { _guard: guard }
    }

    struct EnvGuard {
        _guard: std::sync::MutexGuard<'static, ()>,
    }

    impl Drop for EnvGuard {
        fn drop(&mut self) {
            std::env::remove_var("AI_COREML_COMPUTE_UNITS");
        }
    }
}
