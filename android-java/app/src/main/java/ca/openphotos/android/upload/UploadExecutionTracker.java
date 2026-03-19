package ca.openphotos.android.upload;

import java.util.concurrent.atomic.AtomicBoolean;

/** Process-wide flag for whether an upload runner is actively executing. */
public final class UploadExecutionTracker {
    private static final AtomicBoolean ACTIVE = new AtomicBoolean(false);

    private UploadExecutionTracker() {}

    public static void setActive(boolean active) {
        ACTIVE.set(active);
    }

    public static boolean isActive() {
        return ACTIVE.get();
    }
}
