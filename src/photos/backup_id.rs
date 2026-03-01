use anyhow::Result;
use hmac::{Hmac, Mac};
use sha2::Sha256;

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
