use anyhow::Result;
use once_cell::sync::Lazy;
use std::collections::HashSet;
use std::path::Path;
use std::sync::Arc;

use crate::server::state::AppState;

pub const KEY_KIND_ASSET_ID: &str = "asset_id";
pub const KEY_KIND_BACKUP_ID: &str = "backup_id";

static LEGACY_DELETED_BACKUP_REPAIRS: Lazy<parking_lot::Mutex<HashSet<String>>> =
    Lazy::new(|| parking_lot::Mutex::new(HashSet::new()));

#[derive(Debug, Clone)]
pub struct DeletedUploadMatch {
    pub key_kind: &'static str,
    pub key_value: String,
}

#[derive(Debug, Clone)]
struct PhotoTombstoneSource {
    asset_id: String,
    path: String,
    backup_id: Option<String>,
    is_live_photo: bool,
    live_video_path: Option<String>,
    locked: bool,
}

#[derive(Debug, Clone)]
struct PathBackupIdRow {
    asset_id: String,
    backup_id: Option<String>,
    locked: bool,
}

pub async fn upsert_deleted_tombstones_for_asset(
    state: &AppState,
    organization_id: i32,
    user_id: &str,
    asset_id: &str,
    deleted_at: i64,
) -> Result<usize> {
    let Some(source) =
        load_photo_tombstone_source(state, organization_id, user_id, asset_id).await?
    else {
        return Ok(0);
    };

    let mut keys: HashSet<(&'static str, String)> = HashSet::new();
    keys.insert((KEY_KIND_ASSET_ID, source.asset_id.clone()));

    let mut primary_backup_id = source.backup_id.clone().filter(|v| !v.trim().is_empty());
    if primary_backup_id.is_none() && !source.locked && !source.path.trim().is_empty() {
        primary_backup_id = compute_backup_id_from_path(Path::new(&source.path), user_id).await;
        if let Some(ref bid) = primary_backup_id {
            persist_photo_backup_id(state, organization_id, user_id, &source.asset_id, bid).await?;
        }
    }
    if let Some(bid) = primary_backup_id {
        keys.insert((KEY_KIND_BACKUP_ID, bid));
    }

    if source.is_live_photo {
        if let Some(live_bid) = resolve_live_component_backup_id(
            state,
            organization_id,
            user_id,
            source.live_video_path.as_deref(),
        )
        .await?
        {
            keys.insert((KEY_KIND_BACKUP_ID, live_bid));
        }
    }

    if keys.is_empty() {
        return Ok(0);
    }

    if let Some(pg) = &state.pg_client {
        for (key_kind, key_value) in &keys {
            let _ = pg
                .execute(
                    "INSERT INTO deleted_upload_tombstones (
                        organization_id, user_id, key_kind, key_value, source_asset_id, deleted_at
                     ) VALUES ($1, $2, $3, $4, $5, $6)
                     ON CONFLICT (organization_id, user_id, key_kind, key_value)
                     DO UPDATE SET
                        source_asset_id = EXCLUDED.source_asset_id,
                        deleted_at = EXCLUDED.deleted_at",
                    &[
                        &organization_id,
                        &user_id,
                        key_kind,
                        key_value,
                        &source.asset_id,
                        &deleted_at,
                    ],
                )
                .await?;
        }
    } else {
        let data_db = state.get_user_data_database(user_id)?;
        let conn = data_db.lock();
        for (key_kind, key_value) in &keys {
            conn.execute(
                "INSERT INTO deleted_upload_tombstones (
                    organization_id, user_id, key_kind, key_value, source_asset_id, deleted_at
                 ) VALUES (?, ?, ?, ?, ?, ?)
                 ON CONFLICT (organization_id, user_id, key_kind, key_value)
                 DO UPDATE SET
                    source_asset_id = EXCLUDED.source_asset_id,
                    deleted_at = EXCLUDED.deleted_at",
                duckdb::params![
                    organization_id,
                    user_id,
                    key_kind,
                    key_value,
                    &source.asset_id,
                    deleted_at
                ],
            )?;
        }
    }

    Ok(keys.len())
}

