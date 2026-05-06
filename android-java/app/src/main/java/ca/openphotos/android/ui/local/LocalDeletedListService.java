package ca.openphotos.android.ui.local;

import android.content.Context;

import androidx.annotation.NonNull;

import ca.openphotos.android.core.AuthManager;
import ca.openphotos.android.server.ServerPhotosService;

import java.io.IOException;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.atomic.AtomicBoolean;

/** Dedicated deleted-only local/cloud reconciliation for the Local tab's List Deleted action. */
public final class LocalDeletedListService {
    public interface Listener {
        void onStart(int totalLocalItems, int serverDeletedTotal, boolean serverFirst);
        void onProgress(int processed, int total);
        void onMatchesUpdated(@NonNull Set<String> deletedLocalIds);
        void onFinished(@NonNull Stats stats);
        void onCanceled();
        void onError(@NonNull String message, boolean authExpired);
    }

    public static final class Stats {
        public final int scanned;
        public final int deleted;
        public final int skipped;
        @NonNull public final Set<String> deletedLocalIds;
        @NonNull public final Set<String> scannedLocalIds;
        public final int serverDeletedTotal;
        public final boolean serverFirst;

        public Stats(
                int scanned,
                int deleted,
                int skipped,
                @NonNull Set<String> deletedLocalIds,
                @NonNull Set<String> scannedLocalIds,
                int serverDeletedTotal,
                boolean serverFirst
        ) {
            this.scanned = scanned;
            this.deleted = deleted;
            this.skipped = skipped;
            this.deletedLocalIds = deletedLocalIds;
            this.scannedLocalIds = scannedLocalIds;
            this.serverDeletedTotal = serverDeletedTotal;
            this.serverFirst = serverFirst;
        }
    }

    private static final class Work {
        @NonNull final LocalMediaItem item;
        @NonNull final String fingerprint;
        @NonNull final List<String> cachedCandidates;

        Work(@NonNull LocalMediaItem item, @NonNull String fingerprint, @NonNull List<String> cachedCandidates) {
            this.item = item;
            this.fingerprint = fingerprint;
            this.cachedCandidates = cachedCandidates;
        }
    }

    private static final class PendingMatchWork {
        @NonNull final String localId;
        @NonNull final String fingerprint;
        @NonNull final List<String> candidates;

        PendingMatchWork(@NonNull String localId, @NonNull String fingerprint, @NonNull List<String> candidates) {
            this.localId = localId;
            this.fingerprint = fingerprint;
            this.candidates = candidates;
        }
    }

    private final Context app;
    private final ExecutorService executor = Executors.newSingleThreadExecutor();
    private final AtomicBoolean canceled = new AtomicBoolean(false);
    private Future<?> running;

    public LocalDeletedListService(@NonNull Context app) {
        this.app = app.getApplicationContext();
    }

    public synchronized boolean isRunning() {
        return running != null && !running.isDone();
    }

    public synchronized void cancel() {
        canceled.set(true);
        if (running != null) running.cancel(true);
    }

    public synchronized boolean startScan(
            @NonNull final List<LocalMediaItem> items,
            @NonNull final LocalCloudCacheStore cache,
            @NonNull final Listener listener
    ) {
        if (isRunning()) return false;
        canceled.set(false);
        running = executor.submit(() -> runScan(items, cache, listener));
        return true;
    }

