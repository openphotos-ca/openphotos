import SwiftUI
import Photos

struct GalleryView: View {
    @EnvironmentObject var viewModel: GalleryViewModel
    @EnvironmentObject var auth: AuthManager
    @State private var showingDeleteAlert = false
    @State private var showingSearch = false
    @State private var showingSelectedPhotosView = false
    @State private var showingActionMenu = false
    @State private var showingUploadsView = false
    @State private var showingLogin = false
    @State private var showingAddToAlbumPicker = false
    @State private var addToAlbumSelectedId: Int64? = nil
    @State private var showingStopCloudCheckConfirm = false
    @Environment(\.openURL) private var openURL
    // Header show/hide state (collapses rows above the grid when scrolling down)
    @State private var showHeaders: Bool = true
    @State private var lastOffset: CGFloat = 0
    @State private var isTrackingScroll: Bool = false
    // Direction-aware accumulation to make header toggling reliable on iPhone
    @State private var dirAccum: CGFloat = 0
    @State private var lastDir: Int = 0 // 1 = up (toward top), -1 = down (away from top), 0 = unknown
    // Measured header height for overlay layout
    @State private var headerHeight: CGFloat = 0
    @State private var didInitialLoad: Bool = false
    // Debug scroll logging (local)
    // (debug variables removed)
    
