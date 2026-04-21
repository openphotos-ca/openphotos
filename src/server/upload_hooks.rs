use axum::extract::Query;
use axum::{
    extract::State,
    http::{header, HeaderMap, StatusCode},
    response::{
        sse::{Event, Sse},
        IntoResponse,
    },
    Json,
};
use futures::StreamExt;
use serde::Deserialize;
use serde::Serialize;
use serde_json::Value;
use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;
use tokio::time::{self, Duration};
use tokio_stream::{wrappers::BroadcastStream, wrappers::IntervalStream};

use crate::auth::types::User;
use crate::server::deleted_upload_tombstones::find_deleted_upload_match;
use crate::server::state::AppState;
use crate::server::text_search::reindex_single_asset;
#[cfg(feature = "ee")]
use bcrypt::verify as bcrypt_verify;
use chrono::Datelike;

// Helper macro to log database errors
macro_rules! log_db_error {
    ($result:expr, $context:expr) => {
        if let Err(e) = $result {
            tracing::error!(target: "upload", "[DB-ERROR] {}: {:?}", $context, e);
        }
    };
}

#[derive(Debug, Deserialize)]
pub struct RustusFileInfo {
    pub id: String,
    pub offset: usize,
    pub length: Option<usize>,
    pub path: Option<String>,
    pub is_final: bool,
    pub is_partial: bool,
    pub metadata: HashMap<String, String>,
    pub storage: String,
}

#[derive(Debug, Deserialize)]
pub struct RustusHookRequestV2 {
    pub upload: RustusFileInfo,
    pub request: Value,
}

async fn cleanup_skipped_upload_artifacts(src_path: &Path) {
    let _ = tokio::fs::remove_file(src_path).await;
    let sidecar = src_path.with_extension("info");
    let _ = tokio::fs::remove_file(sidecar).await;
}

async fn compute_backup_id_for_path(path: &Path, user_id: &str) -> Option<String> {
    let src = path.to_path_buf();
    let uid = user_id.to_string();
    tokio::task::spawn_blocking(move || {
        let bytes = std::fs::read(src).ok()?;
        crate::photos::backup_id::from_bytes(&bytes, &uid).ok()
    })
    .await
    .ok()
    .flatten()
}

fn upload_metadata_value(
    metadata: Option<&HashMap<String, String>>,
    keys: &[&str],
) -> Option<String> {
    metadata.and_then(|map| {
        keys.iter().find_map(|key| {
            map.get(*key)
                .map(|value| value.trim())
                .filter(|value| !value.is_empty())
                .map(str::to_owned)
        })
    })
}

fn emit_upload_ingested_event(
    state: &Arc<AppState>,
    user_id: &str,
    asset_id: &str,
    path: &Path,
    metadata: Option<&HashMap<String, String>>,
) {
    let tx = state.get_or_create_upload_channel(user_id);
    let content_id = upload_metadata_value(metadata, &["content_id", "contentId", "content-id"]);
    let backup_id = upload_metadata_value(metadata, &["backup_id", "backupId", "backup-id"]);
    let _ = tx.send(
        serde_json::json!({
            "type": "upload_ingested",
            "user_id": user_id,
            "asset_id": asset_id,
            "content_id": content_id,
            "backup_id": backup_id,
            "path": path.to_string_lossy(),
            "ts": chrono::Utc::now().timestamp()
        })
        .to_string(),
    );
}

#[derive(Debug, Deserialize)]
pub struct UploadsIngestedRequest {
    #[serde(default)]
    pub content_ids: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct UploadsIngestedResponse {
    pub ingested_content_ids: Vec<String>,
}

pub async fn handle_rustus_hook(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(payload): Json<RustusHookRequestV2>,
) -> (StatusCode, String) {
    let hook_name = headers
        .get("Hook-Name")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_string();

    match hook_name.as_str() {
        // Authorization gate before upload is created
        "pre-create" => {
            // Allow either authenticated user OR valid public-link context (EE)
            let auth_ok = auth_user_from_hook_context(&headers, &payload.request, &state)
                .await
                .is_ok();
            if auth_ok {
                return (StatusCode::OK, "ok".into());
            }
            #[cfg(feature = "ee")]
            {
                let meta = &payload.upload.metadata;
                let link_id = meta.get("public_link_id");
                let key = meta.get("public_link_key");
                let pin = meta.get("public_link_pin");
                if let (Some(lid), Some(k)) = (link_id, key) {
                    if verify_public_link_for_upload(
                        &state,
                        lid.as_str(),
                        k.as_str(),
                        pin.as_deref().map(|x| x.as_str()),
                    )
                    .is_some()
                    {
                        return (StatusCode::OK, "ok".into());
                    }
                }
            }
            (StatusCode::UNAUTHORIZED, "unauthorized".into())
        }
        // Upload finished — schedule ingestion (best-effort)
        "post-finish" => {
            let headers_clone = headers.clone();
            let state_clone = state.clone();
            let info = payload.upload;
            let payload_req = payload.request;
            // Log a sample of metadata values (caption, description) for diagnostics
            if !info.metadata.is_empty() {
                let cap = info.metadata.get("caption").cloned().unwrap_or_default();
                let desc = info
                    .metadata
                    .get("description")
                    .cloned()
                    .unwrap_or_default();
                let fav = info.metadata.get("favorite").cloned().unwrap_or_default();
                let created = info.metadata.get("created_at").cloned().unwrap_or_default();
                let trunc = |s: String| -> String {
                    let mut t = s;
                    if t.len() > 200 {
                        t.truncate(200);
                        t.push_str("…");
                    }
                    t
                };
                tracing::info!(target: "upload", "[UPLOAD] metadata sample: caption='{}' description='{}' favorite='{}' created_at='{}'",
                    trunc(cap), trunc(desc), fav, created);
                // Also preview common filename fields to aid debugging missing values
                let fname = info.metadata.get("filename").cloned().unwrap_or_default();
                let name = info.metadata.get("name").cloned().unwrap_or_default();
                let rpath = info
                    .metadata
                    .get("relativePath")
                    .cloned()
                    .unwrap_or_default();
                let mtype = info.metadata.get("type").cloned().unwrap_or_default();
                let ftype = info.metadata.get("filetype").cloned().unwrap_or_default();
                tracing::info!(target: "upload", "[UPLOAD] metadata names: filename='{}' name='{}' rel='{}' type='{}' filetype='{}'",
                    trunc(fname), trunc(name), trunc(rpath), mtype, ftype);
                // Also log crypto/locked context when present
                if let Some(kind) = info.metadata.get("kind") {
                    let asset_id_b58 = info
                        .metadata
                        .get("asset_id_b58")
                        .cloned()
                        .unwrap_or_default();
                    let locked = info
                        .metadata
                        .get("locked")
                        .map(|v| {
                            v.trim().eq_ignore_ascii_case("1")
                                || v.trim().eq_ignore_ascii_case("true")
                        })
                        .unwrap_or(false);
                    tracing::info!(target: "upload", "[UPLOAD] locked={} kind='{}' asset_id_b58='{}'", locked, kind, asset_id_b58);
                }
            }
            // Ignore concatenation parts only; treat non-partials as complete regardless of is_final flag.
            if info.is_partial {
                tracing::info!(
                    target: "upload",
                    "[UPLOAD] ignoring partial/non-final post-finish (upload_id={}, is_final={}, is_partial={}, storage={})",
                    info.id,
                    info.is_final,
                    info.is_partial,
                    info.storage
                );
                return (StatusCode::OK, "ok".into());
            }
            // Require a valid path
            if info.path.is_none() {
                tracing::warn!(target:"upload", "[UPLOAD] post-finish missing path for id={} (storage={})", info.id, info.storage);
                return (StatusCode::OK, "ok".into());
            }
            let idempotency_key = headers
                .get("Idempotency-Key")
                .and_then(|v| v.to_str().ok())
                .map(|s| s.to_string());
            // Spawn non-blocking task for ingestion; return 200 immediately
            tokio::spawn(async move {
                let cached_owner_uid = state_clone.tus_upload_owner(info.id.as_str());
                // Identify user (auth) or resolve via public link (EE)
                // Defaults
                let mut resolved_user_id: Option<String> = None;
                let mut forced_album_id: Option<i32> = None;

                // IMPORTANT: Check for public_link_id FIRST before trying regular auth
                // This ensures lazy album creation works even when user is logged in
                #[cfg(feature = "ee")]
                let mut is_public_link_upload = false;

                #[cfg(feature = "ee")]
                {
                    let meta = &info.metadata;
                    let link_id = meta.get("public_link_id");
                    let key = meta.get("public_link_key");
                    let pin = meta.get("public_link_pin");
                    tracing::info!(
                        target = "upload",
                        "[PUBLIC-LINK-CHECK] link_id={:?}, key_present={}",
                        link_id,
                        key.is_some()
                    );
                    if let (Some(lid), Some(k)) = (link_id, key) {
                        tracing::info!(
                            target = "upload",
                            "[PUBLIC-LINK] Verifying public link upload: link_id={}",
                            lid
                        );
                        if let Some((owner_uid, uploads_album_id)) = verify_public_link_for_upload(
                            &state_clone,
                            lid.as_str(),
                            k.as_str(),
                            pin.as_deref().map(|x| x.as_str()),
                        ) {
                            tracing::info!(
                                target = "upload",
                                "[PUBLIC-LINK] Verified! owner_uid={}, uploads_album_id={:?}",
                                owner_uid,
                                uploads_album_id
                            );
                            resolved_user_id = Some(owner_uid.clone());
                            forced_album_id = uploads_album_id;
                            is_public_link_upload = true;
                            // Lazily create uploads album if missing
                            tracing::info!(target = "upload", "[PUBLIC-LINK] Checking if lazy creation needed: forced_album_id={:?}", forced_album_id);
                            if forced_album_id.is_none() {
                                tracing::info!(
                                    target = "upload",
                                    "[PUBLIC-LINK] Starting lazy album creation for link {}",
                                    lid
                                );
                                let users_db = state_clone
                                    .multi_tenant_db
                                    .as_ref()
                                    .expect("users DB required in DuckDB mode")
                                    .users_connection();
                                let conn = users_db.lock();
                                log_db_error!(
                                    conn.execute(
                                        "CREATE TABLE IF NOT EXISTS ee_public_links (
                                            id TEXT PRIMARY KEY,
                                            owner_org_id INTEGER,
                                            owner_user_id TEXT,
                                            name TEXT,
                                            scope_kind VARCHAR,
                                            scope_album_id INTEGER,
                                            uploads_album_id INTEGER,
                                            key_hash TEXT,
                                            key_plain TEXT,
                                            pin_hash TEXT,
                                            permissions INTEGER,
                                            expires_at TIMESTAMP,
                                            status VARCHAR DEFAULT 'active',
                                            cover_asset_id TEXT,
                                            moderation_enabled BOOLEAN DEFAULT FALSE,
                                            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                                            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                                        )",
                                        [],
                                    ),
                                    "CREATE TABLE ee_public_links in users DB"
                                );
                                let link_name: Option<String> = conn
                                    .prepare(
                                        "SELECT name FROM ee_public_links WHERE id = ? LIMIT 1",
                                    )
                                    .ok()
                                    .and_then(|mut s| {
                                        s.query_row(duckdb::params![lid.as_str()], |r| {
                                            r.get::<_, String>(0)
                                        })
                                        .ok()
                                    });
                                drop(conn);
                                if let Some(link_name) = link_name {
                                    let uploads_name = format!("Uploads from {}", link_name);
                                    tracing::info!(
                                        target = "upload",
                                        "[PUBLIC-LINK] Creating album with name: {}",
                                        uploads_name
                                    );
                                    // Get organization_id for the owner user BEFORE acquiring any locks
                                    let owner_org_id = state_clone.org_id_for_user(&owner_uid);
                                    // Create album in owner's DB
                                    if let Ok(mut odb) = state_clone
                                        .multi_tenant_db
                                        .as_ref()
                                        .expect("users DB required in DuckDB mode")
                                        .get_user_data_database(&owner_uid)
                                    {
                                        let odb = odb.lock();
                                        log_db_error!(
                                                odb.execute("ALTER TABLE albums ADD COLUMN IF NOT EXISTS name_lc TEXT", []),
                                                "ALTER TABLE albums ADD name_lc column"
                                            );
                                        // Use Unix timestamp in SECONDS (not milliseconds) as INTEGER
                                        let now = chrono::Utc::now().timestamp(); // Returns i64 seconds since epoch
                                        let insert_result = odb.execute(
                                                "INSERT INTO albums (organization_id, user_id, name, name_lc, description, parent_id, position, is_live, live_criteria, deleted_at, created_at, updated_at)
                                                 VALUES (?, ?, ?, lower(?), NULL, NULL, COALESCE((SELECT MAX(position)+1 FROM albums WHERE organization_id = ? AND parent_id IS NULL),1), FALSE, NULL, NULL, ?, ?)",
                                                duckdb::params![owner_org_id, owner_uid.as_str(), uploads_name.as_str(), uploads_name.as_str(), owner_org_id, now, now],
                                            );
                                        tracing::info!(
                                            target = "upload",
                                            "[PUBLIC-LINK] Album INSERT result: {:?}",
                                            insert_result
                                        );

                                        // Query back the album ID using the unique constraint (organization_id, parent_id, name_lc)
                                        let new_album_id: Option<i32> = if insert_result.is_ok() {
                                            let id_result = odb.query_row(
                                                    "SELECT id FROM albums WHERE organization_id = ? AND parent_id IS NULL AND name_lc = lower(?) LIMIT 1",
                                                    duckdb::params![owner_org_id, uploads_name.as_str()],
                                                    |row| row.get::<_, i32>(0)
                                                );
                                            tracing::info!(
                                                target = "upload",
                                                "[PUBLIC-LINK] Query album ID result: {:?}",
                                                id_result
                                            );
                                            id_result.ok()
                                        } else {
                                            tracing::error!(
                                                target = "upload",
                                                "[PUBLIC-LINK] Album INSERT failed: {:?}",
                                                insert_result.err()
                                            );
                                            None
                                        };
                                        tracing::info!(
                                            target = "upload",
                                            "[PUBLIC-LINK] Final new_album_id: {:?}",
                                            new_album_id
                                        );
                                        drop(odb);
                                        if let Some(aid) = new_album_id {
                                            // Persist back to users DB
                                            let users_db2 = state_clone
                                                .multi_tenant_db
                                                .as_ref()
                                                .expect("users DB required in DuckDB mode")
                                                .users_connection();
                                            let conn2 = users_db2.lock();
                                            log_db_error!(
                                                    conn2.execute("UPDATE ee_public_links SET uploads_album_id = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?", duckdb::params![aid, lid.as_str()]),
                                                    format!("Failed to update uploads_album_id for link {}", lid)
                                                );
                                            log_db_error!(
                                                conn2.execute("CHECKPOINT;", []),
                                                "Failed to checkpoint after updating public link"
                                            );
                                            drop(conn2);
                                            forced_album_id = Some(aid);
                                            tracing::info!(target = "upload", "[PUBLIC-MOD] lazily created uploads album {} for link {}", aid, lid);
                                        } else {
                                            tracing::warn!(target = "upload", "[PUBLIC-LINK] Failed to get new_album_id after INSERT");
                                        }
                                    } else {
                                        tracing::warn!(target = "upload", "[PUBLIC-LINK] Failed to get owner's data database for user {}", owner_uid);
                                    }
                                } else {
                                    tracing::warn!(target = "upload", "[PUBLIC-LINK] Failed to get link_name from database for link {}", lid);
                                }
                            } else {
                                tracing::info!(
                                    target = "upload",
                                    "[PUBLIC-LINK] Album already exists: forced_album_id={:?}",
                                    forced_album_id
                                );
                            }
                        } else {
                            tracing::warn!(
                                target = "upload",
                                "[PUBLIC-LINK] Failed to verify public link for link_id={}",
                                lid.as_str()
                            );
                        }
                    } else {
                        tracing::info!(
                            target = "upload",
                            "[PUBLIC-LINK-CHECK] No valid link_id or key in metadata"
                        );
                    }
                }

                // Fallback to regular authentication if NOT a public link upload
                #[cfg(feature = "ee")]
                if !is_public_link_upload {
                    if let Ok(user) =
                        auth_user_from_hook_context(&headers_clone, &payload_req, &state_clone)
                            .await
                    {
                        resolved_user_id = Some(user.user_id);
                    }
                }

                #[cfg(not(feature = "ee"))]
                if let Ok(user) =
                    auth_user_from_hook_context(&headers_clone, &payload_req, &state_clone).await
                {
                    resolved_user_id = Some(user.user_id);
                }

                if resolved_user_id.is_none() {
                    if let Some(owner_uid) = cached_owner_uid.clone() {
                        tracing::info!(
                            target: "upload",
                            "[UPLOAD] post-finish recovered owner from cached TUS context: user_id={}, upload_id={}",
                            owner_uid,
                            info.id
                        );
                        resolved_user_id = Some(owner_uid);
                    }
                }

                if let Some(owner_uid) = resolved_user_id {
                    if let Some(path) = info.path.as_ref() {
                        tracing::info!(
                            target: "upload",
                            "[UPLOAD] post-finish received: user_id={}, upload_id={}, path={}, metadata_keys={:?}",
                            owner_uid,
                            info.id,
                            path,
                            info.metadata.keys().collect::<Vec<_>>()
                        );
                        // Merge metadata and inject albumId for public links when available
                        let mut md = info.metadata.clone();
                        if forced_album_id.is_some()
                            && md.get("albumId").is_none()
                            && md.get("album_id").is_none()
                        {
                            md.insert("albumId".to_string(), forced_album_id.unwrap().to_string());
                        }
                        if let Err(e) = ingest_finished_upload(
                            &state_clone,
                            &owner_uid,
                            info.id.as_str(),
                            idempotency_key.as_deref(),
                            Path::new(path),
                            Some(md),
                            Some("tus"),
                        )
                        .await
                        {
                            let pg_mode = state_clone.pg_client.is_some();
                            tracing::warn!(
                                "[UPLOAD] post-finish ingestion failed (user={}, file_id={}, path={}, pg_mode={}): {}",
                                owner_uid,
                                info.id,
                                path,
                                pg_mode,
                                e
                            );
                            // Record a failure for sync stats
                            state_clone.record_sync_failure(&owner_uid);
                        } else {
                            tracing::info!(
                                target: "upload",
                                "[UPLOAD] post-finish ingestion completed: user_id={}, upload_id={}",
                                owner_uid,
                                info.id
                            );
                        }
                        let _ = state_clone.take_tus_upload_owner(info.id.as_str());
                    } else {
                        tracing::warn!(
                            "[UPLOAD] post-finish missing path for id={} (storage={})",
                            info.id,
                            info.storage
                        );
                        let _ = state_clone.take_tus_upload_owner(info.id.as_str());
                    }
                } else {
                    tracing::warn!(
                        "[UPLOAD] post-finish without valid auth or cached owner (upload_id={})",
                        info.id
                    );
                }
            });
            (StatusCode::OK, "ok".into())
        }
        // Other hooks: accept and noop for now
        _ => (StatusCode::OK, "ok".into()),
    }
}

