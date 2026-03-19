package ca.openphotos.android.util;

import android.app.Activity;
import android.os.Handler;
import android.os.Looper;
import android.view.WindowManager;

import androidx.annotation.NonNull;

import ca.openphotos.android.prefs.SyncPreferences;

import java.util.Set;
import java.util.concurrent.CopyOnWriteArraySet;
import java.util.concurrent.atomic.AtomicBoolean;

public final class ForegroundUploadScreenController {
    private static final AtomicBoolean FOREGROUND_UPLOAD_ACTIVE = new AtomicBoolean(false);
    private static final Set<Runnable> LISTENERS = new CopyOnWriteArraySet<>();
    private static final Handler MAIN = new Handler(Looper.getMainLooper());

    private ForegroundUploadScreenController() {}

    public static void setForegroundUploadActive(boolean active) {
        boolean changed = FOREGROUND_UPLOAD_ACTIVE.getAndSet(active) != active;
        if (!changed) return;
        MAIN.post(() -> {
            for (Runnable listener : LISTENERS) {
                try {
                    listener.run();
                } catch (Exception ignored) {
                }
            }
        });
    }

    public static boolean isForegroundUploadActive() {
        return FOREGROUND_UPLOAD_ACTIVE.get();
    }

    public static void addListener(@NonNull Runnable listener) {
        LISTENERS.add(listener);
    }

    public static void removeListener(@NonNull Runnable listener) {
        LISTENERS.remove(listener);
    }

    public static void applyTo(@NonNull Activity activity) {
        boolean keepScreenOn = new SyncPreferences(activity.getApplicationContext()).keepScreenOn()
                && isForegroundUploadActive();
        if (keepScreenOn) {
            activity.getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        } else {
            activity.getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        }
    }
}
