use anyhow::Result;
use image::GenericImageView;
use log::{error, info, warn};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};

// Use the face-normalizer library components instead of local modules
use face_normalizer::{
    cosine_similarity, load_and_fix_orientation, BoundingBox, FaceClusterer, FaceData,
    FaceDetector, FaceNormalizer, FaceRecognizer, YoloDetection, YoloDetector, CLUSTERING_EPS,
    MIN_SAMPLES,
};

mod types;
mod utils;

const INPUT_DIRS: &[&str] = &["../test_photos"];
const OUTPUT_DIR: &str = "../face_output";

// Use the public functions from the library
use face_normalizer::select_best_face;

fn main() -> Result<()> {
    env_logger::init();

    info!("Starting face clustering system");

    // Initialize components using existing models
    let detector = FaceDetector::new("../models/face/det_10g.onnx")?;
    let normalizer = FaceNormalizer::new();
    let recognizer = FaceRecognizer::new("../models/face/w600k_r50.onnx")?;

    // Initialize YOLO for person detection pre-filtering
    let yolo_path = Path::new("../models/yolov8n.onnx");
    let yolo = YoloDetector::new(Some(yolo_path))?;
    info!("Initialized YOLO detector for person pre-filtering");

    // Create output directory
    std::fs::create_dir_all(OUTPUT_DIR)?;

    // Step 1: Process all images and collect face embeddings from multiple directories
    info!(
        "Step 1: Collecting face embeddings from all images in directories: {:?}",
        INPUT_DIRS
    );
    let directory_paths: Vec<&Path> = INPUT_DIRS.iter().map(|d| Path::new(d)).collect();
    let face_data = face_normalizer::collect_all_faces_from_directories(
        &directory_paths,
        &detector,
        &normalizer,
        &recognizer,
        &yolo,
    )?;
    info!("Collected {} faces from input directories", face_data.len());

    if face_data.is_empty() {
        warn!("No faces detected in any images");
        return Ok(());
    }

    // Step 2: Analyze similarities first, then cluster
    info!("Step 2: Clustering faces to identify unique persons");
    info!(
        "Using DBSCAN parameters: eps={}, min_samples={}",
        CLUSTERING_EPS, MIN_SAMPLES
    );

    // Calculate all pairwise similarities to understand the data
    let embeddings: Vec<Vec<f32>> = face_data.iter().map(|f| f.embedding.clone()).collect();
    info!(
        "Analyzing similarities between all {} faces...",
        embeddings.len()
    );

    let mut similarities = Vec::new();
    for i in 0..embeddings.len() {
        for j in (i + 1)..embeddings.len() {
            let sim = cosine_similarity(&embeddings[i], &embeddings[j]);
            similarities.push(sim);
        }
    }

    similarities.sort_by(|a, b| b.partial_cmp(a).unwrap());
    info!(
        "Top 10 similarities: {:?}",
        &similarities[0..10.min(similarities.len())]
    );
    info!(
        "Bottom 10 similarities: {:?}",
        &similarities[similarities.len().saturating_sub(10)..]
    );

    let clusterer = FaceClusterer::new(CLUSTERING_EPS, MIN_SAMPLES);

    // Use DBSCAN to automatically discover number of distinct persons
    info!("Using DBSCAN to automatically discover distinct persons");
    let cluster_labels = clusterer.cluster(&embeddings);

    // Debug: Print clustering results for each face
    for (idx, (face, label)) in face_data.iter().zip(cluster_labels.iter()).enumerate() {
        let photo_name = face.photo_path.file_name().unwrap().to_string_lossy();
        match label {
            Some(cluster_id) => {
                info!(
                    "Face {} from {} (face_idx={}) -> Cluster {}",
                    idx, photo_name, face.face_index, cluster_id
                );
            }
            None => {
                info!(
                    "Face {} from {} (face_idx={}) -> Noise",
                    idx, photo_name, face.face_index
                );
            }
        }
    }

    // Step 3: Assign person IDs to clusters
    info!("Step 3: Assigning person IDs to clusters");
    let cluster_to_person = clusterer.assign_person_ids(&cluster_labels);

    // Create a map from face to person ID (excluding noise)
    let mut face_to_person: Vec<Option<String>> = Vec::new();
    for label in cluster_labels.iter() {
        match label {
            Some(cluster_id) => {
                face_to_person.push(cluster_to_person.get(cluster_id).cloned());
            }
            None => {
                face_to_person.push(None); // Noise points get no person ID
            }
        }
    }

    // Step 4: Save representative person photos
    info!("Step 4: Saving representative person photos");
    let output_path = std::path::Path::new(OUTPUT_DIR);
    let _person_photos = face_normalizer::generate_person_photos(
        &face_data,
        &face_to_person,
        &cluster_to_person,
        output_path,
    )?;

    // Step 5: Group faces by photo and rename files
    info!("Step 5: Renaming photos based on detected persons");
    rename_photos_with_persons(&face_data, &face_to_person)?;

    // Print summary
    print_clustering_summary(&face_data, &face_to_person, &cluster_to_person);

    // Step 6: Demonstrate face search functionality
    info!("Step 6: Testing face search functionality");
    test_face_search(
        &face_data,
        &face_to_person,
        &detector,
        &normalizer,
        &recognizer,
    )?;

    info!("Face clustering completed successfully");
    Ok(())
}

