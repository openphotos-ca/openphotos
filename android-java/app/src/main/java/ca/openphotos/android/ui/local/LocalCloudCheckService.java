package ca.openphotos.android.ui.local;

import android.content.Context;

import androidx.annotation.NonNull;

import ca.openphotos.android.core.AuthManager;
import ca.openphotos.android.server.ServerPhotosService;

import java.io.IOException;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Runs backup-id based cloud checks for local media items.
 */
public final class LocalCloudCheckService {
    public interface Listener {
        void onStart(int total);
        void onProgress(int processed, int total);
        void onItemResult(@NonNull String localId, int cloudState); // see LocalCloudCacheStore.STATE_*
        void onFinished(@NonNull Stats stats);
        void onCanceled();
        void onError(@NonNull String message, boolean authExpired);
    }

    public static final class Stats {
        public final int checked;
        public final int backedUp;
        public final int deleted;
        public final int missing;
        public final int skipped;
        @NonNull public final Set<String> deletedLocalIds;

        public Stats(int checked, int backedUp, int deleted, int missing, int skipped, @NonNull Set<String> deletedLocalIds) {
            this.checked = checked;
            this.backedUp = backedUp;
            this.deleted = deleted;
            this.missing = missing;
            this.skipped = skipped;
            this.deletedLocalIds = deletedLocalIds;
        }
    }

    private final Context app;
    private final ExecutorService executor = Executors.newSingleThreadExecutor();
    private final AtomicBoolean canceled = new AtomicBoolean(false);
    private Future<?> running;

    public LocalCloudCheckService(@NonNull Context app) {
        this.app = app.getApplicationContext();
    }

    public synchronized boolean isRunning() {
        return running != null && !running.isDone();
    }

    public synchronized void cancel() {
        canceled.set(true);
        if (running != null) running.cancel(true);
    }

    public synchronized boolean startCheck(
            @NonNull final List<LocalMediaItem> items,
            @NonNull final LocalCloudCacheStore cache,
            @NonNull final Listener listener
    ) {
        if (isRunning()) return false;
        canceled.set(false);
        running = executor.submit(() -> runCheck(items, cache, listener));
        return true;
    }

