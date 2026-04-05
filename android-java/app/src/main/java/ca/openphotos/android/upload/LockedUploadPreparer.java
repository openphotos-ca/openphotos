package ca.openphotos.android.upload;

import android.content.Context;
import android.media.MediaMetadataRetriever;
import android.net.Uri;
import android.util.Log;

import ca.openphotos.android.core.AuthManager;
import ca.openphotos.android.e2ee.PAE3;
import ca.openphotos.android.media.Transforms;
import ca.openphotos.android.prefs.SecurityPreferences;
import ca.openphotos.android.ui.local.BackupIdUtil;
import ca.openphotos.android.util.Hashing;

import org.json.JSONObject;

import java.io.File;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Prepares locked uploads (orig + thumb) using PAE3 and builds TUS metadata maps.
 */
public final class LockedUploadPreparer {
    private static final String TAG = "OpenPhotosMotion";
    public static class LockedItems { public PreparedItem orig; public PreparedItem thumb; }
    public static class PreparedItem { public File file; public String kind; public Map<String,String> tusMeta; public String assetIdB58; public String outerHeaderB64Url; }

    private LockedUploadPreparer() {}

    public static LockedItems prepare(Context app, Uri uri, boolean isVideo, long createdAt, String albumPathsJson, String caption, String description, boolean includeLocation, String mimeHint) throws Exception {
        File input = copyToCache(app, uri);
        return prepareInternal(app, input, uri, isVideo, createdAt, albumPathsJson, includeLocation, mimeHint, true);
    }

    public static LockedItems prepareFromFile(Context app, File sourceFile, boolean isVideo, long createdAt, String albumPathsJson, boolean includeLocation, String mimeHint) throws Exception {
        return prepareInternal(app, sourceFile, null, isVideo, createdAt, albumPathsJson, includeLocation, mimeHint, false);
    }

