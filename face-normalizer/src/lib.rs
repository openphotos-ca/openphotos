//! Face processing library for face detection, recognition, clustering, and search
//!
//! This library provides a complete face processing pipeline using:
//! - RetinaFace for face detection
//! - ArcFace for face recognition embeddings
//! - DBSCAN for automatic face clustering
//! - Cosine similarity for face search

pub mod clustering;
pub mod face_detection;
pub mod face_normalization;
pub mod face_recognition;
pub mod types;
pub mod utils;
pub mod yolo_detection;

// Re-export main types and components
pub use clustering::FaceClusterer;
pub use face_detection::FaceDetector;
pub use face_normalization::FaceNormalizer;
pub use face_recognition::FaceRecognizer;
pub use types::*;
pub use yolo_detection::{
    BoundingBox as YoloBoundingBox, Detection as YoloDetection, YoloDetector,
};

use anyhow::Result;
use image::GenericImageView;
use log::{debug, error, info};
use std::collections::HashMap;
use std::path::{Path, PathBuf};

// Minimum size for YOLO person detections (to filter out small false positives)
// Detections smaller than this will be ignored as they're likely noise or too small for face recognition
const MIN_PERSON_SIZE: f32 = 50.0; // Minimum width or height in pixels

// Minimum size for face detections (to filter out tiny partial face crops)
// Face detections smaller than this are likely false positives or too small to be useful
// Minimum size for face detections (to filter out tiny partial face crops)
// Face detections smaller than this are likely false positives or too small to be useful
const MIN_FACE_SIZE: f32 = 50.0; // Minimum width or height in pixels

// Aspect ratio constraints for face detections
// Real human faces typically have width/height ratios between 0.6 and 1.7
const MIN_FACE_ASPECT_RATIO: f32 = 0.6; // Minimum width/height ratio (tall faces)
const MAX_FACE_ASPECT_RATIO: f32 = 1.7; // Maximum width/height ratio (wide faces)

/// Face data structure containing all information about a detected face
#[derive(Debug, Clone)]
pub struct FaceData {
    pub photo_path: PathBuf,
    pub face_index: usize,
    pub embedding: Vec<f32>,
    pub bbox: BoundingBox,
    pub confidence: f32,
    // JPEG-encoded 112x112 aligned face thumbnail
    pub aligned_thumbnail: Option<Vec<u8>>,
}

// Constants from the original implementation
pub const SIMILARITY_THRESHOLD: f32 = 0.4; // Same as original face recognition
pub const CLUSTERING_EPS: f32 = 1.0 - SIMILARITY_THRESHOLD; // Distance threshold (0.6)
pub const MIN_SAMPLES: usize = 1; // Allow single faces to form clusters

/// Collect all faces from images in a directory
///
/// This is a modified version of the original collect_all_faces function
/// that accepts a directory parameter instead of using a hardcoded path
pub fn collect_all_faces(
    directory: &Path,
    detector: &FaceDetector,
    normalizer: &FaceNormalizer,
    recognizer: &FaceRecognizer,
) -> Result<Vec<FaceData>> {
    let mut all_faces = Vec::new();
    let input_files = utils::get_image_files(directory)?;

    for (file_idx, image_path) in input_files.iter().enumerate() {
        info!(
            "Processing image {}/{}: {:?}",
            file_idx + 1,
            input_files.len(),
            image_path
        );

        match process_image_for_faces(detector, normalizer, recognizer, image_path) {
            Ok(faces) => {
                info!("  Found {} faces", faces.len());
                all_faces.extend(faces);
            }
            Err(e) => {
                error!("  Failed to process {:?}: {}", image_path, e);
            }
        }
    }

    Ok(all_faces)
}