pub async fn remove_deleted_tombstones_for_asset(
    state: &AppState,
    organization_id: i32,
    user_id: &str,
    asset_id: &str,
) -> Result<()> {
    if let Some(pg) = &state.pg_client {
        let _ = pg
            .execute(
                "DELETE FROM deleted_upload_tombstones
                 WHERE organization_id = $1 AND user_id = $2 AND source_asset_id = $3",
                &[&organization_id, &user_id, &asset_id],
            )
            .await?;
    } else {
        let data_db = state.get_user_data_database(user_id)?;
        let conn = data_db.lock();
        conn.execute(
            "DELETE FROM deleted_upload_tombstones
             WHERE organization_id = ? AND user_id = ? AND source_asset_id = ?",
            duckdb::params![organization_id, user_id, asset_id],
        )?;
    }
    Ok(())
}

pub async fn find_deleted_upload_match(
    state: &AppState,
    organization_id: i32,
    user_id: &str,
    asset_id: Option<&str>,
    backup_id: Option<&str>,
) -> Result<Option<DeletedUploadMatch>> {
    let asset_id = asset_id
        .map(|v| v.trim())
        .filter(|v| !v.is_empty())
        .map(str::to_string);
    let backup_id = backup_id
        .map(|v| v.trim())
        .filter(|v| !v.is_empty())
        .map(str::to_string);

    if asset_id.is_none() && backup_id.is_none() {
        return Ok(None);
    }

    if let Some(pg) = &state.pg_client {
        if let Some(aid) = asset_id.as_ref() {
            if let Some(row) = pg
                .query_opt(
                    "SELECT key_value
                     FROM deleted_upload_tombstones
                     WHERE organization_id = $1 AND user_id = $2 AND key_kind = $3 AND key_value = $4
                     LIMIT 1",
                    &[&organization_id, &user_id, &KEY_KIND_ASSET_ID, aid],
                )
                .await?
            {
                return Ok(Some(DeletedUploadMatch {
                    key_kind: KEY_KIND_ASSET_ID,
                    key_value: row.get(0),
                }));
            }
        }
        if let Some(bid) = backup_id.as_ref() {
            if let Some(row) = pg
                .query_opt(
                    "SELECT key_value
                     FROM deleted_upload_tombstones
                     WHERE organization_id = $1 AND user_id = $2 AND key_kind = $3 AND key_value = $4
                     LIMIT 1",
                    &[&organization_id, &user_id, &KEY_KIND_BACKUP_ID, bid],
                )
                .await?
            {
                return Ok(Some(DeletedUploadMatch {
                    key_kind: KEY_KIND_BACKUP_ID,
                    key_value: row.get(0),
                }));
            }
        }
        return Ok(None);
    }

    let data_db = state.get_user_data_database(user_id)?;
    let conn = data_db.lock();

    if let Some(aid) = asset_id.as_ref() {
        if let Ok(mut stmt) = conn.prepare(
            "SELECT key_value
             FROM deleted_upload_tombstones
             WHERE organization_id = ? AND user_id = ? AND key_kind = ? AND key_value = ?
             LIMIT 1",
        ) {
            if let Ok(key_value) = stmt.query_row(
                duckdb::params![organization_id, user_id, KEY_KIND_ASSET_ID, aid],
                |row| row.get::<_, String>(0),
            ) {
                return Ok(Some(DeletedUploadMatch {
                    key_kind: KEY_KIND_ASSET_ID,
                    key_value,
                }));
            }
        }
    }

    if let Some(bid) = backup_id.as_ref() {
        if let Ok(mut stmt) = conn.prepare(
            "SELECT key_value
             FROM deleted_upload_tombstones
             WHERE organization_id = ? AND user_id = ? AND key_kind = ? AND key_value = ?
             LIMIT 1",
        ) {
            if let Ok(key_value) = stmt.query_row(
                duckdb::params![organization_id, user_id, KEY_KIND_BACKUP_ID, bid],
                |row| row.get::<_, String>(0),
            ) {
                return Ok(Some(DeletedUploadMatch {
                    key_kind: KEY_KIND_BACKUP_ID,
                    key_value,
                }));
            }
        }
    }

    Ok(None)
}