fn process_image_for_faces_in_regions(
    detector: &FaceDetector,
    normalizer: &FaceNormalizer,
    recognizer: &FaceRecognizer,
    image_path: &Path,
    yolo_detections: &[YoloDetection],
) -> Result<Vec<FaceData>> {
    // Use EXIF-corrected image for consistent bbox coordinates with cropping
    let img = load_and_fix_orientation(image_path)?;

    // Create expanded regions around YOLO person detections
    let person_regions = create_person_regions(&yolo_detections, img.dimensions());

    // Run face detection on the full image but filter results to person regions only
    let all_face_detections = detector.detect(&img)?;
    info!(
        "  Face detector found {} potential faces, filtering to person regions",
        all_face_detections.len()
    );

    let mut faces = Vec::new();

    for (face_idx, face_detection) in all_face_detections.iter().enumerate() {
        // Check if this face detection overlaps with any person region
        if is_face_in_person_regions(&face_detection.bbox, &person_regions) {
            let normalized_face = normalizer.normalize_face(&img, face_detection)?;
            let embedding = recognizer.generate_embedding(&normalized_face)?;

            faces.push(FaceData {
                photo_path: image_path.to_path_buf(),
                face_index: face_idx,
                embedding,
                bbox: face_normalizer::BoundingBox::new(
                    face_detection.bbox.x1,
                    face_detection.bbox.y1,
                    face_detection.bbox.x2,
                    face_detection.bbox.y2,
                ),
                confidence: face_detection.confidence,
            });
        } else {
            info!("  Filtered out face detection outside person regions: ({:.0},{:.0}) to ({:.0},{:.0})", 
                  face_detection.bbox.x1, face_detection.bbox.y1, face_detection.bbox.x2, face_detection.bbox.y2);
        }
    }

    Ok(faces)
}

fn save_person_photos(
    face_data: &[FaceData],
    face_to_person: &[Option<String>],
    _cluster_to_person: &HashMap<usize, String>,
) -> Result<()> {
    use std::collections::HashMap;

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

    // For each person, select the best face and save it
    for (person_id, face_indices) in person_faces.iter() {
        if face_indices.is_empty() {
            continue;
        }

        // Select the best quality face based on multiple criteria
        let best_face_idx = select_best_face(face_data, face_indices)?;
        let face = &face_data[best_face_idx];

        // Load the image WITH EXIF correction to match the face detection coordinates
        let corrected_img = load_and_fix_orientation(&face.photo_path)?;
        let (img_width, img_height) = corrected_img.dimensions();
        let bbox = &face.bbox;

        // Debug for p1 and p2
        if person_id == "p1" || person_id == "p2" {
            info!(
                "DEBUG: Processing person {} from {:?}",
                person_id, face.photo_path
            );
            info!(
                "DEBUG: EXIF-corrected image dimensions: {}x{}",
                img_width, img_height
            );
            info!(
                "DEBUG: Face bbox: ({:.1}, {:.1}) to ({:.1}, {:.1})",
                bbox.x1, bbox.y1, bbox.x2, bbox.y2
            );
        }

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

        // The cropped face is correctly oriented since both detection and cropping use EXIF-corrected images

        // Save as person photo
        let person_photo_path = Path::new(OUTPUT_DIR).join(format!("{}.jpg", person_id));
        face_img.save(&person_photo_path)?;
        info!("Saved person photo: {:?}", person_photo_path);
    }

    Ok(())
}

