//
//  ShareVideoPlayer.swift
//  OpenPhotos
//
//  Full-screen video player for shared videos with auto-play.
//

import SwiftUI
import AVKit

/// Full-screen video player for shared videos
struct ShareVideoPlayer: View {
    let share: Share
    let assetId: String

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isLoading {
                ProgressView("Loading video...")
                    .foregroundColor(.white)
            } else if let error = error {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48))
                        .foregroundColor(.red)

                    Text("Error Loading Video")
                        .font(.headline)
                        .foregroundColor(.white)

                    Text(error)
                        .font(.subheadline)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    Button("Close") {
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if let player = player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.5), radius: 4)
            }
            .padding()
        }
        .task {
            await loadVideo()
        }
        .onDisappear {
            player?.pause()
        }
    }

    private func loadVideo() async {
        isLoading = true
        defer { isLoading = false }

        do {
            // Fetch video data from server
            let data = try await ShareService.shared.getShareAssetImage(
                shareId: share.id,
                assetId: assetId
            )

            // Save to temporary file
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mp4")

            try data.write(to: tempURL)

            // Create player
            let newPlayer = AVPlayer(url: tempURL)
            self.player = newPlayer

            // Auto-play
            newPlayer.play()

            // Loop video
            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: newPlayer.currentItem,
                queue: .main
            ) { _ in
                newPlayer.seek(to: .zero)
                newPlayer.play()
            }
        } catch {
            self.error = error.localizedDescription
            print("Failed to load video: \(error)")
        }
    }
}

#Preview {
    ShareVideoPlayer(
        share: Share(
            id: "1",
            ownerOrgId: 1,
            ownerUserId: "user123",
            objectKind: .album,
            objectId: "42",
            defaultPermissions: SharePermissions.viewer.rawValue,
            expiresAt: nil,
            status: .active,
            createdAt: Date(),
            updatedAt: Date(),
            name: "Test Share",
            includeFaces: true,
            includeSubtree: false,
            recipients: []
        ),
        assetId: "video1"
    )
}
