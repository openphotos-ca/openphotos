package ca.openphotos.android.sync;

import android.content.Context;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.net.ConnectivityManager;
import android.net.NetworkCapabilities;
import android.net.Uri;
import android.os.Build;
import android.provider.MediaStore;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.core.content.ContextCompat;

import ca.openphotos.android.core.AuthManager;
import ca.openphotos.android.data.db.AppDatabase;
import ca.openphotos.android.data.db.dao.PhotoDao;
import ca.openphotos.android.data.db.dao.UploadDao;
import ca.openphotos.android.data.db.entities.PhotoEntity;
import ca.openphotos.android.data.db.entities.UploadEntity;
import ca.openphotos.android.media.AlbumPathUtil;
import ca.openphotos.android.media.MotionPhotoSupport;
import ca.openphotos.android.prefs.SyncFoldersPreferences;
import ca.openphotos.android.prefs.SyncPreferences;
import ca.openphotos.android.ui.local.BackupIdUtil;
import ca.openphotos.android.ui.local.LocalCloudCacheStore;
import ca.openphotos.android.ui.local.LocalMediaItem;
import ca.openphotos.android.upload.SyncConcurrencyPolicy;
import ca.openphotos.android.upload.UploadExecutionTracker;
import ca.openphotos.android.upload.UploadOrchestrator;
import ca.openphotos.android.upload.UploadScheduler;
import ca.openphotos.android.upload.UploadStopController;
import ca.openphotos.android.util.Base58;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Sync orchestration for Android tab-3 parity with iOS behavior.
 *
 * Candidate pipeline:
 * - auth + permission checks
 * - scope filter (all / selected + optional unassigned)
 * - photos-only filter
 * - network (cellular) filter by media type
 * - failed retry backoff unless force-retry
 */
public final class SyncService {
    private static final String TAG = "OpenPhotosSync";
    private static final String MOTION_TAG = MotionPhotoSupport.TAG;
    private static volatile SyncService INSTANCE;

    private final Context app;
    private final AppDatabase db;
    private final PhotoDao photoDao;
    private final UploadDao uploadDao;
    private final SyncPreferences prefs;
    private final SyncFoldersPreferences folderPrefs;
    private final LocalCloudCacheStore localCloudCache;
    private final ExecutorService serial = Executors.newSingleThreadExecutor();

    private final Object runLock = new Object();
    private boolean running = false;
    private boolean pending = false;
    private boolean pendingForceRetry = false;
    private boolean observerRegistered = false;
    private volatile boolean stopRequested = false;
    private volatile Thread runThread;
    private volatile ExecutorService preprocessPoolRef;

    private SyncService(Context app) {
        this.app = app.getApplicationContext();
        this.db = AppDatabase.get(this.app);
        this.photoDao = db.photoDao();
        this.uploadDao = db.uploadDao();
        this.prefs = new SyncPreferences(this.app);
        this.folderPrefs = new SyncFoldersPreferences(this.app);
        this.localCloudCache = new LocalCloudCacheStore(this.app);
    }

    public static SyncService get(Context app) {
        if (INSTANCE == null) {
            synchronized (SyncService.class) {
                if (INSTANCE == null) INSTANCE = new SyncService(app);
            }
        }
        return INSTANCE;
    }

    public boolean isSyncBusy() {
        synchronized (runLock) {
            return running || UploadExecutionTracker.isActive();
        }
    }

    public boolean isRunInProgress() {
        synchronized (runLock) {
            return running;
        }
    }

    /** Auto-start on app launch only after user manually starts sync once. */
    public void onAppOpen() {
        if (!prefs.syncEnabledAfterManualStart()) {
            Log.i(TAG, "onAppOpen skipped: manual-start guard not satisfied");
            return;
        }
        if (!prefs.autoStartOnOpen()) {
            Log.i(TAG, "onAppOpen skipped: auto-start disabled");
            return;
        }
        if (prefs.autoStartWifiOnly() && isNetworkMetered()) {
            Log.i(TAG, "onAppOpen skipped: wifi-only auto-start while on metered network");
            return;
        }
        SyncStartResult result = syncNow(false, false);
        Log.i(TAG, "onAppOpen sync trigger result=" + result);
        if (result == SyncStartResult.STARTED || result == SyncStartResult.ALREADY_RUNNING) {
            registerMediaObserverIfNeeded();
        }
    }

    /**
     * Queue a sync run. If one is active, coalesce this request and run again after current run.
     */
    public SyncStartResult syncNow(boolean forceRetryFailed, boolean userInitiated) {
        if (!AuthManager.get(app).isAuthenticated()) return SyncStartResult.NOT_AUTHENTICATED;
        if (!hasMediaReadPermission()) return SyncStartResult.MISSING_MEDIA_PERMISSION;
        String serverUrl = AuthManager.get(app).getServerUrl();
        if (serverUrl == null || serverUrl.trim().isEmpty()) return SyncStartResult.MISSING_SERVER_URL;

        if (userInitiated) prefs.setSyncEnabledAfterManualStart(true);
        UploadStopController.clearUserStopRequest();

        synchronized (runLock) {
            stopRequested = false;
            if (running) {
                pending = true;
                pendingForceRetry = pendingForceRetry || forceRetryFailed;
                return SyncStartResult.ALREADY_RUNNING;
            }
            running = true;
        }

        Log.i(TAG, "syncNow accepted forceRetryFailed=" + forceRetryFailed + " userInitiated=" + userInitiated);
        serial.execute(() -> runSync(forceRetryFailed));
        return SyncStartResult.STARTED;
    }