/// Collect all faces from images in multiple directories with YOLO person pre-filtering
///
/// This version takes an array of directories and processes all photos in all directories.
/// This supports configurable multiple folder directories for future releases.
pub fn collect_all_faces_from_directories(
    directories: &[&Path],
    detector: &FaceDetector,
    normalizer: &FaceNormalizer,
    recognizer: &FaceRecognizer,
    yolo: &YoloDetector,
) -> Result<Vec<FaceData>> {
    let mut all_faces = Vec::new();
    let mut total_files_processed = 0;

    for (dir_idx, directory) in directories.iter().enumerate() {
        info!(
            "Processing directory {}/{}: {:?}",
            dir_idx + 1,
            directories.len(),
            directory
        );

        let input_files = match utils::get_image_files(directory) {
            Ok(files) => files,
            Err(e) => {
                error!(
                    "Failed to get image files from directory {:?}: {}",
                    directory, e
                );
                continue;
            }
        };

        info!(
            "Found {} images in directory {:?}",
            input_files.len(),
            directory
        );

        for (file_idx, image_path) in input_files.iter().enumerate() {
            total_files_processed += 1;
            info!(
                "Processing image {} (total {}): {:?}",
                file_idx + 1,
                total_files_processed,
                image_path
            );

            // Pre-filter: Check if image contains any persons using YOLO
            let img = load_and_fix_orientation(image_path)?;
            let yolo_detections = yolo.detect(&img)?;

            // Filter person detections by minimum size (to eliminate small false positives)
            let person_detections: Vec<_> = yolo_detections
                .iter()
                .filter(|det| {
                    det.class == "person"
                        && det.bbox.width >= MIN_PERSON_SIZE
                        && det.bbox.height >= MIN_PERSON_SIZE
                })
                .cloned()
                .collect();

            let total_persons = yolo_detections
                .iter()
                .filter(|det| det.class == "person")
                .count();
            let filtered_persons = person_detections.len();

            if person_detections.is_empty() {
                if total_persons > 0 {
                    info!("  YOLO detected {} person(s) but all were too small (< {} pixels), skipping face detection", 
                          total_persons, MIN_PERSON_SIZE);
                } else {
                    info!("  No persons detected by YOLO, skipping face detection");
                }
                continue;
            }

            if filtered_persons < total_persons {
                info!(
                    "  YOLO detected {} person(s), {} large enough for processing",
                    total_persons, filtered_persons
                );
            }

            info!("  YOLO detected person(s), running face detection in person regions");
            match process_image_for_faces_in_regions(
                detector,
                normalizer,
                recognizer,
                image_path,
                &person_detections,
            ) {
                Ok(faces) => {
                    info!("  Found {} faces", faces.len());
                    all_faces.extend(faces);
                }
                Err(e) => {
                    error!("  Failed to process {:?}: {}", image_path, e);
                }
            }
        }

        info!(
            "Completed processing directory {:?}: {} faces collected so far",
            directory,
            all_faces.len()
        );
    }

    info!(
        "Completed processing all {} directories: {} total faces collected",
        directories.len(),
        all_faces.len()
    );
    Ok(all_faces)
}

/// Collect all faces from images in a directory with YOLO person pre-filtering
///
/// This version uses YOLO to detect persons first and only runs face detection
/// in regions near detected persons to eliminate false positives in landscapes.
pub fn collect_all_faces_with_yolo(
    directory: &Path,
    detector: &FaceDetector,
    normalizer: &FaceNormalizer,
    recognizer: &FaceRecognizer,
    yolo: &YoloDetector,
) -> Result<Vec<FaceData>> {
    // Use the new multi-directory function with a single directory
    collect_all_faces_from_directories(&[directory], detector, normalizer, recognizer, yolo)
}

/// Process a single image to extract all faces and their embeddings
pub fn process_image_for_faces(
    detector: &FaceDetector,
    normalizer: &FaceNormalizer,
    recognizer: &FaceRecognizer,
    image_path: &Path,
) -> Result<Vec<FaceData>> {
    // Use EXIF-corrected image for consistent bbox coordinates with cropping
    let img = load_and_fix_orientation(image_path)?;
    let all_detections = detector.detect(&img)?;

    // Filter out faces that are too small or have unrealistic aspect ratios
    let detections: Vec<_> = all_detections
        .iter()
        .filter(|detection| {
            let width = detection.bbox.x2 - detection.bbox.x1;
            let height = detection.bbox.y2 - detection.bbox.y1;
            let aspect_ratio = width / height;

            // Check minimum size
            let size_ok = width >= MIN_FACE_SIZE && height >= MIN_FACE_SIZE;

            // Check aspect ratio is within reasonable bounds for human faces
            let aspect_ok =
                aspect_ratio >= MIN_FACE_ASPECT_RATIO && aspect_ratio <= MAX_FACE_ASPECT_RATIO;

            if !size_ok || !aspect_ok {
                info!(
                    "    Filtered face: size={}x{}, aspect={:.2}, size_ok={}, aspect_ok={}",
                    width, height, aspect_ratio, size_ok, aspect_ok
                );
            }

            size_ok && aspect_ok
        })
        .collect();

    if all_detections.len() != detections.len() {
        info!(
            "  Filtered out {} face detections (size < {}px or bad aspect ratio)",
            all_detections.len() - detections.len(),
            MIN_FACE_SIZE
        );
    }

    info!(
        "  Face detector found {} potential faces (no YOLO gating)",
        detections.len()
    );
    let mut faces = Vec::new();

    for (face_idx, detection) in detections.iter().enumerate() {
        // Minimal validation only (geometry disabled)
        if is_likely_human_face(&detection, &img) {
            let normalized_face = normalizer.normalize_face(&img, detection)?;
            let embedding = recognizer.generate_embedding(&normalized_face)?;

            // JPEG-encode aligned face for upright thumbnail
            let mut thumb_buf = Vec::new();
            let rgb = normalized_face;
            if image::codecs::jpeg::JpegEncoder::new_with_quality(&mut thumb_buf, 85)
                .encode(&rgb, rgb.width(), rgb.height(), image::ColorType::Rgb8)
                .is_err()
            {
                thumb_buf.clear();
            }

            faces.push(FaceData {
                photo_path: image_path.to_path_buf(),
                face_index: face_idx,
                embedding,
                bbox: detection.bbox.clone(),
                confidence: detection.confidence,
                aligned_thumbnail: if thumb_buf.is_empty() {
                    None
                } else {
                    Some(thumb_buf)
                },
            });
        } else {
            info!(
                "  Filtered out face by size/conf: ({:.0},{:.0}) to ({:.0},{:.0})",
                detection.bbox.x1, detection.bbox.y1, detection.bbox.x2, detection.bbox.y2
            );
        }
    }

    Ok(faces)
}

