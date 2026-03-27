pub mod asset_id;
pub mod backup_id;
pub mod exif_write;
pub mod geocode;
pub mod metadata;
pub mod phash;
pub mod service;
pub mod similar;

// Re-export commonly used types
pub use service::{
    AlbumPhotosRequest, CreateAlbumRequest, PhotoListQuery, PhotoService, UpdateAlbumRequest,
};

use anyhow::Result;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Photo {
    pub id: Option<i32>,
    pub asset_id: String,
    pub path: String,
    pub filename: String,
    pub mime_type: Option<String>,
    pub created_at: i64,
    pub modified_at: i64,
    pub size: i64,
    pub width: Option<i32>,
    pub height: Option<i32>,
    pub orientation: Option<i32>,
    pub favorites: i32,
    pub locked: bool,
    pub delete_time: i64,
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
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rating: Option<i16>,
}

pub fn mime_type_for_extension(ext: &str) -> Option<&'static str> {
    match ext {
        "jpg" | "jpeg" => Some("image/jpeg"),
        "png" => Some("image/png"),
        "gif" => Some("image/gif"),
        "webp" => Some("image/webp"),
        "bmp" => Some("image/bmp"),
        "tiff" | "tif" => Some("image/tiff"),
        "heic" | "heif" => Some("image/heic"),
        "avif" => Some("image/avif"),
        "dng" => Some("image/dng"),
        "mp4" | "m4v" => Some("video/mp4"),
        "mov" => Some("video/quicktime"),
        "avi" => Some("video/x-msvideo"),
        "mkv" => Some("video/x-matroska"),
        "webm" => Some("video/webm"),
        _ => None,
    }
}

pub fn is_raw_still_extension(ext: &str) -> bool {
    matches!(ext, "dng")
}

pub fn supports_metadata_only_still_ingest(ext: &str) -> bool {
    matches!(ext, "heic" | "heif" | "dng")
}

impl Photo {
    pub fn from_path(path: &Path, user_id: &str) -> Result<Self> {
        use crate::photos::asset_id;
        use std::fs;

        let metadata = fs::metadata(path)?;
        let filename = path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("unknown")
            .to_string();

        // Generate asset_id as Base58(first16(HMAC-SHA256(user_id, file_bytes)))
        let asset_id = asset_id::from_path(path, user_id)?;

        // Get timestamps
        let created_at = metadata
            .created()
            .map(|t| t.duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() as i64)
            .unwrap_or(0);

        let modified_at = metadata
            .modified()
            .map(|t| t.duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() as i64)
            .unwrap_or(0);

        // Determine if video
        let is_video = matches!(
            path.extension()
                .and_then(|e| e.to_str())
                .map(|e| e.to_lowercase())
                .as_deref(),
            Some("mp4") | Some("mov") | Some("avi") | Some("mkv") | Some("webm")
        );

        // Determine mime type
        let mime_type = path
            .extension()
            .and_then(|e| e.to_str())
            .map(|e| e.to_lowercase())
            .and_then(|e| mime_type_for_extension(e.as_str()).map(|m| m.to_string()));

        Ok(Photo {
            id: None,
            asset_id,
            path: path.to_string_lossy().to_string(),
            filename,
            mime_type,
            created_at,
            modified_at,
            size: metadata.len() as i64,
            width: None,
            height: None,
            orientation: None,
            favorites: 0,
            locked: false,
            delete_time: 0,
            is_video,
            is_live_photo: false,
            live_video_path: None,
            duration_ms: None,
            is_screenshot: 0,
            camera_make: None,
            camera_model: None,
            iso: None,
            aperture: None,
            shutter_speed: None,
            focal_length: None,
            latitude: None,
            longitude: None,
            altitude: None,
            location_name: None,
            city: None,
            province: None,
            country: None,
            caption: None,
            description: None,
            rating: None,
        })
    }