async fn auth_user_from_headers(
    headers: &HeaderMap,
    state: &Arc<AppState>,
) -> Result<User, anyhow::Error> {
    // Try Authorization header first
    if let Some(token) = headers
        .get(header::AUTHORIZATION)
        .and_then(|h| h.to_str().ok())
        .and_then(|h| h.strip_prefix("Bearer "))
    {
        let user = state.auth_service.verify_token(token).await?;
        return Ok(user);
    }
    // Fallback: try Cookie header for 'auth-token'
    if let Some(cookie_hdr) = headers.get(header::COOKIE).and_then(|v| v.to_str().ok()) {
        for part in cookie_hdr.split(';') {
            let trimmed = part.trim();
            if let Some(val) = trimmed.strip_prefix("auth-token=") {
                let user = state.auth_service.verify_token(val).await?;
                return Ok(user);
            }
        }
    }
    Err(anyhow::anyhow!("Missing authorization token"))
}

fn hook_request_header(payload_request: &Value, header_name: &str) -> Option<String> {
    let headers_obj = payload_request.get("headers")?.as_object()?;
    let (_, raw_val) = headers_obj
        .iter()
        .find(|(k, _)| k.eq_ignore_ascii_case(header_name))?;
    match raw_val {
        Value::String(s) => Some(s.clone()),
        Value::Array(arr) => arr.iter().find_map(|v| v.as_str().map(|s| s.to_string())),
        _ => None,
    }
}

fn bearer_token_from_value(header_value: &str) -> Option<&str> {
    let trimmed = header_value.trim();
    let (scheme, token) = trimmed.split_once(' ')?;
    if scheme.eq_ignore_ascii_case("bearer") && !token.trim().is_empty() {
        Some(token.trim())
    } else {
        None
    }
}

async fn auth_user_from_hook_context(
    headers: &HeaderMap,
    payload_request: &Value,
    state: &Arc<AppState>,
) -> Result<User, anyhow::Error> {
    if let Ok(user) = auth_user_from_headers(headers, state).await {
        return Ok(user);
    }

    // Rustus v2 payload includes original request headers; use them as fallback.
    if let Some(authz) = hook_request_header(payload_request, "Authorization") {
        if let Some(token) = bearer_token_from_value(&authz) {
            let user = state.auth_service.verify_token(token).await?;
            return Ok(user);
        }
    }

    if let Some(cookie_hdr) = hook_request_header(payload_request, "Cookie") {
        for part in cookie_hdr.split(';') {
            let trimmed = part.trim();
            if let Some(val) = trimmed.strip_prefix("auth-token=") {
                let user = state.auth_service.verify_token(val).await?;
                return Ok(user);
            }
        }
    }

    Err(anyhow::anyhow!(
        "Missing authorization token in hook headers and payload request headers"
    ))
}

