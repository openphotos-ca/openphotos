use axum::{
    extract::State,
    http::{header, HeaderMap, StatusCode},
    response::IntoResponse,
    Json,
};
use serde_json::Value;
use std::sync::Arc;

use crate::server::{state::AppState, AppError};

async fn get_user_from_headers(
    headers: &HeaderMap,
    state: &AppState,
) -> Result<crate::auth::types::User, AppError> {
    // Authorization: Bearer <token> or cookie 'auth-token'
    if let Some(token) = headers
        .get(header::AUTHORIZATION)
        .and_then(|h| h.to_str().ok())
        .and_then(|h| h.strip_prefix("Bearer "))
    {
        let user = state.auth_service.verify_token(token).await?;
        return Ok(user);
    }
    if let Some(cookie_hdr) = headers.get(header::COOKIE).and_then(|v| v.to_str().ok()) {
        for part in cookie_hdr.split(';') {
            let trimmed = part.trim();
            if let Some(val) = trimmed.strip_prefix("auth-token=") {
                let user = state.auth_service.verify_token(val).await?;
                return Ok(user);
            }
        }
    }
    Err(AppError(anyhow::anyhow!("Missing authorization token")))
}

pub async fn get_envelope(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, AppError> {
    let user = get_user_from_headers(&headers, &state).await?;
    if let Some(pg) = &state.pg_client {
        let row = pg
            .query_opt(
                "SELECT crypto_envelope_json, CAST(crypto_envelope_updated_at AS VARCHAR) FROM users WHERE user_id=$1 LIMIT 1",
                &[&user.user_id],
            )
            .await
            .map_err(|e| AppError(anyhow::anyhow!(e)))?;
        let (json_opt, updated_at_opt) = row
            .map(|r| (r.get::<_, Option<String>>(0), r.get::<_, Option<String>>(1)))
            .unwrap_or((None, None));
        tracing::info!(
            target = "upload",
            "[E2EE] GET envelope (PG) user_id={} has_envelope={}",
            user.user_id,
            json_opt.is_some()
        );
        let env_val: Option<Value> = json_opt
            .as_deref()
            .and_then(|s| serde_json::from_str::<Value>(s).ok());
        let body = serde_json::json!({
            "envelope": env_val,
            "updated_at": updated_at_opt,
        });
        return Ok(Json(body));
    }
    let users_db = state
        .multi_tenant_db
        .as_ref()
        .expect("users DB required in DuckDB mode")
        .users_connection();
    let conn = users_db.lock();
    let row = conn
        .prepare(
            "SELECT crypto_envelope_json, CAST(crypto_envelope_updated_at AS VARCHAR) FROM users WHERE user_id = ? LIMIT 1",
        )?
        .query_row([user.user_id.as_str()], |row| {
            Ok((row.get::<_, Option<String>>(0)?, row.get::<_, Option<String>>(1)?))
        })
        .unwrap_or((None, None));
    let (json_opt, updated_at_opt) = row;
    let env_val: Option<Value> = json_opt
        .as_deref()
        .and_then(|s| serde_json::from_str::<Value>(s).ok());
    let body = serde_json::json!({
        "envelope": env_val,
        "updated_at": updated_at_opt,
    });
    Ok(Json(body))
}

pub async fn post_envelope(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(body): Json<Value>,
) -> Result<impl IntoResponse, AppError> {
    let user = get_user_from_headers(&headers, &state).await?;
    let now = chrono::Utc::now().timestamp();
    let json_str = serde_json::to_string(&body).unwrap_or_else(|_| "{}".to_string());
    if let Some(pg) = &state.pg_client {
        let rows = pg
            .execute(
                "UPDATE users SET crypto_envelope_json = $1::text, crypto_envelope_updated_at = NOW() WHERE user_id = $2",
                &[&json_str.as_str(), &user.user_id],
            )
            .await;
        match rows {
            Ok(n) => {
                tracing::info!(
                    target = "upload",
                    "[E2EE] POST envelope (PG) user_id={} updated_rows={}",
                    user.user_id,
                    n
                );
                if n == 0 {
                    // Defensive: signal failure to persist so clients can retry
                    return Ok((
                        StatusCode::BAD_REQUEST,
                        Json(
                            serde_json::json!({"ok": false, "error": "user not found for envelope"}),
                        ),
                    ));
                }
                return Ok((StatusCode::OK, Json(serde_json::json!({"ok": true}))));
            }
            Err(e) => {
                tracing::warn!(target = "upload", "[E2EE] POST envelope (PG) failed: {}", e);
                return Ok((
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(serde_json::json!({"ok": false, "error": "failed to save envelope"})),
                ));
            }
        }
    }
    let users_db = state
        .multi_tenant_db
        .as_ref()
        .expect("users DB required in DuckDB mode")
        .users_connection();
    let conn = users_db.lock();
    let _ = conn.execute(
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS crypto_envelope_json TEXT",
        [],
    );
    let _ = conn.execute(
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS crypto_envelope_updated_at TIMESTAMP",
        [],
    );
    let _ = conn.execute(
        "UPDATE users SET crypto_envelope_json = ?, crypto_envelope_updated_at = TO_TIMESTAMP(?) WHERE user_id = ?",
        duckdb::params![json_str, now, user.user_id],
    );
    Ok((StatusCode::OK, Json(serde_json::json!({"ok": true}))))
}
