package ca.openphotos.android.upload;

import android.content.Context;
import android.net.ConnectivityManager;
import android.net.NetworkCapabilities;
import android.util.Log;

import ca.openphotos.android.core.AuthManager;
import ca.openphotos.android.data.db.AppDatabase;
import ca.openphotos.android.data.db.dao.PhotoDao;
import ca.openphotos.android.data.db.dao.UploadDao;
import ca.openphotos.android.data.db.entities.PhotoEntity;
import ca.openphotos.android.data.db.entities.UploadEntity;
import ca.openphotos.android.server.ServerPhotosService;
import ca.openphotos.android.util.Hashing;

import java.io.File;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.HashMap;
import java.util.Map;

import io.tus.java.client.TusClient;
import io.tus.java.client.TusExecutor;
import io.tus.java.client.TusUpload;
import io.tus.java.client.TusUploader;

/**
 * Foreground TUS uploader using tus-java-client.
 * - 9 MiB chunks
 * - Resume support via stored upload URL
 * - Metadata mirrors iOS for unlocked uploads
 */
public class TusUploadManager {
    private static final String TAG = "TusUpload";
    private static final int DEFAULT_CHUNK_SIZE = 9 * 1024 * 1024;
    private static final int MIN_CHUNK_SIZE = 256 * 1024;
    private static final int CONNECT_TIMEOUT_MS = 30_000;
    private static final int READ_TIMEOUT_MS = 120_000;
    private static final int SLOW_CHUNK_WARN_MS = 45_000;

    private final Context app;
    private final TusClient client;
    private final AuthManager auth;
    private final UploadDao uploadDao;
    private final PhotoDao photoDao;
    private final int chunkSizeBytes;

    public TusUploadManager(Context app) {
        this(app, DEFAULT_CHUNK_SIZE);
    }

    public TusUploadManager(Context app, int chunkSizeBytes) {
        this.app = app.getApplicationContext();
        this.auth = AuthManager.get(this.app);
        this.client = new TusClient() {
            @Override
            public void prepareConnection(HttpURLConnection connection) {
                super.prepareConnection(connection);
                connection.setReadTimeout(READ_TIMEOUT_MS);
            }
        };
        this.client.setConnectTimeout(CONNECT_TIMEOUT_MS);
        this.client.setUploadCreationURL(getFilesUrl());
        this.uploadDao = AppDatabase.get(this.app).uploadDao();
        this.photoDao = AppDatabase.get(this.app).photoDao();
        this.chunkSizeBytes = Math.max(MIN_CHUNK_SIZE, chunkSizeBytes);
    }

    private URL getFilesUrl() {
        try { return new URL(auth.getServerUrl() + "/files"); } catch (Exception e) { throw new RuntimeException(e); }
    }

    /** Upload a single file (unlocked) with TUS metadata, foreground. */
    public void uploadUnlocked(File file, PhotoEntity photo, String albumPathsJson) throws Exception {
        uploadUnlockedInternal(file, photo, albumPathsJson, null, true, true);
    }

    /** Queue-path unlocked upload: no extra upload rows and no direct synced-state mutation. */
    public void uploadUnlockedQueued(File file, PhotoEntity photo, String albumPathsJson, long queueUploadRowId) throws Exception {
        uploadUnlockedInternal(file, photo, albumPathsJson, queueUploadRowId, false, false);
    }