    private void runCheck(
            @NonNull List<LocalMediaItem> items,
            @NonNull LocalCloudCacheStore cache,
            @NonNull Listener listener
    ) {
        int total = items.size();
        int processed = 0;
        int checked = 0;
        int backed = 0;
        int deleted = 0;
        int missing = 0;
        int skipped = 0;
        Set<String> deletedLocalIds = new HashSet<>();

        try {
            String userId = AuthManager.get(app).getUserId();
            if (userId == null || userId.trim().isEmpty()) {
                listener.onError("Not logged in", true);
                return;
            }

            listener.onStart(total);
            final int chunkSize = 20;
            ServerPhotosService service = new ServerPhotosService(app);

            for (int start = 0; start < items.size(); start += chunkSize) {
                if (canceled.get() || Thread.currentThread().isInterrupted()) {
                    listener.onCanceled();
                    return;
                }

                int end = Math.min(items.size(), start + chunkSize);
                List<LocalMediaItem> chunk = items.subList(start, end);
                Map<String, List<String>> candidatesByLocalId = new HashMap<>();
                Set<String> queryIds = new HashSet<>();

                for (LocalMediaItem item : chunk) {
                    if (canceled.get() || Thread.currentThread().isInterrupted()) {
                        listener.onCanceled();
                        return;
                    }

                    String fp = BackupIdUtil.fingerprint(item);
                    LocalCloudCacheStore.Entry cached = cache.get(item.localId);
                    List<String> candidates;
                    if (cached != null && fp.equals(cached.fingerprint) && !cached.candidates.isEmpty()) {
                        candidates = cached.candidates;
                    } else {
                        candidates = BackupIdUtil.computeBackupIdCandidates(app, item, userId);
                    }

                    if (candidates.isEmpty()) {
                        skipped++;
                        processed++;
                        listener.onProgress(processed, total);
                        continue;
                    }
                    candidatesByLocalId.put(item.localId, candidates);
                    queryIds.addAll(candidates);
                }

                ServerPhotosService.ExistsMatchesResult matches = new ServerPhotosService.ExistsMatchesResult(null, null, null, null);
                if (!queryIds.isEmpty()) {
                    matches = fetchMatchesWithRetry(service, new ArrayList<>(queryIds));
                }

                long nowSec = System.currentTimeMillis() / 1000L;
                for (Map.Entry<String, List<String>> e : candidatesByLocalId.entrySet()) {
                    if (canceled.get() || Thread.currentThread().isInterrupted()) {
                        listener.onCanceled();
                        return;
                    }
                    boolean isBacked = false;
                    boolean isDeleted = false;
                    for (String bid : e.getValue()) {
                        if (matches.presentBackupIds.contains(bid)) {
                            isBacked = true;
                            break;
                        }
                    }
                    if (!isBacked) {
                        for (String bid : e.getValue()) {
                            if (matches.deletedBackupIds.contains(bid)) {
                                isDeleted = true;
                                break;
                            }
                        }
                    }

                    checked++;
                    int cloudState;
                    if (isBacked) {
                        backed++;
                        cloudState = LocalCloudCacheStore.STATE_BACKED_UP;
                    } else if (isDeleted) {
                        deleted++;
                        deletedLocalIds.add(e.getKey());
                        cloudState = LocalCloudCacheStore.STATE_DELETED_IN_CLOUD;
                    } else {
                        missing++;
                        cloudState = LocalCloudCacheStore.STATE_MISSING;
                    }
                    // Preserve fingerprint by re-reading item from chunk
                    LocalMediaItem src = findByLocalId(chunk, e.getKey());
                    if (src != null) {
                        cache.put(e.getKey(), new LocalCloudCacheStore.Entry(
                                BackupIdUtil.fingerprint(src),
                                e.getValue(),
                                cloudState,
                                nowSec
                        ));
                    }

                    listener.onItemResult(e.getKey(), cloudState);
                    processed++;
                    listener.onProgress(processed, total);
                }
            }

            listener.onFinished(new Stats(checked, backed, deleted, missing, skipped, deletedLocalIds));
        } catch (IOException ioe) {
            String m = ioe.getMessage() == null ? "Network error" : ioe.getMessage();
            listener.onError(m, isAuthExpired(ioe));
        } catch (Exception e) {
            String m = e.getMessage() == null ? "Cloud check failed" : e.getMessage();
            listener.onError(m, false);
        } finally {
            synchronized (this) {
                running = null;
            }
        }
    }

    @NonNull
    private static ServerPhotosService.ExistsMatchesResult fetchMatchesWithRetry(@NonNull ServerPhotosService service, @NonNull List<String> backupIds) throws IOException {
        try {
            return service.existsMatchesByBackupIds(backupIds, true);
        } catch (IOException first) {
            if (!isRetryable(first)) throw first;
            try {
                Thread.sleep(700L);
            } catch (InterruptedException ie) {
                Thread.currentThread().interrupt();
                throw first;
            }
            return service.existsMatchesByBackupIds(backupIds, true);
        }
    }

    private static boolean isRetryable(@NonNull IOException e) {
        String m = String.valueOf(e.getMessage()).toLowerCase(Locale.US);
        return m.contains("timed out")
                || m.contains("timeout")
                || m.contains("network")
                || m.contains("connection")
                || m.contains("failed to connect")
                || m.contains("dns");
    }

    private static boolean isAuthExpired(@NonNull IOException e) {
        String m = String.valueOf(e.getMessage()).toLowerCase(Locale.US);
        return m.contains("http 401") || m.contains("unauthorized");
    }

    private static LocalMediaItem findByLocalId(@NonNull List<LocalMediaItem> items, @NonNull String localId) {
        for (LocalMediaItem it : items) {
            if (localId.equals(it.localId)) return it;
        }
        return null;
    }
}