pub(crate) async fn ingest_finished_upload(
    state: &Arc<AppState>,
    user_id: &str,
    upload_id: &str,
    idempotency_key: Option<&str>,
    src_path: &Path,
    metadata: Option<HashMap<String, String>>,
    source_method: Option<&str>,
) -> anyhow::Result<()> {
    // Global ingestion concurrency guard to prevent resource exhaustion/segfaults under load
    tracing::info!(
        target = "upload",
        "[INGEST] waiting semaphore user={} upload_id={}",
        user_id,
        upload_id
    );
    let _permit = state
        .ingest_semaphore
        .clone()
        .acquire_owned()
        .await
        .expect("ingest semaphore");
    tracing::info!(
        target = "upload",
        "[INGEST] acquired semaphore user={} upload_id={}",
        user_id,
        upload_id
    );
    use crate::video::is_video_extension;
    use std::fs;

    // Resolve organization id for this user
    let org_id: i32 = state.org_id_for_user(user_id);

    // Idempotency guard: record (upload_id, post-finish, idempotency_key)
    if let Some(pg) = &state.pg_client {
        let _ = pg
            .execute(
                "CREATE TABLE IF NOT EXISTS upload_events (
                    organization_id INTEGER NOT NULL,
                    user_id TEXT NOT NULL,
                    upload_id TEXT NOT NULL,
                    hook_name TEXT NOT NULL,
                    idempotency_key TEXT,
                    seen_at BIGINT,
                    PRIMARY KEY (organization_id, upload_id, hook_name)
                )",
                &[],
            )
            .await;
        let now = chrono::Utc::now().timestamp();
        let idk = idempotency_key.unwrap_or("");
        let rows = pg
            .execute(
                "INSERT INTO upload_events(organization_id, user_id, upload_id, hook_name, idempotency_key, seen_at)
                 VALUES ($1,$2,$3,'post-finish',$4,$5)
                 ON CONFLICT (organization_id, upload_id, hook_name) DO NOTHING",
                &[&org_id, &user_id, &upload_id, &idk, &now],
            )
            .await
            .unwrap_or(0);
        if rows == 0 {
            tracing::info!(target: "upload", "[UPLOAD] duplicate post-finish ignored (user={}, upload_id={}, idk={})", user_id, upload_id, idk);
            return Ok(());
        }
        tracing::info!(target: "upload", "[UPLOAD] idempotency recorded (user={}, upload_id={}, idk={})", user_id, upload_id, idk);
    } else {
        let data_db = state.get_user_data_database(user_id)?;
        {
            let conn = data_db.lock();
            let _ = conn.execute(
                "CREATE TABLE IF NOT EXISTS upload_events (upload_id TEXT, hook_name TEXT, idempotency_key TEXT, seen_at INTEGER)",
                [],
            );
            let _ = conn.execute(
                "CREATE UNIQUE INDEX IF NOT EXISTS upload_events_uniq ON upload_events(upload_id, hook_name)",
                [],
            );
            let now = chrono::Utc::now().timestamp();
            let idk = idempotency_key.unwrap_or("");
            let rows = conn.execute(
                "INSERT INTO upload_events(upload_id, hook_name, idempotency_key, seen_at) VALUES (?, 'post-finish', ?, ?) ON CONFLICT (upload_id, hook_name) DO NOTHING",
                duckdb::params![upload_id, idk, now],
            )?;
            if rows == 0 {
                tracing::info!(target: "upload", "[UPLOAD] duplicate post-finish ignored (user={}, upload_id={}, idk={})", user_id, upload_id, idk);
                return Ok(());
            }
            tracing::info!(target: "upload", "[UPLOAD] idempotency recorded (user={}, upload_id={}, idk={})", user_id, upload_id, idk);
        }
    }

    // Helper: ensure schema supports case-insensitive uniqueness for albums
    fn ensure_album_ci_schema(conn: &duckdb::Connection) {
        log_db_error!(
            conn.execute(
                "ALTER TABLE albums ADD COLUMN IF NOT EXISTS name_lc TEXT",
                []
            ),
            "ensure_album_ci_schema: ALTER TABLE albums ADD name_lc"
        );
        log_db_error!(
            conn.execute(
                "UPDATE albums SET name_lc = lower(name) WHERE name_lc IS NULL",
                []
            ),
            "ensure_album_ci_schema: UPDATE albums SET name_lc"
        );
        // Unique index on (parent_id, name_lc) prevents different-case duplicates
        log_db_error!(
            conn.execute("CREATE UNIQUE INDEX IF NOT EXISTS albums_parent_name_ci ON albums(parent_id, name_lc)", []),
            "ensure_album_ci_schema: CREATE INDEX albums_parent_name_ci"
        );
    }

    // Helper: ensure nested album path exists (case-insensitive per segment) and return leaf album_id
    // Skips and returns None if any segment resolves to a live album (we only attach to manual albums)
    fn ensure_album_path(
        conn: &duckdb::Connection,
        names: &[String],
        organization_id: i32,
        owner_user_id: &str,
    ) -> anyhow::Result<Option<i32>> {
        ensure_album_ci_schema(conn);
        if names.is_empty() {
            return Ok(None);
        }
        let now = chrono::Utc::now().timestamp();
        let mut parent: Option<i32> = None;
        for raw in names {
            let name = raw.trim();
            if name.is_empty() {
                return Ok(None);
            }
            // Lookup existing by case-insensitive name under current parent
            let mut found_id: Option<i32> = None;
            let mut found_is_live: bool = false;
            if let Some(pid) = parent {
                if let Ok(mut stmt) = conn.prepare(
                    "SELECT id, COALESCE(is_live, FALSE) FROM albums WHERE organization_id = ? AND parent_id = ? AND name_lc = lower(?) LIMIT 1",
                ) {
                    let _ = stmt.query_row(duckdb::params![organization_id, pid, name], |row| {
                        found_id = Some(row.get::<_, i32>(0)?);
                        found_is_live = row.get::<_, bool>(1)?;
                        Ok(())
                    });
                }
            } else {
                if let Ok(mut stmt) = conn.prepare(
                    "SELECT id, COALESCE(is_live, FALSE) FROM albums WHERE organization_id = ? AND parent_id IS NULL AND name_lc = lower(?) LIMIT 1",
                ) {
                    let _ = stmt.query_row(duckdb::params![organization_id, name], |row| {
                        found_id = Some(row.get::<_, i32>(0)?);
                        found_is_live = row.get::<_, bool>(1)?;
                        Ok(())
                    });
                }
            }

            if let Some(id) = found_id {
                if found_is_live {
                    return Ok(None);
                }
                parent = Some(id);
                continue;
            }

            // Create new album under parent
            // Determine next position among siblings
            let next_pos: i64 = if let Some(pid) = parent {
                conn.query_row(
                    "SELECT COALESCE(MAX(position), 0) + 1 FROM albums WHERE organization_id = ? AND parent_id = ?",
                    duckdb::params![organization_id, pid],
                    |row| row.get::<_, i64>(0),
                )
                .unwrap_or(1)
            } else {
                conn.query_row(
                    "SELECT COALESCE(MAX(position), 0) + 1 FROM albums WHERE organization_id = ? AND parent_id IS NULL",
                    duckdb::params![organization_id],
                    |row| row.get::<_, i64>(0),
                )
                .unwrap_or(1)
            };

            // Insert row (set name_lc)
            let inserted = if let Some(pid) = parent {
                conn.execute(
                    "INSERT INTO albums (organization_id, user_id, name, name_lc, description, parent_id, position, is_live, live_criteria, deleted_at, created_at, updated_at) VALUES (?, ?, ?, lower(?), NULL, ?, ?, FALSE, NULL, NULL, ?, ?)",
                    duckdb::params![organization_id, owner_user_id, name, name, pid, next_pos, now, now],
                ).unwrap_or(0)
            } else {
                conn.execute(
                    "INSERT INTO albums (organization_id, user_id, name, name_lc, description, parent_id, position, is_live, live_criteria, deleted_at, created_at, updated_at) VALUES (?, ?, ?, lower(?), NULL, NULL, ?, FALSE, NULL, NULL, ?, ?)",
                    duckdb::params![organization_id, owner_user_id, name, name, next_pos, now, now],
                ).unwrap_or(0)
            };

            // Resolve id (unique on (parent_id, name))
            let new_id: i32 = if let Some(pid) = parent {
                conn.query_row(
                    "SELECT id FROM albums WHERE organization_id = ? AND parent_id = ? AND name_lc = lower(?) LIMIT 1",
                    duckdb::params![organization_id, pid, name],
                    |row| row.get::<_, i32>(0),
                )?
            } else {
                conn.query_row(
                    "SELECT id FROM albums WHERE organization_id = ? AND parent_id IS NULL AND name_lc = lower(?) LIMIT 1",
                    duckdb::params![organization_id, name],
                    |row| row.get::<_, i32>(0),
                )?
            };

            // Update closure table (self + inherit ancestors)
            log_db_error!(
                conn.execute(
                    "INSERT INTO album_closure (organization_id, ancestor_id, descendant_id, depth) VALUES (?, ?, ?, 0)",
                    duckdb::params![organization_id, new_id, new_id],
                ),
                format!("ensure_album_path: INSERT closure self for album {}", new_id)
            );
            if let Some(pid) = parent {
                log_db_error!(
                    conn.execute(
                        "INSERT INTO album_closure (organization_id, ancestor_id, descendant_id, depth)
                         SELECT organization_id, ancestor_id, ?, depth + 1 FROM album_closure WHERE organization_id = ? AND descendant_id = ?",
                        duckdb::params![new_id, organization_id, pid],
                    ),
                    format!("ensure_album_path: INSERT closure ancestors for album {}", new_id)
                );
            }
            parent = Some(new_id);
            let _ = inserted; // silence unused in some builds
        }
        Ok(parent)
    }

    // Helper: attach photo to album if album exists and is not live
    fn attach_photo_to_album(
        conn: &duckdb::Connection,
        organization_id: i32,
        album_id: i32,
        photo_id: i32,
    ) {
        // Verify album exists and is not live
        let mut ok = false;
        if let Ok(mut stmt) = conn.prepare(
            "SELECT COALESCE(is_live, FALSE) FROM albums WHERE organization_id = ? AND id = ? LIMIT 1",
        )
        {
            if let Ok(flag) = stmt.query_row(duckdb::params![organization_id, album_id], |row| row.get::<_, bool>(0))
            {
                if !flag {
                    ok = true;
                }
            }
        }
        if !ok {
            return;
        }
        let now = chrono::Utc::now().timestamp();
        log_db_error!(
            conn.execute(
                "INSERT INTO album_photos (organization_id, album_id, photo_id, added_at) VALUES (?, ?, ?, ?) ON CONFLICT (organization_id, album_id, photo_id) DO NOTHING",
                duckdb::params![organization_id, album_id, photo_id, now],
            ),
            format!("attach_photo_to_album: INSERT album_id={} photo_id={}", album_id, photo_id)
        );
        log_db_error!(
            conn.execute(
                "UPDATE albums SET updated_at = ? WHERE organization_id = ? AND id = ?",
                duckdb::params![now, organization_id, album_id],
            ),
            format!(
                "attach_photo_to_album: UPDATE album updated_at for album_id={}",
                album_id
            )
        );
    }

    // If this is a locked upload (E2EE container), take a dedicated ingestion path
    if let Some(meta) = metadata.as_ref() {
        let locked_flag = meta
            .get("locked")
            .map(|v| v.trim().to_ascii_lowercase())
            .map(|v| v == "1" || v == "true" || v == "yes")
            .unwrap_or(false);
        if locked_flag {
            return ingest_locked_upload(state, user_id, upload_id, src_path, meta).await;
        }
    }

    // Compute asset_id for canonical filename + SSE (unlocked/plain ingestion)
    let (computed_asset_id, _ext_from_src) = tokio::task::spawn_blocking({
        let src = src_path.to_path_buf();
        let uid = user_id.to_string();
        move || -> anyhow::Result<(String, String)> {
            let aid = crate::photos::asset_id::from_path(&src, &uid)?;
            let ext = src
                .extension()
                .and_then(|e| e.to_str())
                .unwrap_or("")
                .to_lowercase();
            Ok((aid, ext))
        }
    })
    .await??;

    let replace_requested = metadata
        .as_ref()
        .and_then(|m| m.get("replace"))
        .map(|v| v.trim().to_ascii_lowercase())
        .map(|v| v == "1" || v == "true" || v == "yes")
        .unwrap_or(false);

    let mut asset_id = computed_asset_id.clone();
    let mut forced_replace_asset_id: Option<String> = None;
    if replace_requested {
        let target_from_meta = meta_get(
            &metadata,
            &[
                "asset_id_b58",
                "replace_asset_id",
                "replace_asset_id_b58",
                "asset_id",
            ],
        );
        let target_from_filename = metadata
            .as_ref()
            .and_then(|m| m.get("filename"))
            .and_then(|name| std::path::Path::new(name).file_stem())
            .and_then(|stem| stem.to_str())
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty());
        let candidate = target_from_meta
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .or(target_from_filename);
        if let Some(target_asset_id) = candidate {
            let target_exists = if let Some(pg) = &state.pg_client {
                pg.query_opt(
                    "SELECT 1 FROM photos WHERE organization_id=$1 AND user_id=$2 AND asset_id=$3 LIMIT 1",
                    &[&org_id, &user_id, &target_asset_id],
                )
                .await
                .ok()
                .flatten()
                .is_some()
            } else {
                if let Ok(db) = state.get_user_data_database(user_id) {
                    let conn = db.lock();
                    conn.prepare(
                        "SELECT 1 FROM photos WHERE organization_id = ? AND user_id = ? AND asset_id = ? LIMIT 1",
                    )
                    .ok()
                    .and_then(|mut s| {
                        s.query_row(
                            duckdb::params![org_id, user_id, &target_asset_id],
                            |row| row.get::<_, i32>(0),
                        )
                        .ok()
                    })
                    .is_some()
                } else {
                    false
                }
            };
            if target_exists {
                tracing::info!(
                    target: "upload",
                    "[UPLOAD] replace target resolved (user={}, upload_id={}, computed_asset_id={}, target_asset_id={})",
                    user_id,
                    upload_id,
                    computed_asset_id,
                    target_asset_id
                );
                forced_replace_asset_id = Some(target_asset_id.clone());
                asset_id = target_asset_id;
            } else {
                tracing::warn!(
                    target: "upload",
                    "[UPLOAD] replace requested but target asset_id not found (user={}, upload_id={}, computed_asset_id={}, candidate={})",
                    user_id,
                    upload_id,
                    computed_asset_id,
                    target_asset_id
                );
            }
        } else {
            tracing::warn!(
                target: "upload",
                "[UPLOAD] replace requested but no target asset_id could be inferred (user={}, upload_id={}, computed_asset_id={})",
                user_id,
                upload_id,
                computed_asset_id
            );
        }
    }

    let upload_backup_id = if let Some(bid) = meta_get(&metadata, &["backup_id"]) {
        Some(bid)
    } else {
        compute_backup_id_for_path(src_path, user_id).await
    };
    if let Some(matched) = find_deleted_upload_match(
        state.as_ref(),
        org_id,
        user_id,
        Some(&asset_id),
        upload_backup_id.as_deref(),
    )
    .await?
    {
        tracing::info!(
            target: "upload",
            "[UPLOAD] skipped deleted/tombstoned upload user={} upload_id={} asset_id={} key_kind={} key_value={}",
            user_id,
            upload_id,
            asset_id,
            matched.key_kind,
            matched.key_value
        );
        cleanup_skipped_upload_artifacts(src_path).await;
        let skipped_ext = src_path
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("")
            .to_ascii_lowercase();
        state.record_sync_ingest(
            user_id,
            source_method.unwrap_or("unknown"),
            /*is_photo=*/ !crate::video::is_video_extension(&skipped_ext),
            /*duplicate=*/ true,
            /*success=*/ true,
        );
        return Ok(());
    }

    // Decide destination path if move_on_ingest is enabled
    let dest_path = if state.move_on_ingest {
        // Determine extension preference: from metadata filename -> from src -> fallback to 'bin'
        let ext_from_meta = metadata
            .as_ref()
            .and_then(|m| m.get("filename"))
            .and_then(|fname| {
                std::path::Path::new(fname)
                    .extension()
                    .and_then(|e| e.to_str())
            })
            .map(|s| s.to_lowercase());
        let ext = if let Some(x) = ext_from_meta.clone() {
            x
        } else if !_ext_from_src.is_empty() {
            _ext_from_src.clone()
        } else {
            "bin".to_string()
        };
        tracing::info!(
            target: "upload",
            "[UPLOAD] ext resolution (user={}, upload_id={}): from_meta={:?}, from_src={:?}, chosen={}",
            user_id,
            upload_id,
            ext_from_meta,
            _ext_from_src,
            ext
        );

        // Compute created_at for path: prefer client metadata (created_at),
        // else derive from EXIF/ffprobe of the temp file, else now.
        let mut created_ts = tokio::task::spawn_blocking({
            let src = src_path.to_path_buf();
            let user_id_cloned = user_id.to_string();
            move || -> i64 {
                use crate::photos::Photo as PhotoDto;
                let mut p = match PhotoDto::from_path(&src, &user_id_cloned) {
                    Ok(v) => v,
                    Err(_) => {
                        // Fallback to now
                        return chrono::Utc::now().timestamp();
                    }
                };
                // Guess video flag from extension
                let ext = src
                    .extension()
                    .and_then(|e| e.to_str())
                    .unwrap_or("")
                    .to_lowercase();
                let vid = crate::video::is_video_extension(&ext);
                p.is_video = vid;
                let _ = crate::photos::metadata::extract_metadata(&mut p);
                if p.created_at > 0 {
                    p.created_at
                } else {
                    chrono::Utc::now().timestamp()
                }
            }
        })
        .await
        .unwrap_or_else(|_| chrono::Utc::now().timestamp());

        // If client provided a created_at in metadata, prefer it for date placement
        if let Some(s) = meta_get(
            &metadata,
            &["created_at", "createdAt", "creation_ts", "creationTs"],
        ) {
            if let Ok(v) = s.parse::<i64>() {
                if v > 0 {
                    created_ts = v;
                }
            }
        }
        let dt = chrono::NaiveDateTime::from_timestamp_opt(created_ts, 0)
            .unwrap_or_else(|| chrono::Utc::now().naive_utc());
        let yyyy = format!("{:04}", dt.date().year());
        let mm = format!("{:02}", dt.date().month());
        let dd = format!("{:02}", dt.date().day());

        // Destination day directory under library root
        let day_dir = state
            .library_root
            .join(user_id)
            .join(yyyy)
            .join(mm)
            .join(dd);
        tokio::fs::create_dir_all(&day_dir).await.ok();

        // Determine original filename (sanitized); fallback to asset_id.ext
        let orig_name_raw = metadata
            .as_ref()
            .and_then(|m| m.get("filename"))
            .map(|s| s.as_str())
            .unwrap_or("");
        let sanitized = sanitize_filename_preserve_ext(orig_name_raw, &ext, &asset_id);

        // Early first-wins dedupe by existing DB path for this asset_id.
        // IMPORTANT: do not reuse existing file path for explicit replacements (`replace=1`),
        // otherwise unlock flows can accidentally reuse a locked `.pae3` path and fail decode.
        let mut reuse_existing: Option<std::path::PathBuf> = None;
        if !replace_requested {
            if let Some(pg) = &state.pg_client {
                if let Ok(row) = pg
                    .query_opt(
                        "SELECT path FROM photos WHERE organization_id=$1 AND user_id=$2 AND asset_id=$3 LIMIT 1",
                        &[&org_id, &user_id, &asset_id],
                    )
                    .await
                {
                    if let Some(r) = row {
                        let p: String = r.get(0);
                        let pb = std::path::PathBuf::from(&p);
                        if pb.is_file() {
                            reuse_existing = Some(pb);
                        }
                    }
                }
            } else {
                if let Ok(db) = state.get_user_data_database(user_id) {
                    let conn = db.lock();
                    if let Ok(mut s) =
                        conn.prepare("SELECT path FROM photos WHERE organization_id = ? AND user_id = ? AND asset_id = ? LIMIT 1")
                    {
                        if let Ok(p) =
                            s.query_row(duckdb::params![org_id, user_id, &asset_id], |row| row.get::<_, String>(0))
                        {
                            let pb = std::path::PathBuf::from(&p);
                            if pb.is_file() {
                                reuse_existing = Some(pb);
                            }
                        }
                    }
                }
            }
        } else {
            tracing::info!(
                target: "upload",
                "[UPLOAD] replace requested; bypassing existing-path reuse for asset {}",
                asset_id
            );
        }
        if let Some(existing) = reuse_existing {
            let _ = tokio::fs::remove_file(src_path).await;
            tracing::info!(
                target:"upload",
                "[UPLOAD] reused existing asset file for {} at {} (first-wins)",
                asset_id,
                existing.display()
            );
            existing
        } else {
            // Build unique destination filename within the day folder
            let asset6 = asset_id.get(0..6).unwrap_or(&asset_id);
            let (stem, ext_s) = {
                let p = std::path::Path::new(&sanitized);
                let stem = p.file_stem().and_then(|s| s.to_str()).unwrap_or("");
                let ext_s = p.extension().and_then(|e| e.to_str()).unwrap_or("");
                (stem.to_string(), ext_s.to_string())
            };
            // First try the sanitized name; if taken, append __<asset6>, then numeric suffixes.
            let mut candidate = day_dir.join(&sanitized);
            if candidate.exists() {
                let mut base = format!("{}__{}", stem, asset6);
                let mut n: u32 = 1;
                loop {
                    let fname = if ext_s.is_empty() {
                        base.clone()
                    } else {
                        format!("{}.{}", base, ext_s)
                    };
                    let try_path = day_dir.join(&fname);
                    if !try_path.exists() {
                        candidate = try_path;
                        break;
                    }
                    n += 1;
                    base = format!("{}__{}-{}", stem, asset6, n);
                }
            }

            tracing::info!(
                target: "upload",
                "[UPLOAD] moving file (user={}, upload_id={}): src={}, dest={}",
                user_id,
                upload_id,
                src_path.display(),
                candidate.display(),
            );
            // Move into destination (cross-device safe)
            let rename_res = tokio::fs::rename(src_path, &candidate).await;
            if rename_res.is_err() {
                tokio::fs::copy(src_path, &candidate).await?;
                let _ = tokio::fs::remove_file(src_path).await;
                tracing::info!(target: "upload", "[UPLOAD] cross-device move; copied then removed source (user={}, upload_id={}, dest={})", user_id, upload_id, candidate.display());
            }
            candidate
        }
    } else {
        tracing::info!(target: "upload", "[UPLOAD] move_on_ingest disabled; indexing src in place (user={}, upload_id={}, src={})", user_id, upload_id, src_path.display());
        src_path.to_path_buf()
    };

    // Prepare embedding store (data DB may be refreshed on failure paths)
    let embed_store = state.create_user_embedding_store(user_id)?;

    // Postgres mode: perform ingestion without touching DuckDB paths
    if let Some(pg) = &state.pg_client {
        tracing::info!(target:"upload", "[UPLOAD] PG ingestion path (user={}, upload_id={}, dest={})", user_id, upload_id, dest_path.display());
        // Index one photo/video via PG MetaStore path inside index_single_photo_for_user
        // Pass a throwaway in-memory DuckDB connection (unused in PG branch)
        let dummy_db = std::sync::Arc::new(parking_lot::Mutex::new(
            duckdb::Connection::open_in_memory()
                .map_err(|e| anyhow::anyhow!(format!("open_in_memory: {}", e)))?,
        ));
        let ext_local = dest_path
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("")
            .to_ascii_lowercase();
        if is_video_extension(&ext_local) {
            super::auth_handlers::index_video_for_user(
                state,
                &dummy_db,
                &embed_store,
                &dest_path,
                user_id,
                forced_replace_asset_id.as_deref(),
            )
            .await?;
        } else {
            super::auth_handlers::index_single_photo_for_user(
                state,
                &dummy_db,
                &embed_store,
                &dest_path,
                user_id,
                forced_replace_asset_id.as_deref(),
            )
            .await?;
        }
        // Optional content_id upsert if provided by client
        if let Some(cid) = meta_get(&metadata, &["content_id", "contentId", "content-id"]) {
            let _ = pg
                .execute(
                    "UPDATE photos SET content_id = $1 WHERE organization_id=$2 AND asset_id=$3",
                    &[&cid, &org_id, &asset_id],
                )
                .await;
        }
        if let Some(backup_id) = upload_backup_id
            .as_ref()
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
        {
            let _ = pg
                .execute(
                    "UPDATE photos SET backup_id = $1 WHERE organization_id=$2 AND user_id=$3 AND asset_id=$4",
                    &[&backup_id, &org_id, &user_id, &asset_id],
                )
                .await;
        }
        if let Some(visual_backup_id) = meta_get(
            &metadata,
            &["visual_backup_id", "visualBackupId", "visual-backup-id"],
        ) {
            let _ = pg
                .execute(
                    "UPDATE photos SET visual_backup_id = $1 WHERE organization_id=$2 AND asset_id=$3",
                    &[&visual_backup_id, &org_id, &asset_id],
                )
                .await;
        }
        // Notify via SSE and clean sidecar .info
        emit_upload_ingested_event(state, user_id, &asset_id, &dest_path, metadata.as_ref());
        let sidecar = src_path.with_extension("info");
        let _ = tokio::fs::remove_file(&sidecar).await;
        return Ok(());
    }

    // Route by extension
    let ext = dest_path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_lowercase();

    // Fast-path dedupe: if asset_id already exists, skip heavy indexing when lock state matches.
    // DuckDB data DB for quick checks/updates
    let data_db = state.get_user_data_database(user_id)?;
    let (asset_exists, existing_locked): (bool, bool) = {
        let conn = data_db.lock();
        conn.prepare(
            "SELECT COALESCE(locked, FALSE)
             FROM photos
             WHERE organization_id = ? AND user_id = ? AND asset_id = ?
             LIMIT 1",
        )
        .ok()
        .and_then(|mut s| {
            match s.query_row(duckdb::params![org_id, user_id, &asset_id], |row| {
                row.get::<_, bool>(0)
            }) {
                Ok(lock) => Some((true, lock)),
                Err(_) => None,
            }
        })
        .unwrap_or((false, false))
    };
    // Incoming here is always UNLOCKED
    if asset_exists && existing_locked == false {
        tracing::info!(
            target: "upload",
            "[UPLOAD] asset already exists; skipping heavy indexing (asset_id={}, ext={})",
            asset_id,
            ext
        );
        // Important: even for duplicates, persist client-supplied `content_id` so Live Photo pairing
        // (still + paired MOV) can succeed when one side was uploaded earlier (e.g., older app versions
        // that uploaded only the still). Without this, `try_pair_live_by_content_id` won't find both
        // sides and the paired MOV can remain as a standalone "Video".
        if let Some(cid) = meta_get(&metadata, &["content_id", "contentId", "content-id"]) {
            {
                let conn = data_db.lock();
                // Only set if empty to avoid thrashing when identical bytes are reused across assets.
                log_db_error!(
                    conn.execute(
                        "UPDATE photos
                         SET content_id = CASE
                             WHEN content_id IS NULL OR content_id = '' THEN ?
                             ELSE content_id
                         END
                         WHERE asset_id = ?",
                        duckdb::params![&cid, &asset_id],
                    ),
                    format!("Update content_id for existing asset {}", asset_id)
                );
            }
            // Attempt Live Photo pairing using the (now-persisted) content_id.
            if is_video_extension(&ext) {
                try_pair_live_by_content_id(
                    &data_db,
                    user_id,
                    &cid,
                    None,
                    Some(&dest_path),
                    None,
                    Some(&asset_id),
                );
            } else {
                try_pair_live_by_content_id(
                    &data_db,
                    user_id,
                    &cid,
                    Some(&dest_path),
                    None,
                    Some(&asset_id),
                    None,
                );
            }
        }
        // Update sync stats (duplicate, success)
        state.record_sync_ingest(
            user_id,
            source_method.unwrap_or("unknown"),
            /*is_photo=*/ !is_video_extension(&ext),
            /*duplicate=*/ true,
            /*success=*/ true,
        );
        // Apply favorites if provided
        if let Some(meta) = metadata.as_ref() {
            if let Some(fav_raw) = meta.get("favorite") {
                let fv = fav_raw.trim().to_ascii_lowercase();
                let is_fav = fv == "1" || fv == "true" || fv == "yes";
                let conn = data_db.lock();
                log_db_error!(
                    conn.execute(
                        "UPDATE photos SET favorites = ? WHERE asset_id = ?",
                        duckdb::params![if is_fav { 1 } else { 0 }, &asset_id],
                    ),
                    format!("Update favorites for asset {}", asset_id)
                );
                tracing::info!(target: "upload", "[UPLOAD] set favorites={} for asset {} via metadata", is_fav, asset_id);
            }
            // Apply created_at if provided
            if let Some(created_raw) = meta
                .get("created_at")
                .or_else(|| meta.get("createdAt"))
                .or_else(|| meta.get("creation_ts"))
                .or_else(|| meta.get("creationTs"))
            {
                if let Ok(ts) = created_raw.trim().parse::<i64>() {
                    if ts > 0 {
                        let conn = data_db.lock();
                        log_db_error!(
                            conn.execute(
                                "UPDATE photos SET created_at = ? WHERE asset_id = ?",
                                duckdb::params![ts, &asset_id],
                            ),
                            format!("Update created_at for asset {}", asset_id)
                        );
                        tracing::info!(target: "upload", "[UPLOAD] set created_at={} for existing asset {} via metadata", ts, asset_id);
                    }
                }
            }
            // Apply caption if provided
            if let Some(caption) = meta_get(&metadata, &["caption", "notes", "note"]) {
                let conn = data_db.lock();
                log_db_error!(
                    conn.execute(
                        "UPDATE photos SET caption = COALESCE(caption, ?) WHERE asset_id = ?",
                        duckdb::params![&caption, &asset_id],
                    ),
                    format!("Update caption for asset {}", asset_id)
                );
                let mut cap_log = caption.clone();
                if cap_log.len() > 200 {
                    cap_log.truncate(200);
                    cap_log.push_str("…");
                }
                tracing::info!(target: "upload", "[UPLOAD] set caption for asset {} via metadata: '{}'", asset_id, cap_log);
            }
            // Apply description if provided
            if let Some(desc) = meta_get(&metadata, &["description"]) {
                let conn = data_db.lock();
                log_db_error!(
                    conn.execute(
                        "UPDATE photos SET description = COALESCE(description, ?) WHERE asset_id = ?",
                        duckdb::params![&desc, &asset_id],
                    ),
                    format!("Update description for asset {}", asset_id)
                );
                tracing::info!(target: "upload", "[UPLOAD] set description for asset {} via metadata", asset_id);
            }
        }
        // Attach to album if provided
        if let Some(meta) = metadata.as_ref() {
            if let Some(album_id_str) = meta.get("albumId").or_else(|| meta.get("album_id")) {
                if let Ok(album_id) = album_id_str.parse::<i32>() {
                    // Resolve photo_id by asset_id and attach
                    let photo_id_opt: Option<i32> = {
                        let conn = data_db.lock();
                        conn.prepare("SELECT id FROM photos WHERE asset_id = ? LIMIT 1")
                            .ok()
                            .and_then(|mut s| {
                                s.query_row(duckdb::params![&asset_id], |row| row.get::<_, i32>(0))
                                    .ok()
                            })
                    };
                    if let Some(photo_id) = photo_id_opt {
                        let conn = data_db.lock();
                        // Reuse helper to attach
                        attach_photo_to_album(&conn, org_id, album_id, photo_id);
                    }
                }
            }
        }
        // NOTE: Avoid per-upload `CHECKPOINT;` here. In global-DB mode, this becomes a hot-path
        // checkpoint on a potentially very large DuckDB file and can cause severe contention and
        // runaway memory usage. DuckDB auto-checkpoints as needed; we keep explicit checkpoints
        // only in coarse-grained maintenance jobs (e.g., end-of-reindex).
        // Notify via SSE
        emit_upload_ingested_event(state, user_id, &asset_id, &dest_path, metadata.as_ref());
        tracing::info!(target: "upload", "[UPLOAD] SSE emitted (user={}, asset_id={})", user_id, asset_id);
        // Remove sidecar .info if present
        let sidecar = src_path.with_extension("info");
        let _ = tokio::fs::remove_file(&sidecar).await;
        return Ok(());
    }

    // DuckDB mode: ingestion with one-shot recovery for invalidated/fatal DuckDB states
    let mut attempt = 0;
    let max_attempts = 2;
    loop {
        let data_db_cur = state.get_user_data_database(user_id)?;
        let do_result: anyhow::Result<()> = async {
            if is_video_extension(&ext) {
                tracing::info!(target: "upload", "[UPLOAD] indexing video (user={}, path={})", user_id, dest_path.display());
                super::auth_handlers::index_video_for_user(
                    state,
                    &data_db_cur,
                    &embed_store,
                    &dest_path,
                    user_id,
                    forced_replace_asset_id.as_deref(),
                )
                .await?;
                // Prefer content_id pairing, else fallback to filename
                if let Some(cid) = meta_get(&metadata, &["content_id", "contentId", "content-id"]) {
                    // stamp content_id onto this row
                    let conn = data_db_cur.lock();
                    log_db_error!(
                        conn.execute(
                            "UPDATE photos SET content_id = ? WHERE asset_id = ?",
                            duckdb::params![&cid, &asset_id],
                        ),
                        format!("Update content_id for asset {}", asset_id)
                    );
                    drop(conn);
                    try_pair_live_by_content_id(&data_db_cur, user_id, &cid, None, Some(&dest_path), None, Some(&asset_id));
                }
                let fname_guess = metadata
                    .as_ref()
                    .and_then(|m| m.get("filename").map(|s| s.to_string()))
                    .or_else(|| dest_path.file_name().and_then(|n| n.to_str()).map(|s| s.to_string()))
                    .unwrap_or_else(|| String::from(""));
                try_pair_live_by_filename(state, &data_db_cur, user_id, &fname_guess, None, Some(&dest_path));
            } else {
                if asset_exists && existing_locked {
                    tracing::info!(target: "upload", "[UPLOAD] replace policy: existing=locked, incoming=unlocked → replacing + reindexing (asset_id={})", asset_id);
                }
                tracing::info!(target: "upload", "[UPLOAD] indexing photo (user={}, path={})", user_id, dest_path.display());
                super::auth_handlers::index_single_photo_for_user(
                    state,
                    &data_db_cur,
                    &embed_store,
                    &dest_path,
                    user_id,
                    forced_replace_asset_id.as_deref(),
                )
                .await?;
                // If we are replacing a previously LOCKED asset with an UNLOCKED upload, remove old locked containers
                if asset_exists && existing_locked {
                    let locked_orig = state.locked_original_path_for(user_id, &asset_id);
                    let locked_thumb = state.locked_thumb_path_for(user_id, &asset_id);
                    let _ = std::fs::remove_file(&locked_orig);
                    let _ = std::fs::remove_file(&locked_thumb);
                    tracing::info!(target: "upload", "[UPLOAD] cleanup: removed prior locked containers for asset {}", asset_id);
                }
                if let Some(cid) = meta_get(&metadata, &["content_id", "contentId", "content-id"]) {
                    let conn = data_db_cur.lock();
                    log_db_error!(
                        conn.execute(
                            "UPDATE photos SET content_id = ? WHERE asset_id = ?",
                            duckdb::params![&cid, &asset_id],
                        ),
                        format!("Update content_id for photo asset {}", asset_id)
                    );
                    drop(conn);
                    try_pair_live_by_content_id(&data_db_cur, user_id, &cid, Some(&dest_path), None, Some(&asset_id), None);
                }
                let fname_guess = metadata
                    .as_ref()
                    .and_then(|m| m.get("filename").map(|s| s.to_string()))
                    .or_else(|| dest_path.file_name().and_then(|n| n.to_str()).map(|s| s.to_string()))
                    .unwrap_or_else(|| String::from(""));
                try_pair_live_by_filename(state, &data_db_cur, user_id, &fname_guess, Some(&dest_path), None);
            }
            Ok(())
        }.await;

        match do_result {
            Ok(()) => break,
            Err(e) => {
                if e.downcast_ref::<super::auth_handlers::SkipIngestError>()
                    .is_some()
                {
                    tracing::warn!(
                        target: "upload",
                        "[UPLOAD] skipping corrupt media (user={}, upload_id={}, path={}): {}",
                        user_id,
                        upload_id,
                        dest_path.display(),
                        e
                    );
                    let _ = tokio::fs::remove_file(&dest_path).await;
                    return Ok(());
                }
                let msg = e.to_string();
                let recoverable = msg.contains("database has been invalidated")
                    || msg.contains("Failure while replaying WAL")
                    || msg.contains("Information loss on integer cast");
                if recoverable && attempt + 1 < max_attempts {
                    attempt += 1;
                    tracing::warn!(target: "upload", "[UPLOAD] Recovering data DB after fatal error (attempt={}): {}", attempt, msg);
                    if let Some(db) = &state.multi_tenant_db {
                        let _ = db.open_fresh_user_data_connection(user_id);
                    }
                    continue;
                } else {
                    return Err(e);
                }
            }
        }
    }

    // Compute target asset for metadata updates when content_id is present
    let mut target_asset_id = asset_id.clone();
    if let Some(cid) = meta_get(&metadata, &["content_id", "contentId", "content-id"]) {
        let conn = data_db.lock();
        if let Ok(mut stmt) = conn
            .prepare("SELECT asset_id FROM photos WHERE content_id = ? AND is_video = 0 LIMIT 1")
        {
            if let Ok(aid) = stmt.query_row([&cid], |row| row.get::<_, String>(0)) {
                target_asset_id = aid;
            }
        }
        drop(conn);
    }
    if let Some(visual_backup_id) = meta_get(
        &metadata,
        &["visual_backup_id", "visualBackupId", "visual-backup-id"],
    ) {
        let conn = data_db.lock();
        let _ = conn.execute(
            "UPDATE photos SET visual_backup_id = ? WHERE asset_id = ?",
            duckdb::params![&visual_backup_id, &target_asset_id],
        );
        drop(conn);
    }

    // If a favorite flag was provided, set favorites accordingly on the asset row
    let is_locked_upload_meta = metadata
        .as_ref()
        .and_then(|m| m.get("locked"))
        .map(|v| v.trim().to_ascii_lowercase())
        .map(|v| v == "1" || v == "true" || v == "yes")
        .unwrap_or(false);
    let (allow_cap_pf, allow_desc_pf): (bool, bool) = if is_locked_upload_meta {
        let users_db = state
            .multi_tenant_db
            .as_ref()
            .expect("users DB required in DuckDB mode")
            .users_connection();
        let conn_u = users_db.lock();
        conn_u
            .query_row(
                "SELECT COALESCE(locked_meta_allow_caption, FALSE), COALESCE(locked_meta_allow_description, FALSE) FROM users WHERE user_id = ?",
                duckdb::params![user_id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap_or((false, false))
    } else {
        (true, true)
    };
    if let Some(meta) = metadata.as_ref() {
        if let Some(fav_raw) = meta.get("favorite") {
            let fv = fav_raw.trim().to_ascii_lowercase();
            let is_fav = fv == "1" || fv == "true" || fv == "yes";
            let conn = data_db.lock();
            log_db_error!(
                conn.execute(
                    "UPDATE photos SET favorites = ? WHERE asset_id = ?",
                    duckdb::params![if is_fav { 1 } else { 0 }, &target_asset_id],
                ),
                format!("Update favorites for locked asset {}", target_asset_id)
            );
            tracing::info!(target: "upload", "[UPLOAD] set favorites={} for asset {} via metadata", is_fav, asset_id);
        }
        // If client provided created_at (epoch seconds), honor it
        if let Some(created_raw) = meta
            .get("created_at")
            .or_else(|| meta.get("createdAt"))
            .or_else(|| meta.get("creation_ts"))
            .or_else(|| meta.get("creationTs"))
        {
            if let Ok(ts) = created_raw.trim().parse::<i64>() {
                if ts > 0 {
                    let conn = data_db.lock();
                    log_db_error!(
                        conn.execute(
                            "UPDATE photos SET created_at = ? WHERE asset_id = ?",
                            duckdb::params![ts, &target_asset_id],
                        ),
                        format!("Update created_at for locked asset {}", target_asset_id)
                    );
                    tracing::info!(target: "upload", "[UPLOAD] set created_at={} for asset {} via metadata", ts, target_asset_id);
                }
            }
        }
        // If a caption was provided, set caption accordingly (do not overwrite existing)
        if let Some(caption) = meta_get(&metadata, &["caption", "notes", "note"]) {
            if !is_locked_upload_meta || allow_cap_pf {
                let conn = data_db.lock();
                log_db_error!(
                    conn.execute(
                        "UPDATE photos SET caption = COALESCE(caption, ?) WHERE asset_id = ?",
                        duckdb::params![&caption, &target_asset_id],
                    ),
                    format!("Update caption for locked asset {}", target_asset_id)
                );
                let mut cap_log = caption.clone();
                if cap_log.len() > 200 {
                    cap_log.truncate(200);
                    cap_log.push_str("…");
                }
                tracing::info!(target: "upload", "[UPLOAD] set caption for asset {} via metadata: '{}'", target_asset_id, cap_log);
            }
        }
        // If a description was provided, set description accordingly (do not overwrite existing)
        if let Some(desc) = meta_get(&metadata, &["description"]) {
            if !is_locked_upload_meta || allow_desc_pf {
                let conn = data_db.lock();
                log_db_error!(
                    conn.execute(
                        "UPDATE photos SET description = COALESCE(description, ?) WHERE asset_id = ?",
                        duckdb::params![&desc, &target_asset_id],
                    ),
                    format!("Update description for locked asset {}", target_asset_id)
                );
                tracing::info!(target: "upload", "[UPLOAD] set description for asset {} via metadata", target_asset_id);
            }
        }
    }

    // If an albumId was provided via metadata, auto-attach the new asset to that album
    if let Some(meta) = metadata.as_ref() {
        // Accept either albumId or album_id
        let alb_raw = meta
            .get("albumId")
            .or_else(|| meta.get("album_id"))
            .and_then(|s| s.parse::<i32>().ok());
        if let Some(album_id) = alb_raw {
            // Resolve photo_id by asset_id and attach
            let photo_id_opt: Option<i32> = {
                let conn = data_db.lock();
                conn.prepare(
                    "SELECT id FROM photos WHERE organization_id = ? AND asset_id = ? LIMIT 1",
                )
                .ok()
                .and_then(|mut s| {
                    s.query_row(duckdb::params![org_id, &target_asset_id], |row| {
                        row.get::<_, i32>(0)
                    })
                    .ok()
                })
            };
            if let Some(photo_id) = photo_id_opt {
                let conn = data_db.lock();
                attach_photo_to_album(&conn, org_id, album_id, photo_id);
                tracing::info!(target: "upload", "[UPLOAD] auto-attached asset {} to album {} (photo_id={})", asset_id, album_id, photo_id);
            }
        }
    }

    // If nested album paths were provided via metadata ("albums" JSON), ensure album tree and attach
    if let Some(meta) = metadata.as_ref() {
        if let Some(paths_json) = meta.get("albums") {
            if let Ok(paths) = serde_json::from_str::<Vec<Vec<String>>>(paths_json) {
                // Lookup photo_id for current asset
                let photo_id_opt: Option<i32> = {
                    let conn = data_db.lock();
                    conn.prepare(
                        "SELECT id FROM photos WHERE organization_id = ? AND asset_id = ? LIMIT 1",
                    )
                    .ok()
                    .and_then(|mut s| {
                        s.query_row(duckdb::params![org_id, &target_asset_id], |row| {
                            row.get::<_, i32>(0)
                        })
                        .ok()
                    })
                };
                if let Some(photo_id) = photo_id_opt {
                    for path in paths.into_iter() {
                        // Ensure path exists; skip if any segment is a live album
                        let album_id_opt: Option<i32> = {
                            let conn = data_db.lock();
                            ensure_album_path(&conn, &path, org_id, user_id)
                                .ok()
                                .flatten()
                        };
                        if let Some(album_id) = album_id_opt {
                            let conn = data_db.lock();
                            attach_photo_to_album(&conn, org_id, album_id, photo_id);
                        }
                    }
                }
            }
        }
    }

    #[cfg(feature = "ee")]
    {
        // Record public-link upload moderation sidecar when applicable
        if let Some(meta) = metadata.as_ref() {
            let link_id_opt = meta.get("public_link_id");
            let key_present = meta.get("public_link_key").is_some();
            if let Some(link_id) = link_id_opt {
                if key_present {
                    // Serialize short write to USERS DB to avoid lock inversions with concurrent moderation endpoints
                    let _permit_opt = state.duckdb_semaphore.acquire().await.ok();
                    let users_db = state
                        .multi_tenant_db
                        .as_ref()
                        .expect("users DB required in DuckDB mode")
                        .users_connection();
                    let conn = users_db.lock();
                    // Ensure sidecar tables
                    log_db_error!(
                        conn.execute(
                            "CREATE TABLE IF NOT EXISTS ee_public_links (
                            id TEXT PRIMARY KEY,
                            owner_org_id INTEGER,
                            owner_user_id TEXT,
                            name TEXT,
                            scope_kind VARCHAR,
                            scope_album_id INTEGER,
                            uploads_album_id INTEGER,
                            key_hash TEXT,
                            key_plain TEXT,
                            pin_hash TEXT,
                            permissions INTEGER,
                            expires_at TIMESTAMP,
                            status VARCHAR DEFAULT 'active',
                            cover_asset_id TEXT,
                            moderation_enabled BOOLEAN DEFAULT FALSE,
                            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                        )",
                            [],
                        ),
                        "CREATE TABLE ee_public_links for locked upload moderation"
                    );
                    log_db_error!(
                        conn.execute(
                            "CREATE TABLE IF NOT EXISTS ee_public_link_uploads (
                            link_id TEXT NOT NULL,
                            asset_id TEXT NOT NULL,
                            status VARCHAR NOT NULL,
                            viewer_session_id TEXT,
                            uploader_display_name TEXT,
                            created_at BIGINT,
                            PRIMARY KEY (link_id, asset_id)
                        )",
                            [],
                        ),
                        "CREATE TABLE ee_public_link_uploads for locked upload moderation"
                    );
                    let moderation_enabled: bool = conn
                        .prepare("SELECT moderation_enabled FROM ee_public_links WHERE id = ?")
                        .ok()
                        .and_then(|mut s| {
                            s.query_row(duckdb::params![link_id.as_str()], |r| r.get::<_, bool>(0))
                                .ok()
                        })
                        .unwrap_or(false);
                    let status_val = if moderation_enabled {
                        "pending"
                    } else {
                        "approved"
                    };
                    let viewer_sid = meta.get("viewer_session_id").cloned().unwrap_or_default();
                    let uploader_name = meta
                        .get("uploader_display_name")
                        .cloned()
                        .unwrap_or_default();
                    let now = chrono::Utc::now().timestamp();
                    log_db_error!(
                        conn.execute(
                            "INSERT INTO ee_public_link_uploads (link_id, asset_id, status, viewer_session_id, uploader_display_name, created_at) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT (link_id, asset_id) DO UPDATE SET status=excluded.status",
                            duckdb::params![link_id.as_str(), &target_asset_id, status_val, viewer_sid.as_str(), uploader_name.as_str(), now],
                        ),
                        format!("Failed to record public link upload for link {} asset {}", link_id, target_asset_id)
                    );
                    tracing::info!(
                        target = "upload",
                        "[PUBLIC-MOD] recorded upload for link={} asset={} status={}",
                        link_id,
                        target_asset_id,
                        status_val
                    );
                }
            }
        }
    }

    // Force a checkpoint to ensure immediate visibility across connections (photos + album membership)
    // Best-effort checkpoint; ignore if the database was reinitialized and busy
    if let Ok(dbp) = state.get_user_data_database(user_id) {
        let conn = dbp.lock();
        log_db_error!(
            conn.execute("CHECKPOINT;", []),
            format!("CHECKPOINT user DB for locked upload user {}", user_id)
        );
        tracing::info!(target: "upload", "[UPLOAD] checkpointed user DB (user={})", user_id);
    }

    // Notify via SSE
    emit_upload_ingested_event(state, user_id, &asset_id, &dest_path, metadata.as_ref());
    tracing::info!(target: "upload", "[UPLOAD] SSE emitted (user={}, asset_id={})", user_id, asset_id);
    // Update sync stats for successful ingest
    state.record_sync_ingest(
        user_id,
        source_method.unwrap_or("unknown"),
        /*is_photo=*/ !is_video_extension(&ext),
        /*duplicate=*/ false,
        /*success=*/ true,
    );

    // Remove sidecar .info if present (best-effort)
    let sidecar = src_path.with_extension("info");
    let _ = tokio::fs::remove_file(&sidecar).await;

    Ok(())
}