    private void runScan(
            @NonNull List<LocalMediaItem> items,
            @NonNull LocalCloudCacheStore cache,
            @NonNull Listener listener
    ) {
        final int total = items.size();
        int processed = 0;
        int skipped = 0;
        Set<String> deletedLocalIds = new LinkedHashSet<>();
        Set<String> scannedLocalIds = new LinkedHashSet<>();

        try {
            String userId = AuthManager.get(app).getUserId();
            if (userId == null || userId.trim().isEmpty()) {
                listener.onError("Not logged in", true);
                return;
            }

            ArrayList<Work> works = new ArrayList<>(items.size());
            for (LocalMediaItem item : items) {
                if (isCanceled()) {
                    listener.onCanceled();
                    return;
                }
                String fp = BackupIdUtil.fingerprint(item);
                LocalCloudCacheStore.Entry cached = cache.get(item.localId);
                List<String> candidates = (cached != null && fp.equals(cached.fingerprint))
                        ? cached.candidates
                        : java.util.Collections.emptyList();
                works.add(new Work(item, fp, candidates));
            }

            ServerPhotosService service = new ServerPhotosService(app);
            ServerPhotosService.DeletedBackupsPageResult firstPage = fetchDeletedPageWithRetry(service, 1, null);
            int serverDeletedTotal = Math.max(0, firstPage.total);
            boolean serverFirst = serverDeletedTotal <= works.size();
            listener.onStart(total, serverDeletedTotal, serverFirst);

            if (serverDeletedTotal == 0) {
                for (Work work : works) {
                    scannedLocalIds.add(work.item.localId);
                    cache.put(work.item.localId, new LocalCloudCacheStore.Entry(
                            work.fingerprint,
                            work.cachedCandidates,
                            LocalCloudCacheStore.STATE_UNKNOWN,
                            0L
                    ));
                    processed++;
                    listener.onProgress(processed, total);
                }
                listener.onMatchesUpdated(new LinkedHashSet<>(deletedLocalIds));
                listener.onFinished(new Stats(
                        scannedLocalIds.size(),
                        0,
                        skipped,
                        new LinkedHashSet<>(deletedLocalIds),
                        new LinkedHashSet<>(scannedLocalIds),
                        serverDeletedTotal,
                        serverFirst
                ));
                return;
            }

            if (serverFirst) {
                runServerFirst(works, cache, listener, service, userId, firstPage, total, processed, skipped, deletedLocalIds, scannedLocalIds, serverDeletedTotal);
            } else {
                runLocalFirst(works, cache, listener, service, userId, total, processed, skipped, deletedLocalIds, scannedLocalIds, serverDeletedTotal);
            }
        } catch (IOException ioe) {
            String m = ioe.getMessage() == null ? "Network error" : ioe.getMessage();
            listener.onError(m, isAuthExpired(ioe));
        } catch (Exception e) {
            String m = e.getMessage() == null ? "List Deleted failed" : e.getMessage();
            listener.onError(m, false);
        } finally {
            synchronized (this) {
                running = null;
            }
        }
    }

    private void runServerFirst(
            @NonNull List<Work> works,
            @NonNull LocalCloudCacheStore cache,
            @NonNull Listener listener,
            @NonNull ServerPhotosService service,
            @NonNull String userId,
            @NonNull ServerPhotosService.DeletedBackupsPageResult firstPage,
            int total,
            int processed,
            int skipped,
            @NonNull Set<String> deletedLocalIds,
            @NonNull Set<String> scannedLocalIds,
            int serverDeletedTotal
    ) throws Exception {
        java.util.Map<String, Set<String>> localIdsByBackupId = new java.util.HashMap<>();
        ArrayList<Work> uncached = new ArrayList<>();
        for (Work work : works) {
            if (work.cachedCandidates.isEmpty()) {
                uncached.add(work);
                continue;
            }
            scannedLocalIds.add(work.item.localId);
            for (String bid : work.cachedCandidates) {
                localIdsByBackupId.computeIfAbsent(bid, k -> new LinkedHashSet<>()).add(work.item.localId);
            }
        }

        Set<String> deletedBackupIds = new HashSet<>();
        absorbDeletedPage(firstPage.backupIds, deletedBackupIds, localIdsByBackupId, deletedLocalIds, listener);
        String nextAfter = firstPage.nextAfter;
        while (nextAfter != null && !nextAfter.isEmpty()) {
            if (isCanceled()) {
                listener.onCanceled();
                return;
            }
            ServerPhotosService.DeletedBackupsPageResult page = fetchDeletedPageWithRetry(service, 500, nextAfter);
            absorbDeletedPage(page.backupIds, deletedBackupIds, localIdsByBackupId, deletedLocalIds, listener);
            nextAfter = page.nextAfter;
        }

        processed += scannedLocalIds.size();
        listener.onProgress(Math.min(processed, total), total);

        for (Work work : uncached) {
            if (isCanceled()) {
                listener.onCanceled();
                return;
            }
            List<String> computed = BackupIdUtil.computeBackupIdCandidates(app, work.item, userId);
            if (computed.isEmpty()) {
                skipped++;
                processed++;
                listener.onProgress(Math.min(processed, total), total);
                continue;
            }
            scannedLocalIds.add(work.item.localId);
            cache.put(work.item.localId, new LocalCloudCacheStore.Entry(
                    work.fingerprint,
                    computed,
                    deletedBackupIds.contains(computed.get(0))
                            || intersects(computed, deletedBackupIds)
                            ? LocalCloudCacheStore.STATE_DELETED_IN_CLOUD
                            : LocalCloudCacheStore.STATE_UNKNOWN,
                    deletedBackupIds.contains(computed.get(0))
                            || intersects(computed, deletedBackupIds)
                            ? nowSec()
                            : 0L
            ));
            if (intersects(computed, deletedBackupIds) && deletedLocalIds.add(work.item.localId)) {
                listener.onMatchesUpdated(new LinkedHashSet<>(deletedLocalIds));
            }
            processed++;
            listener.onProgress(Math.min(processed, total), total);
        }

        persistNonDeletedUnknown(cache, works, scannedLocalIds, deletedLocalIds);
        listener.onMatchesUpdated(new LinkedHashSet<>(deletedLocalIds));
        listener.onFinished(new Stats(
                scannedLocalIds.size(),
                deletedLocalIds.size(),
                skipped,
                new LinkedHashSet<>(deletedLocalIds),
                new LinkedHashSet<>(scannedLocalIds),
                serverDeletedTotal,
                true
        ));
    }

