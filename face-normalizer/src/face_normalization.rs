use anyhow::Result;
use image::{DynamicImage, RgbImage};
use log::debug;
use nalgebra::Matrix2x3;

use crate::types::{FaceDetection, FacialLandmarks};

pub struct FaceNormalizer {
    target_size: u32,
}

impl FaceNormalizer {
    pub fn new() -> Self {
        Self {
            target_size: 112, // ArcFace standard input size
        }
    }

    pub fn normalize_face(
        &self,
        image: &DynamicImage,
        detection: &FaceDetection,
    ) -> Result<RgbImage> {
        debug!("Normalizing face with bbox: {:?}", detection.bbox);

        // Use landmark-based alignment for proper face orientation
        // This handles rotated faces correctly (like test2.jpg with 30-degree rotation)
        let aligned_face = self.norm_crop(image, &detection.landmarks)?;

        debug!(
            "Normalized face to {}x{}",
            self.target_size, self.target_size
        );
        Ok(aligned_face)
    }

    /// Simple crop and resize approach to match Python InsightFace behavior
    fn simple_crop_resize(
        &self,
        image: &DynamicImage,
        bbox: &crate::types::BoundingBox,
    ) -> Result<RgbImage> {
        let img_width = image.width() as f32;
        let img_height = image.height() as f32;

        // The bounding box coordinates are already in pixel space, not normalized
        let x1 = bbox.x1.max(0.0).min(img_width - 1.0) as u32;
        let y1 = bbox.y1.max(0.0).min(img_height - 1.0) as u32;
        let x2 = bbox.x2.max(x1 as f32 + 1.0).min(img_width) as u32;
        let y2 = bbox.y2.max(y1 as f32 + 1.0).min(img_height) as u32;

        // Calculate dimensions
        let width = x2 - x1;
        let height = y2 - y1;

        debug!(
            "Image: {}x{}, BBox: ({:.3}, {:.3}, {:.3}, {:.3})",
            img_width, img_height, bbox.x1, bbox.y1, bbox.x2, bbox.y2
        );
        debug!(
            "Cropping face: ({}, {}) -> ({}, {}), size: {}x{}",
            x1, y1, x2, y2, width, height
        );

        // Ensure minimum dimensions
        if width < 10 || height < 10 {
            return Err(anyhow::anyhow!(
                "Face region too small: {}x{}",
                width,
                height
            ));
        }

        // Crop the face region
        let cropped = image.crop_imm(x1, y1, width, height);

        // Resize to target size (this will handle aspect ratio automatically)
        let resized = cropped.resize_exact(
            self.target_size,
            self.target_size,
            image::imageops::FilterType::Lanczos3,
        );

        Ok(resized.to_rgb8())
    }

    /// Implementation of InsightFace's norm_crop function
    /// This aligns the face based on 5 landmarks to a standard 112x112 template
    fn norm_crop(&self, image: &DynamicImage, landmarks: &FacialLandmarks) -> Result<RgbImage> {
        // Standard ArcFace template landmarks for 112x112 face
        // These are the reference positions for aligned faces
        let arcface_template = vec![
            (30.2946, 51.6963), // left eye
            (65.5318, 51.5014), // right eye
            (48.0252, 71.7366), // nose tip
            (33.5493, 92.3655), // left mouth corner
            (62.7299, 92.2041), // right mouth corner
        ];

        // Get transformation matrix using Umeyama algorithm
        let transform_matrix = self.estimate_norm(&landmarks.points, &arcface_template)?;

        // Apply transformation to get aligned face
        let aligned_face = self.warp_affine(image, &transform_matrix, self.target_size)?;

        Ok(aligned_face)
    }