/// Ingest an encrypted (locked) upload: store container to locked path, upsert DB row,
/// and skip all heavy indexing. Expects metadata including asset_id (b58) and kind.
async fn ingest_locked_upload(
    state: &Arc<AppState>,
    user_id: &str,
    upload_id: &str,
    src_path: &Path,
    metadata: &HashMap<String, String>,
) -> anyhow::Result<()> {
    // Resolve organization id for this user (for album scoping)
    let org_id: i32 = state.org_id_for_user(user_id);
    // Resolve asset_id (prefer explicit b58 from metadata). Fallback to parsing container header.
    let mut asset_id_b58 = metadata
        .get("asset_id_b58")
        .map(|s| s.to_string())
        .unwrap_or_default();
    if asset_id_b58.is_empty() {
        if let Ok((aid_b58, _v)) = parse_pae3_header_for_asset_id_b58(src_path) {
            asset_id_b58 = aid_b58;
        }
    }
    if asset_id_b58.is_empty() {
        anyhow::bail!("locked upload missing asset_id");
    }

    // Kind: orig or thumb
    let kind = metadata
        .get("kind")
        .map(|s| s.trim().to_ascii_lowercase())
        .unwrap_or_else(|| "orig".to_string());
    let is_thumb = kind == "thumb";
    let backup_id_opt: Option<String> = metadata.get("backup_id").cloned();
    let visual_backup_id_opt: Option<String> = metadata.get("visual_backup_id").cloned();

    if let Some(matched) = find_deleted_upload_match(
        state.as_ref(),
        org_id,
        user_id,
        Some(&asset_id_b58),
        backup_id_opt.as_deref(),
    )
    .await?
    {
        tracing::info!(
            target: "upload",
            "[UPLOAD-LOCKED] skipped deleted/tombstoned upload user={} asset_id={} key_kind={} key_value={}",
            user_id,
            asset_id_b58,
            matched.key_kind,
            matched.key_value
        );
        cleanup_skipped_upload_artifacts(src_path).await;
        return Ok(());
    }

    // Destination path under locked/
    let dest_path = if is_thumb {
        state.locked_thumb_path_for(user_id, &asset_id_b58)
    } else {
        state.locked_original_path_for(user_id, &asset_id_b58)
    };
    tracing::info!(target:"upload", "[UPLOAD-LOCKED] preparing ingest: user={} asset_id={} kind={} dest_path={}", user_id, asset_id_b58, if is_thumb {"thumb"} else {"orig"}, dest_path.display());
    if let Some(parent) = dest_path.parent() {
        tokio::fs::create_dir_all(parent).await.ok();
    }
    // Move or copy into place
    if let Err(e) = tokio::fs::rename(src_path, &dest_path).await {
        tracing::info!(target:"upload", "[UPLOAD-LOCKED] cross-device move; copying. err={}", e);
        tokio::fs::copy(src_path, &dest_path).await?;
        let _ = tokio::fs::remove_file(src_path).await;
    }

    // Upsert into photos table when kind=orig; when thumb arrives first, create a placeholder row.
    let now = chrono::Utc::now().timestamp();
    let is_video = metadata
        .get("is_video")
        .map(|v| v.trim().to_ascii_lowercase())
        .map(|v| v == "1" || v == "true" || v == "yes")
        .unwrap_or(false);
    let width: Option<i64> = metadata.get("width").and_then(|s| s.parse::<i64>().ok());
    let height: Option<i64> = metadata.get("height").and_then(|s| s.parse::<i64>().ok());
    let orientation: Option<i64> = metadata
        .get("orientation")
        .and_then(|s| s.parse::<i64>().ok());
    let duration_ms: Option<i64> = metadata
        .get("duration_s")
        .and_then(|s| s.parse::<i64>().ok())
        .map(|s| s * 1000);
    // created_at: prefer explicit epoch seconds when provided; else capture_ymd midnight UTC; else now
    let mut created_at = if let Some(ca_raw) = metadata.get("created_at") {
        ca_raw.trim().parse::<i64>().ok().filter(|v| *v > 0)
    } else {
        None
    }
    .unwrap_or_else(|| {
        metadata
            .get("capture_ymd")
            .and_then(|ymd| parse_date_to_utc_midnight(ymd).ok())
            .unwrap_or(now)
    });

    let size_kb_meta: Option<i64> = metadata.get("size_kb").and_then(|s| s.parse::<i64>().ok());
    let size_bytes = if let Some(kb) = size_kb_meta {
        kb.max(0) * 1024
    } else {
        // fallback to actual file size rounded to kb
        dest_path
            .metadata()
            .ok()
            .map(|m| ((m.len() as i64 + 1023) / 1024) * 1024)
            .unwrap_or(0)
    };

    if let Some(pg) = &state.pg_client {
        // Postgres path: robust UPSERT to ensure locked=TRUE is persisted regardless of prior row state
        if is_thumb {
            // Thumb may arrive before original. Insert placeholder and always set locked=TRUE.
            let _ = pg
                .execute(
                    "INSERT INTO photos (
                        organization_id, user_id, asset_id, created_at, modified_at, size, width, height, orientation, favorites, locked, is_video, is_live_photo, duration_ms, delete_time, is_screenshot, last_indexed, crypto_version, locked_orig_uploaded, locked_thumb_uploaded
                    ) VALUES (
                        $1, $2, $3, $4, $5, $6, $7, $8, $9, 0, TRUE, $10, FALSE, $11, 0, 0, $12, 3, FALSE, TRUE
                    ) ON CONFLICT (organization_id, asset_id) DO UPDATE SET
                        created_at = COALESCE(created_at, EXCLUDED.created_at),
                        modified_at = EXCLUDED.modified_at,
                        size = COALESCE(size, EXCLUDED.size),
                        width = COALESCE(width, EXCLUDED.width),
                        height = COALESCE(height, EXCLUDED.height),
                        orientation = COALESCE(orientation, EXCLUDED.orientation),
                        locked = TRUE,
                        locked_thumb_uploaded = TRUE,
                        is_video = COALESCE(is_video, EXCLUDED.is_video),
                        duration_ms = COALESCE(duration_ms, EXCLUDED.duration_ms),
                        crypto_version = 3",
                    &[&org_id, &user_id, &asset_id_b58, &created_at, &now, &size_bytes, &width, &height, &orientation, &is_video, &duration_ms, &now],
                )
                .await;
        } else {
            // Original container: upsert full path/mime and lock the row
            let _ = pg
                .execute(
                    "INSERT INTO photos (
                        organization_id, user_id, asset_id, path, filename, mime_type, created_at, modified_at, size, width, height, orientation, favorites, locked, is_video, is_live_photo, live_video_path, duration_ms, delete_time, is_screenshot, camera_make, camera_model, iso, aperture, shutter_speed, focal_length, latitude, longitude, altitude, location_name, city, province, country, caption, description, comments, likes, ocr_text, search_indexed_at, last_indexed, crypto_version, locked_orig_uploaded, locked_thumb_uploaded
                    ) VALUES (
                        $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,0,TRUE,$13,FALSE,NULL,$14,0,0,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,$15,3, TRUE, FALSE
                    ) ON CONFLICT (organization_id, asset_id) DO UPDATE SET
                        path = EXCLUDED.path,
                        filename = EXCLUDED.filename,
                        mime_type = EXCLUDED.mime_type,
                        created_at = COALESCE(created_at, EXCLUDED.created_at),
                        modified_at = EXCLUDED.modified_at,
                        size = COALESCE(size, EXCLUDED.size),
                        width = COALESCE(width, EXCLUDED.width),
                        height = COALESCE(height, EXCLUDED.height),
                        orientation = COALESCE(orientation, EXCLUDED.orientation),
                        locked = TRUE,
                        locked_orig_uploaded = TRUE,
                        is_video = COALESCE(is_video, EXCLUDED.is_video),
                        duration_ms = COALESCE(duration_ms, EXCLUDED.duration_ms),
                        crypto_version = 3",
                    &[
                        &org_id,
                        &user_id,
                        &asset_id_b58,
                        &dest_path.to_string_lossy(),
                        &format!("{}.pae3", asset_id_b58),
                        &"application/octet-stream".to_string(),
                        &created_at,
                        &now,
                        &size_bytes,
                        &width,
                        &height,
                        &orientation,
                        &is_video,
                        &duration_ms,
                        &now,
                    ],
                )
                .await;
            // Diagnostics: confirm resulting row state
            if let Ok(row) = pg
                .query_one(
                    "SELECT COALESCE(locked, FALSE), COALESCE(path,''), COALESCE(filename,'') FROM photos WHERE organization_id=$1 AND asset_id=$2 LIMIT 1",
                    &[&org_id, &asset_id_b58],
                )
                .await
            {
                let l: bool = row.get(0);
                let p: String = row.get(1);
                let f: String = row.get(2);
                tracing::info!(target:"upload", "[UPLOAD-LOCKED] PG upsert(orig) result locked={} path={} filename={}", l, p, f);
                // Fallback enforcement if locked did not stick (due to unexpected conflicts)
                if !l || !p.ends_with(".pae3") {
                    let _ = pg
                        .execute(
                            "UPDATE photos SET locked=TRUE, path=$1, filename=$2, mime_type='application/octet-stream', crypto_version=3 WHERE organization_id=$3 AND asset_id=$4",
                            &[&dest_path.to_string_lossy(), &format!("{}.pae3", asset_id_b58), &org_id, &asset_id_b58],
                        )
                        .await;
                    if let Ok(row2) = pg
                        .query_one(
                            "SELECT COALESCE(locked, FALSE), COALESCE(path,''), COALESCE(filename,'') FROM photos WHERE organization_id=$1 AND asset_id=$2 LIMIT 1",
                            &[&org_id, &asset_id_b58],
                        )
                        .await
                    {
                        let l2: bool = row2.get(0);
                        let p2: String = row2.get(1);
                        let f2: String = row2.get(2);
                        tracing::info!(target:"upload", "[UPLOAD-LOCKED] PG enforce(orig) result locked={} path={} filename={}", l2, p2, f2);
                    }
                }
            }
        }
        // Thumb diagnostics as well
        if is_thumb {
            if let Ok(row) = pg
                .query_one(
                    "SELECT COALESCE(locked, FALSE) FROM photos WHERE organization_id=$1 AND asset_id=$2 LIMIT 1",
                    &[&org_id, &asset_id_b58],
                )
                .await
            {
                let l: bool = row.get(0);
                tracing::info!(target:"upload", "[UPLOAD-LOCKED] PG upsert(thumb) result locked={}", l);
            }
        }
        // Persist backup_id if provided by the client (lets cloud-check match locked uploads by plaintext bytes)
        if let Some(bid) = backup_id_opt.as_ref().filter(|s| !s.trim().is_empty()) {
            let _ = pg
                .execute(
                    "UPDATE photos SET backup_id=$1 WHERE organization_id=$2 AND user_id=$3 AND asset_id=$4",
                    &[bid, &org_id, &user_id, &asset_id_b58],
                )
                .await;
        }
        if let Some(visual_bid) = visual_backup_id_opt
            .as_ref()
            .filter(|s| !s.trim().is_empty())
        {
            let _ = pg
                .execute(
                    "UPDATE photos SET visual_backup_id=$1 WHERE organization_id=$2 AND user_id=$3 AND asset_id=$4",
                    &[visual_bid, &org_id, &user_id, &asset_id_b58],
                )
                .await;
        }
        // For PG: update text index and emit SSE, then return early to skip DuckDB-only logic below
        if let Err(e) = reindex_single_asset(state, user_id, &asset_id_b58) {
            tracing::warn!(target:"upload", "[UPLOAD-LOCKED] reindex (PG) failed for {}: {}", asset_id_b58, e);
        }
        emit_upload_ingested_event(state, user_id, &asset_id_b58, &dest_path, Some(&metadata));
        return Ok(());
    } else {
        // DuckDB path (original)
        let data_db = state.get_user_data_database(user_id)?;
        // Capture any prior row/path to support replacement clean-up
        let prior_row: Option<(String, bool, bool)> = {
            let conn = data_db.lock();
            conn
                .prepare("SELECT path, COALESCE(locked, FALSE), COALESCE(is_video, FALSE) FROM photos WHERE asset_id = ? LIMIT 1")
                .ok()
                .and_then(|mut s| s.query_row(duckdb::params![&asset_id_b58], |r| Ok((r.get::<_, String>(0)?, r.get::<_, bool>(1)?, r.get::<_, bool>(2)?))).ok())
        };
        {
            let conn = data_db.lock();
            if is_thumb && is_video {
                let vpath = state
                    .locked_original_path_for(user_id, &asset_id_b58)
                    .to_string_lossy()
                    .to_string();
                let paired_exists: bool = conn
                    .prepare(
                        "SELECT 1 FROM photos WHERE COALESCE(locked, FALSE) = TRUE AND is_video = FALSE AND COALESCE(is_live_photo, FALSE) = TRUE AND live_video_path = ? LIMIT 1",
                    )
                    .ok()
                    .and_then(|mut s| s.query_row(duckdb::params![&vpath], |r| r.get::<_, i32>(0)).ok())
                    .is_some();
                if paired_exists {
                    return Ok(());
                }
            }
            let row_exists: bool = conn
                .prepare("SELECT 1 FROM photos WHERE asset_id = ? LIMIT 1")
                .ok()
                .and_then(|mut s| {
                    s.query_row(duckdb::params![&asset_id_b58], |row| row.get::<_, i32>(0))
                        .ok()
                })
                .is_some();
            if row_exists {
                if !is_thumb {
                    log_db_error!(
                        conn.execute(
                            "UPDATE photos SET path = ?, filename = ?, mime_type = ?, created_at = COALESCE(created_at, ?), modified_at = ?, size = COALESCE(size, ?), width = COALESCE(width, ?), height = COALESCE(height, ?), orientation = COALESCE(orientation, ?), locked = TRUE, locked_orig_uploaded = TRUE, is_video = COALESCE(is_video, ?), duration_ms = COALESCE(duration_ms, ?), crypto_version = 3 WHERE asset_id = ? AND organization_id = ?",
                        duckdb::params![
                            &dest_path.to_string_lossy(),
                            format!("{}.pae3", asset_id_b58),
                            "application/octet-stream",
                            created_at,
                            now,
                            size_bytes,
                            width,
                            height,
                            orientation,
                            is_video,
                            duration_ms,
                            &asset_id_b58,
                            org_id
                        ],
                    ),
                    format!("UPDATE locked photo for asset {}", asset_id_b58)
                    );
                } else {
                    log_db_error!(
                        conn.execute(
                            "UPDATE photos SET created_at = COALESCE(created_at, ?), modified_at = ?, size = COALESCE(size, ?), width = COALESCE(width, ?), height = COALESCE(height, ?), orientation = COALESCE(orientation, ?), locked = TRUE, locked_thumb_uploaded = TRUE, is_video = COALESCE(is_video, ?), duration_ms = COALESCE(duration_ms, ?), crypto_version = 3 WHERE asset_id = ? AND organization_id = ?",
                        duckdb::params![
                            created_at,
                            now,
                            size_bytes,
                            width,
                            height,
                            orientation,
                            is_video,
                            duration_ms,
                            &asset_id_b58,
                            org_id
                        ],
                    ),
                    format!("UPDATE locked photo thumbnail for asset {}", asset_id_b58)
                    );
                }
            } else {
                log_db_error!(
                    conn.execute(
                        "INSERT INTO photos (organization_id, user_id, asset_id, path, filename, mime_type, created_at, modified_at, size, width, height, orientation, favorites, locked, is_video, is_live_photo, duration_ms, delete_time, is_screenshot, caption, description, comments, likes, ocr_text, last_indexed, crypto_version, locked_orig_uploaded, locked_thumb_uploaded) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, TRUE, ?, FALSE, ?, 0, 0, NULL, NULL, NULL, NULL, NULL, ?, 3, ?, ?)",
                    duckdb::params![
                        org_id,
                        user_id,
                        &asset_id_b58,
                        &dest_path.to_string_lossy(),
                        format!("{}.pae3", asset_id_b58),
                        "application/octet-stream",
                        created_at,
                        now,
                        size_bytes,
                        width,
                        height,
                        orientation,
                        is_video,
                        duration_ms,
                        now,
                        !is_thumb,
                        is_thumb
                    ],
                ),
                format!("INSERT new locked photo for asset {}", asset_id_b58)
                );
            }
        }
    }

    // DuckDB-only post-processing (pairing, captions, albums)
    if state.pg_client.is_none() {
        let data_db = state.get_user_data_database(user_id)?;
        // If client provided a content_id, stamp it on this row and attempt robust live pairing
        if let Some(cid) = meta_get(
            &Some(metadata.clone()),
            &["content_id", "contentId", "content-id"],
        ) {
            // Update the row's content_id
            {
                let conn = data_db.lock();
                let _ = conn.execute(
                    "UPDATE photos SET content_id = ? WHERE asset_id = ? AND organization_id = ?",
                    duckdb::params![&cid, &asset_id_b58, org_id],
                );
            }
            // Pair via content_id using known paths
            if is_video {
                try_pair_live_by_content_id(
                    &data_db,
                    user_id,
                    &cid,
                    None,
                    Some(&dest_path),
                    None,
                    Some(&asset_id_b58),
                );
            } else {
                try_pair_live_by_content_id(
                    &data_db,
                    user_id,
                    &cid,
                    Some(&dest_path),
                    None,
                    Some(&asset_id_b58),
                    None,
                );
            }
        }

        // Persist backup_id if provided by the client (lets cloud-check match locked uploads by plaintext bytes)
        if let Some(bid) = backup_id_opt.as_ref().filter(|s| !s.trim().is_empty()) {
            let conn = data_db.lock();
            let _ = conn.execute(
                "UPDATE photos SET backup_id = ? WHERE organization_id = ? AND user_id = ? AND asset_id = ?",
                duckdb::params![bid, org_id, user_id, &asset_id_b58],
            );
        }
        if let Some(visual_bid) = visual_backup_id_opt
            .as_ref()
            .filter(|s| !s.trim().is_empty())
        {
            let conn = data_db.lock();
            let _ = conn.execute(
                "UPDATE photos SET visual_backup_id = ? WHERE organization_id = ? AND user_id = ? AND asset_id = ?",
                duckdb::params![visual_bid, org_id, user_id, &asset_id_b58],
            );
        }

        // If this is a locked ORIGINAL (not a thumb), try to pair Live Photo by timestamp proximity
        if !is_thumb {
            try_pair_locked_by_timestamp(&data_db, user_id, created_at, is_video, &dest_path);
        }

        // Respect per-user security settings for which plaintext metadata to retain on locked items
        let (allow_loc, allow_cap, allow_desc): (bool, bool, bool) = {
            let users_db = state
                .multi_tenant_db
                .as_ref()
                .expect("users DB required in DuckDB mode")
                .users_connection();
            let conn_u = users_db.lock();
            conn_u
            .query_row(
                "SELECT COALESCE(locked_meta_allow_location, FALSE), COALESCE(locked_meta_allow_caption, FALSE), COALESCE(locked_meta_allow_description, FALSE) FROM users WHERE user_id = ?",
                duckdb::params![user_id],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .unwrap_or((false, false, false))
        };

        // Apply caption/description per settings
        {
            let conn = data_db.lock();
            if allow_cap {
                if let Some(caption) = metadata.get("caption").cloned() {
                    let _ = conn.execute(
                        "UPDATE photos SET caption = COALESCE(caption, ?) WHERE asset_id = ?",
                        duckdb::params![caption, &asset_id_b58],
                    );
                }
            } else {
                // Clear any existing value when locking if not allowed
                let _ = conn.execute(
                    "UPDATE photos SET caption = NULL WHERE asset_id = ?",
                    duckdb::params![&asset_id_b58],
                );
            }
            if allow_desc {
                if let Some(desc) = metadata.get("description").cloned() {
                    let _ = conn.execute(
                    "UPDATE photos SET description = COALESCE(description, ?) WHERE asset_id = ?",
                    duckdb::params![desc, &asset_id_b58],
                );
                }
            } else {
                let _ = conn.execute(
                    "UPDATE photos SET description = NULL WHERE asset_id = ?",
                    duckdb::params![&asset_id_b58],
                );
            }
            if allow_loc {
                // Accept either numeric strings or empty
                let lat: Option<f64> = metadata.get("latitude").and_then(|s| s.parse::<f64>().ok());
                let lon: Option<f64> = metadata
                    .get("longitude")
                    .and_then(|s| s.parse::<f64>().ok());
                let alt: Option<f64> = metadata.get("altitude").and_then(|s| s.parse::<f64>().ok());
                let loc_name: Option<String> = metadata.get("location_name").cloned();
                let city: Option<String> = metadata.get("city").cloned();
                let province: Option<String> = metadata.get("province").cloned();
                let country: Option<String> = metadata.get("country").cloned();
                let _ = conn.execute(
                "UPDATE photos SET latitude = COALESCE(latitude, ?), longitude = COALESCE(longitude, ?), altitude = COALESCE(altitude, ?), location_name = COALESCE(location_name, ?), city = COALESCE(city, ?), province = COALESCE(province, ?), country = COALESCE(country, ?) WHERE asset_id = ?",
                duckdb::params![lat, lon, alt, loc_name, city, province, country, &asset_id_b58],
            );
            } else {
                let _ = conn.execute(
                "UPDATE photos SET latitude = NULL, longitude = NULL, altitude = NULL, location_name = NULL, city = NULL, province = NULL, country = NULL WHERE asset_id = ?",
                duckdb::params![&asset_id_b58],
            );
            }
        }

        // If we replaced an existing unlocked/or old path with a locked original, remove previous UNLOCKED file and caches (best-effort)
        if !is_thumb {
            // Recompute prior row in this scope
            let prior_row: Option<(String, bool, bool)> = {
                let conn = data_db.lock();
                conn
                .prepare("SELECT path, COALESCE(locked, FALSE), COALESCE(is_video, FALSE) FROM photos WHERE asset_id = ? LIMIT 1")
                .ok()
                .and_then(|mut s| s.query_row(duckdb::params![&asset_id_b58], |r| Ok((r.get::<_, String>(0)?, r.get::<_, bool>(1)?, r.get::<_, bool>(2)?))).ok())
            };
            if let Some((old_path, _old_locked, old_is_video)) = prior_row.as_ref() {
                if *old_path != dest_path.to_string_lossy() {
                    // Skip removal if the old_path is an encrypted container or locked thumb placeholder
                    let is_locked_container = old_path.contains("/locked/")
                        || old_path.ends_with(".pae3")
                        || old_path.ends_with("_t.pae3");
                    if !is_locked_container {
                        if let Err(e) = tokio::fs::remove_file(&old_path).await {
                            tracing::debug!(
                                "[UPLOAD-LOCKED] cleanup: failed to remove old file {}: {}",
                                old_path,
                                e
                            );
                        } else {
                            tracing::info!(
                                "[UPLOAD-LOCKED] cleanup: removed prior file {}",
                                old_path
                            );
                        }
                        // Also remove derived caches for prior UNLOCKED media
                        let thumb_p = state.thumbnail_path_for(user_id, &asset_id_b58);
                        let avif_p = state.avif_path_for(user_id, &asset_id_b58);
                        let poster_p = state.poster_path_for(user_id, &asset_id_b58);
                        let _ = std::fs::remove_file(&thumb_p);
                        let _ = std::fs::remove_file(&avif_p);
                        if *old_is_video {
                            let _ = std::fs::remove_file(&poster_p);
                        }
                    } else {
                        tracing::debug!("[UPLOAD-LOCKED] cleanup: skipping removal of prior locked container {}", old_path);
                    }
                }
            }
        }

        // Helpers (scoped to locked-ingest) to create/attach albums similar to the plain path
        fn ensure_album_ci_schema_locked(conn: &duckdb::Connection) {
            let _ = conn.execute(
                "ALTER TABLE albums ADD COLUMN IF NOT EXISTS name_lc TEXT",
                [],
            );
            let _ = conn.execute(
                "UPDATE albums SET name_lc = lower(name) WHERE name_lc IS NULL",
                [],
            );
            let _ = conn.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS albums_parent_name_ci ON albums(parent_id, name_lc)",
            [],
        );
        }
        fn ensure_album_path_locked(
            conn: &duckdb::Connection,
            organization_id: i32,
            owner_user_id: &str,
            names: &[String],
        ) -> anyhow::Result<Option<i32>> {
            ensure_album_ci_schema_locked(conn);
            if names.is_empty() {
                return Ok(None);
            }
            let now = chrono::Utc::now().timestamp();
            let mut parent: Option<i32> = None;
            for raw in names {
                let name = raw.trim();
                if name.is_empty() {
                    return Ok(None);
                }
                // Lookup existing by case-insensitive name under current parent
                let mut found_id: Option<i32> = None;
                let mut found_is_live: bool = false;
                if let Some(pid) = parent {
                if let Ok(mut stmt) = conn.prepare(
                    "SELECT id, COALESCE(is_live, FALSE) FROM albums WHERE organization_id = ? AND parent_id = ? AND name_lc = lower(?) LIMIT 1",
                ) {
                    let _ = stmt.query_row(duckdb::params![organization_id, pid, name], |row| {
                        found_id = Some(row.get::<_, i32>(0)?);
                        found_is_live = row.get::<_, bool>(1)?;
                        Ok(())
                    });
                }
            } else if let Ok(mut stmt) = conn.prepare(
                "SELECT id, COALESCE(is_live, FALSE) FROM albums WHERE organization_id = ? AND parent_id IS NULL AND name_lc = lower(?) LIMIT 1",
            ) {
                let _ = stmt.query_row(duckdb::params![organization_id, name], |row| {
                    found_id = Some(row.get::<_, i32>(0)?);
                    found_is_live = row.get::<_, bool>(1)?;
                    Ok(())
                });
            }
                if let Some(id) = found_id {
                    if found_is_live {
                        return Ok(None);
                    }
                    parent = Some(id);
                    continue;
                }
                // Determine next position among siblings
                let next_pos: i64 = if let Some(pid) = parent {
                    conn.query_row(
                    "SELECT COALESCE(MAX(position), 0) + 1 FROM albums WHERE organization_id = ? AND parent_id = ?",
                    duckdb::params![organization_id, pid],
                    |row| row.get::<_, i64>(0),
                ).unwrap_or(1)
                } else {
                    conn.query_row(
                    "SELECT COALESCE(MAX(position), 0) + 1 FROM albums WHERE organization_id = ? AND parent_id IS NULL",
                    duckdb::params![organization_id],
                    |row| row.get::<_, i64>(0),
                ).unwrap_or(1)
                };
                // Insert new album
                let _ = if let Some(pid) = parent {
                    conn.execute(
                    "INSERT INTO albums (organization_id, user_id, name, name_lc, description, parent_id, position, is_live, live_criteria, deleted_at, created_at, updated_at) VALUES (?, ?, ?, lower(?), NULL, ?, ?, FALSE, NULL, NULL, ?, ?)",
                    duckdb::params![organization_id, owner_user_id, name, name, pid, next_pos, now, now],
                )
                } else {
                    conn.execute(
                    "INSERT INTO albums (organization_id, user_id, name, name_lc, description, parent_id, position, is_live, live_criteria, deleted_at, created_at, updated_at) VALUES (?, ?, ?, lower(?), NULL, NULL, ?, FALSE, NULL, NULL, ?, ?)",
                    duckdb::params![organization_id, owner_user_id, name, name, next_pos, now, now],
                )
                };
                // Resolve id
                let new_id: i32 = if let Some(pid) = parent {
                    conn.query_row(
                    "SELECT id FROM albums WHERE organization_id = ? AND parent_id = ? AND name_lc = lower(?) LIMIT 1",
                    duckdb::params![organization_id, pid, name],
                    |row| row.get::<_, i32>(0),
                )?
                } else {
                    conn.query_row(
                    "SELECT id FROM albums WHERE organization_id = ? AND parent_id IS NULL AND name_lc = lower(?) LIMIT 1",
                    duckdb::params![organization_id, name],
                    |row| row.get::<_, i32>(0),
                )?
                };
                // Update closure
                let _ = conn.execute(
                "INSERT INTO album_closure (organization_id, ancestor_id, descendant_id, depth) VALUES (?, ?, ?, 0)",
                duckdb::params![organization_id, new_id, new_id],
            );
                if let Some(pid) = parent {
                    let _ = conn.execute(
                    "INSERT INTO album_closure (organization_id, ancestor_id, descendant_id, depth) SELECT organization_id, ancestor_id, ?, depth + 1 FROM album_closure WHERE organization_id = ? AND descendant_id = ?",
                    duckdb::params![new_id, organization_id, pid],
                );
                }
                parent = Some(new_id);
            }
            Ok(parent)
        }
        fn attach_photo_to_album_locked(
            conn: &duckdb::Connection,
            organization_id: i32,
            album_id: i32,
            photo_id: i32,
        ) {
            // verify not live
            let mut ok = false;
            if let Ok(mut stmt) = conn.prepare("SELECT COALESCE(is_live, FALSE) FROM albums WHERE organization_id = ? AND id = ? LIMIT 1") {
            if let Ok(flag) = stmt.query_row(duckdb::params![organization_id, album_id], |row| row.get::<_, bool>(0)) { if !flag { ok = true; } }
        }
            if !ok {
                return;
            }
            let now = chrono::Utc::now().timestamp();
            let _ = conn.execute(
            "INSERT INTO album_photos (organization_id, album_id, photo_id, added_at) VALUES (?, ?, ?, ?) ON CONFLICT (organization_id, album_id, photo_id) DO NOTHING",
            duckdb::params![organization_id, album_id, photo_id, now],
        );
            let _ = conn.execute(
                "UPDATE albums SET updated_at = ? WHERE organization_id = ? AND id = ?",
                duckdb::params![now, organization_id, album_id],
            );
        }

        // Album attachments for locked uploads (use provided metadata)
        if let Some(paths_json) = metadata.get("albums") {
            if let Ok(paths) = serde_json::from_str::<Vec<Vec<String>>>(paths_json) {
                // Resolve photo_id by asset_id
                let photo_id_opt: Option<i32> = {
                    let conn = data_db.lock();
                    conn.prepare("SELECT id FROM photos WHERE asset_id = ? LIMIT 1")
                        .ok()
                        .and_then(|mut s| {
                            s.query_row(duckdb::params![&asset_id_b58], |row| row.get::<_, i32>(0))
                                .ok()
                        })
                };
                if let Some(photo_id) = photo_id_opt {
                    for path in paths.into_iter() {
                        let album_id_opt: Option<i32> = {
                            let conn = data_db.lock();
                            ensure_album_path_locked(&conn, org_id, user_id, &path)
                                .ok()
                                .flatten()
                        };
                        if let Some(album_id) = album_id_opt {
                            let conn = data_db.lock();
                            attach_photo_to_album_locked(&conn, org_id, album_id, photo_id);
                        }
                    }
                }
            }
        }
        // Single album id attachment (albumId or album_id)
        if let Some(alb_raw) = metadata.get("albumId").or_else(|| metadata.get("album_id")) {
            if let Ok(album_id) = alb_raw.parse::<i32>() {
                let photo_id_opt: Option<i32> = {
                    let conn = data_db.lock();
                    conn.prepare("SELECT id FROM photos WHERE asset_id = ? LIMIT 1")
                        .ok()
                        .and_then(|mut s| {
                            s.query_row(duckdb::params![&asset_id_b58], |row| row.get::<_, i32>(0))
                                .ok()
                        })
                };
                if let Some(photo_id) = photo_id_opt {
                    let conn = data_db.lock();
                    attach_photo_to_album_locked(&conn, org_id, album_id, photo_id);
                    tracing::info!(target: "upload", "[UPLOAD-LOCKED] auto-attached asset {} to album {} (photo_id={})", asset_id_b58, album_id, photo_id);
                }
            }
        }
    }

    // Best-effort checkpoint and SSE
    if let Ok(dbp) = state.get_user_data_database(user_id) {
        let conn = dbp.lock();
        let _ = conn.execute("CHECKPOINT;", []);
    }
    // Update text index to reflect locked status (removes doc when locked)
    if let Err(e) = reindex_single_asset(state, user_id, &asset_id_b58) {
        tracing::warn!(target:"upload", "[UPLOAD-LOCKED] reindex failed for {}: {}", asset_id_b58, e);
    }
    emit_upload_ingested_event(state, user_id, &asset_id_b58, &dest_path, Some(&metadata));
    tracing::info!(target:"upload", "[UPLOAD-LOCKED] ingested locked {} (user={}, upload_id={}, asset_id={})", if is_thumb {"thumb"} else {"orig"}, user_id, upload_id, asset_id_b58);
    Ok(())
}