/// Process a single image with pre-computed YOLO detections (exposed for API use)
pub fn process_image_for_faces_with_yolo_detections(
    detector: &FaceDetector,
    normalizer: &FaceNormalizer,
    recognizer: &FaceRecognizer,
    image_path: &Path,
    yolo_detections: &[YoloDetection],
) -> Result<Vec<FaceData>> {
    process_image_for_faces_in_regions(
        detector,
        normalizer,
        recognizer,
        image_path,
        yolo_detections,
    )
}

/// Process a single image with region-based face detection using YOLO person detections
fn process_image_for_faces_in_regions(
    detector: &FaceDetector,
    normalizer: &FaceNormalizer,
    recognizer: &FaceRecognizer,
    image_path: &Path,
    yolo_detections: &[YoloDetection],
) -> Result<Vec<FaceData>> {
    // Use EXIF-corrected image for consistent bbox coordinates with cropping
    let img = load_and_fix_orientation(image_path)?;

    // Create expanded regions around YOLO person detections (with confidence + size gating)
    let person_regions = create_person_regions(&yolo_detections, img.dimensions());

    // Run face detection on the full image but filter results to person regions only
    let raw_face_detections = detector.detect(&img)?;

    // Filter out faces that are too small or have unrealistic aspect ratios
    let size_filtered_detections: Vec<_> = raw_face_detections
        .iter()
        .filter(|detection| {
            let width = detection.bbox.x2 - detection.bbox.x1;
            let height = detection.bbox.y2 - detection.bbox.y1;
            let aspect_ratio = width / height;

            // Check minimum size
            let size_ok = width >= MIN_FACE_SIZE && height >= MIN_FACE_SIZE;

            // Check aspect ratio is within reasonable bounds for human faces
            let aspect_ok =
                aspect_ratio >= MIN_FACE_ASPECT_RATIO && aspect_ratio <= MAX_FACE_ASPECT_RATIO;

            if !size_ok || !aspect_ok {
                info!(
                    "    Filtered face: size={}x{}, aspect={:.2}, size_ok={}, aspect_ok={}",
                    width, height, aspect_ratio, size_ok, aspect_ok
                );
            }

            size_ok && aspect_ok
        })
        .collect();

    if raw_face_detections.len() != size_filtered_detections.len() {
        info!(
            "  Filtered out {} face detections (size < {}px or bad aspect ratio)",
            raw_face_detections.len() - size_filtered_detections.len(),
            MIN_FACE_SIZE
        );
    }

    info!(
        "  Face detector found {} potential faces, filtering to person regions",
        size_filtered_detections.len()
    );

    let mut faces = Vec::new();

    // Optional: require faces to be in the upper/head portion of person regions
    let require_head_region = std::env::var("FACE_REQUIRE_HEAD_REGION")
        .ok()
        .map(|v| matches!(v.as_str(), "1" | "true" | "TRUE"))
        .unwrap_or(false);
    let head_ratio: f32 = std::env::var("FACE_HEAD_TOP_RATIO")
        .ok()
        .and_then(|s| s.parse::<f32>().ok())
        .unwrap_or(0.6);

    for (face_idx, face_detection) in size_filtered_detections.iter().enumerate() {
        // Check if this face detection overlaps with any person region (or head portion if required)
        let in_region = if require_head_region {
            is_face_in_head_portion_of_person_regions(
                &face_detection.bbox,
                &person_regions,
                head_ratio,
            )
        } else {
            is_face_in_person_regions(&face_detection.bbox, &person_regions)
        };
        if in_region {
            if is_likely_human_face(&face_detection, &img) {
                let normalized_face = normalizer.normalize_face(&img, face_detection)?;
                let embedding = recognizer.generate_embedding(&normalized_face)?;

                // JPEG-encode aligned face for upright thumbnail
                let mut thumb_buf = Vec::new();
                let rgb = normalized_face;
                if image::codecs::jpeg::JpegEncoder::new_with_quality(&mut thumb_buf, 85)
                    .encode(&rgb, rgb.width(), rgb.height(), image::ColorType::Rgb8)
                    .is_err()
                {
                    thumb_buf.clear();
                }

                faces.push(FaceData {
                    photo_path: image_path.to_path_buf(),
                    face_index: face_idx,
                    embedding,
                    bbox: face_detection.bbox.clone(),
                    confidence: face_detection.confidence,
                    aligned_thumbnail: if thumb_buf.is_empty() {
                        None
                    } else {
                        Some(thumb_buf)
                    },
                });
            } else {
                info!(
                    "  Filtered out face by size/conf: ({:.0},{:.0}) to ({:.0},{:.0})",
                    face_detection.bbox.x1,
                    face_detection.bbox.y1,
                    face_detection.bbox.x2,
                    face_detection.bbox.y2
                );
            }
        } else {
            info!("  Filtered out face detection outside person regions: ({:.0},{:.0}) to ({:.0},{:.0})", 
                  face_detection.bbox.x1, face_detection.bbox.y1, face_detection.bbox.x2, face_detection.bbox.y2);
        }
    }

    Ok(faces)
}