    private static LockedItems prepareInternal(
            Context app,
            File input,
            Uri sourceUri,
            boolean isVideo,
            long createdAt,
            String albumPathsJson,
            boolean includeLocation,
            String mimeHint,
            boolean deleteInputOnExit
    ) throws Exception {
        AuthManager auth = AuthManager.get(app);
        byte[] umk = new byte[32]; new java.security.SecureRandom().nextBytes(umk); // caller should ensure UMK is present; placeholder
        String userId = auth.getUserId();
        if (userId == null || userId.isEmpty()) throw new IllegalStateException("Missing user id");

        // Build metadata for header + tus
        LockedMetadataBuilder.Result meta;
        if (sourceUri != null) {
            meta = LockedMetadataBuilder.build(app, sourceUri, isVideo, createdAt, mimeHint, includeLocation);
        } else {
            meta = LockedMetadataBuilder.buildForFile(app, input, isVideo, createdAt, mimeHint, includeLocation);
        }
        JSONObject header = meta.headerMeta;
        Map<String,String> tusLocked = jsonToStringMap(meta.tusMeta);
        if (albumPathsJson != null && !albumPathsJson.isEmpty()) tusLocked.put("albums", albumPathsJson);

        List<String> backupIdCandidates = BackupIdUtil.computeBackupIdCandidatesForFile(
                app,
                input,
                mimeHint != null ? mimeHint : "",
                input.getName(),
                isVideo,
                userId
        );
        if (!backupIdCandidates.isEmpty()) {
            tusLocked.put("backup_id", backupIdCandidates.get(0));
        }

        String assetIdB58 = Hashing.assetIdB58FromFile(input, userId);
        // Encrypt orig
        File outOrig = File.createTempFile("orig_", ".pae3", app.getCacheDir());
        PAE3.Info info = PAE3.encryptReturningInfo(umk, userId.getBytes("UTF-8"), input, outOrig, header.toString().getBytes(), 256 * 1024);

        PreparedItem piOrig = new PreparedItem();
        tusLocked.put("locked", "1"); tusLocked.put("crypto_version", "3"); tusLocked.put("kind", "orig"); tusLocked.put("asset_id_b58", info.assetIdB58);
        tusLocked.put("created_at", String.valueOf(createdAt));
        piOrig.file = outOrig; piOrig.kind = "orig"; piOrig.tusMeta = tusLocked; piOrig.assetIdB58 = info.assetIdB58; piOrig.outerHeaderB64Url = info.outerHeaderB64Url;

        // Generate thumbnail
        File thumbFile;
        if (isVideo) {
            MediaMetadataRetriever mmr = new MediaMetadataRetriever();
            if (sourceUri != null) {
                mmr.setDataSource(app, sourceUri);
            } else {
                mmr.setDataSource(input.getAbsolutePath());
            }
            android.graphics.Bitmap frame = mmr.getFrameAtTime(0);
            thumbFile = new File(app.getCacheDir(), "thumb.jpg");
            try (java.io.FileOutputStream fos = new java.io.FileOutputStream(thumbFile)) { frame.compress(android.graphics.Bitmap.CompressFormat.JPEG, 85, fos); }
            mmr.release();
        } else {
            if (sourceUri != null) {
                thumbFile = Transforms.heicToJpeg(app, sourceUri, 0.9f);
                if (thumbFile == null) thumbFile = copyToCache(app, sourceUri);
            } else {
                thumbFile = copyFileToCache(app, input);
            }
        }
        // Header for thumb indicates kind=thumb
        JSONObject headerT = new JSONObject(header.toString()); headerT.put("kind", "thumb");
        File outThumb = File.createTempFile("thumb_", ".pae3", app.getCacheDir());
        PAE3.Info infoT = PAE3.encryptReturningInfo(umk, userId.getBytes("UTF-8"), thumbFile, outThumb, headerT.toString().getBytes(), 256 * 1024);
        Map<String,String> tusT = new HashMap<>(tusLocked);
        tusT.put("kind", "thumb"); tusT.put("mime_hint", "image/jpeg"); tusT.put("size_kb", String.valueOf(Math.max(1, outThumb.length()/1024)));
        PreparedItem piThumb = new PreparedItem();
        piThumb.file = outThumb; piThumb.kind = "thumb"; piThumb.tusMeta = tusT; piThumb.assetIdB58 = infoT.assetIdB58; piThumb.outerHeaderB64Url = infoT.outerHeaderB64Url;

        LockedItems items = new LockedItems(); items.orig = piOrig; items.thumb = piThumb;
        // Cleanup temp inputs
        if (thumbFile != null && thumbFile.exists()) thumbFile.delete();
        if (deleteInputOnExit && input != null && input.exists()) input.delete();
        return items;
    }

    private static File copyToCache(Context app, Uri uri) throws Exception {
        File out = File.createTempFile("inp_", ".bin", app.getCacheDir());
        try (java.io.InputStream is = app.getContentResolver().openInputStream(uri); java.io.FileOutputStream fos = new java.io.FileOutputStream(out)) {
            byte[] buf = new byte[8192]; int r; while ((r = is.read(buf)) > 0) fos.write(buf, 0, r);
        }
        return out;
    }

    private static File copyFileToCache(Context app, File input) throws Exception {
        File out = File.createTempFile("inp_", ".bin", app.getCacheDir());
        try (java.io.FileInputStream fis = new java.io.FileInputStream(input);
             java.io.FileOutputStream fos = new java.io.FileOutputStream(out)) {
            byte[] buf = new byte[8192];
            int r;
            while ((r = fis.read(buf)) > 0) fos.write(buf, 0, r);
        }
        return out;
    }

    private static Map<String,String> jsonToStringMap(JSONObject obj) {
        Map<String,String> m = new HashMap<>();
        java.util.Iterator<String> it = obj.keys();
        while (it.hasNext()) { String k = it.next(); m.put(k, obj.optString(k, null)); }
        return m;
    }
}
