mod ai_config;
mod auth;
mod clip;
mod database;
mod face_processing;
mod media_tools;
mod photos;
mod server;
mod video;
mod yolo_detection;
// Enterprise bridge module (conditionally compiled)
#[cfg(feature = "ee")]
mod ee;

use anyhow::Result;
use bcrypt::hash;
use clap::Parser;
use duckdb::params;
use std::net::SocketAddr;
use std::sync::Arc;
// TraceLayer removed to quiet per-request HTTP logs
use tracing::{info, Level};
use tracing_subscriber::{EnvFilter, FmtSubscriber};
use uuid::Uuid;

use crate::clip::ClipConfig;
use crate::server::photo_routes::hard_delete_assets;
use crate::server::text_search;
use crate::server::{cors_layer, routes::create_router, state::AppState};

const DEMO_EMAIL: &str = "demo@openphotos.ca";
const DEMO_PASSWORD: &str = "demo";
const DEMO_NAME: &str = "Demo User";
const DEMO_ORG_NAME: &str = "Demo Organization";

fn demo_mode_enabled() -> bool {
    std::env::var("DEMO")
        .ok()
        .map(|v| {
            let v = v.trim().to_ascii_lowercase();
            matches!(v.as_str(), "yes" | "true" | "1")
        })
        .unwrap_or(false)
}

async fn ensure_demo_user(state: &AppState) -> Result<()> {
    let demo_hash = tokio::task::spawn_blocking(|| hash(DEMO_PASSWORD, 4))
        .await
        .map_err(|e| anyhow::anyhow!("failed to hash demo password: {}", e))??;

    if let Some(pg) = &state.pg_client {
        let existing = pg
            .query_opt(
                "SELECT id FROM users WHERE lower(email)=lower($1) LIMIT 1",
                &[&DEMO_EMAIL],
            )
            .await?;

        if existing.is_some() {
            let updated = pg
                .execute(
                    "UPDATE users SET password_hash=$1, status='active' WHERE lower(email)=lower($2)",
                    &[&demo_hash, &DEMO_EMAIL],
                )
                .await?;
            info!(
                "[DEMO] reset password for demo user email={} rows={}",
                DEMO_EMAIL, updated
            );
            return Ok(());
        }

        let org_id: i32 = if let Some(row) = pg
            .query_opt("SELECT id FROM organizations ORDER BY id LIMIT 1", &[])
            .await?
        {
            row.get(0)
        } else {
            let row = pg
                .query_one(
                    "INSERT INTO organizations (name) VALUES ($1) RETURNING id",
                    &[&DEMO_ORG_NAME],
                )
                .await?;
            row.get(0)
        };

        let user_id = Uuid::new_v4().to_string();
        let secret = Uuid::new_v4().to_string();
        pg.execute(
            "INSERT INTO users (user_id, name, email, password_hash, organization_id, role, secret, status) \
             VALUES ($1,$2,$3,$4,$5,$6,$7,'active')",
            &[&user_id, &DEMO_NAME, &DEMO_EMAIL, &demo_hash, &org_id, &"admin", &secret],
        )
        .await?;
        info!(
            "[DEMO] created demo user email={} org_id={} backend=postgres",
            DEMO_EMAIL, org_id
        );
        return Ok(());
    }

    let users_db = state
        .multi_tenant_db
        .as_ref()
        .expect("users DB required in DuckDB mode")
        .users_connection();
    let conn = users_db.lock();

    let existing_demo: Option<i32> = conn
        .query_row(
            "SELECT id FROM users WHERE lower(email)=lower(?) LIMIT 1",
            params![DEMO_EMAIL],
            |row| row.get(0),
        )
        .ok();

    if existing_demo.is_some() {
        let updated = conn.execute(
            "UPDATE users SET password_hash = ?, status = 'active' WHERE lower(email)=lower(?)",
            params![&demo_hash, DEMO_EMAIL],
        )?;
        info!(
            "[DEMO] reset password for demo user email={} rows={}",
            DEMO_EMAIL, updated
        );
        return Ok(());
    }

    let org_id: i32 = match conn.query_row(
        "SELECT id FROM organizations ORDER BY id LIMIT 1",
        [],
        |row| row.get(0),
    ) {
        Ok(id) => id,
        Err(_) => conn.query_row(
            "INSERT INTO organizations (name) VALUES (?) RETURNING id",
            params![DEMO_ORG_NAME],
            |row| row.get(0),
        )?,
    };

    let user_id = Uuid::new_v4().to_string();
    let secret = Uuid::new_v4().to_string();
    conn.execute(
        "INSERT INTO users (user_id, name, email, password_hash, organization_id, role, secret, status) \
         VALUES (?, ?, ?, ?, ?, ?, ?, 'active')",
        params![&user_id, DEMO_NAME, DEMO_EMAIL, &demo_hash, org_id, "admin", &secret],
    )?;
    info!(
        "[DEMO] created demo user email={} org_id={} backend=duckdb",
        DEMO_EMAIL, org_id
    );
    Ok(())
}

