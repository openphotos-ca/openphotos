import SwiftUI
import Photos
import Combine

// MARK: - Random Number Generator

struct SeededRandomNumberGenerator: RandomNumberGenerator {
    var seed: Int
    
    mutating func next() -> UInt64 {
        seed = (seed &* 1103515245 &+ 12345) & 0x7FFFFFFF
        return UInt64(seed)
    }
}

// MARK: - Data Models

struct AlbumInfo {
    let name: String
    let displayName: String
    let count: Int
    let collection: PHAssetCollection?
}

enum MediaType: CaseIterable {
    case all, photos, videos
    
    var displayName: String {
        switch self {
        case .all: return "All"
        case .photos: return "Photos"
        case .videos: return "Videos"
        }
    }
}

enum SortOption: CaseIterable {
    case dateNewest, dateOldest, sizeDescending, random
    
    var displayName: String {
        switch self {
        case .dateNewest: return "Newest First"
        case .dateOldest: return "Oldest First"
        case .sizeDescending: return "Largest First"
        case .random: return "Random"
        }
    }
}

extension SortOption {
    var isDateBased: Bool { self == .dateNewest || self == .dateOldest }
}

enum LayoutOption: String, CaseIterable {
    case grid
    case timeline
    
    var displayName: String {
        switch self {
        case .grid: return "Grid"
        case .timeline: return "Timeline"
        }
    }
}

enum FilterType: CaseIterable {
    case timeRange, screenshots, livePhotos, missingInCloud
    
    var displayName: String {
        switch self {
        case .timeRange: return "Time Range"
        case .screenshots: return "Screenshots"
        case .livePhotos: return "Live Photos"
        case .missingInCloud: return "Missing in Cloud"
        }
    }
}

enum TimeRangePreset {
    case lastDay
    case lastWeek
    case lastMonth
    case lastYear
    case allTime
    case custom(from: Date?, to: Date?)
    
    var displayName: String {
        switch self {
        case .lastDay: return "Last Day"
        case .lastWeek: return "Last Week"
        case .lastMonth: return "Last Month"
        case .lastYear: return "Last Year"
        case .allTime: return "All Time"
        case .custom: return "Custom"
        }
    }
    
    var dateRange: (from: Date?, to: Date?) {
        let now = Date()
        let calendar = Calendar.current
        
        switch self {
        case .lastDay:
            let startDate = calendar.date(byAdding: .day, value: -1, to: now)
            return (startDate, now)
        case .lastWeek:
            let startDate = calendar.date(byAdding: .weekOfYear, value: -1, to: now)
            return (startDate, now)
        case .lastMonth:
            let startDate = calendar.date(byAdding: .month, value: -1, to: now)
            return (startDate, now)
        case .lastYear:
            let startDate = calendar.date(byAdding: .year, value: -1, to: now)
            return (startDate, now)
        case .allTime:
            return (nil, nil)
        case .custom(let from, let to):
            return (from, to)
        }
    }
}

enum CloudCheckScope {
    case allPhotos
    case currentSelection
}

class GalleryViewModel: ObservableObject {
    @Published var photos: [PHAsset] = [] {
        didSet { invalidateFilteredMediaCaches() }
    }
    var allPhotos: [PHAsset] = []  // Store all photos separately
    @Published var selectedPhotos: Set<PHAsset> = []
    @Published var isLoading = false
    @Published var isSelectionMode = false
    @Published var searchText = "" {
        didSet { invalidateFilteredMediaCaches() }
    }
    @Published var showingPermissionAlert = false
    
