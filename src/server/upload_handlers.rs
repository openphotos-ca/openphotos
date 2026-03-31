use axum::{
    extract::{Multipart, State},
    http::{header, HeaderMap, StatusCode},
    response::IntoResponse,
    Json,
};
use serde::Serialize;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use crate::server::state::AppState;
use crate::server::AppError;

#[derive(Serialize)]
pub struct UploadResultItem {
    pub filename: String,
    pub queued: bool,
}

#[derive(Serialize)]
pub struct UploadResponse {
    pub uploaded: Vec<UploadResultItem>,
}

/// Multipart upload endpoint compatible with iOS clients.
/// Streams each file part to a temporary path and then invokes the same ingest
/// pipeline as TUS post-finish (moves to canonical path, indexes, emits SSE).
pub async fn upload_multipart(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    mut multipart: Multipart,
) -> impl IntoResponse {
    // Auth (Authorization bearer or auth-token cookie)
    let token_opt = headers
        .get(header::AUTHORIZATION)
        .and_then(|h| h.to_str().ok())
        .and_then(|h| h.strip_prefix("Bearer "))
        .map(|s| s.to_string())
        .or_else(|| {
            headers
                .get(header::COOKIE)
                .and_then(|v| v.to_str().ok())
                .and_then(|cookie| {
                    cookie
                        .split(';')
                        .map(|c| c.trim())
                        .find_map(|c| c.strip_prefix("auth-token=").map(|s| s.to_string()))
                })
        });
    let token = match token_opt {
        Some(t) => t,
        None => {
            return (
                StatusCode::UNAUTHORIZED,
                Json(serde_json::json!({"error":"unauthorized"})),
            )
                .into_response()
        }
    };
    let user = match state.auth_service.verify_token(&token).await {
        Ok(u) => u,
        Err(_) => {
            return (
                StatusCode::UNAUTHORIZED,
                Json(serde_json::json!({"error":"unauthorized"})),
            )
                .into_response()
        }
    };

    #[cfg(feature = "ee")]
    {
        // Enforce first-login password change before allowing uploads (EE only)
        let must_change: bool = if let Some(pg) = &state.pg_client {
            pg.query_opt(
                "SELECT COALESCE(must_change_password, FALSE) FROM users WHERE user_id=$1",
                &[&user.user_id],
            )
            .await
            .ok()
            .flatten()
            .map(|r| r.get::<_, bool>(0))
            .unwrap_or(false)
        } else {
            let users_db = state
                .multi_tenant_db
                .as_ref()
                .expect("users DB required in DuckDB mode")
                .users_connection();
            let conn = users_db.lock();
            conn.query_row(
                "SELECT COALESCE(must_change_password, FALSE) FROM users WHERE user_id = ?",
                [user.user_id.as_str()],
                |row| row.get::<_, bool>(0),
            )
            .unwrap_or(false)
        };
        if must_change {
            return (
                StatusCode::FORBIDDEN,
                Json(serde_json::json!({"error":"password_change_required"})),
            )
                .into_response();
        }
    }

    // Optional common album id from multipart fields (albumId)
    // Accumulate text fields encountered (applies to the next file part)
    let mut current_meta: HashMap<String, String> = HashMap::new();
    // For each staged file, we will spawn ingestion asynchronously immediately after saving
    // Also collect a small response payload for the client
    let mut results: Vec<UploadResultItem> = Vec::new();

    // Prepare uploads staging dir
    let base_dir = std::env::var_os("RUSTUS_DATA_DIR")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .or_else(|| {
            std::env::var_os("DATABASE_PATH")
                .filter(|value| !value.is_empty())
                .map(|value| PathBuf::from(value).join("uploads"))
        })
        .unwrap_or_else(|| Path::new("data").join("uploads"));
    if let Err(e) = tokio::fs::create_dir_all(&base_dir).await {
        tracing::error!(target = "upload", "create uploads dir failed: {}", e);
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(serde_json::json!({"error":"create_dir_failed"})),
        )
            .into_response();
    }

    // First pass: read parts; for file parts, stream to disk; for text fields, record albumId
    while let Some(mut field) = match multipart.next_field().await {
        Ok(f) => f,
        Err(e) => {
            tracing::warn!(target = "upload", "multipart parse error: {}", e);
            return (
                StatusCode::BAD_REQUEST,
                Json(serde_json::json!({"error":"multipart_parse"})),
            )
                .into_response();
        }
    } {
        let name = field.name().unwrap_or("").to_string();
        // Text field: store in current_meta for association with the next file part
        if field.file_name().is_none() {
            if let Ok(val) = field.text().await {
                current_meta.insert(name.clone(), val);
            }
            continue;
        }

        // File parts
        let file_name = field.file_name().map(|s| s.to_string());
        if let Some(fname) = file_name {
            let upload_id = uuid::Uuid::new_v4().to_string();
            let tmp_path = base_dir.join(&upload_id);
            let mut file = match tokio::fs::File::create(&tmp_path).await {
                Ok(f) => f,
                Err(e) => {
                    tracing::error!(target = "upload", "create temp file failed: {}", e);
                    return (
                        StatusCode::INTERNAL_SERVER_ERROR,
                        Json(serde_json::json!({"error":"tempfile"})),
                    )
                        .into_response();
                }
            };
            loop {
                match field.chunk().await {
                    Ok(Some(chunk)) => {
                        use tokio::io::AsyncWriteExt;
                        if let Err(e) = file.write_all(&chunk).await {
                            tracing::error!(target = "upload", "write chunk failed: {}", e);
                            return (
                                StatusCode::INTERNAL_SERVER_ERROR,
                                Json(serde_json::json!({"error":"write_failed"})),
                            )
                                .into_response();
                        }
                    }
                    Ok(None) => break,
                    Err(e) => {
                        tracing::warn!(target = "upload", "read chunk failed: {}", e);
                        return (
                            StatusCode::BAD_REQUEST,
                            Json(serde_json::json!({"error":"read_failed"})),
                        )
                            .into_response();
                    }
                }
            }
            // Snapshot meta for this file; also record filename explicitly
            let mut meta_snapshot = current_meta.clone();
            meta_snapshot
                .entry("filename".into())
                .or_insert(fname.clone());

            // Spawn ingestion asynchronously so we can return immediately after multipart ends
            let state_clone = state.clone();
            let user_id_clone = user.user_id.clone();
            let upload_id_clone = upload_id.clone();
            let tmp_clone = tmp_path.clone();
            tokio::spawn(async move {
                if let Err(e) = crate::server::upload_hooks::ingest_finished_upload(
                    &state_clone,
                    &user_id_clone,
                    &upload_id_clone,
                    None,
                    &tmp_clone,
                    Some(meta_snapshot),
                    Some("multipart"),
                )
                .await
                {
                    tracing::warn!(
                        target = "upload",
                        "[UPLOAD-multipart] ingestion failed (user={}, tmp={}, err={})",
                        user_id_clone,
                        tmp_clone.display(),
                        e
                    );
                    state_clone.record_sync_failure(&user_id_clone);
                }
            });

            // Record result as queued
            results.push(UploadResultItem {
                filename: fname,
                queued: true,
            });
        }
    }

    (StatusCode::OK, Json(UploadResponse { uploaded: results })).into_response()
}
