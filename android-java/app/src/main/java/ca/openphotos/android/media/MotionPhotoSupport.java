package ca.openphotos.android.media;

import android.content.Context;
import android.net.Uri;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import java.io.File;
import java.util.Locale;

/** Shared Android Motion Photo (Live Photo equivalent) heuristics + extraction wrapper. */
public final class MotionPhotoSupport {
    public static final String TAG = "OpenPhotosMotion";

    private MotionPhotoSupport() {}

    /** Heuristic prefilter to avoid expensive parser runs on obvious non-motion assets. */
    public static boolean isLikelyMotionPhoto(@Nullable String filename, @Nullable String mimeType) {
        String name = filename == null ? "" : filename.toUpperCase(Locale.US);
        String mime = mimeType == null ? "" : mimeType.toLowerCase(Locale.US);
        boolean imageLike = mime.contains("jpeg")
                || mime.contains("jpg")
                || mime.contains("heic")
                || mime.contains("heif")
                || mime.startsWith("image/");
        if (!imageLike) return false;
        return name.startsWith("MVIMG")
                || name.contains("_MP")
                || name.contains("MOTION");
    }

    /** Run parser only after heuristic pass; emits structured diagnostics. */
    @Nullable
    public static File extractMotionIfLikely(
            @NonNull Context app,
            @NonNull Uri imageUri,
            @Nullable String filename,
            @Nullable String mimeType,
            @Nullable String contentId,
            @NonNull String source
    ) {
        if (!isLikelyMotionPhoto(filename, mimeType)) {
            return null;
        }
        Log.i(TAG, "heuristic-match source=" + source
                + " file=" + (filename == null ? "" : filename)
                + " mime=" + (mimeType == null ? "" : mimeType)
                + " contentId=" + (contentId == null ? "" : contentId));

        MotionPhotoParser.Result parsed = MotionPhotoParser.detectAndExtract(app.getApplicationContext(), imageUri);
        if (parsed.isMotion && parsed.mp4 != null && parsed.mp4.exists() && parsed.mp4.length() > 0) {
            Log.i(TAG, "extract-success source=" + source
                    + " file=" + parsed.mp4.getName()
                    + " bytes=" + parsed.mp4.length()
                    + " contentId=" + (contentId == null ? "" : contentId));
            return parsed.mp4;
        }

        Log.i(TAG, "extract-miss source=" + source
                + " file=" + (filename == null ? "" : filename)
                + " contentId=" + (contentId == null ? "" : contentId));
        return null;
    }
}