    var body: some View {
        ZStack(alignment: .top) {
            if !PhotoService.shared.hasPermission {
                PermissionRequestView()
            } else {
                // Main scrollable content. Provide a top inset inside content equal to header height when visible.
                Group {
                    if viewModel.shouldShowEmptyState {
                        EmptyStateView()
                    } else if viewModel.isLoading {
                        LoadingView()
                    } else {
                        if viewModel.layout == .timeline && viewModel.sortOption.isDateBased {
                            PhotosTimelineView(
                                onScrollOffsetChange: { y in handleScroll(y) },
                                topInset: showHeaders ? headerHeight : 0
                            )
                            .environmentObject(viewModel)
                        } else {
                            EnhancedPhotoGridView(
                                onScrollOffsetChange: { y in handleScroll(y) },
                                topInset: showHeaders ? headerHeight : 0
                            )
                            .environmentObject(viewModel)
                        }
                    }
                }

                // Overlay header on top, measured and animated like ServerGalleryView
                VStack(spacing: 0) {
                    // App bar
                    GalleryAppBar(
                        isSelectionMode: viewModel.isSelectionMode,
                        isCloudCheckRunning: viewModel.isCloudCheckRunning,
                        showingSearch: $showingSearch,
                        currentSortOption: viewModel.sortOption,
                        currentLayout: viewModel.layout,
                        showLayoutToggle: viewModel.sortOption.isDateBased,
                        onSearch: { showingSearch.toggle() },
                        onSlideshow: { /* TODO: Implement slideshow */ },
                        onSort: { option in viewModel.sortOption = option },
                        onLayoutChange: { layout in viewModel.layout = layout },
                        onCloudCheck: {
                            showingStopCloudCheckConfirm = true
                        },
                        onCloudCheckAll: {
                            viewModel.startCloudCheck(scope: .allPhotos)
                        },
                        onCloudCheckCurrentSelection: {
                            viewModel.startCloudCheck(scope: .currentSelection)
                        },
                        onCloudCheckCancel: {
                            // No-op. Kept to show explicit Cancel row in menu.
                        },
                        onSelect: {
                            if viewModel.isSelectionMode { viewModel.exitSelectionMode() } else { viewModel.startSelectionMode() }
                        }
                    )
                    .padding(.top, 50) // Space for status bar and dynamic island

                    // Row 2: Albums & Filter
                    AlbumChipsRow(
                        selectedAlbum: $viewModel.selectedAlbum,
                        albums: viewModel.dbAlbumsForChips,
                        selectedFilter: $viewModel.selectedFilter
                    )
                    .environmentObject(viewModel)

                    // Row 3: Media Type Tabs
                    MediaTypeTabsRow(
                        selectedMediaType: $viewModel.selectedMediaType,
                        allCount: viewModel.allMediaCount,
                        photoCount: viewModel.photoCount,
                        videoCount: viewModel.videoCount
                    )

                    // Active Filter Bar (if any filter is active)
                    if viewModel.hasActiveFilter {
                        ActiveFilterBar()
                            .environmentObject(viewModel)
                    }
                }
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ViewHeightPreferenceKey.self, value: geo.size.height)
                    }
                )
                .onPreferenceChange(ViewHeightPreferenceKey.self) { h in
                    if abs(headerHeight - h) > 0.5 { headerHeight = h }
                }
                .offset(y: showHeaders ? 0 : -headerHeight)
                .animation(.easeOut(duration: 0.18), value: showHeaders)
            }
        }
        
        // Overlay for Selection Action Bar at the bottom
        .overlay(alignment: .bottom) {
            // Show the action bar only while in explicit selection mode.
            // When the user taps "Cancel" in the app bar, `isSelectionMode`
            // becomes false and the bar (and its Actions menu) disappears.
            if viewModel.isSelectionMode {
                SelectionActionBar(
                    selectedCount: viewModel.selectedPhotos.count,
                    isSelectionMode: viewModel.isSelectionMode,
                    onSwapSelection: {
                        viewModel.swapSelection()
                    },
                    onShowSelected: {
                        showingSelectedPhotosView = true
                    },
                    onActions: {
                        showingActionMenu = true
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(
                    .easeInOut(duration: 0.3),
                    value: viewModel.isSelectionMode
                )
            }
        }
        .searchable(text: $viewModel.searchText, isPresented: $showingSearch, prompt: "Search photos...")
        .alert("Permission Required", isPresented: $viewModel.showingPermissionAlert) {
            Button("Settings") {
                openAppSettings()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("OpenPhotos needs access to your photo library to organize and clean up your photos.")
        }
        .background(Color(.systemBackground))
        .edgesIgnoringSafeArea(.top)
        .alert("Delete Photos", isPresented: $showingDeleteAlert) {
            Button("Delete", role: .destructive) {
                viewModel.deleteSelectedPhotos()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Are you sure you want to delete \(viewModel.selectedPhotos.count) photo(s)? This action cannot be undone.")
        }
        .fullScreenCover(isPresented: $showingSelectedPhotosView) {
            SelectedPhotosView()
                .environmentObject(viewModel)
                .environmentObject(auth)
        }
        .confirmationDialog("Actions", isPresented: $showingActionMenu) {
            // Sync selected photos to the server (formerly "Send")
            if !viewModel.selectedPhotos.isEmpty {
                Button("Sync") {
                    let assets = Array(viewModel.selectedPhotos)
                    if assets.isEmpty { return }
                    if !auth.isAuthenticated {
                        showingLogin = true
                        return
                    }
                    viewModel.syncSelectedAssets(assets, source: "photos-actions-menu")
                    showingUploadsView = true
                    // After performing an action: cancel selection and reload
                    viewModel.exitSelectionMode()
                    viewModel.refreshPhotos()
                }
                Button("Add to Album") {
                    addToAlbumSelectedId = nil
                    showingAddToAlbumPicker = true
                }
            }
            Button("Select All") {
                viewModel.selectAllPhotos()
            }
            Button("Deselect All") {
                viewModel.deselectAll()
            }
            Button("Delete", role: .destructive) {
                showingDeleteAlert = true
            }
            Button("Cancel", role: .cancel) { }
        }
        .alert("Stop Cloud Check?", isPresented: $showingStopCloudCheckConfirm) {
            Button("Stop", role: .destructive) {
                viewModel.stopCloudCheck()
            }
            Button("Continue", role: .cancel) { }
        } message: {
            Text("Cloud check is still running. Do you want to stop checking now?")
        }
        .sheet(isPresented: $showingUploadsView) {
            UploadsView()
        }
        .sheet(isPresented: $showingLogin) {
            LoginView().environmentObject(auth)
        }
        .sheet(isPresented: $showingAddToAlbumPicker) {
            AlbumTreeView(
                isPresented: $showingAddToAlbumPicker,
                selectedAlbumId: $addToAlbumSelectedId,
                pickerOnly: true,
                onAlbumSelected: { albumId in
                    viewModel.addSelectedPhotosToAlbum(albumId: albumId)
                }
            )
            .environmentObject(viewModel)
        }
        .onAppear {
            if !didInitialLoad {
                didInitialLoad = true
                viewModel.refreshPhotos()
            } else {
                viewModel.loadDbAlbums()
            }
            showHeaders = true
            lastOffset = 0
            isTrackingScroll = false
        }
        .fullScreenCover(isPresented: $viewModel.showingFullScreenViewer) {
            FullScreenPhotoView(
                assets: viewModel.filteredMedia,
                initialIndex: viewModel.fullScreenViewerIndex,
                onShowSelected: {
                    // Open the selected collection view after exiting full screen
                    showingSelectedPhotosView = true
                }
            )
            .environmentObject(viewModel)
        }
        .sheet(isPresented: $viewModel.showingTimeRangeDialog) {
            TimeRangeDialog()
                .environmentObject(viewModel)
                .presentationDetents([.medium])
                .presentationDragIndicator(.hidden)
        }
        // Sync quick button removed (dedicated sync page exists)
    }
    
    private func openAppSettings() {
        if let settingsUrl = AppSettings.url {
            openURL(settingsUrl)
        }
    }

    // MARK: - Scroll handling
    private func handleScroll(_ y: CGFloat) {
        // y is minY in the grid's named coordinate space; starts at 0, goes negative when scrolling down
        if !isTrackingScroll { isTrackingScroll = true; lastOffset = y; dirAccum = 0; lastDir = 0; return }
        let delta = y - lastOffset
        lastOffset = y

        // Always show near top
        if y > -10 { if !showHeaders { withAnimation(.easeOut(duration: 0.18)) { showHeaders = true } }; dirAccum = 0; lastDir = 0; return }
        // Ignore tiny jitter
        if abs(delta) < 0.5 { return }

        // Direction: down when delta < 0, up when delta > 0
        let dir = (delta > 0) ? 1 : -1
        if dir != lastDir { dirAccum = 0; lastDir = dir }
        dirAccum += abs(delta)

        // Hysteresis: require more movement to hide than to show
        let hideThreshold: CGFloat = 18
        let showThreshold: CGFloat = 12

        if dir < 0 {
            // Scrolling down (away from top): hide after enough movement
            if showHeaders && dirAccum >= hideThreshold {
                withAnimation(.easeOut(duration: 0.18)) { showHeaders = false }
                dirAccum = 0
            }
        } else {
            // Scrolling up (toward top): show after enough movement
            if !showHeaders && dirAccum >= showThreshold {
                withAnimation(.easeOut(duration: 0.18)) { showHeaders = true }
                dirAccum = 0
            }
        }
    }
}

struct EmptyStateView: View {
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 20) {
                Spacer()
                
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 80))
                    .foregroundColor(.secondary)
                
                Text("No Photos")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text("Your photo library appears to be empty or OpenPhotos doesn't have access to your photos.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                
                Spacer()
            }
            .frame(width: geometry.size.width)
            .padding()
        }
    }
}