    private void uploadUnlockedInternal(
            File file,
            PhotoEntity photo,
            String albumPathsJson,
            Long queueUploadRowId,
            boolean createForegroundRow,
            boolean markPhotoSyncedOnSuccess
    ) throws Exception {
        String contentId = (photo != null && photo.contentId != null && !photo.contentId.isEmpty())
                ? photo.contentId
                : Hashing.contentIdFromFile(file);
        String userId = auth.getUserId();
        String assetId = (userId != null) ? Hashing.assetIdB58FromFile(file, userId) : null;
        if (assetId != null && !assetId.isEmpty()) {
            try {
                boolean exists = new ServerPhotosService(app).isAssetFullyBackedUp(assetId);
                if (exists) {
                    if (markPhotoSyncedOnSuccess) {
                        long now = System.currentTimeMillis() / 1000L;
                        photoDao.markSynced(contentId, now);
                    }
                    Log.i(TAG, "[TUS] preflight skip existing asset_id=" + assetId + " file=" + file.getName());
                    return;
                }
            } catch (Exception e) {
                Log.w(TAG, "[TUS] preflight exists failed; continue upload: " + e.getMessage());
            }
        }

        Map<String, String> meta = new HashMap<>();
        // Filename and mime_type are important for the server to derive extension and process thumbnails.
        meta.put("filename", file.getName());
        String mime = (photo.mediaType == 1 ? "video" : "image");
        meta.put("mime_type", mimeForName(file.getName(), mime));
        meta.put("content_id", contentId);
        meta.put("media_type", mime); // image|video (semantic type)
        meta.put("created_at", String.valueOf(photo.creationTs));
        if (assetId != null) meta.put("asset_id", assetId);
        if (albumPathsJson != null && !albumPathsJson.isEmpty()) meta.put("albums", albumPathsJson);
        meta.put("source", "android");

        TusUpload upload = new TusUpload(file);
        upload.setMetadata(meta);

        final long uploadId;
        final String uploadName;
        final String uploadMime;
        if (createForegroundRow) {
            // Persist upload entry for resume in direct/foreground path.
            UploadEntity ue = new UploadEntity();
            ue.itemId = java.util.UUID.randomUUID().toString();
            ue.contentId = contentId;
            ue.filename = file.getName();
            ue.tempFilePath = file.getAbsolutePath();
            ue.mimeType = photo.mediaType == 1 ? "video/*" : "image/*";
            ue.isVideo = (photo.mediaType == 1);
            ue.totalBytes = file.length();
            ue.status = 1; // uploading (foreground)
            uploadId = uploadDao.upsert(ue);
            uploadName = ue.filename;
            uploadMime = ue.mimeType;
        } else {
            uploadId = queueUploadRowId != null ? queueUploadRowId : -1L;
            uploadName = file.getName();
            uploadMime = mimeForName(file.getName(), (photo.mediaType == 1 ? "video" : "image"));
        }
        Log.i(TAG, String.format("[TUS] BEGIN unlocked uploadId=%d file=%s size=%d connectTimeoutMs=%d readTimeoutMs=%d",
                uploadId, uploadName, file.length(), CONNECT_TIMEOUT_MS, READ_TIMEOUT_MS)
                + " chunkBytes=" + chunkSizeBytes);

        new TusExecutor() {
            @Override
            protected void makeAttempt() {
                try {
                    // Authorization header
                    java.util.HashMap<String,String> headers = new java.util.HashMap<>();
                    if (auth.getToken() != null && !auth.getToken().isEmpty()) headers.put("Authorization", "Bearer " + auth.getToken());
                    client.setHeaders(headers);

                    TusUploader uploader = client.resumeOrCreateUpload(upload);
                    uploader.setChunkSize(chunkSizeBytes);

                    // Save URL for resume
                    java.net.URL uploadUrl = uploader.getUploadURL();
                    if (uploadUrl != null && uploadId > 0) uploadDao.setTusUrl(uploadId, uploadUrl.toString());

                    Log.i(TAG, String.format("[TUS] CREATE filename=%s size=%d type=%s", uploadName, file.length(), uploadMime));
                    long bytesUploaded = 0;
                    long size = upload.getSize();
                    int idx = 0;
                    int slowChunkWarnHits = 0;
                    do {
                        idx++;
                        long beforeOffset = uploader.getOffset();
                        long startedAt = System.currentTimeMillis();
                        Log.i(TAG, String.format("[TUS] PATCH begin chunk=%d offset=%d total=%d", idx, beforeOffset, size));
                        int sent = uploader.uploadChunk();
                        long elapsedMs = System.currentTimeMillis() - startedAt;
                        bytesUploaded += sent;
                        Log.i(TAG, String.format("[TUS] PATCH end chunk=%d wrote=%d offset=%d total=%d dtMs=%d",
                                idx, sent, bytesUploaded, size, elapsedMs));
                        if (elapsedMs >= SLOW_CHUNK_WARN_MS) {
                            slowChunkWarnHits++;
                            Log.w(TAG, String.format("[TUS] PATCH slow chunk=%d dtMs=%d offset=%d total=%d",
                                    idx, elapsedMs, bytesUploaded, size));
                        }
                    } while (bytesUploaded < size);
                    uploader.finish();
                    Log.i(TAG, String.format("[TUS] COMPLETE size=%d", size)
                            + " chunkBytes=" + chunkSizeBytes
                            + " slowChunkWarnHits=" + slowChunkWarnHits);

                    if (markPhotoSyncedOnSuccess) {
                        photoDao.markSynced(contentId, System.currentTimeMillis() / 1000L);
                    }
                    if (createForegroundRow && uploadId > 0) {
                        uploadDao.updateStatus(uploadId, 2, size);
                    }
                } catch (Exception ex) {
                    String summary = UploadFailurePolicy.summarize(ex);
                    boolean retryable = UploadFailurePolicy.isRetryable(ex);
                    Log.e(TAG, "[TUS] unlocked attempt failed"
                            + " file=" + uploadName
                            + " uploadId=" + uploadId
                            + " contentId=" + contentId
                            + " assetId=" + (assetId != null ? assetId : "-")
                            + " retryable=" + retryable
                            + " reason=" + summary
                            + " network=" + networkSummary(), ex);
                    throw new RuntimeException(ex);
                }
            }
        }.makeAttempts();
    }

