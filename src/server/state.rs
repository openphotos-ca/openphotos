use crate::ai_config::AiRuntimeConfig;
use crate::auth::oauth::{OAuthConfig, OAuthService};
use crate::auth::AuthService;
use crate::clip::{textual::TextualEncoder, visual::VisualEncoder, ClipConfig};
use crate::database::embeddings::EmbeddingStore;
use crate::database::meta_store::MetaStore;
use crate::database::multi_tenant::MultiTenantDatabase;
use crate::database::pg_meta_store::PgMetaStore;
use crate::face_processing::FaceService;
use crate::server::updates::UpdateService;
use crate::yolo_detection::YoloDetector;
use anyhow::Result;
use chrono::Utc;
use parking_lot::RwLock;
use rknn_runtime::{AiBackend, RknnRuntime};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Arc as StdArc;
use std::sync::Arc;
use tokio::sync::{broadcast, Semaphore};

pub struct AppState {
    pub visual_encoders: Arc<RwLock<HashMap<String, VisualEncoder>>>,
    pub textual_encoders: Arc<RwLock<HashMap<String, TextualEncoder>>>,
    pub yolo_detector: Arc<YoloDetector>,
    pub face_service: Arc<FaceService>,
    pub default_model: String,
    pub ai_backend: AiBackend,
    pub ai_device_id: i32,
    pub model_path: PathBuf,
    pub rknn_model_path: PathBuf,
    pub rknn_runtime: Option<Arc<RknnRuntime>>,
    pub model_configs: HashMap<String, ClipConfig>,
    pub auth_service: Arc<AuthService>,
    pub oauth_service: Option<Arc<OAuthService>>,
    // DuckDB multi-tenant store (DuckDB mode only). None in Postgres mode.
    pub multi_tenant_db: Option<Arc<MultiTenantDatabase>>,
    pub meta: Option<Arc<dyn MetaStore + Send + Sync>>, // Postgres metadata store when enabled
    // Reindex job streams: job_id -> broadcast sender (JSON strings)
    pub reindex_jobs: Arc<parking_lot::RwLock<HashMap<String, broadcast::Sender<String>>>>,
    // Map job_id -> user_id for ownership checks
    pub reindex_job_owners: Arc<parking_lot::RwLock<HashMap<String, String>>>,
    // Map job_id -> cancellation flag
    pub reindex_cancel_flags:
        Arc<parking_lot::RwLock<HashMap<String, std::sync::Arc<std::sync::atomic::AtomicBool>>>>,
    // Map user_id -> active job_id (only one active at a time per user)
    pub active_job_for_user: Arc<parking_lot::RwLock<HashMap<String, String>>>,
    // pHash configuration and per-user similar indexes (banding)
    pub phash_t_max: u8,
    pub similar_indexes: Arc<
        parking_lot::RwLock<
            HashMap<String, Arc<parking_lot::RwLock<crate::photos::similar::BandingIndex>>>,
        >,
    >,
    // Video similarity configuration
    pub video_similarity_mode: VideoSimilarityMode,
    pub video_phash_percents: Option<Vec<f64>>, // override schedule
    pub video_phash_lowinfo_skip: bool,
    pub video_phash_hamming_max: u8,
    // Upload ingestion options
    pub move_on_ingest: bool,
    pub library_root: std::path::PathBuf,
    pub data_dir: std::path::PathBuf,
    pub library_layout: LibraryLayout,
    // Upload events SSE per user_id
    pub upload_channels: Arc<parking_lot::RwLock<HashMap<String, broadcast::Sender<String>>>>,
    // TUS upload owner mapping for webhook ingestion when hook auth context is missing.
    pub tus_upload_owners: Arc<parking_lot::RwLock<HashMap<String, String>>>,
    // Global ingestion concurrency guard
    pub ingest_semaphore: Arc<Semaphore>,
    // DuckDB concurrency guard to prevent lock starvation under heavy load
    pub duckdb_semaphore: Arc<Semaphore>,
    // Toggle object detection during photo indexing (YOLO). Heavy; default off.
    pub enable_object_detect_on_index: bool,
    // Sync sessions per user for statistics
    pub sync_sessions: Arc<RwLock<HashMap<String, SyncSession>>>,
    pub sync_idle_secs: u64,
    // Per-process backfill guard: which users have had Live Photo motion MOVs classified.
    pub live_photo_video_backfill_done: Arc<parking_lot::RwLock<HashSet<String>>>,
    // Optional Postgres client for embeddings backend
    pub pg_client: Option<StdArc<tokio_postgres::Client>>,
    pub update_service: Arc<UpdateService>,
}