/// Search for all photos containing a specific person
///
/// This is the core function for Filter-Faces functionality.
/// Takes a person photo (like p1.jpg) and returns all photos containing that person.
pub fn search_by_face(
    face_image_path: &Path,
    all_faces: &[FaceData],
    detector: &FaceDetector,
    normalizer: &FaceNormalizer,
    recognizer: &FaceRecognizer,
) -> Result<Vec<PathBuf>> {
    // Load the query face image (already cropped to just the face)
    let query_img = load_and_fix_orientation(face_image_path)?;

    // For cropped face images, try to detect a face first
    let query_detections = detector.detect(&query_img)?;

    // For person photos (px.jpg), skip face detection and treat the whole image as a normalized face
    let query_embedding = if face_image_path
        .file_name()
        .and_then(|name| name.to_str())
        .map(|name| name.starts_with("p") && name.ends_with(".jpg"))
        .unwrap_or(false)
    {
        // This is a person photo (p1.jpg, p2.jpg, etc.), treat whole image as the face
        let resized = query_img.resize_exact(112, 112, image::imageops::FilterType::Lanczos3);
        let rgb_image = resized.to_rgb8();
        recognizer.generate_embedding(&rgb_image)?
    } else {
        // For regular photos, use normal face detection pipeline
        if !query_detections.is_empty() {
            let query_detection = &query_detections[0];
            let query_normalized = normalizer.normalize_face(&query_img, query_detection)?;
            recognizer.generate_embedding(&query_normalized)?
        } else {
            return Ok(Vec::new()); // No faces found in regular photo
        }
    };

    // Find matching faces using the same similarity threshold as clustering
    let mut matching_photos = Vec::new();

    for face in all_faces {
        let similarity = cosine_similarity(&query_embedding, &face.embedding);
        if similarity >= SIMILARITY_THRESHOLD {
            matching_photos.push(face.photo_path.clone());
        }
    }

    // Remove duplicates (same photo might have multiple matching faces)
    matching_photos.sort();
    matching_photos.dedup();

    Ok(matching_photos)
}

/// Generate person photos and return person-to-photo mapping
///
/// This function creates representative photos for each clustered person (p1.jpg, p2.jpg, etc.)
/// and returns a mapping of person IDs to their photo paths for the UI.
pub fn generate_person_photos(
    face_data: &[FaceData],
    face_to_person: &[Option<String>],
    cluster_to_person: &HashMap<usize, String>,
    output_dir: &Path,
) -> Result<HashMap<String, PathBuf>> {
    use std::fs;

    // Create output directory if it doesn't exist
    fs::create_dir_all(output_dir)?;

    // Group faces by person
    let mut person_faces: HashMap<String, Vec<usize>> = HashMap::new();
    for (idx, person_opt) in face_to_person.iter().enumerate() {
        if let Some(person_id) = person_opt {
            person_faces
                .entry(person_id.clone())
                .or_insert_with(Vec::new)
                .push(idx);
        }
    }

    let mut person_to_photo = HashMap::new();

    // For each person, select the best face and save it
    for (person_id, face_indices) in person_faces.iter() {
        if face_indices.is_empty() {
            continue;
        }

        // Select the best quality face based on multiple criteria
        let best_face_idx = select_best_face(face_data, face_indices)?;
        let face = &face_data[best_face_idx];

        info!(
            "Person {} → using face[{}] from {:?} (has {} total faces)",
            person_id,
            best_face_idx,
            face.photo_path.file_name().unwrap_or_default(),
            face_indices.len()
        );

        // Load the image WITH EXIF correction to match the face detection coordinates
        let corrected_img = load_and_fix_orientation(&face.photo_path)?;
        let (img_width, img_height) = corrected_img.dimensions();
        let bbox = &face.bbox;

        // Check if bbox coordinates are in pixel coordinates (>1.0) or normalized (0-1)
        let (x1, y1, x2, y2) = if bbox.x2 > 1.0 || bbox.y2 > 1.0 {
            // Already in pixel coordinates
            (
                bbox.x1 as u32,
                bbox.y1 as u32,
                bbox.x2 as u32,
                bbox.y2 as u32,
            )
        } else {
            // Normalized coordinates, convert to pixels
            let x1 = (bbox.x1 * img_width as f32) as u32;
            let y1 = (bbox.y1 * img_height as f32) as u32;
            let x2 = (bbox.x2 * img_width as f32) as u32;
            let y2 = (bbox.y2 * img_height as f32) as u32;
            (x1, y1, x2, y2)
        };

        // Ensure coordinates are within bounds
        let x1 = x1.min(img_width.saturating_sub(1));
        let y1 = y1.min(img_height.saturating_sub(1));
        let x2 = x2.min(img_width).max(x1 + 1);
        let y2 = y2.min(img_height).max(y1 + 1);

        // Crop the face region from the EXIF-corrected image
        let face_img = corrected_img.crop_imm(x1, y1, x2 - x1, y2 - y1);

        // Save as person photo
        let person_photo_path = output_dir.join(format!("{}.jpg", person_id));
        face_img.save(&person_photo_path)?;
        info!("Saved person photo: {:?}", person_photo_path);

        person_to_photo.insert(person_id.clone(), person_photo_path);
    }

    Ok(person_to_photo)
}

