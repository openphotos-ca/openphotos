pub mod jwt;
pub mod middleware;
pub mod oauth;
pub mod types;

// Re-export commonly used types
pub use self::types::{AuthResponse, LoginRequest, RegisterRequest, User};

use anyhow::{anyhow, Result};
use bcrypt::{hash, verify, DEFAULT_COST};
use chrono::{Duration, Utc};
use duckdb::params;
use sha2::{Digest, Sha256};
use uuid::Uuid;

use self::jwt::create_jwt;
use crate::database::multi_tenant::DbPool;
type PgClient = std::sync::Arc<tokio_postgres::Client>;

pub struct AuthService {
    users_db: Option<DbPool>,
    pub(crate) jwt_secret: String,
    pg_client: Option<PgClient>,
}

impl AuthService {
    pub fn new(users_db: Option<DbPool>, jwt_secret: String, pg_client: Option<PgClient>) -> Self {
        Self {
            users_db,
            jwt_secret,
            pg_client,
        }
    }

    pub async fn register(&self, request: RegisterRequest) -> Result<AuthResponse> {
        if let Some(pg) = &self.pg_client {
            // PG path: create org (if needed), insert user, create session+refresh
            tracing::info!(
                "[AUTH] (PG) register begin email={} org_id_req={:?}",
                request.email,
                request.organization_id
            );
            let password = request.password.clone();
            let password_hash = tokio::task::spawn_blocking(move || hash(&password, 4))
                .await
                .map_err(|e| anyhow!("Task failed: {}", e))??;

            let user_id = Uuid::new_v4().to_string();
            let secret = Uuid::new_v4().to_string();
            let normalized_email = request.email.to_lowercase();

            let org_id: i32 = if let Some(id) = request.organization_id {
                id
            } else {
                // Use a stable placeholder name and tolerate duplicates across tests by upserting
                let row = pg
                    .query_one(
                        "INSERT INTO organizations (name) VALUES ($1)
                         ON CONFLICT (name) DO UPDATE SET name=EXCLUDED.name
                         RETURNING id",
                        &[&""],
                    )
                    .await?;
                row.get(0)
            };
            tracing::info!("[AUTH] (PG) org resolved id={}", org_id);

            // Duplicate email check
            if let Some(_) = pg
                .query_opt(
                    "SELECT 1 FROM users WHERE lower(email)=lower($1) AND organization_id=$2 AND status='active' LIMIT 1",
                    &[&normalized_email, &org_id],
                )
                .await?
            {
                tracing::warn!("[AUTH] (PG) duplicate email for org_id={} email={}", org_id, normalized_email);
                return Err(anyhow!("Email already in use for this account"));
            }

            let row = pg
                .query_one(
                    "INSERT INTO users (user_id, name, email, password_hash, organization_id, role, secret)
                     VALUES ($1,$2,$3,$4,$5,$6,$7)
                     RETURNING id, user_id, name, email, organization_id, role, avatar, status",
                    &[&user_id, &request.name, &normalized_email, &password_hash, &org_id, &"admin", &secret],
                )
                .await?;
            let user = User {
                id: row.get(0),
                user_id: row.get(1),
                name: row.get(2),
                email: row.get(3),
                organization_id: row.get(4),
                role: row.get(5),
                avatar: row.get(6),
                status: row.get(7),
            };
            tracing::info!(
                "[AUTH] (PG) user created id={} user_id={} org_id={} role={}",
                user.id,
                user.user_id,
                user.organization_id,
                user.role
            );

            let access_token = create_jwt(&user, &self.jwt_secret)?;
            self.store_session_pg(user.id, &access_token).await?;
            let refresh = Self::generate_refresh_token();
            self.store_refresh_token_pg(user.id, &refresh).await?;
            let ttl_min: i64 = std::env::var("ACCESS_TOKEN_TTL_MINUTES")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(15);
            return Ok(AuthResponse {
                token: access_token,
                user,
                refresh_token: Some(refresh),
                expires_in: Some(ttl_min * 60),
                password_change_required: None,
            });
        }
        // Hash password in a blocking thread
        let password = request.password.clone();
        let password_hash = tokio::task::spawn_blocking(move || hash(&password, 4))
            .await
            .map_err(|e| anyhow!("Task failed: {}", e))??;

        // Generate user_id and secret
        let user_id = Uuid::new_v4().to_string();
        let secret = Uuid::new_v4().to_string();
        // Normalize email to lowercase for case-insensitive behavior
        let normalized_email = request.email.to_lowercase();

        // Determine target organization: create a new organization when none is provided
        let org_id = {
            let conn = self
                .users_db
                .as_ref()
                .expect("users_db required for DuckDB mode")
                .lock();
            match request.organization_id {
                Some(id) => id,
                None => {
                    // Compute next id manually to avoid sequence drift; insert organization with explicit id
                    let next_id: i32 = conn.query_row(
                        "SELECT COALESCE(MAX(id), 0) + 1 FROM organizations",
                        [],
                        |row| row.get(0),
                    )?;
                    let mut stmt =
                        conn.prepare("INSERT INTO organizations (id, name) VALUES (?, ?)")?;
                    let _ = stmt.execute(params![next_id, ""])?;
                    next_id
                }
            }
        };

        // Prevent duplicate emails within the same organization (case-insensitive)
        {
            let conn = self
                .users_db
                .as_ref()
                .expect("users_db required for DuckDB mode")
                .lock();
            let mut dup = conn.prepare(
                "SELECT 1 FROM users WHERE lower(email) = lower(?) AND organization_id = ? AND status = 'active' LIMIT 1",
            )?;
            let exists: Result<i32, _> =
                dup.query_row(params![&normalized_email, &org_id], |row| row.get(0));
            if exists.is_ok() {
                return Err(anyhow!("Email already in use for this account"));
            }
        }

        // Registration via public page: assign admin role for the organization
        // (Enterprise invites via team_handlers control roles per-request.)

        // Insert user
        let user = {
            let conn = self
                .users_db
                .as_ref()
                .expect("users_db required for DuckDB mode")
                .lock();
            let mut stmt = conn.prepare(
                "INSERT INTO users (user_id, name, email, password_hash, organization_id, role, secret) 
                 VALUES (?, ?, ?, ?, ?, ?, ?)
                 RETURNING id, user_id, name, email, organization_id, role, avatar, status",
            )?;

            stmt.query_row(
                params![
                    &user_id,
                    &request.name,
                    &normalized_email,
                    &password_hash,
                    org_id,
                    "admin",
                    &secret
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
            )?
            // conn is dropped here
        };

        // Create JWT access token
        let access_token = create_jwt(&user, &self.jwt_secret)?;
        self.store_session(&user.user_id, &access_token)?;
        // Create refresh token
        let refresh = Self::generate_refresh_token();
        self.store_refresh_token(&user.user_id, &refresh)?;

        // Expires-in for clients (seconds)
        let ttl_min: i64 = std::env::var("ACCESS_TOKEN_TTL_MINUTES")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(15);
        Ok(AuthResponse {
            token: access_token,
            user,
            refresh_token: Some(refresh),
            expires_in: Some(ttl_min * 60),
            password_change_required: None,
        })
    }

    pub async fn login(&self, request: LoginRequest) -> Result<AuthResponse> {
        if let Some(pg) = &self.pg_client {
            // Load user row
            let row_opt = pg
                .query_opt(
                    "SELECT id, user_id, name, email, password_hash, organization_id, role, avatar, status
                     FROM users WHERE lower(email)=lower($1) AND status='active' LIMIT 1",
                    &[&request.email.to_lowercase()],
                )
                .await?;
            let row = match row_opt {
                Some(r) => r,
                None => return Err(anyhow!("Invalid email or password")),
            };
            let user = User {
                id: row.get(0),
                user_id: row.get(1),
                name: row.get(2),
                email: row.get(3),
                organization_id: row.get(5),
                role: row.get(6),
                avatar: row.get(7),
                status: row.get(8),
            };
            let password_hash: String = row.get(4);
            let password = request.password.clone();
            let hash_clone = password_hash.clone();
            let password_valid =
                tokio::task::spawn_blocking(move || verify(&password, &hash_clone))
                    .await
                    .map_err(|e| anyhow!("Task failed: {}", e))??;
            if !password_valid {
                return Err(anyhow!("Invalid email or password"));
            }
            // Update last_active and promote owner if needed
            let _ = pg
                .execute(
                    "UPDATE users SET last_active = NOW() WHERE id=$1",
                    &[&user.id],
                )
                .await;
            let has_admin: bool = pg
                .query_one(
                    "SELECT COUNT(*) FROM users WHERE organization_id=$1 AND status='active' AND (role='owner' OR role='admin')",
                    &[&user.organization_id],
                )
                .await
                .map(|r| {
                    let c: i64 = r.get(0);
                    c > 0
                })
                .unwrap_or(false);
            let mut user = user;
            if !has_admin {
                let _ = pg
                    .execute(
                        "UPDATE users SET role='owner' WHERE id=(SELECT id FROM users WHERE organization_id=$1 ORDER BY created_at ASC LIMIT 1)",
                        &[&user.organization_id],
                    )
                    .await;
                if let Some(r2) = pg
                    .query_opt(
                        "SELECT id, user_id, name, email, organization_id, role, avatar, status FROM users WHERE id=$1",
                        &[&user.id],
                    )
                    .await?
                {
                    user = User {
                        id: r2.get(0),
                        user_id: r2.get(1),
                        name: r2.get(2),
                        email: r2.get(3),
                        organization_id: r2.get(4),
                        role: r2.get(5),
                        avatar: r2.get(6),
                        status: r2.get(7),
                    };
                }
            }
            let access_token = create_jwt(&user, &self.jwt_secret)?;
            self.store_session_pg(user.id, &access_token).await?;
            let refresh = Self::generate_refresh_token();
            self.store_refresh_token_pg(user.id, &refresh).await?;
            let ttl_min: i64 = std::env::var("ACCESS_TOKEN_TTL_MINUTES")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(15);
            return Ok(AuthResponse {
                token: access_token,
                user,
                refresh_token: Some(refresh),
                expires_in: Some(ttl_min * 60),
                password_change_required: Some(false),
            });
        }
        // Find user by email and get data (without holding connection across await)
        let (user, password_hash) = {
            let conn = self
                .users_db
                .as_ref()
                .expect("users_db required for DuckDB mode")
                .lock();
            let mut stmt = conn.prepare(
                "SELECT id, user_id, name, email, password_hash, organization_id, role, avatar, status 
                 FROM users 
                 WHERE lower(email) = lower(?) AND status = 'active' LIMIT 1"
            )?;

            let result = stmt.query_row(params![&request.email.to_lowercase()], |row| {
                Ok((
                    User {
                        id: row.get(0)?,
                        user_id: row.get(1)?,
                        name: row.get(2)?,
                        email: row.get(3)?,
                        organization_id: row.get(5)?,
                        role: row.get(6)?,
                        avatar: row.get(7)?,
                        status: row.get(8)?,
                    },
                    row.get::<_, String>(4)?, // password_hash
                ))
            });

            match result {
                Ok(data) => data,
                Err(_) => return Err(anyhow!("Invalid email or password")),
            }
            // conn and stmt are dropped here before the await
        };

        // Verify password in a blocking thread
        let password = request.password.clone();
        let hash_clone = password_hash.clone();
        let password_valid = tokio::task::spawn_blocking(move || verify(&password, &hash_clone))
            .await
            .map_err(|e| anyhow!("Task failed: {}", e))??;

        if !password_valid {
            return Err(anyhow!("Invalid email or password"));
        }

        // Update last_active and ensure an owner exists within the organization (first user becomes owner)
        let mut user = user; // make mutable to allow role refresh
        {
            let conn = self
                .users_db
                .as_ref()
                .expect("users_db required for DuckDB mode")
                .lock();
            let _ = conn.execute(
                "UPDATE users SET last_active = CURRENT_TIMESTAMP WHERE id = ?",
                params![user.id],
            );
            // Promote first user in org to owner if no admin/owner exists
            let has_admin: bool = conn
                .query_row(
                    "SELECT COUNT(*) FROM users WHERE organization_id = ? AND status='active' AND (role='owner' OR role='admin')",
                    params![user.organization_id],
                    |row| row.get::<_, i64>(0),
                )
                .map(|c| c > 0)
                .unwrap_or(false);
            if !has_admin {
                let _ = conn.execute(
                    "UPDATE users SET role='owner' WHERE id = (SELECT id FROM users WHERE organization_id = ? ORDER BY created_at ASC LIMIT 1)",
                    params![user.organization_id],
                );
                // Reload current user to reflect possibly updated role
                let mut stmt = conn.prepare(
                    "SELECT id, user_id, name, email, organization_id, role, avatar, status FROM users WHERE id = ?",
                )?;
                user = stmt.query_row(params![user.id], |row| {
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
                })?;
            }
        }

        // Create JWT access token
        let access_token = create_jwt(&user, &self.jwt_secret)?;
        // Store session with short TTL
        self.store_session(&user.user_id, &access_token)?;

        // Create refresh token and store hashed record
        let refresh = Self::generate_refresh_token();
        self.store_refresh_token(&user.user_id, &refresh)?;

        // Enterprise: check if user must change password (column may not exist in OSS DBs)
        let mut must_change_pw = false;
        {
            let conn = self
                .users_db
                .as_ref()
                .expect("users DB required in DuckDB mode")
                .lock();
            if let Ok(mut stmt) =
                conn.prepare("SELECT COALESCE(must_change_password, FALSE) FROM users WHERE id = ?")
            {
                if let Ok(v) = stmt.query_row(params![user.id], |row| row.get::<_, bool>(0)) {
                    must_change_pw = v;
                }
            }
        }

        let ttl_min: i64 = std::env::var("ACCESS_TOKEN_TTL_MINUTES")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(15);
        Ok(AuthResponse {
            token: access_token,
            user,
            refresh_token: Some(refresh),
            expires_in: Some(ttl_min * 60),
            password_change_required: Some(must_change_pw),
        })
    }

    pub async fn verify_token(&self, token: &str) -> Result<User> {
        if let Some(pg) = &self.pg_client {
            let claims = jwt::verify_jwt(token, &self.jwt_secret)?;
            let token_hash = Self::hash_token(token);
            let row = pg
                .query_one(
                    "SELECT u.id, u.user_id, u.name, u.email, u.organization_id, u.role, u.avatar, u.status
                     FROM sessions s JOIN users u ON s.user_id = u.id
                     WHERE s.token_hash=$1 AND s.expires_at > NOW() AND u.status='active'",
                    &[&token_hash],
                )
                .await?;
            let user = User {
                id: row.get(0),
                user_id: row.get(1),
                name: row.get(2),
                email: row.get(3),
                organization_id: row.get(4),
                role: row.get(5),
                avatar: row.get(6),
                status: row.get(7),
            };
            if user.user_id != claims.user_id {
                return Err(anyhow!("Invalid token"));
            }
            return Ok(user);
        }
        // Verify JWT signature
        let claims = jwt::verify_jwt(token, &self.jwt_secret)?;

        // Check if session exists (primary path). If not found, fall back to user row based on claims.
        let token_hash = Self::hash_token(token);
        let conn = self
            .users_db
            .as_ref()
            .expect("users DB required in DuckDB mode")
            .lock();

        let mut stmt = conn.prepare(
            "SELECT u.id, u.user_id, u.name, u.email, u.organization_id, u.role, u.avatar, u.status
             FROM sessions s
             JOIN users u ON s.user_id = u.id
             WHERE s.token_hash = ? AND s.expires_at > CURRENT_TIMESTAMP AND u.status = 'active'",
        )?;

        let user: User = match stmt.query_row(params![&token_hash], |row| {
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
        }) {
            Ok(u) => u,
            Err(_) => {
                // Session not found or expired; as a resilience fallback in DuckDB mode,
                // accept a still-valid JWT by loading the user row directly.
                // This keeps the app usable if the sessions table is cleared or WAL hiccups.
                let mut stmt2 = conn.prepare(
                    "SELECT id, user_id, name, email, organization_id, role, avatar, status \
                     FROM users WHERE user_id = ? AND status = 'active' LIMIT 1",
                )?;
                stmt2.query_row(params![&claims.user_id], |row| {
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
                })?
            }
        };

        // Verify user_id matches
        if user.user_id != claims.user_id {
            return Err(anyhow!("Invalid token"));
        }

        Ok(user)
    }

    pub async fn logout(&self, token: &str) -> Result<()> {
        if let Some(pg) = &self.pg_client {
            let token_hash = Self::hash_token(token);
            let internal_user_id = pg
                .query_opt(
                    "DELETE FROM sessions WHERE token_hash=$1 RETURNING user_id",
                    &[&token_hash],
                )
                .await?
                .map(|row| row.get::<_, i32>(0));
            if let Some(user_id) = internal_user_id {
                let _ = pg
                    .execute(
                        "UPDATE refresh_tokens SET revoked_at=NOW() WHERE user_id=$1 AND revoked_at IS NULL",
                        &[&user_id],
                    )
                    .await;
            }
            return Ok(());
        }
        let token_hash = Self::hash_token(token);
        let conn = self
            .users_db
            .as_ref()
            .expect("users DB required in DuckDB mode")
            .lock();

        let internal_user_id: Option<i32> = conn
            .prepare("SELECT user_id FROM sessions WHERE token_hash = ? LIMIT 1")
            .ok()
            .and_then(|mut stmt| {
                stmt.query_row(params![&token_hash], |row| row.get::<_, i32>(0))
                    .ok()
            });

        conn.execute("DELETE FROM sessions WHERE token_hash = ?", params![&token_hash])?;

        if let Some(user_id) = internal_user_id {
            let _ = conn.execute(
                "UPDATE refresh_tokens SET revoked_at = CURRENT_TIMESTAMP WHERE user_id = ? AND revoked_at IS NULL",
                params![user_id],
            );
        }

        Ok(())
    }

    pub(crate) fn store_session(&self, user_id: &str, token: &str) -> Result<()> {
        if self.pg_client.is_some() {
            // Should not be called in PG mode; use store_session_pg
            tracing::warn!("store_session called in PG mode; ignoring");
            return Ok(());
        }
        let token_hash = Self::hash_token(token);
        // Session TTL should match access token TTL (default 15 min)
        let ttl_min: i64 = std::env::var("ACCESS_TOKEN_TTL_MINUTES")
            .ok()
            .and_then(|v| v.parse::<i64>().ok())
            .unwrap_or(15);
        let expires_at = Utc::now() + Duration::minutes(ttl_min.max(1));

        let conn = self
            .users_db
            .as_ref()
            .expect("users DB required in DuckDB mode")
            .lock();

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

    pub(crate) fn hash_token(token: &str) -> String {
        let mut hasher = Sha256::new();
        hasher.update(token.as_bytes());
        format!("{:x}", hasher.finalize())
    }

    // --- Refresh token support ---

    pub(crate) fn generate_refresh_token() -> String {
        // UUID v4; sufficient entropy for opaque token, will be hashed in DB
        uuid::Uuid::new_v4().to_string()
    }

    pub(crate) fn store_refresh_token(&self, user_id: &str, refresh_token: &str) -> Result<()> {
        if self.pg_client.is_some() {
            // Should not be called in PG mode; use store_refresh_token_pg
            tracing::warn!("store_refresh_token called in PG mode; ignoring");
            return Ok(());
        }
        let token_hash = Self::hash_token(refresh_token);
        let ttl_days: i64 = std::env::var("REFRESH_TOKEN_TTL_DAYS")
            .ok()
            .and_then(|v| v.parse::<i64>().ok())
            .unwrap_or(30);
        let expires_at = Utc::now() + Duration::days(ttl_days.max(1));

        let conn = self
            .users_db
            .as_ref()
            .expect("users DB required in DuckDB mode")
            .lock();

        // Resolve internal user id
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

    pub async fn refresh_with_token(&self, refresh_token: &str) -> Result<(String, String, User)> {
        let token_hash = Self::hash_token(refresh_token);
        if let Some(pg) = &self.pg_client {
            // PG path
            let row_opt = pg
                .query_opt(
                    "SELECT u.id, u.user_id, u.name, u.email, u.organization_id, u.role, u.avatar, u.status
                     FROM refresh_tokens rt JOIN users u ON u.id = rt.user_id
                     WHERE rt.token_hash = $1 AND rt.expires_at > NOW() AND rt.revoked_at IS NULL",
                    &[&token_hash],
                )
                .await?;
            let row = row_opt.ok_or_else(|| anyhow!("Invalid or expired refresh token"))?;
            let user = User {
                id: row.get(0),
                user_id: row.get(1),
                name: row.get(2),
                email: row.get(3),
                organization_id: row.get(4),
                role: row.get(5),
                avatar: row.get(6),
                status: row.get(7),
            };
            let internal_id: i32 = row.get(0);
            let _ = pg
                .execute(
                    "UPDATE refresh_tokens SET revoked_at = NOW(), last_used_at = NOW() WHERE token_hash = $1",
                    &[&token_hash],
                )
                .await;
            let new_refresh = Self::generate_refresh_token();
            let new_hash = Self::hash_token(&new_refresh);
            let ttl_days: i64 = std::env::var("REFRESH_TOKEN_TTL_DAYS")
                .ok()
                .and_then(|v| v.parse::<i64>().ok())
                .unwrap_or(30)
                .max(1);
            let _ = pg
                .execute(
                    "INSERT INTO refresh_tokens (user_id, token_hash, expires_at, created_at) VALUES ($1,$2, NOW() + ($3 || ' days')::interval, NOW())",
                    &[&internal_id, &new_hash, &ttl_days.to_string()],
                )
                .await?;
            let access = create_jwt(&user, &self.jwt_secret)?;
            self.store_session_pg(internal_id, &access).await?;
            return Ok((access, new_refresh, user));
        }
        // DuckDB path
        let conn = self
            .users_db
            .as_ref()
            .expect("users DB required in DuckDB mode")
            .lock();
        let (user_id, user): (i32, User) = {
            let mut stmt = conn.prepare(
                "SELECT u.id, u.user_id, u.name, u.email, u.organization_id, u.role, u.avatar, u.status
                 FROM refresh_tokens rt JOIN users u ON u.id = rt.user_id
                 WHERE rt.token_hash = ? AND rt.expires_at > CURRENT_TIMESTAMP AND rt.revoked_at IS NULL"
            )?;
            let u = stmt.query_row(params![&token_hash], |row| {
                Ok((
                    row.get::<_, i32>(0)?,
                    User {
                        id: row.get(0)?,
                        user_id: row.get(1)?,
                        name: row.get(2)?,
                        email: row.get(3)?,
                        organization_id: row.get(4)?,
                        role: row.get(5)?,
                        avatar: row.get(6)?,
                        status: row.get(7)?,
                    },
                ))
            });
            u.map_err(|_| anyhow!("Invalid or expired refresh token"))?
        };
        let _ = conn.execute(
            "UPDATE refresh_tokens SET revoked_at = CURRENT_TIMESTAMP, last_used_at = CURRENT_TIMESTAMP WHERE token_hash = ?",
            params![&token_hash],
        );
        let new_refresh = Self::generate_refresh_token();
        let new_hash = Self::hash_token(&new_refresh);
        let ttl_days: i64 = std::env::var("REFRESH_TOKEN_TTL_DAYS")
            .ok()
            .and_then(|v| v.parse::<i64>().ok())
            .unwrap_or(30);
        let expires_at = Utc::now() + Duration::days(ttl_days.max(1));
        conn.execute(
            "INSERT INTO refresh_tokens (user_id, token_hash, expires_at, created_at) VALUES (?, ?, ?, CURRENT_TIMESTAMP)",
            params![user_id, &new_hash, expires_at.to_rfc3339()],
        )?;
        let access = create_jwt(&user, &self.jwt_secret)?;
        drop(conn);
        self.store_session(&user.user_id, &access)?;
        Ok((access, new_refresh, user))
    }

    // Fallback path: if a valid (non-expired) access token is presented but the refresh
    // token cookie is missing (e.g., lost cookies), mint a fresh pair and persist both.
    pub async fn rotate_from_access(&self, access_token: &str) -> Result<(String, String, User)> {
        if let Some(pg) = &self.pg_client {
            let claims = crate::auth::jwt::verify_jwt(access_token, &self.jwt_secret)?;
            let row = pg
                .query_one(
                    "SELECT id, user_id, name, email, organization_id, role, avatar, status FROM users WHERE user_id=$1 AND status='active'",
                    &[&claims.user_id],
                )
                .await?;
            let user = User {
                id: row.get(0),
                user_id: row.get(1),
                name: row.get(2),
                email: row.get(3),
                organization_id: row.get(4),
                role: row.get(5),
                avatar: row.get(6),
                status: row.get(7),
            };
            let new_access = create_jwt(&user, &self.jwt_secret)?;
            self.store_session_pg(user.id, &new_access).await?;
            let new_refresh = Self::generate_refresh_token();
            self.store_refresh_token_pg(user.id, &new_refresh).await?;
            return Ok((new_access, new_refresh, user));
        }
        let claims = crate::auth::jwt::verify_jwt(access_token, &self.jwt_secret)?;
        // Load user by user_id to ensure it still exists and is active
        let user: User = {
            let conn = self
                .users_db
                .as_ref()
                .expect("users DB required in DuckDB mode")
                .lock();
            let mut stmt = conn.prepare(
                "SELECT id, user_id, name, email, organization_id, role, avatar, status FROM users WHERE user_id = ? AND status = 'active' LIMIT 1",
            )?;
            stmt.query_row(params![&claims.user_id], |row| {
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
            })?
        };

        let new_access = create_jwt(&user, &self.jwt_secret)?;
        self.store_session(&user.user_id, &new_access)?;
        let new_refresh = Self::generate_refresh_token();
        self.store_refresh_token(&user.user_id, &new_refresh)?;
        Ok((new_access, new_refresh, user))
    }

    /// Change password for a logged-in user (requires current password)
    pub async fn change_password(
        &self,
        user_id: &str,
        current_password: &str,
        new_password: &str,
    ) -> Result<()> {
        if let Some(pg) = &self.pg_client {
            // Load current hash
            let row = pg
                .query_one(
                    "SELECT id, password_hash FROM users WHERE user_id=$1 AND status='active'",
                    &[&user_id],
                )
                .await?;
            let internal_id: i32 = row.get(0);
            let hash_now: String = row.get(1);
            // Verify current
            let cur = current_password.to_string();
            let hash_clone = hash_now.clone();
            let ok = tokio::task::spawn_blocking(move || verify(&cur, &hash_clone))
                .await
                .map_err(|e| anyhow!("Task failed: {}", e))??;
            if !ok {
                return Err(anyhow!("Current password is incorrect"));
            }
            // Hash new
            let npw = new_password.to_string();
            let new_hash = tokio::task::spawn_blocking(move || hash(&npw, DEFAULT_COST))
                .await
                .map_err(|e| anyhow!("Task failed: {}", e))??;
            pg.execute(
                "UPDATE users SET password_hash=$1 WHERE id=$2",
                &[&new_hash, &internal_id],
            )
            .await?;
            let _ = pg
                .execute("DELETE FROM sessions WHERE user_id=$1", &[&internal_id])
                .await;
            let _ = pg
                .execute(
                    "UPDATE refresh_tokens SET revoked_at=NOW() WHERE user_id=$1 AND revoked_at IS NULL",
                    &[&internal_id],
                )
                .await;
            return Ok(());
        }
        // Load current hash
        let (internal_id, hash_now) = {
            let conn = self
                .users_db
                .as_ref()
                .expect("users_db required for DuckDB mode")
                .lock();
            let mut stmt = conn.prepare("SELECT id, password_hash FROM users WHERE user_id = ? AND status = 'active' LIMIT 1")?;
            stmt.query_row(params![user_id], |row| {
                Ok((row.get::<_, i32>(0)?, row.get::<_, String>(1)?))
            })?
        };
        // Verify current
        let cur = current_password.to_string();
        let hash_clone = hash_now.clone();
        let ok = tokio::task::spawn_blocking(move || verify(&cur, &hash_clone))
            .await
            .map_err(|e| anyhow!("Task failed: {}", e))??;
        if !ok {
            return Err(anyhow!("Current password is incorrect"));
        }
        // Hash new
        let npw = new_password.to_string();
        let new_hash = tokio::task::spawn_blocking(move || hash(&npw, DEFAULT_COST))
            .await
            .map_err(|e| anyhow!("Task failed: {}", e))??;
        // Update password; EE builds also clear must_change_password and bump token_version
        let conn = self
            .users_db
            .as_ref()
            .expect("users_db required for DuckDB mode")
            .lock();
        #[cfg(feature = "ee")]
        conn.execute("UPDATE users SET password_hash = ?, must_change_password = FALSE, token_version = token_version + 1 WHERE id = ?", params![&new_hash, &internal_id])?;
        #[cfg(not(feature = "ee"))]
        conn.execute(
            "UPDATE users SET password_hash = ? WHERE id = ?",
            params![&new_hash, &internal_id],
        )?;
        let _ = conn.execute(
            "DELETE FROM sessions WHERE user_id = ?",
            params![&internal_id],
        );
        let _ = conn.execute("UPDATE refresh_tokens SET revoked_at = CURRENT_TIMESTAMP WHERE user_id = ? AND revoked_at IS NULL", params![&internal_id]);
        Ok(())
    }

    // --- PG helpers ---
    async fn store_session_pg(&self, user_internal_id: i32, token: &str) -> Result<()> {
        let token_hash = Self::hash_token(token);
        let ttl_min: i64 = std::env::var("ACCESS_TOKEN_TTL_MINUTES")
            .ok()
            .and_then(|v| v.parse::<i64>().ok())
            .unwrap_or(15)
            .max(1);
        if let Some(pg) = &self.pg_client {
            let _ = pg
                .execute(
                    "INSERT INTO sessions (user_id, token_hash, expires_at) VALUES ($1,$2, NOW() + ($3 || ' minutes')::interval)",
                    &[&user_internal_id, &token_hash, &ttl_min.to_string()],
                )
                .await?;
        }
        Ok(())
    }

    async fn store_refresh_token_pg(
        &self,
        user_internal_id: i32,
        refresh_token: &str,
    ) -> Result<()> {
        let token_hash = Self::hash_token(refresh_token);
        let ttl_days: i64 = std::env::var("REFRESH_TOKEN_TTL_DAYS")
            .ok()
            .and_then(|v| v.parse::<i64>().ok())
            .unwrap_or(30)
            .max(1);
        if let Some(pg) = &self.pg_client {
            let _ = pg
                .execute(
                    "INSERT INTO refresh_tokens (user_id, token_hash, expires_at, created_at) VALUES ($1,$2, NOW() + ($3 || ' days')::interval, NOW())",
                    &[&user_internal_id, &token_hash, &ttl_days.to_string()],
                )
                .await?;
        }
        Ok(())
    }
}
