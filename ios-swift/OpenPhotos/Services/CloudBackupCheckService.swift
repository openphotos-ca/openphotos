import Foundation
import Photos
import CryptoKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct CloudBackupCheckResult {
    let checked: Int
    let backedUp: Int
    let deleted: Int
    let missing: Int
    let skipped: Int
    let deletedLocalIdentifiers: Set<String>
}

struct DeletedCloudListResult {
    let scanned: Int
    let deleted: Int
    let skipped: Int
    let deletedLocalIdentifiers: Set<String>
    let scannedLocalIdentifiers: Set<String>
    let serverDeletedTotal: Int
    let usedServerFirst: Bool
}

private final class ExportRequestContinuationState {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var requestID: PHAssetResourceDataRequestID?
    private var finished: Bool = false

    func setContinuation(_ cont: CheckedContinuation<URL, Error>) {
        lock.lock()
        continuation = cont
        lock.unlock()
    }

    func setRequestID(_ id: PHAssetResourceDataRequestID) {
        lock.lock()
        requestID = id
        lock.unlock()
    }

    func currentRequestID() -> PHAssetResourceDataRequestID? {
        lock.lock()
        let id = requestID
        lock.unlock()
        return id
    }

    func resume(_ result: Result<URL, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let cont = continuation
        continuation = nil
        lock.unlock()

        guard let cont else { return }
        switch result {
        case .success(let url):
            cont.resume(returning: url)
        case .failure(let error):
            cont.resume(throwing: error)
        }
    }
}

final class CloudBackupCheckService {
    static let shared = CloudBackupCheckService()

    private let exportManager = PHAssetResourceManager.default()
    private let exportSemaphore = AsyncSemaphore(value: 1)

    private struct DeletedListWork {
        let asset: PHAsset
        let resource: PHAssetResource
        let localIdentifier: String
        let fingerprint: String
        let cachedCandidates: [String]?
    }

    private init() {
    }

    func runCloudCheck(
        assets: [PHAsset],
        onProgress: @escaping (_ processed: Int, _ total: Int) -> Void
    ) async throws -> CloudBackupCheckResult {
        guard let userId = AuthManager.shared.userId, !userId.isEmpty else {
            throw NSError(domain: "CloudCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not logged in"])
        }

        let total = assets.count
        let checkedAt = Int64(Date().timeIntervalSince1970)
        var processed = 0
        var checked = 0
        var backedUp = 0
        var deleted = 0
        var missing = 0
        var skipped = 0
        var deletedLocalIdentifiers: Set<String> = []