    public boolean stopCurrentSync() {
        boolean hadActiveWork;
        synchronized (runLock) {
            hadActiveWork = running || UploadExecutionTracker.isActive();
            if (!hadActiveWork) {
                return false;
            }
            stopRequested = true;
            pending = false;
            pendingForceRetry = false;
        }

        Log.i(TAG, "stopCurrentSync requested");
        UploadScheduler.cancelCurrentRun(app);

        ExecutorService preprocessPool = preprocessPoolRef;
        if (preprocessPool != null) {
            preprocessPool.shutdownNow();
        }
        Thread activeRunThread = runThread;
        if (activeRunThread != null) {
            activeRunThread.interrupt();
        }

        int requeuedUploads = uploadDao.requeueUploading();
        int pausedPhotos = photoDao.markUploadingAsBackgroundQueued(System.currentTimeMillis() / 1000L);
        Log.i(TAG, "stopCurrentSync requeuedUploads=" + requeuedUploads + " pausedPhotos=" + pausedPhotos);
        return true;
    }

    private void runSync(boolean forceRetryFailed) {
        final long runStartedAt = System.currentTimeMillis();
        final long runId = runStartedAt;
        runThread = Thread.currentThread();
        try {
            if (stopRequested || UploadStopController.isUserStopRequested()) {
                Log.i(TAG, "runSync aborted before start due to user stop request");
                return;
            }
            if (!AuthManager.get(app).isAuthenticated()) {
                Log.w(TAG, "runSync aborted: not authenticated");
                return;
            }
            if (!hasMediaReadPermission()) {
                Log.w(TAG, "runSync aborted: missing media permission");
                return;
            }
            if (AuthManager.get(app).getServerUrl() == null || AuthManager.get(app).getServerUrl().trim().isEmpty()) {
                Log.w(TAG, "runSync aborted: missing server url");
                return;
            }

            SyncConcurrencyPolicy.Snapshot policy = SyncConcurrencyPolicy.resolve(app);
            boolean wifiOnly = prefs.wifiOnly();
            int queuedUploadsAtStart = uploadDao.countByStatus(0);
            int uploadingUploadsAtStart = uploadDao.countByStatus(1);
            Log.i(TAG, "runSync start runId=" + runId
                    + " forceRetryFailed=" + forceRetryFailed
                    + " metered=" + isNetworkMetered()
                    + " policy={" + policy.summary() + "}");
            // Even when no new candidates are found, user-initiated Sync Now should still
            // kick pending upload rows.
            if (queuedUploadsAtStart > 0 || uploadingUploadsAtStart > 0) {
                UploadScheduler.scheduleOnce(app, wifiOnly);
                Log.i(TAG, "runSync kick uploader runId=" + runId
                        + " queuedUploadsAtStart=" + queuedUploadsAtStart
                        + " uploadingUploadsAtStart=" + uploadingUploadsAtStart);
            }

            List<Candidate> candidates = buildCandidates(forceRetryFailed);
            if (candidates.isEmpty()) {
                int bgQueued = photoDao.countBgQueued();
                if (bgQueued > 0 && queuedUploadsAtStart == 0 && uploadingUploadsAtStart == 0) {
                    int recovered = photoDao.markBgQueuedAsPending();
                    if (recovered > 0) {
                        Log.w(TAG, "runSync recovered stale bgQueued rows runId=" + runId
                                + " recovered=" + recovered);
                        candidates = buildCandidates(true);
                    }
                }
                if (candidates.isEmpty()) {
                    Log.i(TAG, "runSync found no eligible candidates runId=" + runId
                            + " queuedUploadsAtStart=" + queuedUploadsAtStart
                            + " uploadingUploadsAtStart=" + uploadingUploadsAtStart
                            + " bgQueued=" + photoDao.countBgQueued());
                    return;
                }
            }
            int queuedBefore = uploadDao.countByStatus(0);
            int uploadingBefore = uploadDao.countByStatus(1);
            int doneBefore = uploadDao.countByStatus(2);
            int failedBefore = uploadDao.countByStatus(3);
            Log.i(TAG, "runSync queued candidates=" + candidates.size()
                    + " runId=" + runId
                    + " queuedUploadsBefore=" + queuedBefore
                    + " uploadingUploadsBefore=" + uploadingBefore);

            long now = System.currentTimeMillis() / 1000L;
            // Kick background uploader immediately so queued rows start draining even if this enqueue loop
            // is interrupted while app is backgrounded.
            UploadScheduler.scheduleOnce(app, wifiOnly);

            AtomicInteger nextIndex = new AtomicInteger(0);
            AtomicInteger processed = new AtomicInteger(0);
            AtomicInteger enqueued = new AtomicInteger(0);
            AtomicInteger failed = new AtomicInteger(0);
            final List<Candidate> finalCandidates = candidates;
            int preprocessWorkers = Math.max(1, policy.preprocessParallelism);
            ExecutorService preprocessPool = Executors.newFixedThreadPool(preprocessWorkers);
            preprocessPoolRef = preprocessPool;
            CountDownLatch preprocessDone = new CountDownLatch(preprocessWorkers);

            for (int i = 0; i < preprocessWorkers; i++) {
                preprocessPool.execute(() -> {
                    UploadOrchestrator orchestrator = new UploadOrchestrator(app);
                    try {
                        while (true) {
                            if (stopRequested || UploadStopController.isUserStopRequested() || Thread.currentThread().isInterrupted()) {
                                return;
                            }
                            int idx = nextIndex.getAndIncrement();
                            if (idx >= finalCandidates.size()) break;
                            Candidate c = finalCandidates.get(idx);
                            String contentId = contentIdForLocalId(c.localId);
                            try {
                                int rows = enqueueCandidate(orchestrator, c, contentId, now);
                                enqueued.addAndGet(rows);
                            } catch (Exception e) {
                                if (stopRequested || UploadStopController.isUserStopRequested() || e instanceof InterruptedException || Thread.currentThread().isInterrupted()) {
                                    if (e instanceof InterruptedException) {
                                        Thread.currentThread().interrupt();
                                    }
                                    Log.i(TAG, "runSync worker stopping during enqueue contentId=" + contentId);
                                    return;
                                }
                                failed.incrementAndGet();
                                Log.w(TAG, "runSync enqueue failed runId=" + runId + " contentId=" + contentId, e);
                                photoDao.markFailed(contentId, e.getMessage(), System.currentTimeMillis() / 1000L);
                            }
                            int done = processed.incrementAndGet();
                            if (done % 25 == 0) {
                                Log.i(TAG, "runSync progress runId=" + runId
                                        + " processedCandidates=" + done
                                        + " enqueuedRows=" + enqueued.get()
                                        + " failed=" + failed.get()
                                        + " queuedUploads=" + uploadDao.countByStatus(0)
                                        + " uploadingUploads=" + uploadDao.countByStatus(1));
                            }
                        }
                    } finally {
                        preprocessDone.countDown();
                    }
                });
            }
            try {
                preprocessDone.await();
            } catch (InterruptedException ie) {
                Thread.currentThread().interrupt();
                Log.w(TAG, "runSync interrupted while waiting preprocess workers", ie);
            } finally {
                preprocessPool.shutdownNow();
                try {
                    preprocessPool.awaitTermination(5, TimeUnit.SECONDS);
                } catch (InterruptedException ignored) {
                    Thread.currentThread().interrupt();
                }
                preprocessPoolRef = null;
            }

            if (stopRequested || UploadStopController.isUserStopRequested() || Thread.currentThread().isInterrupted()) {
                Log.i(TAG, "runSync stopped before scheduling uploader runId=" + runId);
                return;
            }
            UploadScheduler.scheduleOnce(app, wifiOnly);
            long elapsedMs = System.currentTimeMillis() - runStartedAt;
            int queuedAfter = uploadDao.countByStatus(0);
            int uploadingAfter = uploadDao.countByStatus(1);
            int doneAfter = uploadDao.countByStatus(2);
            int failedAfter = uploadDao.countByStatus(3);
            double throughputPerMin = processed.get() <= 0
                    ? 0.0
                    : (processed.get() * 60000.0 / Math.max(1L, elapsedMs));
            Log.i(TAG, "runSync complete runId=" + runId
                    + " processedCandidates=" + processed.get()
                    + " enqueuedRows=" + enqueued.get()
                    + " failed=" + failed.get()
                    + " throughputItemsPerMin=" + String.format(Locale.US, "%.2f", throughputPerMin)
                    + " queuedUploadsAfter=" + queuedAfter
                    + " uploadingUploadsAfter=" + uploadingAfter
                    + " doneAfter=" + doneAfter
                    + " failedAfter=" + failedAfter
                    + " deltaQueued=" + (queuedAfter - queuedBefore)
                    + " deltaUploading=" + (uploadingAfter - uploadingBefore)
                    + " deltaDone=" + (doneAfter - doneBefore)
                    + " deltaFailed=" + (failedAfter - failedBefore)
                    + " elapsedMs=" + elapsedMs);
        } finally {
            runThread = null;
            preprocessPoolRef = null;
            finishRun();
        }
    }

