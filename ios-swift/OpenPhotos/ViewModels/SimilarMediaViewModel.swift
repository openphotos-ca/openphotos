import Foundation
import SwiftUI

/// View model powering the Similar Media screen.
/// Mirrors the web client's SimilarGroups and SimilarVideoGroups behavior.
@MainActor
final class SimilarMediaViewModel: ObservableObject {
    struct PhotoGroupState: Identifiable {
        let id = UUID()
        let group: ServerSimilarGroup

        /// All members, with representative first if present in `members`.
        let baseItems: [String]

        /// Lazily loaded metadata from the server.
        var metadata: [String: ServerSimilarAssetMeta]

        /// Optional filtered subset when album filtering is active.
        var filteredItems: [String]?

        /// Asset ids that have been deleted or removed from this view.
        var removedIds: Set<String> = []

        /// Currently selected asset ids inside this group.
        var selected: Set<String> = []

        /// Optional album filter id and name.
        var albumId: Int?
        var albumName: String?

        enum SortKind {
            case date
            case size
        }

        var sortKind: SortKind = .date

        /// Sorted and filtered asset ids to render for this group.
        var visibleItems: [String] {
            let source = (filteredItems ?? baseItems).filter { !removedIds.contains($0) }
            guard !source.isEmpty else { return [] }
            switch sortKind {
            case .date:
                return source.sorted { lhs, rhs in
                    let lt = metadata[lhs]?.created_at ?? 0
                    let rt = metadata[rhs]?.created_at ?? 0
                    return lt > rt
                }
            case .size:
                return source.sorted { lhs, rhs in
                    let ls = metadata[lhs]?.size ?? 0
                    let rs = metadata[rhs]?.size ?? 0
                    return ls > rs
                }
            }
        }

        var visibleCount: Int { visibleItems.count }
    }

    struct VideoGroupState: Identifiable {
        let id = UUID()
        let group: ServerSimilarGroup
        let baseItems: [String]
        var removedIds: Set<String> = []
        var selected: Set<String> = []

        /// Lazily fetched sizes for items in this group.
        var sizes: [String: Int64] = [:]

        var visibleItems: [String] {
            baseItems.filter { !removedIds.contains($0) }
        }

        var visibleCount: Int { visibleItems.count }
    }

    // MARK: - Published state

    @Published var photoGroups: [PhotoGroupState] = []
    @Published var videoGroups: [VideoGroupState] = []

    @Published var isLoadingPhotos: Bool = false
    @Published var isLoadingVideos: Bool = false

    @Published var photoDone: Bool = false
    @Published var videoDone: Bool = false

    @Published var errorMessage: String?

    // Cursor-based paging mirrors the web client.
    private var photoCursor: Int = 0
    private var videoCursor: Int = 0

    private let service = ServerPhotosService.shared

    // MARK: - Loading