        // Process in small chunks to bound memory and request sizes.
        let chunkSize = 20
        var i = 0
        while i < assets.count {
            try Task.checkCancellation()
            let chunk = Array(assets[i..<min(i + chunkSize, assets.count)])
            i += chunk.count

            // Collect per-asset component candidates and one flat list for server query.
            struct AssetWork {
                let localIdentifier: String
                // Each component corresponds to one resource we expect to be backed up.
                let components: [[String]]
                let isSkippableFailure: Bool
            }

            var work: [AssetWork] = []
            work.reserveCapacity(chunk.count)

            var queryIds: Set<String> = []
            var tempFiles: [URL] = []
            tempFiles.reserveCapacity(chunk.count)
            defer {
                for u in tempFiles { try? FileManager.default.removeItem(at: u) }
            }

            for asset in chunk {
                try Task.checkCancellation()
                let localId = asset.localIdentifier
                guard let res = primaryResourceToCheck(for: asset) else {
                    work.append(AssetWork(localIdentifier: localId, components: [], isSkippableFailure: true))
                    continue
                }

                var components: [[String]] = []
                var failed: Bool = false
                let fingerprint = backupIdFingerprint(asset: asset, resource: res)

                if let cached = SyncRepository.shared.getCachedBackupIdCandidates(
                    userId: userId,
                    localIdentifier: localId,
                    fingerprint: fingerprint
                ) {
                    components.append(cached)
                    for id in cached { queryIds.insert(id) }
                    work.append(AssetWork(localIdentifier: localId, components: components, isSkippableFailure: false))
                    continue
                }

                do {
                    let exported = try await exportAndComputeAssetIdCandidatesKeepingFile(
                        resource: res,
                        asset: asset,
                        userId: userId
                    )
                    tempFiles.append(exported.normalizedURL)
                    if exported.candidates.isEmpty {
                        failed = true
                    } else {
                        components.append(exported.candidates)
                        for id in exported.candidates { queryIds.insert(id) }
                        SyncRepository.shared.setCachedBackupIdCandidates(
                            userId: userId,
                            localIdentifier: localId,
                            fingerprint: fingerprint,
                            candidates: exported.candidates
                        )
                    }
                } catch let cancelError as CancellationError {
                    throw cancelError
                } catch {
                    failed = true
                }

                work.append(
                    AssetWork(
                        localIdentifier: localId,
                        components: components,
                        isSkippableFailure: failed
                    )
                )
            }

            let matches: CloudExistsMatches
            if queryIds.isEmpty {
                matches = .empty
            } else {
                try Task.checkCancellation()
                matches = try await existsWithRetry(backupIds: Array(queryIds))
            }

            for w in work {
                try Task.checkCancellation()
                processed += 1
                onProgress(processed, total)

                if w.isSkippableFailure || w.components.isEmpty {
                    skipped += 1
                    continue
                }

                checked += 1
                let isBackedUp = w.components.allSatisfy { comp in
                    comp.contains(where: matches.presentBackupIds.contains)
                }
                let isDeletedInCloud = !isBackedUp && w.components.allSatisfy { comp in
                    comp.contains(where: matches.deletedBackupIds.contains)
                }
                let status: CloudItemStatus

                if isBackedUp {
                    backedUp += 1
                    status = .backedUp
                } else if isDeletedInCloud {
                    deleted += 1
                    deletedLocalIdentifiers.insert(w.localIdentifier)
                    status = .deletedInCloud
                } else {
                    missing += 1
                    status = .missing
                }

                // Persist result; skip notifications during the bulk run.
                SyncRepository.shared.setCloudStatusForLocalIdentifier(
                    w.localIdentifier,
                    status: status,
                    checkedAt: checkedAt,
                    emitNotification: false
                )
            }
        }