fn parse_date_to_utc_midnight(ymd: &str) -> anyhow::Result<i64> {
    let d = chrono::NaiveDate::parse_from_str(ymd, "%Y-%m-%d")?;
    Ok(
        chrono::NaiveDateTime::new(d, chrono::NaiveTime::from_hms_opt(0, 0, 0).unwrap())
            .and_utc()
            .timestamp(),
    )
}

fn parse_pae3_header_for_asset_id_b58(path: &Path) -> anyhow::Result<(String, u8)> {
    use std::io::Read;
    let mut f = std::fs::File::open(path)?;
    let mut magic = [0u8; 4];
    f.read_exact(&mut magic)?;
    if &magic != b"PAE3" {
        anyhow::bail!("bad magic");
    }
    let mut vb = [0u8; 1];
    f.read_exact(&mut vb)?;
    let version = vb[0];
    let mut fb = [0u8; 1];
    f.read_exact(&mut fb)?; // flags
    let mut hlenb = [0u8; 4];
    f.read_exact(&mut hlenb)?;
    let hlen = u32::from_be_bytes(hlenb) as usize;
    let mut header_bytes = vec![0u8; hlen];
    f.read_exact(&mut header_bytes)?;
    let v: serde_json::Value = serde_json::from_slice(&header_bytes)?;
    let a = v
        .get("asset_id")
        .and_then(|x| x.as_str())
        .ok_or_else(|| anyhow::anyhow!("missing asset_id"))?;
    let aid_bytes = b64url_decode(a)?;
    if aid_bytes.len() != 16 {
        anyhow::bail!("asset_id len");
    }
    let b58 = bs58::encode(&aid_bytes).into_string();
    Ok((b58, version))
}

