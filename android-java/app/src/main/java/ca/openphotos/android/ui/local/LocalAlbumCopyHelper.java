package ca.openphotos.android.ui.local;

import android.content.ContentResolver;
import android.content.ContentValues;
import android.content.Context;
import android.net.Uri;
import android.provider.MediaStore;

import androidx.annotation.NonNull;

import java.io.InputStream;
import java.io.OutputStream;
import java.util.List;
import java.util.Locale;

/** Copies local MediaStore items into another device album/folder path. */
public final class LocalAlbumCopyHelper {
    private LocalAlbumCopyHelper() {}

    public static final class Result {
        public int copied;
        public int skipped;
        public int failed;
    }

    @NonNull
    public static Result copyItemsToFolder(
            @NonNull Context context,
            @NonNull List<LocalMediaItem> items,
            @NonNull String targetFolderPath
    ) {
        Result result = new Result();
        String targetPath = normalizeRelativePath(targetFolderPath);
        if (targetPath.isEmpty()) {
            result.failed = items.size();
            return result;
        }

        ContentResolver resolver = context.getApplicationContext().getContentResolver();
        for (LocalMediaItem item : items) {
            if (item == null) continue;
            if (normalizeRelativePath(item.relativePath).equalsIgnoreCase(targetPath)) {
                result.skipped++;
                continue;
            }

            boolean ok = copySingle(resolver, item, targetPath, safeDisplayName(item));
            if (!ok) {
                ok = copySingle(resolver, item, targetPath, appendCopySuffix(safeDisplayName(item)));
            }
            if (ok) result.copied++;
            else result.failed++;
        }
        return result;
    }

    private static boolean copySingle(
            @NonNull ContentResolver resolver,
            @NonNull LocalMediaItem item,
            @NonNull String targetPath,
            @NonNull String displayName
    ) {
        Uri inserted = null;
        try {
            ContentValues values = new ContentValues();
            values.put(MediaStore.MediaColumns.DISPLAY_NAME, displayName);
            values.put(MediaStore.MediaColumns.MIME_TYPE, safeMimeType(item));
            values.put(MediaStore.MediaColumns.RELATIVE_PATH, targetPath);
            values.put(MediaStore.MediaColumns.IS_PENDING, 1);
            if (item.createdAtSec > 0) {
                long takenMs = item.createdAtSec * 1000L;
                if (item.isVideo) values.put(MediaStore.Video.Media.DATE_TAKEN, takenMs);
                else values.put(MediaStore.Images.Media.DATE_TAKEN, takenMs);
            }
            if (item.dateModifiedSec > 0) {
                values.put(MediaStore.MediaColumns.DATE_MODIFIED, item.dateModifiedSec);
            }

            inserted = resolver.insert(
                    item.isVideo ? MediaStore.Video.Media.EXTERNAL_CONTENT_URI
                            : MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                    values
            );
            if (inserted == null) return false;

            try (InputStream is = resolver.openInputStream(Uri.parse(item.uri));
                 OutputStream os = resolver.openOutputStream(inserted, "w")) {
                if (is == null || os == null) return false;
                byte[] buf = new byte[8192];
                int n;
                while ((n = is.read(buf)) > 0) {
                    os.write(buf, 0, n);
                }
            }

            ContentValues published = new ContentValues();
            published.put(MediaStore.MediaColumns.IS_PENDING, 0);
            resolver.update(inserted, published, null, null);
            return true;
        } catch (Exception ignored) {
            if (inserted != null) {
                try { resolver.delete(inserted, null, null); } catch (Exception ignoredDelete) {}
            }
            return false;
        }
    }

    @NonNull
    private static String normalizeRelativePath(@NonNull String path) {
        String out = path.trim();
        while (out.endsWith("/")) {
            out = out.substring(0, out.length() - 1);
        }
        return out;
    }

    @NonNull
    private static String safeDisplayName(@NonNull LocalMediaItem item) {
        String name = item.displayName == null ? "" : item.displayName.trim();
        if (!name.isEmpty()) return name;
        String fallbackExt = item.isVideo ? ".mp4" : ".jpg";
        return "Copy_" + Math.max(0L, item.createdAtSec) + fallbackExt;
    }

    @NonNull
    private static String safeMimeType(@NonNull LocalMediaItem item) {
        String mime = item.mimeType == null ? "" : item.mimeType.trim().toLowerCase(Locale.US);
        if (!mime.isEmpty()) return mime;
        return item.isVideo ? "video/mp4" : "image/jpeg";
    }

    @NonNull
    private static String appendCopySuffix(@NonNull String displayName) {
        int dot = displayName.lastIndexOf('.');
        if (dot <= 0 || dot == displayName.length() - 1) {
            return displayName + " (Copy)";
        }
        return displayName.substring(0, dot) + " (Copy)" + displayName.substring(dot);
    }
}