struct LoadingView: View {
    var body: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
            
            Text("Loading Photos...")
                .font(.headline)
                .foregroundColor(.secondary)
        }
    }
}

struct PermissionRequestView: View {
    @Environment(\.openURL) private var openURL
    var body: some View {
        VStack(spacing: 30) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 80))
                .foregroundColor(.blue)
            
            VStack(spacing: 16) {
                Text("Photo Access Required")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text("OpenPhotos needs access to your photo library to organize and clean up your photos.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            
            VStack(spacing: 16) {
                Button("Request Photo Access") {
                    PhotoService.shared.requestPermissions()
                }
                .buttonStyle(.borderedProminent)
                .font(.headline)
                
                Button("Open Settings") {
                    openAppSettings()
                }
                .buttonStyle(.bordered)
                .font(.subheadline)
                
                Text("Note: You need to add NSPhotoLibraryUsageDescription to Info.plist in Xcode first, or the app will crash when requesting permission.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
    }
    
    private func openAppSettings() {
        if let settingsUrl = AppSettings.url {
            openURL(settingsUrl)
        }
    }
}

// MARK: - Selection Action Bar

struct SelectionActionBar: View {
    let selectedCount: Int
    let isSelectionMode: Bool
    let onSwapSelection: () -> Void
    let onShowSelected: () -> Void
    let onActions: () -> Void
    
    var body: some View {
        HStack(spacing: 0) {
            Spacer()
            
            // Single Actions menu button (centered). Users can perform
            // all selection actions from this menu, keeping the bar
            // visually simple and aligned with the requested design.
            Button(action: onActions) {
                HStack(spacing: 4) {
                    Text("Actions")
                        .font(.system(size: 16, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(.blue)
            }
            .padding(.horizontal, 16)
            
            Spacer()
        }
        .padding(.vertical, 12)
        .background(
            Rectangle()
                .fill(Color(.systemBackground))
                .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: -2)
        )
    }
}

// MARK: - Selected Photos View

struct SelectedPhotosView: View {
    @EnvironmentObject var viewModel: GalleryViewModel
    @EnvironmentObject var auth: AuthManager
    @Environment(\.dismiss) var dismiss
    
    @State private var showingDeleteAlert = false
    @State private var showingUploadsView = false
    @State private var showingLogin = false
    @State private var showingAddToAlbumPicker = false
    @State private var addToAlbumSelectedId: Int64? = nil
    @State private var showingShareSheet = false
    @State private var shareSheetItems: [Any] = []
    
    private let spacing: CGFloat = 2
    private var selectedShareItems: [SharedAsset] {
        Array(viewModel.selectedPhotos).map { SharedAsset(asset: $0) }
    }
    
    var body: some View {
        NavigationView {
            SelectedAssetsGrid(assets: Array(viewModel.selectedPhotos), spacing: spacing)
            .navigationTitle("Selected (\(viewModel.selectedPhotos.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Back") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button("Send") {
                            let assets = Array(viewModel.selectedPhotos)
                            if assets.isEmpty { return }
                            if !auth.isAuthenticated {
                                showingLogin = true
                            } else {
                                viewModel.syncSelectedAssets(assets, source: "photos-selected-view")
                                showingUploadsView = true
                            }
                        }
                        Button("Add to Album") {
                            addToAlbumSelectedId = nil
                            showingAddToAlbumPicker = true
                        }
                        Button("Delete", role: .destructive) {
                            showingDeleteAlert = true
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("Actions")
                            Image(systemName: "chevron.down")
                                .font(.system(size: 12, weight: .medium))
                        }
                    }
                    .disabled(viewModel.selectedPhotos.isEmpty)
                }
            }
        }
        .sheet(isPresented: $showingUploadsView) {
            UploadsView()
        }
        .sheet(isPresented: $showingLogin) {
            LoginView().environmentObject(auth)
        }
        .sheet(isPresented: $showingAddToAlbumPicker) {
            AlbumTreeView(
                isPresented: $showingAddToAlbumPicker,
                selectedAlbumId: $addToAlbumSelectedId,
                pickerOnly: true,
                onAlbumSelected: { albumId in
                    viewModel.addSelectedPhotosToAlbum(albumId: albumId) { ok in
                        if ok {
                            dismiss()
                        }
                    }
                }
            )
            .environmentObject(viewModel)
        }
        .sheet(isPresented: $showingShareSheet) {
            ShareSheet(items: shareSheetItems)
        }
        .alert("Delete Photos", isPresented: $showingDeleteAlert) {
            Button("Delete", role: .destructive) {
                viewModel.deleteSelectedPhotos()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Are you sure you want to delete \(viewModel.selectedPhotos.count) photo(s)? This action cannot be undone.")
        }
    }
}

// MARK: - Utilities

private struct SelectedAssetsGrid: View {
    let assets: [PHAsset]
    let spacing: CGFloat

    var body: some View {
        GeometryReader { geometry in
            let itemWidth = (geometry.size.width - (spacing * 4)) / 3
            let columns: [GridItem] = Array(repeating: GridItem(.fixed(itemWidth), spacing: spacing), count: 3)

            ScrollView {
                LazyVGrid(columns: columns, spacing: spacing) {
                    ForEach(assets, id: \.localIdentifier) { asset in
                        SelectedPhotoThumbnail(asset: asset, cellSize: itemWidth)
                    }
                }
                .padding(.horizontal, spacing)
            }
        }
    }
}

struct SelectedPhotoThumbnail: View {
    let asset: PHAsset
    let cellSize: CGFloat
    @State private var thumbnail: UIImage?
    @EnvironmentObject var viewModel: GalleryViewModel
    
    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(.systemGray5))
            
            if let thumbnail = thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: cellSize, height: cellSize)
                    .clipped()
            } else {
                ProgressView()
                    .scaleEffect(0.7)
            }
        }
        .frame(width: cellSize, height: cellSize)
        .overlay(alignment: .topTrailing) {
            // Close button to remove from selection
            Button(action: { viewModel.deselect(photo: asset) }) {
                ZStack {
                    Circle()
                        .fill(Color.black.opacity(0.6))
                        .frame(width: 24, height: 24)
                    Image(systemName: "xmark")
                        .foregroundColor(.white)
                        .font(.system(size: 12, weight: .bold))
                }
            }
            .padding(6)
        }
        .onAppear {
            loadThumbnail()
        }
    }
    
    private func loadThumbnail() {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        
        let targetSize = CGSize(width: cellSize * 2, height: cellSize * 2)
        
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        ) { image, _ in
            DispatchQueue.main.async {
                self.thumbnail = image
            }
        }
    }
}