    private void runLocalFirst(
            @NonNull List<Work> works,
            @NonNull LocalCloudCacheStore cache,
            @NonNull Listener listener,
            @NonNull ServerPhotosService service,
            @NonNull String userId,
            int total,
            int processed,
            int skipped,
            @NonNull Set<String> deletedLocalIds,
            @NonNull Set<String> scannedLocalIds,
            int serverDeletedTotal
    ) throws Exception {
        ArrayList<PendingMatchWork> pending = new ArrayList<>();
        Set<String> pendingIds = new HashSet<>();

        for (Work work : works) {
            if (isCanceled()) {
                listener.onCanceled();
                return;
            }

            List<String> candidates = work.cachedCandidates;
            if (candidates.isEmpty()) {
                candidates = BackupIdUtil.computeBackupIdCandidates(app, work.item, userId);
                if (candidates.isEmpty()) {
                    skipped++;
                    processed++;
                    listener.onProgress(Math.min(processed, total), total);
                    continue;
                }
            }

            pending.add(new PendingMatchWork(work.item.localId, work.fingerprint, candidates));
            pendingIds.addAll(candidates);

            if (pending.size() >= 24 || pendingIds.size() >= 300) {
                processed = flushPendingMatchBatch(
                        cache,
                        listener,
                        service,
                        total,
                        processed,
                        pending,
                        pendingIds,
                        deletedLocalIds,
                        scannedLocalIds
                );
            }
        }

        if (!pending.isEmpty()) {
            processed = flushPendingMatchBatch(
                    cache,
                    listener,
                    service,
                    total,
                    processed,
                    pending,
                    pendingIds,
                    deletedLocalIds,
                    scannedLocalIds
            );
        }

        persistNonDeletedUnknown(cache, works, scannedLocalIds, deletedLocalIds);
        listener.onMatchesUpdated(new LinkedHashSet<>(deletedLocalIds));
        listener.onFinished(new Stats(
                scannedLocalIds.size(),
                deletedLocalIds.size(),
                skipped,
                new LinkedHashSet<>(deletedLocalIds),
                new LinkedHashSet<>(scannedLocalIds),
                serverDeletedTotal,
                false
        ));
    }

