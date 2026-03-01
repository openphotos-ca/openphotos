use albumbud::database::postgres::{init_postgres_schema, PgConfig};
use anyhow::Result;

#[tokio::main]
async fn main() -> Result<()> {
    dotenvy::dotenv().ok();
    let cfg = PgConfig::from_env();
    tracing_subscriber::fmt::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();
    tracing::info!(
        "Initializing Postgres schema at {}:{} db={} user={}",
        cfg.host,
        cfg.port,
        cfg.dbname,
        cfg.user
    );
    init_postgres_schema(&cfg).await?;
    Ok(())
}