async fn load_photo_tombstone_source(
    state: &AppState,
    organization_id: i32,
    user_id: &str,
    asset_id: &str,
) -> Result<Option<PhotoTombstoneSource>> {
    if let Some(pg) = &state.pg_client {
        let row = pg
            .query_opt(
                "SELECT asset_id,
                        COALESCE(path, ''),
                        backup_id,
                        COALESCE(is_live_photo, FALSE),
                        live_video_path,
                        COALESCE(locked, FALSE)
                 FROM photos
                 WHERE organization_id = $1 AND user_id = $2 AND asset_id = $3
                 LIMIT 1",
                &[&organization_id, &user_id, &asset_id],
            )
            .await?;
        return Ok(row.map(|r| PhotoTombstoneSource {
            asset_id: r.get(0),
            path: r.get(1),
            backup_id: r.get(2),
            is_live_photo: r.get(3),
            live_video_path: r.get(4),
            locked: r.get(5),
        }));
    }

    let data_db = state.get_user_data_database(user_id)?;
    let conn = data_db.lock();
    if let Ok(mut stmt) = conn.prepare(
        "SELECT asset_id,
                COALESCE(path, ''),
                backup_id,
                COALESCE(is_live_photo, FALSE),
                live_video_path,
                COALESCE(locked, FALSE)
         FROM photos
         WHERE organization_id = ? AND user_id = ? AND asset_id = ?
         LIMIT 1",
    ) {
        if let Ok(row) =
            stmt.query_row(duckdb::params![organization_id, user_id, asset_id], |row| {
                Ok(PhotoTombstoneSource {
                    asset_id: row.get(0)?,
                    path: row.get(1)?,
                    backup_id: row.get(2).ok(),
                    is_live_photo: row.get(3)?,
                    live_video_path: row.get(4).ok(),
                    locked: row.get(5)?,
                })
            })
        {
            return Ok(Some(row));
        }
    }
    Ok(None)
}

async fn persist_photo_backup_id(
    state: &AppState,
    organization_id: i32,
    user_id: &str,
    asset_id: &str,
    backup_id: &str,
) -> Result<()> {
    if let Some(pg) = &state.pg_client {
        let _ = pg
            .execute(
                "UPDATE photos
                 SET backup_id = $1
                 WHERE organization_id = $2 AND user_id = $3 AND asset_id = $4",
                &[&backup_id, &organization_id, &user_id, &asset_id],
            )
            .await?;
        return Ok(());
    }

    let data_db = state.get_user_data_database(user_id)?;
    let conn = data_db.lock();
    conn.execute(
        "UPDATE photos
         SET backup_id = ?
         WHERE organization_id = ? AND user_id = ? AND asset_id = ?",
        duckdb::params![backup_id, organization_id, user_id, asset_id],
    )?;
    Ok(())
}

async fn resolve_live_component_backup_id(
    state: &AppState,
    organization_id: i32,
    user_id: &str,
    live_video_path: Option<&str>,
) -> Result<Option<String>> {
    let Some(path) = live_video_path
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .map(str::to_string)
    else {
        return Ok(None);
    };

    if let Some(row) = load_path_backup_id_row(state, organization_id, user_id, &path).await? {
        if let Some(bid) = row.backup_id.filter(|v| !v.trim().is_empty()) {
            return Ok(Some(bid));
        }
        if !row.locked {
            if let Some(bid) = compute_backup_id_from_path(Path::new(&path), user_id).await {
                persist_photo_backup_id(state, organization_id, user_id, &row.asset_id, &bid)
                    .await?;
                return Ok(Some(bid));
            }
        }
        return Ok(None);
    }

    if looks_like_locked_container(&path) {
        return Ok(None);
    }

    Ok(compute_backup_id_from_path(Path::new(&path), user_id).await)
}

