use crate::database::DbPool;
use anyhow::Result;
use duckdb::params;
use image::imageops::FilterType;
use image::GenericImageView;
use once_cell::sync::Lazy;
use rknn_runtime::{AiBackend, RknnRuntime};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use tokio::runtime::Handle;
use tracing::{error, info, warn};

use crate::photos::metadata::{ensure_heic_ml_proxy, open_image_any};

// Import the face-normalizer library
use face_normalizer::{
    collect_all_faces, collect_all_faces_from_directories, collect_all_faces_with_yolo,
    process_image_for_faces as fm_process_image_for_faces, search_by_face, FaceClusterer, FaceData,
    FaceDetector, FaceNormalizer, FaceRecognizer, YoloDetector, CLUSTERING_EPS, MIN_SAMPLES,
};

// Global cache for face processing results
static FACE_CACHE: Lazy<Arc<Mutex<FaceCache>>> =
    Lazy::new(|| Arc::new(Mutex::new(FaceCache::new())));

#[derive(Debug, Clone)]
struct FaceCache {
    all_faces: Vec<FaceData>,
    person_photos: HashMap<String, PathBuf>,
    person_mapping: HashMap<String, Vec<String>>, // person_id -> list of photo filenames
    last_processed: Option<std::time::SystemTime>,
}

impl FaceCache {
    fn new() -> Self {
        Self {
            all_faces: Vec::new(),
            person_photos: HashMap::new(),
            person_mapping: HashMap::new(),
            last_processed: None,
        }
    }
}

#[derive(Debug, Clone)]
pub struct ClusterResult {
    pub person_mapping: HashMap<String, Vec<String>>, // person_id -> list of photo filenames
}

pub struct FaceService {
    enabled: bool,
    detector: Option<FaceDetector>,
    normalizer: Option<FaceNormalizer>,
    recognizer: Option<FaceRecognizer>,
    clusterer: Option<FaceClusterer>,
    yolo: Option<YoloDetector>,
    output_dir: PathBuf,
    pg_client: Option<Arc<tokio_postgres::Client>>,
}

impl FaceService {
    pub fn new(
        face_models_dir: Option<&Path>,
        ai_backend: AiBackend,
        ai_device_id: i32,
        rknn_runtime: Option<Arc<RknnRuntime>>,
        rknn_models_dir: Option<&Path>,
        pg_client: Option<Arc<tokio_postgres::Client>>,
    ) -> Result<Self> {
        match face_models_dir {
            Some(models_dir) => {
                info!(
                    "[FACE] Initializing face processing with models from: {:?}",
                    models_dir
                );

                let detector_path = models_dir.join("det_10g.onnx");
                let recognizer_path = models_dir.join("w600k_r50.onnx");

                if !detector_path.exists() || !recognizer_path.exists() {
                    warn!(
                        "[FACE] Face processing models not found at {:?}",
                        models_dir
                    );
                    warn!("Expected: det_10g.onnx and w600k_r50.onnx");
                    return Ok(Self {
                        enabled: false,
                        detector: None,
                        normalizer: None,
                        recognizer: None,
                        clusterer: None,
                        yolo: None,
                        output_dir: PathBuf::new(),
                        pg_client,
                    });
                }

                // Initialize face processing components
                info!("[FACE] Loading detector model at {:?}", detector_path);
                let detector_rknn_path = rknn_models_dir.map(|root| root.join("face/det_10g.rknn"));
                let detector = FaceDetector::new_with_backend(
                    &detector_path.to_string_lossy(),
                    ai_backend,
                    ai_device_id,
                    rknn_runtime.clone(),
                    detector_rknn_path.as_deref(),
                )?;
                info!("[FACE] RetinaFace backend: {}", detector.backend_name());
                let normalizer = FaceNormalizer::new();
                info!("[FACE] Loading recognizer model at {:?}", recognizer_path);
                let recognizer = FaceRecognizer::new_with_backend(
                    &recognizer_path.to_string_lossy(),
                    ai_backend,
                    ai_device_id,
                    None,
                )?;
                info!("[FACE] ArcFace backend: {}", recognizer.backend_name());
                let clusterer = FaceClusterer::new(CLUSTERING_EPS, MIN_SAMPLES);

                // Initialize YOLO for person detection pre-filtering
                // YOLO model should be in the root models directory, not the face subdirectory
                let yolo_path = models_dir
                    .parent()
                    .unwrap_or(std::path::Path::new("models"))
                    .join("yolov8n.onnx");
                let yolo = if yolo_path.exists() {
                    info!("[FACE] Loading YOLO detector from: {:?}", yolo_path);
                    let yolo_rknn_path = rknn_models_dir.map(|root| root.join("yolov8n.rknn"));
                    Some(YoloDetector::new_with_backend(
                        Some(&yolo_path),
                        ai_backend,
                        ai_device_id,
                        rknn_runtime.clone(),
                        yolo_rknn_path.as_deref(),
                    )?)
                } else {
                    warn!("[FACE] YOLO model not found at {:?}, using face detection without pre-filtering", yolo_path);
                    None
                };
                if let Some(ref yolo) = yolo {
                    info!("[FACE] Face YOLO backend: {}", yolo.backend_name());
                }

                info!("[FACE] Face processing initialized successfully");
                Ok(Self {
                    enabled: true,
                    detector: Some(detector),
                    normalizer: Some(normalizer),
                    recognizer: Some(recognizer),
                    clusterer: Some(clusterer),
                    yolo,
                    // No on-disk output directory; thumbnails live in DB
                    output_dir: PathBuf::new(),
                    pg_client,
                })
            }
            None => {
                info!("[FACE] Face processing disabled - no models directory provided");
                Ok(Self {
                    enabled: false,
                    detector: None,
                    normalizer: None,
                    recognizer: None,
                    clusterer: None,
                    yolo: None,
                    output_dir: PathBuf::new(),
                    pg_client,
                })
            }
        }
    }

    pub fn is_enabled(&self) -> bool {
        self.enabled
    }

    pub fn process_and_store_faces(
        &self,
        _conn: &DbPool,
        asset_id: &str,
        image_path: &Path,
    ) -> Result<Vec<String>> {
        let settings = FaceQualitySettings::default();
        self.process_and_store_faces_with_settings(
            _conn, asset_id, image_path, None, &settings, None,
        )
    }

