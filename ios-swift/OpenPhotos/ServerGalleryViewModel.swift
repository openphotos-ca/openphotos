import Foundation
import Combine
import SwiftUI

/// ViewModel powering the server-backed Photos tab.
@MainActor
final class ServerGalleryViewModel: ObservableObject {
    // Data
    @Published var photos: [ServerPhoto] = []
    @Published var albums: [ServerAlbum] = []
    @Published var mediaCounts: ServerMediaCounts? = nil
    @Published var yearBuckets: [ServerYearBucket] = []
    @Published var selectedAlbumNameOverrides: [Int: String] = [:]

    // UI/State
    enum MediaType { case all, photos, videos, trash }
    @Published var selectedMediaType: MediaType = .all
    @Published var showFavoritesOnly: Bool = false
    @Published var showLockedOnly: Bool = false // requires unlock
    @Published var includeSubalbums: Bool = true
    @Published var selectedAlbumIds: Set<Int> = []

    enum SortOption: Equatable { case createdNewest, createdOldest, importedNewest, importedOldest, largest, random(seed: Int) }
    @Published var sortOption: SortOption = .createdNewest
    enum LayoutOption: String { case grid, timeline }
    @Published var layout: LayoutOption = .grid

    @Published var searchText: String = ""
    @Published var isSearching: Bool = false

    // Filters (Photos tab)
    @Published var selectedFaces: Set<String> = []
    @Published var dateStart: Date? = nil
    @Published var dateEnd: Date? = nil
    @Published var typeScreenshot: Bool = false
    @Published var typeLive: Bool = false
    @Published var ratingMin: Int? = nil
    // Location placeholders (enabled UI, no query effect in v1)
    @Published var country: String? = nil
    @Published var region: String? = nil
    @Published var city: String? = nil

    // Paging
    @Published var isLoading: Bool = false
    @Published var hasMore: Bool = true
    @Published var lastInitialLoadError: String? = nil
    @Published var isAutoRetryingInitialLoad: Bool = false
    private var currentPage: Int = 1
    private let pageSize: Int = 100
    // Generation token to ignore stale in-flight loads when filters/sort change or refresh runs.
    private var loadGeneration: Int = 0
    // Active photo-page loads keyed by generation; used to avoid concurrency bugs and keep `isLoading` accurate.
    private var activeLoadsByGeneration: [Int: Int] = [:]
    private var initialLoadRetryCountByGeneration: [Int: Int] = [:]

    // Cache: per-query result sets to avoid refetch when switching All/Photos/Videos (and other filters).
    private struct CachedResult {
        let cachedAt: Date
        var photos: [ServerPhoto]
        var hasMore: Bool
        var nextPage: Int
        var mediaCounts: ServerMediaCounts?
        var yearBuckets: [ServerYearBucket]
    }
    private var cache: [String: CachedResult] = [:]
    private let cacheTTLSeconds: TimeInterval = 30 * 60

    // Selection
    @Published var isSelectionMode: Bool = false
    @Published var selected: Set<String> = [] // asset_ids

    // Services
    private let service = ServerPhotosService.shared
    private var cancellables = Set<AnyCancellable>()