fn b64url_decode(s: &str) -> anyhow::Result<Vec<u8>> {
    let t = s.replace('-', "+").replace('_', "/");
    let pad = (4 - (t.len() % 4)) % 4;
    let mut t2 = t.clone();
    if pad > 0 {
        t2.push_str(&"=".repeat(pad));
    }
    Ok(base64::decode(&t2)?)
}

/// For locked uploads we don't have original filenames or content IDs.
/// Pair Live Photos by timestamp proximity (created_at) and typical Live video duration.
/// When both sides are present, mark the photo row as live and remove the separate video row.
fn try_pair_locked_by_timestamp(
    data_db: &crate::database::multi_tenant::DbPool,
    user_id: &str,
    created_at: i64,
    this_is_video: bool,
    this_path: &Path,
) {
    let window: i64 = std::env::var("LIVE_PAIR_LOCKED_TS_WINDOW_SECS")
        .ok()
        .and_then(|s| s.parse::<i64>().ok())
        .unwrap_or(3);
    let conn = data_db.lock();

    // Helper to fetch nearest counterpart
    let find_photo = || -> Option<(String, String)> {
        // asset_id, path
        let mut stmt = conn
            .prepare(
                "SELECT asset_id, path
                 FROM photos
                 WHERE COALESCE(locked, FALSE) = TRUE
                   AND COALESCE(delete_time, 0) = 0
                   AND is_video = FALSE
                   AND ABS(created_at - ?) <= ?
                 ORDER BY ABS(created_at - ?), id DESC
                 LIMIT 1",
            )
            .ok()?;
        stmt.query_row(duckdb::params![created_at, window, created_at], |r| {
            Ok((r.get(0)?, r.get(1)?))
        })
        .ok()
    };
    let find_live_like_video = || -> Option<(i32, String, i64)> {
        // id, path, duration_ms
        let mut stmt = conn
            .prepare(
                "SELECT id, path, COALESCE(duration_ms, 0)
                 FROM photos
                 WHERE COALESCE(locked, FALSE) = TRUE
                   AND COALESCE(delete_time, 0) = 0
                   AND is_video = TRUE
                   AND ABS(created_at - ?) <= ?
                 ORDER BY ABS(created_at - ?), id DESC
                 LIMIT 1",
            )
            .ok()?;
        stmt.query_row(duckdb::params![created_at, window, created_at], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?))
        })
        .ok()
    };

    // Decide pairing direction based on what just arrived
    if this_is_video {
        // We have a video; find a nearby photo
        if let Some((photo_asset_id, _photo_path)) = find_photo() {
            // Filter out non-Live long videos (keep short clips up to 6s as Live)
            let live_like = {
                let mut st = conn
                    .prepare("SELECT COALESCE(duration_ms,0) FROM photos WHERE path = ? LIMIT 1")
                    .ok();
                st.as_mut()
                    .and_then(|s| {
                        s.query_row(duckdb::params![&this_path.to_string_lossy()], |r| {
                            r.get::<_, i64>(0)
                        })
                        .ok()
                    })
                    .unwrap_or(0)
                    <= 6000
            };
            if live_like {
                let _ = conn.execute(
                    "UPDATE photos SET is_live_photo = TRUE, live_video_path = ? WHERE asset_id = ? AND is_video = FALSE",
                    duckdb::params![&this_path.to_string_lossy(), &photo_asset_id],
                );
                // Remove standalone video row to avoid duplicate display
                if let Ok(mut s) =
                    conn.prepare("SELECT id FROM photos WHERE path = ? AND is_video = TRUE LIMIT 1")
                {
                    if let Ok(vid_id) = s
                        .query_row(duckdb::params![&this_path.to_string_lossy()], |r| {
                            r.get::<_, i32>(0)
                        })
                    {
                        let _ = conn.execute(
                            "DELETE FROM album_photos WHERE photo_id = ?",
                            duckdb::params![vid_id],
                        );
                        let _ = conn
                            .execute("DELETE FROM photos WHERE id = ?", duckdb::params![vid_id]);
                    }
                }
                tracing::info!(target:"upload", "[LIVE-LOCKED] Paired by ts (user={}): photo_asset_id={} video_path={}", user_id, photo_asset_id, this_path.display());
            }
        }
    } else {
        // We have a photo; find a nearby video
        if let Some((vid_id, vpath, dur)) = find_live_like_video() {
            if dur <= 6000 && dur > 0 {
                // Use the current photo's path to resolve its asset_id, else fallback to nearest photo
                let photo_asset_id = {
                    let mut stmt = conn
                        .prepare("SELECT asset_id FROM photos WHERE path = ? AND is_video = FALSE LIMIT 1")
                        .ok();
                    stmt.as_mut()
                        .and_then(|s| {
                            s.query_row(duckdb::params![&this_path.to_string_lossy()], |r| {
                                r.get::<_, String>(0)
                            })
                            .ok()
                        })
                        .or_else(|| find_photo().map(|(aid, _)| aid))
                        .unwrap_or_default()
                };
                if !photo_asset_id.is_empty() {
                    let _ = conn.execute(
                        "UPDATE photos SET is_live_photo = TRUE, live_video_path = ? WHERE asset_id = ? AND is_video = FALSE",
                        duckdb::params![&vpath, &photo_asset_id],
                    );
                    // Remove standalone video row
                    let _ = conn.execute(
                        "DELETE FROM album_photos WHERE photo_id = ?",
                        duckdb::params![vid_id],
                    );
                    let _ =
                        conn.execute("DELETE FROM photos WHERE id = ?", duckdb::params![vid_id]);
                    tracing::info!(target:"upload", "[LIVE-LOCKED] Paired by ts (user={}): photo_asset_id={} video_path={}", user_id, photo_asset_id, vpath);
                }
            }
        }
    }
}

