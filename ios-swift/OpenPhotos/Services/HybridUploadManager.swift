import Foundation
import Photos
import Combine
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
// UIKit only used indirectly via IdleTimerManager; avoid direct UI imports here.
import CryptoKit
import Network

final class HybridUploadManager: NSObject, ObservableObject {
    static let shared = HybridUploadManager()

    private static let keepScreenOnDefaultsKey = "sync.keepScreenOnForegroundUploads"

    // Published queue for UI
    @Published private(set) var items: [UploadItem] = []
    @Published var keepScreenOn: Bool = true {
        didSet {
            IdleTimerManager.shared.setDisabled(keepScreenOn)
            UserDefaults.standard.set(keepScreenOn, forKey: Self.keepScreenOnDefaultsKey)
        }
    }

    private let auth = AuthManager.shared
    private var tusClient: TUSClient?
    private var bgSession: URLSession?
    private var bgCompletionHandler: (() -> Void)?
    private let pathMonitor = NWPathMonitor()
    private var isExpensiveNetwork: Bool = false
    private var isNetworkAvailable: Bool = false

    // Control foreground concurrency
    private let tusQueue = DispatchQueue(label: "hybrid.tus.queue")
    private var tusCancelFlags: [UUID: Bool] = [:]
    private var pendingTus: [UploadItem] = []
    private var tusEnqueuedAtUptime: [UUID: TimeInterval] = [:]
    private var activeTusWorkers: Int = 0
    private var foregroundTusSuspended: Bool = false
    private var liveComponentPendingByContentId: [String: Int] = [:]
    private let minTusWorkers: Int = 2
    private let maxTusWorkers: Int = 3
    private let tusScaleUpPendingThreshold: Int = 10
    private let tusScaleDownPendingThreshold: Int = 4
    private let tusThroughputGuardMinSamples: Int = 12
    private let tusHealthEwmaAlpha: Double = 0.2
    private let tusScaleDecisionCooldownSeconds: TimeInterval = 25.0
    private let tusScaleDownEwmaMBpsThreshold: Double = 0.34
    private let tusScaleUpEwmaMBpsThreshold: Double = 0.42
    private let tusScaleDownEwmaUploadMsThreshold: Double = 9_000.0
    private let tusScaleUpEwmaUploadMsThreshold: Double = 11_000.0
    private let tusScaleDownTimeoutRateThreshold: Double = 0.08
    private let tusScaleDownStallRateThreshold: Double = 0.03
    private let tusScaleUpTimeoutRateCeiling: Double = 0.02
    private let tusScaleUpStallRateCeiling: Double = 0.01
    private let tusThroughputGuardDownConsecutiveRequired: Int = 3
    private let tusThroughputGuardUpConsecutiveRequired: Int = 2
    private let tusThroughputGuardRecoveryHoldSeconds: TimeInterval = 95.0
    private let tusThroughputGuardRecoveryUpConsecutiveRequired: Int = 4
    private let tusProbeAfterThroughputGuardCooldownSeconds: TimeInterval = 160.0
    private let tusProbeUpPendingThresholdAfterGuard: Int = 26
    private let tusCreateLatencyGuardMinSamples: Int = 16
    private let tusCreateLatencyGuardEwmaMsThreshold: Double = 1_000.0
    private let tusCreateLatencyGuardConsecutiveRequired: Int = 5
    private let tusCreateLatencyGuardReleaseEwmaMsThreshold: Double = 700.0
    private let tusCreateLatencyGuardReleaseConsecutiveRequired: Int = 12
    private let tusCreateLatencyGuardMinHoldSeconds: TimeInterval = 150.0
    private let tusProbeUpPendingThreshold: Int = 18
    private let tusProbeUpIntervalSeconds: TimeInterval = 75.0
    private let tusProbeHighWorkerHoldSeconds: TimeInterval = 35.0
    // Tunnel uploads have been reliable below the ~350-400 KiB range in logs;
    // keep foreground PATCH bodies comfortably under that ceiling.
    private let foregroundTusChunkSizeBytes: Int = 256 * 1024
    private let foregroundTusMediumChunkSizeBytes: Int = 512 * 1024
    private let foregroundTusLargeChunkSizeBytes: Int = 1024 * 1024
    private let foregroundTusAdaptiveMediumMaxChunkSizeBytes: Int = 1024 * 1024
    private let foregroundTusAdaptiveLargeMaxChunkSizeBytes: Int = 2 * 1024 * 1024
    private let foregroundTusMediumChunkThresholdBytes: Int64 = 24 * 1024 * 1024
    // Promote 100 MB+ uploads into the larger adaptive profile so tunnel uploads
    // spend less time paying per-PATCH overhead. The TUS client can still shrink
    // chunks after a timeout if Cloudflare becomes unstable.
    private let foregroundTusLargeChunkThresholdBytes: Int64 = 100 * 1024 * 1024
    private let tusPatchTimeoutSeconds: TimeInterval = 30.0
    private let tusPatchTimeoutDegradedSeconds: TimeInterval = 40.0
    private let tusPatchTimeoutPoorLinkSeconds: TimeInterval = 45.0
    private let tusPatchTimeoutMediumUploadSeconds: TimeInterval = 60.0
    private let tusPatchTimeoutLargeUploadSeconds: TimeInterval = 90.0
    private let tusPatchAdaptiveMinSamples: Int = 6
    private let tusMaxStallRecoveriesPerUpload: Int = 1
    private let tusMediumUploadStallRecoveries: Int = 3
    private let tusLargeUploadStallRecoveries: Int = 6
    private var tusConcurrencyState = TusConcurrencyState()
    // Limit export concurrency to avoid too many open files
    private let exportSemaphore = DispatchSemaphore(value: 3)
    private let exportResultsQueue = DispatchQueue(label: "hybrid.export.results")
    private let exportBatchSize: Int = 8
    private let maxPendingTusBeforeNextExportBatch: Int = 24
    private let exportBackpressurePollSeconds: TimeInterval = 0.5
    private let minFreeSpaceBytes: Int64 = 500 * 1024 * 1024 // 500 MB threshold
    private let uploadTempDirectoryName = "openphotos-upload"
    // Sync activity tracking (prevents overlapping sync runs)
    private let activityQueue = DispatchQueue(label: "hybrid.activity.queue")
    private var activeExportBatches: Int = 0
    private var activePreflightChecks: Int = 0
    // Track active Photos export/download requests (for cancellation when backgrounding)
    private let exportRequestsQueue = DispatchQueue(label: "hybrid.export.requests")
    private var activeExportRequests: [String: PHAssetResourceDataRequestID] = [:]
    // iCloud visibility for UI counters
    @Published private(set) var icloudPendingCount: Int = 0
    @Published private(set) var icloudDownloadingCount: Int = 0
    private var icloudDownloadingKeys: Set<String> = []
    private var icloudPendingKeys: Set<String> = []
    // Throttle iCloud progress logs (keyed by asset|filename) so debug logging doesn't flood and
    // degrade UI responsiveness during large iCloud-backed syncs.
    private var icloudProgressLogByKey: [String: (pct: Int, lastAt: TimeInterval)] = [:]

    // Throttle foreground progress updates to avoid excessive SwiftUI invalidations while uploading.
    //
    // Upload progress can update frequently (especially on fast networks), and each `@Published` update
    // triggers view recomputation. We gate `sentBytes` updates by time and byte delta, while always
    // allowing the final update (sentBytes == totalBytes) through.
    private let progressThrottleQueue = DispatchQueue(label: "hybrid.upload.progress.throttle")
    private var lastProgressByItem: [UUID: (lastAt: TimeInterval, lastBytes: Int64)] = [:]
    private let progressMinIntervalSeconds: TimeInterval = 0.25
    private let progressMinByteDelta: Int64 = 512 * 1024
    // Stop mode for foreground sync cancellation.
    private let runControlQueue = DispatchQueue(label: "hybrid.upload.run.control")
    private enum StopMode {
        case none
        case pause
        case resync
    }
    private var stopMode: StopMode = .none

    // Deferred server verification (batched, single utility task).
    private let deferredVerifyStateQueue = DispatchQueue(label: "hybrid.upload.verify.state")
    private var deferredVerifyEntriesByContentId: [String: DeferredVerifyEntry] = [:]
    private var deferredVerifyLoopTask: Task<Void, Never>?
    private let deferredVerifyPollSecondsBusy: TimeInterval = 5.0
    private let deferredVerifyPollSecondsBusyHighExists: TimeInterval = 10.0
    private let deferredVerifyPollSecondsBusyVeryHighExists: TimeInterval = 15.0
    private let deferredVerifyBusyPollHighExistsMs: Int = 700
    private let deferredVerifyBusyPollVeryHighExistsMs: Int = 1200
    private let deferredVerifyBusyPollMinExistsCalls: Int = 16
    private let deferredVerifyPollSecondsIdle: TimeInterval = 2.0
    private let deferredVerifyTimedOutRepollFastSeconds: TimeInterval = 8.0
    private let deferredVerifyTimedOutRepollMediumSeconds: TimeInterval = 12.0
    private let deferredVerifyTimedOutRepollSlowSeconds: TimeInterval = 25.0
    private let deferredVerifyAllTimedOutRepollFastSeconds: TimeInterval = 20.0
    private let deferredVerifyAllTimedOutRepollMediumSeconds: TimeInterval = 35.0
    private let deferredVerifyAllTimedOutRepollSlowSeconds: TimeInterval = 60.0
    private let deferredVerifyPostForegroundIdleBoostWindowSeconds: TimeInterval = 120.0
    private let deferredVerifyPostForegroundIdleRepollSeconds: TimeInterval = 6.0
    private let deferredVerifyIdleEntryRepollLowPendingThreshold: Int = 8
    private let deferredVerifyIdleEntryRepollVeryLowPendingThreshold: Int = 3
    private let deferredVerifyIdleEntryRepollLowPendingSeconds: TimeInterval = 2.8
    private let deferredVerifyIdleEntryRepollVeryLowPendingSeconds: TimeInterval = 3.5
    private let deferredVerifyTimedOutRepollHighPendingThreshold: Int = 96
    private let deferredVerifyTimedOutRepollMediumPendingThreshold: Int = 28
    private let deferredVerifyMaxWaitSeconds: TimeInterval = 60.0
    private let deferredVerifyMaxAttempts: Int = 20
    private let verifyDecisionQueue = DispatchQueue(label: "hybrid.upload.verify.decision")
    private let verifyImmediateBypassPendingThreshold: Int = 8
    private let verifyImmediateMissStreakBypassThreshold: Int = 20
    private let verifyImmediateProbeInterval: Int = 12
    private var verifyImmediateMissStreak: Int = 0
    private var verifyPolicyBypassCount: Int = 0

    // Upload performance metrics (summary-oriented, low-overhead).
    private let perfQueue = DispatchQueue(label: "hybrid.upload.perf.queue")
    private var perfRunState = UploadPerfRunState()
    private var perfBgAttemptStartedAt: [String: TimeInterval] = [:]
    private var perfBgFirstQueuedAtByBodyName: [String: TimeInterval] = [:]
    private let perfSummaryMinIntervalSeconds: TimeInterval = 12.0
    private let perfSummaryEveryCompletions: Int = 8
    private let perfSlowUploadThresholdSeconds: TimeInterval = 20.0

    private struct TusConcurrencyState {
        var targetWorkers: Int = 2
        var uploadSamples: Int = 0
        var ewmaUploadMBps: Double = 0
        var ewmaUploadMs: Double = 0
        var createSamples: Int = 0
        var ewmaCreateMs: Double = 0
        var ewmaPatchRetriesPerItem: Double = 0
        var ewmaPatchTimeoutsPerItem: Double = 0
        var ewmaStallRecoveriesPerItem: Double = 0
        var createLatencySignalStreak: Int = 0
        var createLatencyRecoveryStreak: Int = 0
        var createLatencyGuardActive: Bool = false
        var createLatencyGuardHoldUntilUptime: TimeInterval = 0
        var throughputDownSignalStreak: Int = 0
        var throughputUpSignalStreak: Int = 0
        var throughputGuardHoldUntilUptime: TimeInterval = 0
        var lastThroughputGuardDownscaleAtUptime: TimeInterval = 0
        var lastProbeScaleUpAtUptime: TimeInterval = 0
        var lastScaleChangeAtUptime: TimeInterval = 0
    }

    private struct DeferredVerifyEntry {
        let contentId: String
        let filename: String
        let assetId: String
        let waitForLivePairing: Bool
        var attempts: Int
        let queuedAtUptime: TimeInterval
        var timedOutAtUptime: TimeInterval?
        var lastPolledAtUptime: TimeInterval
    }

    private enum VerifyResult {
        case immediateOk
        case deferredQueued
        case failed
    }

    private struct TusUploadProfile {
        let initialChunkSize: Int
        let minimumChunkSize: Int
        let maximumChunkSize: Int
        let patchTimeoutSeconds: TimeInterval
        let maxStallRecoveries: Int
    }

    private struct UploadPerfRunState {
        var runId: Int = 0
        var startedAtUptime: TimeInterval = 0
        var plannedAssets: Int = 0
        var exportedItems: Int = 0
        var preflightSkipped: Int = 0
        var batchCount: Int = 0
        var exportBatchTotalSeconds: TimeInterval = 0
        var preflightTotalSeconds: TimeInterval = 0
        var batchTotalSeconds: TimeInterval = 0
        var tusCompleted: Int = 0
        var bgCompleted: Int = 0
        var failed: Int = 0
        var uploadedBytes: Int64 = 0
        var queueWaitTotalSeconds: TimeInterval = 0
        var queueWaitSamples: Int = 0
        var tusUploadTotalSeconds: TimeInterval = 0
        var tusUploadSamples: Int = 0
        var bgUploadTotalSeconds: TimeInterval = 0
        var bgUploadSamples: Int = 0
        var backpressureWaitTotalSeconds: TimeInterval = 0
        var backpressureEvents: Int = 0
        var verifyImmediateOk: Int = 0
        var verifyImmediatePolicySkipped: Int = 0
        var verifyDeferredQueued: Int = 0
        var verifyDeferredConfirmed: Int = 0
        var verifyDeferredTimedOut: Int = 0
        var headSkipped: Int = 0
        var headPerformed: Int = 0
        var workerScaleUpEvents: Int = 0
        var workerScaleDownEvents: Int = 0
        var workerScaleThroughputDownEvents: Int = 0
        var workerTargetMax: Int = 2
        var existsCalls: Int = 0
        var existsTotalSeconds: TimeInterval = 0
        var patchRetries: Int = 0
        var patchTimeouts: Int = 0
        var stallRecoveries: Int = 0
        var lastSummaryAtUptime: TimeInterval = 0
    }

    private func perfNow() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private func perfMs(_ seconds: TimeInterval) -> Int {
        max(0, Int((seconds * 1000.0).rounded()))
    }