    pub fn process_and_store_faces_with_yolo_detections(
        &self,
        _conn: &DbPool,
        asset_id: &str,
        image_path: &Path,
        yolo_detections: Option<&[crate::yolo_detection::Detection]>,
    ) -> Result<Vec<String>> {
        let settings = FaceQualitySettings::default();
        self.process_and_store_faces_with_settings(
            _conn,
            asset_id,
            image_path,
            yolo_detections,
            &settings,
            None,
        )
    }

    pub fn process_and_store_faces_with_settings(
        &self,
        _conn: &DbPool,
        asset_id: &str,
        image_path: &Path,
        yolo_detections: Option<&[crate::yolo_detection::Detection]>,
        settings: &FaceQualitySettings,
        org_id_hint: Option<i32>,
    ) -> Result<Vec<String>> {
        // Pure Postgres path is handled by the async API `process_and_store_faces_pg` and should be called directly by async callers.
        // This sync helper is used in DuckDB mode only.
        if self.pg_client.is_some() {
            return Ok(Vec::new());
        }
        if !self.enabled {
            warn!(
                "Face processing not enabled, skipping face detection for asset {}",
                asset_id
            );
            return Ok(Vec::new());
        }

        let detector = self.detector.as_ref().unwrap();
        let normalizer = self.normalizer.as_ref().unwrap();
        let recognizer = self.recognizer.as_ref().unwrap();

        info!(
            "[FACE] Processing faces for asset {} at path {:?}",
            asset_id, image_path
        );
        let t0 = std::time::Instant::now();

        // RetinaFace-only face detection (YOLO removed from face path)
        // Use HEIC/HEIF/AVIF -> JPG proxy for ML if needed.
        let path_for_ml = if let Some(ext) = image_path.extension().and_then(|e| e.to_str()) {
            let ext_l = ext.to_lowercase();
            if ext_l == "heic" || ext_l == "heif" || ext_l == "avif" {
                ensure_heic_ml_proxy(image_path, 1024)?
            } else {
                image_path.to_path_buf()
            }
        } else {
            image_path.to_path_buf()
        };
        info!("[FACE] Calling face_normalizer::process_image_for_faces ...");
        let t1 = std::time::Instant::now();
        let faces =
            fm_process_image_for_faces(detector, normalizer, recognizer, &path_for_ml.as_path())?;
        let dt = t1.elapsed();
        info!(
            "[FACE] process_image_for_faces returned {} faces in {:.2?}",
            faces.len(),
            dt
        );

        info!(
            "[FACE] Detected {} faces in asset {}",
            faces.len(),
            asset_id
        );

        // Determine organization and owner user_id for this asset to scope queries.
        // IMPORTANT: keep DB lock held only for the quick lookup, then release before heavy work.
        let default_org = org_id_hint.unwrap_or(1);
        let (org_id, owner_user_id): (i32, String) = {
            let conn = _conn.lock();
            match conn.query_row(
                "SELECT organization_id, user_id FROM photos WHERE asset_id = ? LIMIT 1",
                params![asset_id],
                |row| Ok((row.get::<_, i32>(0)?, row.get::<_, String>(1)?)),
            ) {
                Ok(v) => v,
                Err(_) => (default_org, String::new()),
            }
        };

        // Load full image once to crop thumbnails
        let img = match open_image_any(image_path) {
            Ok(i) => i,
            Err(e) => {
                warn!(
                    "[FACE] Failed to open image for face thumbnails {:?}: {}",
                    image_path, e
                );
                // We can still store embeddings without thumbnails
                image::DynamicImage::new_rgb8(1, 1)
            }
        };
        let (img_w, img_h) = img.dimensions();

        // Prepare data for DB writes without holding the DB lock.
        // We collect all row data in memory, then write in a short critical section.
        struct PreparedFaceRow {
            face_id: String,
            person_id: String,
            embedding_str: String,
            x1: i32,
            y1: i32,
            bw: i32,
            bh: i32,
            confidence: f32,
            face_thumb: Option<Vec<u8>>,
        }
        let mut prepared: Vec<PreparedFaceRow> = Vec::with_capacity(faces.len());

        let mut stored_ids = Vec::new();
        for (idx, f) in faces.iter().enumerate() {
            let face_id = format!("{}#{}", asset_id, idx);

            // Prepare embedding array literal (ensure exactly 512 elements for DuckDB FLOAT[512])
            let mut emb_vec: Vec<f32> = f.embedding.clone();
            if emb_vec.len() < 512 {
                emb_vec.resize(512, 0.0);
            } else if emb_vec.len() > 512 {
                emb_vec.truncate(512);
            }
            let embedding_str = format!(
                "[{}]",
                emb_vec
                    .iter()
                    .map(|v| v.to_string())
                    .collect::<Vec<_>>()
                    .join(",")
            );

            // Compute integer bbox within bounds
            let mut x1 = f.bbox.x1.max(0.0).floor() as i32;
            let mut y1 = f.bbox.y1.max(0.0).floor() as i32;
            let mut x2 = f.bbox.x2.min(img_w as f32).ceil() as i32;
            let mut y2 = f.bbox.y2.min(img_h as f32).ceil() as i32;
            if x2 <= x1 {
                x2 = (x1 + 1).min(img_w as i32);
            }
            if y2 <= y1 {
                y2 = (y1 + 1).min(img_h as i32);
            }
            let bw = (x2 - x1).max(1) as u32;
            let bh = (y2 - y1).max(1) as u32;

            // Use aligned upright thumbnail from face_normalizer when available; fallback to bbox crop
            let mut face_thumb: Option<Vec<u8>> = None;
            let mut sharpness_val: f32 = 0.0;
            if let Some(ref aligned) = f.aligned_thumbnail {
                face_thumb = Some(aligned.clone());
                if let Ok(dimg) = image::load_from_memory(aligned) {
                    let gray = dimg.to_luma8();
                    sharpness_val = estimate_laplacian_variance(&gray) as f32;
                }
            } else if img_w > 1 && img_h > 1 {
                let crop = img.crop_imm(x1.max(0) as u32, y1.max(0) as u32, bw, bh);
                let thumb = crop.resize(160, 160, FilterType::Lanczos3);
                let rgb = thumb.to_rgb8();
                let mut buf = Vec::new();
                if image::codecs::jpeg::JpegEncoder::new_with_quality(&mut buf, 85)
                    .encode(&rgb, rgb.width(), rgb.height(), image::ColorType::Rgb8)
                    .is_ok()
                {
                    face_thumb = Some(buf);
                }
                let gray = image::DynamicImage::ImageRgb8(rgb).to_luma8();
                sharpness_val = estimate_laplacian_variance(&gray) as f32;
            }

            // Find nearest existing person (if any)
            let mut assigned_person: Option<String> = None;
            let mut sim_top: f32 = -1.0;
            let select_sql =
                "SELECT f.person_id, array_cosine_similarity(f.embedding, ?::FLOAT[512]) as sim \
                              FROM faces_embed f \
                              WHERE f.person_id IS NOT NULL AND f.user_id = ? \
                              ORDER BY sim DESC LIMIT 5";
            {
                let conn = _conn.lock();
                if let Ok(mut stmt) = conn.prepare(select_sql) {
                    if let Ok(rows) =
                        stmt.query_map(params![embedding_str.clone(), &owner_user_id], |row| {
                            let pid: Option<String> = row.get(0).ok();
                            let sim: f32 = row.get(1).unwrap_or(0.0);
                            Ok((pid, sim))
                        })
                    {
                        for r in rows.flatten() {
                            if let (Some(pid), sim) = (r.0, r.1) {
                                if sim > sim_top {
                                    sim_top = sim;
                                    assigned_person = Some(pid);
                                }
                            }
                        }
                    }
                }
            }

            // Threshold for same-person assignment
            let threshold: f32 = face_normalizer::SIMILARITY_THRESHOLD; // 0.4 by default
            let person_id = if sim_top >= threshold {
                assigned_person.clone().unwrap()
            } else {
                // Create a new person_id like p{N}
                let mut new_id = String::from("p1");
                // Determine the next person id
                if let Ok(last_pid) = (|| {
                    let conn = _conn.lock();
                    conn.query_row(
                        "SELECT person_id FROM persons ORDER BY TRY_CAST(substr(person_id, 2) AS INTEGER) DESC LIMIT 1",
                        [],
                        |row| row.get::<_, String>(0),
                    )
                })() {
                    let num = last_pid.trim_start_matches('p').parse::<i64>().unwrap_or(0) + 1;
                    new_id = format!("p{}", num);
                }
                // Insert person row if not exists
                let _ = {
                    let conn = _conn.lock();
                    conn.execute(
                    "INSERT INTO persons (person_id, display_name, face_count, representative_face_id)\n                     VALUES (?, NULL, 0, NULL)\n                     ON CONFLICT (person_id) DO NOTHING",
                    params![new_id],
                )
                };
                new_id
            };
            // Ensure assigned_person mirrors the effective person_id
            assigned_person = Some(person_id.clone());

            // Store values for a later batched DB write
            prepared.push(PreparedFaceRow {
                face_id: face_id.clone(),
                person_id: person_id.clone(),
                embedding_str: embedding_str.clone(),
                x1,
                y1,
                bw: bw as i32,
                bh: bh as i32,
                confidence: f.confidence,
                face_thumb,
            });

            // Compute quality and mark hidden if needed
            let conf = f.confidence as f32;
            let short_side = bw.min(bh) as f32;
            let aspect = (bw as f32) / (bh as f32);
            let r_score = aspect_plausibility_score(
                aspect,
                settings.aspect_min,
                settings.aspect_max,
                settings.aspect_tol,
            );
            let s_score = ((short_side - settings.min_size as f32)
                / ((settings.target_size as f32) - settings.min_size as f32))
                .max(0.0)
                .min(1.0);
            let h_score = (sharpness_val / settings.sharpness_target)
                .max(0.0)
                .min(1.0);
            // Orientation proxy via aspect closeness to 1.0
            let f_score = (1.0 - ((aspect - 1.0).abs() / 0.8)).max(0.0).min(1.0);
            let c_score = conf.max(0.0).min(1.0);
            let q = (settings.w_c * c_score
                + settings.w_s * s_score
                + settings.w_h * h_score
                + settings.w_f * f_score
                + settings.w_r * r_score)
                / (settings.w_c + settings.w_s + settings.w_h + settings.w_f + settings.w_r);
            let fails_hard = (conf < settings.min_confidence)
                || (short_side < settings.min_size as f32)
                || (h_score < settings.min_sharpness)
                || (r_score <= 0.0);
            let is_hidden = fails_hard || (q < settings.min_quality);
            if self.pg_client.is_none() {
                let _ = {
                    let conn = _conn.lock();
                    conn.execute(
                    "UPDATE faces_embed SET quality_score = ?, yaw_deg = COALESCE(yaw_deg, NULL), sharpness = ?, is_hidden = ? WHERE face_id = ?",
                    params![q, sharpness_val, is_hidden, face_id],
                )
                };
            }

            // Update person's face_count and representative if empty
            if self.pg_client.is_none() {
                let _ = {
                    let conn = _conn.lock();
                    conn.execute(
                    "UPDATE persons SET face_count = ( \
                        SELECT COUNT(*) FROM faces_embed f \
                        WHERE f.user_id = ? AND f.person_id = ? AND COALESCE(f.is_hidden, FALSE) = FALSE \
                    ) WHERE person_id = ?",
                    params![&owner_user_id, person_id, person_id],
                )
                };
                let _ = {
                    let conn = _conn.lock();
                    conn.execute(
                    "UPDATE persons SET representative_face_id = COALESCE(representative_face_id, ?) WHERE person_id = ?",
                    params![face_id, person_id],
                )
                };
            }

            // Also mirror into Postgres faces when configured
            if let Some(pg) = &self.pg_client {
                let client = pg.clone();
                let emb_pg = format!(
                    "[{}]",
                    emb_vec
                        .iter()
                        .map(|v| v.to_string())
                        .collect::<Vec<_>>()
                        .join(",")
                );
                // Prepare params (thumbnail already moved into `prepared`)
                let thumb_owned: Option<Vec<u8>> =
                    prepared.last().and_then(|r| r.face_thumb.clone());
                let pid_owned: Option<String> = Some(person_id.clone());
                let created_ms: i64 = chrono::Utc::now().timestamp_millis();
                // Insert/upsert into PG
                let sql = format!(
                    "INSERT INTO faces (face_id, organization_id, asset_id, person_id, bbox_x, bbox_y, bbox_width, bbox_height, confidence, embedding, face_thumbnail, time_ms, created_at, updated_at, is_hidden)\n                     VALUES ($1::text, $2::integer, $3::text, $4::text, $5::integer, $6::integer, $7::integer, $8::integer, $9::real, ($10::text)::vector(512), $11::bytea, $12::bigint, NOW(), NOW(), $13::boolean)\n                     ON CONFLICT (face_id) DO UPDATE SET organization_id = EXCLUDED.organization_id, person_id = EXCLUDED.person_id, bbox_x = EXCLUDED.bbox_x, bbox_y = EXCLUDED.bbox_y, bbox_width = EXCLUDED.bbox_width, bbox_height = EXCLUDED.bbox_height, confidence = EXCLUDED.confidence, embedding = EXCLUDED.embedding, face_thumbnail = COALESCE(EXCLUDED.face_thumbnail, faces.face_thumbnail), time_ms = EXCLUDED.time_ms, updated_at = NOW(), is_hidden = EXCLUDED.is_hidden"
                );
                let is_hidden_val: bool = is_hidden;
                // Clone/move owned copies for the async task
                let sql_owned = sql.clone();
                let face_id_owned = face_id.clone();
                let asset_id_owned = asset_id.to_string();
                let x1_c = x1;
                let y1_c = y1;
                let bw_c = bw as i32;
                let bh_c = bh as i32;
                let confidence_c = f.confidence;
                let emb_pg_owned = emb_pg.clone();
                let thumb_c = thumb_owned.clone();
                let pid_c = pid_owned.clone();
                let assigned_person_c = assigned_person.clone();
                // Perform PG writes asynchronously without blocking the current thread.
                // Fire-and-forget is acceptable; DuckDB remains the source of truth for OSS.
                tokio::spawn(async move {
                    let _ = client
                        .execute(
                            &sql_owned,
                            &[
                                &face_id_owned,
                                &org_id,
                                &asset_id_owned,
                                &pid_c,
                                &x1_c,
                                &y1_c,
                                &bw_c,
                                &bh_c,
                                &confidence_c,
                                &emb_pg_owned,
                                &thumb_c,
                                &0_i64, // time_ms
                                &is_hidden_val,
                            ],
                        )
                        .await;
                    if let Some(pid) = assigned_person_c {
                        let _ = client
                            .execute(
                                "INSERT INTO persons (organization_id, person_id, display_name) VALUES ($1, $2, NULL) ON CONFLICT (organization_id, person_id) DO NOTHING",
                                &[&org_id, &pid],
                            )
                            .await;
                        let _ = client
                            .execute(
                                "UPDATE persons SET face_count = (SELECT COUNT(*) FROM faces WHERE organization_id = $1 AND person_id = $2 AND COALESCE(is_hidden,false)=false), updated_at = NOW() WHERE organization_id = $1 AND person_id = $2",
                                &[&org_id, &pid],
                            )
                            .await;
                        let _ = client
                            .execute(
                                "UPDATE persons SET representative_face_id = COALESCE(representative_face_id, $1) WHERE organization_id = $2 AND person_id = $3",
                                &[&face_id_owned, &org_id, &pid],
                            )
                            .await;
                    }
                });
            }

            stored_ids.push(face_id);
        }

        // Now perform DB writes inside a short critical section.
        if self.pg_client.is_none() && !prepared.is_empty() {
            let conn = _conn.lock();
            // Optional: wrap in a transaction to reduce write contention
            // ignore errors in transaction begin; fall back to autocommit
            let _ = conn.execute_batch("BEGIN TRANSACTION;");
            let insert_face_sql = "INSERT INTO faces_embed (face_id, asset_id, user_id, person_id, bbox_x, bbox_y, bbox_width, bbox_height, confidence, embedding, face_thumbnail)
                 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?::FLOAT[512], ?)\n                 ON CONFLICT (face_id) DO UPDATE SET\n                   user_id = EXCLUDED.user_id,\n                   person_id = EXCLUDED.person_id,\n                   bbox_x = EXCLUDED.bbox_x,\n                   bbox_y = EXCLUDED.bbox_y,\n                   bbox_width = EXCLUDED.bbox_width,\n                   bbox_height = EXCLUDED.bbox_height,\n                   confidence = EXCLUDED.confidence,\n                   embedding = EXCLUDED.embedding,\n                   face_thumbnail = COALESCE(EXCLUDED.face_thumbnail, faces_embed.face_thumbnail)";
            for (idx, _f) in faces.iter().enumerate() {
                let row = &prepared[idx];
                if let Err(e) = conn.execute(
                    insert_face_sql,
                    params![
                        row.face_id,
                        asset_id,
                        &owner_user_id,
                        row.person_id,
                        row.x1,
                        row.y1,
                        row.bw,
                        row.bh,
                        row.confidence,
                        row.embedding_str,
                        row.face_thumb
                    ],
                ) {
                    warn!(
                        "[FACE] insert failed for asset={} face_id={} : {}",
                        asset_id, row.face_id, e
                    );
                }
            }
            let _ = conn.execute_batch("COMMIT;");
        }
        let total_dt = t0.elapsed();
        info!(
            "[FACE] Completed face processing for asset {} in {:.2?} ({} results)",
            asset_id,
            total_dt,
            stored_ids.len()
        );
        // Force a checkpoint so face/person changes are persisted to disk immediately.
        // This avoids losing faces on abrupt shutdowns or quick restarts before WAL checkpoint.
        if self.pg_client.is_none() {
            let conn = _conn.lock();
            let _ = conn.execute("CHECKPOINT;", []);
        }
        info!(
            "[FACE] Embedding DB checkpointed after processing asset {}",
            asset_id
        );
        Ok(stored_ids)
    }

    /// Postgres-only face processing and storage path (no DuckDB usage)
    pub async fn process_and_store_faces_pg(
        &self,
        asset_id: &str,
        image_path: &Path,
        _yolo_detections: Option<&[crate::yolo_detection::Detection]>,
        _settings: &FaceQualitySettings,
        org_id: i32,
    ) -> Result<Vec<String>> {
        use crate::photos::metadata::{ensure_heic_ml_proxy, open_image_any};
        use image::imageops::FilterType;
        use image::GenericImageView;
        if !self.enabled {
            return Ok(Vec::new());
        }
        let detector = self.detector.as_ref().unwrap();
        let normalizer = self.normalizer.as_ref().unwrap();
        let recognizer = self.recognizer.as_ref().unwrap();
        let client = self
            .pg_client
            .as_ref()
            .expect("pg_client required for Postgres face storage")
            .clone();

        info!(
            "[FACE] Processing faces for asset {} at path {:?}",
            asset_id, image_path
        );
        let t0 = std::time::Instant::now();
        let path_for_ml = if let Some(ext) = image_path.extension().and_then(|e| e.to_str()) {
            let ext_l = ext.to_lowercase();
            if ext_l == "heic" || ext_l == "heif" || ext_l == "avif" {
                ensure_heic_ml_proxy(image_path, 1024)?
            } else {
                image_path.to_path_buf()
            }
        } else {
            image_path.to_path_buf()
        };
        let faces =
            fm_process_image_for_faces(detector, normalizer, recognizer, &path_for_ml.as_path())?;
        info!(
            "[FACE] process_image_for_faces returned {} faces",
            faces.len()
        );

        // Load full image once to crop thumbnails
        let img = match open_image_any(image_path) {
            Ok(i) => i,
            Err(e) => {
                warn!(
                    "[FACE] Failed to open image for face thumbnails {:?}: {}",
                    image_path, e
                );
                image::DynamicImage::new_rgb8(1, 1)
            }
        };
        let (img_w, img_h) = img.dimensions();

        let mut stored_ids = Vec::new();
        for (idx, f) in faces.iter().enumerate() {
            let face_id = format!("{}#{}", asset_id, idx);
            let mut emb_vec: Vec<f32> = f.embedding.clone();
            if emb_vec.len() < 512 {
                emb_vec.resize(512, 0.0);
            } else if emb_vec.len() > 512 {
                emb_vec.truncate(512);
            }
            let emb_pg = format!(
                "[{}]",
                emb_vec
                    .iter()
                    .map(|v| v.to_string())
                    .collect::<Vec<_>>()
                    .join(",")
            );

            // Compute integer bbox within bounds
            let mut x1 = f.bbox.x1.max(0.0).floor() as i32;
            let mut y1 = f.bbox.y1.max(0.0).floor() as i32;
            let mut x2 = f.bbox.x2.min(img_w as f32).ceil() as i32;
            let mut y2 = f.bbox.y2.min(img_h as f32).ceil() as i32;
            if x2 <= x1 {
                x2 = (x1 + 1).min(img_w as i32);
            }
            if y2 <= y1 {
                y2 = (y1 + 1).min(img_h as i32);
            }
            let bw = (x2 - x1).max(1) as u32;
            let bh = (y2 - y1).max(1) as u32;

            // Thumbnail + sharpness
            let mut face_thumb: Option<Vec<u8>> = None;
            let mut sharpness_val: f32 = 0.0;
            if let Some(ref aligned) = f.aligned_thumbnail {
                face_thumb = Some(aligned.clone());
                if let Ok(dimg) = image::load_from_memory(aligned) {
                    let gray = dimg.to_luma8();
                    sharpness_val = estimate_laplacian_variance(&gray) as f32;
                }
            } else if img_w > 1 && img_h > 1 {
                let crop = img.crop_imm(x1.max(0) as u32, y1.max(0) as u32, bw, bh);
                let thumb = crop.resize(160, 160, FilterType::Lanczos3);
                let rgb = thumb.to_rgb8();
                let mut buf = Vec::new();
                if image::codecs::jpeg::JpegEncoder::new_with_quality(&mut buf, 85)
                    .encode(&rgb, rgb.width(), rgb.height(), image::ColorType::Rgb8)
                    .is_ok()
                {
                    face_thumb = Some(buf);
                }
                let gray = image::DynamicImage::ImageRgb8(rgb).to_luma8();
                sharpness_val = estimate_laplacian_variance(&gray) as f32;
            }

            // Find nearest existing person in PG (cosine distance → similarity)
            let mut assigned_person: Option<String> = None;
            let mut sim_top: f32 = -1.0;
            let sel_sql = "SELECT person_id, (1.0::float4 - (embedding <=> ($1::text)::vector(512))::float4) AS sim \
                            FROM faces WHERE organization_id = $2 AND person_id IS NOT NULL \
                            ORDER BY (embedding <=> ($1::text)::vector(512))::float4 ASC LIMIT 5";
            if let Ok(rows) = client.query(sel_sql, &[&emb_pg, &org_id]).await {
                for row in rows {
                    let pid: Option<String> = row.get(0);
                    let sim: f32 = row.try_get::<_, f32>(1).unwrap_or(0.0);
                    if let Some(p) = pid {
                        if sim > sim_top {
                            sim_top = sim;
                            assigned_person = Some(p);
                        }
                    }
                }
            }
            // PG-only assignment threshold: allow override via env var; default stricter than OSS
            // to avoid over-merging different people when using pgvector similarity.
            let threshold: f32 = std::env::var("PERSON_ASSIGN_THRESHOLD")
                .ok()
                .and_then(|v| v.parse::<f32>().ok())
                .unwrap_or(0.8);
            tracing::info!(
                "[FACE] assignment decision org_id={} asset_id={} sim_top={:.3} threshold={:.3} matched_person={:?}",
                org_id,
                asset_id,
                sim_top,
                threshold,
                assigned_person
            );
            let person_id = if sim_top >= threshold {
                assigned_person.clone().unwrap()
            } else {
                // Create monotonic person id (pN) in PG scope (Postgres syntax)
                // substring(person_id from 2) drops the leading 'p'
                let last_sql = "SELECT person_id FROM persons WHERE organization_id=$1 ORDER BY CAST(SUBSTRING(person_id from 2) AS INTEGER) DESC LIMIT 1";
                let mut new_id = String::from("p1");
                if let Ok(row_opt) = client.query_opt(last_sql, &[&org_id]).await {
                    if let Some(row) = row_opt {
                        let last: String = row.get(0);
                        let num = last.trim_start_matches('p').parse::<i64>().unwrap_or(0) + 1;
                        new_id = format!("p{}", num);
                    }
                }
                let _ = client
                    .execute(
                        "INSERT INTO persons (organization_id, person_id, display_name) VALUES ($1, $2, NULL) \
                         ON CONFLICT (organization_id, person_id) DO NOTHING",
                        &[&org_id, &new_id],
                    )
                    .await;
                tracing::info!(
                    "[FACE] assignment created new person_id={} for asset_id={} (sim_top={:.3} < threshold={:.3})",
                    new_id,
                    asset_id,
                    sim_top,
                    threshold
                );
                new_id
            };

            // Insert/upsert face row into PG
            // Use explicit casts for every parameter to avoid driver type inference issues.
            let sql = "INSERT INTO faces (face_id, organization_id, asset_id, person_id, bbox_x, bbox_y, bbox_width, bbox_height, confidence, embedding, face_thumbnail, time_ms, created_at, updated_at, is_hidden, yaw_deg, sharpness) \
                       VALUES ($1::text,$2::integer,$3::text,$4::text,$5::integer,$6::integer,$7::integer,$8::integer,$9::real,($10::text)::vector(512),$11::bytea,$12::bigint,NOW(),NOW(),$13::boolean,$14::real,$15::real) \
                       ON CONFLICT (face_id) DO UPDATE SET organization_id=EXCLUDED.organization_id, person_id=EXCLUDED.person_id, bbox_x=EXCLUDED.bbox_x, bbox_y=EXCLUDED.bbox_y, bbox_width=EXCLUDED.bbox_width, bbox_height=EXCLUDED.bbox_height, confidence=EXCLUDED.confidence, embedding=EXCLUDED.embedding, face_thumbnail=COALESCE(EXCLUDED.face_thumbnail, faces.face_thumbnail), time_ms=EXCLUDED.time_ms, updated_at=NOW(), is_hidden=EXCLUDED.is_hidden, yaw_deg=EXCLUDED.yaw_deg, sharpness=EXCLUDED.sharpness";
            let created_ms: i64 = chrono::Utc::now().timestamp_millis();
            let is_hidden_val: bool = false;
            let yaw_zero: f32 = 0.0;
            match client
                .execute(
                    sql,
                    &[
                        &face_id,            // $1::text
                        &org_id,             // $2::integer
                        &asset_id,           // $3::text
                        &person_id,          // $4::text
                        &x1,                 // $5::integer
                        &y1,                 // $6::integer
                        &((x2 - x1) as i32), // $7::integer (width)
                        &((y2 - y1) as i32), // $8::integer (height)
                        &f.confidence,       // $9::real
                        &emb_pg,             // $10::text → vector cast
                        &face_thumb,         // $11::bytea
                        &created_ms,         // $12::bigint (time_ms)
                        &is_hidden_val,      // $13::boolean
                        &yaw_zero,           // $14::real
                        &sharpness_val,      // $15::real
                    ],
                )
                .await
            {
                Ok(n) => {
                    tracing::info!(
                        "[FACE] PG upsert face face_id={} org_id={} asset_id={} rows={}",
                        face_id,
                        org_id,
                        asset_id,
                        n
                    );
                }
                Err(e) => {
                    tracing::warn!(
                        "[FACE] PG upsert face failed face_id={} org_id={} asset_id={} err={}",
                        face_id,
                        org_id,
                        asset_id,
                        e
                    );
                }
            }
            match client.execute(
                "UPDATE persons SET face_count = (SELECT COUNT(*) FROM faces WHERE organization_id=$1 AND person_id=$2 AND COALESCE(is_hidden,false)=false), updated_at=NOW(), representative_face_id = COALESCE(representative_face_id, $3) WHERE organization_id=$1 AND person_id=$2",
                &[&org_id, &person_id, &face_id],
            ).await {
                Ok(_) => {}
                Err(e) => {
                    tracing::warn!("[FACE] PG update person failed person_id={} org_id={} err={}", person_id, org_id, e);
                }
            }
            stored_ids.push(face_id);
        }
        info!(
            "[FACE] Completed face processing for asset {} ({} results)",
            asset_id,
            stored_ids.len()
        );
        Ok(stored_ids)
    }

    // existing clustering APIs continue below

    /// Process all photos in a single directory to cluster faces and generate person photos
    /// (Wrapper for the multi-directory function for backward compatibility)
    pub async fn cluster_all_faces(&self, photos_dir: &Path) -> Result<HashMap<String, PathBuf>> {
        self.cluster_all_faces_from_directories(&[photos_dir]).await
    }

    /// Process all photos in multiple directories to cluster faces and generate person photos
    pub async fn cluster_all_faces_from_directories(
        &self,
        directories: &[&Path],
    ) -> Result<HashMap<String, PathBuf>> {
        if !self.enabled {
            warn!("Face processing not enabled, cannot cluster faces");
            return Ok(HashMap::new());
        }

        let detector = self.detector.as_ref().unwrap();
        let normalizer = self.normalizer.as_ref().unwrap();
        let recognizer = self.recognizer.as_ref().unwrap();
        let clusterer = self.clusterer.as_ref().unwrap();

        info!(
            "Starting face clustering for photos in directories: {:?}",
            directories
        );

        // Step 1: Collect all faces from photos in all directories (with YOLO pre-filtering if available)
        let all_faces = if let Some(yolo) = &self.yolo {
            info!("Using YOLO person pre-filtering for face detection");
            collect_all_faces_from_directories(directories, detector, normalizer, recognizer, yolo)?
        } else {
            warn!("YOLO not available, face clustering will likely detect many false positives");
            warn!("Consider enabling YOLO for better results");
            return Ok(HashMap::new()); // Require YOLO for clustering to avoid false positives
        };
        info!("Collected {} faces from all directories", all_faces.len());

        // Debug: Log face sources
        for (idx, face) in all_faces.iter().enumerate() {
            info!(
                "  Face[{}]: from photo {:?}",
                idx,
                face.photo_path.file_name().unwrap_or_default()
            );
        }

        if all_faces.is_empty() {
            return Ok(HashMap::new());
        }

        // Step 2: Cluster faces to identify persons
        let embeddings: Vec<Vec<f32>> = all_faces.iter().map(|f| f.embedding.clone()).collect();
        let cluster_labels = clusterer.cluster(&embeddings);
        let cluster_to_person = clusterer.assign_person_ids(&cluster_labels);

        info!("Identified {} distinct persons", cluster_to_person.len());

        // Step 3: Create face-to-person mapping
        let mut face_to_person: Vec<Option<String>> = Vec::new();
        for (idx, label) in cluster_labels.iter().enumerate() {
            match label {
                Some(cluster_id) => {
                    let person_id = cluster_to_person.get(cluster_id).cloned();
                    info!(
                        "  Face[{}] from {:?} → cluster {} → person {:?}",
                        idx,
                        all_faces[idx].photo_path.file_name().unwrap_or_default(),
                        cluster_id,
                        person_id
                    );
                    face_to_person.push(person_id);
                }
                None => {
                    info!(
                        "  Face[{}] from {:?} → noise (no person)",
                        idx,
                        all_faces[idx].photo_path.file_name().unwrap_or_default()
                    );
                    face_to_person.push(None); // Noise points get no person ID
                }
            }
        }

        // Step 4: Skip generating on-disk person photos; rely on DB thumbnails
        let person_photos: HashMap<String, PathBuf> = HashMap::new();

        // Build person to photos mapping
        let mut person_mapping = HashMap::new();

        // Group photos by person
        let mut face_to_person_map: HashMap<String, Vec<String>> = HashMap::new();
        for (face_idx, person_opt) in face_to_person.iter().enumerate() {
            if let Some(person_id) = person_opt {
                let photo_path = all_faces[face_idx]
                    .photo_path
                    .to_str()
                    .unwrap_or("")
                    .to_string();
                face_to_person_map
                    .entry(person_id.clone())
                    .or_insert_with(Vec::new)
                    .push(photo_path);
            }
        }

        for (person_id, photo_paths) in &face_to_person_map {
            let photo_filenames: Vec<String> = photo_paths
                .iter()
                .filter_map(|path| {
                    std::path::Path::new(path)
                        .file_name()
                        .and_then(|name| name.to_str())
                        .map(|s| s.to_string())
                })
                .collect();
            info!("Person {} → photos: {:?}", person_id, photo_filenames);
            person_mapping.insert(person_id.clone(), photo_filenames);
        }

        // Step 5: Update cache
        {
            let mut cache = FACE_CACHE.lock().unwrap();
            cache.all_faces = all_faces;
            cache.person_photos = person_photos.clone();
            cache.person_mapping = person_mapping;
            cache.last_processed = Some(std::time::SystemTime::now());
        }

        info!("Face clustering completed successfully (no on-disk person photos generated)");
        Ok(person_photos)
    }

    /// Get all detected persons with their photos
    pub fn get_all_persons(&self) -> Result<HashMap<String, PathBuf>> {
        let cache = FACE_CACHE.lock().unwrap();
        Ok(cache.person_photos.clone())
    }

    /// Get cached cluster results
    pub fn get_cached_clusters(&self) -> Option<ClusterResult> {
        let cache = FACE_CACHE.lock().unwrap();
        if cache.person_mapping.is_empty() {
            None
        } else {
            Some(ClusterResult {
                person_mapping: cache.person_mapping.clone(),
            })
        }
    }

    /// Find all photos containing a specific person
    pub fn get_photos_by_person(&self, person_id: &str) -> Result<Vec<PathBuf>> {
        if !self.enabled {
            return Ok(Vec::new());
        }

        let detector = self.detector.as_ref().unwrap();
        let normalizer = self.normalizer.as_ref().unwrap();
        let recognizer = self.recognizer.as_ref().unwrap();

        let cache = FACE_CACHE.lock().unwrap();

        // Get person photo path
        if let Some(person_photo_path) = cache.person_photos.get(person_id) {
            info!("Searching for photos containing person: {}", person_id);

            // Use the search_by_face function from face-normalizer library
            match search_by_face(
                person_photo_path,
                &cache.all_faces,
                detector,
                normalizer,
                recognizer,
            ) {
                Ok(matching_photos) => {
                    info!(
                        "Found {} photos containing person {}",
                        matching_photos.len(),
                        person_id
                    );
                    Ok(matching_photos)
                }
                Err(e) => {
                    error!("Failed to search for person {}: {}", person_id, e);
                    Ok(Vec::new())
                }
            }
        } else {
            warn!("Person {} not found in cache", person_id);
            Ok(Vec::new())
        }
    }
}