    // New properties for enhanced gallery
    @Published var selectedMediaType: MediaType = .all {
        didSet { invalidateFilteredMediaCaches() }
    }
    @Published var selectedAlbum: String? = nil {
        didSet { invalidateFilteredMediaCaches() }
    }
    @Published var selectedAlbumId: Int64? = nil {
        didSet { invalidateFilteredMediaCaches() }
    }
    @Published var selectedAlbumIds: Set<Int64> = [] {
        didSet { invalidateFilteredMediaCaches() }
    }
    @Published var includeSubalbums: Bool = false {
        didSet {
            recomputeAlbumFilter()
            invalidateFilteredMediaCaches()
        }
    }
    @Published var sortOption: SortOption = .dateNewest {
        didSet {
            // Generate new random seed when Random is selected
            if sortOption == .random {
                randomSeed = Int.random(in: 0...Int.max)
            }
            // Enforce grid when not sorting by date
            if !(sortOption == .dateNewest || sortOption == .dateOldest) && layout == .timeline {
                layout = .grid
            }
            invalidateFilteredMediaCaches()
        }
    }
    @Published var selectedFilter: FilterType? = nil {
        didSet { invalidateFilteredMediaCaches() }
    }
    // Layout (persisted)
    @AppStorage("galleryLayout") private var layoutRawValue: String = LayoutOption.grid.rawValue
    @Published var layout: LayoutOption = .grid {
        didSet { layoutRawValue = layout.rawValue }
    }
    @Published var showFavoritesOnly: Bool = false {
        didSet { invalidateFilteredMediaCaches() }
    }
    // Locked filter: when false (default), locked items are excluded.
    // When true, only locked items are shown (requires unlock gate in UI).
    @Published var showLockedOnly: Bool = false {
        didSet { invalidateFilteredMediaCaches() }
    }
    // Per-photo lock override cache (localIdentifier -> override).
    //
    // This is used for lightweight UI elements (e.g., lock badges) and is kept in sync via
    // `SyncRepository.lockOverrideChangedNotification` to avoid per-cell DB reads during scrolling.
    @Published private(set) var lockOverrideByLocalIdentifier: [String: Bool] = [:] {
        didSet { invalidateFilteredMediaCaches(clearLockCache: true) }
    }
    // Per-photo cloud backup cache (localIdentifier -> backed up).
    //
    // Populated from local DB and kept in sync via `SyncRepository.cloudStatusChangedNotification`.
    @Published private(set) var cloudBackedUpLocalIdentifiers: Set<String> = []
    // Per-photo cloud backup cache (localIdentifier -> missing in cloud, but only after being checked).
    @Published private(set) var cloudMissingLocalIdentifiers: Set<String> = [] {
        didSet {
            if selectedFilter == .missingInCloud {
                invalidateFilteredMediaCaches()
            }
        }
    }
    @Published var isCloudCheckRunning: Bool = false
    // Deprecated: system albums (kept for backward compatibility)
    @Published var albums: [AlbumInfo] = []
    // Albums from app database
    @Published var dbAlbums: [Album] = []        // All albums (for tree, lookups)
    @Published var dbAlbumsByRecent: [Album] = [] // Ordered by most recent use (for chips)
    @Published var recentlyCreatedAlbumId: Int64? = nil // Used to float new album to front of chips
    @Published var showingTimeRangeDialog = false
    @Published var selectedTimeRange: TimeRangePreset = .allTime {
        didSet { invalidateFilteredMediaCaches() }
    }
    @Published var customStartDate: Date? = nil {
        didSet { invalidateFilteredMediaCaches() }
    }
    @Published var customEndDate: Date? = nil {
        didSet { invalidateFilteredMediaCaches() }
    }
    private var randomSeed = Int.random(in: 0...Int.max)
    private var cloudCheckTask: Task<Void, Never>? = nil
    private var filterInputsVersion: Int = 0
    private var filteredMediaCacheVersion: Int = -1
    private var filteredMediaCache: [PHAsset] = []
    private var filteredMediaWithoutTypeCacheVersion: Int = -1
    private var filteredMediaWithoutTypeCache: [PHAsset] = []
    private var cachedLockStateByLocalIdentifier: [String: Bool] = [:]
    private var cachedLockScopeSelectedOnly: Bool?
    
    // Full-screen viewer properties
    @Published var showingFullScreenViewer = false
    @Published var fullScreenViewerIndex = 0
    
