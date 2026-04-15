use anyhow::{Context, Result};
use ndarray::Array2;
use ort::{session::Session, value::Value};
use ort_session::{
    build_session_from_file, ProviderConfig, SessionOptimizationLevel, SessionTuning,
};
use parking_lot::Mutex;
use rknn_runtime::{AiBackend, RknnModel, RknnRuntime, TensorFormat, TensorOutput, TensorSpec};
use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;
use tokenizers::tokenizer::Tokenizer;
use tracing::{debug, info, instrument};

use super::{normalize_embedding, ClipConfig};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum EncoderBackend {
    Ort(AiBackend),
    Rknn,
}

pub struct TextualEncoder {
    cpu_session: Option<Arc<Mutex<Session>>>,
    rknn_model: Option<Arc<RknnModel>>,
    active_backend: Mutex<EncoderBackend>,
    tokenizer: Tokenizer,
    config: ClipConfig,
    context_length: usize,
}

impl TextualEncoder {
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
            .join("textual.onnx");

        let tokenizer_path = Path::new(&config.model_path)
            .join(&config.model_name)
            .join("tokenizer.json");

        info!("Loading CLIP textual model from: {:?}", model_path);
        info!("Loading tokenizer from: {:?}", tokenizer_path);

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
                    "Falling back to RKNN-only CLIP textual setup because CPU session failed: {}",
                    err
                );
                    (None, None)
                }
                Err(err) => return Err(err),
            };

        // Load tokenizer
        let mut tokenizer = Tokenizer::from_file(tokenizer_path)
            .map_err(|e| anyhow::anyhow!("Failed to load tokenizer: {}", e))?;

        // Configure tokenizer for CLIP
        let context_length = 77; // Standard CLIP context length

        // Let the tokenizer handle special tokens properly - don't override padding
        // The CLIP tokenizer should already be configured correctly in the JSON file

        let rknn_model = if ai_backend.prefers_rknn() && supports_rknn_text(&config) {
            try_load_rknn_model("CLIP textual", rknn_runtime, rknn_model_path)?
        } else {
            if ai_backend.prefers_rknn() && !supports_rknn_text(&config) {
                info!(
                    "CLIP textual model {:?} requires unsupported multi-input RKNN flow, using CPU backend",
                    config.model_type
                );
            }
            None
        };

        if cpu_session.is_none() && rknn_model.is_none() {
            return Err(anyhow::anyhow!(
                "failed to initialize any CLIP textual backend for {:?}",
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
            debug!("Textual model inputs: {:?}", session.inputs.len());
            debug!("Textual model outputs: {:?}", session.outputs.len());
        }

        Ok(Self {
            cpu_session,
            rknn_model,
            active_backend: Mutex::new(active_backend),
            tokenizer,
            config,
            context_length,
        })
    }

    /// Clean text similar to Immich's clean_text function
    /// Normalizes whitespace and handles basic text preprocessing
    fn clean_text(&self, text: &str) -> String {
        // Similar to Immich's: text = " ".join(text.split())
        text.split_whitespace().collect::<Vec<&str>>().join(" ")
    }

    #[instrument(skip(self))]
    pub fn encode_text(&self, text: &str) -> Result<Vec<f32>> {
        // Clean text similar to Immich's clean_text function
        let cleaned_text = self.clean_text(text);

        debug!(
            "Original text: '{}', Cleaned text: '{}'",
            text, cleaned_text
        );

        // Tokenize text with special tokens
        let encoding = self
            .tokenizer
            .encode(cleaned_text.as_str(), true) // ← Use cleaned text
            .map_err(|e| anyhow::anyhow!("Tokenization failed: {}", e))?;

        let mut input_ids = encoding.get_ids().to_vec();

        eprintln!("Tokenized '{}' -> {:?}", text, input_ids);

        // Ensure exactly 77 tokens with padding using the proper EOS token (49407)
        // This is critical for CLIP to work correctly - Immich uses 49407, not 0!
        input_ids.resize(self.context_length, 49407);

        eprintln!("Padded tokens: {:?}", &input_ids[..10]); // Show first 10 tokens

        let backend = *self.active_backend.lock();
        match backend {
            EncoderBackend::Ort(_) => self.encode_with_ort(&input_ids),
            EncoderBackend::Rknn => match self.encode_with_rknn(&input_ids) {
                Ok(embedding) => Ok(embedding),
                Err(err) => {
                    if self.cpu_session.is_some() {
                        info!(
                            "RKNN CLIP textual inference failed, downgrading to CPU fallback: {}",
                            err
                        );
                        *self.active_backend.lock() = EncoderBackend::Ort(AiBackend::Cpu);
                        self.encode_with_ort(&input_ids)
                    } else {
                        Err(err)
                    }
                }
            },
        }
    }

    fn encode_with_ort(&self, input_ids: &[u32]) -> Result<Vec<f32>> {
        let session = self
            .cpu_session
            .as_ref()
            .context("CLIP textual ONNX backend is unavailable")?;
        let session_guard = session.lock();
        let input_names: Vec<String> = session_guard
            .inputs
            .iter()
            .map(|i| i.name.clone())
            .collect();
        drop(session_guard);
        let mut inputs: HashMap<String, Value> = HashMap::new();

        if self.config.is_multilingual {
            match self.config.model_type {
                crate::clip::ModelType::XlmRobertaClip => {
                    // XLM-RoBERTa CLIP expects only input_ids (int64) - no attention mask
                    let ids_vec = input_ids.iter().map(|&id| id as i64).collect::<Vec<_>>();
                    let input_array = Array2::from_shape_vec((1, self.context_length), ids_vec)?;
                    let input_value = Value::from_array(input_array)?;

                    // Only add input_ids for XLM-RoBERTa CLIP
                    inputs.insert("input_ids".to_string(), input_value.into());
                }
                _ => {
                    // M-CLIP models expect int64 tensors and attention mask
                    let ids_vec = input_ids.iter().map(|&id| id as i64).collect::<Vec<_>>();
                    let input_array = Array2::from_shape_vec((1, self.context_length), ids_vec)?;
                    let input_value = Value::from_array(input_array)?;

                    // Create attention mask (1 for real tokens, 0 for padding)
                    // CLIP uses 49407 as the padding token, not 0!
                    let attention_mask: Vec<i64> = input_ids
                        .iter()
                        .map(|&id| if id != 49407 { 1i64 } else { 0i64 })
                        .collect();
                    let attention_mask_array =
                        Array2::from_shape_vec((1, self.context_length), attention_mask)?;
                    let attention_mask_value = Value::from_array(attention_mask_array)?;

                    // Add input_ids (usually first input)
                    if let Some(input_name) = input_names.get(0) {
                        inputs.insert(input_name.clone(), input_value.into());
                    } else {
                        inputs.insert("input_ids".to_string(), input_value.into());
                    }

                    // Add attention_mask (usually second input)
                    if let Some(attention_name) = input_names.get(1) {
                        inputs.insert(attention_name.clone(), attention_mask_value.into());
                    } else {
                        inputs.insert("attention_mask".to_string(), attention_mask_value.into());
                    }
                }
            }
        } else {
            // OpenAI CLIP models expect int32 tensors and no attention mask
            let ids_vec = input_ids.iter().map(|&id| id as i32).collect::<Vec<_>>();
            let input_array = Array2::from_shape_vec((1, self.context_length), ids_vec)?;
            let input_value = Value::from_array(input_array)?;

            // Add only input_ids - no attention mask for OpenAI models
            // Use correct input name 'text' for OpenAI CLIP models
            inputs.insert("text".to_string(), input_value.into());
        }

        // Run inference
        let mut session_guard = session.lock();
        let outputs = session_guard.run(inputs)?;
        let outputs = ort_outputs_to_tensors(&outputs)?;
        self.normalize_output(select_textual_output(&outputs)?)
    }

    fn encode_with_rknn(&self, input_ids: &[u32]) -> Result<Vec<f32>> {
        let model = self
            .rknn_model
            .as_ref()
            .context("CLIP textual RKNN backend is unavailable")?;
        let outputs = if self.config.is_multilingual {
            match self.config.model_type {
                crate::clip::ModelType::XlmRobertaClip => {
                    let ids_vec = input_ids.iter().map(|&id| id as i64).collect::<Vec<_>>();
                    model.run_tokens_i64(&[1, self.context_length], &ids_vec)?
                }
                _ => {
                    return Err(anyhow::anyhow!(
                        "multi-input RKNN textual execution is not supported for {:?}",
                        self.config.model_type
                    ))
                }
            }
        } else {
            let ids_vec = input_ids.iter().map(|&id| id as i32).collect::<Vec<_>>();
            model.run_tokens_i32(&[1, self.context_length], &ids_vec)?
        };
        self.normalize_output(select_textual_output(&outputs)?)
    }

    fn normalize_output(&self, output: &TensorOutput) -> Result<Vec<f32>> {
        let shape = &output.spec.dims;
        let embedding_data = &output.data;

        let embedding_vec = if self.config.is_multilingual {
            match self.config.model_type {
                crate::clip::ModelType::XlmRobertaClip => {
                    // XLM-RoBERTa CLIP outputs flat vector (batch_size, embedding_dim) = (1, 512)
                    // Both text and visual encoders output 512d - properly aligned!
                    if shape.len() == 2 && shape[0] == 1 {
                        embedding_data[0..self.config.embedding_dim].to_vec()
                    } else {
                        debug!("Unexpected XLM-RoBERTa output shape: {:?}", shape);
                        embedding_data[0..self.config.embedding_dim.min(embedding_data.len())]
                            .to_vec()
                    }
                }
                _ => {
                    // M-CLIP outputs (batch_size, sequence_length, hidden_size) = (1, 77, 768)
                    // We need the [CLS] token embedding which is at position [0, 0, :]
                    if shape.len() == 3 && shape[0] == 1 && shape[1] >= 1 {
                        let hidden_size = shape[2] as usize;
                        // Extract [CLS] token embedding (first token in sequence)
                        let cls_embedding = embedding_data[0..hidden_size].to_vec();

                        // CRITICAL FIX: Project 768d text embeddings to 512d to match visual embeddings
                        // M-CLIP text outputs 768d but visual outputs 512d - they need to be in same space
                        if hidden_size == 768 && self.config.visual_embedding_dim == Some(512) {
                            // Simple linear projection by taking first 512 dimensions
                            // NOTE: This is a temporary fix - proper M-CLIP should have learned projection
                            debug!(
                                "Projecting text embedding from 768d to 512d to match visual space"
                            );
                            cls_embedding[0..512].to_vec()
                        } else {
                            cls_embedding
                        }
                    } else {
                        // Fallback: assume it's already pooled
                        embedding_data[0..self.config.embedding_dim.min(embedding_data.len())]
                            .to_vec()
                    }
                }
            }
        } else {
            // OpenAI CLIP outputs a flat vector (batch_size, embedding_dim) = (1, 512)
            embedding_data[0..self.config.embedding_dim].to_vec()
        };

        let embedding_array = ndarray::Array1::from_vec(embedding_vec);
        let normalized = normalize_embedding(embedding_array.view());

        Ok(normalized.to_vec())
    }

    #[instrument(skip(self))]
    pub fn encode_batch(&self, texts: &[String]) -> Result<Vec<Vec<f32>>> {
        if texts.is_empty() {
            return Ok(vec![]);
        }

        // For now, process texts one by one to avoid batch complexity
        let mut results = Vec::new();
        for text in texts {
            results.push(self.encode_text(text)?);
        }

        Ok(results)
    }

    pub fn embedding_dim(&self) -> usize {
        self.config.embedding_dim
    }
}

