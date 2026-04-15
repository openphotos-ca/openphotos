use anyhow::{Context, Result};
use image::DynamicImage;
use ndarray::Axis;
use ort::{session::Session, value::Value};
use ort_session::{
    build_session_from_file, ProviderConfig, SessionOptimizationLevel, SessionTuning,
};
use parking_lot::Mutex;
use rknn_runtime::{AiBackend, RknnModel, RknnRuntime, TensorFormat, TensorOutput, TensorSpec};
use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;
use tracing::{debug, info, instrument};

use super::{normalize_embedding, preprocess_image, ClipConfig};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum EncoderBackend {
    Ort(AiBackend),
    Rknn,
}

pub struct VisualEncoder {
    cpu_session: Option<Arc<Mutex<Session>>>,
    rknn_model: Option<Arc<RknnModel>>,
    active_backend: Mutex<EncoderBackend>,
    config: ClipConfig,
}

impl VisualEncoder {
    pub fn new(config: ClipConfig) -> Result<Self> {
        Self::new_with_backend(config, AiBackend::Cpu, 0, None, None)
    }

    pub fn new_with_backend(
        config: ClipConfig,
        ai_backend: AiBackend,
        ai_device_id: i32,
        rknn_runtime: Option<Arc<RknnRuntime>>,
        rknn_model_path: Option<&Path>,
    ) -> Result<Self> {
        let model_path = Path::new(&config.model_path)
            .join(&config.model_name)
            .join("visual.onnx");

        info!("Loading CLIP visual model from: {:?}", model_path);

        let ort_backend = if ai_backend.prefers_rknn() {
            AiBackend::Cpu
        } else {
            ai_backend
        };
        let (cpu_session, ort_backend) =
            match build_ort_session(&model_path, ort_backend, ai_device_id) {
                Ok(bundle) => (
                    Some(Arc::new(Mutex::new(bundle.session))),
                    Some(bundle.backend),
                ),
                Err(err) if ai_backend.prefers_rknn() => {
                    info!(
                    "Falling back to RKNN-only CLIP visual setup because CPU session failed: {}",
                    err
                );
                    (None, None)
                }
                Err(err) => return Err(err),
            };

        let rknn_model = if ai_backend.prefers_rknn() {
            try_load_rknn_model("CLIP visual", rknn_runtime, rknn_model_path)?
        } else {
            None
        };

        if cpu_session.is_none() && rknn_model.is_none() {
            return Err(anyhow::anyhow!(
                "failed to initialize any CLIP visual backend for {:?}",
                model_path
            ));
        }

        let active_backend = if ai_backend.prefers_rknn() && rknn_model.is_some() {
            EncoderBackend::Rknn
        } else {
            EncoderBackend::Ort(ort_backend.unwrap_or(AiBackend::Cpu))
        };

        if let Some(session) = &cpu_session {
            let session = session.lock();
            debug!("Visual model inputs: {:?}", session.inputs.len());
            debug!("Visual model outputs: {:?}", session.outputs.len());
        }

        Ok(Self {
            cpu_session,
            rknn_model,
            active_backend: Mutex::new(active_backend),
            config,
        })
    }

    #[instrument(skip(self, image))]
    pub fn encode_image(&self, image: &DynamicImage) -> Result<Vec<f32>> {
        let preprocessed = preprocess_image(
            image,
            self.config.image_size,
            &self.config.mean,
            &self.config.std,
        )?;

        let backend = *self.active_backend.lock();
        match backend {
            EncoderBackend::Ort(_) => self.encode_with_ort(preprocessed),
            EncoderBackend::Rknn => match self.encode_with_rknn(&preprocessed) {
                Ok(embedding) => Ok(embedding),
                Err(err) => {
                    if self.cpu_session.is_some() {
                        info!(
                            "RKNN CLIP visual inference failed, downgrading to CPU fallback: {}",
                            err
                        );
                        *self.active_backend.lock() = EncoderBackend::Ort(AiBackend::Cpu);
                        self.encode_with_ort(preprocessed)
                    } else {
                        Err(err)
                    }
                }
            },
        }
    }

    fn encode_with_ort(&self, preprocessed: ndarray::Array3<f32>) -> Result<Vec<f32>> {
        let session = self
            .cpu_session
            .as_ref()
            .context("CLIP visual ONNX backend is unavailable")?;

        let input = preprocessed.insert_axis(Axis(0));
        let input_value = Value::from_array(input)?;
        let input_name = {
            let session_guard = session.lock();
            session_guard
                .inputs
                .first()
                .map(|i| i.name.clone())
                .unwrap_or_else(|| "input".to_string())
        };

        let mut inputs: HashMap<String, Value> = HashMap::new();
        inputs.insert(input_name, input_value.into());

        let mut session_guard = session.lock();
        let outputs = session_guard.run(inputs)?;
        let outputs = ort_outputs_to_tensors(&outputs)?;
        self.normalize_output(select_visual_output(&outputs)?)
    }

