use crate::server::deleted_upload_tombstones::{
    list_deleted_backup_ids_page, match_deleted_backup_ids, remove_deleted_tombstones_for_asset,
    spawn_legacy_deleted_backup_repair, upsert_deleted_tombstones_for_asset, KEY_KIND_ASSET_ID,
    KEY_KIND_BACKUP_ID,
};
use crate::server::logging;
use axum::extract::Request as AxumRequest;
use axum::{
    extract::{Path, Query, Request, State},
    http::{header, HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    Json,
};
use exif::{In, Tag};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::collections::HashSet;
use std::path::{Path as StdPath, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tracing::{debug, error, info, instrument};

use crate::auth::types::User;
use crate::database::embeddings; // for type visibility and search
use crate::database::embeddings::{PhotoData, PhotoRecord};
use crate::media_tools::ffmpeg_command;
use crate::photos::metadata::extract_metadata;
use crate::photos::metadata::open_image_any;
use crate::photos::metadata::open_image_upright;
use crate::photos::service::{
    AlbumPhotosRequest, CreateAlbumRequest, CreateLiveAlbumRequest, PhotoListQuery, PhotoService,
    UpdateAlbumRequest,
};
use crate::photos::Photo as PhotoDTO2;
use crate::photos::Photo as PhotoDTO;
// PIN endpoints removed; locked items are gated only by auth.
use crate::server::text_search::{delete_single_asset, reindex_single_asset};
use crate::server::{state::AppState, AppError};
use crate::video;
use anyhow::anyhow;
use duckdb::Connection;
use image::codecs::jpeg::JpegEncoder;
use image::imageops::FilterType;
use image::GenericImageView;
use tower::util::ServiceExt;
use tower_http::services::ServeFile; // for .oneshot()

// All pHash calculation and caching logic removed - now handled by database during indexing

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

fn weak_etag_from_metadata(meta: &std::fs::Metadata) -> Option<String> {
    let len = meta.len();
    let modified = meta.modified().ok()?;
    let dur = modified.duration_since(std::time::UNIX_EPOCH).ok()?;
    Some(format!("W/\"{}-{}\"", len, dur.as_nanos()))
}

fn add_private_cache_headers(headers: &mut HeaderMap, etag: Option<&str>) {
    // Authenticated media is user-specific. We still allow the browser's private cache,
    // but force revalidation so we don't serve stale cached content across logins.
    headers.insert(
        header::CACHE_CONTROL,
        axum::http::HeaderValue::from_static("private, max-age=0, must-revalidate"),
    );
    if let Some(etag) = etag {
        if let Ok(hv) = axum::http::HeaderValue::from_str(etag) {
            headers.insert(header::ETAG, hv);
        }
    }
}

fn is_raw_still_path(path: &str) -> bool {
    crate::photos::is_raw_still_extension(
        StdPath::new(path)
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("")
            .to_ascii_lowercase()
            .as_str(),
    )
}

fn raw_placeholder_webp_bytes(max_side: u32) -> Result<Vec<u8>, anyhow::Error> {
    let img = crate::photos::metadata::raw_placeholder_image(max_side).to_rgb8();
    let enc = webp::Encoder::from_rgb(img.as_raw(), img.width(), img.height());
    Ok(enc.encode(80.0).to_vec())
}

fn raw_placeholder_jpeg_bytes(max_side: u32) -> Result<Vec<u8>, anyhow::Error> {
    let img = crate::photos::metadata::raw_placeholder_image(max_side).to_rgb8();
    let mut bytes = Vec::new();
    let mut encoder = JpegEncoder::new_with_quality(&mut bytes, 88);
    encoder.encode(&img, img.width(), img.height(), image::ColorType::Rgb8)?;
    Ok(bytes)
}

fn cache_matches_raw_placeholder_webp(cache_path: &StdPath, max_side: u32) -> bool {
    std::fs::read(cache_path)
        .ok()
        .zip(raw_placeholder_webp_bytes(max_side).ok())
        .is_some_and(|(cached, expected)| cached == expected)
}

fn cache_matches_raw_placeholder_jpeg(cache_path: &StdPath, max_side: u32) -> bool {
    std::fs::read(cache_path)
        .ok()
        .zip(raw_placeholder_jpeg_bytes(max_side).ok())
        .is_some_and(|(cached, expected)| cached == expected)
}

fn album_ids_for_asset(conn: &Connection, org_id: i32, asset_id: &str) -> duckdb::Result<Vec<i32>> {
    let mut stmt = conn.prepare(
        "SELECT ap.album_id FROM album_photos ap
         JOIN photos p ON ap.photo_id = p.id AND ap.organization_id = p.organization_id
         WHERE p.organization_id = ? AND p.asset_id = ?",
    )?;
    let rows = stmt.query_map(duckdb::params![org_id, asset_id], |row| {
        row.get::<_, i32>(0)
    })?;
    let mut ids = Vec::new();
    for r in rows {
        if let Ok(id) = r {
            ids.push(id);
        };
    }
    Ok(ids)
}

fn update_album_count(conn: &Connection, org_id: i32, album_id: i32) -> duckdb::Result<()> {
    let count: i64 = conn.query_row(
        "SELECT COUNT(*) FROM album_photos ap JOIN photos p ON ap.photo_id = p.id WHERE ap.organization_id = ? AND ap.album_id = ? AND p.organization_id = ? AND COALESCE(p.delete_time,0) = 0",
        duckdb::params![org_id, album_id, org_id],
        |row| row.get(0),
    )?;
    conn.execute(
        "UPDATE albums SET photo_count = ?, updated_at = ? WHERE organization_id = ? AND id = ?",
        duckdb::params![count, chrono::Utc::now().timestamp(), org_id, album_id],
    )?;
    Ok(())
}

fn should_ignore_served_media_path(path: &StdPath) -> bool {
    if path.components().any(|c| {
        c.as_os_str()
            .to_string_lossy()
            .eq_ignore_ascii_case("__MACOSX")
    }) {
        return true;
    }
    let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
        return false;
    };
    if name.starts_with("._") {
        return true;
    }
    matches!(name, ".DS_Store" | "Thumbs.db")
}

fn sniff_image_content_type(bytes: &[u8]) -> Option<&'static str> {
    if bytes.len() >= 2 && bytes[0] == 0xFF && bytes[1] == 0xD8 {
        return Some("image/jpeg");
    }
    if bytes.len() >= 8
        && bytes[0] == 0x89
        && bytes[1] == 0x50
        && bytes[2] == 0x4E
        && bytes[3] == 0x47
        && bytes[4] == 0x0D
        && bytes[5] == 0x0A
        && bytes[6] == 0x1A
        && bytes[7] == 0x0A
    {
        return Some("image/png");
    }
    if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
        return Some("image/gif");
    }
    if bytes.len() >= 12 && &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        return Some("image/webp");
    }
    if bytes.len() >= 2 && bytes[0] == 0x42 && bytes[1] == 0x4D {
        return Some("image/bmp");
    }
    if bytes.starts_with(b"II*\0") || bytes.starts_with(b"MM\0*") {
        return Some("image/tiff");
    }
    // ISO BMFF family (HEIC/HEIF/AVIF).
    if bytes.len() >= 12 {
        let max_idx = bytes.len().saturating_sub(4).min(64);
        for idx in 0..=max_idx {
            if &bytes[idx..idx + 4] != b"ftyp" {
                continue;
            }
            let brand_end = (idx + 40).min(bytes.len());
            if idx + 4 >= brand_end {
                break;
            }
            let brands = &bytes[idx + 4..brand_end];
            if brands.windows(4).any(|w| w == b"avif" || w == b"avis") {
                return Some("image/avif");
            }
            if brands.windows(4).any(|w| {
                w == b"heic"
                    || w == b"heix"
                    || w == b"hevc"
                    || w == b"hevx"
                    || w == b"mif1"
                    || w == b"msf1"
            }) {
                return Some("image/heic");
            }
            break;
        }
    }
    None
}

fn looks_like_tiff_family(bytes: &[u8]) -> bool {
    bytes.starts_with(b"II*\0") || bytes.starts_with(b"MM\0*")
}

fn looks_like_declared_image(content_type: &str, bytes: &[u8]) -> bool {
    let ct = content_type.to_ascii_lowercase();
    if ct.starts_with("image/jpeg") {
        return bytes.len() >= 2 && bytes[0] == 0xFF && bytes[1] == 0xD8;
    }
    if ct.starts_with("image/png") {
        return bytes.len() >= 8
            && bytes[0] == 0x89
            && bytes[1] == 0x50
            && bytes[2] == 0x4E
            && bytes[3] == 0x47
            && bytes[4] == 0x0D
            && bytes[5] == 0x0A
            && bytes[6] == 0x1A
            && bytes[7] == 0x0A;
    }
    if ct.starts_with("image/gif") {
        return bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a");
    }
    if ct.starts_with("image/webp") {
        return bytes.len() >= 12 && &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WEBP";
    }
    if ct.starts_with("image/bmp") {
        return bytes.len() >= 2 && bytes[0] == 0x42 && bytes[1] == 0x4D;
    }
    if ct.starts_with("image/tiff") {
        return looks_like_tiff_family(bytes);
    }
    if ct.starts_with("image/dng") {
        return looks_like_tiff_family(bytes);
    }
    if ct.starts_with("image/heic") || ct.starts_with("image/heif") {
        return matches!(sniff_image_content_type(bytes), Some("image/heic"));
    }
    if ct.starts_with("image/avif") {
        return matches!(sniff_image_content_type(bytes), Some("image/avif"));
    }
    true
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RawImageServeMode {
    NotRaw,
    OriginalBytes,
    DerivedAvif,
    DerivedJpeg,
}

fn query_has_format_param(query: &str, format: &str) -> bool {
    query
        .split('&')
        .filter_map(|kv| kv.split_once('=').or(Some((kv, ""))))
        .any(|(key, value)| key == "format" && value.eq_ignore_ascii_case(format))
}

fn raw_image_serve_mode(
    orig_content_type: &str,
    query: &str,
    prefer_avif: bool,
) -> RawImageServeMode {
    if !orig_content_type.eq_ignore_ascii_case("image/dng") {
        return RawImageServeMode::NotRaw;
    }
    if query_has_format_param(query, "original") {
        return RawImageServeMode::OriginalBytes;
    }
    if prefer_avif {
        RawImageServeMode::DerivedAvif
    } else {
        RawImageServeMode::DerivedJpeg
    }
}

fn infer_live_video_content_type(path: &StdPath) -> &'static str {
    let ext_lc = path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase();

    // Try ISO BMFF brand sniff first so stale/misnamed caches still get the right MIME.
    if let Ok(bytes) = std::fs::read(path) {
        if bytes.len() >= 12 && &bytes[4..8] == b"ftyp" {
            let major_brand = &bytes[8..12];
            if major_brand == b"qt  " {
                return "video/quicktime";
            }
            if bytes.len() >= 64 {
                let end = bytes.len().min(64);
                if bytes[8..end].windows(4).any(|w| w == b"qt  ") {
                    return "video/quicktime";
                }
            }
            return "video/mp4";
        }
    }

    // Fallback by extension.
    match ext_lc.as_str() {
        "mov" | "qt" => "video/quicktime",
        _ => "video/mp4",
    }
}

fn is_apple_core_media_user_agent(ua: &str) -> bool {
    // AVPlayer / AVURLAsset requests originate from AppleCoreMedia and include Range headers.
    ua.contains("AppleCoreMedia")
}

fn is_chromium_user_agent(ua: &str) -> bool {
    let lc = ua.to_ascii_lowercase();
    // Chrome/Chromium/Edge (Chromium). Exclude Opera which may report Chrome too.
    (lc.contains("chrome/") || lc.contains("chromium") || lc.contains("edg/"))
        && !lc.contains("opr/")
}

fn is_firefox_user_agent(ua: &str) -> bool {
    ua.to_ascii_lowercase().contains("firefox/")
}

fn request_has_live_compat(query: Option<&str>) -> bool {
    let Some(query) = query else {
        return false;
    };
    query.split('&').any(|kv| {
        let mut parts = kv.splitn(2, '=');
        let key = parts.next().unwrap_or_default();
        if key != "compat" {
            return false;
        }
        let value = parts.next().unwrap_or_default().to_ascii_lowercase();
        value.is_empty() || value == "1" || value == "true" || value == "yes" || value == "on"
    })
}

fn add_live_response_headers<B>(
    resp: &mut axum::http::Response<B>,
    source: &'static str,
    compat: bool,
) {
    let hv = axum::http::HeaderValue::from_static(source);
    resp.headers_mut()
        .insert(axum::http::HeaderName::from_static("x-live-source"), hv);
    resp.headers_mut().insert(
        axum::http::HeaderName::from_static("x-live-compat"),
        if compat {
            axum::http::HeaderValue::from_static("1")
        } else {
            axum::http::HeaderValue::from_static("0")
        },
    );
}

fn is_ios_supported_container_ext(ext_lc: &str) -> bool {
    // iOS reliably supports MP4/MOV/M4V containers for AVPlayer.
    // Other containers (AVI/MKV/WebM/...) are commonly unsupported and can manifest as
    // "stuck on first frame" even when range requests succeed.
    matches!(ext_lc, "mp4" | "m4v" | "mov")
}

fn transcode_video_to_mp4(input_path: &StdPath, output_mp4: &StdPath) -> Result<(), anyhow::Error> {
    // Fast path: try a pure remux (no re-encode). Works when the codecs are already MP4-compatible.
    let out = ffmpeg_command()
        .args([
            "-hide_banner",
            "-loglevel",
            "error",
            "-nostdin",
            "-y",
            "-i",
            input_path.to_string_lossy().as_ref(),
            "-map",
            "0:v:0?",
            "-map",
            "0:a:0?",
            "-c",
            "copy",
            "-movflags",
            "+faststart",
            "-f",
            "mp4",
            output_mp4.to_string_lossy().as_ref(),
        ])
        .output()?;
    if out.status.success() {
        return Ok(());
    }

    // Fallback: re-encode to a widely supported iOS profile (H.264 + AAC).
    let out = ffmpeg_command()
        .args([
            "-hide_banner",
            "-loglevel",
            "error",
            "-nostdin",
            "-y",
            "-i",
            input_path.to_string_lossy().as_ref(),
            "-map",
            "0:v:0?",
            "-map",
            "0:a:0?",
            "-c:v",
            "libx264",
            "-preset",
            "veryfast",
            "-crf",
            "23",
            "-pix_fmt",
            "yuv420p",
            "-c:a",
            "aac",
            "-b:a",
            "160k",
            "-movflags",
            "+faststart",
            "-f",
            "mp4",
            output_mp4.to_string_lossy().as_ref(),
        ])
        .output()?;
    if !out.status.success() {
        let stderr = String::from_utf8_lossy(&out.stderr);
        return Err(anyhow!(
            "ffmpeg failed (status {:?}): {}",
            out.status,
            stderr.trim()
        ));
    }
    Ok(())
}

fn transcode_video_to_stream_mp4(
    input_path: &StdPath,
    output_mp4: &StdPath,
) -> Result<(), anyhow::Error> {
    // Purpose: generate an iOS-friendly MP4 that is smoother to stream over real networks.
    //
    // Strategy:
    // - Re-encode to H.264 + AAC (widely supported by iOS AVPlayer).
    // - Downscale to <= 720p to reduce required throughput.
    // - Cap peak bitrate to avoid rebuffering on mobile/Wi‑Fi fluctuations.
    let out = ffmpeg_command()
        .args([
            "-hide_banner",
            "-loglevel",
            "error",
            "-nostdin",
            "-y",
            "-i",
            input_path.to_string_lossy().as_ref(),
            "-vf",
            "scale='min(1280,iw)':-2",
            "-c:v",
            "libx264",
            "-preset",
            "veryfast",
            "-crf",
            "26",
            "-maxrate",
            "6000k",
            "-bufsize",
            "12000k",
            "-pix_fmt",
            "yuv420p",
            "-c:a",
            "aac",
            "-b:a",
            "160k",
            "-movflags",
            "+faststart",
            "-f",
            "mp4",
            output_mp4.to_string_lossy().as_ref(),
        ])
        .output()?;
    if !out.status.success() {
        let stderr = String::from_utf8_lossy(&out.stderr);
        return Err(anyhow!(
            "ffmpeg failed (status {:?}): {}",
            out.status,
            stderr.trim()
        ));
    }
    Ok(())
}

async fn ensure_ios_mp4_proxy(
    state: &AppState,
    user_id: &str,
    asset_id: &str,
    source_path: &StdPath,
) -> Result<PathBuf, anyhow::Error> {
    let out_path = state.video_mp4_proxy_path_for(user_id, asset_id);
    if out_path.exists() {
        return Ok(out_path);
    }
    let parent = out_path
        .parent()
        .ok_or_else(|| anyhow!("Invalid proxy output path"))?;
    tokio::fs::create_dir_all(parent).await?;

    // Cross-process lock file to avoid duplicating heavy transcodes when multiple requests arrive.
    // If we lose the race, we wait for the proxy file to appear.
    let lock_path = out_path.with_extension("lock");
    match std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&lock_path)
    {
        Ok(mut f) => {
            use std::io::Write;
            let _ = writeln!(f, "pid={}", std::process::id());

            // Keep a `.mp4` suffix so ffmpeg can infer the container reliably.
            let tmp_path = out_path.with_extension("tmp.mp4");
            let source_path = source_path.to_path_buf();
            let out_path_clone = out_path.clone();
            let tmp_path_clone = tmp_path.clone();
            let lock_path_clone = lock_path.clone();
            let result = tokio::task::spawn_blocking(move || -> Result<(), anyhow::Error> {
                // Ensure we don't serve a partially written file.
                let _ = std::fs::remove_file(&tmp_path_clone);
                transcode_video_to_mp4(&source_path, &tmp_path_clone)?;
                std::fs::rename(&tmp_path_clone, &out_path_clone)?;
                Ok(())
            })
            .await;

            // Best-effort cleanup: lock + temp.
            let _ = std::fs::remove_file(&lock_path_clone);
            let _ = std::fs::remove_file(&tmp_path);

            match result {
                Ok(Ok(())) => Ok(out_path),
                Ok(Err(e)) => Err(e),
                Err(e) => Err(anyhow!("MP4 proxy task join error: {}", e)),
            }
        }
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
            let start = Instant::now();
            while start.elapsed() < Duration::from_secs(180) {
                if out_path.exists() {
                    return Ok(out_path);
                }
                tokio::time::sleep(Duration::from_millis(200)).await;
            }
            Err(anyhow!("Timed out waiting for MP4 proxy to be generated"))
        }
        Err(e) => Err(anyhow!("Failed to acquire MP4 proxy lock: {}", e)),
    }
}

async fn ensure_ios_stream_mp4_proxy(
    state: &AppState,
    user_id: &str,
    asset_id: &str,
    source_path: &StdPath,
) -> Result<PathBuf, anyhow::Error> {
    let out_path = state.video_stream_mp4_proxy_path_for(user_id, asset_id);
    if out_path.exists() {
        return Ok(out_path);
    }
    let parent = out_path
        .parent()
        .ok_or_else(|| anyhow!("Invalid proxy output path"))?;
    tokio::fs::create_dir_all(parent).await?;

    let lock_path = out_path.with_extension("lock");
    match std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&lock_path)
    {
        Ok(mut f) => {
            use std::io::Write;
            let _ = writeln!(f, "pid={}", std::process::id());

            // Keep a `.mp4` suffix so ffmpeg can infer the container reliably.
            let tmp_path = out_path.with_extension("tmp.mp4");
            let source_path = source_path.to_path_buf();
            let out_path_clone = out_path.clone();
            let tmp_path_clone = tmp_path.clone();
            let lock_path_clone = lock_path.clone();
            let result = tokio::task::spawn_blocking(move || -> Result<(), anyhow::Error> {
                let _ = std::fs::remove_file(&tmp_path_clone);
                transcode_video_to_stream_mp4(&source_path, &tmp_path_clone)?;
                std::fs::rename(&tmp_path_clone, &out_path_clone)?;
                Ok(())
            })
            .await;

            let _ = std::fs::remove_file(&lock_path_clone);
            let _ = std::fs::remove_file(&tmp_path);

            match result {
                Ok(Ok(())) => Ok(out_path),
                Ok(Err(e)) => Err(e),
                Err(e) => Err(anyhow!("stream MP4 proxy task join error: {}", e)),
            }
        }
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
            let start = Instant::now();
            while start.elapsed() < Duration::from_secs(300) {
                if out_path.exists() {
                    return Ok(out_path);
                }
                tokio::time::sleep(Duration::from_millis(200)).await;
            }
            Err(anyhow!(
                "Timed out waiting for streaming MP4 proxy to be generated"
            ))
        }
        Err(e) => Err(anyhow!("Failed to acquire stream MP4 proxy lock: {}", e)),
    }
}

pub(crate) fn hard_delete_assets(
    state: &AppState,
    user_id: &str,
    asset_ids: &[String],
) -> anyhow::Result<usize> {
    use std::fs;
    let mut purged = 0usize;
    let mut touched_albums: HashSet<i32> = HashSet::new();
    // PG mode
    if let Some(pg) = &state.pg_client {
        // Resolve org id via helper (handles PG/DuckDB)
        let org_id: i32 = state.org_id_for_user(user_id);
        for aid in asset_ids {
            let row_opt = futures::executor::block_on(pg.query_opt(
                "SELECT id, path
                 FROM photos
                 WHERE organization_id=$1 AND user_id=$2 AND asset_id=$3 AND COALESCE(delete_time,0)>0
                 LIMIT 1",
                &[&org_id, &user_id, aid],
            ))
            .ok()
            .flatten();
            if row_opt.is_none() {
                continue;
            }
            let (photo_id, path_opt): (i32, Option<String>) = {
                let r = row_opt.unwrap();
                (r.get(0), Some(r.get(1)))
            };
            // collect album ids
            if let Ok(rows) = futures::executor::block_on(pg.query(
                "SELECT ap.album_id FROM album_photos ap WHERE ap.organization_id=$1 AND ap.photo_id=$2",
                &[&org_id, &photo_id],
            )) { for r in rows { touched_albums.insert(r.get::<_, i32>(0)); } }
            let _ = futures::executor::block_on(pg.execute(
                "DELETE FROM album_photos WHERE organization_id=$1 AND photo_id=$2",
                &[&org_id, &photo_id],
            ));
            let _ = futures::executor::block_on(pg.execute(
                "DELETE FROM faces WHERE organization_id=$1 AND asset_id=$2",
                &[&org_id, aid],
            ));
            let _ = futures::executor::block_on(pg.execute(
                "DELETE FROM photo_hashes WHERE organization_id=$1 AND asset_id=$2",
                &[&org_id, aid],
            ));
            let _ = futures::executor::block_on(pg.execute(
                "DELETE FROM video_phash_samples WHERE organization_id=$1 AND asset_id=$2",
                &[&org_id, aid],
            ));
            let rows = futures::executor::block_on(pg.execute(
                "DELETE FROM photos WHERE organization_id=$1 AND user_id=$2 AND id=$3",
                &[&org_id, &user_id, &photo_id],
            ))
            .unwrap_or(0);
            if rows > 0 {
                purged += 1;
            }
            // files
            let thumb = state.thumbnail_path_for(user_id, aid);
            let locked_thumb = state.locked_thumb_path_for(user_id, aid);
            let poster = state.poster_path_for(user_id, aid);
            let live_mp4 = state.live_video_path_for(user_id, aid);
            let live_mov = state.live_video_mov_path_for(user_id, aid);
            let _ = fs::remove_file(&thumb);
            let _ = fs::remove_file(&locked_thumb);
            let _ = fs::remove_file(&poster);
            let _ = fs::remove_file(&live_mp4);
            let _ = fs::remove_file(&live_mov);
            if let Some(path) = path_opt {
                let _ = fs::remove_file(path);
            }
            if let Err(e) = delete_single_asset(state, user_id, aid) {
                tracing::warn!("[SEARCH] delete from index failed during purge: {}", e);
            }
        }
        if !touched_albums.is_empty() {
            for album_id in touched_albums.clone() {
                let row = futures::executor::block_on(pg.query_one(
                    "SELECT COUNT(*) FROM album_photos ap JOIN photos p ON ap.photo_id=p.id WHERE ap.organization_id=$1 AND ap.album_id=$2 AND COALESCE(p.delete_time,0)=0",
                    &[&org_id, &album_id],
                ));
                let cnt: i64 = row.ok().map(|r| r.get(0)).unwrap_or(0);
                let _ = futures::executor::block_on(pg.execute(
                    "UPDATE albums SET photo_count=$1, updated_at=$2 WHERE organization_id=$3 AND id=$4",
                    &[&cnt, &chrono::Utc::now().timestamp(), &org_id, &album_id],
                ));
            }
        }
        return Ok(purged);
    }

    // DuckDB mode (original)
    let data_db = state.get_user_data_database(user_id)?;
    let embed_db = state.get_user_embedding_database(user_id)?;
    let mut purged = 0usize;
    let mut touched_albums: HashSet<i32> = HashSet::new();
    let org_id: i32 = state.org_id_for_user(user_id);
    for aid in asset_ids {
        let (photo_id_opt, path_opt): (Option<i32>, Option<String>) = {
            let conn = data_db.lock();
            let mut pid: Option<i32> = None;
            let mut pth: Option<String> = None;
            if let Ok(mut stmt) = conn.prepare("SELECT id, path FROM photos WHERE organization_id = ? AND user_id = ? AND asset_id = ? AND COALESCE(delete_time,0) > 0 LIMIT 1") {
                if let Ok((pid_v, path_v)) = stmt.query_row(duckdb::params![org_id, user_id, aid], |row| Ok((row.get::<_, i32>(0)?, row.get::<_, String>(1)?))) {
                    pid = Some(pid_v);
                    pth = Some(path_v);
                }
            }
            (pid, pth)
        };
        let Some(photo_id) = photo_id_opt else {
            continue;
        };
        {
            let conn = data_db.lock();
            let ids = album_ids_for_asset(&conn, org_id, aid).unwrap_or_default();
            for aid_num in &ids {
                touched_albums.insert(*aid_num);
            }
            let _ = conn.execute(
                "DELETE FROM album_photos WHERE organization_id = ? AND photo_id = ?",
                duckdb::params![org_id, photo_id],
            );
            let _ = conn.execute(
                "DELETE FROM face_photos WHERE photo_id = ?",
                duckdb::params![photo_id],
            );
            let _ = conn.execute(
                "DELETE FROM photo_hashes WHERE organization_id = ? AND asset_id = ?",
                duckdb::params![org_id, aid],
            );
            let _ = conn.execute(
                "DELETE FROM video_phash_samples WHERE organization_id = ? AND asset_id = ?",
                duckdb::params![org_id, aid],
            );
            let rows = conn
                .execute(
                    "DELETE FROM photos WHERE organization_id = ? AND user_id = ? AND id = ?",
                    duckdb::params![org_id, user_id, photo_id],
                )
                .unwrap_or(0);
            if rows > 0 {
                purged += 1;
            }
        }
        {
            let conn_e = embed_db.lock();
            let _ = conn_e.execute(
                "DELETE FROM smart_search WHERE asset_id = ?",
                duckdb::params![aid],
            );
            let _ = conn_e.execute(
                "DELETE FROM faces_embed WHERE asset_id = ?",
                duckdb::params![aid],
            );
        }
        let thumb = state.thumbnail_path_for(user_id, aid);
        let locked_thumb = state.locked_thumb_path_for(user_id, aid);
        let poster = state.poster_path_for(user_id, aid);
        let live_mp4 = state.live_video_path_for(user_id, aid);
        let live_mov = state.live_video_mov_path_for(user_id, aid);
        let _ = fs::remove_file(&thumb);
        let _ = fs::remove_file(&locked_thumb);
        let _ = fs::remove_file(&poster);
        let _ = fs::remove_file(&live_mp4);
        let _ = fs::remove_file(&live_mov);
        if let Some(path) = path_opt.clone() {
            let _ = fs::remove_file(path);
        }
        if let Err(e) = delete_single_asset(state, user_id, aid) {
            tracing::warn!("[SEARCH] delete from index failed during purge: {}", e);
        }
    }
    if !touched_albums.is_empty() {
        let conn = data_db.lock();
        for album_id in touched_albums {
            if let Err(e) = update_album_count(&conn, org_id, album_id) {
                tracing::warn!(
                    "[TRASH] failed to refresh album {} after purge: {}",
                    album_id,
                    e
                );
            }
        }
    }
    Ok(purged)
}

// Helper function to get user from headers
async fn get_user_from_headers(
    headers: &HeaderMap,
    auth_service: &crate::auth::AuthService,
) -> Result<User, AppError> {
    // Try Authorization header first
    if let Some(token) = headers
        .get(header::AUTHORIZATION)
        .and_then(|h| h.to_str().ok())
        .and_then(|h| h.strip_prefix("Bearer "))
    {
        match auth_service.verify_token(token).await {
            Ok(user) => return Ok(user),
            Err(e_auth) => {
                // Fallback to cookie when Authorization token is present but invalid/expired.
                // This helps when the client rotated the access token via cookie but a stale
                // Authorization header is still being sent by some callers.
                if let Some(cookie_hdr) = headers.get(header::COOKIE).and_then(|v| v.to_str().ok())
                {
                    for part in cookie_hdr.split(';') {
                        let trimmed = part.trim();
                        if let Some(val) = trimmed.strip_prefix("auth-token=") {
                            if let Ok(user) = auth_service.verify_token(val).await {
                                return Ok(user);
                            }
                        }
                    }
                }
                return Err(AppError(anyhow::anyhow!("Unauthorized: {}", e_auth)));
            }
        }
    }
    // Fallback: try Cookie header for 'auth-token'
    if let Some(cookie_hdr) = headers.get(header::COOKIE).and_then(|v| v.to_str().ok()) {
        for part in cookie_hdr.split(';') {
            let trimmed = part.trim();
            if let Some(val) = trimmed.strip_prefix("auth-token=") {
                let user = auth_service
                    .verify_token(val)
                    .await
                    .map_err(|e| AppError(anyhow::anyhow!("Unauthorized: {}", e)))?;
                return Ok(user);
            }
        }
    }
    Err(AppError(anyhow::anyhow!("Missing authorization token")))
}

#[derive(Debug, Deserialize)]
pub struct FavoritePayload {
    pub favorite: bool,
}

#[instrument(skip(state, headers))]
pub async fn set_favorite(
    State(state): State<Arc<AppState>>,
    Path(asset_id): Path<String>,
    headers: HeaderMap,
    Json(payload): Json<FavoritePayload>,
) -> Result<impl IntoResponse, AppError> {
    let user = get_user_from_headers(&headers, &state.auth_service).await?;
    let val = if payload.favorite { 1 } else { 0 };

    // Try to update row scoped by org+user+asset first; fall back to org+asset for legacy rows
    if let Some(pg) = &state.pg_client {
        // Primary: org + user + asset
        let mut affected_exact: u64 = pg
            .execute(
                "UPDATE photos SET favorites=$1 WHERE organization_id=$2 AND user_id=$3 AND asset_id=$4",
                &[&val, &user.organization_id, &user.user_id, &asset_id],
            )
            .await
            .unwrap_or(0);
        // Fallback: rows with missing/blank user_id within same org
        let mut affected_blank: u64 = 0;
        if affected_exact == 0 {
            affected_blank = pg
                .execute(
                    "UPDATE photos SET favorites=$1 WHERE organization_id=$2 AND (user_id='' OR user_id IS NULL) AND asset_id=$3",
                    &[&val, &user.organization_id, &asset_id],
                )
                .await
                .unwrap_or(0);
        }
        // Last resort (org+asset)
        let mut affected_org_asset: u64 = 0;
        if affected_exact == 0 && affected_blank == 0 {
            affected_org_asset = pg
                .execute(
                    "UPDATE photos SET favorites=$1 WHERE organization_id=$2 AND asset_id=$3",
                    &[&val, &user.organization_id, &asset_id],
                )
                .await
                .unwrap_or(0);
        }
        let affected_total: u64 = affected_exact + affected_blank + affected_org_asset;
        tracing::info!(target="favorite", "[FAVORITE] org={} user={} asset={} set={} affected_exact={} affected_blank={} affected_org_asset={} total={}", user.organization_id, user.user_id, asset_id, val, affected_exact, affected_blank, affected_org_asset, affected_total);
        if affected_total == 0 {
            return Err(AppError(anyhow::anyhow!("Asset not found")));
        }
        // Read back for the current user's row first
        let read_exact = pg
            .query_opt(
                "SELECT COALESCE(favorites,0) FROM photos WHERE organization_id=$1 AND user_id=$2 AND asset_id=$3",
                &[&user.organization_id, &user.user_id, &asset_id],
            )
            .await
            .ok()
            .and_then(|row| row.map(|r| r.get::<_, i32>(0)));
        if let Some(v) = read_exact {
            return Ok(Json(json!({ "asset_id": asset_id, "favorites": v })));
        }
        // Fallback read (org+asset)
        let read_any = pg
            .query_opt(
                "SELECT COALESCE(favorites,0) FROM photos WHERE organization_id=$1 AND asset_id=$2",
                &[&user.organization_id, &asset_id],
            )
            .await
            .ok()
            .and_then(|row| row.map(|r| r.get::<_, i32>(0)));
        let persisted = read_any.unwrap_or(val);
        return Ok(Json(
            json!({ "asset_id": asset_id, "favorites": persisted }),
        ));
    } else {
        let data_db = state.get_user_data_database(&user.user_id)?;
        let conn = data_db.lock();
        // Primary: org + user + asset
        let updated_exact = conn.execute(
            "UPDATE photos SET favorites = ? WHERE organization_id = ? AND user_id = ? AND asset_id = ?",
            duckdb::params![val, user.organization_id, &user.user_id, &asset_id],
        )? as i64;
        // Fallback: blank user rows
        let updated_blank = if updated_exact == 0 {
            conn.execute(
                "UPDATE photos SET favorites = ? WHERE organization_id = ? AND (user_id='' OR user_id IS NULL) AND asset_id = ?",
                duckdb::params![val, user.organization_id, &asset_id],
            )? as i64
        } else {
            0
        };
        // Last resort: org+asset
        let updated_org_asset = if updated_exact == 0 && updated_blank == 0 {
            conn.execute(
                "UPDATE photos SET favorites = ? WHERE organization_id = ? AND asset_id = ?",
                duckdb::params![val, user.organization_id, &asset_id],
            )? as i64
        } else {
            0
        };
        let updated_total = updated_exact + updated_blank + updated_org_asset;
        tracing::info!(target="favorite", "[FAVORITE] org={} user={} asset={} set={} affected_exact={} affected_blank={} affected_org_asset={} total={}", user.organization_id, user.user_id, asset_id, val, updated_exact, updated_blank, updated_org_asset, updated_total);
        if updated_total == 0 {
            return Err(AppError(anyhow::anyhow!("Asset not found")));
        }
        // Read back the persisted value for current user's row first
        let persisted: i32 = conn
            .query_row(
                "SELECT COALESCE(favorites,0) FROM photos WHERE organization_id = ? AND user_id = ? AND asset_id = ? LIMIT 1",
                duckdb::params![user.organization_id, &user.user_id, &asset_id],
                |r| r.get::<_, i32>(0),
            )
            .unwrap_or_else(|_| {
                conn
                    .query_row(
                        "SELECT COALESCE(favorites,0) FROM photos WHERE organization_id = ? AND asset_id = ? LIMIT 1",
                        duckdb::params![user.organization_id, &asset_id],
                        |r| r.get::<_, i32>(0),
                    )
                    .unwrap_or(val)
            });
        return Ok(Json(
            json!({ "asset_id": asset_id, "favorites": persisted }),
        ));
    }
    // Unreachable
}

