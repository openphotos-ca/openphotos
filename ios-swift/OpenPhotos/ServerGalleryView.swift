import SwiftUI

// Server-backed Photos tab view. Mirrors the layout of the local Gallery with server data.
struct ServerGalleryView: View {
    @StateObject var viewModel = ServerGalleryViewModel()
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var unlockCtl: E2EEUnlockController
    @Environment(\.scenePhase) private var scenePhase

    @State private var showingSearch = false
    @FocusState private var searchFieldFocused: Bool
    @State private var showingActions = false
    @State private var showAlbumPicker = false
    @State private var albumPickerSelectedId: Int? = nil
    @State private var albumPickerRemoveMode: Bool = false
    @State private var showMetadataSheet = false
    @State private var editCaption: String = ""
    @State private var editDescription: String = ""
    @State private var showAlbumManager = false
    @State private var showAlbumTree = false
    @State private var albumTreeSelectedId: Int? = nil
    @State private var showLogin: Bool = false
    @State private var showFilters: Bool = false
    @State private var showReindexConfirmation: Bool = false
    // Header collapse on scroll
    @State private var showHeaders: Bool = true
    @State private var lastOffset: CGFloat = 0
    @State private var isTrackingScroll: Bool = false
    @State private var headerHeight: CGFloat = 0
    // Direction-aware accumulation to make header toggling reliable on iPhone
    @State private var dirAccum: CGFloat = 0
    @State private var lastDir: Int = 0 // 1 = down, -1 = up, 0 = unknown

    // Full-screen viewer state
    private struct SelectedViewer: Identifiable { let id: String }
    @State private var selectedViewer: SelectedViewer? = nil
    @State private var viewerIndex: Int = 0

    // Slideshow state
    @State private var showSlideshow: Bool = false

    // Team Management state (Enterprise Edition)
    @State private var showTeamManagement: Bool = false
    // Manage Faces state
    @State private var showManageFaces: Bool = false
    @State private var isEnterpriseEdition: Bool = false
    @State private var didInitialLoad: Bool = false

    // Sharing state (Enterprise Edition)
    @State private var showSharing: Bool = false
    @State private var showCreateShare: Bool = false
    @State private var shareContext: ShareContext?
    @State private var shareError: String? = nil
    @State private var showShareError: Bool = false
    @State private var isPreparingShare: Bool = false

    // Similar Media state
    @State private var showSimilarMedia: Bool = false
    @StateObject private var similarMediaViewModel = SimilarMediaViewModel()
    // Cloud Backup Check is triggered from the local Photos tab (not from Cloud tab).

    // New share sheet state
    // Share sheet context - using item-based sheet presentation for proper state management
    @State private var shareAlbumContext: ShareAlbumContext? = nil

    // Share album context for sheet presentation
    struct ShareAlbumContext: Identifiable {
        let id: Int
        let name: String?
        let isLive: Bool
    }

    private let columns: [GridItem] = Array(repeating: GridItem(.flexible(minimum: 70, maximum: 250), spacing: 2), count: 4)

    private func refreshCapabilities(force: Bool = false) async {
        guard auth.isAuthenticated else {
            await MainActor.run { isEnterpriseEdition = false }
            return
        }
        do {
            let caps = try await CapabilitiesService.shared.get(force: force)
            await MainActor.run { isEnterpriseEdition = caps.ee ?? false }
        } catch {
            await MainActor.run { isEnterpriseEdition = false }
        }
    }