    private func perfMBps(bytes: Int64, seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "n/a" }
        let mbps = (Double(bytes) / (1024.0 * 1024.0)) / seconds
        return String(format: "%.2f", mbps)
    }

    private func ewma(previous: Double, sample: Double, alpha: Double) -> Double {
        guard alpha > 0 && alpha <= 1 else { return sample }
        if previous <= 0 { return sample }
        return ((1.0 - alpha) * previous) + (alpha * sample)
    }

    private func deferredTimedOutRepollIntervalSeconds(pendingEntries: Int) -> TimeInterval {
        if pendingEntries >= deferredVerifyTimedOutRepollHighPendingThreshold {
            return deferredVerifyTimedOutRepollFastSeconds
        }
        if pendingEntries >= deferredVerifyTimedOutRepollMediumPendingThreshold {
            return deferredVerifyTimedOutRepollMediumSeconds
        }
        return deferredVerifyTimedOutRepollSlowSeconds
    }

    private func deferredAllTimedOutRepollIntervalSeconds(pendingEntries: Int) -> TimeInterval {
        if pendingEntries >= deferredVerifyTimedOutRepollHighPendingThreshold {
            return deferredVerifyAllTimedOutRepollFastSeconds
        }
        if pendingEntries >= deferredVerifyTimedOutRepollMediumPendingThreshold {
            return deferredVerifyAllTimedOutRepollMediumSeconds
        }
        return deferredVerifyAllTimedOutRepollSlowSeconds
    }

    private func applyDeferredIdleTailRepollBoost(
        baseSeconds: TimeInterval,
        hasForegroundUploadWork: Bool,
        now: TimeInterval,
        lastForegroundWorkAt: TimeInterval?
    ) -> TimeInterval {
        guard !hasForegroundUploadWork else { return baseSeconds }
        guard let lastForegroundWorkAt else { return baseSeconds }
        let idleElapsed = max(0, now - lastForegroundWorkAt)
        guard idleElapsed <= deferredVerifyPostForegroundIdleBoostWindowSeconds else {
            return baseSeconds
        }
        return min(baseSeconds, deferredVerifyPostForegroundIdleRepollSeconds)
    }

    private func deferredIdleEntryPollIntervalSeconds(
        hasForegroundUploadWork: Bool,
        pendingEntries: Int,
        allEntriesTimedOut: Bool
    ) -> TimeInterval {
        guard !hasForegroundUploadWork else { return 0 }
        guard !allEntriesTimedOut else { return 0 }
        if pendingEntries <= deferredVerifyIdleEntryRepollVeryLowPendingThreshold {
            return deferredVerifyIdleEntryRepollVeryLowPendingSeconds
        }
        if pendingEntries <= deferredVerifyIdleEntryRepollLowPendingThreshold {
            return deferredVerifyIdleEntryRepollLowPendingSeconds
        }
        return deferredVerifyPollSecondsIdle
    }

    private func deferredBusyPollIntervalSeconds() -> TimeInterval {
        let avgExistsMs: Int = perfQueue.sync {
            guard perfRunState.existsCalls >= deferredVerifyBusyPollMinExistsCalls else { return 0 }
            let avg = perfRunState.existsTotalSeconds / Double(max(1, perfRunState.existsCalls))
            return perfMs(avg)
        }
        if avgExistsMs >= deferredVerifyBusyPollVeryHighExistsMs {
            return deferredVerifyPollSecondsBusyVeryHighExists
        }
        if avgExistsMs >= deferredVerifyBusyPollHighExistsMs {
            return deferredVerifyPollSecondsBusyHighExists
        }
        return deferredVerifyPollSecondsBusy
    }

    private func preferredTusPatchTimeoutSeconds() -> TimeInterval {
        tusQueue.sync {
            let samples = tusConcurrencyState.uploadSamples
            if samples < tusPatchAdaptiveMinSamples {
                return tusPatchTimeoutSeconds
            }
            let timeoutSignal = tusConcurrencyState.ewmaPatchTimeoutsPerItem >= tusScaleUpTimeoutRateCeiling
            let stallSignal = tusConcurrencyState.ewmaStallRecoveriesPerItem >= tusScaleUpStallRateCeiling
            if timeoutSignal || stallSignal {
                return tusPatchTimeoutPoorLinkSeconds
            }
            let degradedThroughput = tusConcurrencyState.ewmaUploadMBps > 0 &&
                tusConcurrencyState.ewmaUploadMBps < tusScaleDownEwmaMBpsThreshold &&
                tusConcurrencyState.ewmaUploadMs >= tusScaleDownEwmaUploadMsThreshold
            if degradedThroughput {
                return tusPatchTimeoutDegradedSeconds
            }
            return tusPatchTimeoutSeconds
        }
    }

    private func tusUploadProfile(for item: UploadItem) -> TusUploadProfile {
        let baseTimeout = preferredTusPatchTimeoutSeconds()
        guard !isExpensiveNetwork else {
            return TusUploadProfile(
                initialChunkSize: foregroundTusChunkSizeBytes,
                minimumChunkSize: foregroundTusChunkSizeBytes,
                maximumChunkSize: foregroundTusChunkSizeBytes,
                patchTimeoutSeconds: baseTimeout,
                maxStallRecoveries: tusMaxStallRecoveriesPerUpload
            )
        }
        if item.totalBytes >= foregroundTusLargeChunkThresholdBytes {
            return TusUploadProfile(
                initialChunkSize: foregroundTusLargeChunkSizeBytes,
                minimumChunkSize: foregroundTusChunkSizeBytes,
                maximumChunkSize: foregroundTusAdaptiveLargeMaxChunkSizeBytes,
                patchTimeoutSeconds: max(baseTimeout, tusPatchTimeoutLargeUploadSeconds),
                maxStallRecoveries: tusLargeUploadStallRecoveries
            )
        }
        if item.totalBytes >= foregroundTusMediumChunkThresholdBytes {
            return TusUploadProfile(
                initialChunkSize: foregroundTusMediumChunkSizeBytes,
                minimumChunkSize: foregroundTusChunkSizeBytes,
                maximumChunkSize: foregroundTusAdaptiveMediumMaxChunkSizeBytes,
                patchTimeoutSeconds: max(baseTimeout, tusPatchTimeoutMediumUploadSeconds),
                maxStallRecoveries: tusMediumUploadStallRecoveries
            )
        }
        return TusUploadProfile(
            initialChunkSize: foregroundTusChunkSizeBytes,
            minimumChunkSize: foregroundTusChunkSizeBytes,
            maximumChunkSize: foregroundTusChunkSizeBytes,
            patchTimeoutSeconds: baseTimeout,
            maxStallRecoveries: tusMaxStallRecoveriesPerUpload
        )
    }

    private func pendingLiveComponents(forContentId contentId: String) -> Int {
        tusQueue.sync { liveComponentPendingByContentId[contentId] ?? 0 }
    }

    private func trackLiveComponentEnqueueIfNeeded(_ item: UploadItem) {
        guard item.isLiveComponent else { return }
        let previous = liveComponentPendingByContentId[item.contentId] ?? 0
        let updated = previous + 1
        liveComponentPendingByContentId[item.contentId] = updated
        AppLog.debug(
            AppLog.upload,
            "[PERF] live-pair-track content_id=\(item.contentId) phase=enqueue pending_live=\(updated)"
        )
    }

    private func trackLiveComponentSettledIfNeeded(_ item: UploadItem) {
        guard item.isLiveComponent else { return }
        tusQueue.async {
            let previous = self.liveComponentPendingByContentId[item.contentId] ?? 0
            let updated = max(0, previous - 1)
            if updated == 0 {
                self.liveComponentPendingByContentId.removeValue(forKey: item.contentId)
            } else {
                self.liveComponentPendingByContentId[item.contentId] = updated
            }
            AppLog.debug(
                AppLog.upload,
                "[PERF] live-pair-track content_id=\(item.contentId) phase=settled pending_live=\(updated)"
            )
        }
    }

    private func clearDeferredVerificationWork() {
        deferredVerifyStateQueue.sync {
            deferredVerifyLoopTask?.cancel()
            deferredVerifyLoopTask = nil
            deferredVerifyEntriesByContentId.removeAll(keepingCapacity: true)
        }
    }

    private func perfStartRun(totalAssets: Int) {
        let now = perfNow()
        clearDeferredVerificationWork()
        verifyDecisionQueue.sync {
            verifyImmediateMissStreak = 0
            verifyPolicyBypassCount = 0
        }
        tusQueue.sync {
            liveComponentPendingByContentId.removeAll(keepingCapacity: true)
            tusConcurrencyState.targetWorkers = minTusWorkers
            tusConcurrencyState.uploadSamples = 0
            tusConcurrencyState.ewmaUploadMBps = 0
            tusConcurrencyState.ewmaUploadMs = 0
            tusConcurrencyState.createSamples = 0
            tusConcurrencyState.ewmaCreateMs = 0
            tusConcurrencyState.ewmaPatchRetriesPerItem = 0
            tusConcurrencyState.ewmaPatchTimeoutsPerItem = 0
            tusConcurrencyState.ewmaStallRecoveriesPerItem = 0
            tusConcurrencyState.createLatencySignalStreak = 0
            tusConcurrencyState.createLatencyRecoveryStreak = 0
            tusConcurrencyState.createLatencyGuardActive = false
            tusConcurrencyState.createLatencyGuardHoldUntilUptime = 0
            tusConcurrencyState.throughputDownSignalStreak = 0
            tusConcurrencyState.throughputUpSignalStreak = 0
            tusConcurrencyState.throughputGuardHoldUntilUptime = 0
            tusConcurrencyState.lastThroughputGuardDownscaleAtUptime = 0
            tusConcurrencyState.lastProbeScaleUpAtUptime = now
            tusConcurrencyState.lastScaleChangeAtUptime = now - tusScaleDecisionCooldownSeconds
        }
        perfQueue.sync {
            perfRunState.runId += 1
            perfRunState.startedAtUptime = now
            perfRunState.plannedAssets = totalAssets
            perfRunState.exportedItems = 0
            perfRunState.preflightSkipped = 0
            perfRunState.batchCount = 0
            perfRunState.exportBatchTotalSeconds = 0
            perfRunState.preflightTotalSeconds = 0
            perfRunState.batchTotalSeconds = 0
            perfRunState.tusCompleted = 0
            perfRunState.bgCompleted = 0
            perfRunState.failed = 0
            perfRunState.uploadedBytes = 0
            perfRunState.queueWaitTotalSeconds = 0
            perfRunState.queueWaitSamples = 0
            perfRunState.tusUploadTotalSeconds = 0
            perfRunState.tusUploadSamples = 0
            perfRunState.bgUploadTotalSeconds = 0
            perfRunState.bgUploadSamples = 0
            perfRunState.backpressureWaitTotalSeconds = 0
            perfRunState.backpressureEvents = 0
            perfRunState.verifyImmediateOk = 0
            perfRunState.verifyImmediatePolicySkipped = 0
            perfRunState.verifyDeferredQueued = 0
            perfRunState.verifyDeferredConfirmed = 0
            perfRunState.verifyDeferredTimedOut = 0
            perfRunState.headSkipped = 0
            perfRunState.headPerformed = 0
            perfRunState.workerScaleUpEvents = 0
            perfRunState.workerScaleDownEvents = 0
            perfRunState.workerScaleThroughputDownEvents = 0
            perfRunState.workerTargetMax = self.minTusWorkers
            perfRunState.existsCalls = 0
            perfRunState.existsTotalSeconds = 0
            perfRunState.patchRetries = 0
            perfRunState.patchTimeouts = 0
            perfRunState.stallRecoveries = 0
            perfRunState.lastSummaryAtUptime = now
            perfBgAttemptStartedAt.removeAll(keepingCapacity: true)
            perfBgFirstQueuedAtByBodyName.removeAll(keepingCapacity: true)
        }
    }

    private func perfRecordBatch(exportedCount: Int, skippedCount: Int) {
        perfQueue.async {
            self.perfRunState.exportedItems += exportedCount
            self.perfRunState.preflightSkipped += skippedCount
        }
    }

    private func perfRecordBatchTimings(exportSeconds: TimeInterval, preflightSeconds: TimeInterval, batchSeconds: TimeInterval) {
        perfQueue.async {
            self.perfRunState.batchCount += 1
            self.perfRunState.exportBatchTotalSeconds += max(0, exportSeconds)
            self.perfRunState.preflightTotalSeconds += max(0, preflightSeconds)
            self.perfRunState.batchTotalSeconds += max(0, batchSeconds)
        }
    }

    private func perfRecordBackpressureWait(_ seconds: TimeInterval) {
        guard seconds > 0 else { return }
        perfQueue.async {
            self.perfRunState.backpressureEvents += 1
            self.perfRunState.backpressureWaitTotalSeconds += seconds
        }
    }

    private func perfRecordForegroundCompletion(bytes: Int64, queueWait: TimeInterval?, uploadSeconds: TimeInterval) {
        perfQueue.async {
            self.perfRunState.tusCompleted += 1
            self.perfRunState.uploadedBytes += max(0, bytes)
            if let queueWait {
                self.perfRunState.queueWaitTotalSeconds += max(0, queueWait)
                self.perfRunState.queueWaitSamples += 1
            }
            self.perfRunState.tusUploadTotalSeconds += max(0, uploadSeconds)
            self.perfRunState.tusUploadSamples += 1
        }
    }

    private func perfRecordBackgroundCompletion(bytes: Int64, uploadSeconds: TimeInterval?) {
        perfQueue.async {
            self.perfRunState.bgCompleted += 1
            self.perfRunState.uploadedBytes += max(0, bytes)
            if let uploadSeconds {
                self.perfRunState.bgUploadTotalSeconds += max(0, uploadSeconds)
                self.perfRunState.bgUploadSamples += 1
            }
        }
    }

    private func perfRecordFailure() {
        perfQueue.async { self.perfRunState.failed += 1 }
    }

    private func perfRecordExistsCall(_ seconds: TimeInterval) {
        perfQueue.async {
            self.perfRunState.existsCalls += 1
            self.perfRunState.existsTotalSeconds += max(0, seconds)
        }
    }

    private func perfRecordVerifyImmediateOk() {
        perfQueue.async { self.perfRunState.verifyImmediateOk += 1 }
    }

    private func perfRecordVerifyImmediatePolicySkipped() {
        perfQueue.async { self.perfRunState.verifyImmediatePolicySkipped += 1 }
    }

    private func perfRecordVerifyDeferredQueued() {
        perfQueue.async { self.perfRunState.verifyDeferredQueued += 1 }
    }

    private func perfRecordVerifyDeferredConfirmed() {
        perfQueue.async { self.perfRunState.verifyDeferredConfirmed += 1 }
    }

    private func perfRecordVerifyDeferredTimedOut() {
        perfQueue.async { self.perfRunState.verifyDeferredTimedOut += 1 }
    }

    private func perfRecordHeadSkipped() {
        perfQueue.async { self.perfRunState.headSkipped += 1 }
    }

    private func perfRecordHeadPerformed() {
        perfQueue.async { self.perfRunState.headPerformed += 1 }
    }

    private func perfRecordTusTransport(patchRetries: Int, patchTimeouts: Int, stallRecoveries: Int) {
        perfQueue.async {
            self.perfRunState.patchRetries += max(0, patchRetries)
            self.perfRunState.patchTimeouts += max(0, patchTimeouts)
            self.perfRunState.stallRecoveries += max(0, stallRecoveries)
        }
    }

    private func perfRecordWorkerScale(target: Int, previous: Int, reason: String) {
        perfQueue.async {
            if target > previous {
                self.perfRunState.workerScaleUpEvents += 1
            } else if target < previous {
                self.perfRunState.workerScaleDownEvents += 1
                if reason == "throughput_guard" {
                    self.perfRunState.workerScaleThroughputDownEvents += 1
                }
            }
            self.perfRunState.workerTargetMax = max(self.perfRunState.workerTargetMax, target)
        }
    }

    private func perfRegisterBackgroundTaskStart(taskDescription: String, bodyName: String) {
        let now = perfNow()
        perfQueue.async {
            self.perfBgAttemptStartedAt[taskDescription] = now
            if self.perfBgFirstQueuedAtByBodyName[bodyName] == nil {
                self.perfBgFirstQueuedAtByBodyName[bodyName] = now
            }
        }
    }

    private func perfConsumeBackgroundAttemptDuration(taskDescription: String) -> TimeInterval? {
        let now = perfNow()
        return perfQueue.sync {
            guard let started = perfBgAttemptStartedAt.removeValue(forKey: taskDescription) else { return nil }
            return max(0, now - started)
        }
    }

    private func perfFinishBackgroundEndToEndDuration(bodyName: String) -> TimeInterval? {
        let now = perfNow()
        return perfQueue.sync {
            guard let started = perfBgFirstQueuedAtByBodyName.removeValue(forKey: bodyName) else { return nil }
            return max(0, now - started)
        }
    }

    private func perfShouldLogSummaryLocked(now: TimeInterval, force: Bool) -> Bool {
        let completions = perfRunState.tusCompleted + perfRunState.bgCompleted + perfRunState.failed
        if force { return completions > 0 || perfRunState.exportedItems > 0 || perfRunState.backpressureEvents > 0 }
        if completions < perfSummaryEveryCompletions { return false }
        return (now - perfRunState.lastSummaryAtUptime) >= perfSummaryMinIntervalSeconds
    }

    private func perfLogSummary(reason: String, force: Bool = false) {
        let now = perfNow()
        let rolling = tusQueue.sync {
            (
                samples: tusConcurrencyState.uploadSamples,
                uploadMBps: tusConcurrencyState.ewmaUploadMBps,
                uploadMs: tusConcurrencyState.ewmaUploadMs,
                patchRetries: tusConcurrencyState.ewmaPatchRetriesPerItem,
                patchTimeouts: tusConcurrencyState.ewmaPatchTimeoutsPerItem,
                stallRecoveries: tusConcurrencyState.ewmaStallRecoveriesPerItem
            )
        }
        let line: String? = perfQueue.sync {
            guard perfShouldLogSummaryLocked(now: now, force: force) else { return nil }
            let elapsed = max(0, now - perfRunState.startedAtUptime)
            let queueWaitMs = perfRunState.queueWaitSamples > 0
                ? perfMs(perfRunState.queueWaitTotalSeconds / Double(perfRunState.queueWaitSamples))
                : 0
            let avgTusMs = perfRunState.tusUploadSamples > 0
                ? perfMs(perfRunState.tusUploadTotalSeconds / Double(perfRunState.tusUploadSamples))
                : 0
            let avgBgMs = perfRunState.bgUploadSamples > 0
                ? perfMs(perfRunState.bgUploadTotalSeconds / Double(perfRunState.bgUploadSamples))
                : 0
            let avgExportBatchMs = perfRunState.batchCount > 0
                ? perfMs(perfRunState.exportBatchTotalSeconds / Double(perfRunState.batchCount))
                : 0
            let avgPreflightMs = perfRunState.batchCount > 0
                ? perfMs(perfRunState.preflightTotalSeconds / Double(perfRunState.batchCount))
                : 0
            let avgBatchMs = perfRunState.batchCount > 0
                ? perfMs(perfRunState.batchTotalSeconds / Double(perfRunState.batchCount))
                : 0
            let avgBackpressureMs = perfRunState.backpressureEvents > 0
                ? perfMs(perfRunState.backpressureWaitTotalSeconds / Double(perfRunState.backpressureEvents))
                : 0
            let avgExistsMs = perfRunState.existsCalls > 0
                ? perfMs(perfRunState.existsTotalSeconds / Double(perfRunState.existsCalls))
                : 0

            let bottleneckCandidates: [(String, Int)] = [
                ("export_batch", avgExportBatchMs),
                ("preflight", avgPreflightMs),
                ("queue_wait", queueWaitMs),
                ("tus_upload", avgTusMs),
                ("bg_upload", avgBgMs),
                ("backpressure_wait", avgBackpressureMs)
            ].filter { $0.1 > 0 }
            let bottleneck = bottleneckCandidates.max { $0.1 < $1.1 } ?? ("none", 0)

            let totalDone = perfRunState.tusCompleted + perfRunState.bgCompleted + perfRunState.failed
            let throughput = perfMBps(bytes: perfRunState.uploadedBytes, seconds: max(elapsed, 0.001))
            perfRunState.lastSummaryAtUptime = now
            return "[PERF] run=\(perfRunState.runId) reason=\(reason) elapsed_ms=\(perfMs(elapsed)) planned_assets=\(perfRunState.plannedAssets) exported=\(perfRunState.exportedItems) skipped=\(perfRunState.preflightSkipped) done=\(totalDone) tus_done=\(perfRunState.tusCompleted) bg_done=\(perfRunState.bgCompleted) failed=\(perfRunState.failed) avg_export_batch_ms=\(avgExportBatchMs) avg_preflight_ms=\(avgPreflightMs) avg_batch_ms=\(avgBatchMs) avg_queue_wait_ms=\(queueWaitMs) avg_tus_ms=\(avgTusMs) avg_bg_ms=\(avgBgMs) uploaded_bytes=\(perfRunState.uploadedBytes) avg_run_MBps=\(throughput) backpressure_events=\(perfRunState.backpressureEvents) avg_backpressure_wait_ms=\(avgBackpressureMs) backpressure_wait_ms=\(perfMs(perfRunState.backpressureWaitTotalSeconds)) verify_immediate_ok=\(perfRunState.verifyImmediateOk) verify_policy_skip=\(perfRunState.verifyImmediatePolicySkipped) verify_deferred_queued=\(perfRunState.verifyDeferredQueued) verify_deferred_ok=\(perfRunState.verifyDeferredConfirmed) verify_deferred_timeout=\(perfRunState.verifyDeferredTimedOut) head_skipped=\(perfRunState.headSkipped) head_performed=\(perfRunState.headPerformed) worker_scale_up=\(perfRunState.workerScaleUpEvents) worker_scale_down=\(perfRunState.workerScaleDownEvents) worker_scale_down_throughput=\(perfRunState.workerScaleThroughputDownEvents) worker_target_max=\(perfRunState.workerTargetMax) exists_calls=\(perfRunState.existsCalls) avg_exists_ms=\(avgExistsMs) patch_retries=\(perfRunState.patchRetries) patch_timeouts=\(perfRunState.patchTimeouts) stall_recoveries=\(perfRunState.stallRecoveries) rolling_upload_MBps=\(String(format: "%.2f", rolling.uploadMBps)) rolling_upload_ms=\(Int(rolling.uploadMs.rounded())) rolling_patch_retries=\(String(format: "%.2f", rolling.patchRetries)) rolling_patch_timeouts=\(String(format: "%.2f", rolling.patchTimeouts)) rolling_stall_recoveries=\(String(format: "%.2f", rolling.stallRecoveries)) rolling_samples=\(rolling.samples) top_stage=\(bottleneck.0) top_stage_ms=\(bottleneck.1)"
        }
        if let line {
            AppLog.info(AppLog.upload, line)
        }
    }

    private func perfLogDeferredDrain(reason: String) {
        let now = perfNow()
        let line: String? = perfQueue.sync {
            guard perfRunState.startedAtUptime > 0 else { return nil }
            let elapsed = max(0, now - perfRunState.startedAtUptime)
            return "[PERF] verify-deferred-drained run=\(perfRunState.runId) reason=\(reason) elapsed_ms=\(perfMs(elapsed)) verify_deferred_ok=\(perfRunState.verifyDeferredConfirmed) verify_deferred_timeout=\(perfRunState.verifyDeferredTimedOut)"
        }
        if let line {
            AppLog.info(AppLog.upload, line)
        }
    }

    private func setStopMode(_ mode: StopMode) {
        runControlQueue.sync { stopMode = mode }
    }

    private func currentStopMode() -> StopMode {
        runControlQueue.sync { stopMode }
    }

    private func isStopRequested() -> Bool {
        currentStopMode() != .none
    }

    private func isStopForResyncRequested() -> Bool {
        currentStopMode() == .resync
    }

    private func shouldPublishProgress(itemID: UUID, sentBytes: Int64, totalBytes: Int64) -> Bool {
        // Always publish completion progress so UI reaches 100%.
        if totalBytes > 0 && sentBytes >= totalBytes { return true }
        let now = ProcessInfo.processInfo.systemUptime
        return progressThrottleQueue.sync {
            if let last = lastProgressByItem[itemID] {
                let dt = now - last.lastAt
                let dBytes = abs(sentBytes - last.lastBytes)
                if dt < progressMinIntervalSeconds && dBytes < progressMinByteDelta {
                    return false
                }
            }
            lastProgressByItem[itemID] = (lastAt: now, lastBytes: sentBytes)
            return true
        }
    }

    private func freeSpaceBytes() -> Int64 {
        let path = FileManager.default.temporaryDirectory.path
        do {
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: path)
            if let free = attrs[.systemFreeSize] as? NSNumber { return free.int64Value }
        } catch {
            print("[DISK] free space check failed: \(error.localizedDescription)")
        }
        return -1
    }

    private override init() {
        super.init()
        if UserDefaults.standard.object(forKey: Self.keepScreenOnDefaultsKey) == nil {
            UserDefaults.standard.set(true, forKey: Self.keepScreenOnDefaultsKey)
        }
        keepScreenOn = UserDefaults.standard.bool(forKey: Self.keepScreenOnDefaultsKey)
        IdleTimerManager.shared.setDisabled(keepScreenOn)
        setupBackgroundSession()
        cleanupOrphanedUploadTempArtifactsOnLaunch()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.isExpensiveNetwork = path.isExpensive
            self.isNetworkAvailable = (path.status == .satisfied)
            self.tusQueue.async {
                self.maybeStartTusWorkers(reason: "path-change")
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "hybrid.upload.network"))
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePowerOrThermalStateChange),
            name: ProcessInfo.thermalStateDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePowerOrThermalStateChange),
            name: NSNotification.Name("NSProcessInfoPowerStateDidChange"),
            object: nil
        )

        // ScenePhase changes are handled in OpenPhotosApp; no UIKit lifecycle observers here.
    }

    @objc
    private func handlePowerOrThermalStateChange() {
        tusQueue.async {
            self.maybeStartTusWorkers(reason: "power-thermal-change")
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func setBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        bgCompletionHandler = handler
    }

    private func setupBackgroundSession() {
        let identifier = "com.openphotos.upload.bg"
        // Create once; keep long-lived. Avoid invalidating while app runs.
        if bgSession != nil { return }
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        if #available(iOS 13.0, *) {
            // Allow tasks to run on expensive/constrained networks; we gate per-task policy.
            config.allowsExpensiveNetworkAccess = true
            config.allowsConstrainedNetworkAccess = true
        }
        // Network policy is applied per-task using allowsExpensiveNetworkAccess & allowsConstrainedNetworkAccess on iOS 13+
        bgSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    private func uploadTempDirectoryURL() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(uploadTempDirectoryName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func uploadTempFileURL(name: String) -> URL {
        uploadTempDirectoryURL().appendingPathComponent(name)
    }

    private func pendingTusCount() -> Int {
        tusQueue.sync { pendingTus.count }
    }

    private func isForegroundTusSuspended() -> Bool {
        tusQueue.sync { foregroundTusSuspended }
    }

    private func setForegroundTusSuspended(_ suspended: Bool, reason: String) {
        tusQueue.sync {
            let previous = foregroundTusSuspended
            guard previous != suspended else { return }
            foregroundTusSuspended = suspended
            if suspended {
                // Scene background: drop in-memory foreground queue and force worker retirement.
                pendingTus.removeAll()
                tusEnqueuedAtUptime.removeAll(keepingCapacity: true)
                liveComponentPendingByContentId.removeAll(keepingCapacity: true)
                tusConcurrencyState.targetWorkers = 0
            } else if activeTusWorkers > 0 && pendingTus.isEmpty {
                // Scene active: recover from stale worker counters after background suspension.
                activeTusWorkers = 0
            }
            AppLog.info(
                AppLog.upload,
                "[PERF] tus-scene-suspend reason=\(reason) suspended=\(suspended ? 1 : 0) active_workers=\(activeTusWorkers) pending=\(pendingTus.count)"
            )
        }
    }

    func handleSceneDidBecomeActive() {
        setForegroundTusSuspended(false, reason: "scene-active")
        tusQueue.async {
            self.maybeStartTusWorkers(reason: "scene-active")
        }
    }

    private func continueProcessBatchWhenBacklogAllows(assets: [PHAsset], startIndex: Int, waitStartedAt: TimeInterval? = nil) {
        if isStopRequested() || isForegroundTusSuspended() { return }
        let pending = pendingTusCount()
        if pending >= maxPendingTusBeforeNextExportBatch {
            print("[SYNC-UPLOAD] Backpressure: pendingTus=\(pending) >= \(maxPendingTusBeforeNextExportBatch); waiting to export next batch")
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + exportBackpressurePollSeconds) { [weak self] in
                self?.continueProcessBatchWhenBacklogAllows(
                    assets: assets,
                    startIndex: startIndex,
                    waitStartedAt: waitStartedAt ?? self?.perfNow()
                )
            }
            return
        }
        if let waitStartedAt {
            let waited = max(0, perfNow() - waitStartedAt)
            perfRecordBackpressureWait(waited)
            AppLog.debug(AppLog.upload, "[PERF] backpressure released start=\(startIndex) waited_ms=\(perfMs(waited)) pendingTus=\(pending)")
        }
        processBatch(assets: assets, startIndex: startIndex)
    }

    private func activeBackgroundBodyNames(from tasks: [URLSessionTask]) -> Set<String> {
        var names: Set<String> = []
        for task in tasks {
            guard let desc = task.taskDescription else { continue }
            let comps = desc.split(separator: "|", omittingEmptySubsequences: false)
            if comps.count >= 2 {
                let body = String(comps[1])
                if !body.isEmpty { names.insert(body) }
            }
        }
        return names
    }

    private func isLegacyUploadArtifactName(_ name: String) -> Bool {
        if name.hasSuffix(".multipart") { return true }
        guard let idx = name.firstIndex(of: "_") else { return false }
        let prefix = String(name[..<idx])
        return UUID(uuidString: prefix) != nil
    }

    private func cleanupUploadTempArtifacts(keepBodyNames: Set<String>) -> (removedCount: Int, removedBytes: Int64) {
        let fm = FileManager.default
        var removedCount = 0
        var removedBytes: Int64 = 0

        func removeIfNeeded(_ url: URL) {
            let name = url.lastPathComponent
            if keepBodyNames.contains(name) { return }
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            do {
                try fm.removeItem(at: url)
                removedCount += 1
                removedBytes += size
            } catch {
                // best effort
            }
        }

        // New scoped temp directory for upload artifacts.
        let scopedDir = uploadTempDirectoryURL()
        if let scopedFiles = try? fm.contentsOfDirectory(at: scopedDir, includingPropertiesForKeys: nil) {
            for url in scopedFiles {
                removeIfNeeded(url)
            }
        }

        // Legacy cleanup from root tmp used by previous app versions.
        let legacyTmp = fm.temporaryDirectory
        if let legacyFiles = try? fm.contentsOfDirectory(at: legacyTmp, includingPropertiesForKeys: nil) {
            for url in legacyFiles where isLegacyUploadArtifactName(url.lastPathComponent) {
                removeIfNeeded(url)
            }
        }

        return (removedCount, removedBytes)
    }

    private func cleanupOrphanedUploadTempArtifactsOnLaunch() {
        guard let bgSession else {
            let cleaned = cleanupUploadTempArtifacts(keepBodyNames: [])
            if cleaned.removedCount > 0 {
                print("[UPLOAD] Startup cleanup removed \(cleaned.removedCount) temp artifact(s), bytes=\(cleaned.removedBytes)")
            }
            return
        }
        bgSession.getAllTasks { [weak self] tasks in
            guard let self else { return }
            let keep = self.activeBackgroundBodyNames(from: tasks)
            let cleaned = self.cleanupUploadTempArtifacts(keepBodyNames: keep)
            if cleaned.removedCount > 0 {
                print("[UPLOAD] Startup cleanup removed \(cleaned.removedCount) orphan temp artifact(s), bytes=\(cleaned.removedBytes)")
            }
        }
    }

    // Enumerate active background tasks for debug UI
    func getBackgroundTasks(completion: @escaping ([BgTaskInfo]) -> Void) {
        if bgSession == nil { setupBackgroundSession() }
        guard let bgSession = bgSession else { completion([]); return }
        bgSession.getAllTasks { tasks in
            let mapped: [BgTaskInfo] = tasks.map { t in
                let st: String
                switch t.state {
                case .running: st = "running"
                case .suspended: st = "suspended"
                case .canceling: st = "canceling"
                case .completed: st = "completed"
                @unknown default: st = "unknown"
                }
                let http = t.response as? HTTPURLResponse
                let desc = t.taskDescription ?? (t.originalRequest?.url?.absoluteString ?? "(no desc)")
                return BgTaskInfo(
                    desc: desc,
                    state: st,
                    sent: t.countOfBytesSent,
                    expected: t.countOfBytesExpectedToSend,
                    responseCode: http?.statusCode
                )
            }
            completion(mapped)
        }
    }

    // MARK: - Public API

    func startUpload(assets: [PHAsset]) {
        // New run begins; clear any previous stop request.
        setStopMode(.none)
        setForegroundTusSuspended(false, reason: "sync-start")
        perfStartRun(totalAssets: assets.count)
        // Ensure token freshness before kicking off uploads
        Task { await AuthManager.shared.refreshIfNeeded() }
        // Ensure TUS client reflects current server URL
        guard let filesURL = URL(string: auth.serverURL + "/files") else { return }
        tusClient = TUSClient(baseURL: filesURL, headersProvider: { [weak self] in
            self?.auth.authHeader() ?? [:]
        }, chunkSize: foregroundTusChunkSizeBytes)

        let effectiveAssets: [PHAsset] = AuthManager.shared.syncPhotosOnly
            ? assets.filter { $0.mediaType != .video }
            : assets
        if effectiveAssets.count != assets.count {
            print("[SYNC-UPLOAD] photosOnly filter: total=\(assets.count) -> \(effectiveAssets.count)")
        }
        print("[SYNC-UPLOAD] Starting batched export+upload. total=\(effectiveAssets.count) batch=\(exportBatchSize)")
        AppLog.info(
            AppLog.upload,
            "[PERF] sync-start assets_total=\(assets.count) assets_effective=\(effectiveAssets.count) min_tus_workers=\(minTusWorkers) max_tus_workers=\(maxTusWorkers) export_batch=\(exportBatchSize) export_parallelism=3 pending_limit=\(maxPendingTusBeforeNextExportBatch)"
        )
        processBatch(assets: effectiveAssets, startIndex: 0)
    }

    func stopCurrentSync() {
        setStopMode(.pause)
        clearDeferredVerificationWork()
        tusQueue.sync {
            for item in items { tusCancelFlags[item.id] = true }
            pendingTus.removeAll()
            tusEnqueuedAtUptime.removeAll(keepingCapacity: true)
            liveComponentPendingByContentId.removeAll(keepingCapacity: true)
        }
        cancelActiveExports()
        DispatchQueue.main.async {
            for idx in self.items.indices {
                switch self.items[idx].status {
                case .queued, .exporting, .uploading:
                    self.items[idx].status = .queued
                    SyncRepository.shared.markPending(contentId: self.items[idx].contentId, note: "Sync paused")
                default:
                    break
                }
            }
        }
    }

    private func processBatch(assets: [PHAsset], startIndex: Int) {
        if isStopRequested() || isForegroundTusSuspended() {
            print("[SYNC-UPLOAD] stop requested; aborting remaining batches")
            return
        }
        if startIndex >= assets.count { return }
        let end = min(startIndex + exportBatchSize, assets.count)
        let slice = Array(assets[startIndex..<end])
        let free = freeSpaceBytes()
        if free >= 0 && free < minFreeSpaceBytes {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            let msg = "Sync paused: low free space (\(formatter.string(fromByteCount: free)) available). Free up space and retry."
            print("[DISK] \(msg)")
            DispatchQueue.main.async { ToastManager.shared.show(msg, duration: 4.0) }
            return
        }
        print("[SYNC-UPLOAD] Exporting batch [\(startIndex)..<\(end)) free=\(free)")
        let batchStart = perfNow()
        let exportStart = batchStart
        exportAssetsToTempFiles(assets: slice) { [weak self] exported in
            guard let self else { return }
            if self.isStopRequested() || self.isForegroundTusSuspended() { return }
            let exportElapsed = max(0, self.perfNow() - exportStart)
            let exportedBytes = exported.reduce(Int64(0)) { $0 + max(0, $1.totalBytes) }
            AppLog.debug(
                AppLog.upload,
                "[PERF] batch-export range=\(startIndex)..<\(end) exported=\(exported.count) bytes=\(exportedBytes) export_ms=\(self.perfMs(exportElapsed)) avg_MBps=\(self.perfMBps(bytes: exportedBytes, seconds: max(exportElapsed, 0.001)))"
            )
            let preflightStart = self.perfNow()
            self.preflightFilterAlreadyBackedUp(exported) { uploadable in
                if self.isStopRequested() || self.isForegroundTusSuspended() { return }
                let preflightElapsed = max(0, self.perfNow() - preflightStart)
                let batchElapsed = max(0, self.perfNow() - batchStart)
                let skipped = max(0, exported.count - uploadable.count)
                self.perfRecordBatch(exportedCount: exported.count, skippedCount: skipped)
                self.perfRecordBatchTimings(exportSeconds: exportElapsed, preflightSeconds: preflightElapsed, batchSeconds: batchElapsed)
                AppLog.debug(
                    AppLog.upload,
                    "[PERF] batch-ready range=\(startIndex)..<\(end) uploadable=\(uploadable.count) skipped_preflight=\(skipped) preflight_ms=\(self.perfMs(preflightElapsed)) batch_total_ms=\(self.perfMs(batchElapsed))"
                )
                DispatchQueue.main.async {
                    self.items.append(contentsOf: uploadable)
                }
                self.enqueueTus(uploadable)
                self.continueProcessBatchWhenBacklogAllows(assets: assets, startIndex: end)
            }
        }
    }

    private func preflightFilterAlreadyBackedUp(
        _ exported: [UploadItem],
        completion: @escaping ([UploadItem]) -> Void
    ) {
        activityQueue.sync { activePreflightChecks += 1 }
        func finish(_ items: [UploadItem]) {
            completion(items)
            self.activityQueue.sync { self.activePreflightChecks = max(0, self.activePreflightChecks - 1) }
        }
        if exported.isEmpty {
            finish([])
            return
        }
        // Build unique lookup IDs from locked/unlocked items.
        var lookupIds: Set<String> = []
        for item in exported {
            let aid = preflightAssetId(for: item)
            if let aid, !aid.isEmpty {
                lookupIds.insert(aid)
            }
        }
        if lookupIds.isEmpty {
            finish(exported)
            return
        }

        Task(priority: .utility) {
            let present: Set<String>
            do {
                present = try await self.existsAssetIdsWithRetry(Array(lookupIds))
            } catch {
                print("[UPLOAD] preflight exists failed; continuing uploads without skip: \(error.localizedDescription)")
                finish(exported)
                return
            }

            if present.isEmpty {
                finish(exported)
                return
            }

            var filtered: [UploadItem] = []
            filtered.reserveCapacity(exported.count)
            var skipped = 0

            for item in exported {
                guard let aid = self.preflightAssetId(for: item), present.contains(aid) else {
                    filtered.append(item)
                    continue
                }
                skipped += 1
                if item.lockedKind == nil || (item.isLocked && item.lockedKind == "orig") {
                    SyncRepository.shared.setLocked(contentId: item.contentId, locked: item.isLocked)
                }
                if self.shouldMarkSyncedInRepository(for: item) {
                    SyncRepository.shared.markSynced(contentId: item.contentId)
                }
                try? FileManager.default.removeItem(at: item.tempFileURL)
                print("[UPLOAD] preflight skip existing asset_id=\(aid) file=\(item.filename)")
            }

            if skipped > 0 {
                print("[UPLOAD] preflight skipped \(skipped) already-backed-up item(s)")
            }
            finish(filtered)
        }
    }

    private func preflightAssetId(for item: UploadItem) -> String? {
        if item.isLocked {
            return item.assetIdB58
        }
        return item.assetId ?? computeAssetId(fileURL: item.tempFileURL)
    }

    private func existsAssetIdsWithRetry(_ assetIds: [String]) async throws -> Set<String> {
        let chunkSize = 200
        var present: Set<String> = []
        var i = 0
        while i < assetIds.count {
            let end = min(i + chunkSize, assetIds.count)
            let chunk = Array(assetIds[i..<end])
            do {
                let found = try await existsAssetIdsChunk(chunk)
                present.formUnion(found)
            } catch {
                if isRetryableNetworkError(error) {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    let found = try await existsAssetIdsChunk(chunk)
                    present.formUnion(found)
                } else {
                    throw error
                }
            }
            i = end
        }
        return present
    }

    private func existsAssetIdsChunk(_ assetIds: [String]) async throws -> Set<String> {
        let started = perfNow()
        do {
            let found = try await ServerPhotosService.shared.existsFullyBackedUp(assetIds: assetIds)
            perfRecordExistsCall(max(0, perfNow() - started))
            return found
        } catch {
            perfRecordExistsCall(max(0, perfNow() - started))
            throw error
        }
    }

    private func isRetryableNetworkError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet, .dnsLookupFailed:
                return true
            default:
                return false
            }
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorTimedOut,
                 NSURLErrorCannotFindHost,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorNotConnectedToInternet,
                 NSURLErrorDNSLookupFailed:
                return true
            default:
                return false
            }
        }
        return false
    }

    private func hasDeferredVerificationWork() -> Bool {
        deferredVerifyStateQueue.sync {
            deferredVerifyLoopTask != nil || !deferredVerifyEntriesByContentId.isEmpty
        }
    }

    func isSyncBusy() -> Bool {
        let activityBusy = activityQueue.sync { activeExportBatches > 0 || activePreflightChecks > 0 }
        let tusBusy = tusQueue.sync { !foregroundTusSuspended && (activeTusWorkers > 0 || !pendingTus.isEmpty) }
        let deferredVerifyBusy = hasDeferredVerificationWork()
        return activityBusy || tusBusy || deferredVerifyBusy
    }

    /// Only mark a content item as synced from its primary upload component.
    /// - Live Photo paired video components should not flip sync to success.
    /// - Locked thumbnails should not flip sync to success (only locked originals do).
    private func shouldMarkSyncedInRepository(for item: UploadItem) -> Bool {
        if item.isLocked {
            return item.lockedKind == nil || item.lockedKind == "orig"
        }
        return !item.isLiveComponent
    }

    private func shouldDelayVerificationForLivePairing(for item: UploadItem) -> Bool {
        guard shouldMarkSyncedInRepository(for: item) else { return false }
        return pendingLiveComponents(forContentId: item.contentId) > 0
    }

    /// Mark synced after server confirmation. If confirmation is temporarily unavailable
    /// (for example while live-photo pairing/ingest is still settling), keep the item pending
    /// and verify again in the background instead of marking it failed immediately.
    private func markSyncedAfterServerVerification(
        for item: UploadItem,
        preferDeferred: Bool = false,
        preferDeferredReason: String? = nil,
        waitForLivePairing: Bool = false
    ) async -> VerifyResult {
        guard shouldMarkSyncedInRepository(for: item) else { return .immediateOk }
        let aid = preflightAssetId(for: item)
        return await markSyncedAfterServerVerification(
            contentId: item.contentId,
            filename: item.filename,
            assetId: aid,
            preferDeferred: preferDeferred,
            preferDeferredReason: preferDeferredReason,
            waitForLivePairing: waitForLivePairing
        )
    }

    private func shouldPreferDeferredVerificationForForeground() -> (prefer: Bool, reason: String) {
        let pending = pendingTusCount()
        if pending >= verifyImmediateBypassPendingThreshold {
            return (true, "backlog")
        }
        return verifyDecisionQueue.sync {
            guard verifyImmediateMissStreak >= verifyImmediateMissStreakBypassThreshold else {
                return (false, "normal")
            }
            verifyPolicyBypassCount += 1
            if verifyPolicyBypassCount % verifyImmediateProbeInterval == 0 {
                return (false, "probe")
            }
            return (true, "miss_streak")
        }
    }

    private func recordImmediateVerifyHit() {
        verifyDecisionQueue.async {
            self.verifyImmediateMissStreak = 0
            self.verifyPolicyBypassCount = 0
        }
    }

    private func recordImmediateVerifyMiss() {
        verifyDecisionQueue.async {
            self.verifyImmediateMissStreak += 1
        }
    }

    private func queueDeferredServerVerification(
        contentId: String,
        filename: String,
        assetId: String,
        waitForLivePairing: Bool = false
    ) {
        deferredVerifyStateQueue.async {
            if self.deferredVerifyEntriesByContentId[contentId] == nil {
                let entry = DeferredVerifyEntry(
                    contentId: contentId,
                    filename: filename,
                    assetId: assetId,
                    waitForLivePairing: waitForLivePairing,
                    attempts: 0,
                    queuedAtUptime: self.perfNow(),
                    timedOutAtUptime: nil,
                    lastPolledAtUptime: 0
                )
                self.deferredVerifyEntriesByContentId[contentId] = entry
                AppLog.debug(
                    AppLog.upload,
                    "[PERF] verify-deferred-enqueue content_id=\(contentId) asset_id=\(assetId) pending_entries=\(self.deferredVerifyEntriesByContentId.count)"
                )
            }
            self.ensureDeferredVerifierLoopRunningLocked()
        }
    }

    private func ensureDeferredVerifierLoopRunningLocked() {
        guard deferredVerifyLoopTask == nil else { return }
        deferredVerifyLoopTask = Task.detached(priority: .utility) { [weak self] in
            await self?.runDeferredVerifierLoop()
        }
    }

    private func runDeferredVerifierLoop() async {
        defer {
            deferredVerifyStateQueue.async {
                self.deferredVerifyLoopTask = nil
            }
        }

        var lastForegroundUploadWorkAtUptime: TimeInterval?
        while !Task.isCancelled {
            let hasForegroundUploadWork = tusQueue.sync { activeTusWorkers > 0 || !pendingTus.isEmpty }
            let livePendingByContent = tusQueue.sync { liveComponentPendingByContentId }
            let busyPollSeconds = deferredBusyPollIntervalSeconds()
            let loopNow = perfNow()
            if hasForegroundUploadWork {
                lastForegroundUploadWorkAtUptime = loopNow
            }
            let pendingEntryCount = deferredVerifyStateQueue.sync { deferredVerifyEntriesByContentId.count }
            let allEntriesTimedOut = deferredVerifyStateQueue.sync {
                !deferredVerifyEntriesByContentId.isEmpty &&
                    deferredVerifyEntriesByContentId.values.allSatisfy { $0.timedOutAtUptime != nil }
            }
            let timedOutRepollBaseSeconds = allEntriesTimedOut
                ? deferredAllTimedOutRepollIntervalSeconds(pendingEntries: pendingEntryCount)
                : deferredTimedOutRepollIntervalSeconds(pendingEntries: pendingEntryCount)
            let timedOutRepollSeconds = applyDeferredIdleTailRepollBoost(
                baseSeconds: timedOutRepollBaseSeconds,
                hasForegroundUploadWork: hasForegroundUploadWork,
                now: loopNow,
                lastForegroundWorkAt: lastForegroundUploadWorkAtUptime
            )
            let idleEntryPollIntervalSeconds = deferredIdleEntryPollIntervalSeconds(
                hasForegroundUploadWork: hasForegroundUploadWork,
                pendingEntries: pendingEntryCount,
                allEntriesTimedOut: allEntriesTimedOut
            )
            let snapshot: [DeferredVerifyEntry] = deferredVerifyStateQueue.sync {
                guard !deferredVerifyEntriesByContentId.isEmpty else { return [] }
                return deferredVerifyEntriesByContentId.values.compactMap { entry in
                    if entry.waitForLivePairing && (livePendingByContent[entry.contentId] ?? 0) > 0 {
                        return nil
                    }
                    let elapsedSinceLastPoll = max(0, loopNow - entry.lastPolledAtUptime)
                    guard let timedOutAt = entry.timedOutAtUptime else {
                        if idleEntryPollIntervalSeconds > 0 && elapsedSinceLastPoll < idleEntryPollIntervalSeconds {
                            return nil
                        }
                        return entry
                    }
                    if hasForegroundUploadWork {
                        return nil
                    }
                    let elapsedSinceTimeout = max(0, loopNow - timedOutAt)
                    guard elapsedSinceTimeout >= timedOutRepollSeconds else {
                        return nil
                    }
                    guard elapsedSinceLastPoll >= timedOutRepollSeconds else {
                        return nil
                    }
                    return entry
                }
            }
            let stillPendingBeforePoll = deferredVerifyStateQueue.sync { !deferredVerifyEntriesByContentId.isEmpty }
            if !stillPendingBeforePoll {
                perfLogDeferredDrain(reason: "drained")
                return
            }
            if snapshot.isEmpty {
                let pollSeconds: TimeInterval
                if hasForegroundUploadWork {
                    pollSeconds = busyPollSeconds
                } else if allEntriesTimedOut {
                    pollSeconds = timedOutRepollSeconds
                } else {
                    pollSeconds = min(
                        timedOutRepollSeconds,
                        max(deferredVerifyPollSecondsIdle, idleEntryPollIntervalSeconds)
                    )
                }
                try? await Task.sleep(nanoseconds: UInt64(pollSeconds * 1_000_000_000))
                continue
            }

            let uniqueAssetIds = Array(Set(snapshot.map { $0.assetId }))
            var present: Set<String> = []
            var pollFailed = false
            do {
                present = try await existsAssetIdsWithRetry(uniqueAssetIds)
            } catch {
                pollFailed = true
                AppLog.debug(
                    AppLog.upload,
                    "[PERF] verify-deferred-poll-failed pending_entries=\(snapshot.count) error=\(error.localizedDescription)"
                )
            }

            var confirmed: [DeferredVerifyEntry] = []
            var timedOut: [DeferredVerifyEntry] = []
            let now = perfNow()
            deferredVerifyStateQueue.sync {
                for snap in snapshot {
                    guard var entry = deferredVerifyEntriesByContentId[snap.contentId] else { continue }
                    if entry.waitForLivePairing && (livePendingByContent[entry.contentId] ?? 0) > 0 {
                        deferredVerifyEntriesByContentId[entry.contentId] = entry
                        continue
                    }
                    entry.lastPolledAtUptime = now
                    if present.contains(entry.assetId) {
                        deferredVerifyEntriesByContentId.removeValue(forKey: entry.contentId)
                        confirmed.append(entry)
                        continue
                    }
                    if pollFailed {
                        deferredVerifyEntriesByContentId[entry.contentId] = entry
                        continue
                    }
                    if entry.timedOutAtUptime != nil {
                        deferredVerifyEntriesByContentId[entry.contentId] = entry
                        continue
                    }
                    entry.attempts += 1
                    let waited = max(0, now - entry.queuedAtUptime)
                    if waited >= deferredVerifyMaxWaitSeconds || entry.attempts >= deferredVerifyMaxAttempts {
                        entry.timedOutAtUptime = now
                        deferredVerifyEntriesByContentId[entry.contentId] = entry
                        timedOut.append(entry)
                    } else {
                        deferredVerifyEntriesByContentId[entry.contentId] = entry
                    }
                }
            }

            for entry in confirmed {
                SyncRepository.shared.markSynced(contentId: entry.contentId)
                perfRecordVerifyDeferredConfirmed()
                let waited = max(0, perfNow() - entry.queuedAtUptime)
                let recoveredAfterTimeout = (entry.timedOutAtUptime != nil) ? 1 : 0
                print("[UPLOAD] deferred verify confirmed asset_id=\(entry.assetId) file=\(entry.filename) attempts=\(entry.attempts + 1)")
                AppLog.debug(
                    AppLog.upload,
                    "[PERF] verify-deferred-confirmed content_id=\(entry.contentId) asset_id=\(entry.assetId) attempts=\(entry.attempts + 1) waited_ms=\(perfMs(waited)) recovered_after_timeout=\(recoveredAfterTimeout)"
                )
            }
            for entry in timedOut {
                perfRecordVerifyDeferredTimedOut()
                let waited = max(0, perfNow() - entry.queuedAtUptime)
                print("[UPLOAD] deferred verify timed out asset_id=\(entry.assetId) file=\(entry.filename); remains pending and will be rechecked")
                AppLog.info(
                    AppLog.upload,
                    "[PERF] verify-deferred-timeout content_id=\(entry.contentId) asset_id=\(entry.assetId) attempts=\(entry.attempts) waited_ms=\(perfMs(waited)) will_retry=1"
                )
            }

            let stillPending = deferredVerifyStateQueue.sync { !deferredVerifyEntriesByContentId.isEmpty }
            if !stillPending {
                perfLogDeferredDrain(reason: "drained")
                return
            }
            let allPendingTimedOut = deferredVerifyStateQueue.sync {
                !deferredVerifyEntriesByContentId.isEmpty && deferredVerifyEntriesByContentId.values.allSatisfy { $0.timedOutAtUptime != nil }
            }
            let pendingAfterCount = deferredVerifyStateQueue.sync { deferredVerifyEntriesByContentId.count }
            let timedOutRepollAfterBaseSeconds = allPendingTimedOut
                ? deferredAllTimedOutRepollIntervalSeconds(pendingEntries: pendingAfterCount)
                : deferredTimedOutRepollIntervalSeconds(pendingEntries: pendingAfterCount)
            let timedOutRepollAfterSeconds = applyDeferredIdleTailRepollBoost(
                baseSeconds: timedOutRepollAfterBaseSeconds,
                hasForegroundUploadWork: hasForegroundUploadWork,
                now: now,
                lastForegroundWorkAt: lastForegroundUploadWorkAtUptime
            )
            let idleEntryPollAfterSeconds = deferredIdleEntryPollIntervalSeconds(
                hasForegroundUploadWork: hasForegroundUploadWork,
                pendingEntries: pendingAfterCount,
                allEntriesTimedOut: allPendingTimedOut
            )
            let pollSeconds: TimeInterval
            if hasForegroundUploadWork {
                pollSeconds = busyPollSeconds
            } else if allPendingTimedOut {
                pollSeconds = timedOutRepollAfterSeconds
            } else {
                pollSeconds = max(deferredVerifyPollSecondsIdle, idleEntryPollAfterSeconds)
            }
            try? await Task.sleep(nanoseconds: UInt64(pollSeconds * 1_000_000_000))
        }
    }

    private func markSyncedAfterServerVerification(
        contentId: String,
        filename: String,
        assetId: String?,
        preferDeferred: Bool = false,
        preferDeferredReason: String? = nil,
        waitForLivePairing: Bool = false
    ) async -> VerifyResult {
        guard let aid = assetId, !aid.isEmpty else {
            let msg = "Upload completed but missing asset_id for verification"
            SyncRepository.shared.markFailed(contentId: contentId, error: msg)
            print("[UPLOAD] verify failed missing-asset-id file=\(filename)")
            return .failed
        }

        if preferDeferred {
            let note = "Awaiting server ingest confirmation"
            SyncRepository.shared.markPending(contentId: contentId, note: note)
            perfRecordVerifyImmediatePolicySkipped()
            perfRecordVerifyDeferredQueued()
            queueDeferredServerVerification(
                contentId: contentId,
                filename: filename,
                assetId: aid,
                waitForLivePairing: waitForLivePairing
            )
            print("[UPLOAD] verify deferred by policy asset_id=\(aid) file=\(filename) reason=\(preferDeferredReason ?? "unspecified")")
            AppLog.debug(
                AppLog.upload,
                "[PERF] verify-deferred-queued content_id=\(contentId) asset_id=\(aid) mode=fast_deferred reason=policy_\(preferDeferredReason ?? "unspecified")"
            )
            return .deferredQueued
        }

        do {
            let present = try await existsAssetIdsWithRetry([aid])
            if present.contains(aid) {
                SyncRepository.shared.markSynced(contentId: contentId)
                perfRecordVerifyImmediateOk()
                recordImmediateVerifyHit()
                AppLog.debug(
                    AppLog.upload,
                    "[PERF] verify-immediate-ok content_id=\(contentId) asset_id=\(aid) mode=fast_deferred"
                )
                return .immediateOk
            }
            recordImmediateVerifyMiss()
            let note = "Awaiting server ingest confirmation"
            SyncRepository.shared.markPending(contentId: contentId, note: note)
            perfRecordVerifyDeferredQueued()
            queueDeferredServerVerification(
                contentId: contentId,
                filename: filename,
                assetId: aid,
                waitForLivePairing: waitForLivePairing
            )
            print("[UPLOAD] verify deferred ingest-confirmation asset_id=\(aid) file=\(filename)")
            AppLog.debug(
                AppLog.upload,
                "[PERF] verify-deferred-queued content_id=\(contentId) asset_id=\(aid) mode=fast_deferred"
            )
            return .deferredQueued
        } catch {
            let note = "Verification request failed: \(error.localizedDescription)"
            SyncRepository.shared.markPending(contentId: contentId, note: note)
            perfRecordVerifyDeferredQueued()
            queueDeferredServerVerification(
                contentId: contentId,
                filename: filename,
                assetId: aid,
                waitForLivePairing: waitForLivePairing
            )
            print("[UPLOAD] verify request failed; deferred file=\(filename) err=\(error.localizedDescription)")
            AppLog.debug(
                AppLog.upload,
                "[PERF] verify-deferred-queued content_id=\(contentId) asset_id=\(aid) mode=fast_deferred reason=request_failed"
            )
            return .deferredQueued
        }
    }

    private func enqueueTus(_ newItems: [UploadItem]) {
        tusQueue.async {
            if self.foregroundTusSuspended {
                AppLog.info(
                    AppLog.upload,
                    "[PERF] tus-enqueue-reroute reason=scene-background items=\(newItems.count)"
                )
                DispatchQueue.global(qos: .utility).async {
                    for item in newItems {
                        self.queueBackgroundMultipart(for: item)
                    }
                }
                return
            }
            let now = self.perfNow()
            for item in newItems {
                self.tusEnqueuedAtUptime[item.id] = now
                self.trackLiveComponentEnqueueIfNeeded(item)
            }
            self.pendingTus.append(contentsOf: newItems)
            AppLog.debug(
                AppLog.upload,
                "[PERF] tus-enqueue added=\(newItems.count) pending=\(self.pendingTus.count) active_workers=\(self.activeTusWorkers)"
            )
            self.maybeStartTusWorkers(reason: "enqueue")
        }
    }

    private func recordTusUploadHealth(
        uploadBytes: Int64,
        uploadSeconds: TimeInterval,
        patchRetries: Int,
        patchTimeouts: Int,
        stallRecoveries: Int
    ) {
        guard uploadSeconds > 0 else { return }
        let uploadMBps = (Double(max(0, uploadBytes)) / (1024.0 * 1024.0)) / uploadSeconds
        let uploadMs = max(0, uploadSeconds * 1000.0)
        tusQueue.sync {
            tusConcurrencyState.uploadSamples += 1
            tusConcurrencyState.ewmaUploadMBps = ewma(
                previous: tusConcurrencyState.ewmaUploadMBps,
                sample: uploadMBps,
                alpha: tusHealthEwmaAlpha
            )
            tusConcurrencyState.ewmaUploadMs = ewma(
                previous: tusConcurrencyState.ewmaUploadMs,
                sample: uploadMs,
                alpha: tusHealthEwmaAlpha
            )
            tusConcurrencyState.ewmaPatchRetriesPerItem = ewma(
                previous: tusConcurrencyState.ewmaPatchRetriesPerItem,
                sample: Double(max(0, patchRetries)),
                alpha: tusHealthEwmaAlpha
            )
            tusConcurrencyState.ewmaPatchTimeoutsPerItem = ewma(
                previous: tusConcurrencyState.ewmaPatchTimeoutsPerItem,
                sample: Double(max(0, patchTimeouts)),
                alpha: tusHealthEwmaAlpha
            )
            tusConcurrencyState.ewmaStallRecoveriesPerItem = ewma(
                previous: tusConcurrencyState.ewmaStallRecoveriesPerItem,
                sample: Double(max(0, stallRecoveries)),
                alpha: tusHealthEwmaAlpha
            )
        }
    }

    private func recordTusCreateHealth(createSeconds: TimeInterval) {
        guard createSeconds > 0 else { return }
        let createMs = max(0, createSeconds * 1000.0)
        tusQueue.sync {
            tusConcurrencyState.createSamples += 1
            tusConcurrencyState.ewmaCreateMs = ewma(
                previous: tusConcurrencyState.ewmaCreateMs,
                sample: createMs,
                alpha: tusHealthEwmaAlpha
            )
        }
    }

    private func preferredTusWorkerCapLocked() -> Int {
        let processInfo = ProcessInfo.processInfo
        let thermal = processInfo.thermalState
        let thermalConstrained = (thermal == .serious || thermal == .critical)
        if !isNetworkAvailable || isExpensiveNetwork || processInfo.isLowPowerModeEnabled || thermalConstrained {
            return minTusWorkers
        }
        return maxTusWorkers
    }

    private func thermalStateLabel(_ thermal: ProcessInfo.ThermalState) -> String {
        switch thermal {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private func maybeStartTusWorkers(reason: String = "unspecified") {
        if foregroundTusSuspended {
            tusConcurrencyState.targetWorkers = 0
            return
        }
        var cap = preferredTusWorkerCapLocked()
        let currentTarget = tusConcurrencyState.targetWorkers
        let pending = pendingTus.count
        let now = perfNow()
        let samples = tusConcurrencyState.uploadSamples
        let ewmaUploadMBps = tusConcurrencyState.ewmaUploadMBps
        let ewmaUploadMs = tusConcurrencyState.ewmaUploadMs
        let createSamples = tusConcurrencyState.createSamples
        let ewmaCreateMs = tusConcurrencyState.ewmaCreateMs
        let ewmaPatchRetries = tusConcurrencyState.ewmaPatchRetriesPerItem
        let ewmaPatchTimeouts = tusConcurrencyState.ewmaPatchTimeoutsPerItem
        let ewmaStallRecoveries = tusConcurrencyState.ewmaStallRecoveriesPerItem
        let hasCreateSamples = createSamples >= tusCreateLatencyGuardMinSamples
        let createLatencySignal = hasCreateSamples &&
            ewmaCreateMs >= tusCreateLatencyGuardEwmaMsThreshold
        let createLatencyReleaseSignal = hasCreateSamples &&
            ewmaCreateMs <= tusCreateLatencyGuardReleaseEwmaMsThreshold
        var createGuardTransition: String?
        if !tusConcurrencyState.createLatencyGuardActive {
            tusConcurrencyState.createLatencyRecoveryStreak = 0
            if createLatencySignal {
                tusConcurrencyState.createLatencySignalStreak += 1
            } else {
                tusConcurrencyState.createLatencySignalStreak = 0
            }
            if tusConcurrencyState.createLatencySignalStreak >= tusCreateLatencyGuardConsecutiveRequired {
                tusConcurrencyState.createLatencyGuardActive = true
                tusConcurrencyState.createLatencyGuardHoldUntilUptime = max(
                    tusConcurrencyState.createLatencyGuardHoldUntilUptime,
                    now + tusCreateLatencyGuardMinHoldSeconds
                )
                createGuardTransition = "enabled"
            }
        } else {
            if createLatencySignal {
                tusConcurrencyState.createLatencyRecoveryStreak = 0
            } else if createLatencyReleaseSignal {
                tusConcurrencyState.createLatencyRecoveryStreak += 1
            } else {
                tusConcurrencyState.createLatencyRecoveryStreak = 0
            }
            let createGuardHoldActive = now < tusConcurrencyState.createLatencyGuardHoldUntilUptime
            if !createGuardHoldActive &&
                tusConcurrencyState.createLatencyRecoveryStreak >= tusCreateLatencyGuardReleaseConsecutiveRequired {
                tusConcurrencyState.createLatencyGuardActive = false
                tusConcurrencyState.createLatencySignalStreak = 0
                tusConcurrencyState.createLatencyRecoveryStreak = 0
                tusConcurrencyState.createLatencyGuardHoldUntilUptime = 0
                createGuardTransition = "disabled"
            }
        }
        let createLatencyGuardActive = tusConcurrencyState.createLatencyGuardActive
        let createGuardHoldMs = perfMs(max(0, tusConcurrencyState.createLatencyGuardHoldUntilUptime - now))
        if createLatencyGuardActive {
            cap = min(cap, minTusWorkers)
        }
        let hasThroughputSamples = samples >= tusThroughputGuardMinSamples
        let transportDownSignal = hasThroughputSamples && (
            ewmaPatchTimeouts >= tusScaleDownTimeoutRateThreshold ||
            ewmaStallRecoveries >= tusScaleDownStallRateThreshold
        )
        let performanceDownSignal = hasThroughputSamples &&
            (ewmaUploadMBps > 0 && ewmaUploadMBps < tusScaleDownEwmaMBpsThreshold) &&
            (ewmaUploadMs >= tusScaleDownEwmaUploadMsThreshold)
        let throughputDownSignal = transportDownSignal
        let throughputUpSignal = hasThroughputSamples && (
            ewmaPatchTimeouts <= tusScaleUpTimeoutRateCeiling &&
            ewmaStallRecoveries <= tusScaleUpStallRateCeiling
        )
        if throughputDownSignal {
            tusConcurrencyState.throughputDownSignalStreak += 1
            tusConcurrencyState.throughputUpSignalStreak = 0
        } else if throughputUpSignal {
            tusConcurrencyState.throughputUpSignalStreak += 1
            tusConcurrencyState.throughputDownSignalStreak = 0
        } else {
            tusConcurrencyState.throughputDownSignalStreak = 0
            tusConcurrencyState.throughputUpSignalStreak = 0
        }
        let downStreakRequired = transportDownSignal
            ? max(1, tusThroughputGuardDownConsecutiveRequired - 1)
            : tusThroughputGuardDownConsecutiveRequired
        let throughputGuardDown = hasThroughputSamples &&
            tusConcurrencyState.throughputDownSignalStreak >= downStreakRequired
        let throughputAllowsScaleUp = !hasThroughputSamples ||
            tusConcurrencyState.throughputUpSignalStreak >= tusThroughputGuardUpConsecutiveRequired
        var throughputGuardHoldActive = now < tusConcurrencyState.throughputGuardHoldUntilUptime
        let throughputGuardRecovered = hasThroughputSamples &&
            !throughputDownSignal &&
            tusConcurrencyState.throughputUpSignalStreak >= tusThroughputGuardRecoveryUpConsecutiveRequired
        if throughputGuardHoldActive && throughputGuardRecovered {
            tusConcurrencyState.throughputGuardHoldUntilUptime = 0
            throughputGuardHoldActive = false
        }
        let cooldownActive = (now - tusConcurrencyState.lastScaleChangeAtUptime) < tusScaleDecisionCooldownSeconds
        let probeHoldActive = (now - tusConcurrencyState.lastProbeScaleUpAtUptime) < tusProbeHighWorkerHoldSeconds
        let recentGuardDownscale = tusConcurrencyState.lastThroughputGuardDownscaleAtUptime > 0 &&
            (now - tusConcurrencyState.lastThroughputGuardDownscaleAtUptime) < tusProbeAfterThroughputGuardCooldownSeconds
        let probePendingThreshold = recentGuardDownscale
            ? max(tusProbeUpPendingThreshold, tusProbeUpPendingThresholdAfterGuard)
            : tusProbeUpPendingThreshold
        let probeEligible = cap > minTusWorkers &&
            currentTarget == minTusWorkers &&
            pending >= probePendingThreshold &&
            hasThroughputSamples &&
            !throughputDownSignal &&
            !recentGuardDownscale &&
            !throughputGuardHoldActive &&
            throughputAllowsScaleUp
        let probeDue = probeEligible &&
            (now - tusConcurrencyState.lastProbeScaleUpAtUptime) >= tusProbeUpIntervalSeconds &&
            !cooldownActive
        if let createGuardTransition {
            AppLog.info(
                AppLog.upload,
                "[PERF] tus-create-guard reason=\(reason) state=\(createGuardTransition) active=\(createLatencyGuardActive ? 1 : 0) create_samples=\(createSamples) create_signal_streak=\(tusConcurrencyState.createLatencySignalStreak) create_recovery_streak=\(tusConcurrencyState.createLatencyRecoveryStreak) ewma_create_ms=\(Int(ewmaCreateMs.rounded())) hold_ms=\(createGuardHoldMs) pending=\(pending) target=\(currentTarget)"
            )
        }
        let nextTarget: Int
        let decisionReason: String
        if cap <= minTusWorkers {
            nextTarget = minTusWorkers
            decisionReason = createLatencyGuardActive ? "create_latency_guard" : "safety_gate"
        } else if currentTarget >= cap {
            if pending <= tusScaleDownPendingThreshold {
                nextTarget = minTusWorkers
                decisionReason = "backlog_low"
            } else if probeHoldActive && throughputGuardDown && !transportDownSignal {
                nextTarget = cap
                decisionReason = "probe_hold"
            } else if throughputGuardDown {
                nextTarget = minTusWorkers
                decisionReason = "throughput_guard"
            } else {
                nextTarget = cap
                decisionReason = "hold"
            }
        } else {
            if pending < tusScaleUpPendingThreshold {
                nextTarget = minTusWorkers
                decisionReason = "backlog_low"
            } else if throughputGuardHoldActive {
                nextTarget = minTusWorkers
                decisionReason = "guard_hold"
            } else if probeDue {
                nextTarget = cap
                decisionReason = "probe_up"
            } else if cooldownActive {
                nextTarget = minTusWorkers
                decisionReason = "cooldown"
            } else if !throughputAllowsScaleUp {
                nextTarget = minTusWorkers
                decisionReason = hasThroughputSamples ? "throughput_hold" : "warmup_hold"
            } else {
                nextTarget = cap
                decisionReason = "backlog_high"
            }
        }

        if nextTarget != currentTarget {
            tusConcurrencyState.targetWorkers = nextTarget
            tusConcurrencyState.lastScaleChangeAtUptime = now
            if decisionReason == "probe_up" {
                tusConcurrencyState.lastProbeScaleUpAtUptime = now
            }
            if decisionReason == "throughput_guard" {
                tusConcurrencyState.throughputGuardHoldUntilUptime = max(
                    tusConcurrencyState.throughputGuardHoldUntilUptime,
                    now + tusThroughputGuardRecoveryHoldSeconds
                )
                tusConcurrencyState.lastThroughputGuardDownscaleAtUptime = now
            } else if nextTarget >= cap {
                tusConcurrencyState.throughputGuardHoldUntilUptime = 0
            }
            perfRecordWorkerScale(target: nextTarget, previous: currentTarget, reason: decisionReason)
            let processInfo = ProcessInfo.processInfo
            let guardHoldMs = perfMs(max(0, tusConcurrencyState.throughputGuardHoldUntilUptime - now))
            let guardHoldActiveForLog = tusConcurrencyState.throughputGuardHoldUntilUptime > now
            AppLog.info(
                AppLog.upload,
                "[PERF] tus-concurrency reason=\(reason) decision=\(decisionReason) target=\(nextTarget) previous=\(currentTarget) active=\(activeTusWorkers) pending=\(pending) samples=\(samples) create_samples=\(createSamples) create_guard=\(createLatencyGuardActive ? 1 : 0) create_signal=\(createLatencySignal ? 1 : 0) create_release_signal=\(createLatencyReleaseSignal ? 1 : 0) create_signal_streak=\(tusConcurrencyState.createLatencySignalStreak) create_recovery_streak=\(tusConcurrencyState.createLatencyRecoveryStreak) create_guard_hold_ms=\(createGuardHoldMs) ewma_create_ms=\(Int(ewmaCreateMs.rounded())) throughput_down_signal=\(throughputDownSignal ? 1 : 0) performance_down_signal=\(performanceDownSignal ? 1 : 0) transport_down_signal=\(transportDownSignal ? 1 : 0) throughput_up_signal=\(throughputUpSignal ? 1 : 0) throughput_down_streak=\(tusConcurrencyState.throughputDownSignalStreak) throughput_up_streak=\(tusConcurrencyState.throughputUpSignalStreak) down_streak_required=\(downStreakRequired) probe_pending_threshold=\(probePendingThreshold) probe_recent_guard_cooldown=\(recentGuardDownscale ? 1 : 0) probe_due=\(probeDue ? 1 : 0) probe_hold=\(probeHoldActive ? 1 : 0) guard_hold=\(guardHoldActiveForLog ? 1 : 0) guard_hold_ms=\(guardHoldMs) ewma_upload_MBps=\(String(format: "%.2f", ewmaUploadMBps)) ewma_upload_ms=\(Int(ewmaUploadMs.rounded())) ewma_patch_retries=\(String(format: "%.2f", ewmaPatchRetries)) ewma_patch_timeouts=\(String(format: "%.2f", ewmaPatchTimeouts)) ewma_stall_recoveries=\(String(format: "%.2f", ewmaStallRecoveries)) network=\(isNetworkAvailable ? 1 : 0) expensive=\(isExpensiveNetwork ? 1 : 0) low_power=\(processInfo.isLowPowerModeEnabled ? 1 : 0) thermal=\(thermalStateLabel(processInfo.thermalState))"
            )
        }

        while activeTusWorkers < tusConcurrencyState.targetWorkers && !pendingTus.isEmpty {
            activeTusWorkers += 1
            AppLog.debug(
                AppLog.upload,
                "[PERF] tus-worker-start active_workers=\(activeTusWorkers) target_workers=\(tusConcurrencyState.targetWorkers) pending=\(pendingTus.count)"
            )
            Task.detached { [weak self] in
                await self?.runTusWorker()
            }
        }
    }

    private func nextTusItem() -> (item: UploadItem, queueWait: TimeInterval?)? {
        var result: (item: UploadItem, queueWait: TimeInterval?)?
        tusQueue.sync {
            guard !foregroundTusSuspended else { return }
            guard !pendingTus.isEmpty else { return }
            let item = pendingTus.removeFirst()
            let enqueuedAt = tusEnqueuedAtUptime.removeValue(forKey: item.id)
            let queueWait = enqueuedAt.map { max(0, self.perfNow() - $0) }
            result = (item: item, queueWait: queueWait)
        }
        return result
    }

    private func retireWorkerIfOverTarget() -> Bool {
        var retired = false
        var shouldLogSummary = false
        tusQueue.sync {
            if activeTusWorkers > tusConcurrencyState.targetWorkers {
                activeTusWorkers = max(0, activeTusWorkers - 1)
                retired = true
                AppLog.debug(
                    AppLog.upload,
                    "[PERF] tus-worker-stop reason=scale_down active_workers=\(activeTusWorkers) target_workers=\(tusConcurrencyState.targetWorkers) pending=\(pendingTus.count)"
                )
                shouldLogSummary = (activeTusWorkers == 0 && pendingTus.isEmpty)
            }
        }
        if shouldLogSummary {
            perfLogSummary(reason: "foreground-idle", force: true)
        }
        return retired
    }

    private func finishWorker(reason: String = "idle") {
        var shouldLogSummary = false
        tusQueue.sync {
            activeTusWorkers = max(0, activeTusWorkers - 1)
            AppLog.debug(
                AppLog.upload,
                "[PERF] tus-worker-stop reason=\(reason) active_workers=\(activeTusWorkers) target_workers=\(tusConcurrencyState.targetWorkers) pending=\(pendingTus.count)"
            )
            shouldLogSummary = (activeTusWorkers == 0 && pendingTus.isEmpty)
        }
        if shouldLogSummary {
            perfLogSummary(reason: "foreground-idle", force: true)
        }
    }

    private func runTusWorker() async {
        while true {
            if retireWorkerIfOverTarget() { return }
            guard let next = nextTusItem() else {
                finishWorker(reason: "idle")
                return
            }
            await performTusUpload(next.item, queueWait: next.queueWait)
            perfLogSummary(reason: "foreground-progress")
            tusQueue.sync {
                maybeStartTusWorkers(reason: "post-item")
            }
        }
    }

    func cancelAllForeground() {
        tusQueue.sync {
            for item in items { tusCancelFlags[item.id] = true }
        }
    }

    // Stop current foreground sync work so a fresh ReSync pass can restart immediately.
    // This intentionally does not queue background uploads for canceled foreground items.
    func stopForResync() {
        setStopMode(.resync)
        clearDeferredVerificationWork()
        tusQueue.sync {
            for item in items { tusCancelFlags[item.id] = true }
            pendingTus.removeAll()
            tusEnqueuedAtUptime.removeAll(keepingCapacity: true)
            liveComponentPendingByContentId.removeAll(keepingCapacity: true)
        }
        cancelActiveExports()
        DispatchQueue.main.async {
            for idx in self.items.indices {
                switch self.items[idx].status {
                case .queued, .exporting, .uploading:
                    self.items[idx].status = .canceled
                default:
                    break
                }
            }
        }
    }

    func switchToBackgroundUploads() {
        setForegroundTusSuspended(true, reason: "scene-background")
        // Cancel foreground uploads and queue background tasks for incomplete items
        cancelAllForeground()
        // Cancel any active Photos export requests (iCloud downloads) to avoid background work
        cancelActiveExports()
        // Ensure we have a valid background session to accept tasks
        setupBackgroundSession()
        // Only queue background upload for items that have a finished export (.queued) or were uploading.
        // Avoid queueing for .exporting to prevent reading partial temp files.
        let pending = items.filter { $0.status == .queued || $0.status == .uploading }
        print("[UPLOAD] Queueing background multipart for \(pending.count) pending item(s)")
        if pending.isEmpty { return }
        // Request a short background time window to finish enqueuing tasks as the app backgrounds
        let bt = BackgroundTaskManager.shared.begin("com.openphotos.enqueue-bg-uploads")
        DispatchQueue.global(qos: .userInitiated).async {
            for item in pending { self.queueBackgroundMultipart(for: item) }
            BackgroundTaskManager.shared.end(bt)
        }
    }

    // MARK: - Exporting assets

    private func exportAssetsToTempFiles(assets: [PHAsset], completion: @escaping ([UploadItem]) -> Void) {
        activityQueue.sync { activeExportBatches += 1 }
        var results: [UploadItem] = []
        let group = DispatchGroup()
        let manager = PHAssetResourceManager.default()

        // Run the exporting loop off the main thread so semaphores and file IO don't block UI
        DispatchQueue.global(qos: .userInitiated).async {
            for asset in assets {
                // Pre-read asset metadata on a background queue (PhotoKit objects are thread-safe).
                let creationTs: Int64 = Int64(asset.creationDate?.timeIntervalSince1970 ?? Date().timeIntervalSince1970)
                let pxW: Int = Int(asset.pixelWidth)
                let pxH: Int = Int(asset.pixelHeight)
                let resources = PHAssetResource.assetResources(for: asset)
                var primary: PHAssetResource?
                var pairedMov: PHAssetResource?

                // Ensure Live Photos always export the still image in addition to the paired video
                let isLiveAsset = asset.mediaSubtypes.contains(.photoLive)

                if isLiveAsset {
                    // Prefer a still photo for primary
                    for res in resources {
                        if res.type == .photo || res.type == .fullSizePhoto || res.type == .alternatePhoto {
                            primary = primary ?? res
                        }
                        if res.type == .pairedVideo { pairedMov = res }
                    }
                    // Fallbacks
                    if primary == nil {
                        for res in resources {
                            if res.type == .photo || res.type == .fullSizePhoto || res.type == .alternatePhoto { primary = res; break }
                        }
                    }
                    if pairedMov == nil {
                        for res in resources {
                            if res.type == .video || res.type == .fullSizeVideo { pairedMov = res; break }
                        }
                    }
                } else {
                    for res in resources {
                        if res.type == .photo || res.type == .fullSizePhoto || res.type == .alternatePhoto {
                            primary = primary ?? res
                        } else if res.type == .video || res.type == .fullSizeVideo {
                            primary = primary ?? res
                        } else if res.type == .pairedVideo {
                            pairedMov = res
                        }
                    }
                }

                func enqueue(_ resource: PHAssetResource, isLive: Bool) {
                    group.enter()
                    self.exportSemaphore.wait()
                    print("[EXPORT] start asset=\(asset.localIdentifier) file=\(resource.originalFilename) type=\(resource.type.rawValue)")
                    self.exportResource(manager: manager, resource: resource, asset: asset, preCreationTs: creationTs, prePixelWidth: pxW, prePixelHeight: pxH, isLiveComponent: isLive) { items in
                        if !items.isEmpty { self.exportResultsQueue.sync { results.append(contentsOf: items) } }
                        self.exportSemaphore.signal()
                        print("[EXPORT] done asset=\(asset.localIdentifier) file=\(resource.originalFilename)")
                        group.leave()
                    }
                }

                if let p = primary { enqueue(p, isLive: false) }
                if let v = pairedMov { enqueue(v, isLive: true) }
            }

            group.notify(queue: .main) {
                completion(results)
                self.activityQueue.sync { self.activeExportBatches = max(0, self.activeExportBatches - 1) }
            }
        }
    }

    private func exportResource(manager: PHAssetResourceManager, resource: PHAssetResource, asset: PHAsset, preCreationTs: Int64, prePixelWidth: Int, prePixelHeight: Int, isLiveComponent: Bool, completion: @escaping ([UploadItem]) -> Void) {
        let exportStartedAt = perfNow()
        let filename = resource.originalFilename
        let isVideo = resource.type == .video || resource.type == .fullSizeVideo || resource.type == .pairedVideo
        var mime: String
        if isVideo {
            mime = "video/quicktime"
        } else {
            mime = stillImageMimeType(for: filename)
        }
        let lower = filename.lowercased()
        // Snapshot favorite flag from the asset (PhotoKit objects are thread-safe)
        let favFlag = asset.isFavorite

        let tmpDir = uploadTempDirectoryURL()
        var destURL = tmpDir.appendingPathComponent(UUID().uuidString + "_" + filename)
        // Key for tracking iCloud download state and cancellation
        let key = asset.localIdentifier + "|" + filename

        let opts = PHAssetResourceRequestOptions()
        // Respect cellular policy for foreground iCloud downloads
        // If on an expensive network and user disallows cellular for this media type, do not allow Photos to fetch from network.
        let allowCellular = isVideo ? AuthManager.shared.syncUseCellularVideos : AuthManager.shared.syncUseCellularPhotos
        let allowNetwork = !isExpensiveNetwork || allowCellular
        opts.isNetworkAccessAllowed = allowNetwork
        opts.progressHandler = { progress in
            // 0..1 progress while Photos downloads from iCloud
            let pct = Int(progress * 100)
            self.exportRequestsQueue.async {
                // Log at most every ~2s, or when we cross the next 10% boundary.
                let now = ProcessInfo.processInfo.systemUptime
                let prev = self.icloudProgressLogByKey[key]
                let shouldLog: Bool = {
                    guard let prev else { return true }
                    if pct == 0 || pct == 100 { return true }
                    if pct >= prev.pct + 10 { return true }
                    return (now - prev.lastAt) >= 2.0
                }()
                if shouldLog {
                    self.icloudProgressLogByKey[key] = (pct: pct, lastAt: now)
                    AppLog.debug(AppLog.export, "iCloud progress file=\(filename) pct=\(pct)")
                }
                if progress > 0 && progress < 1 {
                    if !self.icloudDownloadingKeys.contains(key) {
                        self.icloudDownloadingKeys.insert(key)
                        DispatchQueue.main.async { self.icloudDownloadingCount = self.icloudDownloadingKeys.count }
                    }
                }
            }
        }

        // Prepare destination file for writing
        FileManager.default.createFile(atPath: destURL.path, contents: nil, attributes: nil)
        guard let handle = try? FileHandle(forWritingTo: destURL) else {
            completion([]); return
        }
        // Helper to derive a stable content_id per PHAsset (same for HEIC+paired MOV)
        func contentIdForAsset(_ asset: PHAsset) -> String {
            let raw = Data((asset.localIdentifier).utf8)
            let digest = Insecure.MD5.hash(data: raw)
            return Base58.encode(Data(digest))
        }
        // Register request so we can cancel on background
        let writingRequest = manager.requestData(for: resource, options: opts) { data in
            try? handle.write(contentsOf: data)
        } completionHandler: { error in
            try? handle.close()
            func logExportPerf(status: String, inputBytes: Int64, outputItems: Int, outputBytes: Int64) {
                let elapsed = max(0, self.perfNow() - exportStartedAt)
                let effectiveBytes = max(Int64(0), outputBytes > 0 ? outputBytes : inputBytes)
                let line = "[PERF] export-item asset=\(asset.localIdentifier) file=\(filename) type=\(isVideo ? "video" : "photo") status=\(status) elapsed_ms=\(self.perfMs(elapsed)) in_bytes=\(max(Int64(0), inputBytes)) out_items=\(outputItems) out_bytes=\(max(Int64(0), outputBytes)) allow_network=\(allowNetwork ? 1 : 0) throughput_MBps=\(self.perfMBps(bytes: effectiveBytes, seconds: max(elapsed, 0.001)))"
                AppLog.debug(AppLog.export, line)
                if status != "ok" || elapsed >= 8.0 {
                    AppLog.info(AppLog.export, line)
                }
            }
            // Unregister request id
            self.exportRequestsQueue.async {
                self.activeExportRequests.removeValue(forKey: key)
                self.icloudProgressLogByKey.removeValue(forKey: key)
                // Clear downloading indicator for this key
                if self.icloudDownloadingKeys.remove(key) != nil {
                    DispatchQueue.main.async { self.icloudDownloadingCount = self.icloudDownloadingKeys.count }
                }
                // Clear pending indicator if present
                if self.icloudPendingKeys.remove(key) != nil {
                    DispatchQueue.main.async { self.icloudPendingCount = self.icloudPendingKeys.count }
                }
            }
            if let error = error {
                print("Export error: \(error.localizedDescription)")
                logExportPerf(status: "error", inputBytes: 0, outputItems: 0, outputBytes: 0)
                if !allowNetwork && self.isExpensiveNetwork {
                    // Likely in-cloud and network access disallowed by policy
                    DispatchQueue.main.async { ToastManager.shared.show("Skipped iCloud download on cellular (\(isVideo ? "video" : "photo"))") }
                    // Count as iCloud pending for UI purposes (track per key)
                    self.exportRequestsQueue.async {
                        if self.icloudPendingKeys.insert(key).inserted {
                            DispatchQueue.main.async { self.icloudPendingCount = self.icloudPendingKeys.count }
                        }
                    }
                }
                try? FileManager.default.removeItem(at: destURL)
                completion([])
                return
            }
            // Get size
            var size = (try? FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? NSNumber)?.int64Value ?? 0
            // Compute content_id per PHAsset so HEIC and paired MOV share the same id
            let cid = contentIdForAsset(asset)
            // If Photos gave us a HEIF container with a misleading .jpg/.jpeg name, normalize to JPEG
            if !isVideo && (lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg")) {
                if let src = CGImageSourceCreateWithURL(destURL as CFURL, nil),
                   let type = CGImageSourceGetType(src) as String?,
                   type.lowercased().contains("heic") || type.lowercased().contains("heif") {
                    if let conv = self.convertHEICtoJPEG(inputURL: destURL, quality: 0.9) {
                        destURL = conv.url
                        mime = "image/jpeg"
                        size = (try? FileManager.default.attributesOfItem(atPath: conv.url.path)[.size] as? NSNumber)?.int64Value ?? size
                    } else {
                        print("[EXPORT] HEIC->JPEG normalize failed for \(filename); server may not be able to decode")
                    }
                }
            }

            // Log resources for diagnostics
            let resList = PHAssetResource.assetResources(for: asset)
            if !resList.isEmpty {
                var kinds: [String] = []
                for r in resList {
                    let t: String
                    switch r.type {
                    case .photo: t = "photo"
                    case .fullSizePhoto: t = "fullSizePhoto"
                    case .alternatePhoto: t = "alternatePhoto"
                    case .video: t = "video"
                    case .fullSizeVideo: t = "fullSizeVideo"
                    case .pairedVideo: t = "pairedVideo"
                    case .adjustmentData: t = "adjustmentData"
                    default: t = "other(\(r.type.rawValue))"
                    }
                    kinds.append("\(t):\(r.originalFilename)")
                }
                print("[EXPORT] resources asset=\(asset.localIdentifier) -> \(kinds.joined(separator: ", "))")
            }

            // Try to fetch adjustment data to discover embedded captions in edits (best-effort)
            if let adj = resList.first(where: { $0.type == .adjustmentData }) {
                let optsAdj = PHAssetResourceRequestOptions()
                optsAdj.isNetworkAccessAllowed = true
                var collected = Data()
                let _ = manager.requestData(for: adj, options: optsAdj, dataReceivedHandler: { chunk in
                    collected.append(chunk)
                }, completionHandler: { err in
                    if let err = err {
                        print("[EXIF] ADJUSTMENT read error for \(adj.originalFilename): \(err.localizedDescription)")
                    } else {
                        if collected.count > 0 {
                            let preview = collected.prefix(256)
                            let hex = preview.map { String(format: "%02x", $0) }.joined()
                            let str = String(data: preview, encoding: .utf8)
                            print("[EXIF] ADJUSTMENT bytes=\(collected.count) utf8_preview='\(str ?? "<binary>")' hex_preview=\(hex)")
                        } else {
                            print("[EXIF] ADJUSTMENT empty data")
                        }
                    }
                })
            }

            // Log metadata and EXIF/QuickTime tags for diagnostics; also attempt to extract caption/description
            let extracted = self.extractCaptionDescription(fileURL: destURL, isVideo: isVideo)
            self.logExportedMetadata(fileURL: destURL, isVideo: isVideo, asset: asset, resource: resource, preCreationTs: preCreationTs, size: size)
            if let c = extracted.caption, !c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let snippet = c.count > 200 ? (String(c.prefix(200)) + "…") : c
                print("[UPLOAD] CAPTION asset=\(asset.localIdentifier) file=\(filename) caption='\(snippet)'")
            } else {
                print("[UPLOAD] CAPTION asset=\(asset.localIdentifier) file=\(filename) caption='(none)'")
            }
            if let d = extracted.description, !d.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let snippet = d.count > 200 ? (String(d.prefix(200)) + "…") : d
                print("[UPLOAD] DESCRIPTION asset=\(asset.localIdentifier) file=\(filename) description='\(snippet)'")
            }
            // Build album paths JSON if enabled
            var albumJSON: String? = nil
            let preserve = AuthManager.shared.syncPreserveAlbum
            if preserve {
                let onlySelected = AuthManager.shared.syncScope == .selectedAlbums
                let paths = AlbumService.shared.getAlbumPathsForAsset(assetLocalIdentifier: asset.localIdentifier, onlySyncEnabled: onlySelected)
                if let data = try? JSONSerialization.data(withJSONObject: paths, options: []) {
                    albumJSON = String(data: data, encoding: .utf8)
                }
            }
            // Use pre-read creation timestamp and dimensions
            let cts = preCreationTs

            // Determine if this asset is locked based on album flags
            let onlySelectedScope = AuthManager.shared.syncScope == .selectedAlbums
            let shouldLock = AlbumService.shared.isAssetLocked(assetLocalIdentifier: asset.localIdentifier, scopeSelectedOnly: onlySelectedScope)

            if shouldLock {
                // Ensure UMK is available; if not, prompt unlock via UI (envelope)
                if !self.ensureUMKAvailableForLocked() {
                    print("[LOCKED] UMK not available even after prompt; skipping locked encryption for \(filename)")
                    logExportPerf(status: "locked-no-umk", inputBytes: size, outputItems: 0, outputBytes: 0)
                    completion([])
                    return
                }
                // Encrypt original (HEIC->JPEG first for images), and produce encrypted thumbnail
                guard let userId = AuthManager.shared.userId, let umk = E2EEManager.shared.umk, umk.count == 32 else {
                    logExportPerf(status: "locked-missing-keys", inputBytes: size, outputItems: 0, outputBytes: 0)
                    completion([])
                    return
                }

                // Prepare plaintext to encrypt
                var plainURL = destURL
                var plainMime = mime
                var pxW = prePixelWidth
                var pxH = prePixelHeight
                var durationSec: Int = 0
                if isVideo {
                    // Update duration and size if needed
                    let av = AVURLAsset(url: destURL)
                    durationSec = Int(round(CMTimeGetSeconds(av.duration)))
                } else {
                    // If HEIC, convert to JPEG first
                    if filename.lowercased().hasSuffix(".heic") || mime == "image/heic" || mime == "image/heif" {
                        if let conv = self.convertHEICtoJPEG(inputURL: destURL, quality: 0.9) {
                            plainURL = conv.url
                            plainMime = "image/jpeg"
                            pxW = conv.width
                            pxH = conv.height
                        }
                    }
                }

                // Build headerPlain metadata (JSONValue) and TUS locked metadata (String)
                let ymd: String = {
                    let d = Date(timeIntervalSince1970: TimeInterval(cts))
                    let cal = Calendar(identifier: .gregorian)
                    let c = cal.dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: d)
                    let y = c.year ?? 1970; let m = String(format: "%02d", c.month ?? 1); let dd = String(format: "%02d", c.day ?? 1)
                    return "\(y)-\(m)-\(dd)"
                }()
                let plainSize = (try? FileManager.default.attributesOfItem(atPath: plainURL.path)[.size] as? NSNumber)?.int64Value ?? size
                var headerMeta: [String: JSONValue] = [
                    "capture_ymd": .string(ymd),
                    "size_kb": .number(Double(max(1, Int(round(Double(plainSize)/1024.0))))),
                    "width": .number(Double(pxW)),
                    "height": .number(Double(pxH)),
                    "orientation": .number(Double(1)),
                    "is_video": .number(isVideo ? 1 : 0),
                    "duration_s": .number(Double(isVideo ? durationSec : 0)),
                    "mime_hint": .string(isVideo ? (plainMime) : plainMime),
                    "kind": .string("orig"),
                ]
                var tusLockedMeta: [String: String] = [
                    "capture_ymd": ymd,
                    "size_kb": String(max(1, Int(round(Double(plainSize)/1024.0)))),
                    "width": String(pxW),
                    "height": String(pxH),
                    "orientation": "1",
                    "is_video": isVideo ? "1" : "0",
                    "duration_s": String(isVideo ? durationSec : 0),
                    "mime_hint": isVideo ? plainMime : plainMime,
                    "created_at": String(cts),
                ]
                if let bid = self.computeBackupId(fileURL: plainURL) {
                    tusLockedMeta["backup_id"] = bid
                }
                // Optional metadata (user-controlled)
                let prefs = SecurityPreferences.shared
                if prefs.includeCaption, let cap = extracted.caption, !cap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    tusLockedMeta["caption"] = cap
                    headerMeta["caption"] = .string(cap)
                }
                if prefs.includeDescription, let des = extracted.description, !des.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    tusLockedMeta["description"] = des
                    headerMeta["description"] = .string(des)
                }
                // Optional: GPS from PHAsset (coordinates only; server handles reverse-geocoding)
                if prefs.includeLocation, let loc = asset.location {
                    headerMeta["latitude"] = .number(loc.coordinate.latitude)
                    headerMeta["longitude"] = .number(loc.coordinate.longitude)
                    tusLockedMeta["latitude"] = String(loc.coordinate.latitude)
                    tusLockedMeta["longitude"] = String(loc.coordinate.longitude)
                    if loc.altitude != 0 { headerMeta["altitude"] = .number(loc.altitude); tusLockedMeta["altitude"] = String(loc.altitude) }
                }

                // Ensure local sync row exists so markUploading/markSynced can update state even after app restarts
                SyncRepository.shared.upsertPhoto(
                    contentId: cid,
                    localIdentifier: asset.localIdentifier,
                    mediaType: isVideo ? 1 : 0,
                    creationTs: cts,
                    pixelWidth: prePixelWidth,
                    pixelHeight: prePixelHeight,
                    estimatedBytes: plainSize
                )

                // Encrypt original to .pae3
                let outOrig = self.uploadTempFileURL(name: UUID().uuidString + ".pae3")
                var origAssetIdB58: String? = nil
                var lockedBatchItems: [UploadItem] = []
                do {
                    let info = try pae3EncryptFileReturningInfo(umk: umk, userIdKey: Data(userId.utf8), input: plainURL, output: outOrig, headerMetadata: headerMeta, chunkSize: PAE3_DEFAULT_CHUNK_SIZE)
                    origAssetIdB58 = info.assetIdB58
                    let lockedItem = UploadItem(
                        assetLocalIdentifier: asset.localIdentifier,
                        filename: info.assetIdB58 + ".pae3",
                        mimeType: "application/octet-stream",
                        isVideo: isVideo,
                        isLiveComponent: isLiveComponent,
                        isFavorite: favFlag,
                        contentId: cid,
                        creationTs: cts,
                        albumPathsJSON: albumJSON,
                        caption: nil,
                        longDescription: nil,
                        totalBytes: (try? FileManager.default.attributesOfItem(atPath: info.containerURL.path)[.size] as? NSNumber)?.int64Value ?? 0,
                        status: .queued,
                        tempFileURL: info.containerURL,
                        assetId: info.assetIdB58,
                        isLocked: true,
                        lockedKind: "orig",
                        assetIdB58: info.assetIdB58,
                        outerHeaderB64Url: info.outerHeaderB64Url,
                        lockedMetadata: tusLockedMeta
                    )
                    lockedBatchItems.append(lockedItem)
                } catch {
                    print("[LOCKED] Encrypt orig failed: \(error.localizedDescription)")
                }

                // Generate and encrypt thumbnail
                if let t = isVideo ? self.generateVideoThumbnail(url: plainURL) : self.generateImageThumbnail(url: plainURL, maxDim: 512) {
                    var tMeta = headerMeta; tMeta["kind"] = .string("thumb")
                    var tTus = tusLockedMeta; tTus["mime_hint"] = "image/jpeg"; tTus["width"] = String(t.width); tTus["height"] = String(t.height); tTus["size_kb"] = String(max(1, Int(round(Double(t.size)/1024.0))))
                    let outT = self.uploadTempFileURL(name: UUID().uuidString + "_t.pae3")
                    do {
                        let infoT = try pae3EncryptFileReturningInfo(umk: umk, userIdKey: Data(userId.utf8), input: t.url, output: outT, headerMetadata: tMeta, chunkSize: 256 * 1024)
                        let assetIdForThumb = origAssetIdB58 ?? infoT.assetIdB58
                        let thumbItem = UploadItem(
                            assetLocalIdentifier: asset.localIdentifier,
                            filename: assetIdForThumb + "_t.pae3",
                            mimeType: "application/octet-stream",
                            isVideo: isVideo,
                            isLiveComponent: isLiveComponent,
                            isFavorite: favFlag,
                            contentId: cid,
                            creationTs: cts,
                            albumPathsJSON: albumJSON,
                            caption: nil,
                            longDescription: nil,
                            totalBytes: (try? FileManager.default.attributesOfItem(atPath: infoT.containerURL.path)[.size] as? NSNumber)?.int64Value ?? 0,
                            status: .queued,
                            tempFileURL: infoT.containerURL,
                            assetId: assetIdForThumb,
                            isLocked: true,
                            lockedKind: "thumb",
                            // Pair the thumbnail with the original's asset id (match web client behavior)
                            assetIdB58: assetIdForThumb,
                            outerHeaderB64Url: infoT.outerHeaderB64Url,
                            lockedMetadata: tTus
                        )
                        lockedBatchItems.append(thumbItem)
                    } catch {
                        print("[LOCKED] Encrypt thumb failed: \(error.localizedDescription)")
                    }
                    // Cleanup temp thumb plaintext
                    try? FileManager.default.removeItem(at: t.url)
                }

                // Cleanup plaintext copy if we converted HEIC
                if plainURL != destURL { try? FileManager.default.removeItem(at: plainURL) }
                // Remove original exported file to avoid duplicate upload
                try? FileManager.default.removeItem(at: destURL)
                let totalLockedBytes = lockedBatchItems.reduce(Int64(0)) { $0 + max(Int64(0), $1.totalBytes) }
                logExportPerf(
                    status: lockedBatchItems.isEmpty ? "locked-empty" : "ok",
                    inputBytes: plainSize,
                    outputItems: lockedBatchItems.count,
                    outputBytes: totalLockedBytes
                )
                completion(lockedBatchItems)
            } else {
                // Plain upload (unlocked)
                SyncRepository.shared.upsertPhoto(
                    contentId: cid,
                    localIdentifier: asset.localIdentifier,
                    mediaType: isVideo ? 1 : 0,
                    creationTs: cts,
                    pixelWidth: prePixelWidth,
                    pixelHeight: prePixelHeight,
                    estimatedBytes: size
                )
                let item = UploadItem(
                    assetLocalIdentifier: asset.localIdentifier,
                    filename: filename,
                    mimeType: mime,
                    isVideo: isVideo,
                    isLiveComponent: isLiveComponent,
                    isFavorite: favFlag,
                    contentId: cid,
                    creationTs: cts,
                    albumPathsJSON: albumJSON,
                    caption: extracted.caption,
                    longDescription: extracted.description,
                    totalBytes: size,
                    status: .queued,
                    tempFileURL: destURL,
                    assetId: self.computeAssetId(fileURL: destURL)
                )
                logExportPerf(status: "ok", inputBytes: size, outputItems: 1, outputBytes: item.totalBytes)
                completion([item])
            }
        }

        // Keep strong ref until done; also remember request id for cancellation
        _ = writingRequest
        exportRequestsQueue.async { self.activeExportRequests[key] = writingRequest }
    }

    private func stillImageMimeType(for filename: String) -> String {
        let lower = filename.lowercased()
        if lower.hasSuffix(".dng") { return "image/dng" }
        if lower.hasSuffix(".heic") || lower.hasSuffix(".heif") { return "image/heic" }
        if lower.hasSuffix(".png") { return "image/png" }
        if lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") { return "image/jpeg" }
        if lower.hasSuffix(".gif") { return "image/gif" }
        if lower.hasSuffix(".webp") { return "image/webp" }
        if lower.hasSuffix(".tif") || lower.hasSuffix(".tiff") { return "image/tiff" }
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        if let utType = UTType(filenameExtension: ext), let mime = utType.preferredMIMEType {
            switch mime.lowercased() {
            case "image/x-adobe-dng", "application/dng":
                return "image/dng"
            default:
                return mime
            }
        }
        return "image/jpeg"
    }

    private func ensureUMKAvailableForLocked() -> Bool {
        // Step 1: Pull latest envelope from server (best-effort) so freshness check is meaningful
        let fetchSem = DispatchSemaphore(value: 0)
        Task { await E2EEManager.shared.syncEnvelopeFromServer(); fetchSem.signal() }
        _ = fetchSem.wait(timeout: .now() + .seconds(10))
        // Enforce TTL for in-memory UMK
        E2EEManager.shared.clearUMKIfExpired()
        // Step 2: If envelope changed since last verified, force a typed PIN unlock to re-derive UMK
        let prevHash = E2EEManager.shared.getStoredEnvelopeHash()
        let currHash = E2EEManager.shared.currentLocalEnvelopeHash()
        if let currHash = currHash, currHash != prevHash {
            // Require typed PIN unlock to verify the new envelope
            let sem = DispatchSemaphore(value: 0)
            var ok = false
            DispatchQueue.main.async {
                E2EEUnlockController.shared.requireUnlock(reason: "PIN updated — unlock to continue") { success in
                    ok = success
                    sem.signal()
                }
            }
            _ = sem.wait(timeout: .now() + .seconds(60))
            if ok {
                // Update last-seen hash and persist quick unlock for next time
                E2EEManager.shared.updateStoredEnvelopeHashToCurrentLocal()
                if let umk = E2EEManager.shared.umk, umk.count == 32 { _ = E2EEManager.shared.saveDeviceWrappedUMK(umk) }
                return true
            }
            return false
        }
        // Step 3: If UMK present (respecting TTL) or quick unlock succeeds, we are good
        if E2EEManager.shared.hasValidUMKRespectingTTL() { return true }
        if E2EEManager.shared.unlockWithDeviceKey(prompt: "Unlock to encrypt locked items") { return true }
        // Step 4: Fallback to typed PIN if envelope exists
        guard E2EEManager.shared.loadEnvelope() != nil else { return false }
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        DispatchQueue.main.async {
            E2EEUnlockController.shared.requireUnlock(reason: "Needed to encrypt locked items") { success in
                ok = success
                sem.signal()
            }
        }
        _ = sem.wait(timeout: .now() + .seconds(60))
        if ok { E2EEManager.shared.updateStoredEnvelopeHashToCurrentLocal() }
        return ok
    }

    // Best-effort preflight to ensure the PIN/envelope is fresh before any sync run,
    // regardless of whether the current batch contains locked items. This avoids
    // deferring the prompt until the first locked asset is encountered and keeps
    // quick-unlock state in sync early.
    func preflightEnsurePinFreshness() {
        // Pull latest envelope to compare freshness
        let fetchSem = DispatchSemaphore(value: 0)
        Task { await E2EEManager.shared.syncEnvelopeFromServer(); fetchSem.signal() }
        _ = fetchSem.wait(timeout: .now() + .seconds(10))
        // Respect TTL for in-memory UMK
        E2EEManager.shared.clearUMKIfExpired()
        // If the envelope hash changed since last verified, request a typed unlock to
        // re-derive UMK once so subsequent operations (including quick unlock) are valid.
        let prevHash = E2EEManager.shared.getStoredEnvelopeHash()
        let currHash = E2EEManager.shared.currentLocalEnvelopeHash()
        guard let currHash = currHash, currHash != prevHash else { return }
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        DispatchQueue.main.async {
            E2EEUnlockController.shared.requireUnlock(reason: "PIN updated — unlock to continue") { success in
                ok = success
                sem.signal()
            }
        }
        _ = sem.wait(timeout: .now() + .seconds(60))
        if ok {
            E2EEManager.shared.updateStoredEnvelopeHashToCurrentLocal()
            if let umk = E2EEManager.shared.umk, umk.count == 32 {
                _ = E2EEManager.shared.saveDeviceWrappedUMK(umk)
            }
        }
    }

    // MARK: - Image/Video helpers for Locked thumbnails
    private func imageByRemovingAlphaForJPEG(_ image: CGImage) -> CGImage {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return image
        default:
            break
        }

        let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue).union(.byteOrder32Big)
        guard let ctx = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            return image
        }

        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        // JPEG has no alpha channel; flatten once to avoid opaque+alpha write warnings.
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage() ?? image
    }

    private func convertHEICtoJPEG(inputURL: URL, quality: CGFloat) -> (url: URL, width: Int, height: Int)? {
        // Use a transform-aware decode so EXIF/HEIC orientation is respected
        guard let src = CGImageSourceCreateWithURL(inputURL as CFURL, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as NSDictionary?
        let w = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let h = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let maxSide = max(1, max(w, h))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Decode at (approximately) original resolution while applying orientation
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgOriented = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        let jpegReady = imageByRemovingAlphaForJPEG(cgOriented)
        let destURL = uploadTempFileURL(name: UUID().uuidString + ".jpg")
        guard let dest = CGImageDestinationCreateWithURL(destURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        let encProps: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, jpegReady, encProps as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (destURL, jpegReady.width, jpegReady.height)
    }

    private func generateImageThumbnail(url: URL, maxDim: Int) -> (url: URL, width: Int, height: Int, size: Int64)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as NSDictionary?
        let w = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let h = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let scale = w > h ? Double(maxDim) / Double(max(1, w)) : Double(maxDim) / Double(max(1, h))
        let outW = max(1, Int(Double(w) * scale))
        let outH = max(1, Int(Double(h) * scale))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(outW, outH),
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        let jpegReady = imageByRemovingAlphaForJPEG(thumb)
        let destURL = uploadTempFileURL(name: UUID().uuidString + "_thumb.jpg")
        guard let dest = CGImageDestinationCreateWithURL(destURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, jpegReady, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        let sz = (try? FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        return (destURL, outW, outH, sz)
    }

    private func generateVideoThumbnail(url: URL) -> (url: URL, width: Int, height: Int, size: Int64)? {
        let asset = AVAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        let dur = CMTimeGetSeconds(asset.duration)
        let time = CMTime(seconds: max(0.1, dur / 2.0), preferredTimescale: 600)
        guard let cg = try? gen.copyCGImage(at: time, actualTime: nil) else { return nil }
        let jpegReady = imageByRemovingAlphaForJPEG(cg)
        let destURL = uploadTempFileURL(name: UUID().uuidString + "_thumb.jpg")
        guard let dest = CGImageDestinationCreateWithURL(destURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, jpegReady, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        let sz = (try? FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        return (destURL, jpegReady.width, jpegReady.height, sz)
    }

    // MARK: - Metadata logging
    private func extractCaptionDescription(fileURL: URL, isVideo: Bool) -> (caption: String?, description: String?) {
        var cap: String? = nil
        var desc: String? = nil
        if isVideo {
            let av = AVURLAsset(url: fileURL)
            // Common metadata description
            if let item = AVMetadataItem.metadataItems(from: av.commonMetadata, withKey: AVMetadataKey.commonKeyDescription, keySpace: .common).first, let v = item.stringValue, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                cap = v
            }
            // QuickTime description
            if cap == nil {
                for item in av.metadata(forFormat: .quickTimeMetadata) {
                    if item.identifier?.rawValue == "com.apple.quicktime.description", let v = item.stringValue, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        cap = v
                        break
                    }
                }
            }
            desc = cap
        } else {
            guard let src = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return (nil, nil) }
            // XMP via CGImageMetadata
            if let meta = CGImageSourceCopyMetadataAtIndex(src, 0, nil) {
                // Common XMP dc:description path
                if let cf = CGImageMetadataCopyStringValueWithPath(meta, nil, "XMP:dc:description" as CFString) {
                    let s = cf as String
                    if !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { cap = s }
                }
                if cap == nil, let cf2 = CGImageMetadataCopyStringValueWithPath(meta, nil, "XMP:Description" as CFString) {
                    let s2 = cf2 as String
                    if !s2.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { cap = s2 }
                }
            }
            // IPTC / TIFF / EXIF
            if let propsAny = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] {
                if cap == nil, let iptc = propsAny[kCGImagePropertyIPTCDictionary as String] as? [String: Any], let v = iptc[kCGImagePropertyIPTCCaptionAbstract as String] as? String, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    cap = v
                }
                if cap == nil, let tiff = propsAny[kCGImagePropertyTIFFDictionary as String] as? [String: Any], let v = tiff[kCGImagePropertyTIFFImageDescription as String] as? String, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    cap = v
                }
                if cap == nil, let exif = propsAny[kCGImagePropertyExifDictionary as String] as? [String: Any], let v = exif[kCGImagePropertyExifUserComment as String] as? String, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    cap = v
                }
            }
            desc = cap
        }
        return (cap, desc)
    }
    private func logExportedMetadata(fileURL: URL, isVideo: Bool, asset: PHAsset, resource: PHAssetResource, preCreationTs: Int64, size: Int64) {
        func fmt(_ ts: Int64) -> String {
            let d = Date(timeIntervalSince1970: TimeInterval(ts))
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
            return f.string(from: d)
        }
        let resType: String = {
            switch resource.type {
            case .photo: return "photo"
            case .fullSizePhoto: return "fullSizePhoto"
            case .alternatePhoto: return "alternatePhoto"
            case .video: return "video"
            case .fullSizeVideo: return "fullSizeVideo"
            case .pairedVideo: return "pairedVideo"
            default: return "other(\(resource.type.rawValue))"
            }
        }()
        print("[EXIF] asset=\(asset.localIdentifier) file=\(resource.originalFilename) type=\(resType) isVideo=\(isVideo) size=\(size) pre_created_at=\(preCreationTs) (\(fmt(preCreationTs)))")
        if isVideo {
            let av = AVURLAsset(url: fileURL)
            let duration = CMTimeGetSeconds(av.duration)
            let tracks = av.tracks(withMediaType: .video)
            let nat = tracks.first?.naturalSize ?? .zero
            var creation: String = ""
            // Try common metadata
            if let item = AVMetadataItem.metadataItems(from: av.commonMetadata, withKey: AVMetadataKey.commonKeyCreationDate, keySpace: .common).first, let v = item.stringValue {
                creation = v
            } else if let qt = av.metadata(forFormat: .quickTimeMetadata).first(where: { $0.key as? String == "com.apple.quicktime.creationdate" }), let v = qt.stringValue {
                creation = v
            }
            print("[EXIF] VIDEO: duration=\(String(format: "%.3f", duration))s size=\(Int(nat.width))x\(Int(nat.height)) creation=\(creation.isEmpty ? "(none)" : creation)")
        } else {
            guard let src = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
                print("[EXIF] IMAGE: could not create image source for \(fileURL.lastPathComponent)")
                return
            }
            guard let propsAny = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else {
                print("[EXIF] IMAGE: no properties for \(fileURL.lastPathComponent)")
                return
            }
            let exif = (propsAny[kCGImagePropertyExifDictionary as String] as? [String: Any]) ?? [:]
            let tiff = (propsAny[kCGImagePropertyTIFFDictionary as String] as? [String: Any]) ?? [:]
            let gps = (propsAny[kCGImagePropertyGPSDictionary as String] as? [String: Any]) ?? [:]
            let pxW = (propsAny[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue ?? 0
            let pxH = (propsAny[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue ?? 0
            let dto = (exif[kCGImagePropertyExifDateTimeOriginal as String] as? String) ?? ""
            let dtd = (exif[kCGImagePropertyExifDateTimeDigitized as String] as? String) ?? ""
            let oto = (exif[kCGImagePropertyExifOffsetTimeOriginal as String] as? String) ?? (exif[kCGImagePropertyExifOffsetTime as String] as? String) ?? ""
            let make = (tiff[kCGImagePropertyTIFFMake as String] as? String) ?? ""
            let model = (tiff[kCGImagePropertyTIFFModel as String] as? String) ?? ""
            let iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.intValue
            let fnum = (exif[kCGImagePropertyExifFNumber as String] as? NSNumber)?.doubleValue
            let shutter = (exif[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue
            let focal = (exif[kCGImagePropertyExifFocalLength as String] as? NSNumber)?.doubleValue
            let lat = gps[kCGImagePropertyGPSLatitude as String] as? NSNumber
            let lon = gps[kCGImagePropertyGPSLongitude as String] as? NSNumber
            print("[EXIF] IMAGE: dims=\(pxW)x\(pxH) DateTimeOriginal=\(dto.isEmpty ? "(none)" : dto) OffsetTimeOriginal=\(oto.isEmpty ? "(none)" : oto) DateTime=\(dtd.isEmpty ? "(none)" : dtd)")
            print("[EXIF] IMAGE: Make=\(make.isEmpty ? "(none)" : make) Model=\(model.isEmpty ? "(none)" : model) ISO=\(iso.map(String.init) ?? "(none)") FNumber=\(fnum.map { String(format: "f/%.1f", $0) } ?? "(none)") Exposure=\(shutter.map { String(format: "%.5f s", $0) } ?? "(none)") Focal=\(focal.map { String(format: "%.0f mm", $0) } ?? "(none)")")
            if let lat = lat, let lon = lon {
                print("[EXIF] IMAGE: GPS lat=\(lat) lon=\(lon)")
            }
        }
    }

    private func cancelActiveExports() {
        let manager = PHAssetResourceManager.default()
        exportRequestsQueue.sync {
            if !activeExportRequests.isEmpty {
                print("[EXPORT] Cancelling \(activeExportRequests.count) active export(s) before backgrounding")
            }
            for (_, reqId) in activeExportRequests { manager.cancelDataRequest(reqId) }
            activeExportRequests.removeAll()
            // Clear any downloading indicators
            icloudDownloadingKeys.removeAll()
            icloudProgressLogByKey.removeAll()
            DispatchQueue.main.async { self.icloudDownloadingCount = 0 }
        }
    }

    // MARK: - Foreground TUS

    private func startTusUpload(for item: UploadItem) {
        tusQueue.sync { tusCancelFlags[item.id] = false }
        enqueueTus([item])
    }

    @MainActor
    private func setUploading(_ itemID: UUID) async {
        await update(itemID: itemID, status: .uploading)
    }

    private func performTusUpload(_ item: UploadItem, queueWait: TimeInterval?) async {
        let opStartedAt = perfNow()
        defer { trackLiveComponentSettledIfNeeded(item) }
        guard let tusClient else { return }
        let uploadProfile = tusUploadProfile(for: item)
        let patchTimeoutSeconds = uploadProfile.patchTimeoutSeconds
        if !isNetworkAvailable {
            print("[UPLOAD] Skipping TUS (offline): \(item.filename)")
            await update(itemID: item.id, status: .failed)
            SyncRepository.shared.markFailed(contentId: item.contentId, error: "Offline")
            perfRecordFailure()
            AppLog.debug(
                AppLog.upload,
                "[PERF] tus-failed filename=\(item.filename) reason=offline queue_wait_ms=\(queueWait.map(perfMs) ?? 0) total_ms=\(perfMs(max(0, perfNow() - opStartedAt)))"
            )
            do { try FileManager.default.removeItem(at: item.tempFileURL) } catch { }
            return
        }
        print("[UPLOAD] Using TUS for: \(item.filename) size=\(item.totalBytes)")
        AppLog.debug(
            AppLog.upload,
            "[PERF] tus-start filename=\(item.filename) size=\(item.totalBytes) queue_wait_ms=\(queueWait.map(perfMs) ?? 0) pending=\(pendingTusCount()) workers=\(tusQueue.sync { activeTusWorkers }) chunk_bytes=\(uploadProfile.initialChunkSize) min_chunk_bytes=\(uploadProfile.minimumChunkSize) max_chunk_bytes=\(uploadProfile.maximumChunkSize) patch_timeout_s=\(Int(patchTimeoutSeconds.rounded())) stall_recovery_budget=\(uploadProfile.maxStallRecoveries)"
        )
        await setUploading(item.id)
        SyncRepository.shared.markUploading(contentId: item.contentId)

        func tusResumeKey(for item: UploadItem) -> String {
            var key = item.contentId + (item.isVideo ? "-v" : "-p")
            if item.isLocked { key += "-" + (item.lockedKind ?? "orig") }
            return key
        }
        var createSeconds: TimeInterval = 0
        var headSeconds: TimeInterval = 0
        var uploadSeconds: TimeInterval = 0
        var verifySeconds: TimeInterval = 0
        var resumeOffset: Int64 = 0
        var usedPersistedResumeURL = false
        var headSkipped = false
        var verifyDeferred = false
        let verifyMode = "fast_deferred"
        var patchRetries = 0
        var patchTimeouts = 0
        var stallRecoveries = 0

        do {
            var uploadURL = item.tusURL
            var createdFreshUploadURL = false
            // Attempt to resume using a persisted TUS URL from previous sessions
            if uploadURL == nil {
                if let saved = SyncRepository.shared.getTusUploadURL(contentId: tusResumeKey(for: item)), let url = URL(string: saved) {
                    uploadURL = url
                    usedPersistedResumeURL = true
                    await update(itemID: item.id, tusURL: uploadURL)
                }
            }
            if uploadURL == nil {
                var meta: [String: String]
                if item.isLocked, let assetIdB58 = item.assetIdB58, let kind = item.lockedKind, let lmeta = item.lockedMetadata {
                    // Locked upload metadata (orig or thumb)
                    var m: [String: String] = [
                        "locked": "1",
                        "crypto_version": "3",
                        "kind": kind,
                        "asset_id_b58": assetIdB58,
                    ]
                    lmeta.forEach { m[$0.key] = $0.value }
                    // Include album paths for locked uploads as well (safe metadata, server attaches by asset_id)
                    if let albums = item.albumPathsJSON, AuthManager.shared.syncPreserveAlbum {
                        m["albums"] = albums
                    }
                    // Stamp content_id to enable robust live-photo pairing for locked uploads
                    m["content_id"] = item.contentId
                    meta = m
                    print("[UPLOAD] LOCKED TUS meta filename=\(item.filename) kind=\(kind) asset_id=\(assetIdB58) meta=\(m)")
                } else {
                    meta = [
                        "content_id": item.contentId,
                        "media_type": item.isVideo ? "video" : "image",
                        "created_at": String(item.creationTs),
                        "favorite": item.isFavorite ? "1" : "0"
                    ]
                    if let assetId = item.assetId ?? self.computeAssetId(fileURL: item.tempFileURL) { meta["asset_id"] = assetId }
                    if let cap = item.caption, !cap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { meta["caption"] = cap }
                    if let des = item.longDescription, !des.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { meta["description"] = des }
                    print("[UPLOAD] TUS meta filename=\(item.filename) content_id=\(item.contentId) created_at=\(item.creationTs) favorite=\(item.isFavorite ? 1 : 0) caption='\(item.caption ?? "")' description='\(item.longDescription ?? "")' asset_id='\(meta["asset_id"] ?? "")'")
                    if let albums = item.albumPathsJSON, AuthManager.shared.syncPreserveAlbum { meta["albums"] = albums }
                }
                let createStart = perfNow()
                let created = try await tusClient.create(fileSize: item.totalBytes, filename: item.filename, mimeType: item.mimeType, metadata: meta)
                createSeconds += max(0, perfNow() - createStart)
                uploadURL = created.uploadURL
                createdFreshUploadURL = true
                await update(itemID: item.id, tusURL: uploadURL)
                if let u = uploadURL { SyncRepository.shared.setTusUploadURL(contentId: tusResumeKey(for: item), uploadURL: u.absoluteString) }
            }
            guard let uploadURL else { return }
            var activeUploadURL = uploadURL
            // Resolve current offset
            var offset: Int64 = 0
            if createdFreshUploadURL {
                offset = 0
                headSkipped = true
                perfRecordHeadSkipped()
            } else {
                do {
                    let headStart = perfNow()
                    offset = try await tusClient.headOffset(uploadURL: uploadURL)
                    headSeconds += max(0, perfNow() - headStart)
                    perfRecordHeadPerformed()
                } catch {
                    // If HEAD fails (e.g., server GCed the upload), recreate and replace stored URL.
                    SyncRepository.shared.deleteTusUploadURL(contentId: tusResumeKey(for: item))
                    var meta: [String: String]
                    if item.isLocked, let assetIdB58 = item.assetIdB58, let kind = item.lockedKind, let lmeta = item.lockedMetadata {
                        var m: [String: String] = [
                            "locked": "1",
                            "crypto_version": "3",
                            "kind": kind,
                            "asset_id_b58": assetIdB58,
                        ]
                        lmeta.forEach { m[$0.key] = $0.value }
                        if let albums = item.albumPathsJSON, AuthManager.shared.syncPreserveAlbum {
                            m["albums"] = albums
                        }
                        m["content_id"] = item.contentId
                        meta = m
                    } else {
                        meta = [
                            "content_id": item.contentId,
                            "media_type": item.isVideo ? "video" : "image",
                            "created_at": String(item.creationTs),
                            "favorite": item.isFavorite ? "1" : "0"
                        ]
                        if let assetId = item.assetId ?? self.computeAssetId(fileURL: item.tempFileURL) { meta["asset_id"] = assetId }
                        if let cap = item.caption, !cap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { meta["caption"] = cap }
                        if let des = item.longDescription, !des.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { meta["description"] = des }
                        if let albums = item.albumPathsJSON, AuthManager.shared.syncPreserveAlbum { meta["albums"] = albums }
                    }
                    let createStart = perfNow()
                    let created = try await tusClient.create(fileSize: item.totalBytes, filename: item.filename, mimeType: item.mimeType, metadata: meta)
                    createSeconds += max(0, perfNow() - createStart)
                    let newURL = created.uploadURL
                    activeUploadURL = newURL
                    await update(itemID: item.id, tusURL: newURL)
                    SyncRepository.shared.setTusUploadURL(contentId: tusResumeKey(for: item), uploadURL: newURL.absoluteString)
                    offset = 0
                    headSkipped = true
                    perfRecordHeadSkipped()
                }
            }
            resumeOffset = max(0, offset)
            await update(itemID: item.id, sentBytes: offset)

            let uploadStart = perfNow()
            let uploadResult = try await tusClient.upload(
                fileURL: item.tempFileURL,
                uploadURL: activeUploadURL,
                startOffset: offset,
                fileSize: item.totalBytes,
                progress: { [weak self] sent, total in
                    guard let self else { return }
                    if self.shouldPublishProgress(itemID: item.id, sentBytes: sent, totalBytes: total) {
                        Task { await self.update(itemID: item.id, sentBytes: sent) }
                    }
                },
                isCancelled: { [weak self] in
                    guard let self else { return true }
                    return self.tusQueue.sync { self.tusCancelFlags[item.id] ?? false }
                },
                initialChunkSize: uploadProfile.initialChunkSize,
                minimumChunkSize: uploadProfile.minimumChunkSize,
                maximumChunkSize: uploadProfile.maximumChunkSize,
                patchTimeoutSeconds: patchTimeoutSeconds,
                maxStallRecoveries: uploadProfile.maxStallRecoveries
            )
            uploadSeconds = max(0, perfNow() - uploadStart)
            patchRetries = uploadResult.patchRetries
            patchTimeouts = uploadResult.patchTimeouts
            stallRecoveries = uploadResult.stallRecoveries
            guard uploadResult.finalOffset >= item.totalBytes else {
                throw NSError(
                    domain: "TUS",
                    code: -1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Upload incomplete for \(item.filename): offset \(uploadResult.finalOffset) < size \(item.totalBytes)"
                    ]
                )
            }

            // Persist final sync state and last-synced locked flag (orig or plain uploads only)
            if item.lockedKind == nil || (item.isLocked && item.lockedKind == "orig") {
                SyncRepository.shared.setLocked(contentId: item.contentId, locked: item.isLocked)
            }
            let verifyStart = perfNow()
            let waitForLivePairing = shouldDelayVerificationForLivePairing(for: item)
            let verifyPolicy: (prefer: Bool, reason: String)
            if waitForLivePairing {
                verifyPolicy = (true, "live_pair_pending")
                AppLog.debug(
                    AppLog.upload,
                    "[PERF] verify-live-pair-delay content_id=\(item.contentId) pending_live=\(pendingLiveComponents(forContentId: item.contentId))"
                )
            } else {
                verifyPolicy = shouldPreferDeferredVerificationForForeground()
            }
            let verifyResult = await markSyncedAfterServerVerification(
                for: item,
                preferDeferred: verifyPolicy.prefer,
                preferDeferredReason: verifyPolicy.reason,
                waitForLivePairing: waitForLivePairing
            )
            let verified = (verifyResult != .failed)
            verifyDeferred = (verifyResult == .deferredQueued)
            verifySeconds = max(0, perfNow() - verifyStart)
            await update(itemID: item.id, status: verified ? .completed : .failed)
            print("[UPLOAD] TUS completed: \(item.filename)")
            SyncRepository.shared.deleteTusUploadURL(contentId: tusResumeKey(for: item))
            let totalSeconds = max(0, perfNow() - opStartedAt)
            let uploadedBytesEffective = max(0, item.totalBytes - resumeOffset)
            let perfLine = "[PERF] tus-done filename=\(item.filename) status=\(verified ? "ok" : "verify_failed") size=\(item.totalBytes) resumed_offset=\(resumeOffset) resumed_url=\(usedPersistedResumeURL ? 1 : 0) queue_wait_ms=\(queueWait.map(perfMs) ?? 0) create_ms=\(perfMs(createSeconds)) head_ms=\(perfMs(headSeconds)) head_skipped=\(headSkipped ? 1 : 0) upload_ms=\(perfMs(uploadSeconds)) verify_ms=\(perfMs(verifySeconds)) verify_mode=\(verifyMode) verify_deferred=\(verifyDeferred ? 1 : 0) chunk_bytes=\(uploadProfile.initialChunkSize) min_chunk_bytes=\(uploadProfile.minimumChunkSize) max_chunk_bytes=\(uploadProfile.maximumChunkSize) patch_timeout_s=\(Int(patchTimeoutSeconds.rounded())) patch_retries=\(patchRetries) patch_timeouts=\(patchTimeouts) stall_recoveries=\(stallRecoveries) total_ms=\(perfMs(totalSeconds)) upload_MBps=\(perfMBps(bytes: uploadedBytesEffective, seconds: max(uploadSeconds, 0.001)))"
            AppLog.debug(AppLog.upload, perfLine)
            if uploadSeconds >= perfSlowUploadThresholdSeconds {
                AppLog.info(AppLog.upload, perfLine)
            }
            perfRecordTusTransport(patchRetries: patchRetries, patchTimeouts: patchTimeouts, stallRecoveries: stallRecoveries)
            recordTusCreateHealth(createSeconds: createSeconds)
            recordTusUploadHealth(
                uploadBytes: uploadedBytesEffective,
                uploadSeconds: uploadSeconds,
                patchRetries: patchRetries,
                patchTimeouts: patchTimeouts,
                stallRecoveries: stallRecoveries
            )
            if verified {
                perfRecordForegroundCompletion(bytes: uploadedBytesEffective, queueWait: queueWait, uploadSeconds: uploadSeconds)
            } else {
                perfRecordFailure()
            }
            // Remove exported temp file on success
            do { try FileManager.default.removeItem(at: item.tempFileURL) } catch { }
        } catch {
            if let uploadFailure = error as? TUSClient.UploadFailure {
                patchRetries = uploadFailure.patchRetries
                patchTimeouts = uploadFailure.patchTimeouts
                stallRecoveries = uploadFailure.stallRecoveries
            }
            let cancelled = tusQueue.sync { tusCancelFlags[item.id] ?? false }
            let totalSeconds = max(0, perfNow() - opStartedAt)
            if cancelled {
                let stopMode = currentStopMode()
                if stopMode == .resync {
                    await update(itemID: item.id, status: .canceled)
                    SyncRepository.shared.deleteTusUploadURL(contentId: tusResumeKey(for: item))
                    print("[UPLOAD] Foreground upload canceled for ReSync: \(item.filename)")
                    AppLog.debug(
                        AppLog.upload,
                        "[PERF] tus-canceled filename=\(item.filename) reason=resync queue_wait_ms=\(queueWait.map(perfMs) ?? 0) total_ms=\(perfMs(totalSeconds))"
                    )
                    do { try FileManager.default.removeItem(at: item.tempFileURL) } catch { }
                } else if stopMode == .pause {
                    await update(itemID: item.id, status: .queued)
                    SyncRepository.shared.markPending(contentId: item.contentId, note: "Sync paused")
                    print("[UPLOAD] Foreground upload paused: \(item.filename)")
                    AppLog.debug(
                        AppLog.upload,
                        "[PERF] tus-canceled filename=\(item.filename) reason=user_pause queue_wait_ms=\(queueWait.map(perfMs) ?? 0) total_ms=\(perfMs(totalSeconds))"
                    )
                    do { try FileManager.default.removeItem(at: item.tempFileURL) } catch { }
                } else {
                    await update(itemID: item.id, status: .backgroundQueued)
                    SyncRepository.shared.markBackgroundQueued(contentId: item.contentId)
                    print("[UPLOAD] Switching to legacy multipart for: \(item.filename)")
                    AppLog.debug(
                        AppLog.upload,
                        "[PERF] tus-canceled filename=\(item.filename) reason=background_switch queue_wait_ms=\(queueWait.map(perfMs) ?? 0) total_ms=\(perfMs(totalSeconds))"
                    )
                    // Note: original temp file will be removed when we enqueue background multipart
                    // Ensure we actually enqueue a background task for this item (closes race with switchToBackgroundUploads enumeration)
                    queueBackgroundMultipart(for: item)
                }
            } else {
                await update(itemID: item.id, status: .failed)
                let msg = (error as? TUSClient.UploadFailure)?.underlying.localizedDescription ?? error.localizedDescription
                SyncRepository.shared.markFailed(contentId: item.contentId, error: msg)
                print("[UPLOAD] TUS failed: \(item.filename) error=\(msg)")
                perfRecordFailure()
                AppLog.info(
                    AppLog.upload,
                    "[PERF] tus-failed filename=\(item.filename) queue_wait_ms=\(queueWait.map(perfMs) ?? 0) create_ms=\(perfMs(createSeconds)) head_ms=\(perfMs(headSeconds)) upload_ms=\(perfMs(uploadSeconds)) patch_retries=\(patchRetries) patch_timeouts=\(patchTimeouts) stall_recoveries=\(stallRecoveries) total_ms=\(perfMs(totalSeconds)) error=\(msg)"
                )
                do { try FileManager.default.removeItem(at: item.tempFileURL) } catch { }
            }
        }
    }

    // MARK: - Background multipart

    private func queueBackgroundMultipart(for item: UploadItem) {
        let enqueueStartedAt = perfNow()
        let stopMode = currentStopMode()
        if stopMode == .resync {
            Task { await update(itemID: item.id, status: .canceled) }
            return
        }
        if stopMode == .pause {
            Task { await update(itemID: item.id, status: .queued) }
            SyncRepository.shared.markPending(contentId: item.contentId, note: "Sync paused")
            return
        }
        // Recreate session if needed
        if bgSession == nil { setupBackgroundSession() }
        guard let bgSession = bgSession else {
            let reason = "Background session unavailable"
            print("[UPLOAD] \(reason)")
            Task { await update(itemID: item.id, status: .failed) }
            SyncRepository.shared.markFailed(contentId: item.contentId, error: reason)
            perfRecordFailure()
            return
        }
        // Per-item Wi‑Fi only gating
        // Respect cellular policies per media type when on an expensive network
        if isExpensiveNetwork {
            let allowed = item.isVideo ? auth.syncUseCellularVideos : auth.syncUseCellularPhotos
            if !allowed {
                print("[UPLOAD] Skipping background upload due to cellular policy (\(item.isVideo ? "video" : "photo"))")
                Task { await update(itemID: item.id, status: .failed) }
                SyncRepository.shared.markFailed(contentId: item.contentId, error: "Cellular policy disallows upload")
                perfRecordFailure()
                let typeStr = item.isVideo ? "video" : "photo"
                DispatchQueue.main.async { ToastManager.shared.show("Background upload skipped: cellular disallowed for \(typeStr)") }
                // Optionally remove temp file to save space
                try? FileManager.default.removeItem(at: item.tempFileURL)
                return
            }
        }
        guard let url = URL(string: auth.serverURL + "/api/upload") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        auth.authHeader().forEach { key, val in req.setValue(val, forHTTPHeaderField: key) }
        if #available(iOS 13.0, *) {
            let allowed = item.isVideo ? auth.syncUseCellularVideos : auth.syncUseCellularPhotos
            req.allowsExpensiveNetworkAccess = allowed
            req.allowsConstrainedNetworkAccess = allowed
        }

        // Build multipart body file
        let boundary = "----AlbumbudBoundary_\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        // Create body temp file
        let bodyURL = uploadTempFileURL(name: UUID().uuidString + ".multipart")
        FileManager.default.createFile(atPath: bodyURL.path, contents: nil, attributes: nil)

        guard let handle = try? FileHandle(forWritingTo: bodyURL), let inHandle = try? FileHandle(forReadingFrom: item.tempFileURL) else { return }
        defer { try? handle.close(); try? inHandle.close() }

        // Write metadata fields first
        func writeField(name: String, value: String) {
            let field = "--\(boundary)\r\n" +
                "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n" +
                "\(value)\r\n"
            try? handle.write(contentsOf: Data(field.utf8))
        }
        if item.isLocked, let assetIdB58 = item.assetIdB58, let kind = item.lockedKind {
            writeField(name: "locked", value: "1")
            writeField(name: "crypto_version", value: "3")
            writeField(name: "kind", value: kind)
            writeField(name: "asset_id_b58", value: assetIdB58)
            if let lm = item.lockedMetadata {
                for (k, v) in lm { writeField(name: k, value: v) }
            }
            print("[UPLOAD] Multipart LOCKED meta filename=\(item.filename) kind=\(kind) asset_id=\(assetIdB58)")
        } else {
            writeField(name: "content_id", value: item.contentId)
            if let aid = item.assetId ?? computeAssetId(fileURL: item.tempFileURL) { writeField(name: "asset_id", value: aid) }
            writeField(name: "media_type", value: item.isVideo ? "video" : "image")
            writeField(name: "created_at", value: String(item.creationTs))
            writeField(name: "favorite", value: item.isFavorite ? "1" : "0")
            if let cap = item.caption, !cap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { writeField(name: "caption", value: cap) }
            if let des = item.longDescription, !des.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { writeField(name: "description", value: des) }
            print("[UPLOAD] Multipart meta filename=\(item.filename) content_id=\(item.contentId) created_at=\(item.creationTs) favorite=\(item.isFavorite ? 1 : 0) caption='\(item.caption ?? "")' description='\(item.longDescription ?? "")'")
            if let albums = item.albumPathsJSON, AuthManager.shared.syncPreserveAlbum {
                writeField(name: "albums", value: albums)
            }
        }

        let header = "--\(boundary)\r\n" +
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(item.filename)\"\r\n" +
            "Content-Type: \(item.mimeType)\r\n\r\n"
        try? handle.write(contentsOf: Data(header.utf8))
        while autoreleasepool(invoking: {
            if let chunk = try? inHandle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                try? handle.write(contentsOf: chunk)
                return true
            }
            return false
        }) {}
        try? handle.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))

        // We no longer need the original exported temp file
        try? FileManager.default.removeItem(at: item.tempFileURL)

        // Create upload task using file-based body
        let task = bgSession.uploadTask(with: req, fromFile: bodyURL)
        // taskDescription format:
        // uploadItemUUID|bodyFilename|boundary|attempt|contentId|mediaKind|syncMark|assetId
        // syncMark: "mark" for primary components, "skip" for non-primary components.
        let syncMark = shouldMarkSyncedInRepository(for: item) ? "mark" : "skip"
        let assetIdForDesc = preflightAssetId(for: item) ?? ""
        let taskDescription = item.id.uuidString + "|" + bodyURL.lastPathComponent + "|" + boundary + "|0|" + item.contentId + "|" + (item.isVideo ? "video" : "photo") + "|" + syncMark + "|" + assetIdForDesc
        task.taskDescription = taskDescription
        perfRegisterBackgroundTaskStart(taskDescription: taskDescription, bodyName: bodyURL.lastPathComponent)

        if #available(iOS 13.0, *) {
            task.countOfBytesClientExpectsToSend = item.totalBytes
        }
        task.resume()
        // Reflect background enqueuing in both UI state and DB to keep Sync Status accurate
        Task { await update(itemID: item.id, status: .backgroundQueued) }
        SyncRepository.shared.markBackgroundQueued(contentId: item.contentId)
        print("[UPLOAD] Using legacy multipart for: \(item.filename) size=\(item.totalBytes) body=\(bodyURL.lastPathComponent)")
        let bodySize = (try? FileManager.default.attributesOfItem(atPath: bodyURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        let buildSeconds = max(0, perfNow() - enqueueStartedAt)
        let enqueuedWallClock = TimeInterval(item.enqueuedAt)
        let bgQueueWaitSeconds = max(0, Date().timeIntervalSince1970 - enqueuedWallClock)
        AppLog.debug(
            AppLog.upload,
            "[PERF] bg-enqueue filename=\(item.filename) payload_bytes=\(item.totalBytes) body_bytes=\(bodySize) body_overhead_bytes=\(max(Int64(0), bodySize - item.totalBytes)) build_ms=\(perfMs(buildSeconds)) queue_wait_before_enqueue_ms=\(perfMs(bgQueueWaitSeconds))"
        )
    }

    // MARK: - Helpers

    @MainActor
    private func update(itemID: UUID, status: UploadStatus) {
        if let idx = items.firstIndex(where: { $0.id == itemID }) {
            items[idx].status = status
        }
        // Clear throttling state for finished items to keep the cache bounded.
        switch status {
        case .completed, .failed, .canceled:
            progressThrottleQueue.async { [weak self] in
                self?.lastProgressByItem.removeValue(forKey: itemID)
            }
        default:
            break
        }
    }

    @MainActor
    private func update(itemID: UUID, sentBytes: Int64) {
        if let idx = items.firstIndex(where: { $0.id == itemID }) {
            items[idx].sentBytes = sentBytes
        }
    }

    @MainActor
    private func update(itemID: UUID, tusURL: URL?) {
        if let idx = items.firstIndex(where: { $0.id == itemID }) {
            items[idx].tusURL = tusURL
        }
    }

    // MARK: - Cache Management

    // Remove exported temp files for items that are no longer uploading (completed/failed/canceled)
    // Also removes leftover .multipart bodies in the temp directory.
    func clearCache() -> (removedCount: Int, removedBytes: Int64) {
        let fm = FileManager.default
        var removedCount = 0
        var removedBytes: Int64 = 0

        // Snapshot items to avoid concurrent mutation issues
        let snapshot = items
        let finishedStatuses: Set<UploadStatus> = [.completed, .failed, .canceled]
        for it in snapshot where finishedStatuses.contains(it.status) {
            let url = it.tempFileURL
            if fm.fileExists(atPath: url.path) {
                let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
                do {
                    try fm.removeItem(at: url)
                    removedCount += 1
                    removedBytes += size
                } catch {
                    // ignore individual failures
                }
            }
        }

        let cleaned = cleanupUploadTempArtifacts(keepBodyNames: [])
        removedCount += cleaned.removedCount
        removedBytes += cleaned.removedBytes

        return (removedCount, removedBytes)
    }
}