impl AppState {
    /// Resolve organization_id for a given user_id (PG or DuckDB).
    /// Returns 1 when the user cannot be found.
    pub fn org_id_for_user(&self, user_id: &str) -> i32 {
        if let Some(pg) = &self.pg_client {
            // Avoid blocking the Tokio scheduler if called in async contexts
            let res = if tokio::runtime::Handle::try_current().is_ok() {
                tokio::task::block_in_place(|| {
                    futures::executor::block_on(pg.query_opt(
                        "SELECT organization_id FROM users WHERE user_id=$1 LIMIT 1",
                        &[&user_id],
                    ))
                })
                .ok()
            } else {
                futures::executor::block_on(pg.query_opt(
                    "SELECT organization_id FROM users WHERE user_id=$1 LIMIT 1",
                    &[&user_id],
                ))
                .ok()
            };
            return res
                .and_then(|row| row.map(|r| r.get::<_, i32>(0)))
                .unwrap_or(1);
        }
        let udb = self
            .multi_tenant_db
            .as_ref()
            .expect("users DB required in DuckDB mode")
            .users_connection();
        let c = udb.lock();
        c.query_row(
            "SELECT organization_id FROM users WHERE user_id = ? LIMIT 1",
            duckdb::params![user_id],
            |row| row.get::<_, i32>(0),
        )
        .unwrap_or(1)
    }
    pub async fn new(
        db_path: &str,
        model_configs: Vec<ClipConfig>,
        ai_config: AiRuntimeConfig,
    ) -> Result<Self> {
        // Initialize a single ONNX Runtime environment early and deterministically.
        // Ignore AlreadyInitialized errors to allow hot-reload/dev runs.
        let _ = ort::init().commit();
        // Database creation is handled per-user by MultiTenantDatabase
        // Use the configured data directory from CLI/env

        let model_path = model_configs
            .first()
            .map(|config| PathBuf::from(&config.model_path))
            .unwrap_or_else(|| PathBuf::from("models"));

        // Load models
        let mut visual_encoders = HashMap::new();
        let mut textual_encoders = HashMap::new();
        let rknn_runtime = if ai_config.backend.prefers_rknn() {
            match RknnRuntime::load(ai_config.runtime_lib_override.as_deref()) {
                Ok(runtime) => {
                    tracing::info!("Loaded RKNN runtime from {}", runtime.loaded_from.display());
                    Some(Arc::new(runtime))
                }
                Err(err) => {
                    tracing::warn!(
                        "RKNN runtime unavailable, using CPU fallbacks for all AI models: {:#}",
                        err
                    );
                    None
                }
            }
        } else {
            None
        };

        let default_model = model_configs
            .first()
            .map(|c| c.model_name.clone())
            .unwrap_or_else(|| "ViT-B-32__openai".to_string());

        // Store model configurations for language selection
        let mut config_map = HashMap::new();
        for config in &model_configs {
            config_map.insert(config.model_name.clone(), config.clone());
        }

        for config in model_configs {
            let model_name = config.model_name.clone();
            let visual_rknn_path = ai_config.rknn_model_file(format!("{}/visual.rknn", model_name));
            let textual_rknn_path =
                ai_config.rknn_model_file(format!("{}/textual.rknn", model_name));

            // Try to load visual encoder
            match VisualEncoder::new_with_backend(
                config.clone(),
                ai_config.backend,
                ai_config.device_id,
                rknn_runtime.clone(),
                Some(&visual_rknn_path),
            ) {
                Ok(encoder) => {
                    visual_encoders.insert(model_name.clone(), encoder);
                    tracing::info!("Loaded visual encoder: {}", model_name);
                }
                Err(e) => {
                    tracing::warn!("Failed to load visual encoder {}: {}", model_name, e);
                }
            }

            // Try to load textual encoder
            match TextualEncoder::new_with_backend(
                config,
                ai_config.backend,
                ai_config.device_id,
                rknn_runtime.clone(),
                Some(&textual_rknn_path),
            ) {
                Ok(encoder) => {
                    textual_encoders.insert(model_name.clone(), encoder);
                    tracing::info!("Loaded textual encoder: {}", model_name);
                }
                Err(e) => {
                    tracing::warn!("Failed to load textual encoder {}: {}", model_name, e);
                }
            }
        }

        if visual_encoders.is_empty() && textual_encoders.is_empty() {
            return Err(anyhow::anyhow!("No models could be loaded"));
        }

        // Initialize YOLO detector
        let yolo_path = model_path.join("yolov8m-oiv7.onnx");
        let yolo_rknn_path = ai_config.rknn_model_file("yolov8m-oiv7.rknn");
        let yolo_detector = Arc::new(YoloDetector::new_with_backend(
            Some(&yolo_path),
            ai_config.backend,
            ai_config.device_id,
            rknn_runtime.clone(),
            Some(&yolo_rknn_path),
        )?);

        // Optional Postgres embeddings backend (connect early so face service can use it)
        let pg_client = if std::env::var("EMBEDDINGS_BACKEND")
            .unwrap_or_else(|_| "duckdb".to_string())
            .to_ascii_lowercase()
            == "postgres"
        {
            let cfg = crate::database::postgres::PgConfig::from_env();
            // Ensure core schema exists before establishing long-lived client (idempotent)
            if let Err(e) = crate::database::postgres::init_postgres_schema(&cfg).await {
                tracing::error!("[PG] schema init failed: {}", e);
            }
            match tokio_postgres::connect(&cfg.to_connect_str(), tokio_postgres::NoTls).await {
                Ok((client, connection)) => {
                    tokio::spawn(async move {
                        if let Err(e) = connection.await {
                            tracing::error!("Postgres connection error: {}", e);
                        }
                    });
                    Some(StdArc::new(client))
                }
                Err(e) => {
                    tracing::error!("[PG] connect failed; falling back to DuckDB: {}", e);
                    None
                }
            }
        } else {
            None
        };

        // Initialize face service (inject optional PG client)
        let face_models_dir = model_path.join("face");
        let face_service = Arc::new(FaceService::new(
            Some(face_models_dir.as_path()),
            ai_config.backend,
            ai_config.device_id,
            rknn_runtime.clone(),
            Some(ai_config.rknn_model_root.as_path()),
            pg_client.clone(),
        )?);

        // Initialize multi-tenant database only in DuckDB mode
        let data_dir = std::path::Path::new(db_path);
        let multi_tenant_db = if pg_client.is_none() {
            Some(Arc::new(MultiTenantDatabase::new(data_dir)?))
        } else {
            None
        };

        // Initialize EE public link schema once at startup (DuckDB mode only)
        #[cfg(feature = "ee")]
        if let Some(db) = &multi_tenant_db {
            let users_db = db.users_connection();
            let conn = users_db.lock();
            // Idempotent; guarded by Once inside the functions
            crate::ee::public_links::ensure_schema(&conn);
            crate::ee::public_links::ensure_org_settings_schema(&conn);
        }

        // Optional MetaStore (Postgres)
        let meta: Option<Arc<dyn MetaStore + Send + Sync>> = if let Some(pg) = &pg_client {
            Some(Arc::new(PgMetaStore::new(pg.clone())))
        } else {
            None
        };

        // Initialize auth service
        let jwt_secret =
            std::env::var("JWT_SECRET").unwrap_or_else(|_| "your-super-secret-jwt-key".to_string());
        let users_db = multi_tenant_db.as_ref().map(|db| db.users_connection());
        let oauth_users_db = users_db.clone();
        let auth_service = Arc::new(AuthService::new(
            users_db,
            jwt_secret.clone(),
            pg_client.clone(),
        ));

        // Optional OAuth service (DuckDB mode only for now)
        // Required env:
        //  - OAUTH_REDIRECT_BASE_URL (e.g. http://localhost:3003 or https://photos.example.com)
        //  - GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET
        let oauth_service: Option<Arc<OAuthService>> = (|| {
            let users_db = oauth_users_db?;
            let redirect_base_url = std::env::var("OAUTH_REDIRECT_BASE_URL")
                .or_else(|_| std::env::var("PUBLIC_BASE_URL"))
                .ok()?;
            let google_client_id = std::env::var("GOOGLE_CLIENT_ID").ok()?;
            let google_client_secret = std::env::var("GOOGLE_CLIENT_SECRET").ok()?;

            let github_client_id = std::env::var("GITHUB_CLIENT_ID").unwrap_or_default();
            let github_client_secret = std::env::var("GITHUB_CLIENT_SECRET").unwrap_or_default();
            let cfg = OAuthConfig {
                google_client_id,
                google_client_secret,
                github_client_id,
                github_client_secret,
                redirect_base_url,
            };
            Some(Arc::new(OAuthService::new(
                cfg,
                users_db,
                jwt_secret.clone(),
            )))
        })();
        if oauth_service.is_some() {
            tracing::info!("[AUTH] OAuth providers enabled: google{}", {
                let gh = std::env::var("GITHUB_CLIENT_ID").unwrap_or_default();
                if gh.is_empty() {
                    ""
                } else {
                    ", github"
                }
            });
        } else {
            tracing::info!("[AUTH] OAuth providers disabled (missing env or PG-only mode)");
        }

        // Start background cleaner for ML cache (HEIC→JPG proxies)
        let cache_root = data_dir.join("cache").join("ml");
        let _ = std::fs::create_dir_all(&cache_root);
        let ttl_days: u64 = std::env::var("HEIC_PROXY_TTL_DAYS")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(7);
        tokio::spawn(async move {
            use std::time::{Duration, SystemTime};
            use tracing::info;
            let ttl = Duration::from_secs(ttl_days * 24 * 3600);
            let mut interval = tokio::time::interval(Duration::from_secs(48 * 3600));
            loop {
                interval.tick().await;
                let now = SystemTime::now();
                let root = cache_root.clone();
                let mut removed = 0usize;
                let mut kept = 0usize;
                if let Ok(entries) = std::fs::read_dir(&root) {
                    for entry in entries.flatten() {
                        let path = entry.path();
                        if path.is_file() {
                            if let Ok(meta) = entry.metadata() {
                                if let Ok(modified) = meta.modified() {
                                    if let Ok(age) = now.duration_since(modified) {
                                        if age > ttl {
                                            let _ = std::fs::remove_file(&path);
                                            removed += 1;
                                            continue;
                                        }
                                    }
                                }
                            }
                            kept += 1;
                        }
                    }
                }
                info!(
                    "[ML_CACHE] Cleanup run complete: kept={}, removed={}, dir={}",
                    kept,
                    removed,
                    root.display()
                );
            }
        });

        // Configure PHASH_T_MAX (clamped 1..=32) and log
        let phash_t_max: u8 = std::env::var("PHASH_T_MAX")
            .ok()
            .and_then(|v| v.parse::<u8>().ok())
            .map(|v| v.clamp(1, 32))
            .unwrap_or(8);
        let bands = (phash_t_max as usize) + 1;
        tracing::info!("[PHASH] PHASH_T_MAX={} (bands={})", phash_t_max, bands);

        // Video similarity mode
        let video_similarity_mode = std::env::var("VIDEO_SIMILARITY")
            .ok()
            .and_then(|s| VideoSimilarityMode::from_str(&s).ok())
            // Default to Off when env var not provided
            .unwrap_or(VideoSimilarityMode::Off);
        tracing::info!("[VIDEO] VIDEO_SIMILARITY={:?}", video_similarity_mode);

        // Optional schedule override: comma-separated floats 0..1
        let video_phash_percents = std::env::var("VIDEO_PHASH_PERCENTS").ok().and_then(|raw| {
            let mut vals = Vec::new();
            for part in raw.split(',') {
                if let Ok(v) = part.trim().parse::<f64>() {
                    if v.is_finite() {
                        vals.push(v.clamp(0.0, 1.0));
                    }
                }
            }
            if vals.is_empty() {
                None
            } else {
                Some(vals)
            }
        });
        if let Some(ref v) = video_phash_percents {
            tracing::info!("[VIDEO] VIDEO_PHASH_PERCENTS override: {} entries", v.len());
        }

        let video_phash_lowinfo_skip = std::env::var("VIDEO_PHASH_LOWINFO_SKIP")
            .ok()
            .and_then(|s| match s.to_lowercase().as_str() {
                "0" | "false" | "no" => Some(false),
                "1" | "true" | "yes" => Some(true),
                _ => None,
            })
            .unwrap_or(true);
        let video_phash_hamming_max: u8 = std::env::var("VIDEO_PHASH_HAMMING_MAX")
            .ok()
            .and_then(|v| v.parse::<u8>().ok())
            .unwrap_or(10);

        // Upload ingestion options
        let move_on_ingest = std::env::var("MOVE_ON_INGEST")
            .ok()
            .map(|s| matches!(s.to_ascii_lowercase().as_str(), "1" | "true" | "yes"))
            .unwrap_or(true);
        let library_root = std::env::var("LIBRARY_DIR")
            .map(std::path::PathBuf::from)
            .unwrap_or_else(|_| data_dir.join("library"));

        // Library layout strategy (hard-coded to flat date layout)
        // Any provided LIBRARY_LAYOUT is ignored; only DateFlat is supported.
        let library_layout = LibraryLayout::DateFlat;

        // Ingestion concurrency (global)
        let ingest_concurrency: usize = std::env::var("INGEST_CONCURRENCY")
            .ok()
            .and_then(|s| s.parse::<usize>().ok())
            .filter(|&v| v >= 1)
            .unwrap_or(4);
        let ingest_semaphore = Arc::new(Semaphore::new(ingest_concurrency));

        // DuckDB concurrency limit (prevent lock contention)
        // DuckDB uses a single global mutex, so only 1 thread can access at a time.
        // Setting this to >1 causes lock contention where threads compete for the same mutex.
        let duckdb_concurrency = std::env::var("DUCKDB_CONCURRENCY")
            .ok()
            .and_then(|s| s.parse::<usize>().ok())
            .filter(|&v| v >= 1)
            .unwrap_or(1); // Default: max 1 concurrent DuckDB operation (matches DuckDB's single-writer design)
        let duckdb_semaphore = Arc::new(Semaphore::new(duckdb_concurrency));

        // Object detection during photo indexing
        let enable_object_detect_on_index = std::env::var("OBJECT_DETECT_ON_INDEX")
            .ok()
            .map(|s| matches!(s.to_ascii_lowercase().as_str(), "1" | "true" | "yes"))
            .unwrap_or(true);

        // Sync idle timeout for auto-summary logging
        let sync_idle_secs: u64 = std::env::var("SYNC_IDLE_SECS")
            .ok()
            .and_then(|s| s.parse::<u64>().ok())
            .unwrap_or(60);

        // Create sync sessions store and idle watcher
        let sync_sessions: Arc<RwLock<HashMap<String, SyncSession>>> =
            Arc::new(RwLock::new(HashMap::new()));
        {
            let sessions = sync_sessions.clone();
            let idle = sync_idle_secs;
            tokio::spawn(async move {
                let mut interval = tokio::time::interval(std::time::Duration::from_secs(20));
                loop {
                    interval.tick().await;
                    let now = Utc::now().timestamp();
                    let mut to_log: Vec<(String, SyncSession)> = Vec::new();
                    {
                        let mut map = sessions.write();
                        let keys: Vec<String> = map.keys().cloned().collect();
                        for k in keys {
                            if let Some(sess) = map.get(&k) {
                                if now - sess.last_ts >= idle as i64 {
                                    if let Some(owned) = map.remove(&k) {
                                        to_log.push((k.clone(), owned));
                                    }
                                }
                            }
                        }
                    }
                    for (user, sess) in to_log.drain(..) {
                        sess.log_summary(&user);
                    }
                }
            });
        }

        // pg_client already computed above
        let update_service = Arc::new(UpdateService::new());
        UpdateService::spawn_background_checks(update_service.clone());

        Ok(Self {
            visual_encoders: Arc::new(RwLock::new(visual_encoders)),
            textual_encoders: Arc::new(RwLock::new(textual_encoders)),
            yolo_detector,
            face_service,
            default_model,
            ai_backend: ai_config.backend,
            ai_device_id: ai_config.device_id,
            model_path,
            rknn_model_path: ai_config.rknn_model_root,
            rknn_runtime,
            model_configs: config_map,
            auth_service,
            oauth_service,
            multi_tenant_db,
            reindex_jobs: Arc::new(parking_lot::RwLock::new(HashMap::new())),
            reindex_job_owners: Arc::new(parking_lot::RwLock::new(HashMap::new())),
            reindex_cancel_flags: Arc::new(parking_lot::RwLock::new(HashMap::new())),
            active_job_for_user: Arc::new(parking_lot::RwLock::new(HashMap::new())),
            phash_t_max,
            similar_indexes: Arc::new(parking_lot::RwLock::new(HashMap::new())),
            video_similarity_mode,
            video_phash_percents,
            video_phash_lowinfo_skip,
            video_phash_hamming_max,
            move_on_ingest,
            library_root,
            library_layout,
            data_dir: data_dir.to_path_buf(),
            upload_channels: Arc::new(parking_lot::RwLock::new(HashMap::new())),
            tus_upload_owners: Arc::new(parking_lot::RwLock::new(HashMap::new())),
            ingest_semaphore,
            duckdb_semaphore,
            enable_object_detect_on_index,
            sync_sessions,
            sync_idle_secs,
            live_photo_video_backfill_done: Arc::new(parking_lot::RwLock::new(HashSet::new())),
            pg_client,
            meta,
            update_service,
        })
    }