        try Task.checkCancellation()
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: SyncRepository.cloudBulkStatusChangedNotification,
                object: nil
            )
        }
        return CloudBackupCheckResult(
            checked: checked,
            backedUp: backedUp,
            deleted: deleted,
            missing: missing,
            skipped: skipped,
            deletedLocalIdentifiers: deletedLocalIdentifiers
        )
    }

    func runDeletedOnlyList(
        assets: [PHAsset],
        onProgress: @escaping (_ processed: Int, _ total: Int) -> Void,
        onMatchesUpdated: @escaping (_ deletedLocalIdentifiers: Set<String>) -> Void
    ) async throws -> DeletedCloudListResult {
        guard let userId = AuthManager.shared.userId, !userId.isEmpty else {
            throw NSError(domain: "CloudCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not logged in"])
        }

        let total = assets.count
        let checkedAt = Int64(Date().timeIntervalSince1970)
        let deletedPageLimit = 500
        let matchBatchLimit = 300

        var processed = 0
        var skipped = 0
        var scannedLocalIdentifiers: Set<String> = []
        var deletedLocalIdentifiers: Set<String> = []
        var works: [DeletedListWork] = []
        works.reserveCapacity(assets.count)

        for asset in assets {
            try Task.checkCancellation()
            guard let resource = primaryResourceToCheck(for: asset) else {
                skipped += 1
                processed += 1
                onProgress(processed, total)
                continue
            }
            let fingerprint = backupIdFingerprint(asset: asset, resource: resource)
            let cachedCandidates = SyncRepository.shared.getCachedBackupIdCandidates(
                userId: userId,
                localIdentifier: asset.localIdentifier,
                fingerprint: fingerprint
            )
            works.append(
                DeletedListWork(
                    asset: asset,
                    resource: resource,
                    localIdentifier: asset.localIdentifier,
                    fingerprint: fingerprint,
                    cachedCandidates: cachedCandidates
                )
            )
        }

        let firstPage = try await deletedBackupsListWithRetry(limit: 1, after: nil)
        let serverDeletedTotal = firstPage.total
        let useServerFirst = serverDeletedTotal <= works.count

        if serverDeletedTotal == 0 {
            scannedLocalIdentifiers = Set(works.map(\.localIdentifier))
            _ = SyncRepository.shared.setCloudStatusForLocalIdentifiers(
                scannedLocalIdentifiers,
                status: .unknown,
                emitNotification: false
            )
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: SyncRepository.cloudBulkStatusChangedNotification,
                    object: nil
                )
            }
            processed = total
            onProgress(processed, total)
            return DeletedCloudListResult(
                scanned: scannedLocalIdentifiers.count,
                deleted: 0,
                skipped: skipped,
                deletedLocalIdentifiers: [],
                scannedLocalIdentifiers: scannedLocalIdentifiers,
                serverDeletedTotal: serverDeletedTotal,
                usedServerFirst: useServerFirst
            )
        }

        if useServerFirst {
            var deletedBackupIds: Set<String> = []
            var cachedLookup: [String: Set<String>] = [:]
            let cachedWorks = works.filter { $0.cachedCandidates != nil }
            let uncachedWorks = works.filter { $0.cachedCandidates == nil }

            for work in cachedWorks {
                let candidates = work.cachedCandidates ?? []
                scannedLocalIdentifiers.insert(work.localIdentifier)
                for candidate in candidates {
                    cachedLookup[candidate, default: []].insert(work.localIdentifier)
                }
            }

            func absorbDeletedPage(_ backupIds: [String]) {
                for backupId in backupIds {
                    guard deletedBackupIds.insert(backupId).inserted else { continue }
                    guard let localIds = cachedLookup[backupId], !localIds.isEmpty else { continue }
                    let before = deletedLocalIdentifiers.count
                    deletedLocalIdentifiers.formUnion(localIds)
                    if deletedLocalIdentifiers.count != before {
                        onMatchesUpdated(deletedLocalIdentifiers)
                    }
                }
            }

            absorbDeletedPage(firstPage.backupIds)
            var nextAfter = firstPage.nextAfter
            while let after = nextAfter, !after.isEmpty {
                try Task.checkCancellation()
                let page = try await deletedBackupsListWithRetry(limit: deletedPageLimit, after: after)
                absorbDeletedPage(page.backupIds)
                nextAfter = page.nextAfter
            }

            processed = min(total, processed + cachedWorks.count)
            onProgress(processed, total)

            for work in uncachedWorks {
                try Task.checkCancellation()
                do {
                    let exported = try await exportAndComputeAssetIdCandidatesKeepingFile(
                        resource: work.resource,
                        asset: work.asset,
                        userId: userId
                    )
                    defer { try? FileManager.default.removeItem(at: exported.normalizedURL) }
                    if exported.candidates.isEmpty {
                        skipped += 1
                    } else {
                        SyncRepository.shared.setCachedBackupIdCandidates(
                            userId: userId,
                            localIdentifier: work.localIdentifier,
                            fingerprint: work.fingerprint,
                            candidates: exported.candidates
                        )
                        scannedLocalIdentifiers.insert(work.localIdentifier)
                        if exported.candidates.contains(where: deletedBackupIds.contains) {
                            if deletedLocalIdentifiers.insert(work.localIdentifier).inserted {
                                onMatchesUpdated(deletedLocalIdentifiers)
                            }
                        }
                    }
                } catch let cancelError as CancellationError {
                    throw cancelError
                } catch {
                    skipped += 1
                }
                processed += 1
                onProgress(processed, total)
            }
        } else {
            struct PendingMatchWork {
                let localIdentifier: String
                let fingerprint: String
                let candidates: [String]
            }

            func processMatchBatch(_ batch: [PendingMatchWork]) async throws {
                guard !batch.isEmpty else { return }
                let queryIds = Array(Set(batch.flatMap(\.candidates)))
                let deletedMatches = try await matchDeletedBackupsWithRetry(queryIds)
                for work in batch {
                    scannedLocalIdentifiers.insert(work.localIdentifier)
                    if work.candidates.contains(where: deletedMatches.contains) {
                        if deletedLocalIdentifiers.insert(work.localIdentifier).inserted {
                            onMatchesUpdated(deletedLocalIdentifiers)
                        }
                    }
                }
            }

            var pendingBatch: [PendingMatchWork] = []
            pendingBatch.reserveCapacity(32)
            var pendingQueryIds: Set<String> = []

            func flushPendingBatch() async throws {
                try await processMatchBatch(pendingBatch)
                processed += pendingBatch.count
                onProgress(processed, total)
                pendingBatch.removeAll(keepingCapacity: true)
                pendingQueryIds.removeAll(keepingCapacity: true)
            }

            for work in works {
                try Task.checkCancellation()
                if let cached = work.cachedCandidates, !cached.isEmpty {
                    pendingBatch.append(
                        PendingMatchWork(
                            localIdentifier: work.localIdentifier,
                            fingerprint: work.fingerprint,
                            candidates: cached
                        )
                    )
                    pendingQueryIds.formUnion(cached)
                    if pendingQueryIds.count >= matchBatchLimit || pendingBatch.count >= 64 {
                        try await flushPendingBatch()
                    }
                    continue
                }

                do {
                    let exported = try await exportAndComputeAssetIdCandidatesKeepingFile(
                        resource: work.resource,
                        asset: work.asset,
                        userId: userId
                    )
                    defer { try? FileManager.default.removeItem(at: exported.normalizedURL) }
                    if exported.candidates.isEmpty {
                        skipped += 1
                        processed += 1
                        onProgress(processed, total)
                        continue
                    }
                    SyncRepository.shared.setCachedBackupIdCandidates(
                        userId: userId,
                        localIdentifier: work.localIdentifier,
                        fingerprint: work.fingerprint,
                        candidates: exported.candidates
                    )
                    pendingBatch.append(
                        PendingMatchWork(
                            localIdentifier: work.localIdentifier,
                            fingerprint: work.fingerprint,
                            candidates: exported.candidates
                        )
                    )
                    pendingQueryIds.formUnion(exported.candidates)
                    if pendingQueryIds.count >= matchBatchLimit || pendingBatch.count >= 24 {
                        try await flushPendingBatch()
                    }
                } catch let cancelError as CancellationError {
                    throw cancelError
                } catch {
                    skipped += 1
                    processed += 1
                    onProgress(processed, total)
                }
            }

            if !pendingBatch.isEmpty {
                try await flushPendingBatch()
            }
        }

        let deletedSet = deletedLocalIdentifiers
        let clearSet = scannedLocalIdentifiers.subtracting(deletedSet)
        _ = SyncRepository.shared.setCloudStatusForLocalIdentifiers(
            deletedSet,
            status: .deletedInCloud,
            checkedAt: checkedAt,
            emitNotification: false
        )
        _ = SyncRepository.shared.setCloudStatusForLocalIdentifiers(
            clearSet,
            status: .unknown,
            emitNotification: false
        )
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: SyncRepository.cloudBulkStatusChangedNotification,
                object: nil
            )
        }
        onMatchesUpdated(deletedLocalIdentifiers)

        return DeletedCloudListResult(
            scanned: scannedLocalIdentifiers.count,
            deleted: deletedLocalIdentifiers.count,
            skipped: skipped,
            deletedLocalIdentifiers: deletedLocalIdentifiers,
            scannedLocalIdentifiers: scannedLocalIdentifiers,
            serverDeletedTotal: serverDeletedTotal,
            usedServerFirst: useServerFirst
        )
    }

    private func existsWithRetry(backupIds: [String]) async throws -> CloudExistsMatches {
        try Task.checkCancellation()
        do {
            return try await ServerPhotosService.shared.existsMatches(
                backupIds: backupIds,
                includeDeletedMatches: true
            )
        } catch {
            if isRetryableNetworkError(error) {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 700_000_000)
                try Task.checkCancellation()
                return try await ServerPhotosService.shared.existsMatches(
                    backupIds: backupIds,
                    includeDeletedMatches: true
                )
            }
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

    private func deletedBackupsListWithRetry(limit: Int, after: String?) async throws -> DeletedBackupsPage {
        try Task.checkCancellation()
        do {
            return try await ServerPhotosService.shared.listDeletedBackups(limit: limit, after: after)
        } catch {
            if isRetryableNetworkError(error) {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 700_000_000)
                try Task.checkCancellation()
                return try await ServerPhotosService.shared.listDeletedBackups(limit: limit, after: after)
            }
            throw error
        }
    }

    private func matchDeletedBackupsWithRetry(_ backupIds: [String]) async throws -> Set<String> {
        try Task.checkCancellation()
        do {
            return try await ServerPhotosService.shared.matchDeletedBackups(backupIds)
        } catch {
            if isRetryableNetworkError(error) {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 700_000_000)
                try Task.checkCancellation()
                return try await ServerPhotosService.shared.matchDeletedBackups(backupIds)
            }
            throw error
        }
    }

    // MARK: - Resource selection (match uploader's intent)

    private func primaryResourceToCheck(for asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        let hasPairedVideo = resources.contains { $0.type == .pairedVideo }
        let isLiveAsset = asset.mediaSubtypes.contains(.photoLive) || hasPairedVideo

        if asset.mediaType == .video {
            for res in resources {
                if res.type == .video || res.type == .fullSizeVideo {
                    return res
                }
            }
            return resources.first { $0.type == .pairedVideo }
        }

        // Images (including Live Photos): prefer the still component.
        for res in resources {
            if res.type == .photo || res.type == .fullSizePhoto || res.type == .alternatePhoto {
                return res
            }
        }
        if isLiveAsset {
            // Fallback: some libraries report the still as "fullSizePhoto" only.
            return resources.first { $0.type == .fullSizePhoto }
        }
        return nil
    }

    private func backupIdFingerprint(asset: PHAsset, resource: PHAssetResource) -> String {
        let creation = Int64(asset.creationDate?.timeIntervalSince1970 ?? 0)
        let modified = Int64(asset.modificationDate?.timeIntervalSince1970 ?? 0)
        let durationMs = Int64((asset.mediaType == .video ? asset.duration : 0) * 1000.0)
        let uti = resource.uniformTypeIdentifier
        return [
            "v1",
            "mt=\(asset.mediaType.rawValue)",
            "st=\(asset.mediaSubtypes.rawValue)",
            "rt=\(resource.type.rawValue)",
            "fn=\(resource.originalFilename)",
            "uti=\(uti)",
            "w=\(asset.pixelWidth)",
            "h=\(asset.pixelHeight)",
            "durms=\(durationMs)",
            "c=\(creation)",
            "m=\(modified)"
        ].joined(separator: "|")
    }

    // MARK: - Export + asset_id computation

    private struct ExportedCandidates {
        let candidates: [String]
        let normalizedURL: URL
    }

    private func exportAndComputeAssetIdCandidatesKeepingFile(
        resource: PHAssetResource,
        asset: PHAsset,
        userId: String
    ) async throws -> ExportedCandidates {
        try Task.checkCancellation()
        await exportSemaphore.wait()
        defer { exportSemaphore.signal() }

        let filename = resource.originalFilename
        let isVideo = resource.type == .video || resource.type == .fullSizeVideo || resource.type == .pairedVideo
        let lower = filename.lowercased()

        let exportedURL = try await exportResourceToTempFile(
            resource: resource,
            allowNetwork: true,
            filename: filename
        )
        try Task.checkCancellation()

        // Normalize: if the file is actually HEIC/HEIF but has a misleading .jpg/.jpeg name, convert to JPEG.
        var normalizedURL = exportedURL
        if !isVideo && (lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg")) {
            if isHEICContainer(url: normalizedURL) {
                if let conv = ImageConversion.convertHEICtoJPEG(inputURL: normalizedURL, quality: 0.9) {
                    try? FileManager.default.removeItem(at: normalizedURL)
                    normalizedURL = conv.url
                }
            }
        }
        try Task.checkCancellation()

        var candidates: [String] = []
        if let raw = BackupId.computeBackupId(fileURL: normalizedURL, userId: userId) {
            candidates.append(raw)
        }

        // Also compute the "locked upload" candidate: HEIC/HEIF -> JPEG (since locked uploads encrypt a JPEG for images).
        if !isVideo && isHEICContainer(url: normalizedURL) {
            if let conv = ImageConversion.convertHEICtoJPEG(inputURL: normalizedURL, quality: 0.9) {
                if let alt = BackupId.computeBackupId(fileURL: conv.url, userId: userId), !candidates.contains(alt) {
                    candidates.append(alt)
                }
                try? FileManager.default.removeItem(at: conv.url)
            }
        }

        try Task.checkCancellation()
        return ExportedCandidates(candidates: candidates, normalizedURL: normalizedURL)
    }

    private func exportResourceToTempFile(
        resource: PHAssetResource,
        allowNetwork: Bool,
        filename: String
    ) async throws -> URL {
        try Task.checkCancellation()
        let tmpDir = FileManager.default.temporaryDirectory
        let destURL = tmpDir.appendingPathComponent(UUID().uuidString + "_" + filename)
        FileManager.default.createFile(atPath: destURL.path, contents: nil, attributes: nil)
        guard let handle = try? FileHandle(forWritingTo: destURL) else {
            throw NSError(domain: "CloudCheck", code: 10, userInfo: [NSLocalizedDescriptionKey: "Failed to create temp file"])
        }
        defer { try? handle.close() }

        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = allowNetwork

        let continuationState = ExportRequestContinuationState()

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { cont in
                continuationState.setContinuation(cont)
                let requestID = self.exportManager.requestData(for: resource, options: opts) { data in
                    try? handle.write(contentsOf: data)
                } completionHandler: { error in
                    if let error {
                        try? FileManager.default.removeItem(at: destURL)
                        continuationState.resume(.failure(error))
                        return
                    }
                    continuationState.resume(.success(destURL))
                }
                continuationState.setRequestID(requestID)
                if Task.isCancelled {
                    self.exportManager.cancelDataRequest(requestID)
                    try? FileManager.default.removeItem(at: destURL)
                    continuationState.resume(.failure(CancellationError()))
                }
            }
        }, onCancel: {
            if let requestID = continuationState.currentRequestID() {
                self.exportManager.cancelDataRequest(requestID)
            }
            try? FileManager.default.removeItem(at: destURL)
            continuationState.resume(.failure(CancellationError()))
        })
    }

    private func isHEICContainer(url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(src) as String?
        else { return false }
        let t = type.lowercased()
        return t.contains("heic") || t.contains("heif")
    }
}

