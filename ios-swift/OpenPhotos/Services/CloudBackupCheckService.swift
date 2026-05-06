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
    let duplicateGroups: Int
    let duplicateExcess: Int
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
    private let existsRequestBatchSize = 100

    private struct DeletedListWork {
        let asset: PHAsset
        let resource: PHAssetResource
        let localIdentifier: String
        let fingerprint: String
        let cachedCandidates: [String]?
    }

    private struct MissingRecheckWork {
        let localIdentifier: String
        let filename: String
        let components: [[String]]
        let metadataItem: CloudExistsMetadataItem
    }

    private init() {
    }

    private func describeCandidates(_ components: [[String]]) -> String {
        let unique = Array(Set(components.flatMap { $0 })).sorted()
        let head = unique.prefix(4)
        let suffix = unique.count > head.count ? ",..." : ""
        return head.joined(separator: ",") + suffix
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
        var pendingRecheck: [MissingRecheckWork] = []
        var candidateCacheHits = 0
        var candidateCacheMisses = 0
        var candidateExports = 0
        var duplicateMatchOwners: [String: [String: String]] = [:]
        let startedAt = Date()

        // Keep requests bulked enough to avoid hundreds of HTTP round trips.
        let chunkSize = existsRequestBatchSize
        var i = 0
        while i < assets.count {
            try Task.checkCancellation()
            let chunk = Array(assets[i..<min(i + chunkSize, assets.count)])
            i += chunk.count

            // Collect per-asset component candidates and one flat list for server query.
            struct AssetWork {
                let localIdentifier: String
                let filename: String
                // Each component corresponds to one resource we expect to be backed up.
                let components: [[String]]
                let metadataItem: CloudExistsMetadataItem?
                let isSkippableFailure: Bool
                let skipReason: String?
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
                    work.append(
                        AssetWork(
                            localIdentifier: localId,
                            filename: localId,
                            components: [],
                            metadataItem: nil,
                            isSkippableFailure: true,
                            skipReason: "no-primary-resource"
                        )
                    )
                    continue
                }

                var components: [[String]] = []
                var failed: Bool = false
                var skipReason: String?
                let fingerprint = backupIdFingerprint(asset: asset, resource: res)

                if let cached = SyncRepository.shared.getCachedBackupIdCandidates(
                    userId: userId,
                    localIdentifier: localId,
                    fingerprint: fingerprint
                ) {
                    candidateCacheHits += 1
                    components.append(cached)
                    for id in cached { queryIds.insert(id) }
                    work.append(
                        AssetWork(
                            localIdentifier: localId,
                            filename: res.originalFilename,
                            components: components,
                            metadataItem: makeMetadataItem(asset: asset, resource: res, components: components),
                            isSkippableFailure: false,
                            skipReason: nil
                        )
                    )
                    continue
                }

                candidateCacheMisses += 1
                do {
                    let exported = try await exportAndComputeAssetIdCandidatesKeepingFile(
                        resource: res,
                        asset: asset,
                        userId: userId
                    )
                    tempFiles.append(exported.normalizedURL)
                    if exported.candidates.isEmpty {
                        failed = true
                        skipReason = "no-backup-candidates"
                    } else {
                        candidateExports += 1
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
                    skipReason = "export-failed"
                }

                work.append(
                    AssetWork(
                        localIdentifier: localId,
                        filename: res.originalFilename,
                        components: components,
                        metadataItem: makeMetadataItem(asset: asset, resource: res, components: components),
                        isSkippableFailure: failed,
                        skipReason: skipReason
                    )
                )
            }

            let matches: CloudExistsMatches
            if queryIds.isEmpty {
                matches = .empty
            } else {
                try Task.checkCancellation()
                let metadataItems = work.compactMap(\.metadataItem)
                matches = try await existsWithRetry(
                    backupIds: metadataItems.isEmpty ? Array(queryIds) : [],
                    metadataItems: metadataItems
                )
            }

            for w in work {
                try Task.checkCancellation()
                processed += 1
                onProgress(processed, total)

                if w.isSkippableFailure || w.components.isEmpty {
                    skipped += 1
                    print(
                        "[CLOUDCHECK] skipped local_id=\(w.localIdentifier) filename=\(w.filename) " +
                        "reason=\(w.skipReason ?? "unknown")"
                    )
                    continue
                }

                if let matchId = w.metadataItem?.matchId {
                    duplicateMatchOwners[matchId, default: [:]][w.localIdentifier] = w.filename
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
                    print(
                        "[CLOUDCHECK] deleted local_id=\(w.localIdentifier) filename=\(w.filename) " +
                        "backup_candidates=\(describeCandidates(w.components))"
                    )
                    status = .deletedInCloud
                } else {
                    missing += 1
                    if let metadataItem = w.metadataItem {
                        pendingRecheck.append(
                            MissingRecheckWork(
                                localIdentifier: w.localIdentifier,
                                filename: w.filename,
                                components: w.components,
                                metadataItem: metadataItem
                            )
                        )
                    }
                    print(
                        "[CLOUDCHECK] missing local_id=\(w.localIdentifier) filename=\(w.filename) " +
                        "backup_candidates=\(describeCandidates(w.components))"
                    )
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

        if !pendingRecheck.isEmpty {
            let rechecked = try await recheckMissingCloudItems(
                pendingRecheck,
                checkedAt: checkedAt
            )
            backedUp += rechecked.recoveredBackedUp
            deleted += rechecked.recoveredDeleted
            deletedLocalIdentifiers.formUnion(rechecked.deletedLocalIdentifiers)
            missing -= (rechecked.recoveredBackedUp + rechecked.recoveredDeleted)
        }

        try Task.checkCancellation()
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: SyncRepository.cloudBulkStatusChangedNotification,
                object: nil
            )
        }
        let duplicateGroups = duplicateMatchOwners
            .map { (matchId: $0.key, owners: $0.value) }
            .filter { $0.owners.count > 1 }
            .sorted { lhs, rhs in
                if lhs.owners.count != rhs.owners.count {
                    return lhs.owners.count > rhs.owners.count
                }
                return lhs.matchId < rhs.matchId
            }
        let duplicateGroupCount = duplicateGroups.count
        let duplicateExcess = duplicateGroups.reduce(0) { $0 + max(0, $1.owners.count - 1) }
        if !duplicateGroups.isEmpty {
            let sample = duplicateGroups.prefix(12).map { group in
                let files = group.owners.values.sorted().prefix(4).joined(separator: "|")
                return "\(String(group.matchId.prefix(12))):count=\(group.owners.count):\(files)"
            }.joined(separator: "; ")
            print(
                "[CLOUDCHECK] local duplicate backup ids groups=\(duplicateGroupCount) " +
                "duplicate_excess=\(duplicateExcess) sample=\(sample)"
            )
        }
        print(
            "[CLOUDCHECK] run stats selected=\(total) checked=\(checked) backed=\(backedUp) " +
            "deleted=\(deleted) missing=\(missing) skipped=\(skipped) batch_size=\(existsRequestBatchSize) " +
            "duplicate_groups=\(duplicateGroupCount) duplicate_excess=\(duplicateExcess) " +
            "candidate_cache_hits=\(candidateCacheHits) candidate_cache_misses=\(candidateCacheMisses) " +
            "candidate_exports=\(candidateExports) elapsed_ms=\(Int((Date().timeIntervalSince(startedAt) * 1000).rounded()))"
        )
        return CloudBackupCheckResult(
            checked: checked,
            backedUp: backedUp,
            deleted: deleted,
            missing: missing,
            skipped: skipped,
            duplicateGroups: duplicateGroupCount,
            duplicateExcess: duplicateExcess,
            deletedLocalIdentifiers: deletedLocalIdentifiers
        )
    }

    private func recheckMissingCloudItems(
        _ items: [MissingRecheckWork],
        checkedAt: Int64
    ) async throws -> (
        recoveredBackedUp: Int,
        recoveredDeleted: Int,
        deletedLocalIdentifiers: Set<String>
    ) {
        guard !items.isEmpty else { return (0, 0, []) }

        let passDelaysNs: [UInt64] = [3_000_000_000, 6_000_000_000]
        let batchSize = existsRequestBatchSize
        var remaining = items
        var recoveredBackedUp = 0
        var recoveredDeleted = 0
        var deletedLocalIdentifiers: Set<String> = []

        for (passIndex, delayNs) in passDelaysNs.enumerated() {
            guard !remaining.isEmpty else { break }
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: delayNs)
            try Task.checkCancellation()

            let beforeCount = remaining.count
            var stillMissing: [MissingRecheckWork] = []
            stillMissing.reserveCapacity(remaining.count)

            var start = 0
            while start < remaining.count {
                try Task.checkCancellation()
                let batch = Array(remaining[start..<min(start + batchSize, remaining.count)])
                start += batch.count

                let queryIds = Array(Set(batch.flatMap { $0.components.flatMap { $0 } }))
                let metadataItems = batch.map(\.metadataItem)
                let matches = queryIds.isEmpty ? CloudExistsMatches.empty : try await existsWithRetry(
                    backupIds: metadataItems.isEmpty ? queryIds : [],
                    metadataItems: metadataItems
                )

                for item in batch {
                    let isBackedUp = item.components.allSatisfy { comp in
                        comp.contains(where: matches.presentBackupIds.contains)
                    }
                    let isDeletedInCloud = !isBackedUp && item.components.allSatisfy { comp in
                        comp.contains(where: matches.deletedBackupIds.contains)
                    }

                    if isBackedUp {
                        recoveredBackedUp += 1
                        SyncRepository.shared.setCloudStatusForLocalIdentifier(
                            item.localIdentifier,
                            status: .backedUp,
                            checkedAt: checkedAt,
                            emitNotification: false
                        )
                        print(
                            "[CLOUDCHECK] recheck recovered local_id=\(item.localIdentifier) filename=\(item.filename) " +
                            "status=backed_up backup_candidates=\(describeCandidates(item.components))"
                        )
                    } else if isDeletedInCloud {
                        recoveredDeleted += 1
                        deletedLocalIdentifiers.insert(item.localIdentifier)
                        SyncRepository.shared.setCloudStatusForLocalIdentifier(
                            item.localIdentifier,
                            status: .deletedInCloud,
                            checkedAt: checkedAt,
                            emitNotification: false
                        )
                        print(
                            "[CLOUDCHECK] recheck recovered local_id=\(item.localIdentifier) filename=\(item.filename) " +
                            "status=deleted_in_cloud backup_candidates=\(describeCandidates(item.components))"
                        )
                    } else {
                        stillMissing.append(item)
                    }
                }
            }

            print(
                "[CLOUDCHECK] recheck pass=\(passIndex + 1) before=\(beforeCount) after=\(stillMissing.count) " +
                "recovered_backed=\(recoveredBackedUp) recovered_deleted=\(recoveredDeleted)"
            )

            remaining = stillMissing
        }

        return (recoveredBackedUp, recoveredDeleted, deletedLocalIdentifiers)
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

    private func existsWithRetry(
        backupIds: [String],
        metadataItems: [CloudExistsMetadataItem] = []
    ) async throws -> CloudExistsMatches {
        try Task.checkCancellation()
        do {
            return try await ServerPhotosService.shared.existsMatches(
                backupIds: backupIds,
                metadataItems: metadataItems,
                includeDeletedMatches: true
            )
        } catch {
            if isRetryableNetworkError(error) {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 700_000_000)
                try Task.checkCancellation()
                return try await ServerPhotosService.shared.existsMatches(
                    backupIds: backupIds,
                    metadataItems: metadataItems,
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
            "v2-content-fallback",
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

    private func makeMetadataItem(
        asset: PHAsset,
        resource: PHAssetResource,
        components: [[String]]
    ) -> CloudExistsMetadataItem? {
        let backupIds = Array(Set(components.flatMap { $0 })).sorted()
        guard let matchId = backupIds.first else { return nil }
        return CloudExistsMetadataItem(
            matchId: matchId,
            backupIds: backupIds,
            contentId: contentIdForAsset(asset),
            filename: resource.originalFilename,
            createdAt: asset.creationDate.map { Int64($0.timeIntervalSince1970) },
            width: asset.pixelWidth > 0 ? asset.pixelWidth : nil,
            height: asset.pixelHeight > 0 ? asset.pixelHeight : nil,
            isVideo: asset.mediaType == .video
        )
    }

    private func contentIdForAsset(_ asset: PHAsset) -> String {
        let digest = Insecure.MD5.hash(data: Data(asset.localIdentifier.utf8))
        return Base58.encode(Data(digest))
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
        if !isVideo,
           let visual = BackupId.computeVisualBackupId(fileURL: normalizedURL, userId: userId),
           !candidates.contains(visual) {
            candidates.append(visual)
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

    static func computeVisualBackupId(fileURL: URL, userId: String) -> String? {
        guard let cgImage = decodedUprightCGImage(url: fileURL) else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerRow = width * 4
        let totalBytes = bytesPerRow * height
        var pixelData = Data(count: totalBytes)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )
        let rendered = pixelData.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let base = rawBuffer.baseAddress else { return false }
            guard let ctx = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            ) else {
                return false
            }
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(rect)
            ctx.draw(cgImage, in: rect)
            return true
        }
        guard rendered else { return nil }

        let key = SymmetricKey(data: Data(userId.utf8))
        var hmac = HMAC<SHA256>(key: key)
        hmac.update(data: Data("visual-image-v1".utf8))
        var widthBE = UInt32(width).bigEndian
        var heightBE = UInt32(height).bigEndian
        withUnsafeBytes(of: &widthBE) { hmac.update(data: Data($0)) }
        withUnsafeBytes(of: &heightBE) { hmac.update(data: Data($0)) }
        hmac.update(data: pixelData)
        let mac = Data(hmac.finalize())
        return Base58.encode(mac.prefix(16))
    }

    private static func decodedUprightCGImage(url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as NSDictionary?
        let w = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let h = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let maxSide = max(1, max(w, h))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(src, 0, nil)
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