#[derive(Debug, Clone)]
pub struct FaceQualitySettings {
    pub min_quality: f32,
    pub min_confidence: f32,
    pub min_size: i32,
    pub target_size: i32,
    pub yaw_max: f32,
    pub yaw_hard_max: f32,
    pub min_sharpness: f32,
    pub sharpness_target: f32,
    pub aspect_min: f32,
    pub aspect_max: f32,
    pub aspect_tol: f32,
    pub w_c: f32,
    pub w_s: f32,
    pub w_h: f32,
    pub w_f: f32,
    pub w_r: f32,
}

impl Default for FaceQualitySettings {
    fn default() -> Self {
        Self {
            min_quality: 0.55,
            min_confidence: 0.75,
            min_size: 64,
            target_size: 128,
            yaw_max: 75.0,
            yaw_hard_max: 85.0,
            min_sharpness: 0.15,
            sharpness_target: 500.0,
            aspect_min: 0.6,
            aspect_max: 1.7,
            aspect_tol: 0.2,
            w_c: 0.30,
            w_s: 0.20,
            w_h: 0.20,
            w_f: 0.25,
            w_r: 0.05,
        }
    }
}

fn aspect_plausibility_score(aspect: f32, min: f32, max: f32, tol: f32) -> f32 {
    if aspect >= min && aspect <= max {
        return 1.0;
    }
    if aspect < min {
        return (1.0 - ((min - aspect) / tol)).max(0.0).min(1.0);
    }
    (1.0 - ((aspect - max) / tol)).max(0.0).min(1.0)
}

