package ca.openphotos.android.media;

import android.content.ContentResolver;
import android.content.ContentValues;
import android.content.Context;
import android.net.Uri;
import android.os.Build;
import android.provider.MediaStore;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import ca.openphotos.android.core.AuthorizedHttpClient;
import ca.openphotos.android.core.AuthManager;
import ca.openphotos.android.e2ee.E2EEManager;
import ca.openphotos.android.e2ee.PAE3;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;

/**
 * MediaSaveHelper downloads images/videos (and Live photo parts) from the server, decrypts
 * PAE3 containers when required, and inserts the content into MediaStore so it appears in Photos.
 *
 * Design goals:
 * - Minimal allocations: stream to temp files, then copy into MediaStore OutputStream
 * - E2EE-aware: if server replies with application/octet-stream, treat as PAE3 and decrypt
 * - Live photos: save still image and motion video separately (Android v1 parity)
 */
public final class MediaSaveHelper {
    private MediaSaveHelper() {}

    public static void saveImage(@NonNull Context app, @NonNull String assetId, @Nullable String filename) throws Exception {
        Downloaded tmp = download(app, "/api/images/" + enc(assetId), filename != null ? filename : assetId);
        File plain = ensurePlain(app, tmp);
        String display = filename != null ? filename : (assetId + guessExtFromMime(tmp.contentType, true));
        insertImage(app, plain, display);
        cleanup(tmp, plain);
    }

    public static void saveVideo(@NonNull Context app, @NonNull String assetId, @Nullable String filename) throws Exception {
        Downloaded tmp = download(app, "/api/images/" + enc(assetId), (filename != null ? filename : assetId) + ".mov");
        File plain = ensurePlain(app, tmp);
        String display = filename != null ? filename : (assetId + ".mov");
        insertVideo(app, plain, display);
        cleanup(tmp, plain);
    }

    /**
     * Save Live photo components as separate image + video files. This keeps the implementation
     * simple for v1 (Android does not have a paired Live-Photo concept in MediaStore).
     */
    public static void saveLive(@NonNull Context app, @NonNull String assetId, @Nullable String filename) throws Exception {
        // 1) Still image via /api/images
        saveImage(app, assetId, filename != null ? filename + ".heic" : null);
        // 2) Motion via /api/live (or /api/live-locked for locked containers)
        String livePath = "/api/live/" + enc(assetId);
        // If UMK present, prefer locked motion route (server may respond PAE3)
        if (new ca.openphotos.android.e2ee.E2EEManager(app).getUmk() != null) {
            livePath = "/api/live-locked/" + enc(assetId);
        }
        Downloaded tmp = download(app, livePath, (filename != null ? filename : assetId) + ".mov");
        File plain = ensurePlain(app, tmp);
        insertVideo(app, plain, (filename != null ? filename : assetId) + ".mov");
        cleanup(tmp, plain);
    }

    // --- Internals ---
    private static final class Downloaded { File file; String contentType; }

    private static String enc(String s) {
        try { return java.net.URLEncoder.encode(s, java.nio.charset.StandardCharsets.UTF_8.name()); } catch (Exception e) { return s; }
    }

    private static Downloaded download(Context app, String path, String name) throws Exception {
        okhttp3.OkHttpClient client = AuthorizedHttpClient.get(app).raw();
        String url = AuthManager.get(app).getServerUrl() + path;
        okhttp3.Request req = new okhttp3.Request.Builder().url(url).get().build();
        try (okhttp3.Response r = client.newCall(req).execute()) {
            if (!r.isSuccessful() || r.body() == null) throw new java.io.IOException("HTTP " + r.code());
            Downloaded d = new Downloaded();
            d.contentType = r.header("Content-Type", "");
            File tmp = File.createTempFile("dl_", "_" + sanitize(name), app.getCacheDir());
            try (InputStream is = r.body().byteStream(); FileOutputStream fos = new FileOutputStream(tmp)) {
                byte[] buf = new byte[8192]; int n; while ((n = is.read(buf)) > 0) fos.write(buf, 0, n);
            }
            d.file = tmp; return d;
        }
    }

    private static File ensurePlain(Context app, Downloaded d) throws Exception {
        // If bytes are PAE3, decrypt using UMK; otherwise return the downloaded file
        if ("application/octet-stream".equalsIgnoreCase(d.contentType)) {
            E2EEManager e2 = new E2EEManager(app);
            byte[] umk = e2.getUmk();
            String uid = AuthManager.get(app).getUserId();
            if (umk == null || uid == null || uid.isEmpty()) throw new IllegalStateException("UMK required to decrypt");
            File dec = File.createTempFile("dec_", ".bin", app.getCacheDir());
            PAE3.decryptToFile(umk, uid.getBytes(), d.file, dec);
            return dec;
        }
        return d.file;
    }

    private static void insertImage(Context app, File src, String displayName) throws Exception {
        ContentResolver cr = app.getContentResolver();
        ContentValues cv = new ContentValues();
        cv.put(MediaStore.MediaColumns.DISPLAY_NAME, displayName);
        cv.put(MediaStore.MediaColumns.MIME_TYPE, mimeFromName(displayName, true));
        cv.put(MediaStore.MediaColumns.RELATIVE_PATH, "Pictures/OpenPhotos");
        Uri uri = cr.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, cv);
        if (uri == null) throw new IllegalStateException("insert image failed");
        try (OutputStream os = cr.openOutputStream(uri)) { java.nio.file.Files.copy(src.toPath(), os); }
    }

    private static void insertVideo(Context app, File src, String displayName) throws Exception {
        ContentResolver cr = app.getContentResolver();
        ContentValues cv = new ContentValues();
        cv.put(MediaStore.MediaColumns.DISPLAY_NAME, displayName);
        cv.put(MediaStore.MediaColumns.MIME_TYPE, "video/mp4");
        cv.put(MediaStore.MediaColumns.RELATIVE_PATH, "Movies/OpenPhotos");
        Uri uri = cr.insert(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, cv);
        if (uri == null) throw new IllegalStateException("insert video failed");
        try (OutputStream os = cr.openOutputStream(uri)) { java.nio.file.Files.copy(src.toPath(), os); }
    }

    private static void cleanup(Downloaded tmp, File plain) {
        try { if (tmp != null && tmp.file != null) tmp.file.delete(); } catch (Exception ignored) {}
        try { if (plain != null && plain.exists()) plain.delete(); } catch (Exception ignored) {}
    }

    private static String sanitize(String s) { return s.replaceAll("[^A-Za-z0-9._-]", "_"); }

    private static String guessExtFromMime(String ct, boolean image) {
        if (ct == null) return image ? ".jpg" : ".mp4";
        String l = ct.toLowerCase();
        if (image) {
            if (l.contains("heic")) return ".heic";
            if (l.contains("png")) return ".png";
            return ".jpg";
        } else {
            if (l.contains("mp4") || l.contains("mp2t") || l.contains("mov")) return ".mp4";
            return ".mp4";
        }
    }
    private static String mimeFromName(String name, boolean image) {
        if (image) {
            String n = name.toLowerCase();
            if (n.endsWith(".heic") || n.endsWith(".heif")) return "image/heic";
            if (n.endsWith(".png")) return "image/png";
            return "image/jpeg";
        }
        return "video/mp4";
    }
}
