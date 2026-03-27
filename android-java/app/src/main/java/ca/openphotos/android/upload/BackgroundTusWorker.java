package ca.openphotos.android.upload;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.content.Context;
import android.net.ConnectivityManager;
import android.net.NetworkCapabilities;
import android.os.Build;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.core.app.NotificationCompat;
import android.content.pm.ServiceInfo;
import androidx.work.ForegroundInfo;
import androidx.work.WorkInfo;
import androidx.work.Worker;
import androidx.work.WorkerParameters;

import ca.openphotos.android.data.db.AppDatabase;
import ca.openphotos.android.data.db.dao.PhotoDao;
import ca.openphotos.android.data.db.dao.UploadDao;
import ca.openphotos.android.data.db.entities.PhotoEntity;
import ca.openphotos.android.data.db.entities.UploadEntity;
import ca.openphotos.android.util.ForegroundUploadScreenController;

import java.io.File;
import java.io.FileNotFoundException;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Semaphore;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Background TUS worker. Runs with a minimal persistent notification "Uploading…".
 * This worker will orchestrate queued uploads (implementation expanded in later steps).
 */
public class BackgroundTusWorker extends Worker {
    private static final String CHANNEL_ID = "uploads";
    private static final int NOTIFICATION_ID = 1001;
    private static final String TAG = "OpenPhotosUpload";
    private static final int MAX_ITEMS_PER_RUN = 60;
    private static final int MAX_AUTO_REQUEUE_ATTEMPTS = 2;

    public BackgroundTusWorker(@NonNull Context context, @NonNull WorkerParameters params) {
        super(context, params);
    }

    @NonNull
    @Override
    public Result doWork() {
        final long runStartedAt = System.currentTimeMillis();
        final String owner = "worker:" + getId();
        if (UploadStopController.isUserStopRequested()) {
            Log.i(TAG, "worker skipped due to pending user stop request");
            return Result.success();
        }
        Log.i(TAG, "worker start id=" + getId()
                + " attempt=" + getRunAttemptCount()
                + " stopReason=" + stopReasonToString(getStopReason())
                + " network=" + networkSummary());
        if (!UploadRunGate.tryAcquire(owner)) {
            Log.i(TAG, "worker skipped because queue is already draining by " + UploadRunGate.currentOwner());
            return Result.success();
        }
        UploadExecutionTracker.setActive(true);
        ForegroundUploadScreenController.setForegroundUploadActive(true);
        try {
            // Ensure foreground promotion is requested before potentially long uploads.
            setForegroundAsync(createForegroundInfo("Uploading…")).get();
            Log.i(TAG, "worker foreground promoted id=" + getId());
        } catch (Exception fgErr) {
            Log.w(TAG, "failed to promote worker to foreground", fgErr);
        }
        try {
            AppDatabase db = AppDatabase.get(getApplicationContext());
            UploadDao udao = db.uploadDao();
            PhotoDao pdao = db.photoDao();
            int recovered = udao.requeueUploading();
            if (recovered > 0) {
                Log.w(TAG, "requeued interrupted uploads=" + recovered);
            }

            int queuedBefore = udao.countByStatus(0);
            int uploadingBefore = udao.countByStatus(1);
            int doneBefore = udao.countByStatus(2);
            int failedBefore = udao.countByStatus(3);

            SyncConcurrencyPolicy.Snapshot policy = SyncConcurrencyPolicy.resolve(getApplicationContext());
            TusQueueProcessor proc = new TusQueueProcessor(getApplicationContext(), policy.tusChunkSizeBytes);
            int workers = Math.max(1, policy.uploadParallelism);
            Semaphore lockedSlots = new Semaphore(Math.max(1, policy.lockedParallelism));
            Semaphore budget = new Semaphore(MAX_ITEMS_PER_RUN);
            AtomicInteger processed = new AtomicInteger(0);
            AtomicInteger success = new AtomicInteger(0);
            AtomicInteger failed = new AtomicInteger(0);
            ExecutorService pool = Executors.newFixedThreadPool(workers);
            CountDownLatch done = new CountDownLatch(workers);

            Log.i(TAG, "worker concurrency policy " + policy.summary());
            for (int i = 0; i < workers; i++) {
                pool.execute(() -> {
                    try {
                        while (!isStopped()) {
                            if (!budget.tryAcquire()) break;
                            UploadEntity e = claimNextQueued(udao);
                            if (e == null) {
                                budget.release();
                                break;
                            }
                            if (isStopped()) {
                                udao.updateStatus(e.id, 0, 0);
                                break;
                            }
                            processOneUpload("worker", e, proc, udao, pdao, lockedSlots, processed, success, failed);
                        }
                    } finally {
                        done.countDown();
                    }
                });
            }
            try {
                done.await();
            } finally {
                pool.shutdownNow();
                try {
                    pool.awaitTermination(5, TimeUnit.SECONDS);
                } catch (InterruptedException ignored) {
                    Thread.currentThread().interrupt();
                }
            }

            int queued = udao.countByStatus(0);
            int uploading = udao.countByStatus(1);
            int remaining = queued + uploading;
            long elapsedMs = System.currentTimeMillis() - runStartedAt;
            double throughputPerMin = processed.get() <= 0
                    ? 0.0
                    : (processed.get() * 60000.0 / Math.max(1L, elapsedMs));
            Log.i(TAG, "worker summary id=" + getId()
                    + " processed=" + processed.get()
                    + " success=" + success.get()
                    + " failedThisRun=" + failed.get()
                    + " remaining=" + remaining
                    + " stopped=" + isStopped()
                    + " stopReason=" + stopReasonToString(getStopReason())
                    + " throughputItemsPerMin=" + String.format(java.util.Locale.US, "%.2f", throughputPerMin)
                    + " policy={" + policy.summary() + "}"
                    + " queued=" + queued
                    + " uploading=" + uploading
                    + " done=" + udao.countByStatus(2)
                    + " failed=" + udao.countByStatus(3)
                    + " deltaQueued=" + (queued - queuedBefore)
                    + " deltaUploading=" + (uploading - uploadingBefore)
                    + " deltaDone=" + (udao.countByStatus(2) - doneBefore)
                    + " deltaFailed=" + (udao.countByStatus(3) - failedBefore)
                    + " elapsedMs=" + elapsedMs);
            if (udao.countByStatus(3) > failedBefore || failed.get() > 0) {
                UploadFailureLogHelper.logRecentFailedRows(TAG, "worker", udao, pdao, 5);
            }
            if (remaining > 0 && !UploadStopController.isUserStopRequested()) {
                Log.i(TAG, "worker reached run cap/stopped, rescheduling for remaining queue");
                ca.openphotos.android.prefs.SyncPreferences prefs =
                        new ca.openphotos.android.prefs.SyncPreferences(getApplicationContext());
                UploadScheduler.enqueueWorkOnly(getApplicationContext(), prefs.wifiOnly(), "worker_remaining", 0);
            } else {
                Log.i(TAG, "worker queue drained processed=" + processed.get());
            }
            return Result.success();
        } catch (Exception e) {
            if (UploadStopController.isUserStopRequested()) {
                Log.i(TAG, "worker stopped by user request");
                return Result.success();
            }
            Log.w(TAG, "worker failed, retrying", e);
            return Result.retry();
        } finally {
            ForegroundUploadScreenController.setForegroundUploadActive(false);
            UploadExecutionTracker.setActive(false);
            UploadRunGate.release(owner);
        }
    }