#[cfg(feature = "ee")]
#[cfg(feature = "ee")]
fn verify_public_link_for_upload(
    state: &AppState,
    link_id: &str,
    key: &str,
    pin: Option<&str>,
) -> Option<(String, Option<i32>)> {
    let users_db = state
        .multi_tenant_db
        .as_ref()
        .expect("users DB required in DuckDB mode")
        .users_connection();
    let conn = users_db.lock();
    // Load link row
    let row = conn
        .prepare(
            "SELECT owner_user_id, uploads_album_id, key_hash, pin_hash, status, CAST(expires_at AS VARCHAR)
             FROM ee_public_links WHERE id = ?",
        )
        .ok()?
        .query_row(duckdb::params![link_id], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, Option<i32>>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, Option<String>>(3)?,
                r.get::<_, String>(4)?,
                r.get::<_, Option<String>>(5)?,
            ))
        })
        .ok()?;
    let (owner_uid, uploads_album_id, key_hash, pin_hash_opt, status, _expires_at) = row;
    if status != "active" {
        return None;
    }
    // Verify key
    if !bcrypt_verify(key, &key_hash).unwrap_or(false) {
        return None;
    }
    // Verify PIN if required
    if let Some(ph) = pin_hash_opt.as_deref() {
        let provided = pin.unwrap_or("");
        // Public link PINs are exactly 8 characters (see ee/server/public_links.rs)
        if provided.chars().count() != 8 {
            return None;
        }
        if !bcrypt_verify(provided, ph).unwrap_or(false) {
            return None;
        }
    }
    Some((owner_uid, uploads_album_id))
}

fn sanitize_filename_preserve_ext(name: &str, fallback_ext: &str, asset_id: &str) -> String {
    // Remove directory components and control chars; allow unicode filenames
    let base = std::path::Path::new(name)
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("");
    let mut s: String = base
        .chars()
        .map(|c| {
            if c == '/' || c == '\\' || c == '\0' {
                '_'
            } else {
                c
            }
        })
        .collect();
    // Enforce a max length (255 typical)
    if s.len() > 255 {
        s.truncate(255);
    }
    // Ensure we have an extension; if missing, use fallback_ext
    let has_ext = std::path::Path::new(&s)
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| !e.is_empty())
        .unwrap_or(false);
    if s.is_empty() {
        return format!("{}.{}", asset_id, fallback_ext);
    }
    if has_ext {
        s
    } else if !fallback_ext.is_empty() {
        format!("{}.{}", s, fallback_ext)
    } else {
        s
    }
}

// Normalize a filename stem for Live pairing (e.g., IMG_E1234 -> IMG_1234)
fn normalize_stem(name: &str) -> String {
    let stem = name.rsplit_once('.').map(|(s, _)| s).unwrap_or(name).trim();
    let up = stem.to_ascii_uppercase();
    if let Some(tail) = up.strip_prefix("IMG_E") {
        format!("IMG_{}", tail)
    } else {
        up
    }
}

// Extract a string metadata value by trying common key variants
fn meta_get(meta: &Option<HashMap<String, String>>, keys: &[&str]) -> Option<String> {
    if let Some(m) = meta {
        for k in keys {
            if let Some(v) = m.get(*k) {
                let s = v.trim();
                if !s.is_empty() {
                    return Some(s.to_string());
                }
            }
        }
    }
    None
}