/// Select the best face from a list of face candidates based on multiple quality criteria
///
/// Scoring criteria (higher is better):
/// - Face size: Larger faces generally have more detail (40% weight)
/// - Detection confidence: Higher confidence means better detection (30% weight)  
/// - Image resolution: Higher resolution source images (20% weight)
/// - Face position: Faces closer to center are often better composed (10% weight)
pub fn select_best_face(
    face_data: &[FaceData],
    face_indices: &[usize],
) -> Result<usize, anyhow::Error> {
    if face_indices.is_empty() {
        return Err(anyhow::anyhow!("No faces to select from"));
    }

    if face_indices.len() == 1 {
        return Ok(face_indices[0]);
    }

    let mut best_idx = face_indices[0];
    let mut best_score = 0.0f32;

    for &idx in face_indices {
        let face = &face_data[idx];
        let score = calculate_face_quality_score(face)?;

        if score > best_score {
            best_score = score;
            best_idx = idx;
        }
    }

    info!(
        "Selected best face[{}] with quality score: {:.3} from {} candidates",
        best_idx,
        best_score,
        face_indices.len()
    );

    Ok(best_idx)
}

/// Calculate a quality score for a face based on multiple criteria
pub fn calculate_face_quality_score(face: &FaceData) -> Result<f32, anyhow::Error> {
    let bbox = &face.bbox;

    // 1. Face size score (40% weight) - larger faces have more detail
    let face_width = bbox.x2 - bbox.x1;
    let face_height = bbox.y2 - bbox.y1;
    let face_area = face_width * face_height;

    // Load the image to get dimensions for proper scoring
    let img = load_and_fix_orientation(&face.photo_path)?;
    let (img_width, img_height) = img.dimensions();

    // Convert face area to pixels if in normalized coordinates
    let pixel_face_area = if bbox.x2 <= 1.0 && bbox.y2 <= 1.0 {
        // Normalized coordinates
        face_area * (img_width as f32) * (img_height as f32)
    } else {
        // Already in pixel coordinates
        face_area
    };

    // Size score: normalize based on image size, with minimum threshold
    let size_score = (pixel_face_area.sqrt() / (img_width.min(img_height) as f32)).min(1.0);

    // 2. Detection confidence score (30% weight)
    let confidence_score = face.confidence;

    // 3. Image resolution score (20% weight) - higher resolution is better
    let total_pixels = (img_width * img_height) as f32;
    let resolution_score = (total_pixels / 4_000_000.0).min(1.0); // Normalize to ~2K resolution

    // 4. Face position score (10% weight) - faces closer to center are often better
    let face_center_x = (bbox.x1 + bbox.x2) / 2.0;
    let face_center_y = (bbox.y1 + bbox.y2) / 2.0;

    let (center_x, center_y) = if bbox.x2 <= 1.0 && bbox.y2 <= 1.0 {
        // Normalized coordinates - center is at (0.5, 0.5)
        (0.5, 0.5)
    } else {
        // Pixel coordinates - center is at image center
        (img_width as f32 / 2.0, img_height as f32 / 2.0)
    };

    let distance_from_center =
        ((face_center_x - center_x).powi(2) + (face_center_y - center_y).powi(2)).sqrt();
    let max_distance = if bbox.x2 <= 1.0 {
        0.707 // Diagonal distance in normalized coordinates (sqrt(0.5^2 + 0.5^2))
    } else {
        ((img_width as f32 / 2.0).powi(2) + (img_height as f32 / 2.0).powi(2)).sqrt()
    };
    let position_score = 1.0 - (distance_from_center / max_distance).min(1.0);

    // Weighted final score
    let final_score =
        size_score * 0.4 + confidence_score * 0.3 + resolution_score * 0.2 + position_score * 0.1;

    debug!(
        "Face quality score for {:?}: size={:.3}, conf={:.3}, res={:.3}, pos={:.3} → {:.3}",
        face.photo_path.file_name().unwrap_or_default(),
        size_score,
        confidence_score,
        resolution_score,
        position_score,
        final_score
    );

    Ok(final_score)
}

/// Load image with proper EXIF orientation handling
pub fn load_and_fix_orientation(path: &Path) -> Result<image::DynamicImage> {
    use std::fs::File;
    use std::io::BufReader;

    let mut img = image::open(path)?;

    // Try to read EXIF data
    let file = File::open(path)?;
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
                        path.file_name().unwrap_or_default(),
                        orientation
                    );
                }
            }
        }
    }

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
            log::warn!("Unknown EXIF orientation: {}, using original", orientation);
            img
        }
    };

    Ok(img)
}

/// Calculate cosine similarity between two embeddings
pub fn cosine_similarity(emb1: &[f32], emb2: &[f32]) -> f32 {
    let mut dot_product = 0.0;
    let mut norm1 = 0.0;
    let mut norm2 = 0.0;

    for i in 0..emb1.len() {
        dot_product += emb1[i] * emb2[i];
        norm1 += emb1[i] * emb1[i];
        norm2 += emb2[i] * emb2[i];
    }

    norm1 = norm1.sqrt();
    norm2 = norm2.sqrt();

    if norm1 == 0.0 || norm2 == 0.0 {
        return 0.0;
    }

    dot_product / (norm1 * norm2)
}

