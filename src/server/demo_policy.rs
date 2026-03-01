use crate::server::{state::AppState, AppError};

pub const DEMO_EMAIL: &str = "demo@openphotos.ca";

pub fn is_demo_email(email: Option<&str>) -> bool {
    email
        .map(|e| e.trim().eq_ignore_ascii_case(DEMO_EMAIL))
        .unwrap_or(false)
}

pub async fn is_demo_user(state: &AppState, user_id: &str) -> Result<bool, AppError> {
    if let Some(pg) = &state.pg_client {
        let row = pg
            .query_opt(
                "SELECT email FROM users WHERE user_id = $1 LIMIT 1",
                &[&user_id],
            )
            .await
            .map_err(|e| AppError(anyhow::anyhow!(e)))?;
        let email: Option<String> = row.and_then(|r| r.get::<_, Option<String>>(0));
        return Ok(is_demo_email(email.as_deref().map(str::trim)));
    }

    let users_db = state
        .multi_tenant_db
        .as_ref()
        .expect("users DB required in DuckDB mode")
        .users_connection();
    let conn = users_db.lock();
    let email: Option<String> = conn
        .query_row(
            "SELECT email FROM users WHERE user_id = ? LIMIT 1",
            duckdb::params![user_id],
            |row| row.get::<_, Option<String>>(0),
        )
        .unwrap_or(None);
    Ok(is_demo_email(email.as_deref().map(str::trim)))
}

pub fn deny_demo_mutation(route: &str, user_id: &str) -> AppError {
    tracing::warn!(
        "[DEMO-READONLY] blocked route={} user_id={} reason=demo_account_read_only",
        route,
        user_id
    );
    AppError(anyhow::anyhow!("Demo account is read-only"))
}

pub async fn ensure_not_demo_mutation(
    state: &AppState,
    user_id: &str,
    route: &str,
) -> Result<(), AppError> {
    if is_demo_user(state, user_id).await? {
        return Err(deny_demo_mutation(route, user_id));
    }
    Ok(())
}