    var body: some View {
        mainContent
            .safeAreaInset(edge: .bottom) {
                if viewModel.isSelectionMode || !viewModel.selected.isEmpty { selectionBar }
            }
            .sheet(isPresented: $showAlbumPicker) { albumPicker }
            .sheet(isPresented: $showMetadataSheet) { metadataEditor }
            .sheet(isPresented: $showAlbumManager) {
                ServerAlbumManagerView(
                    isPresented: $showAlbumManager,
                    albums: viewModel.albums,
                    refresh: { Task { viewModel.onAppear() } },
                    liveCriteria: criteriaFromCurrentState()
                )
            }
            .sheet(isPresented: $showAlbumTree) { albumTreeSheet }
            .fullScreenCover(isPresented: $showFilters) {
                ServerFiltersSheet(isPresented: $showFilters)
                    .environmentObject(viewModel)
            }
            .onAppear {
                showHeaders = true
                lastOffset = 0
                isTrackingScroll = false
                if auth.isAuthenticated, !didInitialLoad {
                    didInitialLoad = true
                    viewModel.onAppear()
                } else if !auth.isAuthenticated {
                    didInitialLoad = false
                }
            }
            .onChange(of: auth.isAuthenticated) { isAuthed in
                if isAuthed {
                    didInitialLoad = true
                    viewModel.onAppear()
                    Task { await refreshCapabilities(force: true) }
                } else {
                    didInitialLoad = false
                    isEnterpriseEdition = false
                    CapabilitiesService.shared.invalidate()
                }
            }
            .onChange(of: auth.serverURL) { _ in
                CapabilitiesService.shared.invalidate()
                Task { await refreshCapabilities(force: true) }
            }
            .onChange(of: scenePhase) { phase in
                if phase == .active {
                    Task { await refreshCapabilities(force: true) }
                }
            }
            .onChange(of: showAlbumTree) { presented in
                // After dismissing album selection/creation, ensure the header (and album/filter chips)
                // is visible even when the chosen album has zero photos.
                if !presented { revealHeader() }
            }
            .onChange(of: viewModel.photos.count) { n in
                // If the result set is empty, force the header visible; otherwise the user can get stuck
                // with the filter header hidden (no scroll content to reveal it).
                if n == 0 { revealHeader() }
            }
            .task {
                await refreshCapabilities(force: true)
            }
            .sheet(isPresented: $showLogin) { LoginView().environmentObject(auth) }
            .edgesIgnoringSafeArea(.top)
            .onReceive(NotificationCenter.default.publisher(for: .authUnauthorized)) { _ in
                showLogin = true
            }
            .fullScreenCover(item: $selectedViewer) { sel in
                let start = viewModel.photos.firstIndex(where: { $0.asset_id == sel.id }) ?? 0
                ServerFullScreenViewer(
                    photos: viewModel.photos,
                    index: start,
                    onRequestNextPage: {
                        let before = viewModel.photos.count
                        await viewModel.loadNextPageIfNeeded()
                        let after = viewModel.photos.count
                        if after > before { return Array(viewModel.photos.suffix(after - before)) }
                        return []
                    },
                    onDismiss: { selectedViewer = nil }
                )
                .id(sel.id)
            }
            .fullScreenCover(isPresented: $showSlideshow) {
                SlideshowView(
                    photos: viewModel.photos,
                    startIndex: 0,
                    onDismiss: { showSlideshow = false }
                )
            }
            .fullScreenCover(isPresented: $showTeamManagement) {
                TeamManagementView(isPresented: $showTeamManagement)
                    .environmentObject(auth)
            }
            .fullScreenCover(isPresented: $showSimilarMedia) {
                SimilarMediaView(viewModel: similarMediaViewModel)
            }
            .fullScreenCover(isPresented: $showManageFaces) {
                ManageFacesView()
            }
            .sheet(isPresented: $showSharing) {
                SharingView()
            }
            .sheet(isPresented: $showCreateShare) {
                if let context = shareContext {
                    CreateShareSheet(
                        objectKind: context.kind,
                        objectId: context.id,
                        objectName: context.name
                    )
                } else {
                    // This shouldn't happen, but provide fallback UI
                    VStack {
                        Text("Error: No share context available")
                            .padding()
                        Button("Close") {
                            showCreateShare = false
                        }
                    }
                }
            }
            .alert("Share Error", isPresented: $showShareError) {
                Button("OK") {
                    showShareError = false
                    shareError = nil
                }
            } message: {
                Text(shareError ?? "An error occurred while sharing")
            }
            .overlay {
                if isPreparingShare {
                    ZStack {
                        Color.black.opacity(0.5)
                            .ignoresSafeArea()

                        VStack(spacing: 16) {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
                                .scaleEffect(1.5)

                            Text("Preparing photos for sharing...")
                                .foregroundColor(.white)
                                .font(.headline)
                        }
                        .padding(40)
                        .background(Color.gray.opacity(0.9))
                        .cornerRadius(12)
                    }
                }
            }
            .sheet(item: $shareAlbumContext) { context in
                let _ = print("🔍 Sheet presenting with context - id: \(context.id), name: \(context.name ?? "nil"), isLive: \(context.isLive)")
                NewShareSheet(
                    albumId: context.id,
                    albumName: context.name,
                    isLiveAlbum: context.isLive
                )
            }
    }