fn estimate_laplacian_variance(gray: &image::GrayImage) -> f64 {
    let w = gray.width() as i32;
    let h = gray.height() as i32;
    if w < 3 || h < 3 {
        return 0.0;
    }
    let mut sum = 0.0f64;
    let mut sum_sq = 0.0f64;
    let mut count = 0.0f64;
    for y in 1..(h - 1) {
        for x in 1..(w - 1) {
            let c = gray.get_pixel(x as u32, y as u32)[0] as f64;
            let n = gray.get_pixel(x as u32, (y - 1) as u32)[0] as f64;
            let s = gray.get_pixel(x as u32, (y + 1) as u32)[0] as f64;
            let e = gray.get_pixel((x + 1) as u32, y as u32)[0] as f64;
            let wv = gray.get_pixel((x - 1) as u32, y as u32)[0] as f64;
            let lap = 4.0 * c - (n + s + e + wv);
            sum += lap;
            sum_sq += lap * lap;
            count += 1.0;
        }
    }
    if count <= 1.0 {
        return 0.0;
    }
    let mean = sum / count;
    (sum_sq / count) - mean * mean
}

/// Process a single image to extract all faces and their embeddings
/// This is a helper function that reuses the face-normalizer implementation
fn process_image_for_faces(
    detector: &FaceDetector,
    normalizer: &FaceNormalizer,
    recognizer: &FaceRecognizer,
    image_path: &Path,
) -> Result<Vec<FaceData>> {
    use face_normalizer::load_and_fix_orientation;

    // Use EXIF-corrected image for consistent bbox coordinates with cropping
    let img = load_and_fix_orientation(image_path)?;
    let detections = detector.detect(&img)?;

    let mut faces = Vec::new();

    for (face_idx, detection) in detections.iter().enumerate() {
        let normalized_face = normalizer.normalize_face(&img, detection)?;
        let embedding = recognizer.generate_embedding(&normalized_face)?;

        faces.push(FaceData {
            photo_path: image_path.to_path_buf(),
            face_index: face_idx,
            embedding,
            bbox: detection.bbox.clone(),
            confidence: detection.confidence,
            aligned_thumbnail: None,
        });
    }

    Ok(faces)
}