    pub fn detect_screenshot(&mut self) {
        // Heuristic, high-precision screenshot detection without ML
        // Never classify videos as screenshots
        if self.is_video {
            self.is_screenshot = 0;
            return;
        }
        // Combines filename keywords, PNG+no camera EXIF, and device resolution matches
        let filename_lc = self.filename.to_lowercase();
        let ext_lc = filename_lc
            .rsplit_once('.')
            .map(|(_, e)| e.to_string())
            .unwrap_or_default();
        let mime_lc = self.mime_type.clone().unwrap_or_default().to_lowercase();

        // 1) Filename keywords (localized)
        let keywords: &[&str] = &[
            "screenshot",
            "screen shot",
            "screen_shot",
            "screen-shot",
            // Localized/common variants
            "スクリーンショット", // Japanese
            "屏幕快照",
            "屏幕截图",
            "截屏",                // Chinese
            "캡처",                // Korean (capture)
            "снимок экрана",       // Russian
            "captura de pantalla", // Spanish
            "snímek obrazovky",    // Czech
            "schermata",           // Italian
            "ecran",               // French (part of phrase, lenient)
        ];
        let filename_hit = keywords.iter().any(|k| filename_lc.contains(k));

        // 2) Camera EXIF presence (if typical camera fields exist, very unlikely to be a screenshot)
        let camera_exif_present = self.camera_make.is_some()
            || self.camera_model.is_some()
            || self.iso.is_some()
            || self.aperture.is_some()
            || self.shutter_speed.is_some()
            || self.focal_length.is_some();

        // 3) PNG + no camera EXIF is a strong signal
        let is_png = ext_lc == "png" || mime_lc == "image/png";
        let is_jpeg = ext_lc == "jpg" || ext_lc == "jpeg" || mime_lc == "image/jpeg";
        let png_no_camera_exif = is_png && !camera_exif_present;

        // 4) Device resolution matcher (exact or within small tolerance)
        let mut device_match = false;
        if let (Some(w), Some(h)) = (self.width, self.height) {
            // Tolerance in pixels to account for minor crops/processing
            let tol: i32 = 3;
            // Common mobile and desktop screenshot sizes (portrait and landscape)
            let common_sizes: &[(i32, i32)] = &[
                // iPhone recent
                (1170, 2532),
                (1284, 2778),
                (1179, 2556),
                (1290, 2796),
                (1125, 2436),
                (1242, 2688),
                // Android common
                (1080, 1920),
                (1080, 2340),
                (1080, 2400),
                (1440, 2560),
                (1440, 3200),
                // iPad / tablets
                (2048, 2732),
                (1668, 2388),
                (1640, 2360),
                (1620, 2160),
                // Desktop/laptop
                (1920, 1080),
                (2560, 1440),
                (1366, 768),
                (2560, 1600),
                (2880, 1800),
                (3024, 1964),
                (3456, 2234),
                (3840, 2160),
            ];
            let (w, h) = (w, h);
            for &(sw, sh) in common_sizes {
                let match_portrait = (w - sw).abs() <= tol && (h - sh).abs() <= tol;
                let match_landscape = (w - sh).abs() <= tol && (h - sw).abs() <= tol;
                if match_portrait || match_landscape {
                    device_match = true;
                    break;
                }
            }
        }

        // 5) Aspect ratio hint (weak)
        let mut ar_hint = false;
        if let (Some(w), Some(h)) = (self.width, self.height) {
            let ar = w as f32 / h as f32;
            let ar16_9 = (1.0 - (ar / (16.0 / 9.0))).abs() <= 0.01; // ~1% tolerance
            let ar9_16 = (1.0 - (ar / (9.0 / 16.0))).abs() <= 0.01;
            ar_hint = ar16_9 || ar9_16;
        }

        // Decision logic — prefer precision
        let is_screenshot = if filename_hit {
            true
        } else if (!camera_exif_present) && device_match && (is_png || is_jpeg) {
            true
        } else if png_no_camera_exif && ar_hint {
            true
        } else {
            false
        };

        self.is_screenshot = if is_screenshot { 1 } else { 0 };
    }

    pub fn detect_live_photo(&mut self, photos_dir: &Path) {
        // Check if this is a HEIC file
        if self.filename.to_lowercase().ends_with(".heic")
            || self.filename.to_lowercase().ends_with(".heif")
        {
            // Look for corresponding MOV file
            let base_name = self
                .filename
                .rsplit_once('.')
                .map(|(base, _)| base)
                .unwrap_or(&self.filename);
            let mov_path = photos_dir.join(format!("{}.mov", base_name));
            let mov_path_upper = photos_dir.join(format!("{}.MOV", base_name));

            if mov_path.exists() {
                self.is_live_photo = true;
                self.live_video_path = Some(mov_path.to_string_lossy().to_string());
            } else if mov_path_upper.exists() {
                self.is_live_photo = true;
                self.live_video_path = Some(mov_path_upper.to_string_lossy().to_string());
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{
        is_raw_still_extension, mime_type_for_extension, supports_metadata_only_still_ingest, Photo,
    };
    use std::fs;
    use std::path::PathBuf;

    #[test]
    fn mime_type_for_extension_supports_dng() {
        assert_eq!(mime_type_for_extension("dng"), Some("image/dng"));
    }

    #[test]
    fn dng_is_treated_as_raw_and_metadata_only_capable() {
        assert!(is_raw_still_extension("dng"));
        assert!(supports_metadata_only_still_ingest("dng"));
    }

    fn make_temp_dir() -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "openphotos-photo-from-path-{}",
            uuid::Uuid::new_v4()
        ));
        fs::create_dir_all(&dir).expect("create temp dir");
        dir
    }

    #[test]
    fn from_path_maps_avif_mime_type() {
        let dir = make_temp_dir();
        let file = dir.join("sample.avif");
        fs::write(&file, b"test-avif-bytes").expect("write test file");

        let photo = Photo::from_path(&file, "test-user").expect("from_path should parse");
        assert_eq!(photo.mime_type.as_deref(), Some("image/avif"));

        let _ = fs::remove_dir_all(dir);
    }
}
