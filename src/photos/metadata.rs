use anyhow::{Context, Result};
use exif::{Exif, In, Reader, Tag, Value};
use image::imageops;
use image::{DynamicImage, GenericImageView, RgbaImage};
use md5;
use std::fs::File;
use std::io::BufReader;
use std::path::Path;
use std::time::{Duration, SystemTime};
use tracing::{info, warn};

use super::Photo;
use regex::Regex;

// Debug EXIF logging removed after stabilization

pub fn extract_metadata(photo: &mut Photo) -> Result<()> {
    let path_string = photo.path.clone();
    let path = Path::new(&path_string);

    if !photo.is_video {
        // Extract image dimensions (prefer native decode; fallback to open_image_any for HEIC/others)
        let mut got_dims = false;
        if let Ok(img) = image::open(path) {
            let (width, height) = img.dimensions();
            photo.width = Some(width as i32);
            photo.height = Some(height as i32);
            got_dims = true;
        }
        if !got_dims {
            if let Ok(img) = open_image_any(path) {
                let (width, height) = img.dimensions();
                photo.width = Some(width as i32);
                photo.height = Some(height as i32);
            }
        }

        // Extract EXIF data
        let initial_created = photo.created_at;
        match read_exif(path) {
            Ok(exif) => {
                extract_exif_data(photo, &exif);
            }
            Err(e) => {
                // Native parse failed; keep filesystem timestamps and continue (no external fallback)
            }
        }
    } else {
        // Video metadata via ffprobe (duration, creation_time, tags, GPS)
        let _ = extract_video_metadata_ffprobe(photo);
    }

    // Detect screenshot after we have dimensions
    photo.detect_screenshot();

    Ok(())
}

/// Open an image and adjust orientation to be upright according to EXIF Orientation tag.
/// If EXIF cannot be read or Orientation is missing, returns the image as-is.
pub fn open_image_upright(path: &Path) -> Result<DynamicImage> {
    let mut img = image::open(path)?;

    if let Ok(exif) = read_exif(path) {
        if let Some(orientation) = exif.get_field(Tag::Orientation, In::PRIMARY) {
            if let Value::Short(ref vals) = orientation.value {
                if let Some(&o) = vals.first() {
                    match o as u16 {
                        1 => { /* no-op */ }
                        2 => {
                            let buf = imageops::flip_horizontal(&img);
                            img = DynamicImage::ImageRgba8(buf);
                        }
                        3 => {
                            img = DynamicImage::ImageRgba8(imageops::rotate180(&img));
                        }
                        4 => {
                            let buf = imageops::flip_vertical(&img);
                            img = DynamicImage::ImageRgba8(buf);
                        }
                        5 => {
                            let rotated = DynamicImage::ImageRgba8(imageops::rotate90(&img));
                            let buf = imageops::flip_horizontal(&rotated);
                            img = DynamicImage::ImageRgba8(buf);
                        }
                        6 => {
                            img = DynamicImage::ImageRgba8(imageops::rotate90(&img));
                        }
                        7 => {
                            let rotated = DynamicImage::ImageRgba8(imageops::rotate270(&img));
                            let buf = imageops::flip_horizontal(&rotated);
                            img = DynamicImage::ImageRgba8(buf);
                        }
                        8 => {
                            img = DynamicImage::ImageRgba8(imageops::rotate270(&img));
                        }
                        _ => { /* no-op */ }
                    }
                }
            }
        }
    }

    Ok(img)
}

/// Try to open any supported image, including HEIC/HEIF and AVIF via ffmpeg fallback when needed.
pub fn open_image_any(path: &Path) -> Result<DynamicImage> {
    match open_image_upright(path) {
        Ok(img) => Ok(img),
        Err(e) => {
            let ext = path
                .extension()
                .and_then(|e| e.to_str())
                .unwrap_or("")
                .to_lowercase();
            if ext == "heic" || ext == "heif" {
                // Prefer libheif-rs to avoid display-crop; ignore transformations to get full image
                match decode_heic_libheif(path) {
                    Ok(img) => {
                        // libheif decode already applied display transformations (including orientation)
                        Ok(img)
                    }
                    Err(e2) => {
                        let mut img = decode_still_via_ffmpeg(path).map_err(|e3| {
                            anyhow::anyhow!(
                                "HEIC decode failed: libheif={} ffmpeg={} prior={}",
                                e2,
                                e3,
                                e
                            )
                        })?;
                        // Apply EXIF orientation for ffmpeg path as well
                        if let Ok(exif) = read_exif(path) {
                            if let Some(orientation) = exif.get_field(Tag::Orientation, In::PRIMARY)
                            {
                                if let Value::Short(ref vals) = orientation.value {
                                    if let Some(&o) = vals.first() {
                                        use image::imageops;
                                        img = match o as u16 {
                                            1 => img,
                                            2 => DynamicImage::ImageRgba8(
                                                imageops::flip_horizontal(&img),
                                            ),
                                            3 => {
                                                DynamicImage::ImageRgba8(imageops::rotate180(&img))
                                            }
                                            4 => DynamicImage::ImageRgba8(imageops::flip_vertical(
                                                &img,
                                            )),
                                            5 => {
                                                let r = DynamicImage::ImageRgba8(
                                                    imageops::rotate90(&img),
                                                );
                                                DynamicImage::ImageRgba8(imageops::flip_horizontal(
                                                    &r,
                                                ))
                                            }
                                            6 => DynamicImage::ImageRgba8(imageops::rotate90(&img)),
                                            7 => {
                                                let r = DynamicImage::ImageRgba8(
                                                    imageops::rotate270(&img),
                                                );
                                                DynamicImage::ImageRgba8(imageops::flip_horizontal(
                                                    &r,
                                                ))
                                            }
                                            8 => {
                                                DynamicImage::ImageRgba8(imageops::rotate270(&img))
                                            }
                                            _ => img,
                                        };
                                    }
                                }
                            }
                        }
                        Ok(img)
                    }
                }
            } else if ext == "avif" {
                decode_still_via_ffmpeg(path)
                    .map_err(|e2| anyhow::anyhow!("AVIF decode failed: ffmpeg={} prior={}", e2, e))
            } else {
                Err(e)
            }
        }
    }
}

