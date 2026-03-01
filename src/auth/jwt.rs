use anyhow::{anyhow, Result};
use chrono::{Duration, Utc};
use jsonwebtoken::{decode, encode, DecodingKey, EncodingKey, Header, Validation};
use serde::{Deserialize, Serialize};

use super::types::User;

#[derive(Debug, Serialize, Deserialize)]
pub struct Claims {
    pub user_id: String,
    pub email: Option<String>,
    pub role: String,
    pub organization_id: i32,
    pub exp: i64,
    pub iat: i64,
}

pub fn create_jwt(user: &User, secret: &str) -> Result<String> {
    let now = Utc::now();
    // Short-lived access token; default 15 minutes. Override with ACCESS_TOKEN_TTL_MINUTES.
    let ttl_min: i64 = std::env::var("ACCESS_TOKEN_TTL_MINUTES")
        .ok()
        .and_then(|v| v.parse::<i64>().ok())
        .unwrap_or(15);
    let expires_at = now + Duration::minutes(ttl_min.max(1));

    let claims = Claims {
        user_id: user.user_id.clone(),
        email: user.email.clone(),
        role: user.role.clone(),
        organization_id: user.organization_id,
        exp: expires_at.timestamp(),
        iat: now.timestamp(),
    };

    let token = encode(
        &Header::default(),
        &claims,
        &EncodingKey::from_secret(secret.as_bytes()),
    )?;

    Ok(token)
}

pub fn verify_jwt(token: &str, secret: &str) -> Result<Claims> {
    let token_data = decode::<Claims>(
        token,
        &DecodingKey::from_secret(secret.as_bytes()),
        &Validation::default(),
    )
    .map_err(|e| anyhow!("Invalid token: {}", e))?;

    Ok(token_data.claims)
}
