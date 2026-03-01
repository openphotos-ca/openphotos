use albumbud::photos::metadata::open_image_any;
use albumbud::yolo_detection::{Detection, YoloDetector, COCO_CLASSES};
use anyhow::Result;
use clap::Parser;
use image::{DynamicImage, GenericImageView};
use std::fs;
use std::path::{Path, PathBuf};
use tracing::{error, info, warn};
use tracing_subscriber::EnvFilter;

#[derive(Parser, Debug)]
#[command(name = "yolo-detector")]
#[command(about = "YOLO Object Detection CLI Tool")]
struct Args {
    /// Input directory containing images
    #[arg(short, long, default_value = "./test_photos")]
    input: PathBuf,

    /// Path to YOLO ONNX model
    #[arg(short, long, default_value = "./models/yolov8n.onnx")]
    model: PathBuf,

    /// Minimum confidence threshold for detections
    #[arg(short, long, default_value = "0.5")]
    confidence: f32,

    /// Output format (text, json, csv)
    #[arg(short, long, default_value = "text")]
    format: String,

    /// Verbose output
    #[arg(short, long)]
    verbose: bool,
}

fn main() -> Result<()> {
    let args = Args::parse();

    // Initialize logging
    let filter = if args.verbose {
        EnvFilter::from_default_env()
            .add_directive("yolo_detector=debug".parse()?)
            .add_directive("clip_service=debug".parse()?)
    } else {
        EnvFilter::from_default_env()
            .add_directive("yolo_detector=info".parse()?)
            .add_directive("clip_service=info".parse()?)
    };

    tracing_subscriber::fmt().with_env_filter(filter).init();

    info!("YOLO Object Detection CLI");
    info!("=========================");

    // Check if model exists
    let model_path = if args.model.exists() && args.model.metadata()?.len() > 1000 {
        info!("Using YOLO model: {}", args.model.display());
        Some(args.model.as_path())
    } else {
        warn!(
            "YOLO model not found or invalid at {}, using mock detector",
            args.model.display()
        );
        warn!("To use real YOLO detection, please download the model:");
        warn!("  1. Install Python package: pip install ultralytics");
        warn!("  2. Run: python3 -c \"from ultralytics import YOLO; YOLO('yolov8n.pt').export(format='onnx')\"");
        warn!("  3. Move yolov8n.onnx to ./models/");
        None
    };

    // Initialize detector
    let detector = YoloDetector::new(model_path)?;
    info!("Detector initialized");

    // Check input directory
    if !args.input.exists() {
        error!("Input directory does not exist: {}", args.input.display());
        return Ok(());
    }

    // Get all image files
    let image_extensions = ["jpg", "jpeg", "png", "gif", "bmp", "webp"];
    let mut image_files = Vec::new();

    for entry in fs::read_dir(&args.input)? {
        let entry = entry?;
        let path = entry.path();

        if let Some(ext) = path.extension() {
            if image_extensions.contains(&ext.to_string_lossy().to_lowercase().as_str()) {
                image_files.push(path);
            }
        }
    }

    if image_files.is_empty() {
        warn!("No image files found in {}", args.input.display());
        return Ok(());
    }

    info!("Found {} image(s) to process", image_files.len());
    println!();

    // Process each image
    let mut total_objects = 0;
    let mut processed_count = 0;
    let mut results = Vec::new();

    for image_path in &image_files {
        match process_image(&detector, image_path, args.confidence) {
            Ok(detections) => {
                processed_count += 1;
                total_objects += detections.len();

                // Store results
                results.push((image_path.clone(), detections.clone()));

                // Print results based on format
                match args.format.as_str() {
                    "json" => {
                        print_json_result(image_path, &detections);
                    }
                    "csv" => {
                        print_csv_result(image_path, &detections);
                    }
                    _ => {
                        print_text_result(image_path, &detections);
                    }
                }
            }
            Err(e) => {
                error!("Failed to process {}: {}", image_path.display(), e);
            }
        }
    }

    // Print summary
    println!();
    println!("Summary");
    println!("=======");
    println!("✓ Processed {} image(s)", processed_count);
    println!("✓ Found {} total object(s)", total_objects);

    // Print object statistics
    let mut class_counts = std::collections::HashMap::new();
    for (_, detections) in &results {
        for detection in detections {
            *class_counts.entry(detection.class.clone()).or_insert(0) += 1;
        }
    }

    if !class_counts.is_empty() {
        println!();
        println!("Object Statistics:");
        let mut sorted_classes: Vec<_> = class_counts.iter().collect();
        sorted_classes.sort_by(|a, b| b.1.cmp(a.1));

        for (class, count) in sorted_classes {
            println!("  - {}: {}", class, count);
        }
    }

    Ok(())
}

fn process_image(
    detector: &YoloDetector,
    image_path: &Path,
    confidence_threshold: f32,
) -> Result<Vec<Detection>> {
    // Load image (supports HEIC via libheif/ffmpeg fallback)
    let image = open_image_any(image_path)?;

    // Detect objects
    let mut detections = detector.detect(&image)?;

    // Filter by confidence
    detections.retain(|d| d.confidence >= confidence_threshold);

    // Sort by confidence
    detections.sort_by(|a, b| b.confidence.partial_cmp(&a.confidence).unwrap());

    Ok(detections)
}

fn print_text_result(image_path: &Path, detections: &[Detection]) {
    let filename = image_path.file_name().unwrap_or_default().to_string_lossy();

    println!("Processing: {}", filename);

    if detections.is_empty() {
        println!("  No objects detected");
    } else {
        for detection in detections {
            println!(
                "  ✓ {} ({:.1}%) at [{:.0}, {:.0}, {:.0}, {:.0}]",
                detection.class,
                detection.confidence * 100.0,
                detection.bbox.x,
                detection.bbox.y,
                detection.bbox.width,
                detection.bbox.height
            );
        }
        println!("  Total: {} object(s) detected", detections.len());
    }
    println!();
}

fn print_json_result(image_path: &Path, detections: &[Detection]) {
    let result = serde_json::json!({
        "file": image_path.display().to_string(),
        "objects": detections.iter().map(|d| {
            serde_json::json!({
                "class": d.class,
                "confidence": d.confidence,
                "bbox": {
                    "x": d.bbox.x,
                    "y": d.bbox.y,
                    "width": d.bbox.width,
                    "height": d.bbox.height
                }
            })
        }).collect::<Vec<_>>()
    });

    println!("{}", serde_json::to_string_pretty(&result).unwrap());
}

fn print_csv_result(image_path: &Path, detections: &[Detection]) {
    for detection in detections {
        println!(
            "{},{},{:.3},{:.0},{:.0},{:.0},{:.0}",
            image_path.display(),
            detection.class,
            detection.confidence,
            detection.bbox.x,
            detection.bbox.y,
            detection.bbox.width,
            detection.bbox.height
        );
    }
}