    private let photoService = PhotoService.shared
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        setupBindings()
        // Restore persisted layout
        if let saved = LayoutOption(rawValue: layoutRawValue) { layout = saved }
        // Load per-photo overrides once; subsequent changes are applied incrementally via notification.
        refreshLockOverrides()
        // Load cached cloud statuses once; subsequent changes are applied incrementally via notification.
        refreshCloudBackedUp()
        refreshCloudMissing()
        // Don't initialize here - wait for photo permissions
    }

    private func setupBindings() {
        // Bind to photo service
        photoService.$photos
            .receive(on: DispatchQueue.main)
            .sink { [weak self] photos in
                self?.allPhotos = photos
                // Only update photos if no album is selected
                if self?.selectedAlbumId == nil {
                    self?.photos = photos
                }
            }
            .store(in: &cancellables)
        
        photoService.$isLoading
            .receive(on: DispatchQueue.main)
            .assign(to: \.isLoading, on: self)
            .store(in: &cancellables)
        
        photoService.$authorizationStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.handleAuthorizationChange(status)
            }
            .store(in: &cancellables)

        // Listen for lock override changes so thumbnails can update without polling or DB reads.
        NotificationCenter.default.publisher(for: SyncRepository.lockOverrideChangedNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let self else { return }
                guard
                    let userInfo = note.userInfo,
                    let localId = userInfo[SyncRepository.LockOverrideUserInfoKey.localIdentifier] as? String
                else { return }
                let raw = userInfo[SyncRepository.LockOverrideUserInfoKey.overrideValue]
                let value: Bool? = {
                    if raw is NSNull { return nil }
                    if let num = raw as? NSNumber { return num.boolValue }
                    return nil
                }()
                var next = self.lockOverrideByLocalIdentifier
                if let value {
                    next[localId] = value
                } else {
                    next.removeValue(forKey: localId)
                }
                self.lockOverrideByLocalIdentifier = next
            }
            .store(in: &cancellables)

        // Listen for cloud status changes so thumbnails can update without polling or DB reads.
        NotificationCenter.default.publisher(for: SyncRepository.cloudStatusChangedNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let self else { return }
                guard
                    let userInfo = note.userInfo,
                    let localId = userInfo[SyncRepository.CloudStatusUserInfoKey.localIdentifier] as? String,
                    let num = userInfo[SyncRepository.CloudStatusUserInfoKey.backedUp] as? NSNumber
                else { return }
                var next = self.cloudBackedUpLocalIdentifiers
                var missingNext = self.cloudMissingLocalIdentifiers
                if num.boolValue {
                    next.insert(localId)
                    missingNext.remove(localId)
                } else {
                    next.remove(localId)
                    missingNext.insert(localId)
                }
                self.cloudBackedUpLocalIdentifiers = next
                self.cloudMissingLocalIdentifiers = missingNext
            }
            .store(in: &cancellables)

        // Bulk updates: refresh from DB once (avoids N notifications).
        NotificationCenter.default.publisher(for: SyncRepository.cloudBulkStatusChangedNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshCloudBackedUp()
                self?.refreshCloudMissing()
            }
            .store(in: &cancellables)
    }

    // MARK: - Lock Overrides

    /// Returns a user-specified lock override for a given `PHAsset.localIdentifier` if present.
    func lockOverride(forLocalIdentifier localIdentifier: String) -> Bool? {
        lockOverrideByLocalIdentifier[localIdentifier]
    }

    /// Loads all explicit lock overrides from the local DB.
    ///
    /// This is expected to be a small dataset and is safe to load in one query. Keeping it cached
    /// avoids N-per-cell DB lookups during grid scrolling while sync is active.
    func refreshLockOverrides() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let map = SyncRepository.shared.getAllLockOverrides()
            DispatchQueue.main.async {
                self?.lockOverrideByLocalIdentifier = map
            }
        }
    }

    func isCloudBackedUp(localIdentifier: String) -> Bool {
        cloudBackedUpLocalIdentifiers.contains(localIdentifier)
    }

    func refreshCloudBackedUp() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let set = SyncRepository.shared.getAllCloudBackedUpLocalIdentifiers()
            DispatchQueue.main.async {
                self?.cloudBackedUpLocalIdentifiers = set
            }
        }
    }

    func refreshCloudMissing() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let set = SyncRepository.shared.getAllCloudMissingLocalIdentifiers()
            DispatchQueue.main.async {
                self?.cloudMissingLocalIdentifiers = set
            }
        }
    }

    private func invalidateFilteredMediaCaches(clearLockCache: Bool = false) {
        filterInputsVersion &+= 1
        filteredMediaCacheVersion = -1
        filteredMediaWithoutTypeCacheVersion = -1
        if clearLockCache {
            cachedLockStateByLocalIdentifier.removeAll(keepingCapacity: true)
            cachedLockScopeSelectedOnly = nil
        }
    }

    private func isAssetLockedCached(localIdentifier: String, scopeSelectedOnly: Bool) -> Bool {
        if cachedLockScopeSelectedOnly != scopeSelectedOnly {
            cachedLockScopeSelectedOnly = scopeSelectedOnly
            cachedLockStateByLocalIdentifier.removeAll(keepingCapacity: true)
        }
        if let override = lockOverrideByLocalIdentifier[localIdentifier] {
            return override
        }
        if let cached = cachedLockStateByLocalIdentifier[localIdentifier] {
            return cached
        }
        let locked = AlbumService.shared.isAssetLocked(
            assetLocalIdentifier: localIdentifier,
            scopeSelectedOnly: scopeSelectedOnly
        )
        cachedLockStateByLocalIdentifier[localIdentifier] = locked
        return locked
    }

    @MainActor
    func startCloudCheck(scope: CloudCheckScope) {
        guard !isCloudCheckRunning else { return }

        let snapshot: [PHAsset]
        switch scope {
        case .allPhotos:
            snapshot = allPhotos
        case .currentSelection:
            snapshot = filteredMedia
        }

        guard !snapshot.isEmpty else {
            switch scope {
            case .allPhotos:
                ToastManager.shared.show("No photos to check")
            case .currentSelection:
                ToastManager.shared.show("No photos in current selection")
            }
            return
        }

        isCloudCheckRunning = true
        cloudCheckTask = nil
        ToastManager.shared.show("Checking cloud backup…", duration: 2.0)

        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                let result = try await CloudBackupCheckService.shared.runCloudCheck(
                    assets: snapshot,
                    onProgress: { _, _ in }
                )
                await MainActor.run {
                    self.cloudCheckTask = nil
                    self.isCloudCheckRunning = false
                    self.refreshCloudBackedUp()
                    self.refreshCloudMissing()
                    ToastManager.shared.showPinned("Cloud check: \(result.backedUp) backed up, \(result.missing) missing, \(result.skipped) not checked")
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.cloudCheckTask = nil
                    self.isCloudCheckRunning = false
                    self.refreshCloudBackedUp()
                    self.refreshCloudMissing()
                    ToastManager.shared.show("Cloud check stopped")
                }
            } catch {
                await MainActor.run {
                    self.cloudCheckTask = nil
                    self.isCloudCheckRunning = false
                    ToastManager.shared.showPinned("Cloud check failed: \(error.localizedDescription)")
                }
            }
        }

        cloudCheckTask = task
    }

    @MainActor
    func stopCloudCheck() {
        guard isCloudCheckRunning, let task = cloudCheckTask else { return }
        ToastManager.shared.show("Stopping cloud check…", duration: 1.5)
        task.cancel()
    }
    
    private func handleAuthorizationChange(_ status: PHAuthorizationStatus) {
        switch status {
        case .authorized, .limited:
            photoService.loadPhotos()
            showingPermissionAlert = false
            // Initialize album database after getting photo permissions
            initializeAlbumDatabase()
            // Load albums from the app database
            loadDbAlbums()
        case .denied, .restricted:
            showingPermissionAlert = true
        case .notDetermined:
            break
        @unknown default:
            break
        }
    }
    
    // MARK: - Actions
    
    func requestPermissions() {
        photoService.requestPermissions()
    }
    
    func refreshPhotos() {
        // If no album is selected, show all photos
        if selectedAlbumId == nil && selectedAlbumIds.isEmpty {
            photos = allPhotos
        }
        photoService.loadPhotos()
        loadDbAlbums()
    }

    func syncSelectedAssets(_ assets: [PHAsset], source: String = "photos-actions") {
        guard !assets.isEmpty else { return }
        HybridUploadManager.shared.startUpload(assets: assets)
        let localIds = Set(assets.map { $0.localIdentifier })
        SyncService.shared.scheduleManualCloudCheckAfterUpload(
            localIdentifiers: localIds,
            source: source
        )
    }
    
    // MARK: - Album Database
    
    private func initializeAlbumDatabase() {
        // Initialize database on first launch
        let userDefaults = UserDefaults.standard
        let hasInitializedAlbums = userDefaults.bool(forKey: "hasInitializedAlbums")
        
        if !hasInitializedAlbums {
            print("First launch detected - importing system albums...")
            // Import system albums on first launch
            AlbumService.shared.importSystemAlbums()
            userDefaults.set(true, forKey: "hasInitializedAlbums")
            print("System albums import completed")
        } else {
            print("Albums already initialized")
        }
    }

    func loadDbAlbums() {
        let all = AlbumService.shared.getAllAlbums()
        let recent = AlbumService.shared.getAlbumsOrderedByRecentUse()
        DispatchQueue.main.async { [weak self] in
            self?.dbAlbums = all
            self?.dbAlbumsByRecent = recent
            self?.invalidateFilteredMediaCaches(clearLockCache: true)
        }
    }

    var favoritesCount: Int {
        allPhotos.filter { $0.isFavorite }.count
    }

    // Chips list with newly created album pinned first (after Favorites)
    var dbAlbumsForChips: [Album] {
        var list = dbAlbumsByRecent
        if let pinnedId = recentlyCreatedAlbumId,
           let idx = list.firstIndex(where: { $0.id == pinnedId }) {
            let item = list.remove(at: idx)
            list.insert(item, at: 0)
        }
        return list
    }
    
    // Debug method to reset album initialization (for testing)
    func resetAlbumInitialization() {
        UserDefaults.standard.removeObject(forKey: "hasInitializedAlbums")
        print("Album initialization flag reset - albums will be imported on next app launch")
    }
    
    func selectAlbumById(_ albumId: Int64) {
        // Single-select via tree: toggle into multi-selection model
        toggleAlbumSelection(albumId)
    }

    func toggleAlbumSelection(_ albumId: Int64) {
        var next = selectedAlbumIds
        if next.contains(albumId) { next.remove(albumId) } else { next.insert(albumId) }
        selectedAlbumIds = next
        // Sync legacy fields
        if next.count == 0 {
            selectedAlbumId = nil
            selectedAlbum = nil
            photos = allPhotos
            return
        } else if next.count == 1, let onlyId = next.first {
            selectedAlbumId = onlyId
            if let album = AlbumService.shared.getAllAlbums().first(where: { $0.id == onlyId }) {
                selectedAlbum = album.name
            }
        } else {
            selectedAlbumId = nil
            selectedAlbum = nil
        }
        recomputeAlbumFilter()
    }

    func recomputeAlbumFilter() {
        let idsSet = selectedAlbumIds
        if idsSet.isEmpty { return }
        // Compute intersection across selected albums with subtree toggle
        var intersection: Set<String>? = nil
        for id in idsSet {
            let ids = Set(AlbumService.shared.getAlbumPhotos(albumId: id, includeSubtree: includeSubalbums))
            if let current = intersection { intersection = current.intersection(ids) } else { intersection = ids }
        }
        let idSet = intersection ?? []
        guard !idSet.isEmpty else {
            photos = []
            objectWillChange.send()
            return
        }
        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(format: "localIdentifier IN %@", Array(idSet))
        let fetchResult = PHAsset.fetchAssets(with: fetchOptions)
        var filtered: [PHAsset] = []
        fetchResult.enumerateObjects { asset, _, _ in filtered.append(asset) }
        DispatchQueue.main.async { [weak self] in
            self?.photos = filtered
            self?.objectWillChange.send()
        }
    }
    
    private func loadAlbums() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var albumsArray: [AlbumInfo] = []
            
            // Add Favorites album
            let favoritesOptions = PHFetchOptions()
            favoritesOptions.predicate = NSPredicate(format: "isFavorite == YES")
            let favoriteAssets = PHAsset.fetchAssets(with: favoritesOptions)
            if favoriteAssets.count > 0 {
                albumsArray.append(AlbumInfo(
                    name: "Favorites",
                    displayName: "Favorites",
                    count: favoriteAssets.count,
                    collection: nil
                ))
            }
            
            // Add other albums
            let albumResult = PHAssetCollection.fetchAssetCollections(
                with: .album,
                subtype: .any,
                options: nil
            )
            
            albumResult.enumerateObjects { collection, _, _ in
                let assets = PHAsset.fetchAssets(in: collection, options: nil)
                if assets.count > 0 {
                    albumsArray.append(AlbumInfo(
                        name: collection.localIdentifier,
                        displayName: collection.localizedTitle ?? "Unknown",
                        count: assets.count,
                        collection: collection
                    ))
                }
            }
            
            DispatchQueue.main.async {
                self?.albums = albumsArray
            }
        }
    }
    
    func toggleSelection(for photo: PHAsset) {
        if selectedPhotos.contains(photo) {
            selectedPhotos.remove(photo)
        } else {
            selectedPhotos.insert(photo)
        }
        
        if selectedPhotos.isEmpty {
            isSelectionMode = false
        }
    }
    
    func startSelectionMode() {
        isSelectionMode = true
    }
    
    func exitSelectionMode() {
        // Exit selection mode and clear previous selections.
        isSelectionMode = false
        selectedPhotos.removeAll()
    }
    
    func clearSelection() {
        // Explicitly clear all selections
        selectedPhotos.removeAll()
        isSelectionMode = false
    }
    
    func deselectAll() {
        // Clear all selections but remain in selection mode
        selectedPhotos.removeAll()
    }
    
    func deselect(photo: PHAsset) {
        selectedPhotos.remove(photo)
    }
    
    func selectAllPhotos() {
        // Select all photos in the current filtered view
        selectedPhotos = Set(filteredMedia)
    }
    
    func swapSelection() {
        // Invert selection - unselected become selected and vice versa
        let allPhotos = Set(filteredMedia)
        let currentlySelected = selectedPhotos
        
        // Remove currently selected
        selectedPhotos = allPhotos.subtracting(currentlySelected)
    }
    
    func deleteSelectedPhotos() {
        let assetsToDelete = Array(selectedPhotos)
        
        photoService.deletePhotos(assetsToDelete)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { completion in
                    if case .failure(let error) = completion {
                        print("Failed to delete photos: \(error)")
                    }
                },
                receiveValue: { [weak self] success in
                    if success {
                        self?.selectedPhotos.removeAll()
                        self?.isSelectionMode = false
                        self?.refreshPhotos()
                    }
                }
            )
            .store(in: &cancellables)
    }

    func addSelectedPhotosToAlbum(albumId: Int64, completion: ((Bool) -> Void)? = nil) {
        let selectedAssets = Array(selectedPhotos)
        guard !selectedAssets.isEmpty else {
            Task { @MainActor in
                ToastManager.shared.show("No photos selected")
            }
            completion?(false)
            return
        }

        let assetIds = selectedAssets.map { $0.localIdentifier }
        let albumName = AlbumService.shared.getAllAlbums().first(where: { $0.id == albumId })?.name ?? "album"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = AlbumService.shared.addPhotosToAlbum(albumId: albumId, assetIds: assetIds)
            if ok {
                AlbumService.shared.refreshSystemAlbumMemberships()
                self?.loadDbAlbums()
            }

            DispatchQueue.main.async {
                let itemWord = assetIds.count == 1 ? "item" : "items"
                if ok {
                    self?.exitSelectionMode()
                    self?.refreshPhotos()
                    ToastManager.shared.show("Added \(assetIds.count) \(itemWord) to \(albumName)")
                } else {
                    ToastManager.shared.show("Failed to add to \(albumName)")
                }
                completion?(ok)
            }
        }
    }
    
    func shareSelectedPhotos(completion: @escaping ([UIImage]) -> Void) {
        // Convert PHAssets to UIImages for sharing
        var imagesToShare: [UIImage] = []
        let selectedAssets = Array(selectedPhotos)
        let group = DispatchGroup()
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true // allow iCloud-backed assets to download
        
        for asset in selectedAssets {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                PHImageManager.default().requestImage(
                    for: asset,
                    targetSize: CGSize(width: 2048, height: 2048),
                    contentMode: .aspectFit,
                    options: options
                ) { image, _ in
                    if let image = image {
                        DispatchQueue.main.async {
                            imagesToShare.append(image)
                        }
                    }
                    group.leave()
                }
            }
        }
        
        group.notify(queue: .main) {
            completion(imagesToShare)
        }
    }
    
    func openFullScreenViewer(for asset: PHAsset) {
        if let index = filteredMedia.firstIndex(of: asset) {
            fullScreenViewerIndex = index
            showingFullScreenViewer = true
        }
    }
    
    // MARK: - Computed Properties
    
    var filteredMedia: [PHAsset] {
        if filteredMediaCacheVersion == filterInputsVersion {
            return filteredMediaCache
        }

        var assets = photos
        
        // Filter by media type
        switch selectedMediaType {
        case .photos:
            assets = assets.filter { $0.mediaType == .image }
        case .videos:
            assets = assets.filter { $0.mediaType == .video }
        case .all:
            break // Show all
        }
        
        // Apply favorites and album selections (AND semantics)
        if showFavoritesOnly {
            assets = assets.filter { $0.isFavorite }
        }
        if !selectedAlbumIds.isEmpty {
            // Apply intersection across selected albums using localIdentifier
            var intersection: Set<String>? = nil
            for id in selectedAlbumIds {
                let ids = Set(AlbumService.shared.getAlbumPhotos(albumId: id, includeSubtree: includeSubalbums))
                if let cur = intersection { intersection = cur.intersection(ids) } else { intersection = ids }
            }
            let keep = intersection ?? []
            assets = assets.filter { keep.contains($0.localIdentifier) }
        }
        
        // Apply filters
        if let selectedFilter = selectedFilter {
            switch selectedFilter {
            case .screenshots:
                // Filter to show only screenshots using PHAssetMediaSubtype
                assets = assets.filter { asset in
                    asset.mediaType == .image && asset.mediaSubtypes.contains(.photoScreenshot)
                }
            case .livePhotos:
                // Filter to show only Live Photos
                assets = assets.filter { asset in
                    asset.mediaType == .image && asset.mediaSubtypes.contains(.photoLive)
                }
            case .timeRange:
                // Apply time range filter
                let dateRange = selectedTimeRange.dateRange
                if let fromDate = dateRange.from {
                    assets = assets.filter { asset in
                        if let creationDate = asset.creationDate {
                            return creationDate >= fromDate
                        }
                        return false
                    }
                }
                if let toDate = dateRange.to {
                    assets = assets.filter { asset in
                        if let creationDate = asset.creationDate {
                            return creationDate <= toDate
                        }
                        return false
                    }
                }
            case .missingInCloud:
                let missing = cloudMissingLocalIdentifiers
                assets = assets.filter { missing.contains($0.localIdentifier) }
            }
        }
        
        // Apply locked filter (default exclude locked)
        do {
            let onlySelectedScope = (AuthManager.shared.syncScope == .selectedAlbums)
            if showLockedOnly {
                assets = assets.filter { asset in
                    isAssetLockedCached(localIdentifier: asset.localIdentifier, scopeSelectedOnly: onlySelectedScope)
                }
            } else {
                assets = assets.filter { asset in
                    !isAssetLockedCached(localIdentifier: asset.localIdentifier, scopeSelectedOnly: onlySelectedScope)
                }
            }
        }

        // Apply sorting
        switch sortOption {
        case .dateNewest:
            assets.sort { $0.creationDate ?? Date.distantPast > $1.creationDate ?? Date.distantPast }
        case .dateOldest:
            assets.sort { $0.creationDate ?? Date.distantFuture < $1.creationDate ?? Date.distantFuture }
        case .sizeDescending:
            // Sort by pixel count (width * height) - largest first
            assets.sort { $0.pixelWidth * $0.pixelHeight > $1.pixelWidth * $1.pixelHeight }
        case .random:
            // Use a seeded random generator for consistent shuffling until re-selected
            var generator = SeededRandomNumberGenerator(seed: randomSeed)
            assets.shuffle(using: &generator)
        }
        
        // Apply search filter
        if !searchText.isEmpty {
            // In full implementation, this would search by metadata, location, etc.
            // For now, we'll just return the sorted and filtered results
        }

        filteredMediaCache = assets
        filteredMediaCacheVersion = filterInputsVersion
        return assets
    }
    
    // Helper to get filtered media without media type filter
    private var filteredMediaWithoutMediaType: [PHAsset] {
        if filteredMediaWithoutTypeCacheVersion == filterInputsVersion {
            return filteredMediaWithoutTypeCache
        }

        var assets = photos
        
        // If photos are filtered via multi-select OR tree selection, avoid refiltering here
        if selectedAlbumId != nil || !selectedAlbumIds.isEmpty {
            // Already filtered via toggleAlbumSelection/selectAlbumById
        } else if let selectedAlbum = selectedAlbum {
            // Apply album filter for system albums
            if selectedAlbum == "Favorites" {
                // Handled by showFavoritesOnly; ignore legacy field
            } else {
                // Filter by specific album
                if let album = albums.first(where: { $0.name == selectedAlbum }),
                   let collection = album.collection {
                    let albumAssets = PHAsset.fetchAssets(in: collection, options: nil)
                    let albumAssetSet = Set((0..<albumAssets.count).compactMap { albumAssets.object(at: $0) })
                    assets = assets.filter { albumAssetSet.contains($0) }
                }
            }
        }
        // Apply favorites
        if showFavoritesOnly {
            assets = assets.filter { $0.isFavorite }
        }

        // Apply locked filter (default exclude locked) — used for counts
        do {
            let onlySelectedScope = (AuthManager.shared.syncScope == .selectedAlbums)
            if showLockedOnly {
                assets = assets.filter { asset in
                    isAssetLockedCached(localIdentifier: asset.localIdentifier, scopeSelectedOnly: onlySelectedScope)
                }
            } else {
                assets = assets.filter { asset in
                    !isAssetLockedCached(localIdentifier: asset.localIdentifier, scopeSelectedOnly: onlySelectedScope)
                }
            }
        }

        // Apply filters (but not media type filter)
        if let selectedFilter = selectedFilter {
            switch selectedFilter {
            case .screenshots:
                assets = assets.filter { asset in
                    asset.mediaType == .image && asset.mediaSubtypes.contains(.photoScreenshot)
                }
            case .livePhotos:
                assets = assets.filter { asset in
                    asset.mediaType == .image && asset.mediaSubtypes.contains(.photoLive)
                }
            case .timeRange:
                let dateRange = selectedTimeRange.dateRange
                if let fromDate = dateRange.from {
                    assets = assets.filter { asset in
                        if let creationDate = asset.creationDate {
                            return creationDate >= fromDate
                        }
                        return false
                    }
                }
                if let toDate = dateRange.to {
                    assets = assets.filter { asset in
                        if let creationDate = asset.creationDate {
                            return creationDate <= toDate
                        }
                        return false
                    }
                }
            case .missingInCloud:
                let missing = cloudMissingLocalIdentifiers
                assets = assets.filter { missing.contains($0.localIdentifier) }
            }
        }
        filteredMediaWithoutTypeCache = assets
        filteredMediaWithoutTypeCacheVersion = filterInputsVersion
        return assets
    }
    
    var allMediaCount: Int {
        filteredMediaWithoutMediaType.count
    }
    
    var photoCount: Int {
        filteredMediaWithoutMediaType.filter { $0.mediaType == .image }.count
    }
    
    var videoCount: Int {
        // Special case: Screenshots and Live Photos are image-only filters
        if let selectedFilter = selectedFilter {
            switch selectedFilter {
            case .screenshots, .livePhotos:
                return 0
            case .timeRange:
                break
            case .missingInCloud:
                break
            }
        }
        return filteredMediaWithoutMediaType.filter { $0.mediaType == .video }.count
    }
    
    var selectionStatusText: String {
        if selectedPhotos.isEmpty {
            return "Select Photos"
        } else {
            return "\(selectedPhotos.count) Selected"
        }
    }
    
    var hasPhotos: Bool {
        !photos.isEmpty
    }
    
    var shouldShowEmptyState: Bool {
        !isLoading && !hasPhotos && photoService.hasPermission
    }
    
    var hasActiveFilter: Bool {
        (selectedAlbum != nil || selectedAlbumId != nil || !selectedAlbumIds.isEmpty) ||
        selectedFilter != nil ||
        showFavoritesOnly ||
        showLockedOnly ||
        sortOption != .dateNewest
    }
    
    func clearAllFilters() {
        selectedAlbum = nil
        selectedAlbumId = nil
        selectedAlbumIds.removeAll()
        selectedFilter = nil
        showFavoritesOnly = false
        showLockedOnly = false
        sortOption = .dateNewest
        selectedTimeRange = .allTime
        includeSubalbums = false
        // Reset to all photos
        photos = allPhotos
    }
}