async fn load_path_backup_id_row(
    state: &AppState,
    organization_id: i32,
    user_id: &str,
    path: &str,
) -> Result<Option<PathBackupIdRow>> {
    if let Some(pg) = &state.pg_client {
        let row = pg
            .query_opt(
                "SELECT asset_id, backup_id, COALESCE(locked, FALSE)
                 FROM photos
                 WHERE organization_id = $1 AND user_id = $2 AND path = $3
                 LIMIT 1",
                &[&organization_id, &user_id, &path],
            )
            .await?;
        return Ok(row.map(|r| PathBackupIdRow {
            asset_id: r.get(0),
            backup_id: r.get(1),
            locked: r.get(2),
        }));
    }

    let data_db = state.get_user_data_database(user_id)?;
    let conn = data_db.lock();
    if let Ok(mut stmt) = conn.prepare(
        "SELECT asset_id, backup_id, COALESCE(locked, FALSE)
         FROM photos
         WHERE organization_id = ? AND user_id = ? AND path = ?
         LIMIT 1",
    ) {
        if let Ok(row) = stmt.query_row(duckdb::params![organization_id, user_id, path], |row| {
            Ok(PathBackupIdRow {
                asset_id: row.get(0)?,
                backup_id: row.get(1).ok(),
                locked: row.get(2)?,
            })
        }) {
            return Ok(Some(row));
        }
    }
    Ok(None)
}

async fn compute_backup_id_from_path(path: &Path, user_id: &str) -> Option<String> {
    let path = path.to_path_buf();
    let user_id = user_id.to_string();
    tokio::task::spawn_blocking(move || {
        let bytes = std::fs::read(path).ok()?;
        crate::photos::backup_id::from_bytes(&bytes, &user_id).ok()
    })
    .await
    .ok()
    .flatten()
}

fn looks_like_locked_container(path: &str) -> bool {
    path.contains("/locked/") || path.ends_with(".pae3") || path.ends_with("_t.pae3")
}