    private int enqueueCandidate(UploadOrchestrator orchestrator, Candidate c, String contentId, long nowSec) throws Exception {
        ensurePhotoRow(contentId, c);
        File motionVideo = null;
        boolean motionQueued = false;
        boolean motionConsumedByLocked = false;
        try {
            // Retry path parity: if failed queue components already exist for this content_id,
            // requeue them instead of creating duplicate queue rows.
            PhotoEntity current = photoDao.getByContentId(contentId);
            if (current != null && current.syncState == 3) {
                int revived = uploadDao.requeueFailedByContentId(contentId);
                if (revived > 0) {
                    photoDao.markBackgroundQueued(contentId, nowSec);
                    Log.i(TAG, "runSync revived failed queue components contentId=" + contentId
                            + " revived=" + revived);
                    return revived;
                }
            }

            if (!c.isVideo) {
                motionVideo = MotionPhotoSupport.extractMotionIfLikely(
                        app,
                        c.uri,
                        c.displayName,
                        c.mime,
                        contentId,
                        "sync"
                );
            }

            int rowsEnqueuedForCandidate = 0;
            if (c.locked) {
                orchestrator.enqueueLocked(contentId, c.uri, c.isVideo, c.createdAt, c.albumPathsJson, c.mime);
                rowsEnqueuedForCandidate += 2; // orig + thumb
                if (motionVideo != null && motionVideo.exists() && motionVideo.length() > 0) {
                    orchestrator.enqueueLockedFile(
                            contentId,
                            motionVideo,
                            true,
                            c.createdAt,
                            c.albumPathsJson,
                            "video/mp4"
                    );
                    rowsEnqueuedForCandidate += 2; // orig + thumb for motion component
                    motionConsumedByLocked = true;
                    Log.i(MOTION_TAG, "paired-enqueue mode=locked contentId=" + contentId
                            + " still=" + (c.displayName == null ? "" : c.displayName)
                            + " motion=" + motionVideo.getName());
                }
                photoDao.markBackgroundQueued(contentId, nowSec);
            } else {
                File tmp = exportToCache(c.uri, guessExtension(c.mime));
                warmBackupIdCache(c, tmp);
                enqueueUnlockedUploadRow(contentId, tmp, c.displayName, c.isVideo, c.albumPathsJson, c.mime);
                rowsEnqueuedForCandidate++;
                if (motionVideo != null && motionVideo.exists() && motionVideo.length() > 0) {
                    enqueueUnlockedUploadRow(contentId, motionVideo, motionVideo.getName(), true, c.albumPathsJson, "video/mp4");
                    motionQueued = true;
                    rowsEnqueuedForCandidate++;
                    Log.i(MOTION_TAG, "paired-enqueue mode=unlocked contentId=" + contentId
                            + " still=" + (c.displayName == null ? "" : c.displayName)
                            + " motion=" + motionVideo.getName());
                }
                photoDao.markBackgroundQueued(contentId, nowSec);
            }
            return rowsEnqueuedForCandidate;
        } finally {
            if (motionVideo != null && motionVideo.exists() && (motionConsumedByLocked || !motionQueued)) {
                try { motionVideo.delete(); } catch (Exception ignored) {}
            }
        }
    }

