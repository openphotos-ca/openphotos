package ca.openphotos.android.upload;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.net.ConnectivityManager;
import android.net.NetworkCapabilities;
import android.os.Build;
import android.os.IBinder;
import android.os.PowerManager;
import android.util.Log;

import androidx.annotation.Nullable;
import androidx.core.app.NotificationCompat;
import androidx.core.content.ContextCompat;

import ca.openphotos.android.data.db.AppDatabase;
import ca.openphotos.android.data.db.dao.PhotoDao;
import ca.openphotos.android.data.db.dao.UploadDao;
import ca.openphotos.android.data.db.entities.PhotoEntity;
import ca.openphotos.android.data.db.entities.UploadEntity;
import ca.openphotos.android.sync.SyncService;
import ca.openphotos.android.util.ForegroundUploadScreenController;

import java.util.List;
import java.util.Locale;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.Semaphore;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Dedicated foreground service uploader for user-initiated sync sessions.
 * WorkManager remains as a fallback, but long active runs happen here.
 */
public class UploadForegroundService extends Service {
    private static final String TAG = "OpenPhotosUploadSvc";
    private static final String CHANNEL_ID = "uploads";
    private static final int NOTIFICATION_ID = 1101;
    private static final int MAX_ITEMS_PER_RUN = 120;
    private static final int MAX_AUTO_REQUEUE_ATTEMPTS = 2;
    private static final long EMPTY_QUEUE_POLL_MS = 1000L;
    private static final long WAKELOCK_TIMEOUT_MS = 60L * 60L * 1000L;

    public static final String ACTION_PROCESS_QUEUE = "ca.openphotos.android.upload.action.PROCESS_QUEUE";
    public static final String EXTRA_WIFI_ONLY = "wifi_only";
    public static final String EXTRA_TRIGGER = "trigger";

    private final ExecutorService serial = Executors.newSingleThreadExecutor();
    private final AtomicBoolean stopRequested = new AtomicBoolean(false);
    private Future<?> runningTask;
    private PowerManager.WakeLock wakeLock;

    public static boolean start(Context context, boolean wifiOnly, String trigger) {
        Context app = context.getApplicationContext();
        Intent intent = new Intent(app, UploadForegroundService.class);
        intent.setAction(ACTION_PROCESS_QUEUE);
        intent.putExtra(EXTRA_WIFI_ONLY, wifiOnly);
        if (trigger != null && !trigger.isEmpty()) intent.putExtra(EXTRA_TRIGGER, trigger);
        try {
            ContextCompat.startForegroundService(app, intent);
            return true;
        } catch (Exception e) {
            Log.w(TAG, "start failed wifiOnly=" + wifiOnly + " trigger=" + trigger, e);
            return false;
        }
    }

    public static boolean stop(Context context, String trigger) {
        Context app = context.getApplicationContext();
        boolean stopped = app.stopService(new Intent(app, UploadForegroundService.class));
        Log.i(TAG, "stop requested trigger=" + trigger + " stopped=" + stopped);
        return stopped;
    }

    @Override
    public void onCreate() {
        super.onCreate();
        createChannel();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        boolean wifiOnly = intent != null && intent.getBooleanExtra(EXTRA_WIFI_ONLY, false);
        String trigger = intent != null ? intent.getStringExtra(EXTRA_TRIGGER) : null;
        if (trigger == null || trigger.isEmpty()) trigger = "unknown";
        Log.i(TAG, "onStartCommand id=" + startId + " action="
                + (intent != null ? intent.getAction() : "null")
                + " wifiOnly=" + wifiOnly
                + " trigger=" + trigger);

        if (UploadStopController.isUserStopRequested()) {
            Log.i(TAG, "ignoring start because user stop is pending");
            stopSelfResult(startId);
            return START_NOT_STICKY;
        }

        startForegroundCompat("Uploading in background…");

        synchronized (this) {
            if (runningTask != null && !runningTask.isDone()) {
                Log.i(TAG, "upload service already running; ignoring duplicate start id=" + startId);
                return START_STICKY;
            }
            stopRequested.set(false);
            ForegroundUploadScreenController.setForegroundUploadActive(true);
            final String finalTrigger = trigger;
            runningTask = serial.submit(() -> runQueue(startId, wifiOnly, finalTrigger));
        }
        return START_STICKY;
    }

