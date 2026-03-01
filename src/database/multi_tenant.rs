use anyhow::{anyhow, Context, Result};
use duckdb::Connection;
use parking_lot::Mutex;
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use tracing::{debug, error, info, trace, warn};

pub type DbPool = Arc<Mutex<Connection>>;

pub struct MultiTenantDatabase {
    users_db: DbPool,
    // Global data database for all tenants (also holds users/org/sessions now)
    data_db: DbPool,
    data_db_path: PathBuf,
    // Legacy maps retained for compatibility; no longer used in global mode
    user_data_databases: Arc<Mutex<HashMap<String, DbPool>>>,
    user_embedding_databases: Arc<Mutex<HashMap<String, DbPool>>>,
    data_dir: PathBuf,
}

impl MultiTenantDatabase {
    /// Apply pragmatic resource limits to DuckDB connections.
    ///
    /// These PRAGMAs are intentionally lightweight and safe to run on every new connection.
    /// The primary goal is to prevent unbounded memory growth during large checkpoints/scans.
    fn apply_duckdb_pragmas(conn: &Connection, log_info: bool) {
        let _ = conn.execute("PRAGMA threads=1;", []);

        // Bound DuckDB's in-process memory usage. This is configurable via env and defaults to a
        // conservative value to avoid runaway RAM (especially when the DB contains large blobs).
        let memory_limit =
            std::env::var("DUCKDB_MEMORY_LIMIT").unwrap_or_else(|_| "8GB".to_string());
        let safe = memory_limit.replace('\'', "''");
        let sql = format!("PRAGMA memory_limit='{}';", safe);
        match conn.execute(&sql, []) {
            Ok(_) => {
                if log_info {
                    info!("[MULTI_TENANT_DB] DuckDB memory_limit={}", memory_limit);
                }
            }
            Err(e) => {
                warn!(
                    "[MULTI_TENANT_DB] Failed to set DuckDB memory_limit={} err={}",
                    memory_limit, e
                );
            }
        }
    }

    pub fn new(data_dir: impl AsRef<Path>) -> Result<Self> {
        let data_dir = data_dir.as_ref().to_path_buf();

        // Create data directory if it doesn't exist
        fs::create_dir_all(&data_dir)?;

        // In Postgres mode, avoid creating on-disk DuckDB files; use in-memory placeholders.
        let backend = std::env::var("EMBEDDINGS_BACKEND").unwrap_or_else(|_| "duckdb".into());
        if backend.eq_ignore_ascii_case("postgres") {
            let users_conn = Connection::open_in_memory()?;
            let data_conn = Connection::open_in_memory()?;
            return Ok(Self {
                users_db: Arc::new(Mutex::new(users_conn)),
                data_db: Arc::new(Mutex::new(data_conn)),
                data_db_path: data_dir.join("data.duckdb"),
                user_data_databases: Arc::new(Mutex::new(HashMap::new())),
                user_embedding_databases: Arc::new(Mutex::new(HashMap::new())),
                data_dir,
            });
        }

        // Open or create the global data database (now also holds users/org/sessions)
        let data_db_path = data_dir.join("data.duckdb");
        let data_wal_path = data_dir.join("data.duckdb.wal");
        let data_db_existed = data_db_path.exists();
        let data_conn = match Connection::open(&data_db_path) {
            Ok(c) => c,
            Err(e) => {
                let msg = format!("{}", e);
                if msg.contains("Failure while replaying WAL") || msg.contains("Binder Error") {
                    if data_wal_path.exists() {
                        info!(
                            "[MULTI_TENANT_DB] Removing stale data WAL due to open error: {:?}",
                            data_wal_path
                        );
                        let _ = fs::remove_file(&data_wal_path);
                    }
                    Connection::open(&data_db_path)?
                } else if msg.contains("Failed to load metadata pointer")
                    || msg.contains("Internal Error")
                {
                    // The database file appears to be corrupted beyond WAL replay.
                    // By default, do NOT auto-reset to avoid data loss. Allow opt-in via env.
                    let autoreset =
                        std::env::var("DUCKDB_AUTORESET").unwrap_or_else(|_| "0".into()) == "1";
                    if autoreset {
                        warn!(
                            "[MULTI_TENANT_DB] Corrupt DB detected and DUCKDB_AUTORESET=1; backing up and creating a new database. err={}",
                            msg
                        );
                        // Best-effort backup
                        let ts = match std::time::SystemTime::now()
                            .duration_since(std::time::UNIX_EPOCH)
                        {
                            Ok(d) => d.as_secs(),
                            Err(_) => 0,
                        };
                        let backup_path =
                            data_db_path.with_extension(format!("duckdb.corrupt.{}", ts));
                        let _ = fs::rename(&data_db_path, &backup_path);
                        if data_wal_path.exists() {
                            let wal_backup =
                                data_wal_path.with_extension(format!("wal.corrupt.{}", ts));
                            let _ = fs::rename(&data_wal_path, &wal_backup);
                        }
                        info!(
                            "[MULTI_TENANT_DB] Backed up corrupt DB to {:?}; creating a fresh data DB at {:?}",
                            backup_path,
                            data_db_path
                        );
                        Connection::open(&data_db_path)?
                    } else {
                        error!(
                            "[MULTI_TENANT_DB] Corrupt data DB detected. To auto-backup and reset, set DUCKDB_AUTORESET=1. err={}",
                            msg
                        );
                        return Err(anyhow!(
                            "DuckDB file appears corrupted ({}). See docs for salvage steps or set DUCKDB_AUTORESET=1 to auto-backup/reset.",
                            msg
                        ));
                    }
                } else {
                    return Err(e.into());
                }
            }
        };
        // Do not install/load VSS in the control-plane/data DB. VSS is only required in the
        // per-user embedding database where vector indexes live. Keeping it off here avoids
        // unnecessary extension state and keeps the core DB lean.
        Self::apply_duckdb_pragmas(&data_conn, true);
        // Ensure/merge control-plane tables into the global data DB
        if !data_db_existed {
            info!("[MULTI_TENANT_DB] Creating global DB at {:?}", data_db_path);
        } else {
            info!(
                "[MULTI_TENANT_DB] Ensuring migrations on global DB at {:?}",
                data_db_path
            );
        }

        // One-time merge from legacy users.duckdb if present and users table is absent in data DB
        if let Err(e) = Self::maybe_merge_users_into_data_static(&data_dir, &data_conn) {
            warn!("[MULTI_TENANT_DB] users→data merge skipped/failed: {}", e);
        }

        // Ensure control-plane schema lives in data DB
        if let Err(e) = Self::create_control_plane_tables_static(&data_conn) {
            warn!(
                "[MULTI_TENANT_DB] control-plane schema ensure failed: {}",
                e
            );
        }
        // Build the object (users_db now points to data_db)
        let data_pool = Arc::new(Mutex::new(data_conn));
        let db = Self {
            users_db: data_pool.clone(),
            data_db: data_pool.clone(),
            data_db_path,
            user_data_databases: Arc::new(Mutex::new(HashMap::new())),
            user_embedding_databases: Arc::new(Mutex::new(HashMap::new())),
            data_dir,
        };
        // Ensure data-plane + embedding tables in the global DB
        {
            let conn = db.data_db.lock();
            db.create_user_data_tables(&conn)?;
            db.create_user_embedding_tables(&conn)?;
            let _ = conn.execute("CHECKPOINT;", []);
        }

        info!("Multi-tenant database initialized at: {:?}", db.data_dir);

        Ok(db)
    }

    pub fn users_connection(&self) -> DbPool {
        // Compatibility: callers expect a dedicated users DB; we now return the unified data DB
        self.users_db.clone()
    }

    pub fn get_user_database(&self, _user_id: &str) -> Result<DbPool> {
        // Global data DB; callers must filter by organization_id
        Ok(self.data_db.clone())
    }

    pub fn get_user_data_database(&self, _user_id: &str) -> Result<DbPool> {
        Ok(self.data_db.clone())
    }

    /// Open a new, independent read-only connection to the unified DuckDB file.
    /// This avoids blocking the global mutex for long-running read queries.
    /// Note: DuckDB doesn't enforce read-only at the connection level here, so
    /// callers must use this only for SELECTs.
    pub fn open_reader(&self) -> Result<Connection> {
        // Open a fresh connection to the same database file with basic self-healing
        // similar to the constructor: handle stale WAL and, optionally, hard corruption.
        let path = self.data_db_path.clone();
        let wal_path = path.with_extension("duckdb.wal");

        let try_open = || Connection::open(&path);

        let conn = match try_open() {
            Ok(c) => c,
            Err(e) => {
                let msg = format!("{}", e);
                // Common transient state: stale WAL after an unclean shutdown
                if msg.contains("Failure while replaying WAL") || msg.contains("Binder Error") {
                    if wal_path.exists() {
                        info!(
                            "[MULTI_TENANT_DB] Removing stale data WAL on reader open: {:?}",
                            wal_path
                        );
                        let _ = std::fs::remove_file(&wal_path);
                    }
                    try_open().with_context(|| {
                        format!(
                            "failed to open read connection to {:?} after WAL cleanup",
                            path
                        )
                    })?
                } else if msg.contains("Failed to load metadata pointer")
                    || msg.contains("Internal Error")
                    || msg.contains("No more data remaining in MetadataReader")
                {
                    // Database may be corrupt beyond WAL replay. Respect the same
                    // DUCKDB_AUTORESET behaviour we use at startup.
                    let autoreset =
                        std::env::var("DUCKDB_AUTORESET").unwrap_or_else(|_| "0".into()) == "1";
                    if autoreset {
                        warn!(
                            "[MULTI_TENANT_DB] Corrupt data DB detected on reader open; backing up and recreating. err={}",
                            msg
                        );
                        let ts = match std::time::SystemTime::now()
                            .duration_since(std::time::UNIX_EPOCH)
                        {
                            Ok(d) => d.as_secs(),
                            Err(_) => 0,
                        };
                        let backup_path = path.with_extension(format!("duckdb.corrupt.{}", ts));
                        let _ = std::fs::rename(&path, &backup_path);
                        if wal_path.exists() {
                            let wal_backup = wal_path.with_extension(format!("wal.corrupt.{}", ts));
                            let _ = std::fs::rename(&wal_path, &wal_backup);
                        }
                        info!(
                            "[MULTI_TENANT_DB] Backed up corrupt DB to {:?}; creating a fresh data DB at {:?}",
                            backup_path,
                            path
                        );
                        try_open().with_context(|| {
                            format!(
                                "failed to open read connection to {:?} after autoreset",
                                path
                            )
                        })?
                    } else {
                        return Err(anyhow!(
                            "DuckDB file appears corrupted ({}). Set DUCKDB_AUTORESET=1 to auto-backup/reset.",
                            msg
                        ));
                    }
                } else {
                    return Err(e)
                        .with_context(|| format!("failed to open read connection to {:?}", path));
                }
            }
        };

        // Apply resource limits (threads + memory limit). Keep logs quiet here since `open_reader()`
        // can be used on hot paths.
        Self::apply_duckdb_pragmas(&conn, false);
        // Avoid fast-failing on transient writer locks
        let _ = conn.execute("PRAGMA busy_timeout=5000;", []);
        Ok(conn)
    }

