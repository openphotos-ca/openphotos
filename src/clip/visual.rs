use anyhow::{Context, Result};
use image::{DynamicImage, GenericImageView};
use ndarray::Axis;
use ort::{
    session::{
        builder::{GraphOptimizationLevel, SessionBuilder},
        Session,
    },
    value::Value,
};
use parking_lot::Mutex;
use std::collections::HashMap;
use std::path::Path;
use tracing::{debug, info, instrument};

use super::{normalize_embedding, preprocess_image, ClipConfig};

pub struct VisualEncoder {
    session: Mutex<Session>,
    config: ClipConfig,
}

impl VisualEncoder {
    pub fn new(config: ClipConfig) -> Result<Self> {
        let model_path = Path::new(&config.model_path)
            .join(&config.model_name)
            .join("visual.onnx");

        info!("Loading CLIP visual model from: {:?}", model_path);

        let session = SessionBuilder::new()?
            .with_optimization_level(GraphOptimizationLevel::Level3)?
            .with_intra_threads(1)?
            .commit_from_file(model_path)?;

        // Verify model inputs/outputs
        debug!("Visual model inputs: {:?}", session.inputs.len());
        debug!("Visual model outputs: {:?}", session.outputs.len());

        Ok(Self {
            session: Mutex::new(session),
            config,
        })
    }

    #[instrument(skip(self, image))]
    pub fn encode_image(&self, image: &DynamicImage) -> Result<Vec<f32>> {
        // Preprocess image
        let preprocessed = preprocess_image(
            image,
            self.config.image_size,
            &self.config.mean,
            &self.config.std,
        )?;

        // Add batch dimension [1, 3, H, W]
        let input = preprocessed.insert_axis(Axis(0));

        // Convert to ONNX Value
        let input_value = Value::from_array(input)?;

        // Prepare inputs - try common input names
        let input_name = {
            let session_guard = self.session.lock();
            session_guard
                .inputs
                .first()
                .map(|i| i.name.clone())
                .unwrap_or_else(|| "input".to_string())
        };

        let mut inputs: HashMap<String, Value> = HashMap::new();
        inputs.insert(input_name, input_value.into());

        // Run inference
        let mut session_guard = self.session.lock();
        let outputs = session_guard.run(inputs)?;

        // Get the embedding output - try common output names
        let output_key = if outputs.contains_key("output") {
            "output"
        } else if outputs.contains_key("image_features") {
            "image_features"
        } else {
            outputs.keys().next().context("No output found")?
        };

        let output_value = &outputs[output_key];

        let (shape, embedding_data) = output_value
            .try_extract_tensor::<f32>()
            .context("Failed to extract embedding tensor")?;

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