    fn encode_with_rknn(&self, preprocessed: &ndarray::Array3<f32>) -> Result<Vec<f32>> {
        let model = self
            .rknn_model
            .as_ref()
            .context("CLIP visual RKNN backend is unavailable")?;
        let input = preprocessed.view().insert_axis(Axis(0)).to_owned();
        let input_shape = vec![1, 3, self.config.image_size, self.config.image_size];
        let input_data = input.iter().copied().collect::<Vec<_>>();
        let outputs = model.run_nchw_f32(&input_shape, &input_data)?;
        self.normalize_output(select_visual_output(&outputs)?)
    }

    fn normalize_output(&self, output: &TensorOutput) -> Result<Vec<f32>> {
        let shape = &output.spec.dims;
        let embedding_data = &output.data;

        // The actual output dimension might be different from config.embedding_dim for M-CLIP
        let actual_dim = embedding_data.len();
        let expected_dim = self
            .config
            .visual_embedding_dim
            .unwrap_or(self.config.embedding_dim);
        debug!(
            "Visual model output shape: {:?}, actual dimensions: {}, expected dimensions: {}",
            shape, actual_dim, expected_dim
        );

        // Convert to Vec and normalize - ensure we don't exceed actual dimensions
        let take_dim = actual_dim.min(expected_dim);
        let embedding_vec = embedding_data[0..take_dim].to_vec();
        let embedding_array = ndarray::Array1::from_vec(embedding_vec);
        let normalized = normalize_embedding(embedding_array.view());

        Ok(normalized.to_vec())
    }

    #[instrument(skip(self, images))]
    pub fn encode_batch(&self, images: &[DynamicImage]) -> Result<Vec<Vec<f32>>> {
        if images.is_empty() {
            return Ok(vec![]);
        }

        // For now, process images one by one to avoid batch complexity
        let mut results = Vec::new();
        for image in images {
            results.push(self.encode_image(image)?);
        }

        Ok(results)
    }

    pub fn embedding_dim(&self) -> usize {
        self.config.embedding_dim
    }
}

fn build_ort_session(
    model_path: &Path,
    backend: AiBackend,
    device_id: i32,
) -> Result<ort_session::SessionWithBackend> {
    build_session_from_file(
        model_path,
        ProviderConfig::new(backend, device_id),
        SessionTuning {
            optimization_level: SessionOptimizationLevel::Level3,
            intra_threads: Some(1),
        },
    )
    .with_context(|| {
        format!(
            "failed to load CLIP visual ONNX model {}",
            model_path.display()
        )
    })
}

fn try_load_rknn_model(
    label: &str,
    runtime: Option<Arc<RknnRuntime>>,
    model_path: Option<&Path>,
) -> Result<Option<Arc<RknnModel>>> {
    let Some(model_path) = model_path else {
        info!("{label} RKNN model path not configured, using CPU backend");
        return Ok(None);
    };
    if !model_path.exists() {
        info!(
            "{} RKNN model not found at {}, using CPU backend",
            label,
            model_path.display()
        );
        return Ok(None);
    }
    let Some(runtime) = runtime else {
        info!("{label} RKNN runtime unavailable, using CPU backend");
        return Ok(None);
    };
    match runtime.load_model(model_path) {
        Ok(model) => {
            info!("Loaded {} RKNN model from {}", label, model_path.display());
            Ok(Some(Arc::new(model)))
        }
        Err(err) => {
            info!(
                "Failed to load {} RKNN model {}, using CPU backend: {:#}",
                label,
                model_path.display(),
                err
            );
            Ok(None)
        }
    }
}

fn ort_outputs_to_tensors(outputs: &ort::session::SessionOutputs<'_>) -> Result<Vec<TensorOutput>> {
    outputs
        .iter()
        .enumerate()
        .map(|(index, (name, value))| {
            let (shape, data) = value
                .try_extract_tensor::<f32>()
                .context("Failed to extract CLIP visual tensor")?;
            Ok(TensorOutput {
                spec: TensorSpec {
                    index,
                    name: Some(name.to_string()),
                    dims: shape.iter().map(|dim| *dim as usize).collect(),
                    element_count: data.len(),
                    format: TensorFormat::Undefined,
                },
                data: data.to_vec(),
            })
        })
        .collect()
}

fn select_visual_output<'a>(outputs: &'a [TensorOutput]) -> Result<&'a TensorOutput> {
    outputs
        .iter()
        .find(|output| output.spec.name.as_deref() == Some("output"))
        .or_else(|| {
            outputs
                .iter()
                .find(|output| output.spec.name.as_deref() == Some("image_features"))
        })
        .or_else(|| outputs.first())
        .context("No CLIP visual output found")
}
