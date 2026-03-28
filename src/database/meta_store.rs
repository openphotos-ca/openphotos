use anyhow::Result;
use async_trait::async_trait;
use serde::{Deserialize, Serialize};

use crate::photos::service::PhotoListQuery;
use crate::photos::Photo as PhotoDTO;

#[async_trait]
pub trait MetaStore: Send + Sync {
    async fn resolve_org_id(&self, user_id: &str) -> Result<i32>;

    async fn upsert_photo(
        &self,
        organization_id: i32,
        user_id: &str,
        photo: &PhotoUpsert,
    ) -> Result<()>;

    async fn insert_or_update_phash(
        &self,
        organization_id: i32,
        asset_id: &str,
        phash_hex: &str,
    ) -> Result<()>;

    async fn list_photos(
        &self,
        organization_id: i32,
        user_id: &str,
        query: &PhotoListQuery,
    ) -> Result<(Vec<PhotoDTO>, i64)>;
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PhotoUpsert {
    pub asset_id: String,
    pub path: String,
    pub filename: String,
    pub mime_type: Option<String>,
    pub has_gain_map: bool,
    pub hdr_kind: Option<String>,
    pub backup_id: Option<String>,
    pub created_at: i64,
    pub modified_at: i64,
    pub size: i64,
    pub width: Option<i32>,
    pub height: Option<i32>,
    pub orientation: Option<i32>,
    pub is_video: bool,
    pub is_live_photo: bool,
    pub live_video_path: Option<String>,
    pub duration_ms: Option<i64>,
    pub is_screenshot: i32,
    pub camera_make: Option<String>,
    pub camera_model: Option<String>,
    pub iso: Option<i32>,
    pub aperture: Option<f32>,
    pub shutter_speed: Option<String>,
    pub focal_length: Option<f32>,
    pub latitude: Option<f64>,
    pub longitude: Option<f64>,
    pub altitude: Option<f64>,
    pub location_name: Option<String>,
    pub city: Option<String>,
    pub province: Option<String>,
    pub country: Option<String>,
    pub caption: Option<String>,
    pub description: Option<String>,
}
