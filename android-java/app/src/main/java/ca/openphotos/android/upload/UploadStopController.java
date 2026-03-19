package ca.openphotos.android.upload;

import java.util.concurrent.atomic.AtomicBoolean;

/** Shared flag for user-requested stop of the current sync/upload run. */
public final class UploadStopController {
    private static final AtomicBoolean USER_STOP_REQUESTED = new AtomicBoolean(false);

    private UploadStopController() {}

    public static void requestUserStop() {
        USER_STOP_REQUESTED.set(true);
    }

    public static void clearUserStopRequest() {
        USER_STOP_REQUESTED.set(false);
    }

    public static boolean isUserStopRequested() {
        return USER_STOP_REQUESTED.get();
    }
}
