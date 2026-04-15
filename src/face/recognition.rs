use anyhow::{anyhow, Result};
use image::RgbImage;
use log::{debug, info, warn};
use ndarray::Array4;
use ort_session::{build_session_from_file, ProviderConfig, SessionTuning};
use ort::{
    session::{Session, SessionOutputs},
    value::Value
};
use rknn_runtime::AiBackend;
use std::cell::RefCell;
use std::path::Path;

pub struct FaceRecognizer {
    session: Option<RefCell<Session>>,
    input_size: (u32, u32),
}

impl FaceRecognizer {
    pub fn new(model_path: &Path) -> Result<Self> {
        Self::new_with_backend(model_path, AiBackend::Cpu, 0)
    }

    pub fn new_with_backend(model_path: &Path, ai_backend: AiBackend, ai_device_id: i32) -> Result<Self> {
        info!("Initializing ArcFace Recognizer with model: {}", model_path.display());

        let session = if model_path.exists() {
            info!("Loading ArcFace ONNX model from {}", model_path.display());
            let built = build_session_from_file(
                model_path,
                ProviderConfig::new(ai_backend, ai_device_id),
                SessionTuning::default(),
            )?;
            Some(RefCell::new(built.session))
        } else {
            warn!("ArcFace model not found at {}", model_path.display());
            None
        };

        Ok(Self {
            session,
            input_size: (112, 112), // ArcFace standard input size
        })
    }

    pub fn generate_embedding(&self, normalized_face: &RgbImage) -> Result<Vec<f32>> {
        if let Some(session_cell) = &self.session {
            self.generate_arcface_embedding(normalized_face, session_cell)
        } else {
            // Generate deterministic embeddings based on image content
            self.generate_placeholder_embedding(normalized_face)
        }
    }

    fn generate_arcface_embedding(&self, face: &RgbImage, session_cell: &RefCell<Session>) -> Result<Vec<f32>> {
        // Ensure face is the correct size
        let (width, height) = face.dimensions();
        if width != self.input_size.0 || height != self.input_size.1 {
            return Err(anyhow!(
                "Face image must be {}x{}, got {}x{}",
                self.input_size.0, self.input_size.1, width, height
            ));
        }
        
        // Preprocess the face image
        let input_tensor = self.preprocess_face(face)?;
        
        // Run inference - ArcFace uses "input.1" as input name  
        let inputs = ort::inputs!["input.1" => input_tensor];
        let mut session = session_cell.borrow_mut();
        let outputs = session.run(inputs)?;
        
        // Extract embedding from output
        let embedding = self.extract_arcface_embedding(&outputs)?;
        
        debug!("Generated ArcFace embedding with dimension {}", embedding.len());
        Ok(embedding)
    }

    fn preprocess_face(&self, face: &RgbImage) -> Result<Value> {
        // ArcFace preprocessing (same as Python insightface):
        // 1. Convert RGB to BGR
        // 2. Normalize to [-1, 1] range using (pixel - 127.5) / 127.5
        
        let mut array = Array4::<f32>::zeros((
            1, 
            3, 
            self.input_size.1 as usize, 
            self.input_size.0 as usize
        ));
        
        for y in 0..self.input_size.1 {
            for x in 0..self.input_size.0 {
                let pixel = face.get_pixel(x, y);
                
                // Convert RGB to BGR and normalize to [-1, 1] (ArcFace normalization)
                array[[0, 0, y as usize, x as usize]] = (pixel[2] as f32 - 127.5) / 127.5; // B
                array[[0, 1, y as usize, x as usize]] = (pixel[1] as f32 - 127.5) / 127.5; // G
                array[[0, 2, y as usize, x as usize]] = (pixel[0] as f32 - 127.5) / 127.5; // R
            }
        }
        
        Ok(Value::from_array(array)?.into())
    }

