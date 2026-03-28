use anyhow::{anyhow, Result};
use duckdb::{params, Connection};
use serde::{Deserialize, Serialize};
use std::path::Path;
use tracing::{error, info, trace, warn};

use super::Photo;
use crate::database::multi_tenant::{DbPool, MultiTenantDatabase};
use std::sync::Arc;

#[derive(Debug, Deserialize, Clone, Serialize)]
pub struct PhotoListQuery {
    pub q: Option<String>,
    pub page: Option<u32>,
    pub limit: Option<u32>,
    // Optional hint from clients to avoid re-counting totals on deep pages.
    pub total_hint: Option<i64>,
    pub sort_by: Option<String>,
    pub sort_order: Option<String>,
    pub sort_random_seed: Option<i64>,
    pub filter_city: Option<String>,
    pub filter_country: Option<String>,
    pub filter_date_from: Option<i64>,
    pub filter_date_to: Option<i64>,
    pub filter_screenshot: Option<bool>,
    pub filter_live_photo: Option<bool>,
    pub filter_rating_min: Option<i32>,
    // New filters to support redesigned homepage facets
    pub filter_favorite: Option<bool>,
    pub filter_is_video: Option<bool>,
    #[serde(alias = "filter_faces[]")]
    pub filter_faces: Option<String>,
    pub filter_faces_mode: Option<String>,
    pub album_id: Option<i32>,
    pub album_ids: Option<String>,
    pub album_subtree: Option<bool>,
    pub include_locked: Option<bool>,
    pub filter_locked_only: Option<bool>,
    pub include_trashed: Option<bool>,
    pub filter_trashed_only: Option<bool>,
}

#[derive(Debug, Serialize)]
pub struct PhotoListResponse {
    pub photos: Vec<Photo>,
    pub total: usize,
    pub page: u32,
    pub limit: u32,
    pub has_more: bool,
}

#[derive(Debug, Serialize)]
pub struct Album {
    pub id: i32,
    pub name: String,
    pub description: Option<String>,
    pub parent_id: Option<i32>,
    pub position: Option<i32>,
    pub cover_photo_id: Option<i32>,
    pub cover_asset_id: Option<String>,
    pub photo_count: usize,
    pub created_at: i64,
    pub updated_at: i64,
    pub depth: i32,
    pub is_live: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rating_min: Option<i32>,
}

#[derive(Debug, Deserialize)]
pub struct CreateAlbumRequest {
    pub name: String,
    pub description: Option<String>,
    pub parent_id: Option<i32>,
}

#[derive(Debug, Deserialize)]
pub struct CreateLiveAlbumRequest {
    pub name: String,
    pub description: Option<String>,
    pub parent_id: Option<i32>,
    pub criteria: PhotoListQuery,
}

#[derive(Debug, Deserialize)]
pub struct UpdateAlbumRequest {
    pub name: Option<String>,
    pub description: Option<String>,
    pub cover_photo_id: Option<i32>,
    pub parent_id: Option<i32>,
    pub position: Option<i32>,
}

#[derive(Debug, Deserialize)]
pub struct AlbumPhotosRequest {
    pub photo_ids: Vec<i32>,
}

pub struct PhotoService {
    db: Arc<MultiTenantDatabase>,
}

impl PhotoService {
    fn compute_active_album_count(
        conn: &Connection,
        org_id: i32,
        album_id: i32,
    ) -> duckdb::Result<i64> {
        conn.query_row(
            "SELECT COUNT(*) FROM album_photos ap
             JOIN photos p ON ap.photo_id = p.id AND p.organization_id = ap.organization_id
             WHERE ap.organization_id = ? AND ap.album_id = ?
               AND COALESCE(p.delete_time, 0) = 0
               AND COALESCE(p.locked, FALSE) = FALSE",
            params![org_id, album_id],
            |row| row.get::<_, i64>(0),
        )
    }
    pub fn new(db: Arc<MultiTenantDatabase>) -> Self {
        Self { db }
    }