pub struct FaceSearchResult {
    pub person_id: String,
    pub display_name: Option<String>,
    pub face_count: i32,
    pub thumbnail: Vec<u8>,
}

pub fn get_all_persons(_conn: &DbPool) -> Result<Vec<FaceSearchResult>> {
    // Get person photos from the cache
    let cache = FACE_CACHE.lock().unwrap();

    if cache.person_photos.is_empty() {
        info!("No person photos found in cache. Run face clustering first.");
        return Ok(Vec::new());
    }

    let mut results = Vec::new();

    for (person_id, photo_path) in &cache.person_photos {
        // Load the person photo as thumbnail
        let thumbnail_bytes = match std::fs::read(photo_path) {
            Ok(bytes) => bytes,
            Err(e) => {
                warn!("Failed to read person photo {:?}: {}", photo_path, e);
                continue;
            }
        };

        // Count photos for this person
        let photo_count = cache
            .all_faces
            .iter()
            .enumerate()
            .filter(|(idx, _)| {
                // Check if this face belongs to this person (simplified)
                person_id.contains(&format!("p{}", idx + 1))
            })
            .count();

        results.push(FaceSearchResult {
            person_id: person_id.clone(),
            display_name: Some(format!("Person {}", person_id.trim_start_matches('p'))),
            face_count: photo_count as i32,
            thumbnail: thumbnail_bytes,
        });
    }

    info!("Returning {} person results from cache", results.len());
    Ok(results)
}