/// Get the application-wide ML cache directory (for HEIC/HEIF/AVIF -> JPG proxies).
/// Default: `<DATABASE_PATH>/cache/ml` when `DATABASE_PATH` is set, else `data/cache/ml`.
pub fn ml_cache_dir() -> std::path::PathBuf {
    let base = std::env::var_os("DATABASE_PATH")
        .and_then(|v| {
            if v.is_empty() {
                None
            } else {
                Some(std::path::PathBuf::from(v))
            }
        })
        .unwrap_or_else(|| std::path::PathBuf::from("data"))
        .join("cache")
        .join("ml");
    if let Err(e) = std::fs::create_dir_all(&base) {
        warn!(
            "[ML_CACHE] Failed to create cache dir {}: {}",
            base.display(),
            e
        );
    }
    base
}

/// Ensure a resized JPG proxy for HEIC/HEIF/AVIF exists for ML consumption.
/// - max_width: target longest side (preserve aspect), typical 1024.
/// Returns path to the proxy JPG; for other paths, returns the original path.
pub fn ensure_heic_ml_proxy(path: &Path, max_width: u32) -> Result<std::path::PathBuf> {
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_lowercase();
    if ext != "heic" && ext != "heif" && ext != "avif" {
        return Ok(path.to_path_buf());
    }

    // Build a stable cache key from file path + size + mtime + resize parameters
    let meta = std::fs::metadata(path).ok();
    let size = meta.as_ref().map(|m| m.len()).unwrap_or(0);
    let mtime = meta
        .and_then(|m| m.modified().ok())
        .and_then(|t| t.duration_since(SystemTime::UNIX_EPOCH).ok())
        .map(|d| d.as_secs())
        .unwrap_or(0);
    // Bump this when the decode/resize pipeline changes to avoid reusing stale/bad cached proxies.
    const ML_PROXY_CACHE_VERSION: u32 = 3;
    let key_str = format!(
        "v{}|{}|{}|{}|w{}|q{}",
        ML_PROXY_CACHE_VERSION,
        path.display(),
        size,
        mtime,
        max_width,
        88
    );
    let digest = format!("{:x}", md5::compute(key_str));
    let cache_dir = ml_cache_dir();
    let out_path = cache_dir.join(format!("{}.jpg", digest));
    if out_path.exists() {
        return Ok(out_path);
    }

    // Decode source (supports HEIC via libheif if feature enabled, else ffmpeg fallback)
    let img = open_image_any(path)?; // already oriented/upright by open_image_any

    // Resize to target max width/height preserving aspect
    let (w, h) = img.dimensions();
    let (tw, th) = if w >= h {
        let nw = max_width.min(w.max(1));
        let nh = ((h as f32) * (nw as f32 / w as f32)).round() as u32;
        (nw, nh.max(1))
    } else {
        let nh = max_width.min(h.max(1));
        let nw = ((w as f32) * (nh as f32 / h as f32)).round() as u32;
        (nw.max(1), nh)
    };
    let resized = img.resize(tw.max(1), th.max(1), image::imageops::FilterType::Lanczos3);

    // Encode to JPEG (quality 88)
    let mut buf = Vec::new();
    let rgb = resized.to_rgb8();
    image::codecs::jpeg::JpegEncoder::new_with_quality(&mut buf, 88).encode(
        &rgb,
        rgb.width(),
        rgb.height(),
        image::ColorType::Rgb8,
    )?;
    std::fs::write(&out_path, &buf).with_context(|| {
        format!(
            "Failed to write HEIC/AVIF ML proxy JPG to {}",
            out_path.display()
        )
    })?;

    Ok(out_path)
}