    pub async fn list_photos(
        &self,
        user_id: &str,
        query: PhotoListQuery,
    ) -> Result<PhotoListResponse> {
        tracing::info!("[PHOTO_SERVICE] Listing photos for user: {}", user_id);
        // Resolve organization_id for this user
        let org_id: i32 = {
            let users_conn = self.db.users_connection();
            let conn = users_conn.lock();
            conn.query_row(
                "SELECT organization_id FROM users WHERE user_id = ? LIMIT 1",
                duckdb::params![user_id],
                |row| row.get::<_, i32>(0),
            )
            .unwrap_or(1)
        };
        // Use pooled data DB (avoid fresh opens); hold lock only during synchronous operations
        let db_pool = self.db.get_user_data_database(user_id)?;
        let mut conn = db_pool.lock();
        tracing::info!(
            "[PHOTO_SERVICE] Opened fresh connection for user: {}",
            user_id
        );

        // Check connection state (raw count)
        let pre_count = conn
            .query_row("SELECT COUNT(*) FROM photos", [], |row| {
                row.get::<_, i64>(0)
            })
            .unwrap_or(-1);
        tracing::info!(
            "[PHOTO_SERVICE] Direct COUNT(*) check before query: {}",
            pre_count
        );

        // Log underlying database file for this connection for diagnostics
        if let Ok(mut stmt_dbg) = conn.prepare("PRAGMA database_list") {
            if let Ok(rows) = stmt_dbg.query_map([], |row| {
                let name: String = row.get(1)?;
                let file: String = row.get(2)?;
                Ok((name, file))
            }) {
                for r in rows.flatten() {
                    if r.0 == "main" {
                        tracing::info!("[PHOTO_SERVICE] DB file for user {}: {}", user_id, r.1);
                        break;
                    }
                }
            }
        }

        // If raw pre_count is zero, proactively refresh the connection before counting
        // If pre_count is 0, continue; do not reopen connection here.

        let page = query.page.unwrap_or(1);
        let limit = query.limit.unwrap_or(100).min(500);
        let offset = (page - 1) * limit;

        // For simplicity, we'll build a simpler query without complex dynamic parameters
        // This is a workaround for DuckDB's parameter binding limitations

        let mut where_clauses = Vec::new();
        // Always scope by organization and owner user
        where_clauses.push(format!("p.organization_id = {}", org_id));
        where_clauses.push(format!("p.user_id = '{}'", user_id.replace("'", "''")));

        if let Some(city) = &query.filter_city {
            where_clauses.push(format!("p.city = '{}'", city.replace("'", "''")));
        }

        if let Some(country) = &query.filter_country {
            where_clauses.push(format!("p.country = '{}'", country.replace("'", "''")));
        }

        if let Some(date_from) = query.filter_date_from {
            where_clauses.push(format!("p.created_at >= {}", date_from));
        }

        if let Some(date_to) = query.filter_date_to {
            // Client provides end-of-day timestamp (inclusive)
            where_clauses.push(format!("p.created_at <= {}", date_to));
        }

        if let Some(is_screenshot) = query.filter_screenshot {
            where_clauses.push(format!(
                "p.is_screenshot = {}",
                if is_screenshot { 1 } else { 0 }
            ));
        }

        if let Some(is_live) = query.filter_live_photo {
            where_clauses.push(format!("p.is_live_photo = {}", is_live));
        }

        if let Some(fav) = query.filter_favorite {
            if fav {
                where_clauses.push("p.favorites > 0".to_string());
            } else {
                where_clauses.push("p.favorites = 0".to_string());
            }
        }

        if let Some(is_video) = query.filter_is_video {
            where_clauses.push(format!("p.is_video = {}", if is_video { 1 } else { 0 }));
        }

        // Build base query
        let mut sql = String::from(
            "SELECT p.id, p.asset_id, p.path, p.filename, p.mime_type,\
                    p.has_gain_map, p.hdr_kind,\
                    p.created_at, p.modified_at, p.size, p.width, p.height,\
                    p.orientation, p.favorites, p.locked, p.delete_time, p.is_video, p.is_live_photo,\
                    p.live_video_path, p.is_screenshot, p.camera_make, p.camera_model,\
                    p.iso, p.aperture, p.shutter_speed, p.focal_length,\
                    p.latitude, p.longitude, p.altitude, p.location_name,\
                    p.city, p.province, p.country, p.caption, p.description \
             FROM photos p",
        );

        // Handle album filter (single or AND-multi)
        if let Some(ids_csv) = &query.album_ids {
            let base_ids: Vec<i32> = ids_csv
                .split(',')
                .filter_map(|s| s.trim().parse::<i32>().ok())
                .collect();
            if !base_ids.is_empty() {
                for (idx, root_id) in base_ids.iter().enumerate() {
                    let alias = format!("ap{}", idx);
                    sql.push_str(&format!(
                        " INNER JOIN album_photos {} ON p.id = {}.photo_id",
                        alias, alias
                    ));
                    // Note: service.rs legacy path does not support subtree expansion; keep direct match
                    where_clauses.push(format!("{}.album_id = {}", alias, root_id));
                }
            }
        } else if let Some(album_id) = query.album_id {
            sql.push_str(" INNER JOIN album_photos ap ON p.id = ap.photo_id");
            where_clauses.push(format!("ap.album_id = {}", album_id));
        }

        // Handle face filter
        if let Some(face_param) = &query.filter_faces {
            let ids: Vec<String> = face_param
                .split(',')
                .map(|s| s.trim())
                .filter(|s| !s.is_empty())
                .map(|s| s.to_string())
                .collect();
            if !ids.is_empty() {
                // Join detection faces on asset_id to filter by person
                sql.push_str(" INNER JOIN faces_embed f ON p.asset_id = f.asset_id");
                let face_list = ids
                    .iter()
                    .map(|f| format!("'{}'", f.replace("'", "''")))
                    .collect::<Vec<_>>()
                    .join(",");
                where_clauses.push(format!("f.person_id IN ({})", face_list));
            }
        }

        // Add WHERE clause
        if !where_clauses.is_empty() {
            sql.push_str(" WHERE ");
            sql.push_str(&where_clauses.join(" AND "));
        }

        // Choose count path (simple if there are no filters/joins)
        // Always exclude locked by default here unless overrides apply later in query logic
        where_clauses.push("p.locked = 0".to_string());

        let include_trashed = query.include_trashed.unwrap_or(false);
        let trashed_only = query.filter_trashed_only.unwrap_or(false);
        if trashed_only {
            where_clauses.push("p.delete_time > 0".to_string());
        } else if !include_trashed {
            where_clauses.push("p.delete_time = 0".to_string());
        }

        let use_simple_path = where_clauses.len() == 1
            && query.album_id.is_none()
            && query
                .filter_faces
                .as_ref()
                .map(|v| v.is_empty())
                .unwrap_or(true);
        let count_sql = if use_simple_path {
            format!(
                "SELECT COUNT(*) FROM photos p WHERE p.organization_id = {}",
                org_id
            )
        } else {
            format!("SELECT COUNT(*) FROM ({}) AS sub", sql)
        };

        // Reacquire connection for counting (possibly refreshed)
        tracing::info!(
            "[PHOTO_SERVICE] Executing count query for user {}: {}",
            user_id,
            count_sql
        );
        let mut total: i64 = conn
            .query_row(&count_sql, [], |row| row.get(0))
            .unwrap_or(-1);
        tracing::info!(
            "[PHOTO_SERVICE] Count query result for user {}: {}",
            user_id,
            total
        );

        // If the count query failed (negative sentinel), fall back to raw counts
        if total < 0 {
            // Prefer the pre_count observed earlier if available
            if pre_count >= 0 {
                total = pre_count;
            } else {
                let raw_now = conn
                    .query_row("SELECT COUNT(*) FROM photos", [], |row| {
                        row.get::<_, i64>(0)
                    })
                    .unwrap_or(0);
                total = raw_now;
            }
            tracing::warn!(
                "[PHOTO_SERVICE] Count query failed, using fallback total {} for user {}",
                total,
                user_id
            );
        }

        // Fallback: if total is unexpectedly zero, refresh the connection and retry once
        // If total is zero, keep using same connection; do not reopen.

        // If count query is zero but raw pre_count showed rows, trust the raw count
        if total == 0 && pre_count > 0 {
            tracing::warn!(
                "[PHOTO_SERVICE] Adjusting total to raw pre_count {} for user {}",
                pre_count,
                user_id
            );
            total = pre_count;
        }

        // If still zero, double-check raw count on the current connection
        if total == 0 {
            let raw_now = conn
                .query_row("SELECT COUNT(*) FROM photos", [], |row| {
                    row.get::<_, i64>(0)
                })
                .unwrap_or(-1);
            tracing::info!(
                "[PHOTO_SERVICE] Raw COUNT(*) after refresh for user {}: {}",
                user_id,
                raw_now
            );
            if raw_now > 0 {
                tracing::warn!(
                    "[PHOTO_SERVICE] Using raw_now {} as total for user {}",
                    raw_now,
                    user_id
                );
                total = raw_now;
            }
        }

        // Build data SQL
        let sort_by = query.sort_by.as_deref().unwrap_or("created_at");
        let sort_order = query.sort_order.as_deref().unwrap_or("DESC");
        let data_sql = if use_simple_path {
            // Build as a single-line string with explicit spaces to avoid parser issues
            format!(
                "SELECT p.id, p.asset_id, p.path, p.filename, p.mime_type, \
                        p.has_gain_map, p.hdr_kind, \
                        p.created_at, p.modified_at, p.size, p.width, p.height, \
                        p.orientation, p.favorites, p.locked, p.delete_time, p.is_video, p.is_live_photo, \
                        p.live_video_path, p.duration_ms, p.is_screenshot, p.camera_make, p.camera_model, \
                        p.iso, p.aperture, p.shutter_speed, p.focal_length, \
                        p.latitude, p.longitude, p.altitude, p.location_name, \
                        p.city, p.province, p.country, p.caption, p.description \
                 FROM photos p ORDER BY p.{} {} LIMIT {} OFFSET {}",
                sort_by, sort_order, limit, offset
            )
        } else {
            let mut tmp = sql.clone();
            tmp.push_str(&format!(" ORDER BY p.{} {}", sort_by, sort_order));
            tmp.push_str(&format!(" LIMIT {} OFFSET {}", limit, offset));
            tmp
        };

        tracing::info!(
            "[PHOTO_SERVICE] Executing photos query for user {}: {}",
            user_id,
            data_sql
        );
        // Execute query
        // Acquire a fresh lock (may be the same or refreshed connection)
        let mut photos: Vec<Photo> = Vec::new();
        match conn.prepare(&data_sql) {
            Ok(mut stmt) => {
                let mapped = stmt.query_map([], |row| {
                    Ok(Photo {
                        id: Some(row.get(0)?),
                        asset_id: row.get(1)?,
                        path: row.get(2)?,
                        filename: row.get(3)?,
                        mime_type: row.get(4)?,
                        has_gain_map: row.get(5)?,
                        hdr_kind: row.get(6)?,
                        created_at: row.get(7)?,
                        modified_at: row.get(8)?,
                        size: row.get(9)?,
                        width: row.get(10)?,
                        height: row.get(11)?,
                        orientation: row.get(12)?,
                        favorites: row.get(13)?,
                        locked: row.get(14)?,
                        delete_time: row.get(15)?,
                        is_video: row.get(16)?,
                        is_live_photo: row.get(17)?,
                        live_video_path: row.get(18)?,
                        duration_ms: row.get(19)?,
                        is_screenshot: row.get(20)?,
                        camera_make: row.get(21)?,
                        camera_model: row.get(22)?,
                        iso: row.get(23)?,
                        aperture: row.get(24)?,
                        shutter_speed: row.get(25)?,
                        focal_length: row.get(26)?,
                        latitude: row.get(27)?,
                        longitude: row.get(28)?,
                        altitude: row.get(29)?,
                        location_name: row.get(30)?,
                        city: row.get(31)?,
                        province: row.get(32)?,
                        country: row.get(33)?,
                        caption: row.get(34)?,
                        description: row.get(35)?,
                        rating: None,
                    })
                });
                for r in mapped? {
                    photos.push(r?);
                }
            }
            Err(e) => {
                tracing::error!(
                    "[PHOTO_SERVICE] Prepare failed for data_sql (user {}): {}",
                    user_id,
                    e
                );
            }
        }

        // Final safeguard: if the raw table has rows but this query returned none, do a simple fallback select
        if photos.is_empty() && total > 0 {
            tracing::warn!(
                "[PHOTO_SERVICE] Fallback select: raw total {} but query returned 0 for user {}",
                total,
                user_id
            );
            let fallback_sql = format!(
                "SELECT p.id, p.asset_id, p.path, p.filename, p.mime_type, \
                        p.has_gain_map, p.hdr_kind, \
                        p.created_at, p.modified_at, p.size, p.width, p.height, \
                        p.orientation, p.favorites, p.locked, p.delete_time, p.is_video, p.is_live_photo, \
                        p.live_video_path, p.duration_ms, p.is_screenshot, p.camera_make, p.camera_model, \
                        p.iso, p.aperture, p.shutter_speed, p.focal_length, \
                        p.latitude, p.longitude, p.altitude, p.location_name, \
                        p.city, p.province, p.country, p.caption, p.description \
                 FROM photos p ORDER BY p.created_at DESC LIMIT {} OFFSET {}",
                limit, offset
            );
            tracing::info!(
                "[PHOTO_SERVICE] Executing fallback photos query for user {}: {}",
                user_id,
                fallback_sql
            );
            if let Ok(mut stmt_fb) = conn.prepare(&fallback_sql) {
                let mapped = stmt_fb.query_map([], |row| {
                    Ok(Photo {
                        id: Some(row.get(0)?),
                        asset_id: row.get(1)?,
                        path: row.get(2)?,
                        filename: row.get(3)?,
                        mime_type: row.get(4)?,
                        has_gain_map: row.get(5)?,
                        hdr_kind: row.get(6)?,
                        created_at: row.get(7)?,
                        modified_at: row.get(8)?,
                        size: row.get(9)?,
                        width: row.get(10)?,
                        height: row.get(11)?,
                        orientation: row.get(12)?,
                        favorites: row.get(13)?,
                        locked: row.get(14)?,
                        delete_time: row.get(15)?,
                        is_video: row.get(16)?,
                        is_live_photo: row.get(17)?,
                        live_video_path: row.get(18)?,
                        duration_ms: row.get(19)?,
                        is_screenshot: row.get(20)?,
                        camera_make: row.get(21)?,
                        camera_model: row.get(22)?,
                        iso: row.get(23)?,
                        aperture: row.get(24)?,
                        shutter_speed: row.get(25)?,
                        focal_length: row.get(26)?,
                        latitude: row.get(27)?,
                        longitude: row.get(28)?,
                        altitude: row.get(29)?,
                        location_name: row.get(30)?,
                        city: row.get(31)?,
                        province: row.get(32)?,
                        country: row.get(33)?,
                        caption: row.get(34)?,
                        description: row.get(35)?,
                        rating: None,
                    })
                });
                for r in mapped? {
                    photos.push(r?);
                }
            } else {
                tracing::error!(
                    "[PHOTO_SERVICE] Fallback prepare failed for user {}",
                    user_id
                );
            }
        }

        // Ensure negative totals (from prior failures) don't cause overflow or infinite paging
        let total_nonneg = if total < 0 { 0 } else { total };
        Ok(PhotoListResponse {
            photos,
            total: total_nonneg as usize,
            page,
            limit,
            has_more: (page * limit) < (total_nonneg as u32),
        })
    }

