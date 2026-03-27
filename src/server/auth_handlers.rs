use axum::{
    extract::{Query, State},
    http::{header, HeaderMap, StatusCode},
    response::{
        sse::{Event, Sse},
        IntoResponse, Redirect,
    },
    Json,
};
use futures::StreamExt as FStreamExt;
use image::GenericImageView;
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::Arc;
use tokio::sync::broadcast;
use tokio::time::{self, Duration};
use tokio_stream::wrappers::{BroadcastStream, IntervalStream};
use tracing::{debug, instrument};

use crate::auth::oauth::{OAuthConfig, OAuthService};
use crate::auth::types::{
    LoginFinishRequest, LoginStartRequest, LoginStartResponse, LoginStartResponseItem,
    PasswordChangeRequest,
};
use crate::auth::{AuthService, LoginRequest, RegisterRequest};
use crate::face_processing::FaceQualitySettings;
use crate::server::{demo_policy::ensure_not_demo_mutation, state::AppState, AppError};

pub struct AuthHandlers {
    auth_service: Arc<AuthService>,
}

impl AuthHandlers {
    pub fn new(auth_service: Arc<AuthService>) -> Self {
        Self { auth_service }
    }
}

// Aggregated timing stats for indexing
#[derive(Default)]
struct IndexTimingStats {
    photo_us: AtomicU64,
    video_us: AtomicU64,
    photos_count: AtomicUsize,
    videos_count: AtomicUsize,
}

#[derive(Debug, Deserialize)]
pub struct LoginQuery {
    pub email: String,
    pub password: String,
}

#[derive(Debug, Deserialize)]
pub struct RegisterQuery {
    pub name: String,
    pub email: String,
    pub password: String,
    pub organization_id: Option<i32>,
}

#[derive(Debug, Deserialize)]
pub struct OAuthCallbackQuery {
    pub code: String,
    pub state: Option<String>,
}

#[instrument(skip(state))]
pub async fn register(
    State(state): State<Arc<AppState>>,
    Json(request): Json<RegisterRequest>,
) -> Result<impl IntoResponse, AppError> {
    let email_preview = request.email.clone();
    tracing::info!("[AUTH] register attempt email={}", email_preview);
    let response = match state.auth_service.register(request).await {
        Ok(r) => {
            tracing::info!("[AUTH] register success email={}", email_preview);
            r
        }
        Err(e) => {
            tracing::error!("[AUTH] register failed email={} err={}", email_preview, e);
            return Err(e.into());
        }
    };

    // Set short-lived access cookie and long-lived refresh cookie
    let access_max_age = std::env::var("ACCESS_TOKEN_TTL_MINUTES")
        .ok()
        .and_then(|v| v.parse::<i64>().ok())
        .unwrap_or(15)
        * 60; // seconds
    let access_cookie = format!(
        "auth-token={}; Max-Age={}; Path=/; HttpOnly; SameSite=Lax",
        response.token, access_max_age
    );
    let refresh_max_age = std::env::var("REFRESH_TOKEN_TTL_DAYS")
        .ok()
        .and_then(|v| v.parse::<i64>().ok())
        .unwrap_or(30)
        * 24
        * 3600;
    let mut headers = HeaderMap::new();
    headers.insert(
        header::SET_COOKIE,
        axum::http::HeaderValue::from_str(&access_cookie).unwrap(),
    );
    if let Some(ref_token) = &response.refresh_token {
        let refresh_cookie = format!(
            "refresh-token={}; Max-Age={}; Path=/; HttpOnly; SameSite=Lax",
            ref_token, refresh_max_age
        );
        headers.append(
            header::SET_COOKIE,
            axum::http::HeaderValue::from_str(&refresh_cookie).unwrap(),
        );
    }

    Ok((StatusCode::CREATED, headers, Json(response)))
}

#[instrument(skip(state))]
pub async fn login(
    State(state): State<Arc<AppState>>,
    Json(request): Json<LoginRequest>,
) -> Result<impl IntoResponse, AppError> {
    let response = state.auth_service.login(request).await?;

    // Also set an HttpOnly cookie so SSE EventSource requests can authenticate
    let max_age = 7 * 24 * 3600; // 7 days
                                 // Access cookie (short-lived)
    let access_max_age = std::env::var("ACCESS_TOKEN_TTL_MINUTES")
        .ok()
        .and_then(|v| v.parse::<i64>().ok())
        .unwrap_or(15)
        * 60; // seconds
    let mut access_cookie = format!(
        "auth-token={}; Max-Age={}; Path=/; HttpOnly; SameSite=Lax",
        response.token, access_max_age
    );
    // Refresh cookie (long-lived). Note: refresh is not returned in JSON; clients can keep it in cookie.
    let refresh_max_age = std::env::var("REFRESH_TOKEN_TTL_DAYS")
        .ok()
        .and_then(|v| v.parse::<i64>().ok())
        .unwrap_or(30)
        * 24
        * 3600;
    let cookie_secure = std::env::var("COOKIE_SECURE")
        .ok()
        .map(|s| matches!(s.to_ascii_lowercase().as_str(), "1" | "true" | "yes"))
        .unwrap_or(false);
    if cookie_secure {
        access_cookie.push_str("; Secure");
    }
    // For cookie value, we need the actual refresh token. Regenerate via refresh-with-token? Simpler: issue one at login in service and return via header for cookie only.
    // As AuthResponse does not expose refresh token, we read it from a temporary header set by service (not available). Instead, accept setting refresh on refresh endpoint. For login, set only auth-token cookie now.
    let mut headers = HeaderMap::new();
    headers.insert(
        header::SET_COOKIE,
        axum::http::HeaderValue::from_str(&access_cookie).unwrap(),
    );
    if let Some(ref_token) = &response.refresh_token {
        let refresh_cookie = format!(
            "refresh-token={}; Max-Age={}; Path=/; HttpOnly; SameSite=Lax",
            ref_token, refresh_max_age
        );
        headers.append(
            header::SET_COOKIE,
            axum::http::HeaderValue::from_str(&refresh_cookie).unwrap(),
        );
    }

    Ok((StatusCode::OK, headers, Json(response)))
}

#[instrument(skip(state))]
pub async fn change_password(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(req): Json<PasswordChangeRequest>,
) -> Result<impl IntoResponse, AppError> {
    // Extract token and resolve user
    let token = headers
        .get(header::AUTHORIZATION)
        .and_then(|h| h.to_str().ok())
        .and_then(|h| h.strip_prefix("Bearer "))
        .ok_or_else(|| anyhow::anyhow!("Missing authorization token"))?;
    let user = state.auth_service.verify_token(token).await?;
    ensure_not_demo_mutation(&state, &user.user_id, "POST /api/auth/password/change").await?;
    // If current_password is omitted and user is flagged must_change_password, allow update without verifying current
    let mut handled_inline = false;
    if req.current_password.as_deref().unwrap_or("").is_empty() {
        // In Postgres mode, this flag is EE-only and not present; require current password flow.
        // In DuckDB mode (OSS), honor the flag if present.
        let must_change = if state.pg_client.is_some() {
            false
        } else {
            let conn = state
                .multi_tenant_db
                .as_ref()
                .expect("users DB required in DuckDB mode")
                .users_connection();
            let conn = conn.lock();
            let mut stmt = conn.prepare(
                "SELECT COALESCE(must_change_password, FALSE) FROM users WHERE user_id = ? LIMIT 1",
            )?;
            stmt.query_row(duckdb::params![&user.user_id], |row| row.get::<_, bool>(0))
                .unwrap_or(false)
        };
        if must_change {
            // Inline password update without verifying current
            use bcrypt::hash;
            let new_pw = req.new_password.clone();
            let new_hash = tokio::task::spawn_blocking(move || hash(&new_pw, 4))
                .await
                .map_err(|e| AppError(anyhow::anyhow!(e.to_string())))?
                .map_err(|e| AppError(anyhow::anyhow!(e.to_string())))?;
            if let Some(pg) = &state.pg_client {
                // PG path (EE field: must_change_password). Clear must_change flag if present and rotate tokens.
                let _ = pg
                    .execute(
                        "UPDATE users SET password_hash=$1 WHERE user_id=$2",
                        &[&new_hash, &user.user_id],
                    )
                    .await;
                let _ = pg
                    .execute(
                        "DELETE FROM sessions WHERE user_id = (SELECT id FROM users WHERE user_id=$1)",
                        &[&user.user_id],
                    )
                    .await;
                let _ = pg
                    .execute(
                        "UPDATE refresh_tokens SET revoked_at = NOW() WHERE user_id = (SELECT id FROM users WHERE user_id=$1) AND revoked_at IS NULL",
                        &[&user.user_id],
                    )
                    .await;
            } else {
                let conn = state
                    .multi_tenant_db
                    .as_ref()
                    .expect("users DB required in DuckDB mode")
                    .users_connection();
                let conn = conn.lock();
                let _ = conn.execute(
                    "UPDATE users SET password_hash = ?, must_change_password = FALSE, token_version = token_version + 1 WHERE user_id = ?",
                    duckdb::params![new_hash, &user.user_id],
                );
                let _ = conn.execute(
                    "DELETE FROM sessions WHERE user_id = (SELECT id FROM users WHERE user_id = ?)",
                    duckdb::params![&user.user_id],
                );
                let _ = conn.execute("UPDATE refresh_tokens SET revoked_at = CURRENT_TIMESTAMP WHERE user_id = (SELECT id FROM users WHERE user_id = ?)", duckdb::params![&user.user_id]);
            }
            handled_inline = true;
        }
    }
    if !handled_inline {
        // Default: require current password verification
        state
            .auth_service
            .change_password(
                &user.user_id,
                req.current_password.as_deref().unwrap_or(""),
                &req.new_password,
            )
            .await?;
    }

    // Clear auth cookies to force re-login
    let mut h = HeaderMap::new();
    let cookie_secure = std::env::var("COOKIE_SECURE")
        .ok()
        .map(|s| matches!(s.to_ascii_lowercase().as_str(), "1" | "true" | "yes"))
        .unwrap_or(false);
    let mut clear_access = "auth-token=; Max-Age=0; Path=/; HttpOnly; SameSite=Lax".to_string();
    let mut clear_refresh = "refresh-token=; Max-Age=0; Path=/; HttpOnly; SameSite=Lax".to_string();
    if cookie_secure {
        clear_access.push_str("; Secure");
        clear_refresh.push_str("; Secure");
    }
    h.insert(
        header::SET_COOKIE,
        axum::http::HeaderValue::from_str(&clear_access).unwrap(),
    );
    h.append(
        header::SET_COOKIE,
        axum::http::HeaderValue::from_str(&clear_refresh).unwrap(),
    );
    Ok((StatusCode::OK, h, Json(json!({"ok": true }))))
}

#[instrument(skip(state))]
pub async fn refresh(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    maybe_body: Option<Json<RefreshRequest>>,
) -> Result<impl IntoResponse, AppError> {
    // Prefer the explicit bearer token when present so a stale refresh cookie
    // cannot silently switch the active account.
    let bearer = headers
        .get(header::AUTHORIZATION)
        .and_then(|h| h.to_str().ok())
        .and_then(|h| h.strip_prefix("Bearer "));

    let mut refresh_from_cookie: Option<String> = None;
    if let Some(cookie_hdr) = headers.get(header::COOKIE).and_then(|v| v.to_str().ok()) {
        for part in cookie_hdr.split(';') {
            let trimmed = part.trim();
            if let Some(val) = trimmed.strip_prefix("refresh-token=") {
                refresh_from_cookie = Some(val.to_string());
                break;
            }
        }
    }
    let refresh_body = maybe_body
        .as_ref()
        .and_then(|Json(b)| b.refresh_token.clone());

    let (access, new_refresh, user) = if let Some(bearer) = bearer {
        match state.auth_service.rotate_from_access(bearer).await {
            Ok(tuple) => tuple,
            Err(_) => {
                if let Some(rt) = refresh_body.or(refresh_from_cookie) {
                    state.auth_service.refresh_with_token(&rt).await?
                } else {
                    return Ok((
                        StatusCode::UNAUTHORIZED,
                        Json(json!({"error":"unauthorized","status":401})),
                    )
                        .into_response());
                }
            }
        }
    } else if let Some(rt) = refresh_body.or(refresh_from_cookie) {
        state.auth_service.refresh_with_token(&rt).await?
    } else {
        return Ok((
            StatusCode::UNAUTHORIZED,
            Json(json!({"error":"unauthorized","status":401})),
        )
            .into_response());
    };

    // Set cookies (rotate both)
    let access_max_age = std::env::var("ACCESS_TOKEN_TTL_MINUTES")
        .ok()
        .and_then(|v| v.parse::<i64>().ok())
        .unwrap_or(15)
        * 60; // seconds
    let refresh_max_age = std::env::var("REFRESH_TOKEN_TTL_DAYS")
        .ok()
        .and_then(|v| v.parse::<i64>().ok())
        .unwrap_or(30)
        * 24
        * 3600;

    let cookie_secure = std::env::var("COOKIE_SECURE")
        .ok()
        .map(|s| matches!(s.to_ascii_lowercase().as_str(), "1" | "true" | "yes"))
        .unwrap_or(false);
    let mut access_cookie = format!(
        "auth-token={}; Max-Age={}; Path=/; HttpOnly; SameSite=Lax",
        access, access_max_age
    );
    let mut refresh_cookie = format!(
        "refresh-token={}; Max-Age={}; Path=/; HttpOnly; SameSite=Lax",
        new_refresh, refresh_max_age
    );
    if cookie_secure {
        access_cookie.push_str("; Secure");
        refresh_cookie.push_str("; Secure");
    }
    let mut headers_out = HeaderMap::new();
    headers_out.append(
        header::SET_COOKIE,
        axum::http::HeaderValue::from_str(&access_cookie).unwrap(),
    );
    headers_out.append(
        header::SET_COOKIE,
        axum::http::HeaderValue::from_str(&refresh_cookie).unwrap(),
    );

    // Reuse AuthResponse payload for access token
    let body = crate::auth::types::AuthResponse {
        token: access,
        user,
        refresh_token: Some(new_refresh),
        expires_in: Some(access_max_age),
        password_change_required: None,
    };
    Ok((StatusCode::OK, headers_out, Json(body)).into_response())
}