    // MARK: - Main Content
    @ViewBuilder
    private var mainContent: some View {
        VStack(spacing: 0) {
            if !auth.isAuthenticated {
                VStack(spacing: 16) {
                    Image(systemName: "rectangle.and.pencil.and.ellipsis").font(.system(size: 64)).foregroundColor(.blue)
                    Text("Log in to view your Photos").font(.headline)
                    Button("Log In") { showLogin = true }.buttonStyle(.borderedProminent)
                }
                Spacer()
            } else {
                // No header content in layout; header is drawn as an overlay above.

                if viewModel.layout == .timeline, (viewModel.sortOption == .createdNewest || viewModel.sortOption == .createdOldest) {
                    ZStack {
                        ServerTimelineView(
                            photos: viewModel.photos,
                            availableYears: viewModel.yearBuckets.map { $0.year }.sorted(by: >),
                            onPickYear: { year in viewModel.jumpTimeline(toYear: year) },
                            topInset: headerInset,
                            selectionBarVisible: (viewModel.isSelectionMode || !viewModel.selected.isEmpty),
                            isSelectionMode: viewModel.isSelectionMode,
                            selected: viewModel.selected,
                            onToggleSelection: { id in viewModel.toggleSelection(assetId: id) },
                            onOpen: { p in onTileTap(p) },
                            onNearEnd: { Task { await viewModel.loadNextPageIfNeeded() } },
                            onScrollOffsetChange: { y in handleScrollContentOffset(y) },
                            onRefresh: {
                                showHeaders = true
                                await viewModel.pullToRefresh()
                            }
                        )
                        if (viewModel.isLoading || viewModel.isAutoRetryingInitialLoad) && viewModel.photos.isEmpty {
                            VStack(spacing: 20) { ProgressView().scaleEffect(1.4); Text("Loading...").foregroundColor(.secondary) }
                                .padding(.top, headerInset + 40)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                                .allowsHitTesting(false)
                        } else if viewModel.photos.isEmpty && !viewModel.isAutoRetryingInitialLoad {
                            VStack(spacing: 14) {
                                if let err = viewModel.lastInitialLoadError, !err.isEmpty {
                                    Text("Unable to load photos").foregroundColor(.secondary)
                                    Text(err)
                                        .font(.footnote)
                                        .foregroundColor(.secondary)
                                        .multilineTextAlignment(.center)
                                        .lineLimit(4)
                                } else {
                                    Text("No photos found").foregroundColor(.secondary)
                                }
                                Button("Retry") { Task { await viewModel.pullToRefresh() } }
                                    .buttonStyle(.bordered)
                            }
                            .padding(.top, headerInset + 40)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .allowsHitTesting(true)
                        }
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            // Observe UIScrollView content offset for header show/hide
                            ScrollViewOffsetSpy { pt in handleScrollContentOffset(pt.y) }
                                .frame(height: 0)

                            // Spacer equal to header height so grid starts below bars
                            Color.clear.frame(height: headerInset)

                            if viewModel.photos.isEmpty {
                                VStack(spacing: 20) {
                                    if viewModel.isLoading || viewModel.isAutoRetryingInitialLoad {
                                        ProgressView().scaleEffect(1.4)
                                        Text("Loading...").foregroundColor(.secondary)
                                    } else if let err = viewModel.lastInitialLoadError, !err.isEmpty {
                                        Text("Unable to load photos").foregroundColor(.secondary)
                                        Text(err)
                                            .font(.footnote)
                                            .foregroundColor(.secondary)
                                            .multilineTextAlignment(.center)
                                            .lineLimit(4)
                                        Button("Retry") { Task { await viewModel.pullToRefresh() } }
                                            .buttonStyle(.bordered)
                                    } else {
                                        Text("No photos found").foregroundColor(.secondary)
                                        Button("Retry") { Task { await viewModel.pullToRefresh() } }
                                            .buttonStyle(.bordered)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 40)
                            } else {
                                LazyVGrid(columns: columns, spacing: 2) {
                                    ForEach(Array(viewModel.photos.enumerated()), id: \.element.asset_id) { idx, p in
                                        let columnsCount: CGFloat = 4
                                        let spacing: CGFloat = 2
                                        let totalSpacing = spacing * (columnsCount - 1) + spacing * 2
                                        let size = ((UIScreen.main.bounds.width - totalSpacing) / columnsCount).rounded(.down)
                                        RemoteThumbnailView(photo: p, cellSize: size)
                                            .overlay(alignment: .topTrailing) {
                                                if viewModel.isSelectionMode {
                                                    let isSel = viewModel.selected.contains(p.asset_id)
                                                    ZStack {
                                                        Circle().fill(isSel ? Color.white : Color.black.opacity(0.35)).frame(width: 26, height: 26)
                                                        Image(systemName: isSel ? "checkmark.circle.fill" : "circle").foregroundColor(isSel ? .blue : .white).font(.system(size: 18, weight: .semibold))
                                                    }
                                                    .padding(6)
                                                    .allowsHitTesting(false)
                                                }
                                            }
                                            .onLongPressGesture(minimumDuration: 0.3) { viewModel.isSelectionMode = true; viewModel.toggleSelection(assetId: p.asset_id) }
                                            .onTapGesture { if viewModel.isSelectionMode { viewModel.toggleSelection(assetId: p.asset_id) } else { onTileTap(p) } }
                                            .onAppear { if idx >= viewModel.photos.count - 12 { Task { await viewModel.loadNextPageIfNeeded() } } }
                                    }
                                }
                                .padding(.horizontal, 2)
                                .padding(.bottom, (viewModel.isSelectionMode || !viewModel.selected.isEmpty) ? 80 : 0)
                            }
                        }
                    }
                    .refreshable {
                        showHeaders = true
                        await viewModel.pullToRefresh()
                    }
                    // Coordinate space and GeometryReader-based offset tracking removed to avoid
                    // conflicting signals with the UIScrollView observer that caused re‑show lag.
                }
            }
        }
        // Overlay measured header stack so it doesn't occupy layout space
        .overlay(alignment: .top) {
            VStack(spacing: 0) {
                // App bar or inline search bar (Android parity)
                if showingSearch {
                    SearchAppBar(
                        text: $viewModel.searchText,
                        isSubmitEnabled: viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2,
                        focus: $searchFieldFocused,
                        onBack: {
                            searchFieldFocused = false
                            viewModel.cancelSearch()
                            withAnimation(.easeOut(duration: 0.2)) { showingSearch = false }
                        },
                        onClear: { viewModel.searchText = "" },
                        onSubmit: {
                            let len = viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).count
                            guard len >= 2 else { return }
                            viewModel.submitSearch()
                            searchFieldFocused = false
                        }
                    )
                    .padding(.top, 50)
                    .onAppear { // Auto-focus and show keyboard
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.searchFieldFocused = true }
                    }
                } else {
                    ServerAppBar(
                        isSelectionMode: viewModel.isSelectionMode,
                        currentSort: viewModel.sortOption,
                        currentLayout: viewModel.layout,
                        showLayoutToggle: (viewModel.sortOption == .createdNewest || viewModel.sortOption == .createdOldest),
                        isEnterpriseEdition: isEnterpriseEdition,
                        isAuthenticated: auth.isAuthenticated,
                        onSearch: {
                            viewModel.searchText = ""
                            viewModel.isSearching = false
                            withAnimation(.easeOut(duration: 0.2)) { showingSearch = true }
                        },
                        onSlideshow: {
                            // Only show slideshow if there are photos to display
                            guard !viewModel.photos.isEmpty else {
                                ToastManager.shared.show("No photos to display")
                                return
                            }
                            showSlideshow = true
                        },
                        onSort: { viewModel.sortOption = $0 },
                        onLayoutChange: { viewModel.layout = $0 },
                        onSelect: { toggleSelectionMode() },
                        onTeamManagement: { showTeamManagement = true },
                        onShowSharing: { showSharing = true },
                        onShowSimilarMedia: { showSimilarMedia = true },
                        onManageFaces: { showManageFaces = true }
                    )
                    .padding(.top, 50)
                }

                // Chips + Active Filters + Media Tabs (same as main content section)
                HStack(spacing: 0) {
                    Button { showFilters = true } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle").font(.title3).foregroundColor(.primary).padding(.leading, 16).padding(.trailing, 12)
                    }
                    Button { showAlbumTree = true } label: {
                        PineTreeIcon().frame(width: 22, height: 22).foregroundColor(.primary).padding(.trailing, 8)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            AlbumChip(title: "Favorites", count: 0, isSelected: viewModel.showFavoritesOnly) { viewModel.showFavoritesOnly.toggle() }
                            Button {
                                if viewModel.showLockedOnly { viewModel.showLockedOnly = false }
                                else {
                                    if E2EEManager.shared.hasValidUMKRespectingTTL() || E2EEManager.shared.unlockWithDeviceKey(prompt: "Unlock to view locked items") { viewModel.showLockedOnly = true }
                                    else { unlockCtl.requireUnlock(reason: "Unlock to view locked items") { ok in if ok { viewModel.showLockedOnly = true } } }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: viewModel.showLockedOnly ? "lock.circle.fill" : "lock.circle").font(.subheadline).foregroundColor(viewModel.showLockedOnly ? .blue : .secondary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 16).fill(viewModel.showLockedOnly ? Color.blue.opacity(0.2) : Color(.systemGray6)))
                                .overlay(RoundedRectangle(cornerRadius: 16).stroke(viewModel.showLockedOnly ? Color.blue : Color.clear, lineWidth: 1))
                                .accessibilityLabel(viewModel.showLockedOnly ? "Hide Locked" : "Show Locked")
                            }
                            .buttonStyle(PlainButtonStyle())
                            ForEach(viewModel.albums, id: \.id) { a in
                                let sel = viewModel.selectedAlbumIds.contains(a.id)
                                AlbumChip(title: a.name, count: a.photo_count, isSelected: sel) { toggleAlbumSelection(a.id, name: a.name) }
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                }
                .padding(.vertical, 8)
                .background(Color(.systemBackground))

                ActiveFilterRow(albums: viewModel.albums, onShareAlbum: { album in
                    print("🔍 Setting shareAlbumContext - id: \(album.id), name: \(album.name), isLive: \(album.is_live)")
                    // Set share context to trigger sheet presentation
                    shareAlbumContext = ShareAlbumContext(
                        id: album.id,
                        name: album.name,
                        isLive: album.is_live
                    )
                }).environmentObject(viewModel)

                HStack(spacing: 0) {
                    mediaTypeTab(title: "All", count: viewModel.mediaCounts?.all ?? 0, isSelected: viewModel.selectedMediaType == .all) { viewModel.selectedMediaType = .all }
                    mediaTypeTab(title: "Photos", count: viewModel.mediaCounts?.photos ?? 0, isSelected: viewModel.selectedMediaType == .photos) { viewModel.selectedMediaType = .photos }
                    mediaTypeTab(title: "Videos", count: viewModel.mediaCounts?.videos ?? 0, isSelected: viewModel.selectedMediaType == .videos) { viewModel.selectedMediaType = .videos }
                    mediaTypeTab(title: "Trash", count: viewModel.mediaCounts?.trash ?? 0, isSelected: viewModel.selectedMediaType == .trash) { viewModel.selectedMediaType = .trash }
                    Spacer()
                    Button {
                        showReindexConfirmation = true
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.leading, 10)
                    }
                    .disabled(viewModel.isLoading)
                    .accessibilityLabel("Refresh")
                    .buttonStyle(.plain)
                    .alert("ReIndex Photos?", isPresented: $showReindexConfirmation) {
                        Button("Cancel", role: .cancel) {}
                        Button("ReIndex") {
                            viewModel.refreshCurrentTabAndInvalidateOtherMediaTypes()
                        }
                    } message: {
                        Text("This will refresh and reindex photos for the current view.")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(.systemBackground))
            }
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: ViewHeightPreferenceKey.self, value: geo.size.height)
                }
            )
            .onPreferenceChange(ViewHeightPreferenceKey.self) { h in if abs(headerHeight - h) > 0.5 { headerHeight = h } }
            .offset(y: headerIsVisible ? 0 : -headerHeight)
            .animation(.easeOut(duration: 0.18), value: headerIsVisible)
        }
    }

    // MARK: - Subviews and Sheets
    private var selectionBar: some View {
        HStack {
            Button("Select All") { viewModel.selectAll() }
            Button("Deselect All") { viewModel.deselectAll() }
            Spacer()
            Button("Actions") { showingActions = true }
        }
        .padding()
        .background(.ultraThinMaterial)
        .confirmationDialog("Actions", isPresented: $showingActions) {
            Button("Share Selected") {
                // Dismiss the action dialog first
                showingActions = false

                // Check if we have selected items
                guard !viewModel.selected.isEmpty else {
                    shareError = "No photos selected"
                    showShareError = true
                    return
                }

                // If only one photo selected, share it directly
                if viewModel.selected.count == 1, let singleAsset = viewModel.selected.first {
                    shareContext = ShareContext(
                        kind: .asset,
                        id: singleAsset,
                        name: "Selected photo"
                    )
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        showCreateShare = true
                    }
                } else {
                    // Multiple photos selected - create an album and share it
                    Task {
                        // Show loading indicator
                        await MainActor.run {
                            isPreparingShare = true
                        }

                        do {
                            let albumName = "Shared Selection (\(viewModel.selected.count) photos)"

                            // Create a new album
                            let album = try await ServerPhotosService.shared.createAlbum(
                                name: albumName,
                                description: "Collection of \(viewModel.selected.count) photos for sharing"
                            )

                            // Add all selected photos to the album
                            try await ServerPhotosService.shared.addPhotosToAlbum(
                                albumId: album.id,
                                assetIds: Array(viewModel.selected)
                            )

                            // Now share the album containing all photos
                            await MainActor.run {
                                isPreparingShare = false
                                shareContext = ShareContext(
                                    kind: .album,
                                    id: String(album.id),
                                    name: albumName
                                )
                                showCreateShare = true
                            }
                        } catch {
                            await MainActor.run {
                                isPreparingShare = false
                                shareError = "Failed to prepare photos for sharing: \(error.localizedDescription)"
                                showShareError = true
                            }
                        }
                    }
                }
            }
            Divider()
            Button("Favorite") { Task { await bulkFavorite(true) } }
            Button("Unfavorite") { Task { await bulkFavorite(false) } }
            Button("Add to Album…") { albumPickerRemoveMode = false; showAlbumPicker = true }
            Button("Remove from Album…") { albumPickerRemoveMode = true; showAlbumPicker = true }
            Button("Lock (one-way)") { Task { await bulkLock() } }
            Button("Delete (to Trash)", role: .destructive) { Task { await bulkDelete() } }
            Button("Restore from Trash") { Task { await bulkRestore() } }
            Button("Set Rating ★★★★☆") { Task { await bulkRating(4) } }
            Button("Clear Rating") { Task { await bulkRating(nil) } }
            Button("Edit Caption/Description…") { showMetadataSheet = true }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var albumPicker: some View {
        ServerAlbumPickerSheet(isPresented: $showAlbumPicker, albums: viewModel.albums, onChoose: { id in
            albumPickerSelectedId = id
            Task { if albumPickerRemoveMode { await removeSelectedFromAlbum() } else { await addSelectedToAlbum() } }
        })
    }

    private var metadataEditor: some View {
        NavigationView {
            Form {
                Section("Caption") { TextField("Caption", text: $editCaption) }
                Section("Description") { TextField("Description", text: $editDescription, axis: .vertical).lineLimit(3...6) }
            }
            .navigationTitle("Edit Metadata")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showMetadataSheet = false } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await applyMetadata() } } }
            }
        }
    }

    // Server-backed album tree sheet (UI matches Gallery's AlbumTreeView)
    @ViewBuilder
    private var albumTreeSheet: some View {
        ServerAlbumTreeView(
            isPresented: $showAlbumTree,
            includeSubalbums: $viewModel.includeSubalbums,
            selectedAlbumId: $albumTreeSelectedId,
            onAlbumSelected: { id in
                // Toggle into multi-select model; do not alter favorites here
                toggleAlbumSelection(id)
            },
            onAlbumSelectedWithName: { id, name in
                toggleAlbumSelection(id, name: name)
            },
            onAlbumsChanged: {
                Task { viewModel.onAppear(); viewModel.refreshAll(resetPage: true) }
            }
        )
    }

    private func albumChip(title: String, count: Int, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) { Text("\(title) (\(count))").font(.subheadline).lineLimit(1) }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 16).fill(isSelected ? Color.blue.opacity(0.2) : Color(.systemGray6)))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(isSelected ? Color.blue : Color.clear, lineWidth: 1))
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func mediaTypeTab(title: String, count: Int, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("\(title) \(count)")
                .font(.caption2)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundColor(isSelected ? .blue : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .allowsTightening(true)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 16).fill(isSelected ? Color.blue.opacity(0.1) : Color.clear))
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: - Actions
    private func toggleSelectionMode() {
        // Do not allow entering selection mode while header is hidden.
        // Toggling off is always allowed.
        if !headerIsVisible && !viewModel.isSelectionMode {
            return
        }
        withAnimation { viewModel.isSelectionMode.toggle() }
    }
    private func toggleAlbumSelection(_ id: Int, name: String? = nil) {
        var next = viewModel.selectedAlbumIds
        if next.contains(id) {
            next.remove(id)
            viewModel.setSelectedAlbumNameOverride(id: id, name: nil)
        } else {
            next.insert(id)
            if let name { viewModel.setSelectedAlbumNameOverride(id: id, name: name) }
        }
        viewModel.selectedAlbumIds = next
    }
    private func onTileTap(_ p: ServerPhoto) {
        selectedViewer = SelectedViewer(id: p.asset_id)
    }
    private func bulkFavorite(_ fav: Bool) async {
        let ids = viewModel.selected
        await withTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { try? await ServerPhotosService.shared.setFavorite(assetId: id, favorite: fav) } }
        }
        await MainActor.run { viewModel.selected.removeAll(); viewModel.isSelectionMode = false }
        viewModel.refreshAll(resetPage: true)
    }
    private func bulkLock() async {
        let ids = viewModel.selected
        guard E2EEManager.shared.hasValidUMKRespectingTTL() || E2EEManager.shared.unlockWithDeviceKey(prompt: "Unlock to lock items") else {
            unlockCtl.requireUnlock(reason: "Unlock to lock items") { ok in Task { if ok { self.viewModel.refreshAll(resetPage: true) } } }
            return
        }
        await withTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { try? await ServerPhotosService.shared.lock(assetId: id) } }
        }
        await MainActor.run { viewModel.selected.removeAll(); viewModel.isSelectionMode = false }
        viewModel.refreshAll(resetPage: true)
    }
    private func bulkDelete() async {
        let ids = Array(viewModel.selected)
        try? await ServerPhotosService.shared.deletePhotos(assetIds: ids)
        await MainActor.run { viewModel.selected.removeAll(); viewModel.isSelectionMode = false }
        await MainActor.run {
            let idSet = Set(ids)
            let affected = viewModel.photos.filter { idSet.contains($0.asset_id) }
            if viewModel.selectedMediaType != .trash {
                viewModel.photos.removeAll { idSet.contains($0.asset_id) }
            }
            if let counts = viewModel.mediaCounts {
                var all = counts.all
                var photos = counts.photos
                var videos = counts.videos
                let locked = counts.locked
                let lockedPhotos = counts.locked_photos
                let lockedVideos = counts.locked_videos
                var trash = counts.trash ?? 0
                for p in affected {
                    let wasTrashed = (p.delete_time ?? 0) > 0
                    if wasTrashed { continue }
                    all = max(0, all - 1)
                    if p.is_video { videos = max(0, videos - 1) }
                    else { photos = max(0, photos - 1) }
                    trash += 1
                }
                viewModel.mediaCounts = ServerMediaCounts(
                    all: all,
                    photos: photos,
                    videos: videos,
                    locked: locked,
                    locked_photos: lockedPhotos,
                    locked_videos: lockedVideos,
                    trash: trash
                )
            }
        }
        // Mutations must bypass the in-memory cache so counts and grids update immediately.
        viewModel.refreshCurrentTabAndInvalidateOtherMediaTypes()
    }
    private func bulkRestore() async {
        let ids = Array(viewModel.selected)
        try? await ServerPhotosService.shared.restorePhotos(assetIds: ids)
        await MainActor.run { viewModel.selected.removeAll(); viewModel.isSelectionMode = false }
        await MainActor.run {
            let idSet = Set(ids)
            let affected = viewModel.photos.filter { idSet.contains($0.asset_id) }
            if viewModel.selectedMediaType == .trash {
                viewModel.photos.removeAll { idSet.contains($0.asset_id) }
            }
            if let counts = viewModel.mediaCounts {
                var all = counts.all
                var photos = counts.photos
                var videos = counts.videos
                let locked = counts.locked
                let lockedPhotos = counts.locked_photos
                let lockedVideos = counts.locked_videos
                var trash = counts.trash ?? 0
                for p in affected {
                    let wasTrashed = (p.delete_time ?? 0) > 0
                    if !wasTrashed { continue }
                    trash = max(0, trash - 1)
                    all += 1
                    if p.is_video { videos += 1 }
                    else { photos += 1 }
                }
                viewModel.mediaCounts = ServerMediaCounts(
                    all: all,
                    photos: photos,
                    videos: videos,
                    locked: locked,
                    locked_photos: lockedPhotos,
                    locked_videos: lockedVideos,
                    trash: trash
                )
            }
        }
        // Mutations must bypass the in-memory cache so counts and grids update immediately.
        viewModel.refreshCurrentTabAndInvalidateOtherMediaTypes()
    }
    private func bulkRating(_ rating: Int?) async {
        let ids = viewModel.selected
        await withTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { try? await ServerPhotosService.shared.updateRating(assetId: id, rating: rating) } }
        }
        await MainActor.run { viewModel.selected.removeAll(); viewModel.isSelectionMode = false }
        viewModel.refreshAll(resetPage: true)
    }
    private func addSelectedToAlbum() async {
        guard let aid = albumPickerSelectedId else { return }
        let ids = Array(viewModel.selected)
        try? await ServerPhotosService.shared.addPhotosToAlbum(albumId: aid, assetIds: ids)
        await MainActor.run { viewModel.selected.removeAll(); viewModel.isSelectionMode = false }
        viewModel.refreshAll(resetPage: true)
    }
    private func removeSelectedFromAlbum() async {
        guard let aid = albumPickerSelectedId else { return }
        let ids = Array(viewModel.selected)
        try? await ServerPhotosService.shared.removePhotosFromAlbum(albumId: aid, assetIds: ids)
        await MainActor.run { viewModel.selected.removeAll(); viewModel.isSelectionMode = false }
        viewModel.refreshAll(resetPage: true)
    }
    private func applyMetadata() async {
        let ids = viewModel.selected
        await withTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { try? await ServerPhotosService.shared.updateMetadata(assetId: id, caption: editCaption.isEmpty ? nil : editCaption, description: editDescription.isEmpty ? nil : editDescription) } }
        }
        await MainActor.run { showMetadataSheet = false; editCaption = ""; editDescription = ""; viewModel.selected.removeAll(); viewModel.isSelectionMode = false }
        viewModel.refreshAll(resetPage: true)
    }
    private func criteriaFromCurrentState() -> ServerPhotoListQuery { var q = ServerPhotoListQuery(); switch viewModel.sortOption { case .createdNewest: q.sort_by = "created_at"; q.sort_order = "DESC"; case .createdOldest: q.sort_by = "created_at"; q.sort_order = "ASC"; case .importedNewest: q.sort_by = "last_indexed"; q.sort_order = "DESC"; case .importedOldest: q.sort_by = "last_indexed"; q.sort_order = "ASC"; case .largest: q.sort_by = "size"; q.sort_order = "DESC"; case .random(let seed): q.sort_by = "random"; q.sort_random_seed = seed }; switch viewModel.selectedMediaType { case .all: break; case .photos: q.filter_is_video = false; case .videos: q.filter_is_video = true; case .trash: q.filter_trashed_only = true }; if viewModel.showFavoritesOnly { q.filter_favorite = true }; if !viewModel.selectedAlbumIds.isEmpty { q.album_ids = Array(viewModel.selectedAlbumIds); q.album_subtree = viewModel.includeSubalbums }; if viewModel.showLockedOnly { q.filter_locked_only = true }; return q }

    // Header collapse helpers
    private func handleScroll(_ y: CGFloat) {
        if !isTrackingScroll { isTrackingScroll = true; lastOffset = y; return }
        let delta = y - lastOffset
        lastOffset = y
        if y > -10 { if !showHeaders { withAnimation(.easeOut(duration: 0.18)) { showHeaders = true } }; return }
        let threshold: CGFloat = 8
        if delta < -threshold { if showHeaders { withAnimation(.easeOut(duration: 0.18)) { showHeaders = false } } }
        else if delta > threshold { if !showHeaders { withAnimation(.easeOut(duration: 0.18)) { showHeaders = true } } }
    }

    private func handleScrollContentOffset(_ y: CGFloat) {
        // When the result set is empty, keep the header visible so the user can adjust filters.
        if viewModel.photos.isEmpty {
            if !showHeaders { revealHeader() }
            return
        }
        // Disable header collapse while in selection mode
        if viewModel.isSelectionMode {
            if !showHeaders { withAnimation(.easeOut(duration: 0.18)) { showHeaders = true } }
            // Reset tracking to avoid stale deltas when re-enabling
            isTrackingScroll = false
            dirAccum = 0
            lastDir = 0
            lastOffset = y
            return
        }

        // y increases as you scroll down
        if !isTrackingScroll {
            isTrackingScroll = true
            lastOffset = y
            dirAccum = 0
            lastDir = 0
            return
        }
        let delta = y - lastOffset
        lastOffset = y

        // Always keep header visible near the top
        if y < 10 {
            if !showHeaders { withAnimation(.easeOut(duration: 0.18)) { showHeaders = true } }
            dirAccum = 0
            lastDir = 0
            return
        }

        // Ignore tiny jitter
        if abs(delta) < 0.5 { return }

        let dir = (delta > 0) ? 1 : -1
        if dir != lastDir { dirAccum = 0; lastDir = dir }
        dirAccum += abs(delta)

        // Hysteresis thresholds (confirmed by requirements)
        let hideThreshold: CGFloat = 18
        let showThreshold: CGFloat = 12

        if dir > 0 {
            // Scrolling down: hide after enough movement
            if showHeaders && dirAccum >= hideThreshold {
                withAnimation(.easeOut(duration: 0.18)) { showHeaders = false }
                dirAccum = 0
            }
        } else {
            // Scrolling up: show after enough movement
            if !showHeaders && dirAccum >= showThreshold {
                withAnimation(.easeOut(duration: 0.18)) { showHeaders = true }
                dirAccum = 0
            }
        }
    }

    private func revealHeader() {
        if !showHeaders {
            withAnimation(.easeOut(duration: 0.18)) { showHeaders = true }
        } else {
            showHeaders = true
        }
        // Reset tracking so stale deltas don't immediately hide the header again.
        isTrackingScroll = false
        dirAccum = 0
        lastDir = 0
        lastOffset = 0
    }

    private var headerIsVisible: Bool { showHeaders || viewModel.photos.isEmpty }
    private var headerInset: CGFloat { headerIsVisible ? headerHeight : 0 }
}