// MARK: - Custom Gallery Components

struct GalleryAppBar: View {
    let isSelectionMode: Bool
    let isCloudCheckRunning: Bool
    @Binding var showingSearch: Bool
    let currentSortOption: SortOption
    let currentLayout: LayoutOption
    let showLayoutToggle: Bool
    let onSearch: () -> Void
    let onSlideshow: () -> Void
    let onSort: (SortOption) -> Void
    let onLayoutChange: (LayoutOption) -> Void
    let onCloudCheck: () -> Void
    let onCloudCheckAll: () -> Void
    let onCloudCheckCurrentSelection: () -> Void
    let onCloudCheckCancel: () -> Void
    let onSelect: () -> Void
    
    var body: some View {
        HStack(spacing: 16) {
            Menu {
                ForEach(SortOption.allCases, id: \.self) { option in
                    Button {
                        onSort(option)
                    } label: {
                        HStack {
                            Text(option.displayName)
                            if currentSortOption == option {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.title3)
                    .foregroundColor(.primary)
            }
            
            if showLayoutToggle {
                Picker("Layout", selection: Binding(get: { currentLayout }, set: { onLayoutChange($0) })) {
                    Text(LayoutOption.grid.displayName).tag(LayoutOption.grid)
                    Text(LayoutOption.timeline.displayName).tag(LayoutOption.timeline)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
            }
            
            Spacer()

            if isCloudCheckRunning {
                Button(action: onCloudCheck) {
                    ProgressView()
                        .scaleEffect(0.85)
                }
                .accessibilityLabel("Cloud check running. Tap to stop")
            } else {
                Menu {
                    Button("Check all photos", action: onCloudCheckAll)
                    Button("Check Current Selection", action: onCloudCheckCurrentSelection)
                    Button("Cancel", action: onCloudCheckCancel)
                } label: {
                    Image(systemName: "cloud")
                        .font(.title3)
                        .foregroundColor(.primary)
                }
                .accessibilityLabel("Check Cloud Backup")
            }

            Button(action: onSelect) {
                Text(isSelectionMode ? "Cancel" : "Select")
                    .font(.headline)
                    .foregroundColor(isSelectionMode ? .red : .blue)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(Color(.systemBackground))
    }
}

// Simple outlined pine tree icon drawn with SwiftUI to match the web client's style
struct PineTreeIcon: View {
    var lineWidth: CGFloat = 1.0
    
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let cx = w / 2.0
            
            Path { path in
                // Top triangle
                path.move(to: CGPoint(x: cx, y: h * 0.08))
                path.addLine(to: CGPoint(x: cx - w * 0.22, y: h * 0.08 + h * 0.22))
                path.addLine(to: CGPoint(x: cx + w * 0.22, y: h * 0.08 + h * 0.22))
                path.closeSubpath()
                
                // Middle triangle
                path.move(to: CGPoint(x: cx, y: h * 0.30))
                path.addLine(to: CGPoint(x: cx - w * 0.30, y: h * 0.30 + h * 0.24))
                path.addLine(to: CGPoint(x: cx + w * 0.30, y: h * 0.30 + h * 0.24))
                path.closeSubpath()
                
                // Bottom triangle
                path.move(to: CGPoint(x: cx, y: h * 0.52))
                path.addLine(to: CGPoint(x: cx - w * 0.40, y: h * 0.52 + h * 0.24))
                path.addLine(to: CGPoint(x: cx + w * 0.40, y: h * 0.52 + h * 0.24))
                path.closeSubpath()
                
                // Trunk (rounded rectangle)
                let trunkW = w * 0.18
                let trunkH = h * 0.20
                let trunkRect = CGRect(x: cx - trunkW/2, y: h * 0.76, width: trunkW, height: trunkH)
                path.addRoundedRect(in: trunkRect, cornerSize: CGSize(width: trunkW * 0.25, height: trunkW * 0.25))
            }
            .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
    }
}

struct AlbumChipsRow: View {
    @Binding var selectedAlbum: String?
    let albums: [Album]
    @Binding var selectedFilter: FilterType?
    @EnvironmentObject var viewModel: GalleryViewModel
    @State private var showingAlbumTree = false
    @State private var selectedAlbumId: Int64?
    
    var body: some View {
        HStack(spacing: 0) {
            // Tree button
            Button {
                showingAlbumTree = true
            } label: {
                PineTreeIcon()
                    .frame(width: 22, height: 22)
                    .foregroundColor(.primary)
                    .padding(.leading, 16)
                    .padding(.trailing, 8)
                    .accessibilityLabel("Album Tree")
            }
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // Favorites first, icon-only
                    AlbumChip(
                        title: "Favorites",
                        count: viewModel.favoritesCount,
                        isSelected: viewModel.showFavoritesOnly,
                        action: {
                            viewModel.showFavoritesOnly.toggle()
                        }
                    )

                    // Lock chip removed from album row in Gallery tab
                    
                    // Build a quick map for parent name lookup
                    let nameById: [Int64: String] = Dictionary(uniqueKeysWithValues: albums.map { ($0.id, $0.name) })
                    ForEach(albums, id: \.id) { album in
                        // Use parentName.albumName for non-root albums
                        let parentName = album.parentId.flatMap { nameById[$0] }
                        let displayTitle = parentName != nil ? "\(parentName!).\(album.name)" : album.name
                        AlbumChip(
                            title: displayTitle,
                            count: album.photoCount,
                            isSelected: viewModel.selectedAlbumIds.contains(album.id),
                            action: {
                            // Toggling album selection (multi-select with AND semantics)
                            viewModel.toggleAlbumSelection(album.id)
                            }
                        )
                    }
                }
                .padding(.horizontal, 8)
            }
            
            Menu {
                ForEach(FilterType.allCases, id: \.self) { filter in
                    Button {
                        if filter == .timeRange {
                            // Show time range dialog
                            viewModel.showingTimeRangeDialog = true
                        } else {
                            // Toggle other filters
                            selectedFilter = selectedFilter == filter ? nil : filter
                        }
                    } label: {
                        HStack {
                            Text(filter.displayName)
                            if selectedFilter == filter {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.title3)
                    .foregroundColor(.primary)
                    .padding(.trailing, 16)
            }
        }
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
        .sheet(isPresented: $showingAlbumTree) {
            AlbumTreeView(
                isPresented: $showingAlbumTree,
                selectedAlbumId: $selectedAlbumId,
                onAlbumSelected: { albumId in
                    // Toggle into the multi-select model; do not alter Favorites
                    viewModel.toggleAlbumSelection(albumId)
                },
                onAlbumsChanged: {
                    // Reload DB-backed albums so chips update
                    viewModel.loadDbAlbums()
                },
                onAlbumCreated: { newAlbumId in
                    viewModel.recentlyCreatedAlbumId = newAlbumId
                }
            )
            .environmentObject(viewModel)
        }
    }
}

struct AlbumChip: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if title == "Favorites" {
                    // Favorites chip: icon only
                    Image(systemName: "heart.fill")
                        .font(.subheadline)
                        .foregroundColor(.red)
                } else {
                    // Other albums: text only, no leading icon, no count
                    Text(title)
                        .font(.subheadline)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(isSelected ? Color.blue.opacity(0.2) : Color(.systemGray6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct MediaTypeTabsRow: View {
    @Binding var selectedMediaType: MediaType
    let allCount: Int
    let photoCount: Int
    let videoCount: Int
    
    var body: some View {
        HStack(spacing: 0) {
            MediaTypeTab(
                title: "All",
                count: allCount,
                isSelected: selectedMediaType == .all,
                action: { selectedMediaType = .all }
            )
            
            MediaTypeTab(
                title: "Photos",
                count: photoCount,
                isSelected: selectedMediaType == .photos,
                action: { selectedMediaType = .photos }
            )
            
            MediaTypeTab(
                title: "Videos",
                count: videoCount,
                isSelected: selectedMediaType == .videos,
                action: { selectedMediaType = .videos }
            )
            
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
    }
}

struct MediaTypeTab: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text("\(title) (\(count))")
                .font(.subheadline)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundColor(isSelected ? .blue : .secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isSelected ? Color.blue.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct EnhancedPhotoGridView: View {
    @EnvironmentObject var viewModel: GalleryViewModel
    var onScrollOffsetChange: ((CGFloat) -> Void)? = nil
    var topInset: CGFloat = 0
    
    private let spacing: CGFloat = 2
    
    private let columns: [GridItem] = Array(repeating: GridItem(.flexible(minimum: 70, maximum: 250), spacing: 2), count: 4)
    
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Top probe to track scroll offset within the named coordinate space
                GeometryReader { geo in
                    Color.clear.preference(key: ScrollOffsetPreferenceKey.self, value: geo.frame(in: .named("LocalGridScroll")).minY)
                }
                .frame(height: 0)

                // Spacer equal to header height so content starts below the overlaid bars
                Color.clear.frame(height: max(0, topInset))

                let filteredAssets = viewModel.filteredMedia
                LazyVGrid(columns: columns, spacing: spacing) {
                ForEach(filteredAssets, id: \.localIdentifier) { asset in
                    let columnsCount: CGFloat = 4
                    let totalSpacing = spacing * (columnsCount - 1) + spacing * 2 // inter-item + outer padding
                    let size = ((UIScreen.main.bounds.width - totalSpacing) / columnsCount).rounded(.down)
                    MediaThumbnailView(
                        asset: asset,
                        cellSize: size
                    )
                    .environmentObject(viewModel)
                }
                }
                .padding(.horizontal, spacing)
            // Reserve space for the bottom action bar as soon as selection mode starts
            // to avoid layout shifts during the first tap selection.
            .padding(
                .bottom,
                (viewModel.isSelectionMode || !viewModel.selectedPhotos.isEmpty) ? 80 : 0
            )
            }
        }
        .coordinateSpace(name: "LocalGridScroll")
        .onPreferenceChange(ScrollOffsetPreferenceKey.self) { y in
            onScrollOffsetChange?(y)
        }
    }
}

struct MediaThumbnailView: View {
    let asset: PHAsset
    let cellSize: CGFloat
    @EnvironmentObject var viewModel: GalleryViewModel
    @State private var thumbnail: UIImage?
    
    var body: some View {
        let isSelected = viewModel.selectedPhotos.contains(asset)
        ZStack {
            // Background color to ensure consistent cell bounds
            Color(.systemGray5)

            // Image content clipped to square cell
            if let thumbnail = thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: cellSize, height: cellSize)
                    .clipped()
            } else {
                ProgressView().scaleEffect(0.7)
            }

        }
        .frame(width: cellSize, height: cellSize)
        // Ensure the whole square responds to taps (not just visible content)
        .contentShape(Rectangle())
        // Lock override badge pinned to top‑left
        .overlay(alignment: .topLeading) {
            if let o = viewModel.lockOverride(forLocalIdentifier: asset.localIdentifier) {
                ZStack {
                    Circle().fill(Color.black.opacity(0.4))
                    Image(systemName: o ? "lock.fill" : "lock.open")
                        .foregroundColor(.white)
                        .font(.system(size: 12, weight: .medium))
                }
                .frame(width: 22, height: 22)
                .padding(6)
                .allowsHitTesting(false)
            }
        }
        // Selection indicator pinned to top‑right, consistently padded
        .overlay(alignment: .topTrailing) {
            if viewModel.isSelectionMode {
                ZStack {
                    Circle()
                        .fill(isSelected ? Color.white : Color.black.opacity(0.35))
                        .frame(width: 26, height: 26)
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(isSelected ? .blue : .white)
                        .font(.system(size: 18, weight: .semibold))
                }
                .padding(6)
                .allowsHitTesting(false)
            }
        }
        // Video duration badge pinned to bottom‑right
        .overlay(alignment: .bottomTrailing) {
            VStack(alignment: .trailing, spacing: 4) {
                if viewModel.isCloudBackedUp(localIdentifier: asset.localIdentifier) {
                    ZStack {
                        Circle().fill(Color.black.opacity(0.35))
                        Image(systemName: "cloud.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .frame(width: 22, height: 22)
                    .allowsHitTesting(false)
                }
                if asset.mediaType == .video {
                    Text(formatDuration(asset.duration))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.black.opacity(0.8))
                        )
                        .allowsHitTesting(false)
                }
            }
            .padding(5)
        }
        .onAppear {
            loadThumbnail()
        }
        .onTapGesture {
            if viewModel.isSelectionMode {
                viewModel.toggleSelection(for: asset)
            } else {
                viewModel.openFullScreenViewer(for: asset)
            }
        }
    }
    
    private func loadThumbnail() {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        
        let targetSize = CGSize(width: cellSize * 2, height: cellSize * 2)
        
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        ) { image, _ in
            DispatchQueue.main.async {
                self.thumbnail = image
            }
        }
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        // Handle invalid or very small duration values
        guard duration.isFinite && duration > 0 else {
            return "0:00"
        }
        
        let totalSeconds = Int(duration)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        
        // Always format as M:SS to ensure consistent width
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// Filter chip component
struct FilterChip: View {
    let label: String
    let onRemove: () -> Void
    
    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(.blue)
            
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.blue)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 15)
                .fill(Color.blue.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 15)
                        .stroke(Color.blue.opacity(0.3), lineWidth: 0.5)
                )
        )
    }
}

struct ActiveFilterBar: View {
    @EnvironmentObject var viewModel: GalleryViewModel
    
    private var activeFilters: [(id: String, label: String, action: () -> Void)] {
        var filters: [(id: String, label: String, action: () -> Void)] = []
        
        // Add album filters (from DB) — multiple supported
        if !viewModel.selectedAlbumIds.isEmpty {
            let byId = Dictionary(uniqueKeysWithValues: viewModel.dbAlbums.map { ($0.id, $0) })
            for id in viewModel.selectedAlbumIds {
                if let album = byId[id] {
                    let parentName = album.parentId.flatMap { pid in byId[pid]?.name }
                    let label = parentName != nil ? "\(parentName!).\(album.name)" : album.name
                    filters.append((
                        id: "album_\(id)",
                        label: label,
                        action: { viewModel.toggleAlbumSelection(id) }
                    ))
                }
            }
        } else if let albumName = viewModel.selectedAlbum {
            // Fallback for legacy/system selections (e.g., Favorites)
            let label = albumName
            filters.append((
                id: "album_fav",
                label: label,
                action: {
                    viewModel.selectedAlbum = nil
                    viewModel.selectedAlbumId = nil
                    viewModel.photos = viewModel.allPhotos
                }
            ))
        }
        
        // Add filter type
        if let filter = viewModel.selectedFilter {
            let label: String
            switch filter {
            case .screenshots:
                label = "Screenshots"
            case .livePhotos:
                label = "Live Photos"
            case .timeRange:
                label = viewModel.selectedTimeRange.displayName
            case .missingInCloud:
                label = "Missing in Cloud"
            }
            filters.append((
                id: "filter",
                label: label,
                action: { viewModel.selectedFilter = nil }
            ))
        }
        
        // Favorites filter
        if viewModel.showFavoritesOnly {
            filters.append((
                id: "favorites",
                label: "Favorites",
                action: { viewModel.showFavoritesOnly = false }
            ))
        }

        // Locked filter
        if viewModel.showLockedOnly {
            filters.append((
                id: "locked",
                label: "Locked",
                action: { viewModel.showLockedOnly = false }
            ))
        }
        
        // Add sort info
        if viewModel.sortOption != .dateNewest {
            filters.append((
                id: "sort",
                label: viewModel.sortOption.displayName,
                action: { viewModel.sortOption = .dateNewest }
            ))
        }
        
        return filters
    }
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 18))
                .foregroundColor(.blue)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(activeFilters, id: \.id) { filter in
                        FilterChip(
                            label: filter.label,
                            onRemove: filter.action
                        )
                    }
                    // Sub‑albums toggle removed from bar; configured in Album Tree
                }
            }
            
            Spacer()
            
            Button(action: {
                viewModel.clearAllFilters()
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.blue)
                    .padding(6)
                    .background(
                        Circle()
                            .fill(Color.blue.opacity(0.1))
                    )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Color.blue.opacity(0.05)
        )
    }
}

#Preview {
    GalleryView()
        .environmentObject(GalleryViewModel())
}