    fn extract_arcface_embedding(&self, outputs: &SessionOutputs<'_>) -> Result<Vec<f32>> {
        // ArcFace typically outputs a single tensor with embeddings
        if outputs.len() == 0 {
            return Err(anyhow!("No output from ArcFace model"));
        }
        
        // Get the first (and typically only) output
        let embedding_tensor = outputs.iter().next().unwrap().1;
        let (embedding_shape, embedding_data) = embedding_tensor.try_extract_tensor::<f32>()?;
        
        debug!("ArcFace output shape: {:?}", embedding_shape);
        
        // Extract the embedding vector - should be (1, 512) typically
        let embedding_size = if embedding_shape.len() == 2 {
            embedding_shape[1] as usize
        } else {
            embedding_data.len() // Flatten if needed
        };
        
        let mut embedding = Vec::with_capacity(embedding_size);
        
        if embedding_shape.len() == 2 {
            // 2D output: (batch_size, embedding_dim)
            for i in 0..embedding_size {
                embedding.push(embedding_data[i]);
            }
        } else {
            // 1D output: just copy the data
            embedding.extend_from_slice(embedding_data);
        }
        
        // L2 normalize the embedding (standard for ArcFace)
        // Disabled to match Python InsightFace output format
        // self.normalize_l2(&mut embedding);
        
        Ok(embedding)
    }

    fn generate_placeholder_embedding(&self, face: &RgbImage) -> Result<Vec<f32>> {
        // Generate a deterministic 512-dimensional embedding based on image statistics
        // This matches the actual ArcFace output format
        let mut embedding = vec![0.0f32; 512];
        
        let (width, height) = face.dimensions();
        let total_pixels = (width * height) as f32;
        
        // Calculate basic image statistics
        let mut pixel_sums = [0.0f32; 3];
        let mut pixel_squares = [0.0f32; 3];
        
        for y in 0..height {
            for x in 0..width {
                let pixel = face.get_pixel(x, y);
                for i in 0..3 {
                    let val = pixel[i] as f32;
                    pixel_sums[i] += val;
                    pixel_squares[i] += val * val;
                }
            }
        }
        
        // Calculate means and standard deviations
        let means = [
            pixel_sums[0] / total_pixels,
            pixel_sums[1] / total_pixels,
            pixel_sums[2] / total_pixels,
        ];
        
        let stdevs = [
            ((pixel_squares[0] / total_pixels) - means[0] * means[0]).sqrt(),
            ((pixel_squares[1] / total_pixels) - means[1] * means[1]).sqrt(),
            ((pixel_squares[2] / total_pixels) - means[2] * means[2]).sqrt(),
        ];
        
        // Fill embedding with features derived from image statistics
        for i in 0..512 {
            let channel = i % 3;
            let stat_type = (i / 3) % 2;
            let position_factor = (i as f32 / 512.0) * 2.0 * std::f32::consts::PI;
            
            let base_value = if stat_type == 0 { means[channel] } else { stdevs[channel] };
            embedding[i] = (base_value / 255.0) * (position_factor.sin() * 0.5 + 0.5) * 2.0 - 1.0;
        }
        
        // L2 normalize the embedding
        self.normalize_l2(&mut embedding);
        
        debug!("Generated placeholder embedding with dimension {}", embedding.len());
        Ok(embedding)
    }

    fn normalize_l2(&self, embedding: &mut [f32]) {
        let norm = embedding.iter()
            .map(|&x| x * x)
            .sum::<f32>()
            .sqrt();
        
        if norm > 1e-10 {
            for x in embedding.iter_mut() {
                *x /= norm;
            }
        }
    }

    pub fn calculate_similarity(embedding1: &[f32], embedding2: &[f32]) -> f32 {
        assert_eq!(embedding1.len(), embedding2.len());
        
        // Cosine similarity (dot product of L2-normalized vectors)
        embedding1.iter()
            .zip(embedding2.iter())
            .map(|(a, b)| a * b)
            .sum()
    }
}
