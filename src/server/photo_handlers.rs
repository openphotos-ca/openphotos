use axum::{
    extract::{Path, Query, Request, State},
    http::{header, StatusCode},
    response::IntoResponse,
    Json,
};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::sync::Arc;
use tracing::{debug, info, instrument};

use crate::auth::middleware::get_current_user;
use crate::database::multi_tenant::MultiTenantDatabase;
use crate::photos::service::{
    AlbumPhotosRequest, CreateAlbumRequest, PhotoListQuery, PhotoService, UpdateAlbumRequest,
};
use crate::server::AppError;

#[instrument(skip(photo_service, request))]
pub async fn list_photos(
    State(photo_service): State<Arc<PhotoService>>,
    Query(query): Query<PhotoListQuery>,
    request: Request,
) -> Result<impl IntoResponse, AppError> {
    let user =
        get_current_user(&request).ok_or_else(|| anyhow::anyhow!("User not found in request"))?;

    info!(
        "[LIST_PHOTOS] Request from user: {} (name: {})",
        user.user_id, user.name
    );
    info!(
        "[LIST_PHOTOS] Query parameters: page={}, limit={}, sort_by={:?}, sort_order={:?}",
        query.page.unwrap_or(1),
        query.limit.unwrap_or(100),
        query.sort_by,
        query.sort_order
    );

    let response = photo_service.list_photos(&user.user_id, query).await?;

    info!(
        "[LIST_PHOTOS] Response: total={}, photos_count={}, has_more={}",
        response.total,
        response.photos.len(),
        response.has_more
    );

    Ok(Json(response))
}

#[instrument(skip(photo_service, request))]
pub async fn get_photo(
    State(photo_service): State<Arc<PhotoService>>,
    Path(photo_id): Path<i32>,
    request: Request,
) -> Result<impl IntoResponse, AppError> {
    let user =
        get_current_user(&request).ok_or_else(|| anyhow::anyhow!("User not found in request"))?;

    let photo = photo_service.get_photo(&user.user_id, photo_id).await?;

    Ok(Json(photo))
}

#[instrument(skip(db, request))]
pub async fn serve_image(
    State(db): State<Arc<MultiTenantDatabase>>,
    Path(asset_id): Path<String>,
    request: Request,
) -> Result<impl IntoResponse, AppError> {
    let user =
        get_current_user(&request).ok_or_else(|| anyhow::anyhow!("User not found in request"))?;

    let user_db = db.get_user_database(&user.user_id)?;
    let conn = user_db.lock();

    // Get photo path from database
    let path: String = conn
        .query_row(
            "SELECT path FROM photos WHERE asset_id = ?",
            [&asset_id],
            |row| row.get(0),
        )
        .map_err(|_| anyhow::anyhow!("Image not found"))?;

    // Read file and serve
    let image_data = tokio::fs::read(&path)
        .await
        .map_err(|e| anyhow::anyhow!("Failed to read image: {}", e))?;

    // Determine content type from file extension
    let content_type = match std::path::Path::new(&path)
        .extension()
        .and_then(|ext| ext.to_str())
        .map(|ext| ext.to_lowercase())
        .as_deref()
    {
        Some("jpg") | Some("jpeg") => "image/jpeg",
        Some("png") => "image/png",
        Some("gif") => "image/gif",
        Some("webp") => "image/webp",
        Some("heic") | Some("heif") => "image/heic",
        Some("avif") => "image/avif",
        _ => "image/jpeg",
    };

    let headers = [(header::CONTENT_TYPE, content_type)];
    Ok((headers, image_data))
}

#[instrument(skip(db, request))]
pub async fn serve_face_thumbnail(
    State(db): State<Arc<MultiTenantDatabase>>,
    Path(person_id): Path<String>,
    request: Request,
) -> Result<impl IntoResponse, AppError> {
    let user =
        get_current_user(&request).ok_or_else(|| anyhow::anyhow!("User not found in request"))?;

    let faces_path = db.get_user_faces_path(&user.user_id);
    let thumbnail_path = faces_path.join(format!("{}.jpg", person_id));

    if !thumbnail_path.exists() {
        return Err(anyhow::anyhow!("Face thumbnail not found").into());
    }

    let image_data = tokio::fs::read(&thumbnail_path)
        .await
        .map_err(|e| anyhow::anyhow!("Failed to read face thumbnail: {}", e))?;

    let headers = [(header::CONTENT_TYPE, "image/jpeg")];
    Ok((headers, image_data))
}

// Album handlers
#[instrument(skip(photo_service, request))]
pub async fn list_albums(
    State(photo_service): State<Arc<PhotoService>>,
    request: Request,
) -> Result<impl IntoResponse, AppError> {
    let user =
        get_current_user(&request).ok_or_else(|| anyhow::anyhow!("User not found in request"))?;

    let albums = photo_service.list_albums(&user.user_id).await?;

    Ok(Json(albums))
}

