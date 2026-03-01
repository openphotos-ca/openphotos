use anyhow::Result;
use image::{Rgb, RgbImage};
use imageproc::drawing::draw_hollow_rect_mut;
use imageproc::rect::Rect;
use log::{error, info, warn};
use std::collections::HashMap;
use std::fs::File;
use std::io::{BufReader, Write};
use std::path::Path;

mod face_detection;
mod face_normalization;
mod face_recognition;
mod types;
mod utils;

use face_detection::FaceDetector;
use face_normalization::FaceNormalizer;
use face_recognition::FaceRecognizer;
use types::FaceDetection;

const REFERENCES_DIR: &str = "../references";
const INPUT_DIR: &str = "../input";
const OUTPUT_DIR: &str = "../output";
const SIMILARITY_THRESHOLD: f32 = 0.4; // Reasonable threshold for face matching

struct ReferenceFace {
    name: String,
    embedding: Vec<f32>,
}

fn main() -> Result<()> {
    env_logger::init();

    info!("Starting face recognition system");

    // Initialize components
    let detector = FaceDetector::new("models/det_10g.onnx")?;
    let normalizer = FaceNormalizer::new();
    let recognizer = FaceRecognizer::new("models/w600k_r50.onnx")?;

    // Create output directory if it doesn't exist
    std::fs::create_dir_all(OUTPUT_DIR)?;

    // Load reference faces and generate embeddings
    info!("Loading reference faces from {}", REFERENCES_DIR);
    let reference_faces = load_reference_faces(&detector, &normalizer, &recognizer)?;
    info!("Loaded {} reference faces", reference_faces.len());

    // Process all images in input directory
    let input_files = utils::get_image_files(INPUT_DIR)?;
    info!("Found {} input images to process", input_files.len());

    for image_path in input_files.iter() {
        info!("Processing input image: {:?}", image_path);

        match process_input_image(
            &detector,
            &normalizer,
            &recognizer,
            &reference_faces,
            image_path,
        ) {
            Ok(matched_names) => {
                if matched_names.is_empty() {
                    info!("No matching faces found in {:?}", image_path);
                } else {
                    info!("Found matches in {:?}: {:?}", image_path, matched_names);
                }
            }
            Err(e) => {
                error!("Failed to process {:?}: {}", image_path, e);
            }
        }
    }

    info!("Face recognition system completed");
    Ok(())
}

fn load_reference_faces(
    detector: &FaceDetector,
    normalizer: &FaceNormalizer,
    recognizer: &FaceRecognizer,
) -> Result<Vec<ReferenceFace>> {
    let mut reference_faces = Vec::new();
    let reference_files = utils::get_image_files(REFERENCES_DIR)?;

    for ref_path in reference_files.iter() {
        let name = ref_path.file_stem().unwrap().to_string_lossy().to_string();

        info!("Loading reference face: {}", name);

        let img = load_and_fix_orientation(ref_path)?;
        let detections = detector.detect(&img)?;

        if detections.is_empty() {
            warn!("No face detected in reference image: {}", name);
            continue;
        }

        // Take the first (most confident) face
        let detection = &detections[0];
        let normalized_face = normalizer.normalize_face(&img, detection)?;
        let embedding = recognizer.generate_embedding(&normalized_face)?;

        // Save normalized reference face for inspection
        let ref_debug_filename = format!("rust_normalized_ref_{}.jpg", name);
        let ref_debug_path = Path::new(OUTPUT_DIR).join(ref_debug_filename);
        normalized_face.save(&ref_debug_path)?;
        info!("Saved reference normalized face to {:?}", ref_debug_path);

        info!(
            "Generated embedding for {} (dimension: {})",
            name,
            embedding.len()
        );

        reference_faces.push(ReferenceFace { name, embedding });
    }

    Ok(reference_faces)
}

