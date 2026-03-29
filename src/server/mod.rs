pub mod auth_handlers;
pub mod capabilities;
pub mod crypto_envelope;
pub mod demo_policy;
pub mod face_handlers;
pub mod handlers;
pub mod logging;
pub mod photo_handlers;
pub mod photo_routes;
pub mod routes;
pub mod similar_routes;
pub mod state;
pub mod text_search;
pub mod tus_proxy;
pub mod updates;
pub mod upload_handlers;
pub mod upload_hooks;
// Enterprise team handlers are available under feature gate in src/ee.rs

use axum::{
    http::{header, Method, StatusCode},
    response::{IntoResponse, Response},
};
use serde::{Deserialize, Serialize};
use std::fmt;
use tower_http::cors::{Any, CorsLayer};

#[derive(Debug, Serialize, Deserialize)]
pub struct ErrorResponse {
    pub error: String,
    pub status: u16,
}

#[derive(Debug)]
pub struct AppError(pub anyhow::Error);

impl fmt::Display for AppError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl From<anyhow::Error> for AppError {
    fn from(err: anyhow::Error) -> Self {
        AppError(err)
    }
}

impl From<duckdb::Error> for AppError {
    fn from(err: duckdb::Error) -> Self {
        AppError(anyhow::anyhow!("Database error: {}", err))
    }
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let msg = self.0.to_string();
        // Heuristic mapping to friendlier HTTP statuses
        let lowered = msg.to_ascii_lowercase();
        let status = if lowered.contains("unauthorized")
            || lowered.contains("missing authorization token")
            || lowered.contains("invalid token")
            || lowered.contains("pin_required")
        {
            StatusCode::UNAUTHORIZED
        } else if lowered.contains("forbidden") || lowered.contains("read-only") {
            StatusCode::FORBIDDEN
        } else if lowered.contains("not found") || lowered.contains("asset not found") {
            StatusCode::NOT_FOUND
        } else if lowered.contains("bad request")
            || lowered.contains("invalid or expired refresh token")
            || lowered.contains("missing refresh token")
        {
            StatusCode::UNAUTHORIZED
        } else {
            StatusCode::INTERNAL_SERVER_ERROR
        };

        let body = ErrorResponse {
            error: msg,
            status: status.as_u16(),
        };

        (status, axum::Json(body)).into_response()
    }
}

pub fn cors_layer() -> CorsLayer {
    // Expand CORS to be friendly to TUS clients (if ever cross-origin)
    use axum::http::HeaderName;
    let mut allow_headers: Vec<HeaderName> =
        vec![header::AUTHORIZATION, header::CONTENT_TYPE, header::ACCEPT];
    // Media streaming / seeking (HTMLVideoElement, AVPlayer, etc.)
    allow_headers.push(header::RANGE);
    if let Ok(h) = HeaderName::from_lowercase(b"if-range") {
        allow_headers.push(h);
    }
    // TUS-specific headers (optional if same-origin, harmless to allow)
    for name in [
        "Tus-Resumable",
        "Tus-Version",
        "Tus-Max-Size",
        "Tus-Extension",
        "Tus-Checksum-Algorithm",
        "Upload-Offset",
        "Upload-Length",
        "Upload-Checksum",
        "Upload-Metadata",
        "Upload-Concat",
        "Upload-Defer-Length",
        "X-HTTP-Method-Override",
        "Origin",
        "X-Requested-With",
        "X-Request-ID",
    ] {
        if let Ok(h) = HeaderName::from_lowercase(name.to_lowercase().as_bytes()) {
            allow_headers.push(h);
        }
    }

    let mut expose_headers: Vec<HeaderName> = vec![
        header::CONTENT_TYPE,
        header::CONTENT_LENGTH,
        header::ACCEPT_RANGES,
        header::CONTENT_RANGE,
    ];
    for name in [
        "Location",
        "Tus-Version",
        "Tus-Resumable",
        "Tus-Max-Size",
        "Tus-Extension",
        "Tus-Checksum-Algorithm",
        "Upload-Length",
        "Upload-Metadata",
        "Upload-Defer-Length",
        "Upload-Concat",
        "Upload-Offset",
    ] {
        if let Ok(h) = HeaderName::from_lowercase(name.to_lowercase().as_bytes()) {
            expose_headers.push(h);
        }
    }

    CorsLayer::new()
        .allow_origin(Any)
        .allow_methods([
            Method::GET,
            Method::POST,
            Method::PUT,
            Method::DELETE,
            Method::OPTIONS,
            Method::PATCH,
            Method::HEAD,
        ])
        .allow_headers(allow_headers)
        .expose_headers(expose_headers)
}