// MARK: - Asset ID computation (Base58(first16(HMAC-SHA256(user_id, file_bytes))))
extension HybridUploadManager {
    fileprivate func computeAssetId(fileURL: URL) -> String? {
        guard let uid = AuthManager.shared.userId, !uid.isEmpty else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        let key = SymmetricKey(data: Data(uid.utf8))
        var hmac = HMAC<SHA256>(key: key)
        // Stream in 1 MiB chunks
        while autoreleasepool(invoking: {
            if let chunk = try? handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                hmac.update(data: chunk)
                return true
            }
            return false
        }) {}
        let mac = Data(hmac.finalize())
        let truncated = mac.prefix(16)
        return Base58.encode(truncated)
    }

    // backup_id: Base58(first16(HMAC-SHA256(user_id, bytes))), with JPEG EXIF/XMP APP1 stripped.
    fileprivate func computeBackupId(fileURL: URL) -> String? {
        let ext = fileURL.pathExtension.lowercased()
        if ext == "jpg" || ext == "jpeg" {
            guard let uid = AuthManager.shared.userId, !uid.isEmpty else { return nil }
            guard let data = try? Data(contentsOf: fileURL) else { return nil }
            let bytes = [UInt8](data)
            let normalized = Self.stripJpegExifXmpApp1(bytes) ?? bytes
            let key = SymmetricKey(data: Data(uid.utf8))
            let mac = HMAC<SHA256>.authenticationCode(for: Data(normalized), using: key)
            return Base58.encode(Data(mac).prefix(16))
        }
        // For non-JPEGs, backup_id == asset_id (exact bytes).
        return computeAssetId(fileURL: fileURL)
    }

    private static func stripJpegExifXmpApp1(_ bytes: [UInt8]) -> [UInt8]? {
        if bytes.count < 2 || bytes[0] != 0xFF || bytes[1] != 0xD8 { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        out.append(contentsOf: bytes[0..<2]) // SOI

        var i = 2
        while i + 4 <= bytes.count {
            if bytes[i] != 0xFF { return nil }
            var j = i
            while j < bytes.count && bytes[j] == 0xFF { j += 1 }
            if j >= bytes.count { return nil }
            let marker = bytes[j]
            if marker == 0xD9 {
                out.append(contentsOf: bytes[i..<min(j + 1, bytes.count)])
                return out
            }
            if marker == 0xDA {
                out.append(contentsOf: bytes[i..<bytes.count])
                return out
            }
            if j + 2 >= bytes.count { return nil }
            let len = Int(bytes[j + 1]) << 8 | Int(bytes[j + 2])
            let segEnd = j + 1 + len
            if segEnd > bytes.count { return nil }
            let payloadOff = j + 3
            let payload = bytes[payloadOff..<segEnd]
            var keep = true
            if marker == 0xE1 {
                let exifPrefix: [UInt8] = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00] // "Exif\0\0"
                let xmpPrefix = Array("http://ns.adobe.com/xap/1.0/\0".utf8)
                if payload.starts(with: exifPrefix) || payload.starts(with: xmpPrefix) {
                    keep = false
                }
            }
            if keep {
                out.append(contentsOf: bytes[i..<segEnd])
            }
            i = segEnd
        }
        return nil
    }
}

