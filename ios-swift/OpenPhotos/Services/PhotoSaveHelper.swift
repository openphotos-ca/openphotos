import Foundation
import Photos
import AVFoundation
import UIKit

/// PhotoSaveHelper downloads assets (image, video, live photo) from the server,
/// decrypts locked PAE3 containers when required, and saves into the user's Photos library.
///
/// - Images: saves original format (HEIC/JPEG/etc) without transcoding.
/// - Videos: saves as original movie.
/// - Live Photos: pairs the still and motion (.pairedVideo) in a single creation request.
///
/// All methods surface errors via thrown exceptions and do not show UI directly.
enum PhotoSaveHelper {
    enum SaveError: Error { case unauthorized, noUMK, invalidData, system(String) }

    private static func authHeaders() -> [String:String] {
        return AuthManager.shared.authHeader()
    }

    /// Ensure we have permission to add new items into the user's Photos library.
    ///
    /// Notes:
    /// - Saving does not require full read access; `.addOnly` is sufficient.
    /// - If the user has not decided yet, iOS will prompt here.
    private static func ensureAddAuthorization() async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited:
            return
        case .notDetermined:
            let next = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard next == .authorized || next == .limited else { throw SaveError.unauthorized }
            return
        default:
            throw SaveError.unauthorized
        }
    }

    /// Download a URL into a stable temp file on disk.
    ///
    /// Why we use a download task:
    /// - Videos can be hundreds of MB; `URLSession.data(for:)` loads into memory and can fail or be killed.
    /// - `URLSession.download(for:)` streams directly to a file, which is more reliable for large media.
    private static func downloadToTempFile(
        path: String,
        filename: String,
        accept: String? = nil,
        overrideUserAgent: String? = nil
    ) async throws -> URL {
        guard let url = URL(string: AuthManager.shared.serverURL + path) else { throw SaveError.invalidData }
        var req = URLRequest(url: url)
        authHeaders().forEach { k, v in req.setValue(v, forHTTPHeaderField: k) }
        if let accept = accept { req.setValue(accept, forHTTPHeaderField: "Accept") }
        if let overrideUserAgent { req.setValue(overrideUserAgent, forHTTPHeaderField: "User-Agent") }

        let (tmpURL, resp) = try await URLSession.shared.download(for: req)
        guard let http = resp as? HTTPURLResponse else { throw SaveError.invalidData }
        guard (200..<300).contains(http.statusCode) else { throw SaveError.system("HTTP \(http.statusCode)") }

        // Make sure the filename is a single safe path component.
        let safeName = (filename as NSString).lastPathComponent
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(safeName)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmpURL, to: dest)
        return dest
    }

    private static func downloadToTemp(path: String, filename: String, accept: String? = nil) async throws -> URL {
        guard let url = URL(string: AuthManager.shared.serverURL + path) else { throw SaveError.invalidData }
        var req = URLRequest(url: url)
        authHeaders().forEach { k, v in req.setValue(v, forHTTPHeaderField: k) }
        if let accept = accept { req.setValue(accept, forHTTPHeaderField: "Accept") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw SaveError.invalidData }
        guard (200..<300).contains(http.statusCode) else { throw SaveError.system("HTTP \(http.statusCode)") }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try data.write(to: tmp)
        return tmp
    }

    private static func decryptIfNeeded(_ src: URL, suggestedExt: String) throws -> URL {
        // If file starts with PAE3 magic, decrypt using E2EEManager's UMK
        let fh = try FileHandle(forReadingFrom: src)
        let magic = try fh.read(upToCount: 4) ?? Data()
        try? fh.close()
        if magic == Data("PAE3".utf8) {
            guard let umk = E2EEManager.shared.umk, let userId = AuthManager.shared.userId else {
                throw SaveError.noUMK
            }
            let outURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + suggestedExt)
            try pae3DecryptFile(umk: umk, userIdKey: Data(userId.utf8), input: src, output: outURL)
            return outURL
        }
        return src
    }

    static func saveImage(assetId: String, filename: String?) async throws {
        try await ensureAddAuthorization()
        let enc = assetId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? assetId
        // Download original image bytes (could be HEIC or JPEG). Decrypt if locked.
        let tmp = try await downloadToTemp(path: "/api/images/\(enc)", filename: (filename ?? assetId), accept: "image/heic, image/*;q=0.8")
        let ext = (filename as NSString?)?.pathExtension.lowercased() ?? "jpg"
        let plain = try decryptIfNeeded(tmp, suggestedExt: ext)
        try await PHPhotoLibrary.shared().performChanges {
            let opts = PHAssetResourceCreationOptions()
            opts.originalFilename = filename ?? (assetId + "." + ext)
            PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: plain, options: opts)
        }
    }

    static func saveVideo(assetId: String, filename: String?) async throws {
        try await ensureAddAuthorization()
        let enc = assetId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? assetId
        // The images endpoint serves videos as well; Range is supported but for saving we fetch fully.
        //
        // Important:
        // - Use `downloadToTempFile` to avoid loading huge videos into memory.
        // - If the original container is not iOS-friendly (e.g. AVI/MKV/WebM), ask the server for an MP4 proxy
        //   by using an AppleCoreMedia-like User-Agent (this reuses the server's existing proxy logic).
        let originalExt = (filename as NSString?)?.pathExtension.lowercased()
        let isIosFriendly = ["mov", "mp4", "m4v"].contains(originalExt ?? "")

        let baseName: String = {
            if let filename, !filename.isEmpty {
                return ((filename as NSString).lastPathComponent as NSString).deletingPathExtension
            }
            return assetId
        }()
        let outExt = isIosFriendly ? (originalExt?.isEmpty == false ? originalExt! : "mov") : "mp4"
        let tmpName = baseName + "." + outExt

        let tmp = try await downloadToTempFile(
            path: "/api/images/\(enc)",
            filename: tmpName,
            accept: nil,
            overrideUserAgent: isIosFriendly ? nil : "AppleCoreMedia/1.0"
        )
        let plain = try decryptIfNeeded(tmp, suggestedExt: outExt)
        try await PHPhotoLibrary.shared().performChanges {
            let opts = PHAssetResourceCreationOptions()
            opts.originalFilename = baseName + "." + outExt
            PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: plain, options: opts)
        }
    }

    static func saveLivePhoto(assetId: String, filename: String?) async throws {
        try await ensureAddAuthorization()
        // 1) Still image
        let enc = assetId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? assetId
        let stillTmp = try await downloadToTemp(path: "/api/images/\(enc)", filename: (filename ?? assetId) + ".heic", accept: "image/heic, image/*;q=0.8")
        let stillPlain = try decryptIfNeeded(stillTmp, suggestedExt: "heic")

        // 2) Motion video (.mov). Locked motion uses /api/live-locked
        // Try locked first when UMK is present; fall back to /api/live.
        var videoTmp: URL
        if E2EEManager.shared.umk != nil {
            // If locked, this route returns PAE3 container
            videoTmp = try await downloadToTemp(path: "/api/live-locked/\(enc)", filename: (filename ?? assetId) + ".pae3")
        } else {
            videoTmp = try await downloadToTemp(path: "/api/live/\(enc)", filename: (filename ?? assetId) + ".mov")
        }
        let videoPlain = try decryptIfNeeded(videoTmp, suggestedExt: "mov")

        // 3) Create paired LivePhoto asset
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCreationRequest.forAsset()
            let imgOpts = PHAssetResourceCreationOptions(); imgOpts.originalFilename = (filename ?? (assetId + ".heic"))
            let vidOpts = PHAssetResourceCreationOptions(); vidOpts.originalFilename = (filename ?? (assetId + ".mov"))
            req.addResource(with: .photo, fileURL: stillPlain, options: imgOpts)
            req.addResource(with: .pairedVideo, fileURL: videoPlain, options: vidOpts)
        }
    }
}