    private void finishRun() {
        boolean rerun;
        boolean rerunForce;
        boolean stoppedByUser;
        synchronized (runLock) {
            rerun = pending;
            rerunForce = pendingForceRetry;
            pending = false;
            pendingForceRetry = false;
            running = false;
            stoppedByUser = stopRequested || UploadStopController.isUserStopRequested();
        }
        if (stoppedByUser) return;
        if (rerun) syncNow(rerunForce, false);
    }

    private void enqueueUnlockedUploadRow(
            String contentId,
            File tempFile,
            String displayName,
            boolean isVideo,
            String albumPathsJson,
            String mimeType
    ) {
        UploadEntity ue = new UploadEntity();
        ue.itemId = java.util.UUID.randomUUID().toString();
        ue.contentId = contentId;
        ue.filename = preferredUploadFilename(displayName, tempFile.getName(), mimeType, isVideo);
        ue.tempFilePath = tempFile.getAbsolutePath();
        ue.mimeType = mimeType != null ? mimeType : (isVideo ? "video/*" : "image/*");
        ue.isVideo = isVideo;
        ue.totalBytes = tempFile.length();
        ue.sentBytes = 0;
        ue.status = 0;
        ue.isLocked = false;
        ue.lockedKind = null;
        ue.assetIdB58 = null;
        ue.outerHeaderB64Url = null;
        ue.albumPathsJson = prefs.preserveAlbum() ? albumPathsJson : null;
        ue.lockedMetadataJson = null;
        uploadDao.upsert(ue);
    }

    private void warmBackupIdCache(@NonNull Candidate candidate, @NonNull File exportedFile) {
        String userId = AuthManager.get(app).getUserId();
        if (userId == null || userId.trim().isEmpty()) return;
        LocalMediaItem item = candidate.asLocalMediaItem();
        String fingerprint = BackupIdUtil.fingerprint(item);
        java.util.List<String> candidates = BackupIdUtil.computeBackupIdCandidatesForFile(
                app,
                exportedFile,
                candidate.mime != null ? candidate.mime : "",
                candidate.displayName != null ? candidate.displayName : exportedFile.getName(),
                candidate.isVideo,
                userId
        );
        if (candidates.isEmpty()) return;
        localCloudCache.put(candidate.localId, new LocalCloudCacheStore.Entry(
                fingerprint,
                candidates,
                LocalCloudCacheStore.STATE_UNKNOWN,
                0L
        ));
    }

    private String preferredUploadFilename(String displayName, String fallbackName, String mimeType, boolean isVideo) {
        String candidate = (displayName != null && !displayName.trim().isEmpty()) ? displayName.trim() : fallbackName;
        if (candidate == null || candidate.trim().isEmpty()) {
            candidate = isVideo ? "upload.mov" : "upload.jpg";
        }
        if (candidate.contains(".")) {
            return candidate;
        }
        String ext = guessExtension(mimeType);
        if (ext == null || ext.isEmpty()) {
            ext = isVideo ? "mov" : "jpg";
        }
        return candidate + "." + ext;
    }

    public Stats getStats() {
        return getStats(prefs.scope(), prefs.syncIncludeUnassigned());
    }

    public Stats getStats(String scope, boolean includeUnassigned) {
        if (!"selected".equals(scope)) return getGlobalStats();
        return getScopedStats(includeUnassigned);
    }