/// Decode HEIC/HEIF using libheif-rs, ignoring display transformations (avoid unintended crops).
fn decode_heic_libheif(path: &Path) -> Result<DynamicImage> {
    // Use FFI only if libheif-sys is available; otherwise return error to trigger ffmpeg fallback
    #[cfg(not(feature = "libheif_ffi"))]
    {
        return Err(anyhow::anyhow!("libheif FFI not enabled"));
    }
    #[cfg(feature = "libheif_ffi")]
    {
        use libheif_sys as lh;
        use std::{ffi::CString, ptr, slice};

        unsafe {
            let ctx = lh::heif_context_alloc();
            if ctx.is_null() {
                return Err(anyhow::anyhow!("heif_context_alloc failed"));
            }
            let c_path = CString::new(path.to_string_lossy().as_bytes()).unwrap();
            let err = lh::heif_context_read_from_file(ctx, c_path.as_ptr(), ptr::null());
            if err.code != lh::heif_error_code_heif_error_Ok {
                lh::heif_context_free(ctx);
                return Err(anyhow::anyhow!(
                    "heif read_from_file failed: code={} subcode={}",
                    err.code,
                    err.subcode
                ));
            }

            let mut handle: *mut lh::heif_image_handle = ptr::null_mut();
            let err = lh::heif_context_get_primary_image_handle(ctx, &mut handle);
            if err.code != lh::heif_error_code_heif_error_Ok || handle.is_null() {
                lh::heif_context_free(ctx);
                return Err(anyhow::anyhow!(
                    "heif get_primary_image_handle failed: code={} subcode={}",
                    err.code,
                    err.subcode
                ));
            }

            // Allocate decoding options and ignore transformations (avoid clean-aperture crop)
            let opts = lh::heif_decoding_options_alloc();
            if opts.is_null() {
                lh::heif_image_handle_release(handle);
                lh::heif_context_free(ctx);
                return Err(anyhow::anyhow!("heif_decoding_options_alloc failed"));
            }
            // Apply HEIC display transformations (rotation/flip/crop). We prefer correct orientation.
            (*opts).ignore_transformations = 0;

            let mut img: *mut lh::heif_image = ptr::null_mut();
            let err = lh::heif_decode_image(
                handle,
                &mut img,
                lh::heif_colorspace_heif_colorspace_RGB,
                lh::heif_chroma_heif_chroma_interleaved_RGBA,
                opts,
            );
            // Clean up opts early
            lh::heif_decoding_options_free(opts);
            if err.code != lh::heif_error_code_heif_error_Ok || img.is_null() {
                lh::heif_image_handle_release(handle);
                lh::heif_context_free(ctx);
                return Err(anyhow::anyhow!(
                    "heif_decode_image failed: code={} subcode={}",
                    err.code,
                    err.subcode
                ));
            }

            let width = lh::heif_image_get_primary_width(img).max(0) as usize;
            let height = lh::heif_image_get_primary_height(img).max(0) as usize;

            let mut stride: i32 = 0;
            let plane_ptr = lh::heif_image_get_plane(
                img,
                lh::heif_channel_heif_channel_interleaved as _,
                &mut stride,
            );
            if plane_ptr.is_null() || stride <= 0 {
                lh::heif_image_release(img);
                lh::heif_image_handle_release(handle);
                lh::heif_context_free(ctx);
                return Err(anyhow::anyhow!("heif_image_get_plane returned null"));
            }
            let stride = stride as usize;
            let size = height * stride;
            let src = slice::from_raw_parts(plane_ptr, size);

            // Copy each row into tightly packed RGBA buffer
            let mut out = vec![0u8; width * height * 4];
            for y in 0..height {
                let row = &src[y * stride..y * stride + width * 4];
                let dst_row = &mut out[y * width * 4..(y + 1) * width * 4];
                dst_row.copy_from_slice(row);
            }

            let rgba = RgbaImage::from_raw(width as u32, height as u32, out)
                .ok_or_else(|| anyhow::anyhow!("failed to create RGBA image"))?;

            // Release libheif refs
            lh::heif_image_release(img);
            lh::heif_image_handle_release(handle);
            lh::heif_context_free(ctx);

            Ok(DynamicImage::ImageRgba8(rgba))
        }
        // Close cfg(feature) block properly
    }
}