final class AsyncSemaphore: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int) {
        self.value = value
    }

    func wait() async {
        await withCheckedContinuation { cont in
            var shouldResumeNow = false
            lock.lock()
            if value > 0 {
                value -= 1
                shouldResumeNow = true
            } else {
                waiters.append(cont)
            }
            lock.unlock()
            if shouldResumeNow {
                cont.resume()
            }
        }
    }

    func signal() {
        var cont: CheckedContinuation<Void, Never>?
        lock.lock()
        if !waiters.isEmpty {
            cont = waiters.removeFirst()
        } else {
            value += 1
        }
        lock.unlock()
        cont?.resume()
    }
}

enum AssetId {
    static func computeAssetId(fileURL: URL, userId: String) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        let key = SymmetricKey(data: Data(userId.utf8))
        var hmac = HMAC<SHA256>(key: key)
        while autoreleasepool(invoking: {
            if let chunk = try? handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                hmac.update(data: chunk)
                return true
            }
            return false
        }) {}
        let mac = Data(hmac.finalize())
        return Base58.encode(mac.prefix(16))
    }
}

enum BackupId {
    static func computeBackupId(fileURL: URL, userId: String) -> String? {
        let key = SymmetricKey(data: Data(userId.utf8))
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }

        var hmac = HMAC<SHA256>(key: key)
        let chunkSize = 1024 * 1024