pub fn get_photos_by_person(_conn: &DbPool, person_id: &str) -> Result<Vec<String>> {
    // Use the cache to get photos for a person
    let cache = FACE_CACHE.lock().unwrap();

    if cache.person_photos.is_empty() {
        info!("No person photos found in cache. Run face clustering first.");
        return Ok(Vec::new());
    }

    // Get the person photo path
    if let Some(person_photo_path) = cache.person_photos.get(person_id) {
        // For the face search, we need the detector/normalizer/recognizer
        // Since we don't have access to FaceService here, we'll simulate the search
        // In a real implementation, this would call face_service.get_photos_by_person()

        // Use the cached person_mapping to get photos for this specific person
        let matching_photos: Vec<String> =
            if let Some(photo_filenames) = cache.person_mapping.get(person_id) {
                photo_filenames
                    .iter()
                    .filter_map(|filename| {
                        // Extract asset ID from filename (remove extension)
                        std::path::Path::new(filename)
                            .file_stem()
                            .and_then(|s| s.to_str())
                            .map(|s| s.to_string())
                    })
                    .collect()
            } else {
                Vec::new()
            };

        info!(
            "Found {} photos for person {}",
            matching_photos.len(),
            person_id
        );
        Ok(matching_photos)
    } else {
        warn!("Person {} not found", person_id);
        Ok(Vec::new())
    }
}

fn parse_embedding_array(array_str: &str) -> Result<Vec<f32>> {
    // Parse DuckDB array format: [1.0,2.0,3.0]
    let trimmed = array_str.trim_start_matches('[').trim_end_matches(']');
    let parts: Result<Vec<f32>, _> = trimmed
        .split(',')
        .map(|s| s.trim().parse::<f32>())
        .collect();

    parts.map_err(|e| anyhow::anyhow!("Failed to parse embedding array: {}", e))
}

fn cosine_similarity(a: &[f32], b: &[f32]) -> f32 {
    let dot_product: f32 = a.iter().zip(b.iter()).map(|(x, y)| x * y).sum();
    let norm_a: f32 = a.iter().map(|x| x * x).sum::<f32>().sqrt();
    let norm_b: f32 = b.iter().map(|x| x * x).sum::<f32>().sqrt();

    if norm_a * norm_b == 0.0 {
        0.0
    } else {
        dot_product / (norm_a * norm_b)
    }
}