// MARK: - URLSessionDelegate for background uploads

extension HybridUploadManager: URLSessionDelegate, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        // Session invalidated by system or configuration change; recreate lazily on next use
        if let error = error {
            print("[UPLOAD] Background session invalidated: \(error.localizedDescription)")
        } else {
            print("[UPLOAD] Background session invalidated without error")
        }
        bgSession = nil
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let desc = task.taskDescription else { return }
        let comps = desc.split(separator: "|", omittingEmptySubsequences: false)
        guard comps.count >= 2 else { return }
        let idStr = String(comps[0])
        let bodyName = String(comps[1])
        let boundary = comps.count >= 3 ? String(comps[2]) : nil
        let attempt = comps.count >= 4 ? (Int(comps[3]) ?? 0) : 0
        let contentIdFromDescRaw = comps.count >= 5 ? String(comps[4]) : nil
        let contentIdFromDesc = (contentIdFromDescRaw?.isEmpty == false) ? contentIdFromDescRaw : nil
        let mediaKindFromDesc = comps.count >= 6 ? String(comps[5]) : nil
        let syncMarkFromDesc = comps.count >= 7 ? String(comps[6]) : nil
        let assetIdFromDescRaw = comps.count >= 8 ? String(comps[7]) : nil
        let assetIdFromDesc = (assetIdFromDescRaw?.isEmpty == false) ? assetIdFromDescRaw : nil
        let maxAttempts = 3
        let scopedBodyURL = uploadTempFileURL(name: bodyName)
        let bodyURL = FileManager.default.fileExists(atPath: scopedBodyURL.path)
            ? scopedBodyURL
            : FileManager.default.temporaryDirectory.appendingPathComponent(bodyName)
        let statusCode = (task.response as? HTTPURLResponse)?.statusCode
        let statusCodeStr = statusCode.map(String.init) ?? "(none)"
        let errStr = error?.localizedDescription ?? "(none)"
        let cidDescStr = contentIdFromDesc ?? "(none)"
        let bodyBytes = (try? FileManager.default.attributesOfItem(atPath: bodyURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        let attemptDuration = perfConsumeBackgroundAttemptDuration(taskDescription: desc)
        print("[UPLOAD] BG didComplete desc=\(desc) code=\(statusCodeStr) attempt=\(attempt) cidDesc=\(cidDescStr) error=\(errStr)")
        AppLog.debug(
            AppLog.upload,
            "[PERF] bg-attempt-complete body=\(bodyName) attempt=\(attempt) status_code=\(statusCodeStr) err=\(errStr) attempt_ms=\(attemptDuration.map(perfMs) ?? -1) body_bytes=\(bodyBytes)"
        )

        // Delegate callbacks may arrive on a background thread. Ensure all `items` access/mutation
        // happens on the main actor, and keep DB/file work off the main thread to avoid UI jank.
        Task { [weak self] in
            await self?.handleBackgroundMultipartCompletion(
                session: session,
                idStr: idStr,
                bodyName: bodyName,
                boundary: boundary,
                attempt: attempt,
                contentIdFromDesc: contentIdFromDesc,
                mediaKindFromDesc: mediaKindFromDesc,
                syncMarkFromDesc: syncMarkFromDesc,
                assetIdFromDesc: assetIdFromDesc,
                maxAttempts: maxAttempts,
                bodyURL: bodyURL,
                bodyBytes: bodyBytes,
                attemptDuration: attemptDuration,
                statusCode: statusCode,
                completionError: error
            )
        }
    }

    @MainActor
    private func handleBackgroundMultipartCompletion(
        session: URLSession,
        idStr: String,
        bodyName: String,
        boundary: String?,
        attempt: Int,
        contentIdFromDesc: String?,
        mediaKindFromDesc: String?,
        syncMarkFromDesc: String?,
        assetIdFromDesc: String?,
        maxAttempts: Int,
        bodyURL: URL,
        bodyBytes: Int64,
        attemptDuration: TimeInterval?,
        statusCode: Int?,
        completionError: Error?
    ) async {
        let itemUUID = UUID(uuidString: idStr)
        let itemIndex = itemUUID.flatMap { uuid in items.firstIndex(where: { $0.id == uuid }) }

        // Authoritative content id for DB updates:
        //  - Prefer the in-memory UploadItem when available (same-process completions).
        //  - Fall back to the taskDescription-encoded content id (cross-process resumptions).
        let dbContentId: String? = itemIndex.map { items[$0].contentId } ?? contentIdFromDesc

        if itemIndex == nil && dbContentId == nil {
            print("[UPLOAD] BG completion without identifiable contentId; skipping sync state update")
            _ = perfFinishBackgroundEndToEndDuration(bodyName: bodyName)
            return
        }

        // Determine media kind (best-effort) so we can apply correct cellular policy on retries.
        let isVideoResolved: Bool
        if let kind = mediaKindFromDesc {
            isVideoResolved = (kind == "video")
        } else if let idx = itemIndex {
            isVideoResolved = items[idx].isVideo
        } else if let cid = dbContentId {
            // Avoid synchronous DB reads on the main actor: resolve from DB on a detached task.
            isVideoResolved = await Task.detached {
                (SyncRepository.shared.getMediaType(contentId: cid) ?? 0) == 2
            }.value
        } else {
            isVideoResolved = false
        }
        let allowsExpensive: Bool = isVideoResolved ? AuthManager.shared.syncUseCellularVideos : AuthManager.shared.syncUseCellularPhotos
        let mediaKind: String = mediaKindFromDesc ?? (isVideoResolved ? "video" : "photo")
        let shouldMarkSyncedResolved: Bool = {
            if let idx = itemIndex {
                return shouldMarkSyncedInRepository(for: items[idx])
            }
            if let marker = syncMarkFromDesc {
                return marker == "mark"
            }
            return true
        }()
        let payloadBytes: Int64 = itemIndex.map { items[$0].totalBytes } ?? max(Int64(0), bodyBytes)
        let attemptMs = attemptDuration.map(perfMs) ?? -1

        func setItemStatus(_ status: UploadStatus) {
            if let idx = itemIndex { items[idx].status = status }
        }

        func markFailedInDB(_ message: String) {
            guard let cid = dbContentId else { return }
            DispatchQueue.global(qos: .utility).async {
                SyncRepository.shared.markFailed(contentId: cid, error: message)
            }
        }

        func markPendingInDB(_ note: String) {
            guard let cid = dbContentId else { return }
            DispatchQueue.global(qos: .utility).async {
                SyncRepository.shared.markPending(contentId: cid, note: note)
            }
        }

        func removeFiles(exportedTempURL: URL?) {
            DispatchQueue.global(qos: .utility).async {
                if let exportedTempURL { try? FileManager.default.removeItem(at: exportedTempURL) }
                try? FileManager.default.removeItem(at: bodyURL)
            }
        }

        func isTransientTransportError(_ err: Error) -> Bool {
            if let urlError = err as? URLError {
                switch urlError.code {
                case .timedOut,
                     .cannotFindHost,
                     .cannotConnectToHost,
                     .dnsLookupFailed,
                     .networkConnectionLost,
                     .notConnectedToInternet,
                     .resourceUnavailable:
                    return true
                default:
                    break
                }
            } else {
                let nsErr = err as NSError
                if nsErr.domain == NSURLErrorDomain {
                    let code = URLError.Code(rawValue: nsErr.code)
                    switch code {
                    case .timedOut,
                         .cannotFindHost,
                         .cannotConnectToHost,
                         .dnsLookupFailed,
                         .networkConnectionLost,
                         .notConnectedToInternet,
                         .resourceUnavailable:
                        return true
                    default:
                        break
                    }
                }
            }
            let text = err.localizedDescription.lowercased()
            return text.contains("timed out")
                || text.contains("timeout")
                || text.contains("network connection was lost")
                || text.contains("not connected to the internet")
                || text.contains("cannot connect to host")
        }

        func isTransientHTTPStatus(_ code: Int?) -> Bool {
            guard let code else { return false }
            return code == 408 || code == 429 || (500...599).contains(code)
        }

        // 1) Transport error (e.g., offline). Retry up to N times while preserving the body file.
        if let err = completionError {
            let msg = err.localizedDescription
            print("[UPLOAD] BG upload failed attempt=\(attempt) content_id=\(dbContentId ?? "(none)") error=\(msg)")
            if attempt < maxAttempts {
                setItemStatus(.backgroundQueued)
                let delay = pow(2.0, Double(attempt))
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
                    var retryReq = URLRequest(url: URL(string: AuthManager.shared.serverURL + "/api/upload")!)
                    retryReq.httpMethod = "POST"
                    AuthManager.shared.authHeader().forEach { k, v in retryReq.setValue(v, forHTTPHeaderField: k) }
                    if let boundary = boundary, !boundary.isEmpty {
                        retryReq.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
                    }
                    if #available(iOS 13.0, *) {
                        retryReq.allowsExpensiveNetworkAccess = allowsExpensive
                        retryReq.allowsConstrainedNetworkAccess = allowsExpensive
                    }
                    let newTask = session.uploadTask(with: retryReq, fromFile: bodyURL)
                    let cidValue = dbContentId ?? ""
                    let marker = syncMarkFromDesc ?? (shouldMarkSyncedResolved ? "mark" : "skip")
                    let aidValue = assetIdFromDesc ?? ""
                    let boundaryValue = boundary ?? ""
                    let newDescription = idStr + "|" + bodyName + "|" + boundaryValue + "|" + String(attempt + 1) + "|" + cidValue + "|" + mediaKind + "|" + marker + "|" + aidValue
                    newTask.taskDescription = newDescription
                    self.perfRegisterBackgroundTaskStart(taskDescription: newDescription, bodyName: bodyName)
                    newTask.resume()
                }
                AppLog.debug(
                    AppLog.upload,
                    "[PERF] bg-retry scheduled reason=transport body=\(bodyName) attempt=\(attempt) next_attempt=\(attempt + 1) delay_s=\(String(format: "%.2f", delay)) attempt_ms=\(attemptMs)"
                )
            } else {
                if isTransientTransportError(err) {
                    setItemStatus(.queued)
                    markPendingInDB("Transient transport error: \(msg)")
                    let exportedTempURL = itemIndex.map { items[$0].tempFileURL }
                    removeFiles(exportedTempURL: exportedTempURL)
                    let total = perfFinishBackgroundEndToEndDuration(bodyName: bodyName)
                    AppLog.info(
                        AppLog.upload,
                        "[PERF] bg-requeue body=\(bodyName) reason=transport_transient attempts=\(attempt + 1) payload_bytes=\(payloadBytes) attempt_ms=\(attemptMs) total_ms=\(total.map(perfMs) ?? -1) error=\(msg)"
                    )
                    perfLogSummary(reason: "bg-requeue")
                    return
                }
                setItemStatus(.failed)
                markFailedInDB(msg)
                let exportedTempURL = itemIndex.map { items[$0].tempFileURL }
                removeFiles(exportedTempURL: exportedTempURL)
                let total = perfFinishBackgroundEndToEndDuration(bodyName: bodyName)
                perfRecordFailure()
                AppLog.info(
                    AppLog.upload,
                    "[PERF] bg-failed body=\(bodyName) reason=transport attempts=\(attempt + 1) payload_bytes=\(payloadBytes) attempt_ms=\(attemptMs) total_ms=\(total.map(perfMs) ?? -1) error=\(msg)"
                )
                perfLogSummary(reason: "bg-failed")
            }
            return
        }

        // 2) Success (2xx).
        if let code = statusCode, (200..<300).contains(code) {
            let exportedTempURL = itemIndex.map { items[$0].tempFileURL }
            var verified = true
            if shouldMarkSyncedResolved {
                if let idx = itemIndex {
                    let completedItem = items[idx]
                    let verifyResult = await markSyncedAfterServerVerification(for: completedItem)
                    verified = (verifyResult != .failed)
                    setItemStatus(verified ? .completed : .failed)
                } else {
                    if let cid = dbContentId {
                        let verifyResult = await markSyncedAfterServerVerification(contentId: cid, filename: bodyName, assetId: assetIdFromDesc)
                        verified = (verifyResult != .failed)
                    } else {
                        verified = false
                        markFailedInDB("Upload completed but verification could not resolve content id")
                    }
                }
            } else {
                setItemStatus(.completed)
            }
            removeFiles(exportedTempURL: exportedTempURL)
            let total = perfFinishBackgroundEndToEndDuration(bodyName: bodyName)
            if verified {
                perfRecordBackgroundCompletion(bytes: payloadBytes, uploadSeconds: total)
            } else {
                perfRecordFailure()
            }
            AppLog.debug(
                AppLog.upload,
                "[PERF] bg-done body=\(bodyName) status=\(verified ? "ok" : "verify_failed") attempt=\(attempt) payload_bytes=\(payloadBytes) attempt_ms=\(attemptMs) total_ms=\(total.map(perfMs) ?? -1) mbps=\(total.map { perfMBps(bytes: payloadBytes, seconds: max($0, 0.001)) } ?? "n/a")"
            )
            perfLogSummary(reason: "bg-complete")
            return
        }

        // 3) HTTP failure. Handle 401 and 5xx retries, otherwise mark failed.
        if statusCode == 401, let boundary = boundary, !boundary.isEmpty, attempt < maxAttempts {
            setItemStatus(.backgroundQueued)
            let refreshed = await AuthManager.shared.forceRefresh()
            let nextAttempt = attempt + 1
            let scheduleRetry = {
                var retryReq = URLRequest(url: URL(string: AuthManager.shared.serverURL + "/api/upload")!)
                retryReq.httpMethod = "POST"
                AuthManager.shared.authHeader().forEach { k, v in retryReq.setValue(v, forHTTPHeaderField: k) }
                retryReq.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
                if #available(iOS 13.0, *) {
                    retryReq.allowsExpensiveNetworkAccess = allowsExpensive
                    retryReq.allowsConstrainedNetworkAccess = allowsExpensive
                }
                let newTask = session.uploadTask(with: retryReq, fromFile: bodyURL)
                let cidValue = dbContentId ?? ""
                let marker = syncMarkFromDesc ?? (shouldMarkSyncedResolved ? "mark" : "skip")
                let aidValue = assetIdFromDesc ?? ""
                let newDescription = idStr + "|" + bodyName + "|" + boundary + "|" + String(nextAttempt) + "|" + cidValue + "|" + mediaKind + "|" + marker + "|" + aidValue
                newTask.taskDescription = newDescription
                self.perfRegisterBackgroundTaskStart(taskDescription: newDescription, bodyName: bodyName)
                newTask.resume()
            }
            if refreshed {
                scheduleRetry()
            } else {
                let delay = pow(2.0, Double(attempt))
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
                    scheduleRetry()
                }
            }
            AppLog.debug(
                AppLog.upload,
                "[PERF] bg-retry scheduled reason=http401 body=\(bodyName) attempt=\(attempt) next_attempt=\(nextAttempt) refreshed=\(refreshed ? 1 : 0) attempt_ms=\(attemptMs)"
            )
            return
        }

        if let code = statusCode, code >= 500, attempt < maxAttempts {
            setItemStatus(.backgroundQueued)
            let delay = pow(2.0, Double(attempt))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
                var retryReq = URLRequest(url: URL(string: AuthManager.shared.serverURL + "/api/upload")!)
                retryReq.httpMethod = "POST"
                AuthManager.shared.authHeader().forEach { k, v in retryReq.setValue(v, forHTTPHeaderField: k) }
                if let boundary = boundary, !boundary.isEmpty {
                    retryReq.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
                }
                if #available(iOS 13.0, *) {
                    retryReq.allowsExpensiveNetworkAccess = allowsExpensive
                    retryReq.allowsConstrainedNetworkAccess = allowsExpensive
                }
                let newTask = session.uploadTask(with: retryReq, fromFile: bodyURL)
                let cidValue = dbContentId ?? ""
                let marker = syncMarkFromDesc ?? (shouldMarkSyncedResolved ? "mark" : "skip")
                let aidValue = assetIdFromDesc ?? ""
                let boundaryValue = boundary ?? ""
                let newDescription = idStr + "|" + bodyName + "|" + boundaryValue + "|" + String(attempt + 1) + "|" + cidValue + "|" + mediaKind + "|" + marker + "|" + aidValue
                newTask.taskDescription = newDescription
                self.perfRegisterBackgroundTaskStart(taskDescription: newDescription, bodyName: bodyName)
                newTask.resume()
            }
            if let cid = dbContentId, let code = statusCode {
                print("[UPLOAD] BG scheduled retry for HTTP \(code) attempt=\(attempt + 1) content_id=\(cid)")
            }
            AppLog.debug(
                AppLog.upload,
                "[PERF] bg-retry scheduled reason=http\(code) body=\(bodyName) attempt=\(attempt) next_attempt=\(attempt + 1) delay_s=\(String(format: "%.2f", delay)) attempt_ms=\(attemptMs)"
            )
            return
        }

        if isTransientHTTPStatus(statusCode) {
            let errMsg = statusCode.map { "HTTP \($0)" } ?? "HTTP transient"
            setItemStatus(.queued)
            markPendingInDB("Transient server error: \(errMsg)")
            let exportedTempURL = itemIndex.map { items[$0].tempFileURL }
            removeFiles(exportedTempURL: exportedTempURL)
            let total = perfFinishBackgroundEndToEndDuration(bodyName: bodyName)
            AppLog.info(
                AppLog.upload,
                "[PERF] bg-requeue body=\(bodyName) reason=http_transient attempts=\(attempt + 1) status=\(statusCode ?? -1) payload_bytes=\(payloadBytes) attempt_ms=\(attemptMs) total_ms=\(total.map(perfMs) ?? -1)"
            )
            perfLogSummary(reason: "bg-requeue")
            return
        }

        // Unhandled / non-retriable HTTP response.
        setItemStatus(.failed)
        let errMsg = statusCode.map { "HTTP \($0)" } ?? "Unknown error"
        markFailedInDB(errMsg)
        let exportedTempURL = itemIndex.map { items[$0].tempFileURL }
        removeFiles(exportedTempURL: exportedTempURL)
        let total = perfFinishBackgroundEndToEndDuration(bodyName: bodyName)
        perfRecordFailure()
        AppLog.info(
            AppLog.upload,
            "[PERF] bg-failed body=\(bodyName) reason=http attempts=\(attempt + 1) status=\(statusCode ?? -1) payload_bytes=\(payloadBytes) attempt_ms=\(attemptMs) total_ms=\(total.map(perfMs) ?? -1)"
        )
        perfLogSummary(reason: "bg-failed")
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        // Call the completion handler to let the system know we're done processing background events
        print("[UPLOAD] urlSessionDidFinishEvents: all background events delivered")
        perfLogSummary(reason: "bg-events-finished", force: true)
        DispatchQueue.main.async { [weak self] in
            self?.bgCompletionHandler?()
            self?.bgCompletionHandler = nil
        }
    }
}
