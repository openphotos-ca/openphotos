use crate::photos::asset_id;
use crate::server::state::AppState;
use axum::{
    extract::{Path, Query, State},
    http::{header, HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    Json,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::sync::Arc;
//

fn if_none_match_allows_304(headers: &HeaderMap, etag: &str) -> bool {
    let Some(v) = headers.get(header::IF_NONE_MATCH) else {
        return false;
    };
    let Ok(s) = v.to_str() else {
        return false;
    };
    let s = s.trim();
    if s == "*" {
        return true;
    }
    s.split(',')
        .map(|p| p.trim())
        .any(|candidate| candidate == etag)
}

fn add_private_cache_headers(resp: &mut Response, etag: Option<&str>) {
    resp.headers_mut().insert(
        header::CACHE_CONTROL,
        axum::http::HeaderValue::from_static("private, max-age=0, must-revalidate"),
    );
    if let Some(etag) = etag {
        resp.headers_mut().insert(
            header::ETAG,
            axum::http::HeaderValue::from_str(etag).unwrap(),
        );
    }
}

fn weak_etag_sha256(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    format!("W/\"{:x}\"", hasher.finalize())
}

#[derive(Debug, Serialize, Deserialize)]
pub struct PersonResponse {
    pub person_id: String,
    pub display_name: Option<String>,
    pub birth_date: Option<String>,
    // face_count retained for backward compatibility; photo_count used by web
    pub face_count: i32,
    pub photo_count: i32,
    pub thumbnail: String, // Base64 encoded thumbnail or URL
}

#[derive(Debug, Serialize, Deserialize)]
pub struct FaceFilterRequest {
    pub person_id: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct FaceFilterItem {
    pub asset_id: String,
    pub time_ms: Option<i64>,
    pub is_video: bool,
    pub duration_ms: Option<i64>,
    pub filename: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct FaceFilterResponse {
    pub items: Vec<FaceFilterItem>,
}

#[derive(Debug, Deserialize)]
pub struct FaceThumbnailQuery {
    #[serde(rename = "personId")]
    pub person_id: String,
}

#[derive(Debug, Deserialize)]
pub struct MergeFacesRequest {
    pub target_person_id: String,
    pub source_person_ids: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct MergeFacesResponse {
    pub target_person_id: String,
    pub merged_sources: Vec<String>,
    pub updated_face_count: i64,
}

#[derive(Debug, Deserialize)]
pub struct DeletePersonsRequest {
    pub person_ids: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct DeletePersonsResponse {
    pub deleted: usize,
}

// Removed: any dependency on face_output folder for deriving person mappings

/// Get all detected persons/faces
pub async fn get_faces(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Json<Vec<PersonResponse>>, StatusCode> {
    // Verify token (Authorization or Cookie)
    let token_opt = headers
        .get(header::AUTHORIZATION)
        .and_then(|h| h.to_str().ok())
        .and_then(|h| h.strip_prefix("Bearer "))
        .map(|s| s.to_string())
        .or_else(|| {
            headers
                .get(header::COOKIE)
                .and_then(|v| v.to_str().ok())
                .and_then(|cookie| {
                    cookie
                        .split(';')
                        .map(|c| c.trim())
                        .find_map(|c| c.strip_prefix("auth-token=").map(|s| s.to_string()))
                })
        });
    let token = token_opt
        .ok_or(StatusCode::UNAUTHORIZED)
        .map_err(|_| StatusCode::UNAUTHORIZED)?;
    let user = state
        .auth_service
        .verify_token(&token)
        .await
        .map_err(|_| StatusCode::UNAUTHORIZED)?;

    let mut persons = Vec::new();
    if let Some(pg) = &state.pg_client {
        let rows = pg
            .query(
                // Count only visible (unlocked, not deleted) assets for each person, scoped to
                // the current user's library within the organization.
                // Return all discovered persons (up to a practical cap) to avoid hiding small clusters.
                // Cast birth_date to text for robust JSON serialization.
                "WITH person_counts AS (\n                  SELECT f.person_id,\n                         COALESCE(p.display_name, f.person_id) AS display_name,\n                         CAST(p.birth_date AS VARCHAR) AS birth_date,\n                         COUNT(DISTINCT f.asset_id) AS cnt\n                  FROM faces f\n                  LEFT JOIN persons p ON p.person_id = f.person_id AND p.organization_id = f.organization_id\n                  JOIN photos dp ON dp.asset_id = f.asset_id AND dp.organization_id = f.organization_id\n                  WHERE f.organization_id = $1 AND dp.user_id = $2 AND f.person_id IS NOT NULL\n                    AND COALESCE(dp.locked, FALSE) = FALSE AND COALESCE(dp.delete_time, 0) = 0\n                  GROUP BY f.person_id, COALESCE(p.display_name, f.person_id), p.birth_date\n                )\n                SELECT person_id, display_name, birth_date, cnt\n                FROM person_counts\n                ORDER BY cnt DESC, person_id\n                LIMIT 500",
                &[&user.organization_id, &user.user_id],
            )
            .await
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
        for r in rows {
            let cnt: i64 = r.get(3);
            if cnt > 0 {
                persons.push(PersonResponse {
                    person_id: r.get::<_, String>(0),
                    display_name: Some(r.get::<_, String>(1)),
                    birth_date: r.get::<_, Option<String>>(2),
                    face_count: cnt as i32,
                    photo_count: cnt as i32,
                    thumbnail: String::new(),
                });
            }
        }
    } else {
        let db = state
            .get_user_embedding_database(&user.user_id)
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
        let conn = db.lock();
        // DuckDB mode: count only assets visible to the user (unlocked, not deleted)
        let sql = "WITH person_counts AS (\n\
                          SELECT f.person_id,\n\
                                 COALESCE(p.display_name, f.person_id) AS display_name,\n\
                                 p.birth_date,\n\
                                 COUNT(DISTINCT f.asset_id) AS cnt\n\
                          FROM faces_embed f\n\
                          LEFT JOIN persons p ON p.person_id = f.person_id\n\
                          JOIN photos dp ON dp.asset_id = f.asset_id AND dp.organization_id = ? AND dp.user_id = ?\n\
                          WHERE f.person_id IS NOT NULL AND COALESCE(dp.locked, FALSE) = FALSE AND COALESCE(dp.delete_time, 0) = 0\n\
                          GROUP BY f.person_id, COALESCE(p.display_name, f.person_id), p.birth_date\n\
                        )\n\
                        SELECT person_id, display_name, birth_date, cnt\n\
                        FROM person_counts\n\
                        ORDER BY cnt DESC, person_id\n\
                        LIMIT 500";
        if let Ok(mut stmt) = conn.prepare(sql) {
            if let Ok(rows) = stmt.query_map(
                duckdb::params![user.organization_id, &user.user_id],
                |row| {
                    Ok(PersonResponse {
                        person_id: row.get(0)?,
                        display_name: Some(row.get::<_, String>(1)?),
                        birth_date: row.get::<_, Option<String>>(2).ok().flatten(),
                        face_count: row.get::<_, i64>(3)? as i32,
                        photo_count: row.get::<_, i64>(3)? as i32,
                        thumbnail: String::new(),
                    })
                },
            ) {
                for r in rows {
                    if let Ok(p) = r {
                        if p.face_count > 0 {
                            persons.push(p);
                        }
                    }
                }
            }
        }
    }

    // Fallback: use in-memory face clustering cache if DB has no persons yet
    // This helps the UI show faces after clustering, but avoids any disk folder reliance.
    if persons.is_empty() {
        // Try to read clustered persons from the face service cache
        if let Some(cluster) = state.face_service.get_cached_clusters() {
            tracing::info!(
                "[FACES] Using cached clusters ({} persons)",
                cluster.person_mapping.len()
            );
            for (person_id, photos) in cluster.person_mapping.iter() {
                persons.push(PersonResponse {
                    person_id: person_id.clone(),
                    display_name: Some(person_id.clone()),
                    birth_date: None,
                    face_count: photos.len() as i32,
                    photo_count: photos.len() as i32,
                    thumbnail: String::new(),
                });
            }
            // Sort by face count desc for consistent UI ordering
            persons.sort_by(|a, b| b.face_count.cmp(&a.face_count));
        }
    }
    // Faces and photos live in the same global DB; no detach needed

    tracing::info!(
        "[FACES] Returning {} persons for user={} (intersected with photos)",
        persons.len(),
        user.user_id
    );

    Ok(Json(persons))
}

/// Merge multiple source person IDs into a target person ID.
/// - Reassigns faces.person_id from each source to the target
/// - Deletes empty source rows from persons
/// - Updates persons.face_count for the target
pub async fn merge_faces(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(payload): Json<MergeFacesRequest>,
) -> Result<Json<MergeFacesResponse>, StatusCode> {
    // Auth (Authorization or Cookie auth-token)
    let token_opt = headers
        .get(header::AUTHORIZATION)
        .and_then(|h| h.to_str().ok())
        .and_then(|h| h.strip_prefix("Bearer "))
        .map(|s| s.to_string())
        .or_else(|| {
            headers
                .get(header::COOKIE)
                .and_then(|v| v.to_str().ok())
                .and_then(|cookie| {
                    cookie
                        .split(';')
                        .map(|c| c.trim())
                        .find_map(|c| c.strip_prefix("auth-token=").map(|s| s.to_string()))
                })
        });
    let token = token_opt.ok_or(StatusCode::UNAUTHORIZED)?;
    let user = state
        .auth_service
        .verify_token(&token)
        .await
        .map_err(|_| StatusCode::UNAUTHORIZED)?;

    // Extract target and sources for merge
    let target = payload.target_person_id.trim();
    let sources: Vec<String> = payload
        .source_person_ids
        .iter()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty() && s != target)
        .collect();
    if sources.is_empty() {
        return Err(StatusCode::BAD_REQUEST);
    }

    if let Some(pg) = &state.pg_client {
        let _ = pg
            .execute(
                "INSERT INTO persons (organization_id, person_id, display_name) VALUES ($1, $2, NULL) ON CONFLICT (organization_id, person_id) DO NOTHING",
                &[&user.organization_id, &target],
            )
            .await;
        for s in &sources {
            let _ = pg
                .execute(
                    "UPDATE faces SET person_id = $1 WHERE organization_id = $2 AND person_id = $3",
                    &[&target, &user.organization_id, s],
                )
                .await;
        }
        let mut updated_face_count: i64 = 0;
        if let Ok(rows) = pg
            .query(
                "SELECT COUNT(DISTINCT asset_id) FROM faces WHERE organization_id = $1 AND person_id = $2",
                &[&user.organization_id, &target],
            )
            .await
        {
            if let Some(r) = rows.first() {
                updated_face_count = r.get::<_, i64>(0);
            }
        }
        let _ = pg
            .execute(
                "UPDATE persons SET face_count = $1, updated_at = NOW() WHERE organization_id = $2 AND person_id = $3",
                &[&updated_face_count, &user.organization_id, &target],
            )
            .await;
        for s in &sources {
            if let Ok(rows) = pg
                .query(
                    "SELECT COUNT(*) FROM faces WHERE organization_id = $1 AND person_id = $2",
                    &[&user.organization_id, s],
                )
                .await
            {
                if let Some(r) = rows.first() {
                    let cnt: i64 = r.get(0);
                    if cnt == 0 {
                        let _ = pg
                            .execute(
                                "DELETE FROM persons WHERE organization_id = $1 AND person_id = $2",
                                &[&user.organization_id, s],
                            )
                            .await;
                    }
                }
            }
        }
        return Ok(Json(MergeFacesResponse {
            target_person_id: target.to_string(),
            merged_sources: sources.clone(),
            updated_face_count,
        }));
    }
    let db = state
        .get_user_embedding_database(&user.user_id)
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    let conn = db.lock();

    // Ensure target exists
    let _ = conn.execute(
        "INSERT OR IGNORE INTO persons (person_id, display_name, face_count) VALUES (?, NULL, 0)",
        [target],
    );

    // Reassign faces from each source to target
    for s in &sources {
        // Restrict reassignment to this user's organization via photos
        let _ = conn.execute(
            "UPDATE faces_embed SET person_id = ? \
             WHERE face_id IN ( \
               SELECT f.face_id FROM faces_embed f \
               JOIN photos dp ON dp.asset_id = f.asset_id \
               WHERE dp.organization_id = ? AND f.person_id = ? \
             )",
            duckdb::params![target, user.organization_id, s],
        );
    }

    // Update face_count for target based on reassigned faces for this user (count distinct asset faces)
    let mut updated_face_count: i64 = 0;
    if let Ok(mut stmt) = conn.prepare(
        "SELECT COUNT(DISTINCT f.asset_id) FROM faces_embed f JOIN photos dp ON dp.asset_id = f.asset_id WHERE dp.organization_id = ? AND dp.user_id = ? AND f.person_id = ?",
    ) {
        let _ = stmt.query_row(duckdb::params![user.organization_id, &user.user_id, target], |row| {
            updated_face_count = row.get::<_, i64>(0)?;
            Ok(())
        });
    }
    let _ = conn.execute(
        "UPDATE persons SET face_count = ?, updated_at = CURRENT_TIMESTAMP WHERE person_id = ?",
        [updated_face_count.to_string(), target.to_string()],
    );

    // Delete now-empty source person rows
    for s in &sources {
        // Delete person row only if no faces remain for this user
        let mut cnt: i64 = 0;
        if let Ok(mut stmt) =
            conn.prepare("SELECT COUNT(*) FROM faces_embed WHERE user_id = ? AND person_id = ?")
        {
            let _ = stmt.query_row(duckdb::params![&user.user_id, s], |row| {
                cnt = row.get::<_, i64>(0)?;
                Ok(())
            });
        }
        if cnt == 0 {
            let _ = conn.execute("DELETE FROM persons WHERE person_id = ?", [s]);
        }
    }

    // Checkpoint to persist
    let _ = conn.execute("CHECKPOINT;", []);

    Ok(Json(MergeFacesResponse {
        target_person_id: target.to_string(),
        merged_sources: sources,
        updated_face_count,
    }))
}

/// Delete persons (and their associated faces) entirely.
pub async fn delete_persons(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(payload): Json<DeletePersonsRequest>,
) -> Result<Json<DeletePersonsResponse>, StatusCode> {
    // Auth
    let token_opt = headers
        .get(header::AUTHORIZATION)
        .and_then(|h| h.to_str().ok())
        .and_then(|h| h.strip_prefix("Bearer "))
        .map(|s| s.to_string())
        .or_else(|| {
            headers
                .get(header::COOKIE)
                .and_then(|v| v.to_str().ok())
                .and_then(|cookie| {
                    cookie
                        .split(';')
                        .map(|c| c.trim())
                        .find_map(|c| c.strip_prefix("auth-token=").map(|s| s.to_string()))
                })
        });
    let token = token_opt.ok_or(StatusCode::UNAUTHORIZED)?;
    let user = state
        .auth_service
        .verify_token(&token)
        .await
        .map_err(|_| StatusCode::UNAUTHORIZED)?;

    let ids: Vec<String> = payload
        .person_ids
        .into_iter()
        .filter(|s| !s.trim().is_empty())
        .collect();
    if ids.is_empty() {
        return Err(StatusCode::BAD_REQUEST);
    }
    if let Some(pg) = &state.pg_client {
        for pid in &ids {
            let _ = pg
                .execute(
                    "UPDATE faces SET person_id = NULL WHERE organization_id = $1 AND person_id = $2",
                    &[&user.organization_id, pid],
                )
                .await;
            if let Ok(rows) = pg
                .query(
                    "SELECT COUNT(*) FROM faces WHERE organization_id = $1 AND person_id = $2",
                    &[&user.organization_id, pid],
                )
                .await
            {
                if let Some(r) = rows.first() {
                    let cnt: i64 = r.get(0);
                    if cnt == 0 {
                        let _ = pg
                            .execute(
                                "DELETE FROM persons WHERE organization_id = $1 AND person_id = $2",
                                &[&user.organization_id, pid],
                            )
                            .await;
                    }
                }
            }
        }
        return Ok(Json(DeletePersonsResponse { deleted: ids.len() }));
    }
    let db = state
        .get_user_embedding_database(&user.user_id)
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    let conn = db.lock();
    for pid in &ids {
        let _ = conn.execute(
            "UPDATE faces_embed SET person_id = NULL WHERE user_id = ? AND person_id = ?",
            duckdb::params![&user.user_id, pid],
        );
        // Only delete the person row entirely if no faces remain across any users.
        // This keeps person IDs global, but face assignments per-user.
        let mut cnt: i64 = 0;
        if let Ok(mut stmt) = conn.prepare("SELECT COUNT(*) FROM faces_embed WHERE person_id = ?") {
            let _ = stmt.query_row([pid], |row| {
                cnt = row.get::<_, i64>(0)?;
                Ok(())
            });
        }
        if cnt == 0 {
            let _ = conn.execute("DELETE FROM persons WHERE person_id = ?", [pid]);
        }
    }
    let _ = conn.execute("CHECKPOINT;", []);

    Ok(Json(DeletePersonsResponse { deleted: ids.len() }))
}

#[derive(Debug, Deserialize)]
pub struct UpdatePersonRequest {
    pub display_name: Option<String>,
    pub birth_date: Option<String>, // YYYY-MM-DD
}

/// Update or create a person record (name, birth_date)
pub async fn update_person(
    State(state): State<Arc<AppState>>,
    Path(person_id): Path<String>,
    headers: HeaderMap,
    Json(payload): Json<UpdatePersonRequest>,
) -> Result<Response, StatusCode> {
    // Auth
    let token_opt = headers
        .get(header::AUTHORIZATION)
        .and_then(|h| h.to_str().ok())
        .and_then(|h| h.strip_prefix("Bearer "))
        .map(|s| s.to_string())
        .or_else(|| {
            headers
                .get(header::COOKIE)
                .and_then(|v| v.to_str().ok())
                .and_then(|cookie| {
                    cookie
                        .split(';')
                        .map(|c| c.trim())
                        .find_map(|c| c.strip_prefix("auth-token=").map(|s| s.to_string()))
                })
        });
    let token = token_opt.ok_or(StatusCode::UNAUTHORIZED)?;
    let user = state
        .auth_service
        .verify_token(&token)
        .await
        .map_err(|_| StatusCode::UNAUTHORIZED)?;

    if let Some(pg) = &state.pg_client {
        let _ = pg
            .execute(
                "INSERT INTO persons (organization_id, person_id, display_name) VALUES ($1, $2, NULL) ON CONFLICT (organization_id, person_id) DO NOTHING",
                &[&user.organization_id, &person_id],
            )
            .await
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
        if let Some(name) = payload.display_name.clone() {
            let _ = pg
                .execute(
                    "UPDATE persons SET display_name = $1, updated_at = NOW() WHERE organization_id = $2 AND person_id = $3",
                    &[&name, &user.organization_id, &person_id],
                )
                .await;
        }
        if let Some(birth) = payload.birth_date.clone() {
            let _ = pg
                .execute(
                    "UPDATE persons SET birth_date = $1, updated_at = NOW() WHERE organization_id = $2 AND person_id = $3",
                    &[&birth, &user.organization_id, &person_id],
                )
                .await;
        }
        let mut display_name = None;
        let mut birth_date = None;
        let mut face_count = 0_i64;
        if let Ok(rows) = pg
            .query(
                // Cast to stable types: birth_date→text, face_count→bigint; coalesce face_count to 0
                "SELECT display_name, CAST(birth_date AS VARCHAR) AS birth_date, COALESCE((face_count)::bigint, 0) AS face_count\n                 FROM persons WHERE organization_id = $1 AND person_id = $2 LIMIT 1",
                &[&user.organization_id, &person_id],
            )
            .await
        {
            if let Some(r) = rows.first() {
                display_name = r.get::<_, Option<String>>(0);
                birth_date = r.get::<_, Option<String>>(1);
                face_count = r.get::<_, i64>(2);
            }
        }
        let resp = serde_json::json!({
            "person_id": person_id,
            "display_name": display_name,
            "birth_date": birth_date,
            "face_count": face_count
        });
        return Ok((StatusCode::OK, Json(resp)).into_response());
    }
    let db = state
        .get_user_embedding_database(&user.user_id)
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    let conn = db.lock();
    let _ = conn.execute(
        "INSERT OR IGNORE INTO persons (person_id, display_name, face_count) VALUES (?, NULL, 0)",
        [&person_id],
    );
    // Update fields
    if let Some(name) = &payload.display_name {
        let _ = conn.execute("UPDATE persons SET display_name = ?, updated_at = CURRENT_TIMESTAMP WHERE person_id = ?", [name, &person_id]);
    }
    if let Some(birth) = &payload.birth_date {
        // Add column if missing (best-effort)
        let _ = conn.execute(
            "ALTER TABLE persons ADD COLUMN IF NOT EXISTS birth_date VARCHAR",
            [],
        );
        let _ = conn.execute(
            "UPDATE persons SET birth_date = ?, updated_at = CURRENT_TIMESTAMP WHERE person_id = ?",
            [birth, &person_id],
        );
    }

    // Force a checkpoint so metadata persists even if a WAL is present
    let _ = conn.execute("CHECKPOINT;", []);

    // Return merged record
    let mut display_name: Option<String> = None;
    let mut birth_date: Option<String> = None;
    let mut face_count: i64 = 0;
    if let Ok(mut stmt) = conn.prepare(
        "SELECT display_name, birth_date, face_count FROM persons WHERE person_id = ? LIMIT 1",
    ) {
        let _ = stmt.query_row([&person_id], |row| {
            display_name = row.get::<_, Option<String>>(0).ok().flatten();
            birth_date = row.get::<_, Option<String>>(1).ok().flatten();
            face_count = row.get::<_, i64>(2).unwrap_or(0);
            Ok(())
        });
    }

    let resp = serde_json::json!({
        "person_id": person_id,
        "display_name": display_name,
        "birth_date": birth_date,
        "face_count": face_count
    });
    Ok((StatusCode::OK, Json(resp)).into_response())
}

/// Persons on a given asset (photo/video)
pub async fn get_persons_for_asset(
    State(state): State<Arc<AppState>>,
    Path(asset_id): Path<String>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, StatusCode> {
    // Auth
    let token_opt = headers
        .get(header::AUTHORIZATION)
        .and_then(|h| h.to_str().ok())
        .and_then(|h| h.strip_prefix("Bearer "))
        .map(|s| s.to_string())
        .or_else(|| {
            headers
                .get(header::COOKIE)
                .and_then(|v| v.to_str().ok())
                .and_then(|cookie| {
                    cookie
                        .split(';')
                        .map(|c| c.trim())
                        .find_map(|c| c.strip_prefix("auth-token=").map(|s| s.to_string()))
                })
        });
    let token = token_opt.ok_or(StatusCode::UNAUTHORIZED)?;
    let user = state
        .auth_service
        .verify_token(&token)
        .await
        .map_err(|_| StatusCode::UNAUTHORIZED)?;

    if let Some(pg) = &state.pg_client {
        let mut out = Vec::new();
        if let Ok(rows) = pg
            .query(
                "SELECT DISTINCT f.person_id, COALESCE(p.display_name, f.person_id) as display_name, p.birth_date FROM faces f LEFT JOIN persons p ON p.person_id = f.person_id AND p.organization_id = f.organization_id WHERE f.organization_id = $1 AND f.asset_id = $2 ORDER BY display_name",
                &[&user.organization_id, &asset_id],
            )
            .await
        {
            for r in rows {
                out.push(serde_json::json!({
                    "person_id": r.get::<_, String>(0),
                    "display_name": r.get::<_, Option<String>>(1),
                    "birth_date": r.get::<_, Option<String>>(2)
                }));
            }
        }
        return Ok(Json(out));
    }
    let db = state
        .get_user_embedding_database(&user.user_id)
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    let conn = db.lock();
    let sql = "SELECT DISTINCT f.person_id, COALESCE(p.display_name, f.person_id) as display_name, p.birth_date
               FROM faces_embed f LEFT JOIN persons p ON p.person_id = f.person_id
               WHERE f.asset_id = ? AND f.user_id = ? ORDER BY display_name";
    let mut rows = Vec::new();
    if let Ok(mut stmt) = conn.prepare(sql) {
        let iter = stmt
            .query_map(duckdb::params![&asset_id, &user.user_id], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, Option<String>>(1)?,
                    row.get::<_, Option<String>>(2)?,
                ))
            })
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
        for r in iter {
            if let Ok((pid, name, birth)) = r {
                rows.push(serde_json::json!({"person_id": pid, "display_name": name, "birth_date": birth}));
            }
        }
    }
    Ok(Json(rows))
}

/// Filter photos by person ID
pub async fn filter_photos_by_person(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(request): Json<FaceFilterRequest>,
) -> Result<Json<FaceFilterResponse>, StatusCode> {
    tracing::info!("[FACES] Filter request person_id={}", request.person_id);
    // Verify token and get user's embedding DB
    let token_opt = headers
        .get(header::AUTHORIZATION)
        .and_then(|h| h.to_str().ok())
        .and_then(|h| h.strip_prefix("Bearer "))
        .map(|s| s.to_string())
        .or_else(|| {
            headers
                .get(header::COOKIE)
                .and_then(|v| v.to_str().ok())
                .and_then(|cookie| {
                    cookie
                        .split(';')
                        .map(|c| c.trim())
                        .find_map(|c| c.strip_prefix("auth-token=").map(|s| s.to_string()))
                })
        });
    let token = token_opt
        .ok_or(StatusCode::UNAUTHORIZED)
        .map_err(|_| StatusCode::UNAUTHORIZED)?;
    let user = state
        .auth_service
        .verify_token(&token)
        .await
        .map_err(|_| StatusCode::UNAUTHORIZED)?;
    tracing::info!(
        "[FACES] Filter resolved auth org_id={} user_id={} person_id={}",
        user.organization_id,
        user.user_id,
        request.person_id
    );

    // Primary: query faces by backend
    let mut items: Vec<FaceFilterItem> = Vec::new();
    if let Some(pg) = &state.pg_client {
        tracing::info!(
            "[FACES] PG filter query org_id={} person_id={}",
            user.organization_id,
            request.person_id
        );
        match pg
            .query(
                "SELECT f.asset_id, MIN(f.time_ms) AS t\n                 FROM faces f\n                 JOIN photos dp ON dp.asset_id = f.asset_id AND dp.organization_id = f.organization_id\n                 WHERE f.organization_id = $1 AND f.person_id = $2\n                   AND COALESCE(dp.locked, FALSE) = FALSE AND COALESCE(dp.delete_time, 0) = 0\n                 GROUP BY f.asset_id\n                 ORDER BY MAX(dp.created_at) DESC",
                &[&user.organization_id, &request.person_id],
            )
            .await
        {
            Ok(rows) => {
                let mut preview: Vec<String> = Vec::new();
                for r in rows.iter() {
                    let id: String = r.get::<_, String>(0);
                    if preview.len() < 5 {
                        preview.push(id.clone());
                    }
                    items.push(FaceFilterItem {
                        asset_id: id,
                        time_ms: r.get::<_, Option<i64>>(1),
                        is_video: false,
                        duration_ms: None,
                        filename: None,
                    });
                }
                tracing::info!(
                    "[FACES] PG filter returned {} asset_ids (sample: {:?})",
                    items.len(),
                    preview
                );
                if items.is_empty() {
                    // Best-effort diagnostics to understand emptiness
                    if let Ok(r) = pg
                        .query(
                            "SELECT COUNT(*) FROM faces WHERE organization_id=$1",
                            &[&user.organization_id],
                        )
                        .await
                    {
                        if let Some(rr) = r.first() {
                            let c: i64 = rr.get(0);
                            tracing::info!("[FACES][diag] faces total={} (org)", c);
                        }
                    }
                    if let Ok(r) = pg
                        .query(
                            "SELECT COUNT(*), COUNT(DISTINCT asset_id) FROM faces WHERE organization_id=$1 AND person_id=$2",
                            &[&user.organization_id, &request.person_id],
                        )
                        .await
                    {
                        if let Some(rr) = r.first() {
                            let c_all: i64 = rr.get(0);
                            let c_assets: i64 = rr.get(1);
                            tracing::info!(
                                "[FACES][diag] faces for person={} rows={} distinct_assets={}",
                                request.person_id,
                                c_all,
                                c_assets
                            );
                        }
                    }
                    if let Ok(r) = pg
                        .query(
                            "SELECT COUNT(*) FROM photos WHERE organization_id=$1 AND COALESCE(locked,FALSE)=FALSE AND COALESCE(delete_time,0)=0",
                            &[&user.organization_id],
                        )
                        .await
                    {
                        if let Some(rr) = r.first() {
                            let c: i64 = rr.get(0);
                            tracing::info!("[FACES][diag] photos visible (org)={} ", c);
                        }
                    }
                }
            }
            Err(e) => {
                tracing::warn!("[FACES] PG filter query failed err={}", e);
            }
        }
    } else {
        // Use an independent read connection to avoid blocking the global DuckDB mutex for large
        // result sets (a person can have hundreds/thousands of assets).
        let conn = state
            .multi_tenant_db
            .as_ref()
            .ok_or(StatusCode::INTERNAL_SERVER_ERROR)?
            .open_reader()
            .map_err(|e| {
                tracing::warn!("[FACES] DuckDB open_reader failed: {}", e);
                StatusCode::INTERNAL_SERVER_ERROR
            })?;
        let sql = "SELECT f.asset_id, MIN(f.time_ms) AS t FROM faces_embed f \
                   JOIN photos dp ON dp.asset_id = f.asset_id AND dp.organization_id = ? AND dp.user_id = ? \
                   WHERE f.person_id = ? AND COALESCE(dp.locked, FALSE) = FALSE AND COALESCE(dp.delete_time, 0) = 0 \
                   GROUP BY f.asset_id ORDER BY MIN(f.created_at) DESC";
        if let Ok(mut stmt) = conn.prepare(sql) {
            tracing::info!(
                "[FACES] DuckDB filter query org_id={} user_id={} person_id={}",
                user.organization_id,
                user.user_id,
                request.person_id
            );
            if let Ok(rows) = stmt.query_map(
                duckdb::params![user.organization_id, &user.user_id, &request.person_id],
                |row| {
                    Ok(FaceFilterItem {
                        asset_id: row.get::<_, String>(0)?,
                        time_ms: row.get::<_, Option<i64>>(1).ok().flatten(),
                        is_video: false,
                        duration_ms: None,
                        filename: None,
                    })
                },
            ) {
                for r in rows {
                    if let Ok(item) = r {
                        items.push(item);
                    }
                }
                tracing::info!("[FACES] DuckDB filter returned {} asset_ids", items.len());
            }
        }
    }

    // Fallback: use in-memory cache person_mapping → filenames, then map to asset_ids via user's photos table
    if items.is_empty() {
        if let Some(cluster) = state.face_service.get_cached_clusters() {
            if let Some(filenames) = cluster.person_mapping.get(&request.person_id) {
                if !filenames.is_empty() {
                    tracing::info!(
                        "[FACES] Fallback via cached clusters: {} filenames",
                        filenames.len()
                    );
                    // Prefer `open_reader()` to avoid blocking the global DuckDB lock.
                    if let Some(db) = &state.multi_tenant_db {
                        if let Ok(conn2) = db.open_reader() {
                            for name in filenames {
                                // Try exact common extensions first
                                let candidates = [
                                    format!("{}.jpg", name),
                                    format!("{}.jpeg", name),
                                    format!("{}.JPG", name),
                                    format!("{}.JPEG", name),
                                    format!("{}.png", name),
                                    format!("{}.PNG", name),
                                    format!("{}.webp", name),
                                    format!("{}.WEBP", name),
                                ];
                                let mut found: Option<String> = None;
                                for cand in candidates.iter() {
                                    if let Ok(asset_id) = conn2.query_row(
                                            "SELECT asset_id FROM photos WHERE organization_id = ? AND filename = ? LIMIT 1",
                                            duckdb::params![user.organization_id, &cand],
                                            |row| row.get::<_, String>(0),
                                        ) {
                                            found = Some(asset_id);
                                            break;
                                        }
                                }
                                if found.is_none() {
                                    // Fallback: prefix match (handles unknown extensions)
                                    let like = format!("{}.%", name);
                                    if let Ok(asset_id) = conn2.query_row(
                                            "SELECT asset_id FROM photos WHERE organization_id = ? AND filename ILIKE ? LIMIT 1",
                                            duckdb::params![user.organization_id, &like],
                                            |row| row.get::<_, String>(0),
                                        ) {
                                            found = Some(asset_id);
                                        }
                                }
                                if let Some(id) = found {
                                    items.push(FaceFilterItem {
                                        asset_id: id,
                                        time_ms: None,
                                        is_video: false,
                                        duration_ms: None,
                                        filename: None,
                                    });
                                }
                            }
                            tracing::info!(
                                "[FACES] Fallback mapped {} filenames to {} assets",
                                filenames.len(),
                                items.len()
                            );
                        }
                    }
                }
            }
        }
    }

    // Enrich with media metadata (is_video, duration_ms, filename)
    if !items.is_empty() {
        // Prefer `open_reader()` to avoid blocking the global DuckDB lock for large result sets.
        if let Some(db) = &state.multi_tenant_db {
            if let Ok(conn2) = db.open_reader() {
                // Track which asset_ids are locked to filter them out
                let mut locked_ids: std::collections::HashSet<String> =
                    std::collections::HashSet::new();
                let mut enriched: usize = 0;
                if let Ok(mut stmt) = conn2.prepare(
                    "SELECT is_video, duration_ms, filename, COALESCE(locked, FALSE) FROM photos WHERE organization_id = ? AND asset_id = ? LIMIT 1",
                ) {
                    for item in items.iter_mut() {
                        if let Ok((is_video, duration_ms_opt, fname, locked)) = stmt.query_row(
                            duckdb::params![user.organization_id, &item.asset_id],
                            |row| {
                                Ok::<(bool, Option<i64>, String, bool), duckdb::Error>((
                                    row.get(0)?,
                                    row.get(1).ok(),
                                    row.get(2)?,
                                    row.get(3)?,
                                ))
                            },
                        ) {
                            if locked {
                                locked_ids.insert(item.asset_id.clone());
                                continue;
                            }
                            item.is_video = is_video;
                            item.duration_ms = duration_ms_opt;
                            item.filename = Some(fname);
                            enriched += 1;
                        }
                    }
                }
                if !locked_ids.is_empty() {
                    let before = items.len();
                    items.retain(|it| !locked_ids.contains(&it.asset_id));
                    tracing::info!(
                        "[FACES] Filtered out {} locked assets ({} -> {})",
                        locked_ids.len(),
                        before,
                        items.len()
                    );
                }
                tracing::info!("[FACES] Enriched {} items with media metadata", enriched);
            }
        }
    }

    // No more fallbacks that depend on on-disk face_output composites

    tracing::info!(
        "[FACES] Filter results person_id={} assets={}",
        request.person_id,
        items.len()
    );
    if let Some(first) = items.get(0) {
        tracing::info!(
            "[FACES] First asset_id for person_id={} => {}",
            request.person_id,
            first.asset_id
        );
    }
    Ok(Json(FaceFilterResponse { items }))
}

/// Get face thumbnail by person ID
pub async fn get_face_thumbnail(
    Query(params): Query<FaceThumbnailQuery>,
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Response, StatusCode> {
    // Try to serve actual face thumbnail from face processing output
    // person_id is already in the format "p1", "p2", etc.
    // Sanitize person_id to avoid cache-buster query params leaking into filename
    let person_id_raw = params.person_id.trim();
    let person_id_sanitized = person_id_raw
        .split(&['?', '&'][..])
        .next()
        .unwrap_or(person_id_raw)
        .to_string();
    let person_id = &person_id_sanitized;
    // Verify token (Authorization or Cookie)
    let token_opt = headers
        .get(header::AUTHORIZATION)
        .and_then(|h| h.to_str().ok())
        .and_then(|h| h.strip_prefix("Bearer "))
        .map(|s| s.to_string())
        .or_else(|| {
            headers
                .get(header::COOKIE)
                .and_then(|v| v.to_str().ok())
                .and_then(|cookie| {
                    cookie
                        .split(';')
                        .map(|c| c.trim())
                        .find_map(|c| c.strip_prefix("auth-token=").map(|s| s.to_string()))
                })
        });
    if let Some(token) = token_opt {
        if let Ok(user) = state.auth_service.verify_token(&token).await {
            // If Postgres backend, try PG first
            if let Some(pg) = &state.pg_client {
                if let Ok(rows) = pg
                    .query(
                        "SELECT f.face_thumbnail FROM persons p JOIN faces f ON f.face_id = p.representative_face_id AND f.organization_id = p.organization_id WHERE p.organization_id = $1 AND p.person_id = $2 AND f.face_thumbnail IS NOT NULL LIMIT 1",
                        &[&user.organization_id, &person_id],
                    )
                    .await
                {
                    if let Some(r) = rows.first() {
                        let blob: Vec<u8> = r.get(0);
                        let etag = weak_etag_sha256(&blob);
                        if if_none_match_allows_304(&headers, &etag) {
                            let mut resp = StatusCode::NOT_MODIFIED.into_response();
                            resp.headers_mut().insert(
                                header::CONTENT_TYPE,
                                axum::http::HeaderValue::from_static("image/jpeg"),
                            );
                            add_private_cache_headers(&mut resp, Some(&etag));
                            return Ok(resp);
                        }
                        let mut resp = (
                            StatusCode::OK,
                            [(header::CONTENT_TYPE, "image/jpeg")],
                            blob,
                        )
                            .into_response();
                        add_private_cache_headers(&mut resp, Some(&etag));
                        return Ok(resp);
                    }
                }
                if let Ok(rows) = pg
                    .query(
                        "SELECT face_thumbnail FROM faces WHERE organization_id=$1 AND person_id = $2 AND COALESCE(is_hidden,false) = FALSE AND face_thumbnail IS NOT NULL LIMIT 1",
                        &[&user.organization_id, &person_id],
                    )
                    .await
                {
                    if let Some(r) = rows.first() {
                        let blob: Vec<u8> = r.get(0);
                        let etag = weak_etag_sha256(&blob);
                        if if_none_match_allows_304(&headers, &etag) {
                            let mut resp = StatusCode::NOT_MODIFIED.into_response();
                            resp.headers_mut().insert(
                                header::CONTENT_TYPE,
                                axum::http::HeaderValue::from_static("image/jpeg"),
                            );
                            add_private_cache_headers(&mut resp, Some(&etag));
                            return Ok(resp);
                        }
                        let mut resp = (
                            StatusCode::OK,
                            [(header::CONTENT_TYPE, "image/jpeg")],
                            blob,
                        )
                            .into_response();
                        add_private_cache_headers(&mut resp, Some(&etag));
                        return Ok(resp);
                    }
                }
            }
            // Try from embedding DB BLOB (DuckDB) (prefer representative face if set)
            if let Ok(db) = state.get_user_embedding_database(&user.user_id) {
                let conn = db.lock();
                // First try representative, scoped by current user
                let sql_rep = "SELECT f.face_thumbnail FROM persons p \
                                JOIN faces_embed f ON f.face_id = p.representative_face_id \
                                WHERE p.person_id = ? AND f.user_id = ? AND f.face_thumbnail IS NOT NULL LIMIT 1";
                if let Ok(mut stmt) = conn.prepare(sql_rep) {
                    if let Ok(mut rows) = stmt
                        .query_map(duckdb::params![person_id, &user.user_id], |row| {
                            row.get::<_, Vec<u8>>(0)
                        })
                    {
                        if let Some(Ok(blob)) = rows.next() {
                            let etag = weak_etag_sha256(&blob);
                            if if_none_match_allows_304(&headers, &etag) {
                                let mut resp = StatusCode::NOT_MODIFIED.into_response();
                                resp.headers_mut().insert(
                                    header::CONTENT_TYPE,
                                    axum::http::HeaderValue::from_static("image/jpeg"),
                                );
                                add_private_cache_headers(&mut resp, Some(&etag));
                                return Ok(resp);
                            }
                            let mut resp =
                                (StatusCode::OK, [(header::CONTENT_TYPE, "image/jpeg")], blob)
                                    .into_response();
                            add_private_cache_headers(&mut resp, Some(&etag));
                            return Ok(resp);
                        }
                    }
                }
                // Fallback: any visible face
                let sql = "SELECT f.face_thumbnail FROM faces_embed f \
                           WHERE f.person_id = ? AND f.user_id = ? AND COALESCE(f.is_hidden, FALSE) = FALSE AND f.face_thumbnail IS NOT NULL LIMIT 1";
                if let Ok(mut stmt) = conn.prepare(sql) {
                    if let Ok(mut rows) = stmt
                        .query_map(duckdb::params![person_id, &user.user_id], |row| {
                            row.get::<_, Vec<u8>>(0)
                        })
                    {
                        if let Some(Ok(blob)) = rows.next() {
                            let etag = weak_etag_sha256(&blob);
                            if if_none_match_allows_304(&headers, &etag) {
                                let mut resp = StatusCode::NOT_MODIFIED.into_response();
                                resp.headers_mut().insert(
                                    header::CONTENT_TYPE,
                                    axum::http::HeaderValue::from_static("image/jpeg"),
                                );
                                add_private_cache_headers(&mut resp, Some(&etag));
                                return Ok(resp);
                            }
                            let mut resp =
                                (StatusCode::OK, [(header::CONTENT_TYPE, "image/jpeg")], blob)
                                    .into_response();
                            add_private_cache_headers(&mut resp, Some(&etag));
                            return Ok(resp);
                        }
                    }
                }
            }
        }
    }

    // Fallback to SVG avatar if DB thumbnail not available
    tracing::warn!("Face thumbnail not available - returning SVG avatar");
    let person_number = person_id.trim_start_matches('p');
    let svg = generate_svg_avatar(person_number.to_string());
    let etag = weak_etag_sha256(svg.as_bytes());
    if if_none_match_allows_304(&headers, &etag) {
        let mut resp = StatusCode::NOT_MODIFIED.into_response();
        resp.headers_mut().insert(
            header::CONTENT_TYPE,
            axum::http::HeaderValue::from_static("image/svg+xml"),
        );
        add_private_cache_headers(&mut resp, Some(&etag));
        return Ok(resp);
    }
    let mut resp = (
        StatusCode::OK,
        [(header::CONTENT_TYPE, "image/svg+xml")],
        svg,
    )
        .into_response();
    add_private_cache_headers(&mut resp, Some(&etag));
    Ok(resp)
}

/// Generate SVG avatar for demo purposes
fn generate_svg_avatar(person_number: String) -> String {
    let colors = ["#3B82F6", "#10B981", "#F59E0B", "#EF4444", "#8B5CF6"];
    let color_index = person_number.parse::<usize>().unwrap_or(1) - 1;
    let color = colors[color_index % colors.len()];

    format!(
        r#"<svg xmlns="http://www.w3.org/2000/svg" width="150" height="150" viewBox="0 0 150 150">
        <rect width="150" height="150" fill="{}20"/>
        <circle cx="75" cy="60" r="25" fill="{}"/>
        <ellipse cx="75" cy="110" rx="35" ry="25" fill="{}"/>
        <text x="75" y="80" text-anchor="middle" fill="white" font-size="24" font-weight="bold">{}</text>
        </svg>"#,
        color, color, color, person_number
    )
}

// ---------- Faces for Asset + Assign Face ----------

#[derive(Debug, Serialize)]
pub struct AssetFaceResponse {
    pub face_id: String,
    pub bbox: [i32; 4], // x, y, w, h
    pub confidence: f32,
    pub person_id: Option<String>,
    pub thumbnail: Option<String>, // data URL if available
}

/// List face detections for a given asset (photo/video)
pub async fn get_faces_for_asset(
    State(state): State<Arc<AppState>>,
    Path(asset_id): Path<String>,
    headers: HeaderMap,
) -> Result<Json<Vec<AssetFaceResponse>>, StatusCode> {
    // Auth via Authorization header or cookie
    let token_opt = headers
        .get(header::AUTHORIZATION)
        .and_then(|h| h.to_str().ok())
        .and_then(|h| h.strip_prefix("Bearer "))
        .map(|s| s.to_string())
        .or_else(|| {
            headers
                .get(header::COOKIE)
                .and_then(|v| v.to_str().ok())
                .and_then(|cookie| {
                    cookie
                        .split(';')
                        .map(|c| c.trim())
                        .find_map(|c| c.strip_prefix("auth-token=").map(|s| s.to_string()))
                })
        });
    let token = token_opt.ok_or(StatusCode::UNAUTHORIZED)?;
    let user = state
        .auth_service
        .verify_token(&token)
        .await
        .map_err(|_| StatusCode::UNAUTHORIZED)?;

    // PG path: read faces from Postgres when enabled
    if let Some(pg) = &state.pg_client {
        let org_id = user.organization_id;
        let rows = pg
            .query(
                "SELECT face_id, bbox_x, bbox_y, bbox_width, bbox_height, confidence, person_id, face_thumbnail \
                 FROM faces WHERE organization_id = $1 AND asset_id = $2 ORDER BY confidence DESC",
                &[&org_id, &asset_id],
            )
            .await
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
        let mut out: Vec<AssetFaceResponse> = Vec::new();
        for row in rows {
            let thumb: Option<Vec<u8>> = row.get::<_, Option<Vec<u8>>>(7);
            let thumb_data = thumb.map(|blob| {
                let b64 = base64::encode(&blob);
                format!("data:image/jpeg;base64,{}", b64)
            });
            out.push(AssetFaceResponse {
                face_id: row.get::<_, String>(0),
                bbox: [
                    row.get::<_, i32>(1),
                    row.get::<_, i32>(2),
                    row.get::<_, i32>(3),
                    row.get::<_, i32>(4),
                ],
                confidence: row.get::<_, f32>(5),
                person_id: row.get::<_, Option<String>>(6),
                thumbnail: thumb_data,
            });
        }
        return Ok(Json(out));
    }

    // DuckDB path: fallback to embedding DB
    let db = state
        .get_user_embedding_database(&user.user_id)
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    let conn = db.lock();

    let sql = "SELECT face_id, bbox_x, bbox_y, bbox_width, bbox_height, confidence, person_id, face_thumbnail \
               FROM faces_embed WHERE asset_id = ? ORDER BY confidence DESC";
    let mut out: Vec<AssetFaceResponse> = Vec::new();
    if let Ok(mut stmt) = conn.prepare(sql) {
        if let Ok(rows) = stmt.query_map([&asset_id], |row| {
            let thumb: Option<Vec<u8>> = row.get::<_, Option<Vec<u8>>>(7).ok().flatten();
            let thumb_data = thumb.map(|blob| {
                let b64 = base64::encode(&blob);
                format!("data:image/jpeg;base64,{}", b64)
            });
            Ok(AssetFaceResponse {
                face_id: row.get(0)?,
                bbox: [row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?],
                confidence: row.get::<_, f64>(5)? as f32,
                person_id: row.get::<_, Option<String>>(6).ok().flatten(),
                thumbnail: thumb_data,
            })
        }) {
            for r in rows {
                if let Ok(item) = r {
                    out.push(item);
                }
            }
        }
    }

    Ok(Json(out))
}

#[derive(Debug, Deserialize)]
pub struct AssignFaceRequest {
    pub person_id: Option<String>, // None/null to unassign
}

#[derive(Debug, Serialize)]
pub struct AssignFaceResponse {
    pub face_id: String,
    pub person_id: Option<String>,
    pub updated_face_count: Option<i64>,
}

/// Assign a detected face to a person (or unassign if person_id is null)
pub async fn assign_face(
    State(state): State<Arc<AppState>>,
    Path(face_id): Path<String>,
    headers: HeaderMap,
    Json(payload): Json<AssignFaceRequest>,
) -> Result<Json<AssignFaceResponse>, StatusCode> {
    // Auth
    let token_opt = headers
        .get(header::AUTHORIZATION)
        .and_then(|h| h.to_str().ok())
        .and_then(|h| h.strip_prefix("Bearer "))
        .map(|s| s.to_string())
        .or_else(|| {
            headers
                .get(header::COOKIE)
                .and_then(|v| v.to_str().ok())
                .and_then(|cookie| {
                    cookie
                        .split(';')
                        .map(|c| c.trim())
                        .find_map(|c| c.strip_prefix("auth-token=").map(|s| s.to_string()))
                })
        });
    let token = token_opt.ok_or(StatusCode::UNAUTHORIZED)?;
    let user = state
        .auth_service
        .verify_token(&token)
        .await
        .map_err(|_| StatusCode::UNAUTHORIZED)?;

    let db = state
        .get_user_embedding_database(&user.user_id)
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    let conn = db.lock();

    // Validate face exists and capture previous person assignment
    let mut old_person: Option<String> = None;
    if let Ok(mut stmt) =
        conn.prepare("SELECT person_id FROM faces_embed WHERE face_id = ? LIMIT 1")
    {
        if let Ok(pid) = stmt.query_row([&face_id], |row| row.get::<_, Option<String>>(0)) {
            old_person = pid;
        } else {
            return Err(StatusCode::NOT_FOUND);
        }
    } else {
        return Err(StatusCode::NOT_FOUND);
    }

    // If assigning to a person, ensure person row exists
    let person_id_opt = payload
        .person_id
        .as_ref()
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string());
    if let Some(ref pid) = person_id_opt {
        let _ = conn.execute(
            "INSERT OR IGNORE INTO persons (person_id, display_name, face_count) VALUES (?, NULL, 0)",
            [pid],
        );
    }

    // Update face assignment (allow unassign by setting NULL)
    let changed: usize = match &person_id_opt {
        Some(pid) => conn
            .execute(
                "UPDATE faces_embed SET person_id = ? WHERE face_id = ?",
                duckdb::params![pid, &face_id],
            )
            .unwrap_or(0),
        None => conn
            .execute(
                "UPDATE faces_embed SET person_id = NULL WHERE face_id = ?",
                duckdb::params![&face_id],
            )
            .unwrap_or(0),
    };
    if changed == 0 {
        // Nothing updated: report not found to surface mismatch immediately
        return Err(StatusCode::NOT_FOUND);
    }

    // Update face_count for the target person for this user if provided
    let mut updated_face_count: Option<i64> = None;
    if let Some(pid) = &person_id_opt {
        if let Ok(mut stmt) =
            conn.prepare("SELECT COUNT(*) FROM faces_embed WHERE user_id = ? AND person_id = ?")
        {
            if let Ok(cnt) = stmt.query_row(duckdb::params![&user.user_id, pid], |row| {
                row.get::<_, i64>(0)
            }) {
                let _ = conn.execute(
                    "UPDATE persons SET face_count = ?, updated_at = CURRENT_TIMESTAMP WHERE person_id = ?",
                    [cnt.to_string(), pid.to_string()],
                );
                updated_face_count = Some(cnt);
            }
        }
    }

    // Also update face_count for the old person if it changed and exists
    if let Some(old) = old_person {
        if person_id_opt.as_deref() != Some(old.as_str()) {
            if let Ok(mut stmt) =
                conn.prepare("SELECT COUNT(*) FROM faces_embed WHERE user_id = ? AND person_id = ?")
            {
                if let Ok(cnt) = stmt.query_row(duckdb::params![&user.user_id, &old], |row| {
                    row.get::<_, i64>(0)
                }) {
                    let _ = conn.execute(
                        "UPDATE persons SET face_count = ?, updated_at = CURRENT_TIMESTAMP WHERE person_id = ?",
                        [cnt.to_string(), old.to_string()],
                    );
                }
            }
        }
    }

    // Best-effort checkpoint
    let _ = conn.execute("CHECKPOINT;", []);

    // Read back to confirm new assignment
    let mut new_pid: Option<String> = None;
    if let Ok(mut stmt) =
        conn.prepare("SELECT person_id FROM faces_embed WHERE face_id = ? LIMIT 1")
    {
        if let Ok(pid) = stmt.query_row([&face_id], |row| row.get::<_, Option<String>>(0)) {
            new_pid = pid;
        }
    }

    Ok(Json(AssignFaceResponse {
        face_id,
        person_id: new_pid.or(person_id_opt),
        updated_face_count,
    }))
}

// ---------- Add Person (manual face row) ----------

#[derive(Debug, Deserialize)]
pub struct AddPersonPayload {
    pub person_id: String,
}

#[derive(Debug, Serialize)]
pub struct AddPersonResponse {
    pub asset_id: String,
    pub person_id: String,
    pub added: bool,
    pub face_count: i64,
}

/// Attach a person to a photo by inserting a manual face row in the embedding DB
pub async fn assign_person_to_photo(
    State(state): State<Arc<AppState>>,
    Path(asset_id): Path<String>,
    headers: HeaderMap,
    Json(payload): Json<AddPersonPayload>,
) -> Result<Json<AddPersonResponse>, StatusCode> {
    // Auth
    let token_opt = headers
        .get(header::AUTHORIZATION)
        .and_then(|h| h.to_str().ok())
        .and_then(|h| h.strip_prefix("Bearer "))
        .map(|s| s.to_string())
        .or_else(|| {
            headers
                .get(header::COOKIE)
                .and_then(|v| v.to_str().ok())
                .and_then(|cookie| {
                    cookie
                        .split(';')
                        .map(|c| c.trim())
                        .find_map(|c| c.strip_prefix("auth-token=").map(|s| s.to_string()))
                })
        });
    let token = token_opt.ok_or(StatusCode::UNAUTHORIZED)?;
    let user = state
        .auth_service
        .verify_token(&token)
        .await
        .map_err(|_| StatusCode::UNAUTHORIZED)?;

    let embed_db = state
        .get_user_embedding_database(&user.user_id)
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    let conn = embed_db.lock();

    // Ensure person exists
    let _ = conn.execute(
        "INSERT OR IGNORE INTO persons (person_id, display_name, face_count) VALUES (?, NULL, 0)",
        [&payload.person_id],
    );

    // Deterministic face_id to keep idempotency
    let face_id = format!("manual:{}:{}", asset_id, payload.person_id);
    let insert_sql = "INSERT INTO faces_embed (face_id, asset_id, user_id, person_id, bbox_x, bbox_y, bbox_width, bbox_height, confidence, embedding, face_thumbnail, is_manual)\n                        VALUES (?, ?, ?, ?, 0, 0, 1, 1, 1.0, NULL, NULL, TRUE)\n                        ON CONFLICT (face_id) DO NOTHING";
    let changed = conn
        .execute(
            insert_sql,
            duckdb::params![&face_id, &asset_id, &user.user_id, &payload.person_id],
        )
        .unwrap_or(0);

    // Update count (distinct assets)
    let mut face_count: i64 = 0;
    if let Ok(mut stmt) = conn.prepare(
        "SELECT COUNT(DISTINCT f.asset_id) FROM faces_embed f JOIN photos dp ON dp.asset_id = f.asset_id WHERE dp.organization_id = ? AND dp.user_id = ? AND f.person_id = ?",
    ) {
        let _ = stmt.query_row(duckdb::params![user.organization_id, &user.user_id, &payload.person_id], |row| {
            face_count = row.get::<_, i64>(0)?;
            Ok(())
        });
        let _ = conn.execute(
            "UPDATE persons SET face_count = ?, updated_at = CURRENT_TIMESTAMP WHERE person_id = ?",
            duckdb::params![face_count, &payload.person_id],
        );
    }
    // Persist
    let _ = conn.execute("CHECKPOINT;", []);

    Ok(Json(AddPersonResponse {
        asset_id,
        person_id: payload.person_id,
        added: changed > 0,
        face_count,
    }))
}