    /** Infer a specific MIME type based on filename when possible, fallback to semantic type. */
    private String mimeForName(String name, String fallbackSemantic) {
        String lower = name != null ? name.toLowerCase() : "";
        if (lower.endsWith(".jpg") || lower.endsWith(".jpeg")) return "image/jpeg";
        if (lower.endsWith(".png")) return "image/png";
        if (lower.endsWith(".heic") || lower.endsWith(".heif")) return "image/heic";
        if (lower.endsWith(".dng")) return "image/dng";
        if (lower.endsWith(".mp4")) return "video/mp4";
        if (lower.endsWith(".mov") || lower.endsWith(".qt")) return "video/quicktime";
        return fallbackSemantic.equals("video") ? "video/*" : "image/*";
    }

    /** Upload a locked PAE3 file with locked metadata (orig or thumb). */
    public void uploadLocked(File pae3File, String filename, Map<String,String> lockedMeta, long uploadRowId) throws Exception {
        uploadLockedInternal(pae3File, filename, lockedMeta, uploadRowId, true);
    }

    /** Queue-path locked upload: no queue-row status mutation in this layer. */
    public void uploadLockedQueued(File pae3File, String filename, Map<String,String> lockedMeta, long uploadRowId) throws Exception {
        uploadLockedInternal(pae3File, filename, lockedMeta, uploadRowId, false);
    }

