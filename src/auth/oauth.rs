use anyhow::{anyhow, Result};
use duckdb::params;
use oauth2::reqwest::async_http_client;
use oauth2::{
    basic::BasicClient, AuthUrl, AuthorizationCode, ClientId, ClientSecret, CsrfToken, RedirectUrl,
    RevocationUrl, Scope, TokenUrl,
};
use oauth2::{AccessToken, TokenResponse};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use super::jwt::create_jwt;
use super::types::{AuthResponse, User};
use crate::database::multi_tenant::DbPool;

#[derive(Debug, Clone)]
pub struct OAuthConfig {
    pub google_client_id: String,
    pub google_client_secret: String,
    pub github_client_id: String,
    pub github_client_secret: String,
    pub redirect_base_url: String,
}

pub struct OAuthService {
    config: OAuthConfig,
    users_db: DbPool,
    jwt_secret: String,
}

#[derive(Debug, Deserialize)]
struct GoogleUserInfo {
    id: String,
    email: String,
    name: String,
    picture: Option<String>,
}

#[derive(Debug, Deserialize)]
struct GitHubUserInfo {
    id: i64,
    login: String,
    name: Option<String>,
    email: Option<String>,
    avatar_url: Option<String>,
}

impl OAuthService {
    pub fn new(config: OAuthConfig, users_db: DbPool, jwt_secret: String) -> Self {
        Self {
            config,
            users_db,
            jwt_secret,
        }
    }

    pub fn get_google_auth_url(&self) -> Result<String> {
        let client = BasicClient::new(
            ClientId::new(self.config.google_client_id.clone()),
            Some(ClientSecret::new(self.config.google_client_secret.clone())),
            AuthUrl::new("https://accounts.google.com/o/oauth2/v2/auth".to_string())?,
            Some(TokenUrl::new(
                "https://oauth2.googleapis.com/token".to_string(),
            )?),
        )
        .set_redirect_uri(RedirectUrl::new(format!(
            "{}/api/auth/oauth/google/callback",
            self.config.redirect_base_url
        ))?);

        let (auth_url, _csrf_token) = client
            .authorize_url(CsrfToken::new_random)
            .add_scope(Scope::new("email".to_string()))
            .add_scope(Scope::new("profile".to_string()))
            .url();

        Ok(auth_url.to_string())
    }

    pub fn get_github_auth_url(&self) -> Result<String> {
        let client = BasicClient::new(
            ClientId::new(self.config.github_client_id.clone()),
            Some(ClientSecret::new(self.config.github_client_secret.clone())),
            AuthUrl::new("https://github.com/login/oauth/authorize".to_string())?,
            Some(TokenUrl::new(
                "https://github.com/login/oauth/access_token".to_string(),
            )?),
        )
        .set_redirect_uri(RedirectUrl::new(format!(
            "{}/api/auth/oauth/github/callback",
            self.config.redirect_base_url
        ))?);

        let (auth_url, _csrf_token) = client
            .authorize_url(CsrfToken::new_random)
            .add_scope(Scope::new("user:email".to_string()))
            .url();

        Ok(auth_url.to_string())
    }

    pub async fn handle_google_callback(&self, code: String) -> Result<AuthResponse> {
        let client = BasicClient::new(
            ClientId::new(self.config.google_client_id.clone()),
            Some(ClientSecret::new(self.config.google_client_secret.clone())),
            AuthUrl::new("https://accounts.google.com/o/oauth2/v2/auth".to_string())?,
            Some(TokenUrl::new(
                "https://oauth2.googleapis.com/token".to_string(),
            )?),
        )
        .set_redirect_uri(RedirectUrl::new(format!(
            "{}/api/auth/oauth/google/callback",
            self.config.redirect_base_url
        ))?);

        // Exchange code for token
        let token = client
            .exchange_code(AuthorizationCode::new(code))
            .request_async(async_http_client)
            .await?;

        // Get user info from Google
        let user_info = self.get_google_user_info(token.access_token()).await?;

        // Find or create user
        let user = self
            .find_or_create_oauth_user(
                "google",
                &user_info.id,
                &user_info.name,
                Some(&user_info.email),
                user_info.picture.as_deref(),
            )
            .await?;

        // Create JWT access token
        let jwt_token = create_jwt(&user, &self.jwt_secret)?;
        self.store_session(&user.user_id, &jwt_token)?;
        // Issue refresh token
        let refresh = uuid::Uuid::new_v4().to_string();
        self.store_refresh_token(&user.user_id, &refresh)?;
        let ttl_min: i64 = std::env::var("ACCESS_TOKEN_TTL_MINUTES")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(15);
        Ok(AuthResponse {
            token: jwt_token,
            user,
            refresh_token: Some(refresh),
            expires_in: Some(ttl_min * 60),
            password_change_required: None,
        })
    }

    pub async fn handle_github_callback(&self, code: String) -> Result<AuthResponse> {
        let client = BasicClient::new(
            ClientId::new(self.config.github_client_id.clone()),
            Some(ClientSecret::new(self.config.github_client_secret.clone())),
            AuthUrl::new("https://github.com/login/oauth/authorize".to_string())?,
            Some(TokenUrl::new(
                "https://github.com/login/oauth/access_token".to_string(),
            )?),
        )
        .set_redirect_uri(RedirectUrl::new(format!(
            "{}/api/auth/oauth/github/callback",
            self.config.redirect_base_url
        ))?);

        // Exchange code for token
        let token = client
            .exchange_code(AuthorizationCode::new(code))
            .request_async(async_http_client)
            .await?;

        // Get user info from GitHub
        let user_info = self.get_github_user_info(token.access_token()).await?;

        // Find or create user
        let user = self
            .find_or_create_oauth_user(
                "github",
                &user_info.id.to_string(),
                user_info.name.as_deref().unwrap_or(&user_info.login),
                user_info.email.as_deref(),
                user_info.avatar_url.as_deref(),
            )
            .await?;

        // Create JWT access token
        let jwt_token = create_jwt(&user, &self.jwt_secret)?;
        self.store_session(&user.user_id, &jwt_token)?;
        // Issue refresh token
        let refresh = uuid::Uuid::new_v4().to_string();
        self.store_refresh_token(&user.user_id, &refresh)?;
        let ttl_min: i64 = std::env::var("ACCESS_TOKEN_TTL_MINUTES")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(15);
        Ok(AuthResponse {
            token: jwt_token,
            user,
            refresh_token: Some(refresh),
            expires_in: Some(ttl_min * 60),
            password_change_required: None,
        })
    }

