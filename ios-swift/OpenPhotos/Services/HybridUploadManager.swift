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
    private var activeTusWorkers: Int = 0
    private let maxTusWorkers: Int = 2
    // Limit export concurrency to avoid too many open files
    private let exportSemaphore = DispatchSemaphore(value: 3)
    private let exportResultsQueue = DispatchQueue(label: "hybrid.export.results")
    private let exportBatchSize: Int = 8
    private let minFreeSpaceBytes: Int64 = 500 * 1024 * 1024 // 500 MB threshold
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
    // Stop flag used when user requests a foreground restart (ReSync while syncing).
    private let runControlQueue = DispatchQueue(label: "hybrid.upload.run.control")
    private var stopForResyncRequested: Bool = false

    private func setStopForResyncRequested(_ requested: Bool) {
        runControlQueue.sync { stopForResyncRequested = requested }
    }

    private func isStopForResyncRequested() -> Bool {
        runControlQueue.sync { stopForResyncRequested }
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
        pathMonitor.pathUpdateHandler = { [weak self] path in
            self?.isExpensiveNetwork = path.isExpensive
            self?.isNetworkAvailable = (path.status == .satisfied)
        }
        pathMonitor.start(queue: DispatchQueue(label: "hybrid.upload.network"))

        // ScenePhase changes are handled in OpenPhotosApp; no UIKit lifecycle observers here.
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
        setStopForResyncRequested(false)
        // Ensure token freshness before kicking off uploads
        Task { await AuthManager.shared.refreshIfNeeded() }
        // Ensure TUS client reflects current server URL
        guard let filesURL = URL(string: auth.serverURL + "/files") else { return }
        tusClient = TUSClient(baseURL: filesURL, headersProvider: { [weak self] in
            self?.auth.authHeader() ?? [:]
        }, chunkSize: 9 * 1024 * 1024)

        let effectiveAssets: [PHAsset] = AuthManager.shared.syncPhotosOnly
            ? assets.filter { $0.mediaType != .video }
            : assets
        if effectiveAssets.count != assets.count {
            print("[SYNC-UPLOAD] photosOnly filter: total=\(assets.count) -> \(effectiveAssets.count)")
        }
        print("[SYNC-UPLOAD] Starting batched export+upload. total=\(effectiveAssets.count) batch=\(exportBatchSize)")
        processBatch(assets: effectiveAssets, startIndex: 0)
    }

    private func processBatch(assets: [PHAsset], startIndex: Int) {
        if isStopForResyncRequested() {
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
        exportAssetsToTempFiles(assets: slice) { [weak self] exported in
            guard let self else { return }
            if self.isStopForResyncRequested() { return }
            self.preflightFilterAlreadyBackedUp(exported) { uploadable in
                if self.isStopForResyncRequested() { return }
                DispatchQueue.main.async {
                    self.items.append(contentsOf: uploadable)
                }
                self.enqueueTus(uploadable)
                self.processBatch(assets: assets, startIndex: end)
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
                let found = try await ServerPhotosService.shared.existsFullyBackedUp(assetIds: chunk)
                present.formUnion(found)
            } catch {
                if isRetryableNetworkError(error) {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    let found = try await ServerPhotosService.shared.existsFullyBackedUp(assetIds: chunk)
                    present.formUnion(found)
                } else {
                    throw error
                }
            }
            i = end
        }
        return present
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

    func isSyncBusy() -> Bool {
        let activityBusy = activityQueue.sync { activeExportBatches > 0 || activePreflightChecks > 0 }
        let tusBusy = tusQueue.sync { activeTusWorkers > 0 || !pendingTus.isEmpty }
        return activityBusy || tusBusy
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

    /// Mark synced after server confirmation. If confirmation is temporarily unavailable
    /// (for example while live-photo pairing/ingest is still settling), keep the item pending
    /// and verify again in the background instead of marking it failed immediately.
    private func markSyncedAfterServerVerification(for item: UploadItem) async -> Bool {
        guard shouldMarkSyncedInRepository(for: item) else { return true }
        let aid = preflightAssetId(for: item)
        return await markSyncedAfterServerVerification(contentId: item.contentId, filename: item.filename, assetId: aid)
    }

    private func scheduleDeferredServerVerification(contentId: String, filename: String, assetId: String) {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let attempts = 12
            for attempt in 0..<attempts {
                do {
                    let present = try await self.existsAssetIdsWithRetry([assetId])
                    if present.contains(assetId) {
                        SyncRepository.shared.markSynced(contentId: contentId)
                        print("[UPLOAD] deferred verify confirmed asset_id=\(assetId) file=\(filename) attempt=\(attempt + 1)")
                        return
                    }
                } catch {
                    // Best-effort deferred checker: keep trying until timeout.
                }
                if attempt < attempts - 1 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
            print("[UPLOAD] deferred verify timed out asset_id=\(assetId) file=\(filename); remains pending")
        }
    }

    private func markSyncedAfterServerVerification(contentId: String, filename: String, assetId: String?) async -> Bool {
        guard let aid = assetId, !aid.isEmpty else {
            let msg = "Upload completed but missing asset_id for verification"
            SyncRepository.shared.markFailed(contentId: contentId, error: msg)
            print("[UPLOAD] verify failed missing-asset-id file=\(filename)")
            return false
        }

        do {
            // Quick-path verification window.
            for attempt in 0..<4 {
                let present = try await existsAssetIdsWithRetry([aid])
                if present.contains(aid) {
                    SyncRepository.shared.markSynced(contentId: contentId)
                    return true
                }
                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
            let note = "Awaiting server ingest confirmation"
            SyncRepository.shared.markPending(contentId: contentId, note: note)
            scheduleDeferredServerVerification(contentId: contentId, filename: filename, assetId: aid)
            print("[UPLOAD] verify deferred ingest-confirmation asset_id=\(aid) file=\(filename)")
            return true
        } catch {
            let note = "Verification request failed: \(error.localizedDescription)"
            SyncRepository.shared.markPending(contentId: contentId, note: note)
            scheduleDeferredServerVerification(contentId: contentId, filename: filename, assetId: aid)
            print("[UPLOAD] verify request failed; deferred file=\(filename) err=\(error.localizedDescription)")
            return true
        }
    }

    private func enqueueTus(_ newItems: [UploadItem]) {
        tusQueue.async {
            self.pendingTus.append(contentsOf: newItems)
            self.maybeStartTusWorkers()
        }
    }

    private func maybeStartTusWorkers() {
        while activeTusWorkers < maxTusWorkers && !pendingTus.isEmpty {
            activeTusWorkers += 1
            Task.detached { [weak self] in
                await self?.runTusWorker()
            }
        }
    }

    private func nextTusItem() -> UploadItem? {
        var item: UploadItem?
        tusQueue.sync {
            if !pendingTus.isEmpty { item = pendingTus.removeFirst() }
        }
        return item
    }

    private func finishWorker() {
        tusQueue.sync { activeTusWorkers = max(0, activeTusWorkers - 1) }
    }

    private func runTusWorker() async {
        while let item = nextTusItem() {
            await performTusUpload(item)
        }
        finishWorker()
    }

    func cancelAllForeground() {
        tusQueue.sync {
            for item in items { tusCancelFlags[item.id] = true }
        }
    }

    // Stop current foreground sync work so a fresh ReSync pass can restart immediately.
    // This intentionally does not queue background uploads for canceled foreground items.
    func stopForResync() {
        setStopForResyncRequested(true)
        tusQueue.sync {
            for item in items { tusCancelFlags[item.id] = true }
            pendingTus.removeAll()
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
        let filename = resource.originalFilename
        let isVideo = resource.type == .video || resource.type == .fullSizeVideo || resource.type == .pairedVideo
        let lower = filename.lowercased()
        var mime: String
        if isVideo {
            mime = "video/quicktime"
        } else if lower.hasSuffix(".heic") || lower.hasSuffix(".heif") {
            mime = "image/heic"
        } else if lower.hasSuffix(".png") {
            mime = "image/png"
        } else if lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") {
            mime = "image/jpeg"
        } else {
            // Fallback: try to detect from UTI if available; otherwise default to JPEG
            mime = "image/jpeg"
        }
        // Snapshot favorite flag from the asset (PhotoKit objects are thread-safe)
        let favFlag = asset.isFavorite

        let tmpDir = FileManager.default.temporaryDirectory
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
                    completion([])
                    return
                }
                // Encrypt original (HEIC->JPEG first for images), and produce encrypted thumbnail
                guard let userId = AuthManager.shared.userId, let umk = E2EEManager.shared.umk, umk.count == 32 else { completion([]); return }

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
                let outOrig = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pae3")
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
                    let outT = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "_t.pae3")
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
                completion([item])
            }
        }

        // Keep strong ref until done; also remember request id for cancellation
        _ = writingRequest
        exportRequestsQueue.async { self.activeExportRequests[key] = writingRequest }
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
        let destURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        guard let dest = CGImageDestinationCreateWithURL(destURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        let encProps: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, cgOriented, encProps as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (destURL, cgOriented.width, cgOriented.height)
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
        let destURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "_thumb.jpg")
        guard let dest = CGImageDestinationCreateWithURL(destURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, thumb, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
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
        let destURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "_thumb.jpg")
        guard let dest = CGImageDestinationCreateWithURL(destURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        let sz = (try? FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        return (destURL, cg.width, cg.height, sz)
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

    private func performTusUpload(_ item: UploadItem) async {
        guard let tusClient else { return }
        if !isNetworkAvailable {
            print("[UPLOAD] Skipping TUS (offline): \(item.filename)")
            await update(itemID: item.id, status: .failed)
            SyncRepository.shared.markFailed(contentId: item.contentId, error: "Offline")
            do { try FileManager.default.removeItem(at: item.tempFileURL) } catch { }
            return
        }
        print("[UPLOAD] Using TUS for: \(item.filename) size=\(item.totalBytes)")
        await setUploading(item.id)
        SyncRepository.shared.markUploading(contentId: item.contentId)

        func tusResumeKey(for item: UploadItem) -> String {
            var key = item.contentId + (item.isVideo ? "-v" : "-p")
            if item.isLocked { key += "-" + (item.lockedKind ?? "orig") }
            return key
        }
        do {
            var uploadURL = item.tusURL
            // Attempt to resume using a persisted TUS URL from previous sessions
            if uploadURL == nil {
                if let saved = SyncRepository.shared.getTusUploadURL(contentId: tusResumeKey(for: item)), let url = URL(string: saved) {
                    uploadURL = url
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
                let created = try await tusClient.create(fileSize: item.totalBytes, filename: item.filename, mimeType: item.mimeType, metadata: meta)
                uploadURL = created.uploadURL
                await update(itemID: item.id, tusURL: uploadURL)
                if let u = uploadURL { SyncRepository.shared.setTusUploadURL(contentId: tusResumeKey(for: item), uploadURL: u.absoluteString) }
            }
            guard let uploadURL else { return }
            // Resolve current offset
            var offset: Int64 = 0
            do {
                offset = try await tusClient.headOffset(uploadURL: uploadURL)
            } catch {
                // If HEAD fails (e.g., server GCed the upload), recreate and replace stored URL
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
                let created = try await tusClient.create(fileSize: item.totalBytes, filename: item.filename, mimeType: item.mimeType, metadata: meta)
                let newURL = created.uploadURL
                await update(itemID: item.id, tusURL: newURL)
                SyncRepository.shared.setTusUploadURL(contentId: tusResumeKey(for: item), uploadURL: newURL.absoluteString)
                offset = try await tusClient.headOffset(uploadURL: newURL)
            }
            await update(itemID: item.id, sentBytes: offset)

            try await tusClient.upload(fileURL: item.tempFileURL, uploadURL: uploadURL, startOffset: offset, fileSize: item.totalBytes, progress: { [weak self] sent, total in
                guard let self else { return }
                if self.shouldPublishProgress(itemID: item.id, sentBytes: sent, totalBytes: total) {
                    Task { await self.update(itemID: item.id, sentBytes: sent) }
                }
            }, isCancelled: { [weak self] in
                guard let self else { return true }
                return self.tusQueue.sync { self.tusCancelFlags[item.id] ?? false }
            })

            // Persist final sync state and last-synced locked flag (orig or plain uploads only)
            if item.lockedKind == nil || (item.isLocked && item.lockedKind == "orig") {
                SyncRepository.shared.setLocked(contentId: item.contentId, locked: item.isLocked)
            }
            let verified = await markSyncedAfterServerVerification(for: item)
            await update(itemID: item.id, status: verified ? .completed : .failed)
            print("[UPLOAD] TUS completed: \(item.filename)")
            SyncRepository.shared.deleteTusUploadURL(contentId: tusResumeKey(for: item))
            // Remove exported temp file on success
            do { try FileManager.default.removeItem(at: item.tempFileURL) } catch { }
        } catch {
            let cancelled = tusQueue.sync { tusCancelFlags[item.id] ?? false }
            if cancelled {
                if isStopForResyncRequested() {
                    await update(itemID: item.id, status: .canceled)
                    SyncRepository.shared.deleteTusUploadURL(contentId: tusResumeKey(for: item))
                    print("[UPLOAD] Foreground upload canceled for ReSync: \(item.filename)")
                    do { try FileManager.default.removeItem(at: item.tempFileURL) } catch { }
                } else {
                    await update(itemID: item.id, status: .backgroundQueued)
                    SyncRepository.shared.markBackgroundQueued(contentId: item.contentId)
                    print("[UPLOAD] Switching to legacy multipart for: \(item.filename)")
                    // Note: original temp file will be removed when we enqueue background multipart
                    // Ensure we actually enqueue a background task for this item (closes race with switchToBackgroundUploads enumeration)
                    queueBackgroundMultipart(for: item)
                }
            } else {
                await update(itemID: item.id, status: .failed)
                let msg = error.localizedDescription
                SyncRepository.shared.markFailed(contentId: item.contentId, error: msg)
                print("[UPLOAD] TUS failed: \(item.filename) error=\(msg)")
                do { try FileManager.default.removeItem(at: item.tempFileURL) } catch { }
            }
        }
    }

    // MARK: - Background multipart

    private func queueBackgroundMultipart(for item: UploadItem) {
        if isStopForResyncRequested() {
            Task { await update(itemID: item.id, status: .canceled) }
            return
        }
        // Recreate session if needed
        if bgSession == nil { setupBackgroundSession() }
        guard let bgSession = bgSession else {
            let reason = "Background session unavailable"
            print("[UPLOAD] \(reason)")
            Task { await update(itemID: item.id, status: .failed) }
            SyncRepository.shared.markFailed(contentId: item.contentId, error: reason)
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
        let bodyURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".multipart")
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
        task.taskDescription = item.id.uuidString + "|" + bodyURL.lastPathComponent + "|" + boundary + "|0|" + item.contentId + "|" + (item.isVideo ? "video" : "photo") + "|" + syncMark + "|" + assetIdForDesc

        if #available(iOS 13.0, *) {
            task.countOfBytesClientExpectsToSend = item.totalBytes
        }
        task.resume()
        // Reflect background enqueuing in both UI state and DB to keep Sync Status accurate
        Task { await update(itemID: item.id, status: .backgroundQueued) }
        SyncRepository.shared.markBackgroundQueued(contentId: item.contentId)
        print("[UPLOAD] Using legacy multipart for: \(item.filename) size=\(item.totalBytes) body=\(bodyURL.lastPathComponent)")
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

        // Remove any lingering multipart body files
        let tmp = fm.temporaryDirectory
        if let entries = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) {
            for url in entries where url.lastPathComponent.hasSuffix(".multipart") {
                let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
                do {
                    try fm.removeItem(at: url)
                    removedCount += 1
                    removedBytes += size
                } catch { }
            }
        }

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
        let bodyURL = FileManager.default.temporaryDirectory.appendingPathComponent(bodyName)
        let statusCode = (task.response as? HTTPURLResponse)?.statusCode
        let statusCodeStr = statusCode.map(String.init) ?? "(none)"
        let errStr = error?.localizedDescription ?? "(none)"
        let cidDescStr = contentIdFromDesc ?? "(none)"
        print("[UPLOAD] BG didComplete desc=\(desc) code=\(statusCodeStr) attempt=\(attempt) cidDesc=\(cidDescStr) error=\(errStr)")

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

        func setItemStatus(_ status: UploadStatus) {
            if let idx = itemIndex { items[idx].status = status }
        }

        func markFailedInDB(_ message: String) {
            guard let cid = dbContentId else { return }
            DispatchQueue.global(qos: .utility).async {
                SyncRepository.shared.markFailed(contentId: cid, error: message)
            }
        }

        func removeFiles(exportedTempURL: URL?) {
            DispatchQueue.global(qos: .utility).async {
                if let exportedTempURL { try? FileManager.default.removeItem(at: exportedTempURL) }
                try? FileManager.default.removeItem(at: bodyURL)
            }
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
                    newTask.taskDescription = idStr + "|" + bodyName + "|" + (boundary ?? "") + "|" + String(attempt + 1) + "|" + cidValue + "|" + mediaKind + "|" + marker + "|" + aidValue
                    newTask.resume()
                }
            } else {
                setItemStatus(.failed)
                markFailedInDB(msg)
                let exportedTempURL = itemIndex.map { items[$0].tempFileURL }
                removeFiles(exportedTempURL: exportedTempURL)
            }
            return
        }

        // 2) Success (2xx).
        if let code = statusCode, (200..<300).contains(code) {
            let exportedTempURL = itemIndex.map { items[$0].tempFileURL }
            if shouldMarkSyncedResolved {
                if let idx = itemIndex {
                    let completedItem = items[idx]
                    let verified = await markSyncedAfterServerVerification(for: completedItem)
                    setItemStatus(verified ? .completed : .failed)
                } else {
                    if let cid = dbContentId {
                        let _ = await markSyncedAfterServerVerification(contentId: cid, filename: bodyName, assetId: assetIdFromDesc)
                    } else {
                        markFailedInDB("Upload completed but verification could not resolve content id")
                    }
                }
            } else {
                setItemStatus(.completed)
            }
            removeFiles(exportedTempURL: exportedTempURL)
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
                newTask.taskDescription = idStr + "|" + bodyName + "|" + boundary + "|" + String(nextAttempt) + "|" + cidValue + "|" + mediaKind + "|" + marker + "|" + aidValue
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
                newTask.taskDescription = idStr + "|" + bodyName + "|" + (boundary ?? "") + "|" + String(attempt + 1) + "|" + cidValue + "|" + mediaKind + "|" + marker + "|" + aidValue
                newTask.resume()
            }
            if let cid = dbContentId, let code = statusCode {
                print("[UPLOAD] BG scheduled retry for HTTP \(code) attempt=\(attempt + 1) content_id=\(cid)")
            }
            return
        }

        // Unhandled / non-retriable HTTP response.
        setItemStatus(.failed)
        let errMsg = statusCode.map { "HTTP \($0)" } ?? "Unknown error"
        markFailedInDB(errMsg)
        let exportedTempURL = itemIndex.map { items[$0].tempFileURL }
        removeFiles(exportedTempURL: exportedTempURL)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        // Call the completion handler to let the system know we're done processing background events
        print("[UPLOAD] urlSessionDidFinishEvents: all background events delivered")
        DispatchQueue.main.async { [weak self] in
            self?.bgCompletionHandler?()
            self?.bgCompletionHandler = nil
        }
    }
}
