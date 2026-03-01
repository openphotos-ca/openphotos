use anyhow::{anyhow, Context, Result};
use bcrypt::{hash, verify};
use clap::Parser;
use duckdb::{params, Connection};
use std::collections::HashMap;
use std::path::PathBuf;

#[derive(Debug, Parser)]
#[command(
    name = "change_duckdb_user_credentials",
    about = "Change a DuckDB user's email and password for OpenPhotos"
)]
struct Args {
    /// Path to DuckDB database file (defaults to data/data.duckdb)
    #[arg(long, default_value = "data/data.duckdb")]
    db: PathBuf,

    /// Existing user email to match (case-insensitive)
    #[arg(long)]
    old_email: String,

    /// Existing plaintext password used for verification before update
    #[arg(long)]
    old_password: String,

    /// New email to set
    #[arg(long)]
    new_email: String,

    /// New plaintext password to hash and store
    #[arg(long)]
    new_password: String,

    /// bcrypt cost to use (OpenPhotos defaults to 4)
    #[arg(long, default_value_t = 4)]
    bcrypt_cost: u32,

    /// Print what would change without writing to DB
    #[arg(long, default_value_t = false)]
    dry_run: bool,

    /// If new_email is already used by another user, delete those user rows first.
    /// This is destructive: it removes the conflicting users (and their auth/session rows).
    #[arg(long, default_value_t = false)]
    replace_existing_email_user: bool,
}

#[derive(Debug)]
struct UserRow {
    id: i64,
    user_id: String,
    organization_id: i64,
    email: Option<String>,
    password_hash: Option<String>,
}

#[derive(Debug)]
struct CollisionRow {
    id: i64,
    user_id: String,
    organization_id: i64,
}