        func readExact(_ n: Int) throws -> Data {
            if n <= 0 { return Data() }
            var out = Data()
            out.reserveCapacity(n)
            while out.count < n {
                let next = try handle.read(upToCount: n - out.count) ?? Data()
                if next.isEmpty {
                    throw NSError(domain: "CloudCheck", code: 20, userInfo: [NSLocalizedDescriptionKey: "Unexpected EOF"])
                }
                out.append(next)
            }
            return out
        }

        func streamBytes(_ remaining: Int? = nil, update: (Data) -> Void) throws {
            if let remaining {
                var left = remaining
                while left > 0 {
                    let toRead = min(chunkSize, left)
                    let chunk = try handle.read(upToCount: toRead) ?? Data()
                    if chunk.isEmpty {
                        throw NSError(domain: "CloudCheck", code: 21, userInfo: [NSLocalizedDescriptionKey: "Unexpected EOF"])
                    }
                    update(chunk)
                    left -= chunk.count
                }
            } else {
                while true {
                    let chunk: Data? = autoreleasepool { try? handle.read(upToCount: chunkSize) }
                    guard let chunk, !chunk.isEmpty else { break }
                    update(chunk)
                }
            }
        }

        // Read prefix to detect JPEG vs other formats.
        guard let prefix = try? readExact(2) else { return nil }
        hmac.update(data: prefix)

