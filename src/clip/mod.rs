pub mod textual;
pub mod visual;

use anyhow::Result;
use ndarray::{Array1, Array3, ArrayView1};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClipConfig {
    pub model_name: String,
    pub model_path: String,
    pub image_size: usize,
    pub embedding_dim: usize,
    pub visual_embedding_dim: Option<usize>, // Some models have different visual/textual dims
    pub mean: Vec<f32>,
    pub std: Vec<f32>,
    pub is_multilingual: bool,
    pub supported_languages: Vec<String>,
    pub model_type: ModelType,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum ModelType {
    OpenClip,
    MClip,
    XlmRobertaClip,
}

impl Default for ClipConfig {
    fn default() -> Self {
        Self {
            model_name: "ViT-B-32__openai".to_string(),
            model_path: "models".to_string(),
            image_size: 224,
            embedding_dim: 512,
            visual_embedding_dim: Some(512),
            mean: vec![0.48145466, 0.4578275, 0.40821073],
            std: vec![0.26862954, 0.26130258, 0.27577711],
            is_multilingual: false, // OpenAI CLIP is English-only but has better semantic understanding
            supported_languages: vec!["en".to_string()],
            model_type: ModelType::OpenClip,
        }
    }
}

pub fn normalize_embedding(embedding: ArrayView1<f32>) -> Array1<f32> {
    let norm = embedding.dot(&embedding).sqrt();
    if norm > 0.0 {
        &embedding / norm
    } else {
        embedding.to_owned()
    }
}

pub fn cosine_similarity(a: &[f32], b: &[f32]) -> f32 {
    assert_eq!(a.len(), b.len());

    let dot_product: f32 = a.iter().zip(b.iter()).map(|(x, y)| x * y).sum();
    let norm_a: f32 = a.iter().map(|x| x * x).sum::<f32>().sqrt();
    let norm_b: f32 = b.iter().map(|x| x * x).sum::<f32>().sqrt();

    if norm_a == 0.0 || norm_b == 0.0 {
        0.0
    } else {
        dot_product / (norm_a * norm_b)
    }
}

pub fn preprocess_image(
    image: &image::DynamicImage,
    size: usize,
    mean: &[f32],
    std: &[f32],
) -> Result<Array3<f32>> {
    use image::imageops::FilterType;

    // Resize to square using CatmullRom (equivalent to BICUBIC) to match Python exactly
    let resized = image.resize_exact(size as u32, size as u32, FilterType::CatmullRom);

    // Convert to RGB if needed
    let rgb = resized.to_rgb8();

    // Create array with shape [3, H, W]
    let mut array = Array3::<f32>::zeros((3, size, size));

    for (x, y, pixel) in rgb.enumerate_pixels() {
        let channels = pixel.0;
        for c in 0..3 {
            let normalized = (channels[c] as f32 / 255.0 - mean[c]) / std[c];
            array[[c, y as usize, x as usize]] = normalized;
        }
    }

    Ok(array)
}
