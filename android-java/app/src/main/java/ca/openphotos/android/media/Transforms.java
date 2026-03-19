package ca.openphotos.android.media;

import android.content.ContentResolver;
import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.ImageDecoder;
import android.net.Uri;
import android.os.Build;
import android.provider.MediaStore;

import androidx.annotation.Nullable;

import java.io.File;
import java.io.FileOutputStream;

/** Image/Video transforms needed for uploads (HEIC->JPEG for locked, RAW thumb). */
public final class Transforms {
    private Transforms() {}

    /**
     * Convert a HEIC/HEIF image content URI to a JPEG file for locked uploads.
     * Returns the created file or null if conversion failed.
     */
    @Nullable
    public static File heicToJpeg(Context app, Uri input, float quality) {
        try {
            ContentResolver cr = app.getContentResolver();
            Bitmap bmp;
            if (Build.VERSION.SDK_INT >= 28) {
                ImageDecoder.Source src = ImageDecoder.createSource(cr, input);
                bmp = ImageDecoder.decodeBitmap(src);
            } else {
                bmp = MediaStore.Images.Media.getBitmap(cr, input);
            }
            File out = File.createTempFile("conv_", ".jpg", app.getCacheDir());
            try (FileOutputStream fos = new FileOutputStream(out)) {
                bmp.compress(Bitmap.CompressFormat.JPEG, Math.round(quality * 100), fos);
            }
            return out;
        } catch (Exception e) {
            return null;
        }
    }

    /**
     * Generate a thumbnail bitmap file for RAW (e.g., DNG). Uses embedded preview when available;
     * falls back to decoding a scaled bitmap (best-effort). Returns JPEG file or null.
     */
    @Nullable
    public static File rawThumbnailToJpeg(Context app, Uri rawUri, int maxDim) {
        try {
            androidx.exifinterface.media.ExifInterface exif = new androidx.exifinterface.media.ExifInterface(app.getContentResolver().openInputStream(rawUri));
            android.graphics.Bitmap bmp = exif.getThumbnailBitmap();
            if (bmp == null) {
                // Best-effort: some devices expose a decodable preview stream
                if (android.os.Build.VERSION.SDK_INT >= 28) {
                    android.graphics.ImageDecoder.Source src = android.graphics.ImageDecoder.createSource(app.getContentResolver(), rawUri);
                    bmp = android.graphics.ImageDecoder.decodeBitmap(src, (decoder, info, src2) -> decoder.setTargetSampleSize(4));
                }
            }
            if (bmp == null) return null;
            // Scale down to maxDim
            int w = bmp.getWidth(), h = bmp.getHeight();
            float scale = Math.min(1f, maxDim / (float) Math.max(w, h));
            if (scale < 1f) bmp = android.graphics.Bitmap.createScaledBitmap(bmp, Math.round(w * scale), Math.round(h * scale), true);
            File out = File.createTempFile("raw_thumb_", ".jpg", app.getCacheDir());
            try (FileOutputStream fos = new FileOutputStream(out)) {
                bmp.compress(Bitmap.CompressFormat.JPEG, 90, fos);
            }
            return out;
        } catch (Exception e) {
            return null;
        }
    }
}
