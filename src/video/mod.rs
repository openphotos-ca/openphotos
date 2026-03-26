use anyhow::Result;
use image::{imageops, DynamicImage};
use serde::Deserialize;
use std::path::Path;

use crate::media_tools::{ffmpeg_command, ffprobe_command};

#[derive(Debug, Clone, Default)]
pub struct VideoMetadata {
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub duration_ms: Option<i64>,
    pub rotation_deg: Option<i32>,
}

#[derive(Debug, Deserialize)]
struct FfprobeStream {
    width: Option<u32>,
    height: Option<u32>,
    duration: Option<String>,
    tags: Option<FfprobeTags>,
}

#[derive(Debug, Deserialize)]
struct FfprobeTags {
    rotate: Option<String>,
}

#[derive(Debug, Deserialize)]
struct FfprobeOutput {
    streams: Option<Vec<FfprobeStream>>,
}

pub fn is_video_extension(ext: &str) -> bool {
    matches!(
        ext.to_lowercase().as_str(),
        "mp4" | "mov" | "m4v" | "webm" | "mkv" | "avi"
    )
}

pub fn probe_metadata(path: &Path) -> Result<VideoMetadata> {
    let output = ffprobe_command()
        .args([
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-show_entries",
            "stream=width,height,duration:stream_tags=rotate",
            "-of",
            "json",
            &path.to_string_lossy(),
        ])
        .output()?;
    if !output.status.success() {
        return Ok(VideoMetadata::default());
    }
    let parsed: FfprobeOutput =
        serde_json::from_slice(&output.stdout).unwrap_or(FfprobeOutput { streams: None });
    if let Some(streams) = parsed.streams {
        if let Some(s) = streams.first() {
            let width = s.width;
            let height = s.height;
            let rotation_deg = s
                .tags
                .as_ref()
                .and_then(|t| t.rotate.as_ref())
                .and_then(|r| r.parse::<i32>().ok());
            let duration_ms = s
                .duration
                .as_ref()
                .and_then(|d| d.parse::<f64>().ok())
                .map(|secs| (secs * 1000.0) as i64);
            return Ok(VideoMetadata {
                width,
                height,
                duration_ms,
                rotation_deg,
            });
        }
    }
    Ok(VideoMetadata::default())
}

/// Returns true when the video file is a Live Photo motion component (iOS paired MOV).
///
/// We detect this by looking for well-known QuickTime metadata keys emitted by iOS, such as:
/// - `com.apple.quicktime.content.identifier`
/// - `com.apple.quicktime.live-photo.auto`
///
/// This is used to ensure Live Photo paired MOVs are not treated as standalone user videos.
pub fn is_live_photo_component(path: &Path) -> bool {
    let output = ffprobe_command()
        .args([
            "-v",
            "error",
            "-show_entries",
            "format_tags",
            "-of",
            "json",
            &path.to_string_lossy(),
        ])
        .output();
    let Ok(output) = output else {
        return false;
    };
    if !output.status.success() {
        return false;
    }
    let Ok(v) = serde_json::from_slice::<serde_json::Value>(&output.stdout) else {
        return false;
    };
    let Some(tags) = v
        .get("format")
        .and_then(|f| f.get("tags"))
        .and_then(|t| t.as_object())
    else {
        return false;
    };
    tags.contains_key("com.apple.quicktime.content.identifier")
        || tags.contains_key("com.apple.quicktime.live-photo.auto")
        || tags.contains_key("com.apple.quicktime.still-image-time")
}

pub fn extract_frame_image(path: &Path, time_sec: f64) -> Result<DynamicImage> {
    let mut ss_arg = format!("{:.3}", time_sec.max(0.0));
    if ss_arg == "0" {
        ss_arg = "0.0".to_string();
    }
    let output = ffmpeg_command()
        .args([
            "-y",
            "-ss",
            &ss_arg,
            "-i",
            &path.to_string_lossy(),
            "-frames:v",
            "1",
            "-f",
            "image2pipe",
            "-vcodec",
            "png",
            "pipe:1",
        ])
        .output()?;
    if !output.status.success() {
        return Err(anyhow::anyhow!(
            "ffmpeg failed extracting frame (status {:?})",
            output.status
        ));
    }
    let img = image::load_from_memory(&output.stdout)?;
    Ok(img)
}

pub fn extract_frame_upright(path: &Path, time_sec: f64) -> Result<DynamicImage> {
    let mut img = extract_frame_image(path, time_sec)?;
    // Apply rotation if stream has rotate tag
    let meta = probe_metadata(path).unwrap_or_default();
    if let Some(rot) = meta.rotation_deg {
        match rot.rem_euclid(360) {
            90 => {
                img = image::DynamicImage::ImageRgba8(imageops::rotate90(&img));
            }
            180 => {
                img = image::DynamicImage::ImageRgba8(imageops::rotate180(&img));
            }
            270 => {
                img = image::DynamicImage::ImageRgba8(imageops::rotate270(&img));
            }
            _ => {}
        }
    }
    Ok(img)
}