    @Override
    public void onStopped() {
        super.onStopped();
        Log.w(TAG, "worker onStopped id=" + getId()
                + " attempt=" + getRunAttemptCount()
                + " reason=" + stopReasonToString(getStopReason()));
        if (UploadStopController.isUserStopRequested()) {
            Log.i(TAG, "worker onStopped: skipping fallback enqueue due to user stop");
            return;
        }
        try {
            ca.openphotos.android.prefs.SyncPreferences prefs =
                    new ca.openphotos.android.prefs.SyncPreferences(getApplicationContext());
            UploadScheduler.enqueueWorkOnly(getApplicationContext(), prefs.wifiOnly(), "worker_onStopped", 0);
        } catch (Exception e) {
            Log.w(TAG, "worker onStopped fallback enqueue failed", e);
        }
    }

    private ForegroundInfo createForegroundInfo(String text) {
        createChannel();
        Notification notification = new NotificationCompat.Builder(getApplicationContext(), CHANNEL_ID)
                .setContentTitle("OpenPhotos")
                .setContentText(text)
                .setSmallIcon(android.R.drawable.stat_sys_upload)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .build();
        if (android.os.Build.VERSION.SDK_INT >= 29) {
            // Declare the foreground service type explicitly for Android 14+
            return new ForegroundInfo(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC);
        } else {
            return new ForegroundInfo(NOTIFICATION_ID, notification);
        }
    }