        let isJpeg = prefix.count == 2 && prefix[prefix.startIndex] == 0xFF && prefix[prefix.startIndex.advanced(by: 1)] == 0xD8
        if !isJpeg {
            // Hash remaining bytes as-is.
            do {
                try streamBytes(nil) { hmac.update(data: $0) }
                let mac = Data(hmac.finalize())
                return Base58.encode(mac.prefix(16))
            } catch {
                return nil
            }
        }

        // JPEG: hash bytes while skipping APP1 Exif/XMP segments (stability across metadata rewrites).
        let exifPrefix = Data([0x45, 0x78, 0x69, 0x66, 0x00, 0x00]) // "Exif\0\0"
        let xmpPrefix = Data("http://ns.adobe.com/xap/1.0/\0".utf8)

        func readMarkerBytes() throws -> Data? {
            let first = try handle.read(upToCount: 1) ?? Data()
            if first.isEmpty { return nil } // EOF
            guard first[first.startIndex] == 0xFF else {
                throw NSError(domain: "CloudCheck", code: 22, userInfo: [NSLocalizedDescriptionKey: "Invalid JPEG marker"])
            }
            var out = Data(first)
            while true {
                let b = try readExact(1)
                out.append(b)
                if b[b.startIndex] != 0xFF {
                    break
                }
            }
            return out
        }

