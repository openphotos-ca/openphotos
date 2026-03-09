import Foundation
import Photos
import Network
import SQLite3

final class SyncService: NSObject {
    static let shared = SyncService()

    private let auth = AuthManager.shared
    private let photoService = PhotoService.shared
    private let uploader = HybridUploadManager.shared
    private let monitor = NWPathMonitor()
    private var isExpensiveNetwork: Bool = false
    private var isRunning = false
    private var pendingSync = false
    private var pendingForceRetryFailed = false
    private var currentRunAssetLocalIdentifiers: Set<String> = []
    private var pendingManualCloudCheckLocalIdentifiers: Set<String> = []
    private var isManualCloudCheckWatcherArmed: Bool = false
    private var isManualCloudCheckRunning: Bool = false
    private var isAutoCloudCheckRunning: Bool = false
    private var pendingAutoCloudCheckLocalIdentifiers: Set<String> = []
    private var syncCompletionVersion: Int64 = 0
    private struct CandidateStats {
        var preNetworkCount: Int = 0
        var postNetworkCount: Int = 0
        var postBackoffCount: Int = 0
    }
    private var lastCandidateStats = CandidateStats()
    private let queue = DispatchQueue(label: "sync.service.queue")
    private let queueSpecificKey = DispatchSpecificKey<Void>()

    private override init() {
        super.init()
        queue.setSpecific(key: queueSpecificKey, value: ())
        monitor.pathUpdateHandler = { [weak self] path in
            self?.isExpensiveNetwork = path.isExpensive
        }
        monitor.start(queue: DispatchQueue(label: "sync.network.monitor"))
    }

    func latestSyncCompletionVersion() -> Int64 {
        if DispatchQueue.getSpecific(key: queueSpecificKey) != nil {
            return syncCompletionVersion
        }
        return queue.sync { syncCompletionVersion }
    }

    func syncOnAppOpen() {
        guard auth.syncEnabledAfterManualStart else { return }
        guard auth.autoStartSyncOnOpen else { return }
        // If user prefers Wi‑Fi only for auto-start and current path is expensive (cellular), skip
        if auth.autoStartWifiOnly && isExpensiveNetwork { return }
        guard auth.isAuthenticated, !auth.serverURL.isEmpty, photoService.hasPermission else { return }
        scheduleSync(reason: "app_open", forceRetryFailed: false)
    }

    func syncOnLibraryChange() {
        guard auth.syncEnabledAfterManualStart else { return }
        guard auth.isAuthenticated, !auth.serverURL.isEmpty, photoService.hasPermission else { return }
        scheduleSync(reason: "library_change", forceRetryFailed: false)
    }

    // Manual trigger from Settings → Sync Now (bypass backoff for failed items).
    // Non-user-initiated callers are blocked until user has explicitly started sync once.
    func syncNow(forceRetryFailed: Bool = true, userInitiated: Bool = false) {
        if !userInitiated && !auth.syncEnabledAfterManualStart {
            return
        }
        if !auth.isAuthenticated {
            Task { [weak self] in
                guard let self else { return }
                let recovered = await self.auth.forceRefresh()
                if recovered {
                    if userInitiated {
                        self.auth.enableSyncAfterManualStart()
                    }
                    self.scheduleSync(
                        reason: userInitiated ? "manual" : "programmatic",
                        forceRetryFailed: forceRetryFailed
                    )
                    return
                }
                DispatchQueue.main.async {
                    ToastManager.shared.show("Please log in to sync your library.")
                    NotificationCenter.default.post(name: .authUnauthorized, object: nil)
                }
            }
            return
        }
        guard !auth.serverURL.isEmpty else {
            DispatchQueue.main.async {
                ToastManager.shared.show("Set a server URL before syncing.")
            }
            return
        }
        guard photoService.hasPermission else {
            DispatchQueue.main.async {
                ToastManager.shared.show("Photo access is required to sync.")
            }
            return
        }
        if userInitiated {
            auth.enableSyncAfterManualStart()
        }
        scheduleSync(
            reason: userInitiated ? "manual" : "programmatic",
            forceRetryFailed: forceRetryFailed
        )
    }