    @Nullable
    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public void onDestroy() {
        stopRequested.set(true);
        ForegroundUploadScreenController.setForegroundUploadActive(false);
        UploadExecutionTracker.setActive(false);
        synchronized (this) {
            if (runningTask != null && !runningTask.isDone()) {
                runningTask.cancel(true);
            }
        }
        try {
            stopForeground(STOP_FOREGROUND_REMOVE);
        } catch (Exception ignored) {
        }
        releaseWakeLock();
        serial.shutdownNow();
        Log.i(TAG, "onDestroy");
        super.onDestroy();
    }

    private void runQueue(int startId, boolean wifiOnly, String trigger) {
        String owner = "service:" + startId;
        long startedAt = System.currentTimeMillis();
        if (wifiOnly && !isOnUnmeteredNetwork()) {
            Log.i(TAG, "required unmetered network unavailable; enqueue worker fallback");
            UploadScheduler.enqueueWorkOnly(getApplicationContext(), true, "svc_no_unmetered", 0);
            stopSelfResult(startId);
            return;
        }
        if (!UploadRunGate.tryAcquire(owner)) {
            Log.i(TAG, "run skipped: gate held by " + UploadRunGate.currentOwner());
            stopSelfResult(startId);
            return;
        }
        acquireWakeLock();
        UploadExecutionTracker.setActive(true);
        try {
            AppDatabase db = AppDatabase.get(getApplicationContext());
            UploadDao udao = db.uploadDao();
            PhotoDao pdao = db.photoDao();
            SyncService syncService = SyncService.get(getApplicationContext());

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
            AtomicInteger processed = new AtomicInteger(0);
            AtomicInteger success = new AtomicInteger(0);
            AtomicInteger failed = new AtomicInteger(0);

            Log.i(TAG, "service run start id=" + startId
                    + " trigger=" + trigger
                    + " wifiOnly=" + wifiOnly
                    + " policy={" + policy.summary() + "}"
                    + " queued=" + queuedBefore
                    + " uploading=" + uploadingBefore
                    + " done=" + doneBefore
                    + " failed=" + failedBefore);

            while (!stopRequested.get()) {
                if (wifiOnly && !isOnUnmeteredNetwork()) {
                    Log.i(TAG, "service run paused: unmetered network unavailable");
                    UploadScheduler.enqueueWorkOnly(getApplicationContext(), true, "svc_no_unmetered_midrun", 0);
                    return;
                }

                Semaphore budget = new Semaphore(MAX_ITEMS_PER_RUN);
                ExecutorService pool = Executors.newFixedThreadPool(workers);
                CountDownLatch done = new CountDownLatch(workers);

                for (int i = 0; i < workers; i++) {
                    pool.execute(() -> {
                        try {
                            while (!stopRequested.get()) {
                                if (!budget.tryAcquire()) break;
                                UploadEntity e = claimNextQueued(udao);
                                if (e == null) {
                                    budget.release();
                                    break;
                                }
                                if (stopRequested.get()) {
                                    udao.updateStatus(e.id, 0, 0);
                                    break;
                                }
                                processOneUpload("service", e, proc, udao, pdao, lockedSlots, processed, success, failed);
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

                if (stopRequested.get() || UploadStopController.isUserStopRequested() || Thread.currentThread().isInterrupted()) {
                    break;
                }

                int queued = udao.countByStatus(0);
                int uploading = udao.countByStatus(1);
                int remaining = queued + uploading;
                boolean syncRunActive = syncService.isRunInProgress();
                if (remaining > 0) {
                    Log.i(TAG, "service continuing next batch queued=" + queued
                            + " uploading=" + uploading
                            + " syncRunActive=" + syncRunActive);
                    continue;
                }
                if (!syncRunActive) {
                    break;
                }

                Log.i(TAG, "service waiting for more queued uploads while sync enqueue is still running");
                try {
                    Thread.sleep(EMPTY_QUEUE_POLL_MS);
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                    break;
                }
            }

            int queued = udao.countByStatus(0);
            int uploading = udao.countByStatus(1);
            int doneAfter = udao.countByStatus(2);
            int failedAfter = udao.countByStatus(3);
            int remaining = queued + uploading;
            long elapsedMs = System.currentTimeMillis() - startedAt;
            double throughputPerMin = processed.get() <= 0
                    ? 0.0
                    : (processed.get() * 60000.0 / Math.max(1L, elapsedMs));

            Log.i(TAG, "service run summary id=" + startId
                    + " trigger=" + trigger
                    + " processed=" + processed.get()
                    + " success=" + success.get()
                    + " failedThisRun=" + failed.get()
                    + " remaining=" + remaining
                    + " stopRequested=" + stopRequested.get()
                    + " throughputItemsPerMin=" + String.format(Locale.US, "%.2f", throughputPerMin)
                    + " queued=" + queued
                    + " uploading=" + uploading
                    + " done=" + doneAfter
                    + " failed=" + failedAfter
                    + " deltaQueued=" + (queued - queuedBefore)
                    + " deltaUploading=" + (uploading - uploadingBefore)
                    + " deltaDone=" + (doneAfter - doneBefore)
                    + " deltaFailed=" + (failedAfter - failedBefore)
                    + " elapsedMs=" + elapsedMs);

            if (failedAfter > failedBefore || failed.get() > 0) {
                UploadFailureLogHelper.logRecentFailedRows(TAG, "service", udao, pdao, 5);
            }

            if (remaining > 0 && !UploadStopController.isUserStopRequested()) {
                // Hand off immediately if the foreground service exits while work is still queued.
                UploadScheduler.enqueueWorkOnly(getApplicationContext(), wifiOnly, "svc_remaining", 0);
            } else {
                UploadScheduler.cancelRecoveryOnly(getApplicationContext(), "service_queue_drained");
            }
        } catch (Exception e) {
            if (UploadStopController.isUserStopRequested()) {
                Log.i(TAG, "service run interrupted by user stop");
            } else {
                Log.e(TAG, "service run failed, enqueueing retry", e);
                UploadScheduler.enqueueWorkOnly(getApplicationContext(), wifiOnly, "svc_exception", 0);
            }
        } finally {
            ForegroundUploadScreenController.setForegroundUploadActive(false);
            UploadExecutionTracker.setActive(false);
            UploadRunGate.release(owner);
            releaseWakeLock();
            stopForeground(STOP_FOREGROUND_REMOVE);
            stopSelfResult(startId);
        }
    }

    private UploadEntity claimNextQueued(UploadDao udao) {
        for (int i = 0; i < 8 && !stopRequested.get(); i++) {
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

    private void startForegroundCompat(String text) {
        Notification n = new NotificationCompat.Builder(this, CHANNEL_ID)
                .setContentTitle("OpenPhotos")
                .setContentText(text)
                .setSmallIcon(android.R.drawable.stat_sys_upload)
                .setOnlyAlertOnce(true)
                .setOngoing(true)
                .build();
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC);
        } else {
            startForeground(NOTIFICATION_ID, n);
        }
    }

    private void createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return;
        NotificationManager nm = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
        if (nm == null) return;
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return;
        NotificationChannel ch = new NotificationChannel(CHANNEL_ID, "Uploads", NotificationManager.IMPORTANCE_LOW);
        nm.createNotificationChannel(ch);
    }

    private boolean isOnUnmeteredNetwork() {
        try {
            ConnectivityManager cm = (ConnectivityManager) getSystemService(Context.CONNECTIVITY_SERVICE);
            if (cm == null) return false;
            NetworkCapabilities nc = cm.getNetworkCapabilities(cm.getActiveNetwork());
            if (nc == null) return false;
            return nc.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED);
        } catch (Exception e) {
            Log.w(TAG, "network check failed", e);
            return false;
        }
    }

    private void acquireWakeLock() {
        try {
            PowerManager pm = (PowerManager) getSystemService(Context.POWER_SERVICE);
            if (pm == null) return;
            PowerManager.WakeLock wl = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "OpenPhotos:UploadForeground");
            wl.setReferenceCounted(false);
            wl.acquire(WAKELOCK_TIMEOUT_MS);
            wakeLock = wl;
            Log.i(TAG, "wake lock acquired timeoutMs=" + WAKELOCK_TIMEOUT_MS);
        } catch (Exception e) {
            Log.w(TAG, "failed to acquire wake lock", e);
        }
    }

    private void releaseWakeLock() {
        try {
            if (wakeLock != null && wakeLock.isHeld()) wakeLock.release();
            wakeLock = null;
        } catch (Exception e) {
            Log.w(TAG, "failed to release wake lock", e);
        }
    }
}