        func u16be(_ d: Data) -> Int {
            let a = Int(d[d.startIndex])
            let b = Int(d[d.startIndex.advanced(by: 1)])
            return (a << 8) | b
        }

        do {
            while true {
                guard let markerBytes = try readMarkerBytes() else { break }
                guard let marker = markerBytes.last else { break }

                // EOI
                if marker == 0xD9 {
                    hmac.update(data: markerBytes)
                    break
                }

                // SOS: after this, the rest is scan data until EOI; we hash all remaining bytes as-is.
                if marker == 0xDA {
                    let lenData = try readExact(2)
                    let len = u16be(lenData)
                    let headerLen = max(0, len - 2)
                    let header = try readExact(headerLen)
                    hmac.update(data: markerBytes)
                    hmac.update(data: lenData)
                    hmac.update(data: header)
                    try streamBytes(nil) { hmac.update(data: $0) }
                    break
                }

                // Other segments: have a 2-byte big-endian length (includes these two bytes).
                let lenData = try readExact(2)
                let len = u16be(lenData)
                if len < 2 {
                    throw NSError(domain: "CloudCheck", code: 23, userInfo: [NSLocalizedDescriptionKey: "Invalid JPEG segment length"])
                }
                let payloadLen = len - 2

                if marker == 0xE1 {
                    // APP1: peek to detect Exif/XMP, then either skip or hash the full segment.
                    let peekLen = min(payloadLen, max(exifPrefix.count, xmpPrefix.count))
                    let prefixBytes = try readExact(peekLen)
                    let isExif = prefixBytes.count >= exifPrefix.count && prefixBytes.prefix(exifPrefix.count) == exifPrefix
                    let isXmp = prefixBytes.count >= xmpPrefix.count && prefixBytes.prefix(xmpPrefix.count) == xmpPrefix
                    let keep = !(isExif || isXmp)

                    if keep {
                        hmac.update(data: markerBytes)
                        hmac.update(data: lenData)
                        hmac.update(data: prefixBytes)
                    }
                    let remainingPayload = payloadLen - prefixBytes.count
                    if remainingPayload > 0 {
                        if keep {
                            try streamBytes(remainingPayload) { hmac.update(data: $0) }
                        } else {
                            try streamBytes(remainingPayload) { _ in }
                        }
                    }
                } else {
                    // Keep all non-APP1 segments.
                    hmac.update(data: markerBytes)
                    hmac.update(data: lenData)
                    if payloadLen > 0 {
                        try streamBytes(payloadLen) { hmac.update(data: $0) }
                    }
                }
            }

            let mac = Data(hmac.finalize())
            return Base58.encode(mac.prefix(16))
        } catch {
            // Fallback: if the JPEG segment parser fails, hash the raw bytes as-is (still streaming).
            guard let h2 = try? FileHandle(forReadingFrom: fileURL) else { return nil }
            defer { try? h2.close() }
            var hmac2 = HMAC<SHA256>(key: key)
            while true {
                let chunk: Data? = autoreleasepool { try? h2.read(upToCount: chunkSize) }
                guard let chunk, !chunk.isEmpty else { break }
                hmac2.update(data: chunk)
            }
            let mac = Data(hmac2.finalize())
            return Base58.encode(mac.prefix(16))
        }
    }
}

enum ImageConversion {
    private static func imageByRemovingAlphaForJPEG(_ image: CGImage) -> CGImage {
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
        // JPEG cannot represent alpha; flatten onto white once to avoid opaque+alpha encoder warnings.
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage() ?? image
    }

    static func convertHEICtoJPEG(inputURL: URL, quality: CGFloat) -> (url: URL, width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithURL(inputURL as CFURL, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as NSDictionary?
        let w = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let h = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let maxSide = max(1, max(w, h))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgOriented = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        let jpegReady = imageByRemovingAlphaForJPEG(cgOriented)
        let destURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        guard let dest = CGImageDestinationCreateWithURL(destURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        let encProps: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, jpegReady, encProps as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (destURL, jpegReady.width, jpegReady.height)
    }
}