/// Decode a still image to a DynamicImage using ffmpeg CLI as a fallback.
fn decode_still_via_ffmpeg(path: &Path) -> Result<DynamicImage> {
    use std::process::Command;
    let input = path.to_string_lossy().to_string();

    // ffmpeg's HEIF demuxer may expose:
    // - a "Tile Grid" (full-res) composed of many tile streams
    // - auxiliary grayscale streams (gain maps / depth / etc.)
    //
    // We prefer reconstructing the Tile Grid into a single frame using xstack. If no tile grid is
    // present (or reconstruction fails), pick the largest non-grayscale video stream.
    //
    // Important: pass `-noautorotate` so orientation is applied exactly once by our EXIF logic in
    // `open_image_any` (avoids double-rotation when ffmpeg also applies displaymatrix transforms).
    let probe = Command::new("ffprobe")
        .args([
            "-v",
            "error",
            "-print_format",
            "json",
            "-show_entries",
            "stream=index,width,height,pix_fmt,codec_type:stream_group",
            "-show_streams",
            &input,
        ])
        .output();

    let probe_json: Option<serde_json::Value> = match probe {
        Ok(out) if out.status.success() => serde_json::from_slice(&out.stdout).ok(),
        _ => None,
    };

    let mut tile_stream_indices: Vec<u32> = Vec::new();

    if let Some(v) = probe_json.as_ref() {
        if let Some(groups) = v.get("stream_groups").and_then(|g| g.as_array()) {
            // Find the first Tile Grid stream group
            if let Some(g) = groups.iter().find(|g| {
                g.get("type")
                    .and_then(|t| t.as_str())
                    .map(|t| t == "Tile Grid")
                    .unwrap_or(false)
            }) {
                if let Some(comp) = g
                    .get("components")
                    .and_then(|c| c.as_array())
                    .and_then(|c| c.first())
                {
                    let width = comp.get("width").and_then(|n| n.as_u64()).unwrap_or(0) as u32;
                    let height = comp.get("height").and_then(|n| n.as_u64()).unwrap_or(0) as u32;
                    if width > 0 && height > 0 {
                        let mut tiles: Vec<(u32, u32, u32)> = Vec::new(); // (stream_index, x, y)
                        if let Some(subs) = comp.get("subcomponents").and_then(|s| s.as_array()) {
                            for s in subs {
                                let si = s
                                    .get("stream_index")
                                    .and_then(|n| n.as_u64())
                                    .unwrap_or(u64::MAX);
                                let x = s
                                    .get("tile_horizontal_offset")
                                    .and_then(|n| n.as_u64())
                                    .unwrap_or(0);
                                let y = s
                                    .get("tile_vertical_offset")
                                    .and_then(|n| n.as_u64())
                                    .unwrap_or(0);
                                if si != u64::MAX {
                                    tiles.push((si as u32, x as u32, y as u32));
                                }
                            }
                        }

                        tiles.sort_by_key(|(si, _, _)| *si);
                        tile_stream_indices = tiles.iter().map(|(si, _, _)| *si).collect();

                        // Avoid generating absurdly large ffmpeg command lines.
                        if !tiles.is_empty() && tiles.len() <= 256 {
                            let mut filter = String::new();
                            let mut layout = String::new();
                            for (i, (si, x, y)) in tiles.iter().enumerate() {
                                filter.push_str(&format!("[0:{}]", si));
                                if i > 0 {
                                    layout.push('|');
                                }
                                layout.push_str(&format!("{}_{}", x, y));
                            }
                            filter.push_str(&format!(
                                "xstack=inputs={}:layout={},crop={}:{}:0:0,format=rgb24[v]",
                                tiles.len(),
                                layout,
                                width,
                                height
                            ));

                            let out = Command::new("ffmpeg")
                                .args([
                                    "-hide_banner",
                                    "-loglevel",
                                    "error",
                                    "-nostdin",
                                    "-noautorotate",
                                    "-y",
                                    "-i",
                                    &input,
                                    "-filter_complex",
                                    &filter,
                                    "-map",
                                    "[v]",
                                    "-frames:v",
                                    "1",
                                    "-f",
                                    "image2pipe",
                                    "-vcodec",
                                    "png",
                                    "pipe:1",
                                ])
                                .output()
                                .map_err(|e| {
                                    anyhow::anyhow!("Failed to run ffmpeg tile-grid decode: {}", e)
                                })?;
                            if out.status.success() && !out.stdout.is_empty() {
                                let img = image::load_from_memory(&out.stdout).map_err(|e| {
                                    anyhow::anyhow!(
                                        "Failed to load decoded tile-grid image from memory: {}",
                                        e
                                    )
                                })?;
                                return Ok(img);
                            }

                            // If tile grid reconstruction fails, fall through to stream selection.
                            // Keep stderr for diagnostics.
                            if !out.status.success() {
                                let stderr = String::from_utf8_lossy(&out.stderr);
                                warn!(
                                    "ffmpeg tile grid decode failed (status {:?}) for {}: {}",
                                    out.status,
                                    input,
                                    stderr.trim()
                                );
                            }
                        }
                    }
                }
            }
        }
    }

    // Fallback: choose the largest non-grayscale stream (excluding tile streams if we detected them).
    let mut best_index: Option<u32> = None;
    let mut best_area: u64 = 0;
    let mut best_is_gray: bool = true;
    if let Some(v) = probe_json.as_ref() {
        if let Some(streams) = v.get("streams").and_then(|s| s.as_array()) {
            for s in streams {
                let codec_type = s.get("codec_type").and_then(|c| c.as_str()).unwrap_or("");
                if codec_type != "video" {
                    continue;
                }
                let idx = s.get("index").and_then(|n| n.as_u64()).unwrap_or(u64::MAX);
                if idx == u64::MAX {
                    continue;
                }
                let idx_u32 = idx as u32;

                // If we detected a tile grid, avoid selecting a single tile stream when possible.
                if !tile_stream_indices.is_empty() && tile_stream_indices.contains(&idx_u32) {
                    continue;
                }

                let w = s.get("width").and_then(|n| n.as_u64()).unwrap_or(0);
                let h = s.get("height").and_then(|n| n.as_u64()).unwrap_or(0);
                let area = w.saturating_mul(h);
                if area == 0 {
                    continue;
                }
                let pix_fmt = s.get("pix_fmt").and_then(|p| p.as_str()).unwrap_or("");
                let is_gray = pix_fmt.starts_with("gray");

                // Prefer any non-gray stream; then prefer larger area.
                let better = match (best_index, best_is_gray, is_gray) {
                    (None, _, _) => true,
                    (Some(_), true, false) => true,
                    (Some(_), false, true) => false,
                    _ => area > best_area,
                };
                if better {
                    best_index = Some(idx_u32);
                    best_area = area;
                    best_is_gray = is_gray;
                }
            }
        }
    }

    // If we excluded tile streams and found nothing, allow selecting from all streams.
    if best_index.is_none() && probe_json.is_some() && !tile_stream_indices.is_empty() {
        if let Some(v) = probe_json.as_ref() {
            if let Some(streams) = v.get("streams").and_then(|s| s.as_array()) {
                for s in streams {
                    let codec_type = s.get("codec_type").and_then(|c| c.as_str()).unwrap_or("");
                    if codec_type != "video" {
                        continue;
                    }
                    let idx = s.get("index").and_then(|n| n.as_u64()).unwrap_or(u64::MAX);
                    if idx == u64::MAX {
                        continue;
                    }
                    let idx_u32 = idx as u32;
                    let w = s.get("width").and_then(|n| n.as_u64()).unwrap_or(0);
                    let h = s.get("height").and_then(|n| n.as_u64()).unwrap_or(0);
                    let area = w.saturating_mul(h);
                    if area == 0 {
                        continue;
                    }
                    let pix_fmt = s.get("pix_fmt").and_then(|p| p.as_str()).unwrap_or("");
                    let is_gray = pix_fmt.starts_with("gray");
                    let better = match (best_index, best_is_gray, is_gray) {
                        (None, _, _) => true,
                        (Some(_), true, false) => true,
                        (Some(_), false, true) => false,
                        _ => area > best_area,
                    };
                    if better {
                        best_index = Some(idx_u32);
                        best_area = area;
                        best_is_gray = is_gray;
                    }
                }
            }
        }
    }

    let mut ff_args: Vec<String> = vec![
        "-hide_banner".into(),
        "-loglevel".into(),
        "error".into(),
        "-nostdin".into(),
        "-noautorotate".into(),
        "-y".into(),
        "-i".into(),
        input.clone(),
    ];
    if let Some(idx) = best_index {
        ff_args.push("-map".into());
        ff_args.push(format!("0:{}", idx));
    }
    ff_args.extend([
        "-frames:v".into(),
        "1".into(),
        "-f".into(),
        "image2pipe".into(),
        "-vcodec".into(),
        "png".into(),
        "pipe:1".into(),
    ]);
    let output = Command::new("ffmpeg")
        .args(ff_args)
        .output()
        .map_err(|e| anyhow::anyhow!("Failed to run ffmpeg still-image decode: {}", e))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(anyhow::anyhow!(
            "ffmpeg exited with status {:?}: {}",
            output.status,
            stderr.trim()
        ));
    }
    let img = image::load_from_memory(&output.stdout)
        .map_err(|e| anyhow::anyhow!("Failed to load decoded still image from memory: {}", e))?;
    Ok(img)
}