    private Stats getGlobalStats() {
        Stats s = new Stats();
        s.pending = photoDao.countPending();
        s.uploading = photoDao.countUploading();
        s.bgQueued = photoDao.countBgQueued();
        s.failed = photoDao.countFailed();
        s.synced = photoDao.countSynced();
        s.lastSyncAt = photoDao.maxSyncOrAttemptTs();
        return s;
    }

    private Stats getScopedStats(boolean includeUnassigned) {
        Stats s = new Stats();
        Set<String> selected = normalizePaths(folderPrefs.getSyncFolders());
        List<PhotoEntity> rows = photoDao.listAll();

        long maxTs = 0L;
        for (PhotoEntity row : rows) {
            String rel = queryRelativePathSafe(row.contentUri, row.mediaType == 1);
            boolean inSelected = pathMatches(rel, selected);
            boolean inScope = inSelected || (includeUnassigned && !inSelected);
            if (selected.isEmpty() && !includeUnassigned) inScope = false;
            if (!inScope) continue;

            switch (row.syncState) {
                case 1:
                    s.uploading++;
                    break;
                case 4:
                    s.bgQueued++;
                    break;
                case 3:
                    s.failed++;
                    break;
                case 2:
                    s.synced++;
                    break;
                default:
                    s.pending++;
                    break;
            }
            if (row.syncAt != null && row.syncAt > maxTs) maxTs = row.syncAt;
            else if (row.lastAttemptAt != null && row.lastAttemptAt > maxTs) maxTs = row.lastAttemptAt;
        }
        s.lastSyncAt = maxTs;
        return s;
    }

    /** ReSync action: mark everything pending and clear retry metadata. */
    public int resetAllForResync() {
        return photoDao.resetAllToPending();
    }

    /** Retry action: requeue failed + background queued items. */
    public int retryStuckAndFailed() {
        return photoDao.retryStuckAndFailed();
    }

    private List<Candidate> buildCandidates(boolean forceRetryFailed) {
        boolean scopeSelected = "selected".equals(prefs.scope());
        boolean includeUnassigned = prefs.syncIncludeUnassigned();
        boolean photosOnly = prefs.syncPhotosOnly();
        boolean metered = isNetworkMetered();
        boolean allowPhotoCell = prefs.allowCellularPhotos();
        boolean allowVideoCell = prefs.allowCellularVideos();

        Set<String> selectedFolders = normalizePaths(folderPrefs.getSyncFolders());
        Set<String> lockedFolders = normalizePaths(folderPrefs.getLockedFolders());

        List<Candidate> imageCandidates = queryImages(
                scopeSelected,
                includeUnassigned,
                photosOnly,
                metered,
                allowPhotoCell,
                selectedFolders,
                lockedFolders
        );
        List<Candidate> videoCandidates = photosOnly
                ? new ArrayList<>()
                : queryVideos(scopeSelected, includeUnassigned, metered, allowVideoCell, selectedFolders, lockedFolders);
        ArrayList<Candidate> out = new ArrayList<>(imageCandidates.size() + videoCandidates.size());
        out.addAll(imageCandidates);
        out.addAll(videoCandidates);

        long now = System.currentTimeMillis() / 1000L;
        ArrayList<Candidate> filtered = new ArrayList<>(out.size());
        int skippedSynced = 0;
        int skippedInFlight = 0;
        int recoveredStaleInFlight = 0;
        int skippedFailedBackoff = 0;
        int includedFailedRetry = 0;
        int includedSignatureChanged = 0;
        for (Candidate c : out) {
            String contentId = contentIdForLocalId(c.localId);
            PhotoEntity existing = photoDao.getByContentId(contentId);
            if (existing == null) {
                filtered.add(c);
                continue;
            }
            if (existing.syncState == 2) {
                if (hasContentSignatureChanged(existing, c)) {
                    includedSignatureChanged++;
                    Log.w(TAG, "buildCandidates content signature changed for synced row; requeueing contentId=" + contentId
                            + " oldCreationTs=" + existing.creationTs
                            + " newCreationTs=" + c.createdAt
                            + " oldSize=" + existing.estimatedBytes
                            + " newSize=" + c.sizeBytes);
                    filtered.add(c);
                    continue;
                }
                skippedSynced++;
                continue;
            }
            if (existing.syncState == 1 || existing.syncState == 4) {
                int notDoneRows = uploadDao.countNotDoneByContentId(contentId);
                if (notDoneRows > 0) {
                    skippedInFlight++;
                    continue;
                }
                Log.w(TAG, "buildCandidates recovering stale sync state contentId=" + contentId
                        + " state=" + existing.syncState
                        + " notDoneRows=" + notDoneRows);
                recoveredStaleInFlight++;
                filtered.add(c);
                continue;
            }
            if (existing.syncState == 3) {
                if (forceRetryFailed) {
                    includedFailedRetry++;
                    filtered.add(c);
                    continue;
                }
                int attempts = Math.max(0, existing.attempts);
                long backoff = Math.min(3600L, 30L << Math.min(10, attempts));
                long last = existing.lastAttemptAt != null ? existing.lastAttemptAt : 0L;
                if (now - last >= backoff) {
                    filtered.add(c);
                } else {
                    skippedFailedBackoff++;
                }
                continue;
            }
            filtered.add(c);
        }
        Log.i(TAG, "buildCandidates summary"
                + " scope=" + (scopeSelected ? "selected" : "all")
                + " includeUnassigned=" + includeUnassigned
                + " photosOnly=" + photosOnly
                + " metered=" + metered
                + " allowPhotoCell=" + allowPhotoCell
                + " allowVideoCell=" + allowVideoCell
                + " selectedFolders=" + selectedFolders.size()
                + " lockedFolders=" + lockedFolders.size()
                + " imageCandidates=" + imageCandidates.size()
                + " videoCandidates=" + videoCandidates.size()
                + " totalCandidates=" + out.size()
                + " selectedForEnqueue=" + filtered.size()
                + " skippedSynced=" + skippedSynced
                + " skippedInFlight=" + skippedInFlight
                + " recoveredStaleInFlight=" + recoveredStaleInFlight
                + " skippedFailedBackoff=" + skippedFailedBackoff
                + " includedFailedRetry=" + includedFailedRetry
                + " includedSignatureChanged=" + includedSignatureChanged);
        return filtered;
    }

