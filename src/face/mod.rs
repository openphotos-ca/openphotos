pub mod detection;
pub mod recognition;
pub mod clustering;
pub mod normalization;
pub mod types;

pub use detection::FaceDetector;
pub use recognition::FaceRecognizer;
pub use clustering::{cluster_faces, FaceCluster};
pub use normalization::FaceNormalizer;
pub use types::{DetectedFace, FaceEmbedding, Person};

use anyhow::Result;
use std::path::Path;
use image::DynamicImage;

/// High-level face processing pipeline
pub struct FaceProcessor {
    detector: FaceDetector,
    normalizer: FaceNormalizer,
    recognizer: FaceRecognizer,
}

impl FaceProcessor {
    pub fn new(models_path: &Path) -> Result<Self> {
        let detector = FaceDetector::new(&models_path.join("face/det_10g.onnx"))?;
        let normalizer = FaceNormalizer::new();
        let recognizer = FaceRecognizer::new(&models_path.join("face/w600k_r50.onnx"))?;
        
        Ok(Self {
            detector,
            normalizer,
            recognizer,
        })
    }
    
    /// Process an image and return face embeddings
    pub fn process_image(&self, image: &DynamicImage) -> Result<Vec<FaceEmbedding>> {
        let faces = self.detector.detect_faces(image)?;
        let mut embeddings = Vec::new();
        
        for face in faces {
            if let Ok(normalized) = self.normalizer.normalize_face(image, &face) {
                if let Ok(embedding) = self.recognizer.generate_embedding(&normalized) {
                    embeddings.push(FaceEmbedding {
                        bbox: face.bbox,
                        embedding,
                        confidence: face.confidence,
                    });
                }
            }
        }
        
        Ok(embeddings)
    }
    
    /// Extract a face thumbnail from an image
    pub fn extract_face_thumbnail(
        &self,
        image: &DynamicImage,
        bbox: &[f32; 4],
        size: u32,
    ) -> Result<DynamicImage> {
        let (img_width, img_height) = (image.width() as f32, image.height() as f32);
        
        // Convert normalized bbox to pixel coordinates
        let x1 = (bbox[0] * img_width).max(0.0) as u32;
        let y1 = (bbox[1] * img_height).max(0.0) as u32;
        let x2 = (bbox[2] * img_width).min(img_width) as u32;
        let y2 = (bbox[3] * img_height).min(img_height) as u32;
        
        // Add some padding around the face
        let padding = ((x2 - x1).max(y2 - y1) as f32 * 0.2) as u32;
        let x1 = x1.saturating_sub(padding);
        let y1 = y1.saturating_sub(padding);
        let x2 = (x2 + padding).min(image.width());
        let y2 = (y2 + padding).min(image.height());
        
        let face_crop = image.crop_imm(x1, y1, x2 - x1, y2 - y1);
        Ok(face_crop.resize(size, size, image::imageops::FilterType::Lanczos3))
    }
}