// Helper functions for region-based face detection

#[derive(Debug, Clone)]
struct PersonRegion {
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,
}

/// Create expanded regions around YOLO person detections
fn create_person_regions(
    yolo_detections: &[YoloDetection],
    img_dimensions: (u32, u32),
) -> Vec<PersonRegion> {
    let (img_width, img_height) = img_dimensions;
    let mut regions = Vec::new();
    // Min person confidence from env or default
    let min_person_conf: f32 = std::env::var("PERSON_MIN_CONF")
        .ok()
        .and_then(|s| s.parse::<f32>().ok())
        .unwrap_or(0.6);

    for detection in yolo_detections {
        if detection.class == "person" && detection.confidence >= min_person_conf {
            // Convert YOLO bbox (x, y, width, height) to coordinates
            let yolo_bbox = &detection.bbox;
            let center_x = yolo_bbox.x;
            let center_y = yolo_bbox.y;
            let width = yolo_bbox.width;
            let height = yolo_bbox.height;

            // Filter out excessively small person boxes to avoid noise
            if width < MIN_PERSON_SIZE || height < MIN_PERSON_SIZE {
                info!(
                    "  Skipping small person region: {:.0}x{:.0} (<{:.0}px)",
                    width, height, MIN_PERSON_SIZE
                );
                continue;
            }

            // Convert to corner coordinates
            let x1 = center_x - width / 2.0;
            let y1 = center_y - height / 2.0;
            let x2 = center_x + width / 2.0;
            let y2 = center_y + height / 2.0;

            // Expand region by 30% in each direction to catch nearby faces
            let expand_factor = 0.3;
            let expand_x = width * expand_factor;
            let expand_y = height * expand_factor;

            let expanded_x1 = (x1 - expand_x).max(0.0);
            let expanded_y1 = (y1 - expand_y).max(0.0);
            let expanded_x2 = (x2 + expand_x).min(img_width as f32);
            let expanded_y2 = (y2 + expand_y).min(img_height as f32);

            regions.push(PersonRegion {
                x1: expanded_x1,
                y1: expanded_y1,
                x2: expanded_x2,
                y2: expanded_y2,
            });

            info!(
                "  Created person region: ({:.0},{:.0}) to ({:.0},{:.0})",
                expanded_x1, expanded_y1, expanded_x2, expanded_y2
            );
        }
    }

    regions
}

/// Check if a face detection bbox overlaps with any person region
fn is_face_in_person_regions(face_bbox: &BoundingBox, person_regions: &[PersonRegion]) -> bool {
    for region in person_regions {
        if bboxes_overlap(face_bbox, region) {
            return true;
        }
    }
    false
}

/// Check if a face bbox lies within the upper (head) portion of any person region.
/// `top_ratio` defines how much of the region height (from the top) is considered head area (e.g., 0.6).
fn is_face_in_head_portion_of_person_regions(
    face_bbox: &BoundingBox,
    person_regions: &[PersonRegion],
    top_ratio: f32,
) -> bool {
    let top_ratio = top_ratio.clamp(0.1, 1.0);
    for region in person_regions {
        // Define head sub-region
        let head_y2 = region.y1 + (region.y2 - region.y1) * top_ratio;
        let head_region = PersonRegion {
            x1: region.x1,
            y1: region.y1,
            x2: region.x2,
            y2: head_y2,
        };
        if bboxes_overlap(face_bbox, &head_region) {
            return true;
        }
    }
    false
}

/// Check if two bounding boxes overlap
fn bboxes_overlap(face_bbox: &BoundingBox, person_region: &PersonRegion) -> bool {
    // Face bbox is in the format used by face detection (x1, y1, x2, y2)
    let face_x1 = face_bbox.x1;
    let face_y1 = face_bbox.y1;
    let face_x2 = face_bbox.x2;
    let face_y2 = face_bbox.y2;

    // Check for overlap
    !(face_x2 < person_region.x1
        || face_x1 > person_region.x2
        || face_y2 < person_region.y1
        || face_y1 > person_region.y2)
}

/// Additional validation to check if a detected face is likely a human face
/// This helps filter out birds, animals, or other false positives that passed initial detection
// Blur detection function was removed as it was too restrictive