fn read_exif(path: &Path) -> Result<Exif> {
    let file = File::open(path)?;
    let mut reader = BufReader::new(file);
    let exif_reader = Reader::new();
    let exif = exif_reader.read_from_container(&mut reader)?;
    Ok(exif)
}

// exiftool support removed: we rely on native Rust EXIF + ffprobe only

/// Extract video metadata using ffprobe JSON output
fn extract_video_metadata_ffprobe(photo: &mut Photo) -> Result<()> {
    use std::process::Command;
    let output = Command::new("ffprobe")
        .args([
            "-v",
            "quiet",
            "-print_format",
            "json",
            "-show_format",
            "-show_streams",
            &photo.path,
        ])
        .output();
    let Ok(out) = output else {
        return Ok(());
    };
    if !out.status.success() {
        return Ok(());
    }
    let v: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap_or(serde_json::json!({}));
    // Duration
    if let Some(dur_s) = v
        .get("format")
        .and_then(|f| f.get("duration"))
        .and_then(|d| d.as_str())
        .and_then(|s| s.parse::<f64>().ok())
    {
        photo.duration_ms = Some((dur_s * 1000.0) as i64);
    }
    // Tags from format/first stream
    let tags = v
        .get("format")
        .and_then(|f| f.get("tags"))
        .cloned()
        .unwrap_or(serde_json::json!({}));
    let stream0 = v
        .get("streams")
        .and_then(|s| s.as_array())
        .and_then(|a| a.first())
        .cloned()
        .unwrap_or(serde_json::json!({}));
    let stags = stream0
        .get("tags")
        .cloned()
        .unwrap_or(serde_json::json!({}));
    let tags_merged = merge_json_objects(tags, stags);

    // Creation time
    if let Some(ct) = get_tag_str(
        &tags_merged,
        &["creation_time", "com.apple.quicktime.creationdate"],
    ) {
        if let Ok(ts) = parse_ffprobe_datetime(ct) {
            photo.created_at = ts;
        }
    }
    // Make/Model
    if let Some(make) = get_tag_str(&tags_merged, &["com.apple.quicktime.make", "make"]) {
        photo.camera_make = Some(make.to_string());
    }
    if let Some(model) = get_tag_str(&tags_merged, &["com.apple.quicktime.model", "model"]) {
        photo.camera_model = Some(model.to_string());
    }
    // Caption from common QuickTime/MP4 fields
    if photo.caption.is_none() {
        if let Some(desc) = get_tag_str(
            &tags_merged,
            &["description", "com.apple.quicktime.description"],
        ) {
            let st = desc.trim();
            if !st.is_empty() {
                photo.caption = Some(st.to_string());
            }
        } else if let Some(comm) = get_tag_str(&tags_merged, &["comment"]) {
            let st = comm.trim();
            if !st.is_empty() {
                photo.caption = Some(st.to_string());
            }
        } else if let Some(title) = get_tag_str(&tags_merged, &["title"]) {
            let st = title.trim();
            if !st.is_empty() {
                photo.caption = Some(st.to_string());
            }
        }
    }

    // GPS from ISO6709 location or separate tags
    if let Some(loc) = get_tag_str(
        &tags_merged,
        &["com.apple.quicktime.location.ISO6709", "location"],
    ) {
        if let Some((lat, lon, alt)) = parse_iso6709(loc) {
            photo.latitude = Some(lat);
            photo.longitude = Some(lon);
            if let Some(a) = alt {
                photo.altitude = Some(a as f64);
            }
        }
    } else {
        // Some devices store 'latitude'/'longitude'
        if let (Some(lat), Some(lon)) = (
            get_tag_str(&tags_merged, &["latitude"]).and_then(|s| s.parse::<f64>().ok()),
            get_tag_str(&tags_merged, &["longitude"]).and_then(|s| s.parse::<f64>().ok()),
        ) {
            photo.latitude = Some(lat);
            photo.longitude = Some(lon);
        }
    }

    // Dimensions from video stream
    if let (Some(w), Some(h)) = (
        stream0.get("width").and_then(|x| x.as_i64()),
        stream0.get("height").and_then(|x| x.as_i64()),
    ) {
        photo.width = Some(w as i32);
        photo.height = Some(h as i32);
    }

    Ok(())
}

