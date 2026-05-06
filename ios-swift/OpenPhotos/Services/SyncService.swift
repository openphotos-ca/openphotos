import Foundation
import Photos
import Network
import SQLite3
import UIKit
import BackgroundTasks

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
    private var currentRunWasUserInitiated = false
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
    private var resumeInterruptedRunOnForeground = false
    private var resumeInterruptedRunWasUserInitiated = false
    private var isSceneBackgrounded = false
    private var suppressAutomaticResumeUntilNextUserInitiatedSync = false

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

    private func syncQueueSync<T>(_ block: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueSpecificKey) != nil {
            return block()
        }
        return queue.sync(execute: block)
    }

    func resolveAssetsForCurrentSyncScope(preferLiveFetch: Bool = true) -> [PHAsset] {
        if auth.syncScope != .selectedAlbums {
            return snapshotAllAssets(preferLiveFetch: preferLiveFetch)
        }

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
        if !selectedIds.isEmpty {
            merged = fetchAssetsByLocalIdentifiers(selectedIds)
        }

        if auth.syncIncludeUnassigned {
            let inAlbum: Set<String> = Set(
                db.executeSelect("SELECT DISTINCT asset_id FROM album_photos") { stmt in
                    String(cString: sqlite3_column_text(stmt, 0))
                }
            )
            let allAssets = snapshotAllAssets(preferLiveFetch: preferLiveFetch)
            if merged.isEmpty {
                merged.reserveCapacity(allAssets.count)
            }
            var seen = Set(merged.map { $0.localIdentifier })
            for asset in allAssets where !inAlbum.contains(asset.localIdentifier) {
                if seen.insert(asset.localIdentifier).inserted {
                    merged.append(asset)
                }
            }
        }

        return merged
    }

    func syncOnAppOpen() {
        guard auth.syncEnabledAfterManualStart else { return }
        guard auth.autoStartSyncOnOpen else { return }
        guard !isAutomaticResumeSuppressed() else {
            print("[SYNC] app-open auto-sync skipped reason=user-stop-suppressed")
            return
        }
        // If user prefers Wi‑Fi only for auto-start and current path is expensive (cellular), skip
        if auth.autoStartWifiOnly && isExpensiveNetwork { return }
        guard auth.isAuthenticated, !auth.serverURL.isEmpty, photoService.hasPermission else { return }
        scheduleSync(reason: "app_open", forceRetryFailed: false, userInitiated: true)
    }

    func syncOnLibraryChange() {
        guard auth.syncEnabledAfterManualStart else { return }
        guard !isAutomaticResumeSuppressed() else {
            print("[SYNC] library-change auto-sync skipped reason=user-stop-suppressed")
            return
        }
        guard auth.isAuthenticated, !auth.serverURL.isEmpty, photoService.hasPermission else { return }
        scheduleSync(reason: "library_change", forceRetryFailed: false)
    }

    func registerBackgroundTasksIfNeeded() {
        if #available(iOS 26.0, *) {
            SyncContinuedProcessingController.shared.registerIfNeeded()
        }
    }

    @discardableResult
    func handleSceneDidEnterBackground() -> Bool {
        syncQueueSync {
            isSceneBackgrounded = true
            if #available(iOS 26.0, *), !isRunning, SyncContinuedProcessingController.shared.isArmedOrActive {
                print("[SYNC] scene-background preserving pending user sync with BGContinuedProcessingTask")
                return false
            }
            guard isRunning else { return true }
            if shouldKeepForegroundSyncRunningInBackgroundLocked() {
                print(
                    "[SYNC] scene-background continuing foreground sync with BGContinuedProcessingTask current_run_assets=\(currentRunAssetLocalIdentifiers.count)"
                )
                return false
            }
            resumeInterruptedRunOnForeground = true
            resumeInterruptedRunWasUserInitiated = currentRunWasUserInitiated
            print(
                "[SYNC] scene-background marked foreground resume pending current_run_assets=\(currentRunAssetLocalIdentifiers.count)"
            )
            return true
        }
    }

    func noteSceneDidBecomeActive() {
        queue.async { [weak self] in
            self?.isSceneBackgrounded = false
        }
    }

    @discardableResult
    func resumeSyncIfNeededOnForeground() -> Bool {
        guard auth.syncEnabledAfterManualStart else { return false }
        guard auth.isAuthenticated, !auth.serverURL.isEmpty, photoService.hasPermission else { return false }
        let suppressed = syncQueueSync { () -> Bool in
            guard suppressAutomaticResumeUntilNextUserInitiatedSync else { return false }
            resumeInterruptedRunOnForeground = false
            resumeInterruptedRunWasUserInitiated = false
            return true
        }
        if suppressed { return false }

        enum ResumeAction {
            case none
            case coalesced
            case start
        }

        let result: (ResumeAction, Bool) = syncQueueSync {
            guard resumeInterruptedRunOnForeground else { return (.none, false) }
            let resumeWasUserInitiated = resumeInterruptedRunWasUserInitiated
            resumeInterruptedRunOnForeground = false
            resumeInterruptedRunWasUserInitiated = false
            if isRunning {
                pendingSync = true
                currentRunWasUserInitiated = currentRunWasUserInitiated || resumeWasUserInitiated
                print(
                    "[SYNC] foreground-resume coalesced current_run_assets=\(currentRunAssetLocalIdentifiers.count)"
                )
                return (.coalesced, resumeWasUserInitiated)
            }
            print("[SYNC] foreground-resume starting new run")
            return (.start, resumeWasUserInitiated)
        }

        switch result.0 {
        case .none:
            return false
        case .coalesced:
            if result.1 {
                submitContinuedProcessingTaskIfPossible()
            }
            return true
        case .start:
            scheduleSync(
                reason: "foreground_resume",
                forceRetryFailed: false,
                userInitiated: result.1
            )
            return true
        }
    }

    func isSyncBusyOrPendingResume() -> Bool {
        if uploader.isSyncBusy() { return true }
        return syncQueueSync { isRunning || resumeInterruptedRunOnForeground }
    }

    func isAutomaticResumeSuppressed() -> Bool {
        syncQueueSync { suppressAutomaticResumeUntilNextUserInitiatedSync }
    }

    func stopCurrentSync(systemCancelled: Bool = false) {
        let stopSnapshot = syncQueueSync {
            (
                isRunning: isRunning,
                resumeInterruptedRunOnForeground: resumeInterruptedRunOnForeground,
                pendingSync: pendingSync,
                pendingForceRetryFailed: pendingForceRetryFailed,
                currentRunWasUserInitiated: currentRunWasUserInitiated,
                currentRunAssets: currentRunAssetLocalIdentifiers.count,
                isSceneBackgrounded: isSceneBackgrounded
            )
        }
        let uploaderBusyBeforeStop = uploader.isSyncBusy()
        print(
            "[SYNC] stopCurrentSync requested system_cancelled=\(systemCancelled ? 1 : 0) " +
            "is_running=\(stopSnapshot.isRunning ? 1 : 0) " +
            "resume_pending=\(stopSnapshot.resumeInterruptedRunOnForeground ? 1 : 0) " +
            "pending_sync=\(stopSnapshot.pendingSync ? 1 : 0) " +
            "pending_force_retry=\(stopSnapshot.pendingForceRetryFailed ? 1 : 0) " +
            "user_initiated=\(stopSnapshot.currentRunWasUserInitiated ? 1 : 0) " +
            "current_run_assets=\(stopSnapshot.currentRunAssets) " +
            "backgrounded=\(stopSnapshot.isSceneBackgrounded ? 1 : 0) " +
            "uploader_busy=\(uploaderBusyBeforeStop ? 1 : 0)"
        )
        let enabledManualStopSuppression = syncQueueSync {
            // A stop from the BGContinuedProcessing UI is still an explicit user stop.
            // Suppress automatic resume so the sync does not restart behind the lock screen.
            let shouldSuppress = true
            let changed = shouldSuppress && !suppressAutomaticResumeUntilNextUserInitiatedSync
            isRunning = false
            resumeInterruptedRunOnForeground = false
            resumeInterruptedRunWasUserInitiated = false
            pendingSync = false
            pendingForceRetryFailed = false
            currentRunAssetLocalIdentifiers = []
            currentRunWasUserInitiated = false
            if shouldSuppress {
                suppressAutomaticResumeUntilNextUserInitiatedSync = true
            }
            return changed
        }
        if enabledManualStopSuppression {
            print("[SYNC] automatic foreground resume suppressed until next manual sync")
        }
        if #available(iOS 26.0, *) {
            SyncContinuedProcessingController.shared.finishIfNeeded(
                // Mark continued-processing user stops as successful cleanup. Reporting
                // `false` makes iOS keep a persistent "task failed" chip.
                success: true,
                reason: systemCancelled ? "system-user-cancel" : "user-stop",
                terminalTitle: "Sync stopped",
                terminalSubtitle: "Uploads canceled"
            )
        }
        uploader.stopCurrentSync()
        print(
            "[SYNC] stopCurrentSync dispatched system_cancelled=\(systemCancelled ? 1 : 0) " +
            "uploader_busy_after_dispatch=\(uploader.isSyncBusy() ? 1 : 0)"
        )
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
                let recovered = await self.auth.recoverSessionIfPossible(ignoreAutoLoginCooldown: true)
                if recovered {
                    if userInitiated {
                        self.auth.enableSyncAfterManualStart()
                    }
                    self.scheduleSync(
                        reason: userInitiated ? "manual" : "programmatic",
                        forceRetryFailed: forceRetryFailed,
                        userInitiated: userInitiated
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
            let clearedSuppression = syncQueueSync {
                let wasSuppressed = suppressAutomaticResumeUntilNextUserInitiatedSync
                suppressAutomaticResumeUntilNextUserInitiatedSync = false
                return wasSuppressed
            }
            if clearedSuppression {
                print("[SYNC] manual sync cleared automatic foreground-resume suppression")
            }
        }
        if DispatchQueue.getSpecific(key: queueSpecificKey) == nil {
            queue.async { [weak self] in
                self?.syncNow(forceRetryFailed: forceRetryFailed, userInitiated: userInitiated)
            }
            return
        }
        scheduleSync(
            reason: userInitiated ? "manual" : "programmatic",
            forceRetryFailed: forceRetryFailed,
            userInitiated: userInitiated
        )
    }

    private func submitContinuedProcessingTaskIfPossible() {
        guard #available(iOS 26.0, *) else { return }
        SyncContinuedProcessingController.shared.submitIfPossible()
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

    private func scheduleSync(reason: String, forceRetryFailed: Bool, userInitiated: Bool = false) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.isRunning {
                self.pendingSync = true
                self.pendingForceRetryFailed = self.pendingForceRetryFailed || forceRetryFailed
                self.currentRunWasUserInitiated = self.currentRunWasUserInitiated || userInitiated
                if userInitiated {
                    self.submitContinuedProcessingTaskIfPossible()
                }
                return
            }
            self.isRunning = true
            self.currentRunWasUserInitiated = userInitiated
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
                let refreshed = AlbumService.shared.refreshSystemAlbumMembershipsIfNeeded(minInterval: 30)
                if !refreshed {
                    print("[SYNC] selected-album membership refresh skipped reason=recent")
                }
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
            if userInitiated {
                self.submitContinuedProcessingTaskIfPossible()
            }
            print("[SYNC] reason=\(reason) candidates=\(assets.count) expensive=\(self.isExpensiveNetwork)")
            self.uploader.startUpload(assets: assets)
            self.pollUntilUploaderIdle()
        }
    }

    func handleContinuedProcessingTaskActivated() {
        queue.async { [weak self] in
            guard let self else { return }
            print(
                "[SYNC] continued-processing activated is_running=\(self.isRunning ? 1 : 0) current_run_assets=\(self.currentRunAssetLocalIdentifiers.count)"
            )
        }
    }

    func handleContinuedProcessingExpiration() {
        let snapshot = continuedProcessingProgressSnapshot()
        let shouldReportCompletedTail = isNearCompletedBackgroundTail(snapshot)
        let expirationOutcome: (isBackgrounded: Bool, shouldHandoffToBackgroundUploads: Bool) = syncQueueSync {
            guard isRunning || uploader.isSyncBusy() else {
                print("[SYNC] continued-processing expired with no active sync work")
                return (false, false)
            }
            if isSceneBackgrounded {
                resumeInterruptedRunOnForeground = true
                resumeInterruptedRunWasUserInitiated = currentRunWasUserInitiated
            }
            print(
                "[SYNC] continued-processing expired backgrounded=\(isSceneBackgrounded ? 1 : 0) current_run_assets=\(currentRunAssetLocalIdentifiers.count)"
            )
            return (isSceneBackgrounded, isSceneBackgrounded && !shouldReportCompletedTail)
        }

        if expirationOutcome.shouldHandoffToBackgroundUploads {
            print("[SYNC] continued-processing expiration handoff=background-multipart")
            DispatchQueue.main.async {
                HybridUploadManager.shared.switchToBackgroundUploads()
            }
        }

        if #available(iOS 26.0, *) {
            SyncContinuedProcessingController.shared.finishIfNeeded(
                success: true,
                reason: shouldReportCompletedTail
                    ? "expiration-near-complete"
                    : (expirationOutcome.shouldHandoffToBackgroundUploads
                        ? "expiration-background-continue"
                        : (expirationOutcome.isBackgrounded ? "expiration-pause" : "expiration-foreground")),
                terminalTitle: shouldReportCompletedTail
                    ? "Sync complete"
                    : (expirationOutcome.shouldHandoffToBackgroundUploads
                        ? "Syncing photos"
                        : (expirationOutcome.isBackgrounded ? "Sync paused" : "Syncing photos")),
                terminalSubtitle: shouldReportCompletedTail
                    ? "Uploads finished"
                    : (expirationOutcome.shouldHandoffToBackgroundUploads
                        ? "Continuing uploads"
                        : (expirationOutcome.isBackgrounded ? "Open app to continue" : "Continuing in app"))
            )
        }
    }

    func handleContinuedProcessingNearCompletion() {
        let shouldHandoffToBackgroundUploads: Bool = syncQueueSync {
            guard isSceneBackgrounded else { return false }
            guard isRunning || uploader.isSyncBusy() else { return false }
            resumeInterruptedRunOnForeground = true
            resumeInterruptedRunWasUserInitiated = currentRunWasUserInitiated
            print(
                "[SYNC] continued-processing near-complete handoff current_run_assets=\(currentRunAssetLocalIdentifiers.count)"
            )
            return true
        }

        guard shouldHandoffToBackgroundUploads else { return }
        DispatchQueue.main.async {
            HybridUploadManager.shared.switchToBackgroundUploads()
        }

        if #available(iOS 26.0, *) {
            SyncContinuedProcessingController.shared.finishIfNeeded(
                success: true,
                reason: "near-complete-background-handoff",
                terminalTitle: "Syncing photos",
                terminalSubtitle: "Continuing uploads"
            )
        }
    }

    fileprivate func continuedProcessingProgressSnapshot() -> SyncContinuedProcessingProgressSnapshot {
        let state = syncQueueSync {
            (
                plannedIdentifiers: currentRunAssetLocalIdentifiers,
                isRunning: isRunning,
                isBackgrounded: isSceneBackgrounded
            )
        }

        guard !state.plannedIdentifiers.isEmpty else {
            return SyncContinuedProcessingProgressSnapshot(
                plannedAssets: 0,
                completedMilliUnits: 0,
                terminalAssets: 0,
                activeAssets: uploader.isSyncBusy() ? 1 : 0,
                verifyingAssets: 0,
                pendingAssets: 0,
                isRunning: state.isRunning,
                isBackgrounded: state.isBackgrounded
            )
        }

        let uploadSnapshot = uploader.continuedProcessingProgressSnapshot(
            for: state.plannedIdentifiers
        )
        return SyncContinuedProcessingProgressSnapshot(
            plannedAssets: state.plannedIdentifiers.count,
            completedMilliUnits: uploadSnapshot.completedMilliUnits,
            terminalAssets: uploadSnapshot.terminalAssets,
            activeAssets: uploadSnapshot.activeAssets,
            verifyingAssets: uploadSnapshot.verifyingAssets,
            pendingAssets: uploadSnapshot.pendingAssets,
            isRunning: state.isRunning,
            isBackgrounded: state.isBackgrounded
        )
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

    private func shouldKeepForegroundSyncRunningInBackgroundLocked() -> Bool {
        guard currentRunWasUserInitiated else { return false }
        guard #available(iOS 26.0, *) else { return false }
        return SyncContinuedProcessingController.shared.isArmedOrActive
    }

    private func finishSyncAndMaybeRerun() {
        let completedRunLocalIdentifiers = currentRunAssetLocalIdentifiers
        currentRunAssetLocalIdentifiers = []
        let shouldRerun = pendingSync
        let force = pendingForceRetryFailed
        let wasUserInitiated = currentRunWasUserInitiated
        pendingSync = false
        pendingForceRetryFailed = false
        isRunning = false
        currentRunWasUserInitiated = false
        if resumeInterruptedRunOnForeground {
            let stats = SyncRepository.shared.getStats(
                scope: auth.syncScope,
                includeUnassigned: auth.syncIncludeUnassigned,
                photosOnly: auth.syncPhotosOnly
            )
            if stats.pending == 0 && stats.uploading == 0 && stats.bgQueued == 0 {
                resumeInterruptedRunOnForeground = false
                resumeInterruptedRunWasUserInitiated = false
                print("[SYNC] cleared pending foreground resume after sync completed")
            }
        }
        if shouldRerun {
            scheduleSync(
                reason: "coalesced",
                forceRetryFailed: force,
                userInitiated: wasUserInitiated
            )
            return
        }
        if #available(iOS 26.0, *), wasUserInitiated {
            SyncContinuedProcessingController.shared.finishIfNeeded(
                success: true,
                reason: "sync-complete"
            )
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
                        logLine: "[PERF] cloud-check-auto-done source=\(source) requested_ids=\(requested) eligible_ids=\(identifiers.count) resolved_ids=\(resolvedCount) elapsed_ms=\(elapsedMs) checked=\(result.checked) backed_up=\(result.backedUp) deleted=\(result.deleted) missing=\(result.missing) skipped=\(result.skipped) duplicate_groups=\(result.duplicateGroups) duplicate_excess=\(result.duplicateExcess)"
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
                let deletedLocalIds = SyncRepository.shared.getCloudDeletedLocalIdentifiers(in: identifiers)
                let markedSynced = SyncRepository.shared.markSyncedForLocalIdentifiers(
                    backedUpLocalIds.union(deletedLocalIds)
                )
                let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000.0)
                SyncService.shared.queue.async {
                    SyncService.shared.finalizeManualCloudCheckCycle(
                        logLine: "[PERF] cloud-check-manual-done source=\(source) requested_ids=\(requested) resolved_ids=\(resolvedCount) elapsed_ms=\(elapsedMs) checked=\(result.checked) backed_up=\(result.backedUp) deleted=\(result.deleted) missing=\(result.missing) skipped=\(result.skipped) duplicate_groups=\(result.duplicateGroups) duplicate_excess=\(result.duplicateExcess) marked_synced=\(markedSynced)"
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

        func appendSample(_ samples: inout [String], _ value: String) {
            guard samples.count < 8 else { return }
            samples.append(value)
        }

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
            if currentRunWasUserInitiated {
                let liveAssets = snapshotAllAssets(preferLiveFetch: true)
                let cachedIds = Set(list.map(\.localIdentifier))
                let liveIds = Set(liveAssets.map(\.localIdentifier))
                let onlyLive = Array(liveIds.subtracting(cachedIds).prefix(8))
                let onlyCached = Array(cachedIds.subtracting(liveIds).prefix(8))
                print(
                    "[SYNC] candidate-universe cached_assets=\(list.count) live_assets=\(liveAssets.count) " +
                    "delta=\(liveAssets.count - list.count) photos_only=\(photosOnly ? 1 : 0) " +
                    "sample_only_live=\(onlyLive.joined(separator: ",")) " +
                    "sample_only_cached=\(onlyCached.joined(separator: ","))"
                )
            }
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
        var syncedExcluded = 0
        var uploadingExcluded = 0
        var backgroundQueuedExcluded = 0
        var backoffExcluded = 0
        var lockStateMismatchIncluded = 0
        var syncedSamples: [String] = []
        var uploadingSamples: [String] = []
        var backgroundQueuedSamples: [String] = []
        var backoffSamples: [String] = []
        var filtered: [PHAsset] = []
        filtered.reserveCapacity(list.count)

        for asset in list {
            // Determine desired lock state for this asset based on current album selection
            let desiredLocked = AlbumService.shared.isAssetLocked(assetLocalIdentifier: asset.localIdentifier, scopeSelectedOnly: scopeSelectedOnly)
            // Lookup current DB sync state info for this asset
            let info = repo.getSyncInfoForLocalIdentifier(asset.localIdentifier)
            // If last-synced lock differs from desired, force re-sync
            let lastLocked = repo.getLockedForLocalIdentifier(asset.localIdentifier)
            if let lastLocked = lastLocked, lastLocked != desiredLocked {
                lockStateMismatchIncluded += 1
                filtered.append(asset)
                continue
            }
            if let info = info {
                // Skip if already synced, uploading, or queued for background
                if info.state == 2 {
                    syncedExcluded += 1
                    appendSample(&syncedSamples, asset.localIdentifier)
                    continue
                }
                if info.state == 1 {
                    uploadingExcluded += 1
                    appendSample(&uploadingSamples, asset.localIdentifier)
                    continue
                }
                if info.state == 4 {
                    backgroundQueuedExcluded += 1
                    appendSample(&backgroundQueuedSamples, asset.localIdentifier)
                    continue
                }
                // For failed, apply backoff unless forced
                if info.state == 3 {
                    if forceRetryFailed {
                        filtered.append(asset)
                        continue
                    }
                    let base: Int64 = 30 // seconds
                    let maxBackoff: Int64 = 3600 // 1 hour
                    let backoff = min(base << min(info.attempts, 10), maxBackoff)
                    if (now - info.lastAttemptAt) < backoff {
                        backoffExcluded += 1
                        let remaining = max(0, backoff - (now - info.lastAttemptAt))
                        appendSample(&backoffSamples, "\(asset.localIdentifier):\(remaining)s")
                        continue
                    }
                }
            }
            filtered.append(asset)
        }
        list = filtered
        stats.postBackoffCount = list.count
        lastCandidateStats = stats
        print(
            "[SYNC] candidate-filter summary input=\(stats.postNetworkCount) kept=\(list.count) " +
            "synced_excluded=\(syncedExcluded) uploading_excluded=\(uploadingExcluded) " +
            "bg_excluded=\(backgroundQueuedExcluded) backoff_excluded=\(backoffExcluded) " +
            "lock_mismatch_included=\(lockStateMismatchIncluded)"
        )
        if !syncedSamples.isEmpty {
            print("[SYNC] candidate-filter sample_synced_excluded=\(syncedSamples.joined(separator: ","))")
        }
        if !uploadingSamples.isEmpty {
            print("[SYNC] candidate-filter sample_uploading_excluded=\(uploadingSamples.joined(separator: ","))")
        }
        if !backgroundQueuedSamples.isEmpty {
            print("[SYNC] candidate-filter sample_bg_excluded=\(backgroundQueuedSamples.joined(separator: ","))")
        }
        if !backoffSamples.isEmpty {
            print("[SYNC] candidate-filter sample_backoff_excluded=\(backoffSamples.joined(separator: ","))")
        }
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

fileprivate struct SyncContinuedProcessingProgressSnapshot {
    let plannedAssets: Int
    let completedMilliUnits: Int64
    let terminalAssets: Int
    let activeAssets: Int
    let verifyingAssets: Int
    let pendingAssets: Int
    let isRunning: Bool
    let isBackgrounded: Bool
}

fileprivate func isNearCompletedBackgroundTail(
    _ snapshot: SyncContinuedProcessingProgressSnapshot
) -> Bool {
    guard snapshot.isBackgrounded else { return false }
    guard snapshot.plannedAssets > 0 else { return false }
    guard snapshot.activeAssets == 0 else { return false }
    guard snapshot.pendingAssets == 0 else { return false }
    guard snapshot.verifyingAssets > 0 else { return false }
    return snapshot.terminalAssets >= max(0, snapshot.plannedAssets - 1)
}

@available(iOS 26.0, *)
private final class SyncContinuedProcessingController {
    static let shared = SyncContinuedProcessingController()

    private static let taskSemanticContext = "sync.continued"
    private static let persistedOutstandingIdentifiersDefaultsKey = "sync.continued.outstandingIdentifiers"
    private let stateQueue = DispatchQueue(label: "sync.continued.processing.state")
    private var registeredIdentifiers: Set<String> = []
    private var isArmed = false
    private var pendingRequestIdentifier: String?
    private var activeTask: BGContinuedProcessingTask?
    private var progressWorkBridge: Progress?
    private var progressTimer: DispatchSourceTimer?
    private var taskProgressCancelledObserver: NSKeyValueObservation?
    private var taskProgressPausedObserver: NSKeyValueObservation?
    private var childProgressCancelledObserver: NSKeyValueObservation?
    private var childProgressPausedObserver: NSKeyValueObservation?
    private var maxCompletedUnitCount: Int64 = 0
    private var lastSubtitle: String = ""
    private var lastProgressAdvanceUptime: TimeInterval = 0
    private var noWorkObservedSinceUptime: TimeInterval?
    private var nearCompletionHandoffRequested = false
    private var progressCancellationHandled = false
    private let keepAliveProgressIntervalSeconds: TimeInterval = 15.0
    private let keepAliveProgressMaxLeadUnits: Int64 = 120
    private let idleNoWorkCompletionDelaySeconds: TimeInterval = 3.0

    var isArmedOrActive: Bool {
        stateQueue.sync { isArmed || activeTask != nil }
    }

    private static func requestIdentifierPrefix() -> String? {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier, !bundleIdentifier.isEmpty else {
            return nil
        }
        return "\(bundleIdentifier).\(taskSemanticContext)"
    }

    private static func matchesTaskSemanticContext(identifier: String) -> Bool {
        guard let prefix = requestIdentifierPrefix() else { return false }
        return identifier == prefix || identifier.hasPrefix(prefix + ".")
    }

    private static func makeRequestIdentifier() -> String? {
        guard let prefix = requestIdentifierPrefix() else { return nil }
        return "\(prefix).\(UUID().uuidString.lowercased())"
    }

    func registerIfNeeded() {
        restoreOutstandingRequestRegistrations()
    }

    private func registerLaunchHandlerIfNeeded(for identifier: String) -> Bool {
        stateQueue.sync {
            if registeredIdentifiers.contains(identifier) {
                return true
            }
            let registered = BGTaskScheduler.shared.register(
                forTaskWithIdentifier: identifier,
                using: stateQueue
            ) { [weak self] task in
                guard let self, let task = task as? BGContinuedProcessingTask else {
                    print("[SYNC] continued-processing launch-handler received unexpected task type")
                    task.setTaskCompleted(success: true)
                    return
                }
                print("[SYNC] continued-processing launch-handler start identifier=\(task.identifier)")
                self.activate(task)
            }
            if registered {
                registeredIdentifiers.insert(identifier)
            } else {
                print("[SYNC] continued-processing register failed identifier=\(identifier)")
            }
            return registered
        }
    }

    func submitIfPossible() {
        DispatchQueue.main.async { [weak self] in
            self?.submitIfPossibleOnMainThread()
        }
    }

    private func submitIfPossibleOnMainThread() {
        let appState = UIApplication.shared.applicationState
        guard appState != .background else {
            print("[SYNC] continued-processing submit skipped app_state=\(appState.rawValue)")
            return
        }

        let shouldSubmit = stateQueue.sync { () -> Bool in
            if activeTask != nil || isArmed {
                return false
            }
            isArmed = true
            pendingRequestIdentifier = nil
            maxCompletedUnitCount = 0
            lastSubtitle = ""
            lastProgressAdvanceUptime = ProcessInfo.processInfo.systemUptime
            noWorkObservedSinceUptime = nil
            nearCompletionHandoffRequested = false
            progressCancellationHandled = false
            return true
        }
        guard shouldSubmit else { return }

        purgeOutstandingRequests(reason: "pre-submit") { [weak self] in
            self?.submitPreparedRequest()
        }
    }

    func finishIfNeeded(
        success: Bool,
        reason: String,
        terminalTitle: String? = nil,
        terminalSubtitle: String? = nil
    ) {
        stateQueue.async {
            self.finishLocked(
                success: success,
                reason: reason,
                terminalTitle: terminalTitle,
                terminalSubtitle: terminalSubtitle
            )
        }
    }

    @discardableResult
    private func finishLocked(
        success: Bool,
        reason: String,
        terminalTitle: String? = nil,
        terminalSubtitle: String? = nil
    ) -> Bool {
        guard isArmed || activeTask != nil else { return false }
        stopProgressTimerLocked()
        let pendingRequestIdentifier = self.pendingRequestIdentifier
        let activeTaskIdentifier = self.activeTask?.identifier
        if let task = activeTask {
            clearProgressObserversLocked()
            task.progress.cancellationHandler = nil
            task.progress.pausingHandler = nil
            task.progress.resumingHandler = nil
            progressWorkBridge?.cancellationHandler = nil
            progressWorkBridge?.pausingHandler = nil
            progressWorkBridge?.resumingHandler = nil
            if success, let workBridge = progressWorkBridge {
                let total = max(1, workBridge.totalUnitCount)
                workBridge.totalUnitCount = total
                task.progress.totalUnitCount = total
                if reason == "sync-complete" || reason == "idle-no-work" {
                    workBridge.completedUnitCount = total
                    task.progress.completedUnitCount = total
                } else {
                    let completed = min(workBridge.completedUnitCount, total)
                    workBridge.completedUnitCount = completed
                    task.progress.completedUnitCount = min(task.progress.completedUnitCount, total)
                }
            }
            if let terminalTitle, let terminalSubtitle {
                task.updateTitle(terminalTitle, subtitle: terminalSubtitle)
            } else if success {
                task.updateTitle("Sync complete", subtitle: "Uploads finished")
            }
            task.setTaskCompleted(success: success)
        }
        let identifiersToClear = Set([pendingRequestIdentifier, activeTaskIdentifier].compactMap { $0 })
        for identifier in identifiersToClear {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
            registeredIdentifiers.remove(identifier)
        }
        removePersistedOutstandingRequestIdentifiers(identifiersToClear)
        activeTask = nil
        progressWorkBridge = nil
        isArmed = false
        self.pendingRequestIdentifier = nil
        maxCompletedUnitCount = 0
        lastSubtitle = ""
        lastProgressAdvanceUptime = 0
        noWorkObservedSinceUptime = nil
        nearCompletionHandoffRequested = false
        progressCancellationHandled = false
        let titleLog = terminalTitle ?? (success ? "Sync complete" : "(none)")
        let subtitleLog = terminalSubtitle ?? (success ? "Uploads finished" : "(none)")
        print(
            "[SYNC] continued-processing finish success=\(success ? 1 : 0) reason=\(reason) title=\(titleLog) subtitle=\(subtitleLog)"
        )
        return true
    }

    private func submitPreparedRequest() {
        guard let requestIdentifier = Self.makeRequestIdentifier() else {
            stateQueue.sync {
                self.isArmed = false
                self.pendingRequestIdentifier = nil
            }
            print("[SYNC] continued-processing submit failed reason=missing-bundle-identifier")
            return
        }

        guard registerLaunchHandlerIfNeeded(for: requestIdentifier) else {
            stateQueue.sync {
                self.isArmed = false
                self.pendingRequestIdentifier = nil
            }
            print("[SYNC] continued-processing submit aborted identifier=\(requestIdentifier)")
            return
        }

        let request = BGContinuedProcessingTaskRequest(
            identifier: requestIdentifier,
            title: "Syncing photos",
            subtitle: "Preparing uploads"
        )
        request.strategy = .queue

        do {
            try BGTaskScheduler.shared.submit(request)
            stateQueue.sync {
                self.pendingRequestIdentifier = requestIdentifier
                self.persistOutstandingRequestIdentifier(requestIdentifier)
            }
            print("[SYNC] continued-processing submit ok identifier=\(requestIdentifier)")
        } catch {
            stateQueue.sync {
                self.isArmed = false
                self.pendingRequestIdentifier = nil
                self.registeredIdentifiers.remove(requestIdentifier)
                self.removePersistedOutstandingRequestIdentifiers([requestIdentifier])
            }
            print("[SYNC] continued-processing submit failed identifier=\(requestIdentifier) error=\(error.localizedDescription)")
        }
    }

    private func purgeOutstandingRequests(reason: String, completion: (() -> Void)? = nil) {
        BGTaskScheduler.shared.getPendingTaskRequests { [weak self] requests in
            guard let self else {
                completion?()
                return
            }

            let pendingIdentifiers = requests
                .map(\.identifier)
                .filter(Self.matchesTaskSemanticContext)
            let persistedIdentifiers = self.persistedOutstandingRequestIdentifiers().filter(Self.matchesTaskSemanticContext)
            let staleIdentifiers = Set(pendingIdentifiers).union(persistedIdentifiers)

            guard !staleIdentifiers.isEmpty else {
                completion?()
                return
            }

            self.stateQueue.async {
                for identifier in staleIdentifiers {
                    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
                    self.registeredIdentifiers.remove(identifier)
                    if self.pendingRequestIdentifier == identifier {
                        self.pendingRequestIdentifier = nil
                    }
                }
                self.removePersistedOutstandingRequestIdentifiers(staleIdentifiers)
                print(
                    "[SYNC] continued-processing purged stale requests reason=\(reason) count=\(staleIdentifiers.count)"
                )
                completion?()
            }
        }
    }

    private func restoreOutstandingRequestRegistrations() {
        let outstandingIdentifiers = persistedOutstandingRequestIdentifiers().filter(Self.matchesTaskSemanticContext)
        guard !outstandingIdentifiers.isEmpty else { return }
        for identifier in outstandingIdentifiers {
            _ = registerLaunchHandlerIfNeeded(for: identifier)
        }
        print(
            "[SYNC] continued-processing restored registrations count=\(outstandingIdentifiers.count)"
        )
    }

    private func persistedOutstandingRequestIdentifiers() -> Set<String> {
        Set(
            UserDefaults.standard.stringArray(
                forKey: Self.persistedOutstandingIdentifiersDefaultsKey
            ) ?? []
        )
    }

    private func persistOutstandingRequestIdentifier(_ identifier: String) {
        var identifiers = persistedOutstandingRequestIdentifiers()
        identifiers.insert(identifier)
        UserDefaults.standard.set(Array(identifiers).sorted(), forKey: Self.persistedOutstandingIdentifiersDefaultsKey)
    }

    private func removePersistedOutstandingRequestIdentifiers<S: Sequence>(_ identifiers: S) where S.Element == String {
        var storedIdentifiers = persistedOutstandingRequestIdentifiers()
        var changed = false
        for identifier in identifiers {
            if storedIdentifiers.remove(identifier) != nil {
                changed = true
            }
        }
        guard changed else { return }
        UserDefaults.standard.set(
            Array(storedIdentifiers).sorted(),
            forKey: Self.persistedOutstandingIdentifiersDefaultsKey
        )
    }

    private func activate(_ task: BGContinuedProcessingTask) {
        self.stopProgressTimerLocked()
        self.activeTask = task
        self.isArmed = true
        self.pendingRequestIdentifier = nil
        self.persistOutstandingRequestIdentifier(task.identifier)
        self.clearProgressObserversLocked()
        self.progressWorkBridge = nil
        self.maxCompletedUnitCount = 0
        self.lastSubtitle = ""
        self.lastProgressAdvanceUptime = ProcessInfo.processInfo.systemUptime
        self.noWorkObservedSinceUptime = nil
        self.nearCompletionHandoffRequested = false
        self.progressCancellationHandled = false
        task.progress.isCancellable = true
        task.progress.isPausable = true
        print(
            "[SYNC] continued-processing activate identifier=\(task.identifier) " +
            "is_cancelled=\(task.progress.isCancelled ? 1 : 0) " +
            "is_paused=\(task.progress.isPaused ? 1 : 0) " +
            "completed_milli=\(task.progress.completedUnitCount) " +
            "total_milli=\(task.progress.totalUnitCount)"
        )
        task.progress.cancellationHandler = { [weak self] in
            print(
                "[SYNC] continued-processing progress-cancellation-handler callback identifier=\(task.identifier) " +
                "is_cancelled=\(task.progress.isCancelled ? 1 : 0) " +
                "is_paused=\(task.progress.isPaused ? 1 : 0) " +
                "completed_milli=\(task.progress.completedUnitCount) " +
                "total_milli=\(task.progress.totalUnitCount)"
            )
            self?.stateQueue.async { [weak self] in
                self?.logTaskCallbackStateLocked(task: task, source: "progress-handler-callback")
                self?.handleProgressCancellationLocked(source: "progress-handler")
            }
        }
        task.progress.pausingHandler = { [weak self] in
            print(
                "[SYNC] continued-processing progress-pausing-handler callback identifier=\(task.identifier) " +
                "is_cancelled=\(task.progress.isCancelled ? 1 : 0) " +
                "is_paused=\(task.progress.isPaused ? 1 : 0) " +
                "completed_milli=\(task.progress.completedUnitCount) " +
                "total_milli=\(task.progress.totalUnitCount)"
            )
            self?.stateQueue.async { [weak self] in
                self?.logTaskCallbackStateLocked(task: task, source: "progress-pausing-handler-callback")
                self?.handleProgressPauseLocked(source: "progress-pausing-handler")
            }
        }
        task.progress.resumingHandler = {
            print(
                "[SYNC] continued-processing progress-resuming-handler callback identifier=\(task.identifier) " +
                "is_cancelled=\(task.progress.isCancelled ? 1 : 0) " +
                "is_paused=\(task.progress.isPaused ? 1 : 0) " +
                "completed_milli=\(task.progress.completedUnitCount) " +
                "total_milli=\(task.progress.totalUnitCount)"
            )
        }
        task.progress.totalUnitCount = 1_000
        task.progress.completedUnitCount = 0
        let workBridge = Progress.discreteProgress(totalUnitCount: 1_000)
        workBridge.isCancellable = true
        workBridge.isPausable = true
        workBridge.completedUnitCount = 1
        task.progress.addChild(workBridge, withPendingUnitCount: 1)
        self.progressWorkBridge = workBridge
        print(
            "[SYNC] continued-processing attached work-bridge progress identifier=\(task.identifier) " +
            "child_cancelled=\(workBridge.isCancelled ? 1 : 0) " +
            "child_paused=\(workBridge.isPaused ? 1 : 0) " +
            "child_completed=\(workBridge.completedUnitCount) " +
            "child_total=\(workBridge.totalUnitCount)"
        )
        self.taskProgressCancelledObserver = task.progress.observe(\.isCancelled, options: [.initial, .new]) {
            [weak self] progress, change in
            guard change.newValue == true else { return }
            print(
                "[SYNC] continued-processing task-progress KVO cancelled identifier=\(task.identifier) " +
                "is_cancelled=\(progress.isCancelled ? 1 : 0) " +
                "is_paused=\(progress.isPaused ? 1 : 0) " +
                "completed_milli=\(progress.completedUnitCount) " +
                "total_milli=\(progress.totalUnitCount)"
            )
            self?.stateQueue.async { [weak self] in
                self?.logTaskCallbackStateLocked(task: task, source: "task-progress-kvo-cancelled")
                self?.handleProgressCancellationLocked(source: "task-progress-kvo")
            }
        }
        self.taskProgressPausedObserver = task.progress.observe(\.isPaused, options: [.initial, .new]) {
            [weak self] progress, change in
            guard change.newValue == true else { return }
            print(
                "[SYNC] continued-processing task-progress KVO paused identifier=\(task.identifier) " +
                "is_cancelled=\(progress.isCancelled ? 1 : 0) " +
                "is_paused=\(progress.isPaused ? 1 : 0) " +
                "completed_milli=\(progress.completedUnitCount) " +
                "total_milli=\(progress.totalUnitCount)"
            )
            self?.stateQueue.async { [weak self] in
                self?.logTaskCallbackStateLocked(task: task, source: "task-progress-kvo-paused")
                self?.handleProgressPauseLocked(source: "task-progress-kvo")
            }
        }
        workBridge.cancellationHandler = { [weak self] in
            print(
                "[SYNC] continued-processing child-progress cancellation callback identifier=\(task.identifier) " +
                "child_cancelled=\(workBridge.isCancelled ? 1 : 0) " +
                "child_paused=\(workBridge.isPaused ? 1 : 0)"
            )
            self?.stateQueue.async { [weak self] in
                self?.logTaskCallbackStateLocked(task: task, source: "child-progress-cancellation-callback")
                self?.handleProgressCancellationLocked(source: "child-progress-handler")
            }
        }
        self.childProgressCancelledObserver = workBridge.observe(\.isCancelled, options: [.initial, .new]) {
            [weak self] progress, change in
            guard change.newValue == true else { return }
            print(
                "[SYNC] continued-processing child-progress KVO cancelled identifier=\(task.identifier) " +
                "child_cancelled=\(progress.isCancelled ? 1 : 0) " +
                "child_paused=\(progress.isPaused ? 1 : 0)"
            )
            self?.stateQueue.async { [weak self] in
                self?.logTaskCallbackStateLocked(task: task, source: "child-progress-kvo-cancelled")
                self?.handleProgressCancellationLocked(source: "child-progress-kvo")
            }
        }
        workBridge.pausingHandler = { [weak self] in
            print(
                "[SYNC] continued-processing child-progress pausing callback identifier=\(task.identifier) " +
                "child_cancelled=\(workBridge.isCancelled ? 1 : 0) " +
                "child_paused=\(workBridge.isPaused ? 1 : 0)"
            )
            self?.stateQueue.async { [weak self] in
                self?.logTaskCallbackStateLocked(task: task, source: "child-progress-pausing-callback")
                self?.handleProgressPauseLocked(source: "child-progress-handler")
            }
        }
        self.childProgressPausedObserver = workBridge.observe(\.isPaused, options: [.initial, .new]) {
            [weak self] progress, change in
            guard change.newValue == true else { return }
            print(
                "[SYNC] continued-processing child-progress KVO paused identifier=\(task.identifier) " +
                "child_cancelled=\(progress.isCancelled ? 1 : 0) " +
                "child_paused=\(progress.isPaused ? 1 : 0)"
            )
            self?.stateQueue.async { [weak self] in
                self?.logTaskCallbackStateLocked(task: task, source: "child-progress-kvo-paused")
                self?.handleProgressPauseLocked(source: "child-progress-kvo")
            }
        }
        workBridge.resumingHandler = {
            print(
                "[SYNC] continued-processing child-progress resuming callback identifier=\(task.identifier) " +
                "child_cancelled=\(workBridge.isCancelled ? 1 : 0) " +
                "child_paused=\(workBridge.isPaused ? 1 : 0)"
            )
        }
        task.updateTitle("Syncing photos", subtitle: "Preparing uploads")
        task.expirationHandler = { [weak self] in
            print(
                "[SYNC] continued-processing expiration-handler callback identifier=\(task.identifier) " +
                "is_cancelled=\(task.progress.isCancelled ? 1 : 0) " +
                "is_paused=\(task.progress.isPaused ? 1 : 0) " +
                "completed_milli=\(task.progress.completedUnitCount) " +
                "total_milli=\(task.progress.totalUnitCount)"
            )
            self?.stateQueue.async { [weak self] in
                guard let self else { return }
                self.stopProgressTimerLocked()
                self.logTaskCallbackStateLocked(task: task, source: "expiration-handler-entry")
                if task.progress.isCancelled {
                    print(
                        "[SYNC] continued-processing expiration-handler routing=cancel identifier=\(task.identifier)"
                    )
                    self.handleProgressCancellationLocked(source: "expiration-handler")
                    return
                }
                if task.progress.isPaused {
                    print(
                        "[SYNC] continued-processing expiration-handler routing=pause identifier=\(task.identifier)"
                    )
                    self.handleProgressPauseLocked(source: "expiration-handler")
                    return
                }
                print(
                    "[SYNC] continued-processing expiration-handler routing=expiration identifier=\(task.identifier)"
                )
                SyncService.shared.handleContinuedProcessingExpiration()
            }
        }
        self.startProgressTimerLocked()
        self.refreshProgressLocked()
        SyncService.shared.handleContinuedProcessingTaskActivated()
    }

    private func startProgressTimerLocked() {
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            self?.refreshProgressLocked()
        }
        progressTimer = timer
        timer.resume()
    }

    private func stopProgressTimerLocked() {
        progressTimer?.setEventHandler {}
        progressTimer?.cancel()
        progressTimer = nil
    }

    private func clearProgressObserversLocked() {
        taskProgressCancelledObserver?.invalidate()
        taskProgressPausedObserver?.invalidate()
        childProgressCancelledObserver?.invalidate()
        childProgressPausedObserver?.invalidate()
        taskProgressCancelledObserver = nil
        taskProgressPausedObserver = nil
        childProgressCancelledObserver = nil
        childProgressPausedObserver = nil
    }

    private func logTaskCallbackStateLocked(task: BGContinuedProcessingTask, source: String) {
        let snapshot = SyncService.shared.continuedProcessingProgressSnapshot()
        let activeIdentifier = activeTask?.identifier ?? "(none)"
        let pendingIdentifier = pendingRequestIdentifier ?? "(none)"
        let childProgress = progressWorkBridge
        print(
            "[SYNC] continued-processing callback-state source=\(source) " +
            "task_identifier=\(task.identifier) " +
            "active_identifier=\(activeIdentifier) " +
            "matches_active=\(activeTask?.identifier == task.identifier ? 1 : 0) " +
            "pending_identifier=\(pendingIdentifier) " +
            "is_armed=\(isArmed ? 1 : 0) " +
            "progress_cancel_handled=\(progressCancellationHandled ? 1 : 0) " +
            "task_cancelled=\(task.progress.isCancelled ? 1 : 0) " +
            "task_paused=\(task.progress.isPaused ? 1 : 0) " +
            "child_cancelled=\(childProgress?.isCancelled == true ? 1 : 0) " +
            "child_paused=\(childProgress?.isPaused == true ? 1 : 0) " +
            "child_completed=\(childProgress?.completedUnitCount ?? -1) " +
            "child_total=\(childProgress?.totalUnitCount ?? -1) " +
            "task_completed_milli=\(task.progress.completedUnitCount) " +
            "task_total_milli=\(task.progress.totalUnitCount) " +
            "planned=\(snapshot.plannedAssets) " +
            "terminal=\(snapshot.terminalAssets) " +
            "active=\(snapshot.activeAssets) " +
            "verifying=\(snapshot.verifyingAssets) " +
            "pending=\(snapshot.pendingAssets) " +
            "sync_running=\(snapshot.isRunning ? 1 : 0) " +
            "backgrounded=\(snapshot.isBackgrounded ? 1 : 0)"
        )
    }

    private func refreshProgressLocked() {
        guard let task = activeTask else { return }
        if progressWorkBridge?.isCancelled == true {
            handleProgressCancellationLocked(source: "child-progress-poll")
            return
        }
        if progressWorkBridge?.isPaused == true {
            handleProgressPauseLocked(source: "child-progress-poll")
            return
        }
        if task.progress.isCancelled {
            handleProgressCancellationLocked(source: "progress-poll")
            return
        }
        if task.progress.isPaused {
            handleProgressPauseLocked(source: "progress-poll")
            return
        }

        let nowUptime = ProcessInfo.processInfo.systemUptime
        let snapshot = SyncService.shared.continuedProcessingProgressSnapshot()
        if completeIdleNoWorkTaskIfNeededLocked(
            task: task,
            snapshot: snapshot,
            nowUptime: nowUptime
        ) {
            return
        }

        let totalUnitCount = Int64(max(1, snapshot.plannedAssets)) * 1_000
        var completedUnitCount = snapshot.completedMilliUnits
        let measuredCompletedUnitCount = completedUnitCount

        if snapshot.plannedAssets == 0 {
            completedUnitCount = snapshot.isRunning ? max(1, maxCompletedUnitCount) : maxCompletedUnitCount
        } else if completedUnitCount == 0 &&
                    (snapshot.activeAssets > 0 || snapshot.pendingAssets > 0 || snapshot.isRunning) {
            completedUnitCount = 1
        }

        if completedUnitCount > maxCompletedUnitCount {
            lastProgressAdvanceUptime = nowUptime
        } else if shouldApplyKeepAliveProgress(
            snapshot: snapshot,
            measuredCompletedUnitCount: measuredCompletedUnitCount,
            totalUnitCount: totalUnitCount,
            nowUptime: nowUptime
        ) {
            completedUnitCount = min(totalUnitCount - 1, maxCompletedUnitCount + 1)
            lastProgressAdvanceUptime = nowUptime
            print(
                "[SYNC] continued-processing keepalive measured_milli=\(measuredCompletedUnitCount) bumped_milli=\(completedUnitCount) lead=\(completedUnitCount - measuredCompletedUnitCount)"
            )
        }

        completedUnitCount = min(totalUnitCount, max(maxCompletedUnitCount, completedUnitCount))
        maxCompletedUnitCount = completedUnitCount

        if task.progress.totalUnitCount != totalUnitCount {
            task.progress.totalUnitCount = totalUnitCount
        }
        if task.progress.completedUnitCount != completedUnitCount {
            task.progress.completedUnitCount = completedUnitCount
        }
        if let workBridge = progressWorkBridge {
            if workBridge.totalUnitCount != totalUnitCount {
                workBridge.totalUnitCount = totalUnitCount
            }
            if workBridge.completedUnitCount != completedUnitCount {
                workBridge.completedUnitCount = completedUnitCount
            }
        }

        let subtitle = buildSubtitle(snapshot: snapshot)
        if subtitle != lastSubtitle {
            task.updateTitle("Syncing photos", subtitle: subtitle)
            lastSubtitle = subtitle
            print(
                "[SYNC] continued-processing subtitle planned=\(snapshot.plannedAssets) terminal=\(snapshot.terminalAssets) active=\(snapshot.activeAssets) verifying=\(snapshot.verifyingAssets) pending=\(snapshot.pendingAssets) completed_milli=\(completedUnitCount) total_milli=\(totalUnitCount) subtitle=\(subtitle)"
            )
        }

        if !nearCompletionHandoffRequested && isNearCompletedBackgroundTail(snapshot) {
            nearCompletionHandoffRequested = true
            print(
                "[SYNC] continued-processing near-complete handoff planned=\(snapshot.plannedAssets) terminal=\(snapshot.terminalAssets) verifying=\(snapshot.verifyingAssets)"
            )
            DispatchQueue.global(qos: .utility).async {
                SyncService.shared.handleContinuedProcessingNearCompletion()
            }
        }
    }

    private func completeIdleNoWorkTaskIfNeededLocked(
        task: BGContinuedProcessingTask,
        snapshot: SyncContinuedProcessingProgressSnapshot,
        nowUptime: TimeInterval
    ) -> Bool {
        guard snapshot.plannedAssets == 0,
              !snapshot.isRunning,
              snapshot.activeAssets == 0,
              snapshot.verifyingAssets == 0,
              snapshot.pendingAssets == 0 else {
            noWorkObservedSinceUptime = nil
            return false
        }

        guard let firstObservedUptime = noWorkObservedSinceUptime else {
            noWorkObservedSinceUptime = nowUptime
            print(
                "[SYNC] continued-processing idle-no-work observed identifier=\(task.identifier) " +
                "delay_s=\(Int(idleNoWorkCompletionDelaySeconds.rounded()))"
            )
            return false
        }

        guard nowUptime - firstObservedUptime >= idleNoWorkCompletionDelaySeconds else {
            return false
        }

        print(
            "[SYNC] continued-processing idle-no-work completing identifier=\(task.identifier) " +
            "observed_s=\(Int((nowUptime - firstObservedUptime).rounded()))"
        )
        finishLocked(
            success: true,
            reason: "idle-no-work",
            terminalTitle: "Sync complete",
            terminalSubtitle: "No uploads needed"
        )
        return true
    }

    private func handleProgressCancellationLocked(source: String) {
        handleProgressStopRequestedLocked(source: source, signal: "cancelled")
    }

    private func handleProgressPauseLocked(source: String) {
        handleProgressStopRequestedLocked(source: source, signal: "paused")
    }

    private func handleProgressStopRequestedLocked(source: String, signal: String) {
        guard isArmed || activeTask != nil else { return }
        guard !progressCancellationHandled else { return }
        progressCancellationHandled = true
        stopProgressTimerLocked()
        if let task = activeTask {
            logTaskCallbackStateLocked(task: task, source: "stop-requested-\(signal)-\(source)")
        } else {
            let snapshot = SyncService.shared.continuedProcessingProgressSnapshot()
            print(
                "[SYNC] continued-processing stop requested signal=\(signal) source=\(source) " +
                "task_identifier=(none) " +
                "is_armed=\(isArmed ? 1 : 0) " +
                "planned=\(snapshot.plannedAssets) " +
                "terminal=\(snapshot.terminalAssets) " +
                "active=\(snapshot.activeAssets) " +
                "verifying=\(snapshot.verifyingAssets) " +
                "pending=\(snapshot.pendingAssets) " +
                "sync_running=\(snapshot.isRunning ? 1 : 0) " +
                "backgrounded=\(snapshot.isBackgrounded ? 1 : 0)"
            )
        }
        if activeTask != nil {
            print("[SYNC] continued-processing stop requested signal=\(signal) source=\(source)")
        }
        DispatchQueue.global(qos: .userInitiated).async {
            SyncService.shared.stopCurrentSync(systemCancelled: true)
        }
    }

    private func shouldApplyKeepAliveProgress(
        snapshot: SyncContinuedProcessingProgressSnapshot,
        measuredCompletedUnitCount: Int64,
        totalUnitCount: Int64,
        nowUptime: TimeInterval
    ) -> Bool {
        guard snapshot.isBackgrounded else { return false }
        guard snapshot.terminalAssets < snapshot.plannedAssets else { return false }
        guard snapshot.activeAssets > 0 || snapshot.verifyingAssets > 0 else { return false }
        guard totalUnitCount > 1 else { return false }
        guard maxCompletedUnitCount < totalUnitCount - 1 else { return false }
        guard nowUptime - lastProgressAdvanceUptime >= keepAliveProgressIntervalSeconds else {
            return false
        }
        let lead = maxCompletedUnitCount - measuredCompletedUnitCount
        return lead < keepAliveProgressMaxLeadUnits
    }

    private func buildSubtitle(snapshot: SyncContinuedProcessingProgressSnapshot) -> String {
        guard snapshot.plannedAssets > 0 else {
            return snapshot.isRunning ? "Preparing uploads" : "Waiting to resume"
        }

        if snapshot.activeAssets > 0 {
            return "Synced \(snapshot.terminalAssets) of \(snapshot.plannedAssets) • Uploading \(snapshot.activeAssets)"
        }
        if snapshot.verifyingAssets > 0 {
            return "Synced \(snapshot.terminalAssets) of \(snapshot.plannedAssets) • Finalizing \(snapshot.verifyingAssets)"
        }
        if snapshot.pendingAssets > 0 {
            return "Synced \(snapshot.terminalAssets) of \(snapshot.plannedAssets) • Preparing \(snapshot.pendingAssets)"
        }
        if snapshot.terminalAssets >= snapshot.plannedAssets {
            return "Uploads finished"
        }
        if snapshot.isBackgrounded {
            return "Paused until app returns to foreground"
        }
        return "Preparing uploads"
    }
}