pub async fn list_deleted_backup_ids_page(
    state: &AppState,
    organization_id: i32,
    user_id: &str,
    limit: usize,
    after: Option<&str>,
) -> Result<(usize, Vec<String>)> {
    let limit = limit.clamp(1, 1000) as i64;
    let after = after
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .unwrap_or("")
        .to_string();

    if let Some(pg) = &state.pg_client {
        let count_row = pg
            .query_one(
                "WITH deleted_candidates AS (
                    SELECT backup_id
                    FROM photos
                    WHERE organization_id = $1 AND user_id = $2
                      AND COALESCE(delete_time, 0) > 0
                      AND COALESCE(backup_id, '') <> ''
                    UNION
                    SELECT key_value AS backup_id
                    FROM deleted_upload_tombstones
                    WHERE organization_id = $1 AND user_id = $2 AND key_kind = $3
                      AND COALESCE(key_value, '') <> ''
                 )
                 SELECT COUNT(*)::BIGINT
                 FROM deleted_candidates dc
                 WHERE NOT EXISTS (
                    SELECT 1
                    FROM photos active
                    WHERE active.organization_id = $1
                      AND active.user_id = $2
                      AND COALESCE(active.delete_time, 0) = 0
                      AND active.backup_id = dc.backup_id
                 )",
                &[&organization_id, &user_id, &KEY_KIND_BACKUP_ID],
            )
            .await?;
        let total: i64 = count_row.get(0);
        let rows = pg
            .query(
                "WITH deleted_candidates AS (
                    SELECT backup_id
                    FROM photos
                    WHERE organization_id = $1 AND user_id = $2
                      AND COALESCE(delete_time, 0) > 0
                      AND COALESCE(backup_id, '') <> ''
                    UNION
                    SELECT key_value AS backup_id
                    FROM deleted_upload_tombstones
                    WHERE organization_id = $1 AND user_id = $2 AND key_kind = $3
                      AND COALESCE(key_value, '') <> ''
                 )
                 SELECT dc.backup_id
                 FROM deleted_candidates dc
                 WHERE NOT EXISTS (
                    SELECT 1
                    FROM photos active
                    WHERE active.organization_id = $1
                      AND active.user_id = $2
                      AND COALESCE(active.delete_time, 0) = 0
                      AND active.backup_id = dc.backup_id
                 )
                   AND ($4 = '' OR dc.backup_id > $4)
                 ORDER BY dc.backup_id ASC
                 LIMIT $5",
                &[
                    &organization_id,
                    &user_id,
                    &KEY_KIND_BACKUP_ID,
                    &after,
                    &limit,
                ],
            )
            .await?;
        let backup_ids = rows
            .into_iter()
            .map(|row| row.get::<_, String>(0))
            .collect::<Vec<_>>();
        return Ok((total.max(0) as usize, backup_ids));
    }

    let data_db = state.get_user_data_database(user_id)?;
    let conn = data_db.lock();
    let total: i64 = conn.query_row(
        "WITH deleted_candidates AS (
            SELECT backup_id
            FROM photos
            WHERE organization_id = ? AND user_id = ?
              AND COALESCE(delete_time, 0) > 0
              AND COALESCE(backup_id, '') <> ''
            UNION
            SELECT key_value AS backup_id
            FROM deleted_upload_tombstones
            WHERE organization_id = ? AND user_id = ? AND key_kind = ?
              AND COALESCE(key_value, '') <> ''
         )
         SELECT COUNT(*)
         FROM deleted_candidates dc
         WHERE NOT EXISTS (
            SELECT 1
            FROM photos active
            WHERE active.organization_id = ?
              AND active.user_id = ?
              AND COALESCE(active.delete_time, 0) = 0
              AND active.backup_id = dc.backup_id
         )",
        duckdb::params![
            organization_id,
            user_id,
            organization_id,
            user_id,
            KEY_KIND_BACKUP_ID,
            organization_id,
            user_id
        ],
        |row| row.get::<_, i64>(0),
    )?;
    let mut stmt = conn.prepare(
        "WITH deleted_candidates AS (
            SELECT backup_id
            FROM photos
            WHERE organization_id = ? AND user_id = ?
              AND COALESCE(delete_time, 0) > 0
              AND COALESCE(backup_id, '') <> ''
            UNION
            SELECT key_value AS backup_id
            FROM deleted_upload_tombstones
            WHERE organization_id = ? AND user_id = ? AND key_kind = ?
              AND COALESCE(key_value, '') <> ''
         )
         SELECT dc.backup_id
         FROM deleted_candidates dc
         WHERE NOT EXISTS (
            SELECT 1
            FROM photos active
            WHERE active.organization_id = ?
              AND active.user_id = ?
              AND COALESCE(active.delete_time, 0) = 0
              AND active.backup_id = dc.backup_id
         )
           AND (? = '' OR dc.backup_id > ?)
         ORDER BY dc.backup_id ASC
         LIMIT ?",
    )?;
    let mapped = stmt.query_map(
        duckdb::params![
            organization_id,
            user_id,
            organization_id,
            user_id,
            KEY_KIND_BACKUP_ID,
            organization_id,
            user_id,
            &after,
            &after,
            limit
        ],
        |row| row.get::<_, String>(0),
    )?;
    let mut backup_ids = Vec::new();
    for row in mapped {
        if let Ok(v) = row {
            backup_ids.push(v);
        }
    }
    Ok((total.max(0) as usize, backup_ids))
}