    pub fn model_file(&self, relative_path: impl AsRef<Path>) -> PathBuf {
        self.model_path.join(relative_path)
    }

    pub fn rknn_model_file(&self, relative_path: impl AsRef<Path>) -> PathBuf {
        self.rknn_model_path.join(relative_path)
    }

    /// Get or create an upload events broadcast channel for a user
    pub fn get_or_create_upload_channel(&self, user_id: &str) -> broadcast::Sender<String> {
        if let Some(tx) = self.upload_channels.read().get(user_id).cloned() {
            return tx;
        }
        let (tx, _rx) = broadcast::channel(64);
        self.upload_channels
            .write()
            .insert(user_id.to_string(), tx.clone());
        tx
    }

    pub fn subscribe_upload_channel(&self, user_id: &str) -> broadcast::Receiver<String> {
        let tx = self.get_or_create_upload_channel(user_id);
        tx.subscribe()
    }

    pub fn remember_tus_upload_owner(&self, upload_id: &str, user_id: &str) {
        self.tus_upload_owners
            .write()
            .insert(upload_id.to_string(), user_id.to_string());
    }

    pub fn tus_upload_owner(&self, upload_id: &str) -> Option<String> {
        self.tus_upload_owners.read().get(upload_id).cloned()
    }

    pub fn take_tus_upload_owner(&self, upload_id: &str) -> Option<String> {
        self.tus_upload_owners.write().remove(upload_id)
    }

