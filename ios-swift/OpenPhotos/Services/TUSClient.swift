import Foundation

// Minimal TUS client (1.0.0) for foreground uploads
// Supports: POST create, HEAD offset, PATCH chunked upload with resume.
final class TUSClient {
    struct CreateResponse { let uploadURL: URL }
    struct UploadResult {
        let finalOffset: Int64
        let patchRetries: Int
        let patchTimeouts: Int
        let stallRecoveries: Int
    }
    struct UploadFailure: LocalizedError {
        let underlying: Error
        let patchRetries: Int
        let patchTimeouts: Int
        let stallRecoveries: Int

        var errorDescription: String? { underlying.localizedDescription }
    }

    private let baseFilesURL: URL
    private let headersProvider: () -> [String: String]
    private let chunkSize: Int
    private let maxRetries: Int = 3
    private let timeoutRecoveryPollSeconds: TimeInterval = 8
    private let timeoutRecoveryGraceSeconds: TimeInterval = 210
    private let adaptiveChunkGrowthSuccessStreak: Int = 8

    init(baseURL: URL, headersProvider: @escaping () -> [String: String], chunkSize: Int = 8 * 1024 * 1024) {
        self.baseFilesURL = baseURL
        self.headersProvider = headersProvider
        self.chunkSize = chunkSize
    }

    // MARK: - Auth-aware send helpers (one-time refresh + retry on 401)