#[instrument(skip(state))]
pub async fn logout(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, AppError> {
    // Best-effort: clear cookies even when the access token is already gone.
    let token = headers
        .get(header::AUTHORIZATION)
        .and_then(|h| h.to_str().ok())
        .and_then(|h| h.strip_prefix("Bearer "))
        .map(|s| s.to_string())
        .or_else(|| {
            headers
                .get(header::COOKIE)
                .and_then(|v| v.to_str().ok())
                .and_then(|cookie_hdr| {
                    cookie_hdr.split(';').find_map(|part| {
                        part.trim()
                            .strip_prefix("auth-token=")
                            .map(|val| val.to_string())
                    })
                })
        });

    if let Some(token) = token.as_deref() {
        let _ = state.auth_service.logout(token).await;
    }

    // Clear auth cookies
    let mut h = HeaderMap::new();
    let cookie_secure = std::env::var("COOKIE_SECURE")
        .ok()
        .map(|s| matches!(s.to_ascii_lowercase().as_str(), "1" | "true" | "yes"))
        .unwrap_or(false);
    let mut clear_access = "auth-token=; Max-Age=0; Path=/; HttpOnly; SameSite=Lax".to_string();
    let mut clear_refresh = "refresh-token=; Max-Age=0; Path=/; HttpOnly; SameSite=Lax".to_string();
    if cookie_secure {
        clear_access.push_str("; Secure");
        clear_refresh.push_str("; Secure");
    }
    h.insert(
        header::SET_COOKIE,
        axum::http::HeaderValue::from_str(&clear_access).unwrap(),
    );
    h.append(
        header::SET_COOKIE,
        axum::http::HeaderValue::from_str(&clear_refresh).unwrap(),
    );

    Ok((h, Json(json!({"message": "Logged out successfully"}))))
}

#[instrument(skip(state))]
pub async fn me(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, AppError> {
    // Extract token from Authorization header
    let token = headers
        .get(header::AUTHORIZATION)
        .and_then(|h| h.to_str().ok())
        .and_then(|h| h.strip_prefix("Bearer "))
        .ok_or_else(|| anyhow::anyhow!("Missing authorization token"))?;

    let user = state.auth_service.verify_token(token).await?;

    Ok(Json(user))
}

// OAuth endpoints would go here but require OAuth service integration
// Implementation notes:
// - Web is a static export; OAuth must be handled on the Rust server.
// - Callback redirects back into the web app with the access token in the URL fragment.

fn inferred_redirect_base_url(headers: &HeaderMap, host: &str) -> String {
    let proto = headers
        .get("x-forwarded-proto")
        .and_then(|v| v.to_str().ok())
        .map(|s| s.split(',').next().unwrap_or("http").trim())
        .filter(|s| !s.is_empty())
        .unwrap_or("http");
    format!("{}://{}", proto, host)
}

fn oauth_config_from_env(redirect_base_url: String) -> Result<OAuthConfig, Vec<&'static str>> {
    let google_client_id = std::env::var("GOOGLE_CLIENT_ID").unwrap_or_default();
    let google_client_secret = std::env::var("GOOGLE_CLIENT_SECRET").unwrap_or_default();

    let mut missing: Vec<&'static str> = Vec::new();
    if google_client_id.is_empty() {
        missing.push("GOOGLE_CLIENT_ID");
    }
    if google_client_secret.is_empty() {
        missing.push("GOOGLE_CLIENT_SECRET");
    }
    if !missing.is_empty() {
        return Err(missing);
    }

    let github_client_id = std::env::var("GITHUB_CLIENT_ID").unwrap_or_default();
    let github_client_secret = std::env::var("GITHUB_CLIENT_SECRET").unwrap_or_default();

    Ok(OAuthConfig {
        google_client_id,
        google_client_secret,
        github_client_id,
        github_client_secret,
        redirect_base_url,
    })
}

#[instrument(skip(state))]
pub async fn oauth_google_url(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    axum::extract::Host(host): axum::extract::Host,
) -> Result<impl IntoResponse, AppError> {
    // Prefer explicit public base URL, but fall back to request host/proto for local dev.
    let redirect_base_url = std::env::var("OAUTH_REDIRECT_BASE_URL")
        .or_else(|_| std::env::var("PUBLIC_BASE_URL"))
        .unwrap_or_else(|_| inferred_redirect_base_url(&headers, &host));

    // If the caller configured a public base URL, and we cached a service at startup, use it.
    let explicit_base = std::env::var("OAUTH_REDIRECT_BASE_URL").is_ok()
        || std::env::var("PUBLIC_BASE_URL").is_ok();
    if explicit_base {
        if let Some(svc) = state.oauth_service.as_ref() {
            let url = svc.get_google_auth_url()?;
            return Ok(Json(json!({ "url": url })).into_response());
        }
    }

    let users_db = match state.multi_tenant_db.as_ref() {
        Some(db) => db.users_connection(),
        None => {
            return Ok((
                StatusCode::NOT_IMPLEMENTED,
                Json(json!({
                    "error": "oauth_not_supported",
                    "message": "OAuth requires DuckDB mode"
                })),
            )
                .into_response());
        }
    };
    let cfg = match oauth_config_from_env(redirect_base_url) {
        Ok(c) => c,
        Err(missing) => {
            return Ok((
                StatusCode::NOT_IMPLEMENTED,
                Json(json!({
                    "error": "oauth_not_configured",
                    "message": format!("Missing {}", missing.join(", "))
                })),
            )
                .into_response());
        }
    };
    let svc = OAuthService::new(cfg, users_db, state.auth_service.jwt_secret.clone());
    let url = svc.get_google_auth_url()?;
    Ok(Json(json!({ "url": url })).into_response())
}

#[instrument(skip(state))]
pub async fn oauth_google_callback(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    axum::extract::Host(host): axum::extract::Host,
    Query(query): Query<OAuthCallbackQuery>,
) -> Result<impl IntoResponse, AppError> {
    let redirect_base_url = std::env::var("OAUTH_REDIRECT_BASE_URL")
        .or_else(|_| std::env::var("PUBLIC_BASE_URL"))
        .unwrap_or_else(|_| inferred_redirect_base_url(&headers, &host));

    let explicit_base = std::env::var("OAUTH_REDIRECT_BASE_URL").is_ok()
        || std::env::var("PUBLIC_BASE_URL").is_ok();
    let auth = if explicit_base {
        if let Some(svc) = state.oauth_service.as_ref() {
            svc.handle_google_callback(query.code).await?
        } else {
            let users_db = match state.multi_tenant_db.as_ref() {
                Some(db) => db.users_connection(),
                None => return Ok(Redirect::to("/auth?oauth=not-supported").into_response()),
            };
            let cfg = match oauth_config_from_env(redirect_base_url) {
                Ok(c) => c,
                Err(_) => return Ok(Redirect::to("/auth?oauth=not-configured").into_response()),
            };
            let svc = OAuthService::new(cfg, users_db, state.auth_service.jwt_secret.clone());
            svc.handle_google_callback(query.code).await?
        }
    } else {
        let users_db = match state.multi_tenant_db.as_ref() {
            Some(db) => db.users_connection(),
            None => return Ok(Redirect::to("/auth?oauth=not-supported").into_response()),
        };
        let cfg = match oauth_config_from_env(redirect_base_url) {
            Ok(c) => c,
            Err(_) => return Ok(Redirect::to("/auth?oauth=not-configured").into_response()),
        };
        let svc = OAuthService::new(cfg, users_db, state.auth_service.jwt_secret.clone());
        svc.handle_google_callback(query.code).await?
    };

    // Set cookies for SSE/cookie-only clients (mirrors /api/auth/login).
    let access_max_age = std::env::var("ACCESS_TOKEN_TTL_MINUTES")
        .ok()
        .and_then(|v| v.parse::<i64>().ok())
        .unwrap_or(15)
        * 60;
    let refresh_max_age = std::env::var("REFRESH_TOKEN_TTL_DAYS")
        .ok()
        .and_then(|v| v.parse::<i64>().ok())
        .unwrap_or(30)
        * 24
        * 3600;
    let cookie_secure = std::env::var("COOKIE_SECURE")
        .ok()
        .map(|s| matches!(s.to_ascii_lowercase().as_str(), "1" | "true" | "yes"))
        .unwrap_or(false);

    let mut access_cookie = format!(
        "auth-token={}; Max-Age={}; Path=/; HttpOnly; SameSite=Lax",
        auth.token, access_max_age
    );
    if cookie_secure {
        access_cookie.push_str("; Secure");
    }
    let mut headers_out = HeaderMap::new();
    headers_out.insert(
        header::SET_COOKIE,
        axum::http::HeaderValue::from_str(&access_cookie).unwrap(),
    );
    if let Some(ref_token) = &auth.refresh_token {
        let mut refresh_cookie = format!(
            "refresh-token={}; Max-Age={}; Path=/; HttpOnly; SameSite=Lax",
            ref_token, refresh_max_age
        );
        if cookie_secure {
            refresh_cookie.push_str("; Secure");
        }
        headers_out.append(
            header::SET_COOKIE,
            axum::http::HeaderValue::from_str(&refresh_cookie).unwrap(),
        );
    }

    // Pass token via fragment so it doesn't get sent back to the server on subsequent requests.
    let expires_in = auth.expires_in.unwrap_or(access_max_age);
    let redirect = format!(
        "/auth/oauth/callback#token={}&expires_in={}",
        auth.token, expires_in
    );
    Ok((headers_out, Redirect::to(&redirect)).into_response())
}

#[instrument(skip(state))]
pub async fn oauth_github_url(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    axum::extract::Host(host): axum::extract::Host,
) -> Result<impl IntoResponse, AppError> {
    let gh = std::env::var("GITHUB_CLIENT_ID").unwrap_or_default();
    if gh.is_empty() {
        return Ok((
            StatusCode::NOT_IMPLEMENTED,
            Json(json!({
                "error": "oauth_not_configured",
                "message": "GitHub OAuth is not configured on this server"
            })),
        )
            .into_response());
    }
    let redirect_base_url = std::env::var("OAUTH_REDIRECT_BASE_URL")
        .or_else(|_| std::env::var("PUBLIC_BASE_URL"))
        .unwrap_or_else(|_| inferred_redirect_base_url(&headers, &host));

    let users_db = match state.multi_tenant_db.as_ref() {
        Some(db) => db.users_connection(),
        None => {
            return Ok((
                StatusCode::NOT_IMPLEMENTED,
                Json(json!({
                    "error": "oauth_not_supported",
                    "message": "OAuth requires DuckDB mode"
                })),
            )
                .into_response());
        }
    };
    let cfg = match oauth_config_from_env(redirect_base_url) {
        Ok(c) => c,
        Err(missing) => {
            return Ok((
                StatusCode::NOT_IMPLEMENTED,
                Json(json!({
                    "error": "oauth_not_configured",
                    "message": format!("Missing {}", missing.join(", "))
                })),
            )
                .into_response());
        }
    };
    let svc = OAuthService::new(cfg, users_db, state.auth_service.jwt_secret.clone());
    let url = svc.get_github_auth_url()?;
    Ok(Json(json!({ "url": url })).into_response())
}

#[instrument(skip(state))]
pub async fn oauth_github_callback(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    axum::extract::Host(host): axum::extract::Host,
    Query(query): Query<OAuthCallbackQuery>,
) -> Result<impl IntoResponse, AppError> {
    let redirect_base_url = std::env::var("OAUTH_REDIRECT_BASE_URL")
        .or_else(|_| std::env::var("PUBLIC_BASE_URL"))
        .unwrap_or_else(|_| inferred_redirect_base_url(&headers, &host));
    let users_db = match state.multi_tenant_db.as_ref() {
        Some(db) => db.users_connection(),
        None => return Ok(Redirect::to("/auth?oauth=not-supported").into_response()),
    };
    let cfg = match oauth_config_from_env(redirect_base_url) {
        Ok(c) => c,
        Err(_) => return Ok(Redirect::to("/auth?oauth=not-configured").into_response()),
    };
    let svc = OAuthService::new(cfg, users_db, state.auth_service.jwt_secret.clone());
    let auth = svc.handle_github_callback(query.code).await?;

    let access_max_age = std::env::var("ACCESS_TOKEN_TTL_MINUTES")
        .ok()
        .and_then(|v| v.parse::<i64>().ok())
        .unwrap_or(15)
        * 60;
    let refresh_max_age = std::env::var("REFRESH_TOKEN_TTL_DAYS")
        .ok()
        .and_then(|v| v.parse::<i64>().ok())
        .unwrap_or(30)
        * 24
        * 3600;
    let cookie_secure = std::env::var("COOKIE_SECURE")
        .ok()
        .map(|s| matches!(s.to_ascii_lowercase().as_str(), "1" | "true" | "yes"))
        .unwrap_or(false);

    let mut access_cookie = format!(
        "auth-token={}; Max-Age={}; Path=/; HttpOnly; SameSite=Lax",
        auth.token, access_max_age
    );
    if cookie_secure {
        access_cookie.push_str("; Secure");
    }
    let mut headers_out = HeaderMap::new();
    headers_out.insert(
        header::SET_COOKIE,
        axum::http::HeaderValue::from_str(&access_cookie).unwrap(),
    );
    if let Some(ref_token) = &auth.refresh_token {
        let mut refresh_cookie = format!(
            "refresh-token={}; Max-Age={}; Path=/; HttpOnly; SameSite=Lax",
            ref_token, refresh_max_age
        );
        if cookie_secure {
            refresh_cookie.push_str("; Secure");
        }
        headers_out.append(
            header::SET_COOKIE,
            axum::http::HeaderValue::from_str(&refresh_cookie).unwrap(),
        );
    }

    let expires_in = auth.expires_in.unwrap_or(access_max_age);
    let redirect = format!(
        "/auth/oauth/callback#token={}&expires_in={}",
        auth.token, expires_in
    );
    Ok((headers_out, Redirect::to(&redirect)).into_response())
}

// Helper function to extract user ID from token
// Prefer Authorization header, but fall back to 'auth-token' cookie for EventSource/cookie-only clients.
async fn extract_user_id(state: &AppState, headers: &HeaderMap) -> Result<String, AppError> {
    let try_cookie = |headers: &HeaderMap| -> Option<String> {
        let cookie_hdr = headers.get(header::COOKIE).and_then(|v| v.to_str().ok())?;
        for part in cookie_hdr.split(';') {
            let trimmed = part.trim();
            if let Some(val) = trimmed.strip_prefix("auth-token=") {
                return Some(val.to_string());
            }
        }
        None
    };

    // Try Authorization header first
    if let Some(token) = headers
        .get(header::AUTHORIZATION)
        .and_then(|h| h.to_str().ok())
        .and_then(|h| h.strip_prefix("Bearer "))
    {
        match state.auth_service.verify_token(token).await {
            Ok(user) => return Ok(user.user_id),
            Err(primary_err) => {
                // Align with photo routes: if Authorization is stale, allow
                // fallback to cookie-based auth to avoid transient 500s.
                if let Some(cookie_token) = try_cookie(headers) {
                    if let Ok(user) = state.auth_service.verify_token(&cookie_token).await {
                        return Ok(user.user_id);
                    }
                }
                return Err(AppError(anyhow::anyhow!("Unauthorized: {}", primary_err)));
            }
        }
    }

    // Fallback: try Cookie header for 'auth-token'
    if let Some(cookie_token) = try_cookie(headers) {
        let user = state.auth_service.verify_token(&cookie_token).await?;
        return Ok(user.user_id);
    }

    Err(AppError(anyhow::anyhow!("Missing authorization token")))
}

fn load_face_settings(state: &AppState, user_id: &str) -> FaceQualitySettings {
    let mut settings = FaceQualitySettings::default();
    if let Some(pg) = &state.pg_client {
        let row_res = if tokio::runtime::Handle::try_current().is_ok() {
            tokio::task::block_in_place(|| {
                futures::executor::block_on(pg.query_opt(
                    "SELECT face_min_quality, face_min_confidence, face_min_size, face_yaw_max, face_yaw_hard_max, face_min_sharpness, face_sharpness_target FROM users WHERE user_id=$1",
                    &[&user_id],
                ))
            })
        } else {
            futures::executor::block_on(pg.query_opt(
                "SELECT face_min_quality, face_min_confidence, face_min_size, face_yaw_max, face_yaw_hard_max, face_min_sharpness, face_sharpness_target FROM users WHERE user_id=$1",
                &[&user_id],
            ))
        };
        if let Ok(row_opt) = row_res {
            if let Some(row) = row_opt {
                // Columns are REAL in Postgres schema; read as f32 (not f64)
                let q: Option<f32> = row.get(0);
                let c: Option<f32> = row.get(1);
                let s: Option<i32> = row.get(2);
                let ym: Option<f32> = row.get(3);
                let yh: Option<f32> = row.get(4);
                let ms: Option<f32> = row.get(5);
                let st: Option<f32> = row.get(6);
                if let Some(v) = q {
                    settings.min_quality = v;
                }
                if let Some(v) = c {
                    settings.min_confidence = v;
                }
                if let Some(v) = s {
                    settings.min_size = v;
                }
                if let Some(v) = ym {
                    settings.yaw_max = v;
                }
                if let Some(v) = yh {
                    settings.yaw_hard_max = v;
                }
                if let Some(v) = ms {
                    settings.min_sharpness = v;
                }
                if let Some(v) = st {
                    settings.sharpness_target = v;
                }
            }
        }
        return settings;
    }
    let users_db = state
        .multi_tenant_db
        .as_ref()
        .expect("users DB required in DuckDB mode")
        .users_connection();
    let conn = users_db.lock();
    if let Ok(mut stmt) = conn.prepare(
        "SELECT face_min_quality, face_min_confidence, face_min_size, face_yaw_max, face_yaw_hard_max, face_min_sharpness, face_sharpness_target FROM users WHERE user_id = ?",
    ) {
        if let Ok((q, c, s, ym, yh, ms, st)) = stmt.query_row([user_id], |row| {
            Ok((
                row.get::<_, f32>(0)?,
                row.get::<_, f32>(1)?,
                row.get::<_, i32>(2)?,
                row.get::<_, f32>(3)?,
                row.get::<_, f32>(4)?,
                row.get::<_, f32>(5)?,
                row.get::<_, f32>(6)?,
            ))
        }) {
            settings.min_quality = q;
            settings.min_confidence = c;
            settings.min_size = s;
            settings.yaw_max = ym;
            settings.yaw_hard_max = yh;
            settings.min_sharpness = ms;
            settings.sharpness_target = st;
        }
    }
    settings
}

#[derive(Debug, Clone)]
struct VideoProcessingSettings {
    gating_mode: String, // off | yolo | yolo_fallback
    yolo_person_threshold: f32,
    retina_min_frames: usize,
}

fn load_video_settings(state: &AppState, user_id: &str) -> VideoProcessingSettings {
    if let Some(pg) = &state.pg_client {
        if let Ok(row_opt) = futures::executor::block_on(pg.query_opt(
            "SELECT COALESCE(video_face_gating_mode, 'yolo_fallback'), COALESCE(yolo_person_threshold, 0.30), COALESCE(retina_min_frames, 1) FROM users WHERE user_id=$1",
            &[&user_id],
        )) {
            if let Some(row) = row_opt {
                return VideoProcessingSettings {
                    gating_mode: row.get::<_, String>(0),
                    yolo_person_threshold: row.get::<_, f32>(1),
                    retina_min_frames: (row.get::<_, i64>(2)).max(0) as usize,
                };
            }
        }
        return VideoProcessingSettings {
            gating_mode: "yolo_fallback".into(),
            yolo_person_threshold: 0.30,
            retina_min_frames: 1,
        };
    }
    let users_db = state
        .multi_tenant_db
        .as_ref()
        .expect("users DB required in DuckDB mode")
        .users_connection();
    let conn = users_db.lock();
    if let Ok(mut stmt) = conn.prepare(
        "SELECT COALESCE(video_face_gating_mode, 'yolo_fallback'), COALESCE(yolo_person_threshold, 0.30), COALESCE(retina_min_frames, 1) FROM users WHERE user_id = ?",
    ) {
        if let Ok((mode, thr, minf)) = stmt.query_row([user_id], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, f32>(1)?, row.get::<_, i64>(2)?))
        }) {
            return VideoProcessingSettings {
                gating_mode: mode,
                yolo_person_threshold: thr,
                retina_min_frames: minf.max(0) as usize,
            };
        }
    }
    VideoProcessingSettings {
        gating_mode: "yolo_fallback".to_string(),
        yolo_person_threshold: 0.30,
        retina_min_frames: 1,
    }
}

#[derive(Debug, Serialize, Deserialize)]
pub struct FoldersResponse {
    pub folders: Vec<String>,
    pub album_parent_id: Option<i32>,
    pub preserve_tree_path: bool,
}

#[derive(Debug, Deserialize)]
pub struct UpdateFoldersRequest {
    pub folders: Vec<String>,
    pub album_parent_id: Option<i32>,
    pub preserve_tree_path: Option<bool>,
}

#[instrument(skip(state))]
pub async fn get_user_folders(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, AppError> {
    let user_id = extract_user_id(&state, &headers).await?;

    // Get user's folders from database
    let (folders_str, album_parent_id, preserve_tree): (String, Option<i32>, bool) = if let Some(
        pg,
    ) =
        &state.pg_client
    {
        let row = pg
            .query_opt(
                "SELECT COALESCE(folders,''), index_parent_album_id, COALESCE(index_preserve_tree_path,FALSE) FROM users WHERE user_id=$1 LIMIT 1",
                &[&user_id],
            )
            .await
            .map_err(|e| AppError(anyhow::anyhow!(e)))?;
        match row {
            Some(r) => (
                r.get::<_, String>(0),
                r.get::<_, Option<i32>>(1),
                r.get::<_, bool>(2),
            ),
            None => (String::new(), None, false),
        }
    } else {
        let users_db = state
            .multi_tenant_db
            .as_ref()
            .expect("users DB required in DuckDB mode")
            .users_connection();
        let conn = users_db.lock();
        let mut stmt = conn.prepare("SELECT folders, index_parent_album_id, COALESCE(index_preserve_tree_path, FALSE) FROM users WHERE user_id = ?")?;
        stmt.query_row([&user_id], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, Option<i32>>(1)?,
                row.get::<_, bool>(2)?,
            ))
        })
        .unwrap_or((String::new(), None, false))
    };

    let folders: Vec<String> = if folders_str.is_empty() {
        Vec::new()
    } else {
        folders_str
            .split(',')
            .map(|s| s.trim().to_string())
            .collect()
    };

    Ok(Json(FoldersResponse {
        folders,
        album_parent_id,
        preserve_tree_path: preserve_tree,
    }))
}

#[instrument(skip(state))]
pub async fn update_user_folders(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(request): Json<UpdateFoldersRequest>,
) -> Result<impl IntoResponse, AppError> {
    let user_id = extract_user_id(&state, &headers).await?;
    ensure_not_demo_mutation(&state, &user_id, "PUT /api/settings/folders").await?;

    // Validate folder paths exist and are accessible
    for folder in &request.folders {
        let path = std::path::Path::new(folder);
        if !path.exists() || !path.is_dir() {
            return Err(AppError(anyhow::anyhow!(
                "Folder does not exist or is not accessible: {}",
                folder
            )));
        }
        // Disallow indexing the server's own library_root to avoid double work
        let lib_root = state
            .library_root
            .canonicalize()
            .unwrap_or(state.library_root.clone());
        let cand = path.canonicalize().unwrap_or(path.to_path_buf());
        if cand.starts_with(&lib_root) {
            return Err(AppError(anyhow::anyhow!(
                "Cannot index internal library folder: {}",
                folder
            )));
        }
    }

    // Update user's folders in database
    let folders_str = request.folders.join(",");
    if let Some(pg) = &state.pg_client {
        let _ = pg
            .execute(
                "UPDATE users SET folders=$1, index_parent_album_id=COALESCE($2, index_parent_album_id), index_preserve_tree_path=COALESCE($3, index_preserve_tree_path) WHERE user_id=$4",
                &[&folders_str, &request.album_parent_id, &request.preserve_tree_path, &user_id],
            )
            .await
            .map_err(|e| AppError(anyhow::anyhow!(e)))?;
    } else {
        let users_db = state
            .multi_tenant_db
            .as_ref()
            .expect("users DB required in DuckDB mode")
            .users_connection();
        let conn = users_db.lock();
        conn.execute(
            "UPDATE users SET folders = ?, index_parent_album_id = COALESCE(?, index_parent_album_id), index_preserve_tree_path = COALESCE(?, index_preserve_tree_path) WHERE user_id = ?",
            [
                &folders_str,
                &request.album_parent_id as &dyn duckdb::ToSql,
                &request.preserve_tree_path as &dyn duckdb::ToSql,
                &user_id as &dyn duckdb::ToSql,
            ],
        )?;
    }

    // Trigger indexing for the updated folders (DuckDB mode only; skip in PG mode)
    if state.pg_client.is_some() {
        return Ok(Json(json!({"message":"Folders updated"})));
    }
    // DuckDB mode: SSE reindex
    let folders_clone = request.folders.clone();
    let album_opts = AlbumIndexOptions {
        album_parent_id: request.album_parent_id,
        preserve_tree_path: request.preserve_tree_path.unwrap_or(false),
    };
    let (job_id, tx) = state.create_reindex_job_for(&user_id);
    let cancel_flag = state.get_cancel_flag(&job_id).expect("cancel flag exists");
    // Fire 'started'
    let _ = tx.send(
        serde_json::json!({
            "type": "started",
            "jobId": job_id,
            "folders": folders_clone,
        })
        .to_string(),
    );

    if !request.folders.is_empty() {
        let state_clone = state.clone();
        let user_id_clone = user_id.clone();
        let job_id_for_task = job_id.clone();
        tokio::spawn(async move {
            if let Err(e) = index_user_folders(
                &state_clone,
                &user_id_clone,
                &folders_clone,
                &job_id_for_task,
                cancel_flag.clone(),
                album_opts,
            )
            .await
            {
                tracing::error!("Failed to index folders for user {}: {}", user_id_clone, e);
                let _ = tx.send(
                    serde_json::json!({
                        "type": "error",
                        "jobId": job_id_for_task,
                        "message": e.to_string()
                    })
                    .to_string(),
                );
            }
            // After completion, report count and finish job
            if let Ok(data_db) = state_clone.get_user_data_database(&user_id_clone) {
                let conn = data_db.lock();
                let post_count = conn
                    .query_row("SELECT COUNT(*) FROM photos", [], |row| {
                        row.get::<_, i64>(0)
                    })
                    .unwrap_or(-1);
                tracing::info!(
                    "[REINDEX] Photos count AFTER update folders for user {}: {}",
                    user_id_clone,
                    post_count
                );
                let msg_type = if cancel_flag.load(std::sync::atomic::Ordering::Relaxed) {
                    "cancelled"
                } else {
                    "done"
                };
                let _ = tx.send(
                    serde_json::json!({
                        "type": msg_type,
                        "jobId": job_id_for_task,
                        "count": post_count
                    })
                    .to_string(),
                );
            }
            state_clone.finish_reindex_job(&job_id_for_task);
        });
    }

    Ok(Json(json!({
        "message": "Folders updated successfully, indexing started",
        "folders": request.folders,
        "indexed": true,
        "job_id": job_id
    })))
}

