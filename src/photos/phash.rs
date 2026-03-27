use anyhow::{Context, Result};
use image::imageops::FilterType;
use image::{DynamicImage, GenericImageView, Luma};
use std::path::Path;

use crate::photos::metadata::{ensure_heic_ml_proxy, open_image_any, open_image_upright};

/// Compute a 64-bit perceptual hash (pHash) using a DCT-based algorithm.
/// Steps:
/// - Load image and apply EXIF orientation (upright)
/// - Convert to grayscale and resize to 32x32
/// - Compute 2D DCT (type-II) and take the top-left 8x8 coefficients (excluding DC)
/// - Threshold by median to produce 64-bit hash
pub fn compute_phash_from_path(path: &Path) -> Result<u64> {
    // For HEIC/HEIF/AVIF, reuse the ML JPG proxy we generate for YOLO/RetinaFace to ensure
    // consistent decoding and orientation handling.
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_lowercase();
    if ext == "heic" || ext == "heif" || ext == "avif" {
        let proxy = ensure_heic_ml_proxy(path, 1024)
            .with_context(|| format!("Failed to build ML proxy for pHash: {:?}", path))?;
        let img = image::open(&proxy)
            .with_context(|| format!("Failed to open ML proxy JPG for pHash: {:?}", proxy))?;
        return compute_phash(&img);
    } else if ext == "dng" {
        let img = open_image_any(path)
            .with_context(|| format!("Failed to open DNG preview for pHash: {:?}", path))?;
        return compute_phash(&img);
    }

    let img = open_image_upright(path)
        .with_context(|| format!("Failed to open image for pHash: {:?}", path))?;
    compute_phash(&img)
}

pub fn compute_phash(img: &DynamicImage) -> Result<u64> {
    // 1) Grayscale and resize to 32x32
    let gray = img.to_luma8();
    let resized = image::imageops::resize(&gray, 32, 32, FilterType::CatmullRom);

    // 2) Convert to f64 matrix [32x32], normalize to [0,1]
    let mut mat = [[0f64; 32]; 32];
    for y in 0..32 {
        for x in 0..32 {
            let p = resized.get_pixel(x, y).0[0] as f64;
            mat[y as usize][x as usize] = p;
        }
    }

    // 3) 2D DCT (type-II) via separable 1D DCT on rows then columns
    let mut tmp = [[0f64; 32]; 32];
    for y in 0..32 {
        dct_1d(&mat[y], &mut tmp[y]);
    }

    let mut dct = [[0f64; 32]; 32];
    // Transpose, DCT columns, transpose back
    let mut col_in = [0f64; 32];
    let mut col_out = [0f64; 32];
    for x in 0..32 {
        for y in 0..32 {
            col_in[y] = tmp[y][x];
        }
        dct_1d(&col_in, &mut col_out);
        for y in 0..32 {
            dct[y][x] = col_out[y];
        }
    }

    // 4) Take top-left 8x8 block, ignoring DC at (0,0)
    let mut vals = [0f64; 64];
    let mut k = 0usize;
    for y in 0..8 {
        for x in 0..8 {
            vals[k] = dct[y][x];
            k += 1;
        }
    }
    // Exclude DC from median calculation
    let mut ac_vals = [0f64; 63];
    for i in 1..64 {
        ac_vals[i - 1] = vals[i];
    }
    ac_vals.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let median = ac_vals[31];

    // 5) Build 64-bit hash: bit i is 1 if vals[i] > median
    let mut hash: u64 = 0;
    for i in 0..64 {
        if vals[i] > median {
            hash |= 1u64 << i;
        }
    }

    Ok(hash)
}

fn dct_1d(input: &[f64; 32], output: &mut [f64; 32]) {
    // Orthogonal DCT-II with symmetric normalization
    const N: usize = 32;
    let n = N as f64;
    for u in 0..N {
        let mut sum = 0.0f64;
        for x in 0..N {
            let theta = std::f64::consts::PI * ((x as f64) + 0.5) * (u as f64) / n;
            sum += input[x] * theta.cos();
        }
        let alpha = if u == 0 {
            (1.0 / n).sqrt()
        } else {
            (2.0 / n).sqrt()
        };
        output[u] = alpha * sum;
    }
}

/// Convert a 64-bit pHash to lowercase hex string
pub fn phash_to_hex(h: u64) -> String {
    format!("{:016x}", h)
}

/// Parse lowercase hex string to u64
pub fn phash_from_hex(s: &str) -> Option<u64> {
    u64::from_str_radix(s, 16).ok()
}

/// Hamming distance between two 64-bit hashes
pub fn hamming_distance(a: u64, b: u64) -> u32 {
    (a ^ b).count_ones()
}