#[derive(Parser, Debug)]
#[command(author, version, about, long_about = None)]
struct Args {
    /// Database path (use :memory: for in-memory database)
    #[arg(
        short,
        long,
        default_value = "clip_service.duckdb",
        env = "DATABASE_PATH"
    )]
    database: String,

    /// Server address
    #[arg(short, long, default_value = "0.0.0.0:3003", env = "SERVER_ADDRESS")]
    address: String,

    /// Model directory path
    #[arg(short, long, default_value = "models", env = "MODEL_PATH")]
    model_path: String,

    /// Default model name
    #[arg(long, default_value = "ViT-B-32__openai", env = "DEFAULT_MODEL")]
    default_model: String,

    /// AI backend: auto, cpu, cuda, coreml, directml, migraphx, or rk3588-hybrid
    #[arg(long, default_value = "auto", env = "AI_BACKEND")]
    ai_backend: String,

    /// AI device index for GPU execution providers
    #[arg(long, default_value_t = 0, env = "AI_DEVICE_ID")]
    ai_device_id: i32,

    /// Optional RKNN model directory root
    #[arg(long, env = "RKNN_MODEL_PATH")]
    rknn_model_path: Option<String>,

    /// Log level
    #[arg(long, default_value = "info", env = "LOG_LEVEL")]
    log_level: String,

    /// Repair DuckDB constraints and exit (useful if startup fails with FK violations)
    #[arg(long, default_value_t = false)]
    repair_db: bool,
}