fn main() -> Result<()> {
    let args = Args::parse();

    let conn = Connection::open(&args.db)
        .with_context(|| format!("failed to open DuckDB file: {}", args.db.display()))?;

    let mut stmt = conn
        .prepare(
            "SELECT id, user_id, organization_id, email, password_hash
             FROM users
             WHERE lower(email) = lower(?)
             ORDER BY id",
        )
        .context("failed to prepare users lookup query")?;

    let rows = stmt
        .query_map(params![&args.old_email], |row| {
            Ok(UserRow {
                id: row.get(0)?,
                user_id: row.get(1)?,
                organization_id: row.get(2)?,
                email: row.get(3).ok(),
                password_hash: row.get(4).ok(),
            })
        })
        .context("failed to query users by old email")?;

    let mut targets: Vec<UserRow> = Vec::new();
    for row in rows {
        targets.push(row.context("failed to decode user row")?);
    }

    if targets.is_empty() {
        return Err(anyhow!(
            "no users found with email '{}' (case-insensitive)",
            args.old_email
        ));
    }

    for user in &targets {
        let stored_hash = user
            .password_hash
            .as_deref()
            .ok_or_else(|| anyhow!("user_id={} has no password_hash", user.user_id))?;
        let matches = verify(&args.old_password, stored_hash).with_context(|| {
            format!(
                "failed to verify old password against stored hash for user_id={}",
                user.user_id
            )
        })?;
        if !matches {
            return Err(anyhow!(
                "old password does not match user_id={} (email={})",
                user.user_id,
                user.email.clone().unwrap_or_default()
            ));
        }
    }

    // Prevent collisions: for each target org, the new email must not already belong to a different id.
    let mut org_to_target_ids: HashMap<i64, Vec<i64>> = HashMap::new();
    for user in &targets {
        org_to_target_ids
            .entry(user.organization_id)
            .or_default()
            .push(user.id);
    }
    let mut collision_stmt = conn
        .prepare(
            "SELECT id, user_id, organization_id
             FROM users
             WHERE lower(email) = lower(?)
             ORDER BY id",
        )
        .context("failed to prepare email collision query")?;
    let collision_rows = collision_stmt
        .query_map(params![&args.new_email], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, i64>(2)?,
            ))
        })
        .context("failed to run email collision query")?;
    let mut collisions: Vec<CollisionRow> = Vec::new();
    for row in collision_rows {
        let (id, uid, org_id) = row.context("failed to decode collision row")?;
        let target_ids = org_to_target_ids.get(&org_id);
        let belongs_to_target = target_ids.is_some_and(|ids| ids.contains(&id));
        if !belongs_to_target {
            collisions.push(CollisionRow {
                id,
                user_id: uid,
                organization_id: org_id,
            });
        }
    }

    if !collisions.is_empty() && !args.replace_existing_email_user {
        let summary = collisions
            .iter()
            .map(|c| {
                format!(
                    "user_id={} (id={}, org_id={})",
                    c.user_id, c.id, c.organization_id
                )
            })
            .collect::<Vec<_>>()
            .join(", ");
        return Err(anyhow!(
            "cannot set new email '{}': already used by {}. \
             Re-run with --replace-existing-email-user to delete those user rows first",
            args.new_email,
            summary
        ));
    }

    println!(
        "Matched {} user row(s) with email '{}' in {}",
        targets.len(),
        args.old_email,
        args.db.display()
    );
    for u in &targets {
        println!(
            "  - id={} user_id={} org_id={} email={}",
            u.id,
            u.user_id,
            u.organization_id,
            u.email.clone().unwrap_or_default()
        );
    }

    if args.dry_run {
        if !collisions.is_empty() {
            println!(
                "Dry-run: would delete {} conflicting user row(s) that already use email '{}':",
                collisions.len(),
                args.new_email
            );
            for c in &collisions {
                println!(
                    "  - delete id={} user_id={} org_id={}",
                    c.id, c.user_id, c.organization_id
                );
            }
        }
        println!(
            "Dry-run: would set email='{}' and update bcrypt password hash (cost={})",
            args.new_email, args.bcrypt_cost
        );
        return Ok(());
    }

    let new_hash = hash(&args.new_password, args.bcrypt_cost).with_context(|| {
        format!(
            "failed to generate bcrypt hash with cost={}",
            args.bcrypt_cost
        )
    })?;

    let mut delete_sessions_stmt = conn
        .prepare("DELETE FROM sessions WHERE user_id = ?")
        .context("failed to prepare sessions cleanup")?;
    let mut delete_refresh_stmt = conn
        .prepare("DELETE FROM refresh_tokens WHERE user_id = ?")
        .context("failed to prepare refresh token cleanup")?;
    // EE-only table may exist; if present, clear rows that reference users(id).
    let mut delete_user_groups_stmt = conn
        .prepare("DELETE FROM user_groups WHERE user_id = ?")
        .ok();
    // EE-only table may exist; recipients reference users by user_id text.
    let mut delete_share_recipients_stmt = conn
        .prepare("DELETE FROM ee_share_recipients WHERE recipient_user_id = ?")
        .ok();
    let mut delete_user_stmt = conn
        .prepare("DELETE FROM users WHERE id = ?")
        .context("failed to prepare users delete statement")?;

    let mut update_stmt = conn
        .prepare(
            "UPDATE users
             SET email = ?,
                 password_hash = ?,
                 status = 'active',
                 must_change_password = FALSE,
                 token_version = COALESCE(token_version, 0) + 1,
                 last_active = CURRENT_TIMESTAMP
             WHERE id = ?",
        )
        .context("failed to prepare update statement")?;

    if !collisions.is_empty() {
        println!(
            "Deleting {} existing user row(s) that already use email='{}' before update:",
            collisions.len(),
            args.new_email
        );
        for c in &collisions {
            println!(
                "  - deleting id={} user_id={} org_id={}",
                c.id, c.user_id, c.organization_id
            );
            delete_sessions_stmt
                .execute(params![c.id])
                .with_context(|| {
                    format!(
                        "failed to delete sessions for conflicting user_id={}",
                        c.user_id
                    )
                })?;
            delete_refresh_stmt
                .execute(params![c.id])
                .with_context(|| {
                    format!(
                        "failed to delete refresh_tokens for conflicting user_id={}",
                        c.user_id
                    )
                })?;
            if let Some(stmt) = delete_user_groups_stmt.as_mut() {
                let _ = stmt.execute(params![c.id]);
            }
            if let Some(stmt) = delete_share_recipients_stmt.as_mut() {
                let _ = stmt.execute(params![&c.user_id]);
            }
            delete_user_stmt
                .execute(params![c.id])
                .with_context(|| format!("failed to delete conflicting user_id={}", c.user_id))?;
        }
    }

    // DuckDB FK limitation: updating users.email can fail if referencing rows exist,
    // and delete+update inside the same explicit transaction may still violate checks.
    // Execute in autocommit mode: clear dependents first, then update the user row.
    for user in &targets {
        delete_sessions_stmt
            .execute(params![user.id])
            .with_context(|| format!("failed to delete sessions for user_id={}", user.user_id))?;
        delete_refresh_stmt
            .execute(params![user.id])
            .with_context(|| {
                format!(
                    "failed to delete refresh_tokens for user_id={}",
                    user.user_id
                )
            })?;
        if let Some(stmt) = delete_user_groups_stmt.as_mut() {
            let _ = stmt.execute(params![user.id]);
        }
        update_stmt
            .execute(params![&args.new_email, &new_hash, user.id])
            .with_context(|| format!("failed to update user_id={}", user.user_id))?;
    }

    println!(
        "Updated {} user row(s): email='{}' -> '{}', password hash replaced",
        targets.len(),
        args.old_email,
        args.new_email
    );
    Ok(())
}
