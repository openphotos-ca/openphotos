use anyhow::{Result, anyhow};
use duckdb::params;
use serde::{Deserialize, Serialize};
use std::path::Path;

use crate::database::multi_tenant::{MultiTenantDatabase, DbPool};
use super::Photo;

#[derive(Debug, Deserialize)]
pub struct PhotoListQuery {
    pub page: Option<u32>,
    pub limit: Option<u32>,
    pub sort_by: Option<String>,
    pub sort_order: Option<String>,
    pub filter_city: Option<String>,
    pub filter_country: Option<String>,
    pub filter_date_from: Option<i64>,
    pub filter_date_to: Option<i64>,
    pub filter_screenshot: Option<bool>,
    pub filter_live_photo: Option<bool>,
    pub filter_faces: Option<Vec<String>>,
    pub album_id: Option<i32>,
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
    pub cover_photo_id: Option<i32>,
    pub photo_count: usize,
    pub created_at: i64,
    pub updated_at: i64,
}

#[derive(Debug, Deserialize)]
pub struct CreateAlbumRequest {
    pub name: String,
    pub description: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct UpdateAlbumRequest {
    pub name: Option<String>,
    pub description: Option<String>,
    pub cover_photo_id: Option<i32>,
}

#[derive(Debug, Deserialize)]
pub struct AlbumPhotosRequest {
    pub photo_ids: Vec<i32>,
}

pub struct PhotoService {
    db: MultiTenantDatabase,
}

impl PhotoService {
    pub fn new(db: MultiTenantDatabase) -> Self {
        Self { db }
    }
    