fn merge_json_objects(a: serde_json::Value, b: serde_json::Value) -> serde_json::Value {
    use serde_json::Map;
    let mut map = Map::new();
    if let Some(o) = a.as_object() {
        for (k, v) in o {
            map.insert(k.clone(), v.clone());
        }
    }
    if let Some(o) = b.as_object() {
        for (k, v) in o {
            map.insert(k.clone(), v.clone());
        }
    }
    serde_json::Value::Object(map)
}

fn get_tag_str<'a>(tags: &'a serde_json::Value, keys: &[&str]) -> Option<&'a str> {
    for k in keys {
        if let Some(v) = tags.get(*k).and_then(|x| x.as_str()) {
            return Some(v);
        }
    }
    None
}

fn parse_ffprobe_datetime(s: &str) -> Result<i64> {
    use chrono::{DateTime, FixedOffset, TimeZone};
    // Try RFC3339 first
    if let Ok(dt) = DateTime::parse_from_rfc3339(s) {
        return Ok(dt.timestamp());
    }
    // QuickTime date example: 2023-06-12 14:23:45 +0000
    if let Ok(dt) = DateTime::parse_from_str(s, "%Y-%m-%d %H:%M:%S %z") {
        return Ok(dt.timestamp());
    }
    // Fallback without TZ (assume UTC)
    if let Ok(ndt) = chrono::NaiveDateTime::parse_from_str(s, "%Y-%m-%d %H:%M:%S") {
        return Ok(chrono::Utc.from_utc_datetime(&ndt).timestamp());
    }
    Ok(chrono::Utc::now().timestamp())
}

fn parse_iso6709(s: &str) -> Option<(f64, f64, Option<f32>)> {
    // Example: +37.7850-122.4060+000.000/
    let re =
        Regex::new(r"^(?P<lat>[+-][0-9.]+)(?P<lon>[+-][0-9.]+)(?P<alt>[+-][0-9.]+)?/?").ok()?;
    let caps = re.captures(s)?;
    let lat: f64 = caps.name("lat")?.as_str().parse().ok()?;
    let lon: f64 = caps.name("lon")?.as_str().parse().ok()?;
    let alt: Option<f32> = caps
        .name("alt")
        .and_then(|m| m.as_str().parse::<f32>().ok());
    Some((lat, lon, alt))
}

fn exif_field_any<'a>(exif: &'a Exif, tag: Tag) -> Option<&'a exif::Field> {
    exif.fields().find(|f| f.tag == tag)
}

fn value_to_int(v: &Value) -> Option<i32> {
    match v {
        Value::Short(vals) if !vals.is_empty() => Some(vals[0] as i32),
        Value::Long(vals) if !vals.is_empty() => Some(vals[0] as i32),
        Value::Rational(vals) if !vals.is_empty() => {
            let n = vals[0].num as f32 / vals[0].denom as f32;
            Some(n.round() as i32)
        }
        _ => None,
    }
}