pub async fn match_deleted_backup_ids(
    state: &AppState,
    organization_id: i32,
    user_id: &str,
    backup_ids: &[String],
) -> Result<HashSet<String>> {
    let requested: Vec<String> = backup_ids
        .iter()
        .map(|v| v.trim())
        .filter(|v| !v.is_empty())
        .map(str::to_string)
        .collect();
    if requested.is_empty() {
        return Ok(HashSet::new());
    }

    if let Some(pg) = &state.pg_client {
        let mut params: Vec<&(dyn tokio_postgres::types::ToSql + Sync)> =
            Vec::with_capacity(3 + requested.len());
        params.push(&organization_id);
        params.push(&user_id);
        params.push(&KEY_KIND_BACKUP_ID);
        let mut placeholders: Vec<String> = Vec::with_capacity(requested.len());
        for (i, id) in requested.iter().enumerate() {
            placeholders.push(format!("${}", i + 4));
            params.push(id);
        }
        let ids_clause = placeholders.join(",");
        let sql = format!(
            "WITH deleted_candidates AS (
                SELECT backup_id
                FROM photos
                WHERE organization_id = $1 AND user_id = $2
                  AND COALESCE(delete_time, 0) > 0
                  AND backup_id IN ({ids_clause})
                UNION
                SELECT key_value AS backup_id
                FROM deleted_upload_tombstones
                WHERE organization_id = $1 AND user_id = $2 AND key_kind = $3
                  AND key_value IN ({ids_clause})
             )
             SELECT dc.backup_id
             FROM deleted_candidates dc
             WHERE NOT EXISTS (
                SELECT 1
                FROM photos active
                WHERE active.organization_id = $1
                  AND active.user_id = $2
                  AND COALESCE(active.delete_time, 0) = 0
                  AND active.backup_id = dc.backup_id
             )"
        );
        let rows = pg.query(&sql, &params).await?;
        return Ok(rows
            .into_iter()
            .map(|row| row.get::<_, String>(0))
            .collect::<HashSet<_>>());
    }

    let data_db = state.get_user_data_database(user_id)?;
    let conn = data_db.lock();
    let placeholders = vec!["?"; requested.len()].join(",");
    let sql = format!(
        "WITH deleted_candidates AS (
            SELECT backup_id
            FROM photos
            WHERE organization_id = ? AND user_id = ?
              AND COALESCE(delete_time, 0) > 0
              AND backup_id IN ({placeholders})
            UNION
            SELECT key_value AS backup_id
            FROM deleted_upload_tombstones
            WHERE organization_id = ? AND user_id = ? AND key_kind = ?
              AND key_value IN ({placeholders})
         )
         SELECT dc.backup_id
         FROM deleted_candidates dc
         WHERE NOT EXISTS (
            SELECT 1
            FROM photos active
            WHERE active.organization_id = ?
              AND active.user_id = ?
              AND COALESCE(active.delete_time, 0) = 0
              AND active.backup_id = dc.backup_id
         )"
    );
    let mut query_params: Vec<Box<dyn duckdb::ToSql>> =
        Vec::with_capacity(7 + (requested.len() * 2));
    query_params.push(Box::new(organization_id));
    query_params.push(Box::new(user_id.to_string()));
    for id in &requested {
        query_params.push(Box::new(id.clone()));
    }
    query_params.push(Box::new(organization_id));
    query_params.push(Box::new(user_id.to_string()));
    query_params.push(Box::new(KEY_KIND_BACKUP_ID.to_string()));
    for id in &requested {
        query_params.push(Box::new(id.clone()));
    }
    query_params.push(Box::new(organization_id));
    query_params.push(Box::new(user_id.to_string()));
    let mut stmt = conn.prepare(&sql)?;
    let mapped = stmt.query_map(
        duckdb::params_from_iter(query_params.iter().map(|b| &**b)),
        |row| row.get::<_, String>(0),
    )?;
    let mut matches = HashSet::new();
    for row in mapped {
        if let Ok(v) = row {
            matches.insert(v);
        }
    }
    Ok(matches)
}

