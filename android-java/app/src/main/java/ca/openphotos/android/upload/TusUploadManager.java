package ca.openphotos.android.upload;

import android.content.Context;
import android.net.ConnectivityManager;
import android.net.NetworkCapabilities;
import android.util.Log;

import androidx.annotation.Nullable;

import ca.openphotos.android.core.AuthManager;
import ca.openphotos.android.data.db.AppDatabase;
import ca.openphotos.android.data.db.dao.PhotoDao;
import ca.openphotos.android.data.db.dao.UploadDao;
import ca.openphotos.android.data.db.entities.PhotoEntity;
import ca.openphotos.android.data.db.entities.UploadEntity;
import ca.openphotos.android.server.ServerPhotosService;
import ca.openphotos.android.util.Hashing;
import ca.openphotos.android.util.Logx;

import java.io.File;
import java.io.IOException;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;

import io.tus.java.client.TusClient;
import io.tus.java.client.TusUpload;
import io.tus.java.client.TusUploader;

/**
 * Android TUS uploader with Cloudflare-safe request sizing and persisted upload URLs.
 */
public class TusUploadManager {
    private static final String TAG = "TusUpload";
    private static final String SHARED_TAG = "OpenPhotos";
    private static final int DEFAULT_CHUNK_SIZE = 1 * TusAdaptiveChunkController.MIB;
    private static final int CONNECT_TIMEOUT_MS = 30_000;
    private static final int READ_TIMEOUT_MS = 120_000;
    private static final int SLOW_CHUNK_WARN_MS = 45_000;
    private static final long RECOVERY_WINDOW_MS = 210_000L;
    private static final long RECOVERY_POLL_MS = 1_500L;