fn extract_exif_data(photo: &mut Photo, exif: &Exif) {
    // Camera info
    if let Some(make) = exif_field_any(exif, Tag::Make) {
        let s = make.display_value().to_string();
        if !s.trim().is_empty() {
            photo.camera_make = Some(s);
        }
    }
    if let Some(model) = exif_field_any(exif, Tag::Model) {
        let s = model.display_value().to_string();
        if !s.trim().is_empty() {
            photo.camera_model = Some(s);
        }
    }

    // Photo settings
    if photo.iso.is_none() {
        if let Some(field) = exif_field_any(exif, Tag::PhotographicSensitivity)
            .or_else(|| exif_field_any(exif, Tag::ISOSpeed))
            .or_else(|| exif_field_any(exif, Tag::StandardOutputSensitivity))
            .or_else(|| exif_field_any(exif, Tag::RecommendedExposureIndex))
        {
            photo.iso = value_to_int(&field.value);
        }
    }

    if let Some(aperture) = exif_field_any(exif, Tag::FNumber) {
        if let Value::Rational(ref vals) = aperture.value {
            if !vals.is_empty() {
                photo.aperture = Some(vals[0].num as f32 / vals[0].denom as f32);
            }
        }
    }

    if let Some(shutter) = exif_field_any(exif, Tag::ExposureTime) {
        photo.shutter_speed = Some(shutter.display_value().to_string());
    }

    if let Some(focal) = exif_field_any(exif, Tag::FocalLength) {
        if let Value::Rational(ref vals) = focal.value {
            if !vals.is_empty() {
                photo.focal_length = Some(vals[0].num as f32 / vals[0].denom as f32);
            }
        }
    }

    // Orientation
    if let Some(orientation) = exif_field_any(exif, Tag::Orientation) {
        if let Value::Short(ref vals) = orientation.value {
            if !vals.is_empty() {
                photo.orientation = Some(vals[0] as i32);
            }
        }
    }

    // Date taken (prefer over file date)
    if let Some(datetime) = exif_field_any(exif, Tag::DateTimeOriginal) {
        if let Ok(timestamp) =
            parse_exif_datetime_with_offset(&datetime.display_value().to_string(), exif)
        {
            photo.created_at = timestamp;
        }
    } else if let Some(datetime) = exif_field_any(exif, Tag::DateTime) {
        if let Ok(timestamp) =
            parse_exif_datetime_with_offset(&datetime.display_value().to_string(), exif)
        {
            photo.created_at = timestamp;
        }
    }

    // GPS coordinates
    extract_gps_data(photo, exif);

    // Caption (iPhone "Caption") from common EXIF fields
    if photo.caption.is_none() {
        // 1) Standard ImageDescription
        if let Some(desc) = exif_field_any(exif, Tag::ImageDescription) {
            let s = desc.display_value().to_string();
            let st = s.trim();
            if !st.is_empty() {
                photo.caption = Some(st.to_string());
            }
        }
    }
    if photo.caption.is_none() {
        // 2) UserComment (may be ASCII/UNICODE); attempt best-effort decoding
        if let Some(uc) = exif_field_any(exif, Tag::UserComment) {
            if let Some(text) = decode_user_comment(&uc.value) {
                let st = text.trim();
                if !st.is_empty() {
                    photo.caption = Some(st.to_string());
                }
            }
        }
    }
}

// Best-effort decoder for EXIF UserComment value (Undefined or Ascii).
fn decode_user_comment(val: &Value) -> Option<String> {
    match val {
        Value::Ascii(vv) => {
            if vv.is_empty() {
                return None;
            }
            let mut s = String::new();
            for part in vv {
                let piece = String::from_utf8_lossy(part);
                if !piece.trim().is_empty() {
                    if !s.is_empty() {
                        s.push(' ');
                    }
                    s.push_str(piece.trim());
                }
            }
            if s.is_empty() {
                None
            } else {
                Some(s)
            }
        }
        Value::Undefined(ref data, _) => {
            let data: &[u8] = data.as_slice();
            if data.is_empty() {
                return None;
            }
            // Try EXIF defined encodings with 8-byte prefix
            if data.len() >= 8 {
                let head = &data[..8];
                // ASCII\0\0\0
                if &head[..5] == b"ASCII" {
                    let rest = &data[8..];
                    let s = String::from_utf8_lossy(rest);
                    let st = s.trim_matches(char::from(0)).trim();
                    return if st.is_empty() {
                        None
                    } else {
                        Some(st.to_string())
                    };
                }
                // UNICODE\0 (commonly UTF-16LE)
                if &head[..7] == b"UNICODE" {
                    let rest = &data[8..];
                    if rest.len() >= 2 {
                        let mut u16s = Vec::with_capacity(rest.len() / 2);
                        let mut i = 0;
                        while i + 1 < rest.len() {
                            let lo = rest[i] as u16;
                            let hi = rest[i + 1] as u16;
                            u16s.push(lo | (hi << 8));
                            i += 2;
                        }
                        let s = String::from_utf16_lossy(&u16s);
                        let st = s.trim_matches(char::from(0)).trim();
                        return if st.is_empty() {
                            None
                        } else {
                            Some(st.to_string())
                        };
                    }
                }
            }
            // Fallback: assume utf-8/latin
            let s = String::from_utf8_lossy(data);
            let st = s.trim_matches(char::from(0)).trim();
            if st.is_empty() {
                None
            } else {
                Some(st.to_string())
            }
        }
        _ => None,
    }
}