    pub async fn list_photos(
        &self,
        user_id: &str,
        query: PhotoListQuery,
    ) -> Result<PhotoListResponse> {
        let user_db = self.db.get_user_database(user_id)?;
        let conn = user_db.lock();
        
        let page = query.page.unwrap_or(1);
        let limit = query.limit.unwrap_or(100).min(500);
        let offset = (page - 1) * limit;
        
        // Build query
        let mut sql = String::from(
            "SELECT p.id, p.asset_id, p.path, p.filename, p.mime_type,
                    p.created_at, p.modified_at, p.size, p.width, p.height,
                    p.orientation, p.favorites, p.is_video, p.is_live_photo,
                    p.live_video_path, p.is_screenshot, p.camera_make, p.camera_model,
                    p.iso, p.aperture, p.shutter_speed, p.focal_length,
                    p.latitude, p.longitude, p.altitude, p.location_name,
                    p.city, p.province, p.country, p.notes
             FROM photos p"
        );
        
        let mut where_clauses = Vec::new();
        let mut params_vec: Vec<Box<dyn duckdb::ToSql>> = Vec::new();
        
        // Add filters
        if let Some(city) = &query.filter_city {
            where_clauses.push("p.city = ?");
            params_vec.push(Box::new(city.clone()));
        }
        
        if let Some(country) = &query.filter_country {
            where_clauses.push("p.country = ?");
            params_vec.push(Box::new(country.clone()));
        }
        
        if let Some(date_from) = query.filter_date_from {
            where_clauses.push("p.created_at >= ?");
            params_vec.push(Box::new(date_from));
        }
        
        if let Some(date_to) = query.filter_date_to {
            where_clauses.push("p.created_at <= ?");
            params_vec.push(Box::new(date_to));
        }
        
        if let Some(is_screenshot) = query.filter_screenshot {
            where_clauses.push("p.is_screenshot = ?");
            params_vec.push(Box::new(if is_screenshot { 1 } else { 0 }));
        }
        
        if let Some(is_live) = query.filter_live_photo {
            where_clauses.push("p.is_live_photo = ?");
            params_vec.push(Box::new(is_live));
        }
        
        // Handle album filter
        if let Some(album_id) = query.album_id {
            sql.push_str(" INNER JOIN album_photos ap ON p.id = ap.photo_id");
            where_clauses.push("ap.album_id = ?");
            params_vec.push(Box::new(album_id));
        }
        
        // Handle face filter
        if let Some(faces) = &query.filter_faces {
            if !faces.is_empty() {
                sql.push_str(" INNER JOIN face_photos fp ON p.id = fp.photo_id");
                sql.push_str(" INNER JOIN faces f ON fp.face_id = f.id");
                let placeholders = faces.iter().map(|_| "?").collect::<Vec<_>>().join(",");
                where_clauses.push(&format!("f.person_id IN ({})", placeholders));
                for face in faces {
                    params_vec.push(Box::new(face.clone()));
                }
            }
        }
        
        // Add WHERE clause
        if !where_clauses.is_empty() {
            sql.push_str(" WHERE ");
            sql.push_str(&where_clauses.join(" AND "));
        }
        
        // Add sorting
        let sort_by = query.sort_by.as_deref().unwrap_or("created_at");
        let sort_order = query.sort_order.as_deref().unwrap_or("DESC");
        sql.push_str(&format!(" ORDER BY p.{} {}", sort_by, sort_order));
        
        // Get total count
        let count_sql = sql.replace(
            "SELECT p.id, p.asset_id, p.path, p.filename, p.mime_type,
                    p.created_at, p.modified_at, p.size, p.width, p.height,
                    p.orientation, p.favorites, p.is_video, p.is_live_photo,
                    p.live_video_path, p.is_screenshot, p.camera_make, p.camera_model,
                    p.iso, p.aperture, p.shutter_speed, p.focal_length,
                    p.latitude, p.longitude, p.altitude, p.location_name,
                    p.city, p.province, p.country, p.notes",
            "SELECT COUNT(DISTINCT p.id)"
        );
        
        let total: usize = conn.query_row(&count_sql, params_vec.as_slice(), |row| {
            row.get::<_, i64>(0).map(|v| v as usize)
        })?;
        
        // Add pagination
        sql.push_str(&format!(" LIMIT {} OFFSET {}", limit, offset));
        
        // Execute query
        let mut stmt = conn.prepare(&sql)?;
        let photos = stmt.query_map(params_vec.as_slice(), |row| {
            Ok(Photo {
                id: Some(row.get(0)?),
                asset_id: row.get(1)?,
                path: row.get(2)?,
                filename: row.get(3)?,
                mime_type: row.get(4)?,
                created_at: row.get(5)?,
                modified_at: row.get(6)?,
                size: row.get(7)?,
                width: row.get(8)?,
                height: row.get(9)?,
                orientation: row.get(10)?,
                favorites: row.get(11)?,
                locked: false,
                delete_time: 0,
                is_video: row.get(12)?,
                is_live_photo: row.get(13)?,
                live_video_path: row.get(14)?,
                is_screenshot: row.get(15)?,
                camera_make: row.get(16)?,
                camera_model: row.get(17)?,
                iso: row.get(18)?,
                aperture: row.get(19)?,
                shutter_speed: row.get(20)?,
                focal_length: row.get(21)?,
                latitude: row.get(22)?,
                longitude: row.get(23)?,
                altitude: row.get(24)?,
                location_name: row.get(25)?,
                city: row.get(26)?,
                province: row.get(27)?,
                country: row.get(28)?,
                notes: row.get(29)?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
        
        Ok(PhotoListResponse {
            photos,
            total,
            page,
            limit,
            has_more: (page * limit) < total as u32,
        })
    }
    
    pub async fn get_photo(&self, user_id: &str, photo_id: i32) -> Result<Photo> {
        let user_db = self.db.get_user_database(user_id)?;
        let conn = user_db.lock();
        
        let photo = conn.query_row(
            "SELECT id, asset_id, path, filename, mime_type,
                    created_at, modified_at, size, width, height,
                    orientation, favorites, is_video, is_live_photo,
                    live_video_path, is_screenshot, camera_make, camera_model,
                    iso, aperture, shutter_speed, focal_length,
                    latitude, longitude, altitude, location_name,
                    city, province, country, notes
             FROM photos WHERE id = ?",
            params![photo_id],
            |row| {
                Ok(Photo {
                    id: Some(row.get(0)?),
                    asset_id: row.get(1)?,
                    path: row.get(2)?,
                    filename: row.get(3)?,
                    mime_type: row.get(4)?,
                    created_at: row.get(5)?,
                    modified_at: row.get(6)?,
                    size: row.get(7)?,
                    width: row.get(8)?,
                    height: row.get(9)?,
                orientation: row.get(10)?,
                favorites: row.get(11)?,
                locked: false,
                delete_time: 0,
                is_video: row.get(12)?,
                is_live_photo: row.get(13)?,
                live_video_path: row.get(14)?,
                is_screenshot: row.get(15)?,
                camera_make: row.get(16)?,
                    camera_model: row.get(17)?,
                    iso: row.get(18)?,
                    aperture: row.get(19)?,
                    shutter_speed: row.get(20)?,
                    focal_length: row.get(21)?,
                    latitude: row.get(22)?,
                    longitude: row.get(23)?,
                    altitude: row.get(24)?,
                    location_name: row.get(25)?,
                    city: row.get(26)?,
                    province: row.get(27)?,
                    country: row.get(28)?,
                    notes: row.get(29)?,
                })
            }
        )?;
        
        Ok(photo)
    }
    
    pub async fn list_albums(&self, user_id: &str) -> Result<Vec<Album>> {
        let user_db = self.db.get_user_database(user_id)?;
        let conn = user_db.lock();
        
        let mut stmt = conn.prepare(
            "SELECT a.id, a.name, a.description, a.cover_photo_id,
                    a.created_at, a.updated_at,
                    COUNT(ap.photo_id) as photo_count
             FROM albums a
             LEFT JOIN album_photos ap ON a.id = ap.album_id
             GROUP BY a.id, a.name, a.description, a.cover_photo_id,
                      a.created_at, a.updated_at
             ORDER BY a.updated_at DESC"
        )?;
        
        let albums = stmt.query_map([], |row| {
            Ok(Album {
                id: row.get(0)?,
                name: row.get(1)?,
                description: row.get(2)?,
                cover_photo_id: row.get(3)?,
                created_at: row.get(4)?,
                updated_at: row.get(5)?,
                photo_count: row.get::<_, i64>(6)? as usize,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
        
        Ok(albums)
    }
    
    pub async fn create_album(
        &self,
        user_id: &str,
        request: CreateAlbumRequest,
    ) -> Result<Album> {
        let user_db = self.db.get_user_database(user_id)?;
        let conn = user_db.lock();
        
        let now = chrono::Utc::now().timestamp();
        
        conn.execute(
            "INSERT INTO albums (name, description, created_at, updated_at)
             VALUES (?, ?, ?, ?)",
            params![&request.name, &request.description, now, now]
        )?;
        
        let album_id = conn.last_insert_rowid();
        
        Ok(Album {
            id: album_id as i32,
            name: request.name,
            description: request.description,
            cover_photo_id: None,
            photo_count: 0,
            created_at: now,
            updated_at: now,
        })
    }
    
    pub async fn update_album(
        &self,
        user_id: &str,
        album_id: i32,
        request: UpdateAlbumRequest,
    ) -> Result<Album> {
        let user_db = self.db.get_user_database(user_id)?;
        let conn = user_db.lock();
        
        let now = chrono::Utc::now().timestamp();
        
        // Build update query dynamically
        let mut updates = Vec::new();
        let mut params: Vec<Box<dyn duckdb::ToSql>> = Vec::new();
        
        if let Some(name) = &request.name {
            updates.push("name = ?");
            params.push(Box::new(name.clone()));
        }
        
        if let Some(desc) = &request.description {
            updates.push("description = ?");
            params.push(Box::new(desc.clone()));
        }
        
        if let Some(cover) = request.cover_photo_id {
            updates.push("cover_photo_id = ?");
            params.push(Box::new(cover));
        }
        
        updates.push("updated_at = ?");
        params.push(Box::new(now));
        
        params.push(Box::new(album_id));
        
        let sql = format!(
            "UPDATE albums SET {} WHERE id = ?",
            updates.join(", ")
        );
        
        conn.execute(&sql, params.as_slice())?;
        
        // Fetch and return updated album
        self.get_album(user_id, album_id).await
    }
    
    pub async fn delete_album(&self, user_id: &str, album_id: i32) -> Result<()> {
        let user_db = self.db.get_user_database(user_id)?;
        let conn = user_db.lock();
        
        conn.execute("DELETE FROM albums WHERE id = ?", params![album_id])?;
        
        Ok(())
    }
    
    pub async fn add_photos_to_album(
        &self,
        user_id: &str,
        album_id: i32,
        photo_ids: Vec<i32>,
    ) -> Result<()> {
        let user_db = self.db.get_user_database(user_id)?;
        let conn = user_db.lock();
        
        let now = chrono::Utc::now().timestamp();
        let tx = conn.unchecked_transaction()?;
        
        let mut stmt = tx.prepare(
            "INSERT OR IGNORE INTO album_photos (album_id, photo_id, added_at)
             VALUES (?, ?, ?)"
        )?;
        
        for photo_id in photo_ids {
            stmt.execute(params![album_id, photo_id, now])?;
        }
        
        // Update album's updated_at
        tx.execute(
            "UPDATE albums SET updated_at = ? WHERE id = ?",
            params![now, album_id]
        )?;
        
        tx.commit()?;
        
        Ok(())
    }
    
    pub async fn remove_photos_from_album(
        &self,
        user_id: &str,
        album_id: i32,
        photo_ids: Vec<i32>,
    ) -> Result<()> {
        let user_db = self.db.get_user_database(user_id)?;
        let conn = user_db.lock();
        
        let placeholders = photo_ids.iter().map(|_| "?").collect::<Vec<_>>().join(",");
        let sql = format!(
            "DELETE FROM album_photos WHERE album_id = ? AND photo_id IN ({})",
            placeholders
        );
        
        let mut params: Vec<Box<dyn duckdb::ToSql>> = Vec::new();
        params.push(Box::new(album_id));
        for id in photo_ids {
            params.push(Box::new(id));
        }
        
        conn.execute(&sql, params.as_slice())?;
        
        // Update album's updated_at
        conn.execute(
            "UPDATE albums SET updated_at = ? WHERE id = ?",
            params![chrono::Utc::now().timestamp(), album_id]
        )?;
        
        Ok(())
    }
    
    async fn get_album(&self, user_id: &str, album_id: i32) -> Result<Album> {
        let user_db = self.db.get_user_database(user_id)?;
        let conn = user_db.lock();
        
        let album = conn.query_row(
            "SELECT a.id, a.name, a.description, a.cover_photo_id,
                    a.created_at, a.updated_at,
                    COUNT(ap.photo_id) as photo_count
             FROM albums a
             LEFT JOIN album_photos ap ON a.id = ap.album_id
             WHERE a.id = ?
             GROUP BY a.id, a.name, a.description, a.cover_photo_id,
                      a.created_at, a.updated_at",
            params![album_id],
            |row| {
                Ok(Album {
                    id: row.get(0)?,
                    name: row.get(1)?,
                    description: row.get(2)?,
                    cover_photo_id: row.get(3)?,
                    created_at: row.get(4)?,
                    updated_at: row.get(5)?,
                    photo_count: row.get::<_, i64>(6)? as usize,
                })
            }
        )?;
        
        Ok(album)
    }
}
