use axum::{
    extract::{Request, State},
    http::{header, StatusCode},
    middleware::Next,
    response::{IntoResponse, Response},
    Json,
};
use serde_json::json;
use std::sync::Arc;

use super::types::User;
use super::AuthService;

#[derive(Clone)]
pub struct AuthState {
    pub user: User,
}

pub async fn auth_middleware(
    State(auth_service): State<Arc<AuthService>>,
    mut request: Request,
    next: Next,
) -> Result<Response, impl IntoResponse> {
    // Extract token from Authorization header
    let token = match request
        .headers()
        .get(header::AUTHORIZATION)
        .and_then(|h| h.to_str().ok())
        .and_then(|h| h.strip_prefix("Bearer "))
    {
        Some(token) => token,
        None => {
            return Err((
                StatusCode::UNAUTHORIZED,
                Json(json!({ "error": "Missing authorization token" })),
            ));
        }
    };

    // Verify token and get user
    let user = match auth_service.verify_token(token).await {
        Ok(user) => user,
        Err(e) => {
            return Err((
                StatusCode::UNAUTHORIZED,
                Json(json!({ "error": format!("Invalid token: {}", e) })),
            ));
        }
    };

    // Insert user into request extensions
    request.extensions_mut().insert(AuthState { user });

    Ok(next.run(request).await)
}

// Helper function to extract user from request
pub fn get_current_user(request: &Request) -> Option<User> {
    request
        .extensions()
        .get::<AuthState>()
        .map(|state| state.user.clone())
}