    /// Umeyama algorithm for estimating similarity transformation
    /// This is the same algorithm used by InsightFace
    fn estimate_norm(
        &self,
        src_points: &[(f32, f32)],
        dst_points: &[(f32, f32)],
    ) -> Result<Matrix2x3<f32>> {
        assert_eq!(src_points.len(), dst_points.len());
        assert_eq!(src_points.len(), 5);

        let num_points = src_points.len();

        // Convert to matrix form
        let mut src_mat = nalgebra::DMatrix::<f32>::zeros(num_points * 2, 4);
        let mut dst_vec = nalgebra::DVector::<f32>::zeros(num_points * 2);

        for i in 0..num_points {
            let (sx, sy) = src_points[i];
            let (dx, dy) = dst_points[i];

            // Fill matrix for least squares
            // [x -y 1 0] [a]   [x']
            // [y  x 0 1] [b] = [y']
            //            [c]
            //            [d]
            src_mat[(i * 2, 0)] = sx;
            src_mat[(i * 2, 1)] = -sy;
            src_mat[(i * 2, 2)] = 1.0;
            src_mat[(i * 2, 3)] = 0.0;

            src_mat[(i * 2 + 1, 0)] = sy;
            src_mat[(i * 2 + 1, 1)] = sx;
            src_mat[(i * 2 + 1, 2)] = 0.0;
            src_mat[(i * 2 + 1, 3)] = 1.0;

            dst_vec[i * 2] = dx;
            dst_vec[i * 2 + 1] = dy;
        }

        // Solve least squares problem
        let svd = src_mat.clone().svd(true, true);
        let params = svd
            .solve(&dst_vec, 1e-6)
            .map_err(|e| anyhow::anyhow!("Failed to solve transformation: {}", e))?;

        // Extract transformation parameters
        let a = params[0];
        let b = params[1];
        let c = params[2];
        let d = params[3];

        // Build affine transformation matrix
        let transform = Matrix2x3::new(a, -b, c, b, a, d);

        Ok(transform)
    }

    /// Apply affine transformation to warp the image
    fn warp_affine(
        &self,
        image: &DynamicImage,
        transform: &Matrix2x3<f32>,
        output_size: u32,
    ) -> Result<RgbImage> {
        let rgb_image = image.to_rgb8();
        let mut output = RgbImage::new(output_size, output_size);

        // Compute inverse transformation for backward mapping
        let a = transform[(0, 0)];
        let b = transform[(0, 1)];
        let c = transform[(0, 2)];
        let d = transform[(1, 0)];
        let e = transform[(1, 1)];
        let f = transform[(1, 2)];

        let det = a * e - b * d;
        if det.abs() < 1e-10 {
            return Err(anyhow::anyhow!("Transformation matrix is singular"));
        }

        let inv_det = 1.0 / det;
        let inv_a = e * inv_det;
        let inv_b = -b * inv_det;
        let inv_c = (b * f - c * e) * inv_det;
        let inv_d = -d * inv_det;
        let inv_e = a * inv_det;
        let inv_f = (c * d - a * f) * inv_det;

        // Apply backward mapping with bilinear interpolation
        for y_out in 0..output_size {
            for x_out in 0..output_size {
                // Transform output coordinates to input coordinates
                let x_in = inv_a * x_out as f32 + inv_b * y_out as f32 + inv_c;
                let y_in = inv_d * x_out as f32 + inv_e * y_out as f32 + inv_f;

                // Bilinear interpolation
                let pixel = self.bilinear_interpolate(&rgb_image, x_in, y_in);
                output.put_pixel(x_out, y_out, pixel);
            }
        }

        Ok(output)
    }

    /// Bilinear interpolation for smooth image warping
    fn bilinear_interpolate(&self, image: &RgbImage, x: f32, y: f32) -> image::Rgb<u8> {
        let (width, height) = image.dimensions();

        // Clamp coordinates
        let x = x.max(0.0).min((width - 1) as f32);
        let y = y.max(0.0).min((height - 1) as f32);

        // Get integer coordinates
        let x0 = x.floor() as u32;
        let y0 = y.floor() as u32;
        let x1 = (x0 + 1).min(width - 1);
        let y1 = (y0 + 1).min(height - 1);

        // Get fractional parts
        let fx = x - x0 as f32;
        let fy = y - y0 as f32;

        // Get pixels
        let p00 = image.get_pixel(x0, y0);
        let p01 = image.get_pixel(x0, y1);
        let p10 = image.get_pixel(x1, y0);
        let p11 = image.get_pixel(x1, y1);

        // Interpolate
        let mut result = [0u8; 3];
        for i in 0..3 {
            let v00 = p00[i] as f32;
            let v01 = p01[i] as f32;
            let v10 = p10[i] as f32;
            let v11 = p11[i] as f32;

            let v0 = v00 * (1.0 - fx) + v10 * fx;
            let v1 = v01 * (1.0 - fx) + v11 * fx;
            let v = v0 * (1.0 - fy) + v1 * fy;

            result[i] = v.round().max(0.0).min(255.0) as u8;
        }

        image::Rgb(result)
    }
}