pub fn spawn_legacy_deleted_backup_repair(
    state: Arc<AppState>,
    organization_id: i32,
    user_id: String,
) {
    let repair_key = format!("{}:{}", organization_id, user_id);
    {
        let mut running = LEGACY_DELETED_BACKUP_REPAIRS.lock();
        if !running.insert(repair_key.clone()) {
            return;
        }
    }

    tokio::spawn(async move {
        let result =
            repair_legacy_deleted_backups_batch(state.as_ref(), organization_id, &user_id, 250)
                .await;
        if let Err(err) = result {
            tracing::warn!(
                "[DELETED-BACKUPS] legacy repair failed org={} user={} err={}",
                organization_id,
                user_id,
                err
            );
        }
        LEGACY_DELETED_BACKUP_REPAIRS.lock().remove(&repair_key);
    });
}

async fn repair_legacy_deleted_backups_batch(
    state: &AppState,
    organization_id: i32,
    user_id: &str,
    limit: usize,
) -> Result<usize> {
    let limit = limit.clamp(1, 1000) as i64;
    let rows: Vec<(String, i64)> = if let Some(pg) = &state.pg_client {
        let rows = pg
            .query(
                "SELECT p.asset_id, COALESCE(p.delete_time, 0) AS deleted_at
                 FROM photos p
                 WHERE p.organization_id = $1 AND p.user_id = $2
                   AND COALESCE(p.delete_time, 0) > 0
                   AND (
                        COALESCE(p.backup_id, '') = ''
                        OR NOT EXISTS (
                            SELECT 1
                            FROM deleted_upload_tombstones t
                            WHERE t.organization_id = p.organization_id
                              AND t.user_id = p.user_id
                              AND t.source_asset_id = p.asset_id
                        )
                   )
                 ORDER BY COALESCE(p.delete_time, 0) DESC, p.asset_id ASC
                 LIMIT $3",
                &[&organization_id, &user_id, &limit],
            )
            .await?;
        rows.into_iter()
            .map(|row| (row.get::<_, String>(0), row.get::<_, i64>(1)))
            .collect()
    } else {
        let data_db = state.get_user_data_database(user_id)?;
        let conn = data_db.lock();
        let mut stmt = conn.prepare(
            "SELECT p.asset_id, COALESCE(p.delete_time, 0) AS deleted_at
             FROM photos p
             WHERE p.organization_id = ? AND p.user_id = ?
               AND COALESCE(p.delete_time, 0) > 0
               AND (
                    COALESCE(p.backup_id, '') = ''
                    OR NOT EXISTS (
                        SELECT 1
                        FROM deleted_upload_tombstones t
                        WHERE t.organization_id = p.organization_id
                          AND t.user_id = p.user_id
                          AND t.source_asset_id = p.asset_id
                    )
               )
             ORDER BY COALESCE(p.delete_time, 0) DESC, p.asset_id ASC
             LIMIT ?",
        )?;
        let mapped = stmt.query_map(duckdb::params![organization_id, user_id, limit], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
        })?;
        let mut out = Vec::new();
        for row in mapped {
            if let Ok(v) = row {
                out.push(v);
            }
        }
        out
    };

    let mut repaired = 0usize;
    for (asset_id, deleted_at) in rows {
        let touched = upsert_deleted_tombstones_for_asset(
            state,
            organization_id,
            user_id,
            &asset_id,
            deleted_at,
        )
        .await?;
        if touched > 0 {
            repaired += 1;
        }
    }
    if repaired > 0 {
        tracing::info!(
            "[DELETED-BACKUPS] legacy repair org={} user={} repaired={}",
            organization_id,
            user_id,
            repaired
        );
    }
    Ok(repaired)
}