    private List<Candidate> queryImages(
            boolean scopeSelected,
            boolean includeUnassigned,
            boolean photosOnly,
            boolean metered,
            boolean allowCell,
            Set<String> selectedFolders,
            Set<String> lockedFolders
    ) {
        List<Candidate> list = new ArrayList<>();
        if (metered && !allowCell) return list;

        String[] proj = {
                MediaStore.Images.Media._ID,
                MediaStore.Images.Media.DATE_TAKEN,
                MediaStore.Images.Media.DATE_ADDED,
                MediaStore.Images.Media.RELATIVE_PATH,
                MediaStore.Images.Media.MIME_TYPE,
                MediaStore.Images.Media.DISPLAY_NAME,
                MediaStore.Images.Media.SIZE
        };
        try (Cursor c = app.getContentResolver().query(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                proj,
                null,
                null,
                MediaStore.Images.Media.DATE_TAKEN + " DESC"
        )) {
            if (c == null) return list;
            while (c.moveToNext()) {
                long id = c.getLong(0);
                long dateTakenMs = c.getLong(1);
                long dateAddedSec = c.getLong(2);
                String rel = c.getString(3);
                String mime = c.getString(4);
                String displayName = c.getString(5);
                long sizeBytes = c.getLong(6);

                Uri uri = Uri.withAppendedPath(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, String.valueOf(id));
                String norm = normalizePath(rel);
                boolean inSelected = pathMatches(norm, selectedFolders);

                if (scopeSelected) {
                    if (selectedFolders.isEmpty()) {
                        if (!includeUnassigned) continue;
                    } else if (!inSelected && !includeUnassigned) {
                        continue;
                    }
                }

                Candidate cd = new Candidate();
                cd.uri = uri;
                cd.localId = uri.toString();
                cd.isVideo = false;
                cd.createdAt = dateTakenMs > 0 ? (dateTakenMs / 1000L) : dateAddedSec;
                cd.dateModifiedSec = c.getColumnIndex(MediaStore.Images.Media.DATE_MODIFIED) >= 0
                        ? c.getLong(c.getColumnIndex(MediaStore.Images.Media.DATE_MODIFIED))
                        : 0L;
                cd.width = c.getColumnIndex(MediaStore.Images.Media.WIDTH) >= 0
                        ? c.getInt(c.getColumnIndex(MediaStore.Images.Media.WIDTH))
                        : 0;
                cd.height = c.getColumnIndex(MediaStore.Images.Media.HEIGHT) >= 0
                        ? c.getInt(c.getColumnIndex(MediaStore.Images.Media.HEIGHT))
                        : 0;
                cd.durationMs = 0L;
                cd.relPath = norm;
                cd.mime = mime;
                cd.displayName = displayName;
                cd.sizeBytes = sizeBytes;
                cd.albumPathsJson = prefs.preserveAlbum() ? AlbumPathUtil.pathsJsonFromRelativePath(norm) : null;
                cd.unassigned = scopeSelected && !inSelected;
                if (scopeSelected) {
                    cd.locked = (inSelected && pathMatches(norm, lockedFolders)) || (cd.unassigned && includeUnassigned && prefs.syncUnassignedLocked());
                } else {
                    cd.locked = pathMatches(norm, lockedFolders);
                }
                list.add(cd);
            }
        } catch (Exception ignored) {
        }

        return list;
    }