#[tokio::main]
async fn main() -> Result<()> {
    // Parse command line arguments
    let args = Args::parse();

    // Initialize logging
    // Bridge `log` crate records (from dependencies like Tantivy) into `tracing`, but only WARN+
    let _ = tracing_log::LogTracer::init_with_filter(log::LevelFilter::Warn);
    let subscriber = FmtSubscriber::builder()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new(&args.log_level)),
        )
        .with_max_level(Level::TRACE)
        .finish();

    tracing::subscriber::set_global_default(subscriber)?;

    info!("Starting CLIP Service");
    info!("Database: {}", args.database);
    info!("Server address: {}", args.address);
    info!("Model path: {}", args.model_path);
    info!("Default model: {}", args.default_model);
    info!("AI backend: {}", args.ai_backend);
    info!("AI device ID: {}", args.ai_device_id);

    // Load environment variables from .env file if present
    dotenvy::dotenv().ok();

    let ai_config = crate::ai_config::AiRuntimeConfig::from_args(
        &args.model_path,
        &args.ai_backend,
        args.ai_device_id,
        args.rknn_model_path.as_deref(),
    )?;
    std::env::set_var(
        "AI_COREML_COMPUTE_UNITS",
        ai_config.coreml_compute_units.as_str(),
    );
    info!("RKNN model path: {}", ai_config.rknn_model_root.display());
    info!(
        "AI CoreML compute units: {}",
        ai_config.coreml_compute_units.as_str()
    );

    // Optional one-shot repair flow
    if args.repair_db {
        use std::path::Path;
        let data_dir = Path::new(&args.database);
        tracing::info!(
            "[REPAIR] Attempting FK/orphan repair at {}",
            data_dir.display()
        );
        if let Err(e) =
            crate::database::multi_tenant::MultiTenantDatabase::repair_data_dir(data_dir)
        {
            tracing::error!("[REPAIR] Failed: {}", e);
            // Exit with error code to surface failure in CI/shell
            return Err(e);
        }
        tracing::info!("[REPAIR] Completed successfully");
        return Ok(());
    }

    // Check presence of required external tools (ffprobe/ffmpeg)
    fn tool_version(cmd: &std::path::Path, args: &[&str]) -> Option<String> {
        std::process::Command::new(cmd)
            .args(args)
            .output()
            .ok()
            .and_then(|o| {
                if o.status.success() {
                    Some(String::from_utf8_lossy(&o.stdout).to_string())
                } else {
                    None
                }
            })
    }
    let ffprobe_path = crate::media_tools::ffprobe_path();
    let ffmpeg_path = crate::media_tools::ffmpeg_path();
    let has_ffprobe = std::process::Command::new(&ffprobe_path)
        .arg("-version")
        .output()
        .is_ok();
    let has_ffmpeg = std::process::Command::new(&ffmpeg_path)
        .arg("-version")
        .output()
        .is_ok();
    if !has_ffprobe {
        tracing::warn!(
            "ffprobe not found in PATH. Video metadata (duration/size/rotation) may be missing. See cmdtools.md for install instructions."
        );
    } else if let Some(v) = tool_version(&ffprobe_path, &["-version"]) {
        let first = v.lines().next().unwrap_or("");
        tracing::info!("ffprobe detected at {}: {}", ffprobe_path.display(), first);
    }
    if !has_ffmpeg {
        tracing::warn!(
            "ffmpeg not found in PATH. Video poster extraction, HEIC fallback decode, and Live Photo remux may fail. See cmdtools.md for install instructions."
        );
    } else if let Some(v) = tool_version(&ffmpeg_path, &["-version"]) {
        let first = v.lines().next().unwrap_or("");
        tracing::info!("ffmpeg detected at {}: {}", ffmpeg_path.display(), first);
    }

    // Use the default ClipConfig which is now configured for M-CLIP
    let default_config = ClipConfig::default();
    let model_configs = vec![ClipConfig {
        model_name: default_config.model_name.clone(),
        model_path: args.model_path.clone(),
        image_size: default_config.image_size,
        embedding_dim: default_config.embedding_dim,
        visual_embedding_dim: default_config.visual_embedding_dim,
        mean: default_config.mean.clone(),
        std: default_config.std.clone(),
        is_multilingual: default_config.is_multilingual,
        supported_languages: default_config.supported_languages.clone(),
        model_type: default_config.model_type,
    }];

    // Initialize application state
    let state = Arc::new(
        AppState::new(&args.database, model_configs.clone(), ai_config.clone())
            .await
            .unwrap_or_else(|e| {
                // Attempt an automatic one-time repair for common FK issues, then retry once
                tracing::warn!("[STARTUP] AppState init failed: {}", e);
                tracing::warn!("[STARTUP] Trying automatic DB repair and retry");
                let data_dir = std::path::Path::new(&args.database);
                if let Err(re) =
                    crate::database::multi_tenant::MultiTenantDatabase::repair_data_dir(data_dir)
                {
                    tracing::error!("[STARTUP] Auto-repair failed: {}", re);
                    panic!(
                        "Failed to initialize application state (repair failed): {}",
                        e
                    );
                }
                futures::executor::block_on(AppState::new(
                    &args.database,
                    model_configs.clone(),
                    ai_config.clone(),
                ))
                .expect("Failed to initialize application state after repair")
            }),
    );

    if demo_mode_enabled() {
        info!("[DEMO] demo mode enabled; ensuring demo account");
        ensure_demo_user(state.as_ref()).await?;
    } else {
        info!("[DEMO] demo mode disabled");
    }

    // Background text-search incremental sync for all users (lightweight loop)
    {
        let state_sync = Arc::clone(&state);
        tokio::spawn(async move {
            use std::time::Duration;
            let mut interval = tokio::time::interval(Duration::from_secs(120));
            loop {
                interval.tick().await;
                // Enumerate users (keep DB guard out of any await)
                let user_ids: Vec<String> = if let Some(pg) = &state_sync.pg_client {
                    if let Ok(rows) = pg
                        .query("SELECT user_id FROM users WHERE status='active'", &[])
                        .await
                    {
                        rows.into_iter().map(|r| r.get::<_, String>(0)).collect()
                    } else {
                        Vec::new()
                    }
                } else {
                    let users_db = state_sync
                        .multi_tenant_db
                        .as_ref()
                        .expect("users DB required in DuckDB mode")
                        .users_connection();
                    let conn = users_db.lock();
                    let mut ids: Vec<String> = Vec::new();
                    if let Ok(mut stmt) =
                        conn.prepare("SELECT user_id FROM users WHERE status = 'active'")
                    {
                        if let Ok(rows) = stmt.query_map([], |row| row.get::<_, String>(0)) {
                            for r in rows {
                                if let Ok(u) = r {
                                    ids.push(u);
                                }
                            }
                        }
                    }
                    ids
                };
                for uid in user_ids {
                    let st = Arc::clone(&state_sync);
                    // Run sync in blocking task to avoid stalling reactor
                    let _ = tokio::task::spawn_blocking(move || {
                        match text_search::sync_user(&st, &uid, 2000) {
                            Ok(n) => {
                                if n > 0 {
                                    // tracing::info!("[SEARCH] synced {} docs for user {}", n, uid);
                                }
                            }
                            Err(e) => tracing::warn!("[SEARCH] sync_user error for {}: {}", uid, e),
                        }
                    })
                    .await;
                }
            }
        });
    }

    // Background trash auto-purge loop
    {
        let purge_state = Arc::clone(&state);
        tokio::spawn(async move {
            use std::time::Duration;
            let mut interval = tokio::time::interval(Duration::from_secs(24 * 3600));
            loop {
                interval.tick().await;
                let user_settings: Vec<(String, i64)> = if let Some(pg) = &purge_state.pg_client {
                    if let Ok(rows) = pg
                        .query(
                            "SELECT user_id, COALESCE(trash_auto_purge_days, 0)::bigint FROM users WHERE status='active'",
                            &[],
                        )
                        .await
                    {
                        rows.into_iter()
                            .map(|r| (r.get::<_, String>(0), r.get::<_, i64>(1)))
                            .collect()
                    } else {
                        Vec::new()
                    }
                } else {
                    let users_db = purge_state
                        .multi_tenant_db
                        .as_ref()
                        .expect("users DB required in DuckDB mode")
                        .users_connection();
                    let conn = users_db.lock();
                    let mut rows = Vec::new();
                    if let Ok(mut stmt) = conn.prepare(
                        "SELECT user_id, COALESCE(trash_auto_purge_days, 0) FROM users WHERE status = 'active'",
                    ) {
                        if let Ok(iter) = stmt.query_map([], |row| {
                            Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
                        }) {
                            for r in iter {
                                if let Ok(pair) = r {
                                    rows.push(pair);
                                }
                            }
                        }
                    }
                    rows
                };

                let now = chrono::Utc::now().timestamp();
                for (uid, days) in user_settings {
                    if days <= 0 {
                        continue;
                    }
                    let cutoff = now - (days * 86_400);
                    let st_for_query = Arc::clone(&purge_state);
                    let uid_clone = uid.clone();
                    let assets = match tokio::task::spawn_blocking(move || {
                        let mut ids = Vec::new();
                        if let Some(pg) = &st_for_query.pg_client {
                            if let Ok(rows) = futures::executor::block_on(pg.query(
                                "SELECT asset_id FROM photos WHERE COALESCE(delete_time,0) > 0 AND delete_time <= $1",
                                &[&cutoff],
                            )) {
                                for r in rows {
                                    ids.push(r.get::<_, String>(0));
                                }
                            }
                        } else if let Ok(db) = st_for_query.get_user_data_database(&uid_clone) {
                            let conn = db.lock();
                            if let Ok(mut stmt) = conn.prepare("SELECT asset_id FROM photos WHERE COALESCE(delete_time,0) > 0 AND delete_time <= ?") {
                                if let Ok(iter) = stmt.query_map([cutoff], |row| row.get::<_, String>(0)) {
                                    for r in iter {
                                        if let Ok(a) = r { ids.push(a); }
                                    }
                                }
                            }
                        }
                        ids
                    }).await {
                        Ok(list) => list,
                        Err(_) => Vec::new(),
                    };

                    if assets.is_empty() {
                        continue;
                    }
                    if let Err(e) = hard_delete_assets(purge_state.as_ref(), &uid, &assets) {
                        tracing::warn!("[TRASH] auto-purge failed for user {}: {}", uid, e);
                    } else {
                        tracing::info!(
                            "[TRASH] auto-purged {} items for user {}",
                            assets.len(),
                            uid
                        );
                    }
                }
            }
        });
    }

    // Create router
    let app = create_router(state).layer(cors_layer());

    // Parse address
    let addr: SocketAddr = args.address.parse()?;

    info!("CLIP service listening on {}", addr);
    info!("Health check: http://{}/ping", addr);
    info!("Predict endpoint: http://{}/predict", addr);

    // Start server
    let listener = tokio::net::TcpListener::bind(addr).await?;
    axum::serve(listener, app).await?;

    Ok(())
}
