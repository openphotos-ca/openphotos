use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct User {
    pub id: i32,
    pub user_id: String,
    pub name: String,
    pub email: Option<String>,
    pub organization_id: i32,
    pub role: String,
    pub avatar: Option<String>,
    pub status: String,
}

#[derive(Debug, Deserialize)]
pub struct LoginRequest {
    pub email: String,
    pub password: String,
}

// Two-step login
#[derive(Debug, Deserialize)]
pub struct LoginStartRequest {
    pub email: String,
}

#[derive(Debug, Serialize)]
pub struct LoginStartResponseItem {
    pub organization_id: i32,
    pub organization_name: String,
}

#[derive(Debug, Serialize)]
pub struct LoginStartResponse {
    pub accounts: Vec<LoginStartResponseItem>,
}

#[derive(Debug, Deserialize)]
pub struct LoginFinishRequest {
    pub email: String,
    pub organization_id: i32,
    pub password: String,
}

#[derive(Debug, Deserialize)]
pub struct RegisterRequest {
    pub name: String,
    pub email: String,
    pub password: String,
    pub organization_id: Option<i32>,
}

#[derive(Debug, Serialize)]
pub struct AuthResponse {
    pub token: String,
    pub user: User,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub refresh_token: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub expires_in: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub password_change_required: Option<bool>,
}

#[derive(Debug, Deserialize)]
pub struct OAuthCallback {
    pub code: String,
    pub state: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct PasswordChangeRequest {
    #[serde(default)]
    pub current_password: Option<String>,
    pub new_password: String,
}