    private void createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationManager nm = (NotificationManager) getApplicationContext().getSystemService(Context.NOTIFICATION_SERVICE);
            if (nm.getNotificationChannel(CHANNEL_ID) == null) {
                NotificationChannel ch = new NotificationChannel(CHANNEL_ID, "Uploads", NotificationManager.IMPORTANCE_LOW);
                nm.createNotificationChannel(ch);
            }
        }
    }

    private static String stopReasonToString(int reason) {
        switch (reason) {
            case WorkInfo.STOP_REASON_NOT_STOPPED: return "NOT_STOPPED";
            case WorkInfo.STOP_REASON_UNKNOWN: return "UNKNOWN";
            case WorkInfo.STOP_REASON_CANCELLED_BY_APP: return "CANCELLED_BY_APP";
            case WorkInfo.STOP_REASON_PREEMPT: return "PREEMPT";
            case WorkInfo.STOP_REASON_TIMEOUT: return "TIMEOUT";
            case WorkInfo.STOP_REASON_DEVICE_STATE: return "DEVICE_STATE";
            case WorkInfo.STOP_REASON_CONSTRAINT_BATTERY_NOT_LOW: return "CONSTRAINT_BATTERY_NOT_LOW";
            case WorkInfo.STOP_REASON_CONSTRAINT_CHARGING: return "CONSTRAINT_CHARGING";
            case WorkInfo.STOP_REASON_CONSTRAINT_CONNECTIVITY: return "CONSTRAINT_CONNECTIVITY";
            case WorkInfo.STOP_REASON_CONSTRAINT_DEVICE_IDLE: return "CONSTRAINT_DEVICE_IDLE";
            case WorkInfo.STOP_REASON_CONSTRAINT_STORAGE_NOT_LOW: return "CONSTRAINT_STORAGE_NOT_LOW";
            case WorkInfo.STOP_REASON_QUOTA: return "QUOTA";
            case WorkInfo.STOP_REASON_BACKGROUND_RESTRICTION: return "BACKGROUND_RESTRICTION";
            case WorkInfo.STOP_REASON_APP_STANDBY: return "APP_STANDBY";
            case WorkInfo.STOP_REASON_USER: return "USER";
            case WorkInfo.STOP_REASON_SYSTEM_PROCESSING: return "SYSTEM_PROCESSING";
            case WorkInfo.STOP_REASON_ESTIMATED_APP_LAUNCH_TIME_CHANGED: return "ESTIMATED_APP_LAUNCH_TIME_CHANGED";
            default: return "UNKNOWN(" + reason + ")";
        }
    }

    private String networkSummary() {
        try {
            ConnectivityManager cm = (ConnectivityManager) getApplicationContext().getSystemService(Context.CONNECTIVITY_SERVICE);
            if (cm == null) return "none";
            NetworkCapabilities nc = cm.getNetworkCapabilities(cm.getActiveNetwork());
            if (nc == null) return "disconnected";
            boolean wifi = nc.hasTransport(NetworkCapabilities.TRANSPORT_WIFI);
            boolean cell = nc.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR);
            boolean eth = nc.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET);
            boolean validated = nc.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED);
            return "wifi=" + wifi + ",cell=" + cell + ",eth=" + eth + ",validated=" + validated;
        } catch (Exception e) {
            return "error:" + e.getClass().getSimpleName();
        }
    }

    private UploadEntity claimNextQueued(UploadDao udao) {
        for (int i = 0; i < 8 && !isStopped(); i++) {
            List<UploadEntity> rows = udao.listQueued(1);
            if (rows == null || rows.isEmpty()) return null;
            UploadEntity e = rows.get(0);
            if (udao.claimQueued(e.id) > 0) return e;
        }
        return null;
    }

    private void processOneUpload(
            String runner,
            UploadEntity e,
            TusQueueProcessor proc,
            UploadDao udao,
            PhotoDao pdao,
            Semaphore lockedSlots,
            AtomicInteger processed,
            AtomicInteger success,
            AtomicInteger failed
    ) {
        boolean lockedPermit = false;
        long itemStartedAt = System.currentTimeMillis();
        try {
            if (e.isLocked) {
                lockedSlots.acquire();
                lockedPermit = true;
            }
            int itemSeq = processed.incrementAndGet();
            Log.i(TAG, runner + " item start #" + itemSeq
                    + " uploadId=" + e.id
                    + " contentId=" + e.contentId
                    + " file=" + e.filename
                    + " total=" + e.totalBytes
                    + " sentBytes=" + e.sentBytes
                    + " hasTusUrl=" + (e.tusUrl != null && !e.tusUrl.isEmpty())
                    + " locked=" + e.isLocked
                    + " video=" + e.isVideo);
            if (e.contentId != null && !e.contentId.isEmpty()) {
                pdao.markUploading(e.contentId, System.currentTimeMillis() / 1000L);
            }
            proc.process(e);
            udao.markCompleted(e.id, e.totalBytes);
            if (e.contentId != null && !e.contentId.isEmpty()) {
                int unresolved = udao.countNotDoneByContentId(e.contentId);
                if (unresolved == 0) {
                    pdao.markSynced(e.contentId, System.currentTimeMillis() / 1000L);
                } else {
                    Log.i(TAG, runner + " content pending components contentId=" + e.contentId
                            + " unresolved=" + unresolved);
                }
            }
            success.incrementAndGet();
            Log.i(TAG, runner + " item success uploadId=" + e.id
                    + " elapsedMs=" + (System.currentTimeMillis() - itemStartedAt));
        } catch (InterruptedException ie) {
            Thread.currentThread().interrupt();
            udao.updateStatusOnly(e.id, 0);
            Log.w(TAG, runner + " item interrupted uploadId=" + e.id);
        } catch (Exception ex) {
            String errorSummary = UploadFailurePolicy.summarize(ex);
            boolean retryable = UploadFailurePolicy.isRetryable(ex);
            long nowSec = System.currentTimeMillis() / 1000L;
            if (e.contentId != null && !e.contentId.isEmpty()) {
                PhotoEntity row = pdao.getByContentId(e.contentId);
                if (row == null || row.syncState != 2) {
                    int attempts = row != null ? Math.max(0, row.attempts) : 0;
                    if (row != null && retryable && attempts < MAX_AUTO_REQUEUE_ATTEMPTS) {
                        udao.updateStatusOnly(e.id, 0);
                        pdao.markRetryQueued(e.contentId, errorSummary, nowSec);
                        Log.w(TAG, runner + " item auto-requeued uploadId=" + e.id
                                + " contentId=" + e.contentId
                                + " retryAttempt=" + (attempts + 1)
                                + " reason=" + errorSummary);
                        return;
                    }
                    udao.updateStatusOnly(e.id, 3);
                    pdao.markFailed(e.contentId, errorSummary, nowSec);
                } else {
                    Log.i(TAG, runner + " failure ignored for already-synced contentId=" + e.contentId);
                    udao.updateStatusOnly(e.id, 3);
                }
            } else {
                udao.updateStatusOnly(e.id, 3);
            }
            failed.incrementAndGet();
            Log.e(TAG, runner + " item failed uploadId=" + e.id
                    + " retryable=" + retryable
                    + " reason=" + errorSummary
                    + " elapsedMs=" + (System.currentTimeMillis() - itemStartedAt), ex);
        } finally {
            if (lockedPermit) lockedSlots.release();
        }
    }
}