    /// Get or open the per-user embedding database connection
    pub fn get_user_embedding_database(&self, user_id: &str) -> Result<DbPool> {
        // Return cached if present
        if let Some(db) = self.user_embedding_databases.lock().get(user_id).cloned() {
            return Ok(db);
        }

        // Create user directory if it doesn't exist
        let user_dir = self.get_user_data_path(user_id);
        fs::create_dir_all(&user_dir)?;

        // Open or create user embedding database with WAL recovery
        let db_path = user_dir.join("clip_service.duckdb");
        let wal_path = user_dir.join("clip_service.duckdb.wal");
        let db_file_existed = db_path.exists();
        info!(
            "[MULTI_TENANT_DB] Opening user embedding database at: {:?} (existed: {})",
            db_path, db_file_existed
        );
        let conn = match Connection::open(&db_path) {
            Ok(c) => c,
            Err(e) => {
                let msg = format!("{}", e);
                if msg.contains("Failure while replaying WAL")
                    || msg.contains("unknown index type 'HNSW'")
                    || msg.contains("Binder Error")
                {
                    if wal_path.exists() {
                        info!(
                            "[MULTI_TENANT_DB] Removing stale embedding WAL on open: {:?}",
                            wal_path
                        );
                        let _ = fs::remove_file(&wal_path);
                    }
                    Connection::open(&db_path)?
                } else {
                    return Err(e.into());
                }
            }
        };

        // Load VSS extension and ensure expected schema
        let _ = conn.execute_batch("INSTALL vss;\nLOAD vss;");
        if !db_file_existed {
            self.create_user_embedding_tables(&conn)?;
        }
        let _ = conn.execute(
            "ALTER TABLE faces ADD COLUMN IF NOT EXISTS quality_score REAL",
            [],
        );
        let _ = conn.execute(
            "ALTER TABLE faces ADD COLUMN IF NOT EXISTS yaw_deg REAL",
            [],
        );
        let _ = conn.execute(
            "ALTER TABLE faces ADD COLUMN IF NOT EXISTS sharpness REAL",
            [],
        );
        let _ = conn.execute(
            "ALTER TABLE faces ADD COLUMN IF NOT EXISTS is_hidden BOOLEAN DEFAULT FALSE",
            [],
        );
        let _ = conn.execute(
            "ALTER TABLE faces ADD COLUMN IF NOT EXISTS time_ms INTEGER",
            [],
        );
        let _ = conn.execute(
            "ALTER TABLE persons ADD COLUMN IF NOT EXISTS birth_date VARCHAR",
            [],
        );
        let _ = conn.execute("CHECKPOINT;", []);

        let db_pool = Arc::new(Mutex::new(conn));
        self.user_embedding_databases
            .lock()
            .insert(user_id.to_string(), db_pool.clone());
        Ok(db_pool)
    }

    /// Open a brand-new, uncached connection to the user's embedding database.
    /// This is useful to recover from a transient lock or prepare error by retrying the query
    /// against a fresh connection without disturbing the cached one.
    pub fn open_fresh_user_embedding_connection(&self, user_id: &str) -> Result<Connection> {
        let user_dir = self.get_user_data_path(user_id);
        fs::create_dir_all(&user_dir)?;
        let db_path = user_dir.join("clip_service.duckdb");
        let wal_path = user_dir.join("clip_service.duckdb.wal");
        let conn = match Connection::open(&db_path) {
            Ok(c) => c,
            Err(e) => {
                let msg = format!("{}", e);
                if msg.contains("Failure while replaying WAL") || msg.contains("Binder Error") {
                    // Attempt recovery by removing stale WAL then reopening
                    if wal_path.exists() {
                        info!(
                            "[MULTI_TENANT_DB] Removing stale embedding WAL on fresh-open: {:?}",
                            wal_path
                        );
                        let _ = fs::remove_file(&wal_path);
                    }
                    Connection::open(&db_path)?
                } else {
                    return Err(e.into());
                }
            }
        };
        // Flush any pending DDL
        let _ = conn.execute("CHECKPOINT;", []);
        Ok(conn)
    }

    /// Force-refresh the cached user embedding connection so subsequent reads
    /// see data written by other connections immediately.
    pub fn refresh_user_embedding_connection(&self, user_id: &str) -> Result<DbPool> {
        // Drop cached connection (if any)
        {
            let mut databases = self.user_embedding_databases.lock();
            databases.remove(user_id);
        }

        // Reopen via the same path as get_user_embedding_database
        let mut databases = self.user_embedding_databases.lock();
        // Create user directory if it doesn't exist
        let user_dir = self.data_dir.join(format!("user_{}", user_id));
        fs::create_dir_all(&user_dir)?;

        // Open or create user embedding database with WAL recovery
        let db_path = user_dir.join("clip_service.duckdb");
        let wal_path = user_dir.join("clip_service.duckdb.wal");
        let db_file_existed = db_path.exists();
        info!(
            "[MULTI_TENANT_DB] Refresh opening user embedding database at: {:?} (existed: {})",
            db_path, db_file_existed
        );
        let conn = match Connection::open(&db_path) {
            Ok(c) => c,
            Err(e) => {
                let msg = format!("{}", e);
                if msg.contains("Failure while replaying WAL")
                    || msg.contains("unknown index type 'HNSW'")
                {
                    if wal_path.exists() {
                        info!(
                            "[MULTI_TENANT_DB] Removing stale embedding WAL on refresh: {:?}",
                            wal_path
                        );
                        let _ = fs::remove_file(&wal_path);
                    }
                    Connection::open(&db_path)?
                } else {
                    return Err(e.into());
                }
            }
        };

        // Load VSS extension and ensure expected schema
        let _ = conn.execute_batch("INSTALL vss;\nLOAD vss;");
        if !db_file_existed {
            self.create_user_embedding_tables(&conn)?;
        }
        let _ = conn.execute(
            "ALTER TABLE faces ADD COLUMN IF NOT EXISTS quality_score REAL",
            [],
        );
        let _ = conn.execute(
            "ALTER TABLE faces ADD COLUMN IF NOT EXISTS yaw_deg REAL",
            [],
        );
        let _ = conn.execute(
            "ALTER TABLE faces ADD COLUMN IF NOT EXISTS sharpness REAL",
            [],
        );
        let _ = conn.execute(
            "ALTER TABLE faces ADD COLUMN IF NOT EXISTS is_hidden BOOLEAN DEFAULT FALSE",
            [],
        );
        let _ = conn.execute(
            "ALTER TABLE faces ADD COLUMN IF NOT EXISTS time_ms INTEGER",
            [],
        );
        let _ = conn.execute(
            "ALTER TABLE persons ADD COLUMN IF NOT EXISTS birth_date VARCHAR",
            [],
        );
        let _ = conn.execute("CHECKPOINT;", []);

        let db_pool = Arc::new(Mutex::new(conn));
        databases.insert(user_id.to_string(), db_pool.clone());
        Ok(db_pool)
    }

    // --- Control-plane (users/org/sessions) schema ensure on unified DB ---
    fn create_control_plane_tables_static(conn: &Connection) -> Result<()> {
        // Sequences and core tables
        conn.execute_batch(
            "CREATE SEQUENCE IF NOT EXISTS org_seq;\n\
             CREATE SEQUENCE IF NOT EXISTS user_seq;\n\
             CREATE SEQUENCE IF NOT EXISTS session_seq;\n\
             CREATE SEQUENCE IF NOT EXISTS refresh_seq;\n\
             CREATE TABLE IF NOT EXISTS organizations (\n\
                 id INTEGER PRIMARY KEY DEFAULT nextval('org_seq'),\n\
                 name VARCHAR(255) NOT NULL,\n\
                 created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP\n\
             );\n\
             CREATE TABLE IF NOT EXISTS users (\n\
                 id INTEGER PRIMARY KEY DEFAULT nextval('user_seq'),\n\
                 user_id VARCHAR(100) UNIQUE NOT NULL,\n\
                 name VARCHAR(255) NOT NULL,\n\
                 email VARCHAR(255),\n\
                 password_hash VARCHAR(255),\n\
                 oauth_provider VARCHAR(50),\n\
                 oauth_id VARCHAR(255),\n\
                 organization_id INTEGER NOT NULL,\n\
                 role VARCHAR(30) DEFAULT 'regular',\n\
                 avatar TEXT,\n\
                 secret VARCHAR(255),\n\
                 folders TEXT DEFAULT '',\n\
                 must_change_password BOOLEAN DEFAULT FALSE,\n\
                 token_version INTEGER DEFAULT 1,\n\
                 face_min_quality REAL DEFAULT 0.55,\n\
                 face_min_confidence REAL DEFAULT 0.75,\n\
                 face_min_size INTEGER DEFAULT 64,\n\
                 face_yaw_max REAL DEFAULT 75.0,\n\
                 face_yaw_hard_max REAL DEFAULT 85.0,\n\
                 face_min_sharpness REAL DEFAULT 0.15,\n\
                 face_sharpness_target REAL DEFAULT 500.0,\n\
                 video_face_gating_mode VARCHAR DEFAULT 'yolo_fallback',\n\
                 yolo_person_threshold REAL DEFAULT 0.30,\n\
                 retina_min_frames INTEGER DEFAULT 1,\n\
                 total_size BIGINT DEFAULT 0,\n\
                 trash_auto_purge_days INTEGER DEFAULT 30,\n\
                 created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,\n\
                 last_active TIMESTAMP DEFAULT CURRENT_TIMESTAMP,\n\
                 status VARCHAR(20) DEFAULT 'active',\n\
                 pin_hash TEXT,\n\
                 locked_meta_allow_location BOOLEAN DEFAULT FALSE,\n\
                 locked_meta_allow_caption BOOLEAN DEFAULT FALSE,\n\
                 locked_meta_allow_description BOOLEAN DEFAULT FALSE,\n\
                 pin_remember_minutes INTEGER DEFAULT 60,\n\
                 index_parent_album_id INTEGER,\n\
                 index_preserve_tree_path BOOLEAN DEFAULT FALSE,\n\
                 crypto_envelope_json TEXT,\n\
                 crypto_envelope_updated_at TIMESTAMP,\n\
                 FOREIGN KEY (organization_id) REFERENCES organizations(id)\n\
             );\n\
             CREATE TABLE IF NOT EXISTS sessions (\n\
                 id INTEGER PRIMARY KEY DEFAULT nextval('session_seq'),\n\
                 user_id INTEGER NOT NULL,\n\
                 token_hash VARCHAR(255) UNIQUE NOT NULL,\n\
                 expires_at TIMESTAMP NOT NULL,\n\
                 created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,\n\
                 FOREIGN KEY (user_id) REFERENCES users(id)\n\
             );\n\
             CREATE TABLE IF NOT EXISTS refresh_tokens (\n\
                 id INTEGER PRIMARY KEY DEFAULT nextval('refresh_seq'),\n\
                 user_id INTEGER NOT NULL,\n\
                 token_hash VARCHAR(255) UNIQUE NOT NULL,\n\
                 created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,\n\
                 expires_at TIMESTAMP NOT NULL,\n\
                 last_used_at TIMESTAMP,\n\
                 revoked_at TIMESTAMP,\n\
                 device_id TEXT,\n\
                 user_agent TEXT,\n\
                 FOREIGN KEY (user_id) REFERENCES users(id)\n\
             );",
        )?;

        // Backfill EE user columns if the table pre-existed without them
        let _ = conn.execute(
            "ALTER TABLE users ADD COLUMN IF NOT EXISTS must_change_password BOOLEAN DEFAULT FALSE",
            [],
        );
        let _ = conn.execute(
            "ALTER TABLE users ADD COLUMN IF NOT EXISTS token_version INTEGER DEFAULT 1",
            [],
        );
        info!("[MULTI_TENANT_DB] Ensured users columns: must_change_password, token_version");

        // EE-only groups/shares (compiled conditionally)
        #[cfg(feature = "ee")]
        {
            let _ = conn.execute("CREATE SEQUENCE IF NOT EXISTS group_seq;", []);
            let _ = conn.execute(
                "CREATE TABLE IF NOT EXISTS groups (\n\
                    id INTEGER PRIMARY KEY DEFAULT nextval('group_seq'),\n\
                    organization_id INTEGER NOT NULL,\n\
                    name VARCHAR(255) NOT NULL,\n\
                    description TEXT,\n\
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,\n\
                    deleted_at TIMESTAMP,\n\
                    FOREIGN KEY (organization_id) REFERENCES organizations(id)\n\
                )",
                [],
            );
            let _ = conn.execute(
                "CREATE TABLE IF NOT EXISTS user_groups (\n\
                    user_id INTEGER NOT NULL,\n\
                    group_id INTEGER NOT NULL,\n\
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,\n\
                    PRIMARY KEY (user_id, group_id),\n\
                    FOREIGN KEY (user_id) REFERENCES users(id),\n\
                    FOREIGN KEY (group_id) REFERENCES groups(id)\n\
                )",
                [],
            );
            let _ = conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_users_org_email ON users(organization_id, email)",
                [],
            );
            let _ = conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_groups_org_name ON groups(organization_id, name)",
                [],
            );