    private final Context app;
    private final TusClient client;
    private final AuthManager auth;
    private final UploadDao uploadDao;
    private final PhotoDao photoDao;
    private final int requestedInitialChunkBytes;

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
        this.requestedInitialChunkBytes = Math.max(TusAdaptiveChunkController.MIN_CHUNK_BYTES, chunkSizeBytes);
    }

    private URL getFilesUrl() {
        try {
            return new URL(auth.getServerUrl() + "/files");
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }

    /** Upload a single file (unlocked) with TUS metadata, foreground. */
    public void uploadUnlocked(File file, PhotoEntity photo, String albumPathsJson) throws Exception {
        uploadUnlockedInternal(file, photo, albumPathsJson, null, null, null, true, true);
    }

    /** Upload a single file (unlocked) while preserving the original display name and mime type. */
    public void uploadUnlocked(
            File file,
            PhotoEntity photo,
            String albumPathsJson,
            @Nullable String originalFilename,
            @Nullable String originalMimeType
    ) throws Exception {
        uploadUnlockedInternal(file, photo, albumPathsJson, null, originalFilename, originalMimeType, true, true);
    }

    /** Queue-path unlocked upload: no extra upload rows and no direct synced-state mutation. */
    public void uploadUnlockedQueued(File file, PhotoEntity photo, String albumPathsJson, UploadEntity queueRow) throws Exception {
        uploadUnlockedInternal(file, photo, albumPathsJson, queueRow, null, null, false, false);
    }

    private void uploadUnlockedInternal(
            File file,
            PhotoEntity photo,
            String albumPathsJson,
            @Nullable UploadEntity queueRow,
            @Nullable String originalFilename,
            @Nullable String originalMimeType,
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
                    String existingName = chooseUploadFilename(queueRow, originalFilename, originalMimeType, file, photo);
                    logTusInfo("preflight skip existing asset_id=" + assetId + " file=" + existingName);
                    return;
                }
            } catch (Exception e) {
                String existingName = chooseUploadFilename(queueRow, originalFilename, originalMimeType, file, photo);
                logTusWarn("preflight exists failed file=" + existingName + " reason=" + UploadFailurePolicy.summarize(e));
            }
        }

        String uploadFilename = chooseUploadFilename(queueRow, originalFilename, originalMimeType, file, photo);
        String mime = (photo.mediaType == 1 ? "video" : "image");
        String uploadMime = chooseUploadMime(queueRow, originalMimeType, uploadFilename, mime);

        Map<String, String> meta = new HashMap<>();
        meta.put("filename", uploadFilename);
        meta.put("mime_type", uploadMime);
        meta.put("content_id", contentId);
        meta.put("media_type", mime);
        meta.put("created_at", String.valueOf(photo.creationTs));
        if (assetId != null) meta.put("asset_id", assetId);
        if (albumPathsJson != null && !albumPathsJson.isEmpty()) meta.put("albums", albumPathsJson);
        meta.put("source", "android");

        TusUpload upload = new TusUpload(file);
        upload.setMetadata(meta);

        UploadEntity uploadRow;
        if (createForegroundRow) {
            UploadEntity ue = new UploadEntity();
            ue.itemId = java.util.UUID.randomUUID().toString();
            ue.contentId = contentId;
            ue.filename = uploadFilename;
            ue.tempFilePath = file.getAbsolutePath();
            ue.mimeType = uploadMime;
            ue.isVideo = (photo.mediaType == 1);
            ue.totalBytes = file.length();
            ue.sentBytes = 0;
            ue.tusUrl = null;
            ue.status = 1;
            ue.id = uploadDao.upsert(ue);
            uploadRow = ue;
        } else {
            if (queueRow == null) {
                throw new IllegalArgumentException("queueRow required for queued upload");
            }
            uploadRow = queueRow;
        }

        try {
            performUpload(upload, uploadRow, uploadFilename, assetId, createForegroundRow, size -> {
                if (markPhotoSyncedOnSuccess) {
                    photoDao.markSynced(contentId, System.currentTimeMillis() / 1000L);
                }
            });
        } catch (Exception ex) {
            if (createForegroundRow && uploadRow.id > 0) {
                uploadDao.updateStatusOnly(uploadRow.id, 3);
            }
            throw ex;
        }
    }

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

    private String chooseUploadFilename(
            @Nullable UploadEntity queueRow,
            @Nullable String originalFilename,
            @Nullable String originalMimeType,
            File file,
            PhotoEntity photo
    ) {
        String semantic = (photo.mediaType == 1) ? "video" : "image";
        String candidate = firstNonBlank(
                queueRow != null ? queueRow.filename : null,
                originalFilename,
                file.getName()
        );
        String mime = chooseUploadMime(queueRow, originalMimeType, candidate, semantic);
        return ensureFilenameExtension(candidate, mime, semantic);
    }

    private String chooseUploadMime(
            @Nullable UploadEntity queueRow,
            @Nullable String originalMimeType,
            String filename,
            String fallbackSemantic
    ) {
        String explicit = firstNonBlank(
                originalMimeType,
                queueRow != null ? queueRow.mimeType : null
        );
        if (explicit != null && !explicit.contains("*")) return explicit;
        return mimeForName(filename, fallbackSemantic);
    }

    @Nullable
    private String firstNonBlank(@Nullable String... values) {
        if (values == null) return null;
        for (String value : values) {
            if (value == null) continue;
            String trimmed = value.trim();
            if (!trimmed.isEmpty()) return trimmed;
        }
        return null;
    }

    private String ensureFilenameExtension(String filename, String mimeType, String fallbackSemantic) {
        String trimmed = filename == null ? "" : filename.trim();
        if (trimmed.isEmpty()) {
            trimmed = fallbackSemantic.equals("video") ? "upload.mov" : "upload.jpg";
        }
        int slash = Math.max(trimmed.lastIndexOf('/'), trimmed.lastIndexOf(File.separatorChar));
        if (slash >= 0 && slash < trimmed.length() - 1) {
            trimmed = trimmed.substring(slash + 1);
        }
        if (trimmed.contains(".")) {
            return trimmed;
        }
        String ext = extensionForMime(mimeType, fallbackSemantic);
        return ext == null ? trimmed : (trimmed + "." + ext);
    }

    @Nullable
    private String extensionForMime(@Nullable String mimeType, String fallbackSemantic) {
        String lower = mimeType == null ? "" : mimeType.toLowerCase(Locale.US);
        if (lower.contains("jpeg") || lower.contains("jpg")) return "jpg";
        if (lower.contains("png")) return "png";
        if (lower.contains("heic") || lower.contains("heif")) return "heic";
        if (lower.contains("dng")) return "dng";
        if (lower.contains("avif")) return "avif";
        if (lower.contains("mp4")) return "mp4";
        if (lower.contains("quicktime") || lower.contains("mov")) return "mov";
        return fallbackSemantic.equals("video") ? "mov" : "jpg";
    }

    /** Upload a locked PAE3 file with locked metadata (orig or thumb). */
    public void uploadLocked(File pae3File, String filename, Map<String, String> lockedMeta, long uploadRowId) throws Exception {
        UploadEntity row = new UploadEntity();
        row.id = uploadRowId;
        row.filename = filename;
        row.tempFilePath = pae3File.getAbsolutePath();
        row.totalBytes = pae3File.length();
        row.sentBytes = 0;
        row.status = 1;
        uploadLockedInternal(pae3File, filename, lockedMeta, row, true);
    }

    /** Queue-path locked upload: no queue-row status mutation in this layer. */
    public void uploadLockedQueued(File pae3File, String filename, Map<String, String> lockedMeta, UploadEntity uploadRow) throws Exception {
        uploadLockedInternal(pae3File, filename, lockedMeta, uploadRow, false);
    }

    private void uploadLockedInternal(
            File pae3File,
            String filename,
            Map<String, String> lockedMeta,
            UploadEntity uploadRow,
            boolean updateQueueStatusOnSuccess
    ) throws Exception {
        String assetId = lockedMeta != null ? lockedMeta.get("asset_id_b58") : null;
        if (assetId != null && !assetId.isEmpty()) {
            try {
                boolean exists = new ServerPhotosService(app).isAssetFullyBackedUp(assetId);
                if (exists) {
                    if (updateQueueStatusOnSuccess) {
                        uploadDao.markCompleted(uploadRow.id, pae3File.length());
                    }
                    logTusInfo("preflight skip existing locked asset_id=" + assetId + " file=" + filename);
                    return;
                }
            } catch (Exception e) {
                logTusWarn("locked preflight exists failed file=" + filename + " reason=" + UploadFailurePolicy.summarize(e));
            }
        }

        TusUpload upload = new TusUpload(pae3File);
        Map<String, String> meta = new HashMap<>(lockedMeta);
        meta.put("source", "android");
        upload.setMetadata(meta);

        try {
            performUpload(upload, uploadRow, filename, assetId, updateQueueStatusOnSuccess, size -> { });
        } catch (Exception ex) {
            if (updateQueueStatusOnSuccess && uploadRow.id > 0) {
                uploadDao.updateStatusOnly(uploadRow.id, 3);
            }
            throw ex;
        }
    }

    private void performUpload(
            TusUpload upload,
            UploadEntity uploadRow,
            String uploadName,
            @Nullable String assetId,
            boolean markRowCompletedOnSuccess,
            CompletionHook onComplete
    ) throws Exception {
        long size = upload.getSize();
        TusAdaptiveChunkController chunkController =
                TusAdaptiveChunkController.forUpload(size, requestedInitialChunkBytes);
        UploadSessionStats stats = new UploadSessionStats();
        URL uploadUrl = parseStoredUploadUrl(uploadRow.tusUrl);
        TusUploader uploader = null;
        boolean completedWithoutUploader = false;

        logTusInfo("tus-start file=" + uploadName
                + " uploadId=" + uploadRow.id
                + " size=" + size
                + " connectTimeoutMs=" + CONNECT_TIMEOUT_MS
                + " readTimeoutMs=" + READ_TIMEOUT_MS
                + " initialChunkBytes=" + chunkController.currentChunkBytes()
                + " maxChunkBytes=" + chunkController.maxChunkBytes()
                + " sentBytes=" + uploadRow.sentBytes
                + " hasTusUrl=" + (uploadUrl != null)
                + " network=" + networkSummary());

        while (true) {
            if (uploader == null && !completedWithoutUploader) {
                if (uploadUrl != null) {
                    HeadProbeResult probe = probeRemoteOffset(uploadUrl);
                    if (probe.status == HeadProbeStatus.NOT_FOUND) {
                        if (isUploadAlreadyFinalized(assetId)) {
                            completedWithoutUploader = true;
                            break;
                        }
                        clearResumeState(uploadRow);
                        uploadUrl = null;
                    } else if (probe.status == HeadProbeStatus.OK) {
                        refreshClientHeaders();
                        uploader = client.beginOrResumeUploadFromURL(upload, uploadUrl);
                        persistResumeState(uploadRow, uploadUrl, probe.offset);
                        logTusInfo("tus-resume file=" + uploadName
                                + " uploadId=" + uploadRow.id
                                + " offset=" + probe.offset
                                + " total=" + size);
                    } else {
                        throw probe.error;
                    }
                }
                if (uploader == null && !completedWithoutUploader) {
                    refreshClientHeaders();
                    uploader = client.createUpload(upload);
                    uploadUrl = uploader.getUploadURL();
                    persistResumeState(uploadRow, uploadUrl, 0L);
                    logTusInfo("tus-create file=" + uploadName
                            + " uploadId=" + uploadRow.id
                            + " url=" + oneLine(uploadUrl != null ? uploadUrl.toString() : null)
                            + " total=" + size);
                }
            }

            if (completedWithoutUploader) {
                break;
            }

            if (uploader.getOffset() >= size) {
                break;
            }

            int chunkBytes = chunkController.currentChunkBytes();
            configureUploader(uploader, chunkBytes);
            long beforeOffset = uploader.getOffset();
            stats.patchRequests++;
            long startedAt = System.currentTimeMillis();
            logTusInfo("tus-patch-begin file=" + uploadName
                    + " uploadId=" + uploadRow.id
                    + " chunk=" + stats.patchRequests
                    + " offset=" + beforeOffset
                    + " total=" + size
                    + " chunkBytes=" + chunkBytes);
            try {
                int sent = uploader.uploadChunk();
                long elapsedMs = System.currentTimeMillis() - startedAt;
                if (sent == -1) {
                    break;
                }
                long afterOffset = uploader.getOffset();
                persistResumeState(uploadRow, uploadUrl, afterOffset);
                logTusInfo("tus-patch-end file=" + uploadName
                        + " uploadId=" + uploadRow.id
                        + " chunk=" + stats.patchRequests
                        + " wrote=" + sent
                        + " offset=" + afterOffset
                        + " total=" + size
                        + " dtMs=" + elapsedMs);
                if (elapsedMs >= SLOW_CHUNK_WARN_MS) {
                    stats.slowChunkWarnHits++;
                    logTusWarn("tus-patch-slow file=" + uploadName
                            + " uploadId=" + uploadRow.id
                            + " chunk=" + stats.patchRequests
                            + " dtMs=" + elapsedMs
                            + " offset=" + afterOffset
                            + " total=" + size);
                }
                int adjustedChunk = chunkController.recordSuccess();
                if (adjustedChunk > chunkBytes) {
                    logTusInfo("stable tunnel file=" + uploadName
                            + " uploadId=" + uploadRow.id
                            + " increasing_chunk_size=" + adjustedChunk);
                }
            } catch (Exception ex) {
                safeFinish(uploader);
                uploader = null;

                String summary = UploadFailurePolicy.summarize(ex);
                boolean retryable = UploadFailurePolicy.isRetryable(ex);
                if (retryable) {
                    stats.retryableFailures++;
                }
                logTusWarn("tus-patch-failed file=" + uploadName
                        + " uploadId=" + uploadRow.id
                        + " offset=" + beforeOffset
                        + " chunkBytes=" + chunkBytes
                        + " retryable=" + retryable
                        + " reason=" + summary);
                if (!retryable) {
                    throw ex;
                }

                DelayedRecoveryResult recovery = waitForDelayedPatchDelivery(uploadName, uploadUrl, beforeOffset, size, assetId);
                if (recovery.status == RecoveryStatus.SERVER_FINALIZED) {
                    completedWithoutUploader = true;
                    persistResumeState(uploadRow, null, size);
                    break;
                }
                if (recovery.status == RecoveryStatus.ADVANCED) {
                    stats.stallRecoveries++;
                    chunkController.recordRecoveredProgress();
                    persistResumeState(uploadRow, uploadUrl, recovery.offset);
                    refreshClientHeaders();
                    uploader = client.beginOrResumeUploadFromURL(upload, uploadUrl);
                    logTusInfo("delayed PATCH recovered file=" + uploadName
                            + " uploadId=" + uploadRow.id
                            + " recoveredOffset=" + recovery.offset
                            + " total=" + size);
                    continue;
                }

                int reducedChunk = chunkController.recordRecoveryMiss();
                logTusWarn("waiting for delayed tunnel PATCH did not advance file=" + uploadName
                        + " uploadId=" + uploadRow.id
                        + " offset=" + beforeOffset
                        + " reducing_chunk_size=" + reducedChunk
                        + " recoveryMisses=" + chunkController.recoveryMisses()
                        + "/" + chunkController.maxRecoveryAttempts());
                if (!chunkController.canAttemptRecovery()) {
                    throw ex;
                }
                if (recovery.status == RecoveryStatus.STALE_UPLOAD) {
                    clearResumeState(uploadRow);
                    uploadUrl = null;
                } else if (uploadUrl != null) {
                    persistResumeState(uploadRow, uploadUrl, beforeOffset);
                }
            }
        }

        if (!completedWithoutUploader && uploader != null) {
            uploader.finish();
        }

        if (markRowCompletedOnSuccess && uploadRow.id > 0) {
            uploadDao.markCompleted(uploadRow.id, size);
        } else if (uploadRow.id > 0) {
            persistResumeState(uploadRow, null, size);
        }
        onComplete.onComplete(size);
        logTusInfo("tus-done file=" + uploadName
                + " uploadId=" + uploadRow.id
                + " size=" + size
                + " patchRequests=" + stats.patchRequests
                + " retryableFailures=" + stats.retryableFailures
                + " stallRecoveries=" + stats.stallRecoveries
                + " slowChunkWarnHits=" + stats.slowChunkWarnHits
                + " finalChunkBytes=" + chunkController.currentChunkBytes());
    }

    private void configureUploader(TusUploader uploader, int chunkBytes) {
        uploader.setChunkSize(chunkBytes);
        uploader.setRequestPayloadSize(chunkBytes);
    }

    private DelayedRecoveryResult waitForDelayedPatchDelivery(
            String uploadName,
            @Nullable URL uploadUrl,
            long beforeOffset,
            long totalBytes,
            @Nullable String assetId
    ) throws Exception {
        if (uploadUrl == null) {
            return DelayedRecoveryResult.staleUpload();
        }

        long deadline = System.currentTimeMillis() + RECOVERY_WINDOW_MS;
        while (System.currentTimeMillis() < deadline) {
            HeadProbeResult probe = probeRemoteOffset(uploadUrl);
            if (probe.status == HeadProbeStatus.OK) {
                logTusInfo("tus-head file=" + uploadName
                        + " offset=" + probe.offset
                        + " total=" + totalBytes
                        + " previousOffset=" + beforeOffset);
                if (probe.offset > beforeOffset) {
                    return DelayedRecoveryResult.advanced(probe.offset);
                }
            } else if (probe.status == HeadProbeStatus.NOT_FOUND) {
                if (isUploadAlreadyFinalized(assetId)) {
                    return DelayedRecoveryResult.serverFinalized();
                }
                return DelayedRecoveryResult.staleUpload();
            } else if (probe.error != null && !UploadFailurePolicy.isRetryable(probe.error)) {
                throw probe.error;
            }

            try {
                Thread.sleep(RECOVERY_POLL_MS);
            } catch (InterruptedException ie) {
                Thread.currentThread().interrupt();
                throw ie;
            }
        }
        return DelayedRecoveryResult.noProgress();
    }

    private HeadProbeResult probeRemoteOffset(URL uploadUrl) {
        HttpURLConnection connection = null;
        try {
            refreshClientHeaders();
            connection = (HttpURLConnection) uploadUrl.openConnection();
            connection.setReadTimeout(READ_TIMEOUT_MS);
            connection.setRequestMethod("HEAD");
            client.prepareConnection(connection);
            connection.connect();

            int responseCode = connection.getResponseCode();
            if (responseCode == 404 || responseCode == 410) {
                return HeadProbeResult.notFound(responseCode);
            }
            if (!(responseCode >= 200 && responseCode < 300)) {
                return HeadProbeResult.error(new IOException("HTTP " + responseCode + " while probing upload"));
            }

            String offsetStr = connection.getHeaderField("Upload-Offset");
            if (offsetStr == null || offsetStr.trim().isEmpty()) {
                return HeadProbeResult.error(new IOException("missing Upload-Offset while probing upload"));
            }
            return HeadProbeResult.ok(Long.parseLong(offsetStr.trim()));
        } catch (Exception e) {
            return HeadProbeResult.error(e);
        } finally {
            if (connection != null) {
                connection.disconnect();
            }
        }
    }

    private boolean isUploadAlreadyFinalized(@Nullable String assetId) {
        if (assetId == null || assetId.isEmpty()) {
            return false;
        }
        try {
            boolean exists = new ServerPhotosService(app).isAssetFullyBackedUp(assetId);
            if (exists) {
                logTusInfo("tus-finalize-verified asset_id=" + assetId);
            }
            return exists;
        } catch (Exception e) {
            logTusWarn("tus-finalize-verify-failed asset_id=" + assetId + " reason=" + UploadFailurePolicy.summarize(e));
            return false;
        }
    }

    private void refreshClientHeaders() {
        HashMap<String, String> headers = new HashMap<>();
        if (auth.getToken() != null && !auth.getToken().isEmpty()) {
            headers.put("Authorization", "Bearer " + auth.getToken());
        }
        client.setHeaders(headers);
    }

    @Nullable
    private URL parseStoredUploadUrl(@Nullable String rawUrl) {
        if (rawUrl == null || rawUrl.trim().isEmpty()) {
            return null;
        }
        try {
            return new URL(rawUrl.trim());
        } catch (Exception ignored) {
            return null;
        }
    }

    private void persistResumeState(UploadEntity uploadRow, @Nullable URL uploadUrl, long sentBytes) {
        if (uploadRow.id <= 0) {
            return;
        }
        String rawUrl = uploadUrl != null ? uploadUrl.toString() : null;
        uploadDao.setResumeState(uploadRow.id, sentBytes, rawUrl);
        uploadRow.sentBytes = sentBytes;
        uploadRow.tusUrl = rawUrl;
    }

    private void clearResumeState(UploadEntity uploadRow) {
        if (uploadRow.id > 0) {
            uploadDao.clearResumeState(uploadRow.id);
        }
        uploadRow.sentBytes = 0;
        uploadRow.tusUrl = null;
    }

    private void safeFinish(@Nullable TusUploader uploader) {
        if (uploader == null) {
            return;
        }
        try {
            uploader.finish();
        } catch (Exception ignored) {
        }
    }

    private static String oneLine(@Nullable String value) {
        if (value == null || value.trim().isEmpty()) {
            return "-";
        }
        return value.trim().replace('\n', ' ').replace('\r', ' ');
    }

    private static void logTusInfo(String msg) {
        String full = "[TUS] " + msg;
        Log.i(TAG, full);
        Logx.TUS(msg);
    }

    private static void logTusWarn(String msg) {
        String full = "[TUS] " + msg;
        Log.w(TAG, full);
        Log.w(SHARED_TAG, full);
    }

    private interface CompletionHook {
        void onComplete(long size) throws Exception;
    }

    private static final class UploadSessionStats {
        int patchRequests;
        int retryableFailures;
        int stallRecoveries;
        int slowChunkWarnHits;
    }

    private enum RecoveryStatus {
        ADVANCED,
        NO_PROGRESS,
        STALE_UPLOAD,
        SERVER_FINALIZED
    }

    private static final class DelayedRecoveryResult {
        final RecoveryStatus status;
        final long offset;

        private DelayedRecoveryResult(RecoveryStatus status, long offset) {
            this.status = status;
            this.offset = offset;
        }

        static DelayedRecoveryResult advanced(long offset) {
            return new DelayedRecoveryResult(RecoveryStatus.ADVANCED, offset);
        }

        static DelayedRecoveryResult noProgress() {
            return new DelayedRecoveryResult(RecoveryStatus.NO_PROGRESS, -1L);
        }

        static DelayedRecoveryResult staleUpload() {
            return new DelayedRecoveryResult(RecoveryStatus.STALE_UPLOAD, -1L);
        }

        static DelayedRecoveryResult serverFinalized() {
            return new DelayedRecoveryResult(RecoveryStatus.SERVER_FINALIZED, -1L);
        }
    }

    private enum HeadProbeStatus {
        OK,
        NOT_FOUND,
        ERROR
    }

    private static final class HeadProbeResult {
        final HeadProbeStatus status;
        final long offset;
        final Exception error;

        private HeadProbeResult(HeadProbeStatus status, long offset, @Nullable Exception error) {
            this.status = status;
            this.offset = offset;
            this.error = error;
        }

        static HeadProbeResult ok(long offset) {
            return new HeadProbeResult(HeadProbeStatus.OK, offset, null);
        }

        static HeadProbeResult notFound(int ignoredStatusCode) {
            return new HeadProbeResult(HeadProbeStatus.NOT_FOUND, -1L, null);
        }

        static HeadProbeResult error(Exception error) {
            return new HeadProbeResult(HeadProbeStatus.ERROR, -1L, error);
        }
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
