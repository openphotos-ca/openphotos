import SwiftUI

/// Full-screen Similar Media experience, mirroring the web client's Similar Photos/Videos overlay.
struct SimilarMediaView: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject var viewModel: SimilarMediaViewModel

    private struct SelectedAsset: Identifiable {
        let id: String
    }

    // Local viewer state so Similar Media can open a simple full-screen asset view.
    @State private var selectedAsset: SelectedAsset?

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 24) {
                        if let msg = viewModel.errorMessage {
                            Text(msg)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .padding(.top, 8)
                        }
                        SimilarPhotoGroupsSection(viewModel: viewModel, onOpenAssets: openViewerFromGroup)
                        SimilarVideoGroupsSection(viewModel: viewModel, onOpenAssets: openViewerFromGroup)
                    }
                    .padding(.bottom, 24)
                }
            }
        }
        .onAppear {
            viewModel.loadInitial()
        }
        .fullScreenCover(item: $selectedAsset) { asset in
            SimilarMediaFullScreenAssetView(assetId: asset.id)
        }
    }

    private var header: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle()
                            .strokeBorder(Color(.separator))
                    )
            }
            .padding(.leading, 12)

            Spacer()

            Text("Similar Photos/Videos")
                .font(.headline)
                .padding(.vertical, 12)

            Spacer()

            // Spacer to balance back button
            Color.clear
                .frame(width: 32, height: 32)
                .padding(.trailing, 12)
        }
        .background(Color(.systemBackground).opacity(0.98))
        .overlay(
            Divider()
                .offset(y: 0.5),
            alignment: .bottom
        )
    }

    /// Build a viewer sequence for a similar group and present the full-screen viewer.
    private func openViewerFromGroup(assetId: String, group: [String], index: Int) {
        selectedAsset = SelectedAsset(id: assetId)
    }
}

// MARK: - Photo Groups Section