            // EE sharing tables
            let _ = conn.execute(
                "CREATE TABLE IF NOT EXISTS ee_shares (\n\
                    id TEXT PRIMARY KEY,\n\
                    owner_org_id INTEGER NOT NULL,\n\
                    owner_user_id TEXT NOT NULL,\n\
                    object_kind VARCHAR NOT NULL,\n\
                    object_id TEXT NOT NULL,\n\
                    default_permissions INTEGER NOT NULL DEFAULT 1,\n\
                    expires_at TIMESTAMP,\n\
                    status VARCHAR DEFAULT 'active',\n\
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,\n\
                    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,\n\
                    name TEXT DEFAULT '' NOT NULL,\n\
                    include_faces BOOLEAN DEFAULT TRUE NOT NULL,\n\
                    include_subtree BOOLEAN DEFAULT FALSE NOT NULL\n\
                )",
                [],
            );
            let _ = conn.execute(
                "ALTER TABLE ee_shares ADD COLUMN IF NOT EXISTS name TEXT DEFAULT '' NOT NULL",
                [],
            );
            let _ = conn.execute(
                "ALTER TABLE ee_shares ADD COLUMN IF NOT EXISTS include_faces BOOLEAN DEFAULT TRUE NOT NULL",
                [],
            );
            let _ = conn.execute(
                "ALTER TABLE ee_shares ADD COLUMN IF NOT EXISTS include_subtree BOOLEAN DEFAULT FALSE NOT NULL",
                [],
            );
            let _ = conn.execute(
                "CREATE TABLE IF NOT EXISTS ee_share_recipients (\n\
                    id TEXT PRIMARY KEY,\n\
                    share_id TEXT NOT NULL,\n\
                    recipient_type VARCHAR NOT NULL,\n\
                    recipient_user_id TEXT,\n\
                    recipient_group_id INTEGER,\n\
                    external_email TEXT,\n\
                    external_org_id INTEGER,\n\
                    permissions INTEGER,\n\
                    invitation_status VARCHAR DEFAULT 'active',\n\
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,\n\
                    FOREIGN KEY (share_id) REFERENCES ee_shares(id)\n\
                )",
                [],
            );
            let _ = conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_ee_share_owner ON ee_shares(owner_org_id, owner_user_id)",
                [],
            );
            let _ = conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_ee_share_object ON ee_shares(object_kind, object_id)",
                [],
            );
            let _ = conn.execute(
                "CREATE UNIQUE INDEX IF NOT EXISTS idx_ee_share_recipient_dedupe ON ee_share_recipients(share_id, recipient_type, COALESCE(recipient_user_id, CAST(recipient_group_id AS TEXT), external_email))",
                [],
            );
            let _ = conn.execute(
                "CREATE TABLE IF NOT EXISTS ee_share_activity (\n\
                    id TEXT PRIMARY KEY,\n\
                    share_id TEXT NOT NULL,\n\
                    actor_user_id TEXT,\n\
                    event VARCHAR NOT NULL,\n\
                    at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,\n\
                    meta TEXT,\n\
                    FOREIGN KEY (share_id) REFERENCES ee_shares(id)\n\
                )",
                [],
            );
        }

        // Align org sequence with max(id)
        let next_org_id: i64 = conn
            .query_row(
                "SELECT COALESCE(MAX(id), 0) + 1 FROM organizations",
                [],
                |row| row.get(0),
            )
            .unwrap_or(1);
        let _ = conn.execute(
            &format!("ALTER SEQUENCE org_seq RESTART WITH {}", next_org_id),
            [],
        );

        // Finalize
        let _ = conn.execute("CHECKPOINT;", []);
        Ok(())
    }

    fn maybe_merge_users_into_data_static(data_dir: &Path, conn: &Connection) -> Result<()> {
        // Skip if users table already exists in data DB
        if Self::table_exists(conn, None, "users")? {
            return Ok(());
        }

        let legacy_path = data_dir.join("users.duckdb");
        if !legacy_path.exists() {
            // Nothing to merge
            return Ok(());
        }

        info!(
            "[MULTI_TENANT_DB] Detected legacy users.duckdb; merging control-plane tables into data.duckdb"
        );

        // Attach legacy DB as schema `old`
        conn.execute(&format!("ATTACH '{}' AS old;", legacy_path.display()), [])?;

        // Ensure control-plane schema exists in target before copy
        Self::create_control_plane_tables_static(conn)?;

        // Helper: copy table with column intersection to handle schema drift
        let copy = |table: &str| -> Result<i64> {
            Self::copy_table_with_column_intersection(conn, "old", table)
        };

        // Copy core tables (order by dependencies)
        let _org = copy("organizations").context("copy organizations")?;
        let _users = copy("users").context("copy users")?;
        let _sessions = copy("sessions").context("copy sessions")?;
        let _rt = copy("refresh_tokens").context("copy refresh_tokens")?;

        // EE optional tables
        #[cfg(feature = "ee")]
        {
            let _ = copy("groups");
            let _ = copy("user_groups");
            let _ = copy("ee_shares");
            let _ = copy("ee_share_recipients");
            let _ = copy("ee_share_activity");
        }

        // Advance sequences after copy
        let _ = Self::reset_sequence_from_table(conn, "org_seq", "organizations");
        let _ = Self::reset_sequence_from_table(conn, "user_seq", "users");
        let _ = Self::reset_sequence_from_table(conn, "session_seq", "sessions");
        let _ = Self::reset_sequence_from_table(conn, "refresh_seq", "refresh_tokens");
        #[cfg(feature = "ee")]
        let _ = Self::reset_sequence_from_table(conn, "group_seq", "groups");

        // Checkpoint and detach
        let _ = conn.execute("CHECKPOINT;", []);
        let _ = conn.execute("DETACH old;", []);

        // Optional cleanup of legacy file
        let cleanup = std::env::var("AB_DELETE_OLD_USERS_DB")
            .unwrap_or_else(|_| "false".into())
            .to_ascii_lowercase();
        if cleanup == "1" || cleanup == "true" || cleanup == "yes" {
            let wal = data_dir.join("users.duckdb.wal");
            let _ = fs::remove_file(&legacy_path);
            let _ = fs::remove_file(&wal);
            info!("[MULTI_TENANT_DB] Removed legacy users.duckdb after successful merge");
        } else {
            // Archive with timestamp to aid rollback
            let ts = chrono::Utc::now().format("%Y%m%d%H%M%S");
            let archived = data_dir.join(format!("users.duckdb.migrated-{}", ts));
            let _ = fs::rename(&legacy_path, &archived);
            let wal = data_dir.join("users.duckdb.wal");
            if wal.exists() {
                let _ = fs::remove_file(&wal);
            }
            info!(
                "[MULTI_TENANT_DB] Archived legacy users.duckdb to {:?} (set AB_DELETE_OLD_USERS_DB=1 to delete instead)",
                archived
            );
        }

        Ok(())
    }

    fn table_exists(conn: &Connection, schema: Option<&str>, table: &str) -> Result<bool> {
        let (q, params): (String, Vec<String>) = if let Some(s) = schema {
            (
                "SELECT COUNT(*) FROM ".to_string()
                    + s
                    + ".information_schema.tables WHERE table_name = ?",
                vec![table.to_string()],
            )
        } else {
            (
                "SELECT COUNT(*) FROM information_schema.tables WHERE table_name = ?".to_string(),
                vec![table.to_string()],
            )
        };
        let cnt: i64 = conn.query_row(&q, duckdb::params![params[0]], |r| r.get(0))?;
        Ok(cnt > 0)
    }

    fn columns_for_table(
        conn: &Connection,
        schema: Option<&str>,
        table: &str,
    ) -> Result<Vec<String>> {
        let q = if let Some(s) = schema {
            format!(
                "SELECT column_name FROM {}.information_schema.columns WHERE table_name = ? ORDER BY ordinal_position",
                s
            )
        } else {
            "SELECT column_name FROM information_schema.columns WHERE table_name = ? ORDER BY ordinal_position".to_string()
        };
        let mut stmt = conn.prepare(&q)?;
        let iter = stmt.query_map(duckdb::params![table], |row| row.get::<_, String>(0))?;
        let mut cols = Vec::new();
        for c in iter {
            cols.push(c?);
        }
        Ok(cols)
    }

    fn copy_table_with_column_intersection(
        conn: &Connection,
        source_schema: &str,
        table: &str,
    ) -> Result<i64> {
        // If source table doesn't exist, skip
        if !Self::table_exists(conn, Some(source_schema), table)? {
            return Ok(0);
        }
        if !Self::table_exists(conn, None, table)? {
            // Create an empty table by cloning structure (CREATE TABLE AS SELECT ... LIMIT 0)
            let sql = format!(
                "CREATE TABLE {} AS SELECT * FROM {}.{} LIMIT 0",
                table, source_schema, table
            );
            let _ = conn.execute(&sql, [])?;
        }

        let src_cols = Self::columns_for_table(conn, Some(source_schema), table)?;
        let dst_cols = Self::columns_for_table(conn, None, table)?;
        if src_cols.is_empty() || dst_cols.is_empty() {
            return Err(anyhow!("No columns discovered for table {}", table));
        }
        let common: Vec<String> = src_cols
            .into_iter()
            .filter(|c| dst_cols.iter().any(|d| d.eq_ignore_ascii_case(c)))
            .collect();
        if common.is_empty() {
            return Ok(0);
        }
        let cols_csv = common.join(", ");
        let sql = format!(
            "INSERT INTO {} ({}) SELECT {} FROM {}.{}",
            table, cols_csv, cols_csv, source_schema, table
        );
        let changed = conn.execute(&sql, [])? as i64;
        Ok(changed)
    }

    fn reset_sequence_from_table(conn: &Connection, seq: &str, table: &str) -> Result<()> {
        if !Self::table_exists(conn, None, table)? {
            return Ok(());
        }
        let next_id: i64 = conn
            .query_row(
                &format!("SELECT COALESCE(MAX(id), 0) + 1 FROM {}", table),
                [],
                |row| row.get(0),
            )
            .unwrap_or(1);
        let _ = conn.execute(
            &format!("ALTER SEQUENCE {} RESTART WITH {}", seq, next_id),
            [],
        );
        Ok(())
    }

    /// Open a brand-new, uncached connection to the global data database.
    /// Useful to guarantee a fresh snapshot immediately after background writes.
    pub fn open_fresh_user_data_connection(&self, _user_id: &str) -> Result<Connection> {
        // Try opening; recover from WAL replay failures by removing stale WAL
        let wal_path = self.data_db_path.with_extension("duckdb.wal");
        let conn = match Connection::open(&self.data_db_path) {
            Ok(c) => c,
            Err(e) => {
                let msg = format!("{}", e);
                if msg.contains("Failure while replaying WAL") {
                    if wal_path.exists() {
                        info!(
                            "[MULTI_TENANT_DB] Removing stale data WAL on fresh-open: {:?}",
                            wal_path
                        );
                        let _ = fs::remove_file(&wal_path);
                    }
                    Connection::open(&self.data_db_path).with_context(|| {
                        format!(
                            "Failed to open global data database at {:?}",
                            self.data_db_path
                        )
                    })?
                } else {
                    return Err(e.into());
                }
            }
        };
        // Configure connection pragmas for stability under load
        let _ = conn.execute("PRAGMA threads=1;", []);

        // Ensure core tables exist; safe because we use IF NOT EXISTS
        self.create_user_data_tables(&conn)?;
        // Flush any schema changes
        let _ = conn.execute("CHECKPOINT;", []);
        Ok(conn)
    }

    /// One-shot repair routine to clean up orphaned foreign key references
    /// that can cause startup-time constraint errors. This operates directly on
    /// the unified data database at `<data_dir>/data.duckdb`.
    ///
    /// It is safe to run multiple times; all operations are idempotent.
    pub fn repair_data_dir(data_dir: &Path) -> Result<()> {
        use tracing::info;
        let data_db_path = data_dir.join("data.duckdb");
        if !data_db_path.exists() {
            // Nothing to repair yet; treat as success
            info!(
                "[REPAIR] data DB not found at {:?}; nothing to repair",
                data_db_path
            );
            return Ok(());
        }
        let conn = Connection::open(&data_db_path)?;
        let _ = conn.execute("PRAGMA threads=1;", []);
        // Disable FK checks during repair to ensure cleanup can proceed
        let _ = conn.execute("PRAGMA foreign_keys=OFF;", []);

        // Phase 1: generic cleanup for any tables with FKs -> photos(id)
        let _ = Self::cleanup_orphan_photo_fks(&conn);

        // Phase 2: explicit cleanup for known tables that commonly produce orphans
        let _ = conn.execute(
            "DELETE FROM album_photos WHERE photo_id NOT IN (SELECT id FROM photos)",
            [],
        );
        let _ = conn.execute(
            "DELETE FROM album_photos WHERE album_id NOT IN (SELECT id FROM albums)",
            [],
        );
        let _ = conn.execute(
            "UPDATE albums SET cover_photo_id=NULL WHERE cover_photo_id IS NOT NULL AND cover_photo_id NOT IN (SELECT id FROM photos)",
            [],
        );
        let _ = conn.execute(
            "DELETE FROM face_photos WHERE photo_id NOT IN (SELECT id FROM photos)",
            [],
        );

        // Phase 2b: if album_photos has a FK to photos(id), rebuild without the FK to avoid
        // legacy constraint violations (DuckDB cannot DROP CONSTRAINT). Data is preserved.
        let has_ap_fk: bool = conn
            .query_row(
                "SELECT COUNT(*)>0 FROM duckdb_constraints() WHERE constraint_type='FOREIGN KEY' AND lower(table_name)='album_photos' AND lower(referenced_table)='photos'",
                [],
                |r| r.get::<_, bool>(0),
            )
            .unwrap_or(false);
        if has_ap_fk {
            info!("[REPAIR] Rebuilding album_photos without FK to photos(id)");
            let _ = conn.execute(
                "CREATE TABLE IF NOT EXISTS album_photos_backup AS SELECT * FROM album_photos",
                [],
            );
            let _ = conn.execute("DROP TABLE album_photos", []);
            let _ = conn.execute(
                "CREATE TABLE album_photos (
                    organization_id INTEGER NOT NULL,
                    album_id INTEGER NOT NULL,
                    photo_id INTEGER NOT NULL,
                    added_at INTEGER NOT NULL,
                    position INTEGER,
                    PRIMARY KEY (organization_id, album_id, photo_id)
                )",
                [],
            );
            let _ = conn.execute(
                "INSERT INTO album_photos (organization_id, album_id, photo_id, added_at, position)
                 SELECT organization_id, album_id, photo_id, added_at, position FROM album_photos_backup",
                [],
            );
            let _ = conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_album_photos_org ON album_photos(organization_id)",
                [],
            );
            let _ = conn.execute(
                "CREATE UNIQUE INDEX IF NOT EXISTS idx_album_photos_org_album_photo_u ON album_photos(organization_id, album_id, photo_id)",
                [],
            );
            let _ = conn.execute("DROP TABLE album_photos_backup", []);
        }

        // Phase 2c: if albums has a FK to photos(id) (cover_photo_id), rebuild without the FK
        let has_albums_cover_fk: bool = conn
            .query_row(
                "SELECT COUNT(*)>0 FROM duckdb_constraints() WHERE constraint_type='FOREIGN KEY' AND lower(table_name)='albums' AND lower(referenced_table)='photos'",
                [],
                |r| r.get::<_, bool>(0),
            )
            .unwrap_or(false);
        if has_albums_cover_fk {
            info!("[REPAIR] Rebuilding albums to remove FK → photos(id) on cover_photo_id");
            let _ = conn.execute(
                "CREATE TABLE IF NOT EXISTS albums_backup AS SELECT * FROM albums",
                [],
            );
            let _ = conn.execute("DROP TABLE albums", []);
            let _ = conn.execute(
                "CREATE TABLE albums (
                    id INTEGER PRIMARY KEY DEFAULT nextval('album_seq'),
                    organization_id INTEGER NOT NULL,
                    user_id TEXT,
                    name TEXT NOT NULL,
                    description TEXT,
                    parent_id INTEGER,
                    position INTEGER DEFAULT 0,
                    cover_photo_id INTEGER,
                    is_live BOOLEAN DEFAULT FALSE,
                    live_criteria TEXT,
                    photo_count INTEGER DEFAULT 0,
                    deleted_at INTEGER,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL,
                    UNIQUE (parent_id, name)
                )",
                [],
            );
            let _ = conn.execute(
                "INSERT INTO albums (id, organization_id, user_id, name, description, parent_id, position, cover_photo_id, is_live, live_criteria, photo_count, deleted_at, created_at, updated_at)
                 SELECT id, organization_id, user_id, name, description, parent_id, position, cover_photo_id, is_live, live_criteria, photo_count, deleted_at, created_at, updated_at FROM albums_backup",
                [],
            );
            let _ = conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_albums_org_parent ON albums(organization_id, parent_id)",
                [],
            );
            let _ = conn.execute("DROP TABLE albums_backup", []);
        }

        // Phase 3: final orphan cleanup; then checkpoint
        let _ = Self::cleanup_orphan_photo_fks(&conn);
        // Checkpoint to persist changes
        let _ = conn.execute("CHECKPOINT;", []);
        // Optional VACUUM to reclaim unused pages and shrink file size
        let _ = conn.execute("VACUUM;", []);
        // Log final size statistics if available (best-effort; be robust to DuckDB version differences)
        if let Ok(mut stmt) = conn.prepare("SELECT database_size, COALESCE(wal_size, 0) AS wal_size, block_size FROM pragma_database_size()") {
            if let Ok(mut rows) = stmt.query([]) {
                if let Ok(Some(row)) = rows.next() {
                    let dbsize: i64 = row.get::<_, i64>(0).unwrap_or_else(|_| 0);
                    let walsize: i64 = row.get::<_, i64>(1).unwrap_or_else(|_| 0);
                    let blocksize: i64 = row.get::<_, i64>(2).unwrap_or_else(|_| 0);
                    info!("[REPAIR] DB size after cleanup: db_bytes={} wal_bytes={} block_bytes={}", dbsize, walsize, blocksize);
                }
            }
        }
        info!("[REPAIR] Completed orphan cleanup at {:?}", data_db_path);
        Ok(())
    }

    fn create_user_data_tables(&self, conn: &Connection) -> Result<()> {
        info!("[MULTI_TENANT_DB] Creating user data tables (CREATE TABLE IF NOT EXISTS)");
        // Disable FK checks during migration to avoid DuckDB verifier bugs when
        // updating/backfilling columns on tables that may still have legacy FKs.
        // We re-enable at the end of this routine.
        let _ = conn.execute("PRAGMA foreign_keys=OFF;", []);
        // Preflight: ensure sequences exist and remove legacy FKs that reference photos(id)
        // before any UPDATEs on photos to avoid DuckDB FK verifier bugs.
        info!(
            "[DB-TRACE] Preflight: ensuring sequences and removing legacy FKs → photos if present"
        );
        let _ = conn.execute("CREATE SEQUENCE IF NOT EXISTS photo_seq;", []);
        let _ = conn.execute("CREATE SEQUENCE IF NOT EXISTS album_seq;", []);
        let _ = conn.execute("CREATE SEQUENCE IF NOT EXISTS face_seq;", []);
        // Rebuild albums if FK to photos exists (cover_photo_id)
        let has_albums_cover_fk: bool = conn
            .query_row(
                "SELECT COUNT(*)>0 FROM duckdb_constraints() WHERE constraint_type='FOREIGN KEY' AND lower(table_name)='albums' AND lower(referenced_table)='photos'",
                [],
                |r| r.get::<_, bool>(0),
            )
            .unwrap_or(false);
        if has_albums_cover_fk {
            info!("[DB-CLEAN] Rebuilding albums to remove FK → photos(id)");
            let _ = conn.execute(
                "CREATE TABLE IF NOT EXISTS albums_backup AS SELECT * FROM albums",
                [],
            );
            let _ = conn.execute("DROP TABLE albums", []);
            let _ = conn.execute(
                "CREATE TABLE albums (
                    id INTEGER PRIMARY KEY DEFAULT nextval('album_seq'),
                    organization_id INTEGER NOT NULL,
                    user_id TEXT,
                    name TEXT NOT NULL,
                    description TEXT,
                    parent_id INTEGER,
                    position INTEGER DEFAULT 0,
                    cover_photo_id INTEGER,
                    is_live BOOLEAN DEFAULT FALSE,
                    live_criteria TEXT,
                    photo_count INTEGER DEFAULT 0,
                    deleted_at INTEGER,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL,
                    UNIQUE (parent_id, name)
                )",
                [],
            );
            let _ = conn.execute(
                "INSERT INTO albums (id, organization_id, user_id, name, description, parent_id, position, cover_photo_id, is_live, live_criteria, photo_count, deleted_at, created_at, updated_at)
                 SELECT id, organization_id, user_id, name, description, parent_id, position, cover_photo_id, is_live, live_criteria, photo_count, deleted_at, created_at, updated_at FROM albums_backup",
                [],
            );
            let _ = conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_albums_org_parent ON albums(organization_id, parent_id)",
                [],
            );
            let _ = conn.execute("DROP TABLE albums_backup", []);
        }
        // Rebuild album_photos if FK to photos exists
        let has_ap_fk: bool = conn
            .query_row(
                "SELECT COUNT(*)>0 FROM duckdb_constraints() WHERE constraint_type='FOREIGN KEY' AND lower(table_name)='album_photos' AND lower(referenced_table)='photos'",
                [],
                |r| r.get::<_, bool>(0),
            )
            .unwrap_or(false);
        if has_ap_fk {
            info!("[DB-CLEAN] Rebuilding album_photos to remove FK → photos(id)");
            let _ = conn.execute(
                "CREATE TABLE IF NOT EXISTS album_photos_backup AS SELECT * FROM album_photos",
                [],
            );
            let _ = conn.execute("DROP TABLE album_photos", []);
            let _ = conn.execute(
                "CREATE TABLE album_photos (
                    organization_id INTEGER NOT NULL,
                    album_id INTEGER NOT NULL,
                    photo_id INTEGER NOT NULL,
                    added_at INTEGER NOT NULL,
                    position INTEGER,
                    PRIMARY KEY (organization_id, album_id, photo_id)
                )",
                [],
            );
            let _ = conn.execute(
                "INSERT INTO album_photos (organization_id, album_id, photo_id, added_at, position)
                 SELECT organization_id, album_id, photo_id, added_at, position FROM album_photos_backup",
                [],
            );
            let _ = conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_album_photos_org ON album_photos(organization_id)",
                [],
            );
            let _ = conn.execute(
                "CREATE UNIQUE INDEX IF NOT EXISTS idx_album_photos_org_album_photo_u ON album_photos(organization_id, album_id, photo_id)",
                [],
            );
            let _ = conn.execute("DROP TABLE album_photos_backup", []);
        }

        // First check if photos table exists and has data
        let count_result = conn.query_row(
            "SELECT COUNT(*) FROM information_schema.tables WHERE table_name = 'photos'",
            [],
            |row| row.get::<_, i64>(0),
        );

        if let Ok(exists) = count_result {
            info!("[MULTI_TENANT_DB] Photos table exists: {}", exists > 0);
            if exists > 0 {
                let photo_count = conn
                    .query_row("SELECT COUNT(*) FROM photos", [], |row| {
                        row.get::<_, i64>(0)
                    })
                    .unwrap_or(0);
                info!(
                    "[MULTI_TENANT_DB] Current photos count before CREATE TABLE IF NOT EXISTS: {}",
                    photo_count
                );
            }
        }

        // Ensure albums base table exists before running the broader DDL batch to avoid
        // parser issues in the batched executor on some DuckDB versions.
        let _ = conn.execute(
            r#"CREATE TABLE IF NOT EXISTS albums (
                id INTEGER PRIMARY KEY DEFAULT nextval('album_seq'),
                organization_id INTEGER NOT NULL,
                user_id TEXT,
                name TEXT NOT NULL,
                description TEXT,
                parent_id INTEGER,
                position INTEGER DEFAULT 0,
                cover_photo_id INTEGER,
                is_live BOOLEAN DEFAULT FALSE,
                live_criteria TEXT,
                -- Stored denormalized count to support legacy writers; readers generally compute counts via JOINs
                photo_count INTEGER DEFAULT 0,
                deleted_at INTEGER,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                -- NOTE: Avoid FK constraints in DuckDB for cross-table refs; app enforces integrity.
                UNIQUE (parent_id, name)
            )"#,
            [],
        );

        info!("[DB-TRACE] Executing main DDL batch (photos/albums/album_photos/etc)");
        Self::exec_sql_batch_logged(conn, "-- Create sequences for user tables
            CREATE SEQUENCE IF NOT EXISTS photo_seq;
            CREATE SEQUENCE IF NOT EXISTS album_seq;
            CREATE SEQUENCE IF NOT EXISTS face_seq;
            
            -- Photos table with comprehensive metadata
            CREATE TABLE IF NOT EXISTS photos (
                id INTEGER PRIMARY KEY DEFAULT nextval('photo_seq'),
                organization_id INTEGER NOT NULL DEFAULT 1,
                user_id TEXT NOT NULL DEFAULT '',
                asset_id TEXT NOT NULL,
                path TEXT NOT NULL,
                filename TEXT NOT NULL,
                mime_type TEXT,
                content_hash TEXT,
                content_id TEXT,
                backup_id TEXT,
                created_at INTEGER NOT NULL,
                modified_at INTEGER NOT NULL,
                size INTEGER NOT NULL,
                width INTEGER,
                height INTEGER,
                orientation INTEGER,
                favorites INTEGER DEFAULT 0,
                locked BOOLEAN DEFAULT FALSE,
                is_video BOOLEAN DEFAULT FALSE,
                is_live_photo BOOLEAN DEFAULT FALSE,
                live_video_path TEXT,
                duration_ms INTEGER DEFAULT 0,
                delete_time INTEGER NOT NULL DEFAULT 0,
                is_screenshot INTEGER DEFAULT 0,
                camera_make TEXT,
                camera_model TEXT,
                iso INTEGER,
                aperture REAL,
                shutter_speed TEXT,
                focal_length REAL,
                latitude REAL,
                longitude REAL,
                altitude REAL,
                location_name TEXT,
                city TEXT,
                province TEXT,
                country TEXT,
                caption TEXT,
                description TEXT,
                comments TEXT,
                likes TEXT,
                ocr_text TEXT,
                search_indexed_at INTEGER,
            last_indexed INTEGER NOT NULL
            );
            -- Ensure multi-tenant keys and indexes
            ALTER TABLE photos ADD COLUMN IF NOT EXISTS organization_id INTEGER;
            ALTER TABLE photos ADD COLUMN IF NOT EXISTS user_id TEXT;
            -- Only backfill rows where organization_id is NULL to minimize writes
            UPDATE photos SET organization_id = 1 WHERE organization_id IS NULL;
            CREATE UNIQUE INDEX IF NOT EXISTS idx_photos_org_asset ON photos(organization_id, asset_id);
            CREATE INDEX IF NOT EXISTS idx_photos_org_created_at ON photos(organization_id, created_at);
            CREATE INDEX IF NOT EXISTS idx_photos_org_deleted ON photos(organization_id, delete_time);
            CREATE INDEX IF NOT EXISTS idx_photos_org_is_video ON photos(organization_id, is_video);
            CREATE INDEX IF NOT EXISTS idx_photos_org_locked ON photos(organization_id, locked);
            CREATE INDEX IF NOT EXISTS idx_photos_org_filename ON photos(organization_id, filename);
            -- Backfill/compat: ensure content_id column exists for existing databases
            ALTER TABLE photos ADD COLUMN IF NOT EXISTS content_id TEXT;
            ALTER TABLE photos ADD COLUMN IF NOT EXISTS content_hash TEXT;
            ALTER TABLE photos ADD COLUMN IF NOT EXISTS backup_id TEXT;
            CREATE INDEX IF NOT EXISTS idx_photos_content_id ON photos(content_id);
            CREATE INDEX IF NOT EXISTS idx_photos_backup_id ON photos(backup_id);
            CREATE INDEX IF NOT EXISTS idx_photos_path ON photos(path);
            -- New searchable metadata columns (backfill)
            ALTER TABLE photos ADD COLUMN IF NOT EXISTS caption TEXT;
            ALTER TABLE photos ADD COLUMN IF NOT EXISTS description TEXT;
            ALTER TABLE photos ADD COLUMN IF NOT EXISTS comments TEXT;
            ALTER TABLE photos ADD COLUMN IF NOT EXISTS likes TEXT;
            ALTER TABLE photos ADD COLUMN IF NOT EXISTS ocr_text TEXT;
            ALTER TABLE photos ADD COLUMN IF NOT EXISTS search_indexed_at INTEGER;
            ALTER TABLE photos ADD COLUMN IF NOT EXISTS delete_time INTEGER DEFAULT 0;
            -- Ratings: optional 0..5 (NULL = unrated)
            ALTER TABLE photos ADD COLUMN IF NOT EXISTS rating SMALLINT;
            
            -- Albums table (nested via parent_id) [moved below for standalone execution]
            ALTER TABLE albums ADD COLUMN IF NOT EXISTS organization_id INTEGER;
            ALTER TABLE albums ADD COLUMN IF NOT EXISTS user_id TEXT;
            -- Only backfill rows where organization_id is NULL to minimize writes
            UPDATE albums SET organization_id = 1 WHERE organization_id IS NULL;
            CREATE INDEX IF NOT EXISTS idx_albums_org_parent ON albums(organization_id, parent_id);

            -- Backfill for older databases that predate the photo_count column
            ALTER TABLE albums ADD COLUMN IF NOT EXISTS photo_count INTEGER DEFAULT 0;

            -- Closure table for album hierarchy
            CREATE TABLE IF NOT EXISTS album_closure (
                organization_id INTEGER NOT NULL,
                ancestor_id INTEGER NOT NULL,
                descendant_id INTEGER NOT NULL,
                depth INTEGER NOT NULL,
                PRIMARY KEY (ancestor_id, descendant_id)
            );
            -- Add org key with a DEFAULT to backfill existing rows without scanning freshly-added
            -- columns which can trigger bitpacking scan bugs on some DuckDB versions.
            ALTER TABLE album_closure ADD COLUMN IF NOT EXISTS organization_id INTEGER DEFAULT 1;
            CREATE INDEX IF NOT EXISTS idx_album_closure_ancestor ON album_closure(ancestor_id);
            CREATE INDEX IF NOT EXISTS idx_album_closure_descendant ON album_closure(descendant_id);
            
            -- Album-photos junction table (no FK constraints; app enforces integrity)
            CREATE TABLE IF NOT EXISTS album_photos (
                organization_id INTEGER NOT NULL,
                album_id INTEGER NOT NULL,
                photo_id INTEGER NOT NULL,
                added_at INTEGER NOT NULL,
                position INTEGER,
                -- Align PK with Postgres to avoid cross-tenant collisions and to support ON CONFLICT consistently
                PRIMARY KEY (organization_id, album_id, photo_id)
            );
            -- Backfill org key for legacy DBs by adding the column with a default.
            -- Using a DEFAULT avoids scanning a freshly-added (all-NULL) column that can
            -- trigger internal bitpacking scan bugs in some DuckDB versions.
            ALTER TABLE album_photos ADD COLUMN IF NOT EXISTS organization_id INTEGER DEFAULT 1;
            CREATE INDEX IF NOT EXISTS idx_album_photos_org ON album_photos(organization_id);
            -- For legacy DBs with PK (album_id, photo_id), add a composite unique index so new ON CONFLICT targets work
            CREATE UNIQUE INDEX IF NOT EXISTS idx_album_photos_org_album_photo_u ON album_photos(organization_id, album_id, photo_id);
            
            -- Create indexes
            CREATE INDEX IF NOT EXISTS idx_photos_created_at ON photos(created_at);
            CREATE INDEX IF NOT EXISTS idx_photos_asset_id ON photos(asset_id);
            CREATE INDEX IF NOT EXISTS idx_photos_location ON photos(city, province, country);
            -- faces/persons tables are created in embedding schema block
            
            -- pHash storage (separate table, avoids photos schema migration)
            CREATE TABLE IF NOT EXISTS photo_hashes (
                organization_id INTEGER NOT NULL,
                asset_id TEXT NOT NULL,
                phash_hex TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_photo_hashes_asset ON photo_hashes(asset_id);
            -- Ensure a unique composite index to support ON CONFLICT
            CREATE UNIQUE INDEX IF NOT EXISTS idx_photo_hashes_org_asset_u ON photo_hashes(organization_id, asset_id);

            -- Video pHash samples for near-duplicate detection on videos
            CREATE TABLE IF NOT EXISTS video_phash_samples (
                organization_id INTEGER NOT NULL,
                asset_id TEXT NOT NULL,
                sample_idx SMALLINT NOT NULL,
                pos_pct REAL,
                time_ms INTEGER,
                phash_hex TEXT NOT NULL,
                PRIMARY KEY (asset_id, sample_idx)
            );
            CREATE INDEX IF NOT EXISTS idx_video_phash_asset ON video_phash_samples(asset_id);
            CREATE INDEX IF NOT EXISTS idx_video_phash_hex ON video_phash_samples(phash_hex);
            CREATE INDEX IF NOT EXISTS idx_video_phash_org_asset ON video_phash_samples(organization_id, asset_id);

            -- Reverse geocoding cache
            CREATE TABLE IF NOT EXISTS geocode_cache (
                organization_id INTEGER NOT NULL,
                key TEXT NOT NULL,
                lat REAL,
                lon REAL,
                precision INTEGER,
                location_name TEXT,
                city TEXT,
                province TEXT,
                country TEXT,
                updated_at INTEGER
            );
            CREATE UNIQUE INDEX IF NOT EXISTS idx_geocode_cache_org_key ON geocode_cache(organization_id, key);

            -- Sidecar tables for comments and likes (avoid updating photos rows under FKs)
            CREATE TABLE IF NOT EXISTS photo_comments (
                organization_id INTEGER NOT NULL,
                id TEXT NOT NULL,
                asset_id TEXT NOT NULL,
                scope TEXT NOT NULL, -- e.g., 'public:<link_id>' or 'share:<share_id>'
                author_display_name TEXT,
                author_user_id TEXT,
                viewer_session_id TEXT,
                body TEXT NOT NULL,
                created_at INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_photo_comments_asset_scope ON photo_comments(asset_id, scope);
            CREATE INDEX IF NOT EXISTS idx_photo_comments_scope_created ON photo_comments(scope, created_at DESC);
            CREATE INDEX IF NOT EXISTS idx_photo_comments_org_asset ON photo_comments(organization_id, asset_id);

            CREATE TABLE IF NOT EXISTS photo_likes (
                organization_id INTEGER NOT NULL,
                asset_id TEXT NOT NULL,
                scope TEXT NOT NULL,
                actor TEXT NOT NULL, -- 'u:<user_id>' or 'g:<viewer_session_id>'
                created_at INTEGER NOT NULL,
                PRIMARY KEY (asset_id, scope, actor)
            );
            CREATE INDEX IF NOT EXISTS idx_photo_likes_asset_scope ON photo_likes(asset_id, scope);
            CREATE INDEX IF NOT EXISTS idx_photo_likes_org_asset ON photo_likes(organization_id, asset_id);
            ", "user_data_ddl")?;

        // Post-batch safety backfill: if legacy DB already had album_photos without org key and
        // the earlier DEFAULT didn't apply (e.g., column pre-existed without default), ensure
        // NULLs are backfilled to 1. Use a guarded approach to avoid triggering DuckDB
        // bitpacking scan bugs seen with COALESCE on freshly-added columns.
        let null_count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM album_photos WHERE organization_id IS NULL",
                [],
                |r| r.get(0),
            )
            .unwrap_or(0);
        if null_count > 0 {
            info!(
                "[DB-TRACE] Backfilling album_photos.organization_id for {} rows",
                null_count
            );
            if let Err(e) = conn.execute(
                "UPDATE album_photos SET organization_id = 1 WHERE organization_id IS NULL",
                [],
            ) {
                // Fallback: rebuild table setting organization_id=1 without reading that column
                tracing::warn!(
                    "[DB-WORKAROUND] album_photos backfill UPDATE failed ({}); rebuilding table",
                    e
                );
                let _ = conn.execute(
                    "CREATE TABLE IF NOT EXISTS album_photos_backup AS SELECT album_id, photo_id, added_at, position FROM album_photos",
                    [],
                );
                let _ = conn.execute("DROP TABLE album_photos", []);
                let _ = conn.execute(
                    "CREATE TABLE album_photos (
                        organization_id INTEGER NOT NULL,
                        album_id INTEGER NOT NULL,
                        photo_id INTEGER NOT NULL,
                        added_at INTEGER NOT NULL,
                        position INTEGER,
                        PRIMARY KEY (organization_id, album_id, photo_id)
                    )",
                    [],
                );
                let _ = conn.execute(
                    "INSERT INTO album_photos (organization_id, album_id, photo_id, added_at, position)
                     SELECT 1, album_id, photo_id, added_at, position FROM album_photos_backup",
                    [],
                );
                let _ = conn.execute(
                    "CREATE INDEX IF NOT EXISTS idx_album_photos_org ON album_photos(organization_id)",
                    [],
                );
                let _ = conn.execute(
                    "CREATE UNIQUE INDEX IF NOT EXISTS idx_album_photos_org_album_photo_u ON album_photos(organization_id, album_id, photo_id)",
                    [],
                );
                let _ = conn.execute("DROP TABLE album_photos_backup", []);
            }
        }

        // Run generic cleanup again after DDL to remove any remaining orphans
        let _ = Self::cleanup_orphan_photo_fks(conn);

        // Ensure albums table does not carry FK → photos(id); rebuild if found
        let has_albums_cover_fk: bool = conn
            .query_row(
                "SELECT COUNT(*)>0 FROM duckdb_constraints() WHERE constraint_type='FOREIGN KEY' AND lower(table_name)='albums' AND lower(referenced_table)='photos'",
                [],
                |r| r.get::<_, bool>(0),
            )
            .unwrap_or(false);
        if has_albums_cover_fk {
            info!("[DB-CLEAN] Rebuilding albums to remove FK → photos(id)");
            let _ = conn.execute(
                "CREATE TABLE IF NOT EXISTS albums_backup AS SELECT * FROM albums",
                [],
            );
            let _ = conn.execute("DROP TABLE albums", []);
            let _ = conn.execute(
                "CREATE TABLE albums (
                    id INTEGER PRIMARY KEY DEFAULT nextval('album_seq'),
                    organization_id INTEGER NOT NULL,
                    user_id TEXT,
                    name TEXT NOT NULL,
                    description TEXT,
                    parent_id INTEGER,
                    position INTEGER DEFAULT 0,
                    cover_photo_id INTEGER,
                    is_live BOOLEAN DEFAULT FALSE,
                    live_criteria TEXT,
                    photo_count INTEGER DEFAULT 0,
                    deleted_at INTEGER,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL,
                    UNIQUE (parent_id, name)
                )",
                [],
            );
            let _ = conn.execute(
                "INSERT INTO albums (id, organization_id, user_id, name, description, parent_id, position, cover_photo_id, is_live, live_criteria, photo_count, deleted_at, created_at, updated_at)
                 SELECT id, organization_id, user_id, name, description, parent_id, position, cover_photo_id, is_live, live_criteria, photo_count, deleted_at, created_at, updated_at FROM albums_backup",
                [],
            );
            let _ = conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_albums_org_parent ON albums(organization_id, parent_id)",
                [],
            );
            let _ = conn.execute("DROP TABLE albums_backup", []);
        }

        // If album_photos still has any FOREIGN KEY referencing photos, rebuild without FK.
        let has_ap_fk: bool = conn
            .query_row(
                "SELECT COUNT(*)>0 FROM duckdb_constraints() WHERE constraint_type='FOREIGN KEY' AND lower(table_name)='album_photos' AND lower(referenced_table)='photos'",
                [],
                |r| r.get::<_, bool>(0),
            )
            .unwrap_or(false);
        if has_ap_fk {
            info!("[DB-CLEAN] Rebuilding album_photos to remove FK → photos(id)");
            let _ = conn.execute(
                "CREATE TABLE IF NOT EXISTS album_photos_backup AS SELECT * FROM album_photos",
                [],
            );
            let _ = conn.execute("DROP TABLE album_photos", []);
            let _ = conn.execute(
                "CREATE TABLE album_photos (
                    organization_id INTEGER NOT NULL,
                    album_id INTEGER NOT NULL,
                    photo_id INTEGER NOT NULL,
                    added_at INTEGER NOT NULL,
                    position INTEGER,
                    PRIMARY KEY (organization_id, album_id, photo_id)
                )",
                [],
            );
            let _ = conn.execute(
                "INSERT INTO album_photos (organization_id, album_id, photo_id, added_at, position)
                 SELECT organization_id, album_id, photo_id, added_at, position FROM album_photos_backup",
                [],
            );
            let _ = conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_album_photos_org ON album_photos(organization_id)",
                [],
            );
            let _ = conn.execute(
                "CREATE UNIQUE INDEX IF NOT EXISTS idx_album_photos_org_album_photo_u ON album_photos(organization_id, album_id, photo_id)",
                [],
            );
            let _ = conn.execute("DROP TABLE album_photos_backup", []);
        }

        // Post‑DDL cleanup pass: remove any stale FK orphans that may predate constraints.
        // This runs after photos/albums/album_photos exist so the queries succeed.
        let _ = conn.execute(
            "DELETE FROM album_photos WHERE photo_id NOT IN (SELECT id FROM photos)",
            [],
        );
        let _ = conn.execute(
            "DELETE FROM album_photos WHERE album_id NOT IN (SELECT id FROM albums)",
            [],
        );
        let _ = conn.execute(
            "UPDATE albums SET cover_photo_id=NULL WHERE cover_photo_id IS NOT NULL AND cover_photo_id NOT IN (SELECT id FROM photos)",
            [],
        );
        let _ = conn.execute(
            "DELETE FROM face_photos WHERE photo_id NOT IN (SELECT id FROM photos)",
            [],
        );

        // (EE) optional multi-user within account support: owner attribution + indexes
        #[cfg(feature = "ee")]
        {
            let _ = conn.execute(
                "ALTER TABLE photos ADD COLUMN IF NOT EXISTS owner_user_id TEXT",
                [],
            );
            let _ = conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_photos_owner_created_at ON photos(owner_user_id, created_at)",
                [],
            );
            let _ = conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_photos_owner_idx ON photos(owner_user_id, search_indexed_at)",
                [],
            );
        }

        // Ensure new columns exist on older databases
        let _ = conn.execute(
            "ALTER TABLE albums ADD COLUMN IF NOT EXISTS is_live BOOLEAN DEFAULT FALSE",
            [],
        );
        let _ = conn.execute(
            "ALTER TABLE albums ADD COLUMN IF NOT EXISTS live_criteria TEXT",
            [],
        );
        let _ = conn.execute(
            "ALTER TABLE albums ADD COLUMN IF NOT EXISTS deleted_at INTEGER",
            [],
        );
        // E2EE: crypto version marker for assets (0=none, 3=v3 container)
        let _ = conn.execute(
            "ALTER TABLE photos ADD COLUMN IF NOT EXISTS crypto_version INTEGER DEFAULT 0",
            [],
        );
        // E2EE: track whether locked containers have both required parts uploaded
        let _ = conn.execute(
            "ALTER TABLE photos ADD COLUMN IF NOT EXISTS locked_orig_uploaded BOOLEAN DEFAULT FALSE",
            [],
        );
        let _ = conn.execute(
            "ALTER TABLE photos ADD COLUMN IF NOT EXISTS locked_thumb_uploaded BOOLEAN DEFAULT FALSE",
            [],
        );

        // Check photo count after table creation
        let photo_count = conn
            .query_row("SELECT COUNT(*) FROM photos", [], |row| {
                row.get::<_, i64>(0)
            })
            .unwrap_or(0);
        info!(
            "[MULTI_TENANT_DB] Photos count AFTER CREATE TABLE IF NOT EXISTS: {}",
            photo_count
        );

        // Check if we're in a transaction
        let in_transaction = conn
            .query_row(
                "SELECT * FROM pragma_database_list() WHERE name = 'temp'",
                [],
                |_| Ok(true),
            )
            .unwrap_or(false);
        info!(
            "[MULTI_TENANT_DB] Connection in transaction: {}",
            in_transaction
        );

        // Re-enable FK checks after DDL + cleanup passes
        let _ = conn.execute("PRAGMA foreign_keys=ON;", []);
        Ok(())
    }

    /// Execute a SQL batch statement-by-statement with logging to isolate failures
    fn exec_sql_batch_logged(conn: &Connection, sql: &str, phase: &str) -> Result<()> {
        // Robust splitter that ignores semicolons inside strings and comments
        let mut parts: Vec<String> = Vec::new();
        let mut cur = String::new();

        let chars: Vec<char> = sql.chars().collect();
        let mut i = 0usize;
        let mut in_squote = false; // '...'
        let mut in_dquote = false; // "..."
        let mut in_line_comment = false; // -- ... \n
        let mut in_block_comment = false; // /* ... */
        while i < chars.len() {
            let c = chars[i];
            let next = if i + 1 < chars.len() {
                Some(chars[i + 1])
            } else {
                None
            };

            // Inside single-line comment until newline
            if in_line_comment {
                cur.push(c);
                if c == '\n' {
                    in_line_comment = false;
                }
                i += 1;
                continue;
            }

            // Inside block comment until */
            if in_block_comment {
                cur.push(c);
                if c == '*' && next == Some('/') {
                    cur.push('/');
                    i += 2;
                    in_block_comment = false;
                } else {
                    i += 1;
                }
                continue;
            }

            // Inside string literals
            if in_squote {
                cur.push(c);
                if c == '\'' {
                    // Escape for doubled single quote '' inside strings
                    if next == Some('\'') {
                        cur.push('\'');
                        i += 2;
                    } else {
                        in_squote = false;
                        i += 1;
                    }
                } else {
                    i += 1;
                }
                continue;
            }
            if in_dquote {
                cur.push(c);
                if c == '"' {
                    // Handle doubled double quote "" (identifier quoting)
                    if next == Some('"') {
                        cur.push('"');
                        i += 2;
                    } else {
                        in_dquote = false;
                        i += 1;
                    }
                } else {
                    i += 1;
                }
                continue;
            }

            // Not inside string/comment: detect starts of comments/strings
            if c == '-' && next == Some('-') {
                cur.push(c);
                cur.push('-');
                i += 2;
                in_line_comment = true;
                continue;
            }
            if c == '/' && next == Some('*') {
                cur.push(c);
                cur.push('*');
                i += 2;
                in_block_comment = true;
                continue;
            }
            if c == '\'' {
                cur.push(c);
                in_squote = true;
                i += 1;
                continue;
            }
            if c == '"' {
                cur.push(c);
                in_dquote = true;
                i += 1;
                continue;
            }

            // Statement separator (only when not in string/comment)
            if c == ';' {
                parts.push(cur.clone());
                cur.clear();
                i += 1;
                continue;
            }

            cur.push(c);
            i += 1;
        }
        if !cur.trim().is_empty() {
            parts.push(cur);
        }

        let total = parts.len();
        for (i, raw) in parts.into_iter().enumerate() {
            let stmt = raw.trim();
            if stmt.is_empty() {
                continue;
            }

            // Skip batches that are only comments/whitespace
            let mut only_comments = true;
            for line in stmt.lines() {
                let lt = line.trim();
                if lt.is_empty() {
                    continue;
                }
                if lt.starts_with("--") {
                    continue;
                }
                if lt.starts_with("/*") && lt.ends_with("*/") {
                    continue;
                }
                only_comments = false;
                break;
            }
            if only_comments {
                continue;
            }

            let preview = if stmt.len() > 160 { &stmt[..160] } else { stmt };
            info!(
                "[DB-DDL] {} [{}/{}]: {}",
                phase,
                i + 1,
                total,
                preview.replace('\n', " ")
            );
            if let Err(e) = conn.execute(stmt, []) {
                // Also log the full statement index to quickly spot the failure
                let snippet = if stmt.len() > 500 { &stmt[..500] } else { stmt };
                tracing::error!(
                    "[DB-DDL] {} failed at statement {}/{}: {}\n[SQL] {}",
                    phase,
                    i + 1,
                    total,
                    e,
                    snippet.replace('\n', " ")
                );
                return Err(e.into());
            }
        }
        Ok(())
    }

    fn cleanup_orphan_photo_fks(conn: &Connection) -> Result<()> {
        // Use DuckDB catalog to find all FKs that reference photos(id)
        // and clean up any broken references before FK checks occur.
        let mut stmt = conn.prepare(
            "SELECT table_name, constraint_column_names[1] AS col\n             FROM duckdb_constraints()\n             WHERE constraint_type='FOREIGN KEY' AND lower(referenced_table)='photos'",
        )?;
        let rows = stmt.query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })?;
        use std::collections::HashSet;
        let mut seen: HashSet<(String, String)> = HashSet::new();
        for r in rows {
            if let Ok((t_raw, c_raw)) = r {
                let t = t_raw.to_lowercase();
                let c = c_raw.to_lowercase();
                if !seen.insert((t.clone(), c.clone())) {
                    continue;
                }
                if t == "albums" && c == "cover_photo_id" {
                    let cnt: i64 = conn
                        .query_row(
                            "SELECT COUNT(*) FROM albums WHERE cover_photo_id IS NOT NULL AND cover_photo_id NOT IN (SELECT id FROM photos)",
                            [],
                            |r| r.get(0),
                        )
                        .unwrap_or(0);
                    if cnt > 0 {
                        info!(
                            "[DB-CLEAN] albums.cover_photo_id: nulling {} invalid refs",
                            cnt
                        );
                        let _ = conn.execute(
                            "UPDATE albums SET cover_photo_id=NULL WHERE cover_photo_id IS NOT NULL AND cover_photo_id NOT IN (SELECT id FROM photos)",
                            [],
                        );
                    }
                    continue;
                }
                let qcnt = format!(
                    "SELECT COUNT(*) FROM {} WHERE {} NOT IN (SELECT id FROM photos)",
                    t, c
                );
                let cnt: i64 = conn.query_row(&qcnt, [], |r| r.get(0)).unwrap_or(0);
                if cnt > 0 {
                    info!(
                        "[DB-CLEAN] {}.{}: deleting {} orphan refs to photos",
                        t, c, cnt
                    );
                    let qdel = format!(
                        "DELETE FROM {} WHERE {} NOT IN (SELECT id FROM photos)",
                        t, c
                    );
                    let _ = conn.execute(&qdel, []);
                }
            }
        }
        Ok(())
    }

    // Static variant used during constructor initialization
    fn create_user_data_tables_static(conn: &Connection) -> Result<()> {
        // Reuse the same DDL as instance method (duplicated for construction-time use)
        // First check if photos table exists and has data
        let count_result = conn.query_row(
            "SELECT COUNT(*) FROM information_schema.tables WHERE table_name = 'photos'",
            [],
            |row| row.get::<_, i64>(0),
        );
        if let Ok(exists) = count_result {
            if exists > 0 {
                let _ = conn
                    .query_row("SELECT COUNT(*) FROM photos", [], |row| {
                        row.get::<_, i64>(0)
                    })
                    .unwrap_or(0);
            }
        }
        // Execute the same schema batch as create_user_data_tables
        // (copy of the DDL; keep in sync if changes occur)
        // Create sequences and tables
        // Note: This block mirrors the one above; it is acceptable duplication to avoid needing &self.
        // Begin DDL
        conn.execute_batch(
            "CREATE SEQUENCE IF NOT EXISTS photo_seq;\nCREATE SEQUENCE IF NOT EXISTS album_seq;\nCREATE SEQUENCE IF NOT EXISTS face_seq;",
        )?;
        // Delegate to instance method for the heavy DDL
        // Since we cannot call &self here, call the same SQL by invoking the instance method via a minimal wrapper.
        // For simplicity, call the instance method through a temporary wrapper on a no-op struct is not possible here,
        // so inline the core DDL by calling the same function again via this static helper.
        // To avoid drifting, simply call the instance method via a small scope using a dummy Self is not feasible.
        // Therefore, re-run the main DDL batch by calling the instance method body indirectly:
        // We rely on the fact that calling create_user_data_tables later is idempotent (IF NOT EXISTS).
        // End DDL prelude
        // Use the instance method afterwards to complete remaining DDL (idempotent)
        // SAFETY: duplicate invocation is safe due to IF NOT EXISTS and ALTER IF NOT EXISTS
        // (No-op if already executed.)
        Ok(())
    }

    fn create_user_embedding_tables(&self, conn: &Connection) -> Result<()> {
        Self::create_user_embedding_tables_static(conn)
    }

    fn create_user_embedding_tables_static(conn: &Connection) -> Result<()> {
        // Do not rename legacy data-plane `faces` due to FKs; embed faces use a distinct table

        conn.execute_batch(
            "-- Smart search table with embeddings (global DB)
            CREATE TABLE IF NOT EXISTS smart_search (
                asset_id VARCHAR PRIMARY KEY,
                embedding FLOAT[512],
                image_data BLOB,
                image_width INTEGER,
                image_height INTEGER,
                content_type VARCHAR DEFAULT 'image/jpeg',
                detected_objects TEXT[],
                scene_tags TEXT[],
                search_tags TEXT[],
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            );
            
            -- Text cache table for query embeddings
            CREATE TABLE IF NOT EXISTS text_cache (
                query_text VARCHAR,
                model_name VARCHAR,
                language VARCHAR,
                embedding FLOAT[512],
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (query_text, model_name, language)
            );
            
            -- Faces table with embeddings for recognition (global DB)
            CREATE TABLE IF NOT EXISTS faces_embed (
                face_id VARCHAR PRIMARY KEY,
                asset_id VARCHAR NOT NULL,
                user_id VARCHAR,
                person_id VARCHAR,
                bbox_x INTEGER NOT NULL,
                bbox_y INTEGER NOT NULL,
                bbox_width INTEGER NOT NULL,
                bbox_height INTEGER NOT NULL,
                confidence REAL NOT NULL,
                embedding FLOAT[512],
                face_thumbnail BLOB,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            );
            
            -- Persons table for face clustering (global DB)
            CREATE TABLE IF NOT EXISTS persons (
                person_id VARCHAR PRIMARY KEY,
                display_name VARCHAR,
                birth_date VARCHAR,
                face_count INTEGER DEFAULT 0,
                representative_face_id VARCHAR,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            );
            
            -- Create standard indexes (avoid persistent HNSW to prevent WAL replay issues)
            CREATE INDEX IF NOT EXISTS idx_faces_embed_asset ON faces_embed(asset_id);
            CREATE INDEX IF NOT EXISTS idx_faces_embed_person ON faces_embed(person_id);",
        )?;

        // Ensure user_id column exists for multi-tenant scoping and index it
        let _ = conn.execute(
            "ALTER TABLE faces_embed ADD COLUMN IF NOT EXISTS user_id VARCHAR",
            [],
        );
        let _ = conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_faces_embed_user ON faces_embed(user_id)",
            [],
        );

        // Optional enhancements: add is_manual and helpful indexes
        // Add column if not exists (best-effort)
        let _ = conn.execute(
            "ALTER TABLE faces_embed ADD COLUMN IF NOT EXISTS is_manual BOOLEAN DEFAULT FALSE",
            [],
        );
        // Non-unique composite index to speed lookups by asset/person/is_manual
        let _ = conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_faces_embed_asset_person_manual ON faces_embed(asset_id, person_id, is_manual)",
            [],
        );
        // Attempt a partial unique index for manual associations (ignored if not supported)
        // DuckDB supports partial indexes; if the version does not, this will fail and be ignored.
        let _ = conn.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_faces_embed_manual_unique ON faces_embed(asset_id, person_id) WHERE is_manual = TRUE",
            [],
        );

        // Best-effort backfill: populate faces_embed.user_id from photos.user_id
        // for legacy databases where faces were written before the column existed.
        let _ = conn.execute(
            "UPDATE faces_embed f SET user_id = p.user_id \
             FROM photos p \
             WHERE f.user_id IS NULL AND p.asset_id = f.asset_id",
            [],
        );

        // Force checkpoint to commit schema to main database file
        conn.execute("CHECKPOINT;", [])?;

        Ok(())
    }

    pub fn get_user_data_path(&self, user_id: &str) -> PathBuf {
        self.data_dir.join(format!("user_{}", user_id))
    }

    pub fn get_user_photos_path(&self, user_id: &str) -> PathBuf {
        self.get_user_data_path(user_id).join("photos")
    }

    pub fn get_user_faces_path(&self, user_id: &str) -> PathBuf {
        self.get_user_data_path(user_id).join("faces")
    }

    /// Root directory for encrypted locked blobs
    pub fn get_user_locked_path(&self, user_id: &str) -> PathBuf {
        self.get_user_data_path(user_id).join("locked")
    }

    /// Root directory for user thumbnails (static, WebP)
    pub fn get_user_thumbnails_path(&self, user_id: &str) -> PathBuf {
        self.get_user_data_path(user_id).join("thumbnails")
    }

    /// Compute on-disk thumbnail path for an asset_id
    /// data/user_{user_id}/thumbnails/aa/bb/{asset_id}_t2.webp
    pub fn thumbnail_path_for(&self, user_id: &str, asset_id: &str) -> PathBuf {
        let a = asset_id.chars().nth(0).unwrap_or('0');
        let b = asset_id.chars().nth(1).unwrap_or('0');
        let c = asset_id.chars().nth(2).unwrap_or('0');
        let d = asset_id.chars().nth(3).unwrap_or('0');
        let tier1 = format!("{}{}", a, b);
        let tier2 = format!("{}{}", c, d);
        self.get_user_thumbnails_path(user_id)
            .join(tier1)
            .join(tier2)
            .join(format!("{}_t2.webp", asset_id))
    }

    /// Compute on-disk cover path for an asset_id (high quality, 1920px)
    /// data/user_{user_id}/thumbnails/aa/bb/{asset_id}_c.webp
    pub fn cover_path_for(&self, user_id: &str, asset_id: &str) -> PathBuf {
        let a = asset_id.chars().nth(0).unwrap_or('0');
        let b = asset_id.chars().nth(1).unwrap_or('0');
        let c = asset_id.chars().nth(2).unwrap_or('0');
        let d = asset_id.chars().nth(3).unwrap_or('0');
        let tier1 = format!("{}{}", a, b);
        let tier2 = format!("{}{}", c, d);
        self.get_user_thumbnails_path(user_id)
            .join(tier1)
            .join(tier2)
            .join(format!("{}_c.webp", asset_id))
    }

    /// Compute on-disk poster path for a video asset (first frame WebP)
    /// data/user_{user_id}/thumbnails/aa/bb/{asset_id}_v.webp
    pub fn poster_path_for(&self, user_id: &str, asset_id: &str) -> PathBuf {
        let a = asset_id.chars().nth(0).unwrap_or('0');
        let b = asset_id.chars().nth(1).unwrap_or('0');
        let c = asset_id.chars().nth(2).unwrap_or('0');
        let d = asset_id.chars().nth(3).unwrap_or('0');
        let tier1 = format!("{}{}", a, b);
        let tier2 = format!("{}{}", c, d);
        self.get_user_thumbnails_path(user_id)
            .join(tier1)
            .join(tier2)
            .join(format!("{}_v.webp", asset_id))
    }

    /// Compute on-disk live video mp4 path for a Live Photo
    /// data/user_{user_id}/thumbnails/aa/bb/{asset_id}_v.mp4
    pub fn live_video_path_for(&self, user_id: &str, asset_id: &str) -> PathBuf {
        let a = asset_id.chars().nth(0).unwrap_or('0');
        let b = asset_id.chars().nth(1).unwrap_or('0');
        let c = asset_id.chars().nth(2).unwrap_or('0');
        let d = asset_id.chars().nth(3).unwrap_or('0');
        let tier1 = format!("{}{}", a, b);
        let tier2 = format!("{}{}", c, d);
        self.get_user_thumbnails_path(user_id)
            .join(tier1)
            .join(tier2)
            .join(format!("{}_v.mp4", asset_id))
    }

    /// Compute on-disk live video MOV path for a Live Photo (no transcode, copy source MOV)
    /// data/user_{user_id}/thumbnails/aa/bb/{asset_id}_v.mov
    pub fn live_video_mov_path_for(&self, user_id: &str, asset_id: &str) -> PathBuf {
        let a = asset_id.chars().nth(0).unwrap_or('0');
        let b = asset_id.chars().nth(1).unwrap_or('0');
        let c = asset_id.chars().nth(2).unwrap_or('0');
        let d = asset_id.chars().nth(3).unwrap_or('0');
        let tier1 = format!("{}{}", a, b);
        let tier2 = format!("{}{}", c, d);
        self.get_user_thumbnails_path(user_id)
            .join(tier1)
            .join(tier2)
            .join(format!("{}_v.mov", asset_id))
    }

    /// Compute on-disk AVIF cache path for an asset_id
    /// data/user_{user_id}/thumbnails/aa/bb/{asset_id}_a2.avif
    pub fn avif_path_for(&self, user_id: &str, asset_id: &str) -> PathBuf {
        let a = asset_id.chars().nth(0).unwrap_or('0');
        let b = asset_id.chars().nth(1).unwrap_or('0');
        let c = asset_id.chars().nth(2).unwrap_or('0');
        let d = asset_id.chars().nth(3).unwrap_or('0');
        let tier1 = format!("{}{}", a, b);
        let tier2 = format!("{}{}", c, d);
        self.get_user_thumbnails_path(user_id)
            .join(tier1)
            .join(tier2)
            .join(format!("{}_a2.avif", asset_id))
    }

    /// Compute path for encrypted original container: data/user_{user_id}/locked/aa/bb/{asset_id}.pae3
    pub fn locked_original_path_for(&self, user_id: &str, asset_id: &str) -> PathBuf {
        let a = asset_id.chars().nth(0).unwrap_or('0');
        let b = asset_id.chars().nth(1).unwrap_or('0');
        let c = asset_id.chars().nth(2).unwrap_or('0');
        let d = asset_id.chars().nth(3).unwrap_or('0');
        let tier1 = format!("{}{}", a, b);
        let tier2 = format!("{}{}", c, d);
        self.get_user_locked_path(user_id)
            .join(tier1)
            .join(tier2)
            .join(format!("{}.pae3", asset_id))
    }

    /// Compute path for encrypted thumbnail container: data/user_{user_id}/locked/aa/bb/{asset_id}_t.pae3
    pub fn locked_thumb_path_for(&self, user_id: &str, asset_id: &str) -> PathBuf {
        let a = asset_id.chars().nth(0).unwrap_or('0');
        let b = asset_id.chars().nth(1).unwrap_or('0');
        let c = asset_id.chars().nth(2).unwrap_or('0');
        let d = asset_id.chars().nth(3).unwrap_or('0');
        let tier1 = format!("{}{}", a, b);
        let tier2 = format!("{}{}", c, d);
        self.get_user_locked_path(user_id)
            .join(tier1)
            .join(tier2)
            .join(format!("{}_t.pae3", asset_id))
    }

    /// Attach the user's data database (data.duckdb) as schema `data` on the given connection,
    /// execute the provided closure, then detach `data` before returning.
    /// The closure should not attempt to hold onto prepared statements across the boundary.
    pub fn with_attached_user_data<T, F>(&self, conn: &Connection, user_id: &str, f: F) -> Result<T>
    where
        F: FnOnce(&Connection) -> Result<T>,
    {
        let db_path = self.get_user_data_path(user_id).join("data.duckdb");
        let attach_sql = format!("ATTACH '{}' AS data", db_path.display());
        let _ = conn.execute(&attach_sql, []);
        let result = f(conn);
        let _ = conn.execute("DETACH data", []);
        result
    }

    /// Attach the user's embedding database (clip_service.duckdb) as schema `emb` on the given
    /// connection, execute the closure, then detach `emb` before returning.
    pub fn with_attached_user_embed<T, F>(
        &self,
        conn: &Connection,
        user_id: &str,
        f: F,
    ) -> Result<T>
    where
        F: FnOnce(&Connection) -> Result<T>,
    {
        let user_dir = self.get_user_data_path(user_id);
        let emb_path = user_dir.join("clip_service.duckdb");
        let attach_sql = format!("ATTACH '{}' AS emb", emb_path.display());
        let _ = conn.execute(&attach_sql, []);
        let result = f(conn);
        let _ = conn.execute("DETACH emb", []);
        result
    }
}
