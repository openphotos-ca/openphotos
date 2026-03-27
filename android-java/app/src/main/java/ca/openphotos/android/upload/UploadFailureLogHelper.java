package ca.openphotos.android.upload;

import android.util.Log;

import androidx.annotation.NonNull;

import ca.openphotos.android.data.db.dao.PhotoDao;
import ca.openphotos.android.data.db.dao.UploadDao;
import ca.openphotos.android.data.db.entities.PhotoEntity;
import ca.openphotos.android.data.db.entities.UploadEntity;

import java.util.List;

/** Emits compact failed-upload samples after a run so logs remain diagnosable even without stack traces. */
public final class UploadFailureLogHelper {
    private UploadFailureLogHelper() {}

    public static void logRecentFailedRows(
            @NonNull String tag,
            @NonNull String runner,
            @NonNull UploadDao uploadDao,
            @NonNull PhotoDao photoDao,
            int limit
    ) {
        try {
            List<UploadEntity> rows = uploadDao.listFailed(Math.max(1, limit));
            if (rows == null || rows.isEmpty()) {
                Log.w(tag, runner + " failed sample query returned no rows");
                return;
            }
            int idx = 0;
            for (UploadEntity row : rows) {
                if (row == null) continue;
                idx++;
                PhotoEntity photo = null;
                if (row.contentId != null && !row.contentId.isEmpty()) {
                    try {
                        photo = photoDao.getByContentId(row.contentId);
                    } catch (Exception ignored) {
                    }
                }
                Log.w(tag, runner + " failed sample #" + idx
                        + " uploadId=" + row.id
                        + " contentId=" + oneLine(row.contentId)
                        + " file=" + oneLine(row.filename)
                        + " bytes=" + row.totalBytes
                        + " sent=" + row.sentBytes
                        + " video=" + row.isVideo
                        + " locked=" + row.isLocked
                        + " attempts=" + (photo != null ? photo.attempts : -1)
                        + " lastError=" + oneLine(photo != null ? photo.lastError : null)
                        + " tusUrl=" + oneLine(row.tusUrl));
            }
        } catch (Exception e) {
            Log.w(tag, runner + " failed sample logging failed", e);
        }
    }

    @NonNull
    private static String oneLine(String value) {
        if (value == null || value.trim().isEmpty()) return "-";
        String compact = value.trim().replace('\n', ' ').replace('\r', ' ');
        return compact.length() > 160 ? compact.substring(0, 160) : compact;
    }
}
