use anyhow::{Context, Result};
use async_trait::async_trait;
use tokio_postgres::Client;

use crate::database::meta_store::{MetaStore, PhotoUpsert};
use crate::photos::service::PhotoListQuery;
use crate::photos::Photo as PhotoDTO;

#[derive(Clone)]
pub struct PgMetaStore {
    client: std::sync::Arc<Client>,
}

impl PgMetaStore {
    pub fn new(client: std::sync::Arc<Client>) -> Self {
        Self { client }
    }
}

#[async_trait]
impl MetaStore for PgMetaStore {
    async fn resolve_org_id(&self, user_id: &str) -> Result<i32> {
        let row = self
            .client
            .query_one(
                "SELECT organization_id FROM users WHERE user_id = $1 LIMIT 1",
                &[&user_id],
            )
            .await?;
        Ok(row.get::<_, i32>(0))
    }

    async fn upsert_photo(
        &self,
        organization_id: i32,
        user_id: &str,
        p: &PhotoUpsert,
    ) -> Result<()> {
        // Diagnostics: flag non-finite floats that may cause serialization errors
        let ap_ok = p.aperture.map(|v| v.is_finite()).unwrap_or(true);
        let fl_ok = p.focal_length.map(|v| v.is_finite()).unwrap_or(true);
        let lat_ok = p.latitude.map(|v| v.is_finite()).unwrap_or(true);
        let lon_ok = p.longitude.map(|v| v.is_finite()).unwrap_or(true);
        let alt_ok = p.altitude.map(|v| v.is_finite()).unwrap_or(true);
        if !(ap_ok && fl_ok && lat_ok && lon_ok && alt_ok) {
            tracing::warn!(
                target = "upload",
                "[PG] upsert_photo non-finite floats detected: asset_id={} aperture={:?} focal_length={:?} lat={:?} lon={:?} alt={:?}",
                p.asset_id, p.aperture, p.focal_length, p.latitude, p.longitude, p.altitude
            );
        }
        // Normalize float types to f64 for driver stability and rely on PG coercion where needed
        let ap64: Option<f64> = p.aperture.map(|v| v as f64);
        let foc64: Option<f64> = p.focal_length.map(|v| v as f64);

        // Insert or update by tenant+asset
        let sql = "INSERT INTO photos (
	                organization_id, user_id, asset_id, path, filename, mime_type, created_at, modified_at,
	                size, width, height, orientation, favorites, locked, is_video, is_live_photo, live_video_path,
	                duration_ms, delete_time, is_screenshot, has_gain_map, hdr_kind, camera_make, camera_model, iso, aperture, shutter_speed,
	                focal_length, latitude, longitude, altitude, location_name, city, province, country, caption, description,
	                backup_id, last_indexed
	            ) VALUES (
	                $1, $2, $3, $4, $5, $6, $7, $8,
	                $9, $10::integer, $11::integer, $12::integer, 0, FALSE, $13::boolean, $14::boolean, $15,
	                $16::bigint, 0, $17::integer, $18::boolean, $19, $20, $21, $22::integer, $23::double precision, $24,
	                $25::double precision, $26::double precision, $27::double precision, $28::double precision, $29, $30, $31, $32, $33, $34,
	                $35, $36::bigint
	            ) ON CONFLICT (organization_id, asset_id) DO UPDATE SET
	                user_id = EXCLUDED.user_id,
	                path = EXCLUDED.path,
	                filename = EXCLUDED.filename,
	                mime_type = EXCLUDED.mime_type,
	                backup_id = EXCLUDED.backup_id,
	                created_at = EXCLUDED.created_at,
	                modified_at = EXCLUDED.modified_at,
	                size = EXCLUDED.size,
	                width = EXCLUDED.width,
                height = EXCLUDED.height,
                orientation = EXCLUDED.orientation,
                is_video = EXCLUDED.is_video,
                is_live_photo = EXCLUDED.is_live_photo,
                live_video_path = EXCLUDED.live_video_path,
                duration_ms = EXCLUDED.duration_ms,
                is_screenshot = EXCLUDED.is_screenshot,
                has_gain_map = EXCLUDED.has_gain_map,
                hdr_kind = EXCLUDED.hdr_kind,
                camera_make = EXCLUDED.camera_make,
                camera_model = EXCLUDED.camera_model,
                iso = EXCLUDED.iso,
                aperture = EXCLUDED.aperture,
                shutter_speed = EXCLUDED.shutter_speed,
                focal_length = EXCLUDED.focal_length,
                latitude = EXCLUDED.latitude,
                longitude = EXCLUDED.longitude,
                altitude = EXCLUDED.altitude,
                location_name = EXCLUDED.location_name,
                city = EXCLUDED.city,
                province = EXCLUDED.province,
                country = EXCLUDED.country,
                caption = EXCLUDED.caption,
                description = EXCLUDED.description,
                last_indexed = EXCLUDED.last_indexed";