// MARK: - Album Picker Sheet (server)
struct ServerAlbumPickerSheet: View {
    @Binding var isPresented: Bool
    let albums: [ServerAlbum]
    let onChoose: (Int) -> Void
    @State private var selectedId: Int? = nil
    @State private var includeSubtree: Bool = true

    var body: some View {
        NavigationView {
            List {
                ForEach(albums, id: \.id) { a in
                    HStack { Text(a.name); Spacer(); if selectedId == a.id { Image(systemName: "checkmark") } }
                        .contentShape(Rectangle())
                        .onTapGesture { selectedId = (selectedId == a.id ? nil : a.id) }
                }
            }
            .navigationTitle("Choose Album")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { isPresented = false } }
                ToolbarItem(placement: .confirmationAction) { Button("Add") { if let id = selectedId { isPresented = false; onChoose(id) } } .disabled(selectedId == nil) }
            }
        }
    }
}

// MARK: - Server App Bar (mirrors GalleryAppBar layout)
private struct ServerAppBar: View {
    let isSelectionMode: Bool
    let currentSort: ServerGalleryViewModel.SortOption
    let currentLayout: ServerGalleryViewModel.LayoutOption
    let showLayoutToggle: Bool
    let isEnterpriseEdition: Bool
    let isAuthenticated: Bool
    let onSearch: () -> Void
    let onSlideshow: () -> Void
    let onSort: (ServerGalleryViewModel.SortOption) -> Void
    let onLayoutChange: (ServerGalleryViewModel.LayoutOption) -> Void
    let onSelect: () -> Void
    let onTeamManagement: () -> Void
    let onShowSharing: () -> Void
    let onShowSimilarMedia: () -> Void
    let onManageFaces: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Button(action: onSearch) { Image(systemName: "magnifyingglass").font(.title3).foregroundColor(.primary) }
            Menu {
                Button("Newest First") { onSort(.createdNewest) }
                Button("Oldest First") { onSort(.createdOldest) }
                Button("Imported Newest") { onSort(.importedNewest) }
                Button("Imported Oldest") { onSort(.importedOldest) }
                Button("Largest First") { onSort(.largest) }
                Button("Random") { onSort(.random(seed: Int.random(in: 0...1_000_000))) }
            } label: { Image(systemName: "arrow.up.arrow.down").font(.title3).foregroundColor(.primary) }
            if showLayoutToggle {
                Picker("Layout", selection: Binding(get: { currentLayout }, set: { onLayoutChange($0) })) {
                    // Icon-only segments; the highlighted segment conveys selection.
                    Image(systemName: currentLayout == .grid ? "square.grid.2x2.fill" : "square.grid.2x2")
                        .accessibilityLabel("Grid")
                        .tag(ServerGalleryViewModel.LayoutOption.grid)
                    Image(systemName: currentLayout == .timeline ? "calendar.circle.fill" : "calendar")
                        .accessibilityLabel("Timeline")
                        .tag(ServerGalleryViewModel.LayoutOption.timeline)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
            }
            Spacer()
            Button(action: onSelect) {
                Text(isSelectionMode ? "Cancel" : "Select").font(.headline).foregroundColor(isSelectionMode ? .red : .blue)
            }
            Menu {
                Button(action: onSlideshow) {
                    Label("Slideshow", systemImage: "play.rectangle")
                }
                Divider()
                if isEnterpriseEdition && isAuthenticated {
                    Button(action: onShowSharing) {
                        Label("Sharing", systemImage: "square.and.arrow.up")
                    }
                }
                // Users & Groups (Enterprise Edition only, server enforces role permissions)
                if isEnterpriseEdition && isAuthenticated {
                    Button(action: onTeamManagement) {
                        Label("Users & Groups", systemImage: "person.2")
                    }
                }
                Button(action: onManageFaces) {
                    Label("Manage Faces", systemImage: "face.smiling")
                }
                Button {
                    onShowSimilarMedia()
                } label: {
                    Label("Similar Media", systemImage: "photo.on.rectangle.angled")
                }
                Divider()
                Button(role: .destructive) {
                    // TODO: Implement sign out
                } label: {
                    Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.title3)
                    .foregroundColor(.primary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(Color(.systemBackground))
    }
}

// MARK: - Inline Search App Bar (Android parity)
private struct SearchAppBar: View {
    @Binding var text: String
    let isSubmitEnabled: Bool
    @FocusState.Binding var focus: Bool
    let onBack: () -> Void
    let onClear: () -> Void
    let onSubmit: () -> Void

    // Limit input length to 255 chars
    private func clamp(_ s: String) -> String { String(s.prefix(255)) }

    var body: some View {
        HStack(spacing: 10) {
            // Back/close chevron while search is expanded
            Button(action: onBack) { Image(systemName: "chevron.left").font(.title3).foregroundColor(.primary) }

            // Single-line text field expands to fill row
            ZStack(alignment: .trailing) {
                TextField("Search photos", text: Binding(
                    get: { text },
                    set: { text = clamp($0) }
                ))
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .submitLabel(.search)
                .onSubmit { if isSubmitEnabled { onSubmit() } }
                .focused($focus)
                .frame(maxWidth: .infinity)

                // Clear button appears only when there is text
                if !text.isEmpty {
                    Button(action: onClear) {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }
                    .padding(.trailing, 8)
                }
            }

            // Submit icon at the far right, flush to edge
            Button(action: onSubmit) {
                Image(systemName: "magnifyingglass")
                    .font(.title3)
                    .foregroundColor(isSubmitEnabled ? .blue : .secondary)
            }
            .disabled(!isSubmitEnabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(Color(.systemBackground))
    }
}

// MARK: - Share Context

/// Context for share creation
struct ShareContext {
    let kind: Share.ObjectKind
    let id: String
    let name: String?
}