    /// Register a Photos-tab manual sync selection for post-sync cloud-check.
    ///
    /// The check runs only after the uploader becomes idle, and confirmed cloud-backed items
    /// are marked as synced in the local repository.
    func scheduleManualCloudCheckAfterUpload(
        localIdentifiers: Set<String>,
        source: String = "photos-actions"
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            guard !localIdentifiers.isEmpty else { return }
            let before = self.pendingManualCloudCheckLocalIdentifiers.count
            self.pendingManualCloudCheckLocalIdentifiers.formUnion(localIdentifiers)
            let added = max(0, self.pendingManualCloudCheckLocalIdentifiers.count - before)
            print(
                "[PERF] cloud-check-manual-scheduled source=\(source) added_ids=\(added) pending_ids=\(self.pendingManualCloudCheckLocalIdentifiers.count)"
            )
            guard !self.isManualCloudCheckWatcherArmed else { return }
            self.isManualCloudCheckWatcherArmed = true
            self.pollUntilUploaderIdleForManualCloudCheck(source: source)
        }
    }

    private func scheduleSync(reason: String, forceRetryFailed: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.isRunning {
                self.pendingSync = true
                self.pendingForceRetryFailed = self.pendingForceRetryFailed || forceRetryFailed
                return
            }
            self.isRunning = true
            DispatchQueue.main.async {
                ToastManager.shared.show("Preparing sync…", duration: 1.0)
            }
            // Always preflight PIN freshness so any envelope changes are verified
            // before syncing selected albums or the entire library.
            self.uploader.preflightEnsurePinFreshness()
            // Keep selected-albums membership up-to-date before computing candidates
            if self.auth.syncScope == .selectedAlbums {
                DispatchQueue.main.async {
                    ToastManager.shared.show("Refreshing album memberships…", duration: 1.5)
                }
                AlbumService.shared.refreshSystemAlbumMemberships()
            }
            print("[SYNC] buildCandidates start scope=\(self.auth.syncScope.rawValue) includeUnassigned=\(self.auth.syncIncludeUnassigned) forceRetryFailed=\(forceRetryFailed)")
            let assets = self.buildCandidates(forceRetryFailed: forceRetryFailed)
            self.currentRunAssetLocalIdentifiers = Set(assets.map { $0.localIdentifier })
            if assets.isEmpty {
                DispatchQueue.main.async {
                    let stats = self.lastCandidateStats
                    if self.isExpensiveNetwork && stats.preNetworkCount > 0 && stats.postNetworkCount == 0 {
                        ToastManager.shared.show(
                            "Sync paused on cellular. Enable cellular sync to proceed.",
                            duration: 3.0
                        )
                    } else if self.photoService.authorizationStatus == .limited && stats.preNetworkCount == 0 {
                        ToastManager.shared.show(
                            "Nothing to sync. Photo access is limited; new photos may be unavailable.",
                            duration: 3.0
                        )
                    } else if stats.preNetworkCount > 0 && stats.postBackoffCount == 0 {
                        ToastManager.shared.show("Nothing to sync (already synced).", duration: 2.0)
                    } else {
                        ToastManager.shared.show("Nothing to sync.", duration: 2.0)
                    }
                }
                self.finishSyncAndMaybeRerun()
                return
            }
            DispatchQueue.main.async {
                let word = assets.count == 1 ? "item" : "items"
                ToastManager.shared.show("Syncing \(assets.count) \(word)…", duration: 2.0)
            }
            print("[SYNC] reason=\(reason) candidates=\(assets.count) expensive=\(self.isExpensiveNetwork)")
            self.uploader.startUpload(assets: assets)
            self.pollUntilUploaderIdle()
        }
    }

    private func pollUntilUploaderIdle() {
        queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            if self.uploader.isSyncBusy() {
                self.pollUntilUploaderIdle()
                return
            }
            self.finishSyncAndMaybeRerun()
        }
    }

    private func pollUntilUploaderIdleForManualCloudCheck(source: String) {
        queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            if self.uploader.isSyncBusy() {
                self.pollUntilUploaderIdleForManualCloudCheck(source: source)
                return
            }
            self.isManualCloudCheckWatcherArmed = false
            self.consumeManualCloudCheckIfPossible(source: "\(source)-idle")
        }
    }

    private func finishSyncAndMaybeRerun() {
        let completedRunLocalIdentifiers = currentRunAssetLocalIdentifiers
        currentRunAssetLocalIdentifiers = []
        let shouldRerun = pendingSync
        let force = pendingForceRetryFailed
        pendingSync = false
        pendingForceRetryFailed = false
        isRunning = false
        if shouldRerun {
            scheduleSync(reason: "coalesced", forceRetryFailed: force)
            return
        }
        publishSyncRunCompletedLocked()
        scheduleAutoCloudCheckAfterRun(localIdentifiers: completedRunLocalIdentifiers)
    }

    // Must be called on `queue`.
    private func publishSyncRunCompletedLocked() {
        syncCompletionVersion += 1
        let version = syncCompletionVersion
        print("[PERF] sync-run-complete version=\(version)")
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .syncRunCompleted,
                object: nil,
                userInfo: [SyncRunCompletedUserInfoKey.version: NSNumber(value: version)]
            )
        }
    }

    private func scheduleAutoCloudCheckAfterRun(localIdentifiers: Set<String>) {
        let requested = localIdentifiers.count
        guard requested > 0 else {
            print("[PERF] cloud-check-auto-skip reason=no-run-assets requested_ids=0")
            return
        }

        let repo = SyncRepository.shared
        let eligible = Set(localIdentifiers.filter { repo.isLocalIdentifierSynced($0) })
        let eligibleCount = eligible.count
        guard eligibleCount > 0 else {
            print(
                "[PERF] cloud-check-auto-skip reason=no-eligible-assets requested_ids=\(requested) eligible_ids=0"
            )
            return
        }

        if isAutoCloudCheckRunning {
            coalescePendingAutoCloudCheck(ids: eligible, requested: requested)
            return
        }
        startAutoCloudCheck(ids: eligible, source: "sync-idle", requested: requested)
    }

    private func coalescePendingAutoCloudCheck(ids: Set<String>, requested: Int) {
        let before = pendingAutoCloudCheckLocalIdentifiers.count
        pendingAutoCloudCheckLocalIdentifiers.formUnion(ids)
        let added = max(0, pendingAutoCloudCheckLocalIdentifiers.count - before)
        print(
            "[PERF] cloud-check-auto-skip reason=coalesced requested_ids=\(requested) added_ids=\(added) pending_ids=\(pendingAutoCloudCheckLocalIdentifiers.count)"
        )
    }

    private func startAutoCloudCheck(ids: Set<String>, source: String, requested: Int) {
        guard !ids.isEmpty else {
            print(
                "[PERF] cloud-check-auto-skip reason=no-eligible-assets requested_ids=\(requested) eligible_ids=0"
            )
            return
        }
        isAutoCloudCheckRunning = true
        let identifiers = Array(ids)
        let startedAt = Date()
        print(
            "[PERF] cloud-check-auto-start source=\(source) requested_ids=\(requested) eligible_ids=\(identifiers.count)"
        )

        Task.detached(priority: .utility) {
            let assets = SyncService.fetchAssetsByLocalIdentifiers(identifiers)
            let resolvedCount = assets.count
            if resolvedCount == 0 {
                let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000.0)
                SyncService.shared.queue.async {
                    SyncService.shared.finalizeAutoCloudCheckCycle(
                        logLine: "[PERF] cloud-check-auto-skip reason=no-assets-resolved source=\(source) requested_ids=\(requested) eligible_ids=\(identifiers.count) resolved_ids=0 elapsed_ms=\(elapsedMs)"
                    )
                }
                return
            }

            do {
                let result = try await CloudBackupCheckService.shared.runCloudCheck(
                    assets: assets,
                    onProgress: { _, _ in }
                )
                let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000.0)
                SyncService.shared.queue.async {
                    SyncService.shared.finalizeAutoCloudCheckCycle(
                        logLine: "[PERF] cloud-check-auto-done source=\(source) requested_ids=\(requested) eligible_ids=\(identifiers.count) resolved_ids=\(resolvedCount) elapsed_ms=\(elapsedMs) checked=\(result.checked) backed_up=\(result.backedUp) missing=\(result.missing) skipped=\(result.skipped)"
                    )
                }
            } catch {
                let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000.0)
                let msg = error.localizedDescription.replacingOccurrences(of: "\n", with: " ")
                SyncService.shared.queue.async {
                    SyncService.shared.finalizeAutoCloudCheckCycle(
                        logLine: "[PERF] cloud-check-auto-failed source=\(source) requested_ids=\(requested) eligible_ids=\(identifiers.count) resolved_ids=\(resolvedCount) elapsed_ms=\(elapsedMs) error=\(msg)"
                    )
                }
            }
        }
    }

    // Must be called on `queue`.
    private func finalizeAutoCloudCheckCycle(logLine: String) {
        isAutoCloudCheckRunning = false
        print(logLine)
        consumePendingAutoCloudCheckIfNeeded()
        consumeManualCloudCheckIfPossible(source: "after-auto")
    }

    private func consumePendingAutoCloudCheckIfNeeded() {
        guard !isAutoCloudCheckRunning else { return }
        let pending = pendingAutoCloudCheckLocalIdentifiers
        pendingAutoCloudCheckLocalIdentifiers.removeAll(keepingCapacity: true)
        guard !pending.isEmpty else { return }
        startAutoCloudCheck(ids: pending, source: "coalesced", requested: pending.count)
    }

    private func consumeManualCloudCheckIfPossible(source: String) {
        guard !isAutoCloudCheckRunning else { return }
        guard !isManualCloudCheckRunning else { return }
        let pending = pendingManualCloudCheckLocalIdentifiers
        pendingManualCloudCheckLocalIdentifiers.removeAll(keepingCapacity: true)
        guard !pending.isEmpty else { return }
        startManualCloudCheck(ids: pending, source: source)
    }

    private func startManualCloudCheck(ids: Set<String>, source: String) {
        guard !ids.isEmpty else { return }
        isManualCloudCheckRunning = true
        let identifiers = Array(ids)
        let requested = identifiers.count
        let startedAt = Date()
        print(
            "[PERF] cloud-check-manual-start source=\(source) requested_ids=\(requested)"
        )

        Task.detached(priority: .utility) {
            let assets = SyncService.fetchAssetsByLocalIdentifiers(identifiers)
            let resolvedCount = assets.count
            if resolvedCount == 0 {
                let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000.0)
                SyncService.shared.queue.async {
                    SyncService.shared.finalizeManualCloudCheckCycle(
                        logLine: "[PERF] cloud-check-manual-skip reason=no-assets-resolved source=\(source) requested_ids=\(requested) resolved_ids=0 elapsed_ms=\(elapsedMs)"
                    )
                }
                return
            }

            do {
                let result = try await CloudBackupCheckService.shared.runCloudCheck(
                    assets: assets,
                    onProgress: { _, _ in }
                )
                let backedUpLocalIds = SyncRepository.shared.getCloudBackedUpLocalIdentifiers(in: identifiers)
                let markedSynced = SyncRepository.shared.markSyncedForLocalIdentifiers(backedUpLocalIds)
                let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000.0)
                SyncService.shared.queue.async {
                    SyncService.shared.finalizeManualCloudCheckCycle(
                        logLine: "[PERF] cloud-check-manual-done source=\(source) requested_ids=\(requested) resolved_ids=\(resolvedCount) elapsed_ms=\(elapsedMs) checked=\(result.checked) backed_up=\(result.backedUp) missing=\(result.missing) skipped=\(result.skipped) marked_synced=\(markedSynced)"
                    )
                }
            } catch {
                let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000.0)
                let msg = error.localizedDescription.replacingOccurrences(of: "\n", with: " ")
                SyncService.shared.queue.async {
                    SyncService.shared.finalizeManualCloudCheckCycle(
                        logLine: "[PERF] cloud-check-manual-failed source=\(source) requested_ids=\(requested) resolved_ids=\(resolvedCount) elapsed_ms=\(elapsedMs) error=\(msg)"
                    )
                }
            }
        }
    }

    // Must be called on `queue`.
    private func finalizeManualCloudCheckCycle(logLine: String) {
        isManualCloudCheckRunning = false
        print(logLine)
        consumeManualCloudCheckIfPossible(source: "manual-coalesced")
    }

    private func buildCandidates(forceRetryFailed: Bool) -> [PHAsset] {
        let scope = auth.syncScope
        let _ = auth.syncPreserveAlbum
        let photosOnly = auth.syncPhotosOnly
        let allowPhotosOnCell = auth.syncUseCellularPhotos
        let allowVideosOnCell = auth.syncUseCellularVideos

        var stats = CandidateStats()
        var list: [PHAsset]
        if scope == .selectedAlbums {
            // Collect asset IDs from album_photos where album or any ancestor is sync_enabled
            let db = DatabaseManager.shared
            let allowed: [String] = db.executeSelect(
                """
                SELECT DISTINCT ap.asset_id
                FROM album_photos ap
                WHERE EXISTS (
                    SELECT 1 FROM album_closure ac JOIN albums a ON a.id = ac.ancestor_id
                    WHERE ac.descendant_id = ap.album_id AND a.sync_enabled = 1
                )
                """
            ) { stmt in String(cString: sqlite3_column_text(stmt, 0)) }
            let selectedIds = Set(allowed)
            var merged: [PHAsset] = []
            var selectedFetchedCount: Int = 0

            // Targeted fetch to avoid scanning full library for selected-album members.
            if !selectedIds.isEmpty {
                merged = fetchAssetsByLocalIdentifiers(selectedIds)
                selectedFetchedCount = merged.count
            }

            if auth.syncIncludeUnassigned {
                let inAlbum: Set<String> = Set(
                    db.executeSelect("SELECT DISTINCT asset_id FROM album_photos") { stmt in
                        String(cString: sqlite3_column_text(stmt, 0))
                    }
                )
                // Prefer a live PhotoKit snapshot here so newly-created photos are not missed
                // due to a stale in-memory `PhotoService.photos` array.
                let allAssets = snapshotAllAssets(preferLiveFetch: true)
                let unassigned = allAssets.filter { asset in
                    !inAlbum.contains(asset.localIdentifier)
                }
                if !unassigned.isEmpty {
                    var seen = Set(merged.map { $0.localIdentifier })
                    merged.reserveCapacity(merged.count + unassigned.count)
                    for asset in unassigned {
                        if seen.insert(asset.localIdentifier).inserted {
                            merged.append(asset)
                        }
                    }
                }
                print("[SYNC] scope filter (selected + unassigned): selectedAllowed=\(selectedIds.count) selectedFetched=\(selectedFetchedCount) allAssets=\(allAssets.count) inAlbum=\(inAlbum.count) unassigned=\(unassigned.count) total=\(merged.count)")
            } else {
                print("[SYNC] scope filter (selected albums): allowed=\(selectedIds.count) fetched=\(merged.count)")
            }

            if merged.isEmpty {
                stats.preNetworkCount = 0
                stats.postNetworkCount = 0
                stats.postBackoffCount = 0
                lastCandidateStats = stats
                return []
            }
            list = merged
        } else {
            // Snapshot current assets (full library as previously loaded by PhotoService)
            list = photoService.photos
        }

        if photosOnly {
            list = list.filter { $0.mediaType != .video }
            print("[SYNC] photosOnly filter: -> \(list.count)")
        }
        stats.preNetworkCount = list.count

        // Network policy
        if isExpensiveNetwork {
            list = list.filter { asset in
                if asset.mediaType == .video { return allowVideosOnCell }
                else { return allowPhotosOnCell }
            }
            print("[SYNC] network policy filter (cellular): -> \(list.count)")
        }
        stats.postNetworkCount = list.count

        // Filter by DB state, retry backoff, and lock-state mismatch (trigger re-sync if desired != last-synced)
        let repo = SyncRepository.shared
        let now = Int64(Date().timeIntervalSince1970)
        let scopeSelectedOnly = (scope == .selectedAlbums)
        list = list.filter { asset in
            // Determine desired lock state for this asset based on current album selection
            let desiredLocked = AlbumService.shared.isAssetLocked(assetLocalIdentifier: asset.localIdentifier, scopeSelectedOnly: scopeSelectedOnly)
            // Lookup current DB sync state info for this asset
            let info = repo.getSyncInfoForLocalIdentifier(asset.localIdentifier)
            // If last-synced lock differs from desired, force re-sync
            let lastLocked = repo.getLockedForLocalIdentifier(asset.localIdentifier)
            if let lastLocked = lastLocked, lastLocked != desiredLocked {
                return true
            }
            if let info = info {
                // Skip if already synced, uploading, or queued for background
                if info.state == 2 || info.state == 1 || info.state == 4 { return false }
                // For failed, apply backoff unless forced
                if info.state == 3 {
                    if forceRetryFailed { return true }
                    let base: Int64 = 30 // seconds
                    let maxBackoff: Int64 = 3600 // 1 hour
                    let backoff = min(base << min(info.attempts, 10), maxBackoff)
                    return (now - info.lastAttemptAt) >= backoff
                }
            }
            return true
        }
        stats.postBackoffCount = list.count
        lastCandidateStats = stats
        print("[SYNC] backoff filter\(forceRetryFailed ? " (forced)" : ""): -> \(list.count)")
        return list
    }

    // Fetch PHAsset objects by local identifiers in batches to avoid full-library scans and memory spikes.
    private func fetchAssetsByLocalIdentifiers(_ ids: Set<String>, batchSize: Int = 500) -> [PHAsset] {
        Self.fetchAssetsByLocalIdentifiers(Array(ids), batchSize: batchSize)
    }

    // Fetch PHAsset objects by local identifiers in batches to avoid full-library scans and memory spikes.
    private static func fetchAssetsByLocalIdentifiers(_ ids: [String], batchSize: Int = 500) -> [PHAsset] {
        if ids.isEmpty { return [] }
        var result: [PHAsset] = []
        result.reserveCapacity(ids.count)
        var i = 0
        while i < ids.count {
            let end = min(i + batchSize, ids.count)
            let slice = Array(ids[i..<end])
            let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: slice, options: nil)
            fetchResult.enumerateObjects { asset, _, _ in
                result.append(asset)
            }
            i = end
        }
        return result
    }

    private func snapshotAllAssets(preferLiveFetch: Bool = false) -> [PHAsset] {
        if !preferLiveFetch && !photoService.photos.isEmpty {
            return photoService.photos
        }
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        fetchOptions.fetchLimit = 0
        let fetchResult = PHAsset.fetchAssets(with: fetchOptions)
        var assets: [PHAsset] = []
        fetchResult.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
        if assets.isEmpty && !photoService.photos.isEmpty {
            return photoService.photos
        }
        return assets
    }
}