/** Simple processor that uploads a single queued UploadEntity using TusUploadManager. */
class TusQueueProcessor {
    private final Context app;
    private final int chunkSizeBytes;
    TusQueueProcessor(Context app, int chunkSizeBytes) {
        this.app = app.getApplicationContext();
        this.chunkSizeBytes = chunkSizeBytes;
    }

    void process(UploadEntity e) throws Exception {
        // Queue processor supports both unlocked and locked rows.
        File file = new File(e.tempFilePath);
        if (!file.exists()) throw new FileNotFoundException(e.tempFilePath);
        TusUploadManager mgr = new TusUploadManager(app, chunkSizeBytes);
        if (e.isLocked) {
            java.util.Map<String,String> meta = new java.util.HashMap<>();
            if (e.lockedMetadataJson != null && !e.lockedMetadataJson.isEmpty()) {
                org.json.JSONObject o = new org.json.JSONObject(e.lockedMetadataJson);
                java.util.Iterator<String> it = o.keys();
                while (it.hasNext()) { String k = it.next(); meta.put(k, o.optString(k, null)); }
            }
            mgr.uploadLockedQueued(file, e.filename, meta, e);
        } else {
            PhotoEntity ph =
                    (e.contentId != null && !e.contentId.isEmpty())
                            ? AppDatabase.get(app).photoDao().getByContentId(e.contentId)
                            : null;
            if (ph == null) ph = new PhotoEntity();
            ph.mediaType = e.isVideo ? 1 : 0;
            if (ph.contentId == null || ph.contentId.isEmpty()) ph.contentId = e.contentId != null ? e.contentId : "";
            if (ph.creationTs <= 0) {
                long fileTs = file.lastModified() > 0 ? (file.lastModified() / 1000L) : 0L;
                ph.creationTs = fileTs > 0 ? fileTs : (System.currentTimeMillis() / 1000L);
            }
            mgr.uploadUnlockedQueued(file, ph, e.albumPathsJson, e);
        }
    }
}