    private int flushPendingMatchBatch(
            @NonNull LocalCloudCacheStore cache,
            @NonNull Listener listener,
            @NonNull ServerPhotosService service,
            int total,
            int processed,
            @NonNull List<PendingMatchWork> pending,
            @NonNull Set<String> pendingIds,
            @NonNull Set<String> deletedLocalIds,
            @NonNull Set<String> scannedLocalIds
    ) throws Exception {
        Set<String> deletedIds = matchDeletedWithRetry(service, new ArrayList<>(pendingIds));
        long nowSec = nowSec();
        for (PendingMatchWork work : pending) {
            scannedLocalIds.add(work.localId);
            boolean deleted = intersects(work.candidates, deletedIds);
            cache.put(work.localId, new LocalCloudCacheStore.Entry(
                    work.fingerprint,
                    work.candidates,
                    deleted ? LocalCloudCacheStore.STATE_DELETED_IN_CLOUD : LocalCloudCacheStore.STATE_UNKNOWN,
                    deleted ? nowSec : 0L
            ));
            if (deleted && deletedLocalIds.add(work.localId)) {
                listener.onMatchesUpdated(new LinkedHashSet<>(deletedLocalIds));
            }
        }
        processed += pending.size();
        listener.onProgress(Math.min(processed, total), total);
        pending.clear();
        pendingIds.clear();
        return processed;
    }

    private static void absorbDeletedPage(
            @NonNull List<String> backupIds,
            @NonNull Set<String> deletedBackupIds,
            @NonNull java.util.Map<String, Set<String>> localIdsByBackupId,
            @NonNull Set<String> deletedLocalIds,
            @NonNull Listener listener
    ) {
        boolean changed = false;
        for (String bid : backupIds) {
            if (!deletedBackupIds.add(bid)) continue;
            Set<String> localIds = localIdsByBackupId.get(bid);
            if (localIds == null || localIds.isEmpty()) continue;
            if (deletedLocalIds.addAll(localIds)) changed = true;
        }
        if (changed) {
            listener.onMatchesUpdated(new LinkedHashSet<>(deletedLocalIds));
        }
    }

    private static void persistNonDeletedUnknown(
            @NonNull LocalCloudCacheStore cache,
            @NonNull List<Work> works,
            @NonNull Set<String> scannedLocalIds,
            @NonNull Set<String> deletedLocalIds
    ) {
        for (Work work : works) {
            if (!scannedLocalIds.contains(work.item.localId) || deletedLocalIds.contains(work.item.localId)) {
                continue;
            }
            LocalCloudCacheStore.Entry existing = cache.get(work.item.localId);
            List<String> candidates = existing != null && work.fingerprint.equals(existing.fingerprint)
                    ? existing.candidates
                    : work.cachedCandidates;
            cache.put(work.item.localId, new LocalCloudCacheStore.Entry(
                    work.fingerprint,
                    candidates != null ? candidates : java.util.Collections.emptyList(),
                    LocalCloudCacheStore.STATE_UNKNOWN,
                    0L
            ));
        }
    }

    @NonNull
    private static ServerPhotosService.DeletedBackupsPageResult fetchDeletedPageWithRetry(
            @NonNull ServerPhotosService service,
            int limit,
            @androidx.annotation.Nullable String after
    ) throws IOException {
        try {
            return service.listDeletedBackups(limit, after);
        } catch (IOException first) {
            if (!isRetryable(first)) throw first;
            try {
                Thread.sleep(700L);
            } catch (InterruptedException ie) {
                Thread.currentThread().interrupt();
                throw first;
            }
            return service.listDeletedBackups(limit, after);
        }
    }

    @NonNull
    private static Set<String> matchDeletedWithRetry(
            @NonNull ServerPhotosService service,
            @NonNull List<String> backupIds
    ) throws IOException {
        try {
            return service.matchDeletedBackups(backupIds);
        } catch (IOException first) {
            if (!isRetryable(first)) throw first;
            try {
                Thread.sleep(700L);
            } catch (InterruptedException ie) {
                Thread.currentThread().interrupt();
                throw first;
            }
            return service.matchDeletedBackups(backupIds);
        }
    }

    private boolean isCanceled() {
        return canceled.get() || Thread.currentThread().isInterrupted();
    }

    private static long nowSec() {
        return System.currentTimeMillis() / 1000L;
    }

    private static boolean intersects(@NonNull List<String> candidates, @NonNull Set<String> values) {
        for (String candidate : candidates) {
            if (values.contains(candidate)) return true;
        }
        return false;
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
}
