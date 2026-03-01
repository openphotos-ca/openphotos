//
//  SharePhotoGrid.swift
//  OpenPhotos
//
//  Photo grid for displaying assets in a share.
//

import SwiftUI

/// Photo grid for share viewer
struct SharePhotoGrid: View {
    let share: Share
    @ObservedObject var viewModel: ShareViewerViewModel

    @State private var selectedAssetId: String?
    @State private var selectedVideoAssetId: String?
    @State private var commentAssetId: String?

    var body: some View {
        ScrollView {
            // GeometryReader to compute exact square cell size (3 columns)
            GeometryReader { proxy in
                let sidePadding: CGFloat = 16 // we add .padding(.horizontal, 8)
                let spacing: CGFloat = 1
                let available = proxy.size.width - sidePadding - (2 * spacing)
                let scale = UIScreen.main.scale
                let raw = available / 3
                let cellSide = floor(raw * scale) / scale

                let columns: [GridItem] = Array(repeating: GridItem(.fixed(cellSide), spacing: spacing), count: 3)

                LazyVGrid(columns: columns, spacing: spacing) {
                    ForEach(viewModel.assetIds, id: \.self) { id in
                        photoCell(assetId: id, cellSide: cellSide)
                    }

                    if viewModel.isLoadingAssets && !viewModel.assetIds.isEmpty {
                        ProgressView()
                            .frame(height: 80)
                            .padding(.vertical, 20)
                            .gridCellColumns(3)
                    }
                }
                .padding(.horizontal, 8)
                .frame(width: proxy.size.width, alignment: .leading)
            }
        }
        .refreshable {
            await viewModel.reload()
        }
        .fullScreenCover(item: Binding(
            get: { selectedAssetId.map { SelectedAsset(id: $0) } },
            set: { selectedAssetId = $0?.id }
        )) { selected in
            ShareFullScreenViewer(
                share: share,
                assetIds: viewModel.assetIds,
                startIndex: viewModel.assetIds.firstIndex(of: selected.id) ?? 0
            )
        }
        .sheet(item: Binding(
            get: { commentAssetId.map { SelectedAsset(id: $0) } },
            set: { commentAssetId = $0?.id }
        )) { selected in
            CommentThreadSheet(
                share: share,
                assetId: selected.id
            )
        }
        .fullScreenCover(item: Binding(
            get: { selectedVideoAssetId.map { SelectedAsset(id: $0) } },
            set: { selectedVideoAssetId = $0?.id }
        )) { selected in
            ShareVideoPlayer(
                share: share,
                assetId: selected.id
            )
        }
    }

    @ViewBuilder
    private func photoCell(assetId: String, cellSide: CGFloat) -> some View {
        SharePhotoTile(
            share: share,
            assetId: assetId,
            isSelected: viewModel.selectedAssetIds.contains(assetId),
            showCheckbox: viewModel.isSelectionMode,
            likeCount: viewModel.likeCounts[assetId],
            canLike: viewModel.hasPermission(SharePermissions.like.rawValue),
            latestComment: viewModel.latestComments[assetId] ?? nil,
            canComment: viewModel.hasPermission(SharePermissions.comment.rawValue),
            onLikeTap: {
                Task {
                    await viewModel.toggleLike(assetId: assetId)
                }
            },
            onCommentTap: {
                commentAssetId = assetId
            },
            size: cellSide,
            showControls: false,
            metadata: viewModel.assetMetadata[assetId]
        )
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 12) {
                if viewModel.hasPermission(SharePermissions.comment.rawValue) {
                    Image(systemName: (viewModel.latestComments[assetId] ?? nil) != nil ? "bubble.left.fill" : "bubble.left")
                        .foregroundColor(.white)
                        .font(.system(size: 20))
                        .shadow(color: .black.opacity(0.5), radius: 2)
                        .onTapGesture { commentAssetId = assetId }
                }

                if viewModel.hasPermission(SharePermissions.like.rawValue) {
                    HStack(spacing: 4) {
                        Image(systemName: (viewModel.likeCounts[assetId]?.likedByMe ?? false) ? "heart.fill" : "heart")
                            .foregroundColor((viewModel.likeCounts[assetId]?.likedByMe ?? false) ? .red : .white)
                            .font(.system(size: 20))
                            .shadow(color: .black.opacity(0.5), radius: 2)

                        if let count = viewModel.likeCounts[assetId]?.count, count > 0 {
                            Text("\(count)")
                                .foregroundColor(.white)
                                .font(.caption)
                                .shadow(color: .black.opacity(0.5), radius: 2)
                        }
                    }
                    .onTapGesture {
                        Task { await viewModel.toggleLike(assetId: assetId) }
                    }
                }
            }
            .padding(.bottom, 8)
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .onTapGesture {
            if viewModel.isSelectionMode {
                viewModel.toggleAssetSelection(assetId)
            } else {
                // Check if it's a video
                if viewModel.assetMetadata[assetId]?.isVideo == true {
                    selectedVideoAssetId = assetId
                } else {
                    selectedAssetId = assetId
                }
            }
        }
        .onAppear {
            let index = viewModel.assetIds.firstIndex(of: assetId) ?? 0
            if index == viewModel.assetIds.count - 10 {
                Task {
                    await viewModel.loadNextPageIfNeeded()
                }
            }
        }
    }

    // no-op helpers removed
}

// Helper struct for sheet binding
private struct SelectedAsset: Identifiable {
    let id: String
}

#Preview {
    SharePhotoGrid(
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
        viewModel: ShareViewerViewModel(share: Share(
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
        ))
    )
}