private struct SimilarPhotoGroupsSection: View {
    @ObservedObject var viewModel: SimilarMediaViewModel
    let onOpenAssets: (_ assetId: String, _ group: [String], _ index: Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Similar Photo Groups")
                        .font(.headline)
                    Text("\(viewModel.photoGroups.count) groups loaded")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button {
                    Task { await viewModel.loadMorePhotos() }
                } label: {
                    Text(viewModel.photoDone ? "All loaded" : (viewModel.isLoadingPhotos ? "Loading…" : "Load more"))
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.photoDone || viewModel.isLoadingPhotos)
            }
            if viewModel.photoGroups.isEmpty && !viewModel.isLoadingPhotos {
                Text("No similar photo groups found. Try indexing more photos.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
            }
            VStack(spacing: 16) {
                ForEach(Array(viewModel.photoGroups.enumerated()), id: \.1.id) { index, group in
                    SimilarPhotoGroupCard(
                        group: group,
                        index: index,
                        viewModel: viewModel,
                        onOpenAssets: onOpenAssets
                    )
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }
}

// MARK: - Video Groups Section

private struct SimilarVideoGroupsSection: View {
    @ObservedObject var viewModel: SimilarMediaViewModel
    let onOpenAssets: (_ assetId: String, _ group: [String], _ index: Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Similar Video Groups")
                        .font(.headline)
                    Text("\(viewModel.videoGroups.count) groups loaded")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button {
                    Task { await viewModel.loadMoreVideos() }
                } label: {
                    Text(viewModel.videoDone ? "All loaded" : (viewModel.isLoadingVideos ? "Loading…" : "Load more"))
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.videoDone || viewModel.isLoadingVideos)
            }
            if viewModel.videoGroups.isEmpty && !viewModel.isLoadingVideos {
                Text("No similar video groups found.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
            }
            VStack(spacing: 16) {
                ForEach(Array(viewModel.videoGroups.enumerated()), id: \.1.id) { index, group in
                    SimilarVideoGroupCard(
                        group: group,
                        index: index,
                        viewModel: viewModel,
                        onOpenAssets: onOpenAssets
                    )
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}

// MARK: - Photo Group Card

private struct SimilarPhotoGroupCard: View {
    let group: SimilarMediaViewModel.PhotoGroupState
    let index: Int
    @ObservedObject var viewModel: SimilarMediaViewModel
    let onOpenAssets: (_ assetId: String, _ group: [String], _ index: Int) -> Void

    @State private var showAlbumPicker: Bool = false
    @State private var albumPickerSelectedId: Int?
    @State private var albumPickerAlbums: [ServerAlbum] = []

    // Fixed square tiles in a 3-column grid.
    private let tileSize: CGFloat = 110
    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.fixed(tileSize), spacing: 8), count: 3)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 8) {
                ForEach(group.visibleItems, id: \.self) { assetId in
                    SimilarAssetTile(
                        assetId: assetId,
                        isSelected: group.selected.contains(assetId),
                        size: tileSize,
                        onTap: {
                            if group.selected.isEmpty {
                                let items = group.visibleItems
                                if let idx = items.firstIndex(of: assetId) {
                                    onOpenAssets(assetId, items, idx)
                                }
                            } else {
                                viewModel.toggleSelectPhoto(groupIndex: index, assetId: assetId)
                            }
                        },
                        onToggleSelect: {
                            viewModel.toggleSelectPhoto(groupIndex: index, assetId: assetId)
                        }
                    )
                }
            }
            .padding(8)
        }
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(.separator))
        )
        .sheet(isPresented: $showAlbumPicker) {
            ServerAlbumPickerSheet(
                isPresented: $showAlbumPicker,
                albums: albumPickerAlbums,
                onChoose: { albumId in
                    albumPickerSelectedId = albumId
                    Task {
                        let name = albumPickerAlbums.first(where: { $0.id == albumId })?.name
                        await viewModel.applyAlbumFilterToPhotoGroup(groupIndex: index, albumId: albumId, albumName: name)
                    }
                }
            )
        }
        .task {
            // Load albums once when this card becomes visible.
            if albumPickerAlbums.isEmpty {
                do {
                    albumPickerAlbums = try await ServerPhotosService.shared.listAlbums()
                } catch { }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            HStack {
                HStack(spacing: 6) {
                    Text("Similar group")
                        .font(.subheadline)
                        .foregroundColor(.primary)
                    Text("\(group.visibleCount) / \(group.group.count)")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.blue.opacity(0.1))
                        )
                        .overlay(
                            Capsule()
                                .stroke(Color.blue.opacity(0.4))
                        )
                }
                Spacer()
                HStack(spacing: 8) {
                    if !group.selected.isEmpty {
                        Text("Selected (\(group.selected.count))")
                            .font(.caption2)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(Color.blue.opacity(0.12))
                            )
                    }
                    Menu {
                        Section {
                            Button("Select All") {
                                viewModel.toggleSelectAllPhotos(groupIndex: index)
                            }
                            if !group.selected.isEmpty {
                                Button("Clear Selection") {
                                    viewModel.clearSelectionForPhotoGroup(groupIndex: index)
                                }
                            }
                            Button("Select Inferior") {
                                viewModel.selectInferiorPhotos(groupIndex: index)
                            }
                        }
                        Section {
                            Button(role: .destructive) {
                                Task {
                                    await viewModel.deleteSelectedPhotos(groupIndex: index)
                                }
                            } label: {
                                Text("Delete Selected")
                            }
                            .disabled(group.selected.isEmpty)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "ellipsis.circle")
                            Text("Actions")
                        }
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(.systemBackground))
                        )
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)

            HStack(spacing: 8) {
                Menu {
                    Button("Date (Newest First)") {
                        viewModel.setPhotoSort(groupIndex: index, kind: .date)
                    }
                    Button("File Size (Largest First)") {
                        viewModel.setPhotoSort(groupIndex: index, kind: .size)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("Sort")
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(.systemBackground))
                    )
                }

                Button {
                    showAlbumPicker = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "tree")
                        Text("Album")
                    }
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(.systemBackground))
                    )
                }

                if let name = group.albumName, group.albumId != nil {
                    HStack(spacing: 4) {
                        Image(systemName: "tree")
                            .font(.caption2)
                        Text(name)
                            .font(.caption2)
                            .lineLimit(1)
                        Button {
                            viewModel.clearAlbumFilterForPhotoGroup(groupIndex: index)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2.weight(.bold))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color(.systemBackground))
                    )
                }

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
        }
        .background(Color(.systemBackground))
    }
}

