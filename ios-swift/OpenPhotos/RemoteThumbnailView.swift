import SwiftUI
import UIKit
import AVFoundation

/// RemoteThumbnailView fetches and displays a server thumbnail for a given ServerPhoto.
/// - Handles WebP decode on supported iOS versions.
/// - Detects locked PAE3 containers and decrypts when UMK is available; otherwise renders nothing (hidden policy).
struct RemoteThumbnailView: View {
    let photo: ServerPhoto
    let cellSize: CGFloat

    @State private var image: UIImage? = nil
    @State private var isLoading: Bool = false
    @State private var loadTask: Task<Void, Never>? = nil
    // Prevent repeated network hits for permanently broken thumbnails (corrupt bytes, missing file, etc).
    @State private var didFail: Bool = false

    private static let cache = NSCache<NSString, UIImage>()

    var body: some View {
        ZStack {
            Color(.systemGray5)
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: cellSize, height: cellSize)
                    .clipped()
            } else if isLoading {
                ProgressView().scaleEffect(0.7)
            } else {
                // Blank placeholder on failure
                Color(.systemGray5)
            }
            if photo.is_video, let ms = photo.duration_ms, ms > 0, image != nil {
                // Duration badge
                Text(formatDuration(ms))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.8)))
                    .padding(5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .frame(width: cellSize, height: cellSize)
        .contentShape(Rectangle())
        .onAppear { loadIfNeeded() }
        .onChange(of: photo.asset_id) { _ in loadIfNeeded(true) }
        .onDisappear { loadTask?.cancel(); loadTask = nil }
    }

    private func loadIfNeeded(_ force: Bool = false) {
        if force {
            didFail = false
        } else if didFail {
            return
        }
        // First: in-memory cache
        if !force, let cached = Self.cache.object(forKey: photo.asset_id as NSString) { self.image = cached; return }
        // Second: disk cache (thumbs bucket)
        if let data = DiskImageCache.shared.readData(bucket: .thumbs, key: photo.asset_id), let ui = decodeImage(from: data) {
            Self.cache.setObject(ui, forKey: photo.asset_id as NSString)
            self.image = ui
            return
        }
        // Else: fetch
        loadTask?.cancel()
        loadTask = Task { await loadImage() }
    }

    private func loadImage() async {
        await MainActor.run { isLoading = true }
        defer { Task { await MainActor.run { isLoading = false } } }
        let encoded = photo.asset_id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? photo.asset_id
        let url = AuthorizedHTTPClient.shared.buildURL(path: "/api/thumbnails/" + encoded)
        var req = URLRequest(url: url)
        AuthManager.shared.authHeader().forEach { k, v in req.setValue(v, forHTTPHeaderField: k) }
        do {
            guard !Task.isCancelled else { return }
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return }
            let ctHeader = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            let lockedHint = http.value(forHTTPHeaderField: "x-locked-source")?.lowercased() ?? ""
            let isLockedContainer = ctHeader.contains("application/octet-stream")
            if isLockedContainer {
                // Debug
                print("[THUMB] locked resp asset=\(photo.asset_id) len=\(data.count) src=\(lockedHint)")
                // Locked PAE3; only show if UMK is present
                guard let umk = E2EEManager.shared.umk, umk.count == 32 else {
                    print("[THUMB] no UMK")
                    await MainActor.run { didFail = true }
                    return
                }
                guard let userId = AuthManager.shared.userId, !userId.isEmpty else {
                    print("[THUMB] no userId")
                    await MainActor.run { didFail = true }
                    return
                }
                // Write encrypted bytes to temp, decrypt to temp, persist DECRYPTED bytes in disk cache, then decode
                let encURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pae3")
                let outURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".thumb")
                guard !Task.isCancelled else { return }
                try data.write(to: encURL)
                do {
                    try pae3DecryptFile(umk: umk, userIdKey: Data(userId.utf8), input: encURL, output: outURL)
                    // Persist decrypted bytes on disk cache; thumbnails default to webp, but keep raw bytes.
                    if let plainData = try? Data(contentsOf: outURL) {
                        if DiskImageCache.shared.write(bucket: .thumbs, key: photo.asset_id, data: plainData, ext: "webp", protection: .complete) == nil {
                            print("[THUMB] ⚠️ Cache write failed for locked thumbnail asset=\(photo.asset_id)")
                        }
                        if let ui = decodeImage(from: plainData) {
                            Self.cache.setObject(ui, forKey: photo.asset_id as NSString)
                            await MainActor.run { self.image = ui }
                        } else if let poster = posterFromVideo(url: outURL) {
                            Self.cache.setObject(poster, forKey: photo.asset_id as NSString)
                            await MainActor.run { self.image = poster }
                        } else {
                            await MainActor.run { didFail = true }
                        }
                    }
                } catch {
                    print("[THUMB] decrypt failed asset=\(photo.asset_id) err=\(error.localizedDescription)")
                    await MainActor.run { didFail = true }
                }
                // Cleanup
                try? FileManager.default.removeItem(at: encURL)
                try? FileManager.default.removeItem(at: outURL)
                return
            } else {
                // WebP or other supported image content type
                guard !Task.isCancelled else { return }
                if let ui = decodeImage(from: data) {
                    // Persist to disk cache for future loads
                    if DiskImageCache.shared.write(bucket: .thumbs, key: photo.asset_id, data: data, ext: "webp") == nil {
                        print("[THUMB] ⚠️ Cache write failed for unlocked thumbnail asset=\(photo.asset_id)")
                    }
                    Self.cache.setObject(ui, forKey: photo.asset_id as NSString)
                    await MainActor.run { self.image = ui }
                } else {
                    await MainActor.run { didFail = true }
                }
            }
        } catch {
            print("[THUMB] load error asset=\(photo.asset_id) err=\(error.localizedDescription)")
            await MainActor.run { didFail = true }
        }
    }

    // Robust decoding for WebP or other formats via ImageIO fallback
    private func decodeImage(from data: Data) -> UIImage? {
        if let ui = UIImage(data: data) { return ui }
        // Try ImageIO as a fallback (helps with WebP if direct init fails)
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(src) > 0,
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return UIImage(cgImage: cg)
    }

    private func decodeImage(fromURL url: URL) -> UIImage? {
        if let data = try? Data(contentsOf: url), let ui = UIImage(data: data) { return ui }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0,
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return UIImage(cgImage: cg)
    }

    // Extract a still image from a video file
    private func posterFromVideo(url: URL) -> UIImage? {
        let asset = AVAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        let dur = CMTimeGetSeconds(asset.duration)
        let time = CMTime(seconds: max(0.1, dur / 2.0), preferredTimescale: 600)
        guard let cg = try? gen.copyCGImage(at: time, actualTime: nil) else { return nil }
        return UIImage(cgImage: cg)
    }

    private func formatDuration(_ ms: Int64) -> String {
        let totalSeconds = Int(ms / 1000)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