    private func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        var lastErr: Error?
        while attempt <= maxRetries {
            await AuthManager.shared.refreshIfNeeded()
            var attemptReq = req
            // Always apply latest Authorization header
            headersProvider().forEach { k, v in attemptReq.setValue(v, forHTTPHeaderField: k) }
            do {
                let (data, resp) = try await URLSession.shared.data(for: attemptReq)
                guard let http = resp as? HTTPURLResponse else { throw tusError("No response") }
                if http.statusCode == 401 {
                    // One immediate retry after a forced refresh
                    let refreshed = await AuthManager.shared.forceRefresh()
                    guard refreshed else { return (data, http) }
                    var retry = req
                    headersProvider().forEach { k, v in retry.setValue(v, forHTTPHeaderField: k) }
                    let (d2, r2) = try await URLSession.shared.data(for: retry)
                    guard let h2 = r2 as? HTTPURLResponse else { throw tusError("No response") }
                    return (d2, h2)
                }
                if http.statusCode >= 500 && attempt < maxRetries {
                    attempt += 1
                    try? await Task.sleep(nanoseconds: backoffNanos(attempt))
                    continue
                }
                return (data, http)
            } catch {
                lastErr = error
                if attempt < maxRetries {
                    attempt += 1
                    try? await Task.sleep(nanoseconds: backoffNanos(attempt))
                    continue
                }
                throw error
            }
        }
        throw lastErr ?? tusError("Unknown error")
    }

    private func sendUpload(_ req: URLRequest, body: Data, retryOnTimeout: Bool) async throws -> (Data, HTTPURLResponse, Int) {
        var attempt = 0
        var retriesPerformed = 0
        var lastErr: Error?
        while attempt <= maxRetries {
            await AuthManager.shared.refreshIfNeeded()
            var attemptReq = req
            headersProvider().forEach { k, v in attemptReq.setValue(v, forHTTPHeaderField: k) }
            do {
                let (data, resp) = try await URLSession.shared.upload(for: attemptReq, from: body)
                guard let http = resp as? HTTPURLResponse else { throw tusError("No response") }
                if http.statusCode == 401 {
                    let refreshed = await AuthManager.shared.forceRefresh()
                    guard refreshed else { return (data, http, retriesPerformed) }
                    var retry = req
                    headersProvider().forEach { k, v in retry.setValue(v, forHTTPHeaderField: k) }
                    let (d2, r2) = try await URLSession.shared.upload(for: retry, from: body)
                    guard let h2 = r2 as? HTTPURLResponse else { throw tusError("No response") }
                    return (d2, h2, retriesPerformed + 1)
                }
                if http.statusCode >= 500 && attempt < maxRetries {
                    attempt += 1
                    retriesPerformed += 1
                    try? await Task.sleep(nanoseconds: backoffNanos(attempt))
                    continue
                }
                return (data, http, retriesPerformed)
            } catch {
                if !retryOnTimeout && isTimeoutError(error) {
                    throw error
                }
                lastErr = error
                if attempt < maxRetries {
                    attempt += 1
                    retriesPerformed += 1
                    try? await Task.sleep(nanoseconds: backoffNanos(attempt))
                    continue
                }
                throw error
            }
        }
        throw lastErr ?? tusError("Unknown error")
    }

    private func backoffNanos(_ attempt: Int) -> UInt64 {
        // Base 1s exponential backoff with jitter up to 250ms
        let base = pow(2.0, Double(attempt - 1))
        let seconds = min(8.0, base) // cap at 8s
        let jitter = Double.random(in: 0...0.25)
        let total = seconds + jitter
        return UInt64(total * 1_000_000_000)
    }

    func create(fileSize: Int64, filename: String, mimeType: String, metadata: [String: String] = [:]) async throws -> CreateResponse {
        var req = URLRequest(url: baseFilesURL)
        req.httpMethod = "POST"
        // Required headers
        req.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
        req.setValue(String(fileSize), forHTTPHeaderField: "Upload-Length")
        // Metadata: filename (b64), filetype (b64), source=ios
        var meta = [
            "filename": Data(filename.utf8).base64EncodedString(),
            "filetype": Data(mimeType.utf8).base64EncodedString(),
            "source": Data("ios".utf8).base64EncodedString(),
        ]
        for (k, v) in metadata {
            meta[k] = Data(v.utf8).base64EncodedString()
        }
        let metaHeader = meta.map { "\($0.key) \($0.value)" }.joined(separator: ",")
        req.setValue(metaHeader, forHTTPHeaderField: "Upload-Metadata")
        headersProvider().forEach { k, v in req.setValue(v, forHTTPHeaderField: k) }

        AppLog.debug(AppLog.upload, "TUS CREATE filename=\(filename) size=\(fileSize) type=\(mimeType)")
        let (data, http) = try await send(req)
        guard let _ = Optional(http) else {
            throw tusError("No response from server")
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw tusError("Create failed (status: \(http.statusCode)) \(msg)")
        }
        guard let loc = http.value(forHTTPHeaderField: "Location"), let url = URL(string: loc, relativeTo: baseFilesURL) else {
            // Some servers return absolute Location; if relative, resolve against base
            // Try absolute fallback
            if let abs = http.value(forHTTPHeaderField: "Location"), let absURL = URL(string: abs) {
                AppLog.debug(AppLog.upload, "TUS CREATE location=\(absURL.absoluteString)")
                return CreateResponse(uploadURL: absURL)
            }
            throw tusError("Missing Location header")
        }
        // Resolve to absolute URL
        let absolute = url.absoluteURL
        AppLog.debug(AppLog.upload, "TUS CREATE location=\(absolute.absoluteString)")
        return CreateResponse(uploadURL: absolute)
    }

    func headOffset(uploadURL: URL) async throws -> Int64 {
        var req = URLRequest(url: uploadURL)
        req.httpMethod = "HEAD"
        req.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
        headersProvider().forEach { k, v in req.setValue(v, forHTTPHeaderField: k) }

        let (_, http) = try await send(req)
        guard (200..<300).contains(http.statusCode) else {
            throw tusError("HEAD failed (status: \(http.statusCode))")
        }
        let offStr = http.value(forHTTPHeaderField: "Upload-Offset") ?? "0"
        let off = Int64(offStr) ?? 0
        AppLog.debug(AppLog.upload, "TUS HEAD offset=\(off)")
        return off
    }

    @discardableResult
    func upload(
        fileURL: URL,
        uploadURL: URL,
        startOffset: Int64,
        fileSize: Int64,
        progress: @escaping (Int64, Int64) -> Void,
        isCancelled: @escaping () -> Bool,
        initialChunkSize: Int? = nil,
        minimumChunkSize: Int? = nil,
        maximumChunkSize: Int? = nil,
        patchTimeoutSeconds: TimeInterval = 30,
        maxStallRecoveries: Int = 1
    ) async throws -> UploadResult {
        let fh = try FileHandle(forReadingFrom: fileURL)
        defer { try? fh.close() }

        var offset = startOffset
        var patchIndex = 0
        var patchRetriesTotal = 0
        var patchTimeouts = 0
        var stallRecoveries = 0
        var currentChunkSize = max(1, initialChunkSize ?? chunkSize)
        let minimumChunkSize = max(1, min(minimumChunkSize ?? currentChunkSize, currentChunkSize))
        let maximumChunkSize = max(currentChunkSize, maximumChunkSize ?? currentChunkSize)
        var stablePatchStreak = 0
        try fh.seek(toOffset: UInt64(offset))

        while offset < fileSize {
            if isCancelled() { throw tusError("Cancelled") }
            let remaining = Int(fileSize - offset)
            let toRead = min(currentChunkSize, remaining)
            guard let chunk = try fh.read(upToCount: toRead), !chunk.isEmpty else { break }
            patchIndex += 1
            AppLog.debug(
                AppLog.upload,
                "TUS PATCH chunk=\(patchIndex) offset=\(offset) size=\(chunk.count) total=\(fileSize)"
            )

            var req = URLRequest(url: uploadURL)
            req.httpMethod = "PATCH"
            req.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
            req.setValue("application/offset+octet-stream", forHTTPHeaderField: "Content-Type")
            req.setValue(String(offset), forHTTPHeaderField: "Upload-Offset")
            req.setValue(String(chunk.count), forHTTPHeaderField: "Content-Length")
            req.timeoutInterval = patchTimeoutSeconds
            headersProvider().forEach { k, v in req.setValue(v, forHTTPHeaderField: k) }

            let data: Data
            let http: HTTPURLResponse
            let responseRetries: Int
            do {
                let response = try await sendUpload(req, body: chunk, retryOnTimeout: false)
                data = response.0
                http = response.1
                responseRetries = response.2
                patchRetriesTotal += response.2
            } catch {
                if isCancelled() { throw tusError("Cancelled") }
                if isTimeoutError(error) {
                    patchTimeouts += 1
                    AppLog.info(
                        AppLog.upload,
                        "[TUS] PATCH timeout offset=\(offset) chunk=\(patchIndex) checking server offset"
                    )
                    let serverOffset = try await recoverOffsetAfterTimeout(
                        uploadURL: uploadURL,
                        localOffset: offset,
                        chunkSize: chunk.count,
                        fileSize: fileSize,
                        isCancelled: isCancelled
                    )
                    if serverOffset != offset {
                        AppLog.info(
                            AppLog.upload,
                            "[TUS] Delayed PATCH recovered local=\(offset) -> server=\(serverOffset)"
                        )
                        stablePatchStreak = 0
                        offset = serverOffset
                        progress(offset, fileSize)
                        try fh.seek(toOffset: UInt64(offset))
                        continue
                    }
                    if stallRecoveries < maxStallRecoveries {
                        let nextChunkSize = max(minimumChunkSize, currentChunkSize / 2)
                        if nextChunkSize < currentChunkSize {
                            currentChunkSize = nextChunkSize
                            AppLog.info(
                                AppLog.upload,
                                "[TUS] PATCH timeout offset=\(offset) reducing_chunk_size=\(currentChunkSize)"
                            )
                        }
                        stallRecoveries += 1
                        stablePatchStreak = 0
                        AppLog.info(
                            AppLog.upload,
                            "[TUS] PATCH timeout offset=\(offset) chunk=\(patchIndex) retrying_after_grace=1 attempt=\(stallRecoveries)"
                        )
                        try fh.seek(toOffset: UInt64(offset))
                        continue
                    }
                    AppLog.info(
                        AppLog.upload,
                        "[TUS] PATCH timeout offset=\(offset) chunk=\(patchIndex) recovery_exhausted=1"
                    )
                }
                throw UploadFailure(
                    underlying: error,
                    patchRetries: patchRetriesTotal,
                    patchTimeouts: patchTimeouts,
                    stallRecoveries: stallRecoveries
                )
            }
            if http.statusCode == 409 || http.statusCode == 412 {
                // Offset mismatch; reconcile
                let serverOffset: Int64
                do {
                    serverOffset = try await headOffset(uploadURL: uploadURL)
                } catch {
                    if isMissingUploadAfterFinalChunk(error, offset: offset, chunkSize: chunk.count, fileSize: fileSize) {
                        offset = fileSize
                        AppLog.info(
                            AppLog.upload,
                            "[TUS] HEAD 404 after final chunk conflict; assuming complete size=\(fileSize)"
                        )
                        progress(offset, fileSize)
                        break
                    }
                    throw error
                }
                if serverOffset != offset {
                    AppLog.debug(AppLog.upload, "TUS OFFSET CONFLICT local=\(offset) -> server=\(serverOffset)")
                } else {
                    AppLog.debug(AppLog.upload, "TUS OFFSET CONFLICT retrying same offset=\(offset)")
                }
                stablePatchStreak = 0
                offset = serverOffset
                // Always rewind before retrying this chunk.
                try fh.seek(toOffset: UInt64(offset))
                continue
            }
            guard (200..<300).contains(http.statusCode) else {
                let msg = String(data: data, encoding: .utf8) ?? ""
                throw UploadFailure(
                    underlying: tusError("PATCH failed (status: \(http.statusCode)) \(msg)"),
                    patchRetries: patchRetriesTotal,
                    patchTimeouts: patchTimeouts,
                    stallRecoveries: stallRecoveries
                )
            }
            // Success; server returns new Upload-Offset
            let offStr = http.value(forHTTPHeaderField: "Upload-Offset") ?? String(offset + Int64(chunk.count))
            offset = Int64(offStr) ?? (offset + Int64(chunk.count))
            AppLog.debug(AppLog.upload, "TUS OFFSET -> \(offset)")
            progress(offset, fileSize)

            if responseHadRetry(responseRetries: responseRetries) {
                stablePatchStreak = 0
            } else {
                stablePatchStreak += 1
                if currentChunkSize < maximumChunkSize &&
                    stablePatchStreak >= adaptiveChunkGrowthSuccessStreak &&
                    offset < fileSize {
                    let nextChunkSize = min(maximumChunkSize, currentChunkSize * 2)
                    if nextChunkSize > currentChunkSize {
                        currentChunkSize = nextChunkSize
                        stablePatchStreak = 0
                        AppLog.info(
                            AppLog.upload,
                            "[TUS] Stable tunnel offset=\(offset) increasing_chunk_size=\(currentChunkSize)"
                        )
                    }
                }
            }
        }
        if offset < fileSize {
            throw UploadFailure(
                underlying: tusError("Upload incomplete (offset=\(offset), size=\(fileSize))"),
                patchRetries: patchRetriesTotal,
                patchTimeouts: patchTimeouts,
                stallRecoveries: stallRecoveries
            )
        }
        AppLog.debug(AppLog.upload, "TUS COMPLETE size=\(fileSize)")
        return UploadResult(
            finalOffset: offset,
            patchRetries: patchRetriesTotal,
            patchTimeouts: patchTimeouts,
            stallRecoveries: stallRecoveries
        )
    }

    private func isTimeoutError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return urlError.code == .timedOut
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isTimeoutError(underlying)
        }
        return false
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

    private func responseHadRetry(responseRetries: Int) -> Bool {
        responseRetries > 0
    }

    private func tusStatusCode(from error: Error) -> Int? {
        let description = error.localizedDescription
        guard let marker = description.range(of: "status: ") else { return nil }
        let suffix = description[marker.upperBound...]
        let digits = suffix.prefix { $0.isNumber }
        return Int(digits)
    }

    private func shouldKeepPollingAfterTimeout(_ error: Error) -> Bool {
        if isRetryableNetworkError(error) { return true }
        guard let status = tusStatusCode(from: error) else { return false }
        switch status {
        case 408, 425, 429, 500...599:
            return true
        default:
            return false
        }
    }

    private func recoverOffsetAfterTimeout(
        uploadURL: URL,
        localOffset: Int64,
        chunkSize: Int,
        fileSize: Int64,
        isCancelled: @escaping () -> Bool
    ) async throws -> Int64 {
        let deadline = Date().addingTimeInterval(timeoutRecoveryGraceSeconds)
        var announcedGraceWait = false

        while true {
            if isCancelled() { throw tusError("Cancelled") }

            do {
                let serverOffset = try await headOffset(uploadURL: uploadURL)
                if serverOffset != localOffset {
                    return serverOffset
                }
            } catch {
                if isMissingUploadAfterFinalChunk(error, offset: localOffset, chunkSize: chunkSize, fileSize: fileSize) {
                    AppLog.info(
                        AppLog.upload,
                        "[TUS] HEAD 404 after final chunk timeout; assuming complete size=\(fileSize)"
                    )
                    return fileSize
                }
                if !shouldKeepPollingAfterTimeout(error) {
                    throw error
                }
            }

            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                return localOffset
            }
            if !announcedGraceWait {
                AppLog.info(
                    AppLog.upload,
                    "[TUS] Waiting for delayed tunnel PATCH offset=\(localOffset) grace_s=\(Int(timeoutRecoveryGraceSeconds.rounded())) poll_s=\(Int(timeoutRecoveryPollSeconds.rounded()))"
                )
                announcedGraceWait = true
            }
            let sleepSeconds = min(timeoutRecoveryPollSeconds, max(1, remaining))
            try? await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
        }
    }

    private func isMissingUploadAfterFinalChunk(_ error: Error, offset: Int64, chunkSize: Int, fileSize: Int64) -> Bool {
        guard offset + Int64(chunkSize) >= fileSize else { return false }
        let description = error.localizedDescription
        return description.contains("HEAD failed (status: 404)")
    }

    private func tusError(_ message: String) -> NSError {
        NSError(domain: "TUS", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