// Pair using a strong content_id provided by clients; works regardless of arrival order
fn try_pair_live_by_content_id(
    data_db: &crate::database::multi_tenant::DbPool,
    user_id: &str,
    content_id: &str,
    image_path_opt: Option<&Path>,
    video_path_opt: Option<&Path>,
    image_asset_opt: Option<&str>,
    video_asset_opt: Option<&str>,
) {
    {
        let conn = data_db.lock();
        let _ = conn.execute(
            "CREATE TABLE IF NOT EXISTS pending_live2 (
                user_id TEXT NOT NULL,
                content_id TEXT NOT NULL,
                image_asset_id TEXT,
                image_path TEXT,
                video_asset_id TEXT,
                video_path TEXT,
                first_seen_at INTEGER,
                PRIMARY KEY (user_id, content_id)
            )",
            [],
        );
    }

    {
        let conn = data_db.lock();
        let now = chrono::Utc::now().timestamp();
        if let Some(p) = image_path_opt {
            let _ = conn.execute(
                "INSERT INTO pending_live2(user_id, content_id, image_asset_id, image_path, first_seen_at)
                 VALUES (?, ?, ?, ?, ?) ON CONFLICT (user_id, content_id)
                 DO UPDATE SET image_asset_id = COALESCE(EXCLUDED.image_asset_id, image_asset_id), image_path = COALESCE(EXCLUDED.image_path, image_path)",
                duckdb::params![user_id, content_id, image_asset_opt, &p.to_string_lossy(), now],
            );
        }
        if let Some(v) = video_path_opt {
            let _ = conn.execute(
                "INSERT INTO pending_live2(user_id, content_id, video_asset_id, video_path, first_seen_at)
                 VALUES (?, ?, ?, ?, ?) ON CONFLICT (user_id, content_id)
                 DO UPDATE SET video_asset_id = COALESCE(EXCLUDED.video_asset_id, video_asset_id), video_path = COALESCE(EXCLUDED.video_path, video_path)",
                duckdb::params![user_id, content_id, video_asset_opt, &v.to_string_lossy(), now],
            );
        }
    }

    let (photo_row, video_row): (Option<(i32, String, String)>, Option<(i32, String, String)>) = {
        let conn = data_db.lock();
        let mut p: Option<(i32, String, String)> = None;
        let mut v: Option<(i32, String, String)> = None;
        if let Ok(mut s) = conn.prepare(
            "SELECT id, asset_id, path FROM photos WHERE is_video = 0 AND content_id = ? LIMIT 1",
        ) {
            p = s
                .query_row([content_id], |row| {
                    Ok((row.get(0)?, row.get(1)?, row.get(2)?))
                })
                .ok();
        }
        if let Ok(mut s) = conn.prepare(
            "SELECT id, asset_id, path FROM photos WHERE is_video = 1 AND content_id = ? LIMIT 1",
        ) {
            v = s
                .query_row([content_id], |row| {
                    Ok((row.get(0)?, row.get(1)?, row.get(2)?))
                })
                .ok();
        }
        (p, v)
    };

    match (photo_row.as_ref(), video_row.as_ref()) {
        (
            Some((photo_id, _photo_asset, _photo_path)),
            Some((video_id, _video_asset, video_path)),
        ) => {
            let conn = data_db.lock();
            let _ = conn.execute(
                "UPDATE photos SET is_live_photo = TRUE, live_video_path = ? WHERE id = ?",
                duckdb::params![video_path, *photo_id],
            );
            let _ = conn.execute(
                "INSERT INTO album_photos (organization_id, album_id, photo_id, added_at)
                 SELECT organization_id, album_id, ?, added_at FROM album_photos WHERE photo_id = ?
                 ON CONFLICT (organization_id, album_id, photo_id) DO NOTHING",
                duckdb::params![*photo_id, *video_id],
            );
            let _ = conn.execute(
                "DELETE FROM album_photos WHERE photo_id = ?",
                duckdb::params![*video_id],
            );
            let _ = conn.execute(
                "DELETE FROM photos WHERE id = ? AND is_video = 1",
                duckdb::params![*video_id],
            );
            let _ = conn.execute(
                "DELETE FROM pending_live2 WHERE user_id = ? AND content_id = ?",
                duckdb::params![user_id, content_id],
            );
            tracing::info!(target:"upload", "[LIVE-CID] Paired by content_id={} for user={}", content_id, user_id);
        }
        _ => {
            tracing::info!(target:"upload", "[LIVE-CID] Pending side captured (cid={}, user={}, photo?={}, video?={})", content_id, user_id, photo_row.is_some(), video_row.is_some());
        }
    }
}

fn try_pair_live_by_filename(
    state: &Arc<AppState>,
    data_db: &crate::database::multi_tenant::DbPool,
    user_id: &str,
    original_filename: &str,
    photo_path_opt: Option<&Path>,
    video_path_opt: Option<&Path>,
) {
    // Derive normalized base name from actual file path if available; fallback to provided filename
    let stem_norm = if let Some(p) = photo_path_opt.or(video_path_opt) {
        let name = p
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or(original_filename)
            .trim();
        normalize_stem(name)
    } else {
        normalize_stem(original_filename.trim())
    };

    // Prepare timestamps using best-effort file metadata
    let ts_photo = photo_path_opt
        .and_then(|p| std::fs::metadata(p).ok())
        .and_then(|m| m.created().ok().or_else(|| m.modified().ok()))
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs() as i64);
    let ts_video = video_path_opt
        .and_then(|p| std::fs::metadata(p).ok())
        .and_then(|m| m.created().ok().or_else(|| m.modified().ok()))
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs() as i64);

    // Create pending table if needed
    {
        let conn = data_db.lock();
        let _ = conn.execute(
            "CREATE TABLE IF NOT EXISTS pending_live (
                user_id TEXT NOT NULL,
                base_name TEXT NOT NULL,
                image_asset_id TEXT,
                image_path TEXT,
                image_ts INTEGER,
                video_path TEXT,
                video_ts INTEGER,
                first_seen_at INTEGER,
                PRIMARY KEY (user_id, base_name)
            )",
            [],
        );
    }

    // Upsert the side we just ingested
    {
        let conn = data_db.lock();
        let now = chrono::Utc::now().timestamp();
        if let Some(photo_path) = photo_path_opt {
            // Lookup photo asset_id by path we just inserted
            let image_asset_id: Option<String> = conn
                .query_row(
                    "SELECT asset_id FROM photos WHERE path = ? AND is_video = FALSE LIMIT 1",
                    duckdb::params![&photo_path.to_string_lossy()],
                    |row| row.get::<_, String>(0),
                )
                .ok();
            let _ = conn.execute(
                "INSERT INTO pending_live(user_id, base_name, image_asset_id, image_path, image_ts, first_seen_at) VALUES (?, ?, ?, ?, ?, ?) \
                 ON CONFLICT (user_id, base_name) DO UPDATE SET image_asset_id = COALESCE(EXCLUDED.image_asset_id, image_asset_id), image_path = COALESCE(EXCLUDED.image_path, image_path), image_ts = COALESCE(EXCLUDED.image_ts, image_ts)",
                duckdb::params![
                    user_id,
                    &stem_norm,
                    image_asset_id.as_deref(),
                    &photo_path.to_string_lossy(),
                    ts_photo.unwrap_or(now),
                    now
                ],
            );
        }
        if let Some(video_path) = video_path_opt {
            let _ = conn.execute(
                "INSERT INTO pending_live(user_id, base_name, video_path, video_ts, first_seen_at) VALUES (?, ?, ?, ?, ?) \
                 ON CONFLICT (user_id, base_name) DO UPDATE SET video_path = COALESCE(EXCLUDED.video_path, video_path), video_ts = COALESCE(EXCLUDED.video_ts, video_ts)",
                duckdb::params![
                    user_id,
                    &stem_norm,
                    &video_path.to_string_lossy(),
                    ts_video.unwrap_or(now),
                    now
                ],
            );
        }
    }

    // Try to complete pairing if both sides exist with reasonable ts window
    let (mut image_asset_id_opt, video_path_opt2, its, vts) = {
        let conn = data_db.lock();
        let mut stmt = conn
            .prepare("SELECT image_asset_id, video_path, COALESCE(image_ts,0), COALESCE(video_ts,0) FROM pending_live WHERE user_id = ? AND base_name = ? LIMIT 1")
            .ok();
        if let Some(ref mut s) = stmt {
            s.query_row(duckdb::params![user_id, &stem_norm], |row| {
                Ok((
                    row.get::<_, Option<String>>(0)?,
                    row.get::<_, Option<String>>(1)?,
                    row.get::<_, i64>(2)?,
                    row.get::<_, i64>(3)?,
                ))
            })
            .ok()
        } else {
            None
        }
    }
    .unwrap_or((None, None, 0, 0));

    // If we have no image asset yet, try to locate an existing photo row by filename stem.
    if image_asset_id_opt.is_none() {
        let stem_a = stem_norm.clone(); // e.g., IMG_1234
        let stem_b = if let Some(tail) = stem_norm.strip_prefix("IMG_") {
            format!("IMG_E{}", tail)
        } else {
            stem_norm.clone()
        };
        let conn = data_db.lock();
        // Prefer exact stem match on filename start; order by created_at desc to pick the most recent
        if let Ok(mut stmt) = conn.prepare("SELECT asset_id FROM photos WHERE is_video = FALSE AND (filename LIKE ? OR filename LIKE ?) ORDER BY created_at DESC LIMIT 1") {
            let like_a = format!("{}.%", stem_a);
            let like_b = format!("{}.%", stem_b);
            if let Ok(found) = stmt.query_row(duckdb::params![&like_a, &like_b], |row| row.get::<_, String>(0)) {
                image_asset_id_opt = Some(found.clone());
                // Update pending row to speed future pair checks
                let _ = conn.execute(
                    "UPDATE pending_live SET image_asset_id = ? WHERE user_id = ? AND base_name = ?",
                    duckdb::params![&found, user_id, &stem_norm],
                );
            }
        }
    }

    if let (Some(image_asset_id), Some(vpath)) = (image_asset_id_opt, video_path_opt2.as_deref()) {
        let delta = (its - vts).abs();
        let window: i64 = std::env::var("LIVE_PAIR_WINDOW_SECS")
            .ok()
            .and_then(|s| s.parse::<i64>().ok())
            .unwrap_or(300); // 5 minutes default
        if delta <= window {
            // Link: mark photo as live and attach video path
            let conn = data_db.lock();
            let _ = conn.execute(
                "UPDATE photos SET is_live_photo = TRUE, live_video_path = ? WHERE asset_id = ? AND is_video = FALSE",
                duckdb::params![&vpath, &image_asset_id],
            );
            // Remove standalone MOV row if present, making sure to clear album_photos references first
            if let Ok(mut stmt) =
                conn.prepare("SELECT id FROM photos WHERE path = ? AND is_video = TRUE LIMIT 1")
            {
                if let Ok(vid_id) =
                    stmt.query_row(duckdb::params![&vpath], |row| row.get::<_, i32>(0))
                {
                    let _ = conn.execute(
                        "DELETE FROM album_photos WHERE photo_id = ?",
                        duckdb::params![vid_id],
                    );
                    let _ =
                        conn.execute("DELETE FROM photos WHERE id = ?", duckdb::params![vid_id]);
                }
            }
            // Clear pending row
            let _ = conn.execute(
                "DELETE FROM pending_live WHERE user_id = ? AND base_name = ?",
                duckdb::params![user_id, &stem_norm],
            );
            tracing::info!(target:"upload", "[LIVE] Paired Live Photo: user={} base={} image_asset_id={} video_path={}", user_id, stem_norm, image_asset_id, vpath);
        } else {
            tracing::info!(target:"upload", "[LIVE] Pending pair (time delta {}s exceeds window {}) base={} user={}", delta, window, stem_norm, user_id);
        }
    } else {
        tracing::info!(target:"upload", "[LIVE] Pending side captured: base={} user={} photo?={} video?={}", stem_norm, user_id, photo_path_opt.is_some(), video_path_opt.is_some());
    }
}

#[derive(Debug, Deserialize)]
pub struct UploadsStreamQuery {
    pub token: Option<String>,
    pub user_id: Option<String>,
}

#[tracing::instrument(skip(state, headers, payload))]
pub async fn uploads_ingested(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(payload): Json<UploadsIngestedRequest>,
) -> Result<impl IntoResponse, crate::server::AppError> {
    let user = auth_user_from_headers(&headers, &state).await?;
    let requested: Vec<String> = payload
        .content_ids
        .into_iter()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
        .take(2_000)
        .collect();
    if requested.is_empty() {
        return Ok(Json(UploadsIngestedResponse {
            ingested_content_ids: Vec::new(),
        }));
    }

    let ingested_content_ids = if let Some(pg) = &state.pg_client {
        let mut params: Vec<&(dyn tokio_postgres::types::ToSql + Sync)> = Vec::new();
        params.push(&user.organization_id);
        params.push(&user.user_id);
        let mut placeholders: Vec<String> = Vec::with_capacity(requested.len());
        for (i, content_id) in requested.iter().enumerate() {
            placeholders.push(format!("${}", i + 3));
            params.push(content_id);
        }
        let sql = format!(
            "SELECT DISTINCT content_id
             FROM photos
             WHERE organization_id = $1
               AND user_id = $2
               AND COALESCE(delete_time, 0) = 0
               AND COALESCE(content_id, '') <> ''
               AND COALESCE(locked, FALSE) = FALSE
               AND COALESCE(is_live_photo, FALSE) = FALSE
               AND content_id IN ({})",
            placeholders.join(",")
        );
        pg.query(&sql, &params)
            .await
            .map_err(|e| crate::server::AppError(anyhow::anyhow!(e.to_string())))?
            .into_iter()
            .filter_map(|row| row.try_get::<_, String>(0).ok())
            .collect()
    } else {
        let data_db = state.get_user_data_database(&user.user_id)?;
        let mut query = String::from(
            "SELECT DISTINCT content_id
             FROM photos
             WHERE organization_id = ?
               AND user_id = ?
               AND COALESCE(delete_time, 0) = 0
               AND COALESCE(content_id, '') <> ''
               AND COALESCE(locked, FALSE) = FALSE
               AND COALESCE(is_live_photo, FALSE) = FALSE
               AND content_id IN (",
        );
        query.push_str(&vec!["?"; requested.len()].join(","));
        query.push(')');
        let mut params: Vec<Box<dyn duckdb::ToSql>> = Vec::with_capacity(2 + requested.len());
        params.push(Box::new(user.organization_id));
        params.push(Box::new(user.user_id.clone()));
        for content_id in &requested {
            params.push(Box::new(content_id.clone()));
        }
        let conn = data_db.lock();
        let mut stmt = conn
            .prepare(&query)
            .map_err(|e| crate::server::AppError(anyhow::anyhow!(e.to_string())))?;
        let mapped = stmt
            .query_map(
                duckdb::params_from_iter(params.iter().map(|param| &**param)),
                |row| row.get::<_, String>(0),
            )
            .map_err(|e| crate::server::AppError(anyhow::anyhow!(e.to_string())))?;
        let mut rows = Vec::new();
        for row in mapped {
            if let Ok(content_id) = row {
                rows.push(content_id);
            }
        }
        rows
    };

    Ok(Json(UploadsIngestedResponse {
        ingested_content_ids,
    }))
}

#[tracing::instrument(skip(state, headers))]
pub async fn uploads_stream(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    q: Option<Query<UploadsStreamQuery>>,
) -> Result<
    Sse<impl futures::Stream<Item = Result<Event, std::convert::Infallible>>>,
    crate::server::AppError,
> {
    // Validate auth with relaxed fallbacks for background reconnection
    let user_res = auth_user_from_headers(&headers, &state).await;
    let user_id = match user_res {
        Ok(u) => u.user_id,
        Err(_) => {
            // Fallback 1: token in query string
            if let Some(Query(ref qp)) = q {
                if let Some(ref tok) = qp.token {
                    if let Ok(u) = state.auth_service.verify_token(tok).await {
                        u.user_id
                    } else {
                        // Fallback 2 (optional, controlled by env): accept user_id without token
                        let allow = std::env::var("ALLOW_UPLOADS_SSE_NOAUTH")
                            .ok()
                            .map(|s| {
                                matches!(s.to_ascii_lowercase().as_str(), "1" | "true" | "yes")
                            })
                            .unwrap_or(false);
                        if allow {
                            qp.user_id.clone().unwrap_or_default()
                        } else {
                            return Err(crate::server::AppError(anyhow::anyhow!("unauthorized")));
                        }
                    }
                } else {
                    let allow = std::env::var("ALLOW_UPLOADS_SSE_NOAUTH")
                        .ok()
                        .map(|s| matches!(s.to_ascii_lowercase().as_str(), "1" | "true" | "yes"))
                        .unwrap_or(false);
                    if allow {
                        qp.user_id.clone().unwrap_or_default()
                    } else {
                        return Err(crate::server::AppError(anyhow::anyhow!("unauthorized")));
                    }
                }
            } else {
                return Err(crate::server::AppError(anyhow::anyhow!("unauthorized")));
            }
        }
    };
    if user_id.is_empty() {
        return Err(crate::server::AppError(anyhow::anyhow!("unauthorized")));
    }
    let rx = state.subscribe_upload_channel(&user_id);
    let msg_stream = BroadcastStream::new(rx)
        .filter_map(|msg| futures::future::ready(msg.ok()))
        .map(|s| Ok(Event::default().data(s)));
    let heartbeat = IntervalStream::new(time::interval(Duration::from_secs(20)))
        .map(|_| Ok(Event::default().data("{\"type\":\"heartbeat\"}")));
    let stream = futures::stream::select(msg_stream, heartbeat);
    Ok(Sse::new(stream))
}