fn process_input_image(
    detector: &FaceDetector,
    normalizer: &FaceNormalizer,
    recognizer: &FaceRecognizer,
    reference_faces: &[ReferenceFace],
    image_path: &Path,
) -> Result<Vec<String>> {
    // Load image with orientation correction
    let img = load_and_fix_orientation(image_path)?;
    let mut img_with_boxes = img.to_rgb8();

    // Detect faces
    let detections = detector.detect(&img)?;
    info!("Detected {} faces in {:?}", detections.len(), image_path);

    let mut matched_names = Vec::new();
    let mut face_matches: HashMap<String, Vec<&FaceDetection>> = HashMap::new();

    // Process each detected face
    for (face_idx, detection) in detections.iter().enumerate() {
        // Normalize face and generate embedding
        let normalized_face = normalizer.normalize_face(&img, detection)?;
        let embedding = recognizer.generate_embedding(&normalized_face)?;

        // Save normalized face for ALL images to verify they look correct
        let debug_filename = format!(
            "rust_normalized_{}_{}.jpg",
            image_path.file_stem().unwrap().to_string_lossy(),
            face_idx
        );
        let debug_path = Path::new(OUTPUT_DIR).join(debug_filename);
        normalized_face.save(&debug_path)?;
        info!("Saved normalized face {} to {:?}", face_idx, debug_path);

        // Save embedding for IMG_2984 debugging
        if image_path.to_string_lossy().contains("IMG_2984") {
            let emb_filename = format!("rust_IMG_2984_face_{}_embedding.txt", face_idx);
            let emb_path = Path::new(OUTPUT_DIR).join(emb_filename);
            save_embedding_as_text(&embedding, &emb_path)?;
        }

        // Compare with reference faces
        let mut best_match = ("", 0.0f32);
        let mut all_scores = Vec::new();
        for ref_face in reference_faces.iter() {
            let similarity = cosine_similarity(&embedding, &ref_face.embedding);
            all_scores.push((ref_face.name.as_str(), similarity));

            // Track best match for debugging
            if similarity > best_match.1 {
                best_match = (&ref_face.name, similarity);
            }

            if similarity > SIMILARITY_THRESHOLD {
                info!(
                    "Face matched with {} (similarity: {:.3})",
                    ref_face.name, similarity
                );
                face_matches
                    .entry(ref_face.name.clone())
                    .or_insert_with(Vec::new)
                    .push(detection);

                if !matched_names.contains(&ref_face.name) {
                    matched_names.push(ref_face.name.clone());
                }
            }
        }

        // Log all similarities for debug (IMG_2984 and test2)
        if image_path.to_string_lossy().contains("IMG_2984")
            || image_path.to_string_lossy().contains("test2")
        {
            info!(
                "Face {} similarities: hong={:.3}, you={:.3}, zheng={:.3}",
                face_idx,
                all_scores
                    .iter()
                    .find(|&&(n, _)| n == "hong")
                    .map(|&(_, s)| s)
                    .unwrap_or(0.0),
                all_scores
                    .iter()
                    .find(|&&(n, _)| n == "you")
                    .map(|&(_, s)| s)
                    .unwrap_or(0.0),
                all_scores
                    .iter()
                    .find(|&&(n, _)| n == "zheng")
                    .map(|&(_, s)| s)
                    .unwrap_or(0.0)
            );
        }

        // Log best match even if below threshold for debugging
        if best_match.1 > 0.0 && best_match.1 <= SIMILARITY_THRESHOLD {
            info!(
                "Best match below threshold: {} (similarity: {:.3})",
                best_match.0, best_match.1
            );
        }
    }

    // If we found matches, draw rectangles and save the image
    if !matched_names.is_empty() {
        // Draw green rectangles around matched faces
        for (_name, detections) in face_matches.iter() {
            for detection in detections {
                draw_face_rectangle(&mut img_with_boxes, detection);
            }
        }

        // Generate output filename
        let base_name = image_path.file_stem().unwrap().to_string_lossy();
        matched_names.sort(); // Ensure consistent ordering
        let output_filename = format!("{}_{}.jpg", base_name, matched_names.join("_"));
        let output_path = Path::new(OUTPUT_DIR).join(output_filename);

        // Save the image with rectangles
        img_with_boxes.save(&output_path)?;
        info!("Saved annotated image to {:?}", output_path);
    }

    Ok(matched_names)
}