fn extract_gps_data(photo: &mut Photo, exif: &Exif) {
    // Latitude
    if let Some(lat_ref) = exif_field_any(exif, Tag::GPSLatitudeRef) {
        if let Some(lat) = exif_field_any(exif, Tag::GPSLatitude) {
            if let Value::Rational(ref vals) = lat.value {
                if vals.len() >= 3 {
                    let degrees = vals[0].num as f64 / vals[0].denom as f64;
                    let minutes = vals[1].num as f64 / vals[1].denom as f64;
                    let seconds = vals[2].num as f64 / vals[2].denom as f64;

                    let mut latitude = degrees + minutes / 60.0 + seconds / 3600.0;

                    // Apply hemisphere
                    if lat_ref.display_value().to_string().starts_with('S') {
                        latitude = -latitude;
                    }

                    photo.latitude = Some(latitude);
                }
            }
        }
    }

    // Longitude
    if let Some(lon_ref) = exif_field_any(exif, Tag::GPSLongitudeRef) {
        if let Some(lon) = exif_field_any(exif, Tag::GPSLongitude) {
            if let Value::Rational(ref vals) = lon.value {
                if vals.len() >= 3 {
                    let degrees = vals[0].num as f64 / vals[0].denom as f64;
                    let minutes = vals[1].num as f64 / vals[1].denom as f64;
                    let seconds = vals[2].num as f64 / vals[2].denom as f64;

                    let mut longitude = degrees + minutes / 60.0 + seconds / 3600.0;

                    // Apply hemisphere
                    if lon_ref.display_value().to_string().starts_with('W') {
                        longitude = -longitude;
                    }

                    photo.longitude = Some(longitude);
                }
            }
        }
    }

    // Altitude
    if let Some(alt) = exif_field_any(exif, Tag::GPSAltitude) {
        if let Value::Rational(ref vals) = alt.value {
            if !vals.is_empty() {
                let altitude = vals[0].num as f64 / vals[0].denom as f64;

                // Check altitude reference (below sea level)
                let below_sea_level = exif_field_any(exif, Tag::GPSAltitudeRef)
                    .map(|r| r.display_value().to_string() == "1")
                    .unwrap_or(false);

                photo.altitude = Some(if below_sea_level { -altitude } else { altitude });
            }
        }
    }
}

fn parse_exif_datetime_with_offset(datetime_str: &str, exif: &Exif) -> Result<i64> {
    use chrono::{DateTime, Local, NaiveDateTime, TimeZone};
    // Prefer raw ASCII if available; display_value may use hyphens
    let raw_dt = exif_field_any(exif, Tag::DateTimeOriginal)
        .and_then(|f| match &f.value {
            Value::Ascii(v) if !v.is_empty() => Some(String::from_utf8_lossy(&v[0]).to_string()),
            _ => None,
        })
        .unwrap_or_else(|| datetime_str.to_string());
    let cleaned = raw_dt.trim_matches('"').to_string();
    let hy = cleaned.replace(':', "-");
    let offset_val = exif_field_any(exif, Tag::OffsetTimeOriginal)
        .or_else(|| exif_field_any(exif, Tag::OffsetTime))
        .map(|v| v.display_value().to_string());

    if let Some(off) = offset_val {
        let off_clean = off.trim_matches('"');
        for base in [&cleaned[..], &hy[..]] {
            let with_colon = format!("{} {}", base, off_clean);
            if let Ok(dt) = DateTime::parse_from_str(&with_colon, "%Y:%m:%d %H:%M:%S %:z")
                .or_else(|_| DateTime::parse_from_str(&with_colon, "%Y-%m-%d %H:%M:%S %:z"))
            {
                return Ok(dt.timestamp());
            }
            let with_plain = format!("{} {}", base, off_clean.replace(':', ""));
            if let Ok(dt) = DateTime::parse_from_str(&with_plain, "%Y:%m:%d %H:%M:%S %z")
                .or_else(|_| DateTime::parse_from_str(&with_plain, "%Y-%m-%d %H:%M:%S %z"))
            {
                return Ok(dt.timestamp());
            }
        }
    }
    if let Ok(naive) = NaiveDateTime::parse_from_str(&cleaned, "%Y:%m:%d %H:%M:%S")
        .or_else(|_| NaiveDateTime::parse_from_str(&hy, "%Y-%m-%d %H:%M:%S"))
    {
        if let Some(local_dt) = Local.from_local_datetime(&naive).single() {
            return Ok(local_dt.timestamp());
        }
        return Ok(naive.and_utc().timestamp());
    }
    Ok(chrono::Utc::now().timestamp())
}

// Removed debug_exif_for_path; use normal metadata paths

// Reverse geocoding would go here - placeholder for now
pub async fn reverse_geocode(
    latitude: f64,
    longitude: f64,
) -> Result<(
    Option<String>,
    Option<String>,
    Option<String>,
    Option<String>,
)> {
    // This would call a geocoding API like Nominatim or Google Maps
    // For now, return empty values
    Ok((None, None, None, None))
}

#[cfg(test)]
mod tests {
    use super::ensure_heic_ml_proxy;
    use image::codecs::jpeg::JpegEncoder;
    use std::fs;
    use std::path::PathBuf;

    fn mk_test_dir() -> PathBuf {
        let mut p = std::env::temp_dir();
        p.push(format!(
            "openphotos-metadata-tests-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos()
        ));
        fs::create_dir_all(&p).expect("create temp dir");
        p
    }

    #[test]
    fn ensure_heic_ml_proxy_supports_avif_extension() {
        let dir = mk_test_dir();
        let avif_like = dir.join("sample.avif");

        let rgb = image::RgbImage::from_pixel(16, 12, image::Rgb([10, 20, 30]));
        let mut encoded = Vec::new();
        JpegEncoder::new_with_quality(&mut encoded, 85)
            .encode(&rgb, rgb.width(), rgb.height(), image::ColorType::Rgb8)
            .expect("encode jpeg");
        fs::write(&avif_like, encoded).expect("write avif-like jpeg");

        let proxy = ensure_heic_ml_proxy(&avif_like, 1024).expect("build proxy");
        assert!(proxy.exists(), "proxy file should exist");
        assert_ne!(proxy, avif_like, "avif path should map to proxy");
        assert_eq!(proxy.extension().and_then(|e| e.to_str()), Some("jpg"));
    }
}