    /// Record a successful ingest event into the user's current sync session (auto-starts if absent)
    pub fn record_sync_ingest(
        &self,
        user_id: &str,
        method: &str,
        is_photo: bool,
        duplicate: bool,
        success: bool,
    ) {
        let mut sessions = self.sync_sessions.write();
        let sess = sessions
            .entry(user_id.to_string())
            .or_insert_with(|| SyncSession::new());
        sess.touch();
        match method {
            "tus" => sess.tus += 1,
            "multipart" => sess.multipart += 1,
            _ => sess.other += 1,
        }
        if is_photo {
            sess.photos += 1;
        } else {
            sess.videos += 1;
        }
        if duplicate {
            sess.duplicates += 1;
        }
        if !success {
            sess.failures += 1;
        }
    }

    /// Record a failure into the user's current sync session (auto-starts if absent)
    pub fn record_sync_failure(&self, user_id: &str) {
        let mut sessions = self.sync_sessions.write();
        let sess = sessions
            .entry(user_id.to_string())
            .or_insert_with(|| SyncSession::new());
        sess.touch();
        sess.failures += 1;
    }

    /// Best-effort backfill: mark Live Photo motion-component MOVs as `is_live_photo=TRUE` so
    /// they don't show up as standalone videos.
    ///
    /// This runs at most once per process per user and only scans short QuickTime videos.
    pub async fn backfill_live_photo_video_flags(&self, user_id: &str) {
        if self.pg_client.is_some() || self.multi_tenant_db.is_none() {
            return;
        }
        {
            let done = self.live_photo_video_backfill_done.read();
            if done.contains(user_id) {
                return;
            }
        }
        let user_id_s = user_id.to_string();
        let org_id = self.org_id_for_user(&user_id_s);
        let data_db = match self.get_user_data_database(&user_id_s) {
            Ok(db) => db,
            Err(_) => return,
        };

        let updated = tokio::task::spawn_blocking(move || -> i64 {
            // Gather candidates without holding the DB lock across ffprobe calls.
            let candidates: Vec<(i32, String)> = {
                let conn = data_db.lock();
                let mut out: Vec<(i32, String)> = Vec::new();
                if let Ok(mut stmt) = conn.prepare(
                    "SELECT id, path FROM photos
                     WHERE organization_id = ? AND user_id = ?
                       AND is_video = TRUE
                       AND COALESCE(is_live_photo, FALSE) = FALSE
                       AND COALESCE(delete_time, 0) = 0
                       AND COALESCE(duration_ms, 0) <= 3500
                       AND (COALESCE(mime_type,'') = '' OR mime_type = 'video/quicktime')
                     LIMIT 1000",
                ) {
                    if let Ok(rows) = stmt.query_map(duckdb::params![org_id, &user_id_s], |row| {
                        Ok((row.get::<_, i32>(0)?, row.get::<_, String>(1)?))
                    }) {
                        for r in rows.flatten() {
                            out.push(r);
                        }
                    }
                }
                out
            };

            let mut to_mark: Vec<i32> = Vec::new();
            for (id, path) in &candidates {
                let p = std::path::Path::new(path);
                if !p.is_file() {
                    continue;
                }
                if crate::video::is_live_photo_component(p) {
                    to_mark.push(*id);
                }
            }
            if to_mark.is_empty() {
                return 0;
            }

            let conn = data_db.lock();
            let mut n: i64 = 0;
            for id in to_mark {
                if conn
                    .execute(
                        "UPDATE photos SET is_live_photo = TRUE WHERE id = ?",
                        duckdb::params![id],
                    )
                    .unwrap_or(0)
                    > 0
                {
                    n += 1;
                }
            }
            n
        })
        .await
        .unwrap_or(0);

        if updated > 0 {
            tracing::info!(
                target: "upload",
                "[LIVE-PHOTO] Marked {} Live Photo motion videos for user={}",
                updated,
                user_id
            );
        }
        self.live_photo_video_backfill_done
            .write()
            .insert(user_id.to_string());
    }