    init() {
        // React to filter changes
        Publishers.CombineLatest4($selectedMediaType, $showFavoritesOnly, $showLockedOnly, $selectedAlbumIds)
            .dropFirst()
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshAll(resetPage: true) }
            .store(in: &cancellables)
        $sortOption
            .dropFirst()
            .sink { [weak self] opt in
                if case .largest = opt { self?.layout = .grid }
                self?.refreshAll(resetPage: true)
            }
            .store(in: &cancellables)
        $includeSubalbums
            .dropFirst()
            .sink { [weak self] _ in self?.refreshAll(resetPage: true) }
            .store(in: &cancellables)
        // React to new filter changes (faces/date/type/rating). Debounce to avoid rapid reloads.
        Publishers.MergeMany([
            $selectedFaces.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $dateStart.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $dateEnd.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $typeScreenshot.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $typeLive.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $ratingMin.dropFirst().map { _ in () }.eraseToAnyPublisher()
        ])
        .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
        .sink { [weak self] in self?.refreshAll(resetPage: true) }
        .store(in: &cancellables)
        // Note: iOS search mirrors Android — explicit submit only (no debounce).
        // We therefore do not auto-run queries on text change here.
    }

    // MARK: - Public API

    func onAppear() {
        refreshAll(resetPage: true)
        let gen = loadGeneration
        Task { await loadAlbums(generation: gen) }
    }

    private func bumpGeneration() -> Int {
        loadGeneration += 1
        lastInitialLoadError = nil
        isAutoRetryingInitialLoad = false
        initialLoadRetryCountByGeneration.removeAll()
        updateIsLoading()
        return loadGeneration
    }

    private func beginLoad(generation: Int) {
        activeLoadsByGeneration[generation, default: 0] += 1
        updateIsLoading()
    }

    private func endLoad(generation: Int) {
        let next = (activeLoadsByGeneration[generation] ?? 0) - 1
        if next <= 0 { activeLoadsByGeneration.removeValue(forKey: generation) }
        else { activeLoadsByGeneration[generation] = next }
        updateIsLoading()
    }

    private func hasActiveLoad(generation: Int) -> Bool {
        (activeLoadsByGeneration[generation] ?? 0) > 0
    }

    private func updateIsLoading() {
        isLoading = (activeLoadsByGeneration[loadGeneration] ?? 0) > 0
    }

    /// User-initiated refresh (pull-to-refresh). Performs a full reload of the current
    /// result set (including counts) and awaits completion so the UI refresh control ends
    /// at the right time.
    func pullToRefresh() async {
        // Exit selection mode to avoid mismatches if items change while refreshing.
        isSelectionMode = false
        selected.removeAll()

        let gen = bumpGeneration()
        currentPage = 1
        hasMore = true
        lastInitialLoadError = nil
        isAutoRetryingInitialLoad = false

        await loadAlbums(generation: gen)
        await loadYearBuckets(generation: gen)
        await loadNextPageIfNeeded(force: true, generation: gen)
        // Only refresh counts if we successfully advanced past page 1.
        if gen == loadGeneration, currentPage > 1 {
            await loadMediaCounts(generation: gen)
        }
    }

    func refreshAll(resetPage: Bool, forceNetwork: Bool = false) {
        let gen = resetPage ? bumpGeneration() : loadGeneration
        if resetPage {
            currentPage = 1
            hasMore = true
            lastInitialLoadError = nil
            isAutoRetryingInitialLoad = false
        }

        if resetPage, !forceNetwork, restoreFromCacheIfFresh(generation: gen) {
            return
        }

        if resetPage {
            // No cache for this filter state; clear immediately so the UI reflects the change.
            photos = []
        }
        Task {
            // Load the next page immediately so the UI can show progress and render photos as soon as possible.
            // Counts can be slower; fetch them in parallel to avoid blocking the grid.
            async let pageLoad: Void = loadNextPageIfNeeded(force: true, generation: gen)
            async let countsLoad: Void = loadMediaCounts(generation: gen)
            async let yearsLoad: Void = loadYearBuckets(generation: gen)
            _ = await (pageLoad, countsLoad, yearsLoad)
        }
    }

    /// Clear all active filters to show all photos. Keeps media type and sort intact,
    /// mirroring the web client's clearAllFilters behavior.
    func clearAllFilters() {
        // Search
        searchText = ""
        isSearching = false
        // Favorites / Albums / Subtree
        showFavoritesOnly = false
        selectedAlbumIds.removeAll()
        includeSubalbums = true
        // Faces / Types / Rating
        selectedFaces.removeAll()
        typeScreenshot = false
        typeLive = false
        ratingMin = nil
        // Location
        country = nil
        region = nil
        city = nil
        // Time range
        dateStart = nil
        dateEnd = nil
        // Locked-only
        showLockedOnly = false

        // Note: Do not touch selectedMediaType or sortOption (including random seed)
        refreshAll(resetPage: true)
    }

    func loadNextPageIfNeeded(force: Bool = false, generation: Int? = nil) async {
        let gen = generation ?? loadGeneration
        // Ignore stale scheduled loads when filters/sort changed.
        guard gen == loadGeneration else { return }
        guard hasMore || force else { return }
        guard !hasActiveLoad(generation: gen) else { return }
        beginLoad(generation: gen)
        defer { endLoad(generation: gen) }

        if isSearching && !searchText.isEmpty {
            // Search mode handled separately
            await performSearchPage(page: currentPage, generation: gen)
            return
        }

        let page = currentPage
        var q = buildQuery()
        q.page = page
        q.limit = pageSize
        let cacheKey = currentCacheKey()
        do {
            let res = try await service.listPhotos(query: q)
            await MainActor.run {
                guard gen == self.loadGeneration else { return }
                if page == 1 {
                    self.photos = res.photos
                    self.lastInitialLoadError = nil
                    self.isAutoRetryingInitialLoad = false
                } else {
                    // Deduplicate by asset_id
                    let seen = Set(self.photos.map { $0.asset_id })
                    let newOnes = res.photos.filter { !seen.contains($0.asset_id) }
                    self.photos.append(contentsOf: newOnes)
                }
                self.hasMore = res.has_more
                self.currentPage = page + 1

                // Update cache for this query signature.
                let entry = CachedResult(
                    cachedAt: Date(),
                    photos: self.photos,
                    hasMore: self.hasMore,
                    nextPage: self.currentPage,
                    mediaCounts: self.mediaCounts,
                    yearBuckets: self.yearBuckets
                )
                self.cache[cacheKey] = entry
            }
        } catch {
            if (error is CancellationError) || (error as? URLError)?.code == .cancelled {
                return
            }
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
                return
            }
            // If the very first page fails, do a short auto-retry for transient startup/network blips.
            if page == 1 {
                let msg = ns.localizedDescription.isEmpty ? "(no details)" : ns.localizedDescription
                let retryCount = initialLoadRetryCountByGeneration[gen, default: 0]
                if retryCount < 2, isRetryableInitialLoadError(error) {
                    initialLoadRetryCountByGeneration[gen] = retryCount + 1
                    await MainActor.run {
                        guard gen == self.loadGeneration else { return }
                        self.lastInitialLoadError = nil
                        self.isAutoRetryingInitialLoad = true
                        // Keep paging enabled so the retry can run.
                        self.hasMore = true
                    }
                    Task {
                        try? await Task.sleep(nanoseconds: 700_000_000)
                        await self.loadNextPageIfNeeded(force: true, generation: gen)
                        await MainActor.run {
                            guard gen == self.loadGeneration else { return }
                            self.isAutoRetryingInitialLoad = false
                        }
                    }
                    return
                }
                await MainActor.run {
                    guard gen == self.loadGeneration else { return }
                    self.lastInitialLoadError = msg
                    self.isAutoRetryingInitialLoad = false
                    self.hasMore = false
                }
                return
            }

            // On later pages, stop paging to avoid tight loops (but don't blank the grid).
            await MainActor.run {
                guard gen == self.loadGeneration else { return }
                self.hasMore = false
            }
        }
    }

    private func isRetryableInitialLoadError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet, .dnsLookupFailed:
                return true
            default:
                return false
            }
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorTimedOut,
                 NSURLErrorCannotFindHost,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorNotConnectedToInternet,
                 NSURLErrorDNSLookupFailed:
                return true
            default:
                return false
            }
        }
        if ns.domain == "HTTP" {
            if ns.code == 408 { return true }
            if (500...599).contains(ns.code) { return true }
        }
        return false
    }

    func toggleSelection(assetId: String) {
        if selected.contains(assetId) { selected.remove(assetId) } else { selected.insert(assetId) }
    }

    func selectAll() { selected = Set(photos.map { $0.asset_id }) }
    func deselectAll() { selected.removeAll() }

    // MARK: - Counts/Albums

    /// Reload the albums list from the server.
    /// Call this after creating, updating, or deleting albums to refresh the UI.
    func reloadAlbums() async {
        await loadAlbums()
    }

    private func loadAlbums() async {
        await loadAlbums(generation: nil)
    }

    private func loadAlbums(generation: Int?) async {
        let gen = generation ?? loadGeneration
        do {
            let list = try await service.listAlbums()
            let ordered = list.sorted { $0.updated_at > $1.updated_at }
            await MainActor.run {
                guard gen == self.loadGeneration else { return }
                self.albums = ordered
                // Clear any temporary names once the canonical album list has them.
                for a in ordered { self.selectedAlbumNameOverrides.removeValue(forKey: a.id) }
            }
        } catch {
            if (error is CancellationError) || (error as? URLError)?.code == .cancelled {
                return
            }
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
                return
            }
            await MainActor.run {
                guard gen == self.loadGeneration else { return }
                self.albums = []
            }
        }
    }

    func setSelectedAlbumNameOverride(id: Int, name: String?) {
        if let name, !name.isEmpty {
            selectedAlbumNameOverrides[id] = name
        } else {
            selectedAlbumNameOverrides.removeValue(forKey: id)
        }
    }

    private func loadMediaCounts() async {
        await loadMediaCounts(generation: nil)
    }

    private func loadYearBuckets(generation: Int?) async {
        let gen = generation ?? loadGeneration
        do {
            // Populate year picker/rail from server buckets so it includes years not present in the current page window.
            var q = buildQuery(includePage: false)
            if isSearching, !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                q.q = searchText
            }
            let buckets = try await service.bucketYears(query: q)
            await MainActor.run {
                guard gen == self.loadGeneration else { return }
                self.yearBuckets = buckets
                self.updateCachedYearBucketsIfPresent(years: buckets)
            }
        } catch {
            if (error is CancellationError) || (error as? URLError)?.code == .cancelled {
                return
            }
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
                return
            }
            await MainActor.run {
                guard gen == self.loadGeneration else { return }
                // Keep previous buckets on failure; avoid flashing empty year list.
            }
        }
    }

    private func loadMediaCounts(generation: Int?) async {
        let gen = generation ?? loadGeneration
        do {
            // Counts should reflect the segmented-control totals, not the currently selected media tab.
            // So we intentionally do NOT pass `filter_is_video` or trash-only filters.
            var q = buildQuery(includePage: false)
            q.filter_is_video = nil
            q.include_trashed = nil
            q.filter_trashed_only = nil
            if isSearching, !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                q.q = searchText
            }
            let counts = try await service.getMediaCounts(query: q)
            await MainActor.run {
                guard gen == self.loadGeneration else { return }
                // If we still have visible results, ignore an all-zero counts response which
                // is almost always a transient/failed refresh (prevents All/Photos/Videos -> 0).
                if counts.all == 0 && !self.photos.isEmpty { return }
                self.mediaCounts = counts
                self.updateCachedCountsIfPresent(counts: counts)
            }
        } catch {
            if (error is CancellationError) || (error as? URLError)?.code == .cancelled {
                return
            }
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
                return
            }
            await MainActor.run {
                guard gen == self.loadGeneration else { return }
                // Keep previous counts if refresh fails; avoid flashing to 0s.
            }
        }
    }

    // MARK: - Cache helpers

    private func currentCacheKey() -> String {
        let q = buildQuery(includePage: false)
        return signature(from: q.asQueryItems())
    }

    private func currentCacheBaseKey() -> String {
        let q = buildQuery(includePage: false)
        let items = q.asQueryItems().filter { $0.name != "filter_is_video" }
        return signature(from: items)
    }

    private func signature(from items: [URLQueryItem]) -> String {
        items
            .filter { $0.name != "page" && $0.name != "limit" }
            .sorted { a, b in
                if a.name != b.name { return a.name < b.name }
                return (a.value ?? "") < (b.value ?? "")
            }
            .map { "\($0.name)=\($0.value ?? "")" }
            .joined(separator: "&")
    }

    private func restoreFromCacheIfFresh(generation gen: Int) -> Bool {
        pruneExpiredCache()
        let key = currentCacheKey()
        guard let entry = cache[key] else { return false }
        guard Date().timeIntervalSince(entry.cachedAt) <= cacheTTLSeconds else {
            cache.removeValue(forKey: key)
            return false
        }
        // Only restore if the generation hasn't changed and we aren't in the middle of a load.
        guard gen == loadGeneration else { return false }
        photos = entry.photos
        hasMore = entry.hasMore
        currentPage = entry.nextPage
        mediaCounts = entry.mediaCounts
        yearBuckets = entry.yearBuckets
        lastInitialLoadError = nil
        isAutoRetryingInitialLoad = false
        return true
    }

    private func pruneExpiredCache() {
        let now = Date()
        cache = cache.filter { _, entry in now.timeIntervalSince(entry.cachedAt) <= cacheTTLSeconds }
    }

    private func updateCachedCountsIfPresent(counts: ServerMediaCounts) {
        let key = currentCacheKey()
        guard var entry = cache[key] else { return }
        entry.mediaCounts = counts
        cache[key] = entry
    }

    private func updateCachedYearBucketsIfPresent(years: [ServerYearBucket]) {
        let key = currentCacheKey()
        guard var entry = cache[key] else { return }
        entry.yearBuckets = years
        cache[key] = entry
    }

    /// Force refresh the current media-type tab and invalidate cached results for the other
    /// media-type tabs under the same filters/sort.
    func refreshCurrentTabAndInvalidateOtherMediaTypes() {
        pruneExpiredCache()
        let base = currentCacheBaseKey()
        let currentKey = currentCacheKey()
        cache = cache.filter { key, _ in
            let sameBase = signatureBase(of: key) == base
            if !sameBase { return true }
            // Keep only the current tab's cache; drop the other media-type caches.
            return key == currentKey
        }

        // Force a refetch for the current tab without flashing empty state.
        isSelectionMode = false
        selected.removeAll()
        let gen = bumpGeneration()
        currentPage = 1
        hasMore = true
        lastInitialLoadError = nil
        isAutoRetryingInitialLoad = false
        Task {
            async let pageLoad: Void = loadNextPageIfNeeded(force: true, generation: gen)
            async let countsLoad: Void = loadMediaCounts(generation: gen)
            async let yearsLoad: Void = loadYearBuckets(generation: gen)
            _ = await (pageLoad, countsLoad, yearsLoad)
        }
    }

    private func signatureBase(of key: String) -> String {
        // Best-effort: remove media-type selectors (`filter_is_video`, `filter_trashed_only`) so we can compare across tabs.
        // This keeps the logic resilient if ordering changes.
        let parts = key.split(separator: "&").filter {
            !$0.hasPrefix("filter_is_video=") && !$0.hasPrefix("filter_trashed_only=")
        }
        return parts.joined(separator: "&")
    }

    // MARK: - Search

    /// Called by UI when the user taps submit or presses keyboard Search.
    func submitSearch() {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return }
        let gen = bumpGeneration()
        isSearching = true
        currentPage = 1
        hasMore = true
        photos = []
        Task {
            await performSearchPage(page: 1, generation: gen)
            await loadMediaCounts(generation: gen)
        }
    }

    /// Collapse search and revert to the current Photos grid and filters without altering them.
    func cancelSearch() {
        searchText = ""
        isSearching = false
        currentPage = 1
        hasMore = true
        photos = []
        refreshAll(resetPage: true)
    }

    /// Jump the timeline to a specific year without changing filters.
    ///
    /// The server-backed timeline only has a window of pages loaded. To "jump" to a year that is not
    /// currently present in `photos`, we compute the page that should contain that year based on
    /// `/api/buckets/years` counts, then load that page and let the timeline view scroll to the year anchor.
    func jumpTimeline(toYear year: Int) {
        // Search results are ranked; there is no stable notion of "year position" to jump to.
        guard !isSearching else {
            ToastManager.shared.show("Jump to year isn't available while searching")
            return
        }
        // Timeline supports created_at ordering only.
        let newestFirst: Bool
        switch sortOption {
        case .createdNewest: newestFirst = true
        case .createdOldest: newestFirst = false
        default:
            ToastManager.shared.show("Jump to year is only available when sorting by date")
            return
        }
        guard !yearBuckets.isEmpty else {
            ToastManager.shared.show("Year list is still loading…")
            return
        }
        guard yearBuckets.contains(where: { $0.year == year }) else { return }

        // Compute the 0-based offset (in items) where the selected year begins.
        let offset: Int64 = yearBuckets
            .filter { newestFirst ? $0.year > year : $0.year < year }
            .reduce(0) { $0 + $1.count }
        let targetPage = max(1, Int(offset / Int64(pageSize)) + 1)

        // Clear selection to avoid mismatches if items change while jumping.
        isSelectionMode = false
        selected.removeAll()

        let gen = bumpGeneration()
        currentPage = targetPage
        hasMore = true
        photos = []

        Task { await loadNextPageIfNeeded(force: true, generation: gen) }
    }

    private func performSearchPage(page: Int) async {
        await performSearchPage(page: page, generation: nil)
    }

    private func performSearchPage(page: Int, generation: Int?) async {
        let gen = generation ?? loadGeneration
        do {
            // Pass supported filters to /api/search (media, locked, dates). Others are intersected client-side.
            var media: String? = nil
            switch selectedMediaType {
            case .all: media = nil
            case .photos: media = "photos"
            case .videos: media = "videos"
            case .trash: media = nil
            }
            let locked = showLockedOnly ? true : nil
            let dateFrom = dateStart.map { Int64($0.timeIntervalSince1970) }
            // Inclusive end-of-day for dateEnd
            let dateTo = dateEnd.map {
                let cal = Calendar.current
                let endOfDay = cal.date(bySettingHour: 23, minute: 59, second: 59, of: $0) ?? $0
                return Int64(endOfDay.timeIntervalSince1970)
            }
            let res = try await service.textSearch(query: searchText, media: media, locked: locked, dateFrom: dateFrom, dateTo: dateTo, page: page, limit: pageSize)
            let ids = res.items.map { $0.asset_id }
            let hydrated = try await service.getPhotosByAssetIds(ids, includeLocked: showLockedOnly)
            // Client-side intersection for filters not supported by /api/search (favorites, albums, rating minimum)
            var filtered = hydrated
            if showFavoritesOnly {
                filtered = filtered.filter { ($0.favorites ?? 0) > 0 }
            }
            if selectedMediaType == .trash {
                filtered = filtered.filter { ($0.delete_time ?? 0) > 0 }
            }
            if !selectedAlbumIds.isEmpty {
                // If album filters are active, intersect by calling getAlbumsForPhoto per item is expensive.
                // We rely on server-side album filters for main grid; for search, keep results as-is to avoid latency.
                // If strict intersection is required later, we can add a by-ids+albums filter endpoint.
            }
            if let rmin = ratingMin { filtered = filtered.filter { ($0.rating ?? 0) >= rmin } }
            await MainActor.run {
                guard gen == self.loadGeneration else { return }
                // Keep original rank order
                let byId = Dictionary(uniqueKeysWithValues: filtered.map { ($0.asset_id, $0) })
                let ordered = ids.compactMap { byId[$0] }
                if page == 1 { self.photos = ordered } else { self.photos.append(contentsOf: ordered) }
                self.hasMore = res.has_more
                self.currentPage = page + 1
            }
        } catch {
            if (error is CancellationError) || (error as? URLError)?.code == .cancelled {
                return
            }
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
                return
            }
            await MainActor.run {
                guard gen == self.loadGeneration else { return }
                self.hasMore = false
            }
        }
    }

    // MARK: - Query Builder

    private func buildQuery(includePage: Bool = true, includeDateRange: Bool = true) -> ServerPhotoListQuery {
        var q = ServerPhotoListQuery()
        q.sort_by = sortByField()
        q.sort_order = sortOrder()
        if case .random(let seed) = sortOption { q.sort_by = "random"; q.sort_random_seed = seed }

        switch selectedMediaType {
        case .all: break
        case .photos: q.filter_is_video = false
        case .videos: q.filter_is_video = true
        case .trash:
            q.filter_trashed_only = true
        }
        if showFavoritesOnly { q.filter_favorite = true }
        if showLockedOnly {
            // Require unlock upstream in UI; here include only locked
            q.filter_locked_only = true
        }
        if !selectedAlbumIds.isEmpty {
            q.album_ids = Array(selectedAlbumIds)
            q.album_subtree = includeSubalbums
        }
        // Faces (AND semantics by default)
        if !selectedFaces.isEmpty {
            q.filter_faces = Array(selectedFaces).joined(separator: ",")
        }
        // Time range
        if includeDateRange {
            if let s = dateStart {
                q.filter_date_from = Int64(s.timeIntervalSince1970)
            }
            if let e = dateEnd {
                // Inclusive end-of-day: advance to 23:59:59 local
                let cal = Calendar.current
                let endOfDay = cal.date(bySettingHour: 23, minute: 59, second: 59, of: e) ?? e
                q.filter_date_to = Int64(endOfDay.timeIntervalSince1970)
            }
        }
        // Type flags
        if typeScreenshot { q.filter_screenshot = true }
        if typeLive { q.filter_live_photo = true }
        // Rating minimum
        if let r = ratingMin, r >= 1, r <= 5 { q.filter_rating_min = r }
        if includePage {
            q.page = currentPage
            q.limit = pageSize
        }
        return q
    }

    private func sortByField() -> String {
        switch sortOption {
        case .createdNewest, .createdOldest: return "created_at"
        case .importedNewest, .importedOldest: return "last_indexed"
        case .largest: return "size"
        case .random: return "random"
        }
    }
    private func sortOrder() -> String {
        switch sortOption {
        case .createdNewest, .importedNewest: return "DESC"
        case .createdOldest, .importedOldest: return "ASC"
        case .largest: return "DESC"
        case .random: return "ASC"
        }
    }
}