#[derive(Debug, Deserialize)]
pub struct ReindexRequest {
    pub directory: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct ReindexResponse {
    pub total_files: usize,
    pub photos_indexed: usize,
    pub faces_detected: usize,
    pub errors: Vec<String>,
    pub message: String,
}

#[derive(Debug, Serialize)]
pub struct DebugPhotosCountResponse {
    pub user_id: String,
    pub db_path: String,
    pub db_file: Option<String>,
    pub count: i64,
    pub sample_asset_ids: Vec<String>,
}

#[derive(Debug, Deserialize)]
pub struct DeletePhotosRequest {
    pub asset_ids: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct DeletePhotosResponse {
    pub requested: usize,
    pub deleted: usize,
}

#[derive(Debug, Deserialize)]
pub struct AssetIdsRequest {
    pub asset_ids: Vec<String>,
    #[serde(default)]
    pub include_locked: Option<bool>,
}

#[derive(Debug, Deserialize)]
pub struct ExistsRequest {
    #[serde(default)]
    pub asset_ids: Vec<String>,
    #[serde(default)]
    pub backup_ids: Vec<String>,
    #[serde(default)]
    pub include_deleted_matches: bool,
}

#[derive(Debug, Serialize)]
pub struct ExistsResponse {
    pub present_asset_ids: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub present_backup_ids: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub deleted_asset_ids: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub deleted_backup_ids: Option<Vec<String>>,
}

#[derive(Debug, Deserialize)]
pub struct DeletedBackupsQuery {
    #[serde(default = "default_deleted_backups_limit")]
    pub limit: usize,
    #[serde(default)]
    pub after: Option<String>,
}

fn default_deleted_backups_limit() -> usize {
    500
}

#[derive(Debug, Serialize)]
pub struct DeletedBackupsPageResponse {
    pub total: usize,
    pub backup_ids: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub next_after: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct DeletedBackupsMatchRequest {
    #[serde(default)]
    pub backup_ids: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct DeletedBackupsMatchResponse {
    pub deleted_backup_ids: Vec<String>,
}

#[derive(Debug, Deserialize)]
pub struct TrashActionRequest {
    pub asset_ids: Vec<String>,
}

async fn locked_components_exist_on_disk(
    state: &Arc<AppState>,
    user_id: &str,
    asset_id: &str,
) -> (bool, bool) {
    let orig_path = state.locked_original_path_for(user_id, asset_id);
    let thumb_path = state.locked_thumb_path_for(user_id, asset_id);
    let orig_exists = tokio::fs::metadata(orig_path).await.is_ok();
    let thumb_exists = tokio::fs::metadata(thumb_path).await.is_ok();
    (orig_exists, thumb_exists)
}

async fn unlocked_live_video_exists_on_disk(
    state: &Arc<AppState>,
    user_id: &str,
    asset_id: &str,
    photo_path: &str,
    live_video_path: &Option<String>,
) -> bool {
    // Prefer any existing cached render
    let live_mov_cache = state.live_video_mov_path_for(user_id, asset_id);
    if tokio::fs::metadata(&live_mov_cache).await.is_ok() {
        return true;
    }
    let live_mp4_cache = state.live_video_path_for(user_id, asset_id);
    if tokio::fs::metadata(&live_mp4_cache).await.is_ok() {
        return true;
    }

    // Prefer DB live_video_path; else infer .mov beside original
    let mov_candidate = if let Some(p) = live_video_path.clone().filter(|s| !s.is_empty()) {
        std::path::PathBuf::from(p)
    } else {
        let p = std::path::Path::new(photo_path);
        let base = p.with_extension("");
        let mov = base.with_extension("mov");
        if mov.exists() {
            mov
        } else {
            base.with_extension("MOV")
        }
    };
    tokio::fs::metadata(mov_candidate).await.is_ok()
}

async fn locked_live_video_fully_backed_up_on_disk(
    state: &Arc<AppState>,
    user_id: &str,
    live_video_path: &Option<String>,
) -> bool {
    let live_path = match live_video_path.clone().filter(|s| !s.is_empty()) {
        Some(p) => p,
        None => return false,
    };
    if tokio::fs::metadata(&live_path).await.is_err() {
        return false;
    }
    let stem = std::path::Path::new(&live_path)
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("");
    if stem.is_empty() {
        return false;
    }
    let stem = stem.strip_suffix("_t").unwrap_or(stem);
    let thumb_path = state.locked_thumb_path_for(user_id, stem);
    tokio::fs::metadata(thumb_path).await.is_ok()
}

#[instrument(skip(state, headers))]
pub async fn photos_exist(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(payload): Json<ExistsRequest>,
) -> Result<impl IntoResponse, AppError> {
    let user = get_user_from_headers(&headers, &state.auth_service).await?;
    if payload.asset_ids.is_empty() && payload.backup_ids.is_empty() {
        return Ok(Json(ExistsResponse {
            present_asset_ids: Vec::new(),
            present_backup_ids: None,
            deleted_asset_ids: None,
            deleted_backup_ids: None,
        }));
    }

    let use_backup_ids = !payload.backup_ids.is_empty();
    let requested_ids: &Vec<String> = if use_backup_ids {
        &payload.backup_ids
    } else {
        &payload.asset_ids
    };
    let requested_set: HashSet<String> = requested_ids.iter().cloned().collect();

    if let Some(pg) = &state.pg_client {
        // On-demand backfill so `backup_id` queries work without a full reindex.
        if use_backup_ids {
            let rows = pg
                .query(
                    "SELECT asset_id, path
                     FROM photos
                     WHERE organization_id=$1 AND user_id=$2
                       AND COALESCE(delete_time,0)=0
                       AND COALESCE(locked,FALSE)=FALSE
                       AND (
                            COALESCE(mime_type,'') = 'image/jpeg'
                            OR LOWER(path) LIKE '%.jpg'
                            OR LOWER(path) LIKE '%.jpeg'
                            OR LOWER(filename) LIKE '%.jpg'
                            OR LOWER(filename) LIKE '%.jpeg'
                       )
                       AND (backup_id IS NULL OR backup_id = '')
                     LIMIT 10000",
                    &[&user.organization_id, &user.user_id],
                )
                .await
                .unwrap_or_default();
            let mut filled: usize = 0;
            for r in rows {
                let asset_id: String = r.get(0);
                let path: String = r.get(1);
                let bid = tokio::task::spawn_blocking({
                    let p = std::path::PathBuf::from(path);
                    let uid = user.user_id.clone();
                    move || -> Option<String> {
                        let bytes = std::fs::read(p).ok()?;
                        crate::photos::backup_id::from_bytes(&bytes, &uid).ok()
                    }
                })
                .await
                .ok()
                .flatten();
                if let Some(bid) = bid {
                    let _ = pg
                        .execute(
                            "UPDATE photos SET backup_id=$1 WHERE organization_id=$2 AND user_id=$3 AND asset_id=$4",
                            &[&bid, &user.organization_id, &user.user_id, &asset_id],
                        )
                        .await;
                    filled += 1;
                }
            }
            if filled > 0 {
                tracing::info!(
                    target: "cloudcheck",
                    "[CLOUDCHECK] backup_id backfill (pg) filled={}",
                    filled
                );
            }
        }

        let mut present: Vec<String> = Vec::new();
        let mut active_request_matches: HashSet<String> = HashSet::new();
        let mut deleted_requested: HashSet<String> = HashSet::new();
        if !requested_ids.is_empty() {
            let mut params: Vec<&(dyn tokio_postgres::types::ToSql + Sync)> = Vec::new();
            params.push(&user.organization_id);
            params.push(&user.user_id);
            let mut placeholders: Vec<String> = Vec::new();
            for (i, id) in requested_ids.iter().enumerate() {
                placeholders.push(format!("${}", i + 3));
                params.push(id);
            }
            let where_clause = if use_backup_ids {
                format!(
                    "(backup_id IN ({}) OR asset_id IN ({}))",
                    placeholders.join(","),
                    placeholders.join(",")
                )
            } else {
                format!("asset_id IN ({})", placeholders.join(","))
            };
            let sql = format!(
                "SELECT asset_id,
                        backup_id,
                        COALESCE(locked, FALSE) AS locked,
                        COALESCE(locked_orig_uploaded, FALSE) AS locked_orig_uploaded,
                        COALESCE(locked_thumb_uploaded, FALSE) AS locked_thumb_uploaded,
                        COALESCE(is_live_photo, FALSE) AS is_live_photo,
                        live_video_path,
                        path
                 FROM photos
                 WHERE organization_id = $1 AND user_id = $2
                   AND COALESCE(delete_time, 0) = 0
                   AND {}",
                where_clause
            );
            let rows = pg
                .query(&sql, &params)
                .await
                .map_err(|e| AppError(anyhow::anyhow!(e.to_string())))?;

            let matched_rows = rows.len();
            let mut live_total: usize = 0;
            let mut live_missing: usize = 0;
            let mut locked_total: usize = 0;
            let mut locked_incomplete: usize = 0;
            for r in rows {
                let asset_id: String = r.get(0);
                let backup_id: Option<String> = r.get(1);
                let locked: bool = r.get(2);
                let mut orig_ok: bool = r.get(3);
                let mut thumb_ok: bool = r.get(4);
                let is_live: bool = r.get(5);
                let live_video_path: Option<String> = r.get(6);
                let photo_path: String = r.get(7);

                if locked {
                    locked_total += 1;
                }
                if is_live {
                    live_total += 1;
                }

                if locked && (!orig_ok || !thumb_ok) {
                    let (orig_exists, thumb_exists) =
                        locked_components_exist_on_disk(&state, &user.user_id, &asset_id).await;
                    if orig_exists {
                        orig_ok = true;
                    }
                    if thumb_exists {
                        thumb_ok = true;
                    }
                    if orig_exists || thumb_exists {
                        let _ = pg
                            .execute(
                                "UPDATE photos
                                 SET locked_orig_uploaded = CASE WHEN $1 THEN TRUE ELSE locked_orig_uploaded END,
                                     locked_thumb_uploaded = CASE WHEN $2 THEN TRUE ELSE locked_thumb_uploaded END
                                 WHERE organization_id = $3 AND user_id = $4 AND asset_id = $5",
                                &[
                                    &orig_exists,
                                    &thumb_exists,
                                    &user.organization_id,
                                    &user.user_id,
                                    &asset_id,
                                ],
                            )
                            .await;
                    }
                }

                let live_ok = if is_live {
                    if locked {
                        locked_live_video_fully_backed_up_on_disk(
                            &state,
                            &user.user_id,
                            &live_video_path,
                        )
                        .await
                    } else {
                        unlocked_live_video_exists_on_disk(
                            &state,
                            &user.user_id,
                            &asset_id,
                            &photo_path,
                            &live_video_path,
                        )
                        .await
                    }
                } else {
                    true
                };
                if is_live && !live_ok {
                    live_missing += 1;
                }

                let fully_backed_up = if locked {
                    orig_ok && thumb_ok && live_ok
                } else {
                    live_ok
                };
                if locked && !(orig_ok && thumb_ok) {
                    locked_incomplete += 1;
                }
                if fully_backed_up {
                    if use_backup_ids {
                        if let Some(bid) = backup_id.as_ref() {
                            if requested_set.contains(bid) {
                                active_request_matches.insert(bid.clone());
                            }
                        }
                        if requested_set.contains(&asset_id) {
                            active_request_matches.insert(asset_id.clone());
                        }
                    } else {
                        active_request_matches.insert(asset_id.clone());
                    }
                    if use_backup_ids {
                        present.push(backup_id.unwrap_or(asset_id));
                    } else {
                        present.push(asset_id);
                    }
                }
            }
            tracing::info!(
                target: "cloudcheck",
                "[CLOUDCHECK] exists (pg) mode={} requested={} matched_rows={} present={} live_total={} live_missing={} locked_total={} locked_incomplete={}",
                if use_backup_ids { "backup_id" } else { "asset_id" },
                requested_ids.len(),
                matched_rows,
                present.len(),
                live_total,
                live_missing,
                locked_total,
                locked_incomplete
            );

            if payload.include_deleted_matches {
                let deleted_sql = format!(
                    "SELECT asset_id, backup_id
                     FROM photos
                     WHERE organization_id = $1 AND user_id = $2
                       AND COALESCE(delete_time, 0) > 0
                       AND {}",
                    where_clause
                );
                let deleted_rows = pg
                    .query(&deleted_sql, &params)
                    .await
                    .map_err(|e| AppError(anyhow::anyhow!(e.to_string())))?;
                for row in deleted_rows {
                    let deleted_asset_id: String = row.get(0);
                    let deleted_backup_id: Option<String> = row.get(1);
                    if use_backup_ids {
                        if let Some(bid) = deleted_backup_id.as_ref() {
                            if requested_set.contains(bid) {
                                deleted_requested.insert(bid.clone());
                            }
                        }
                        if requested_set.contains(&deleted_asset_id) {
                            deleted_requested.insert(deleted_asset_id);
                        }
                    } else {
                        deleted_requested.insert(deleted_asset_id);
                    }
                }

                let mut tombstone_params: Vec<&(dyn tokio_postgres::types::ToSql + Sync)> =
                    Vec::new();
                tombstone_params.push(&user.organization_id);
                tombstone_params.push(&user.user_id);
                let tombstone_key_kind = if use_backup_ids {
                    KEY_KIND_BACKUP_ID
                } else {
                    KEY_KIND_ASSET_ID
                };
                tombstone_params.push(&tombstone_key_kind);
                let mut tombstone_placeholders: Vec<String> = Vec::new();
                for (i, id) in requested_ids.iter().enumerate() {
                    tombstone_placeholders.push(format!("${}", i + 4));
                    tombstone_params.push(id);
                }
                let tombstone_sql = format!(
                    "SELECT key_value
                     FROM deleted_upload_tombstones
                     WHERE organization_id = $1 AND user_id = $2 AND key_kind = $3
                       AND key_value IN ({})",
                    tombstone_placeholders.join(",")
                );
                let tombstone_rows = pg
                    .query(&tombstone_sql, &tombstone_params)
                    .await
                    .map_err(|e| AppError(anyhow::anyhow!(e.to_string())))?;
                for row in tombstone_rows {
                    deleted_requested.insert(row.get::<_, String>(0));
                }

                deleted_requested.retain(|id| !active_request_matches.contains(id));
            }
        }

        let deleted_values: Vec<String> = deleted_requested.into_iter().collect();
        return Ok(Json(ExistsResponse {
            present_asset_ids: if use_backup_ids {
                Vec::new()
            } else {
                present.clone()
            },
            present_backup_ids: if use_backup_ids { Some(present) } else { None },
            deleted_asset_ids: if payload.include_deleted_matches && !use_backup_ids {
                Some(deleted_values.clone())
            } else {
                None
            },
            deleted_backup_ids: if payload.include_deleted_matches && use_backup_ids {
                Some(deleted_values)
            } else {
                None
            },
        }));
    }

    // DuckDB path
    let data_db = state.get_user_data_database(&user.user_id)?;
    let org_id = user.organization_id;

    // On-demand backfill so `backup_id` queries work without a full reindex.
    if use_backup_ids {
        let to_fill: Vec<(String, String)> = {
            let conn = data_db.lock();
            let mut stmt = conn
                .prepare(
                    "SELECT asset_id, path
                     FROM photos
                     WHERE organization_id=? AND user_id=?
                       AND COALESCE(delete_time,0)=0
                       AND COALESCE(locked,FALSE)=FALSE
                       AND (
                            COALESCE(mime_type,'') = 'image/jpeg'
                            OR lower(path) LIKE '%.jpg'
                            OR lower(path) LIKE '%.jpeg'
                            OR lower(filename) LIKE '%.jpg'
                            OR lower(filename) LIKE '%.jpeg'
                       )
                       AND (backup_id IS NULL OR backup_id='')
                     LIMIT 10000",
                )
                .map_err(|e| AppError(anyhow!(e)))?;
            let mapped = stmt
                .query_map(duckdb::params![org_id, &user.user_id], |row| {
                    Ok::<(String, String), duckdb::Error>((row.get(0)?, row.get(1)?))
                })
                .map_err(|e| AppError(anyhow!(e)))?;
            let mut out: Vec<(String, String)> = Vec::new();
            for r in mapped {
                if let Ok(v) = r {
                    out.push(v);
                }
            }
            out
        };
        if !to_fill.is_empty() {
            let mut filled: usize = 0;
            for (asset_id, path) in to_fill {
                let bid = tokio::task::spawn_blocking({
                    let p = std::path::PathBuf::from(path);
                    let uid = user.user_id.clone();
                    move || -> Option<String> {
                        let bytes = std::fs::read(p).ok()?;
                        crate::photos::backup_id::from_bytes(&bytes, &uid).ok()
                    }
                })
                .await
                .ok()
                .flatten();
                if let Some(bid) = bid {
                    let conn = data_db.lock();
                    let _ = conn.execute(
                        "UPDATE photos SET backup_id=? WHERE organization_id=? AND user_id=? AND asset_id=?",
                        duckdb::params![&bid, org_id, &user.user_id, &asset_id],
                    );
                    filled += 1;
                }
            }
            tracing::info!(
                target: "cloudcheck",
                "[CLOUDCHECK] backup_id backfill (duckdb) filled={}",
                filled
            );
        }
    }

    let mut present: Vec<String> = Vec::new();
    let mut active_request_matches: HashSet<String> = HashSet::new();
    let mut deleted_requested: HashSet<String> = HashSet::new();
    if !requested_ids.is_empty() {
        let ids = requested_ids.clone();
        let rows: Vec<(
            String,
            Option<String>,
            bool,
            bool,
            bool,
            bool,
            Option<String>,
            String,
        )> = {
            let conn = data_db.lock();
            let mut q = String::from(
                "SELECT asset_id,
                        backup_id,
                        COALESCE(locked, FALSE) AS locked,
                        COALESCE(locked_orig_uploaded, FALSE) AS locked_orig_uploaded,
                        COALESCE(locked_thumb_uploaded, FALSE) AS locked_thumb_uploaded,
                        COALESCE(is_live_photo, FALSE) AS is_live_photo,
                        live_video_path,
                        path
                 FROM photos
                 WHERE organization_id = ? AND user_id = ? AND COALESCE(delete_time, 0) = 0 AND ",
            );
            if use_backup_ids {
                q.push_str("(backup_id IN (");
                q.push_str(&vec!["?"; ids.len()].join(","));
                q.push_str(") OR asset_id IN (");
                q.push_str(&vec!["?"; ids.len()].join(","));
                q.push_str("))");
            } else {
                q.push_str("asset_id IN (");
                q.push_str(&vec!["?"; ids.len()].join(","));
                q.push(')');
            }
            let mut stmt = conn.prepare(&q).map_err(|e| AppError(anyhow!(e)))?;
            let mut params: Vec<Box<dyn duckdb::ToSql>> =
                Vec::with_capacity(2 + (ids.len() * if use_backup_ids { 2 } else { 1 }));
            params.push(Box::new(org_id));
            params.push(Box::new(user.user_id.clone()));
            for id in &ids {
                params.push(Box::new(id.clone()));
            }
            if use_backup_ids {
                for id in &ids {
                    params.push(Box::new(id.clone()));
                }
            }
            let mapped = stmt
                .query_map(
                    duckdb::params_from_iter(params.iter().map(|b| &**b)),
                    |row| {
                        let asset_id: String = row.get(0)?;
                        let backup_id: Option<String> = row.get(1).ok();
                        let locked: bool = row.get(2)?;
                        let orig_ok: bool = row.get(3)?;
                        let thumb_ok: bool = row.get(4)?;
                        let is_live: bool = row.get(5)?;
                        let live_video_path: Option<String> = row.get(6).ok();
                        let photo_path: String = row.get(7)?;
                        Ok((
                            asset_id,
                            backup_id,
                            locked,
                            orig_ok,
                            thumb_ok,
                            is_live,
                            live_video_path,
                            photo_path,
                        ))
                    },
                )
                .map_err(|e| AppError(anyhow!(e)))?;
            let mut out: Vec<(
                String,
                Option<String>,
                bool,
                bool,
                bool,
                bool,
                Option<String>,
                String,
            )> = Vec::new();
            for r in mapped {
                if let Ok(v) = r {
                    out.push(v);
                }
            }
            out
        };

        let matched_rows = rows.len();
        let mut live_total: usize = 0;
        let mut live_missing: usize = 0;
        let mut locked_total: usize = 0;
        let mut locked_incomplete: usize = 0;
        for (
            asset_id,
            backup_id,
            locked,
            mut orig_ok,
            mut thumb_ok,
            is_live,
            live_video_path,
            photo_path,
        ) in rows
        {
            if locked {
                locked_total += 1;
            }
            if is_live {
                live_total += 1;
            }
            if locked && (!orig_ok || !thumb_ok) {
                let (orig_exists, thumb_exists) =
                    locked_components_exist_on_disk(&state, &user.user_id, &asset_id).await;
                if orig_exists {
                    orig_ok = true;
                }
                if thumb_exists {
                    thumb_ok = true;
                }
                if orig_exists || thumb_exists {
                    let conn = data_db.lock();
                    let _ = conn.execute(
                        "UPDATE photos
                         SET locked_orig_uploaded = CASE WHEN ? THEN TRUE ELSE locked_orig_uploaded END,
                             locked_thumb_uploaded = CASE WHEN ? THEN TRUE ELSE locked_thumb_uploaded END
                         WHERE organization_id = ? AND user_id = ? AND asset_id = ?",
                        duckdb::params![orig_exists, thumb_exists, org_id, &user.user_id, &asset_id],
                    );
                }
            }
            let live_ok = if is_live {
                if locked {
                    locked_live_video_fully_backed_up_on_disk(
                        &state,
                        &user.user_id,
                        &live_video_path,
                    )
                    .await
                } else {
                    unlocked_live_video_exists_on_disk(
                        &state,
                        &user.user_id,
                        &asset_id,
                        &photo_path,
                        &live_video_path,
                    )
                    .await
                }
            } else {
                true
            };
            if is_live && !live_ok {
                live_missing += 1;
            }
            let fully_backed_up = if locked {
                orig_ok && thumb_ok && live_ok
            } else {
                live_ok
            };
            if locked && !(orig_ok && thumb_ok) {
                locked_incomplete += 1;
            }
            if fully_backed_up {
                if use_backup_ids {
                    if let Some(bid) = backup_id.as_ref() {
                        if requested_set.contains(bid) {
                            active_request_matches.insert(bid.clone());
                        }
                    }
                    if requested_set.contains(&asset_id) {
                        active_request_matches.insert(asset_id.clone());
                    }
                } else {
                    active_request_matches.insert(asset_id.clone());
                }
                if use_backup_ids {
                    present.push(backup_id.unwrap_or(asset_id));
                } else {
                    present.push(asset_id);
                }
            }
        }
        tracing::info!(
            target: "cloudcheck",
            "[CLOUDCHECK] exists (duckdb) mode={} requested={} matched_rows={} present={} live_total={} live_missing={} locked_total={} locked_incomplete={}",
            if use_backup_ids { "backup_id" } else { "asset_id" },
            requested_ids.len(),
            matched_rows,
            present.len(),
            live_total,
            live_missing,
            locked_total,
            locked_incomplete
        );

        if payload.include_deleted_matches {
            let ids = requested_ids.clone();
            let deleted_rows: Vec<(String, Option<String>)> = {
                let conn = data_db.lock();
                let mut q = String::from(
                    "SELECT asset_id, backup_id
                     FROM photos
                     WHERE organization_id = ? AND user_id = ? AND COALESCE(delete_time, 0) > 0 AND ",
                );
                if use_backup_ids {
                    q.push_str("(backup_id IN (");
                    q.push_str(&vec!["?"; ids.len()].join(","));
                    q.push_str(") OR asset_id IN (");
                    q.push_str(&vec!["?"; ids.len()].join(","));
                    q.push_str("))");
                } else {
                    q.push_str("asset_id IN (");
                    q.push_str(&vec!["?"; ids.len()].join(","));
                    q.push(')');
                }
                let mut stmt = conn.prepare(&q).map_err(|e| AppError(anyhow!(e)))?;
                let mut params: Vec<Box<dyn duckdb::ToSql>> =
                    Vec::with_capacity(2 + (ids.len() * if use_backup_ids { 2 } else { 1 }));
                params.push(Box::new(org_id));
                params.push(Box::new(user.user_id.clone()));
                for id in &ids {
                    params.push(Box::new(id.clone()));
                }
                if use_backup_ids {
                    for id in &ids {
                        params.push(Box::new(id.clone()));
                    }
                }
                let mapped = stmt
                    .query_map(
                        duckdb::params_from_iter(params.iter().map(|b| &**b)),
                        |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?)),
                    )
                    .map_err(|e| AppError(anyhow!(e)))?;
                let mut out: Vec<(String, Option<String>)> = Vec::new();
                for r in mapped {
                    if let Ok(v) = r {
                        out.push(v);
                    }
                }
                out
            };
            for (deleted_asset_id, deleted_backup_id) in deleted_rows {
                if use_backup_ids {
                    if let Some(bid) = deleted_backup_id.as_ref() {
                        if requested_set.contains(bid) {
                            deleted_requested.insert(bid.clone());
                        }
                    }
                    if requested_set.contains(&deleted_asset_id) {
                        deleted_requested.insert(deleted_asset_id);
                    }
                } else {
                    deleted_requested.insert(deleted_asset_id);
                }
            }

            let tombstone_rows: Vec<String> = {
                let conn = data_db.lock();
                let mut q = String::from(
                    "SELECT key_value
                     FROM deleted_upload_tombstones
                     WHERE organization_id = ? AND user_id = ? AND key_kind = ? AND key_value IN (",
                );
                q.push_str(&vec!["?"; ids.len()].join(","));
                q.push(')');
                let mut stmt = conn.prepare(&q).map_err(|e| AppError(anyhow!(e)))?;
                let mut params: Vec<Box<dyn duckdb::ToSql>> = Vec::with_capacity(3 + ids.len());
                params.push(Box::new(org_id));
                params.push(Box::new(user.user_id.clone()));
                params.push(Box::new(
                    if use_backup_ids {
                        KEY_KIND_BACKUP_ID
                    } else {
                        KEY_KIND_ASSET_ID
                    }
                    .to_string(),
                ));
                for id in &ids {
                    params.push(Box::new(id.clone()));
                }
                let mapped = stmt
                    .query_map(
                        duckdb::params_from_iter(params.iter().map(|b| &**b)),
                        |row| row.get::<_, String>(0),
                    )
                    .map_err(|e| AppError(anyhow!(e)))?;
                let mut out = Vec::new();
                for r in mapped {
                    if let Ok(v) = r {
                        out.push(v);
                    }
                }
                out
            };
            deleted_requested.extend(tombstone_rows);
            deleted_requested.retain(|id| !active_request_matches.contains(id));
        }
    }

    let deleted_values: Vec<String> = deleted_requested.into_iter().collect();
    Ok(Json(ExistsResponse {
        present_asset_ids: if use_backup_ids {
            Vec::new()
        } else {
            present.clone()
        },
        present_backup_ids: if use_backup_ids { Some(present) } else { None },
        deleted_asset_ids: if payload.include_deleted_matches && !use_backup_ids {
            Some(deleted_values.clone())
        } else {
            None
        },
        deleted_backup_ids: if payload.include_deleted_matches && use_backup_ids {
            Some(deleted_values)
        } else {
            None
        },
    }))
}

#[instrument(skip(state, headers))]
pub async fn list_deleted_backups(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(query): Query<DeletedBackupsQuery>,
) -> Result<impl IntoResponse, AppError> {
    let user = get_user_from_headers(&headers, &state.auth_service).await?;
    spawn_legacy_deleted_backup_repair(state.clone(), user.organization_id, user.user_id.clone());
    let limit = query.limit.clamp(1, 1000);
    let (total, backup_ids) = list_deleted_backup_ids_page(
        state.as_ref(),
        user.organization_id,
        &user.user_id,
        limit,
        query.after.as_deref(),
    )
    .await
    .map_err(AppError)?;
    let next_after = if backup_ids.len() == limit {
        backup_ids.last().cloned()
    } else {
        None
    };
    Ok(Json(DeletedBackupsPageResponse {
        total,
        backup_ids,
        next_after,
    }))
}

#[instrument(skip(state, headers))]
pub async fn match_deleted_backups(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(payload): Json<DeletedBackupsMatchRequest>,
) -> Result<impl IntoResponse, AppError> {
    let user = get_user_from_headers(&headers, &state.auth_service).await?;
    spawn_legacy_deleted_backup_repair(state.clone(), user.organization_id, user.user_id.clone());
    let mut deleted_backup_ids = match_deleted_backup_ids(
        state.as_ref(),
        user.organization_id,
        &user.user_id,
        &payload.backup_ids,
    )
    .await
    .map_err(AppError)?
    .into_iter()
    .collect::<Vec<_>>();
    deleted_backup_ids.sort();
    Ok(Json(DeletedBackupsMatchResponse { deleted_backup_ids }))
}

#[instrument(skip(state, headers))]
pub async fn get_photos_by_asset_ids(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(payload): Json<AssetIdsRequest>,
) -> Result<impl IntoResponse, AppError> {
    let user = get_user_from_headers(&headers, &state.auth_service).await?;
    if let Some(pg) = &state.pg_client {
        let include_locked = payload.include_locked.unwrap_or(false);
        if payload.asset_ids.is_empty() {
            return Ok(Json(Vec::<PhotoDTO>::new()));
        }
        // Build IN list safely with parameters
        let mut params: Vec<&(dyn tokio_postgres::types::ToSql + Sync)> = Vec::new();
        params.push(&user.organization_id);
        params.push(&user.user_id);
        let mut placeholders: Vec<String> = Vec::new();
        for (i, aid) in payload.asset_ids.iter().enumerate() {
            placeholders.push(format!("${}", i + 3));
            params.push(aid);
        }
        let lock_clause = if include_locked {
            ""
        } else {
            " AND COALESCE(p.locked, FALSE) = FALSE"
        };
        let sql = format!(
            "SELECT id, asset_id, COALESCE(filename,'') AS filename, mime_type, COALESCE(has_gain_map, FALSE), hdr_kind, created_at, modified_at, size, width, height, orientation, favorites, locked, delete_time, is_video, is_live_photo, duration_ms, is_screenshot, camera_make, camera_model, iso, aperture, shutter_speed, focal_length, location_name, city, province, country, rating
             FROM photos p WHERE p.organization_id = $1 AND p.user_id = $2 AND p.asset_id IN ({}){}",
            placeholders.join(","),
            lock_clause
        );
        let rows = pg
            .query(&sql, &params)
            .await
            .map_err(|e| AppError(anyhow::anyhow!(e.to_string())))?;
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
        return Ok(Json(out));
    }
    let data_db = state.get_user_data_database(&user.user_id)?;
    let conn = data_db.lock();
    let mut out: Vec<PhotoDTO> = Vec::new();
    tracing::info!(
        target = "search",
        "[BY_IDS] user={} asset_ids={} sample_first={:?}",
        user.user_id,
        payload.asset_ids.len(),
        payload.asset_ids.get(0)
    );
    let include_locked = payload.include_locked.unwrap_or(false);
    for aid in &payload.asset_ids {
        let sql = if include_locked {
            "SELECT id, asset_id, path, filename, mime_type, COALESCE(has_gain_map, FALSE), hdr_kind, created_at, modified_at, size, width, height, orientation, favorites, locked, delete_time, is_video, is_live_photo, live_video_path, duration_ms, is_screenshot, camera_make, camera_model, iso, aperture, shutter_speed, focal_length, latitude, longitude, altitude, location_name, city, province, country, caption, description, rating FROM photos WHERE organization_id = ? AND user_id = ? AND asset_id = ? AND COALESCE(delete_time,0) = 0 LIMIT 1"
        } else {
            "SELECT id, asset_id, path, filename, mime_type, COALESCE(has_gain_map, FALSE), hdr_kind, created_at, modified_at, size, width, height, orientation, favorites, locked, delete_time, is_video, is_live_photo, live_video_path, duration_ms, is_screenshot, camera_make, camera_model, iso, aperture, shutter_speed, focal_length, latitude, longitude, altitude, location_name, city, province, country, caption, description, rating FROM photos WHERE organization_id = ? AND user_id = ? AND asset_id = ? AND COALESCE(locked, FALSE) = FALSE AND COALESCE(delete_time,0) = 0 LIMIT 1"
        };
        if let Ok(mut stmt) = conn.prepare(sql) {
            if let Ok(row) = stmt.query_row(
                duckdb::params![user.organization_id, &user.user_id, aid],
                |row| {
                    Ok(PhotoDTO {
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
                        rating: row.get(36).ok(),
                    })
                },
            ) {
                out.push(row);
            }
        }
    }
    tracing::info!(target = "search", "[BY_IDS] found {} rows", out.len());
    Ok(Json(out))
}

#[derive(Debug, Serialize)]
pub struct LockedSampleResponse {
    pub locked_count: i64,
    pub sample: Vec<(String, String)>,
    pub unlocked_count: i64,
}

/// Debug: show how many locked items exist and a small sample (asset_id, filename)
#[instrument(skip(state, headers))]
pub async fn debug_locked_sample(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, AppError> {
    let user = get_user_from_headers(&headers, &state.auth_service).await?;
    let data_db = state.get_user_data_database(&user.user_id)?;
    let conn = data_db.lock();
    let locked_count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM photos WHERE organization_id = ? AND COALESCE(locked, FALSE) = TRUE",
            duckdb::params![user.organization_id],
            |r| r.get(0),
        )
        .unwrap_or(0);
    let unlocked_count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM photos WHERE organization_id = ? AND COALESCE(locked, FALSE) = FALSE",
            duckdb::params![user.organization_id],
            |r| r.get(0),
        )
        .unwrap_or(0);
    let mut sample: Vec<(String, String)> = Vec::new();
    if let Ok(mut stmt) = conn.prepare(
        "SELECT asset_id, COALESCE(filename,'') FROM photos WHERE organization_id = ? AND COALESCE(locked, FALSE) = TRUE ORDER BY created_at DESC LIMIT 10",
    ) {
        let rows = stmt.query_map(duckdb::params![user.organization_id], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)) )?;
        for r in rows { if let Ok(p) = r { sample.push(p); } }
    }
    Ok(Json(LockedSampleResponse {
        locked_count,
        sample,
        unlocked_count,
    }))
}