    pub async fn get_photo(&self, user_id: &str, photo_id: i32) -> Result<Photo> {
        // Resolve organization_id for this user
        let org_id: i32 = {
            let users_conn = self.db.users_connection();
            let conn = users_conn.lock();
            conn.query_row(
                "SELECT organization_id FROM users WHERE user_id = ? LIMIT 1",
                duckdb::params![user_id],
                |row| row.get::<_, i32>(0),
            )
            .unwrap_or(1)
        };
        let user_db = self.db.get_user_database(user_id)?;
        let conn = user_db.lock();
        let photo = conn.query_row(
            "SELECT id, asset_id, path, filename, mime_type, has_gain_map, hdr_kind,
                    created_at, modified_at, size, width, height,
                    orientation, favorites, locked, delete_time, is_video, is_live_photo,
                    live_video_path, duration_ms, is_screenshot, camera_make, camera_model,
                    iso, aperture, shutter_speed, focal_length,
                    latitude, longitude, altitude, location_name,
                    city, province, country, caption, description
             FROM photos WHERE organization_id = ? AND id = ?",
            params![org_id, photo_id],
            |row| {
                Ok(Photo {
                    id: Some(row.get(0)?),
                    asset_id: row.get(1)?,
                    path: row.get(2)?,
                    filename: row.get(3)?,
                    mime_type: row.get(4)?,
                    has_gain_map: row.get(5)?,
                    hdr_kind: row.get(6)?,
                    created_at: row.get(7)?,
                    modified_at: row.get(8)?,
                    size: row.get(9)?,
                    width: row.get(10)?,
                    height: row.get(11)?,
                    orientation: row.get(12)?,
                    favorites: row.get(13)?,
                    locked: row.get(14)?,
                    delete_time: row.get(15)?,
                    is_video: row.get(16)?,
                    is_live_photo: row.get(17)?,
                    live_video_path: row.get(18)?,
                    duration_ms: row.get(19)?,
                    is_screenshot: row.get(20)?,
                    camera_make: row.get(21)?,
                    camera_model: row.get(22)?,
                    iso: row.get(23)?,
                    aperture: row.get(24)?,
                    shutter_speed: row.get(25)?,
                    focal_length: row.get(26)?,
                    latitude: row.get(27)?,
                    longitude: row.get(28)?,
                    altitude: row.get(29)?,
                    location_name: row.get(30)?,
                    city: row.get(31)?,
                    province: row.get(32)?,
                    country: row.get(33)?,
                    caption: row.get(34)?,
                    description: row.get(35)?,
                    rating: None,
                })
            },
        )?;

        Ok(photo)
    }