    private void uploadLockedInternal(
            File pae3File,
            String filename,
            Map<String,String> lockedMeta,
            long uploadRowId,
            boolean updateQueueStatusOnSuccess
    ) throws Exception {
        String assetId = lockedMeta != null ? lockedMeta.get("asset_id_b58") : null;
        if (assetId != null && !assetId.isEmpty()) {
            try {
                boolean exists = new ServerPhotosService(app).isAssetFullyBackedUp(assetId);
                if (exists) {
                    if (updateQueueStatusOnSuccess) {
                        uploadDao.updateStatus(uploadRowId, 2, pae3File.length());
                    }
                    Log.i(TAG, "[TUS] preflight skip existing locked asset_id=" + assetId + " file=" + filename);
                    return;
                }
            } catch (Exception e) {
                Log.w(TAG, "[TUS] locked preflight exists failed; continue upload: " + e.getMessage());
            }
        }
        TusUpload upload = new TusUpload(pae3File);
        Map<String,String> meta = new HashMap<>(lockedMeta);
        meta.put("source", "android");
        upload.setMetadata(meta);
        Log.i(TAG, String.format("[TUS] BEGIN locked uploadRowId=%d file=%s size=%d connectTimeoutMs=%d readTimeoutMs=%d",
                uploadRowId, filename, pae3File.length(), CONNECT_TIMEOUT_MS, READ_TIMEOUT_MS)
                + " chunkBytes=" + chunkSizeBytes);
        new TusExecutor() {
            @Override
            protected void makeAttempt() {
                try {
                    java.util.HashMap<String,String> headers = new java.util.HashMap<>();
                    if (auth.getToken() != null && !auth.getToken().isEmpty()) headers.put("Authorization", "Bearer " + auth.getToken());
                    client.setHeaders(headers);
                    TusUploader uploader = client.resumeOrCreateUpload(upload);
                    uploader.setChunkSize(chunkSizeBytes);
                    java.net.URL uploadUrl = uploader.getUploadURL();
                    if (uploadUrl != null && uploadRowId > 0) uploadDao.setTusUrl(uploadRowId, uploadUrl.toString());
                    long size = upload.getSize();
                    long uploaded = 0;
                    int idx = 0;
                    int slowChunkWarnHits = 0;
                    do {
                        idx++;
                        long beforeOffset = uploader.getOffset();
                        long startedAt = System.currentTimeMillis();
                        Log.i(TAG, String.format("[TUS] PATCH begin chunk=%d offset=%d total=%d", idx, beforeOffset, size));
                        int sent = uploader.uploadChunk();
                        long elapsedMs = System.currentTimeMillis() - startedAt;
                        uploaded += sent;
                        Log.i(TAG, String.format("[TUS] PATCH end chunk=%d wrote=%d offset=%d total=%d dtMs=%d",
                                idx, sent, uploaded, size, elapsedMs));
                        if (elapsedMs >= SLOW_CHUNK_WARN_MS) {
                            slowChunkWarnHits++;
                            Log.w(TAG, String.format("[TUS] PATCH slow chunk=%d dtMs=%d offset=%d total=%d",
                                    idx, elapsedMs, uploaded, size));
                        }
                    }
                    while (uploaded < size);
                    uploader.finish();
                    Log.i(TAG, String.format("[TUS] COMPLETE size=%d", size)
                            + " chunkBytes=" + chunkSizeBytes
                            + " slowChunkWarnHits=" + slowChunkWarnHits);
                    if (updateQueueStatusOnSuccess && uploadRowId > 0) {
                        uploadDao.updateStatus(uploadRowId, 2, size);
                    }
                } catch (Exception ex) {
                    String summary = UploadFailurePolicy.summarize(ex);
                    boolean retryable = UploadFailurePolicy.isRetryable(ex);
                    Log.e(TAG, "[TUS] locked attempt failed"
                            + " file=" + filename
                            + " uploadRowId=" + uploadRowId
                            + " assetId=" + (assetId != null ? assetId : "-")
                            + " retryable=" + retryable
                            + " reason=" + summary
                            + " network=" + networkSummary(), ex);
                    throw new RuntimeException(ex);
                }
            }
        }.makeAttempts();
    }

    private String networkSummary() {
        try {
            ConnectivityManager cm = (ConnectivityManager) app.getSystemService(Context.CONNECTIVITY_SERVICE);
            if (cm == null) return "none";
            NetworkCapabilities nc = cm.getNetworkCapabilities(cm.getActiveNetwork());
            if (nc == null) return "disconnected";
            boolean wifi = nc.hasTransport(NetworkCapabilities.TRANSPORT_WIFI);
            boolean cell = nc.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR);
            boolean eth = nc.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET);
            boolean validated = nc.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED);
            boolean metered = !nc.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED);
            return "wifi=" + wifi + ",cell=" + cell + ",eth=" + eth + ",validated=" + validated + ",metered=" + metered;
        } catch (Exception e) {
            return "error:" + e.getClass().getSimpleName();
        }
    }
}
