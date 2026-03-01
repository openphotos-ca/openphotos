import Foundation
import Photos
import CryptoKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct CloudBackupCheckResult {
    let checked: Int
    let backedUp: Int
    let missing: Int
    let skipped: Int
}

final class CloudBackupCheckService {
    static let shared = CloudBackupCheckService()

    private let exportManager = PHAssetResourceManager.default()
    private let exportSemaphore = AsyncSemaphore(value: 1)

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
        var missing = 0
        var skipped = 0

        // Process in small chunks to bound memory and request sizes.
        let chunkSize = 20
        var i = 0
        while i < assets.count {
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

            let present: Set<String>
            if queryIds.isEmpty {
                present = []
            } else {
                present = try await existsWithRetry(backupIds: Array(queryIds))
            }

            for w in work {
                processed += 1
                onProgress(processed, total)

                if w.isSkippableFailure || w.components.isEmpty {
                    skipped += 1
                    continue
                }

                checked += 1
                let isBackedUp = w.components.allSatisfy { comp in comp.contains(where: present.contains) }

                if isBackedUp {
                    backedUp += 1
                } else {
                    missing += 1
                }

                // Persist result; skip notifications during the bulk run.
                SyncRepository.shared.setCloudBackedUpForLocalIdentifier(
                    w.localIdentifier,
                    backedUp: isBackedUp,
                    checkedAt: checkedAt,
                    emitNotification: false
                )
            }
        }

        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: SyncRepository.cloudBulkStatusChangedNotification,
                object: nil
            )
        }
        return CloudBackupCheckResult(checked: checked, backedUp: backedUp, missing: missing, skipped: skipped)
    }

    private func existsWithRetry(backupIds: [String]) async throws -> Set<String> {
        do {
            return try await ServerPhotosService.shared.existsFullyBackedUp(backupIds: backupIds)
        } catch {
            if isRetryableNetworkError(error) {
                try? await Task.sleep(nanoseconds: 700_000_000)
                return try await ServerPhotosService.shared.existsFullyBackedUp(backupIds: backupIds)
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

        return ExportedCandidates(candidates: candidates, normalizedURL: normalizedURL)
    }

    private func exportResourceToTempFile(
        resource: PHAssetResource,
        allowNetwork: Bool,
        filename: String
    ) async throws -> URL {
        let tmpDir = FileManager.default.temporaryDirectory
        let destURL = tmpDir.appendingPathComponent(UUID().uuidString + "_" + filename)
        FileManager.default.createFile(atPath: destURL.path, contents: nil, attributes: nil)
        guard let handle = try? FileHandle(forWritingTo: destURL) else {
            throw NSError(domain: "CloudCheck", code: 10, userInfo: [NSLocalizedDescriptionKey: "Failed to create temp file"])
        }
        defer { try? handle.close() }

        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = allowNetwork

        return try await withCheckedThrowingContinuation { cont in
            self.exportManager.requestData(for: resource, options: opts) { data in
                try? handle.write(contentsOf: data)
            } completionHandler: { error in
                if let error {
                    try? FileManager.default.removeItem(at: destURL)
                    cont.resume(throwing: error)
                    return
                }
                cont.resume(returning: destURL)
            }
        }
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
        let destURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        guard let dest = CGImageDestinationCreateWithURL(destURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        let encProps: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, cgOriented, encProps as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (destURL, cgOriented.width, cgOriented.height)
    }
}