    func loadInitial() {
        if isLoadingPhotos || isLoadingVideos { return }
        photoGroups = []
        videoGroups = []
        photoCursor = 0
        videoCursor = 0
        photoDone = false
        videoDone = false
        errorMessage = nil
        Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.loadMorePhotos() }
                group.addTask { await self.loadMoreVideos() }
            }
        }
    }

    func loadMorePhotos() async {
        guard !photoDone, !isLoadingPhotos else { return }
        isLoadingPhotos = true
        defer { isLoadingPhotos = false }
        do {
            let res = try await service.getSimilarPhotoGroups(threshold: 8, minGroupSize: 2, limit: 50, cursor: photoCursor)
            var nextGroups: [PhotoGroupState] = []
            for g in res.groups {
                let base: [String]
                if g.members.contains(g.representative) {
                    let rest = g.members.filter { $0 != g.representative }
                    base = [g.representative] + rest
                } else {
                    base = g.members
                }
                let meta = res.metadata ?? [:]
                let state = PhotoGroupState(group: g, baseItems: base, metadata: meta)
                nextGroups.append(state)
            }
            photoGroups += nextGroups
            if let next = res.next_cursor {
                photoCursor = next
            } else {
                photoDone = true
            }
        } catch {
            if photoGroups.isEmpty {
                errorMessage = error.localizedDescription
            }
            photoDone = true
        }
    }

    func loadMoreVideos() async {
        guard !videoDone, !isLoadingVideos else { return }
        isLoadingVideos = true
        defer { isLoadingVideos = false }
        do {
            let res = try await service.getSimilarVideoGroups(minGroupSize: 2, limit: 50, cursor: videoCursor)
            var nextGroups: [VideoGroupState] = []
            for g in res.groups {
                let base: [String]
                if g.members.contains(g.representative) {
                    let rest = g.members.filter { $0 != g.representative }
                    base = [g.representative] + rest
                } else {
                    base = g.members
                }
                let state = VideoGroupState(group: g, baseItems: base)
                nextGroups.append(state)
            }
            videoGroups += nextGroups
            if let next = res.next_cursor {
                videoCursor = next
            } else {
                videoDone = true
            }
        } catch {
            if videoGroups.isEmpty {
                errorMessage = error.localizedDescription
            }
            videoDone = true
        }
    }

    // MARK: - Photo group actions

    func toggleSelectAllPhotos(groupIndex: Int) {
        guard photoGroups.indices.contains(groupIndex) else { return }
        var g = photoGroups[groupIndex]
        if g.selected.isEmpty {
            g.selected = Set(g.visibleItems)
        } else {
            g.selected.removeAll()
        }
        photoGroups[groupIndex] = g
    }

    func toggleSelectPhoto(groupIndex: Int, assetId: String) {
        guard photoGroups.indices.contains(groupIndex) else { return }
        var g = photoGroups[groupIndex]
        if g.selected.contains(assetId) {
            g.selected.remove(assetId)
        } else {
            g.selected.insert(assetId)
        }
        photoGroups[groupIndex] = g
    }

    func clearSelectionForPhotoGroup(groupIndex: Int) {
        guard photoGroups.indices.contains(groupIndex) else { return }
        var g = photoGroups[groupIndex]
        g.selected.removeAll()
        photoGroups[groupIndex] = g
    }

    func setPhotoSort(groupIndex: Int, kind: PhotoGroupState.SortKind) {
        guard photoGroups.indices.contains(groupIndex) else { return }
        var g = photoGroups[groupIndex]
        g.sortKind = kind
        photoGroups[groupIndex] = g
    }

    /// Select all items except the largest by file size.
    func selectInferiorPhotos(groupIndex: Int) {
        guard photoGroups.indices.contains(groupIndex) else { return }
        var g = photoGroups[groupIndex]
        let items = g.visibleItems
        guard !items.isEmpty else { return }
        var maxId = items[0]
        var maxSize = g.metadata[maxId]?.size ?? 0
        for id in items.dropFirst() {
            let size = g.metadata[id]?.size ?? 0
            if size > maxSize {
                maxSize = size
                maxId = id
            }
        }
        g.selected = Set(items.filter { $0 != maxId })
        photoGroups[groupIndex] = g
    }

    /// Delete selected assets in the given photo group.
    func deleteSelectedPhotos(groupIndex: Int) async {
        guard photoGroups.indices.contains(groupIndex) else { return }
        var g = photoGroups[groupIndex]
        let ids = Array(g.selected)
        guard !ids.isEmpty else { return }
        do {
            try await service.deletePhotos(assetIds: ids)
            var removed = g.removedIds
            ids.forEach { removed.insert($0) }
            g.removedIds = removed
            g.selected.removeAll()
            photoGroups[groupIndex] = g
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Filter a photo group by a specific album. Mirrors the web's "Album" filter.
    func applyAlbumFilterToPhotoGroup(groupIndex: Int, albumId: Int, albumName: String?) async {
        guard photoGroups.indices.contains(groupIndex) else { return }
        var g = photoGroups[groupIndex]
        let targetIds = Set(g.baseItems)
        var found = Set<String>()
        var page = 1
        let perPage = 250
        var hasMore = true
        while hasMore && found.count < targetIds.count {
            var q = ServerPhotoListQuery()
            q.page = page
            q.limit = perPage
            q.album_id = albumId
            do {
                let res = try await service.listPhotos(query: q)
                for p in res.photos {
                    if targetIds.contains(p.asset_id) {
                        found.insert(p.asset_id)
                    }
                }
                hasMore = res.has_more
                page += 1
            } catch {
                hasMore = false
                errorMessage = error.localizedDescription
            }
        }
        if !found.isEmpty {
            g.filteredItems = g.baseItems.filter { found.contains($0) }
            g.albumId = albumId
            g.albumName = albumName
        } else {
            g.filteredItems = []
            g.albumId = albumId
            g.albumName = albumName
        }
        g.selected.removeAll()
        photoGroups[groupIndex] = g
    }

    func clearAlbumFilterForPhotoGroup(groupIndex: Int) {
        guard photoGroups.indices.contains(groupIndex) else { return }
        var g = photoGroups[groupIndex]
        g.filteredItems = nil
        g.albumId = nil
        g.albumName = nil
        g.selected.removeAll()
        photoGroups[groupIndex] = g
    }

    // MARK: - Video group actions

    func toggleSelectAllVideos(groupIndex: Int) {
        guard videoGroups.indices.contains(groupIndex) else { return }
        var g = videoGroups[groupIndex]
        if g.selected.isEmpty {
            g.selected = Set(g.visibleItems)
        } else {
            g.selected.removeAll()
        }
        videoGroups[groupIndex] = g
    }

    func toggleSelectVideo(groupIndex: Int, assetId: String) {
        guard videoGroups.indices.contains(groupIndex) else { return }
        var g = videoGroups[groupIndex]
        if g.selected.contains(assetId) {
            g.selected.remove(assetId)
        } else {
            g.selected.insert(assetId)
        }
        videoGroups[groupIndex] = g
    }

    func clearSelectionForVideoGroup(groupIndex: Int) {
        guard videoGroups.indices.contains(groupIndex) else { return }
        var g = videoGroups[groupIndex]
        g.selected.removeAll()
        videoGroups[groupIndex] = g
    }

    /// Select all but the largest by size inside a video group. Sizes are fetched on demand.
    func selectInferiorVideos(groupIndex: Int) async {
        guard videoGroups.indices.contains(groupIndex) else { return }
        var g = videoGroups[groupIndex]
        let items = g.visibleItems
        guard !items.isEmpty else { return }
        var sizes = g.sizes
        let missing = items.filter { sizes[$0] == nil }
        if !missing.isEmpty {
            do {
                let photos = try await service.getPhotosByAssetIds(missing, includeLocked: true)
                for p in photos {
                    sizes[p.asset_id] = p.size ?? 0
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        g.sizes = sizes
        var maxId = items[0]
        var maxSize = sizes[maxId] ?? 0
        for id in items.dropFirst() {
            let sz = sizes[id] ?? 0
            if sz > maxSize {
                maxSize = sz
                maxId = id
            }
        }
        g.selected = Set(items.filter { $0 != maxId })
        videoGroups[groupIndex] = g
    }

    func deleteSelectedVideos(groupIndex: Int) async {
        guard videoGroups.indices.contains(groupIndex) else { return }
        var g = videoGroups[groupIndex]
        let ids = Array(g.selected)
        guard !ids.isEmpty else { return }
        do {
            try await service.deletePhotos(assetIds: ids)
            var removed = g.removedIds
            ids.forEach { removed.insert($0) }
            g.removedIds = removed
            g.selected.removeAll()
            videoGroups[groupIndex] = g
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