fn rename_photos_with_persons(
    face_data: &[FaceData],
    face_to_person: &[Option<String>],
) -> Result<()> {
    // Group faces by photo
    let mut photo_faces: HashMap<PathBuf, Vec<(usize, Option<String>)>> = HashMap::new();

    for (idx, face) in face_data.iter().enumerate() {
        let person_id = face_to_person[idx].clone();
        photo_faces
            .entry(face.photo_path.clone())
            .or_insert_with(Vec::new)
            .push((face.face_index, person_id));
    }

    // Process each photo
    for (photo_path, faces) in photo_faces.iter() {
        // Collect unique person IDs in this photo (excluding None)
        let mut person_ids: Vec<String> = faces
            .iter()
            .filter_map(|(_, pid)| pid.clone())
            .collect::<HashSet<_>>()
            .into_iter()
            .collect();

        if person_ids.is_empty() {
            info!("No clustered persons in {:?}, skipping rename", photo_path);
            continue;
        }

        // Sort person IDs for consistent naming
        person_ids.sort();

        // Generate new filename
        let stem = photo_path.file_stem().unwrap().to_string_lossy();
        let extension = photo_path.extension().unwrap_or_default().to_string_lossy();
        let new_name = format!("{}_{}.{}", stem, person_ids.join("_"), extension);
        let new_path = Path::new(OUTPUT_DIR).join(new_name);

        // Copy file with new name
        fs::copy(photo_path, &new_path)?;
        info!("Created: {:?}", new_path);
    }

    Ok(())
}

fn print_clustering_summary(
    face_data: &[FaceData],
    face_to_person: &[Option<String>],
    cluster_to_person: &HashMap<usize, String>,
) {
    println!("\n=== Clustering Summary ===");
    println!("Total faces detected: {}", face_data.len());
    println!("Number of persons identified: {}", cluster_to_person.len());

    // Count faces per person
    let mut person_counts: HashMap<String, usize> = HashMap::new();
    for person_opt in face_to_person.iter() {
        if let Some(person) = person_opt {
            *person_counts.entry(person.clone()).or_insert(0) += 1;
        }
    }

    // Count unclustered faces
    let unclustered = face_to_person.iter().filter(|p| p.is_none()).count();

    println!("\nFaces per person:");
    let mut persons: Vec<_> = person_counts.iter().collect();
    persons.sort_by_key(|(p, _)| p.as_str());
    for (person, count) in persons {
        println!("  {}: {} faces", person, count);
    }

    if unclustered > 0 {
        println!("  Unclustered: {} faces", unclustered);
    }

    // Count photos per person
    let mut photo_persons: HashMap<PathBuf, HashSet<String>> = HashMap::new();
    for (idx, face) in face_data.iter().enumerate() {
        if let Some(person) = &face_to_person[idx] {
            photo_persons
                .entry(face.photo_path.clone())
                .or_insert_with(HashSet::new)
                .insert(person.clone());
        }
    }

    let mut person_photo_counts: HashMap<String, usize> = HashMap::new();
    for persons in photo_persons.values() {
        for person in persons {
            *person_photo_counts.entry(person.clone()).or_insert(0) += 1;
        }
    }

    println!("\nPhotos per person:");
    let mut persons: Vec<_> = person_photo_counts.iter().collect();
    persons.sort_by_key(|(p, _)| p.as_str());
    for (person, count) in persons {
        println!("  {}: {} photos", person, count);
    }
}

// Get EXIF orientation value for coordinate transformation
fn get_exif_orientation(path: &Path) -> u32 {
    use std::fs::File;
    use std::io::BufReader;

    let file = match File::open(path) {
        Ok(f) => f,
        Err(_) => return 1,
    };

    let mut buf_reader = BufReader::new(&file);
    let exifreader = exif::Reader::new();

    if let Ok(exif_data) = exifreader.read_from_container(&mut buf_reader) {
        if let Some(field) = exif_data.get_field(exif::Tag::Orientation, exif::In::PRIMARY) {
            if let exif::Value::Short(values) = &field.value {
                if !values.is_empty() {
                    return values[0] as u32;
                }
            }
        }
    }

    1 // Default orientation
}

