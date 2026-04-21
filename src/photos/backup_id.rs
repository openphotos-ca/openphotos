use anyhow::Result;
use hmac::{Hmac, Mac};
use sha2::Sha256;
use std::path::Path;

type HmacSha256 = Hmac<Sha256>;

fn compute_hmac_b58_first16(user_id: &str, bytes: &[u8]) -> Result<String> {
    let mut mac = HmacSha256::new_from_slice(user_id.as_bytes())
        .map_err(|e| anyhow::anyhow!("hmac init: {}", e))?;
    mac.update(bytes);
    let full = mac.finalize().into_bytes();
    Ok(bs58::encode(&full[..16]).into_string())
}

fn is_jpeg(bytes: &[u8]) -> bool {
    bytes.len() >= 2 && bytes[0] == 0xFF && bytes[1] == 0xD8
}

fn strip_jpeg_exif_xmp_app1(bytes: &[u8]) -> Option<Vec<u8>> {
    if !is_jpeg(bytes) {
        return None;
    }
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    out.extend_from_slice(&bytes[0..2]); // SOI

    let mut i = 2usize;
    while i + 4 <= bytes.len() {
        if bytes[i] != 0xFF {
            // Invalid marker; fallback to hashing full bytes
            return None;
        }
        let mut j = i;
        while j < bytes.len() && bytes[j] == 0xFF {
            j += 1;
        }
        if j >= bytes.len() {
            return None;
        }
        let marker = bytes[j];
        if marker == 0xD9 {
            // EOI
            out.extend_from_slice(&bytes[i..j + 1]);
            return Some(out);
        }
        if marker == 0xDA {
            // SOS: copy rest as-is
            out.extend_from_slice(&bytes[i..]);
            return Some(out);
        }
        if j + 2 >= bytes.len() {
            return None;
        }
        let len = u16::from_be_bytes([bytes[j + 1], bytes[j + 2]]) as usize; // includes length bytes
        let seg_end = j + 1 + len;
        if seg_end > bytes.len() {
            return None;
        }
        let payload_off = j + 3;
        let payload = &bytes[payload_off..seg_end];
        let keep = if marker == 0xE1 {
            // APP1: skip EXIF and XMP packets
            !(payload.starts_with(b"Exif\0\0")
                || payload.starts_with(b"http://ns.adobe.com/xap/1.0/\0"))
        } else {
            true
        };
        if keep {
            out.extend_from_slice(&bytes[i..seg_end]);
        }
        i = seg_end;
    }
    None
}

/// Compute a stable "backup_id" fingerprint for cloud-backup checks.
///
/// For JPEGs, this strips EXIF/XMP APP1 segments before hashing so that server-side EXIF writes
/// (or other metadata-only changes) don't cause false "missing" results.
/// For all other types, it hashes the full bytes.
pub fn from_bytes(bytes: &[u8], user_id: &str) -> Result<String> {
    if let Some(stripped) = strip_jpeg_exif_xmp_app1(bytes) {
        return compute_hmac_b58_first16(user_id, &stripped);
    }
    compute_hmac_b58_first16(user_id, bytes)
}

/// Compute a stable image-only fingerprint from upright decoded pixels.
///
/// This is intended for cloud-backup presence checks on still images whose container bytes may
/// change across exports or metadata rewrites (for example HEIC and PNG). The visible image is
/// flattened onto white, encoded as RGBA bytes, and then HMACed with the user id.
pub fn visual_from_path(path: &Path, user_id: &str) -> Result<String> {
    let img = crate::photos::metadata::open_image_any(path)?;
    let rgba = img.to_rgba8();
    let (width, height) = rgba.dimensions();

    let mut normalized = Vec::with_capacity((width as usize) * (height as usize) * 4);
    for px in rgba.pixels() {
        let [r, g, b, a] = px.0;
        let alpha = a as u32;
        let inv_alpha = 255u32.saturating_sub(alpha);
        let out_r = ((r as u32 * alpha) + (255 * inv_alpha) + 127) / 255;
        let out_g = ((g as u32 * alpha) + (255 * inv_alpha) + 127) / 255;
        let out_b = ((b as u32 * alpha) + (255 * inv_alpha) + 127) / 255;
        normalized.push(out_r as u8);
        normalized.push(out_g as u8);
        normalized.push(out_b as u8);
        normalized.push(255);
    }

    let mut payload = Vec::with_capacity(16 + normalized.len());
    payload.extend_from_slice(b"visual-image-v1");
    payload.extend_from_slice(&width.to_be_bytes());
    payload.extend_from_slice(&height.to_be_bytes());
    payload.extend_from_slice(&normalized);
    compute_hmac_b58_first16(user_id, &payload)
}