fn is_likely_human_face(face_detection: &types::FaceDetection, img: &image::DynamicImage) -> bool {
    // Geometry checks disabled: rely on detector score and basic size heuristics only

    // Thresholds via env (with sensible defaults)
    let min_area_ratio: f32 = std::env::var("FACE_MIN_AREA_RATIO")
        .ok()
        .and_then(|s| s.parse::<f32>().ok())
        .unwrap_or(0.001); // 0.1% of image area
    let min_conf: f32 = std::env::var("FACE_MIN_CONF")
        .ok()
        .and_then(|s| s.parse::<f32>().ok())
        .unwrap_or(0.7);
    let min_face_px: f32 = std::env::var("FACE_MIN_SIZE")
        .ok()
        .and_then(|s| s.parse::<f32>().ok())
        .unwrap_or(60.0);
    let debug = std::env::var("FACE_DEBUG")
        .ok()
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false);

    let face_width = face_detection.bbox.x2 - face_detection.bbox.x1;
    let face_height = face_detection.bbox.y2 - face_detection.bbox.y1;
    let face_area = face_width * face_height;

    // Get image dimensions
    let (img_width, img_height) = img.dimensions();
    let img_area = (img_width * img_height) as f32;

    // Calculate face-to-image ratio
    let face_to_image_ratio = if img_area > 0.0 {
        face_area / img_area
    } else {
        0.0
    };

    // Log inputs when debugging
    if debug {
        info!("    [FACE_GATE] bbox=({:.0},{:.0})-({:.0},{:.0}) w={:.0} h={:.0} img={}x{} area_ratio={:.5} conf={:.3} thresholds[min_ratio={:.5}, min_conf={:.2}, min_px={:.0}]",
              face_detection.bbox.x1, face_detection.bbox.y1, face_detection.bbox.x2, face_detection.bbox.y2,
              face_width, face_height, img_width, img_height, face_to_image_ratio, face_detection.confidence,
              min_area_ratio, min_conf, min_face_px);
    }

    // Filter out faces that are too small relative to image
    if face_to_image_ratio < min_area_ratio {
        info!(
            "    [FACE_GATE] drop: area_ratio {:.5} < min {:.5}",
            face_to_image_ratio, min_area_ratio
        );
        return false;
    }

    // Filter out faces that are too large relative to image (extreme closeups might be misdetected)
    if face_to_image_ratio > 0.8 {
        // More than 80% of image area
        info!(
            "    [FACE_GATE] drop: area_ratio {:.3}% > 80%",
            face_to_image_ratio * 100.0
        );
        return false;
    }

    // Use detection confidence (RetinaFace provides confidence scores)
    let confidence = face_detection.confidence;
    if confidence < min_conf {
        info!(
            "    [FACE_GATE] drop: confidence {:.3} < min {:.3}",
            confidence, min_conf
        );
        return false;
    }

    // Additional minimum face size in pixels
    if face_width < min_face_px || face_height < min_face_px {
        info!(
            "    [FACE_GATE] drop: size {}x{} < min {:.0}px",
            face_width as u32, face_height as u32, min_face_px
        );
        return false;
    }

    true // Passed minimal validation checks
}