// Transform bounding box coordinates from EXIF-corrected space to raw image space
fn transform_bbox_to_raw(
    bbox: &BoundingBox,
    orientation: u32,
    raw_width: u32,
    raw_height: u32,
) -> BoundingBox {
    let (x1, y1, x2, y2) = (bbox.x1, bbox.y1, bbox.x2, bbox.y2);

    match orientation {
        1 => bbox.clone(), // No transformation needed
        2 => BoundingBox {
            // Flip horizontal
            x1: raw_width as f32 - x2,
            y1,
            x2: raw_width as f32 - x1,
            y2,
        },
        3 => BoundingBox {
            // Rotate 180°
            x1: raw_width as f32 - x2,
            y1: raw_height as f32 - y2,
            x2: raw_width as f32 - x1,
            y2: raw_height as f32 - y1,
        },
        4 => BoundingBox {
            // Flip vertical
            x1,
            y1: raw_height as f32 - y2,
            x2,
            y2: raw_height as f32 - y1,
        },
        5 => BoundingBox {
            // Flip horizontal + rotate 90° CW -> reverse: rotate 270° + flip horizontal
            x1: y1,
            y1: raw_width as f32 - x2,
            x2: y2,
            y2: raw_width as f32 - x1,
        },
        6 => BoundingBox {
            // Rotate 90° CW -> reverse: rotate 90° CCW
            x1: raw_height as f32 - y2,
            y1: x1,
            x2: raw_height as f32 - y1,
            y2: x2,
        },
        7 => BoundingBox {
            // Flip horizontal + rotate 270° CW -> reverse: rotate 90° + flip horizontal
            x1: raw_height as f32 - y2,
            y1: x1,
            x2: raw_height as f32 - y1,
            y2: x2,
        },
        8 => BoundingBox {
            // Rotate 270° CW -> reverse: rotate 90° CW
            x1: raw_height as f32 - y2,
            y1: x1,
            x2: raw_height as f32 - y1,
            y2: x2,
        },
        _ => bbox.clone(), // Unknown orientation, use original
    }
}

fn test_face_search(
    all_faces: &[FaceData],
    face_to_person: &[Option<String>],
    detector: &FaceDetector,
    normalizer: &FaceNormalizer,
    recognizer: &FaceRecognizer,
) -> Result<()> {
    // Test with each generated person photo
    for person_id in 1..=9 {
        let person_photo = format!("p{}.jpg", person_id);
        let person_path = Path::new(OUTPUT_DIR).join(&person_photo);

        if !person_path.exists() {
            continue;
        }

        info!(
            "Searching for photos containing person from {}",
            person_photo
        );

        match face_normalizer::search_by_face(
            &person_path,
            all_faces,
            detector,
            normalizer,
            recognizer,
        ) {
            Ok(matching_photos) => {
                info!("  Found {} photos with this person:", matching_photos.len());
                for photo in &matching_photos {
                    let photo_name = photo.file_name().unwrap().to_string_lossy();
                    info!("    - {}", photo_name);
                }

                // Cross-reference with clustering results to verify accuracy
                let expected_person_id = format!("p{}", person_id);
                let expected_photos: HashSet<_> = all_faces
                    .iter()
                    .enumerate()
                    .filter_map(|(idx, face)| {
                        if face_to_person[idx].as_ref() == Some(&expected_person_id) {
                            Some(face.photo_path.clone())
                        } else {
                            None
                        }
                    })
                    .collect();

                let found_photos: HashSet<_> = matching_photos.into_iter().collect();

                if found_photos == expected_photos {
                    info!("  ✅ Search results match clustering results perfectly");
                } else {
                    info!("  ⚠️  Search results differ from clustering:");
                    info!("    Expected: {} photos", expected_photos.len());
                    info!("    Found: {} photos", found_photos.len());
                }
            }
            Err(e) => {
                error!("  Failed to search with {}: {}", person_photo, e);
            }
        }

        println!(); // Add blank line for readability
    }

    Ok(())
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

    for detection in yolo_detections {
        if detection.class == "person" {
            // Convert YOLO bbox (x, y, width, height) to coordinates
            let yolo_bbox = &detection.bbox;
            let center_x = yolo_bbox.x;
            let center_y = yolo_bbox.y;
            let width = yolo_bbox.width;
            let height = yolo_bbox.height;

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

// Note: EXIF orientation correction is handled by load_and_fix_orientation() function
