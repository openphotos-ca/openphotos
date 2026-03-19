package ca.openphotos.android.upload;

import android.util.Log;

import java.util.concurrent.atomic.AtomicReference;

/** Process-wide gate so only one upload queue runner (service/worker) drains at a time. */
final class UploadRunGate {
    private static final String TAG = "OpenPhotosUpload";
    private static final AtomicReference<String> OWNER = new AtomicReference<>(null);

    private UploadRunGate() {}

    static boolean tryAcquire(String owner) {
        String who = (owner == null || owner.isEmpty()) ? "unknown" : owner;
        boolean acquired = OWNER.compareAndSet(null, who);
        if (acquired) {
            Log.i(TAG, "run gate acquired owner=" + who);
        } else {
            String held = OWNER.get();
            Log.i(TAG, "run gate busy requester=" + who + " heldBy=" + (held == null ? "none" : held));
        }
        return acquired;
    }

    static String currentOwner() {
        String held = OWNER.get();
        return held == null ? "none" : held;
    }

    static void release(String owner) {
        String who = (owner == null || owner.isEmpty()) ? "unknown" : owner;
        boolean released = OWNER.compareAndSet(who, null);
        if (released) {
            Log.i(TAG, "run gate released owner=" + who);
        } else {
            String held = OWNER.get();
            Log.w(TAG, "run gate release skipped owner=" + who + " heldBy=" + (held == null ? "none" : held));
        }
    }
}
