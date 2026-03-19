package ca.openphotos.android.upload;

import android.content.Context;
import android.util.Log;

import androidx.work.Constraints;
import androidx.work.ExistingWorkPolicy;
import androidx.work.ExistingPeriodicWorkPolicy;
import androidx.work.NetworkType;
import androidx.work.OneTimeWorkRequest;
import androidx.work.OutOfQuotaPolicy;
import androidx.work.PeriodicWorkRequest;
import androidx.work.WorkManager;

import java.util.concurrent.TimeUnit;

/** Schedules background TUS processing with Wi‑Fi-only policy and periodic retries. */
public final class UploadScheduler {
    private static final String TAG = "OpenPhotosUploadSched";
    private static final String UNIQUE_ONCE = "bg_tus_once";
    private static final String UNIQUE_PERIODIC = "bg_tus_periodic";
    private UploadScheduler() {}

    public static void scheduleOnce(Context app, boolean wifiOnly) {
        if (UploadStopController.isUserStopRequested()) {
            Log.i(TAG, "scheduleOnce skipped due to user stop request");
            return;
        }
        boolean serviceStarted = UploadForegroundService.start(app, wifiOnly, "scheduleOnce");
        Log.i(TAG, "scheduleOnce wifiOnly=" + wifiOnly + " serviceStarted=" + serviceStarted);
        enqueueWorkOnly(app, wifiOnly, serviceStarted ? "fallback_after_service_start" : "service_start_failed",
                serviceStarted ? 120 : 0);
    }

    static void enqueueWorkOnly(Context app, boolean wifiOnly, String reason, int initialDelaySec) {
        if (UploadStopController.isUserStopRequested()) {
            Log.i(TAG, "enqueueWorkOnly skipped due to user stop request reason=" + reason);
            return;
        }
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
        OneTimeWorkRequest req = builder.build();
        Log.i(TAG, "enqueueWorkOnly wifiOnly=" + wifiOnly
                + " reason=" + reason
                + " initialDelaySec=" + initialDelaySec
                + " req=" + req.getId());
        WorkManager.getInstance(app)
                .enqueueUniqueWork(UNIQUE_ONCE, ExistingWorkPolicy.APPEND_OR_REPLACE, req);
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
        Log.i(TAG, "cancelCurrentRun requested");
    }
}