// MARK: - Video Group Card

private struct SimilarVideoGroupCard: View {
    let group: SimilarMediaViewModel.VideoGroupState
    let index: Int
    @ObservedObject var viewModel: SimilarMediaViewModel
    let onOpenAssets: (_ assetId: String, _ group: [String], _ index: Int) -> Void

    // Fixed square tiles in a 3-column grid similar to photos.
    private let tileSize: CGFloat = 110
    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.fixed(tileSize), spacing: 8), count: 3)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 8) {
                ForEach(group.visibleItems, id: \.self) { assetId in
                    SimilarAssetTile(
                        assetId: assetId,
                        isSelected: group.selected.contains(assetId),
                        size: tileSize,
                        onTap: {
                            if group.selected.isEmpty {
                                let items = group.visibleItems
                                if let idx = items.firstIndex(of: assetId) {
                                    onOpenAssets(assetId, items, idx)
                                }
                            } else {
                                viewModel.toggleSelectVideo(groupIndex: index, assetId: assetId)
                            }
                        },
                        onToggleSelect: {
                            viewModel.toggleSelectVideo(groupIndex: index, assetId: assetId)
                        }
                    )
                }
            }
            .padding(8)
        }
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(.separator))
        )
    }

    private var header: some View {
        VStack(spacing: 4) {
            HStack {
                HStack(spacing: 6) {
                    Text("Similar video group")
                        .font(.subheadline)
                        .foregroundColor(.primary)
                    Text("\(group.visibleCount) / \(group.group.count)")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.blue.opacity(0.1))
                        )
                        .overlay(
                            Capsule()
                                .stroke(Color.blue.opacity(0.4))
                        )
                }
                Spacer()
                HStack(spacing: 8) {
                    if !group.selected.isEmpty {
                        Text("Selected (\(group.selected.count))")
                            .font(.caption2)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(Color.blue.opacity(0.12))
                            )
                    }
                    Menu {
                        Section {
                            Button("Select All") {
                                viewModel.toggleSelectAllVideos(groupIndex: index)
                            }
                            if !group.selected.isEmpty {
                                Button("Clear Selection") {
                                    viewModel.clearSelectionForVideoGroup(groupIndex: index)
                                }
                            }
                            Button("Select Inferior") {
                                Task {
                                    await viewModel.selectInferiorVideos(groupIndex: index)
                                }
                            }
                        }
                        Section {
                            Button(role: .destructive) {
                                Task {
                                    await viewModel.deleteSelectedVideos(groupIndex: index)
                                }
                            } label: {
                                Text("Delete Selected")
                            }
                            .disabled(group.selected.isEmpty)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "ellipsis.circle")
                            Text("Actions")
                        }
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(.systemBackground))
                        )
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .background(Color(.systemBackground))
    }
}

// MARK: - Tile

private struct SimilarAssetTile: View {
    let assetId: String
    let isSelected: Bool
    let size: CGFloat
    let onTap: () -> Void
    let onToggleSelect: () -> Void

    var body: some View {
        Button {
            onTap()
        } label: {
            ZStack(alignment: .topLeading) {
                AuthImage(url: SimilarMediaFullScreenAssetView.imageURL(for: assetId, thumbnail: true))
                    .frame(width: size, height: size)
                    .clipped()

                if isSelected {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 22, height: 22)
                        .overlay(
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                        )
                        .padding(6)
                        .onTapGesture {
                            onToggleSelect()
                        }
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Full-screen asset view

private struct SimilarMediaFullScreenAssetView: View {
    let assetId: String
    @Environment(\.dismiss) private var dismiss

    static func imageURL(for assetId: String, thumbnail: Bool) -> URL {
        let enc = assetId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? assetId
        let path = thumbnail ? "/api/thumbnails/\(enc)" : "/api/images/\(enc)"
        return AuthorizedHTTPClient.shared.buildURL(path: path)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            AuthImage(url: Self.imageURL(for: assetId, thumbnail: false))
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 32, height: 32)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Circle())
                    }
                    .padding(.leading, 16)
                    .padding(.top, 12)

                    Spacer()
                }
                Spacer()
            }
        }
    }
}