        self.client
            .execute(
                sql,
                &[
                    &organization_id,
                    &user_id,
                    &p.asset_id,
                    &p.path,
                    &p.filename,
                    &p.mime_type,
                    &p.created_at,
                    &p.modified_at,
                    &p.size,
                    &p.width,
                    &p.height,
                    &p.orientation,
                    &p.is_video,
                    &p.is_live_photo,
                    &p.live_video_path,
                    &p.duration_ms,
                    &p.is_screenshot,
                    &p.has_gain_map,
                    &p.hdr_kind,
                    &p.camera_make,
                    &p.camera_model,
                    &p.iso,
                &ap64,
                &p.shutter_speed,
                &foc64,
                &p.latitude,
                &p.longitude,
                &p.altitude,
                    &p.location_name,
                    &p.city,
	                    &p.province,
	                    &p.country,
	                    &p.caption,
	                    &p.description,
	                    &p.backup_id,
	                    &p.modified_at, // last_indexed
	                ],
	            )
            .await
            .map_err(|e| {
                // Include a brief param summary to aid debugging parameter index errors
                let diag = format!(
                    "asset_id={} w={:?} h={:?} orient={:?} is_video={} iso={:?} aperture={:?} focal={:?} lat={:?} lon={:?} alt={:?}",
                    p.asset_id,
                    p.width,
                    p.height,
                    p.orientation,
                    p.is_video,
                    p.iso,
                    p.aperture,
                    p.focal_length,
                    p.latitude,
                    p.longitude,
                    p.altitude
                );
                tracing::warn!(target="upload", "[PG] upsert_photo execute error: {} | {}", e.to_string(), diag);
                e
            })?;
        Ok(())
    }

    async fn insert_or_update_phash(
        &self,
        organization_id: i32,
        asset_id: &str,
        phash_hex: &str,
    ) -> Result<()> {
        let sql = "INSERT INTO photo_hashes (organization_id, asset_id, phash_hex)
                   VALUES ($1, $2, $3)
                   ON CONFLICT (organization_id, asset_id) DO UPDATE SET phash_hex = EXCLUDED.phash_hex";
        self.client
            .execute(sql, &[&organization_id, &asset_id, &phash_hex])
            .await?;
        Ok(())
    }

    async fn list_photos(
        &self,
        organization_id: i32,
        user_id: &str,
        query: &PhotoListQuery,
    ) -> Result<(Vec<PhotoDTO>, i64)> {
        // If a live album is targeted, load its criteria and overlay incoming page/limit/sort.
        let mut q: PhotoListQuery = query.clone();
        if let Some(album_id) = q.album_id {
            if let Ok(row_opt) = self
                .client
                .query_opt(
                    "SELECT COALESCE(is_live, FALSE), live_criteria FROM albums WHERE organization_id=$1 AND user_id=$2 AND id=$3",
                    &[&organization_id, &user_id, &album_id],
                )
                .await
            {
                if let Some(row) = row_opt {
                    let is_live: bool = row.get::<_, bool>(0);
                    if is_live {
                        let crit_json: Option<String> = row.get::<_, Option<String>>(1);
                        if let Some(cj) = crit_json {
                            if let Ok(mut crit) = serde_json::from_str::<PhotoListQuery>(&cj) {
                                // Prevent recursion and album membership join for live albums
                                crit.album_id = None;
                                crit.album_ids = None;
                                crit.album_subtree = None;
                                // Overlay paging/sorting from incoming request
                                if let Some(p) = q.page { crit.page = Some(p); }
                                if let Some(l) = q.limit { crit.limit = Some(l); }
                                if let Some(sb) = q.sort_by.clone() { crit.sort_by = Some(sb); }
                                if let Some(so) = q.sort_order.clone() { crit.sort_order = Some(so); }
                                if let Some(sr) = q.sort_random_seed { crit.sort_random_seed = Some(sr); }
                                q = crit;
                            }
                        }
                    }
                }
            }
        }

        // Basic filters aligned with DuckDB path
        let page = q.page.unwrap_or(1);
        let limit = q.limit.unwrap_or(100).min(500);
        let offset = (page - 1) * limit;
        let sort_by = q.sort_by.as_deref().unwrap_or("created_at");
        let sort_order = q.sort_order.as_deref().unwrap_or("DESC");

        // WHERE base
        let mut where_sql = String::from("p.organization_id = $1 AND p.user_id = $2");
        // Locked/trashed flags
        let include_locked = q.include_locked.unwrap_or(false);
        let locked_only = q.filter_locked_only.unwrap_or(false);
        if locked_only {
            where_sql.push_str(" AND COALESCE(p.locked, FALSE) = TRUE");
        } else if !include_locked {
            where_sql.push_str(" AND COALESCE(p.locked, FALSE) = FALSE");
        }
        let include_trashed = q.include_trashed.unwrap_or(false);
        let trashed_only = q.filter_trashed_only.unwrap_or(false);
        if trashed_only {
            where_sql.push_str(" AND COALESCE(p.delete_time, 0) > 0");
        } else if !include_trashed {
            where_sql.push_str(" AND COALESCE(p.delete_time, 0) = 0");
        }
        // Optional JOINs buffer
        let mut join_sql = String::new();
        let mut params: Vec<&(dyn tokio_postgres::types::ToSql + Sync)> = Vec::new();
        params.push(&organization_id);
        params.push(&user_id);

        if let Some(fav) = q.filter_favorite {
            if fav {
                where_sql.push_str(" AND p.favorites > 0");
            }
        }
        if let Some(minr) = q.filter_rating_min {
            if minr > 0 {
                where_sql.push_str(" AND COALESCE(p.rating, 0) >= ");
                where_sql.push_str(&minr.min(5).to_string());
            }
        }
        if let Some(is_video) = q.filter_is_video {
            where_sql.push_str(" AND p.is_video = ");
            where_sql.push_str(if is_video { "TRUE" } else { "FALSE" });
        }
        if let Some(city) = &q.filter_city {
            where_sql.push_str(" AND p.city = ");
            where_sql.push('"');
            where_sql.push_str(&city.replace('"', "\""));
            where_sql.push('"');
        }
        if let Some(country) = &q.filter_country {
            where_sql.push_str(" AND p.country = ");
            where_sql.push('"');
            where_sql.push_str(&country.replace('"', "\""));
            where_sql.push('"');
        }
        if let Some(date_from) = q.filter_date_from {
            where_sql.push_str(" AND p.created_at >= ");
            where_sql.push_str(&date_from.to_string());
        }
        if let Some(date_to) = q.filter_date_to {
            where_sql.push_str(" AND p.created_at <= ");
            where_sql.push_str(&date_to.to_string());
        }
        if let Some(s) = q.filter_screenshot {
            if s {
                where_sql.push_str(" AND p.is_screenshot = 1 AND p.is_video = FALSE");
            } else {
                where_sql.push_str(" AND p.is_screenshot = 0");
            }
        }
        if let Some(live) = q.filter_live_photo {
            where_sql.push_str(" AND p.is_live_photo = ");
            where_sql.push_str(if live { "TRUE" } else { "FALSE" });
            if live {
                where_sql.push_str(" AND p.is_video = FALSE");
            }
        }

        // Album filters
        if let Some(ids_csv) = &q.album_ids {
            // AND semantics across all provided IDs (no subtree expansion for album_ids)
            let roots: Vec<i32> = ids_csv
                .split(',')
                .filter_map(|s| s.trim().parse::<i32>().ok())
                .collect();
            for (idx, root_id) in roots.iter().enumerate() {
                let alias = format!("ap{}", idx);
                join_sql.push_str(&format!(
                    " INNER JOIN album_photos {} ON {}.organization_id = p.organization_id AND {}.photo_id = p.id",
                    alias, alias, alias
                ));
                where_sql.push_str(&format!(" AND {}.album_id = {}", alias, root_id));
            }
        } else if let Some(album_id) = q.album_id {
            join_sql.push_str(
                " INNER JOIN album_photos ap ON ap.organization_id = p.organization_id AND ap.photo_id = p.id",
            );
            if q.album_subtree.unwrap_or(true) {
                // Expand descendants via album_closure
                let rows = self
                    .client
                    .query(
                        "SELECT descendant_id FROM album_closure WHERE organization_id=$1 AND ancestor_id=$2",
                        &[&organization_id, &album_id],
                    )
                    .await
                    .unwrap_or_default();
                let mut ids: Vec<i32> = vec![album_id];
                for r in rows {
                    ids.push(r.get::<_, i32>(0));
                }
                let inlist = ids
                    .into_iter()
                    .map(|id| id.to_string())
                    .collect::<Vec<_>>()
                    .join(",");
                where_sql.push_str(&format!(" AND ap.album_id IN ({})", inlist));
            } else {
                where_sql.push_str(&format!(" AND ap.album_id = {}", album_id));
            }
        }

        // Face filters (person_id list)
        if let Some(face_param) = &q.filter_faces {
            let ids: Vec<String> = face_param
                .split(',')
                .map(|s| s.trim())
                .filter(|s| !s.is_empty())
                .map(|s| s.to_string())
                .collect();
            if !ids.is_empty() {
                match q.filter_faces_mode.as_deref() {
                    Some("any") => {
                        join_sql.push_str(
                            " INNER JOIN faces f ON f.organization_id = p.organization_id AND f.asset_id = p.asset_id",
                        );
                        let in_list = ids
                            .iter()
                            .map(|s| format!("'{}'", s.replace("'", "''")))
                            .collect::<Vec<_>>()
                            .join(",");
                        where_sql.push_str(&format!(" AND f.person_id IN ({})", in_list));
                    }
                    _ => {
                        // AND semantics: asset must contain all selected person_ids
                        let in_list = ids
                            .iter()
                            .map(|s| format!("'{}'", s.replace("'", "''")))
                            .collect::<Vec<_>>()
                            .join(",");
                        let need = ids.len();
                        where_sql.push_str(&format!(
                            " AND p.asset_id IN (SELECT f.asset_id FROM faces f WHERE f.organization_id = {} AND f.person_id IN ({}) GROUP BY f.asset_id HAVING COUNT(DISTINCT f.person_id) = {})",
                            organization_id, in_list, need
                        ));
                    }
                }
            }
        }

        let from_sql = format!(" FROM photos p{} WHERE {}", join_sql, where_sql);
        tracing::info!(
            target = "upload",
            "[PG-LIST/SQL] org={} user={} where='{}' join='{}' sort_by={} order={} page={} limit={}",
            organization_id,
            user_id,
            where_sql,
            if join_sql.is_empty() { "" } else { join_sql.as_str() },
            sort_by,
            sort_order,
            page,
            limit
        );
        let count_sql = format!("SELECT COUNT(*){}", from_sql);
        let row = self.client.query_one(&count_sql, &params).await?;
        let total: i64 = row.get(0);
        if total == 0 {
            // Sanity check by loosening filters to pinpoint mismatch
            if let Ok(row2) = self
                .client
                .query_one(
                    "SELECT COUNT(*) FROM photos p WHERE p.organization_id=$1 AND p.user_id=$2",
                    &[&organization_id, &user_id],
                )
                .await
            {
                let t2: i64 = row2.get(0);
                tracing::info!(
                    target = "upload",
                    "[PG-LIST/SQL] sanity org={} user={} base_count={}",
                    organization_id,
                    user_id,
                    t2
                );
            }
        }

        let data_sql = format!(
            "SELECT p.id, p.asset_id, COALESCE(p.filename,'') AS filename, p.mime_type, p.has_gain_map, p.hdr_kind, p.created_at, p.modified_at, p.size, p.width, p.height, p.orientation, p.favorites, p.locked, p.delete_time, p.is_video, p.is_live_photo, p.duration_ms, p.is_screenshot, p.camera_make, p.camera_model, p.iso, p.aperture, p.shutter_speed, p.focal_length, p.location_name, p.city, p.province, p.country, p.rating{} ORDER BY p.{} {} LIMIT {} OFFSET {}",
            from_sql, sort_by, sort_order, limit, offset
        );
        let rows = self.client.query(&data_sql, &params).await?;
        let mut out: Vec<PhotoDTO> = Vec::with_capacity(rows.len());
        for r in rows {
            out.push(PhotoDTO {
                id: r.get(0),
                asset_id: r.get(1),
                path: String::new(),
                filename: r.get(2),
                mime_type: r.get(3),
                has_gain_map: r.get(4),
                hdr_kind: r.get(5),
                created_at: r.get(6),
                modified_at: r.get(7),
                size: r.get(8),
                width: r.get(9),
                height: r.get(10),
                orientation: r.get(11),
                favorites: r.get(12),
                locked: r.get(13),
                delete_time: r.get(14),
                is_video: r.get(15),
                is_live_photo: r.get(16),
                live_video_path: None,
                duration_ms: r.get(17),
                is_screenshot: r.get(18),
                camera_make: r.get(19),
                camera_model: r.get(20),
                iso: r.get(21),
                aperture: r.get(22),
                shutter_speed: r.get(23),
                focal_length: r.get(24),
                latitude: None,
                longitude: None,
                altitude: None,
                location_name: r.get(25),
                city: r.get(26),
                province: r.get(27),
                country: r.get(28),
                caption: None,
                description: None,
                rating: r.get(29),
            });
        }
        Ok((out, total))
    }
}