    private List<Candidate> queryVideos(
            boolean scopeSelected,
            boolean includeUnassigned,
            boolean metered,
            boolean allowCell,
            Set<String> selectedFolders,
            Set<String> lockedFolders
    ) {
        List<Candidate> list = new ArrayList<>();
        if (metered && !allowCell) return list;

        String[] proj = {
                MediaStore.Video.Media._ID,
                MediaStore.Video.Media.DATE_TAKEN,
                MediaStore.Video.Media.DATE_ADDED,
                MediaStore.Video.Media.RELATIVE_PATH,
                MediaStore.Video.Media.MIME_TYPE,
                MediaStore.Video.Media.DISPLAY_NAME,
                MediaStore.Video.Media.SIZE
        };
        try (Cursor c = app.getContentResolver().query(
                MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
                proj,
                null,
                null,
                MediaStore.Video.Media.DATE_TAKEN + " DESC"
        )) {
            if (c == null) return list;
            while (c.moveToNext()) {
                long id = c.getLong(0);
                long dateTakenMs = c.getLong(1);
                long dateAddedSec = c.getLong(2);
                String rel = c.getString(3);
                String mime = c.getString(4);
                String displayName = c.getString(5);
                long sizeBytes = c.getLong(6);

                Uri uri = Uri.withAppendedPath(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, String.valueOf(id));
                String norm = normalizePath(rel);
                boolean inSelected = pathMatches(norm, selectedFolders);

                if (scopeSelected) {
                    if (selectedFolders.isEmpty()) {
                        if (!includeUnassigned) continue;
                    } else if (!inSelected && !includeUnassigned) {
                        continue;
                    }
                }

                Candidate cd = new Candidate();
                cd.uri = uri;
                cd.localId = uri.toString();
                cd.isVideo = true;
                cd.createdAt = dateTakenMs > 0 ? (dateTakenMs / 1000L) : dateAddedSec;
                cd.dateModifiedSec = c.getColumnIndex(MediaStore.Video.Media.DATE_MODIFIED) >= 0
                        ? c.getLong(c.getColumnIndex(MediaStore.Video.Media.DATE_MODIFIED))
                        : 0L;
                cd.width = c.getColumnIndex(MediaStore.Video.Media.WIDTH) >= 0
                        ? c.getInt(c.getColumnIndex(MediaStore.Video.Media.WIDTH))
                        : 0;
                cd.height = c.getColumnIndex(MediaStore.Video.Media.HEIGHT) >= 0
                        ? c.getInt(c.getColumnIndex(MediaStore.Video.Media.HEIGHT))
                        : 0;
                cd.durationMs = c.getColumnIndex(MediaStore.Video.Media.DURATION) >= 0
                        ? c.getLong(c.getColumnIndex(MediaStore.Video.Media.DURATION))
                        : 0L;
                cd.relPath = norm;
                cd.mime = mime;
                cd.displayName = displayName;
                cd.sizeBytes = sizeBytes;
                cd.albumPathsJson = prefs.preserveAlbum() ? AlbumPathUtil.pathsJsonFromRelativePath(norm) : null;
                cd.unassigned = scopeSelected && !inSelected;
                if (scopeSelected) {
                    cd.locked = (inSelected && pathMatches(norm, lockedFolders)) || (cd.unassigned && includeUnassigned && prefs.syncUnassignedLocked());
                } else {
                    cd.locked = pathMatches(norm, lockedFolders);
                }
                list.add(cd);
            }
        } catch (Exception ignored) {
        }

        return list;
    }

    private void ensurePhotoRow(String contentId, Candidate c) {
        PhotoEntity existing = photoDao.getByContentId(contentId);
        if (existing == null) {
            PhotoEntity e = new PhotoEntity();
            e.contentId = contentId;
            e.contentUri = c.localId;
            e.mediaType = c.isVideo ? 1 : 0;
            e.creationTs = c.createdAt;
            e.pixelWidth = 0;
            e.pixelHeight = 0;
            e.estimatedBytes = c.sizeBytes;
            e.syncState = 0;
            e.attempts = 0;
            e.lastError = null;
            e.lastAttemptAt = null;
            e.syncAt = null;
            e.lockOverride = null;
            photoDao.upsert(e);
            return;
        }

        existing.contentUri = c.localId;
        existing.mediaType = c.isVideo ? 1 : 0;
        if (existing.syncState == 2 && hasContentSignatureChanged(existing, c)) {
            existing.syncState = 0;
            existing.attempts = 0;
            existing.lastError = null;
            existing.lastAttemptAt = null;
            existing.syncAt = null;
        }
        existing.creationTs = c.createdAt;
        existing.estimatedBytes = c.sizeBytes;
        photoDao.upsert(existing);
    }

    private static boolean hasContentSignatureChanged(PhotoEntity existing, Candidate c) {
        if (existing == null || c == null) return false;
        if (existing.creationTs > 0 && c.createdAt > 0 && existing.creationTs != c.createdAt) return true;
        return existing.estimatedBytes > 0 && c.sizeBytes > 0 && existing.estimatedBytes != c.sizeBytes;
    }

    private static String contentIdForLocalId(String localId) {
        try {
            MessageDigest md = MessageDigest.getInstance("MD5");
            byte[] dig = md.digest(localId.getBytes(StandardCharsets.UTF_8));
            return Base58.encode(dig);
        } catch (Exception ignored) {
            return localId;
        }
    }

    private String queryRelativePathSafe(String contentUri, boolean isVideo) {
        if (contentUri == null || contentUri.isEmpty()) return "";
        try {
            Uri uri = Uri.parse(contentUri);
            String col = isVideo ? MediaStore.Video.Media.RELATIVE_PATH : MediaStore.Images.Media.RELATIVE_PATH;
            try (Cursor c = app.getContentResolver().query(uri, new String[]{col}, null, null, null)) {
                if (c != null && c.moveToFirst()) {
                    return normalizePath(c.getString(0));
                }
            }
        } catch (Exception ignored) {
        }
        return "";
    }