// Face quality settings API
#[derive(Debug, Serialize, Deserialize)]
pub struct FaceSettingsResponse {
    pub min_quality: f32,
    pub min_confidence: f32,
    pub min_size: i32,
    pub yaw_max: f32,
    pub yaw_hard_max: f32,
    pub min_sharpness: f32,
    pub sharpness_target: f32,
}

#[instrument(skip(state))]
pub async fn get_face_settings(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, AppError> {
    let user_id = extract_user_id(&state, &headers).await?;
    if let Some(pg) = &state.pg_client {
        let row = pg
            .query_one(
                "SELECT COALESCE(face_min_quality,0.55), COALESCE(face_min_confidence,0.75), COALESCE(face_min_size,64), COALESCE(face_yaw_max,75.0), COALESCE(face_yaw_hard_max,85.0), COALESCE(face_min_sharpness,0.15), COALESCE(face_sharpness_target,500.0) FROM users WHERE user_id=$1",
                &[&user_id],
            )
            .await
            .map_err(|e| AppError(anyhow::anyhow!(e)))?;
        let q: f32 = row.get::<_, f32>(0);
        let c: f32 = row.get::<_, f32>(1);
        let s: i32 = row.get::<_, i32>(2);
        let ym: f32 = row.get::<_, f32>(3);
        let yh: f32 = row.get::<_, f32>(4);
        let ms: f32 = row.get::<_, f32>(5);
        let st: f32 = row.get::<_, f32>(6);
        return Ok(Json(FaceSettingsResponse {
            min_quality: q,
            min_confidence: c,
            min_size: s,
            yaw_max: ym,
            yaw_hard_max: yh,
            min_sharpness: ms,
            sharpness_target: st,
        }));
    }
    let users_db = state
        .multi_tenant_db
        .as_ref()
        .expect("users DB required in DuckDB mode")
        .users_connection();
    let conn = users_db.lock();
    let mut stmt = conn.prepare("SELECT face_min_quality, face_min_confidence, face_min_size, face_yaw_max, face_yaw_hard_max, face_min_sharpness, face_sharpness_target FROM users WHERE user_id = ?")?;
    let (q, c, s, ym, yh, ms, st): (f32, f32, i32, f32, f32, f32, f32) =
        stmt.query_row([&user_id], |row| {
            Ok((
                row.get(0)?,
                row.get(1)?,
                row.get(2)?,
                row.get(3)?,
                row.get(4)?,
                row.get(5)?,
                row.get(6)?,
            ))
        })?;
    Ok(Json(FaceSettingsResponse {
        min_quality: q,
        min_confidence: c,
        min_size: s,
        yaw_max: ym,
        yaw_hard_max: yh,
        min_sharpness: ms,
        sharpness_target: st,
    }))
}

#[derive(Debug, Serialize, Deserialize)]
pub struct UpdateFaceSettingsRequest {
    pub min_quality: Option<f32>,
    pub min_confidence: Option<f32>,
    pub min_size: Option<i32>,
    pub yaw_max: Option<f32>,
    pub yaw_hard_max: Option<f32>,
    pub min_sharpness: Option<f32>,
    pub sharpness_target: Option<f32>,
}

#[instrument(skip(state))]
pub async fn update_face_settings(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(req): Json<UpdateFaceSettingsRequest>,
) -> Result<impl IntoResponse, AppError> {
    let user_id = extract_user_id(&state, &headers).await?;
    ensure_not_demo_mutation(&state, &user_id, "PUT /api/settings/face").await?;
    if let Some(pg) = &state.pg_client {
        let _ = pg
            .execute(
                "UPDATE users SET 
                    face_min_quality = COALESCE($1, face_min_quality),
                    face_min_confidence = COALESCE($2, face_min_confidence),
                    face_min_size = COALESCE($3, face_min_size),
                    face_yaw_max = COALESCE($4, face_yaw_max),
                    face_yaw_hard_max = COALESCE($5, face_yaw_hard_max),
                    face_min_sharpness = COALESCE($6, face_min_sharpness),
                    face_sharpness_target = COALESCE($7, face_sharpness_target)
                 WHERE user_id = $8",
                &[
                    &req.min_quality,
                    &req.min_confidence,
                    &req.min_size,
                    &req.yaw_max,
                    &req.yaw_hard_max,
                    &req.min_sharpness,
                    &req.sharpness_target,
                    &user_id,
                ],
            )
            .await
            .map_err(|e| AppError(anyhow::anyhow!(e)))?;
        return Ok(Json(json!({"message":"Face settings updated"})));
    }
    let users_db = state
        .multi_tenant_db
        .as_ref()
        .expect("users DB required in DuckDB mode")
        .users_connection();
    let conn = users_db.lock();
    let p1 = req.min_quality;
    let p2 = req.min_confidence;
    let p3 = req.min_size.map(|v| v as i64);
    let p4 = req.yaw_max;
    let p5 = req.yaw_hard_max;
    let p6 = req.min_sharpness;
    let p7 = req.sharpness_target;
    let p8 = user_id;
    let _ = conn.execute(
        "UPDATE users SET 
            face_min_quality = COALESCE(?, face_min_quality),
            face_min_confidence = COALESCE(?, face_min_confidence),
            face_min_size = COALESCE(?, face_min_size),
            face_yaw_max = COALESCE(?, face_yaw_max),
            face_yaw_hard_max = COALESCE(?, face_yaw_hard_max),
            face_min_sharpness = COALESCE(?, face_min_sharpness),
            face_sharpness_target = COALESCE(?, face_sharpness_target)
         WHERE user_id = ?",
        [
            &p1 as &dyn duckdb::ToSql,
            &p2 as &dyn duckdb::ToSql,
            &p3 as &dyn duckdb::ToSql,
            &p4 as &dyn duckdb::ToSql,
            &p5 as &dyn duckdb::ToSql,
            &p6 as &dyn duckdb::ToSql,
            &p7 as &dyn duckdb::ToSql,
            &p8 as &dyn duckdb::ToSql,
        ],
    )?;
    Ok(Json(json!({"message":"Face settings updated"})))
}

#[derive(Debug, Serialize, Deserialize)]
pub struct TrashSettingsResponse {
    pub auto_purge_days: i64,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct UpdateTrashSettingsRequest {
    pub auto_purge_days: i64,
}

#[instrument(skip(state))]
pub async fn get_trash_settings(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, AppError> {
    let user_id = extract_user_id(&state, &headers).await?;
    let days: i64 = if let Some(pg) = &state.pg_client {
        let rows = pg
            .query(
                "SELECT COALESCE(trash_auto_purge_days,30) FROM users WHERE user_id=$1 LIMIT 1",
                &[&user_id],
            )
            .await
            .unwrap_or_default();
        rows.first()
            .map(|r| (r.get::<_, i32>(0)) as i64)
            .unwrap_or(30)
    } else {
        let users_db = state
            .multi_tenant_db
            .as_ref()
            .expect("users DB required in DuckDB mode")
            .users_connection();
        let conn = users_db.lock();
        conn.query_row(
            "SELECT trash_auto_purge_days FROM users WHERE user_id = ?",
            [&user_id],
            |row| row.get(0),
        )
        .unwrap_or(30)
    };
    Ok(Json(TrashSettingsResponse {
        auto_purge_days: days,
    }))
}

// Security settings: control which metadata are kept in plaintext for locked items
#[derive(Debug, Serialize, Deserialize)]
pub struct SecuritySettingsResponse {
    pub include_location: bool,
    pub include_caption: bool,
    pub include_description: bool,
    pub remember_minutes: i64,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct UpdateSecuritySettingsRequest {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub include_location: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub include_caption: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub include_description: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub remember_minutes: Option<i64>,
}

#[instrument(skip(state))]
pub async fn get_security_settings(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, AppError> {
    let user_id = extract_user_id(&state, &headers).await?;
    let (loc, cap, desc, rem): (bool, bool, bool, i64) = if let Some(pg) = &state.pg_client {
        let rows = pg
            .query(
                "SELECT COALESCE(locked_meta_allow_location, FALSE), COALESCE(locked_meta_allow_caption, FALSE), COALESCE(locked_meta_allow_description, FALSE), COALESCE(pin_remember_minutes, 60) FROM users WHERE user_id=$1 LIMIT 1",
                &[&user_id],
            )
            .await
            .unwrap_or_default();
        rows.first()
            .map(|r| {
                let loc: bool = r.get(0);
                let cap: bool = r.get(1);
                let desc: bool = r.get(2);
                let rem: i64 = (r.get::<_, i32>(3)) as i64;
                (loc, cap, desc, rem)
            })
            .unwrap_or((false, false, false, 60))
    } else {
        let users_db = state
            .multi_tenant_db
            .as_ref()
            .expect("users DB required in DuckDB mode")
            .users_connection();
        let conn = users_db.lock();
        conn
            .query_row(
                "SELECT COALESCE(locked_meta_allow_location, FALSE), COALESCE(locked_meta_allow_caption, FALSE), COALESCE(locked_meta_allow_description, FALSE), COALESCE(pin_remember_minutes, 60) FROM users WHERE user_id = ?",
                [&user_id],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .unwrap_or((false, false, false, 60))
    };
    Ok(Json(SecuritySettingsResponse {
        include_location: loc,
        include_caption: cap,
        include_description: desc,
        remember_minutes: rem,
    }))
}

#[instrument(skip(state))]
pub async fn update_security_settings(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(req): Json<UpdateSecuritySettingsRequest>,
) -> Result<impl IntoResponse, AppError> {
    let user_id = extract_user_id(&state, &headers).await?;
    ensure_not_demo_mutation(&state, &user_id, "PUT /api/settings/security").await?;
    if let Some(pg) = &state.pg_client {
        let _ = pg
            .execute(
                "UPDATE users SET 
                    locked_meta_allow_location = COALESCE($1, locked_meta_allow_location),
                    locked_meta_allow_caption = COALESCE($2, locked_meta_allow_caption),
                    locked_meta_allow_description = COALESCE($3, locked_meta_allow_description),
                    pin_remember_minutes = COALESCE($4, pin_remember_minutes)
                 WHERE user_id = $5",
                &[
                    &req.include_location,
                    &req.include_caption,
                    &req.include_description,
                    &req.remember_minutes,
                    &user_id,
                ],
            )
            .await
            .map_err(|e| AppError(anyhow::anyhow!(e)))?;
    } else {
        let users_db = state
            .multi_tenant_db
            .as_ref()
            .expect("users DB required in DuckDB mode")
            .users_connection();
        let conn = users_db.lock();
        let _ = conn.execute(
            "UPDATE users SET 
                locked_meta_allow_location = COALESCE(?, locked_meta_allow_location),
                locked_meta_allow_caption = COALESCE(?, locked_meta_allow_caption),
                locked_meta_allow_description = COALESCE(?, locked_meta_allow_description),
                pin_remember_minutes = COALESCE(?, pin_remember_minutes)
             WHERE user_id = ?",
            duckdb::params![
                req.include_location as Option<bool>,
                req.include_caption as Option<bool>,
                req.include_description as Option<bool>,
                req.remember_minutes as Option<i64>,
                &user_id
            ],
        );
    }
    // Return updated values
    if let Some(pg) = &state.pg_client {
        let row_opt = pg
            .query_opt(
                "SELECT COALESCE(locked_meta_allow_location, FALSE), COALESCE(locked_meta_allow_caption, FALSE), COALESCE(locked_meta_allow_description, FALSE), COALESCE(pin_remember_minutes, 60) FROM users WHERE user_id=$1 LIMIT 1",
                &[&user_id],
            )
            .await
            .ok()
            .flatten();
        let (loc, cap, desc, rem) = row_opt
            .map(|r| {
                let loc: bool = r.get(0);
                let cap: bool = r.get(1);
                let desc: bool = r.get(2);
                let rem: i64 = (r.get::<_, i32>(3)) as i64;
                (loc, cap, desc, rem)
            })
            .unwrap_or((false, false, false, 60));
        return Ok(Json(SecuritySettingsResponse {
            include_location: loc,
            include_caption: cap,
            include_description: desc,
            remember_minutes: rem,
        }));
    } else {
        let users_db = state
            .multi_tenant_db
            .as_ref()
            .expect("users DB required in DuckDB mode")
            .users_connection();
        let conn = users_db.lock();
        let (loc, cap, desc, rem): (bool, bool, bool, i64) = conn
            .query_row(
                "SELECT COALESCE(locked_meta_allow_location, FALSE), COALESCE(locked_meta_allow_caption, FALSE), COALESCE(locked_meta_allow_description, FALSE), COALESCE(pin_remember_minutes, 60) FROM users WHERE user_id = ?",
                [&user_id],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .unwrap_or((false, false, false, 60));
        return Ok(Json(SecuritySettingsResponse {
            include_location: loc,
            include_caption: cap,
            include_description: desc,
            remember_minutes: rem,
        }));
    }
}

#[instrument(skip(state))]
pub async fn update_trash_settings(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(req): Json<UpdateTrashSettingsRequest>,
) -> Result<impl IntoResponse, AppError> {
    let user_id = extract_user_id(&state, &headers).await?;
    ensure_not_demo_mutation(&state, &user_id, "PUT /api/settings/trash").await?;
    if let Some(pg) = &state.pg_client {
        let days = req.auto_purge_days.clamp(0, 365);
        pg.execute(
            "UPDATE users SET trash_auto_purge_days = $1 WHERE user_id = $2",
            &[&days, &user_id],
        )
        .await
        .map_err(|e| AppError(anyhow::anyhow!(e)))?;
        return Ok(Json(TrashSettingsResponse {
            auto_purge_days: days,
        }));
    }
    let users_db = state
        .multi_tenant_db
        .as_ref()
        .expect("users DB required in DuckDB mode")
        .users_connection();
    let conn = users_db.lock();
    let days = req.auto_purge_days.clamp(0, 365);
    conn.execute(
        "UPDATE users SET trash_auto_purge_days = ? WHERE user_id = ?",
        duckdb::params![days, &user_id],
    )?;
    Ok(Json(TrashSettingsResponse {
        auto_purge_days: days,
    }))
}

// User-specific indexing function
#[derive(Debug, Clone)]
struct AlbumIndexOptions {
    album_parent_id: Option<i32>,
    preserve_tree_path: bool,
}

async fn index_user_folders(
    state: &Arc<AppState>,
    user_id: &str,
    folders: &[String],
    job_id: &str,
    cancel_flag: std::sync::Arc<std::sync::atomic::AtomicBool>,
    album_opts: AlbumIndexOptions,
) -> Result<(), anyhow::Error> {
    tracing::info!(
        "Starting indexing for user {} in {} folders",
        user_id,
        folders.len()
    );
    let started_at = std::time::Instant::now();
    let timing = std::sync::Arc::new(IndexTimingStats::default());

    // Get user-specific databases (DuckDB) or a dummy in-memory connection in Postgres mode
    let data_db = if state.pg_client.is_some() {
        let conn = duckdb::Connection::open_in_memory()
            .map_err(|e| anyhow::anyhow!(format!("open_in_memory: {}", e)))?;
        std::sync::Arc::new(parking_lot::Mutex::new(conn))
    } else {
        state.get_user_data_database(user_id)?
    };
    let embedding_store = state.create_user_embedding_store(user_id)?;

    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc as StdArc;
    let mut total_indexed = 0;

    // Optional progress channel and counters
    let (progress_tx, processed_counter, total_counter) = {
        let tx_opt = state.reindex_jobs.read().get(job_id).cloned();
        (
            tx_opt,
            StdArc::new(AtomicUsize::new(0)),
            StdArc::new(AtomicUsize::new(0)),
        )
    };

    // Checkpointing a large global DuckDB file is expensive. During reindex we gate checkpoints
    // to a coarse time-based schedule and keep a single final checkpoint at the end.
    let checkpoint_throttle = std::sync::Arc::new(std::sync::Mutex::new(
        ReindexCheckpointThrottle::new(std::time::Duration::from_secs(60)),
    ));

    for folder in folders {
        if cancel_flag.load(std::sync::atomic::Ordering::Relaxed) {
            tracing::warn!(
                "[REINDEX] Cancellation detected before folder {} (user={})",
                folder,
                user_id
            );
            break;
        }
        tracing::info!("Indexing folder: {}", folder);
        // Pre-count images in this folder to compute progress totals
        let total_files_in_folder = count_image_files(&folder)?;
        total_counter.fetch_add(total_files_in_folder, Ordering::Relaxed);

        let indexed_count = index_folder_recursively(
            state.clone(),
            data_db.clone(),
            embedding_store.clone(),
            folder.clone(),
            folder.clone(),
            user_id.to_string(),
            timing.clone(),
            progress_tx.clone(),
            processed_counter.clone(),
            total_counter.clone(),
            cancel_flag.clone(),
            album_opts.clone(),
            checkpoint_throttle.clone(),
        )
        .await?;
        total_indexed += indexed_count;
        tracing::info!("Indexed {} photos from {}", indexed_count, folder);
    }

    // Ensure all writes are fully persisted and visible across connections
    // DuckDB is transactional, but an explicit CHECKPOINT helps guarantee
    // that readers using another connection observe the latest data.
    {
        let conn = data_db.lock();
        let _ = conn.execute("CHECKPOINT;", []);
        tracing::info!(
            "Checkpointed user data DB after indexing (user: {})",
            user_id
        );
    }

    // Compute timing stats and log summary
    let elapsed = started_at.elapsed();
    let photos = timing.photos_count.load(Ordering::Relaxed) as u64;
    let videos = timing.videos_count.load(Ordering::Relaxed) as u64;
    let photo_us = timing.photo_us.load(Ordering::Relaxed);
    let video_us = timing.video_us.load(Ordering::Relaxed);
    let avg_photo_ms = if photos > 0 {
        (photo_us as f64 / photos as f64) / 1000.0
    } else {
        0.0
    };
    let avg_video_ms = if videos > 0 {
        (video_us as f64 / videos as f64) / 1000.0
    } else {
        0.0
    };

    tracing::info!(
        "Completed indexing for user {}: {} items indexed in {:.2?} | photos: {} avg {:.2} ms | videos: {} avg {:.2} ms",
        user_id,
        total_indexed,
        elapsed,
        photos,
        avg_photo_ms,
        videos,
        avg_video_ms
    );
    Ok(())
}

/// Coarse checkpoint throttle used during long-running reindex jobs.
///
/// Why: `CHECKPOINT;` on a large DuckDB file is expensive (CPU + RAM + I/O) and can cause
/// lock contention when called too frequently. We gate it to a time-based cadence and still
/// run a final checkpoint at the end of the job.
struct ReindexCheckpointThrottle {
    last_checkpoint: std::time::Instant,
    min_interval: std::time::Duration,
}

impl ReindexCheckpointThrottle {
    fn new(min_interval: std::time::Duration) -> Self {
        Self {
            last_checkpoint: std::time::Instant::now(),
            min_interval,
        }
    }

    fn should_checkpoint(&mut self) -> bool {
        if self.last_checkpoint.elapsed() >= self.min_interval {
            self.last_checkpoint = std::time::Instant::now();
            true
        } else {
            false
        }
    }
}

/// Marker error used to indicate a file should be skipped during ingest/reindex
/// (e.g., AppleDouble `._*` files or corrupted media that cannot be decoded).
#[derive(Debug)]
pub(crate) struct SkipIngestError {
    pub reason: String,
}

impl SkipIngestError {
    pub fn new(reason: impl Into<String>) -> Self {
        Self {
            reason: reason.into(),
        }
    }
}

impl std::fmt::Display for SkipIngestError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "skip_ingest: {}", self.reason)
    }
}

impl std::error::Error for SkipIngestError {}

fn should_ignore_ingest_path(path: &std::path::Path) -> bool {
    if path
        .components()
        .any(|c| c.as_os_str().to_string_lossy() == "__MACOSX")
    {
        return true;
    }
    let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
    if name.is_empty() {
        return false;
    }
    // AppleDouble resource forks created by macOS when copying to non-HFS volumes.
    if name.starts_with("._") {
        return true;
    }
    // Other common filesystem junk
    matches!(name, ".DS_Store" | "Thumbs.db")
}

// Recursively index all photos in a folder
fn index_folder_recursively(
    state: Arc<AppState>,
    data_db: crate::database::multi_tenant::DbPool,
    embedding_store: Arc<crate::database::embeddings::EmbeddingStore>,
    folder_path: String,
    base_root: String,
    user_id: String,
    timing: std::sync::Arc<IndexTimingStats>,
    progress_tx: Option<broadcast::Sender<String>>,
    processed: std::sync::Arc<std::sync::atomic::AtomicUsize>,
    total: std::sync::Arc<std::sync::atomic::AtomicUsize>,
    cancel_flag: std::sync::Arc<std::sync::atomic::AtomicBool>,
    album_opts: AlbumIndexOptions,
    checkpoint_throttle: std::sync::Arc<std::sync::Mutex<ReindexCheckpointThrottle>>,
) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<usize, anyhow::Error>> + Send>> {
    Box::pin(async move {
        use std::fs;

        // Skip internal library_root to prevent re-indexing files already ingested by uploads
        let lib_root = state
            .library_root
            .canonicalize()
            .unwrap_or(state.library_root.clone());
        let current = std::path::Path::new(&folder_path)
            .canonicalize()
            .unwrap_or(std::path::PathBuf::from(&folder_path));
        if current.starts_with(&lib_root) {
            tracing::warn!("[REINDEX] Skipping internal library folder {}", folder_path);
            return Ok(0);
        }

        let mut indexed_count = 0;
        let entries = fs::read_dir(&folder_path)?;

        for entry in entries {
            if cancel_flag.load(std::sync::atomic::Ordering::Relaxed) {
                tracing::warn!("[REINDEX] Cancellation detected (user={})", user_id);
                break;
            }
            let entry = entry?;
            let path = entry.path();

            if should_ignore_ingest_path(&path) {
                continue;
            }

            if path.is_dir() {
                // Recursively index subdirectories
                let subdir_count = index_folder_recursively(
                    state.clone(),
                    data_db.clone(),
                    embedding_store.clone(),
                    path.to_string_lossy().to_string(),
                    base_root.clone(),
                    user_id.clone(),
                    timing.clone(),
                    progress_tx.clone(),
                    processed.clone(),
                    total.clone(),
                    cancel_flag.clone(),
                    album_opts.clone(),
                    checkpoint_throttle.clone(),
                )
                .await?;
                indexed_count += subdir_count;
            } else if path.is_file() {
                // Check if it's an image file (including HEIC variants) or video
                if let Some(extension) = path.extension() {
                    let ext = extension.to_string_lossy().to_lowercase();
                    if matches!(
                        ext.as_str(),
                        "jpg" | "jpeg" | "png" | "webp" | "bmp" | "tiff" | "avif"
                    ) {
                        let t0 = std::time::Instant::now();
                        match index_single_photo_for_user(
                            &state,
                            &data_db,
                            &embedding_store,
                            &path,
                            &user_id,
                            None,
                        )
                        .await
                        {
                            Ok(()) => {
                                let dur_us = t0.elapsed().as_micros() as u64;
                                timing.photo_us.fetch_add(dur_us, Ordering::Relaxed);
                                timing.photos_count.fetch_add(1, Ordering::Relaxed);
                                indexed_count += 1;
                                let current = processed
                                    .fetch_add(1, std::sync::atomic::Ordering::Relaxed)
                                    + 1;
                                if let Some(tx) = &progress_tx {
                                    let _ = tx.send(serde_json::json!({
                                        "type": "progress",
                                        "stage": "indexing",
                                        "processed": current,
                                        "total": total.load(std::sync::atomic::Ordering::Relaxed)
                                    }).to_string());
                                }
                                // Periodic checkpoint (throttled): keeps the WAL bounded during very
                                // long jobs without turning `CHECKPOINT;` into a hot path.
                                let do_checkpoint = {
                                    let mut throttle = checkpoint_throttle
                                        .lock()
                                        .unwrap_or_else(|e| e.into_inner());
                                    throttle.should_checkpoint()
                                };
                                if do_checkpoint {
                                    let conn_ck = data_db.lock();
                                    let _ = conn_ck.execute("CHECKPOINT;", []);
                                }
                                if indexed_count % 100 == 0 {
                                    tracing::info!("Indexed {} photos so far...", indexed_count);
                                }
                                // Album assignment for still images
                                if let Err(e) = maybe_assign_to_album(
                                    &state,
                                    &data_db,
                                    &user_id,
                                    &path,
                                    &base_root,
                                    &album_opts,
                                )
                                .await
                                {
                                    tracing::warn!(
                                        "[REINDEX] album assignment failed for {}: {}",
                                        path.display(),
                                        e
                                    );
                                }
                            }
                            Err(e) => {
                                if let Some(skip) = e.downcast_ref::<SkipIngestError>() {
                                    tracing::info!(
                                        "[REINDEX] Skipping {}: {}",
                                        path.display(),
                                        skip.reason
                                    );
                                    let current = processed
                                        .fetch_add(1, std::sync::atomic::Ordering::Relaxed)
                                        + 1;
                                    if let Some(tx) = &progress_tx {
                                        let _ = tx.send(serde_json::json!({
                                            "type": "progress",
                                            "stage": "indexing",
                                            "processed": current,
                                            "total": total.load(std::sync::atomic::Ordering::Relaxed)
                                        }).to_string());
                                    }
                                } else {
                                    tracing::warn!("Failed to index {}: {}", path.display(), e);
                                }
                            }
                        }
                    } else if matches!(ext.as_str(), "heic" | "heif") {
                        // Fallback to generic photo indexer (handles EXIF + metadata). Live Photo pairing is handled later by video path.
                        let t0 = std::time::Instant::now();
                        match index_single_photo_for_user(
                            &state,
                            &data_db,
                            &embedding_store,
                            &path,
                            &user_id,
                            None,
                        )
                        .await
                        {
                            Ok(()) => {
                                let dur_us = t0.elapsed().as_micros() as u64;
                                timing.photo_us.fetch_add(dur_us, Ordering::Relaxed);
                                timing.photos_count.fetch_add(1, Ordering::Relaxed);
                                indexed_count += 1;
                                let current = processed
                                    .fetch_add(1, std::sync::atomic::Ordering::Relaxed)
                                    + 1;
                                if let Some(tx) = &progress_tx {
                                    let _ = tx.send(serde_json::json!({
                                        "type": "progress",
                                        "stage": "indexing",
                                        "processed": current,
                                        "total": total.load(std::sync::atomic::Ordering::Relaxed)
                                    }).to_string());
                                }
                                let do_checkpoint = {
                                    let mut throttle = checkpoint_throttle
                                        .lock()
                                        .unwrap_or_else(|e| e.into_inner());
                                    throttle.should_checkpoint()
                                };
                                if do_checkpoint {
                                    let conn_ck = data_db.lock();
                                    let _ = conn_ck.execute("CHECKPOINT;", []);
                                }
                                // Album assignment for HEIC
                                if let Err(e) = maybe_assign_to_album(
                                    &state,
                                    &data_db,
                                    &user_id,
                                    &path,
                                    &base_root,
                                    &album_opts,
                                )
                                .await
                                {
                                    tracing::warn!(
                                        "[REINDEX] album assignment failed for {}: {}",
                                        path.display(),
                                        e
                                    );
                                }
                            }
                            Err(e) => {
                                if let Some(skip) = e.downcast_ref::<SkipIngestError>() {
                                    tracing::info!(
                                        "[REINDEX] Skipping {}: {}",
                                        path.display(),
                                        skip.reason
                                    );
                                    let current = processed
                                        .fetch_add(1, std::sync::atomic::Ordering::Relaxed)
                                        + 1;
                                    if let Some(tx) = &progress_tx {
                                        let _ = tx.send(serde_json::json!({
                                            "type": "progress",
                                            "stage": "indexing",
                                            "processed": current,
                                            "total": total.load(std::sync::atomic::Ordering::Relaxed)
                                        }).to_string());
                                    }
                                } else {
                                    tracing::warn!("Failed to index HEIC {}: {}", path.display(), e)
                                }
                            }
                        }
                    } else if matches!(ext.as_str(), "mp4" | "mov" | "m4v" | "webm" | "mkv" | "avi")
                    {
                        let t0 = std::time::Instant::now();
                        match index_video_for_user(
                            &state,
                            &data_db,
                            &embedding_store,
                            &path,
                            &user_id,
                            None,
                        )
                        .await
                        {
                            Ok(()) => {
                                let dur_us = t0.elapsed().as_micros() as u64;
                                timing.video_us.fetch_add(dur_us, Ordering::Relaxed);
                                timing.videos_count.fetch_add(1, Ordering::Relaxed);
                                indexed_count += 1;
                                let current = processed
                                    .fetch_add(1, std::sync::atomic::Ordering::Relaxed)
                                    + 1;
                                if let Some(tx) = &progress_tx {
                                    let _ = tx.send(serde_json::json!({
                                        "type": "progress",
                                        "stage": "indexing",
                                        "processed": current,
                                        "total": total.load(std::sync::atomic::Ordering::Relaxed)
                                    }).to_string());
                                }
                                let do_checkpoint = {
                                    let mut throttle = checkpoint_throttle
                                        .lock()
                                        .unwrap_or_else(|e| e.into_inner());
                                    throttle.should_checkpoint()
                                };
                                if do_checkpoint {
                                    let conn_ck = data_db.lock();
                                    let _ = conn_ck.execute("CHECKPOINT;", []);
                                }
                                // Album assignment for videos
                                if let Err(e) = maybe_assign_to_album(
                                    &state,
                                    &data_db,
                                    &user_id,
                                    &path,
                                    &base_root,
                                    &album_opts,
                                )
                                .await
                                {
                                    tracing::warn!(
                                        "[REINDEX] album assignment failed for video {}: {}",
                                        path.display(),
                                        e
                                    );
                                }
                            }
                            Err(e) => {
                                if let Some(skip) = e.downcast_ref::<SkipIngestError>() {
                                    tracing::info!(
                                        "[REINDEX] Skipping {}: {}",
                                        path.display(),
                                        skip.reason
                                    );
                                    let current = processed
                                        .fetch_add(1, std::sync::atomic::Ordering::Relaxed)
                                        + 1;
                                    if let Some(tx) = &progress_tx {
                                        let _ = tx.send(serde_json::json!({
                                            "type": "progress",
                                            "stage": "indexing",
                                            "processed": current,
                                            "total": total.load(std::sync::atomic::Ordering::Relaxed)
                                        }).to_string());
                                    }
                                } else {
                                    tracing::warn!(
                                        "Failed to index video {}: {}",
                                        path.display(),
                                        e
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }

        Ok(indexed_count)
    })
}

fn count_image_files(folder: &str) -> Result<usize, anyhow::Error> {
    use std::collections::HashSet;
    use std::fs;
    use std::path::{Path, PathBuf};

    fn ext_lower(path: &Path) -> String {
        path.extension()
            .and_then(|e| e.to_str())
            .map(|s| s.to_lowercase())
            .unwrap_or_else(|| String::new())
    }
    fn is_image_ext(ext: &str) -> bool {
        matches!(
            ext,
            "jpg" | "jpeg" | "png" | "webp" | "bmp" | "tiff" | "gif" | "heic" | "heif" | "avif"
        )
    }
    fn is_video_ext(ext: &str) -> bool {
        matches!(ext, "mp4" | "mov" | "m4v" | "webm" | "mkv" | "avi")
    }

    // Gather all files under folder
    let mut files: Vec<PathBuf> = Vec::new();
    fn collect(p: &Path, acc: &mut Vec<PathBuf>) -> std::io::Result<()> {
        for entry in fs::read_dir(p)? {
            let entry = entry?;
            let p2 = entry.path();
            if should_ignore_ingest_path(&p2) {
                continue;
            }
            if p2.is_dir() {
                collect(&p2, acc)?;
            } else if p2.is_file() {
                acc.push(p2);
            }
        }
        Ok(())
    }
    collect(Path::new(folder), &mut files)?;

    // Build a set of (dir, stem) for HEIC/HEIF so we can skip companion videos with same stem
    let mut heic_keys: HashSet<(PathBuf, String)> = HashSet::new();
    for f in &files {
        let ext = ext_lower(f);
        if ext == "heic" || ext == "heif" {
            let dir = f.parent().unwrap_or_else(|| Path::new("")).to_path_buf();
            let stem = f
                .file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or("")
                .to_lowercase();
            heic_keys.insert((dir, stem));
        }
    }

    // Count work units matching actual indexing behavior
    let mut total = 0usize;
    for f in &files {
        let ext = ext_lower(f);
        if is_image_ext(&ext) {
            total += 1;
        } else if is_video_ext(&ext) {
            // Skip videos that are Live Photo companions (same stem HEIC/HEIF in same directory)
            let dir = f.parent().unwrap_or_else(|| Path::new("")).to_path_buf();
            let stem = f
                .file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or("")
                .to_lowercase();
            if heic_keys.contains(&(dir, stem.clone())) {
                continue;
            }
            total += 1;
        }
    }
    Ok(total)
}

// --- Album assignment helpers for folder indexing ---
async fn maybe_assign_to_album(
    state: &Arc<AppState>,
    data_db: &crate::database::multi_tenant::DbPool,
    user_id: &str,
    file_path: &std::path::Path,
    base_root: &str,
    opts: &AlbumIndexOptions,
) -> Result<(), anyhow::Error> {
    // Postgres backend: implement via PG tables
    if let Some(pg) = &state.pg_client {
        // Early-out if nothing to do
        if !opts.preserve_tree_path && opts.album_parent_id.is_none() {
            return Ok(());
        }
        // Resolve org id
        let org_id: i32 = state.org_id_for_user(user_id);
        // Decide target album
        let target_album_id: Option<i32> = if opts.preserve_tree_path {
            let base = std::path::Path::new(base_root);
            let parent_dir = file_path
                .parent()
                .unwrap_or_else(|| std::path::Path::new(""));
            let rel = parent_dir.strip_prefix(base).unwrap_or(parent_dir);
            let segments: Vec<String> = rel
                .components()
                .filter_map(|c| match c {
                    std::path::Component::Normal(os) => Some(os.to_string_lossy().to_string()),
                    _ => None,
                })
                .filter(|s| !s.is_empty())
                .collect();
            if segments.is_empty() {
                opts.album_parent_id
            } else {
                let mut current = opts.album_parent_id;
                let now = chrono::Utc::now().timestamp();
                for seg in segments {
                    // find existing
                    let row = if let Some(pid) = current {
                        pg.query_opt(
                            "SELECT id, COALESCE(is_live,FALSE) FROM albums WHERE organization_id=$1 AND parent_id=$2 AND name_lc=lower($3) LIMIT 1",
                            &[&org_id, &pid, &seg],
                        )
                        .await
                        .ok()
                        .flatten()
                    } else {
                        pg.query_opt(
                            "SELECT id, COALESCE(is_live,FALSE) FROM albums WHERE organization_id=$1 AND parent_id IS NULL AND name_lc=lower($2) LIMIT 1",
                            &[&org_id, &seg],
                        )
                        .await
                        .ok()
                        .flatten()
                    };
                    if let Some(r) = row {
                        let id: i32 = r.get(0);
                        let is_live: bool = r.get(1);
                        if is_live {
                            return Ok(());
                        }
                        current = Some(id);
                        continue;
                    }
                    // create album
                    let name_lc = seg.to_lowercase();
                    let parent_id = current;
                    let rowc = pg
                        .query_one(
                            "INSERT INTO albums (organization_id, user_id, name, name_lc, description, parent_id, created_at, updated_at) VALUES ($1,$2,$3,$4,$5,$6,$7,$8) RETURNING id",
                            &[&org_id, &user_id, &seg, &name_lc, &Option::<String>::None, &parent_id, &now, &now],
                        )
                        .await
                        .map_err(|e| anyhow::anyhow!(e))?;
                    let new_id: i32 = rowc.get(0);
                    // closure (best-effort)
                    let _ = pg
                        .execute(
                            "INSERT INTO album_closure (organization_id, ancestor_id, descendant_id, depth) VALUES ($1,$2,$3,0) ON CONFLICT DO NOTHING",
                            &[&org_id, &new_id, &new_id],
                        )
                        .await;
                    if let Some(pid) = parent_id {
                        let _ = pg
                            .execute(
                                "INSERT INTO album_closure (organization_id, ancestor_id, descendant_id, depth) SELECT organization_id, ancestor_id, $1, depth + 1 FROM album_closure WHERE organization_id=$2 AND descendant_id=$3",
                                &[&new_id, &org_id, &pid],
                            )
                            .await;
                        let _ = pg
                            .execute(
                                "INSERT INTO album_closure (organization_id, ancestor_id, descendant_id, depth) VALUES ($1,$2,$3,1) ON CONFLICT DO NOTHING",
                                &[&org_id, &pid, &new_id],
                            )
                            .await;
                    }
                    current = Some(new_id);
                }
                current
            }
        } else {
            opts.album_parent_id
        };
        let Some(album_id) = target_album_id else {
            return Ok(());
        };
        // attach
        let pid_opt: Option<i32> = pg
            .query_opt(
                "SELECT id FROM photos WHERE organization_id=$1 AND user_id=$2 AND path=$3 LIMIT 1",
                &[&org_id, &user_id, &file_path.to_string_lossy().to_string()],
            )
            .await
            .ok()
            .flatten()
            .map(|r| r.get::<_, i32>(0));
        if let Some(photo_id) = pid_opt {
            let now = chrono::Utc::now().timestamp();
            let res = pg
                .execute(
                    "INSERT INTO album_photos (organization_id, album_id, photo_id, added_at) VALUES ($1,$2,$3,$4) ON CONFLICT (organization_id, album_id, photo_id) DO NOTHING",
                    &[&org_id, &album_id, &photo_id, &now],
                )
                .await;
            if let Err(e) = res {
                tracing::warn!(
                    target = "albums",
                    "[ALBUMS] attach failed (org_id={}, album_id={}, photo_id={}): {}",
                    org_id,
                    album_id,
                    photo_id,
                    e
                );
            }
        }
        return Ok(());
    }
    // If preserve is off and no parent album was selected, do nothing
    if !opts.preserve_tree_path && opts.album_parent_id.is_none() {
        return Ok(());
    }

    // Compute target album id
    let target_album: Option<i32> = if opts.preserve_tree_path {
        // Derive chain from relative path under base_root
        let base = std::path::Path::new(base_root);
        let parent_dir = file_path
            .parent()
            .unwrap_or_else(|| std::path::Path::new(""));
        let rel = parent_dir.strip_prefix(base).unwrap_or(parent_dir);
        let segments: Vec<String> = rel
            .components()
            .filter_map(|c| match c {
                std::path::Component::Normal(os) => Some(os.to_string_lossy().to_string()),
                _ => None,
            })
            .filter(|s| !s.is_empty())
            .collect();
        if segments.is_empty() {
            // If there are no segments and a parent was chosen, assign directly to it; otherwise skip
            opts.album_parent_id
        } else {
            let pid = opts.album_parent_id;
            Some(ensure_album_chain(state, user_id, pid, &segments).await?)
        }
    } else {
        // Flat assignment: use chosen album if any
        opts.album_parent_id
    };

    let Some(album_id) = target_album else {
        return Ok(());
    };

    // Lookup the photo row id and attach to album
    let pid_opt: Option<i32> = {
        let conn = data_db.lock();
        let r = conn
            .query_row(
                "SELECT id FROM photos WHERE path = ? LIMIT 1",
                duckdb::params![file_path.to_string_lossy().to_string()],
                |row| row.get::<_, i32>(0),
            )
            .ok();
        r
    };
    if let Some(photo_id) = pid_opt {
        let db = state
            .multi_tenant_db
            .as_ref()
            .expect("user DB required in DuckDB mode")
            .clone();
        let svc = crate::photos::service::PhotoService::new(db);
        let _ = svc
            .add_photos_to_album(user_id, album_id, vec![photo_id])
            .await;
    }
    Ok(())
}

async fn ensure_album_chain(
    state: &Arc<AppState>,
    user_id: &str,
    parent_id: Option<i32>,
    segments: &[String],
) -> Result<i32, anyhow::Error> {
    use duckdb::params;
    let db = state
        .multi_tenant_db
        .as_ref()
        .expect("user DB required in DuckDB mode")
        .clone();
    let svc = crate::photos::service::PhotoService::new(db);
    let user_db = state
        .multi_tenant_db
        .as_ref()
        .expect("user DB required in DuckDB mode")
        .get_user_database(user_id)?;
    // Resolve organization_id for scoping
    let organization_id: i32 = state.org_id_for_user(user_id);
    let mut current_parent = parent_id;
    for name in segments {
        // Try to find existing album
        let found: Option<i32> = {
            let conn = user_db.lock();
            if let Some(pid) = current_parent {
                conn
                    .query_row(
                        "SELECT id FROM albums WHERE organization_id = ? AND parent_id = ? AND name = ? AND deleted_at IS NULL LIMIT 1",
                        params![organization_id, pid, name],
                        |row| row.get::<_, i32>(0),
                    )
                    .ok()
            } else {
                conn
                    .query_row(
                        "SELECT id FROM albums WHERE organization_id = ? AND parent_id IS NULL AND name = ? AND deleted_at IS NULL LIMIT 1",
                        params![organization_id, name],
                        |row| row.get::<_, i32>(0),
                    )
                    .ok()
            }
        };
        if let Some(id) = found {
            current_parent = Some(id);
            continue;
        }
        // Create new album when missing
        let req = crate::photos::service::CreateAlbumRequest {
            name: name.clone(),
            description: None,
            parent_id: current_parent,
        };
        let album = svc.create_album(user_id, req).await?;
        current_parent = Some(album.id);
    }
    current_parent.ok_or_else(|| anyhow::anyhow!("No album id resolved"))
}

async fn upsert_visual_embedding_for_image(
    state: &Arc<AppState>,
    embedding_store: &Arc<crate::database::embeddings::EmbeddingStore>,
    asset_id: &str,
    content_type: &str,
    image_path: &std::path::Path,
    img: &image::DynamicImage,
) {
    let (w, h) = img.dimensions();
    let t_clip = std::time::Instant::now();
    if let Some(res) = state.with_visual_encoder(None, |encoder| encoder.encode_image(img)) {
        match res {
            Ok(embedding) => {
                let t_yolo = std::time::Instant::now();
                let detected_objects: Vec<String> = if state.enable_object_detect_on_index {
                    state
                        .yolo_detector
                        .detect(img)
                        .unwrap_or_default()
                        .iter()
                        .map(|d| d.class.clone())
                        .collect()
                } else {
                    Vec::new()
                };
                let yolo_ms = t_yolo.elapsed().as_millis();
                let _ = embedding_store
                    .upsert_image_embedding(
                        asset_id.to_string(),
                        embedding,
                        None,
                        w,
                        h,
                        content_type.to_string(),
                        Some(detected_objects),
                        Some(vec![]),
                    )
                    .await;
                tracing::info!(
                    "[REINDEX] CLIP+upsert ms={} (yolo_ms={}) for {}",
                    t_clip.elapsed().as_millis(),
                    yolo_ms,
                    image_path.display()
                );
            }
            Err(e) => tracing::warn!(
                "[REINDEX] Failed to encode embedding for {}: {}",
                image_path.display(),
                e
            ),
        }
    } else {
        tracing::warn!(
            "[REINDEX] Visual encoder unavailable while indexing {}",
            image_path.display()
        )
    }
}

// Index a single photo for a specific user
pub(crate) async fn index_single_photo_for_user(
    state: &Arc<AppState>,
    data_db: &crate::database::multi_tenant::DbPool,
    embedding_store: &Arc<crate::database::embeddings::EmbeddingStore>,
    image_path: &std::path::Path,
    user_id: &str,
    forced_asset_id: Option<&str>,
) -> Result<(), anyhow::Error> {
    use image::GenericImageView;
    tracing::info!("[REINDEX] Begin index file {:?}", image_path);
    if should_ignore_ingest_path(image_path) {
        return Err(SkipIngestError::new(format!(
            "ignored non-media file: {}",
            image_path.display()
        ))
        .into());
    }
    let t_all = std::time::Instant::now();

    // File system metadata
    let metadata = std::fs::metadata(image_path)?;
    let file_size = metadata.len();
    let modified_time = metadata
        .modified()?
        .duration_since(std::time::UNIX_EPOCH)?
        .as_secs() as i64;

    // Guess content type from extension
    let ext = image_path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_lowercase();
    let content_type = crate::photos::mime_type_for_extension(ext.as_str())
        .unwrap_or("application/octet-stream")
        .to_string();

    // Try to load image only for formats commonly supported by the `image` crate
    let supports_decode = matches!(
        ext.as_str(),
        "jpg" | "jpeg" | "png" | "webp" | "bmp" | "tiff" | "gif" | "avif"
    );

    let mut width_i32: i32 = 0;
    let mut height_i32: i32 = 0;
    let is_video_flag = matches!(ext.as_str(), "mp4" | "mov" | "m4v" | "webm" | "mkv" | "avi");

    // Resolve user's organization id for scoping embedding queries (PG or DuckDB)
    let org_id: i32 = state.org_id_for_user(user_id);

    // Pre-check existing row by path (skip work when unchanged)
    let (existing_asset_id, existing_size, existing_modified, existing_hash): (
        Option<String>,
        Option<i64>,
        Option<i64>,
        Option<String>,
    ) = {
        let conn = data_db.lock();
        let mut stmt = conn
            .prepare("SELECT asset_id, size, modified_at, content_hash FROM photos WHERE path = ? LIMIT 1")
            .ok();
        if let Some(ref mut s) = stmt {
            match s.query_row([&image_path.to_string_lossy().to_string()], |row| {
                Ok((
                    row.get::<_, String>(0).ok(),
                    row.get::<_, i64>(1).ok(),
                    row.get::<_, i64>(2).ok(),
                    row.get::<_, String>(3).ok(),
                ))
            }) {
                Ok(t) => t,
                Err(_) => (None, None, None, None),
            }
        } else {
            (None, None, None, None)
        }
    };
    if let (Some(aid), Some(db_size), Some(db_mod)) =
        (&existing_asset_id, existing_size, existing_modified)
    {
        if (file_size as i64) == db_size && modified_time <= db_mod {
            let now = chrono::Utc::now().timestamp();
            let conn = data_db.lock();
            let _ = conn.execute(
                "UPDATE photos SET last_indexed = ?, filename = COALESCE(filename, ?) WHERE asset_id = ?",
                duckdb::params![now, image_path.file_name().unwrap_or_default().to_string_lossy().to_string(), aid],
            );
            return Ok(());
        }
    }

    // Changed or new: compute content fingerprint; compute asset_id only if inserting
    let bytes = std::fs::read(image_path)?;
    let content_hash = blake3::hash(&bytes).to_hex().to_string();
    let backup_id = crate::photos::backup_id::from_bytes(&bytes, user_id)?;
    let asset_id: String =
        if let Some(forced) = forced_asset_id.map(|s| s.trim()).filter(|s| !s.is_empty()) {
            forced.to_string()
        } else if let Some(existing) = &existing_asset_id {
            existing.clone()
        } else {
            crate::photos::asset_id::from_bytes(&bytes, user_id)?
        };
    let content_changed = existing_hash.as_deref() != Some(&content_hash);

    fn looks_like_image(ext: &str, bytes: &[u8]) -> bool {
        match ext {
            "jpg" | "jpeg" => bytes.len() >= 2 && bytes[0] == 0xFF && bytes[1] == 0xD8,
            "png" => bytes.starts_with(b"\x89PNG\r\n\x1a\n"),
            "gif" => bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a"),
            "webp" => bytes.len() >= 12 && &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WEBP",
            "bmp" => bytes.starts_with(b"BM"),
            "tif" | "tiff" => bytes.starts_with(b"II*\0") || bytes.starts_with(b"MM\0*"),
            // AVIF container/brand variants in the wild can break strict pre-signature checks.
            // Let decode paths be the source of truth for validity.
            "avif" => true,
            _ => true,
        }
    }

    if supports_decode {
        if !looks_like_image(ext.as_str(), &bytes) {
            return Err(SkipIngestError::new(format!(
                "corrupt image (invalid {} signature): {}",
                ext,
                image_path.display()
            ))
            .into());
        }
        match image::open(image_path) {
            Ok(img) => {
                let (w, h) = img.dimensions();
                width_i32 = w as i32;
                height_i32 = h as i32;
                tracing::info!("[REINDEX] Decoded image {}x{} at {:?}", w, h, image_path);

                if content_changed {
                    // NOTE: Do NOT persist full image bytes into `smart_search.image_data`.
                    // Thumbnails/previews are served from `/api/thumbnails/:asset_id` and
                    // `/api/images/:asset_id`. Storing BLOBs here massively bloats DuckDB and
                    // makes checkpoints (and memory usage) explode over time.
                    upsert_visual_embedding_for_image(
                        state,
                        embedding_store,
                        &asset_id,
                        &content_type,
                        image_path,
                        &img,
                    )
                    .await;
                }
            }
            Err(e) => {
                // AVIF may fail native `image::open` on some deployments; retry with generic fallback.
                if ext == "avif" {
                    match crate::photos::metadata::open_image_any(image_path) {
                        Ok(img) => {
                            let (w, h) = img.dimensions();
                            width_i32 = w as i32;
                            height_i32 = h as i32;
                            tracing::info!(
                                "[REINDEX] Fallback decoded AVIF (open_image_any) {}x{} for {}",
                                w,
                                h,
                                image_path.display()
                            );
                            if content_changed {
                                upsert_visual_embedding_for_image(
                                    state,
                                    embedding_store,
                                    &asset_id,
                                    &content_type,
                                    image_path,
                                    &img,
                                )
                                .await;
                            }
                        }
                        Err(fallback_err) => {
                            return Err(SkipIngestError::new(format!(
                                "corrupt image (decode failed): {} ({})",
                                image_path.display(),
                                fallback_err
                            ))
                            .into());
                        }
                    }
                } else {
                    return Err(SkipIngestError::new(format!(
                        "corrupt image (decode failed): {} ({})",
                        image_path.display(),
                        e
                    ))
                    .into());
                }
            }
        }
    } else {
        // Unsupported by the `image` crate (e.g., HEIC) or video.
        // For still images, attempt a lightweight decode via open_image_any to populate dimensions
        if !is_video_flag {
            match crate::photos::metadata::open_image_any(image_path) {
                Ok(img) => {
                    let (w, h) = img.dimensions();
                    width_i32 = w as i32;
                    height_i32 = h as i32;
                    tracing::info!(
                        "[REINDEX] Fallback decoded (open_image_any) {}x{} for {}",
                        w,
                        h,
                        image_path.display()
                    );
                    if content_changed {
                        upsert_visual_embedding_for_image(
                            state,
                            embedding_store,
                            &asset_id,
                            &content_type,
                            image_path,
                            &img,
                        )
                        .await;
                    }
                }
                Err(e) => {
                    if crate::photos::supports_metadata_only_still_ingest(ext.as_str()) {
                        // Keep still-image uploads indexable even when preview/decode backends are unavailable.
                        // This preserves gallery visibility and content_id-based pairing instead of skipping ingest.
                        tracing::warn!(
                            "[REINDEX] {} decode unavailable; indexing metadata-only for {}: {}",
                            ext.to_uppercase(),
                            image_path.display(),
                            e
                        );
                    } else {
                        return Err(SkipIngestError::new(format!(
                            "corrupt image (decode failed): {} ({})",
                            image_path.display(),
                            e
                        ))
                        .into());
                    }
                }
            }
        } else {
            tracing::info!(
                "[REINDEX] Skipping embedding for non-image file: {} (ext: {})",
                image_path.display(),
                ext
            );
        }
    }

    // Heuristic screenshot detection (precision-first)
    let is_screenshot_flag: bool = {
        if is_video_flag || width_i32 <= 0 || height_i32 <= 0 {
            false
        } else {
            // Filename keywords
            let fname_lc = image_path
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("")
                .to_lowercase();
            let fn_hit = [
                "screenshot",
                "screen shot",
                "screen_shot",
                "screen-shot",
                "スクリーンショット",
                "屏幕快照",
                "屏幕截图",
                "截屏",
                "캡처",
                "снимок экрана",
                "captura de pantalla",
                "snímek obrazovky",
                "schermata",
                "ecran",
            ]
            .iter()
            .any(|k| fname_lc.contains(k));

            // Camera EXIF presence
            let (is_png, is_jpeg) = (content_type == "image/png", content_type == "image/jpeg");
            let camera_exif_present = if is_png || is_jpeg {
                use std::fs::File;
                use std::io::BufReader;
                if let Ok(f) = File::open(image_path) {
                    let mut rdr = BufReader::new(f);
                    let exif_reader = exif::Reader::new();
                    if let Ok(exif) = exif_reader.read_from_container(&mut rdr) {
                        exif.get_field(exif::Tag::Make, exif::In::PRIMARY).is_some()
                            || exif
                                .get_field(exif::Tag::Model, exif::In::PRIMARY)
                                .is_some()
                            || exif
                                .get_field(exif::Tag::PhotographicSensitivity, exif::In::PRIMARY)
                                .is_some()
                            || exif
                                .get_field(exif::Tag::FNumber, exif::In::PRIMARY)
                                .is_some()
                            || exif
                                .get_field(exif::Tag::ExposureTime, exif::In::PRIMARY)
                                .is_some()
                            || exif
                                .get_field(exif::Tag::FocalLength, exif::In::PRIMARY)
                                .is_some()
                    } else {
                        false
                    }
                } else {
                    false
                }
            } else {
                false
            };

            // Device resolution match (±3 px, portrait or landscape)
            let tol: i32 = 3;
            let w = width_i32;
            let h = height_i32;
            let common = [
                (1170, 2532),
                (1284, 2778),
                (1179, 2556),
                (1290, 2796),
                (1125, 2436),
                (1242, 2688),
                (1080, 1920),
                (1080, 2340),
                (1080, 2400),
                (1440, 2560),
                (1440, 3200),
                (2048, 2732),
                (1668, 2388),
                (1640, 2360),
                (1620, 2160),
                (1920, 1080),
                (2560, 1440),
                (1366, 768),
                (2560, 1600),
                (2880, 1800),
                (3024, 1964),
                (3456, 2234),
                (3840, 2160),
            ];
            let device_match = common.iter().any(|(sw, sh)| {
                (w - sw).abs() <= tol && (h - sh).abs() <= tol
                    || (w - sh).abs() <= tol && (h - sw).abs() <= tol
            });

            // Aspect ratio hint
            let ar = if h != 0 { (w as f32) / (h as f32) } else { 0.0 };
            let ar16_9 = (1.0 - (ar / (16.0 / 9.0))).abs() <= 0.01;
            let ar9_16 = (1.0 - (ar / (9.0 / 16.0))).abs() <= 0.01;
            let ar_hint = ar16_9 || ar9_16;

            if fn_hit {
                true
            } else if (!camera_exif_present) && device_match && (is_png || is_jpeg) {
                true
            } else if is_png && !camera_exif_present && ar_hint {
                true
            } else {
                false
            }
        }
    };

    // Parse EXIF/metadata for created_at (EXIF DateTimeOriginal), camera, ISO, GPS
    let mut parsed = crate::photos::Photo::from_path(image_path, user_id)
        .map_err(|e| anyhow::anyhow!("from_path: {}", e))?;
    if parsed.width.is_none() && width_i32 > 0 {
        parsed.width = Some(width_i32);
    }
    if parsed.height.is_none() && height_i32 > 0 {
        parsed.height = Some(height_i32);
    }
    let _ = crate::photos::metadata::extract_metadata(&mut parsed);
    let created_time = if parsed.created_at > 0 {
        parsed.created_at
    } else {
        modified_time
    };

    // Postgres metadata path via MetaStore (no DuckDB usage)
    if let Some(meta) = &state.meta {
        let up = crate::database::meta_store::PhotoUpsert {
            asset_id: asset_id.clone(),
            path: image_path.to_string_lossy().to_string(),
            filename: image_path
                .file_name()
                .unwrap_or_default()
                .to_string_lossy()
                .to_string(),
            mime_type: Some(content_type.clone()),
            backup_id: Some(backup_id.clone()),
            created_at: created_time,
            modified_at: modified_time,
            size: file_size as i64,
            width: Some(parsed.width.unwrap_or(width_i32)),
            height: Some(parsed.height.unwrap_or(height_i32)),
            orientation: parsed.orientation,
            is_video: is_video_flag,
            is_live_photo: false,
            live_video_path: None,
            duration_ms: None,
            is_screenshot: if is_screenshot_flag { 1 } else { 0 },
            camera_make: parsed.camera_make.clone(),
            camera_model: parsed.camera_model.clone(),
            iso: parsed.iso,
            aperture: parsed.aperture,
            shutter_speed: parsed.shutter_speed.clone(),
            focal_length: parsed.focal_length,
            latitude: parsed.latitude,
            longitude: parsed.longitude,
            altitude: parsed.altitude,
            location_name: parsed.location_name.clone(),
            city: parsed.city.clone(),
            province: parsed.province.clone(),
            country: parsed.country.clone(),
            caption: parsed.caption.clone(),
            description: parsed.description.clone(),
        };
        // Verbose param diagnostics for PG upsert failures
        let cap_len = up.caption.as_ref().map(|s| s.len()).unwrap_or(0);
        let desc_len = up.description.as_ref().map(|s| s.len()).unwrap_or(0);
        let diag = format!(
            "asset={} w={} h={} is_video={} orient={:?} iso={:?} aperture={:?} shutter={:?} focal={:?} lat={:?} lon={:?} alt={:?} cap_len={} desc_len={}",
            up.asset_id,
            up.width.unwrap_or(0),
            up.height.unwrap_or(0),
            up.is_video,
            up.orientation,
            up.iso,
            up.aperture,
            up.shutter_speed,
            up.focal_length,
            up.latitude,
            up.longitude,
            up.altitude,
            cap_len,
            desc_len
        );
        tracing::info!(target = "upload", "[PG] upsert_photo params: {}", diag);
        if let Err(e) = meta.upsert_photo(org_id, user_id, &up).await {
            tracing::warn!(
                target = "upload",
                "[PG] upsert_photo failed: {} | {}",
                e.to_string(),
                diag
            );
            return Err(anyhow::anyhow!(e.to_string()));
        }

        // Reverse geocode via PG cache and update location fields when available
        if let (Some(lat), Some(lon)) = (parsed.latitude, parsed.longitude) {
            if let Some(pg) = &state.pg_client {
                let t_gc = std::time::Instant::now();
                if let Ok((name, city, prov, country)) =
                    crate::photos::geocode::reverse_geocode_cached_pg(pg, org_id, lat, lon).await
                {
                    let _ = pg
                        .execute(
                            "UPDATE photos SET location_name = COALESCE(location_name,$1), city=COALESCE(city,$2), province=COALESCE(province,$3), country=COALESCE(country,$4) WHERE organization_id=$5 AND asset_id=$6",
                            &[&name, &city, &prov, &country, &org_id, &asset_id],
                        )
                        .await;
                    tracing::info!(
                        target = "geocode",
                        "[REINDEX] geocode (pg) ms={} lat={} lon={}",
                        t_gc.elapsed().as_millis(),
                        lat,
                        lon
                    );
                }
            }
        }

        // pHash into Postgres and in-memory band index
        if !is_video_flag && content_changed {
            match crate::photos::phash::compute_phash_from_path(image_path) {
                Ok(h) => {
                    let hex = crate::photos::phash::phash_to_hex(h);
                    meta.insert_or_update_phash(org_id, &asset_id, &hex)
                        .await
                        .ok();
                    if let Ok(idx) = state.get_or_build_similar_index(user_id) {
                        let mut guard = idx.write();
                        guard.upsert(asset_id.clone(), h);
                        tracing::info!(
                            "[PHASH] Index upsert complete (user={}, size={})",
                            user_id,
                            guard.len()
                        );
                    }
                }
                Err(e) => {
                    tracing::warn!(
                        "[REINDEX] Failed to compute pHash for {}: {}",
                        image_path.display(),
                        e
                    );
                }
            }
        }

        // Ensure on-disk thumbnail exists
        if let Err(e) = ensure_thumbnail_for_user(state, user_id, &asset_id, image_path) {
            tracing::warn!(
                "[REINDEX] Failed to generate thumbnail for {}: {}",
                asset_id,
                e
            );
        }
        // Face detection (PG only; no DuckDB usage)
        if state.face_service.is_enabled() {
            let settings = load_face_settings(state, user_id);
            if let Err(e) = state
                .face_service
                .process_and_store_faces_pg(&asset_id, image_path, None, &settings, org_id)
                .await
            {
                tracing::warn!(
                    "[REINDEX] Face processing failed for {}: {}",
                    image_path.display(),
                    e
                );
            }
        }
        return Ok(());
    }

    // Store photo metadata in user's data database
    {
        let now_ts = chrono::Utc::now().timestamp();
        let conn = data_db.lock();
        conn.execute(
            "INSERT INTO photos (
            organization_id, user_id, asset_id, path, filename, mime_type, content_hash, backup_id, created_at, modified_at, size,
            width, height, is_video, is_screenshot, last_indexed
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (organization_id, asset_id) DO UPDATE SET 
            path = EXCLUDED.path,
            filename = EXCLUDED.filename,
            modified_at = EXCLUDED.modified_at,
            size = EXCLUDED.size,
            width = EXCLUDED.width,
            height = EXCLUDED.height,
            is_video = EXCLUDED.is_video,
            is_screenshot = EXCLUDED.is_screenshot,
            content_hash = EXCLUDED.content_hash,
            backup_id = EXCLUDED.backup_id,
            last_indexed = EXCLUDED.last_indexed,
            locked = FALSE,
            crypto_version = 0",
            &[
                &org_id as &dyn duckdb::ToSql,
                &user_id as &dyn duckdb::ToSql,
                &asset_id as &dyn duckdb::ToSql,
                &image_path.to_string_lossy().to_string() as &dyn duckdb::ToSql,
                &image_path
                    .file_name()
                    .unwrap_or_default()
                    .to_string_lossy()
                    .to_string() as &dyn duckdb::ToSql,
                &content_type as &dyn duckdb::ToSql,
                &content_hash as &dyn duckdb::ToSql,
                &backup_id as &dyn duckdb::ToSql,
                &created_time as &dyn duckdb::ToSql,
                &modified_time as &dyn duckdb::ToSql,
                &(file_size as i64) as &dyn duckdb::ToSql,
                &(parsed.width.unwrap_or(width_i32)) as &dyn duckdb::ToSql,
                &(parsed.height.unwrap_or(height_i32)) as &dyn duckdb::ToSql,
                &is_video_flag as &dyn duckdb::ToSql,
                &is_screenshot_flag as &dyn duckdb::ToSql,
                &now_ts as &dyn duckdb::ToSql,
            ],
        )?;

        // Optional: trace a small sample of inserts
        tracing::debug!(
            "[REINDEX] Upserted photo asset_id={} path={}",
            asset_id,
            image_path.to_string_lossy()
        );
    } // end insert lock scope

    // Enrich row with camera and GPS; then reverse geocode if coordinates exist
    {
        let connm = data_db.lock();
        let _ = connm.execute(
            "UPDATE photos SET camera_make = ?, camera_model = ?, iso = ?, aperture = ?, shutter_speed = ?, focal_length = ?, latitude = ?, longitude = ?, altitude = ?, caption = COALESCE(caption, ?) WHERE asset_id = ?",
            duckdb::params![
                &parsed.camera_make,
                &parsed.camera_model,
                parsed.iso,
                parsed.aperture,
                &parsed.shutter_speed,
                parsed.focal_length,
                parsed.latitude,
                parsed.longitude,
                parsed.altitude,
                &parsed.caption,
                &asset_id
            ],
        );
        if let Some(cap) = parsed.caption.as_ref() {
            let mut v = cap.clone();
            if v.len() > 200 {
                v.truncate(200);
                v.push_str("…");
            }
            tracing::info!(target:"upload", "[EXIF] Parsed caption for asset {}: '{}'", asset_id, v);
        }
    }
    if let (Some(lat), Some(lon)) = (parsed.latitude, parsed.longitude) {
        let t_gc = std::time::Instant::now();
        if let Ok((name, city, prov, country)) =
            crate::photos::geocode::reverse_geocode_cached(data_db, lat, lon).await
        {
            let connr = data_db.lock();
            let _ = connr.execute(
                    "UPDATE photos SET location_name = COALESCE(location_name, ?), city = COALESCE(city, ?), province = COALESCE(province, ?), country = COALESCE(country, ?) WHERE asset_id = ?",
                    duckdb::params![&name, &city, &prov, &country, &asset_id],
                );
            tracing::info!(
                "[REINDEX] geocode ms={} lat={} lon={}",
                t_gc.elapsed().as_millis(),
                lat,
                lon
            );
        }
    }

    // Compute and persist pHash for all still images (including HEIC/HEIF).
    // Do not gate on `supports_decode` because pHash uses our HEIC proxy when needed.
    if !is_video_flag && content_changed {
        match crate::photos::phash::compute_phash_from_path(image_path) {
            Ok(h) => {
                let hex = crate::photos::phash::phash_to_hex(h);
                tracing::info!(
                    "[PHASH] Computed pHash for {} => {}",
                    image_path.display(),
                    hex
                );
                let conn = data_db.lock();
                // Ensure multi-tenant schema and unique index exist
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
                let _ = conn.execute(
                    "INSERT INTO photo_hashes(organization_id, asset_id, phash_hex) VALUES (?, ?, ?) \
                     ON CONFLICT (organization_id, asset_id) DO UPDATE SET phash_hex = EXCLUDED.phash_hex",
                    &[&org_id as &dyn duckdb::ToSql, &asset_id as &dyn duckdb::ToSql, &hex],
                );
                drop(conn);
                // Update in-memory index
                if let Ok(idx) = state.get_or_build_similar_index(user_id) {
                    let mut guard = idx.write();
                    guard.upsert(asset_id.clone(), h);
                    tracing::info!(
                        "[PHASH] Index upsert complete (user={}, size={})",
                        user_id,
                        guard.len()
                    );
                }
            }
            Err(e) => {
                tracing::warn!(
                    "[REINDEX] Failed to compute pHash for {}: {}",
                    image_path.display(),
                    e
                );
            }
        }
    }

    // Ensure on-disk thumbnail exists
    if let Err(e) = ensure_thumbnail_for_user(state, user_id, &asset_id, image_path) {
        tracing::warn!(
            "[REINDEX] Failed to generate thumbnail for {}: {}",
            asset_id,
            e
        );
    }

    // Incremental face detection + assignment (best-effort)
    if state.face_service.is_enabled() {
        // Get embedding DB in DuckDB mode for faces_embed/persons writes
        let embed_db = if state.pg_client.is_none() {
            state.get_user_embedding_database(user_id)?
        } else {
            // Dummy in PG mode; unused when calling PG path
            data_db.clone()
        };
        let settings = load_face_settings(state, user_id);
        if state.pg_client.is_some() {
            if let Err(e) = state
                .face_service
                .process_and_store_faces_pg(&asset_id, image_path, None, &settings, org_id)
                .await
            {
                tracing::warn!(
                    "[REINDEX] Face processing (pg) failed for {}: {}",
                    image_path.display(),
                    e
                );
            }
        } else {
            // Offload DuckDB face processing to a blocking thread to avoid stalling the async runtime
            let svc = state.face_service.clone();
            let db = embed_db.clone();
            let aid = asset_id.clone();
            let path_buf = image_path.to_path_buf();
            let settings_cloned = settings.clone();
            let org = org_id;
            if let Err(e) = tokio::task::spawn_blocking(move || {
                svc.process_and_store_faces_with_settings(
                    &db,
                    &aid,
                    &path_buf,
                    None,
                    &settings_cloned,
                    Some(org),
                )
            })
            .await
            .unwrap_or_else(|join_err| Err(anyhow::anyhow!(format!("join error: {}", join_err))))
            {
                tracing::warn!(
                    "[REINDEX] Face processing (duckdb) failed for {}: {}",
                    image_path.display(),
                    e
                );
            }
        }
    }

    tracing::info!(
        "[REINDEX] Completed file {:?} total_ms={}",
        image_path,
        t_all.elapsed().as_millis()
    );
    Ok(())
}

/*
// HEIC-specific indexing: currently disabled; use generic photo indexer for EXIF and metadata.
async fn index_heic_photo_for_user(
    _state: &Arc<AppState>,
    _data_db: &crate::database::multi_tenant::DbPool,
    _heic_path: &std::path::Path,
    _user_id: &str,
) -> Result<(), anyhow::Error> {
    Ok(())
}

// Original HEIC indexing (disabled)
#[cfg(any())]
async fn index_heic_photo_for_user(
    state: &Arc<AppState>,
    data_db: &crate::database::multi_tenant::DbPool,
    heic_path: &std::path::Path,
    user_id: &str,
) -> Result<(), anyhow::Error> {
    use crate::photos::metadata::open_image_any;
    use std::fs;
    use std::io::Read;
// asset_id from Base58(first16(HMAC-SHA256(user_id, file bytes)))
    let mut file = fs::File::open(heic_path)?;
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes)?;
    let asset_id = crate::photos::asset_id::from_bytes(&bytes, user_id)?;

    // File metadata
    let metadata = fs::metadata(heic_path)?;
    let file_size = metadata.len();
    let modified_time = metadata
        .modified()?
        .duration_since(std::time::UNIX_EPOCH)?
        .as_secs() as i64;
    // Parse EXIF for HEIC to preferentially set created_at and camera fields later
    let mut parsed = crate::photos::Photo::from_path(heic_path, user_id)
        .map_err(|e| anyhow::anyhow!("from_path: {}", e))?;
    let _ = crate::photos::metadata::extract_metadata(&mut parsed);
    let created_time = parsed.created_at.max(
        metadata
            .created()
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| d.as_secs() as i64)
            .unwrap_or(modified_time),
    );

    // Dimensions using HEIC-capable decoder
    let (width_i32, height_i32) = match open_image_any(heic_path) {
        Ok(img) => {
            let (w, h) = img.dimensions();
            (w as i32, h as i32)
        }
        Err(_) => (0, 0),
    };

    // Detect paired MOV for Live Photo
    let base = heic_path.with_extension("");
    let mov_lower = base.with_extension("mov");
    let mov_upper = base.with_extension("MOV");
    let mut live_mov = if mov_lower.exists() {
        Some(mov_lower)
    } else if mov_upper.exists() {
        Some(mov_upper)
    } else {
        None
    };
    // Additional heuristics: handle iOS IMG_E#### vs IMG_#### naming; or time-nearby MOV in same folder
    if live_mov.is_none() {
        if let Some(stem) = heic_path.file_stem().and_then(|s| s.to_str()) {
            let mut alt = None;
            if let Some(tail) = stem.strip_prefix("IMG_E") {
                alt = Some(format!("IMG_{}", tail));
            } else if let Some(tail) = stem.strip_prefix("IMG_") {
                alt = Some(format!("IMG_E{}", tail));
            }
            if let Some(altstem) = alt {
                let p = heic_path
                    .parent()
                    .unwrap_or_else(|| std::path::Path::new("."));
                let cand1 = p.join(format!("{}.mov", altstem));
                let cand2 = p.join(format!("{}.MOV", altstem));
                if cand1.exists() {
                    live_mov = Some(cand1);
                } else if cand2.exists() {
                    live_mov = Some(cand2);
                }
            }
        }
    }
    // Optional: time-nearby MOV heuristic (disabled by default as it can cause false positives)
    if live_mov.is_none() {
        let enable_nearby = std::env::var("ENABLE_NEARBY_LIVE_MATCH")
            .ok()
            .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
            .unwrap_or(false);
        if enable_nearby {
            // Time-nearby MOV in same directory (within 3 seconds)
            if let Ok(heic_meta) = std::fs::metadata(heic_path) {
                let heic_mtime = heic_meta
                    .modified()
                    .ok()
                    .and_then(|t| t.elapsed().ok())
                    .map(|e| e.as_secs())
                    .unwrap_or(0);
                if let Some(dir) = heic_path.parent() {
                    if let Ok(read) = std::fs::read_dir(dir) {
                        for entry in read.flatten() {
                            let p = entry.path();
                            if p.extension()
                                .and_then(|e| e.to_str())
                                .map(|s| s.eq_ignore_ascii_case("mov"))
                                .unwrap_or(false)
                            {
                                if let Ok(m) = std::fs::metadata(&p) {
                                    if let Ok(mt) = m.modified() {
                                        if let Ok(el) = mt.elapsed() {
                                            let secs = el.as_secs();
                                            if heic_mtime.abs_diff(secs) <= 3 {
                                                live_mov = Some(p);
                                                break;
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // Upsert into photos table with is_live_photo + live_video_path
    let conn = data_db.lock();
    conn.execute(
        "INSERT INTO photos (
            organization_id, user_id, asset_id, path, filename, mime_type, backup_id, created_at, modified_at, size,
            width, height, is_video, is_live_photo, live_video_path, is_screenshot, last_indexed
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (organization_id, asset_id) DO UPDATE SET
            path = EXCLUDED.path,
            filename = EXCLUDED.filename,
            modified_at = EXCLUDED.modified_at,
            size = EXCLUDED.size,
            width = EXCLUDED.width,
            height = EXCLUDED.height,
            backup_id = EXCLUDED.backup_id,
            is_live_photo = EXCLUDED.is_live_photo,
            live_video_path = EXCLUDED.live_video_path,
            is_screenshot = EXCLUDED.is_screenshot,
            last_indexed = EXCLUDED.last_indexed,
            locked = FALSE,
            crypto_version = 0",
        &[
            &org_id as &dyn duckdb::ToSql,
            &user_id as &dyn duckdb::ToSql,
            &asset_id as &dyn duckdb::ToSql,
            &heic_path.to_string_lossy(),
            &heic_path
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("unknown"),
            &"image/heic".to_string(),
            &backup_id as &dyn duckdb::ToSql,
            &created_time,
            &modified_time,
            &(file_size as i64),
            &(parsed.width.unwrap_or(width_i32)),
            &(parsed.height.unwrap_or(height_i32)),
            &false,
            &live_mov.is_some(),
            &live_mov.as_ref().map(|p| p.to_string_lossy().to_string()),
            &false, // HEIC screenshots rare; default to false
            &chrono::Utc::now().timestamp(),
        ],
    )?;

    // If we detected a companion MOV, migrate album membership and remove the standalone
    if let Some(mov_path) = &live_mov {
        // Resolve ids: current photo id and companion video id
        let (photo_id_opt, video_id_opt): (Option<i32>, Option<i32>) = {
            let mut pid: Option<i32> = None;
            let mut vid: Option<i32> = None;
            if let Ok(mut stmt) = conn.prepare("SELECT id FROM photos WHERE asset_id = ? AND is_video = 0 LIMIT 1") {
                pid = stmt.query_row([&asset_id], |row| row.get::<_, i32>(0)).ok();
            }
            if let Ok(mut stmt) = conn.prepare("SELECT id FROM photos WHERE path = ? AND is_video = 1 LIMIT 1") {
                vid = stmt.query_row([&mov_path.to_string_lossy().to_string()], |row| row.get::<_, i32>(0)).ok();
            }
            (pid, vid)
        };
        if let (Some(photo_id), Some(video_id)) = (photo_id_opt, video_id_opt) {
            // Copy album membership from video to photo, then delete video references and row
            let organization_id: i32 = {
                let users_db = state
                    .multi_tenant_db
                    .as_ref()
                    .expect("users DB required in DuckDB mode")
                    .users_connection();
                let c = users_db.lock();
                c.query_row(
                    "SELECT organization_id FROM users WHERE user_id = ? LIMIT 1",
                    duckdb::params![user_id],
                    |row| row.get::<_, i32>(0),
                )
                .unwrap_or(1)
            };
            let _ = conn.execute(
                "INSERT INTO album_photos (organization_id, album_id, photo_id, added_at)
                 SELECT organization_id, album_id, ?, added_at FROM album_photos WHERE organization_id = ? AND photo_id = ?
                 ON CONFLICT (organization_id, album_id, photo_id) DO NOTHING",
                duckdb::params![photo_id, organization_id, video_id],
            );
            let _ = conn.execute(
                "DELETE FROM album_photos WHERE organization_id = ? AND photo_id = ?",
                duckdb::params![organization_id, video_id],
            );
            let _ = conn.execute(
                "DELETE FROM photos WHERE id = ? AND is_video = 1",
                duckdb::params![video_id],
            );
        }
    }
    }

    // Update camera / GPS and reverse geocode for HEIC
    {
        let connm = data_db.lock();
        let _ = connm.execute(
            "UPDATE photos SET camera_make = ?, camera_model = ?, iso = ?, aperture = ?, shutter_speed = ?, focal_length = ?, latitude = ?, longitude = ?, altitude = ? WHERE asset_id = ?",
            duckdb::params![
                &parsed.camera_make,
                &parsed.camera_model,
                parsed.iso,
                parsed.aperture,
                &parsed.shutter_speed,
                parsed.focal_length,
                parsed.latitude,
                parsed.longitude,
                parsed.altitude,
                &asset_id
            ],
        );
    }
    if content_changed {
    if let (Some(lat), Some(lon)) = (parsed.latitude, parsed.longitude) {
        if let Ok((name, city, prov, country)) = crate::photos::geocode::reverse_geocode_cached(data_db, lat, lon).await {
            let connr = data_db.lock();
            let _ = connr.execute(
                "UPDATE photos SET location_name = COALESCE(location_name, ?), city = COALESCE(city, ?), province = COALESCE(province, ?), country = COALESCE(country, ?) WHERE asset_id = ?",
                duckdb::params![&name, &city, &prov, &country, &asset_id],
            );
        }
    }
    }

    // Compute and persist pHash for HEIC (using proxy decode if needed). Update in-memory band index.
    match crate::photos::phash::compute_phash_from_path(heic_path) {
        Ok(h) => {
            let hex = crate::photos::phash::phash_to_hex(h);
            tracing::info!(
                "[PHASH] Computed pHash for HEIC {} => {}",
                heic_path.display(),
                hex
            );
            let conn_h = data_db.lock();
            // Ensure multi-tenant schema and unique index
            let _ = conn_h.execute(
                "CREATE TABLE IF NOT EXISTS photo_hashes (
                    organization_id INTEGER NOT NULL,
                    asset_id TEXT NOT NULL,
                    phash_hex TEXT NOT NULL
                )",
                []
            );
            let _ = conn_h.execute(
                "CREATE UNIQUE INDEX IF NOT EXISTS idx_photo_hashes_org_asset_u ON photo_hashes(organization_id, asset_id)",
                []
            );
            let _ = conn_h.execute(
                "INSERT INTO photo_hashes(organization_id, asset_id, phash_hex) VALUES (?, ?, ?) \
                 ON CONFLICT (organization_id, asset_id) DO UPDATE SET phash_hex = EXCLUDED.phash_hex",
                &[&org_id as &dyn duckdb::ToSql, &asset_id as &dyn duckdb::ToSql, &hex],
            );
            drop(conn_h);
            if let Ok(idx) = state.get_or_build_similar_index(user_id) {
                let mut guard = idx.write();
                guard.upsert(asset_id.clone(), h);
                tracing::info!(
                    "[PHASH] Index upsert complete (user={}, size={})",
                    user_id,
                    guard.len()
                );
            }
        }
        Err(e) => {
            tracing::warn!(
                "[REINDEX] Failed to compute pHash for HEIC {}: {}",
                heic_path.display(),
                e
            );
        }
    }

    // Ensure thumbnail
    if let Err(e) = ensure_thumbnail_for_user(state, user_id, &asset_id, heic_path) {
        tracing::warn!(
            "[REINDEX] Failed to generate thumbnail for HEIC {}: {}",
            heic_path.display(),
            e
        );
    }

    // Incremental face detection + assignment for HEIC still image
    if state.face_service.is_enabled() {
        let settings = load_face_settings(state, user_id);
        if state.pg_client.is_some() {
            if let Err(e) = state
                .face_service
                .process_and_store_faces_pg(&asset_id, heic_path, None, &settings, org_id)
                .await
            {
                tracing::warn!(
                    "[REINDEX] Face processing (pg) failed for HEIC {}: {}",
                    heic_path.display(),
                    e
                );
            }
        } else {
            // Offload DuckDB face processing to a blocking thread in HEIC path as well
            let svc = state.face_service.clone();
            let db = embed_db.clone();
            let aid = asset_id.clone();
            let path_buf = heic_path.to_path_buf();
            let settings_cloned = settings.clone();
            let org = org_id;
            if let Err(e) = tokio::task::spawn_blocking(move || {
                svc.process_and_store_faces_with_settings(
                    &db,
                    &aid,
                    &path_buf,
                    None,
                    &settings_cloned,
                    Some(org),
                )
            })
            .await
            .unwrap_or_else(|join_err| Err(anyhow::anyhow!(format!("join error: {}", join_err))))
            {
                tracing::warn!(
                    "[REINDEX] Face processing (duckdb) failed for HEIC {}: {}",
                    heic_path.display(),
                    e
                );
            }
        }
    }

    // If live, extract video to cached mp4 path
    if let Some(mov_path) = live_mov {
        tracing::info!(
            "[REINDEX] Detected Live Photo pair: heic={} mov={}",
            heic_path.display(),
            mov_path.display()
        );
        let mov_out = state.live_video_mov_path_for(user_id, &asset_id);
        if !mov_out.exists() {
            if let Some(parent) = mov_out.parent() {
                let _ = fs::create_dir_all(parent);
            }
            if let Err(e) = std::fs::copy(&mov_path, &mov_out) {
                tracing::warn!(
                    "[REINDEX] Failed to copy live video {} -> {}: {}",
                    mov_path.display(),
                    mov_out.display(),
                    e
                );
            }
        }
    }

    Ok(())
}

*/
// Index a single video for a specific user
pub(crate) async fn index_video_for_user(
    state: &Arc<AppState>,
    data_db: &crate::database::multi_tenant::DbPool,
    embedding_store: &Arc<crate::database::embeddings::EmbeddingStore>,
    video_path: &std::path::Path,
    user_id: &str,
    forced_asset_id: Option<&str>,
) -> Result<(), anyhow::Error> {
    use image::imageops::FilterType;
    if should_ignore_ingest_path(video_path) {
        return Err(SkipIngestError::new(format!(
            "ignored non-media file: {}",
            video_path.display()
        ))
        .into());
    }

    // Resolve user's organization id for multi-tenant scoping (PG or DuckDB)
    let org_id: i32 = if let Some(meta) = &state.meta {
        match meta.resolve_org_id(user_id).await {
            Ok(v) => v,
            Err(_) => 1,
        }
    } else {
        let users_conn = state
            .multi_tenant_db
            .as_ref()
            .expect("users DB required in DuckDB mode")
            .users_connection();
        let conn = users_conn.lock();
        conn.query_row(
            "SELECT organization_id FROM users WHERE user_id = ? LIMIT 1",
            duckdb::params![user_id],
            |row| row.get::<_, i32>(0),
        )
        .unwrap_or(1)
    };

    // Ignore Live Photo companion videos (same-stem HEIC/HEIF present)
    if let Some(stem) = video_path.file_stem().and_then(|s| s.to_str()) {
        let dir = video_path
            .parent()
            .unwrap_or_else(|| std::path::Path::new("."));
        let heic = dir.join(format!("{}.heic", stem));
        let heif = dir.join(format!("{}.heif", stem));
        if heic.exists() || heif.exists() {
            tracing::info!(
                "[REINDEX] Skipping Live Photo companion video: {}",
                video_path.display()
            );
            return Ok(());
        }
    }

    // FS metadata
    let metadata = std::fs::metadata(video_path)?;
    let file_size = metadata.len();
    let modified_time = metadata
        .modified()?
        .duration_since(std::time::UNIX_EPOCH)?
        .as_secs() as i64;
    let created_time = metadata
        .created()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs() as i64)
        .unwrap_or(modified_time);

    // MIME from ext
    let ext = video_path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_lowercase();
    let content_type = match ext.as_str() {
        "mp4" => "video/mp4",
        "mov" => "video/quicktime",
        "m4v" => "video/mp4",
        "webm" => "video/webm",
        "mkv" => "video/x-matroska",
        "avi" => "video/x-msvideo",
        _ => "application/octet-stream",
    }
    .to_string();

    // Pre-check by path to skip unchanged videos
    let (existing_asset_id, existing_size, existing_modified, existing_hash): (
        Option<String>,
        Option<i64>,
        Option<i64>,
        Option<String>,
    ) = {
        let conn = data_db.lock();
        let mut stmt = conn
            .prepare("SELECT asset_id, size, modified_at, content_hash FROM photos WHERE path = ? LIMIT 1")
            .ok();
        if let Some(ref mut s) = stmt {
            match s.query_row([&video_path.to_string_lossy().to_string()], |row| {
                Ok((
                    row.get::<_, String>(0).ok(),
                    row.get::<_, i64>(1).ok(),
                    row.get::<_, i64>(2).ok(),
                    row.get::<_, String>(3).ok(),
                ))
            }) {
                Ok(t) => t,
                Err(_) => (None, None, None, None),
            }
        } else {
            (None, None, None, None)
        }
    };
    if let (Some(aid), Some(db_size), Some(db_mod)) =
        (&existing_asset_id, existing_size, existing_modified)
    {
        if (file_size as i64) == db_size && modified_time <= db_mod {
            let now = chrono::Utc::now().timestamp();
            let conn = data_db.lock();
            let _ = conn.execute(
                "UPDATE photos SET last_indexed = ?, filename = COALESCE(filename, ?) WHERE asset_id = ?",
                duckdb::params![now, video_path.file_name().and_then(|n| n.to_str()).unwrap_or("unknown"), aid],
            );
            return Ok(());
        }
    }
    // Changed or new: compute content hash; reuse asset_id if exists
    let bytes = std::fs::read(video_path)?;
    let content_hash = blake3::hash(&bytes).to_hex().to_string();
    let backup_id = crate::photos::backup_id::from_bytes(&bytes, user_id)?;
    let asset_id: String =
        if let Some(forced) = forced_asset_id.map(|s| s.trim()).filter(|s| !s.is_empty()) {
            forced.to_string()
        } else if let Some(existing) = &existing_asset_id {
            existing.clone()
        } else {
            crate::photos::asset_id::from_bytes(&bytes, user_id)?
        };
    let content_changed = existing_hash.as_deref() != Some(&content_hash);

    // Probe video metadata (dimensions/duration)
    let vmeta = crate::video::probe_metadata(video_path).unwrap_or_default();
    if vmeta.width.is_none() && vmeta.height.is_none() && vmeta.duration_ms.is_none() {
        return Err(SkipIngestError::new(format!(
            "corrupt video (ffprobe failed): {}",
            video_path.display()
        ))
        .into());
    }
    let width_i32 = vmeta.width.unwrap_or(0) as i32;
    let height_i32 = vmeta.height.unwrap_or(0) as i32;
    let duration_ms_probe = vmeta.duration_ms.unwrap_or(0);
    let is_live_photo_component = video_path
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| e.eq_ignore_ascii_case("mov"))
        .unwrap_or(false)
        && crate::video::is_live_photo_component(video_path);

    // Parse rich metadata for creation time and camera/GPS
    let mut parsed = crate::photos::Photo::from_path(video_path, user_id).map_err(|e| {
        SkipIngestError::new(format!(
            "corrupt video (metadata parse failed): {} ({})",
            video_path.display(),
            e
        ))
    })?;
    let _ = crate::photos::metadata::extract_metadata(&mut parsed);
    let created_time = parsed.created_at.max(created_time);
    let duration_ms = parsed.duration_ms.unwrap_or(duration_ms_probe);

    // Ensure poster (first frame) before inserting into DB so corrupted videos are ignored.
    // Skip for Live Photo paired MOVs: they are internal motion components, not standalone videos.
    let poster_path = state.poster_path_for(user_id, &asset_id);
    if !poster_path.exists() && !is_live_photo_component {
        if let Some(parent) = poster_path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let img = crate::video::extract_frame_upright(video_path, 0.0).map_err(|e| {
            SkipIngestError::new(format!(
                "corrupt video (cannot decode frame): {} ({})",
                video_path.display(),
                e
            ))
        })?;
        // Resize and write WebP
        let (w, h) = img.dimensions();
        let max_side: u32 = 512;
        let (tw, th) = if w >= h {
            (
                max_side,
                ((h as f32) * (max_side as f32 / w as f32)).round() as u32,
            )
        } else {
            (
                ((w as f32) * (max_side as f32 / h as f32)).round() as u32,
                max_side,
            )
        };
        let thumb = img.resize(tw.max(1), th.max(1), FilterType::Lanczos3);
        let rgb = thumb.to_rgb8();
        let enc = webp::Encoder::from_rgb(rgb.as_raw(), rgb.width(), rgb.height());
        let webp_data = enc.encode(80.0);
        std::fs::write(&poster_path, &*webp_data)?;
    }

    // Upsert into photos table as video
    {
        let conn = data_db.lock();
        conn.execute(
            "INSERT INTO photos (
                organization_id, user_id, asset_id, path, filename, mime_type, content_hash, backup_id, created_at, modified_at, size,
                width, height, is_video, is_live_photo, live_video_path, duration_ms, last_indexed
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, TRUE, ?, NULL, ?, ?)
            ON CONFLICT (organization_id, asset_id) DO UPDATE SET
                path = EXCLUDED.path,
                filename = EXCLUDED.filename,
                modified_at = EXCLUDED.modified_at,
                size = EXCLUDED.size,
                width = EXCLUDED.width,
                height = EXCLUDED.height,
                content_hash = EXCLUDED.content_hash,
                backup_id = EXCLUDED.backup_id,
                is_live_photo = EXCLUDED.is_live_photo,
                duration_ms = EXCLUDED.duration_ms,
                last_indexed = EXCLUDED.last_indexed,
                locked = FALSE,
                crypto_version = 0",
            &[
                &org_id as &dyn duckdb::ToSql,
                &user_id as &dyn duckdb::ToSql,
                &asset_id as &dyn duckdb::ToSql,
                &video_path.to_string_lossy().to_string(),
                &video_path
                    .file_name()
                    .and_then(|n| n.to_str())
                    .unwrap_or("unknown"),
                &content_type,
                &content_hash,
                &backup_id,
                &created_time,
                &modified_time,
                &(file_size as i64),
                &width_i32,
                &height_i32,
                &is_live_photo_component,
                &duration_ms,
                &chrono::Utc::now().timestamp(),
            ],
        )?;
    }

    // Update camera/GPS and reverse geocode for video
    {
        let connm = data_db.lock();
        let _ = connm.execute(
            "UPDATE photos SET camera_make = ?, camera_model = ?, latitude = ?, longitude = ?, altitude = ?, caption = COALESCE(caption, ?) WHERE asset_id = ?",
            duckdb::params![
                &parsed.camera_make,
                &parsed.camera_model,
                parsed.latitude,
                parsed.longitude,
                parsed.altitude,
                &parsed.caption,
                &asset_id
            ],
        );
        if let Some(cap) = parsed.caption.as_ref() {
            let mut v = cap.clone();
            if v.len() > 200 {
                v.truncate(200);
                v.push_str("…");
            }
            tracing::info!(target:"upload", "[EXIF] Parsed caption for asset {}: '{}'", asset_id, v);
        }
    }
    if let (Some(lat), Some(lon)) = (parsed.latitude, parsed.longitude) {
        if let Ok((name, city, prov, country)) =
            crate::photos::geocode::reverse_geocode_cached(data_db, lat, lon).await
        {
            let connr = data_db.lock();
            let _ = connr.execute(
                "UPDATE photos SET location_name = COALESCE(location_name, ?), city = COALESCE(city, ?), province = COALESCE(province, ?), country = COALESCE(country, ?) WHERE asset_id = ?",
                duckdb::params![&name, &city, &prov, &country, &asset_id],
            );
        }
    }

    // Video pHash samples (near-duplicate detection) per VIDEO_SIMILARITY mode
    if content_changed
        && state.video_similarity_mode != crate::server::state::VideoSimilarityMode::Off
    {
        // Determine schedule: override from env or default recommended order
        let default_schedule = vec![0.05, 0.50, 0.95, 0.25, 0.75, 0.125, 0.875, 0.375, 0.625];
        let schedule: Vec<f64> = state
            .video_phash_percents
            .clone()
            .unwrap_or_else(|| default_schedule.clone());
        let count: usize = match state.video_similarity_mode {
            crate::server::state::VideoSimilarityMode::Off => 0,
            crate::server::state::VideoSimilarityMode::Fixed(n) => n,
            crate::server::state::VideoSimilarityMode::Cascade => {
                if duration_ms < 1000 {
                    1
                } else {
                    3
                }
            }
        };
        if count > 0 {
            // Very short videos: single sample at start
            if duration_ms < 1000 {
                let pos = 0.0;
                let t_ms = 0i64;
                if let Ok(img) = crate::video::extract_frame_upright(video_path, 0.0) {
                    if let Ok(ph) = crate::photos::phash::compute_phash(&img) {
                        let hex = crate::photos::phash::phash_to_hex(ph);
                        let conn = data_db.lock();
                        let _ = conn.execute(
                            "CREATE TABLE IF NOT EXISTS video_phash_samples (
                                asset_id TEXT NOT NULL,
                                sample_idx SMALLINT NOT NULL,
                                pos_pct REAL,
                                time_ms INTEGER,
                                phash_hex TEXT NOT NULL,
                                PRIMARY KEY (asset_id, sample_idx)
                            )",
                            [],
                        );
                        let _ = conn.execute(
                            "INSERT INTO video_phash_samples(asset_id, sample_idx, pos_pct, time_ms, phash_hex) VALUES (?, ?, ?, ?, ?) \
                             ON CONFLICT (asset_id, sample_idx) DO UPDATE SET pos_pct = EXCLUDED.pos_pct, time_ms = EXCLUDED.time_ms, phash_hex = EXCLUDED.phash_hex",
                            duckdb::params![&asset_id, 0i16, pos as f64, t_ms, hex],
                        );
                        drop(conn);
                    }
                }
            } else {
                // Normal duration: sample first N from ordered schedule
                let dur_s = (duration_ms as f64) / 1000.0;
                let mut inserted = 0usize;
                for (idx, &pct) in schedule.iter().enumerate() {
                    if inserted >= count {
                        break;
                    }
                    let mut chosen_pos = pct.clamp(0.0, 0.999);
                    // Low-info skip: try slight nudges if enabled
                    let mut attempts = 0;
                    let mut img_opt: Option<image::DynamicImage> = None;
                    loop {
                        let t = (chosen_pos * dur_s).clamp(0.0, (dur_s - 0.001).max(0.0));
                        if let Ok(img) = crate::video::extract_frame_upright(video_path, t) {
                            if state.video_phash_lowinfo_skip
                                && is_low_info_frame(&img)
                                && attempts < 2
                            {
                                // nudge +0.02 then -0.02
                                attempts += 1;
                                chosen_pos = if attempts == 1 {
                                    (pct + 0.02).clamp(0.0, 0.999)
                                } else {
                                    (pct - 0.02).clamp(0.0, 0.999)
                                };
                                continue;
                            }
                            img_opt = Some(img);
                        }
                        break;
                    }

                    if let Some(img) = img_opt {
                        if let Ok(ph) = crate::photos::phash::compute_phash(&img) {
                            let hex = crate::photos::phash::phash_to_hex(ph);
                            let t_ms = ((chosen_pos * dur_s) * 1000.0).round() as i64;
                            let conn = data_db.lock();
                            let _ = conn.execute(
                                "CREATE TABLE IF NOT EXISTS video_phash_samples (
                                    asset_id TEXT NOT NULL,
                                    sample_idx SMALLINT NOT NULL,
                                    pos_pct REAL,
                                    time_ms INTEGER,
                                    phash_hex TEXT NOT NULL,
                                    PRIMARY KEY (asset_id, sample_idx)
                                )",
                                [],
                            );
                            let _ = conn.execute(
                                "INSERT INTO video_phash_samples(asset_id, sample_idx, pos_pct, time_ms, phash_hex) VALUES (?, ?, ?, ?, ?) \
                                 ON CONFLICT (asset_id, sample_idx) DO UPDATE SET pos_pct = EXCLUDED.pos_pct, time_ms = EXCLUDED.time_ms, phash_hex = EXCLUDED.phash_hex",
                                duckdb::params![&asset_id, idx as i16, chosen_pos as f64, t_ms, hex],
                            );
                            drop(conn);
                            inserted += 1;
                        }
                    }
                }
            }
        }
    }

    // Prepare sampled frames once, run YOLO for objects + person gating, and compute CLIP embedding
    use std::collections::HashSet;
    let vsettings = load_video_settings(state, user_id);
    let dur_s = (duration_ms as f64) / 1000.0;
    let ts: Vec<f64> = if duration_ms < 1000 {
        vec![0.0]
    } else {
        vec![
            0.0,
            dur_s * 0.25,
            dur_s * 0.5,
            dur_s * 0.75,
            (dur_s - 0.001).max(0.0),
        ]
    };
    let mut frames: Vec<(f64, image::DynamicImage)> = Vec::new();
    let mut allow_face: Vec<bool> = Vec::new();
    let mut object_labels: HashSet<String> = HashSet::new();
    for &t in &ts {
        if let Ok(img) = crate::video::extract_frame_upright(video_path, t) {
            let mut person_found = false;
            if let Ok(dets) = state.yolo_detector.detect(&img) {
                for d in dets {
                    // Add object label if above person threshold for objects as well
                    if d.confidence >= vsettings.yolo_person_threshold {
                        object_labels.insert(d.class.clone());
                    }
                    let lc = d.class.to_ascii_lowercase();
                    if (lc == "person" || lc == "man" || lc == "woman")
                        && d.confidence >= vsettings.yolo_person_threshold
                    {
                        person_found = true;
                    }
                }
            }
            allow_face.push(person_found);
            frames.push((t, img));
        } else {
            allow_face.push(false);
        }
    }

    // Fallbacks: ensure at least center frame runs RetinaFace, and include neighbors for any hit
    match vsettings.gating_mode.as_str() {
        "off" => {
            for a in allow_face.iter_mut() {
                *a = true;
            }
        }
        "yolo" => {
            // no fallback or neighbor expansion
        }
        _ => {
            // yolo_fallback
            if !allow_face.iter().any(|&b| b) {
                if !allow_face.is_empty() {
                    let center = allow_face.len() / 2;
                    allow_face[center] = true;
                }
            } else {
                let mut expanded = allow_face.clone();
                for i in 0..allow_face.len() {
                    if allow_face[i] {
                        if i > 0 {
                            expanded[i - 1] = true;
                        }
                        if i + 1 < allow_face.len() {
                            expanded[i + 1] = true;
                        }
                    }
                }
                allow_face = expanded;
            }
        }
    }

    // Ensure minimum number of frames for RetinaFace
    let mut allowed_count = allow_face.iter().filter(|&&b| b).count();
    if allowed_count < vsettings.retina_min_frames && !allow_face.is_empty() {
        // Promote center-outward until min frames satisfied
        let mut i = 0usize;
        while allowed_count < vsettings.retina_min_frames && i < allow_face.len() {
            let idx = ((allow_face.len() / 2) as isize
                + if i % 2 == 0 {
                    -(i as isize / 2)
                } else {
                    ((i as isize + 1) / 2)
                }) as isize;
            if idx >= 0 && (idx as usize) < allow_face.len() {
                let u = idx as usize;
                if !allow_face[u] {
                    allow_face[u] = true;
                    allowed_count += 1;
                }
            }
            i += 1;
        }
    }

    // Compute CLIP embedding from prepared frames
    if content_changed {
        if let Some(Some(video_embedding)) = state.with_visual_encoder(None, |enc| {
            if frames.is_empty() {
                return None;
            }
            let mut embs = Vec::new();
            for (_, img) in &frames {
                if let Ok(v) = enc.encode_image(img) {
                    embs.push(v);
                }
            }
            if embs.is_empty() {
                return None;
            }
            let dim = embs[0].len();
            let mut mean = vec![0.0f32; dim];
            for e in &embs {
                for i in 0..dim {
                    mean[i] += e[i];
                }
            }
            for i in 0..dim {
                mean[i] /= embs.len() as f32;
            }
            let norm = (mean.iter().map(|v| (v * v) as f32).sum::<f32>())
                .sqrt()
                .max(1e-6);
            for i in 0..dim {
                mean[i] /= norm;
            }
            Some(mean)
        }) {
            // Store in embedding DB using YOLO object tags. We intentionally do not store
            // poster/full image bytes in `smart_search.image_data` (see note in photo path).
            let detected_objects: Vec<String> = object_labels.into_iter().collect();
            let _ = embedding_store
                .upsert_image_embedding(
                    asset_id.clone(),
                    video_embedding,
                    None,
                    width_i32.max(0) as u32,
                    height_i32.max(0) as u32,
                    content_type.clone(),
                    Some(detected_objects),
                    None,
                )
                .await;
        }
    }

    // Faces on videos: run RetinaFace on gated frames only (with fallback applied), deduplicate, and insert
    if content_changed && state.face_service.is_enabled() {
        use face_normalizer::{
            FaceData, FaceDetector, FaceNormalizer, FaceRecognizer, SIMILARITY_THRESHOLD,
        };
        let models_dir = std::path::Path::new("models/face");
        let detector = FaceDetector::new(&models_dir.join("det_10g.onnx").to_string_lossy())?;
        let normalizer = FaceNormalizer::new();
        let recognizer = FaceRecognizer::new(&models_dir.join("w600k_r50.onnx").to_string_lossy())?;

        let mut candidates: Vec<(i64, FaceData)> = Vec::new();
        for (idx, (t, img)) in frames.iter().enumerate() {
            if idx >= allow_face.len() || !allow_face[idx] {
                continue;
            }
            if let Ok(tmp) = save_frame_to_temp_image(img, *t) {
                if let Ok(mut faces) = face_normalizer::process_image_for_faces(
                    &detector,
                    &normalizer,
                    &recognizer,
                    &tmp,
                ) {
                    if !faces.is_empty() {
                        let t_ms = (t * 1000.0).round() as i64;
                        for f in faces.drain(..) {
                            candidates.push((t_ms, f));
                        }
                    }
                }
                let _ = std::fs::remove_file(&tmp);
            }
        }

        // Deduplicate by cosine similarity >= SIMILARITY_THRESHOLD
        let mut deduped: Vec<(i64, FaceData)> = Vec::new();
        'outer: for (t_ms, face) in candidates.into_iter() {
            for (_, ex) in deduped.iter() {
                let sim = cosine_sim(&face.embedding, &ex.embedding);
                if sim >= SIMILARITY_THRESHOLD as f32 {
                    continue 'outer;
                }
            }
            deduped.push((t_ms, face));
        }

        // Insert faces with person assignment and time_ms
        let embed_db = state.get_user_embedding_database(user_id)?;
        let conn = embed_db.lock();
        for (idx, (t_ms, f)) in deduped.into_iter().enumerate() {
            let face_id = format!("{}#v{}", asset_id, idx);
            // bbox ints
            let mut x1 = f.bbox.x1.max(0.0).floor() as i32;
            let mut y1 = f.bbox.y1.max(0.0).floor() as i32;
            let mut x2 = f.bbox.x2.ceil() as i32;
            let mut y2 = f.bbox.y2.ceil() as i32;
            if x2 <= x1 {
                x2 = x1 + 1;
            }
            if y2 <= y1 {
                y2 = y1 + 1;
            }
            let bw = (x2 - x1).max(1) as i32;
            let bh = (y2 - y1).max(1) as i32;

            // embedding literal (pad/trim to 512)
            let mut emb_vec: Vec<f32> = f.embedding.clone();
            if emb_vec.len() < 512 {
                emb_vec.resize(512, 0.0);
            }
            if emb_vec.len() > 512 {
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

            // Find nearest existing person
            let mut assigned_person: Option<String> = None;
            let mut sim_top: f32 = -1.0;
            let select_sql =
                "SELECT f.person_id, array_cosine_similarity(f.embedding, ?::FLOAT[512]) as sim \
                              FROM faces_embed f \
                              WHERE f.person_id IS NOT NULL AND f.user_id = ? \
                              ORDER BY sim DESC LIMIT 5";
            if let Ok(mut stmt) = conn.prepare(select_sql) {
                if let Ok(rows) =
                    stmt.query_map(duckdb::params![embedding_str.clone(), user_id], |row| {
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
            let threshold: f32 = face_normalizer::SIMILARITY_THRESHOLD;
            let person_id = if sim_top >= threshold {
                assigned_person.unwrap()
            } else {
                // create new person id p{N}
                let mut new_id = String::from("p1");
                if let Ok(last_pid) = conn.query_row(
                    "SELECT person_id FROM persons ORDER BY TRY_CAST(substr(person_id, 2) AS INTEGER) DESC LIMIT 1",
                    [],
                    |row| row.get::<_, String>(0),
                ) { let num = last_pid.trim_start_matches('p').parse::<i64>().unwrap_or(0) + 1; new_id = format!("p{}", num); }
                let _ = conn.execute(
                    "INSERT INTO persons (person_id, display_name, face_count, representative_face_id) VALUES (?, NULL, 0, NULL) ON CONFLICT (person_id) DO NOTHING",
                    duckdb::params![new_id],
                );
                new_id
            };

            let insert_sql = "INSERT INTO faces_embed (face_id, asset_id, user_id, person_id, bbox_x, bbox_y, bbox_width, bbox_height, confidence, embedding, face_thumbnail, time_ms) \
                               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?::FLOAT[512], ?, ?) \
                               ON CONFLICT (face_id) DO UPDATE SET \
                                 user_id = EXCLUDED.user_id, \
                                 person_id = EXCLUDED.person_id, \
                                 bbox_x = EXCLUDED.bbox_x, \
                                 bbox_y = EXCLUDED.bbox_y, \
                                 bbox_width = EXCLUDED.bbox_width, \
                                 bbox_height = EXCLUDED.bbox_height, \
                                 confidence = EXCLUDED.confidence, \
                                 embedding = EXCLUDED.embedding, \
                                 face_thumbnail = COALESCE(EXCLUDED.face_thumbnail, faces_embed.face_thumbnail), \
                                 time_ms = EXCLUDED.time_ms";

            let thumb_bytes: Option<Vec<u8>> = f.aligned_thumbnail.clone();
            if let Err(e) = conn.execute(
                insert_sql,
                duckdb::params![
                    face_id,
                    asset_id,
                    user_id,
                    person_id,
                    x1,
                    y1,
                    bw,
                    bh,
                    f.confidence,
                    embedding_str,
                    thumb_bytes,
                    t_ms,
                ],
            ) {
                tracing::warn!(
                    "[FACE] video insert failed for asset={} face_id={} (embedding_len={}): {}",
                    asset_id,
                    face_id,
                    emb_vec.len(),
                    e
                );
            }
        }
    }

    Ok(())
}

fn extract_frame_to_temp(
    video_path: &std::path::Path,
    time_sec: f64,
) -> Result<std::path::PathBuf, anyhow::Error> {
    // Extract a frame to a temporary PNG file and return its path
    let img = crate::video::extract_frame_upright(video_path, time_sec)?;
    save_frame_to_temp_image(&img, time_sec)
}

fn save_frame_to_temp_image(
    img: &image::DynamicImage,
    time_sec: f64,
) -> Result<std::path::PathBuf, anyhow::Error> {
    let mut tmpfile = std::env::temp_dir();
    let name = format!(
        "albumbud_frame_{}_{}.png",
        std::process::id(),
        (time_sec * 1000.0) as i64
    );
    tmpfile.push(name);
    img.save(&tmpfile)?;
    Ok(tmpfile)
}

fn is_low_info_frame(img: &image::DynamicImage) -> bool {
    use image::GenericImageView;
    // Downscale for quick stats
    let thumb = img.thumbnail(64, 64).to_luma8();
    let mut sum: f64 = 0.0;
    let mut sum2: f64 = 0.0;
    let mut min_v: u8 = 255;
    let mut max_v: u8 = 0;
    for &p in thumb.as_raw().iter() {
        let v = p as f64;
        sum += v;
        sum2 += v * v;
        if p < min_v {
            min_v = p;
        }
        if p > max_v {
            max_v = p;
        }
    }
    let n = thumb.as_raw().len().max(1) as f64;
    let mean = sum / n;
    let var = (sum2 / n) - (mean * mean);
    let stddev = var.max(0.0).sqrt();
    // Heuristics: near-black/near-white or very low contrast
    (mean < 8.0) || (mean > 247.0) || (stddev < 5.0) || ((max_v as i16 - min_v as i16) < 8)
}

fn cosine_sim(a: &[f32], b: &[f32]) -> f32 {
    let mut dot = 0.0f32;
    let mut na = 0.0f32;
    let mut nb = 0.0f32;
    let len = a.len().min(b.len());
    for i in 0..len {
        dot += a[i] * b[i];
        na += a[i] * a[i];
        nb += b[i] * b[i];
    }
    if na == 0.0 || nb == 0.0 {
        return 0.0;
    }
    dot / (na.sqrt() * nb.sqrt())
}

fn ensure_thumbnail_for_user(
    state: &Arc<AppState>,
    user_id: &str,
    asset_id: &str,
    image_path: &std::path::Path,
) -> Result<(), anyhow::Error> {
    use image::imageops::FilterType;
    use std::fs;

    let thumb_path = state.thumbnail_path_for(user_id, asset_id);
    if thumb_path.exists() {
        return Ok(());
    }

    if let Some(parent) = thumb_path.parent() {
        fs::create_dir_all(parent)?;
    }

    let ext = image_path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    let img = match crate::photos::metadata::open_image_any(image_path) {
        Ok(i) => i,
        Err(e) => {
            if crate::photos::is_raw_still_extension(ext.as_str()) {
                tracing::warn!(
                    target: "upload",
                    "[RAW] thumbnail preview unavailable; writing placeholder asset={} path={} err={}",
                    asset_id,
                    image_path.display(),
                    e
                );
                let placeholder = crate::photos::metadata::raw_placeholder_image(512);
                let rgb = placeholder.to_rgb8();
                let enc = webp::Encoder::from_rgb(rgb.as_raw(), rgb.width(), rgb.height());
                let webp_data = enc.encode(80.0);
                std::fs::write(thumb_path, &*webp_data)?;
                return Ok(());
            }
            tracing::warn!(
                "[REINDEX] Could not open image for thumbnail {}: {}",
                image_path.display(),
                e
            );
            return Ok(()); // skip silently
        }
    };
    let (w, h) = img.dimensions();
    let max_side: u32 = 512;
    let (tw, th) = if w >= h {
        let nw = max_side;
        let nh = ((h as f32) * (nw as f32 / w as f32)).round() as u32;
        (nw, nh)
    } else {
        let nh = max_side;
        let nw = ((w as f32) * (nh as f32 / h as f32)).round() as u32;
        (nw, nh)
    };
    let thumb = img.resize(tw.max(1), th.max(1), FilterType::Lanczos3);
    let rgb = thumb.to_rgb8();
    let enc = webp::Encoder::from_rgb(rgb.as_raw(), rgb.width(), rgb.height());
    let webp_data = enc.encode(80.0);
    std::fs::write(thumb_path, &*webp_data)?;
    Ok(())
}

// Helper function to calculate perceptual hash
// pHash calculation deprecated: asset_id now uses Base58(first16(HMAC-SHA256(user_id, contents)))
// fn calculate_phash(image: &image::DynamicImage) -> Result<String, anyhow::Error> { /* deprecated */ }

// Manual reindex endpoint
#[instrument(skip(state))]
pub async fn reindex_user_photos(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, AppError> {
    let user_id = extract_user_id(&state, &headers).await?;

    #[cfg(feature = "ee")]
    {
        // Enforce first-login password change before running reindex (EE only)
        let must_change: bool = if let Some(pg) = &state.pg_client {
            pg.query_opt(
                "SELECT COALESCE(must_change_password, FALSE) FROM users WHERE user_id = $1",
                &[&user_id],
            )
            .await
            .ok()
            .flatten()
            .map(|row| row.get::<_, bool>(0))
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
                [user_id.as_str()],
                |row| row.get::<_, bool>(0),
            )
            .unwrap_or(false)
        };
        if must_change {
            return Ok((
                StatusCode::FORBIDDEN,
                Json(json!({"error":"password_change_required"})),
            )
                .into_response());
        }
    }

    // Get user's folders from database (PG or DuckDB)
    let folders_str: String = if let Some(pg) = &state.pg_client {
        let row = pg
            .query_opt(
                "SELECT folders FROM users WHERE user_id = $1 LIMIT 1",
                &[&user_id],
            )
            .await
            .map_err(|e| AppError(anyhow::anyhow!(e)))?;
        row.map(|r| r.get::<_, String>(0)).unwrap_or_default()
    } else {
        let users_db = state
            .multi_tenant_db
            .as_ref()
            .expect("users DB required in DuckDB mode")
            .users_connection();
        let conn = users_db.lock();
        let mut stmt = conn.prepare("SELECT folders FROM users WHERE user_id = ?")?;
        let s: String = stmt
            .query_row([&user_id], |row| Ok(row.get::<_, String>(0)?))
            .unwrap_or_default();
        drop(conn);
        s
    };

    if folders_str.is_empty() {
        return Err(AppError(anyhow::anyhow!(
            "No folders configured for indexing. Please add folders in settings first."
        )));
    }

    let folders: Vec<String> = folders_str
        .split(',')
        .map(|s| s.trim().to_string())
        .collect();
    tracing::info!(
        "[REINDEX] User {} has {} folders configured: {:?}",
        user_id,
        folders.len(),
        folders
    );
    // Log current photo count before starting (backend-specific)
    {
        if let Some(pg) = &state.pg_client {
            let org_id: i32 = if let Some(meta) = &state.meta {
                meta.resolve_org_id(&user_id).await.unwrap_or(1)
            } else {
                1
            };
            let pre_count = pg
                .query_one(
                    "SELECT COUNT(*)::BIGINT FROM photos WHERE organization_id=$1 AND user_id=$2",
                    &[&org_id, &user_id],
                )
                .await
                .ok()
                .map(|r| r.get::<_, i64>(0))
                .unwrap_or(-1);
            tracing::info!(
                "[REINDEX] Photos count BEFORE reindex for user {}: {}",
                user_id,
                pre_count
            );
        } else {
            let data_db = state.get_user_data_database(&user_id)?;
            let conn = data_db.lock();
            let pre_count = conn
                .query_row("SELECT COUNT(*) FROM photos", [], |row| {
                    row.get::<_, i64>(0)
                })
                .unwrap_or(-1);
            tracing::info!(
                "[REINDEX] Photos count BEFORE reindex for user {}: {}",
                user_id,
                pre_count
            );
        }
    }
    let folders_clone = folders.clone();

    // Create SSE job and start indexing in background
    let (job_id, tx) = state.create_reindex_job_for(&user_id);
    let state_clone = state.clone();
    let user_id_clone = user_id.clone();
    let folders_clone2 = folders.clone();
    // Fire 'started'
    let _ = tx.send(
        serde_json::json!({
            "type": "started",
            "jobId": job_id,
            "folders": folders_clone2,
        })
        .to_string(),
    );

    let job_id_for_task = job_id.clone();
    let cancel_flag = state
        .get_cancel_flag(&job_id_for_task)
        .expect("cancel flag exists");
    // Load persisted options for this user
    let album_opts = if let Some(pg) = &state.pg_client {
        let row = pg
            .query_opt(
                "SELECT index_parent_album_id, COALESCE(index_preserve_tree_path, FALSE) FROM users WHERE user_id = $1",
                &[&user_id],
            )
            .await
            .ok()
            .flatten();
        let (pid, preserve): (Option<i32>, bool) = row
            .map(|r| (r.get::<_, Option<i32>>(0), r.get::<_, bool>(1)))
            .unwrap_or((None, false));
        AlbumIndexOptions {
            album_parent_id: pid,
            preserve_tree_path: preserve,
        }
    } else {
        let users_db = state
            .multi_tenant_db
            .as_ref()
            .expect("users DB required in DuckDB mode")
            .users_connection();
        let conn = users_db.lock();
        let mut stmt = conn
            .prepare(
                "SELECT index_parent_album_id, COALESCE(index_preserve_tree_path, FALSE) FROM users WHERE user_id = ?",
            )
            .expect("prepare ok");
        let (pid, preserve): (Option<i32>, bool) = stmt
            .query_row([&user_id], |row| {
                Ok((row.get::<_, Option<i32>>(0)?, row.get::<_, bool>(1)?))
            })
            .unwrap_or((None, false));
        AlbumIndexOptions {
            album_parent_id: pid,
            preserve_tree_path: preserve,
        }
    };
    tokio::spawn(async move {
        if let Err(e) = index_user_folders(
            &state_clone,
            &user_id_clone,
            &folders_clone,
            &job_id_for_task,
            cancel_flag.clone(),
            album_opts,
        )
        .await
        {
            tracing::error!(
                "Failed to reindex folders for user {}: {}",
                user_id_clone,
                e
            );
            let _ = tx.send(
                serde_json::json!({
                    "type": "error",
                    "jobId": job_id_for_task,
                    "message": e.to_string()
                })
                .to_string(),
            );
        }
        // Log count after in background task as well
        let post_count: i64 = if let Some(pg) = &state_clone.pg_client {
            let org_id: i32 = if let Some(meta) = &state_clone.meta {
                meta.resolve_org_id(&user_id_clone).await.unwrap_or(1)
            } else {
                1
            };
            pg.query_one(
                "SELECT COUNT(*)::BIGINT FROM photos WHERE organization_id=$1 AND user_id=$2",
                &[&org_id, &user_id_clone],
            )
            .await
            .ok()
            .map(|r| r.get::<_, i64>(0))
            .unwrap_or(-1)
        } else if let Ok(data_db) = state_clone.get_user_data_database(&user_id_clone) {
            let conn = data_db.lock();
            conn.query_row("SELECT COUNT(*) FROM photos", [], |row| {
                row.get::<_, i64>(0)
            })
            .unwrap_or(-1)
        } else {
            -1
        };
        tracing::info!(
            "[REINDEX] Photos count AFTER reindex for user {}: {}",
            user_id_clone,
            post_count
        );
        let msg_type = if cancel_flag.load(std::sync::atomic::Ordering::Relaxed) {
            "cancelled"
        } else {
            "done"
        };
        let _ = tx.send(
            serde_json::json!({
                "type": msg_type,
                "jobId": job_id_for_task,
                "count": post_count
            })
            .to_string(),
        );
        // Remove job sender to close streams
        state_clone.finish_reindex_job(&job_id_for_task);
    });

    Ok(Json(json!({
        "message": format!("Reindexing started for {} folders", folders.len()),
        "folders": folders,
        "indexed": true,
        "job_id": job_id
    }))
    .into_response())
}

#[derive(Debug, Deserialize)]
pub struct ReindexStreamQuery {
    pub jobId: String,
}

#[instrument(skip(state))]
pub async fn reindex_stream(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(q): Query<ReindexStreamQuery>,
) -> Result<Sse<impl futures::Stream<Item = Result<Event, std::convert::Infallible>>>, AppError> {
    // Validate auth (Authorization or Cookie)
    let user_id = extract_user_id(&state, &headers).await?;

    // Ensure the job belongs to this user
    if let Some(owner) = state.reindex_job_owners.read().get(&q.jobId) {
        if owner != &user_id {
            return Err(AppError(anyhow::anyhow!("Job not found")));
        }
    }

    let rx = state
        .get_reindex_receiver(&q.jobId)
        .ok_or_else(|| AppError(anyhow::anyhow!("Job not found")))?;

    // Convert broadcast to SSE stream and merge a heartbeat every 20s
    let msg_stream = BroadcastStream::new(rx)
        .filter_map(|msg| futures::future::ready(msg.ok()))
        .map(|s| Ok(Event::default().data(s)));

    let heartbeat = IntervalStream::new(time::interval(Duration::from_secs(20)))
        .map(|_| Ok(Event::default().data("{\"type\":\"heartbeat\"}")));

    let stream = futures::stream::select(msg_stream, heartbeat);

    Ok(Sse::new(stream))
}

#[derive(Debug, Serialize)]
pub struct ActiveJobResponse {
    pub active: bool,
    pub job_id: Option<String>,
}

#[instrument(skip(state))]
pub async fn reindex_active(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, AppError> {
    let user_id = extract_user_id(&state, &headers).await?;
    let active = state.get_active_reindex_job_for_user(&user_id);
    Ok(Json(ActiveJobResponse {
        active: active.is_some(),
        job_id: active,
    }))
}

#[derive(Debug, Deserialize)]
pub struct ReindexStopRequest {
    pub job_id: String,
}

#[instrument(skip(state))]
pub async fn reindex_stop(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(req): Json<ReindexStopRequest>,
) -> Result<impl IntoResponse, AppError> {
    tracing::info!(
        "[REINDEX] /api/reindex/stop received (job_id={:?}, auth_hdr_present={})",
        req.job_id,
        headers.get(header::AUTHORIZATION).is_some()
    );
    let user_id = extract_user_id(&state, &headers).await?;
    tracing::info!(
        "[REINDEX] stop requested by user={} job_id={}",
        user_id,
        req.job_id
    );
    // Validate ownership
    if let Some(owner) = state.reindex_job_owners.read().get(&req.job_id) {
        if owner != &user_id {
            tracing::warn!(
                "[REINDEX] stop denied: user {} is not owner of job {} (owner={})",
                user_id,
                req.job_id,
                owner
            );
            return Err(AppError(anyhow::anyhow!("Job not found"))); // or 403
        }
    } else {
        tracing::info!(
            "[REINDEX] stop: job not found for user {} (job_id={})",
            user_id,
            req.job_id
        );
        return Ok(Json(
            json!({ "ok": true, "stopped": false, "message": "No such job" }),
        ));
    }
    // Signal cancellation
    let stopped = state.cancel_reindex_job(&req.job_id);
    if stopped {
        tracing::info!("[REINDEX] cancellation flag set for job {}", req.job_id);
        if let Some(tx) = state.reindex_jobs.read().get(&req.job_id).cloned() {
            let _ = tx.send(
                serde_json::json!({
                    "type": "cancel-requested",
                    "jobId": req.job_id
                })
                .to_string(),
            );
            tracing::info!(
                "[REINDEX] cancel-requested broadcast sent for job {}",
                req.job_id
            );
        }
    }
    Ok(Json(json!({ "ok": true, "stopped": stopped })))
}
#[derive(Debug, Deserialize)]
pub struct RefreshRequest {
    pub refresh_token: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::count_image_files;
    use std::fs;
    use std::path::PathBuf;

    fn make_temp_dir() -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("openphotos-count-image-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&dir).expect("create temp dir");
        dir
    }

    #[test]
    fn count_image_files_counts_avif() {
        let dir = make_temp_dir();
        let path = dir.join("demo.avif");
        fs::write(&path, b"not-a-real-avif").expect("write avif");

        let total = count_image_files(dir.to_str().expect("dir utf8")).expect("count");
        assert_eq!(total, 1);

        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn count_image_files_ignores_appledouble_avif() {
        let dir = make_temp_dir();
        let path = dir.join("._demo.avif");
        fs::write(&path, b"junk").expect("write appledouble");

        let total = count_image_files(dir.to_str().expect("dir utf8")).expect("count");
        assert_eq!(total, 0);

        let _ = fs::remove_dir_all(dir);
    }
}
