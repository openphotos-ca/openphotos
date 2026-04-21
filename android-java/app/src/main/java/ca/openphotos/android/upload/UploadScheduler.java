package ca.openphotos.android.upload;

import android.content.Context;
import android.os.SystemClock;
import android.util.Log;

import androidx.work.Constraints;
import androidx.work.ExistingWorkPolicy;
import androidx.work.ExistingPeriodicWorkPolicy;
import androidx.work.NetworkType;
import androidx.work.OneTimeWorkRequest;
import androidx.work.OutOfQuotaPolicy;
import androidx.work.PeriodicWorkRequest;
import androidx.work.WorkManager;

import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.TimeUnit;

/** Schedules background TUS processing with Wi‑Fi-only policy and periodic retries. */
public final class UploadScheduler {
    private static final String TAG = "OpenPhotosUploadSched";
    private static final String UNIQUE_ONCE = "bg_tus_once";
    private static final String UNIQUE_RECOVERY = "bg_tus_recovery";
    private static final String UNIQUE_PERIODIC = "bg_tus_periodic";
    static final int SERVICE_RECOVERY_DELAY_SEC = 15;
    private static final long RECOVERY_COALESCE_WINDOW_MS = 5_000L;
    private static final AtomicLong LAST_RECOVERY_ENQUEUE_MS = new AtomicLong(0L);

    private UploadScheduler() {}

    public static void scheduleOnce(Context app, boolean wifiOnly) {
        if (UploadStopController.isUserStopRequested()) {
            Log.i(TAG, "scheduleOnce skipped due to user stop request");
            return;
        }
        boolean serviceStarted = UploadForegroundService.start(app, wifiOnly, "scheduleOnce");
        Log.i(TAG, "scheduleOnce wifiOnly=" + wifiOnly + " serviceStarted=" + serviceStarted);
        if (serviceStarted) {
            // Keep a short watchdog behind the foreground service for OEMs that freeze backgrounded apps.
            enqueueRecoveryOnly(app, wifiOnly, "fallback_after_service_start", SERVICE_RECOVERY_DELAY_SEC);
        } else {
            enqueueWorkOnly(app, wifiOnly, "service_start_failed", 0);
        }
    }

    static void enqueueWorkOnly(Context app, boolean wifiOnly, String reason, int initialDelaySec) {
        if (UploadStopController.isUserStopRequested()) {
            Log.i(TAG, "enqueueWorkOnly skipped due to user stop request reason=" + reason);
            return;
        }
        OneTimeWorkRequest req = buildOneTimeRequest(wifiOnly, initialDelaySec);
        Log.i(TAG, "enqueueWorkOnly wifiOnly=" + wifiOnly
                + " reason=" + reason
                + " initialDelaySec=" + initialDelaySec
                + " req=" + req.getId());
        WorkManager.getInstance(app)
                .enqueueUniqueWork(UNIQUE_ONCE, ExistingWorkPolicy.APPEND_OR_REPLACE, req);
    }

    static void enqueueRecoveryOnly(Context app, boolean wifiOnly, String reason, int initialDelaySec) {
        if (UploadStopController.isUserStopRequested()) {
            Log.i(TAG, "enqueueRecoveryOnly skipped due to user stop request reason=" + reason);
            return;
        }
        long now = SystemClock.elapsedRealtime();
        long last = LAST_RECOVERY_ENQUEUE_MS.get();
        if (initialDelaySec > 0 && last > 0 && (now - last) < RECOVERY_COALESCE_WINDOW_MS) {
            Log.i(TAG, "enqueueRecoveryOnly coalesced wifiOnly=" + wifiOnly
                    + " reason=" + reason
                    + " initialDelaySec=" + initialDelaySec
                    + " sinceLastMs=" + (now - last));
            return;
        }
        LAST_RECOVERY_ENQUEUE_MS.set(now);
        OneTimeWorkRequest req = buildOneTimeRequest(wifiOnly, initialDelaySec);
        Log.i(TAG, "enqueueRecoveryOnly wifiOnly=" + wifiOnly
                + " reason=" + reason
                + " initialDelaySec=" + initialDelaySec
                + " req=" + req.getId());
        WorkManager.getInstance(app)
                .enqueueUniqueWork(UNIQUE_RECOVERY, ExistingWorkPolicy.APPEND_OR_REPLACE, req);
    }

    static void cancelRecoveryOnly(Context app, String reason) {
        LAST_RECOVERY_ENQUEUE_MS.set(0L);
        WorkManager.getInstance(app.getApplicationContext()).cancelUniqueWork(UNIQUE_RECOVERY);
        Log.i(TAG, "cancelRecoveryOnly reason=" + reason);
    }

    public static void schedulePeriodic(Context app, boolean wifiOnly, int minutes) {
        int safeMinutes = Math.max(15, minutes);
        Constraints c = new Constraints.Builder()
                .setRequiredNetworkType(wifiOnly ? NetworkType.UNMETERED : NetworkType.CONNECTED)
                .build();
        PeriodicWorkRequest req = new PeriodicWorkRequest.Builder(BackgroundTusWorker.class, safeMinutes, TimeUnit.MINUTES)
                .addTag("uploads")
                .setConstraints(c)
                .build();
        Log.i(TAG, "schedulePeriodic wifiOnly=" + wifiOnly + " minutes=" + safeMinutes + " req=" + req.getId());
        WorkManager.getInstance(app).enqueueUniquePeriodicWork(UNIQUE_PERIODIC, ExistingPeriodicWorkPolicy.UPDATE, req);
    }

    public static void cancelCurrentRun(Context app) {
        Context ctx = app.getApplicationContext();
        UploadStopController.requestUserStop();
        UploadForegroundService.stop(ctx, "user_stop");
        WorkManager.getInstance(ctx).cancelUniqueWork(UNIQUE_ONCE);
        WorkManager.getInstance(ctx).cancelUniqueWork(UNIQUE_RECOVERY);
        LAST_RECOVERY_ENQUEUE_MS.set(0L);
        Log.i(TAG, "cancelCurrentRun requested");
    }

    private static OneTimeWorkRequest buildOneTimeRequest(boolean wifiOnly, int initialDelaySec) {
        Constraints c = new Constraints.Builder()
                .setRequiredNetworkType(wifiOnly ? NetworkType.UNMETERED : NetworkType.CONNECTED)
                .build();
        OneTimeWorkRequest.Builder builder = new OneTimeWorkRequest.Builder(BackgroundTusWorker.class)
                .addTag("uploads")
                .setConstraints(c);
        if (initialDelaySec > 0) {
            builder.setInitialDelay(initialDelaySec, TimeUnit.SECONDS);
        } else {
            builder.setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST);
        }
        return builder.build();
    }
}