    /// Get or build the in-memory banded pHash index for a user
    pub fn get_or_build_similar_index(
        &self,
        user_id: &str,
    ) -> anyhow::Result<Arc<parking_lot::RwLock<crate::photos::similar::BandingIndex>>> {
        if let Some(idx) = self.similar_indexes.read().get(user_id) {
            return Ok(idx.clone());
        }
        // Resolve user's organization id
        let org_id: i32 = if let Some(pg) = &self.pg_client {
            let row_res = if tokio::runtime::Handle::try_current().is_ok() {
                tokio::task::block_in_place(|| {
                    futures::executor::block_on(pg.query_one(
                        "SELECT organization_id FROM users WHERE user_id=$1 LIMIT 1",
                        &[&user_id],
                    ))
                })
                .ok()
            } else {
                futures::executor::block_on(pg.query_one(
                    "SELECT organization_id FROM users WHERE user_id=$1 LIMIT 1",
                    &[&user_id],
                ))
                .ok()
            };
            row_res.map(|r| r.get::<_, i32>(0)).unwrap_or(1)
        } else {
            let udb = self
                .multi_tenant_db
                .as_ref()
                .expect("users DB required in DuckDB mode")
                .users_connection();
            let c = udb.lock();
            c.query_row(
                "SELECT organization_id FROM users WHERE user_id = ? LIMIT 1",
                duckdb::params![user_id],
                |row| row.get::<_, i32>(0),
            )
            .unwrap_or(1)
        };
        let mut idx = crate::photos::similar::BandingIndex::new(self.phash_t_max);
        if let Some(pg) = &self.pg_client {
            // Avoid blocking the Tokio scheduler: run synchronous wait inside block_in_place
            let query_result = if tokio::runtime::Handle::try_current().is_ok() {
                tokio::task::block_in_place(|| {
                    futures::executor::block_on(pg.query(
                        "SELECT asset_id, phash_hex FROM photo_hashes WHERE organization_id=$1",
                        &[&org_id],
                    ))
                })
            } else {
                futures::executor::block_on(pg.query(
                    "SELECT asset_id, phash_hex FROM photo_hashes WHERE organization_id=$1",
                    &[&org_id],
                ))
            };
            if let Ok(rows) = query_result {
                for r in rows {
                    let aid: String = r.get(0);
                    let hex: String = r.get(1);
                    if let Some(h) = crate::photos::phash::phash_from_hex(&hex) {
                        idx.upsert(aid, h);
                    }
                }
            }
        } else {
            // DuckDB load
            let pool = self.get_user_data_database(user_id)?;
            let conn = pool.lock();
            let _ = conn.execute(
                "CREATE TABLE IF NOT EXISTS photo_hashes (
                    organization_id INTEGER NOT NULL,
                    asset_id TEXT NOT NULL,
                    phash_hex TEXT NOT NULL
                )",
                [],
            );
            let _ = conn.execute(
                "CREATE UNIQUE INDEX IF NOT EXISTS idx_photo_hashes_org_asset_u ON photo_hashes(organization_id, asset_id)",
                []
            );
            let mut stmt = conn.prepare(
                "SELECT asset_id, phash_hex FROM photo_hashes WHERE organization_id = ?",
            )?;
            let rows = stmt.query_map(duckdb::params![org_id], |row| {
                let asset_id: String = row.get(0)?;
                let phash_hex: String = row.get(1)?;
                Ok((asset_id, phash_hex))
            })?;
            for r in rows {
                if let Ok((asset_id, hex)) = r {
                    if let Some(h) = crate::photos::phash::phash_from_hex(&hex) {
                        idx.upsert(asset_id, h);
                    }
                }
            }
        }
        tracing::info!(
            "[PHASH] Built band index (user={}, t_max={}, hashes={})",
            user_id,
            self.phash_t_max,
            idx.len()
        );
        let idx = Arc::new(parking_lot::RwLock::new(idx));
        self.similar_indexes
            .write()
            .insert(user_id.to_string(), idx.clone());
        Ok(idx)
    }

    /// Force rebuild of a user's in-memory index from DB content
    pub fn rebuild_similar_index(&self, user_id: &str) -> anyhow::Result<()> {
        let pool = self.get_user_data_database(user_id)?;
        let conn = pool.lock();
        let mut stmt = conn.prepare("SELECT asset_id, phash_hex FROM photo_hashes")?;
        let mut new_idx = crate::photos::similar::BandingIndex::new(self.phash_t_max);
        let rows = stmt.query_map([], |row| {
            let asset_id: String = row.get(0)?;
            let phash_hex: String = row.get(1)?;
            Ok((asset_id, phash_hex))
        })?;
        for r in rows {
            if let Ok((asset_id, hex)) = r {
                if let Some(h) = crate::photos::phash::phash_from_hex(&hex) {
                    new_idx.upsert(asset_id, h);
                }
            }
        }
        let arc_idx = self.get_or_build_similar_index(user_id)?;
        *arc_idx.write() = new_idx;
        tracing::info!(
            "[PHASH] Rebuilt band index (user={}, t_max={})",
            user_id,
            self.phash_t_max
        );
        Ok(())
    }

    pub fn with_visual_encoder<T, F>(&self, model_name: Option<&str>, f: F) -> Option<T>
    where
        F: FnOnce(&VisualEncoder) -> T,
    {
        let model_name = model_name.unwrap_or(&self.default_model);
        let encoders = self.visual_encoders.read();
        encoders.get(model_name).map(f)
    }

    pub fn with_textual_encoder<T, F>(&self, model_name: Option<&str>, f: F) -> Option<T>
    where
        F: FnOnce(&TextualEncoder) -> T,
    {
        let model_name = model_name.unwrap_or(&self.default_model);
        let encoders = self.textual_encoders.read();
        encoders.get(model_name).map(f)
    }

    pub fn list_models(&self) -> Vec<String> {
        let mut models = std::collections::HashSet::new();

        for key in self.visual_encoders.read().keys() {
            models.insert(key.clone());
        }

        for key in self.textual_encoders.read().keys() {
            models.insert(key.clone());
        }

        models.into_iter().collect()
    }

    /// Select the appropriate model based on language
    pub fn select_model_for_language(&self, language: Option<&str>) -> String {
        let lang = language.unwrap_or("en");

        // Normalize language code (zh-CN -> zh)
        let normalized_lang = lang.split('-').next().unwrap_or(lang);

        // Use OpenAI CLIP as the primary model (supports English best)
        if self.model_configs.contains_key("ViT-B-32__openai") {
            if let Some(config) = self.model_configs.get("ViT-B-32__openai") {
                if config
                    .supported_languages
                    .contains(&normalized_lang.to_string())
                {
                    return "ViT-B-32__openai".to_string();
                }
            }
        }

        // Fallback to default model
        tracing::warn!("Language '{}' not supported, using default model", lang);
        self.default_model.clone()
    }

    /// Get supported languages for all models
    pub fn get_supported_languages(&self) -> Vec<String> {
        let mut languages = std::collections::HashSet::new();

        for config in self.model_configs.values() {
            for lang in &config.supported_languages {
                languages.insert(lang.clone());
            }
        }

        languages.into_iter().collect()
    }

    /// Check if a language is supported
    pub fn is_language_supported(&self, language: &str) -> bool {
        let normalized_lang = language.split('-').next().unwrap_or(language);
        let supported_languages = self.get_supported_languages();
        supported_languages.contains(&normalized_lang.to_string())
    }

    /// Get user-specific data database (photos, albums, faces metadata) — DuckDB mode only
    pub fn get_user_data_database(
        &self,
        user_id: &str,
    ) -> Result<crate::database::multi_tenant::DbPool> {
        if let Some(db) = &self.multi_tenant_db {
            return db.get_user_data_database(user_id);
        }
        Err(anyhow::anyhow!("DuckDB not available in Postgres mode"))
    }

    /// Get embedding database handle (global DB stores embeddings too) — DuckDB mode only
    pub fn get_user_embedding_database(
        &self,
        user_id: &str,
    ) -> Result<crate::database::multi_tenant::DbPool> {
        if let Some(db) = &self.multi_tenant_db {
            return db.get_user_database(user_id);
        }
        Err(anyhow::anyhow!("DuckDB not available in Postgres mode"))
    }

    // -------- Path helpers (independent of DB backend) --------
    pub fn user_data_path(&self, user_id: &str) -> std::path::PathBuf {
        self.data_dir.join(format!("user_{}", user_id))
    }
    pub fn user_thumbnails_path(&self, user_id: &str) -> std::path::PathBuf {
        self.user_data_path(user_id).join("thumbnails")
    }
    pub fn user_locked_path(&self, user_id: &str) -> std::path::PathBuf {
        self.user_data_path(user_id).join("locked")
    }
    pub fn user_faces_path(&self, user_id: &str) -> std::path::PathBuf {
        self.user_data_path(user_id).join("faces")
    }
    pub fn user_videos_path(&self, user_id: &str) -> std::path::PathBuf {
        self.user_data_path(user_id).join("videos")
    }
    pub fn thumbnail_path_for(&self, user_id: &str, asset_id: &str) -> std::path::PathBuf {
        let a = asset_id.chars().nth(0).unwrap_or('0');
        let b = asset_id.chars().nth(1).unwrap_or('0');
        let c = asset_id.chars().nth(2).unwrap_or('0');
        let d = asset_id.chars().nth(3).unwrap_or('0');
        let tier1 = format!("{}{}", a, b);
        let tier2 = format!("{}{}", c, d);
        self.user_thumbnails_path(user_id)
            .join(tier1)
            .join(tier2)
            .join(format!("{}_t2.webp", asset_id))
    }
    pub fn poster_path_for(&self, user_id: &str, asset_id: &str) -> std::path::PathBuf {
        let a = asset_id.chars().nth(0).unwrap_or('0');
        let b = asset_id.chars().nth(1).unwrap_or('0');
        let c = asset_id.chars().nth(2).unwrap_or('0');
        let d = asset_id.chars().nth(3).unwrap_or('0');
        let tier1 = format!("{}{}", a, b);
        let tier2 = format!("{}{}", c, d);
        self.user_thumbnails_path(user_id)
            .join(tier1)
            .join(tier2)
            .join(format!("{}_v.webp", asset_id))
    }
    pub fn cover_path_for(&self, user_id: &str, asset_id: &str) -> std::path::PathBuf {
        let a = asset_id.chars().nth(0).unwrap_or('0');
        let b = asset_id.chars().nth(1).unwrap_or('0');
        let c = asset_id.chars().nth(2).unwrap_or('0');
        let d = asset_id.chars().nth(3).unwrap_or('0');
        let tier1 = format!("{}{}", a, b);
        let tier2 = format!("{}{}", c, d);
        self.user_thumbnails_path(user_id)
            .join(tier1)
            .join(tier2)
            .join(format!("{}_c.webp", asset_id))
    }
    pub fn live_video_path_for(&self, user_id: &str, asset_id: &str) -> std::path::PathBuf {
        let a = asset_id.chars().nth(0).unwrap_or('0');
        let b = asset_id.chars().nth(1).unwrap_or('0');
        let c = asset_id.chars().nth(2).unwrap_or('0');
        let d = asset_id.chars().nth(3).unwrap_or('0');
        let tier1 = format!("{}{}", a, b);
        let tier2 = format!("{}{}", c, d);
        self.user_thumbnails_path(user_id)
            .join(tier1)
            .join(tier2)
            .join(format!("{}_v.mp4", asset_id))
    }
    pub fn live_video_mov_path_for(&self, user_id: &str, asset_id: &str) -> std::path::PathBuf {
        let a = asset_id.chars().nth(0).unwrap_or('0');
        let b = asset_id.chars().nth(1).unwrap_or('0');
        let c = asset_id.chars().nth(2).unwrap_or('0');
        let d = asset_id.chars().nth(3).unwrap_or('0');
        let tier1 = format!("{}{}", a, b);
        let tier2 = format!("{}{}", c, d);
        self.user_thumbnails_path(user_id)
            .join(tier1)
            .join(tier2)
            .join(format!("{}_v.mov", asset_id))
    }
    pub fn video_mp4_proxy_path_for(&self, user_id: &str, asset_id: &str) -> std::path::PathBuf {
        let a = asset_id.chars().nth(0).unwrap_or('0');
        let b = asset_id.chars().nth(1).unwrap_or('0');
        let c = asset_id.chars().nth(2).unwrap_or('0');
        let d = asset_id.chars().nth(3).unwrap_or('0');
        let tier1 = format!("{}{}", a, b);
        let tier2 = format!("{}{}", c, d);
        self.user_videos_path(user_id)
            .join(tier1)
            .join(tier2)
            .join(format!("{}_p.mp4", asset_id))
    }
    /// iOS-optimized streaming proxy (lower bitrate) for smoother playback on mobile networks.
    pub fn video_stream_mp4_proxy_path_for(
        &self,
        user_id: &str,
        asset_id: &str,
    ) -> std::path::PathBuf {
        let a = asset_id.chars().nth(0).unwrap_or('0');
        let b = asset_id.chars().nth(1).unwrap_or('0');
        let c = asset_id.chars().nth(2).unwrap_or('0');
        let d = asset_id.chars().nth(3).unwrap_or('0');
        let tier1 = format!("{}{}", a, b);
        let tier2 = format!("{}{}", c, d);
        self.user_videos_path(user_id)
            .join(tier1)
            .join(tier2)
            .join(format!("{}_s.mp4", asset_id))
    }
    pub fn avif_path_for(&self, user_id: &str, asset_id: &str) -> std::path::PathBuf {
        let a = asset_id.chars().nth(0).unwrap_or('0');
        let b = asset_id.chars().nth(1).unwrap_or('0');
        let c = asset_id.chars().nth(2).unwrap_or('0');
        let d = asset_id.chars().nth(3).unwrap_or('0');
        let tier1 = format!("{}{}", a, b);
        let tier2 = format!("{}{}", c, d);
        self.user_thumbnails_path(user_id)
            .join(tier1)
            .join(tier2)
            .join(format!("{}_a2.avif", asset_id))
    }
    pub fn image_preview_jpeg_path_for(&self, user_id: &str, asset_id: &str) -> std::path::PathBuf {
        let a = asset_id.chars().nth(0).unwrap_or('0');
        let b = asset_id.chars().nth(1).unwrap_or('0');
        let c = asset_id.chars().nth(2).unwrap_or('0');
        let d = asset_id.chars().nth(3).unwrap_or('0');
        let tier1 = format!("{}{}", a, b);
        let tier2 = format!("{}{}", c, d);
        self.user_thumbnails_path(user_id)
            .join(tier1)
            .join(tier2)
            .join(format!("{}_i2.jpg", asset_id))
    }
    pub fn locked_original_path_for(&self, user_id: &str, asset_id: &str) -> std::path::PathBuf {
        let a = asset_id.chars().nth(0).unwrap_or('0');
        let b = asset_id.chars().nth(1).unwrap_or('0');
        let c = asset_id.chars().nth(2).unwrap_or('0');
        let d = asset_id.chars().nth(3).unwrap_or('0');
        let tier1 = format!("{}{}", a, b);
        let tier2 = format!("{}{}", c, d);
        self.user_locked_path(user_id)
            .join(tier1)
            .join(tier2)
            .join(format!("{}.pae3", asset_id))
    }
    pub fn locked_thumb_path_for(&self, user_id: &str, asset_id: &str) -> std::path::PathBuf {
        let a = asset_id.chars().nth(0).unwrap_or('0');
        let b = asset_id.chars().nth(1).unwrap_or('0');
        let c = asset_id.chars().nth(2).unwrap_or('0');
        let d = asset_id.chars().nth(3).unwrap_or('0');
        let tier1 = format!("{}{}", a, b);
        let tier2 = format!("{}{}", c, d);
        self.user_locked_path(user_id)
            .join(tier1)
            .join(tier2)
            .join(format!("{}_t.pae3", asset_id))
    }

    /// Create user-specific embedding store for search operations
    pub fn create_user_embedding_store(&self, user_id: &str) -> Result<Arc<EmbeddingStore>> {
        let embedding_dim = self
            .model_configs
            .values()
            .next()
            .map(|c| c.embedding_dim)
            .unwrap_or(512); // Default to 512 for backwards compatibility
        if let Some(pg) = &self.pg_client {
            return Ok(Arc::new(EmbeddingStore::new_postgres(
                pg.clone(),
                embedding_dim,
            )));
        }
        let embedding_db = self.get_user_embedding_database(user_id)?;
        Ok(Arc::new(EmbeddingStore::new(embedding_db, embedding_dim)))
    }

    // Reindex job helpers
    pub fn create_reindex_job_for(&self, user_id: &str) -> (String, broadcast::Sender<String>) {
        let job_id = uuid::Uuid::new_v4().to_string();
        let (tx, _rx) = broadcast::channel(64);
        self.reindex_jobs.write().insert(job_id.clone(), tx.clone());
        self.reindex_job_owners
            .write()
            .insert(job_id.clone(), user_id.to_string());
        // Initialize cancellation flag
        use std::sync::atomic::AtomicBool;
        let flag = std::sync::Arc::new(AtomicBool::new(false));
        self.reindex_cancel_flags
            .write()
            .insert(job_id.clone(), flag);
        self.active_job_for_user
            .write()
            .insert(user_id.to_string(), job_id.clone());
        (job_id, tx)
    }

    pub fn get_reindex_receiver(&self, job_id: &str) -> Option<broadcast::Receiver<String>> {
        self.reindex_jobs
            .read()
            .get(job_id)
            .map(|tx| tx.subscribe())
    }

    pub fn finish_reindex_job(&self, job_id: &str) {
        self.reindex_jobs.write().remove(job_id);
        if let Some(user_id) = self.reindex_job_owners.write().remove(job_id) {
            let mut map = self.active_job_for_user.write();
            if let Some(active) = map.get(&user_id) {
                if active == job_id {
                    map.remove(&user_id);
                }
            }
        }
        self.reindex_cancel_flags.write().remove(job_id);
    }

    pub fn get_active_reindex_job_for_user(&self, user_id: &str) -> Option<String> {
        self.active_job_for_user.read().get(user_id).cloned()
    }

    pub fn cancel_reindex_job(&self, job_id: &str) -> bool {
        if let Some(flag) = self.reindex_cancel_flags.read().get(job_id).cloned() {
            tracing::info!("[REINDEX] Setting cancel flag for job {}", job_id);
            flag.store(true, std::sync::atomic::Ordering::Relaxed);
            true
        } else {
            tracing::info!("[REINDEX] Cancel flag requested for unknown job {}", job_id);
            false
        }
    }

    pub fn get_cancel_flag(
        &self,
        job_id: &str,
    ) -> Option<std::sync::Arc<std::sync::atomic::AtomicBool>> {
        self.reindex_cancel_flags.read().get(job_id).cloned()
    }
}

