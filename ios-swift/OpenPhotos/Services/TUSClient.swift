import Foundation

// Minimal TUS client (1.0.0) for foreground uploads
// Supports: POST create, HEAD offset, PATCH chunked upload with resume.
final class TUSClient {
    struct CreateResponse { let uploadURL: URL }

    private let baseFilesURL: URL
    private let headersProvider: () -> [String: String]
    private let chunkSize: Int
    private let maxRetries: Int = 3

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

    private func sendUpload(_ req: URLRequest, body: Data) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
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
                    guard refreshed else { return (data, http) }
                    var retry = req
                    headersProvider().forEach { k, v in retry.setValue(v, forHTTPHeaderField: k) }
                    let (d2, r2) = try await URLSession.shared.upload(for: retry, from: body)
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

    func upload(fileURL: URL, uploadURL: URL, startOffset: Int64, fileSize: Int64, progress: @escaping (Int64, Int64) -> Void, isCancelled: @escaping () -> Bool) async throws {
        let fh = try FileHandle(forReadingFrom: fileURL)
        defer { try? fh.close() }

        var offset = startOffset
        var chunkIndex = max(0, Int(startOffset) / chunkSize)
        try fh.seek(toOffset: UInt64(offset))

        while offset < fileSize {
            if isCancelled() { throw tusError("Cancelled") }
            let remaining = Int(fileSize - offset)
            let toRead = min(chunkSize, remaining)
            guard let chunk = try fh.read(upToCount: toRead), !chunk.isEmpty else { break }
            chunkIndex += 1
            AppLog.debug(AppLog.upload, "TUS PATCH chunk=\(chunkIndex) offset=\(offset) size=\(chunk.count) total=\(fileSize)")

            var req = URLRequest(url: uploadURL)
            req.httpMethod = "PATCH"
            req.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
            req.setValue("application/offset+octet-stream", forHTTPHeaderField: "Content-Type")
            req.setValue(String(offset), forHTTPHeaderField: "Upload-Offset")
            req.setValue(String(chunk.count), forHTTPHeaderField: "Content-Length")
            headersProvider().forEach { k, v in req.setValue(v, forHTTPHeaderField: k) }

            let (data, http) = try await sendUpload(req, body: chunk)
            if http.statusCode == 409 || http.statusCode == 412 {
                // Offset mismatch; reconcile
                let serverOffset = try await headOffset(uploadURL: uploadURL)
                if serverOffset == offset { continue }
                AppLog.debug(AppLog.upload, "TUS OFFSET CONFLICT local=\(offset) -> server=\(serverOffset)")
                offset = serverOffset
                try fh.seek(toOffset: UInt64(offset))
                continue
            }
            guard (200..<300).contains(http.statusCode) else {
                let msg = String(data: data, encoding: .utf8) ?? ""
                throw tusError("PATCH failed (status: \(http.statusCode)) \(msg)")
            }
            // Success; server returns new Upload-Offset
            let offStr = http.value(forHTTPHeaderField: "Upload-Offset") ?? String(offset + Int64(chunk.count))
            offset = Int64(offStr) ?? (offset + Int64(chunk.count))
            AppLog.debug(AppLog.upload, "TUS OFFSET -> \(offset)")
            progress(offset, fileSize)
        }
        if offset >= fileSize { AppLog.debug(AppLog.upload, "TUS COMPLETE size=\(fileSize)") }
    }

    private func tusError(_ message: String) -> NSError {
        NSError(domain: "TUS", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
