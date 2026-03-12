//
//  SharePhotoTile.swift
//  OpenPhotos
//
//  Individual photo tile for share grid.
//

import SwiftUI

/// Individual photo tile in share grid
struct SharePhotoTile: View {
    let share: Share
    let assetId: String
    let isSelected: Bool
    let showCheckbox: Bool
    let likeCount: ShareLikeCount?
    let canLike: Bool
    let latestComment: ShareComment?
    let canComment: Bool
    let onLikeTap: () -> Void
    let onCommentTap: () -> Void
    let size: CGFloat
    let showControls: Bool
    let metadata: ShareAssetMetadata?

    @State private var thumbnail: UIImage?
    @State private var isLoading = true

    var body: some View {
        ZStack {
            // Thumbnail
            if let thumbnail = thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .clipped()
            } else if isLoading {
                Color.gray.opacity(0.3)
                ProgressView()
            } else {
                Color.gray.opacity(0.3)
                Image(systemName: "photo")
                    .foregroundColor(.gray)
            }

            // Video indicator
            if metadata?.isVideo == true {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.5), radius: 4)
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .overlay(alignment: .bottomTrailing) {
            Group {
                if showControls && showCheckbox {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(isSelected ? .blue : .white)
                        .font(.title2)
                        .padding(8)
                        .background(Color.black.opacity(0.3))
                        .clipShape(Circle())
                        .padding(4)
                } else if showControls {
                    HStack(spacing: 12) {
                        if canComment {
                            Button(action: onCommentTap) {
                                Image(systemName: latestComment != nil ? "bubble.left.fill" : "bubble.left")
                                    .foregroundColor(.white)
                                    .font(.system(size: 20))
                                    .shadow(color: .black.opacity(0.5), radius: 2)
                            }
                            .buttonStyle(.plain)
                            .padding(4)
                            .contentShape(Rectangle())
                        }

                        if canLike {
                            Button(action: onLikeTap) {
                                HStack(spacing: 4) {
                                    Image(systemName: (likeCount?.likedByMe ?? false) ? "heart.fill" : "heart")
                                        .foregroundColor((likeCount?.likedByMe ?? false) ? .red : .white)
                                        .font(.system(size: 20))
                                        .shadow(color: .black.opacity(0.5), radius: 2)

                                    if let count = likeCount?.count, count > 0 {
                                        Text("\(count)")
                                            .foregroundColor(.white)
                                            .font(.caption)
                                            .shadow(color: .black.opacity(0.5), radius: 2)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .padding(4)
                            .contentShape(Rectangle())
                        }
                    }
                }
            }
            .padding(.bottom, 8)
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 4)
        )
        .task {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let data = try await ShareService.shared.getShareAssetThumbnail(
                shareId: share.id,
                assetId: assetId
            )
            thumbnail = UIImage(data: data)
        } catch {
            print("Failed to load thumbnail for asset \(assetId): \(error)")
        }
    }
}

#Preview {
    SharePhotoTile(
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
        assetId: "asset1",
        isSelected: true,
        showCheckbox: true,
        likeCount: ShareLikeCount(assetId: "asset1", count: 5, likedByMe: true),
        canLike: true,
        latestComment: nil,
        canComment: true,
        onLikeTap: {},
        onCommentTap: {},
        size: 100,
        showControls: true,
        metadata: ShareAssetMetadata(
            assetId: "asset1",
            filename: "video.mp4",
            mimeType: "video/mp4",
            width: 1920,
            height: 1080,
            createdAt: Int64(Date().timeIntervalSince1970),
            favorites: 0,
            isVideo: true,
            isLivePhoto: false
        )
    )
}
