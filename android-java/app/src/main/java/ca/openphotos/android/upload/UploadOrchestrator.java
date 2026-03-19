package ca.openphotos.android.upload;

import android.content.Context;
import android.net.Uri;
import android.util.Log;

import ca.openphotos.android.data.db.AppDatabase;
import ca.openphotos.android.data.db.entities.UploadEntity;
import ca.openphotos.android.prefs.SecurityPreferences;

import java.io.File;

/** Orchestrates preparing and enqueuing uploads (locked and unlocked). */
public final class UploadOrchestrator {
    private static final String MOTION_TAG = "OpenPhotosMotion";
    private final Context app;
    public UploadOrchestrator(Context app) { this.app = app.getApplicationContext(); }

    public void enqueueLocked(String contentId, Uri uri, boolean isVideo, long createdAt, String albumPathsJson, String mimeHint) throws Exception {
        SecurityPreferences sp = new SecurityPreferences(app);
        boolean includeLoc = sp.includeLocation();
        LockedUploadPreparer.LockedItems items = LockedUploadPreparer.prepare(app, uri, isVideo, createdAt, albumPathsJson, null, null, includeLoc, mimeHint);
        enqueuePrepared(contentId, isVideo, albumPathsJson, items);
    }

    public void enqueueLockedFile(String contentId, File sourceFile, boolean isVideo, long createdAt, String albumPathsJson, String mimeHint) throws Exception {
        SecurityPreferences sp = new SecurityPreferences(app);
        boolean includeLoc = sp.includeLocation();
        LockedUploadPreparer.LockedItems items =
                LockedUploadPreparer.prepareFromFile(app, sourceFile, isVideo, createdAt, albumPathsJson, includeLoc, mimeHint);
        enqueuePrepared(contentId, isVideo, albumPathsJson, items);
        Log.i(MOTION_TAG, "locked-paired-enqueue contentId=" + contentId
                + " source=" + sourceFile.getName()
                + " bytes=" + sourceFile.length()
                + " isVideo=" + isVideo);
    }

    private void enqueuePrepared(String contentId, boolean isVideo, String albumPathsJson, LockedUploadPreparer.LockedItems items) {
        AppDatabase db = AppDatabase.get(app);
        UploadEntity e1 = new UploadEntity();
        e1.itemId = java.util.UUID.randomUUID().toString();
        e1.contentId = contentId;
        e1.filename = items.orig.file.getName();
        e1.tempFilePath = items.orig.file.getAbsolutePath();
        e1.mimeType = "application/octet-stream";
        e1.isVideo = isVideo;
        e1.totalBytes = items.orig.file.length();
        e1.sentBytes = 0; e1.status = 0; e1.isLocked = true; e1.lockedKind = "orig";
        e1.assetIdB58 = items.orig.assetIdB58; e1.outerHeaderB64Url = items.orig.outerHeaderB64Url; e1.albumPathsJson = albumPathsJson;
        e1.lockedMetadataJson = withContentId(items.orig.tusMeta, contentId);
        db.uploadDao().upsert(e1);

        UploadEntity e2 = new UploadEntity();
        e2.itemId = java.util.UUID.randomUUID().toString();
        e2.contentId = contentId;
        e2.filename = items.thumb.file.getName();
        e2.tempFilePath = items.thumb.file.getAbsolutePath();
        e2.mimeType = "application/octet-stream";
        e2.isVideo = isVideo;
        e2.totalBytes = items.thumb.file.length();
        e2.sentBytes = 0; e2.status = 0; e2.isLocked = true; e2.lockedKind = "thumb";
        e2.assetIdB58 = items.thumb.assetIdB58; e2.outerHeaderB64Url = items.thumb.outerHeaderB64Url; e2.albumPathsJson = albumPathsJson;
        e2.lockedMetadataJson = withContentId(items.thumb.tusMeta, contentId);
        db.uploadDao().upsert(e2);
        // Schedule background upload
        UploadScheduler.scheduleOnce(app, true);
    }

    private static String withContentId(java.util.Map<String, String> src, String contentId) {
        try {
            org.json.JSONObject o = new org.json.JSONObject(src);
            o.put("content_id", contentId);
            return o.toString();
        } catch (Exception ignored) {
            return "{}";
        }
    }
}