    async fn get_google_user_info(&self, access_token: &AccessToken) -> Result<GoogleUserInfo> {
        let client = reqwest::Client::new();
        let response = client
            .get("https://www.googleapis.com/oauth2/v2/userinfo")
            .bearer_auth(access_token.secret())
            .send()
            .await?;

        if !response.status().is_success() {
            return Err(anyhow!("Failed to get Google user info"));
        }

        Ok(response.json().await?)
    }

    async fn get_github_user_info(&self, access_token: &AccessToken) -> Result<GitHubUserInfo> {
        let client = reqwest::Client::new();
        let response = client
            .get("https://api.github.com/user")
            .header("User-Agent", "clip-service")
            .bearer_auth(access_token.secret())
            .send()
            .await?;

        if !response.status().is_success() {
            return Err(anyhow!("Failed to get GitHub user info"));
        }

        Ok(response.json().await?)
    }

    async fn find_or_create_oauth_user(
        &self,
        provider: &str,
        oauth_id: &str,
        name: &str,
        email: Option<&str>,
        avatar: Option<&str>,
    ) -> Result<User> {
        let conn = self.users_db.lock();

        // Try to find existing user
        let existing = conn.query_row(
            "SELECT id, user_id, name, email, organization_id, role, avatar, status
             FROM users
             WHERE oauth_provider = ? AND oauth_id = ?",
            params![provider, oauth_id],
            |row| {
                Ok(User {
                    id: row.get(0)?,
                    user_id: row.get(1)?,
                    name: row.get(2)?,
                    email: row.get(3)?,
                    organization_id: row.get(4)?,
                    role: row.get(5)?,
                    avatar: row.get(6)?,
                    status: row.get(7)?,
                })
            },
        );

        if let Ok(user) = existing {
            // Update last_active
            conn.execute(
                "UPDATE users SET last_active = CURRENT_TIMESTAMP WHERE id = ?",
                params![user.id],
            )?;
            return Ok(user);
        }

        // Create new user
        let user_id = Uuid::new_v4().to_string();
        let secret = Uuid::new_v4().to_string();

        let mut stmt = conn.prepare(
            "INSERT INTO users (user_id, name, email, oauth_provider, oauth_id, organization_id, avatar, secret)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?)
             RETURNING id, user_id, name, email, organization_id, role, avatar, status"
        )?;

        let user = stmt.query_row(
            params![
                &user_id, name, email, provider, oauth_id, 1, // Default organization
                avatar, &secret
            ],
            |row| {
                Ok(User {
                    id: row.get(0)?,
                    user_id: row.get(1)?,
                    name: row.get(2)?,
                    email: row.get(3)?,
                    organization_id: row.get(4)?,
                    role: row.get(5)?,
                    avatar: row.get(6)?,
                    status: row.get(7)?,
                })
            },
        )?;

        Ok(user)
    }

    fn store_session(&self, user_id: &str, token: &str) -> Result<()> {
        use chrono::{Duration, Utc};
        use sha2::{Digest, Sha256};

        let mut hasher = Sha256::new();
        hasher.update(token.as_bytes());
        let token_hash = format!("{:x}", hasher.finalize());

        let ttl_min: i64 = std::env::var("ACCESS_TOKEN_TTL_MINUTES")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(15);
        let expires_at = Utc::now() + Duration::minutes(ttl_min.max(1));

        let conn = self.users_db.lock();

        // Get user's internal ID
        let user_internal_id: i32 = conn.query_row(
            "SELECT id FROM users WHERE user_id = ?",
            params![user_id],
            |row| row.get(0),
        )?;

        conn.execute(
            "INSERT INTO sessions (user_id, token_hash, expires_at) VALUES (?, ?, ?)",
            params![user_internal_id, &token_hash, expires_at.to_rfc3339()],
        )?;

        Ok(())
    }

    fn store_refresh_token(&self, user_id: &str, refresh_token: &str) -> Result<()> {
        use chrono::{Duration, Utc};
        use sha2::{Digest, Sha256};

        let mut hasher = Sha256::new();
        hasher.update(refresh_token.as_bytes());
        let token_hash = format!("{:x}", hasher.finalize());

        let ttl_days: i64 = std::env::var("REFRESH_TOKEN_TTL_DAYS")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(30);
        let expires_at = Utc::now() + Duration::days(ttl_days.max(1));
        let conn = self.users_db.lock();
        let user_internal_id: i32 = conn.query_row(
            "SELECT id FROM users WHERE user_id = ?",
            params![user_id],
            |row| row.get(0),
        )?;
        conn.execute(
            "INSERT INTO refresh_tokens (user_id, token_hash, expires_at, created_at) VALUES (?, ?, ?, CURRENT_TIMESTAMP)",
            params![user_internal_id, &token_hash, expires_at.to_rfc3339()],
        )?;
        Ok(())
    }
}
