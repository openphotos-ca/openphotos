use anyhow::{anyhow, Context, Result};
use tokio_postgres::{Client, NoTls};

#[derive(Clone, Debug)]
struct PgConfig {
    host: String,
    port: u16,
    dbname: String,
    user: String,
    password: String,
}

impl PgConfig {
    fn from_env() -> Self {
        let host = std::env::var("POSTGRES_HOST").unwrap_or_else(|_| "127.0.0.1".to_string());
        let port = std::env::var("POSTGRES_PORT")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(5432);
        let dbname = std::env::var("POSTGRES_DB").unwrap_or_else(|_| "albumbud".to_string());
        let user = std::env::var("POSTGRES_USER").unwrap_or_else(|_| "postgres".to_string());
        let password = std::env::var("POSTGRES_PASSWORD").unwrap_or_default();
        Self {
            host,
            port,
            dbname,
            user,
            password,
        }
    }
    fn to_connect_str(&self) -> String {
        format!(
            "host={} port={} dbname={} user={} password={}",
            self.host, self.port, self.dbname, self.user, self.password
        )
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    dotenvy::dotenv().ok();
    tracing_subscriber::fmt::init();
    println!("[pg_migrate] Starting migration tool");
    let cfg = PgConfig::from_env();
    let (client, conn) = tokio_postgres::connect(&cfg.to_connect_str(), NoTls)
        .await
        .with_context(|| "Failed to connect to Postgres")?;
    tokio::spawn(async move {
        if let Err(e) = conn.await {
            eprintln!("[pg_migrate] connection error: {}", e);
        }
    });

    run_migrations(&client).await?;
    println!("[pg_migrate] Completed.");
    Ok(())
}

async fn run_migrations(client: &Client) -> Result<()> {
    // Best-effort: add missing columns and promote tenant-first PKs. Each step is independent.
    // persons: add organization_id and backfill from faces
    try_exec(
        client,
        "ALTER TABLE IF EXISTS persons ADD COLUMN IF NOT EXISTS organization_id INTEGER;",
    )
    .await;
    try_exec(
        client,
        r#"
        UPDATE persons p SET organization_id = sub.organization_id
        FROM (
            SELECT person_id, MIN(organization_id) AS organization_id
            FROM faces
            WHERE person_id IS NOT NULL
            GROUP BY person_id
        ) sub
        WHERE p.organization_id IS NULL AND p.person_id = sub.person_id;
    "#,
    )
    .await;
    // Remove orphan persons without org to allow PK creation
    try_exec(client, "DELETE FROM persons WHERE organization_id IS NULL;").await;

    // photos → PK(org, asset)
    promote_pk(client, "photos", "PRIMARY KEY (organization_id, asset_id)").await?;
    // E2EE: locked container presence flags (orig + thumb)
    try_exec(
        client,
        "ALTER TABLE IF EXISTS photos ADD COLUMN IF NOT EXISTS locked_orig_uploaded BOOLEAN DEFAULT FALSE;",
    )
    .await;
    try_exec(
        client,
        "ALTER TABLE IF EXISTS photos ADD COLUMN IF NOT EXISTS locked_thumb_uploaded BOOLEAN DEFAULT FALSE;",
    )
    .await;
    // photo_embeddings → PK(org, asset)
    promote_pk(
        client,
        "photo_embeddings",
        "PRIMARY KEY (organization_id, asset_id)",
    )
    .await?;
    // faces → PK(org, face_id)
    promote_pk(client, "faces", "PRIMARY KEY (organization_id, face_id)").await?;
    // persons → PK(org, person_id)
    promote_pk(
        client,
        "persons",
        "PRIMARY KEY (organization_id, person_id)",
    )
    .await?;
    // album tables
    promote_pk(client, "albums", "PRIMARY KEY (organization_id, id)").await?;
    promote_pk(
        client,
        "album_photos",
        "PRIMARY KEY (organization_id, album_id, photo_id)",
    )
    .await?;
    promote_pk(
        client,
        "album_closure",
        "PRIMARY KEY (organization_id, ancestor_id, descendant_id)",
    )
    .await?;
    // comments/likes
    promote_pk(
        client,
        "photo_comments",
        "PRIMARY KEY (organization_id, id)",
    )
    .await?;
    promote_pk(
        client,
        "photo_likes",
        "PRIMARY KEY (organization_id, asset_id, scope, actor)",
    )
    .await?;
    // video pHash samples
    promote_pk(
        client,
        "video_phash_samples",
        "PRIMARY KEY (organization_id, asset_id, sample_idx)",
    )
    .await?;

    println!("[pg_migrate] PK promotion completed.");
    Ok(())
}

async fn promote_pk(client: &Client, table: &str, pk_sql: &str) -> Result<()> {
    let drop_sql = format!(
        "ALTER TABLE IF EXISTS {} DROP CONSTRAINT IF EXISTS {}_pkey;",
        table, table
    );
    try_exec(client, &drop_sql).await;
    let add_sql = format!("ALTER TABLE {} ADD {};", table, pk_sql);
    match client.execute(&add_sql, &[]).await {
        Ok(_) => {
            println!("[pg_migrate] {}: set {}", table, pk_sql);
            Ok(())
        }
        Err(e) => {
            eprintln!("[pg_migrate] {}: failed to set {} => {}", table, pk_sql, e);
            Err(anyhow!(e))
        }
    }
}

async fn try_exec(client: &Client, sql: &str) {
    if let Err(e) = client.execute(sql, &[]).await {
        eprintln!("[pg_migrate] warn: {} => {}", sql, e);
    }
}
