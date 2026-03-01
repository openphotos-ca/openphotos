use anyhow::Result;
use hmac::{Hmac, Mac};
use sha2::Sha256;
use std::fs::File;
use std::io::{BufReader, Read};

type HmacSha256 = Hmac<Sha256>;

/// Compute Base58(first16(HMAC-SHA256(user_id, file_bytes))) from a file path (streaming).
pub fn from_path(path: &std::path::Path, user_id: &str) -> Result<String> {
    let mut mac = HmacSha256::new_from_slice(user_id.as_bytes())
        .map_err(|e| anyhow::anyhow!("hmac init: {}", e))?;
    let file = File::open(path)?;
    let mut reader = BufReader::new(file);
    let mut buf = vec![0u8; 512 * 1024];
    loop {
        let n = reader.read(&mut buf)?;
        if n == 0 {
            break;
        }
        mac.update(&buf[..n]);
    }
    let full = mac.finalize().into_bytes();
    let truncated = &full[..16];
    Ok(bs58::encode(truncated).into_string())
}

/// Compute Base58(first16(HMAC-SHA256(user_id, bytes))) from in-memory bytes.
pub fn from_bytes(bytes: &[u8], user_id: &str) -> Result<String> {
    let mut mac = HmacSha256::new_from_slice(user_id.as_bytes())
        .map_err(|e| anyhow::anyhow!("hmac init: {}", e))?;
    mac.update(bytes);
    let full = mac.finalize().into_bytes();
    let truncated = &full[..16];
    Ok(bs58::encode(truncated).into_string())
}
