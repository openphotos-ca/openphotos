import SwiftUI
import AVKit
import AVFoundation
import UIKit

/// RemotePhotoViewerView presents a full-screen viewer for an asset id.
struct RemotePhotoViewerView: View {
    let assetId: String
    let isVideo: Bool
    let isLocked: Bool
    let isLive: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var uiImage: UIImage? = nil
    @State private var player: AVPlayer? = nil
    @State private var loading: Bool = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player = player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    .onAppear { player.play() }
            } else if let img = uiImage {
                GeometryReader { geo in
                    Image(uiImage: img).resizable().scaledToFit().frame(width: geo.size.width, height: geo.size.height).background(Color.black)
                }
            } else if loading {
                ProgressView().tint(.white)
            } else {
                Text("Failed to load").foregroundColor(.white)
            }
        }
        .task { await load() }
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: { stopPlayback(); dismiss() }) {
                    Image(systemName: "xmark").foregroundColor(.white)
                }
            }
        }
        .onDisappear { stopPlayback() }
        .background(Color.black)
    }

    /// Ensures any active AVPlayer stops when the viewer is dismissed.
    /// Without this, audio can continue playing even after the UI is gone.
    private func stopPlayback() {
        player?.pause()
        // Release the current item to stop any in-flight streaming pipeline immediately.
        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    private func load() async {
        await MainActor.run { loading = true }
        defer { Task { await MainActor.run { loading = false } } }
        if isVideo || isLive {
            await loadVideo()
        } else {
            await loadImage()
        }
    }

    private func loadImage() async {
        let encId = assetId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? assetId
        let url = AuthorizedHTTPClient.shared.buildURL(path: "/api/images/" + encId)
        var req = URLRequest(url: url)
        AuthManager.shared.authHeader().forEach { k, v in req.setValue(v, forHTTPHeaderField: k) }
        // Ask server for original HEIC when available
        req.setValue("image/heic, image/*;q=0.8", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return }
            let ct = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            if ct == "application/octet-stream" {
                // Locked PAE3 — decrypt to temp
                guard let umk = E2EEManager.shared.umk, umk.count == 32, let userId = AuthManager.shared.userId else { return }
                let encURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pae3")
                let outURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try data.write(to: encURL)
                try pae3DecryptFile(umk: umk, userIdKey: Data(userId.utf8), input: encURL, output: outURL)
                let plain = try Data(contentsOf: outURL)
                if let ui = UIImage(data: plain) { await MainActor.run { self.uiImage = ui } }
                try? FileManager.default.removeItem(at: encURL)
                try? FileManager.default.removeItem(at: outURL)
            } else {
                if let ui = UIImage(data: data) { await MainActor.run { self.uiImage = ui } }
            }
        } catch {
            // no-op
        }
    }

    private func loadVideo() async {
        if isLocked && isLive {
            // Fetch locked live container, decrypt to temp movie, play locally
            let encId = assetId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? assetId
            let url = AuthorizedHTTPClient.shared.buildURL(path: "/api/live-locked/" + encId)
            guard let umk = E2EEManager.shared.umk, let userId = AuthManager.shared.userId else { return }
            var req = URLRequest(url: url)
            AuthManager.shared.authHeader().forEach { k, v in req.setValue(v, forHTTPHeaderField: k) }
            do {
                let (data, _) = try await URLSession.shared.data(for: req)
                let encURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pae3")
                let outURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
                try data.write(to: encURL)
                try pae3DecryptFile(umk: umk, userIdKey: Data(userId.utf8), input: encURL, output: outURL)
                let av = AVPlayer(url: outURL)
                await MainActor.run { self.player = av }
            } catch { }
            return
        }
        // Stream via AVURLAsset with auth headers (images endpoint supports Range for videos)
        let encId = assetId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? assetId
        let urlStr = isLive ? "/api/live/" + encId + "?compat=1" : "/api/images/" + encId
        let url = AuthorizedHTTPClient.shared.buildURL(path: urlStr)
        let headers = AuthManager.shared.authHeader()
        let options: [String: Any] = [
            "AVURLAssetHTTPHeaderFieldsKey": headers,
            AVURLAssetPreferPreciseDurationAndTimingKey: false
        ]
        let asset = AVURLAsset(url: url, options: options)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = isLive ? 0.15 : 2.0
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        let player = AVPlayer(playerItem: item)
        if isLive { player.automaticallyWaitsToMinimizeStalling = false }
        await MainActor.run { self.player = player }
    }
}

// Convenience presenter from grids
enum RemotePhotoViewer {
    static func present(assetId: String, isVideo: Bool, isLocked: Bool, isLive: Bool) {
        // Present via a topmost window scene by hosting a SwiftUI view in a full-screen UIHostingController.
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let window = scene.windows.first else { return }
        let host = UIHostingController(rootView: RemotePhotoViewerView(assetId: assetId, isVideo: isVideo, isLocked: isLocked, isLive: isLive))
        host.modalPresentationStyle = .fullScreen
        window.rootViewController?.present(host, animated: true)
    }
}