    pub async fn list_albums(&self, user_id: &str) -> Result<Vec<Album>> {
        // Resolve organization_id for this user so we can scope results
        let org_id: i32 = {
            let users_conn = self.db.users_connection();
            let conn = users_conn.lock();
            conn.query_row(
                "SELECT organization_id FROM users WHERE user_id = ? LIMIT 1",
                duckdb::params![user_id],
                |row| row.get::<_, i32>(0),
            )
            .unwrap_or(1)
        };

        // Use the shared connection guarded by a mutex to avoid concurrent multi-connection access
        let user_db = self.db.get_user_database(user_id)?;
        let conn = user_db.lock();
        // [ALBUMS] opened pooled connection log suppressed

        // Log basic DB info to help isolate crashes within DuckDB
        if let Ok(mut stmt) = conn.prepare("PRAGMA database_list") {
            let rows = stmt.query_map([], |row| {
                let name: String = row.get(1)?;
                let file: String = row.get(2)?;
                Ok((name, file))
            });
            match rows {
                Ok(rs) => {
                    let mut v = Vec::new();
                    for r in rs.flatten() {
                        v.push(format!("{}:{}", r.0, r.1));
                    }
                    // trace!(target: "albums", "[ALBUMS] PRAGMA database_list => {:?}", v);
                }
                Err(e) => warn!(target: "albums", "[ALBUMS] PRAGMA database_list failed: {}", e),
            }
        }

        // Inspect existing tables and quick counts; ignore errors but log them
        if let Ok(mut stmt) = conn.prepare(
            "SELECT table_name FROM information_schema.tables ORDER BY table_name LIMIT 50",
        ) {
            let rows = stmt.query_map([], |row| row.get::<_, String>(0));
            match rows {
                Ok(rs) => {
                    let mut names = Vec::new();
                    for r in rs.flatten() {
                        names.push(r);
                    }
                    // trace!(target: "albums", "[ALBUMS] tables: {:?}", names);
                }
                Err(e) => warn!(target: "albums", "[ALBUMS] list tables failed: {}", e),
            }
        }
        let albums_count: i64 = conn
            .query_row(
                &format!(
                    "SELECT COUNT(*) FROM albums WHERE organization_id = {} AND user_id = '{}'",
                    org_id,
                    user_id.replace("'", "''")
                ),
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap_or(-1);
        let photos_count: i64 = conn
            .query_row(
                &format!(
                    "SELECT COUNT(*) FROM photos WHERE organization_id = {} AND user_id = '{}'",
                    org_id,
                    user_id.replace("'", "''")
                ),
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap_or(-1);
        let ap_count: i64 = conn
            .query_row(
                &format!(
                    "SELECT COUNT(*) FROM album_photos WHERE organization_id = {}",
                    org_id
                ),
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap_or(-1);
        // trace!(target: "albums", "[ALBUMS] counts: albums={} photos={} album_photos={}", albums_count, photos_count, ap_count);

        // Short-circuit: if there are no albums, avoid scanning/joining tables at all.
        if albums_count == 0 {
            // trace!(target: "albums", "[ALBUMS] zero albums; returning empty list without scan");
            return Ok(Vec::new());
        }
        // Detect if deleted_at column exists (older DBs may not have it yet)
        let has_deleted_at: bool = conn
            .query_row(
                "SELECT COUNT(*) > 0 FROM information_schema.columns WHERE lower(table_name)='albums' AND lower(column_name)='deleted_at'",
                [],
                |row| row.get(0),
            )
            .unwrap_or(false);
        let base = "SELECT a.id, a.name, a.description, a.parent_id, a.position, a.cover_photo_id, p2.asset_id,
                    a.created_at, a.updated_at,
                    (SELECT COUNT(*)
                       FROM album_photos ap2 JOIN photos p3 ON ap2.photo_id = p3.id
                      WHERE ap2.album_id = a.id AND ap2.organization_id = a.organization_id
                        AND COALESCE(p3.delete_time, 0) = 0
                        AND COALESCE(p3.locked, FALSE) = FALSE) AS photo_count,
                    COALESCE((SELECT MAX(depth) FROM album_closure ac WHERE ac.descendant_id = a.id AND ac.organization_id = a.organization_id), 0) as depth,
                    COALESCE(a.is_live, FALSE) as is_live
             FROM albums a
             LEFT JOIN photos p2 ON a.cover_photo_id = p2.id AND p2.organization_id = a.organization_id";
        let mut filter = format!(
            " WHERE a.organization_id = {} AND a.user_id = '{}'",
            org_id,
            user_id.replace("'", "''")
        );
        if has_deleted_at {
            filter.push_str(" AND a.deleted_at IS NULL");
        }
        // Hide internal share snapshot albums from regular listings
        filter.push_str(" AND COALESCE(a.description, '') <> 'Share snapshot'");
        let tail = " GROUP BY a.organization_id, a.id, a.name, a.description, a.parent_id, a.position, a.cover_photo_id, p2.asset_id,
                      a.created_at, a.updated_at, a.is_live
             ORDER BY a.parent_id NULLS FIRST, a.position ASC, a.updated_at DESC";
        let sql = [base, filter.as_str(), tail].concat();
        // trace!(target: "albums", "[ALBUMS] about to prepare SQL (has_deleted_at={}): {}", has_deleted_at, sql);
        let mut stmt = conn.prepare(&sql)?;
        // trace!(target: "albums", "[ALBUMS] statement prepared successfully");

        let mut albums = stmt
            .query_map([], |row| {
                Ok(Album {
                    id: row.get(0)?,
                    name: row.get(1)?,
                    description: row.get(2)?,
                    parent_id: row.get(3)?,
                    position: row.get(4)?,
                    cover_photo_id: row.get(5)?,
                    cover_asset_id: row.get(6)?,
                    created_at: row.get(7)?,
                    updated_at: row.get(8)?,
                    photo_count: row.get::<_, i64>(9)? as usize,
                    depth: row.get::<_, i64>(10)? as i32,
                    is_live: row.get::<_, bool>(11).unwrap_or(false),
                    rating_min: None,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;

        // Enrich live albums with rating_min extracted from JSON criteria (best-effort)
        for a in albums.iter_mut() {
            if !a.is_live {
                continue;
            }
            let crit: Option<String> = conn
                .prepare(&format!(
                    "SELECT live_criteria FROM albums WHERE id = ? AND organization_id = {}",
                    org_id
                ))
                .ok()
                .and_then(|mut st| st.query_row([a.id], |r| r.get::<_, Option<String>>(0)).ok())
                .flatten();
            if let Some(cj) = crit {
                if let Ok(v) = serde_json::from_str::<serde_json::Value>(&cj) {
                    if let Some(n) = v.get("filter_rating_min").and_then(|x| x.as_i64()) {
                        if n >= 1 && n <= 5 {
                            a.rating_min = Some(n as i32);
                        }
                    }
                }
            }
        }

        // trace!(target: "albums", "[ALBUMS] query_map collected {} rows", albums.len());

        Ok(albums)
    }

    pub async fn create_album(&self, user_id: &str, request: CreateAlbumRequest) -> Result<Album> {
        // Resolve organization_id for this user from the control-plane users DB
        let org_id: i32 = {
            let users_conn = self.db.users_connection();
            let conn = users_conn.lock();
            conn.query_row(
                "SELECT organization_id FROM users WHERE user_id = ? LIMIT 1",
                duckdb::params![user_id],
                |row| row.get::<_, i32>(0),
            )
            .unwrap_or(1)
        };

        let user_db = self.db.get_user_database(user_id)?;
        let conn = user_db.lock();

        let now = chrono::Utc::now().timestamp();

        // Disallow creating a child under a live album
        if let Some(pid) = request.parent_id {
            let is_live_parent: bool = conn
                .query_row(
                    "SELECT COALESCE(is_live, FALSE) FROM albums WHERE id = ?",
                    params![pid],
                    |row| row.get::<_, bool>(0),
                )
                .unwrap_or(false);
            if is_live_parent {
                return Err(anyhow!("Cannot create a child under a live album"));
            }
        }

        // Insert and get the ID using a returning clause
        // Determine next position among siblings
        let pos: i64 = match request.parent_id {
            Some(pid) => conn
                .query_row(
                    "SELECT COALESCE(MAX(position)+1, 1) FROM albums WHERE parent_id = ?",
                    params![pid],
                    |row| row.get::<_, i64>(0),
                )
                .unwrap_or(1),
            None => conn
                .query_row(
                    "SELECT COALESCE(MAX(position)+1, 1) FROM albums WHERE parent_id IS NULL",
                    [],
                    |row| row.get::<_, i64>(0),
                )
                .unwrap_or(1),
        };

        // Insert album with tenant scoping (organization_id, user_id) plus parent and position
        let album: (i32, String, Option<String>, Option<i32>, i64, i64) = conn.query_row(
            "INSERT INTO albums (organization_id, user_id, name, description, parent_id, position, created_at, updated_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?)
             RETURNING id, name, description, parent_id, created_at, updated_at",
            params![
                org_id,
                user_id,
                &request.name,
                &request.description,
                &request.parent_id,
                pos,
                now,
                now
            ],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                    row.get(5)?,
                ))
            },
        )?;

        // Maintain closure table
        // self-row
        conn.execute(
            "INSERT OR IGNORE INTO album_closure (organization_id, ancestor_id, descendant_id, depth) VALUES (?, ?, ?, 0)",
            params![org_id, album.0, album.0]
        )?;
        if let Some(pid) = request.parent_id {
            // Inherit ancestors from parent and add parent relationship
            conn.execute(
                "INSERT OR IGNORE INTO album_closure (organization_id, ancestor_id, descendant_id, depth)
                 SELECT ?, ac.ancestor_id, ?, ac.depth + 1 FROM album_closure ac WHERE ac.descendant_id = ?",
                params![org_id, album.0, pid]
            )?;
            // Ensure direct parent relationship exists even if parent had no closure rows yet
            conn.execute(
                "INSERT OR IGNORE INTO album_closure (organization_id, ancestor_id, descendant_id, depth) VALUES (?, ?, ?, 1)",
                params![org_id, pid, album.0]
            )?;
        }

        // Force checkpoint to ensure album creation is persisted
        conn.execute("CHECKPOINT", [])?;

        Ok(Album {
            id: album.0,
            name: album.1,
            description: album.2,
            parent_id: album.3,
            position: Some(pos as i32),
            cover_photo_id: None,
            cover_asset_id: None,
            photo_count: 0,
            created_at: album.4,
            updated_at: album.5,
            depth: match request.parent_id {
                Some(_) => 1,
                None => 0,
            },
            is_live: false,
            rating_min: None,
        })
    }

    pub async fn create_live_album(
        &self,
        user_id: &str,
        request: CreateLiveAlbumRequest,
    ) -> Result<Album> {
        // Resolve organization_id for this user from the control-plane users DB
        let org_id: i32 = {
            let users_conn = self.db.users_connection();
            let conn = users_conn.lock();
            conn.query_row(
                "SELECT organization_id FROM users WHERE user_id = ? LIMIT 1",
                duckdb::params![user_id],
                |row| row.get::<_, i32>(0),
            )
            .unwrap_or(1)
        };

        let user_db = self.db.get_user_database(user_id)?;
        let conn = user_db.lock();

        // Disallow creating a child under a live album
        if let Some(pid) = request.parent_id {
            let is_live_parent: bool = conn
                .query_row(
                    "SELECT COALESCE(is_live, FALSE) FROM albums WHERE id = ?",
                    params![pid],
                    |row| row.get::<_, bool>(0),
                )
                .unwrap_or(false);
            if is_live_parent {
                return Err(anyhow!("Cannot create a child under a live album"));
            }
        }

        let now = chrono::Utc::now().timestamp();
        let pos: i64 = match request.parent_id {
            Some(pid) => conn
                .query_row(
                    "SELECT COALESCE(MAX(position)+1, 1) FROM albums WHERE parent_id = ?",
                    params![pid],
                    |row| row.get::<_, i64>(0),
                )
                .unwrap_or(1),
            None => conn
                .query_row(
                    "SELECT COALESCE(MAX(position)+1, 1) FROM albums WHERE parent_id IS NULL",
                    [],
                    |row| row.get::<_, i64>(0),
                )
                .unwrap_or(1),
        };

        // Sanitize criteria to avoid recursion
        let mut criteria = request.criteria.clone();
        criteria.album_id = None;
        criteria.album_subtree = None;
        let criteria_json = serde_json::to_string(&criteria)?;

        let album: (i32, String, Option<String>, Option<i32>, i64, i64, bool) = conn.query_row(
            "INSERT INTO albums (organization_id, user_id, name, description, parent_id, position, created_at, updated_at, is_live, live_criteria)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, TRUE, ?)
             RETURNING id, name, description, parent_id, created_at, updated_at, is_live",
            params![
                org_id,
                user_id,
                &request.name,
                &request.description,
                &request.parent_id,
                pos,
                now,
                now,
                criteria_json,
            ],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                    row.get(5)?,
                    row.get(6)?,
                ))
            },
        )?;

        // Maintain closure table
        conn.execute(
            "INSERT OR IGNORE INTO album_closure (organization_id, ancestor_id, descendant_id, depth) VALUES (?, ?, ?, 0)",
            params![org_id, album.0, album.0],
        )?;
        if let Some(pid) = request.parent_id {
            conn.execute(
                "INSERT OR IGNORE INTO album_closure (organization_id, ancestor_id, descendant_id, depth)
                 SELECT ?, ac.ancestor_id, ?, ac.depth + 1 FROM album_closure ac WHERE ac.descendant_id = ?",
                params![org_id, album.0, pid],
            )?;
            conn.execute(
                "INSERT OR IGNORE INTO album_closure (organization_id, ancestor_id, descendant_id, depth) VALUES (?, ?, ?, 1)",
                params![org_id, pid, album.0],
            )?;
        }
        conn.execute("CHECKPOINT", [])?;

        Ok(Album {
            id: album.0,
            name: album.1,
            description: album.2,
            parent_id: album.3,
            position: Some(pos as i32),
            cover_photo_id: None,
            cover_asset_id: None,
            photo_count: 0,
            created_at: album.4,
            updated_at: album.5,
            depth: match request.parent_id {
                Some(_) => 1,
                None => 0,
            },
            is_live: album.6,
            rating_min: None,
        })
    }

    pub async fn update_album(
        &self,
        user_id: &str,
        album_id: i32,
        request: UpdateAlbumRequest,
    ) -> Result<Album> {
        // Resolve org id before locking the data DB to avoid re-entrant locking
        let org_id: i32 = {
            let users_conn = self.db.users_connection();
            let conn_u = users_conn.lock();
            conn_u
                .query_row(
                    "SELECT organization_id FROM users WHERE user_id = ? LIMIT 1",
                    duckdb::params![user_id],
                    |row| row.get::<_, i32>(0),
                )
                .unwrap_or(1)
        };
        let user_db = self.db.get_user_database(user_id)?;
        let conn = user_db.lock();

        let now = chrono::Utc::now().timestamp();

        // Build update query based on provided fields
        let mut changed_parent = false;

        if let Some(name) = &request.name {
            conn.execute(
                "UPDATE albums SET name = ? WHERE id = ?",
                params![name, album_id],
            )?;
        }

        if let Some(desc) = &request.description {
            conn.execute(
                "UPDATE albums SET description = ? WHERE id = ?",
                params![desc, album_id],
            )?;
        }

        if let Some(cover) = request.cover_photo_id {
            conn.execute(
                "UPDATE albums SET cover_photo_id = ? WHERE id = ?",
                params![cover, album_id],
            )?;
        }

        // Move album to a new parent if provided
        if let Some(new_parent) = request.parent_id {
            changed_parent = true;
            // Prevent cycles: new parent cannot be a descendant of album_id
            let is_descendant: Option<i64> = conn.query_row(
                "SELECT 1 FROM album_closure WHERE ancestor_id = ? AND descendant_id = ? LIMIT 1",
                params![album_id, new_parent],
                |row| row.get(0)
            ).ok();
            if is_descendant.is_some() {
                return Err(anyhow!(
                    "Invalid parent: cannot move album under its own descendant"
                ));
            }

            // Disallow moving under a live album
            let is_live_parent: bool = conn
                .query_row(
                    "SELECT COALESCE(is_live, FALSE) FROM albums WHERE id = ?",
                    params![new_parent],
                    |row| row.get::<_, bool>(0),
                )
                .unwrap_or(false);
            if is_live_parent {
                return Err(anyhow!("Cannot move album under a live album"));
            }

            let tx = conn.unchecked_transaction()?;
            // Update parent_id
            tx.execute(
                "UPDATE albums SET parent_id = ? WHERE id = ?",
                params![new_parent, album_id],
            )?;

            // Identify subtree (descendants of album_id including itself with their depth to album)
            // Detach subtree from old ancestors (keep intra-subtree relations)
            tx.execute(
                "DELETE FROM album_closure
                 WHERE organization_id = ?
                   AND descendant_id IN (SELECT descendant_id FROM album_closure WHERE organization_id = ? AND ancestor_id = ?)
                   AND ancestor_id NOT IN (SELECT descendant_id FROM album_closure WHERE organization_id = ? AND ancestor_id = ?)",
                params![org_id, org_id, album_id, org_id, album_id]
            )?;

            // Reattach to new parent's ancestors
            // Insert rows for each ancestor 'a' of new_parent and each node 'd' in subtree
            tx.execute(
                "INSERT OR IGNORE INTO album_closure (organization_id, ancestor_id, descendant_id, depth)
                 SELECT ?, a.ancestor_id, d.descendant_id, a.depth + d.depth + 1
                 FROM album_closure a
                 JOIN album_closure d ON d.organization_id = ? AND d.ancestor_id = ?
                 WHERE a.organization_id = ? AND a.descendant_id = ?",
                params![org_id, org_id, album_id, org_id, new_parent],
            )?;

            tx.commit()?;

            // Force checkpoint to ensure parent change is persisted
            conn.execute("CHECKPOINT", [])?;
        }

        // If explicit position provided, set it (used for reorder). UI is responsible for reindexing siblings.
        if let Some(pos) = request.position {
            conn.execute(
                "UPDATE albums SET position = ? WHERE id = ?",
                params![pos, album_id],
            )?;
        } else if changed_parent {
            // If moved to a new parent and no position specified, append at the end
            let max_pos: i64 = conn
                .query_row(
                    "SELECT COALESCE(MAX(position), 0) FROM albums WHERE parent_id IS ?",
                    params![request.parent_id],
                    |row| row.get::<_, i64>(0),
                )
                .unwrap_or(0);
            conn.execute(
                "UPDATE albums SET position = ? WHERE id = ?",
                params![max_pos + 1, album_id],
            )?;
        }

        // Always update updated_at
        conn.execute(
            "UPDATE albums SET updated_at = ? WHERE id = ?",
            params![now, album_id],
        )?;

        // Force checkpoint to ensure updates are persisted
        conn.execute("CHECKPOINT", [])?;

        // Drop the connection before await
        drop(conn);

        // Fetch and return updated album synchronously to keep this future Send
        self.get_album_sync(user_id, album_id)
    }

    fn get_album_sync(&self, user_id: &str, album_id: i32) -> Result<Album> {
        // Resolve org
        let org_id: i32 = {
            let users_conn = self.db.users_connection();
            let conn = users_conn.lock();
            conn.query_row(
                "SELECT organization_id FROM users WHERE user_id = ? LIMIT 1",
                duckdb::params![user_id],
                |row| row.get::<_, i32>(0),
            )
            .unwrap_or(1)
        };
        let user_db = self.db.get_user_database(user_id)?;
        let conn = user_db.lock();
        let album = conn.query_row(
            "SELECT a.id, a.name, a.description, a.parent_id, a.position, a.cover_photo_id, p2.asset_id,
                    a.created_at, a.updated_at,
                    (SELECT COUNT(*)
                       FROM album_photos ap2 JOIN photos p3 ON ap2.photo_id = p3.id AND ap2.organization_id = p3.organization_id
                      WHERE ap2.organization_id = a.organization_id AND ap2.album_id = a.id
                        AND COALESCE(p3.delete_time, 0) = 0
                        AND COALESCE(p3.locked, FALSE) = FALSE) AS photo_count,
                    COALESCE((SELECT MAX(depth) FROM album_closure ac WHERE ac.organization_id = a.organization_id AND ac.descendant_id = a.id), 0) as depth,
                    COALESCE(a.is_live, FALSE) as is_live
             FROM albums a
             LEFT JOIN photos p2 ON p2.organization_id = a.organization_id AND a.cover_photo_id = p2.id
             WHERE a.organization_id = ? AND a.user_id = ? AND a.id = ?
             GROUP BY a.organization_id, a.user_id, a.id, a.name, a.description, a.parent_id, a.position, a.cover_photo_id, p2.asset_id,
                      a.created_at, a.updated_at, a.is_live",
            params![org_id, user_id, album_id],
            |row| {
                Ok(Album {
                    id: row.get(0)?,
                    name: row.get(1)?,
                    description: row.get(2)?,
                    parent_id: row.get(3)?,
                    position: row.get(4)?,
                    cover_photo_id: row.get(5)?,
                    cover_asset_id: row.get(6)?,
                    created_at: row.get(7)?,
                    updated_at: row.get(8)?,
                    photo_count: row.get::<_, i64>(9)? as usize,
                    depth: row.get::<_, i64>(10)? as i32,
                    is_live: row.get::<_, bool>(11).unwrap_or(false),
                    rating_min: None,
                })
            }
        )?;
        Ok(album)
    }

    pub async fn delete_album(&self, user_id: &str, album_id: i32) -> Result<()> {
        // Resolve org for scoping deletions
        let org_id: i32 = {
            let users_conn = self.db.users_connection();
            let conn = users_conn.lock();
            conn.query_row(
                "SELECT organization_id FROM users WHERE user_id = ? LIMIT 1",
                duckdb::params![user_id],
                |row| row.get::<_, i32>(0),
            )
            .unwrap_or(1)
        };
        let user_db = self.db.get_user_database(user_id)?;
        let conn = user_db.lock();
        let tx = conn.unchecked_transaction()?;
        // Gather subtree (including self); if closure table empty, fall back to just self
        let mut ids: Vec<i32> = Vec::new();
        if let Ok(mut stmt) = tx.prepare(
            "SELECT descendant_id FROM album_closure WHERE organization_id = ? AND ancestor_id = ?",
        ) {
            let rows = stmt.query_map(params![org_id, album_id], |row| row.get::<_, i32>(0))?;
            for r in rows {
                if let Ok(id) = r {
                    ids.push(id);
                }
            }
        }
        if ids.is_empty() {
            ids.push(album_id);
        }
        let in_list = ids
            .iter()
            .map(|id| id.to_string())
            .collect::<Vec<_>>()
            .join(",");

        // Remove album-photo links
        tx.execute(
            &format!(
                "DELETE FROM album_photos WHERE organization_id = ? AND album_id IN ({})",
                in_list
            ),
            params![org_id],
        )?;
        // Remove closure rows touching these nodes
        tx.execute(
            &format!(
                "DELETE FROM album_closure WHERE organization_id = ? AND (ancestor_id IN ({0}) OR descendant_id IN ({0}))",
                in_list
            ),
            params![org_id],
        )?;
        // Soft-delete albums (subtree): mark deleted_at and rename to avoid UNIQUE(parent_id, name) conflicts
        let now = chrono::Utc::now().timestamp();
        tx.execute(
            &format!(
                "UPDATE albums SET deleted_at = ?, name = name || ' (merged ' || ? || ')', updated_at = ? WHERE id IN ({})",
                in_list
            ),
            params![now, now, now],
        )?;
        tx.commit()?;

        // Force checkpoint to ensure deletion is persisted
        conn.execute("CHECKPOINT", [])?;

        Ok(())
    }

    /// List albums that contain the given photo
    pub async fn get_albums_for_photo(&self, user_id: &str, photo_id: i32) -> Result<Vec<Album>> {
        // Resolve organization_id for scoping
        let org_id: i32 = {
            let users_conn = self.db.users_connection();
            let conn = users_conn.lock();
            conn.query_row(
                "SELECT organization_id FROM users WHERE user_id = ? LIMIT 1",
                duckdb::params![user_id],
                |row| row.get::<_, i32>(0),
            )
            .unwrap_or(1)
        };
        let user_db = self.db.get_user_database(user_id)?;
        let conn = user_db.lock();

        let mut stmt = conn.prepare(
            "SELECT a.id, a.name, a.description, a.parent_id, a.position, a.cover_photo_id, p2.asset_id, \
                    a.created_at, a.updated_at, \
                    COUNT(ap2.photo_id) as photo_count, \
                    COALESCE((SELECT MAX(depth) FROM album_closure ac WHERE ac.organization_id = a.organization_id AND ac.descendant_id = a.id), 0) as depth \
             FROM albums a \
             INNER JOIN album_photos ap ON ap.organization_id = a.organization_id AND ap.album_id = a.id \
             LEFT JOIN album_photos ap2 ON ap2.organization_id = a.organization_id AND ap2.album_id = a.id \
             LEFT JOIN photos p2 ON p2.organization_id = a.organization_id AND a.cover_photo_id = p2.id \
             WHERE a.organization_id = ? AND a.user_id = ? AND ap.photo_id = ? \
               AND COALESCE(a.description, '') <> 'Share snapshot' \
             GROUP BY a.organization_id, a.user_id, a.id, a.name, a.description, a.parent_id, a.position, a.cover_photo_id, p2.asset_id, \
                      a.created_at, a.updated_at \
             ORDER BY a.updated_at DESC, a.id ASC"
        )?;

        let albums = stmt
            .query_map(params![org_id, user_id, photo_id], |row| {
                Ok(Album {
                    id: row.get(0)?,
                    name: row.get(1)?,
                    description: row.get(2)?,
                    parent_id: row.get(3)?,
                    position: row.get(4)?,
                    cover_photo_id: row.get(5)?,
                    cover_asset_id: row.get(6)?,
                    created_at: row.get(7)?,
                    updated_at: row.get(8)?,
                    photo_count: row.get::<_, i64>(9)? as usize,
                    depth: row.get::<_, i64>(10)? as i32,
                    is_live: false,
                    rating_min: None,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(albums)
    }

    pub async fn add_photos_to_album(
        &self,
        user_id: &str,
        album_id: i32,
        photo_ids: Vec<i32>,
    ) -> Result<()> {
        // Resolve organization_id for this user from the control-plane users DB
        let org_id: i32 = {
            let users_conn = self.db.users_connection();
            let conn = users_conn.lock();
            conn.query_row(
                "SELECT organization_id FROM users WHERE user_id = ? LIMIT 1",
                duckdb::params![user_id],
                |row| row.get::<_, i32>(0),
            )
            .unwrap_or(1)
        };
        tracing::info!(
            "Starting add_photos_to_album for user {}, album {}, photos: {:?}",
            user_id,
            album_id,
            photo_ids
        );

        let user_db = self.db.get_user_database(user_id)?;
        let conn = user_db.lock();

        // Disallow membership changes for live albums
        let is_live: bool = conn
            .query_row(
                "SELECT COALESCE(is_live, FALSE) FROM albums WHERE id = ?",
                params![album_id],
                |row| row.get::<_, bool>(0),
            )
            .unwrap_or(false);
        if is_live {
            return Err(anyhow!("Cannot add photos to a live album"));
        }

        // Check database file path for debugging
        if let Ok(mut stmt) = conn.prepare("PRAGMA database_list") {
            if let Ok(rows) = stmt.query_map([], |row| {
                let name: String = row.get(1)?;
                let file: String = row.get(2)?;
                Ok((name, file))
            }) {
                for r in rows.flatten() {
                    if r.0 == "main" {
                        tracing::info!("Operating on database file: {}", r.1);
                        break;
                    }
                }
            }
        }

        let now = chrono::Utc::now().timestamp();

        tracing::info!("Starting transaction for album {}", album_id);
        let tx = conn.unchecked_transaction()?;

        let mut added_count = 0;
        let mut skipped_count = 0;

        for photo_id in photo_ids {
            // Check if this photo is already in the album
            let exists: bool = tx
                .query_row(
                    "SELECT COUNT(*) > 0 FROM album_photos WHERE organization_id = ? AND album_id = ? AND photo_id = ?",
                    params![org_id, album_id, photo_id],
                    |row| row.get(0),
                )
                .unwrap_or(false);

            if exists {
                skipped_count += 1;
                tracing::debug!("Photo {} already in album {}, skipping", photo_id, album_id);
                continue;
            }

            // Use INSERT without OR IGNORE to catch actual errors
            match tx.execute(
                "INSERT INTO album_photos (organization_id, album_id, photo_id, added_at) VALUES (?, ?, ?, ?)",
                params![org_id, album_id, photo_id, now],
            ) {
                Ok(rows) => {
                    added_count += 1;
                    tracing::info!(
                        "Successfully inserted photo {} to album {} (rows affected: {})",
                        photo_id,
                        album_id,
                        rows
                    );
                }
                Err(e) => {
                    tracing::error!(
                        "Failed to add photo {} to album {}: {}",
                        photo_id,
                        album_id,
                        e
                    );
                    // Rollback and return error
                    let _ = tx.rollback();
                    return Err(anyhow!("Failed to add photo {} to album: {}", photo_id, e));
                }
            }
        }

        tracing::info!(
            "Album {}: added {} photos, skipped {} already existing",
            album_id,
            added_count,
            skipped_count
        );

        let new_count = Self::compute_active_album_count(&tx, org_id, album_id)?;
        match tx.execute(
            "UPDATE albums SET updated_at = ?, photo_count = ? WHERE id = ?",
            params![now, new_count, album_id],
        ) {
            Ok(rows) => {
                tracing::info!(
                    "Updated album {} metadata (rows affected: {}, photo_count={})",
                    album_id,
                    rows,
                    new_count
                );
            }
            Err(e) => {
                tracing::error!("Failed to update album {}: {}", album_id, e);
                let _ = tx.rollback();
                return Err(anyhow!("Failed to update album: {}", e));
            }
        }

        tracing::info!("Committing transaction for album {}", album_id);
        match tx.commit() {
            Ok(_) => {
                tracing::info!("Transaction committed successfully for album {}", album_id);

                // Force a checkpoint to ensure data is persisted to disk
                match conn.execute("CHECKPOINT", []) {
                    Ok(_) => {
                        tracing::info!("Checkpoint executed successfully for album {}", album_id);
                    }
                    Err(e) => {
                        tracing::warn!("Failed to execute checkpoint: {}", e);
                    }
                }

                // Verify the data was actually written
                let verify_count: i64 = conn
                    .query_row(
                        "SELECT COUNT(*) FROM album_photos WHERE organization_id = ? AND album_id = ?",
                        params![org_id, album_id],
                        |row| row.get(0),
                    )
                    .unwrap_or(0);
                tracing::info!(
                    "Verification: album {} now has {} photos in database",
                    album_id,
                    verify_count
                );

                // Double-check with a fresh query to ensure persistence
                let all_photos: Vec<(i32, i32)> = conn
                    .prepare("SELECT album_id, photo_id FROM album_photos WHERE organization_id = ? AND album_id = ?")?
                    .query_map(params![org_id, album_id], |row| {
                        Ok((row.get::<_, i32>(0)?, row.get::<_, i32>(1)?))
                    })?
                    .collect::<Result<Vec<_>, _>>()
                    .unwrap_or_else(|_| Vec::new());

                tracing::info!("Album {} photos after commit: {:?}", album_id, all_photos);
            }
            Err(e) => {
                tracing::error!("Failed to commit transaction for album {}: {}", album_id, e);
                return Err(anyhow!("Failed to commit transaction: {}", e));
            }
        }

        Ok(())
    }

    pub async fn remove_photos_from_album(
        &self,
        user_id: &str,
        album_id: i32,
        photo_ids: Vec<i32>,
    ) -> Result<()> {
        // Resolve organization_id
        let org_id: i32 = {
            let users_conn = self.db.users_connection();
            let conn = users_conn.lock();
            conn.query_row(
                "SELECT organization_id FROM users WHERE user_id = ? LIMIT 1",
                duckdb::params![user_id],
                |row| row.get::<_, i32>(0),
            )
            .unwrap_or(1)
        };

        let user_db = self.db.get_user_database(user_id)?;
        let conn = user_db.lock();

        // Disallow membership changes for live albums
        let is_live: bool = conn
            .query_row(
                "SELECT COALESCE(is_live, FALSE) FROM albums WHERE id = ?",
                params![album_id],
                |row| row.get::<_, bool>(0),
            )
            .unwrap_or(false);
        if is_live {
            return Err(anyhow!("Cannot remove photos from a live album"));
        }

        let tx = conn.unchecked_transaction()?;

        // Remove each photo individually
        for photo_id in photo_ids {
            tx.execute(
                "DELETE FROM album_photos WHERE organization_id = ? AND album_id = ? AND photo_id = ?",
                params![org_id, album_id, photo_id],
            )?;
        }

        // Update album's updated_at
        let now = chrono::Utc::now().timestamp();
        let new_count = Self::compute_active_album_count(&tx, org_id, album_id)?;
        tx.execute(
            "UPDATE albums SET updated_at = ?, photo_count = ? WHERE id = ?",
            params![now, new_count, album_id],
        )?;

        tx.commit()?;

        // Force checkpoint to ensure removal is persisted
        conn.execute("CHECKPOINT", [])?;

        Ok(())
    }

    /// Merge a regular source album into a regular target album.
    /// - Moves all unique photo memberships from source to target (deduplicated)
    /// - Optionally deletes the source album (default true). Only leaf albums are allowed as source.
    /// - Returns counts for added/skipped/total in target.
    pub async fn merge_albums(
        &self,
        user_id: &str,
        source_album_id: i32,
        target_album_id: i32,
        delete_source: bool,
        dry_run: bool,
    ) -> Result<(i64, i64, i64, bool)> {
        // Resolve organization_id for this user
        let org_id: i32 = {
            let users_conn = self.db.users_connection();
            let conn = users_conn.lock();
            conn.query_row(
                "SELECT organization_id FROM users WHERE user_id = ? LIMIT 1",
                duckdb::params![user_id],
                |row| row.get::<_, i32>(0),
            )
            .unwrap_or(1)
        };

        let user_db = self.db.get_user_database(user_id)?;

        if source_album_id == target_album_id {
            return Err(anyhow!("Source and target albums must be different"));
        }

        // Validate albums exist and are regular (not live)
        // Use a scoped block for DB guards so they drop before any await
        let (added_count, skipped_count, total_in_target_after) = {
            let conn = user_db.lock();
            let (source_exists, source_is_live): (bool, bool) = conn
                .query_row(
                    "SELECT COUNT(*) > 0, COALESCE(MAX(is_live), FALSE) FROM albums WHERE id = ?",
                    params![source_album_id],
                    |row| Ok((row.get::<_, bool>(0)?, row.get::<_, bool>(1)?)),
                )
                .unwrap_or((false, false));
            if !source_exists {
                return Err(anyhow!("Source album not found"));
            }
            if source_is_live {
                return Err(anyhow!("Cannot merge from a live album"));
            }

            let (target_exists, target_is_live): (bool, bool) = conn
                .query_row(
                    "SELECT COUNT(*) > 0, COALESCE(MAX(is_live), FALSE) FROM albums WHERE id = ?",
                    params![target_album_id],
                    |row| Ok((row.get::<_, bool>(0)?, row.get::<_, bool>(1)?)),
                )
                .unwrap_or((false, false));
            if !target_exists {
                return Err(anyhow!("Target album not found"));
            }
            if target_is_live {
                return Err(anyhow!("Cannot merge into a live album"));
            }

            // Only allow merging from leaf albums to avoid implicit subtree deletion surprises
            let child_count: i64 = conn
                .query_row(
                    "SELECT COUNT(*) FROM albums WHERE parent_id = ?",
                    params![source_album_id],
                    |row| row.get(0),
                )
                .unwrap_or(0);
            if child_count > 0 {
                return Err(anyhow!(
                    "Cannot merge an album that has sub-albums. Move or delete sub-albums first."
                ));
            }

            // Compute counts
            let added_count: i64 = conn
                .query_row(
                    "SELECT COUNT(*) FROM album_photos ap \
                 LEFT JOIN album_photos ap2 \
                   ON ap2.organization_id = ap.organization_id AND ap2.album_id = ? AND ap2.photo_id = ap.photo_id \
                 WHERE ap.organization_id = ? AND ap.album_id = ? AND ap2.photo_id IS NULL",
                    params![target_album_id, org_id, source_album_id],
                    |row| row.get(0),
                )
                .unwrap_or(0);
            let target_count_before: i64 = conn
                .query_row(
                    "SELECT COUNT(*) FROM album_photos WHERE organization_id = ? AND album_id = ?",
                    params![org_id, target_album_id],
                    |row| row.get(0),
                )
                .unwrap_or(0);
            let source_total: i64 = conn
                .query_row(
                    "SELECT COUNT(*) FROM album_photos WHERE organization_id = ? AND album_id = ?",
                    params![org_id, source_album_id],
                    |row| row.get(0),
                )
                .unwrap_or(0);
            let skipped_count = source_total.saturating_sub(added_count);
            let total_in_target_after = target_count_before + added_count;

            if dry_run {
                return Ok((added_count, skipped_count, total_in_target_after, false));
            }

            let now = chrono::Utc::now().timestamp();
            let tx = conn.unchecked_transaction()?;

            // First, collect the photos we need to move (before deleting anything)
            let photos_to_move: Vec<i32> = {
                let mut stmt = tx.prepare(
                    "SELECT ap.photo_id FROM album_photos ap \
                     LEFT JOIN album_photos ap2 \
                       ON ap2.organization_id = ap.organization_id AND ap2.album_id = ? AND ap2.photo_id = ap.photo_id \
                     WHERE ap.organization_id = ? AND ap.album_id = ? AND ap2.photo_id IS NULL",
                )?;
                let rows = stmt
                    .query_map(params![target_album_id, org_id, source_album_id], |row| {
                        row.get::<_, i32>(0)
                    })?;
                rows.filter_map(|r| r.ok()).collect()
            };

            tracing::debug!(
                "[merge] photos_to_move={} src={} dst={}",
                photos_to_move.len(),
                source_album_id,
                target_album_id
            );

            // First, insert the photos into the target album (before deleting anything)
            tracing::debug!(
                "[merge] inserting {} photos into target album",
                photos_to_move.len()
            );
            for photo_id in photos_to_move.iter() {
                // Check if already exists to avoid conflicts
                let exists: bool = tx
                    .query_row(
                        "SELECT COUNT(*) > 0 FROM album_photos WHERE organization_id = ? AND album_id = ? AND photo_id = ?",
                        params![org_id, target_album_id, photo_id],
                        |row| row.get(0),
                    )
                    .unwrap_or(false);

                if !exists {
                    tx.execute(
                        "INSERT INTO album_photos (organization_id, album_id, photo_id, added_at) VALUES (?, ?, ?, ?)",
                        params![org_id, target_album_id, photo_id, now],
                    )?;
                    tracing::debug!(
                        "[merge] inserted photo {} into album {}",
                        photo_id,
                        target_album_id
                    );
                } else {
                    tracing::debug!(
                        "[merge] photo {} already in album {}, skipping",
                        photo_id,
                        target_album_id
                    );
                }
            }
            tracing::debug!("[merge] finished inserting into target album");

            // If we're deleting the source, just clear its photo memberships here (avoid touching albums row in-Tx)
            if delete_source {
                tracing::debug!("[merge] deleting source album_photos");
                let deleted_photos = tx.execute(
                    &format!(
                        "DELETE FROM album_photos WHERE album_id = {}",
                        source_album_id
                    ),
                    [],
                )?;
                tracing::debug!("[merge] deleted {} source associations", deleted_photos);
            }

            // If we're not deleting the source album, just remove the moved photos from it
            if !delete_source && !photos_to_move.is_empty() {
                let photo_ids_str = photos_to_move
                    .iter()
                    .map(|id| id.to_string())
                    .collect::<Vec<_>>()
                    .join(",");
                tx.execute(
                    &format!(
                        "DELETE FROM album_photos WHERE organization_id = ? AND album_id = ? AND photo_id IN ({})",
                        photo_ids_str
                    ),
                    params![org_id, source_album_id],
                )?;
            }

            tx.commit()?;
            // Ensure durability of the insert/deletion
            let _ = conn.execute("CHECKPOINT", []);

            // Optionally soft-delete the source album outside the Tx (best-effort; avoid FK engine quirks)
            if delete_source {
                let now_ts = chrono::Utc::now().timestamp();
                let has_deleted_at: bool = conn
                    .query_row(
                        "SELECT COUNT(*) > 0 FROM information_schema.columns WHERE lower(table_name)='albums' AND lower(column_name)='deleted_at'",
                        [],
                        |row| row.get(0),
                    )
                    .unwrap_or(false);
                if has_deleted_at {
                    let _ = conn.execute(
                        "UPDATE albums SET deleted_at = ?, name = name || ' (merged #' || CAST(id AS VARCHAR) || ')', parent_id = NULL, updated_at = ? WHERE id = ?",
                        params![now_ts, now_ts, source_album_id],
                    );
                } else {
                    let _ = conn.execute(
                        "UPDATE albums SET name = name || ' (merged #' || CAST(id AS VARCHAR) || ')', parent_id = NULL, updated_at = ? WHERE id = ?",
                        params![now_ts, source_album_id],
                    );
                }
            }

            // Skip touching target's updated_at to avoid FK engine quirks during tight update windows

            (added_count, skipped_count, total_in_target_after)
        };

        let deleted = delete_source;

        Ok((added_count, skipped_count, total_in_target_after, deleted))
    }

    async fn get_album(&self, user_id: &str, album_id: i32) -> Result<Album> {
        let user_db = self.db.get_user_database(user_id)?;
        let conn = user_db.lock();

        let album = conn.query_row(
            "SELECT a.id, a.name, a.description, a.parent_id, a.position, a.cover_photo_id, p2.asset_id,
                    a.created_at, a.updated_at,
                    (SELECT COUNT(*) FROM album_photos ap2 JOIN photos p3 ON ap2.photo_id = p3.id
                       WHERE ap2.album_id = a.id AND COALESCE(p3.delete_time, 0) = 0) AS photo_count,
                    COALESCE((SELECT MAX(depth) FROM album_closure ac WHERE ac.descendant_id = a.id), 0) as depth,
                    COALESCE(a.is_live, FALSE) as is_live
             FROM albums a
             LEFT JOIN photos p2 ON a.cover_photo_id = p2.id
             WHERE a.id = ?
             GROUP BY a.id, a.name, a.description, a.parent_id, a.position, a.cover_photo_id, p2.asset_id,
                      a.created_at, a.updated_at, a.is_live",
            params![album_id],
            |row| {
                Ok(Album {
                    id: row.get(0)?,
                    name: row.get(1)?,
                    description: row.get(2)?,
                    parent_id: row.get(3)?,
                    position: row.get(4)?,
                    cover_photo_id: row.get(5)?,
                    cover_asset_id: row.get(6)?,
                    created_at: row.get(7)?,
                    updated_at: row.get(8)?,
                    photo_count: row.get::<_, i64>(9)? as usize,
                    depth: row.get::<_, i64>(10)? as i32,
                    is_live: row.get::<_, bool>(11).unwrap_or(false),
                    rating_min: None,
                })
            }
        )?;

        Ok(album)
    }
}