#[instrument(skip(state, headers))]
pub async fn list_photos(
    State(state): State<Arc<AppState>>,
    Query(incoming): Query<PhotoListQuery>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, AppError> {
    // Get authenticated user
    let user = get_user_from_headers(&headers, &state.auth_service).await?;

    // Postgres path: use MetaStore when available
    if let Some(meta) = &state.meta {
        let query = incoming.clone();
        let (photos, total) = meta
            .list_photos(user.organization_id, &user.user_id, &query)
            .await?;
        tracing::info!(
            target = "upload",
            "[PG-LIST] user={} org={} total={} page={} limit={} sort_by={:?} order={:?}",
            user.user_id,
            user.organization_id,
            total,
            query.page.unwrap_or(1),
            query.limit.unwrap_or(100).min(500),
            query.sort_by,
            query.sort_order
        );
        let page = query.page.unwrap_or(1);
        let limit = query.limit.unwrap_or(100).min(500);
        let has_more = (page * limit) < (total as u32);
        let payload = serde_json::json!({
            "photos": photos,
            "total": total,
            "page": page,
            "limit": limit,
            "has_more": has_more,
        });
        let mut hm = HeaderMap::new();
        hm.insert(
            header::CONTENT_TYPE,
            axum::http::HeaderValue::from_static("application/json"),
        );
        return Ok((
            hm,
            serde_json::to_string(&payload).unwrap_or_else(|_| "{}".to_string()),
        ));
    }

    // Robust listing mode (pooled connection + minimal projection to avoid large TEXT scans)
    // [LIST_PHOTOS] pooled+minimal mode log suppressed
    let data_db = state.get_user_data_database(&user.user_id)?;
    state.backfill_live_photo_video_flags(&user.user_id).await;

    // Resolve live album criteria if needed
    let mut query = incoming;
    // Check both album_id (singular) and album_ids (plural with single ID)
    let target_album_id = query.album_id.or_else(|| {
        // If album_ids contains exactly one ID, treat it as album_id for live album resolution
        query.album_ids.as_ref().and_then(|ids_str| {
            let ids: Vec<i32> = ids_str
                .split(',')
                .filter_map(|s| s.trim().parse::<i32>().ok())
                .collect();
            if ids.len() == 1 {
                Some(ids[0])
            } else {
                None
            }
        })
    });

    if let Some(album_id) = target_album_id {
        let (is_live, crit_json) = {
            let conn = data_db.lock();
            let mut is_live = false;
            let mut crit_json: Option<String> = None;
            if let Ok(mut stmt) = conn.prepare(
                "SELECT COALESCE(is_live, FALSE), live_criteria FROM albums WHERE organization_id = ? AND id = ? LIMIT 1",
            ) {
                let row = stmt.query_row(duckdb::params![user.organization_id, album_id], |row| {
                    Ok::<(bool, Option<String>), duckdb::Error>((row.get(0)?, row.get(1).ok()))
                });
                if let Ok((flag, cj)) = row {
                    is_live = flag;
                    crit_json = cj;
                }
            }
            (is_live, crit_json)
        };
        if is_live {
            if let Some(cj) = crit_json {
                if let Ok(mut crit) = serde_json::from_str::<PhotoListQuery>(&cj) {
                    // prevent recursion
                    crit.album_id = None;
                    crit.album_ids = None;
                    crit.album_subtree = None;
                    // Allow page/limit/sort overrides from incoming
                    if let Some(p) = query.page {
                        crit.page = Some(p);
                    }
                    if let Some(l) = query.limit {
                        crit.limit = Some(l);
                    }
                    if let Some(th) = query.total_hint {
                        crit.total_hint = Some(th);
                    }
                    if let Some(sb) = query.sort_by {
                        crit.sort_by = Some(sb);
                    }
                    if let Some(so) = query.sort_order {
                        crit.sort_order = Some(so);
                    }
                    if let Some(sr) = query.sort_random_seed {
                        crit.sort_random_seed = Some(sr);
                    }
                    query = crit;
                }
            }
        }
    }

    // Build dynamic WHERE/JOINs for a subset of filters (favorite, album, is_video)
    let page = query.page.unwrap_or(1);
    let limit = query.limit.unwrap_or(100).min(500);
    let offset = page.saturating_sub(1) * limit;
    let sort_by = query.sort_by.as_deref().unwrap_or("created_at");
    let sort_order = query.sort_order.as_deref().unwrap_or("DESC");
    let req_started = Instant::now();

    let mut where_clauses: Vec<String> = Vec::new();
    // Always scope by organization and owner user for safety
    where_clauses.push(format!("p.organization_id = {}", user.organization_id));
    where_clauses.push(format!("p.user_id = '{}'", user.user_id.replace("'", "''")));
    // Filter out macOS AppleDouble resource forks and other filesystem junk.
    // These can have photo-like extensions (e.g., `._IMG_0001.jpg`) but are not valid media.
    where_clauses.push("COALESCE(p.filename,'') NOT LIKE '._%'".to_string());
    where_clauses.push("COALESCE(p.filename,'') <> '.DS_Store'".to_string());
    where_clauses.push("COALESCE(p.filename,'') <> 'Thumbs.db'".to_string());
    // Hide Live Photo motion components (paired MOVs) from library views/counts.
    // These are stored as short video rows (is_video=1) but should never appear as user videos.
    where_clauses
        .push("NOT (p.is_video = 1 AND COALESCE(p.is_live_photo, FALSE) = TRUE)".to_string());
    let mut joins: Vec<String> = Vec::new();

    if let Some(fav) = query.filter_favorite {
        if fav {
            where_clauses.push("p.favorites > 0".to_string());
        }
    }
    if let Some(minr) = query.filter_rating_min {
        if minr > 0 {
            where_clauses.push(format!("COALESCE(p.rating, 0) >= {}", minr.min(5)));
        }
    }
    if let Some(is_video) = query.filter_is_video {
        where_clauses.push(format!("p.is_video = {}", if is_video { 1 } else { 0 }));
    }
    // Location filters
    if let Some(city) = &query.filter_city {
        where_clauses.push(format!("p.city = '{}'", city.replace("'", "''")));
    }
    if let Some(country) = &query.filter_country {
        where_clauses.push(format!("p.country = '{}'", country.replace("'", "''")));
    }
    // Time range filters (created_at is photo taken time when EXIF is available)
    if let Some(date_from) = query.filter_date_from {
        where_clauses.push(format!("p.created_at >= {}", date_from));
    }
    if let Some(date_to) = query.filter_date_to {
        // Client provides an end-of-day timestamp; treat it as inclusive
        where_clauses.push(format!("p.created_at <= {}", date_to));
    }
    // Apply screenshot filter; when enabled, always exclude videos
    if let Some(s) = query.filter_screenshot {
        if s {
            where_clauses.push("p.is_screenshot = 1".to_string());
            where_clauses.push("p.is_video = 0".to_string());
        } else {
            where_clauses.push("p.is_screenshot = 0".to_string());
        }
    }
    // Apply live-photos filter (still photos paired with video component)
    if let Some(live) = query.filter_live_photo {
        where_clauses.push(format!("p.is_live_photo = {}", if live { 1 } else { 0 }));
        // Live Photos are photos, not videos
        if live {
            where_clauses.push("p.is_video = 0".to_string());
        }
    }
    // Rating minimum (1..5). NULL ratings never match unless min <= 0
    if let Some(minr) = query.filter_rating_min {
        if minr > 0 {
            where_clauses.push(format!("COALESCE(p.rating, 0) >= {}", minr.min(5)));
        }
    }
    if let Some(ref ids_csv) = query.album_ids {
        // AND semantics across selected roots: one join per root (expanded to descendants when enabled)
        let base_ids: Vec<i32> = ids_csv
            .split(',')
            .filter_map(|s| s.trim().parse::<i32>().ok())
            .collect();
        if !base_ids.is_empty() {
            let include_desc = query.album_subtree.unwrap_or(true);
            let conn = data_db.lock();
            for (idx, root_id) in base_ids.iter().enumerate() {
                let mut group: Vec<i32> = vec![*root_id];
                if include_desc {
                    if let Ok(mut stmt) = conn
                        .prepare("SELECT descendant_id FROM album_closure WHERE organization_id = ? AND ancestor_id = ?")
                    {
                        if let Ok(rows) = stmt.query_map(duckdb::params![user.organization_id, *root_id], |row| row.get::<_, i32>(0)) {
                            for r in rows {
                                if let Ok(id) = r {
                                    group.push(id);
                                }
                            }
                        }
                    }
                }
                group.sort();
                group.dedup();
                let inlist = group
                    .iter()
                    .map(|id| id.to_string())
                    .collect::<Vec<_>>()
                    .join(",");
                let alias = format!("ap{}", idx);
                joins.push(format!(
                    "INNER JOIN album_photos {} ON {}.organization_id = p.organization_id AND p.id = {}.photo_id AND {}.album_id IN ({})",
                    alias, alias, alias, alias, inlist
                ));
            }
        }
    } else if let Some(album_id) = query.album_id {
        joins.push("INNER JOIN album_photos ap ON ap.organization_id = p.organization_id AND p.id = ap.photo_id".to_string());
        // Default to include descendants when filtering by album
        if query.album_subtree.unwrap_or(true) {
            // Expand to descendant albums via closure table
            let ids = {
                let conn = data_db.lock();
                let mut collected: Vec<i32> = vec![album_id];
                if let Ok(mut stmt) =
                    conn.prepare("SELECT descendant_id FROM album_closure WHERE organization_id = ? AND ancestor_id = ?")
                {
                    let rows = match stmt.query_map(duckdb::params![user.organization_id, album_id], |row| row.get::<_, i32>(0)) {
                        Ok(rows) => rows,
                        Err(err) => return Err(AppError::from(err)),
                    };
                    for r in rows {
                        if let Ok(id) = r {
                            collected.push(id);
                        }
                    }
                }
                collected
            };
            let inlist = ids
                .iter()
                .map(|id| id.to_string())
                .collect::<Vec<_>>()
                .join(",");
            where_clauses.push(format!("ap.album_id IN ({})", inlist));
        } else {
            where_clauses.push(format!("ap.album_id = {}", album_id));
        }
    }
    if let Some(face_param) = &query.filter_faces {
        let ids: Vec<String> = face_param
            .split(',')
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .map(|s| s.to_string())
            .collect();
        if !ids.is_empty() {
            // AND semantics: only assets that contain all selected persons
            let embed_db = state.get_user_embedding_database(&user.user_id)?;
            let conn_e = embed_db.lock();
            let ids_list = ids
                .iter()
                .map(|s| format!("'{}'", s.replace("'", "''")))
                .collect::<Vec<_>>()
                .join(",");
            let org_id = user.organization_id;
            let user_id = user.user_id.replace("'", "''");
            let sql = match query.filter_faces_mode.as_deref() {
                Some("any") => {
                    // OR semantics: any of the selected persons (include hidden faces)
                    format!(
                        "SELECT DISTINCT f.asset_id FROM faces_embed f JOIN photos dp ON dp.asset_id = f.asset_id WHERE dp.organization_id = {} AND dp.user_id = '{}' AND f.person_id IN ({})",
                        org_id, user_id, ids_list
                    )
                }
                _ => {
                    // Default AND semantics (include hidden faces)
                    format!(
                        "SELECT f.asset_id FROM faces_embed f JOIN photos dp ON dp.asset_id = f.asset_id WHERE dp.organization_id = {} AND dp.user_id = '{}' AND f.person_id IN ({}) GROUP BY f.asset_id HAVING COUNT(DISTINCT f.person_id) = {}",
                        org_id, user_id, ids_list, ids.len()
                    )
                }
            };
            let mut asset_ids: Vec<String> = Vec::new();
            match conn_e.prepare(&sql) {
                Ok(mut stmt) => {
                    let rows = stmt.query_map([], |row| row.get::<_, String>(0))?;
                    for r in rows {
                        if let Ok(a) = r {
                            asset_ids.push(a);
                        }
                    }
                }
                Err(err) => {
                    // Transient prepare error (e.g., database lock). Retry once with a refreshed embedding connection.
                    tracing::warn!("[LIST_PHOTOS] faces query prepare failed: {}. Retrying with refreshed embed connection...", err);
                    let embed_db2 = state
                        .multi_tenant_db
                        .as_ref()
                        .expect("user DB required in DuckDB mode")
                        .refresh_user_embedding_connection(&user.user_id)?;
                    let conn2 = embed_db2.lock();
                    let mut stmt = conn2.prepare(&sql)?;
                    let rows = stmt.query_map([], |row| row.get::<_, String>(0))?;
                    for r in rows {
                        if let Ok(a) = r {
                            asset_ids.push(a);
                        }
                    }
                }
            }
            if asset_ids.is_empty() {
                let payload = serde_json::json!({
                    "photos": [],
                    "total": 0,
                    "page": page,
                    "limit": limit,
                    "has_more": false,
                });
                let mut hm = HeaderMap::new();
                hm.insert(
                    header::CONTENT_TYPE,
                    axum::http::HeaderValue::from_static("application/json"),
                );
                return Ok((hm, serde_json::to_string(&payload).unwrap()));
            }
            let inlist = asset_ids
                .iter()
                .map(|s| format!("'{}'", s.replace("'", "''")))
                .collect::<Vec<_>>()
                .join(",");
            where_clauses.push(format!("p.asset_id IN ({})", inlist));
        }
    }

    // Text search filter: use embedding store to get candidate asset_ids and filter by IN (...)
    if let Some(ref q) = query.q {
        let qtrim = q.trim();
        if !qtrim.is_empty() {
            let store = state.create_user_embedding_store(&user.user_id)?;
            // Encode with default textual encoder
            let model_name = state.default_model.clone();
            let embedding = state
                .with_textual_encoder(Some(&model_name), |enc| enc.encode_text(qtrim))
                .ok_or_else(|| anyhow::anyhow!("Text encoder not available"))??;
            // Generous limit to allow further filtering and pagination later
            let results = store.search_combined(qtrim, embedding, 5000).await?;
            let ids: Vec<String> = results.into_iter().map(|r| r.asset_id).collect();
            if ids.is_empty() {
                // Short-circuit: no matches
                let payload = serde_json::json!({
                    "photos": [],
                    "total": 0,
                    "page": page,
                    "limit": limit,
                    "has_more": false,
                });
                let mut hm = HeaderMap::new();
                hm.insert(
                    header::CONTENT_TYPE,
                    axum::http::HeaderValue::from_static("application/json"),
                );
                return Ok((hm, serde_json::to_string(&payload).unwrap()));
            }
            let inlist = ids
                .into_iter()
                .map(|s| format!("'{}'", s.replace("'", "''")))
                .collect::<Vec<_>>()
                .join(",");
            where_clauses.push(format!("p.asset_id IN ({})", inlist));
        }
    }

    // Enforce locked filtering by default; support locked-only and include_locked
    let include_locked = query.include_locked.unwrap_or(false);
    let locked_only = query.filter_locked_only.unwrap_or(false);
    if locked_only {
        where_clauses.push("COALESCE(p.locked, FALSE) = TRUE".to_string());
    } else if !include_locked {
        where_clauses.push("COALESCE(p.locked, FALSE) = FALSE".to_string());
    }

    let include_trashed = query.include_trashed.unwrap_or(false);
    let trashed_only = query.filter_trashed_only.unwrap_or(false);
    if trashed_only {
        where_clauses.push("COALESCE(p.delete_time, 0) > 0".to_string());
    } else if !include_trashed {
        where_clauses.push("COALESCE(p.delete_time, 0) = 0".to_string());
    }

    // Minimal-ish column set: include filename + camera/location metadata needed by viewer info panel
    let mut base = String::from(
        "SELECT DISTINCT p.id, p.asset_id, COALESCE(p.filename, '') AS filename, p.mime_type, \
                COALESCE(p.has_gain_map, FALSE), p.hdr_kind, \
                p.created_at, p.modified_at, p.size, p.width, p.height, \
                p.orientation, p.favorites, p.locked, p.delete_time, p.is_video, p.is_live_photo, \
                p.duration_ms, p.is_screenshot, p.camera_make, p.camera_model, \
                p.iso, p.aperture, p.shutter_speed, p.focal_length, \
                p.location_name, p.city, p.province, p.country, p.rating \
         FROM photos p",
    );
    for j in &joins {
        base.push(' ');
        base.push_str(j);
    }
    if !where_clauses.is_empty() {
        base.push_str(" WHERE ");
        base.push_str(&where_clauses.join(" AND "));
    }

    let conn = data_db.lock();
    // Counting is expensive (distinct+joins); avoid re-counting on every page.
    // Use a client-provided total hint when available; otherwise compute total (always on page 1).
    let mut total: i64 = query.total_hint.filter(|t| *t >= 0).unwrap_or(-1);
    let mut count_ms: Option<u128> = None;
    if page == 1 || total < 0 {
        let count_started = Instant::now();
        let mut count_sql = String::from("SELECT COUNT(DISTINCT p.id) FROM photos p");
        for j in &joins {
            count_sql.push(' ');
            count_sql.push_str(j);
        }
        if !where_clauses.is_empty() {
            count_sql.push_str(" WHERE ");
            count_sql.push_str(&where_clauses.join(" AND "));
        }
        total = conn
            .query_row(&count_sql, [], |row| row.get::<_, i64>(0))
            .unwrap_or(0);
        count_ms = Some(count_started.elapsed().as_millis());
    }

    let order_clause = if sort_by == "random" {
        let seed = query.sort_random_seed.unwrap_or(42);
        // Use 64-bit arithmetic to avoid INT32 overflow in DuckDB
        // Deterministic pseudo-random order per seed
        format!(
            " ORDER BY ((CAST(p.id AS BIGINT) * CAST(1103515245 AS BIGINT) + CAST({} AS BIGINT)) % CAST(2147483647 AS BIGINT)) ASC",
            seed
        )
    } else {
        format!(" ORDER BY p.{} {}", sort_by, sort_order)
    };
    // Avoid expensive COUNT(*) on every page: fetch one extra row to infer has_more.
    let data_limit = limit.saturating_add(1);
    let data_sql = format!(
        "{}{} LIMIT {} OFFSET {}",
        base, order_clause, data_limit, offset
    );
    // Log the exact SQL used to fetch photos for the grid (useful for debugging)
    tracing::debug!(target = "grid", "[GRID_SQL] {}", data_sql);

    let mut photos: Vec<PhotoDTO> = Vec::new();
    let data_started = Instant::now();
    if let Ok(mut stmt) = conn.prepare(&data_sql) {
        let mapped = stmt.query_map([], |row| {
            Ok(PhotoDTO {
                id: Some(row.get(0)?),
                asset_id: row.get(1)?,
                path: String::new(),
                filename: row.get(2)?,
                mime_type: row.get(3)?,
                has_gain_map: row.get(4)?,
                hdr_kind: row.get(5)?,
                created_at: row.get(6)?,
                modified_at: row.get(7)?,
                size: row.get(8)?,
                width: row.get(9)?,
                height: row.get(10)?,
                orientation: row.get(11)?,
                favorites: row.get(12)?,
                locked: row.get(13)?,
                delete_time: row.get(14)?,
                is_video: row.get(15)?,
                is_live_photo: row.get(16)?,
                live_video_path: None,
                duration_ms: row.get(17)?,
                is_screenshot: row.get(18)?,
                camera_make: row.get(19)?,
                camera_model: row.get(20)?,
                iso: row.get(21)?,
                aperture: row.get(22)?,
                shutter_speed: row.get(23)?,
                focal_length: row.get(24)?,
                latitude: None,
                longitude: None,
                altitude: None,
                location_name: row.get(25)?,
                city: row.get(26)?,
                province: row.get(27)?,
                country: row.get(28)?,
                caption: None,
                description: None,
                rating: row.get(29).ok(),
            })
        });
        for r in mapped? {
            photos.push(r?);
        }
    } else {
        tracing::error!(
            "[LIST_PHOTOS] Prepare failed for data SQL (user {})",
            user.user_id
        );
    }

    let mut has_more = photos.len() > limit as usize;
    if has_more {
        photos.truncate(limit as usize);
    }
    // If we skipped COUNT on non-first pages, we can still return an exact total once we hit the end.
    if total < 0 && !has_more {
        total = offset as i64 + photos.len() as i64;
    }
    if total < 0 {
        total = 0;
    }
    let data_ms = data_started.elapsed().as_millis();
    let total_ms = req_started.elapsed().as_millis();
    tracing::info!(
        target = "perf",
        "[PHOTOS] page={} limit={} offset={} returned={} has_more={} total={} ms_total={} ms_count={:?} ms_data={}",
        page,
        limit,
        offset,
        photos.len(),
        has_more,
        total,
        total_ms,
        count_ms,
        data_ms
    );

    let payload = serde_json::json!({
        "photos": photos,
        "total": total,
        "page": page,
        "limit": limit,
        "has_more": has_more,
    });

    // Summary log suppressed

    let mut hm = HeaderMap::new();
    hm.insert(
        header::CONTENT_TYPE,
        axum::http::HeaderValue::from_static("application/json"),
    );
    Ok((
        hm,
        serde_json::to_string(&payload).unwrap_or_else(|_| "{}".to_string()),
    ))
}

#[instrument(skip(state, headers))]
pub async fn lock_photo(
    State(state): State<Arc<AppState>>,
    Path(asset_id): Path<String>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, AppError> {
    let user = get_user_from_headers(&headers, &state.auth_service).await?;
    // Postgres path
    if let Some(pg) = &state.pg_client {
        let _ = pg
            .execute(
                "UPDATE photos SET locked = TRUE WHERE organization_id=$1 AND asset_id=$2",
                &[&user.organization_id, &asset_id],
            )
            .await
            .unwrap_or(0);
        // Respect security settings
        let row = pg
            .query_opt(
                "SELECT COALESCE(locked_meta_allow_location, FALSE), COALESCE(locked_meta_allow_caption, FALSE), COALESCE(locked_meta_allow_description, FALSE) FROM users WHERE user_id = $1",
                &[&user.user_id],
            )
            .await
            .map_err(|e| AppError(anyhow::anyhow!(e)))?;
        let (allow_loc, allow_cap, allow_desc) = row
            .map(|r| {
                (
                    r.get::<_, bool>(0),
                    r.get::<_, bool>(1),
                    r.get::<_, bool>(2),
                )
            })
            .unwrap_or((false, false, false));
        if !allow_cap {
            let _ = pg
                .execute(
                    "UPDATE photos SET caption=NULL WHERE organization_id=$1 AND asset_id=$2",
                    &[&user.organization_id, &asset_id],
                )
                .await;
        }
        if !allow_desc {
            let _ = pg
                .execute(
                    "UPDATE photos SET description=NULL WHERE organization_id=$1 AND asset_id=$2",
                    &[&user.organization_id, &asset_id],
                )
                .await;
        }
        if !allow_loc {
            let _ = pg
                .execute(
                    "UPDATE photos SET latitude=NULL, longitude=NULL, altitude=NULL, location_name=NULL, city=NULL, province=NULL, country=NULL WHERE organization_id=$1 AND asset_id=$2",
                    &[&user.organization_id, &asset_id],
                )
                .await;
        }
        if let Err(e) = reindex_single_asset(&state, &user.user_id, &asset_id) {
            tracing::warn!("[SEARCH] reindex on lock (PG) failed: {}", e);
        }
        return Ok((
            StatusCode::OK,
            Json(serde_json::json!({"ok": true, "asset_id": asset_id})),
        ));
    }
    // Update locked flag idempotently
    let data_db = state.get_user_data_database(&user.user_id)?;
    {
        let conn = data_db.lock();
        let _rows = conn
            .execute(
                "UPDATE photos SET locked = TRUE WHERE asset_id = ?",
                duckdb::params![asset_id],
            )
            .unwrap_or(0);
    } // drop DB lock before reindex to avoid self-deadlock

    // Respect user security settings by clearing disallowed plaintext metadata when locking
    let (allow_loc, allow_cap, allow_desc): (bool, bool, bool) = {
        let users_db = state
            .multi_tenant_db
            .as_ref()
            .expect("users DB required in DuckDB mode")
            .users_connection();
        let conn_u = users_db.lock();
        conn_u
            .query_row(
                "SELECT COALESCE(locked_meta_allow_location, FALSE), COALESCE(locked_meta_allow_caption, FALSE), COALESCE(locked_meta_allow_description, FALSE) FROM users WHERE user_id = ?",
                duckdb::params![&user.user_id],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .unwrap_or((false, false, false))
    };
    {
        let conn = data_db.lock();
        if !allow_cap {
            let _ = conn.execute(
                "UPDATE photos SET caption = NULL WHERE asset_id = ?",
                duckdb::params![&asset_id],
            );
        }
        if !allow_desc {
            let _ = conn.execute(
                "UPDATE photos SET description = NULL WHERE asset_id = ?",
                duckdb::params![&asset_id],
            );
        }
        if !allow_loc {
            let _ = conn.execute(
                "UPDATE photos SET latitude = NULL, longitude = NULL, altitude = NULL, location_name = NULL, city = NULL, province = NULL, country = NULL WHERE asset_id = ?",
                duckdb::params![&asset_id],
            );
        }
    }
    // Reindex this asset so text search reflects locked status
    if let Err(e) = reindex_single_asset(&state, &user.user_id, &asset_id) {
        tracing::warn!("[SEARCH] reindex on lock failed: {}", e);
    }
    Ok((
        StatusCode::OK,
        Json(serde_json::json!({"ok": true, "asset_id": asset_id})),
    ))
}

#[instrument(skip(state, headers))]
pub async fn delete_photos(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(payload): Json<DeletePhotosRequest>,
) -> Result<impl IntoResponse, AppError> {
    let user = get_user_from_headers(&headers, &state.auth_service).await?;
    if let Some(pg) = &state.pg_client {
        let mut deleted = 0usize;
        let now = chrono::Utc::now().timestamp();
        for aid in &payload.asset_ids {
            upsert_deleted_tombstones_for_asset(
                state.as_ref(),
                user.organization_id,
                &user.user_id,
                aid,
                now,
            )
            .await
            .map_err(AppError)?;
            let rows = pg
                .execute(
                    "UPDATE photos
                     SET delete_time=$1, favorites=0
                     WHERE organization_id=$2 AND user_id=$3 AND asset_id=$4 AND COALESCE(delete_time,0)=0",
                    &[&now, &user.organization_id, &user.user_id, aid],
                )
                .await
                .unwrap_or(0);
            if rows > 0 {
                deleted += 1;
                if let Err(e) = delete_single_asset(&state, &user.user_id, aid) {
                    tracing::warn!("[SEARCH] delete from index failed: {}", e);
                }
            }
        }
        return Ok(Json(DeletePhotosResponse {
            requested: payload.asset_ids.len(),
            deleted,
        }));
    }
    let data_db = state.get_user_data_database(&user.user_id)?;
    let mut deleted = 0usize;
    let now = chrono::Utc::now().timestamp();

    for aid in &payload.asset_ids {
        upsert_deleted_tombstones_for_asset(
            state.as_ref(),
            user.organization_id,
            &user.user_id,
            aid,
            now,
        )
        .await
        .map_err(AppError)?;
        let conn = data_db.lock();
        let rows = conn
            .execute(
                "UPDATE photos
                 SET delete_time = ?, favorites = 0
                 WHERE organization_id = ? AND user_id = ? AND asset_id = ? AND COALESCE(delete_time,0) = 0",
                duckdb::params![now, user.organization_id, &user.user_id, aid],
            )
            .unwrap_or(0);
        drop(conn);

        if rows > 0 {
            deleted += 1;
            if let Err(e) = delete_single_asset(&state, &user.user_id, aid) {
                tracing::warn!("[SEARCH] delete from index failed: {}", e);
            }
        }
    }

    Ok(Json(DeletePhotosResponse {
        requested: payload.asset_ids.len(),
        deleted,
    }))
}

#[instrument(skip(state, headers))]
pub async fn restore_photos(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(payload): Json<TrashActionRequest>,
) -> Result<impl IntoResponse, AppError> {
    let user = get_user_from_headers(&headers, &state.auth_service).await?;
    if let Some(pg) = &state.pg_client {
        let mut restored = 0usize;
        for aid in &payload.asset_ids {
            let rows = pg
                .execute(
                    "UPDATE photos
                     SET delete_time=0
                     WHERE organization_id=$1 AND user_id=$2 AND asset_id=$3 AND COALESCE(delete_time,0)>0",
                    &[&user.organization_id, &user.user_id, aid],
                )
                .await
                .unwrap_or(0);
            if rows > 0 {
                remove_deleted_tombstones_for_asset(
                    state.as_ref(),
                    user.organization_id,
                    &user.user_id,
                    aid,
                )
                .await
                .map_err(AppError)?;
                restored += 1;
                if let Err(e) = reindex_single_asset(&state, &user.user_id, aid) {
                    tracing::warn!("[SEARCH] reindex on restore (PG) failed: {}", e);
                }
            }
        }
        return Ok(Json(json!({
            "requested": payload.asset_ids.len(),
            "restored": restored,
        })));
    }
    let data_db = state.get_user_data_database(&user.user_id)?;
    let mut restored = 0usize;

    for aid in &payload.asset_ids {
        let rows = {
            let conn = data_db.lock();
            conn.execute(
                "UPDATE photos
                 SET delete_time = 0
                 WHERE organization_id = ? AND user_id = ? AND asset_id = ? AND COALESCE(delete_time,0) > 0",
                duckdb::params![user.organization_id, &user.user_id, aid],
            )
            .unwrap_or(0)
        };
        if rows > 0 {
            remove_deleted_tombstones_for_asset(
                state.as_ref(),
                user.organization_id,
                &user.user_id,
                aid,
            )
            .await
            .map_err(AppError)?;
            restored += 1;
            if let Err(e) = reindex_single_asset(&state, &user.user_id, aid) {
                tracing::warn!("[SEARCH] reindex on restore failed: {}", e);
            }
        }
    }

    Ok(Json(json!({
        "requested": payload.asset_ids.len(),
        "restored": restored,
    })))
}

#[instrument(skip(state, headers))]
pub async fn purge_photos(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(payload): Json<TrashActionRequest>,
) -> Result<impl IntoResponse, AppError> {
    let user = get_user_from_headers(&headers, &state.auth_service).await?;
    let purged = hard_delete_assets(&state, &user.user_id, &payload.asset_ids)?;
    Ok(Json(json!({
        "requested": payload.asset_ids.len(),
        "purged": purged,
    })))
}

#[instrument(skip(state, headers))]
pub async fn purge_all_trash(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, AppError> {
    let user = get_user_from_headers(&headers, &state.auth_service).await?;
    let asset_ids: Vec<String> = if let Some(pg) = &state.pg_client {
        let mut ids = Vec::new();
        if let Ok(rows) = pg
            .query(
                "SELECT asset_id
                 FROM photos
                 WHERE organization_id=$1 AND user_id=$2 AND COALESCE(delete_time,0)>0",
                &[&user.organization_id, &user.user_id],
            )
            .await
        {
            for r in rows {
                ids.push(r.get::<_, String>(0));
            }
        }
        ids
    } else {
        let data_db = state.get_user_data_database(&user.user_id)?;
        let conn = data_db.lock();
        let mut ids = Vec::new();
        if let Ok(mut stmt) = conn.prepare(
            "SELECT asset_id
             FROM photos
             WHERE organization_id = ? AND user_id = ? AND COALESCE(delete_time,0) > 0",
        ) {
            if let Ok(rows) = stmt.query_map(
                duckdb::params![user.organization_id, &user.user_id],
                |row| row.get::<_, String>(0),
            ) {
                for r in rows {
                    if let Ok(a) = r {
                        ids.push(a);
                    }
                }
            }
        }
        ids
    };

    if asset_ids.is_empty() {
        return Ok(Json(json!({ "purged": 0 })));
    }

    match hard_delete_assets(state.as_ref(), &user.user_id, &asset_ids) {
        Ok(count) => Ok(Json(json!({ "purged": count }))),
        Err(e) => Err(AppError(e)),
    }
}

#[derive(Debug, serde::Deserialize)]
pub struct UpdatePhotoMetadata {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub caption: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
}

#[derive(Debug, serde::Deserialize)]
pub struct UpdatePhotoRating {
    pub rating: Option<i32>,
}

/// Update caption and/or description for a photo
#[instrument(skip(state, headers, payload))]
pub async fn update_photo_metadata(
    State(state): State<Arc<AppState>>,
    Path(asset_id): Path<String>,
    headers: HeaderMap,
    Json(payload): Json<UpdatePhotoMetadata>,
) -> Result<impl IntoResponse, AppError> {
    let user = get_user_from_headers(&headers, &state.auth_service).await?;
    if let Some(pg) = &state.pg_client {
        let now = chrono::Utc::now().timestamp();
        if payload.caption.is_some() {
            let _ = pg
                .execute(
                    "UPDATE photos SET caption=$1, modified_at=$2 WHERE organization_id=$3 AND asset_id=$4",
                    &[&payload.caption, &now, &user.organization_id, &asset_id],
                )
                .await;
        }
        if payload.description.is_some() {
            let _ = pg
                .execute(
                    "UPDATE photos SET description=$1, modified_at=$2 WHERE organization_id=$3 AND asset_id=$4",
                    &[&payload.description, &now, &user.organization_id, &asset_id],
                )
                .await;
        }
        // Reindex this asset for text search without blocking the reactor
        let st = Arc::clone(&state);
        let uid = user.user_id.clone();
        let aid = asset_id.clone();
        tokio::spawn(async move {
            let _ = tokio::task::spawn_blocking(move || {
                if let Err(e) = crate::server::text_search::reindex_single_asset(&st, &uid, &aid) {
                    tracing::warn!("[SEARCH] reindex on metadata update failed: {}", e);
                }
            })
            .await;
        });
        return Ok(Json(serde_json::json!({ "ok": true })));
    }
    let data_db = state.get_user_data_database(&user.user_id)?;
    let now = chrono::Utc::now().timestamp();
    {
        let conn = data_db.lock();
        if let Some(caption) = payload.caption.as_ref() {
            let _ = conn.execute(
                "UPDATE photos SET caption = ?, modified_at = ? WHERE asset_id = ?",
                duckdb::params![caption, now, &asset_id],
            );
        }
        if let Some(desc) = payload.description.as_ref() {
            let _ = conn.execute(
                "UPDATE photos SET description = ?, modified_at = ? WHERE asset_id = ?",
                duckdb::params![desc, now, &asset_id],
            );
        }
    }
    // Reindex this asset for text search without blocking
    {
        let st = Arc::clone(&state);
        let uid = user.user_id.clone();
        let aid = asset_id.clone();
        tokio::spawn(async move {
            let _ = tokio::task::spawn_blocking(move || {
                if let Err(e) = crate::server::text_search::reindex_single_asset(&st, &uid, &aid) {
                    tracing::warn!("[SEARCH] reindex on metadata update failed: {}", e);
                }
            })
            .await;
        });
    }
    Ok(Json(serde_json::json!({ "ok": true })))
}

/// Update rating for a photo (0..5; 0 or null clears to NULL)
#[instrument(skip(state, headers, payload))]
pub async fn update_photo_rating(
    State(state): State<Arc<AppState>>,
    Path(asset_id): Path<String>,
    headers: HeaderMap,
    Json(payload): Json<UpdatePhotoRating>,
) -> Result<impl IntoResponse, AppError> {
    let user = get_user_from_headers(&headers, &state.auth_service).await?;
    if let Some(pg) = &state.pg_client {
        let mut new_rating_opt: Option<i32> = payload.rating;
        // Session capability diagnostics
        let tx_ro: Option<String> = pg
            .query_opt("SELECT current_setting('transaction_read_only', true)", &[])
            .await
            .ok()
            .flatten()
            .map(|row| row.get::<_, Option<String>>(0))
            .flatten();
        let is_recovery: Option<bool> = pg
            .query_opt("SELECT pg_is_in_recovery()", &[])
            .await
            .ok()
            .flatten()
            .map(|row| row.get::<_, bool>(0));
        let can_update: Option<bool> = pg
            .query_opt(
                "SELECT has_table_privilege(current_user, 'photos', 'UPDATE')",
                &[],
            )
            .await
            .ok()
            .flatten()
            .map(|row| row.get::<_, bool>(0));
        tracing::info!(
            target = "rating",
            "[RATING/DIAG] session ro={:?} recovery={:?} can_update_photos={:?}",
            tx_ro,
            is_recovery,
            can_update
        );
        // Pre-flight: existence diagnostics
        let diag_exact = pg
            .query_opt(
                "SELECT rating FROM photos WHERE organization_id=$1 AND user_id=$2 AND asset_id=$3",
                &[&user.organization_id, &user.user_id, &asset_id],
            )
            .await
            .ok()
            .flatten()
            .and_then(|row| row.get::<_, Option<i16>>(0));
        tracing::info!(
            target = "rating",
            "[RATING/DIAG] preflight exact org={} user={} asset={} rating_present={:?}",
            user.organization_id,
            user.user_id,
            asset_id,
            diag_exact
        );
        let diag_by_org = pg
            .query_opt(
                "SELECT id, user_id, rating FROM photos WHERE organization_id=$1 AND asset_id=$2",
                &[&user.organization_id, &asset_id],
            )
            .await
            .ok()
            .flatten()
            .map(|row| {
                (
                    row.get::<_, i32>(0),
                    row.get::<_, String>(1),
                    row.get::<_, Option<i16>>(2),
                )
            });
        if let Some((pid, uid, r)) = diag_by_org.as_ref() {
            tracing::info!(
                target = "rating",
                "[RATING/DIAG] preflight org+asset matched id={} user_id={} rating={:?}",
                pid,
                uid,
                r
            );
        } else {
            tracing::info!(
                target = "rating",
                "[RATING/DIAG] preflight org+asset found NO ROW"
            );
        }
        let diag_any = pg
            .query_opt(
                "SELECT organization_id, user_id FROM photos WHERE asset_id=$1",
                &[&asset_id],
            )
            .await
            .ok()
            .flatten()
            .map(|row| (row.get::<_, i32>(0), row.get::<_, String>(1)));
        if let Some((org_found, user_found)) = diag_any.as_ref() {
            tracing::info!(
                target = "rating",
                "[RATING/DIAG] preflight asset only exists at org={} user_id={}",
                org_found,
                user_found
            );
        } else {
            tracing::info!(
                target = "rating",
                "[RATING/DIAG] preflight asset not found anywhere"
            );
        }
        if let Some(r) = new_rating_opt {
            let clamped = r.max(0).min(5);
            new_rating_opt = if clamped == 0 { None } else { Some(clamped) };
        }
        // Execute update and confirm affected rows; if 0, fall back to org+asset match
        // Resolve target id first to avoid any subtle WHERE mismatches
        let target_id_row = pg
            .query_opt(
                "SELECT id FROM photos WHERE organization_id=$1 AND user_id=$2 AND asset_id=$3",
                &[&user.organization_id, &user.user_id, &asset_id],
            )
            .await
            .ok()
            .flatten()
            .map(|row| row.get::<_, i32>(0));
        let target_id = if let Some(pid) = target_id_row {
            Some(pid)
        } else {
            // Fall back to org+asset if user_id differs
            pg.query_opt(
                "SELECT id FROM photos WHERE organization_id=$1 AND asset_id=$2",
                &[&user.organization_id, &asset_id],
            )
            .await
            .ok()
            .flatten()
            .map(|row| row.get::<_, i32>(0))
        };
        tracing::info!(
            target = "rating",
            "[RATING/DIAG] target_id for update asset={} => {:?}",
            asset_id,
            target_id
        );

        if let Some(pid) = target_id {
            // Snapshot before update
            let before = pg
                .query_opt("SELECT rating FROM photos WHERE id = $1", &[&pid])
                .await
                .ok()
                .flatten()
                .and_then(|row| row.get::<_, Option<i16>>(0));
            tracing::info!(
                target = "rating",
                "[RATING/DIAG] before_update id={} rating={:?}",
                pid,
                before
            );
            if let Some(r) = new_rating_opt {
                let r16: i16 = (r as i16).clamp(0, 5);
                match pg
                    .execute("UPDATE photos SET rating = $1 WHERE id = $2", &[&r16, &pid])
                    .await
                {
                    Ok(n) => tracing::info!(
                        target = "rating",
                        "[RATING] update_by_id id={} asset={} affected={} set={}",
                        pid,
                        asset_id,
                        n,
                        r16
                    ),
                    Err(e) => tracing::error!(
                        target = "rating",
                        "[RATING/ERR] update_by_id failed id={} asset={} err={}",
                        pid,
                        asset_id,
                        e
                    ),
                }
            } else {
                match pg
                    .execute("UPDATE photos SET rating = NULL WHERE id = $1", &[&pid])
                    .await
                {
                    Ok(n) => tracing::info!(
                        target = "rating",
                        "[RATING] clear_by_id id={} asset={} affected={}",
                        pid,
                        asset_id,
                        n
                    ),
                    Err(e) => tracing::error!(
                        target = "rating",
                        "[RATING/ERR] clear_by_id failed id={} asset={} err={}",
                        pid,
                        asset_id,
                        e
                    ),
                }
            }
        } else {
            tracing::info!(
                target = "rating",
                "[RATING] no target row resolved for asset={} (org={} user={})",
                asset_id,
                user.organization_id,
                user.user_id
            );
        }
        tracing::info!(
            target = "rating",
            "[RATING] user={} asset={} rating={:?}",
            user.user_id,
            asset_id,
            new_rating_opt
        );
        // Read-back to confirm persisted value and return it
        let row_opt = pg
            .query_opt(
                "SELECT rating FROM photos WHERE organization_id=$1 AND asset_id=$2",
                &[&user.organization_id, &asset_id],
            )
            .await
            .ok()
            .flatten();
        let saved: Option<i16> = row_opt.and_then(|row| row.get::<_, Option<i16>>(0));
        tracing::info!(
            target = "rating",
            "[RATING/DIAG] post_update readback org={} asset={} rating_now={:?}",
            user.organization_id,
            asset_id,
            saved
        );
        return Ok(Json(json!({"ok": true, "rating": saved })));
    }
    let data_db = state.get_user_data_database(&user.user_id)?;
    let mut new_rating_opt: Option<i32> = payload.rating;
    // Normalize: clamp to 0..5, map 0 to NULL
    if let Some(r) = new_rating_opt {
        let clamped = r.max(0).min(5);
        if clamped == 0 {
            new_rating_opt = None;
        } else {
            new_rating_opt = Some(clamped);
        }
    }
    {
        let conn = data_db.lock();
        if let Some(r) = new_rating_opt {
            let _ = conn.execute(
                "UPDATE photos SET rating = ? WHERE asset_id = ?",
                duckdb::params![r as i32, &asset_id],
            );
            tracing::info!(
                target = "rating",
                "[RATING] user={} asset={} rating={}",
                user.user_id,
                asset_id,
                r
            );
        } else {
            let _ = conn.execute(
                "UPDATE photos SET rating = NULL WHERE asset_id = ?",
                duckdb::params![&asset_id],
            );
            tracing::info!(
                target = "rating",
                "[RATING] user={} asset={} rating=NULL",
                user.user_id,
                asset_id
            );
        }
    }
    Ok(Json(json!({"ok": true, "rating": new_rating_opt })))
}

/// Alias for `/api/media` that reuses list_photos with the same query shape
#[instrument(skip(state, headers))]
pub async fn list_media(
    State(state): State<Arc<AppState>>,
    Query(query): Query<PhotoListQuery>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, AppError> {
    // Delegate to the same logic as list_photos (keeps compatibility while we evolve the API)
    list_photos(State(state), Query(query), headers).await
}

#[derive(Debug, Serialize)]
pub struct MediaCounts {
    pub all: i64,
    pub photos: i64,
    pub videos: i64,
    pub locked: i64,
    pub locked_photos: i64,
    pub locked_videos: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub trash: Option<i64>,
}

/// Counts for segmented control under current basic filters (favorite/album)
#[instrument(skip(state, headers))]
pub async fn media_counts(
    State(state): State<Arc<AppState>>,
    Query(incoming): Query<PhotoListQuery>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, AppError> {
    let user = get_user_from_headers(&headers, &state.auth_service).await?;
    // Postgres path
    if let Some(pg) = &state.pg_client {
        let org_id = user.organization_id;
        // Apply minimal filters (favorite, is_video) if provided
        let fav_clause = if incoming.filter_favorite.unwrap_or(false) {
            " AND COALESCE(p.favorites,0) > 0"
        } else {
            ""
        };
        let include_trashed = incoming.include_trashed.unwrap_or(false);
        let trashed_only = incoming.filter_trashed_only.unwrap_or(false);
        let trash_clause = if trashed_only {
            " AND COALESCE(p.delete_time,0) > 0"
        } else if !include_trashed {
            " AND COALESCE(p.delete_time,0) = 0"
        } else {
            ""
        };
        let mut sql_all = format!(
            "SELECT COUNT(*) FROM photos p WHERE p.organization_id=$1 AND p.user_id=$2{}{} AND NOT (p.is_video=TRUE AND COALESCE(p.is_live_photo,FALSE)=TRUE)",
            fav_clause, trash_clause
        );
        let mut sql_photos = format!(
            "SELECT COUNT(*) FROM photos p WHERE p.organization_id=$1 AND p.user_id=$2 AND p.is_video=FALSE{}{}",
            fav_clause, trash_clause
        );
        let mut sql_videos = format!(
            "SELECT COUNT(*) FROM photos p WHERE p.organization_id=$1 AND p.user_id=$2 AND p.is_video=TRUE AND COALESCE(p.is_live_photo,FALSE)=FALSE{}{}",
            fav_clause, trash_clause
        );
        let sql_locked = format!(
            "SELECT COALESCE(SUM(CASE WHEN p.locked THEN 1 ELSE 0 END),0),
                    COALESCE(SUM(CASE WHEN p.locked AND p.is_video THEN 1 ELSE 0 END),0),
                    COALESCE(SUM(CASE WHEN p.locked AND NOT p.is_video THEN 1 ELSE 0 END),0)
             FROM photos p WHERE p.organization_id=$1 AND p.user_id=$2{} AND NOT (p.is_video=TRUE AND COALESCE(p.is_live_photo,FALSE)=TRUE)",
            trash_clause
        );
        let all: i64 = pg
            .query_one(&sql_all, &[&org_id, &user.user_id])
            .await
            .map(|r| r.get(0))
            .unwrap_or(0);
        let photos: i64 = pg
            .query_one(&sql_photos, &[&org_id, &user.user_id])
            .await
            .map(|r| r.get(0))
            .unwrap_or(0);
        let videos: i64 = pg
            .query_one(&sql_videos, &[&org_id, &user.user_id])
            .await
            .map(|r| r.get(0))
            .unwrap_or(0);
        let row_locked = pg
            .query_one(&sql_locked, &[&org_id, &user.user_id])
            .await
            .ok();
        let (locked, locked_videos, locked_photos) = if let Some(r) = row_locked {
            (r.get(0), r.get(1), r.get(2))
        } else {
            (0i64, 0i64, 0i64)
        };
        let trash: i64 = pg
            .query_one(
                "SELECT COUNT(*) FROM photos p WHERE p.organization_id=$1 AND p.user_id=$2 AND COALESCE(p.delete_time,0) > 0",
                &[&org_id, &user.user_id],
            )
            .await
            .map(|r| r.get(0))
            .unwrap_or(0);
        return Ok(Json(MediaCounts {
            all,
            photos,
            videos,
            locked,
            locked_photos,
            locked_videos,
            trash: Some(trash),
        }));
    }
    let data_db = state.get_user_data_database(&user.user_id)?;
    state.backfill_live_photo_video_flags(&user.user_id).await;

    // Resolve live album criteria if needed
    let mut query = incoming;
    if let Some(album_id) = query.album_id {
        let (is_live, crit_json) = {
            let conn = data_db.lock();
            let mut is_live = false;
            let mut crit_json: Option<String> = None;
            if let Ok(mut stmt) = conn.prepare(
                "SELECT COALESCE(is_live, FALSE), live_criteria FROM albums WHERE organization_id = ? AND id = ? LIMIT 1",
            ) {
                let row = stmt.query_row(duckdb::params![user.organization_id, album_id], |row| {
                    Ok::<(bool, Option<String>), duckdb::Error>((row.get(0)?, row.get(1).ok()))
                });
                if let Ok((flag, cj)) = row {
                    is_live = flag;
                    crit_json = cj;
                }
            }
            (is_live, crit_json)
        };
        if is_live {
            if let Some(cj) = crit_json {
                if let Ok(mut crit) = serde_json::from_str::<PhotoListQuery>(&cj) {
                    crit.album_id = None;
                    crit.album_subtree = None;
                    // Allow counts overrides not necessary; but honor sort doesn't matter
                    query = crit;
                }
            }
        }
    }

    // Build filtered FROM/WHERE (include favorites, album, faces, location, date, screenshot/live)
    let mut where_clauses: Vec<String> = Vec::new();
    // Always scope by organization and current owner user
    where_clauses.push(format!("p.organization_id = {}", user.organization_id));
    where_clauses.push(format!("p.user_id = '{}'", user.user_id.replace("'", "''")));
    // Hide Live Photo motion components (paired MOVs) from library views/counts.
    where_clauses
        .push("NOT (p.is_video = 1 AND COALESCE(p.is_live_photo, FALSE) = TRUE)".to_string());
    let mut joins: Vec<String> = Vec::new();
    if let Some(fav) = query.filter_favorite {
        if fav {
            where_clauses.push("p.favorites > 0".to_string());
        }
    }
    if let Some(minr) = query.filter_rating_min {
        if minr > 0 {
            where_clauses.push(format!("COALESCE(p.rating, 0) >= {}", minr.min(5)));
        }
    }
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
        // Client provides an end-of-day timestamp; treat it as inclusive
        where_clauses.push(format!("p.created_at <= {}", date_to));
    }
    if let Some(s) = query.filter_screenshot {
        where_clauses.push(format!("p.is_screenshot = {}", if s { 1 } else { 0 }));
        if s {
            where_clauses.push("p.is_video = 0".to_string());
        }
    }
    if let Some(l) = query.filter_live_photo {
        where_clauses.push(format!("p.is_live_photo = {}", l));
    }
    if let Some(ref ids_csv) = query.album_ids {
        // AND semantics
        let base_ids: Vec<i32> = ids_csv
            .split(',')
            .filter_map(|s| s.trim().parse::<i32>().ok())
            .collect();
        if !base_ids.is_empty() {
            let include_desc = query.album_subtree.unwrap_or(true);
            let conn = data_db.lock();
            for (idx, root_id) in base_ids.iter().enumerate() {
                let mut group: Vec<i32> = vec![*root_id];
                if include_desc {
                    if let Ok(mut stmt) = conn
                        .prepare("SELECT descendant_id FROM album_closure WHERE organization_id = ? AND ancestor_id = ?")
                    {
                        if let Ok(rows) = stmt.query_map(duckdb::params![user.organization_id, *root_id], |row| row.get::<_, i32>(0)) {
                            for r in rows {
                                if let Ok(id) = r {
                                    group.push(id);
                                }
                            }
                        }
                    }
                }
                group.sort();
                group.dedup();
                let inlist = group
                    .iter()
                    .map(|id| id.to_string())
                    .collect::<Vec<_>>()
                    .join(",");
                let alias = format!("ap{}", idx);
                joins.push(format!(
                    "INNER JOIN album_photos {} ON {}.organization_id = p.organization_id AND p.id = {}.photo_id AND {}.album_id IN ({})",
                    alias, alias, alias, alias, inlist
                ));
            }
        }
    } else if let Some(album_id) = query.album_id {
        joins.push("INNER JOIN album_photos ap ON ap.organization_id = p.organization_id AND p.id = ap.photo_id".to_string());
        // Default to include descendants when filtering by album
        if query.album_subtree.unwrap_or(true) {
            let ids = {
                let conn = data_db.lock();
                let mut collected: Vec<i32> = vec![album_id];
                if let Ok(mut stmt) =
                    conn.prepare("SELECT descendant_id FROM album_closure WHERE organization_id = ? AND ancestor_id = ?")
                {
                    let rows = match stmt.query_map(duckdb::params![user.organization_id, album_id], |row| row.get::<_, i32>(0)) {
                        Ok(rows) => rows,
                        Err(err) => return Err(AppError::from(err)),
                    };
                    for r in rows {
                        if let Ok(id) = r {
                            collected.push(id);
                        }
                    }
                }
                collected
            };
            let inlist = ids
                .iter()
                .map(|id| id.to_string())
                .collect::<Vec<_>>()
                .join(",");
            where_clauses.push(format!("ap.album_id IN ({})", inlist));
        } else {
            where_clauses.push(format!("ap.album_id = {}", album_id));
        }
    }
    if let Some(face_param) = &query.filter_faces {
        let ids: Vec<String> = face_param
            .split(',')
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .map(|s| s.to_string())
            .collect();
        if !ids.is_empty() {
            let embed_db = state.get_user_embedding_database(&user.user_id)?;
            let conn_e = embed_db.lock();
            let ids_list = ids
                .iter()
                .map(|s| format!("'{}'", s.replace("'", "''")))
                .collect::<Vec<_>>()
                .join(",");
            let org_id = user.organization_id;
            let user_id = user.user_id.replace("'", "''");
            let sql = match query.filter_faces_mode.as_deref() {
                Some("any") => format!(
                    "SELECT DISTINCT f.asset_id FROM faces_embed f JOIN photos dp ON dp.asset_id = f.asset_id WHERE dp.organization_id = {} AND dp.user_id = '{}' AND f.person_id IN ({})",
                    org_id, user_id, ids_list
                ),
                _ => format!(
                    "SELECT f.asset_id FROM faces_embed f JOIN photos dp ON dp.asset_id = f.asset_id WHERE dp.organization_id = {} AND dp.user_id = '{}' AND f.person_id IN ({}) GROUP BY f.asset_id HAVING COUNT(DISTINCT f.person_id) = {}",
                    org_id, user_id, ids_list, ids.len()
                ),
            };
            let mut asset_ids: Vec<String> = Vec::new();
            match conn_e.prepare(&sql) {
                Ok(mut stmt) => {
                    let rows = stmt.query_map([], |row| row.get::<_, String>(0))?;
                    for r in rows {
                        if let Ok(a) = r {
                            asset_ids.push(a);
                        }
                    }
                }
                Err(err) => {
                    tracing::warn!("[MEDIA_COUNTS] faces query prepare failed: {}. Retrying with refreshed embed connection...", err);
                    let embed_db2 = state
                        .multi_tenant_db
                        .as_ref()
                        .expect("user DB required in DuckDB mode")
                        .refresh_user_embedding_connection(&user.user_id)?;
                    let conn2 = embed_db2.lock();
                    let mut stmt = conn2.prepare(&sql)?;
                    let rows = stmt.query_map([], |row| row.get::<_, String>(0))?;
                    for r in rows {
                        if let Ok(a) = r {
                            asset_ids.push(a);
                        }
                    }
                }
            }
            if asset_ids.is_empty() {
                return Ok(Json(MediaCounts {
                    all: 0,
                    photos: 0,
                    videos: 0,
                    locked: 0,
                    locked_photos: 0,
                    locked_videos: 0,
                    trash: Some(0),
                }));
            }
            let inlist = asset_ids
                .iter()
                .map(|s| format!("'{}'", s.replace("'", "''")))
                .collect::<Vec<_>>()
                .join(",");
            where_clauses.push(format!("p.asset_id IN ({})", inlist));
        }
    }

    // Text query support for counts as well (same as list)
    if let Some(ref q) = query.q {
        let qtrim = q.trim();
        if !qtrim.is_empty() {
            let store = state.create_user_embedding_store(&user.user_id)?;
            let model_name = state.default_model.clone();
            let embedding = state
                .with_textual_encoder(Some(&model_name), |enc| enc.encode_text(qtrim))
                .ok_or_else(|| anyhow::anyhow!("Text encoder not available"))??;
            let results = store.search_combined(qtrim, embedding, 5000).await?;
            let ids: Vec<String> = results.into_iter().map(|r| r.asset_id).collect();
            if ids.is_empty() {
                return Ok(Json(MediaCounts {
                    all: 0,
                    photos: 0,
                    videos: 0,
                    locked: 0,
                    locked_photos: 0,
                    locked_videos: 0,
                    trash: Some(0),
                }));
            }
            let inlist = ids
                .into_iter()
                .map(|s| format!("'{}'", s.replace("'", "''")))
                .collect::<Vec<_>>()
                .join(",");
            where_clauses.push(format!("p.asset_id IN ({})", inlist));
        }
    }

    // Locked filtering: default exclude locked; support locked-only and include-locked
    if query.filter_locked_only.unwrap_or(false) {
        where_clauses.push("p.locked = 1".to_string());
    } else if !query.include_locked.unwrap_or(false) {
        where_clauses.push("p.locked = 0".to_string());
    }

    let include_trashed = query.include_trashed.unwrap_or(false);
    let trashed_only = query.filter_trashed_only.unwrap_or(false);
    if trashed_only {
        where_clauses.push("p.delete_time > 0".to_string());
    } else if !include_trashed {
        where_clauses.push("p.delete_time = 0".to_string());
    }

    let mut base = String::from("FROM photos p");
    for j in &joins {
        base.push(' ');
        base.push_str(j);
    }
    // No PIN gating; client holds UMK locally

    if !where_clauses.is_empty() {
        base.push_str(" WHERE ");
        base.push_str(&where_clauses.join(" AND "));
    }

    let conn = data_db.lock();
    let sql_all = format!("SELECT COUNT(*) {}", base);
    let sql_photos = format!(
        "SELECT COUNT(*) {} {}",
        base,
        if base.contains(" WHERE ") {
            " AND p.is_video = 0"
        } else {
            " WHERE p.is_video = 0"
        }
    );
    let sql_videos = format!(
        "SELECT COUNT(*) {} {}",
        base,
        if base.contains(" WHERE ") {
            " AND p.is_video = 1"
        } else {
            " WHERE p.is_video = 1"
        }
    );

    let all = conn
        .query_row(&sql_all, [], |row| row.get::<_, i64>(0))
        .unwrap_or(0);
    let photos = conn
        .query_row(&sql_photos, [], |row| row.get::<_, i64>(0))
        .unwrap_or(0);
    let videos = conn
        .query_row(&sql_videos, [], |row| row.get::<_, i64>(0))
        .unwrap_or(0);
    // Compute locked_count under same filters but ignoring the locked filter
    let mut base_locked = String::from("FROM photos p");
    for j in &joins {
        base_locked.push(' ');
        base_locked.push_str(j);
    }
    let where_wo_locked: Vec<String> = where_clauses
        .iter()
        .filter(|s| s.trim() != "p.locked = 0")
        .cloned()
        .collect();
    if !where_wo_locked.is_empty() {
        base_locked.push_str(" WHERE ");
        base_locked.push_str(&where_wo_locked.join(" AND "));
    }
    let sql_locked = format!(
        "SELECT COUNT(*) {} {}",
        base_locked,
        if base_locked.contains(" WHERE ") {
            " AND COALESCE(p.locked, FALSE) = TRUE"
        } else {
            " WHERE COALESCE(p.locked, FALSE) = TRUE"
        }
    );
    let locked = conn
        .query_row(&sql_locked, [], |row| row.get::<_, i64>(0))
        .unwrap_or(0);
    // And split locked into photos/videos
    let sql_locked_photos = format!(
        "SELECT COUNT(*) {} {}",
        base_locked,
        if base_locked.contains(" WHERE ") {
            " AND COALESCE(p.locked, FALSE) = TRUE AND p.is_video = 0"
        } else {
            " WHERE COALESCE(p.locked, FALSE) = TRUE AND p.is_video = 0"
        }
    );
    let sql_locked_videos = format!(
        "SELECT COUNT(*) {} {}",
        base_locked,
        if base_locked.contains(" WHERE ") {
            " AND COALESCE(p.locked, FALSE) = TRUE AND p.is_video = 1"
        } else {
            " WHERE COALESCE(p.locked, FALSE) = TRUE AND p.is_video = 1"
        }
    );
    let locked_photos = conn
        .query_row(&sql_locked_photos, [], |row| row.get::<_, i64>(0))
        .unwrap_or(0);
    let locked_videos = conn
        .query_row(&sql_locked_videos, [], |row| row.get::<_, i64>(0))
        .unwrap_or(0);
    let trash = conn
        .query_row(
            "SELECT COUNT(*) FROM photos WHERE organization_id = ? AND user_id = ? AND COALESCE(delete_time,0) > 0",
            duckdb::params![user.organization_id, &user.user_id],
            |row| row.get::<_, i64>(0),
        )
        .unwrap_or(0);
    Ok(Json(MediaCounts {
        all,
        photos,
        videos,
        locked,
        locked_photos,
        locked_videos,
        trash: Some(trash),
    }))
}

#[instrument(skip(state, headers))]
pub async fn debug_photos_count(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, AppError> {
    // Get authenticated user; return 401 instead of 500 for missing/invalid token
    let user = match get_user_from_headers(&headers, &state.auth_service).await {
        Ok(u) => u,
        Err(e) => {
            tracing::warn!("[DEBUG_PHOTOS_COUNT] auth failed: {}", e);
            return Ok((
                StatusCode::UNAUTHORIZED,
                Json(json!({"error":"unauthorized","reason": e.to_string()})),
            ));
        }
    };

    // Postgres mode: compute counts from PG tables
    if let Some(pg) = &state.pg_client {
        let org_id = user.organization_id;
        // Count rows for this user/org
        let row = pg
            .query_one(
                "SELECT COUNT(*) FROM photos WHERE organization_id=$1 AND user_id=$2",
                &[&org_id, &user.user_id],
            )
            .await
            .ok();
        let count: i64 = row.as_ref().map(|r| r.get::<_, i64>(0)).unwrap_or(0);
        // Sample a few asset_ids for debugging
        let mut sample: Vec<String> = Vec::new();
        if let Ok(rows) = pg
            .query(
                "SELECT asset_id FROM photos WHERE organization_id=$1 AND user_id=$2 ORDER BY id DESC LIMIT 5",
                &[&org_id, &user.user_id],
            )
            .await
        {
            for r in rows { sample.push(r.get::<_, String>(0)); }
        }
        let response = DebugPhotosCountResponse {
            user_id: user.user_id,
            db_path: String::from("postgres"),
            db_file: None,
            count,
            sample_asset_ids: sample,
        };
        let value = serde_json::to_value(&response).unwrap_or(json!({"count": count}));
        return Ok((StatusCode::OK, Json(value)));
    }

    // DuckDB mode: inspect on-disk DB for extra diagnostics
    let data_db = state.get_user_data_database(&user.user_id)?;
    let user_db_path = state.user_data_path(&user.user_id);
    let conn = data_db.lock();
    let db_file: Option<String> = {
        let mut stmt = conn.prepare("PRAGMA database_list")?;
        let mut file_opt: Option<String> = None;
        let rows = stmt.query_map([], |row| {
            let name: String = row.get(1)?;
            let file: String = row.get(2)?;
            Ok((name, file))
        })?;
        for r in rows {
            if let Ok((name, file)) = r {
                if name == "main" {
                    file_opt = Some(file);
                    break;
                }
            }
        }
        file_opt
    };
    let count: i64 = conn
        .query_row("SELECT COUNT(*) FROM photos", [], |row| {
            row.get::<_, i64>(0)
        })
        .unwrap_or(-1);
    let mut sample: Vec<String> = Vec::new();
    if count > 0 {
        if let Ok(mut stmt) = conn.prepare("SELECT asset_id FROM photos ORDER BY id DESC LIMIT 5") {
            if let Ok(rows) = stmt.query_map([], |row| row.get::<_, String>(0)) {
                for r in rows.flatten() {
                    sample.push(r);
                }
            }
        }
    }

    let response = DebugPhotosCountResponse {
        user_id: user.user_id,
        db_path: user_db_path.display().to_string(),
        db_file,
        count,
        sample_asset_ids: sample,
    };
    if logging::debug_enabled() {
        tracing::info!(
            "[DEBUG_PHOTOS_COUNT] user={}, db={}, count={}, sample_first={:?}",
            response.user_id,
            response.db_path,
            response.count,
            response.sample_asset_ids.get(0)
        );
    }
    let value = serde_json::to_value(&response).unwrap_or(json!({"count": count}));
    Ok((StatusCode::OK, Json(value)))
}

#[instrument(skip(state, headers))]
pub async fn get_photo(
    State(state): State<Arc<AppState>>,
    Path(photo_id): Path<i32>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, AppError> {
    let user = get_user_from_headers(&headers, &state.auth_service).await?;

    let db = state
        .multi_tenant_db
        .as_ref()
        .ok_or_else(|| AppError(anyhow::anyhow!("Albums not supported in Postgres mode yet")))?
        .clone();
    let photo_service = PhotoService::new(db);
    let photo = photo_service.get_photo(&user.user_id, photo_id).await?;

    Ok(Json(photo))
}

#[instrument(
    skip(state, request),
    fields(
        asset_id = %asset_id,
        method = %request.method(),
        uri = %request.uri(),
        range = ?request.headers().get(header::RANGE),
        ua = ?request.headers().get(header::USER_AGENT),
    )
)]
pub async fn serve_image(
    State(state): State<Arc<AppState>>,
    Path(asset_id): Path<String>,
    request: Request,
) -> Result<axum::response::Response, AppError> {
    // Get authenticated user
    let headers = request.headers();
    let user = get_user_from_headers(headers, &state.auth_service).await?;
    let mut pin_set_cookie: Option<String> = None;
    // Read original file path from DB (PG or DuckDB)
    //
    // Note: `mime_type` is not always populated (especially for older ingests). For video playback to
    // start quickly on clients (AVPlayer), we want HTTP Range support. We therefore also read
    // `is_video` and use `ServeFile` when appropriate even if the stored `mime_type` is missing.
    let photo_data: Option<(
        String,
        Option<String>,
        bool,
        bool,
        Option<i64>,
        Option<i64>,
        bool,
        Option<String>,
    )> = if let Some(pg) = &state.pg_client {
        let row = pg
            .query_opt(
                "SELECT path, mime_type, COALESCE(is_video, FALSE), COALESCE(locked, FALSE), size, duration_ms, COALESCE(has_gain_map, FALSE), hdr_kind FROM photos WHERE organization_id=$1 AND user_id=$2 AND asset_id=$3 LIMIT 1",
                &[&user.organization_id, &user.user_id, &asset_id],
            )
            .await
            .map_err(|e| AppError(anyhow::anyhow!(e.to_string())))?;
        row.map(|r| {
            (
                r.get::<_, String>(0),
                r.get::<_, Option<String>>(1),
                r.get::<_, bool>(2),
                r.get::<_, bool>(3),
                r.get::<_, Option<i64>>(4),
                r.get::<_, Option<i64>>(5),
                r.get::<_, bool>(6),
                r.get::<_, Option<String>>(7),
            )
        })
    } else {
        let data_db = state.get_user_data_database(&user.user_id)?;
        let conn = data_db.lock();
        let mut stmt = conn.prepare(
            "SELECT path, mime_type, COALESCE(is_video, FALSE), COALESCE(locked, FALSE), size, duration_ms, COALESCE(has_gain_map, FALSE), hdr_kind FROM photos WHERE organization_id = ? AND user_id = ? AND asset_id = ? LIMIT 1",
        )?;
        stmt.query_row(
            duckdb::params![user.organization_id, &user.user_id, &asset_id],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1).ok(),
                    row.get::<_, bool>(2)?,
                    row.get::<_, bool>(3)?,
                    row.get::<_, Option<i64>>(4).ok().flatten(),
                    row.get::<_, Option<i64>>(5).ok().flatten(),
                    row.get::<_, bool>(6)?,
                    row.get::<_, Option<String>>(7).ok().flatten(),
                ))
            },
        )
        .ok()
    }; // Database lock released here

    if let Some((
        path,
        mime_type_opt,
        is_video,
        is_locked,
        size_opt,
        duration_ms_opt,
        has_gain_map,
        hdr_kind,
    )) = photo_data
    {
        if should_ignore_served_media_path(StdPath::new(&path)) {
            return Ok((StatusCode::NOT_FOUND, "not found").into_response());
        }
        if is_locked {
            // Serve encrypted container bytes (no Range, generic content type).
            // Some rows can hold stale `photos.path`; probe canonical orig and
            // locked thumbnail paths as fallbacks before returning 500.
            let db_path = std::path::PathBuf::from(&path);
            let fallback_orig = state.locked_original_path_for(&user.user_id, &asset_id);
            let fallback_thumb = state.locked_thumb_path_for(&user.user_id, &asset_id);
            let mut candidates: Vec<(std::path::PathBuf, &'static str)> = Vec::with_capacity(3);
            candidates.push((
                db_path.clone(),
                if path.ends_with("_t.pae3") {
                    "db-path-thumb"
                } else {
                    "db-path-orig"
                },
            ));
            if fallback_orig != db_path {
                candidates.push((fallback_orig.clone(), "fallback-orig"));
            }
            if fallback_thumb != db_path && fallback_thumb != fallback_orig {
                candidates.push((fallback_thumb.clone(), "fallback-thumb"));
            }

            let mut locked_source = "db-path-orig";
            let mut bytes: Option<Vec<u8>> = None;
            let mut failure_notes: Vec<String> = Vec::with_capacity(candidates.len());
            for (candidate, source) in candidates {
                match tokio::fs::read(&candidate).await {
                    Ok(b) => {
                        locked_source = source;
                        bytes = Some(b);
                        break;
                    }
                    Err(err) => {
                        failure_notes.push(format!(
                            "{}: {} ({})",
                            source,
                            candidate.display(),
                            err
                        ));
                    }
                }
            }
            let bytes = bytes.ok_or_else(|| {
                anyhow::anyhow!(
                    "Failed to read encrypted container for asset {}. {}",
                    asset_id,
                    failure_notes.join(" | ")
                )
            })?;
            if locked_source != "db-path-orig" && locked_source != "db-path-thumb" {
                tracing::warn!(
                    "[IMAGE] Serving locked asset via fallback source (asset_id={}, source={}, db_path={})",
                    asset_id,
                    locked_source,
                    path
                );
            }
            let mut headers_map = HeaderMap::new();
            headers_map.insert(
                header::CONTENT_TYPE,
                axum::http::HeaderValue::from_static("application/octet-stream"),
            );
            if let Ok(hv) = axum::http::HeaderValue::from_str(locked_source) {
                headers_map.insert(header::HeaderName::from_static("x-locked-source"), hv);
            }
            return Ok((headers_map, bytes).into_response());
        }
        // Decide on-the-fly AVIF for HEIC if requested or non-Safari
        let query = request.uri().query().unwrap_or("");
        let wants_avif_param = query_has_format_param(query, "avif");
        let wants_heic_param = query_has_format_param(query, "heic");
        let wants_original_param = query_has_format_param(query, "original");
        let ua = request
            .headers()
            .get(header::USER_AGENT)
            .and_then(|v| v.to_str().ok())
            .unwrap_or("");
        let is_safari = ua.contains("Safari")
            && !ua.contains("Chrome")
            && !ua.contains("Chromium")
            && !ua.contains("CriOS")
            && !ua.contains("FxiOS")
            && !ua.contains("Edg");
        let accept_hdr = request
            .headers()
            .get(header::ACCEPT)
            .and_then(|v| v.to_str().ok())
            .unwrap_or("");
        let accepts_avif = accept_hdr.contains("image/avif");
        let accepts_heic = accept_hdr.contains("image/heic");

        // Extension is used as a fallback for `mime_type` and to ensure video responses advertise a
        // video content-type (important for AVPlayer progressive playback).
        let ext_lc = StdPath::new(&path)
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("")
            .to_lowercase();

        let orig_content_type = mime_type_opt.unwrap_or_else(|| {
            crate::photos::mime_type_for_extension(ext_lc.as_str())
                .unwrap_or("application/octet-stream")
                .to_string()
        });
        if has_gain_map {
            tracing::info!(
                target: "upload",
                "[HDR] serve_image asset_id={} kind={} mime={} wants_original={} wants_heic={} wants_avif={} accepts_heic={} accepts_avif={}",
                asset_id,
                hdr_kind.as_deref().unwrap_or("unknown"),
                orig_content_type,
                wants_original_param,
                wants_heic_param,
                wants_avif_param,
                accepts_heic,
                accepts_avif
            );
        }

        let video_content_type = if is_video && !orig_content_type.starts_with("video/") {
            match ext_lc.as_str() {
                "mov" => "video/quicktime".to_string(),
                "mp4" | "m4v" => "video/mp4".to_string(),
                "avi" => "video/x-msvideo".to_string(),
                "mkv" => "video/x-matroska".to_string(),
                "webm" => "video/webm".to_string(),
                // Avoid lying about the container/codec; let clients handle unknown types explicitly.
                _ => "application/octet-stream".to_string(),
            }
        } else {
            orig_content_type.clone()
        };

        // If source is HEIC, decide whether to serve AVIF or original HEIC.
        // Preference order:
        //   - format=heic query forces HEIC
        //   - format=avif query forces AVIF
        //   - If client Accept includes image/heic, prefer HEIC even if not Safari
        //   - Otherwise, for non‑Safari or clients that explicitly Accept AVIF, serve AVIF
        let prefer_avif = if wants_heic_param {
            false
        } else if wants_avif_param {
            true
        } else if accepts_avif {
            true
        } else if !is_safari && !accepts_heic {
            true
        } else {
            false
        };
        if !wants_original_param && orig_content_type == "image/heic" && prefer_avif {
            let avif_path = state.avif_path_for(&user.user_id, &asset_id);
            if !avif_path.exists() {
                if let Some(parent) = avif_path.parent() {
                    let _ = std::fs::create_dir_all(parent);
                }
                generate_avif(&path, &avif_path).map_err(|e| {
                    anyhow::anyhow!("Failed to generate AVIF for {}: {}", asset_id, e)
                })?;
            }
            let etag = tokio::fs::metadata(&avif_path)
                .await
                .ok()
                .and_then(|m| weak_etag_from_metadata(&m));
            if let Some(et) = etag.as_deref() {
                if if_none_match_allows_304(request.headers(), et) {
                    let mut headers_map = HeaderMap::new();
                    headers_map.insert(
                        header::CONTENT_TYPE,
                        axum::http::HeaderValue::from_static("image/avif"),
                    );
                    add_private_cache_headers(&mut headers_map, Some(et));
                    if let Some(sc) = &pin_set_cookie {
                        headers_map.insert(
                            header::SET_COOKIE,
                            axum::http::HeaderValue::from_str(sc).unwrap(),
                        );
                    }
                    return Ok((StatusCode::NOT_MODIFIED, headers_map).into_response());
                }
            }
            let bytes = tokio::fs::read(&avif_path).await.map_err(|e| {
                anyhow::anyhow!("Failed to read AVIF file {}: {}", avif_path.display(), e)
            })?;
            let mut headers_map = HeaderMap::new();
            headers_map.insert(
                header::CONTENT_TYPE,
                axum::http::HeaderValue::from_static("image/avif"),
            );
            add_private_cache_headers(&mut headers_map, etag.as_deref());
            if let Some(sc) = &pin_set_cookie {
                headers_map.insert(
                    header::SET_COOKIE,
                    axum::http::HeaderValue::from_str(sc).unwrap(),
                );
            }
            return Ok((headers_map, bytes).into_response());
        }

        match raw_image_serve_mode(&orig_content_type, query, prefer_avif) {
            RawImageServeMode::DerivedAvif | RawImageServeMode::DerivedJpeg => {
                let try_avif_first = matches!(
                    raw_image_serve_mode(&orig_content_type, query, prefer_avif),
                    RawImageServeMode::DerivedAvif
                );
                if try_avif_first {
                    let avif_path = state.avif_path_for(&user.user_id, &asset_id);
                    if !avif_path.exists() {
                        if let Some(parent) = avif_path.parent() {
                            let _ = std::fs::create_dir_all(parent);
                        }
                        if let Err(err) = generate_avif(&path, &avif_path) {
                            tracing::warn!(
                                target: "upload",
                                "[RAW] Failed to generate AVIF preview for asset_id={} path={} err={}",
                                asset_id,
                                path,
                                err
                            );
                        } else {
                            tracing::info!(
                                target: "upload",
                                "[RAW] Generated AVIF preview for asset_id={} path={}",
                                asset_id,
                                path
                            );
                        }
                    }
                    if avif_path.exists() {
                        let etag = tokio::fs::metadata(&avif_path)
                            .await
                            .ok()
                            .and_then(|m| weak_etag_from_metadata(&m));
                        if let Some(et) = etag.as_deref() {
                            if if_none_match_allows_304(request.headers(), et) {
                                let mut headers_map = HeaderMap::new();
                                headers_map.insert(
                                    header::CONTENT_TYPE,
                                    axum::http::HeaderValue::from_static("image/avif"),
                                );
                                add_private_cache_headers(&mut headers_map, Some(et));
                                if let Some(sc) = &pin_set_cookie {
                                    headers_map.insert(
                                        header::SET_COOKIE,
                                        axum::http::HeaderValue::from_str(sc).unwrap(),
                                    );
                                }
                                return Ok((StatusCode::NOT_MODIFIED, headers_map).into_response());
                            }
                        }
                        let bytes = tokio::fs::read(&avif_path).await.map_err(|e| {
                            anyhow::anyhow!(
                                "Failed to read AVIF file {}: {}",
                                avif_path.display(),
                                e
                            )
                        })?;
                        let mut headers_map = HeaderMap::new();
                        headers_map.insert(
                            header::CONTENT_TYPE,
                            axum::http::HeaderValue::from_static("image/avif"),
                        );
                        add_private_cache_headers(&mut headers_map, etag.as_deref());
                        if let Some(sc) = &pin_set_cookie {
                            headers_map.insert(
                                header::SET_COOKIE,
                                axum::http::HeaderValue::from_str(sc).unwrap(),
                            );
                        }
                        return Ok((headers_map, bytes).into_response());
                    }
                }

                let jpeg_path = state.image_preview_jpeg_path_for(&user.user_id, &asset_id);
                let refresh_placeholder =
                    jpeg_path.exists() && cache_matches_raw_placeholder_jpeg(&jpeg_path, 2560);
                if !jpeg_path.exists() || refresh_placeholder {
                    generate_display_jpeg(&path, &jpeg_path, 2560).map_err(|e| {
                        anyhow::anyhow!("Failed to generate JPEG preview for {}: {}", asset_id, e)
                    })?;
                    tracing::info!(
                        target: "upload",
                        "[RAW] Generated JPEG preview for asset_id={} path={} refresh_placeholder={}",
                        asset_id,
                        path,
                        refresh_placeholder
                    );
                }

                let etag = tokio::fs::metadata(&jpeg_path)
                    .await
                    .ok()
                    .and_then(|m| weak_etag_from_metadata(&m));
                if let Some(et) = etag.as_deref() {
                    if if_none_match_allows_304(request.headers(), et) {
                        let mut headers_map = HeaderMap::new();
                        headers_map.insert(
                            header::CONTENT_TYPE,
                            axum::http::HeaderValue::from_static("image/jpeg"),
                        );
                        add_private_cache_headers(&mut headers_map, Some(et));
                        if let Some(sc) = &pin_set_cookie {
                            headers_map.insert(
                                header::SET_COOKIE,
                                axum::http::HeaderValue::from_str(sc).unwrap(),
                            );
                        }
                        return Ok((StatusCode::NOT_MODIFIED, headers_map).into_response());
                    }
                }

                let bytes = tokio::fs::read(&jpeg_path).await.map_err(|e| {
                    anyhow::anyhow!("Failed to read JPEG preview {}: {}", jpeg_path.display(), e)
                })?;
                let mut headers_map = HeaderMap::new();
                headers_map.insert(
                    header::CONTENT_TYPE,
                    axum::http::HeaderValue::from_static("image/jpeg"),
                );
                add_private_cache_headers(&mut headers_map, etag.as_deref());
                if let Some(sc) = &pin_set_cookie {
                    headers_map.insert(
                        header::SET_COOKIE,
                        axum::http::HeaderValue::from_str(sc).unwrap(),
                    );
                }
                return Ok((headers_map, bytes).into_response());
            }
            RawImageServeMode::OriginalBytes | RawImageServeMode::NotRaw => {}
        }

        // If this is a video, use ServeFile to support Range seeking / progressive playback.
        // We treat `is_video` as authoritative even if the stored `mime_type` is missing or generic.
        if is_video || orig_content_type.starts_with("video/") {
            let is_apple = is_apple_core_media_user_agent(ua);

            // Heuristic: very high bitrate videos (or huge files when duration is unknown) commonly
            // stall on mobile networks. For AppleCoreMedia clients we generate a lower‑bitrate MP4
            // proxy for smoother playback.
            let mut size_bytes = size_opt;
            if is_apple && size_bytes.is_none() {
                if let Ok(meta) = tokio::fs::metadata(&path).await {
                    size_bytes = Some(meta.len() as i64);
                }
            }
            let avg_mbps: Option<f64> = match (size_bytes, duration_ms_opt) {
                (Some(sz), Some(ms)) if sz > 0 && ms > 0 => {
                    let secs = (ms as f64) / 1000.0;
                    Some((sz as f64 * 8.0) / (secs * 1_000_000.0))
                }
                _ => None,
            };
            let needs_stream_proxy = is_apple
                && avg_mbps
                    .map(|mbps| mbps > 20.0)
                    .unwrap_or_else(|| size_bytes.unwrap_or(0) > 400 * 1024 * 1024);

            if needs_stream_proxy {
                match ensure_ios_stream_mp4_proxy(
                    state.as_ref(),
                    &user.user_id,
                    &asset_id,
                    StdPath::new(&path),
                )
                .await
                {
                    Ok(proxy_path) => {
                        info!(
                            "Serving iOS streaming MP4 proxy for user {}. asset_id: {}, source: {}, proxy: {}, avg_mbps={:?}",
                            user.user_id,
                            asset_id,
                            path,
                            proxy_path.display(),
                            avg_mbps
                        );
                        let svc = ServeFile::new(proxy_path);
                        let mut resp = svc.oneshot(request).await.unwrap();
                        resp.headers_mut().insert(
                            header::CONTENT_TYPE,
                            axum::http::HeaderValue::from_static("video/mp4"),
                        );
                        resp.headers_mut().insert(
                            header::ACCEPT_RANGES,
                            axum::http::HeaderValue::from_static("bytes"),
                        );
                        if let Some(sc) = &pin_set_cookie {
                            resp.headers_mut().insert(
                                header::SET_COOKIE,
                                axum::http::HeaderValue::from_str(sc).unwrap(),
                            );
                        }
                        return Ok(resp.into_response());
                    }
                    Err(e) => {
                        tracing::warn!(
                            "Failed to generate iOS streaming MP4 proxy for asset_id={} path={} err={}",
                            asset_id,
                            path,
                            e
                        );
                    }
                }
            }

            // iOS AVPlayer has limited container support. When the source is an unsupported container
            // (commonly AVI/MKV/WebM), playback can stall on the first frame even though Range
            // requests succeed. For AppleCoreMedia clients we generate a cached MP4 proxy and serve
            // that instead.
            if is_apple && !is_ios_supported_container_ext(ext_lc.as_str()) {
                match ensure_ios_mp4_proxy(
                    state.as_ref(),
                    &user.user_id,
                    &asset_id,
                    StdPath::new(&path),
                )
                .await
                {
                    Ok(proxy_path) => {
                        info!(
                            "Serving iOS MP4 proxy for user {}. asset_id: {}, source: {}, proxy: {}",
                            user.user_id,
                            asset_id,
                            path,
                            proxy_path.display()
                        );
                        let svc = ServeFile::new(proxy_path);
                        let mut resp = svc.oneshot(request).await.unwrap();
                        resp.headers_mut().insert(
                            header::CONTENT_TYPE,
                            axum::http::HeaderValue::from_static("video/mp4"),
                        );
                        resp.headers_mut().insert(
                            header::ACCEPT_RANGES,
                            axum::http::HeaderValue::from_static("bytes"),
                        );
                        if let Some(sc) = &pin_set_cookie {
                            resp.headers_mut().insert(
                                header::SET_COOKIE,
                                axum::http::HeaderValue::from_str(sc).unwrap(),
                            );
                        }
                        return Ok(resp.into_response());
                    }
                    Err(e) => {
                        tracing::warn!(
                            "Failed to generate iOS MP4 proxy for asset_id={} path={} err={}",
                            asset_id,
                            path,
                            e
                        );
                        // Fall through to serve original bytes; client may still fail to play
                        // unsupported containers, but this preserves behavior when ffmpeg is missing.
                    }
                }
            }
            info!(
                "Streaming video with Range support for user {}. asset_id: {}, path: {}",
                user.user_id, asset_id, path
            );
            let svc = ServeFile::new(path.clone());
            let mut resp = svc.oneshot(request).await.unwrap();
            // Always set content-type for videos. This is important for AVPlayer to treat the response
            // as media (and not a generic download), and for consistent behavior across platforms.
            resp.headers_mut().insert(
                header::CONTENT_TYPE,
                axum::http::HeaderValue::from_str(&video_content_type).unwrap_or_else(|_| {
                    axum::http::HeaderValue::from_static("application/octet-stream")
                }),
            );
            // Advertise byte ranges
            resp.headers_mut().insert(
                header::ACCEPT_RANGES,
                axum::http::HeaderValue::from_static("bytes"),
            );
            if let Some(sc) = &pin_set_cookie {
                resp.headers_mut().insert(
                    header::SET_COOKIE,
                    axum::http::HeaderValue::from_str(sc).unwrap(),
                );
            }
            return Ok(resp.into_response());
        }

        // Else serve original bytes (images)
        let etag = tokio::fs::metadata(&path)
            .await
            .ok()
            .and_then(|m| weak_etag_from_metadata(&m));
        if let Some(et) = etag.as_deref() {
            if if_none_match_allows_304(request.headers(), et) {
                let mut headers_map = HeaderMap::new();
                headers_map.insert(
                    header::CONTENT_TYPE,
                    axum::http::HeaderValue::from_str(&orig_content_type).unwrap_or_else(|_| {
                        axum::http::HeaderValue::from_static("application/octet-stream")
                    }),
                );
                add_private_cache_headers(&mut headers_map, Some(et));
                if let Some(sc) = &pin_set_cookie {
                    headers_map.insert(
                        header::SET_COOKIE,
                        axum::http::HeaderValue::from_str(sc).unwrap(),
                    );
                }
                return Ok((StatusCode::NOT_MODIFIED, headers_map).into_response());
            }
        }
        let bytes = tokio::fs::read(&path)
            .await
            .map_err(|e| anyhow::anyhow!("Failed to read image file {}: {}", path, e))?;

        let mut effective_content_type = orig_content_type.clone();
        if orig_content_type.starts_with("image/")
            && !looks_like_declared_image(&orig_content_type, &bytes)
        {
            if let Some(detected) = sniff_image_content_type(&bytes) {
                tracing::warn!(
                    "Image MIME mismatch asset_id={} path={} declared_ct={} detected_ct={} (serving detected)",
                    asset_id,
                    path,
                    orig_content_type,
                    detected
                );
                effective_content_type = detected.to_string();
            } else {
                tracing::warn!(
                    "Refusing to serve invalid image bytes asset_id={} path={} ct={}",
                    asset_id,
                    path,
                    orig_content_type
                );
                return Ok((StatusCode::UNSUPPORTED_MEDIA_TYPE, "invalid image").into_response());
            }
        }

        info!(
            "Serving image for user {} from photos table path. asset_id: {}, path: {}",
            user.user_id, asset_id, path
        );

        let mut headers_map = HeaderMap::new();
        headers_map.insert(
            header::CONTENT_TYPE,
            axum::http::HeaderValue::from_str(&effective_content_type).unwrap_or_else(|_| {
                axum::http::HeaderValue::from_static("application/octet-stream")
            }),
        );
        add_private_cache_headers(&mut headers_map, etag.as_deref());
        if let Some(sc) = &pin_set_cookie {
            headers_map.insert(
                header::SET_COOKIE,
                axum::http::HeaderValue::from_str(sc).unwrap(),
            );
        }
        return Ok((headers_map, bytes).into_response());
    }

    // Not found in photos table
    Err(anyhow::anyhow!(
        "Image not found for asset_id: {} (user {})",
        asset_id,
        user.user_id
    )
    .into())
}

#[instrument(skip(state, headers))]
pub async fn serve_thumbnail(
    State(state): State<Arc<AppState>>,
    Path(asset_id): Path<String>,
    headers: HeaderMap,
) -> Result<Response, AppError> {
    tracing::info!("[THUMBNAIL] Request START asset_id={}", asset_id);
    // Identify user
    let user = get_user_from_headers(&headers, &state.auth_service).await?;
    tracing::info!(
        "[THUMBNAIL] User authenticated asset_id={} user_id={}",
        asset_id,
        user.user_id
    );

    // Decide cache path based on media type and enforce PIN for locked assets
    let mut pin_set_cookie: Option<String> = None;
    let (orig_path, is_video, is_locked): (String, bool, bool) = if let Some(pg) = &state.pg_client
    {
        let row = pg
            .query_opt(
                "SELECT path, is_video, COALESCE(locked, FALSE) FROM photos WHERE organization_id=$1 AND user_id=$2 AND asset_id=$3 LIMIT 1",
                &[&user.organization_id, &user.user_id, &asset_id],
            )
            .await
            .map_err(|e| AppError(anyhow::anyhow!(e.to_string())))?;
        if let Some(r) = row {
            (
                r.get::<_, String>(0),
                r.get::<_, bool>(1),
                r.get::<_, bool>(2),
            )
        } else {
            error!(
                "[THUMBNAIL] Asset not found (PG) asset_id={}, user={}",
                asset_id, user.user_id
            );
            return Err(AppError(anyhow!("Asset not found")));
        }
    } else {
        // FIX: Use semaphore + spawn_blocking to prevent blocking Tokio threads
        // DuckDB's Mutex::lock() is BLOCKING, which can cause Tokio threads to stall.
        let _permit = state
            .duckdb_semaphore
            .acquire()
            .await
            .map_err(|e| AppError(anyhow::anyhow!("Semaphore acquire failed: {}", e)))?;

        let user_id_clone = user.user_id.clone();
        let org_id_clone = user.organization_id.clone();
        let asset_id_clone = asset_id.clone();
        let state_clone = state.clone();

        // Move entire DB operation to blocking thread to avoid stalling Tokio
        tokio::task::spawn_blocking(move || {
            let data_db = state_clone.get_user_data_database(&user_id_clone)?;
            let conn = data_db.lock();
            let mut stmt = conn.prepare(
                "SELECT path, is_video, COALESCE(locked, FALSE) FROM photos WHERE organization_id = ? AND user_id = ? AND asset_id = ? LIMIT 1",
            )?;
            let row = stmt
                .query_row(duckdb::params![org_id_clone, &user_id_clone, &asset_id_clone], |row| {
                    Ok((row.get::<_, String>(0)?, row.get::<_, bool>(1)?, row.get::<_, bool>(2)?))
                })
                .ok();
            if let Some((p, v, l)) = row {
                Ok((p, v, l))
            } else {
                error!("[THUMBNAIL] Asset not found for asset_id={}, user={}", asset_id_clone, user_id_clone);
                Err(AppError(anyhow!("Asset not found")))
            }
        }).await
        .map_err(|e| AppError(anyhow::anyhow!("Blocking task failed: {}", e)))??
    };
    tracing::info!(
        "[THUMBNAIL] DB query complete asset_id={} video={} locked={}",
        asset_id,
        is_video,
        is_locked
    );

    if is_locked {
        // Serve encrypted thumbnail container directly; if missing, fall back to encrypted original
        let locked_thumb = state.locked_thumb_path_for(&user.user_id, &asset_id);
        let mut locked_path = locked_thumb.clone();
        let bytes = match std::fs::read(&locked_thumb) {
            Ok(b) => b,
            Err(e1) => {
                // Noisy but non-fatal — we will fall back to the locked original if present
                tracing::warn!(
                    "[THUMBNAIL] Failed to read locked thumb (asset_id={}, path={}): {}",
                    asset_id,
                    locked_thumb.display(),
                    e1
                );
                // Fallback: try encrypted original; better to show something than 500
                let locked_orig = state.locked_original_path_for(&user.user_id, &asset_id);
                match std::fs::read(&locked_orig) {
                    Ok(b) => {
                        locked_path = locked_orig;
                        b
                    }
                    Err(e2) => {
                        error!(
                            "[THUMBNAIL] Fallback to locked original also failed (asset_id={}, path={}): {}",
                            asset_id,
                            locked_orig.display(),
                            e2
                        );
                        return Err(AppError(anyhow!(e2)));
                    }
                }
            }
        };
        let mut hm = HeaderMap::new();
        hm.insert(
            header::CONTENT_TYPE,
            axum::http::HeaderValue::from_static("application/octet-stream"),
        );
        // Include a small hint header to aid diagnostics
        hm.insert(
            header::HeaderName::from_static("x-locked-source"),
            axum::http::HeaderValue::from_str(if locked_path.ends_with("_t.pae3") {
                "thumb"
            } else {
                "orig"
            })
            .unwrap_or_else(|_| axum::http::HeaderValue::from_static("unknown")),
        );
        // Cache encrypted payloads with mandatory revalidation.
        add_private_cache_headers(&mut hm, None);
        return Ok((hm, bytes).into_response());
    };

    let cache_path = if is_video {
        state.poster_path_for(&user.user_id, &asset_id)
    } else {
        state.thumbnail_path_for(&user.user_id, &asset_id)
    };

    let refresh_raw_placeholder = !is_video
        && cache_path.exists()
        && is_raw_still_path(&orig_path)
        && cache_matches_raw_placeholder_webp(&cache_path, 512);
    if !cache_path.exists() || refresh_raw_placeholder {
        debug!(
            "[THUMBNAIL] Cache {} for asset_id={}, is_video={}, cache_path={}",
            if refresh_raw_placeholder {
                "placeholder refresh"
            } else {
                "miss"
            },
            asset_id,
            is_video,
            cache_path.display()
        );
        if let Some(parent) = cache_path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let orig_path_cloned = orig_path.clone();
        let cache_path_cloned = cache_path.clone();
        let generate_result = tokio::task::spawn_blocking(move || {
            if is_video {
                generate_video_poster(&orig_path_cloned, &cache_path_cloned)
            } else {
                generate_thumbnail(&orig_path_cloned, &cache_path_cloned)
            }
        })
        .await
        .map_err(|e| AppError(anyhow!(format!("thumbnail task join error: {}", e))))?;
        if let Err(e) = generate_result {
            error!(
                "[THUMBNAIL] Failed to generate {} (asset_id={}, path={}, cache={}): {}",
                if is_video {
                    "video poster"
                } else {
                    "thumbnail"
                },
                asset_id,
                orig_path,
                cache_path.display(),
                e
            );
            return Err(AppError(anyhow!(
                "Failed to generate {} for {}: {}",
                if is_video {
                    "video poster"
                } else {
                    "thumbnail"
                },
                asset_id,
                e
            )));
        }
    }

    // Conditional GET: if cached and unchanged, let the browser reuse its cached body.
    let etag = std::fs::metadata(&cache_path)
        .ok()
        .and_then(|m| weak_etag_from_metadata(&m));
    if let Some(et) = etag.as_deref() {
        if if_none_match_allows_304(&headers, et) {
            let mut hm = HeaderMap::new();
            hm.insert(
                header::CONTENT_TYPE,
                axum::http::HeaderValue::from_static("image/webp"),
            );
            add_private_cache_headers(&mut hm, Some(et));
            return Ok((StatusCode::NOT_MODIFIED, hm).into_response());
        }
    }

    let bytes = std::fs::read(&cache_path).map_err(|e| {
        error!(
            "[THUMBNAIL] Failed to read cache file (asset_id={}, cache={}): {}",
            asset_id,
            cache_path.display(),
            e
        );
        AppError(anyhow!(e))
    })?;
    let mut hm = HeaderMap::new();
    hm.insert(
        header::CONTENT_TYPE,
        axum::http::HeaderValue::from_static("image/webp"),
    );
    add_private_cache_headers(&mut hm, etag.as_deref());
    Ok((hm, bytes).into_response())
}

fn generate_thumbnail(
    original_path: &str,
    thumb_path: &std::path::Path,
) -> Result<(), anyhow::Error> {
    use std::fs;
    use std::io::Write;

    // Ensure parent dirs
    if let Some(parent) = thumb_path.parent() {
        fs::create_dir_all(parent)?;
    }

    // Decode source upright. open_image_any applies EXIF/HEIC display transforms when needed.
    let path = std::path::Path::new(original_path);
    let img = match open_image_any(path) {
        Ok(img) => img,
        Err(err)
            if crate::photos::is_raw_still_extension(
                path.extension()
                    .and_then(|e| e.to_str())
                    .unwrap_or("")
                    .to_ascii_lowercase()
                    .as_str(),
            ) =>
        {
            info!(
                target: "upload",
                "[RAW] thumbnail preview unavailable; using placeholder path={} err={}",
                path.display(),
                err
            );
            crate::photos::metadata::raw_placeholder_image(512)
        }
        Err(err) => return Err(err),
    };
    let (w, h) = img.dimensions();
    // Target geometry: longest side 512
    let max_side: u32 = 512;
    let (tw, th) = if w >= h {
        let nw = max_side;
        let nh = ((h as f32) * (nw as f32 / w as f32)).round() as u32;
        (nw, nh)
    } else {
        let nh = max_side;
        let nw = ((w as f32) * (nh as f32 / h as f32)).round() as u32;
        (nw, nh)
    };
    let thumb = img.resize(tw.max(1), th.max(1), FilterType::Lanczos3);
    let rgb = thumb.to_rgb8();
    let enc = webp::Encoder::from_rgb(rgb.as_raw(), rgb.width(), rgb.height());
    let webp_data = enc.encode(80.0);

    let mut f = fs::File::create(thumb_path)?;
    f.write_all(&webp_data)?;
    Ok(())
}

fn generate_display_jpeg(
    original_path: &str,
    jpeg_path: &std::path::Path,
    max_side: u32,
) -> Result<(), anyhow::Error> {
    use std::fs;
    use std::io::Write;

    if let Some(parent) = jpeg_path.parent() {
        fs::create_dir_all(parent)?;
    }

    let path = std::path::Path::new(original_path);
    let mut img = match open_image_any(path) {
        Ok(img) => img,
        Err(err)
            if crate::photos::is_raw_still_extension(
                path.extension()
                    .and_then(|e| e.to_str())
                    .unwrap_or("")
                    .to_ascii_lowercase()
                    .as_str(),
            ) =>
        {
            info!(
                target: "upload",
                "[RAW] display preview unavailable; using placeholder path={} err={}",
                path.display(),
                err
            );
            crate::photos::metadata::raw_placeholder_image(max_side)
        }
        Err(err) => return Err(err),
    };

    let (w, h) = img.dimensions();
    if w > max_side || h > max_side {
        let (tw, th) = if w >= h {
            let nw = max_side;
            let nh = ((h as f32) * (nw as f32 / w as f32)).round() as u32;
            (nw, nh)
        } else {
            let nh = max_side;
            let nw = ((w as f32) * (nh as f32 / h as f32)).round() as u32;
            (nw, nh)
        };
        img = img.resize(tw.max(1), th.max(1), FilterType::Lanczos3);
    }

    let rgb = img.to_rgb8();
    let mut f = fs::File::create(jpeg_path)?;
    let mut encoder = JpegEncoder::new_with_quality(&mut f, 88);
    encoder.encode(&rgb, rgb.width(), rgb.height(), image::ColorType::Rgb8)?;
    f.flush()?;
    Ok(())
}

fn generate_video_poster(
    original_path: &str,
    poster_path: &std::path::Path,
) -> Result<(), anyhow::Error> {
    use image::imageops::FilterType;
    let img = video::extract_frame_upright(std::path::Path::new(original_path), 0.0)?;
    let (w, h) = img.dimensions();
    let max_side: u32 = 512;
    let (tw, th) = if w >= h {
        let nw = max_side;
        let nh = ((h as f32) * (nw as f32 / w as f32)).round() as u32;
        (nw, nh)
    } else {
        let nh = max_side;
        let nw = ((w as f32) * (nh as f32 / h as f32)).round() as u32;
        (nw, nh)
    };
    let thumb = img.resize(tw.max(1), th.max(1), FilterType::Lanczos3);
    let rgb = thumb.to_rgb8();
    let enc = webp::Encoder::from_rgb(rgb.as_raw(), rgb.width(), rgb.height());
    let webp_data = enc.encode(80.0);
    std::fs::write(poster_path, &*webp_data)?;
    Ok(())
}

/// Generate an AVIF file for the given original, using cached path.
fn generate_avif(original_path: &str, avif_path: &std::path::Path) -> Result<(), anyhow::Error> {
    use std::fs;
    use std::io::Write;
    if let Some(parent) = avif_path.parent() {
        fs::create_dir_all(parent)?;
    }
    let path = std::path::Path::new(original_path);
    // Use the same upright decoding as thumbnails for consistent orientation
    let img = match open_image_upright(path) {
        Ok(img) => img,
        Err(_) => {
            // Fallback decoder (libheif/ffmpeg) already returns an upright image
            // Avoid reapplying EXIF orientation here to prevent double-rotation.
            open_image_any(path)?
        }
    };
    let mut buf = Vec::new();
    img.write_to(
        &mut std::io::Cursor::new(&mut buf),
        image::ImageFormat::Avif,
    )
    .map_err(|e| anyhow::anyhow!("AVIF encode error via image crate: {}", e))?;
    let mut f = fs::File::create(avif_path)?;
    f.write_all(&buf)?;
    Ok(())
}

#[instrument(skip(state, request))]
pub async fn serve_live_video(
    State(state): State<Arc<AppState>>,
    Path(asset_id): Path<String>,
    request: Request,
) -> Result<axum::response::Response, AppError> {
    let query = request.uri().query().map(|q| q.to_string());
    let compat_requested = request_has_live_compat(query.as_deref());
    let range_header = request
        .headers()
        .get(header::RANGE)
        .and_then(|h| h.to_str().ok())
        .map(|s| s.to_string());
    let user_agent = request
        .headers()
        .get(header::USER_AGENT)
        .and_then(|h| h.to_str().ok())
        .map(|s| s.to_string());
    let is_chromium_ua = user_agent
        .as_deref()
        .map(is_chromium_user_agent)
        .unwrap_or(false);
    let is_firefox_ua = user_agent
        .as_deref()
        .map(is_firefox_user_agent)
        .unwrap_or(false);
    let prefer_stream_proxy = compat_requested || is_chromium_ua || is_firefox_ua;

    // Get authenticated user
    let headers = request.headers();
    let user = get_user_from_headers(headers, &state.auth_service).await?;
    info!(
        "[LIVE] request asset_id={} user={} range={:?} ua={:?} query={:?} compat_requested={} chromium_ua={} firefox_ua={} prefer_stream_proxy={}",
        asset_id,
        user.user_id,
        range_header,
        user_agent,
        query,
        compat_requested,
        is_chromium_ua,
        is_firefox_ua,
        prefer_stream_proxy
    );

    // If locked, do not serve live video via this endpoint
    {
        if let Some(pg) = &state.pg_client {
            if let Ok(row) = pg
                .query_one(
                    "SELECT COALESCE(locked,FALSE) FROM photos WHERE organization_id=$1 AND asset_id=$2 AND user_id=$3 LIMIT 1",
                    &[&user.organization_id, &asset_id, &user.user_id],
                )
                .await
            {
                let locked: bool = row.get(0);
                if locked {
                    info!(
                        "[LIVE] denied locked asset asset_id={} user={}",
                        asset_id,
                        user.user_id
                    );
                    return Ok((StatusCode::UNAUTHORIZED, Json(serde_json::json!({"error":"LOCKED_ASSET"}))).into_response());
                }
            }
        } else {
            let data_db = state.get_user_data_database(&user.user_id)?;
            let conn = data_db.lock();
            if let Ok(mut stmt) = conn.prepare("SELECT COALESCE(locked, FALSE) FROM photos WHERE organization_id = ? AND asset_id = ? LIMIT 1") {
                if let Ok(locked) = stmt.query_row(duckdb::params![user.organization_id, &asset_id], |row| row.get::<_, bool>(0)) {
                    if locked {
                        info!(
                            "[LIVE] denied locked asset asset_id={} user={}",
                            asset_id,
                            user.user_id
                        );
                        return Ok((StatusCode::UNAUTHORIZED, Json(serde_json::json!({"error":"LOCKED_ASSET"}))).into_response());
                    }
                }
            }
        }
    }

    let live_mov_cache = state.live_video_mov_path_for(&user.user_id, &asset_id);
    let live_mp4_cache = state.live_video_path_for(&user.user_id, &asset_id);
    if live_mov_cache.exists() {
        // Stream cached live component with detected MIME (supports stale misnamed cache files).
        let mut serve_path = live_mov_cache.clone();
        let mut content_type = infer_live_video_content_type(&serve_path);
        let mut live_source = "cache_raw";
        if prefer_stream_proxy {
            match ensure_ios_stream_mp4_proxy(state.as_ref(), &user.user_id, &asset_id, &serve_path)
                .await
            {
                Ok(proxy_path) => {
                    info!(
                        "[LIVE] stream proxy hit asset_id={} user={} source={} proxy={}",
                        asset_id,
                        user.user_id,
                        serve_path.display(),
                        proxy_path.display()
                    );
                    serve_path = proxy_path;
                    content_type = "video/mp4";
                    live_source = "stream_proxy";
                }
                Err(e) => {
                    tracing::warn!(
                        "[LIVE] stream proxy failed asset_id={} user={} source={} err={}",
                        asset_id,
                        user.user_id,
                        serve_path.display(),
                        e
                    );
                }
            }
        }
        info!(
            "[LIVE] cache hit asset_id={} user={} path={} content_type={}",
            asset_id,
            user.user_id,
            serve_path.display(),
            content_type
        );
        let mut resp = ServeFile::new(serve_path.clone())
            .oneshot(request)
            .await
            .unwrap();
        resp.headers_mut().insert(
            header::CONTENT_TYPE,
            axum::http::HeaderValue::from_static(content_type),
        );
        resp.headers_mut().insert(
            header::ACCEPT_RANGES,
            axum::http::HeaderValue::from_static("bytes"),
        );
        add_live_response_headers(&mut resp, live_source, compat_requested);
        let status = resp.status();
        let content_range = resp
            .headers()
            .get(header::CONTENT_RANGE)
            .and_then(|h| h.to_str().ok())
            .map(|s| s.to_string());
        let content_len = resp
            .headers()
            .get(header::CONTENT_LENGTH)
            .and_then(|h| h.to_str().ok())
            .map(|s| s.to_string());
        info!(
            "[LIVE] response asset_id={} user={} status={} content_range={:?} content_length={:?}",
            asset_id, user.user_id, status, content_range, content_len
        );
        return Ok(resp.into_response());
    }
    if live_mp4_cache.exists() {
        let mut serve_path = live_mp4_cache.clone();
        let mut content_type = infer_live_video_content_type(&serve_path);
        let mut live_source = "cache_raw";
        if prefer_stream_proxy {
            match ensure_ios_stream_mp4_proxy(state.as_ref(), &user.user_id, &asset_id, &serve_path)
                .await
            {
                Ok(proxy_path) => {
                    info!(
                        "[LIVE] stream proxy hit asset_id={} user={} source={} proxy={}",
                        asset_id,
                        user.user_id,
                        serve_path.display(),
                        proxy_path.display()
                    );
                    serve_path = proxy_path;
                    content_type = "video/mp4";
                    live_source = "stream_proxy";
                }
                Err(e) => {
                    tracing::warn!(
                        "[LIVE] stream proxy failed asset_id={} user={} source={} err={}",
                        asset_id,
                        user.user_id,
                        serve_path.display(),
                        e
                    );
                }
            }
        }
        info!(
            "[LIVE] cache hit asset_id={} user={} path={} content_type={}",
            asset_id,
            user.user_id,
            serve_path.display(),
            content_type
        );
        let mut resp = ServeFile::new(serve_path.clone())
            .oneshot(request)
            .await
            .unwrap();
        resp.headers_mut().insert(
            header::CONTENT_TYPE,
            axum::http::HeaderValue::from_static(content_type),
        );
        resp.headers_mut().insert(
            header::ACCEPT_RANGES,
            axum::http::HeaderValue::from_static("bytes"),
        );
        add_live_response_headers(&mut resp, live_source, compat_requested);
        let status = resp.status();
        let content_range = resp
            .headers()
            .get(header::CONTENT_RANGE)
            .and_then(|h| h.to_str().ok())
            .map(|s| s.to_string());
        let content_len = resp
            .headers()
            .get(header::CONTENT_LENGTH)
            .and_then(|h| h.to_str().ok())
            .map(|s| s.to_string());
        info!(
            "[LIVE] response asset_id={} user={} status={} content_range={:?} content_length={:?}",
            asset_id, user.user_id, status, content_range, content_len
        );
        return Ok(resp.into_response());
    }

    // Need to create it from the original MOV path stored in DB or inferred by filename
    let (photo_path, is_live, live_src_path) = if let Some(pg) = &state.pg_client {
        if let Ok(row) = pg
            .query_one(
                "SELECT path, COALESCE(is_live_photo,FALSE), live_video_path FROM photos WHERE organization_id=$1 AND user_id=$2 AND asset_id=$3 LIMIT 1",
                &[&user.organization_id, &user.user_id, &asset_id],
            )
            .await
        {
            (row.get::<_, String>(0), row.get::<_, bool>(1), row.get::<_, Option<String>>(2))
        } else { (String::new(), false, None) }
    } else {
        let data_db = state.get_user_data_database(&user.user_id)?;
        let conn = data_db.lock();
        let mut stmt = conn.prepare("SELECT path, is_live_photo, live_video_path FROM photos WHERE organization_id = ? AND asset_id = ? LIMIT 1")?;
        let row = stmt
            .query_row(duckdb::params![user.organization_id, &asset_id], |row| {
                Ok::<(String, bool, Option<String>), duckdb::Error>((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2).ok(),
                ))
            })
            .ok();
        row.unwrap_or_else(|| (String::new(), false, None))
    };

    if !is_live {
        info!(
            "[LIVE] rejected non-live asset asset_id={} user={} path={} live_video_path_present={}",
            asset_id,
            user.user_id,
            photo_path,
            live_src_path.is_some()
        );
        return Err(AppError(anyhow::anyhow!("Not a live photo")));
    }

    // Prefer DB live_video_path; else infer sidecar beside original photo path.
    let live_src_candidate = if let Some(p) = live_src_path {
        std::path::PathBuf::from(p)
    } else {
        let p = std::path::Path::new(&photo_path);
        let base = p.with_extension("");
        let mp4 = base.with_extension("mp4");
        if mp4.exists() {
            mp4
        } else {
            let mp4_upper = base.with_extension("MP4");
            if mp4_upper.exists() {
                mp4_upper
            } else {
                let mov = base.with_extension("mov");
                if mov.exists() {
                    mov
                } else {
                    base.with_extension("MOV")
                }
            }
        }
    };

    if !live_src_candidate.exists() {
        info!(
            "[LIVE] source missing asset_id={} user={} source={}",
            asset_id,
            user.user_id,
            live_src_candidate.display()
        );
        return Err(AppError(anyhow::anyhow!("Live video source not found")));
    }

    if prefer_stream_proxy {
        match ensure_ios_stream_mp4_proxy(
            state.as_ref(),
            &user.user_id,
            &asset_id,
            &live_src_candidate,
        )
        .await
        {
            Ok(proxy_path) => {
                info!(
                    "[LIVE] stream proxy generated asset_id={} user={} source={} proxy={}",
                    asset_id,
                    user.user_id,
                    live_src_candidate.display(),
                    proxy_path.display()
                );
                let mut resp = ServeFile::new(proxy_path).oneshot(request).await.unwrap();
                resp.headers_mut().insert(
                    header::CONTENT_TYPE,
                    axum::http::HeaderValue::from_static("video/mp4"),
                );
                resp.headers_mut().insert(
                    header::ACCEPT_RANGES,
                    axum::http::HeaderValue::from_static("bytes"),
                );
                add_live_response_headers(&mut resp, "stream_proxy", compat_requested);
                let status = resp.status();
                let content_range = resp
                    .headers()
                    .get(header::CONTENT_RANGE)
                    .and_then(|h| h.to_str().ok())
                    .map(|s| s.to_string());
                let content_len = resp
                    .headers()
                    .get(header::CONTENT_LENGTH)
                    .and_then(|h| h.to_str().ok())
                    .map(|s| s.to_string());
                info!(
                    "[LIVE] response asset_id={} user={} status={} content_range={:?} content_length={:?}",
                    asset_id,
                    user.user_id,
                    status,
                    content_range,
                    content_len
                );
                return Ok(resp.into_response());
            }
            Err(e) => {
                tracing::warn!(
                    "[LIVE] stream proxy generation failed asset_id={} user={} source={} err={}",
                    asset_id,
                    user.user_id,
                    live_src_candidate.display(),
                    e
                );
            }
        }
    }

    let content_type = infer_live_video_content_type(&live_src_candidate);
    let target_cache = if content_type == "video/mp4" {
        live_mp4_cache.clone()
    } else {
        live_mov_cache.clone()
    };
    info!(
        "[LIVE] source selected asset_id={} user={} source={} target_cache={} content_type={}",
        asset_id,
        user.user_id,
        live_src_candidate.display(),
        target_cache.display(),
        content_type
    );

    // Ensure target dir
    if let Some(parent) = target_cache.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if let Err(e) = std::fs::copy(&live_src_candidate, &target_cache) {
        error!(
            "[LIVE] cache copy failed asset_id={} user={} source={} target={} err={}",
            asset_id,
            user.user_id,
            live_src_candidate.display(),
            target_cache.display(),
            e
        );
        return Err(AppError(anyhow::anyhow!(
            "Failed to copy live video: {}",
            e
        )));
    }

    let mut resp = ServeFile::new(target_cache).oneshot(request).await.unwrap();
    resp.headers_mut().insert(
        header::CONTENT_TYPE,
        axum::http::HeaderValue::from_static(content_type),
    );
    resp.headers_mut().insert(
        header::ACCEPT_RANGES,
        axum::http::HeaderValue::from_static("bytes"),
    );
    add_live_response_headers(&mut resp, "cache_raw", compat_requested);
    info!(
        "[LIVE] served asset_id={} user={} content_type={}",
        asset_id, user.user_id, content_type
    );
    let status = resp.status();
    let content_range = resp
        .headers()
        .get(header::CONTENT_RANGE)
        .and_then(|h| h.to_str().ok())
        .map(|s| s.to_string());
    let content_len = resp
        .headers()
        .get(header::CONTENT_LENGTH)
        .and_then(|h| h.to_str().ok())
        .map(|s| s.to_string());
    info!(
        "[LIVE] response asset_id={} user={} status={} content_range={:?} content_length={:?}",
        asset_id, user.user_id, status, content_range, content_len
    );
    Ok(resp.into_response())
}

#[instrument(skip(state, request))]
pub async fn serve_locked_live_video(
    State(state): State<Arc<AppState>>,
    Path(asset_id): Path<String>,
    request: Request,
) -> Result<axum::response::Response, AppError> {
    // Authenticate
    let headers = request.headers();
    let user = get_user_from_headers(headers, &state.auth_service).await?;

    // Look up locked + live + live_video_path
    let (is_locked, is_live, live_path_opt): (bool, bool, Option<String>) = if let Some(pg) =
        &state.pg_client
    {
        if let Ok(row) = pg
            .query_one(
                "SELECT COALESCE(locked,FALSE), COALESCE(is_live_photo,FALSE), live_video_path FROM photos WHERE organization_id=$1 AND user_id=$2 AND asset_id=$3 LIMIT 1",
                &[&user.organization_id, &user.user_id, &asset_id],
            )
            .await
        {
            (row.get::<_, bool>(0), row.get::<_, bool>(1), row.get::<_, Option<String>>(2))
        } else {
            (false, false, None)
        }
    } else {
        let data_db = state.get_user_data_database(&user.user_id)?;
        let conn = data_db.lock();
        let mut stmt = conn.prepare("SELECT COALESCE(locked, FALSE), COALESCE(is_live_photo, FALSE), live_video_path FROM photos WHERE organization_id = ? AND asset_id = ? LIMIT 1")?;
        stmt.query_row(duckdb::params![user.organization_id, &asset_id], |row| {
            Ok((
                row.get::<_, bool>(0)?,
                row.get::<_, bool>(1)?,
                row.get::<_, Option<String>>(2)?,
            ))
        })
        .ok()
        .unwrap_or((false, false, None))
    };

    if !is_locked {
        // Not locked; suggest client use /api/live
        return Ok((StatusCode::BAD_REQUEST, Json(json!({"error":"NOT_LOCKED"}))).into_response());
    }
    if !is_live {
        return Ok((StatusCode::BAD_REQUEST, Json(json!({"error":"NOT_LIVE"}))).into_response());
    }
    let live_path = if let Some(p) = live_path_opt {
        p
    } else {
        return Ok((StatusCode::NOT_FOUND, Json(json!({"error":"NO_LIVE_PATH"}))).into_response());
    };
    let bytes = tokio::fs::read(&live_path).await.map_err(|e| {
        anyhow::anyhow!("Failed to read locked live container {}: {}", live_path, e)
    })?;
    let mut headers_map = HeaderMap::new();
    headers_map.insert(
        header::CONTENT_TYPE,
        axum::http::HeaderValue::from_static("application/octet-stream"),
    );
    Ok((headers_map, bytes).into_response())
}

pub(crate) fn transcode_mov_to_mp4(
    input_mov: &std::path::Path,
    output_mp4: &std::path::Path,
) -> Result<(), anyhow::Error> {
    // Prefer in-process remux when feature is enabled; fallback to ffmpeg CLI
    #[cfg(feature = "ffmpeg-inprocess")]
    {
        if let Err(e) = inprocess_remux_mov_to_mp4(input_mov, output_mp4) {
            tracing::warn!("In-process remux failed ({}), falling back to CLI", e);
            cli_transcode_mov_to_mp4(input_mov, output_mp4)?;
        }
        return Ok(());
    }
    #[cfg(not(feature = "ffmpeg-inprocess"))]
    {
        cli_transcode_mov_to_mp4(input_mov, output_mp4)
    }
}

#[cfg(feature = "ffmpeg-inprocess")]
fn inprocess_remux_mov_to_mp4(
    input_mov: &std::path::Path,
    output_mp4: &std::path::Path,
) -> Result<(), anyhow::Error> {
    use ffmpeg_next as ffmpeg;
    ffmpeg::format::network::init();
    ffmpeg::init().map_err(|e| anyhow::anyhow!("ffmpeg init: {:?}", e))?;

    let mut ictx =
        ffmpeg::format::input(&input_mov).map_err(|e| anyhow::anyhow!("open input: {:?}", e))?;

    // Create output context with mp4
    let mut octx =
        ffmpeg::format::output(&output_mp4).map_err(|e| anyhow::anyhow!("open output: {:?}", e))?;

    let mut stream_map = Vec::new();
    for (i, ist) in ictx.streams().enumerate() {
        let codecpar = ist.parameters();
        // Only include video stream; ignore audio for simplicity
        if ist.parameters().medium() == ffmpeg::media::Type::Video {
            let mut ost = octx.add_stream(unsafe {
                ffmpeg::codec::decoder::find(codecpar.id())
                    .ok_or_else(|| anyhow::anyhow!("codec not found"))?
            })?;
            ost.set_parameters(codecpar);
            stream_map.push((i, ost.index()));
        }
    }
    if stream_map.is_empty() {
        return Err(anyhow::anyhow!("no video stream found"));
    }

    octx.set_metadata(ictx.metadata().to_owned());
    octx.write_header()
        .map_err(|e| anyhow::anyhow!("write header: {:?}", e))?;

    let in_time_base: Vec<_> = ictx.streams().map(|s| s.time_base()).collect();
    let out_time_base: Vec<_> = octx.streams().map(|s| s.time_base()).collect();

    for (stream, mut packet) in ictx.packets() {
        let in_index = stream.index();
        // Map stream index
        let out_index = match stream_map.iter().find(|(i, _)| *i == in_index) {
            Some((_, o)) => *o,
            None => continue,
        };
        packet.set_stream(out_index);
        // Rescale timestamps
        packet.rescale_ts(in_time_base[in_index], out_time_base[out_index]);
        packet.set_position(-1);
        packet
            .write_interleaved(&mut octx)
            .map_err(|e| anyhow::anyhow!("write packet: {:?}", e))?;
    }
    octx.write_trailer()
        .map_err(|e| anyhow::anyhow!("write trailer: {:?}", e))?;
    Ok(())
}

fn cli_transcode_mov_to_mp4(
    input_mov: &std::path::Path,
    output_mp4: &std::path::Path,
) -> Result<(), anyhow::Error> {
    // Try remux copy first (fast)
    let status = ffmpeg_command()
        .args([
            "-y",
            "-i",
            input_mov.to_string_lossy().as_ref(),
            "-c:v",
            "copy",
            "-an",
            "-movflags",
            "+faststart",
            output_mp4.to_string_lossy().as_ref(),
        ])
        .status();
    match status {
        Ok(s) if s.success() => return Ok(()),
        _ => {}
    }
    // Fallback to re-encode to H.264
    let status = ffmpeg_command()
        .args([
            "-y",
            "-i",
            input_mov.to_string_lossy().as_ref(),
            "-c:v",
            "libx264",
            "-preset",
            "veryfast",
            "-crf",
            "23",
            "-an",
            "-movflags",
            "+faststart",
            output_mp4.to_string_lossy().as_ref(),
        ])
        .status()?;
    if !status.success() {
        return Err(anyhow::anyhow!("ffmpeg failed with status: {:?}", status));
    }
    Ok(())
}

#[instrument(skip(state, headers))]
pub async fn serve_face_thumbnail(
    State(state): State<Arc<AppState>>,
    Path(person_id): Path<String>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, AppError> {
    let user = get_user_from_headers(&headers, &state.auth_service).await?;

    let faces_path = state.user_faces_path(&user.user_id);
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
#[instrument(skip(state, headers))]
pub async fn list_albums(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, AppError> {
    let user = get_user_from_headers(&headers, &state.auth_service).await?;
    if let Some(pg) = &state.pg_client {
        // Postgres path
        let sql = r#"
            SELECT a.id, a.name, a.description, a.parent_id, a.position, a.cover_photo_id,
                   COALESCE(a.photo_count,0) AS photo_count, a.created_at, a.updated_at,
                   COALESCE(a.is_live,FALSE) AS is_live
            FROM albums a
            WHERE a.organization_id = $1 AND a.user_id = $2
              AND COALESCE(a.description, '') <> 'Share snapshot'
            ORDER BY a.created_at DESC
        "#;
        let rows = pg
            .query(sql, &[&user.organization_id, &user.user_id])
            .await
            .map_err(|e| AppError(anyhow::anyhow!(e)))?;
        let mut out: Vec<serde_json::Value> = Vec::new();
        for r in rows {
            // Try resolve cover asset id
            let cover_photo_id: Option<i32> = r.get(5);
            let cover_asset_id: Option<String> = if let Some(pid) = cover_photo_id {
                pg.query_opt(
                    "SELECT asset_id FROM photos WHERE organization_id=$1 AND id=$2",
                    &[&user.organization_id, &pid],
                )
                .await
                .ok()
                .flatten()
                .map(|rr| rr.get::<_, String>(0))
            } else {
                None
            };
            // photo_count is INTEGER; retrieve as i32 to avoid type mismatch
            let pc_i32: i32 = r.get::<_, i32>(6);
            out.push(serde_json::json!({
                "id": r.get::<_, i32>(0),
                "name": r.get::<_, String>(1),
                "description": r.get::<_, Option<String>>(2),
                "parent_id": r.get::<_, Option<i32>>(3),
                "position": r.get::<_, Option<i32>>(4),
                "cover_photo_id": cover_photo_id,
                "cover_asset_id": cover_asset_id,
                "photo_count": pc_i32 as usize,
                "created_at": r.get::<_, i64>(7),
                "updated_at": r.get::<_, i64>(8),
                "depth": 0,
                "is_live": r.get::<_, bool>(9),
            }));
        }
        return Ok((StatusCode::OK, Json(serde_json::Value::Array(out))));
    }
    let db = match &state.multi_tenant_db {
        Some(db) => db.clone(),
        None => {
            return Ok((
                StatusCode::NOT_IMPLEMENTED,
                Json(serde_json::json!({ "albums": [] })),
            ))
        }
    };
    // [ALBUMS] /api/albums start suppressed
    let photo_service = PhotoService::new(db);
    match photo_service.list_albums(&user.user_id).await {
        Ok(albums) => {
            // Lightweight debug summary to verify counts exclude trashed
            if albums.len() <= 20 {
                let summary: Vec<_> = albums
                    .iter()
                    .map(|a| format!("{}:{}", a.id, a.photo_count))
                    .collect();
                tracing::info!(
                    target = "albums",
                    "[ALBUMS] list summary user={} -> {}",
                    user.user_id,
                    summary.join(",")
                );

                // Extra diagnostic: compute active vs trashed directly from DB
                if let Some(db2) = &state.multi_tenant_db {
                    if let Ok(user_db) = db2.get_user_database(&user.user_id) {
                        let conn = user_db.lock();
                        for a in albums.iter().take(5) {
                            let active: i64 = conn
                                .query_row(
                                    "SELECT COUNT(*) FROM album_photos ap JOIN photos p ON ap.photo_id = p.id WHERE ap.album_id = ? AND COALESCE(p.delete_time,0) = 0",
                                    [a.id],
                                    |row| row.get::<_, i64>(0),
                                )
                                .unwrap_or(-1);
                            let trashed: i64 = conn
                                .query_row(
                                    "SELECT COUNT(*) FROM album_photos ap JOIN photos p ON ap.photo_id = p.id WHERE ap.album_id = ? AND COALESCE(p.delete_time,0) > 0",
                                    [a.id],
                                    |row| row.get::<_, i64>(0),
                                )
                                .unwrap_or(-1);
                            tracing::info!(
                                target = "albums",
                                "[ALBUMS] counts album={} active={} trashed={}",
                                a.id,
                                active,
                                trashed
                            );
                        }
                    }
                }
            } else {
                tracing::info!(
                    target = "albums",
                    "[ALBUMS] list rows={} (summary suppressed)",
                    albums.len()
                );
            }
            Ok((StatusCode::OK, Json(serde_json::to_value(albums).unwrap())))
        }
        Err(e) => {
            tracing::error!(target: "albums", "[ALBUMS] /api/albums error: {}", e);
            Err(AppError(e))
        }
    }
}

#[instrument(skip(state, headers))]
pub async fn create_album(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(album_request): Json<CreateAlbumRequest>,
) -> Result<impl IntoResponse, AppError> {
    let user = get_user_from_headers(&headers, &state.auth_service).await?;
    if let Some(pg) = &state.pg_client {
        let now = chrono::Utc::now().timestamp();
        let name_lc = album_request.name.to_lowercase();
        let row = pg
            .query_one(
                "INSERT INTO albums (organization_id, user_id, name, name_lc, description, parent_id, created_at, updated_at)\n                 VALUES ($1,$2,$3,$4,$5,$6,$7,$8)\n                 RETURNING id, name, description, parent_id, position, cover_photo_id, COALESCE(photo_count,0), created_at, updated_at, COALESCE(is_live,FALSE)",
                &[&user.organization_id, &user.user_id, &album_request.name, &name_lc, &album_request.description, &album_request.parent_id, &now, &now],
            )
            .await
            .map_err(|e| AppError(anyhow::anyhow!(e)))?;
        let out = serde_json::json!({
            "id": row.get::<_, i32>(0),
            "name": row.get::<_, String>(1),
            "description": row.get::<_, Option<String>>(2),
            "parent_id": row.get::<_, Option<i32>>(3),
            "position": row.get::<_, Option<i32>>(4),
            "cover_photo_id": row.get::<_, Option<i32>>(5),
            "cover_asset_id": serde_json::Value::Null,
            // photo_count column is INTEGER in Postgres; retrieve as i32 to avoid type mismatch
            "photo_count": row.get::<_, i32>(6) as usize,
            "created_at": row.get::<_, i64>(7),
            "updated_at": row.get::<_, i64>(8),
            "depth": 0,
            "is_live": row.get::<_, bool>(9),
        });
        return Ok((StatusCode::CREATED, Json(out)));
    }
    let db = state
        .multi_tenant_db
        .as_ref()
        .ok_or_else(|| AppError(anyhow::anyhow!("Albums not supported in Postgres mode yet")))?
        .clone();
    let photo_service = PhotoService::new(db);
    let album = photo_service
        .create_album(&user.user_id, album_request)
        .await?;
    Ok((
        StatusCode::CREATED,
        Json(serde_json::to_value(album).map_err(|e| AppError(anyhow::anyhow!(e)))?),
    ))
}

#[instrument(skip(state, headers))]
pub async fn create_live_album(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(album_request): Json<CreateLiveAlbumRequest>,
) -> Result<impl IntoResponse, AppError> {
    let user = get_user_from_headers(&headers, &state.auth_service).await?;
    if let Some(pg) = &state.pg_client {
        let now = chrono::Utc::now().timestamp();
        let criteria_json = serde_json::to_string(&album_request.criteria)
            .map_err(|e| AppError(anyhow::anyhow!(e)))?;
        let name_lc = album_request.name.to_lowercase();
        let row = pg
            .query_one(
                "INSERT INTO albums (organization_id, user_id, name, name_lc, description, parent_id, is_live, live_criteria, created_at, updated_at)\n                 VALUES ($1,$2,$3,$4,$5,$6,TRUE,$7,$8,$9)\n                 RETURNING id, name, description, parent_id, position, cover_photo_id, COALESCE(photo_count,0), created_at, updated_at, COALESCE(is_live,FALSE)",
                &[&user.organization_id, &user.user_id, &album_request.name, &name_lc, &album_request.description, &album_request.parent_id, &criteria_json, &now, &now],
            )
            .await
            .map_err(|e| AppError(anyhow::anyhow!(e)))?;
        let out = serde_json::json!({
            "id": row.get::<_, i32>(0),
            "name": row.get::<_, String>(1),
            "description": row.get::<_, Option<String>>(2),
            "parent_id": row.get::<_, Option<i32>>(3),
            "position": row.get::<_, Option<i32>>(4),
            "cover_photo_id": row.get::<_, Option<i32>>(5),
            "cover_asset_id": serde_json::Value::Null,
            // photo_count column is INTEGER in Postgres; retrieve as i32 to avoid type mismatch
            "photo_count": row.get::<_, i32>(6) as usize,
            "created_at": row.get::<_, i64>(7),
            "updated_at": row.get::<_, i64>(8),
            "depth": 0,
            "is_live": row.get::<_, bool>(9),
        });
        return Ok((StatusCode::CREATED, Json(out)));
    }
    let db = state
        .multi_tenant_db
        .as_ref()
        .ok_or_else(|| {
            AppError(anyhow::anyhow!(
                "Live albums not supported in Postgres mode yet"
            ))
        })?
        .clone();
    let photo_service = PhotoService::new(db);
    let album = photo_service
        .create_live_album(&user.user_id, album_request)
        .await?;
    Ok((
        StatusCode::CREATED,
        Json(serde_json::to_value(album).map_err(|e| AppError(anyhow::anyhow!(e)))?),
    ))
}

#[instrument(skip(state, headers))]
pub async fn update_album(
    State(state): State<Arc<AppState>>,
    Path(album_id): Path<i32>,
    headers: HeaderMap,
    Json(album_request): Json<UpdateAlbumRequest>,
) -> Result<impl IntoResponse, AppError> {
    let user = get_user_from_headers(&headers, &state.auth_service).await?;
    if let Some(pg) = &state.pg_client {
        let now = chrono::Utc::now().timestamp();
        let mut sets: Vec<String> = vec!["updated_at = $1".to_string()];
        let mut binds: Vec<&(dyn tokio_postgres::types::ToSql + Sync)> = vec![&now];
        // Hold owned strings used in binds to avoid E0716
        let mut owned_strings: Vec<String> = Vec::new();
        let mut idx: i32 = 2;
        if let Some(name) = &album_request.name {
            sets.push(format!("name = ${}", idx));
            binds.push(name);
            idx += 1;
            sets.push(format!("name_lc = ${}", idx));
            owned_strings.push(name.to_lowercase());
            let name_lc_ref: &String = owned_strings.last().unwrap();
            binds.push(name_lc_ref);
            idx += 1;
        }
        if let Some(desc) = &album_request.description {
            sets.push(format!("description = ${}", idx));
            binds.push(desc);
            idx += 1;
        }
        if let Some(cpid) = &album_request.cover_photo_id {
            sets.push(format!("cover_photo_id = ${}", idx));
            binds.push(cpid);
            idx += 1;
        }
        if let Some(pid) = &album_request.parent_id {
            sets.push(format!("parent_id = ${}", idx));
            binds.push(pid);
            idx += 1;
        }
        if let Some(pos) = &album_request.position {
            sets.push(format!("position = ${}", idx));
            binds.push(pos);
            idx += 1;
        }
        let org_bind = &user.organization_id;
        let id_bind = &album_id;
        let sql = format!(
            "UPDATE albums SET {} WHERE organization_id = ${} AND id = ${} RETURNING id, name, description, parent_id, position, cover_photo_id, COALESCE(photo_count,0), created_at, updated_at, COALESCE(is_live,FALSE)",
            sets.join(", "), idx, idx + 1
        );
        binds.push(org_bind);
        binds.push(id_bind);
        let row = pg
            .query_one(&sql, &binds)
            .await
            .map_err(|e| AppError(anyhow::anyhow!(e)))?;
        let out = serde_json::json!({
            "id": row.get::<_, i32>(0),
            "name": row.get::<_, String>(1),
            "description": row.get::<_, Option<String>>(2),
            "parent_id": row.get::<_, Option<i32>>(3),
            "position": row.get::<_, Option<i32>>(4),
            "cover_photo_id": row.get::<_, Option<i32>>(5),
            "cover_asset_id": serde_json::Value::Null,
            // photo_count column is INTEGER in Postgres; retrieve as i32 to avoid type mismatch
            "photo_count": row.get::<_, i32>(6) as usize,
            "created_at": row.get::<_, i64>(7),
            "updated_at": row.get::<_, i64>(8),
            "depth": 0,
            "is_live": row.get::<_, bool>(9),
        });
        return Ok(Json(out));
    }
    let db = state
        .multi_tenant_db
        .as_ref()
        .ok_or_else(|| AppError(anyhow::anyhow!("Albums not supported in Postgres mode yet")))?
        .clone();
    let photo_service = PhotoService::new(db);
    let album = photo_service
        .update_album(&user.user_id, album_id, album_request)
        .await?;
    Ok(Json(
        serde_json::to_value(album).map_err(|e| AppError(anyhow::anyhow!(e)))?,
    ))
}

// POST wrapper for update (used by clients that can't use PUT reliably)
#[instrument(skip(state, headers))]
pub async fn update_album_post(
    State(state): State<Arc<AppState>>,
    Path(album_id): Path<i32>,
    headers: HeaderMap,
    Json(album_request): Json<UpdateAlbumRequest>,
) -> Result<impl IntoResponse, AppError> {
    update_album(State(state), Path(album_id), headers, Json(album_request)).await
}

#[derive(Debug, Deserialize)]
pub struct UpdateAlbumJson {
    pub id: i32,
    pub name: Option<String>,
    pub description: Option<String>,
    pub cover_photo_id: Option<i32>,
    pub parent_id: Option<i32>,
    pub position: Option<i32>,
}

// POST /api/albums/update with JSON body including id (no path param)
#[instrument(skip(state, headers))]
pub async fn update_album_json(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(payload): Json<UpdateAlbumJson>,
) -> Result<axum::response::Response, AppError> {
    let user = get_user_from_headers(&headers, &state.auth_service).await?;
    if let Some(_pg) = &state.pg_client {
        // Reuse update_album handler for PG branch
        let req = UpdateAlbumRequest {
            name: payload.name,
            description: payload.description,
            cover_photo_id: payload.cover_photo_id,
            parent_id: payload.parent_id,
            position: payload.position,
        };
        let resp = update_album(State(state), Path(payload.id), headers, Json(req)).await?;
        return Ok(resp.into_response());
    }
    let db = state
        .multi_tenant_db
        .as_ref()
        .ok_or_else(|| {
            AppError(anyhow::anyhow!(
                "Live albums not supported in Postgres mode yet"
            ))
        })?
        .clone();
    let photo_service = PhotoService::new(db);
    let req = UpdateAlbumRequest {
        name: payload.name,
        description: payload.description,
        cover_photo_id: payload.cover_photo_id,
        parent_id: payload.parent_id,
        position: payload.position,
    };
    let album = photo_service
        .update_album(&user.user_id, payload.id, req)
        .await?;
    Ok(
        Json(serde_json::to_value(album).map_err(|e| AppError(anyhow::anyhow!(e)))?)
            .into_response(),
    )
}

#[derive(Debug, Deserialize)]
pub struct UpdateLiveAlbumJson {
    pub id: i32,
    pub name: Option<String>,
    pub description: Option<String>,
    pub parent_id: Option<i32>,
    pub position: Option<i32>,
    pub criteria: Option<PhotoListQuery>,
}

#[instrument(skip(state, headers))]
pub async fn update_live_album_json(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(payload): Json<UpdateLiveAlbumJson>,
) -> Result<impl IntoResponse, AppError> {
    let user = get_user_from_headers(&headers, &state.auth_service).await?;
    let db = state
        .multi_tenant_db
        .as_ref()
        .ok_or_else(|| AppError(anyhow::anyhow!("Albums not supported in Postgres mode yet")))?
        .clone();
    let photo_service = PhotoService::new(db);
    // Update basic fields via existing service
    let req = UpdateAlbumRequest {
        name: payload.name.clone(),
        description: payload.description.clone(),
        cover_photo_id: None,
        parent_id: payload.parent_id,
        position: payload.position,
    };
    let mut album = photo_service
        .update_album(&user.user_id, payload.id, req)
        .await?;

    // If criteria provided, update live_criteria directly
    if let Some(mut crit) = payload.criteria {
        // sanitize
        crit.album_id = None;
        crit.album_subtree = None;
        let criteria_json =
            serde_json::to_string(&crit).map_err(|e| AppError(anyhow::anyhow!(e)))?;
        let user_db = state
            .multi_tenant_db
            .as_ref()
            .expect("user DB required in DuckDB mode")
            .get_user_database(&user.user_id)?;
        let conn = user_db.lock();
        let updated = conn.execute(
            "UPDATE albums SET live_criteria = ?, updated_at = ? WHERE id = ? AND COALESCE(is_live, FALSE) = TRUE",
            duckdb::params![criteria_json, chrono::Utc::now().timestamp(), payload.id],
        )?;
        if updated == 0 {
            return Err(AppError(anyhow::anyhow!(
                "Album not found or not a live album"
            )));
        }
    }
    Ok(Json(
        serde_json::to_value(album).map_err(|e| AppError(anyhow::anyhow!(e)))?,
    ))
}

#[derive(Debug, Deserialize)]
pub struct FreezeAlbumJson {
    pub name: Option<String>,
}

#[instrument(skip(state, headers))]
pub async fn freeze_live_album(
    State(state): State<Arc<AppState>>,
    Path(album_id): Path<i32>,
    headers: HeaderMap,
    Json(payload): Json<FreezeAlbumJson>,
) -> Result<impl IntoResponse, AppError> {
    let user = get_user_from_headers(&headers, &state.auth_service).await?;
    if let Some(pg) = &state.pg_client {
        // Load live album criteria from PG
        let row = pg
            .query_one(
                "SELECT COALESCE(is_live,FALSE), name, live_criteria FROM albums WHERE organization_id=$1 AND id=$2",
                &[&user.organization_id, &album_id],
            )
            .await
            .map_err(|_| AppError(anyhow::anyhow!("Album not found")))?;
        let is_live: bool = row.get(0);
        if !is_live {
            return Err(AppError(anyhow::anyhow!("Only live albums can be frozen")));
        }
        let live_name: String = row.get(1);
        let crit_json: Option<String> = row.get(2);
        let criteria_str =
            crit_json.ok_or_else(|| AppError(anyhow::anyhow!("Live criteria missing")))?;
        let mut criteria: PhotoListQuery =
            serde_json::from_str(&criteria_str).map_err(|e| AppError(anyhow::anyhow!(e)))?;
        criteria.album_id = None;
        criteria.album_subtree = None;

        // Iterate results using MetaStore paging (PG)
        let mut page: u32 = 1;
        let limit: u32 = 1000;
        let mut ids: Vec<i32> = Vec::new();
        let meta = state
            .meta
            .as_ref()
            .ok_or_else(|| AppError(anyhow::anyhow!("MetaStore not available")))?;
        loop {
            let mut q = criteria.clone();
            q.page = Some(page);
            q.limit = Some(limit);
            let (photos, total) = meta
                .list_photos(user.organization_id, &user.user_id, &q)
                .await?;
            for p in photos {
                if let Some(pid) = p.id {
                    ids.push(pid);
                }
            }
            if (page * limit) as usize >= total as usize {
                break;
            }
            page += 1;
        }

        // Create new static album
        let default_name = format!(
            "{} (Snapshot {})",
            live_name,
            chrono::Utc::now().date_naive()
        );
        let new_name = payload.name.as_deref().unwrap_or(&default_name);
        let now = chrono::Utc::now().timestamp();
        let name_lc = new_name.to_lowercase();
        let row2 = pg
            .query_one(
                "INSERT INTO albums (organization_id, user_id, name, name_lc, description, parent_id, is_live, created_at, updated_at) VALUES ($1,$2,$3,$4,$5,$6,FALSE,$7,$8) RETURNING id",
                &[&user.organization_id, &user.user_id, &new_name, &name_lc, &Some("Frozen from live album".to_string()), &None::<i32>, &now, &now],
            )
            .await
            .map_err(|e| AppError(anyhow::anyhow!(e)))?;
        let new_album_id: i32 = row2.get(0);
        // Add photos to it
        for pid in ids.iter() {
            let _ = pg
                .execute(
                    "INSERT INTO album_photos (organization_id, album_id, photo_id, added_at) VALUES ($1,$2,$3,$4) ON CONFLICT (organization_id, album_id, photo_id) DO NOTHING",
                    &[&user.organization_id, &new_album_id, pid, &now],
                )
                .await;
        }
        let out = serde_json::json!({
            "id": new_album_id,
            "name": new_name,
            "description": "Frozen from live album",
            "parent_id": serde_json::Value::Null,
            "position": serde_json::Value::Null,
            "cover_photo_id": serde_json::Value::Null,
            "cover_asset_id": serde_json::Value::Null,
            "photo_count": ids.len(),
            "created_at": now,
            "updated_at": now,
            "depth": 0,
            "is_live": false,
        });
        return Ok(Json(out));
    }

    // DuckDB path
    // Load criteria within a non-async scope to avoid holding non-Send guards across awaits
    let (live_name, criteria): (String, PhotoListQuery) = {
        let user_db = state
            .multi_tenant_db
            .as_ref()
            .expect("user DB required in DuckDB mode")
            .get_user_database(&user.user_id)?;
        let conn = user_db.lock();
        let row = conn.query_row(
            "SELECT COALESCE(is_live, FALSE), name, live_criteria FROM albums WHERE organization_id = ? AND id = ?",
            duckdb::params![user.organization_id, album_id],
            |row| {
                Ok((
                    row.get::<_, bool>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, Option<String>>(2)?,
                ))
            },
        );
        let (is_live, live_name, crit_json) =
            row.map_err(|_| anyhow::anyhow!("Album not found"))?;
        if !is_live {
            return Err(AppError(anyhow::anyhow!("Only live albums can be frozen")));
        }
        let criteria_str =
            crit_json.ok_or_else(|| AppError(anyhow::anyhow!("Live criteria missing")))?;
        let mut criteria: PhotoListQuery =
            serde_json::from_str(&criteria_str).map_err(|e| AppError(anyhow::anyhow!(e)))?;
        criteria.album_id = None;
        criteria.album_subtree = None;
        (live_name, criteria)
    };
    let db = state
        .multi_tenant_db
        .as_ref()
        .ok_or_else(|| {
            AppError(anyhow::anyhow!(
                "Albums/photos ops not supported in Postgres mode yet"
            ))
        })?
        .clone();
    let photo_service = PhotoService::new(db);
    let mut page: u32 = 1;
    let limit: u32 = 1000;
    let mut ids: Vec<i32> = Vec::new();
    loop {
        let mut q = criteria.clone();
        q.page = Some(page);
        q.limit = Some(limit);
        let resp = photo_service.list_photos(&user.user_id, q).await?;
        for p in resp.photos {
            if let Some(pid) = p.id {
                ids.push(pid);
            }
        }
        if !resp.has_more {
            break;
        }
        page += 1;
    }
    let default_name = format!(
        "{} (Snapshot {})",
        live_name,
        chrono::Utc::now().date_naive()
    );
    let new_name = payload.name.as_deref().unwrap_or(&default_name);
    let new_album = photo_service
        .create_album(
            &user.user_id,
            CreateAlbumRequest {
                name: new_name.to_string(),
                description: Some("Frozen from live album".to_string()),
                parent_id: None,
            },
        )
        .await?;
    photo_service
        .add_photos_to_album(&user.user_id, new_album.id, ids)
        .await?;
    Ok(Json(
        serde_json::to_value(new_album).map_err(|e| AppError(anyhow::anyhow!(e)))?,
    ))
}

// POST /api/albums/update alternative using Request extractor (avoids HeaderMap binding issues)
#[instrument(skip(state, request))]
pub async fn update_album_api(
    State(state): State<Arc<AppState>>,
    request: AxumRequest,
    Json(payload): Json<UpdateAlbumJson>,
) -> Result<impl IntoResponse, AppError> {
    let headers = request.headers();
    let user = get_user_from_headers(headers, &state.auth_service).await?;
    let db = state
        .multi_tenant_db
        .as_ref()
        .ok_or_else(|| {
            AppError(anyhow::anyhow!(
                "Albums/photos ops not supported in Postgres mode yet"
            ))
        })?
        .clone();
    let photo_service = PhotoService::new(db);
    let req = UpdateAlbumRequest {
        name: payload.name,
        description: payload.description,
        cover_photo_id: payload.cover_photo_id,
        parent_id: payload.parent_id,
        position: payload.position,
    };
    let album = photo_service
        .update_album(&user.user_id, payload.id, req)
        .await?;
    Ok(Json(album))
}

#[instrument(skip(state, headers))]
pub async fn delete_album(
    State(state): State<Arc<AppState>>,
    Path(album_id): Path<i32>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, AppError> {
    let user = get_user_from_headers(&headers, &state.auth_service).await?;
    if let Some(pg) = &state.pg_client {
        let _ = pg
            .execute(
                "DELETE FROM albums WHERE organization_id=$1 AND id=$2",
                &[&user.organization_id, &album_id],
            )
            .await;
        return Ok(Json(json!({"message": "Album deleted successfully"})));
    }
    let db = state
        .multi_tenant_db
        .as_ref()
        .ok_or_else(|| {
            AppError(anyhow::anyhow!(
                "Albums/photos ops not supported in Postgres mode yet"
            ))
        })?
        .clone();
    let photo_service = PhotoService::new(db);
    photo_service.delete_album(&user.user_id, album_id).await?;
    Ok(Json(json!({"message": "Album deleted successfully"})))
}

#[instrument(skip(state, headers))]
pub async fn add_photos_to_album(
    State(state): State<Arc<AppState>>,
    Path(album_id): Path<i32>,
    headers: HeaderMap,
    Json(photos_request): Json<AlbumPhotosRequest>,
) -> Result<impl IntoResponse, AppError> {
    let user = get_user_from_headers(&headers, &state.auth_service).await?;
    if let Some(pg) = &state.pg_client {
        let now = chrono::Utc::now().timestamp();
        for pid in photos_request.photo_ids.iter() {
            let _ = pg
                .execute(
                    "INSERT INTO album_photos (organization_id, album_id, photo_id, added_at) VALUES ($1,$2,$3,$4) ON CONFLICT (organization_id, album_id, photo_id) DO NOTHING",
                    &[&user.organization_id, &album_id, pid, &now],
                )
                .await;
        }
        return Ok(Json(
            json!({"message": "Photos added to album successfully"}),
        ));
    }
    let db = state
        .multi_tenant_db
        .as_ref()
        .ok_or_else(|| {
            AppError(anyhow::anyhow!(
                "Albums/photos ops not supported in Postgres mode yet"
            ))
        })?
        .clone();
    let photo_service = PhotoService::new(db);
    photo_service
        .add_photos_to_album(&user.user_id, album_id, photos_request.photo_ids)
        .await?;
    Ok(Json(
        json!({"message": "Photos added to album successfully"}),
    ))
}

#[instrument(skip(state, headers))]
pub async fn remove_photos_from_album(
    State(state): State<Arc<AppState>>,
    Path(album_id): Path<i32>,
    headers: HeaderMap,
    Json(photos_request): Json<AlbumPhotosRequest>,
) -> Result<impl IntoResponse, AppError> {
    let user = get_user_from_headers(&headers, &state.auth_service).await?;
    if let Some(pg) = &state.pg_client {
        for pid in photos_request.photo_ids.iter() {
            let _ = pg
                .execute(
                    "DELETE FROM album_photos WHERE organization_id=$1 AND album_id=$2 AND photo_id=$3",
                    &[&user.organization_id, &album_id, pid],
                )
                .await;
        }
        return Ok(Json(
            json!({"message": "Photos removed from album successfully"}),
        ));
    }
    let db = state
        .multi_tenant_db
        .as_ref()
        .ok_or_else(|| {
            AppError(anyhow::anyhow!(
                "Albums/photos ops not supported in Postgres mode yet"
            ))
        })?
        .clone();
    let photo_service = PhotoService::new(db);
    photo_service
        .remove_photos_from_album(&user.user_id, album_id, photos_request.photo_ids)
        .await?;
    Ok(Json(
        json!({"message": "Photos removed from album successfully"}),
    ))
}

// GET /api/photos/:id/albums - list albums for a given photo id
#[instrument(skip(state, headers))]
pub async fn get_albums_for_photo(
    State(state): State<Arc<AppState>>,
    Path(photo_id): Path<i32>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, AppError> {
    let user = get_user_from_headers(&headers, &state.auth_service).await?;
    if let Some(pg) = &state.pg_client {
        let sql = r#"
            SELECT a.id, a.name, a.description, a.parent_id, a.position, a.cover_photo_id,
                   COALESCE(a.photo_count,0) AS photo_count, a.created_at, a.updated_at,
                   COALESCE(a.is_live,FALSE) AS is_live
            FROM album_photos ap JOIN albums a ON a.id = ap.album_id AND a.organization_id=ap.organization_id
            WHERE ap.organization_id=$1 AND ap.photo_id=$2
            ORDER BY a.created_at DESC
        "#;
        let rows = pg
            .query(sql, &[&user.organization_id, &photo_id])
            .await
            .map_err(|e| AppError(anyhow::anyhow!(e)))?;
        let mut out: Vec<serde_json::Value> = Vec::new();
        for r in rows {
            out.push(serde_json::json!({
                "id": r.get::<_, i32>(0),
                "name": r.get::<_, String>(1),
                "description": r.get::<_, Option<String>>(2),
                "parent_id": r.get::<_, Option<i32>>(3),
                "position": r.get::<_, Option<i32>>(4),
                "cover_photo_id": r.get::<_, Option<i32>>(5),
                "cover_asset_id": serde_json::Value::Null,
                // photo_count column is INTEGER in Postgres; retrieve as i32 to avoid type mismatch
                "photo_count": r.get::<_, i32>(6) as usize,
                "created_at": r.get::<_, i64>(7),
                "updated_at": r.get::<_, i64>(8),
                "depth": 0,
                "is_live": r.get::<_, bool>(9),
            }));
        }
        return Ok(Json(serde_json::Value::Array(out)));
    }
    let db = state
        .multi_tenant_db
        .as_ref()
        .ok_or_else(|| {
            AppError(anyhow::anyhow!(
                "Albums/photos ops not supported in Postgres mode yet"
            ))
        })?
        .clone();
    let photo_service = PhotoService::new(db);
    let albums = photo_service
        .get_albums_for_photo(&user.user_id, photo_id)
        .await?;
    Ok(Json(
        serde_json::to_value(albums).map_err(|e| AppError(anyhow::anyhow!(e)))?,
    ))
}

// Filter endpoints for client-side filtering data
#[instrument(skip(state, headers))]
#[axum::debug_handler]
pub async fn get_filter_metadata(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, AppError> {
    let user = get_user_from_headers(&headers, &state.auth_service).await?;
    // Cities/countries/date/cameras and faces
    let (cities, countries, date_range, cameras, faces) = if let Some(pg) = &state.pg_client {
        // Postgres path (no DuckDB usage)
        let cities_rows = pg
            .query(
                "SELECT DISTINCT city FROM photos WHERE organization_id=$1 AND city IS NOT NULL ORDER BY city",
                &[&user.organization_id],
            )
            .await
            .unwrap_or_default();
        let mut cities: Vec<String> = Vec::new();
        for r in cities_rows {
            cities.push(r.get::<_, String>(0));
        }

        let country_rows = pg
            .query(
                "SELECT DISTINCT country FROM photos WHERE organization_id=$1 AND country IS NOT NULL ORDER BY country",
                &[&user.organization_id],
            )
            .await
            .unwrap_or_default();
        let mut countries: Vec<String> = Vec::new();
        for r in country_rows {
            countries.push(r.get::<_, String>(0));
        }

        let dr_opt = pg
            .query_opt(
                "SELECT MIN(created_at), MAX(created_at) FROM photos WHERE organization_id=$1",
                &[&user.organization_id],
            )
            .await
            .ok()
            .flatten()
            .and_then(|r| {
                // Prefer BIGINT epoch; fall back to TIMESTAMP if DB was initialized with timestamp columns
                let ai: Result<i64, _> = r.try_get(0);
                let bi: Result<i64, _> = r.try_get(1);
                if let (Ok(x), Ok(y)) = (ai, bi) {
                    return Some((x, y));
                }
                let at: Result<chrono::NaiveDateTime, _> = r.try_get(0);
                let bt: Result<chrono::NaiveDateTime, _> = r.try_get(1);
                if let (Ok(x), Ok(y)) = (at, bt) {
                    return Some((x.timestamp(), y.timestamp()));
                }
                None
            });

        let camera_rows = pg
            .query(
                "SELECT DISTINCT camera_model FROM photos WHERE organization_id=$1 AND camera_model IS NOT NULL ORDER BY camera_model",
                &[&user.organization_id],
            )
            .await
            .unwrap_or_default();
        let mut cameras: Vec<String> = Vec::new();
        for r in camera_rows {
            cameras.push(r.get::<_, String>(0));
        }

        // Faces facet: scope to this user's visible photos (per organization)
        let mut faces: Vec<serde_json::Value> = Vec::new();
        if let Ok(rows) = pg
            .query(
                // Faces filter optimization:
                // - If there are many persons and at least one strong cluster (>= 5 assets),
                //   hide tiny clusters (< 5).
                // - If all clusters are small, keep the top 30 so the UI never appears empty.
                "WITH person_counts AS (\n                  SELECT f.person_id,\n                         COALESCE(p.display_name, f.person_id) AS name,\n                         COUNT(DISTINCT f.asset_id) AS cnt\n                  FROM faces f\n                  LEFT JOIN persons p ON p.person_id = f.person_id AND p.organization_id = f.organization_id\n                  JOIN photos dp ON dp.asset_id = f.asset_id AND dp.organization_id = f.organization_id\n                  WHERE f.organization_id = $1 AND dp.user_id = $2 AND f.person_id IS NOT NULL\n                    AND COALESCE(dp.locked, FALSE) = FALSE AND COALESCE(dp.delete_time, 0) = 0\n                  GROUP BY f.person_id, COALESCE(p.display_name, f.person_id)\n                )\n                SELECT person_id, name, cnt\n                FROM (\n                  SELECT *,\n                         COUNT(*) OVER() AS total_persons,\n                         MAX(cnt) OVER() AS max_cnt,\n                         ROW_NUMBER() OVER(ORDER BY cnt DESC, person_id) AS rn\n                  FROM person_counts\n                ) pc\n                WHERE total_persons <= 30\n                   OR (max_cnt >= 5 AND cnt >= 5)\n                   OR (max_cnt < 5 AND rn <= 30)\n                ORDER BY cnt DESC, person_id",
                &[&user.organization_id, &user.user_id],
            )
            .await
        {
            for r in rows {
                faces.push(json!({
                    "person_id": r.get::<_, String>(0),
                    "name": r.get::<_, Option<String>>(1),
                    "photo_count": r.get::<_, i64>(2)
                }));
            }
        }
        (cities, countries, dr_opt, cameras, faces)
    } else {
        // DuckDB path
        // 1) Query scalar filter facets from data DB (release lock ASAP)
        let (cities, countries, date_range, cameras) = {
            let user_db = state
                .multi_tenant_db
                .as_ref()
                .expect("user DB required in DuckDB mode")
                .get_user_database(&user.user_id)?;
            let conn = user_db.lock();

            let mut cities_stmt = conn
                .prepare("SELECT DISTINCT city FROM photos WHERE city IS NOT NULL ORDER BY city")?;
            let cities: Vec<String> = cities_stmt
                .query_map([], |row| row.get::<_, String>(0))?
                .collect::<Result<Vec<_>, _>>()?;

            let mut countries_stmt = conn.prepare(
                "SELECT DISTINCT country FROM photos WHERE country IS NOT NULL ORDER BY country",
            )?;
            let countries: Vec<String> = countries_stmt
                .query_map([], |row| row.get::<_, String>(0))?
                .collect::<Result<Vec<_>, _>>()?;

            let date_range: Option<(i64, i64)> = conn
                .query_row(
                    "SELECT MIN(created_at), MAX(created_at) FROM photos",
                    [],
                    |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?)),
                )
                .ok();

            let mut cameras_stmt = conn.prepare("SELECT DISTINCT camera_model FROM photos WHERE camera_model IS NOT NULL ORDER BY camera_model")?;
            let cameras: Vec<String> = cameras_stmt
                .query_map([], |row| row.get::<_, String>(0))?
                .collect::<Result<Vec<_>, _>>()?;
            (cities, countries, date_range, cameras)
        };

        // 2) Faces facet from embedding DB, intersected with this user's visible photos
        let faces: Vec<serde_json::Value> = {
            let embed_db = state.get_user_embedding_database(&user.user_id)?;
            let econn = embed_db.lock();
            let mut faces: Vec<serde_json::Value> = Vec::new();
            if let Ok(mut stmt) = econn.prepare(
                // Faces filter optimization:
                // - If there are many persons and at least one strong cluster (>= 5 assets),
                //   hide tiny clusters (< 5).
                // - If all clusters are small, keep the top 30 so the UI never appears empty.
                "WITH person_counts AS (\n                 SELECT f.person_id, COALESCE(p.display_name, f.person_id) AS name, COUNT(DISTINCT f.asset_id) AS cnt\n                 FROM faces_embed f\n                 LEFT JOIN persons p ON p.person_id = f.person_id\n                 JOIN photos dp ON dp.asset_id = f.asset_id AND dp.organization_id = ? AND dp.user_id = ?\n                 WHERE f.person_id IS NOT NULL AND COALESCE(dp.locked, FALSE) = FALSE AND COALESCE(dp.delete_time, 0) = 0\n                 GROUP BY f.person_id, COALESCE(p.display_name, f.person_id)\n                )\n                SELECT person_id, name, cnt\n                FROM (\n                  SELECT *,\n                         COUNT(*) OVER() AS total_persons,\n                         MAX(cnt) OVER() AS max_cnt,\n                         ROW_NUMBER() OVER(ORDER BY cnt DESC, person_id) AS rn\n                  FROM person_counts\n                ) pc\n                WHERE total_persons <= 30\n                   OR (max_cnt >= 5 AND cnt >= 5)\n                   OR (max_cnt < 5 AND rn <= 30)\n                ORDER BY cnt DESC, person_id",
            ) {
                if let Ok(rows) = stmt.query_map(duckdb::params![user.organization_id, &user.user_id], |row| {
                    Ok(json!({
                        "person_id": row.get::<_, String>(0)?,
                        "name": row.get::<_, Option<String>>(1)?,
                        "photo_count": row.get::<_, i64>(2)?
                    }))
                }) {
                    for r in rows { if let Ok(v) = r { faces.push(v); } }
                }
            }
            faces
        };

        (cities, countries, date_range, cameras, faces)
    };

    let out = json!({
        "cities": cities,
        "countries": countries,
        "date_range": date_range.map(|(min, max)| json!({"min": min, "max": max})),
        "faces": faces,
        "cameras": cameras
    });
    tracing::info!(
        "[FILTERS] user={} cities={} countries={} faces={}",
        user.user_id,
        out["cities"].as_array().map(|a| a.len()).unwrap_or(0),
        out["countries"].as_array().map(|a| a.len()).unwrap_or(0),
        out["faces"].as_array().map(|a| a.len()).unwrap_or(0)
    );
    Ok(Json(out))
}

#[derive(Debug, Serialize)]
pub struct RefreshMetadataResponse {
    pub asset_id: String,
    pub updated: bool,
    pub camera_make: Option<String>,
    pub camera_model: Option<String>,
    pub iso: Option<i32>,
    pub aperture: Option<f32>,
    pub shutter_speed: Option<String>,
    pub focal_length: Option<f32>,
    pub created_at: i64,
    pub latitude: Option<f64>,
    pub longitude: Option<f64>,
    pub altitude: Option<f64>,
}

#[instrument(skip(state, headers))]
pub async fn refresh_photo_metadata(
    State(state): State<Arc<AppState>>,
    Path(asset_id): Path<String>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, AppError> {
    let user = get_user_from_headers(&headers, &state.auth_service).await?;
    let data_db = state.get_user_data_database(&user.user_id)?;
    let conn = data_db.lock();
    let mut path_opt: Option<String> = None;
    if let Ok(mut stmt) =
        conn.prepare("SELECT path FROM photos WHERE organization_id = ? AND asset_id = ? LIMIT 1")
    {
        let r = stmt.query_row(duckdb::params![user.organization_id, &asset_id], |row| {
            row.get::<_, String>(0)
        });
        if let Ok(p) = r {
            path_opt = Some(p);
        }
    }
    drop(conn);
    let Some(path_str) = path_opt else {
        return Ok(Json(
            serde_json::json!({ "error": "asset not found", "asset_id": asset_id }),
        ));
    };

    // Build a temporary Photo from file and parse EXIF purely in Rust
    let path = std::path::Path::new(&path_str);
    let mut tmp = PhotoDTO2::from_path(path, &user.user_id)
        .map_err(|e| anyhow::anyhow!("from_path: {}", e))?;
    // Keep current DB created_at to avoid overwriting client-provided timestamp when EXIF has no capture date
    let current_created: i64 = {
        let conn0 = data_db.lock();
        conn0
            .prepare(
                "SELECT created_at FROM photos WHERE organization_id = ? AND asset_id = ? LIMIT 1",
            )
            .ok()
            .and_then(|mut s| {
                s.query_row(duckdb::params![user.organization_id, &asset_id], |row| {
                    row.get::<_, i64>(0)
                })
                .ok()
            })
            .unwrap_or(tmp.created_at)
    };
    extract_metadata(&mut tmp).map_err(|e| anyhow::anyhow!("extract_metadata: {}", e))?;
    // Decide whether to update created_at: only if EXIF contains a capture date (DateTimeOriginal/DateTime)
    let mut created_for_db = current_created.max(0);
    if let Ok(file) = std::fs::File::open(path) {
        let mut reader = std::io::BufReader::new(file);
        if let Ok(ex) = exif::Reader::new().read_from_container(&mut reader) {
            let has_dt = ex
                .get_field(Tag::DateTimeOriginal, In::PRIMARY)
                .or_else(|| ex.get_field(Tag::DateTime, In::PRIMARY))
                .is_some();
            if has_dt && tmp.created_at > 0 {
                created_for_db = tmp.created_at;
            }
        }
    }

    // Write updates back to DB
    let conn = data_db.lock();
    let _ = conn.execute(
        "UPDATE photos SET camera_make = ?, camera_model = ?, iso = ?, aperture = ?, shutter_speed = ?, focal_length = ?, created_at = ?, latitude = ?, longitude = ?, altitude = ? WHERE asset_id = ?",
        duckdb::params![
            &tmp.camera_make,
            &tmp.camera_model,
            tmp.iso,
            tmp.aperture,
            &tmp.shutter_speed,
            tmp.focal_length,
            created_for_db,
            tmp.latitude,
            tmp.longitude,
            tmp.altitude,
            &asset_id
        ],
    );
    drop(conn);

    let resp = RefreshMetadataResponse {
        asset_id: asset_id.clone(),
        updated: true,
        camera_make: tmp.camera_make.clone(),
        camera_model: tmp.camera_model.clone(),
        iso: tmp.iso,
        aperture: tmp.aperture,
        shutter_speed: tmp.shutter_speed.clone(),
        focal_length: tmp.focal_length,
        created_at: created_for_db,
        latitude: tmp.latitude,
        longitude: tmp.longitude,
        altitude: tmp.altitude,
    };
    // Reindex asset so created_at or other updated fields take effect in text search filters
    if let Err(e) = reindex_single_asset(&state, &user.user_id, &asset_id) {
        tracing::warn!("[SEARCH] reindex on metadata refresh failed: {}", e);
    }
    Ok(Json(serde_json::to_value(resp).unwrap()))
}

// --- Album merge ---
#[derive(Debug, Deserialize)]
pub struct MergeAlbumsRequest {
    pub source_album_id: i32,
    pub target_album_id: i32,
    pub delete_source: Option<bool>,
    pub dry_run: Option<bool>,
}

#[derive(Debug, Serialize)]
pub struct MergeAlbumsResponse {
    pub added_count: i64,
    pub skipped_count: i64,
    pub total_in_target: i64,
    pub deleted_source: bool,
}

#[instrument(skip(state, headers))]
pub async fn merge_albums(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(payload): Json<MergeAlbumsRequest>,
) -> Result<Json<MergeAlbumsResponse>, AppError> {
    let user = get_user_from_headers(&headers, &state.auth_service).await?;
    let db = state
        .multi_tenant_db
        .as_ref()
        .ok_or_else(|| {
            AppError(anyhow::anyhow!(
                "Albums/photos ops not supported in Postgres mode yet"
            ))
        })?
        .clone();
    let photo_service = PhotoService::new(db);

    let delete_source = payload.delete_source.unwrap_or(true);
    let dry_run = payload.dry_run.unwrap_or(false);

    let (added, skipped, total_after, deleted) = photo_service
        .merge_albums(
            &user.user_id,
            payload.source_album_id,
            payload.target_album_id,
            delete_source,
            dry_run,
        )
        .await?;

    Ok(Json(MergeAlbumsResponse {
        added_count: added,
        skipped_count: skipped,
        total_in_target: total_after,
        deleted_source: deleted,
    }))
}

// --- Admin/repair utilities ---
/// POST /api/admin/purge-smart-search-image-data
///
/// Removes embedded image BLOBs from `smart_search.image_data` for the authenticated user's
/// assets. This is safe and idempotent: it does not delete photos or embeddings, only clears the
/// optional preview bytes that historically caused massive DuckDB bloat.
///
/// Note: DuckDB does not immediately shrink the on-disk file when rows are updated. To reclaim
/// disk space after this purge, run the offline repack script (see `scripts/repack_duckdb_data.sh`)
/// while the server is stopped.
#[instrument(skip(state, headers))]
pub async fn purge_smart_search_image_data(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, AppError> {
    let user = get_user_from_headers(&headers, &state.auth_service).await?;

    // Postgres backend: update directly with tenant scoping via photos table.
    if let Some(pg) = &state.pg_client {
        let updated = pg
            .execute(
                "UPDATE smart_search
                 SET image_data = NULL
                 WHERE image_data IS NOT NULL
                   AND asset_id IN (
                        SELECT asset_id FROM photos
                        WHERE organization_id = $1 AND user_id = $2
                   )",
                &[&user.organization_id, &user.user_id],
            )
            .await
            .map_err(|e| AppError(anyhow::anyhow!(e)))?;
        return Ok((
            StatusCode::OK,
            Json(json!({ "ok": true, "updated_rows": updated })),
        ));
    }

    // DuckDB backend: run in a blocking task so we don't stall the Tokio executor.
    let data_db = state.get_user_data_database(&user.user_id)?;
    let org_id = user.organization_id;
    let user_id = user.user_id.clone();
    let updated = tokio::task::spawn_blocking(move || -> Result<usize, anyhow::Error> {
        let conn = data_db.lock();
        let n = conn.execute(
            "UPDATE smart_search
             SET image_data = NULL
             WHERE image_data IS NOT NULL
               AND asset_id IN (
                    SELECT asset_id FROM photos
                    WHERE organization_id = ? AND user_id = ?
               )",
            duckdb::params![org_id, user_id],
        )?;
        Ok(n)
    })
    .await
    .map_err(|e| AppError(anyhow::anyhow!(e)))??;

    Ok((
        StatusCode::OK,
        Json(json!({ "ok": true, "updated_rows": updated })),
    ))
}

#[derive(Debug, serde::Serialize)]
struct RepairReport {
    scanned: i64,
    paired: i64,
    deleted: i64,
    migrated_memberships: i64,
    already_linked: i64,
    unmatched: i64,
}

fn normalize_stem_for_repair(name: &str) -> String {
    let stem = name.rsplit_once('.').map(|(s, _)| s).unwrap_or(name).trim();
    let up = stem.to_ascii_uppercase();
    if let Some(tail) = up.strip_prefix("IMG_E") {
        format!("IMG_{}", tail)
    } else {
        up
    }
}

/// POST /api/admin/repair/live-photos
/// Scans for short MOVs, pairs them with still images, and removes redundant video rows.
#[instrument(skip(state, headers))]
pub async fn repair_live_photos(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, AppError> {
    let user = get_user_from_headers(&headers, &state.auth_service).await?;
    let data_db = state.get_user_data_database(&user.user_id)?;

    let mut report = RepairReport {
        scanned: 0,
        paired: 0,
        deleted: 0,
        migrated_memberships: 0,
        already_linked: 0,
        unmatched: 0,
    };
    let conn = data_db.lock();
    let _ = conn.execute("BEGIN TRANSACTION", []);
    let _ = conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_photos_path ON photos(path)",
        [],
    );
    let _ = conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_photos_filename ON photos(filename)",
        [],
    );
    let _ = conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_photos_created ON photos(created_at)",
        [],
    );

    // Remove videos that are referenced by a photo's live_video_path
    let mut direct_pairs: Vec<(i32, i32, String, i32)> = Vec::new();
    if let Ok(mut stmt) = conn.prepare(
        "SELECT v.organization_id, v.id, v.path, p.id
         FROM photos v
         JOIN photos p ON p.organization_id = v.organization_id AND p.is_video = 0 AND COALESCE(p.live_video_path,'') = v.path
         WHERE v.is_video = 1",
    ) {
        if let Ok(rows) = stmt.query_map([], |row| {
            Ok((
                row.get::<_, i32>(0)?,  // organization_id
                row.get::<_, i32>(1)?,  // video id (v.id)
                row.get::<_, String>(2)?, // video path (v.path)
                row.get::<_, i32>(3)?,  // photo id (p.id)
            ))
        }) {
            for r in rows {
                if let Ok(t) = r {
                    direct_pairs.push(t);
                }
            }
        }
    }
    for (org_id, video_id, _vpath, photo_id) in direct_pairs.into_iter() {
        report.migrated_memberships += conn
            .execute(
                "INSERT INTO album_photos (organization_id, album_id, photo_id, added_at)
             SELECT organization_id, album_id, ?, added_at FROM album_photos WHERE organization_id = ? AND photo_id = ?
             ON CONFLICT (organization_id, album_id, photo_id) DO NOTHING",
                duckdb::params![photo_id, org_id, video_id],
            )
            .unwrap_or(0) as i64;
        let _ = conn.execute(
            "DELETE FROM album_photos WHERE organization_id = ? AND photo_id = ?",
            duckdb::params![org_id, video_id],
        );
        report.deleted += conn
            .execute(
                "DELETE FROM photos WHERE id = ? AND is_video = 1",
                duckdb::params![video_id],
            )
            .unwrap_or(0) as i64;
        report.paired += 1;
    }

    // Short video candidates (<= 3s)
    let mut vids: Vec<(i32, i32, String, String, i64, i64)> = Vec::new();
    if let Ok(mut stmt) = conn.prepare(
        "SELECT organization_id, id, path, filename, created_at, COALESCE(duration_ms, 0)
         FROM photos WHERE is_video = 1 AND COALESCE(duration_ms, 0) <= 3000",
    ) {
        if let Ok(rows) = stmt.query_map([], |row| {
            Ok((
                row.get::<_, i32>(0)?, // org
                row.get::<_, i32>(1)?, // id
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, i64>(4)?,
                row.get::<_, i64>(5)?,
            ))
        }) {
            for r in rows {
                if let Ok(t) = r {
                    vids.push(t);
                }
            }
        }
    }
    report.scanned += vids.len() as i64;

    for (org_id, video_id, vpath, vname, vts, _dur) in vids.into_iter() {
        // Only treat true Live Photo motion components as repair candidates.
        if !crate::video::is_live_photo_component(std::path::Path::new(&vpath)) {
            continue;
        }
        // Skip if this MOV is already referenced
        let referenced: Option<i32> = conn
            .prepare("SELECT id FROM photos WHERE organization_id = ? AND is_video = 0 AND COALESCE(live_video_path,'') = ? LIMIT 1")
            .ok()
            .and_then(|mut s| s.query_row(duckdb::params![org_id, &vpath], |row| row.get::<_, i32>(0)).ok());
        if let Some(photo_id) = referenced {
            report.migrated_memberships += conn
                .execute(
                    "INSERT INTO album_photos (organization_id, album_id, photo_id, added_at)
                 SELECT organization_id, album_id, ?, added_at FROM album_photos WHERE organization_id = ? AND photo_id = ?
                 ON CONFLICT (organization_id, album_id, photo_id) DO NOTHING",
                    duckdb::params![photo_id, org_id, video_id],
                )
                .unwrap_or(0) as i64;
            let _ = conn.execute(
                "DELETE FROM album_photos WHERE organization_id = ? AND photo_id = ?",
                duckdb::params![org_id, video_id],
            );
            report.deleted += conn
                .execute(
                    "DELETE FROM photos WHERE id = ? AND is_video = 1",
                    duckdb::params![video_id],
                )
                .unwrap_or(0) as i64;
            report.already_linked += 1;
            continue;
        }

        // Stem match
        let stem = normalize_stem_for_repair(&vname);
        let like_pat = format!("{}.%", stem);
        let photo_id_by_name: Option<i32> = conn
            .prepare("SELECT id FROM photos WHERE organization_id = ? AND is_video = 0 AND upper(replace(filename, 'IMG_E', 'IMG_')) LIKE ? LIMIT 1")
            .ok()
            .and_then(|mut s| s.query_row(duckdb::params![org_id, &like_pat], |row| row.get::<_, i32>(0)).ok());

        // Time proximity fallback
        let window: i64 = std::env::var("LIVE_PAIR_WINDOW_SECS")
            .ok()
            .and_then(|s| s.parse::<i64>().ok())
            .unwrap_or(300);
        let photo_id_time: Option<i32> = if photo_id_by_name.is_none() {
            conn.prepare("SELECT id FROM photos WHERE organization_id = ? AND is_video = 0 AND ABS(created_at - ?) <= ? ORDER BY ABS(created_at - ?) ASC LIMIT 1")
                .ok()
                .and_then(|mut s| s.query_row(duckdb::params![org_id, vts, window, vts], |row| row.get::<_, i32>(0)).ok())
        } else {
            None
        };

        let photo_id = photo_id_by_name.or(photo_id_time);
        if let Some(pid) = photo_id {
            let _ = conn.execute(
                "UPDATE photos SET is_live_photo = TRUE, live_video_path = COALESCE(live_video_path, ?) WHERE id = ?",
                duckdb::params![&vpath, pid],
            );
            report.migrated_memberships += conn
                .execute(
                    "INSERT INTO album_photos (organization_id, album_id, photo_id, added_at)
                 SELECT organization_id, album_id, ?, added_at FROM album_photos WHERE organization_id = ? AND photo_id = ?
                 ON CONFLICT (organization_id, album_id, photo_id) DO NOTHING",
                    duckdb::params![pid, org_id, video_id],
                )
                .unwrap_or(0) as i64;
            let _ = conn.execute(
                "DELETE FROM album_photos WHERE organization_id = ? AND photo_id = ?",
                duckdb::params![org_id, video_id],
            );
            report.deleted += conn
                .execute(
                    "DELETE FROM photos WHERE id = ? AND is_video = 1",
                    duckdb::params![video_id],
                )
                .unwrap_or(0) as i64;
            report.paired += 1;
        } else {
            // Still unmatched, but confirmed this is a Live Photo motion component: hide it from Videos.
            let _ = conn.execute(
                "UPDATE photos SET is_live_photo = TRUE WHERE id = ?",
                duckdb::params![video_id],
            );
            report.unmatched += 1;
        }
    }

    let _ = conn.execute("COMMIT", []);
    Ok(Json(report))
}
// Buckets (years/quarters)
#[derive(Debug, Serialize)]
pub struct YearBucket {
    pub year: i32,
    pub count: i64,
    pub first_ts: i64,
    pub last_ts: i64,
}

#[derive(Debug, Serialize)]
pub struct QuarterBucket {
    pub quarter: i32,
    pub count: i64,
    pub first_ts: i64,
    pub last_ts: i64,
}

#[instrument(skip(state, headers))]
pub async fn bucket_years(
    State(state): State<Arc<AppState>>,
    Query(incoming): Query<PhotoListQuery>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, AppError> {
    let user = get_user_from_headers(&headers, &state.auth_service).await?;
    let data_db = state.get_user_data_database(&user.user_id)?;
    let mut query = incoming;
    let started = Instant::now();

    // Resolve live album criteria if needed (mirrors /api/photos).
    let target_album_id = query.album_id.or_else(|| {
        query.album_ids.as_ref().and_then(|ids_str| {
            let ids: Vec<i32> = ids_str
                .split(',')
                .filter_map(|s| s.trim().parse::<i32>().ok())
                .collect();
            if ids.len() == 1 {
                Some(ids[0])
            } else {
                None
            }
        })
    });
    if let Some(album_id) = target_album_id {
        let (is_live, crit_json) = {
            let conn = data_db.lock();
            let mut is_live = false;
            let mut crit_json: Option<String> = None;
            if let Ok(mut stmt) = conn.prepare(
                "SELECT COALESCE(is_live, FALSE), live_criteria FROM albums WHERE organization_id = ? AND id = ? LIMIT 1",
            ) {
                let row = stmt.query_row(duckdb::params![user.organization_id, album_id], |row| {
                    Ok::<(bool, Option<String>), duckdb::Error>((row.get(0)?, row.get(1).ok()))
                });
                if let Ok((flag, cj)) = row {
                    is_live = flag;
                    crit_json = cj;
                }
            }
            (is_live, crit_json)
        };
        if is_live {
            if let Some(cj) = crit_json {
                if let Ok(mut crit) = serde_json::from_str::<PhotoListQuery>(&cj) {
                    // prevent recursion
                    crit.album_id = None;
                    crit.album_ids = None;
                    crit.album_subtree = None;
                    query = crit;
                }
            }
        }
    }

    let mut where_clauses: Vec<String> = Vec::new();
    // Always scope by organization and owner user for safety
    where_clauses.push(format!("p.organization_id = {}", user.organization_id));
    where_clauses.push(format!("p.user_id = '{}'", user.user_id.replace("'", "''")));
    let mut joins: Vec<String> = Vec::new();

    if let Some(fav) = query.filter_favorite {
        if fav {
            where_clauses.push("p.favorites > 0".to_string());
        }
    }
    if let Some(minr) = query.filter_rating_min {
        if minr > 0 {
            where_clauses.push(format!("COALESCE(p.rating, 0) >= {}", minr.min(5)));
        }
    }
    if let Some(is_video) = query.filter_is_video {
        where_clauses.push(format!("p.is_video = {}", if is_video { 1 } else { 0 }));
    }
    // Location filters
    if let Some(city) = &query.filter_city {
        where_clauses.push(format!("p.city = '{}'", city.replace("'", "''")));
    }
    if let Some(country) = &query.filter_country {
        where_clauses.push(format!("p.country = '{}'", country.replace("'", "''")));
    }
    // Time range filters (created_at is photo taken time when EXIF is available)
    if let Some(date_from) = query.filter_date_from {
        where_clauses.push(format!("p.created_at >= {}", date_from));
    }
    if let Some(date_to) = query.filter_date_to {
        where_clauses.push(format!("p.created_at <= {}", date_to));
    }
    // Screenshot filter: always excludes videos
    if let Some(s) = query.filter_screenshot {
        if s {
            where_clauses.push("p.is_screenshot = 1".to_string());
            where_clauses.push("p.is_video = 0".to_string());
        } else {
            where_clauses.push("p.is_screenshot = 0".to_string());
        }
    }
    // Live Photos are photos, not videos
    if let Some(live) = query.filter_live_photo {
        where_clauses.push(format!("p.is_live_photo = {}", if live { 1 } else { 0 }));
        if live {
            where_clauses.push("p.is_video = 0".to_string());
        }
    }

    // Album filters (mirror /api/photos)
    {
        let conn = data_db.lock();
        if let Some(ref ids_csv) = query.album_ids {
            // AND semantics across selected roots: one join per root (expanded to descendants when enabled)
            let base_ids: Vec<i32> = ids_csv
                .split(',')
                .filter_map(|s| s.trim().parse::<i32>().ok())
                .collect();
            if !base_ids.is_empty() {
                let include_desc = query.album_subtree.unwrap_or(true);
                for (idx, root_id) in base_ids.iter().enumerate() {
                    let mut group: Vec<i32> = vec![*root_id];
                    if include_desc {
                        if let Ok(mut stmt) = conn.prepare(
                            "SELECT descendant_id FROM album_closure WHERE organization_id = ? AND ancestor_id = ?",
                        ) {
                            if let Ok(rows) = stmt.query_map(duckdb::params![user.organization_id, *root_id], |row| row.get::<_, i32>(0)) {
                                for r in rows {
                                    if let Ok(id) = r {
                                        group.push(id);
                                    }
                                }
                            }
                        }
                    }
                    group.sort();
                    group.dedup();
                    let inlist = group
                        .iter()
                        .map(|id| id.to_string())
                        .collect::<Vec<_>>()
                        .join(",");
                    let alias = format!("ap{}", idx);
                    joins.push(format!(
                        "INNER JOIN album_photos {} ON {}.organization_id = p.organization_id AND p.id = {}.photo_id AND {}.album_id IN ({})",
                        alias, alias, alias, alias, inlist
                    ));
                }
            }
        } else if let Some(album_id) = query.album_id {
            joins.push("INNER JOIN album_photos ap ON ap.organization_id = p.organization_id AND p.id = ap.photo_id".to_string());
            // Default to include descendants when filtering by album
            if query.album_subtree.unwrap_or(true) {
                let mut collected: Vec<i32> = vec![album_id];
                if let Ok(mut stmt) = conn.prepare(
                    "SELECT descendant_id FROM album_closure WHERE organization_id = ? AND ancestor_id = ?",
                ) {
                    if let Ok(rows) = stmt.query_map(duckdb::params![user.organization_id, album_id], |row| row.get::<_, i32>(0)) {
                        for r in rows {
                            if let Ok(id) = r {
                                collected.push(id);
                            }
                        }
                    }
                }
                collected.sort();
                collected.dedup();
                let inlist = collected
                    .iter()
                    .map(|id| id.to_string())
                    .collect::<Vec<_>>()
                    .join(",");
                where_clauses.push(format!("ap.album_id IN ({})", inlist));
            } else {
                where_clauses.push(format!("ap.album_id = {}", album_id));
            }
        }
    }

    // Faces filter (mirror /api/photos DuckDB mode)
    if let Some(face_param) = &query.filter_faces {
        let ids: Vec<String> = face_param
            .split(',')
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .map(|s| s.to_string())
            .collect();
        if !ids.is_empty() {
            let embed_db = state.get_user_embedding_database(&user.user_id)?;
            let conn_e = embed_db.lock();
            let ids_list = ids
                .iter()
                .map(|s| format!("'{}'", s.replace("'", "''")))
                .collect::<Vec<_>>()
                .join(",");
            let org_id = user.organization_id;
            let user_id = user.user_id.replace("'", "''");
            let sql = match query.filter_faces_mode.as_deref() {
                Some("any") => format!(
                    "SELECT DISTINCT f.asset_id FROM faces_embed f JOIN photos dp ON dp.asset_id = f.asset_id WHERE dp.organization_id = {} AND dp.user_id = '{}' AND f.person_id IN ({})",
                    org_id, user_id, ids_list
                ),
                _ => format!(
                    "SELECT f.asset_id FROM faces_embed f JOIN photos dp ON dp.asset_id = f.asset_id WHERE dp.organization_id = {} AND dp.user_id = '{}' AND f.person_id IN ({}) GROUP BY f.asset_id HAVING COUNT(DISTINCT f.person_id) = {}",
                    org_id, user_id, ids_list, ids.len()
                ),
            };
            let mut asset_ids: Vec<String> = Vec::new();
            if let Ok(mut stmt) = conn_e.prepare(&sql) {
                if let Ok(rows) = stmt.query_map([], |row| row.get::<_, String>(0)) {
                    for r in rows {
                        if let Ok(a) = r {
                            asset_ids.push(a);
                        }
                    }
                }
            }
            if asset_ids.is_empty() {
                return Ok(Json(Vec::<YearBucket>::new()));
            }
            let inlist = asset_ids
                .iter()
                .map(|s| format!("'{}'", s.replace("'", "''")))
                .collect::<Vec<_>>()
                .join(",");
            where_clauses.push(format!("p.asset_id IN ({})", inlist));
        }
    }

    // Text search filter (mirror /api/photos): use embedding store to get candidate asset_ids and filter by IN (...)
    if let Some(ref q) = query.q {
        let qtrim = q.trim();
        if !qtrim.is_empty() {
            let store = state.create_user_embedding_store(&user.user_id)?;
            let model_name = state.default_model.clone();
            let embedding = state
                .with_textual_encoder(Some(&model_name), |enc| enc.encode_text(qtrim))
                .ok_or_else(|| anyhow::anyhow!("Text encoder not available"))??;
            let results = store.search_combined(qtrim, embedding, 5000).await?;
            let ids: Vec<String> = results.into_iter().map(|r| r.asset_id).collect();
            if ids.is_empty() {
                return Ok(Json(Vec::<YearBucket>::new()));
            }
            let inlist = ids
                .into_iter()
                .map(|s| format!("'{}'", s.replace("'", "''")))
                .collect::<Vec<_>>()
                .join(",");
            where_clauses.push(format!("p.asset_id IN ({})", inlist));
        }
    }

    // Enforce locked filtering by default; support locked-only and include_locked
    let include_locked = query.include_locked.unwrap_or(false);
    let locked_only = query.filter_locked_only.unwrap_or(false);
    if locked_only {
        where_clauses.push("COALESCE(p.locked, FALSE) = TRUE".to_string());
    } else if !include_locked {
        where_clauses.push("COALESCE(p.locked, FALSE) = FALSE".to_string());
    }

    let include_trashed = query.include_trashed.unwrap_or(false);
    let trashed_only = query.filter_trashed_only.unwrap_or(false);
    if trashed_only {
        where_clauses.push("COALESCE(p.delete_time, 0) > 0".to_string());
    } else if !include_trashed {
        where_clauses.push("COALESCE(p.delete_time, 0) = 0".to_string());
    }

    let mut out: Vec<YearBucket> = Vec::new();
    let mut base = String::from("SELECT DISTINCT p.id, p.created_at FROM photos p");
    for j in &joins {
        base.push(' ');
        base.push_str(j);
    }
    if !where_clauses.is_empty() {
        base.push_str(" WHERE ");
        base.push_str(&where_clauses.join(" AND "));
    }
    let sql = format!(
        "SELECT CAST(date_part('year', to_timestamp(created_at)) AS INTEGER) AS y, \
                COUNT(*) AS c, \
                MIN(created_at) AS first_ts, \
                MAX(created_at) AS last_ts \
         FROM ({}) AS sub \
         GROUP BY 1 \
         ORDER BY y DESC",
        base
    );
    let conn = data_db.lock();
    if let Ok(mut stmt) = conn.prepare(&sql) {
        let rows = stmt.query_map([], |row| {
            Ok(YearBucket {
                year: row.get::<_, i32>(0)?,
                count: row.get::<_, i64>(1)?,
                first_ts: row.get::<_, i64>(2)?,
                last_ts: row.get::<_, i64>(3)?,
            })
        })?;
        for r in rows {
            out.push(r?);
        }
    }
    let ms = started.elapsed().as_millis();
    tracing::info!(
        target = "perf",
        "[BUCKET_YEARS] years={} ms={} user={} org={}",
        out.len(),
        ms,
        user.user_id,
        user.organization_id
    );
    Ok(Json(out))
}

#[derive(Debug, Deserialize)]
pub struct BucketQuarterParams {
    pub year: i32,
    #[serde(flatten)]
    pub query: PhotoListQuery,
}

#[instrument(skip(state, headers))]
pub async fn bucket_quarters(
    State(state): State<Arc<AppState>>,
    Query(params): Query<BucketQuarterParams>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, AppError> {
    let user = get_user_from_headers(&headers, &state.auth_service).await?;
    let data_db = state.get_user_data_database(&user.user_id)?;
    let mut query = params.query;
    let started = Instant::now();

    // Resolve live album criteria if needed (mirrors /api/photos).
    let target_album_id = query.album_id.or_else(|| {
        query.album_ids.as_ref().and_then(|ids_str| {
            let ids: Vec<i32> = ids_str
                .split(',')
                .filter_map(|s| s.trim().parse::<i32>().ok())
                .collect();
            if ids.len() == 1 {
                Some(ids[0])
            } else {
                None
            }
        })
    });
    if let Some(album_id) = target_album_id {
        let (is_live, crit_json) = {
            let conn = data_db.lock();
            let mut is_live = false;
            let mut crit_json: Option<String> = None;
            if let Ok(mut stmt) = conn.prepare(
                "SELECT COALESCE(is_live, FALSE), live_criteria FROM albums WHERE organization_id = ? AND id = ? LIMIT 1",
            ) {
                let row = stmt.query_row(duckdb::params![user.organization_id, album_id], |row| {
                    Ok::<(bool, Option<String>), duckdb::Error>((row.get(0)?, row.get(1).ok()))
                });
                if let Ok((flag, cj)) = row {
                    is_live = flag;
                    crit_json = cj;
                }
            }
            (is_live, crit_json)
        };
        if is_live {
            if let Some(cj) = crit_json {
                if let Ok(mut crit) = serde_json::from_str::<PhotoListQuery>(&cj) {
                    // prevent recursion
                    crit.album_id = None;
                    crit.album_ids = None;
                    crit.album_subtree = None;
                    query = crit;
                }
            }
        }
    }

    let mut where_clauses: Vec<String> = Vec::new();
    where_clauses.push(format!("p.organization_id = {}", user.organization_id));
    where_clauses.push(format!("p.user_id = '{}'", user.user_id.replace("'", "''")));
    let mut joins: Vec<String> = Vec::new();

    if let Some(fav) = query.filter_favorite {
        if fav {
            where_clauses.push("p.favorites > 0".to_string());
        }
    }
    if let Some(minr) = query.filter_rating_min {
        if minr > 0 {
            where_clauses.push(format!("COALESCE(p.rating, 0) >= {}", minr.min(5)));
        }
    }
    if let Some(is_video) = query.filter_is_video {
        where_clauses.push(format!("p.is_video = {}", if is_video { 1 } else { 0 }));
    }
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
        where_clauses.push(format!("p.created_at <= {}", date_to));
    }
    if let Some(s) = query.filter_screenshot {
        if s {
            where_clauses.push("p.is_screenshot = 1".to_string());
            where_clauses.push("p.is_video = 0".to_string());
        } else {
            where_clauses.push("p.is_screenshot = 0".to_string());
        }
    }
    if let Some(live) = query.filter_live_photo {
        where_clauses.push(format!("p.is_live_photo = {}", if live { 1 } else { 0 }));
        if live {
            where_clauses.push("p.is_video = 0".to_string());
        }
    }

    // Album filters (mirror /api/photos)
    {
        let conn = data_db.lock();
        if let Some(ref ids_csv) = query.album_ids {
            let base_ids: Vec<i32> = ids_csv
                .split(',')
                .filter_map(|s| s.trim().parse::<i32>().ok())
                .collect();
            if !base_ids.is_empty() {
                let include_desc = query.album_subtree.unwrap_or(true);
                for (idx, root_id) in base_ids.iter().enumerate() {
                    let mut group: Vec<i32> = vec![*root_id];
                    if include_desc {
                        if let Ok(mut stmt) = conn.prepare(
                            "SELECT descendant_id FROM album_closure WHERE organization_id = ? AND ancestor_id = ?",
                        ) {
                            if let Ok(rows) = stmt.query_map(duckdb::params![user.organization_id, *root_id], |row| row.get::<_, i32>(0)) {
                                for r in rows {
                                    if let Ok(id) = r {
                                        group.push(id);
                                    }
                                }
                            }
                        }
                    }
                    group.sort();
                    group.dedup();
                    let inlist = group
                        .iter()
                        .map(|id| id.to_string())
                        .collect::<Vec<_>>()
                        .join(",");
                    let alias = format!("ap{}", idx);
                    joins.push(format!(
                        "INNER JOIN album_photos {} ON {}.organization_id = p.organization_id AND p.id = {}.photo_id AND {}.album_id IN ({})",
                        alias, alias, alias, alias, inlist
                    ));
                }
            }
        } else if let Some(album_id) = query.album_id {
            joins.push("INNER JOIN album_photos ap ON ap.organization_id = p.organization_id AND p.id = ap.photo_id".to_string());
            if query.album_subtree.unwrap_or(true) {
                let mut collected: Vec<i32> = vec![album_id];
                if let Ok(mut stmt) = conn.prepare(
                    "SELECT descendant_id FROM album_closure WHERE organization_id = ? AND ancestor_id = ?",
                ) {
                    if let Ok(rows) = stmt.query_map(duckdb::params![user.organization_id, album_id], |row| row.get::<_, i32>(0)) {
                        for r in rows {
                            if let Ok(id) = r {
                                collected.push(id);
                            }
                        }
                    }
                }
                collected.sort();
                collected.dedup();
                let inlist = collected
                    .iter()
                    .map(|id| id.to_string())
                    .collect::<Vec<_>>()
                    .join(",");
                where_clauses.push(format!("ap.album_id IN ({})", inlist));
            } else {
                where_clauses.push(format!("ap.album_id = {}", album_id));
            }
        }
    }

    if let Some(face_param) = &query.filter_faces {
        let ids: Vec<String> = face_param
            .split(',')
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .map(|s| s.to_string())
            .collect();
        if !ids.is_empty() {
            let embed_db = state.get_user_embedding_database(&user.user_id)?;
            let conn_e = embed_db.lock();
            let ids_list = ids
                .iter()
                .map(|s| format!("'{}'", s.replace("'", "''")))
                .collect::<Vec<_>>()
                .join(",");
            let org_id = user.organization_id;
            let user_id = user.user_id.replace("'", "''");
            let sql = match query.filter_faces_mode.as_deref() {
                Some("any") => format!(
                    "SELECT DISTINCT f.asset_id FROM faces_embed f JOIN photos dp ON dp.asset_id = f.asset_id WHERE dp.organization_id = {} AND dp.user_id = '{}' AND f.person_id IN ({})",
                    org_id, user_id, ids_list
                ),
                _ => format!(
                    "SELECT f.asset_id FROM faces_embed f JOIN photos dp ON dp.asset_id = f.asset_id WHERE dp.organization_id = {} AND dp.user_id = '{}' AND f.person_id IN ({}) GROUP BY f.asset_id HAVING COUNT(DISTINCT f.person_id) = {}",
                    org_id, user_id, ids_list, ids.len()
                ),
            };
            let mut asset_ids: Vec<String> = Vec::new();
            if let Ok(mut stmt) = conn_e.prepare(&sql) {
                if let Ok(rows) = stmt.query_map([], |row| row.get::<_, String>(0)) {
                    for r in rows {
                        if let Ok(a) = r {
                            asset_ids.push(a);
                        }
                    }
                }
            }
            if asset_ids.is_empty() {
                return Ok(Json(Vec::<QuarterBucket>::new()));
            }
            let inlist = asset_ids
                .iter()
                .map(|s| format!("'{}'", s.replace("'", "''")))
                .collect::<Vec<_>>()
                .join(",");
            where_clauses.push(format!("p.asset_id IN ({})", inlist));
        }
    }

    if let Some(ref q) = query.q {
        let qtrim = q.trim();
        if !qtrim.is_empty() {
            let store = state.create_user_embedding_store(&user.user_id)?;
            let model_name = state.default_model.clone();
            let embedding = state
                .with_textual_encoder(Some(&model_name), |enc| enc.encode_text(qtrim))
                .ok_or_else(|| anyhow::anyhow!("Text encoder not available"))??;
            let results = store.search_combined(qtrim, embedding, 5000).await?;
            let ids: Vec<String> = results.into_iter().map(|r| r.asset_id).collect();
            if ids.is_empty() {
                return Ok(Json(Vec::<QuarterBucket>::new()));
            }
            let inlist = ids
                .into_iter()
                .map(|s| format!("'{}'", s.replace("'", "''")))
                .collect::<Vec<_>>()
                .join(",");
            where_clauses.push(format!("p.asset_id IN ({})", inlist));
        }
    }

    let include_locked = query.include_locked.unwrap_or(false);
    let locked_only = query.filter_locked_only.unwrap_or(false);
    if locked_only {
        where_clauses.push("COALESCE(p.locked, FALSE) = TRUE".to_string());
    } else if !include_locked {
        where_clauses.push("COALESCE(p.locked, FALSE) = FALSE".to_string());
    }

    let include_trashed = query.include_trashed.unwrap_or(false);
    let trashed_only = query.filter_trashed_only.unwrap_or(false);
    if trashed_only {
        where_clauses.push("COALESCE(p.delete_time, 0) > 0".to_string());
    } else if !include_trashed {
        where_clauses.push("COALESCE(p.delete_time, 0) = 0".to_string());
    }

    let mut out: Vec<QuarterBucket> = Vec::new();
    let mut base = String::from("SELECT DISTINCT p.id, p.created_at FROM photos p");
    for j in &joins {
        base.push(' ');
        base.push_str(j);
    }
    if !where_clauses.is_empty() {
        base.push_str(" WHERE ");
        base.push_str(&where_clauses.join(" AND "));
    }
    let sql = format!(
        "SELECT CAST(date_part('quarter', to_timestamp(created_at)) AS INTEGER) AS q, \
                COUNT(*) AS c, \
                MIN(created_at) AS first_ts, \
                MAX(created_at) AS last_ts \
         FROM ({}) AS sub \
         WHERE CAST(date_part('year', to_timestamp(created_at)) AS INTEGER) = {} \
         GROUP BY 1 \
         ORDER BY q ASC",
        base, params.year
    );
    let conn = data_db.lock();
    if let Ok(mut stmt) = conn.prepare(&sql) {
        let rows = stmt.query_map([], |row| {
            Ok(QuarterBucket {
                quarter: row.get::<_, i32>(0)?,
                count: row.get::<_, i64>(1)?,
                first_ts: row.get::<_, i64>(2)?,
                last_ts: row.get::<_, i64>(3)?,
            })
        })?;
        for r in rows {
            out.push(r?);
        }
    }
    let ms = started.elapsed().as_millis();
    tracing::info!(
        target = "perf",
        "[BUCKET_QUARTERS] year={} quarters={} ms={} user={} org={}",
        params.year,
        out.len(),
        ms,
        user.user_id,
        user.organization_id
    );
    Ok(Json(out))
}
#[derive(Debug, Deserialize)]
pub struct PhotoStateQuery {
    pub asset_id: String,
}

#[derive(Debug, Serialize)]
pub struct PhotoStateResponse {
    pub exists: bool,
    pub locked: bool,
}

/// Lightweight existence/lock-state probe for upload preflight
#[instrument(skip(state, headers))]
pub async fn get_photo_state(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(q): Query<PhotoStateQuery>,
) -> Result<impl IntoResponse, AppError> {
    let user = get_user_from_headers(&headers, &state.auth_service).await?;
    if let Some(pg) = &state.pg_client {
        let row = pg
            .query_opt(
                "SELECT COALESCE(locked, FALSE) FROM photos WHERE organization_id=$1 AND asset_id=$2 LIMIT 1",
                &[&user.organization_id, &q.asset_id],
            )
            .await
            .map_err(|e| AppError(anyhow::anyhow!(e)))?;
        if let Some(r) = row {
            let locked: bool = r.get(0);
            return Ok(Json(PhotoStateResponse {
                exists: true,
                locked,
            }));
        }
        return Ok(Json(PhotoStateResponse {
            exists: false,
            locked: false,
        }));
    }
    let data_db = state.get_user_data_database(&user.user_id)?;
    let conn = data_db.lock();
    let row = conn
        .prepare("SELECT COALESCE(locked, FALSE) FROM photos WHERE organization_id = ? AND asset_id = ? LIMIT 1")
        .ok()
        .and_then(|mut s| s.query_row(duckdb::params![user.organization_id, &q.asset_id], |r| r.get::<_, bool>(0)).ok());
    match row {
        Some(locked) => Ok(Json(PhotoStateResponse {
            exists: true,
            locked,
        })),
        None => Ok(Json(PhotoStateResponse {
            exists: false,
            locked: false,
        })),
    }
}

// -------- Debug helpers --------
#[derive(Debug, Serialize)]
pub struct DebugPhotoRow {
    pub organization_id: i32,
    pub user_id: String,
    pub asset_id: String,
    pub favorites: i32,
    pub locked: bool,
    pub delete_time: i64,
}

/// Debug: return a raw view of the photo row (favorites, owner) for a given asset_id
#[instrument(skip(state, headers))]
pub async fn debug_photo_row(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(asset_id): Path<String>,
) -> Result<impl IntoResponse, AppError> {
    let user = get_user_from_headers(&headers, &state.auth_service).await?;
    if let Some(pg) = &state.pg_client {
        let row = pg
            .query_opt(
                "SELECT organization_id, COALESCE(user_id,''), asset_id, COALESCE(favorites,0), COALESCE(locked,FALSE), COALESCE(delete_time,0) FROM photos WHERE organization_id=$1 AND asset_id=$2 LIMIT 1",
                &[&user.organization_id, &asset_id],
            )
            .await
            .map_err(|e| AppError(anyhow::anyhow!(e)))?;
        if let Some(r) = row {
            let resp = DebugPhotoRow {
                organization_id: r.get(0),
                user_id: r.get(1),
                asset_id: r.get(2),
                favorites: r.get(3),
                locked: r.get(4),
                delete_time: r.get(5),
            };
            return Ok(Json(resp));
        }
        return Err(AppError(anyhow::anyhow!("Asset not found")));
    }
    let data_db = state.get_user_data_database(&user.user_id)?;
    let conn = data_db.lock();
    if let Ok(mut stmt) = conn.prepare(
        "SELECT organization_id, COALESCE(user_id,''), asset_id, COALESCE(favorites,0), COALESCE(locked,FALSE), COALESCE(delete_time,0) FROM photos WHERE organization_id = ? AND asset_id = ? LIMIT 1",
    ) {
        if let Ok(row) = stmt.query_row(duckdb::params![user.organization_id, &asset_id], |r| {
            Ok(DebugPhotoRow {
                organization_id: r.get(0)?,
                user_id: r.get(1)?,
                asset_id: r.get(2)?,
                favorites: r.get(3)?,
                locked: r.get(4)?,
                delete_time: r.get(5)?,
            })
        }) {
            return Ok(Json(row));
        }
    }
    Err(AppError(anyhow::anyhow!("Asset not found")))
}

#[cfg(test)]
mod tests {
    use super::{
        cache_matches_raw_placeholder_jpeg, cache_matches_raw_placeholder_webp,
        generate_display_jpeg, generate_thumbnail, looks_like_declared_image,
        query_has_format_param, raw_image_serve_mode, sniff_image_content_type, RawImageServeMode,
    };
    use std::fs;

    #[test]
    fn looks_like_declared_image_accepts_valid_avif_signature() {
        // Minimal ISO BMFF-style header with ftyp+avif major brand.
        let bytes = [
            0x00, 0x00, 0x00, 0x18, b'f', b't', b'y', b'p', b'a', b'v', b'i', b'f', b'm', b'i',
            b'f', b'1',
        ];
        assert!(looks_like_declared_image("image/avif", &bytes));
    }

    #[test]
    fn looks_like_declared_image_rejects_avif_when_bytes_are_jpeg() {
        let bytes = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, b'J', b'F', b'I', b'F'];
        assert!(!looks_like_declared_image("image/avif", &bytes));
        assert_eq!(sniff_image_content_type(&bytes), Some("image/jpeg"));
    }

    #[test]
    fn looks_like_declared_image_accepts_dng_tiff_header() {
        let bytes = [0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00];
        assert!(looks_like_declared_image("image/dng", &bytes));
    }

    #[test]
    fn raw_image_serve_mode_prefers_original_when_requested() {
        assert_eq!(
            raw_image_serve_mode("image/dng", "foo=bar&format=original", true),
            RawImageServeMode::OriginalBytes
        );
        assert_eq!(
            raw_image_serve_mode("image/dng", "", true),
            RawImageServeMode::DerivedAvif
        );
        assert_eq!(
            raw_image_serve_mode("image/dng", "", false),
            RawImageServeMode::DerivedJpeg
        );
        assert_eq!(
            raw_image_serve_mode("image/jpeg", "format=original", true),
            RawImageServeMode::NotRaw
        );
        assert!(query_has_format_param("format=original&x=1", "original"));
    }

    #[test]
    fn generate_thumbnail_uses_placeholder_for_invalid_dng() {
        let base = std::env::temp_dir().join(format!(
            "openphotos-dng-thumb-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("unix time")
                .as_nanos()
        ));
        fs::create_dir_all(&base).expect("create temp dir");
        let dng_path = base.join("sample.dng");
        let thumb_path = base.join("sample.webp");
        fs::write(&dng_path, b"not-a-real-dng").expect("write dng");

        generate_thumbnail(dng_path.to_str().expect("utf8 path"), &thumb_path)
            .expect("thumbnail generation should fall back to placeholder");

        let bytes = fs::read(&thumb_path).expect("read thumbnail");
        assert!(bytes.len() > 12);
        assert_eq!(&bytes[0..4], b"RIFF");
        assert_eq!(&bytes[8..12], b"WEBP");

        let _ = fs::remove_file(&dng_path);
        let _ = fs::remove_file(&thumb_path);
        let _ = fs::remove_dir(&base);
    }

    #[test]
    fn generate_display_jpeg_uses_placeholder_for_invalid_dng() {
        let base = std::env::temp_dir().join(format!(
            "openphotos-dng-jpeg-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("unix time")
                .as_nanos()
        ));
        fs::create_dir_all(&base).expect("create temp dir");
        let dng_path = base.join("sample.dng");
        let jpeg_path = base.join("sample.jpg");
        fs::write(&dng_path, b"not-a-real-dng").expect("write dng");

        generate_display_jpeg(dng_path.to_str().expect("utf8 path"), &jpeg_path, 1024)
            .expect("jpeg generation should fall back to placeholder");

        let bytes = fs::read(&jpeg_path).expect("read jpeg");
        assert!(bytes.len() > 4);
        assert_eq!(bytes[0], 0xFF);
        assert_eq!(bytes[1], 0xD8);

        let _ = fs::remove_file(&dng_path);
        let _ = fs::remove_file(&jpeg_path);
        let _ = fs::remove_dir(&base);
    }

    #[test]
    fn placeholder_thumbnail_bytes_are_detected_for_refresh() {
        let base = std::env::temp_dir().join(format!(
            "openphotos-dng-thumb-refresh-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("unix time")
                .as_nanos()
        ));
        fs::create_dir_all(&base).expect("create temp dir");
        let dng_path = base.join("sample.dng");
        let thumb_path = base.join("sample.webp");
        fs::write(&dng_path, b"not-a-real-dng").expect("write dng");

        generate_thumbnail(dng_path.to_str().expect("utf8 path"), &thumb_path)
            .expect("generate placeholder thumbnail");

        assert!(cache_matches_raw_placeholder_webp(&thumb_path, 512));

        let _ = fs::remove_file(&dng_path);
        let _ = fs::remove_file(&thumb_path);
        let _ = fs::remove_dir(&base);
    }

    #[test]
    fn placeholder_display_jpeg_bytes_are_detected_for_refresh() {
        let base = std::env::temp_dir().join(format!(
            "openphotos-dng-jpeg-refresh-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("unix time")
                .as_nanos()
        ));
        fs::create_dir_all(&base).expect("create temp dir");
        let dng_path = base.join("sample.dng");
        let jpeg_path = base.join("sample.jpg");
        fs::write(&dng_path, b"not-a-real-dng").expect("write dng");

        generate_display_jpeg(dng_path.to_str().expect("utf8 path"), &jpeg_path, 2560)
            .expect("generate placeholder jpeg");

        assert!(cache_matches_raw_placeholder_jpeg(&jpeg_path, 2560));

        let _ = fs::remove_file(&dng_path);
        let _ = fs::remove_file(&jpeg_path);
        let _ = fs::remove_dir(&base);
    }
}
