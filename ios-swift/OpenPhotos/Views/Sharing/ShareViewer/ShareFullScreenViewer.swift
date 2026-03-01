//
//  ShareFullScreenViewer.swift
//  OpenPhotos
//
//  Full-screen photo/video viewer for shared assets.
//

import SwiftUI

/// Full-screen viewer for share assets
struct ShareFullScreenViewer: View {
    let share: Share
    let assetIds: [String]
    let startIndex: Int

    @State private var currentIndex: Int
    @State private var images: [String: UIImage] = [:]
    @State private var isLoadingCurrent = false
    @StateObject private var decryptor = SharePhotoDecryptor()
    @Environment(\.dismiss) private var dismiss

    init(share: Share, assetIds: [String], startIndex: Int) {
        self.share = share
        self.assetIds = assetIds
        self.startIndex = startIndex
        self._currentIndex = State(initialValue: startIndex)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if assetIds.isEmpty {
                Text("No photos")
                    .foregroundColor(.white)
            } else {
                TabView(selection: $currentIndex) {
                    ForEach(Array(assetIds.enumerated()), id: \.offset) { index, assetId in
                        GeometryReader { geo in
                            ZStack {
                                if let image = images[assetId] {
                                    Image(uiImage: image)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: geo.size.width, height: geo.size.height)
                                } else if isLoadingCurrent && index == currentIndex {
                                    ProgressView()
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                } else {
                                    Color.black
                                }
                            }
                        }
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .onChange(of: currentIndex) { _, newIndex in
                    Task {
                        await loadImage(at: newIndex)
                    }
                }
            }

            // Toolbar
            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.title3)
                            .foregroundColor(.white)
                            .padding()
                            .background(Circle().fill(Color.black.opacity(0.5)))
                    }

                    Spacer()

                    Text("\(currentIndex + 1) of \(assetIds.count)")
                        .foregroundColor(.white)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.black.opacity(0.5)))

                    Spacer()

                    // Placeholder for action menu
                    Color.clear
                        .frame(width: 44, height: 44)
                }
                .padding()

                Spacer()
            }
        }
        .statusBarHidden()
        .task {
            await loadImage(at: currentIndex)
        }
    }

    /// Load image for asset at index
    private func loadImage(at index: Int) async {
        guard index >= 0 && index < assetIds.count else { return }

        let assetId = assetIds[index]

        // Check if already loaded
        if images[assetId] != nil {
            return
        }

        isLoadingCurrent = true
        defer { isLoadingCurrent = false }

        do {
            var data = try await ShareService.shared.getShareAssetImage(
                shareId: share.id,
                assetId: assetId
            )

            // Check if encrypted and decrypt if needed
            if decryptor.isEncrypted(data) {
                do {
                    data = try await decryptor.decryptOriginal(
                        shareId: share.id,
                        assetId: assetId,
                        encryptedData: data
                    )
                } catch {
                    print("Failed to decrypt image for \(assetId): \(error)")
                    // Could show locked placeholder
                    return
                }
            }

            if let image = UIImage(data: data) {
                images[assetId] = image
            }
        } catch {
            print("Failed to load image for \(assetId): \(error)")
        }
    }
}

#Preview {
    ShareFullScreenViewer(
        share: Share(
            id: "1",
            ownerOrgId: 1,
            ownerUserId: "user123",
            objectKind: .album,
            objectId: "42",
            defaultPermissions: 1,
            expiresAt: nil,
            status: .active,
            createdAt: Date(),
            updatedAt: Date(),
            name: "Test Share",
            includeFaces: false,
            includeSubtree: false,
            recipients: []
        ),
        assetIds: ["asset1", "asset2", "asset3"],
        startIndex: 0
    )
}