#[instrument(skip(photo_service, request))]
pub async fn create_album(
    State(photo_service): State<Arc<PhotoService>>,
    Json(album_request): Json<CreateAlbumRequest>,
    request: Request,
) -> Result<impl IntoResponse, AppError> {
    let user =
        get_current_user(&request).ok_or_else(|| anyhow::anyhow!("User not found in request"))?;

    let album = photo_service
        .create_album(&user.user_id, album_request)
        .await?;

    Ok((StatusCode::CREATED, Json(album)))
}

#[instrument(skip(photo_service, request))]
pub async fn update_album(
    State(photo_service): State<Arc<PhotoService>>,
    Path(album_id): Path<i32>,
    Json(album_request): Json<UpdateAlbumRequest>,
    request: Request,
) -> Result<impl IntoResponse, AppError> {
    let user =
        get_current_user(&request).ok_or_else(|| anyhow::anyhow!("User not found in request"))?;

    let album = photo_service
        .update_album(&user.user_id, album_id, album_request)
        .await?;

    Ok(Json(album))
}

#[instrument(skip(photo_service, request))]
pub async fn delete_album(
    State(photo_service): State<Arc<PhotoService>>,
    Path(album_id): Path<i32>,
    request: Request,
) -> Result<impl IntoResponse, AppError> {
    let user =
        get_current_user(&request).ok_or_else(|| anyhow::anyhow!("User not found in request"))?;

    photo_service.delete_album(&user.user_id, album_id).await?;

    Ok(Json(json!({"message": "Album deleted successfully"})))
}

#[instrument(skip(photo_service, request))]
pub async fn add_photos_to_album(
    State(photo_service): State<Arc<PhotoService>>,
    Path(album_id): Path<i32>,
    Json(photos_request): Json<AlbumPhotosRequest>,
    request: Request,
) -> Result<impl IntoResponse, AppError> {
    let user =
        get_current_user(&request).ok_or_else(|| anyhow::anyhow!("User not found in request"))?;

    photo_service
        .add_photos_to_album(&user.user_id, album_id, photos_request.photo_ids)
        .await?;

    Ok(Json(
        json!({"message": "Photos added to album successfully"}),
    ))
}

#[instrument(skip(photo_service, request))]
pub async fn remove_photos_from_album(
    State(photo_service): State<Arc<PhotoService>>,
    Path(album_id): Path<i32>,
    Json(photos_request): Json<AlbumPhotosRequest>,
    request: Request,
) -> Result<impl IntoResponse, AppError> {
    let user =
        get_current_user(&request).ok_or_else(|| anyhow::anyhow!("User not found in request"))?;

    photo_service
        .remove_photos_from_album(&user.user_id, album_id, photos_request.photo_ids)
        .await?;

    Ok(Json(
        json!({"message": "Photos removed from album successfully"}),
    ))
}

// Filter endpoints for client-side filtering data
#[instrument(skip(db, request))]
pub async fn get_filter_metadata(
    State(db): State<Arc<MultiTenantDatabase>>,
    request: Request,
) -> Result<impl IntoResponse, AppError> {
    let user =
        get_current_user(&request).ok_or_else(|| anyhow::anyhow!("User not found in request"))?;

    let user_db = db.get_user_database(&user.user_id)?;
    let conn = user_db.lock();

    // Get available cities
    let mut cities_stmt =
        conn.prepare("SELECT DISTINCT city FROM photos WHERE city IS NOT NULL ORDER BY city")?;
    let cities: Vec<String> = cities_stmt
        .query_map([], |row| row.get::<_, String>(0))?
        .collect::<Result<Vec<_>, _>>()?;

    // Get available countries
    let mut countries_stmt = conn.prepare(
        "SELECT DISTINCT country FROM photos WHERE country IS NOT NULL ORDER BY country",
    )?;
    let countries: Vec<String> = countries_stmt
        .query_map([], |row| row.get::<_, String>(0))?
        .collect::<Result<Vec<_>, _>>()?;

    // Get date range
    let date_range: Option<(i64, i64)> = conn
        .query_row(
            "SELECT MIN(created_at), MAX(created_at) FROM photos",
            [],
            |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?)),
        )
        .ok();

    // Get available faces
    let mut faces_stmt =
        conn.prepare("SELECT person_id, name, photo_count FROM faces ORDER BY photo_count DESC")?;
    let faces: Vec<serde_json::Value> = faces_stmt
        .query_map([], |row| {
            Ok(json!({
                "person_id": row.get::<_, String>(0)?,
                "name": row.get::<_, Option<String>>(1)?,
                "photo_count": row.get::<_, i32>(2)?
            }))
        })?
        .collect::<Result<Vec<_>, _>>()?;

    // Get camera models
    let mut cameras_stmt = conn.prepare("SELECT DISTINCT camera_model FROM photos WHERE camera_model IS NOT NULL ORDER BY camera_model")?;
    let cameras: Vec<String> = cameras_stmt
        .query_map([], |row| row.get::<_, String>(0))?
        .collect::<Result<Vec<_>, _>>()?;

    Ok(Json(json!({
        "cities": cities,
        "countries": countries,
        "date_range": date_range.map(|(min, max)| json!({"min": min, "max": max})),
        "faces": faces,
        "cameras": cameras
    })))
}