fn supports_rknn_text(config: &ClipConfig) -> bool {
    !config.is_multilingual || matches!(config.model_type, crate::clip::ModelType::XlmRobertaClip)
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
            "failed to load CLIP textual ONNX model {}",
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
                .context("Failed to extract CLIP textual tensor")?;
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

fn select_textual_output<'a>(outputs: &'a [TensorOutput]) -> Result<&'a TensorOutput> {
    outputs
        .iter()
        .find(|output| output.spec.name.as_deref() == Some("embedding"))
        .or_else(|| {
            outputs
                .iter()
                .find(|output| output.spec.name.as_deref() == Some("output"))
        })
        .or_else(|| {
            outputs
                .iter()
                .find(|output| output.spec.name.as_deref() == Some("text_features"))
        })
        .or_else(|| outputs.first())
        .context("No CLIP textual output found")
}

// Alternative simple tokenizer if tokenizer.json is not available
pub struct SimpleTokenizer {
    vocab: std::collections::HashMap<String, u32>,
    context_length: usize,
}

impl SimpleTokenizer {
    pub fn from_bpe_vocab(vocab_path: &Path) -> Result<Self> {
        use std::fs::File;
        use std::io::{BufRead, BufReader};

        let file = File::open(vocab_path)?;
        let reader = BufReader::new(file);
        let mut vocab = std::collections::HashMap::new();

        for (idx, line) in reader.lines().enumerate() {
            let token = line?;
            vocab.insert(token, idx as u32);
        }

        Ok(Self {
            vocab,
            context_length: 77,
        })
    }

    pub fn encode(&self, text: &str) -> Vec<u32> {
        // Simple whitespace tokenization (placeholder)
        // In production, use proper BPE tokenization
        let mut tokens = vec![self.vocab.get("<|startoftext|>").copied().unwrap_or(0)];

        for word in text.split_whitespace() {
            if let Some(&token_id) = self.vocab.get(word) {
                tokens.push(token_id);
            }

            if tokens.len() >= self.context_length - 1 {
                break;
            }
        }

        tokens.push(self.vocab.get("<|endoftext|>").copied().unwrap_or(0));
        tokens.resize(self.context_length, 0);
        tokens
    }
}