    private boolean hasMediaReadPermission() {
        if (Build.VERSION.SDK_INT >= 33) {
            int images = ContextCompat.checkSelfPermission(app, android.Manifest.permission.READ_MEDIA_IMAGES);
            int videos = ContextCompat.checkSelfPermission(app, android.Manifest.permission.READ_MEDIA_VIDEO);
            return images == PackageManager.PERMISSION_GRANTED || videos == PackageManager.PERMISSION_GRANTED;
        }
        int read = ContextCompat.checkSelfPermission(app, android.Manifest.permission.READ_EXTERNAL_STORAGE);
        return read == PackageManager.PERMISSION_GRANTED;
    }

    private boolean isNetworkMetered() {
        ConnectivityManager cm = (ConnectivityManager) app.getSystemService(Context.CONNECTIVITY_SERVICE);
        if (cm == null) return true;
        NetworkCapabilities nc = cm.getNetworkCapabilities(cm.getActiveNetwork());
        if (nc == null) return true;
        boolean unmetered = nc.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) || nc.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET);
        return !unmetered;
    }

    private void registerMediaObserverIfNeeded() {
        if (observerRegistered) return;
        android.database.ContentObserver obs = new android.database.ContentObserver(new android.os.Handler()) {
            @Override
            public void onChange(boolean selfChange, Uri uri) {
                if (!prefs.syncEnabledAfterManualStart()) return;
                syncNow(false, false);
            }
        };
        app.getContentResolver().registerContentObserver(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, true, obs);
        app.getContentResolver().registerContentObserver(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, true, obs);
        observerRegistered = true;
    }

    private File exportToCache(Uri uri, String ext) throws Exception {
        File out = File.createTempFile("upl_", (ext != null ? ("." + ext) : ".bin"), app.getCacheDir());
        try (InputStream is = app.getContentResolver().openInputStream(uri);
             FileOutputStream fos = new FileOutputStream(out)) {
            if (is == null) throw new IllegalStateException("Cannot open source URI");
            byte[] buf = new byte[8192];
            int r;
            while ((r = is.read(buf)) > 0) fos.write(buf, 0, r);
        }
        return out;
    }

    private String guessExtension(String mime) {
        if (mime == null) return null;
        String m = mime.toLowerCase(Locale.US);
        if (m.contains("jpeg") || m.contains("jpg")) return "jpg";
        if (m.contains("png")) return "png";
        if (m.contains("heic") || m.contains("heif")) return "heic";
        if (m.contains("mp4")) return "mp4";
        if (m.contains("quicktime") || m.contains("mov")) return "mov";
        return null;
    }

    private static Set<String> normalizePaths(Set<String> src) {
        HashSet<String> out = new HashSet<>();
        if (src == null) return out;
        for (String p : src) {
            String n = normalizePath(p);
            if (!n.isEmpty()) out.add(n);
        }
        return out;
    }

    private static String normalizePath(String rel) {
        if (rel == null) return "";
        String p = rel.trim();
        if (p.isEmpty()) return "";
        String[] parts = p.split("/");
        StringBuilder out = new StringBuilder();
        for (String part : parts) {
            String clean = sanitizeSegment(part);
            if (clean.isEmpty()) continue;
            if (out.length() > 0) out.append('/');
            out.append(clean);
        }
        return out.toString();
    }

    private static String sanitizeSegment(String raw) {
        if (raw == null) return "";
        String s = raw.trim();
        if (s.isEmpty()) return "";
        StringBuilder b = new StringBuilder(s.length());
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (Character.isISOControl(c)) continue;
            if (c == '/' || c == '\\') continue;
            b.append(c);
        }
        return b.toString().trim();
    }

    private static boolean pathMatches(String rel, Set<String> set) {
        if (rel == null || rel.isEmpty() || set == null || set.isEmpty()) return false;
        String rNorm = normalizePath(rel);
        if (rNorm.isEmpty()) return false;
        String r = (rNorm.endsWith("/") ? rNorm : (rNorm + "/")).toLowerCase(Locale.US);
        for (String p : set) {
            String pNorm = normalizePath(p);
            if (pNorm.isEmpty()) continue;
            String s = (pNorm.endsWith("/") ? pNorm : (pNorm + "/")).toLowerCase(Locale.US);
            if (r.startsWith(s)) return true;
        }
        return false;
    }

    public static class Stats {
        public int pending;
        public int uploading;
        public int bgQueued;
        public int failed;
        public int synced;
        public long lastSyncAt;
    }

    public enum SyncStartResult {
        STARTED,
        ALREADY_RUNNING,
        NOT_AUTHENTICATED,
        MISSING_MEDIA_PERMISSION,
        MISSING_SERVER_URL
    }

    private static class Candidate {
        Uri uri;
        String localId;
        boolean isVideo;
        long createdAt;
        long dateModifiedSec;
        long sizeBytes;
        long durationMs;
        int width;
        int height;
        String relPath;
        String displayName;
        String albumPathsJson;
        boolean locked;
        boolean unassigned;
        String mime;

        LocalMediaItem asLocalMediaItem() {
            return new LocalMediaItem(
                    localId,
                    uri != null ? uri.toString() : localId,
                    displayName != null ? displayName : "",
                    mime != null ? mime : "",
                    relPath != null ? relPath : "",
                    isVideo,
                    createdAt,
                    dateModifiedSec,
                    sizeBytes,
                    durationMs,
                    width,
                    height,
                    false,
                    false,
                    false
            );
        }
    }
}