fn draw_face_rectangle(img: &mut RgbImage, detection: &FaceDetection) {
    let bbox = &detection.bbox;

    // Convert normalized coordinates to pixel coordinates
    let (img_width, img_height) = img.dimensions();
    let x = (bbox.x1 * img_width as f32) as i32;
    let y = (bbox.y1 * img_height as f32) as i32;
    let width = ((bbox.x2 - bbox.x1) * img_width as f32) as u32;
    let height = ((bbox.y2 - bbox.y1) * img_height as f32) as u32;

    // Ensure coordinates are within bounds
    let x = x.max(0).min(img_width as i32 - 1);
    let y = y.max(0).min(img_height as i32 - 1);
    let width = width.min(img_width - x as u32);
    let height = height.min(img_height - y as u32);

    // Draw green rectangle
    let rect = Rect::at(x, y).of_size(width, height);
    let green = Rgb([0u8, 255u8, 0u8]);

    // Draw with thickness of 3 pixels
    for offset in 0..3 {
        if x - offset >= 0 && y - offset >= 0 {
            let inner_rect = Rect::at(x - offset, y - offset)
                .of_size(width + 2 * offset as u32, height + 2 * offset as u32);
            draw_hollow_rect_mut(img, inner_rect, green);
        }
    }
}

fn cosine_similarity(a: &[f32], b: &[f32]) -> f32 {
    if a.len() != b.len() {
        return 0.0;
    }

    let dot_product: f32 = a.iter().zip(b.iter()).map(|(x, y)| x * y).sum();
    let norm_a: f32 = a.iter().map(|x| x * x).sum::<f32>().sqrt();
    let norm_b: f32 = b.iter().map(|x| x * x).sum::<f32>().sqrt();

    if norm_a == 0.0 || norm_b == 0.0 {
        return 0.0;
    }

    dot_product / (norm_a * norm_b)
}

fn save_embedding_as_text(embedding: &[f32], path: &Path) -> Result<()> {
    let mut file = File::create(path)?;

    // Save embedding as text format for easy comparison
    writeln!(file, "shape: ({})", embedding.len())?;
    writeln!(
        file,
        "norm: {:.6}",
        (embedding.iter().map(|x| x * x).sum::<f32>()).sqrt()
    )?;
    write!(file, "data: [")?;
    for (i, &val) in embedding.iter().enumerate() {
        if i > 0 {
            write!(file, ", ")?;
        }
        write!(file, "{:.6}", val)?;
        if i >= 10 {
            // Show first 10 values
            write!(file, ", ... and {} more", embedding.len() - 11)?;
            break;
        }
    }
    writeln!(file, "]")?;

    Ok(())
}

fn load_and_fix_orientation(image_path: &Path) -> Result<image::DynamicImage> {
    use std::fs::File;

    // Try to read EXIF data
    let file = File::open(image_path)?;
    let mut buf_reader = BufReader::new(&file);
    let exifreader = exif::Reader::new();

    let mut orientation = 1u32; // Default orientation (no rotation)

    if let Ok(exif_data) = exifreader.read_from_container(&mut buf_reader) {
        if let Some(field) = exif_data.get_field(exif::Tag::Orientation, exif::In::PRIMARY) {
            if let exif::Value::Short(values) = &field.value {
                if !values.is_empty() {
                    orientation = values[0] as u32;
                    info!(
                        "EXIF orientation for {:?}: {}",
                        image_path.file_name().unwrap_or_default(),
                        orientation
                    );
                }
            }
        }
    }

    // Load the image
    let mut img = image::open(image_path)?;

    // Apply rotation based on EXIF orientation
    img = match orientation {
        1 => img,                     // No rotation
        2 => img.fliph(),             // Flip horizontal
        3 => img.rotate180(),         // Rotate 180°
        4 => img.flipv(),             // Flip vertical
        5 => img.fliph().rotate90(),  // Flip horizontal + rotate 90° CW
        6 => img.rotate90(),          // Rotate 90° CW
        7 => img.fliph().rotate270(), // Flip horizontal + rotate 270° CW
        8 => img.rotate270(),         // Rotate 270° CW (90° CCW)
        _ => {
            warn!("Unknown EXIF orientation: {}, using original", orientation);
            img
        }
    };

    Ok(img)
}