#[derive(Clone, Debug)]
pub struct SyncSession {
    pub id: String,
    pub start_ts: i64,
    pub last_ts: i64,
    pub tus: u64,
    pub multipart: u64,
    pub other: u64,
    pub photos: u64,
    pub videos: u64,
    pub duplicates: u64,
    pub failures: u64,
}

impl SyncSession {
    pub fn new() -> Self {
        let now = Utc::now().timestamp();
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            start_ts: now,
            last_ts: now,
            tus: 0,
            multipart: 0,
            other: 0,
            photos: 0,
            videos: 0,
            duplicates: 0,
            failures: 0,
        }
    }
    pub fn touch(&mut self) {
        self.last_ts = Utc::now().timestamp();
    }
    pub fn log_summary(&self, user_id: &str) {
        let duration = (self.last_ts - self.start_ts).max(0);
        let total = self.photos + self.videos;
        tracing::info!(
            "[SYNC] completed user={} sync_id={} duration_s={} total={} photos={} videos={} tus={} multipart={} other={} duplicates={} failures={}",
            user_id,
            self.id,
            duration,
            total,
            self.photos,
            self.videos,
            self.tus,
            self.multipart,
            self.other,
            self.duplicates,
            self.failures
        );
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VideoSimilarityMode {
    Off,
    Fixed(usize), // 3|5|7|9
    Cascade,
}

impl VideoSimilarityMode {
    pub fn from_str(s: &str) -> Result<Self, ()> {
        match s.to_ascii_lowercase().as_str() {
            "off" => Ok(Self::Off),
            "3" => Ok(Self::Fixed(3)),
            "5" => Ok(Self::Fixed(5)),
            "7" => Ok(Self::Fixed(7)),
            "9" => Ok(Self::Fixed(9)),
            "cascade" => Ok(Self::Cascade),
            _ => Err(()),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LibraryLayout {
    // Flat date layout: <yyyy>/<mm>/<dd>/<filename>
    DateFlat,
}

impl LibraryLayout {
    pub fn from_str(_s: &str) -> Result<Self, ()> {
        // Only DateFlat is supported going forward
        Ok(Self::DateFlat)
    }
}