/// Validate landmark geometry for a human face using 5 points:
/// [left_eye, right_eye, nose, left_mouth, right_mouth]
fn landmark_geometry_is_plausible(
    landmarks: &types::FacialLandmarks,
    bbox: &types::BoundingBox,
) -> bool {
    // Basic sanity: need exactly 5 points
    if landmarks.points.len() < 5 {
        return false;
    }

    // Extract canonical points
    let (le_x, le_y) = landmarks.points[0];
    let (re_x, re_y) = landmarks.points[1];
    let (no_x, no_y) = landmarks.points[2];
    let (lm_x, lm_y) = landmarks.points[3];
    let (rm_x, rm_y) = landmarks.points[4];

    let bw = (bbox.x2 - bbox.x1).max(1e-3);
    let bh = (bbox.y2 - bbox.y1).max(1e-3);
    let cx = (bbox.x1 + bbox.x2) * 0.5;

    // All landmarks should lie within bbox with a small tolerance
    let tol_x = 0.1 * bw;
    let tol_y = 0.1 * bh;
    let inside = |x: f32, y: f32| {
        x >= bbox.x1 - tol_x && x <= bbox.x2 + tol_x && y >= bbox.y1 - tol_y && y <= bbox.y2 + tol_y
    };
    if !(inside(le_x, le_y)
        && inside(re_x, re_y)
        && inside(no_x, no_y)
        && inside(lm_x, lm_y)
        && inside(rm_x, rm_y))
    {
        debug!("    Landmark outside bbox tolerance");
        return false;
    }

    // Rotation-aware geometry checks: de-rotate points so the eye line is horizontal.
    let cx_eyes = 0.5 * (le_x + re_x);
    let cy_eyes = 0.5 * (le_y + re_y);
    let theta = (re_y - le_y).atan2(re_x - le_x); // signed tilt in radians
    let cos_t = theta.cos();
    let sin_t = theta.sin();
    let mut rot = |x: f32, y: f32| -> (f32, f32) {
        let dx = x - cx_eyes;
        let dy = y - cy_eyes;
        // rotate by -theta
        let xr = cos_t * dx + sin_t * dy + cx_eyes;
        let yr = -sin_t * dx + cos_t * dy + cy_eyes;
        (xr, yr)
    };
    let (le_xr, le_yr) = rot(le_x, le_y);
    let (re_xr, re_yr) = rot(re_x, re_y);
    let (no_xr, no_yr) = rot(no_x, no_y);
    let (lm_xr, lm_yr) = rot(lm_x, lm_y);
    let (rm_xr, rm_yr) = rot(rm_x, rm_y);

    // Eye order: if mislabeled, swap so left is actually on the left (do not reject)
    let (le_xr, le_yr, re_xr, re_yr) = if le_xr < re_xr {
        (le_xr, le_yr, re_xr, re_yr)
    } else {
        debug!("    Eye order swapped after derotation (treating right as left)");
        (re_xr, re_yr, le_xr, le_yr)
    };

    // Vertical ordering: eyes above nose; nose above mouth (de-rotated frame)
    let eyes_yr = 0.5 * (le_yr + re_yr);
    let mouth_yr = 0.5 * (lm_yr + rm_yr);
    if !(eyes_yr + 0.01 * bh < no_yr && no_yr + 0.01 * bh < mouth_yr) {
        debug!("    Vertical order invalid after derotation (eyes/nose/mouth)");
        return false;
    }

    // Eye line tilt: do NOT hard-reject. We'll apply a soft penalty later.
    // Keep for diagnostics only.
    let dx_e = (re_x - le_x).abs().max(1e-3);
    let dy_e = re_y - le_y;
    let tilt_rad = (dy_e / dx_e).atan();
    let tilt_deg = tilt_rad.abs().to_degrees();
    if tilt_deg > 22.0 {
        debug!("    Eye tilt high: {:.1} deg (not rejecting)", tilt_deg);
    }

    // Ratios relative to bbox
    let eye_dist = ((re_x - le_x).powi(2) + (re_y - le_y).powi(2)).sqrt();
    let mouth_dist = ((rm_x - lm_x).powi(2) + (rm_y - lm_y).powi(2)).sqrt();
    let eye_ratio = eye_dist / bw;
    let mouth_ratio = mouth_dist / bw;

    // Inter-ocular distance ratio within plausible human range
    if eye_ratio < 0.22 || eye_ratio > 0.60 {
        debug!("    Eye distance ratio out of range: {:.2}", eye_ratio);
        return false;
    }

    // Mouth width ratio within plausible range
    if mouth_ratio < 0.18 || mouth_ratio > 0.65 {
        debug!("    Mouth width ratio out of range: {:.2}", mouth_ratio);
        return false;
    }

    // Vertical proportionality: distances from eyes to nose and mouth
    // Use de-rotated vertical span as effective face height to be robust to rotation
    let min_y_r = le_yr.min(re_yr).min(no_yr).min(lm_yr).min(rm_yr);
    let max_y_r = le_yr.max(re_yr).max(no_yr).max(lm_yr).max(rm_yr);
    let h_eff = (max_y_r - min_y_r).abs().max(1e-3);

    let eyes_to_nose = (no_yr - eyes_yr) / h_eff;
    let eyes_to_mouth = (mouth_yr - eyes_yr) / h_eff;

    // Compute eye-line tilt for adaptive thresholds
    let tilt_deg = compute_eye_tilt_degrees(landmarks);

    // Base acceptable ranges
    let (mut nose_min, mut nose_max) = (0.08, 0.50);
    let (mut mouth_min, mut mouth_max) = (0.20, 0.78);
    // If very high tilt (e.g., ~90°), allow a slightly larger upper bound for eyes_to_mouth
    if tilt_deg > 60.0 {
        mouth_max = 0.88;
    }

    if eyes_to_nose < nose_min || eyes_to_nose > nose_max {
        debug!(
            "    Eyes-to-nose ratio out of range (soft): {:.2} (tilt {:.1}°)",
            eyes_to_nose, tilt_deg
        );
        // Soft issue; do not reject here. Confidence penalty applied downstream.
    }
    if eyes_to_mouth < mouth_min || eyes_to_mouth > mouth_max {
        debug!(
            "    Eyes-to-mouth ratio out of range (soft): {:.2} (tilt {:.1}°)",
            eyes_to_mouth, tilt_deg
        );
        // Do not hard-reject; treat via soft penalty later
    }

    // Nose should be reasonably centered horizontally
    let nose_center_offset = (no_xr - cx).abs() / bw;
    if nose_center_offset > 0.28 {
        debug!(
            "    Nose too far from face center: {:.2}",
            nose_center_offset
        );
        return false;
    }

    // Symmetry: nose-to-eye distances should be roughly similar
    let d_le = ((le_x - no_x).powi(2) + (le_y - no_y).powi(2)).sqrt();
    let d_re = ((re_x - no_x).powi(2) + (re_y - no_y).powi(2)).sqrt();
    let eye_sym = (d_le - d_re).abs() / (d_le.max(d_re).max(1e-3));
    if eye_sym > 0.35 {
        // allow asymmetry up to 35%
        debug!("    Eye symmetry too low: {:.2}", eye_sym);
        return false;
    }

    true
}

/// Compute absolute eye-line tilt in degrees based on left/right eye landmarks
fn compute_eye_tilt_degrees(landmarks: &types::FacialLandmarks) -> f32 {
    if landmarks.points.len() < 2 {
        return 0.0;
    }
    let (le_x, le_y) = landmarks.points[0];
    let (re_x, re_y) = landmarks.points[1];
    let dx = (re_x - le_x).abs().max(1e-3);
    let dy = re_y - le_y;
    (dy / dx).atan().abs().to_degrees()
}
