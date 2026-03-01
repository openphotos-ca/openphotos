import SwiftUI
import UIKit

/// ActiveFilterRow renders the currently-applied filters as removable chips and
/// provides context actions (Save as Live, Freeze, Share, Clear All), mirroring
/// the web client's ActiveFilterChips behavior.
///
/// Layout: Horizontally scrollable filter chips on the left, with fixed action buttons
/// always visible on the right. A subtle fade gradient indicates scrollable content.
/// Space-optimized designs adapt to chip density: icon-only Favorites chip, and
/// "Save as Live" button shows full text (0-1 chips) or icon-only (2+ chips).
///
/// Visibility: Shown when any filter is active or any album is selected.
struct ActiveFilterRow: View {
    @EnvironmentObject var viewModel: ServerGalleryViewModel

    // Albums list to resolve names/covers/live flags
    let albums: [ServerAlbum]

    // Callback for Share button action
    let onShareAlbum: (ServerAlbum) -> Void

    // Local UI state for sheets
    @State private var showSaveLive = false
    @State private var showFreeze = false
    @State private var newAlbumName: String = ""
    @State private var eeEnabled: Bool = false

    // Small authenticated image loader for album covers and face thumbs
    private let imageLoader = AuthImageLoader.shared

    var body: some View {
        if !hasAnyActiveFilter { EmptyView() } else {
            // Layout strategy: Horizontal scrolling chips on the left, fixed action buttons on the right.
            // The ScrollView allows unlimited filter chips without overlapping the action buttons.
            // Visual hints (fade gradient) indicate scrollability when content extends beyond view.
            let rowHeight: CGFloat = 44
            let reservedActionsWidth: CGFloat = 180 // Reserve space for fixed action buttons
            ZStack(alignment: .trailing) {
                // Scrollable filter chips container with fade gradient hint
                ZStack(alignment: .trailing) {
                    // Chips row (horizontal scroll, no indicators)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            // Album chips (multi supported). Use selected ids directly so the row stays visible
                            // even if an album was just created and the albums list hasn't refreshed yet.
                            ForEach(selectedAlbumIds, id: \.self) { id in
                                if let a = albumById[id] {
                                    ChipAlbum(album: a, onRemove: { toggleAlbum(a.id) })
                                } else {
                                    let label = viewModel.selectedAlbumNameOverrides[id].map { "\($0)" } ?? "Album \(id)"
                                    ChipSimple(label: label) { toggleAlbum(id) }
                                }
                            }

                            // Sub-albums toggle (shown when any selected album has children)
                            if selectedAlbums.count > 0 && anySelectedHasChildren {
                                Toggle(isOn: Binding(get: { viewModel.includeSubalbums }, set: { viewModel.includeSubalbums = $0 })) {
                                    Text("sub‑albums").font(.footnote)
                                }
                                .toggleStyle(.switch)
                            }

                            // Favorites (icon-only for space efficiency)
                            if viewModel.showFavoritesOnly {
                                ChipIconOnly(systemImage: "heart.fill", tint: .red) {
                                    viewModel.showFavoritesOnly = false
                                }
                            }

                            // Rating ≥ N
                            if let r = viewModel.ratingMin, r >= 1 {
                                ChipSimple(label: "★≥\(r)") { viewModel.ratingMin = nil }
                            }

                            // Locked-only
                            if viewModel.showLockedOnly {
                                ChipSimple(label: "Locked", systemImage: "lock.fill", tint: .orange) {
                                    viewModel.showLockedOnly = false
                                }
                            }

                            // Faces (show up to 3 with +N)
                            if !viewModel.selectedFaces.isEmpty {
                                HStack(spacing: 6) {
                                    let faces = Array(viewModel.selectedFaces).prefix(3)
                                    ForEach(faces, id: \.self) { pid in
                                        ChipFace(personId: pid) {
                                            viewModel.selectedFaces.remove(pid)
                                        }
                                    }
                                    let extra = max(0, viewModel.selectedFaces.count - 3)
                                    if extra > 0 {
                                        Text("+\(extra)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }

                            // Type filter chips
                            if viewModel.typeScreenshot {
                                ChipSimple(label: "Screenshots") { viewModel.typeScreenshot = false }
                            }
                            if viewModel.typeLive {
                                ChipSimple(label: "Live Photos") { viewModel.typeLive = false }
                            }

                            // Date range
                            if viewModel.dateStart != nil || viewModel.dateEnd != nil {
                                ChipSimple(label: dateRangeLabel) {
                                    viewModel.dateStart = nil; viewModel.dateEnd = nil
                                }
                            }

                            // Location chips
                            if let c = viewModel.country, !c.isEmpty {
                                ChipSimple(label: "Country \(c)") { viewModel.country = nil }
                            }
                            if let r = viewModel.region, !r.isEmpty {
                                ChipSimple(label: "Region \(r)") { viewModel.region = nil }
                            }
                            if let city = viewModel.city, !city.isEmpty {
                                ChipSimple(label: "City \(city)") { viewModel.city = nil }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.trailing, reservedActionsWidth)
                        .frame(height: rowHeight)
                    }

                    // Subtle fade gradient on the right edge to hint at scrollable content
                    // Provides visual affordance that more chips may exist beyond the visible area
                    LinearGradient(
                        gradient: Gradient(colors: [
                            Color(.systemBackground).opacity(0),
                            Color(.systemBackground)
                        ]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 40)
                    .allowsHitTesting(false)
                }

                // Fixed action buttons (always visible on the right)
                // These buttons remain accessible regardless of how many filter chips are active
                HStack(spacing: 8) {
                    // Save as Live (hide if exactly one selected live album)
                    // Show full text when few chips (better discoverability), icon-only when many chips (space-saving)
                    if showSaveAsLiveButton {
                        Button {
                            newAlbumName = ""; showSaveLive = true
                        } label: {
                            if activeChipCount > 1 {
                                // Icon-only when multiple chips active
                                Image(systemName: "sparkles")
                                    .font(.footnote)
                            } else {
                                // Full label when 0-1 chips
                                Label("Save as Live", systemImage: "sparkles")
                                    .font(.footnote)
                            }
                        }
                        .buttonStyle(.bordered)
                    }

                    // Freeze (only when exactly one selected album is live)
                    if showFreezeButton {
                        Button {
                            newAlbumName = ""; showFreeze = true
                        } label: {
                            Label("Freeze", systemImage: "snowflake")
                                .font(.footnote)
                        }
                        .buttonStyle(.bordered)
                    }

                    // Share (EE only, exactly one selected album)
                    if eeEnabled && selectedAlbums.count == 1 {
                        Button {
                            print("🔍 Share button tapped - selectedAlbums count: \(selectedAlbums.count)")
                            // Trigger share sheet with the selected album
                            if let album = selectedAlbums.first {
                                print("🔍 Calling onShareAlbum with album: \(album.name) (id: \(album.id))")
                                onShareAlbum(album)
                            } else {
                                print("❌ No album found to share!")
                            }
                        } label: {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .font(.footnote)
                        }
                        .buttonStyle(.bordered)
                    }

                    // Clear All button (circular)
                    Button {
                        viewModel.clearAllFilters()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.footnote.weight(.semibold))
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Color.primary))
                            .foregroundColor(Color(.systemBackground))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.trailing, 4)
                .frame(height: rowHeight)
                .background(
                    // Subtle background to visually separate action buttons from chips
                    Color(.systemBackground)
                        .shadow(color: Color.black.opacity(0.05), radius: 8, x: -4, y: 0)
                )
            }
            .frame(height: rowHeight)
            .background(Color(.systemBackground))
            .clipped()
            .onAppear { Task { eeEnabled = (try? await CapabilitiesService.shared.get(force: true).ee) ?? false } }
            .sheet(isPresented: $showSaveLive) { saveLiveSheet }
            .sheet(isPresented: $showFreeze) { freezeSheet }
        }
    }

    // MARK: - Computed helpers

    private var selectedAlbumIds: [Int] { Array(viewModel.selectedAlbumIds).sorted() }
    private var albumById: [Int: ServerAlbum] { Dictionary(uniqueKeysWithValues: albums.map { ($0.id, $0) }) }
    private var selectedAlbums: [ServerAlbum] {
        return selectedAlbumIds.compactMap { albumById[$0] }
    }
    private var anySelectedHasChildren: Bool {
        guard !selectedAlbums.isEmpty else { return false }
        let ids = Set(selectedAlbums.map { $0.id })
        return albums.contains { a in a.parent_id != nil && ids.contains(a.parent_id!) }
    }

    /// Count of visible filter chips (used to determine if action button text should be condensed)
    private var activeChipCount: Int {
        var count = 0
        // Album chips
        count += selectedAlbumIds.count
        // Sub-albums toggle (shown as a toggle, not a chip, but counts toward UI density)
        if selectedAlbums.count > 0 && anySelectedHasChildren { count += 1 }
        // Other filter chips
        if viewModel.showFavoritesOnly { count += 1 }
        if let r = viewModel.ratingMin, r >= 1 { count += 1 }
        if viewModel.showLockedOnly { count += 1 }
        if !viewModel.selectedFaces.isEmpty { count += min(3, viewModel.selectedFaces.count) }
        if viewModel.typeScreenshot { count += 1 }
        if viewModel.typeLive { count += 1 }
        if viewModel.dateStart != nil || viewModel.dateEnd != nil { count += 1 }
        if viewModel.country != nil { count += 1 }
        if viewModel.region != nil { count += 1 }
        if viewModel.city != nil { count += 1 }
        return count
    }

    private var hasOtherFilters: Bool {
        return !viewModel.searchText.isEmpty ||
               viewModel.showFavoritesOnly ||
               !viewModel.selectedFaces.isEmpty ||
               viewModel.typeScreenshot || viewModel.typeLive ||
               viewModel.country != nil || viewModel.region != nil || viewModel.city != nil ||
               viewModel.dateStart != nil || viewModel.dateEnd != nil ||
               viewModel.ratingMin != nil
        // Note: Media type (Photos/Videos) alone is not considered an active filter for
        // showing this row, per product requirement. Keep it out of the trigger list.
    }

    private var hasAnyActiveFilter: Bool {
        return !viewModel.selectedAlbumIds.isEmpty || hasOtherFilters || viewModel.showLockedOnly
    }

    private var showSaveAsLiveButton: Bool {
        // Hide when exactly one selected album and it is live
        let anyLiveSelected = selectedAlbums.contains { $0.is_live }
        let exactlyOneAlbum = selectedAlbums.count == 1
        if exactlyOneAlbum && anyLiveSelected { return false }
        // Show when: no album but filters present, or multiple albums selected, or any filters beyond the one selected live album
        return (selectedAlbums.isEmpty && hasOtherFilters) || (selectedAlbums.count > 1) || hasOtherFilters
    }

    private var showFreezeButton: Bool {
        selectedAlbums.count == 1 && (selectedAlbums.first?.is_live == true)
    }

    private var dateRangeLabel: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let s = viewModel.dateStart.map { f.string(from: $0) } ?? ""
        let e = viewModel.dateEnd.map { f.string(from: $0) } ?? ""
        return e.isEmpty ? "Time \(s)" : "Time \(s) → \(e)"
    }

    // MARK: - Sheets
    private var saveLiveSheet: some View {
        NavigationView {
            Form {
                Section(header: Text("Album name")) {
                    TextField("e.g., Paris 2023", text: $newAlbumName)
                        .textInputAutocapitalization(.words)
                }
            }
            .navigationTitle("Save as Live")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showSaveLive = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await createLiveAlbum() } }
                        .disabled(newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var freezeSheet: some View {
        NavigationView {
            Form {
                Section(header: Text("Static album name (optional)")) {
                    TextField("Type a name", text: $newAlbumName)
                        .textInputAutocapitalization(.words)
                }
            }
            .navigationTitle("Freeze Live Album")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showFreeze = false } }
                ToolbarItem(placement: .confirmationAction) { Button("Create") { Task { await freezeAlbum() } } }
            }
        }
    }

    // MARK: - Actions
    private func toggleAlbum(_ id: Int) {
        var next = viewModel.selectedAlbumIds
        if next.contains(id) {
            next.remove(id)
            viewModel.setSelectedAlbumNameOverride(id: id, name: nil)
        } else {
            next.insert(id)
        }
        viewModel.selectedAlbumIds = next
    }

    private func createLiveAlbum() async {
        // Use Task in defer to avoid awaiting within defer body
        defer { Task { @MainActor in showSaveLive = false } }
        let name = newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let criteria = buildCriteriaFromState()
        do {
            print("[ActiveFilterRow] Creating live album '\(name)' with criteria: \(criteria)")
            let album = try await ServerPhotosService.shared.createLiveAlbum(name: name, description: nil, parentId: nil, criteria: criteria)
            print("[ActiveFilterRow] Live album created successfully: id=\(album.id), name=\(album.name)")
            // Reload albums list so the new live album appears in the UI
            await viewModel.reloadAlbums()
            await MainActor.run {
                viewModel.clearAllFilters()
                viewModel.selectedAlbumIds = [album.id]
                viewModel.refreshAll(resetPage: true)
                ToastManager.shared.show("Live album '\(album.name)' created")
            }
        } catch {
            print("[ActiveFilterRow] createLiveAlbum failed: \(error)")
            await MainActor.run {
                ToastManager.shared.show("Failed to create album: \(error.localizedDescription)")
            }
        }
    }

    private func freezeAlbum() async {
        defer { Task { @MainActor in showFreeze = false } }
        guard let targetId = selectedAlbums.first?.id else { return }
        let name = newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let frozen = try await ServerPhotosService.shared.freezeAlbum(id: targetId, name: name.isEmpty ? nil : name)
            // Reload albums list so the frozen album appears in the UI
            await viewModel.reloadAlbums()
            await MainActor.run {
                viewModel.clearAllFilters()
                viewModel.selectedAlbumIds = [frozen.id]
                viewModel.refreshAll(resetPage: true)
            }
        } catch { print("[ActiveFilterRow] freezeAlbum failed: \(error)") }
    }

    /// Build PhotoListQuery criteria mirroring the web when saving Live albums.
    private func buildCriteriaFromState() -> ServerPhotoListQuery {
        var q = ServerPhotoListQuery()
        // Sort
        switch viewModel.sortOption {
        case .createdNewest: q.sort_by = "created_at"; q.sort_order = "DESC"
        case .createdOldest: q.sort_by = "created_at"; q.sort_order = "ASC"
        case .importedNewest: q.sort_by = "last_indexed"; q.sort_order = "DESC"
        case .importedOldest: q.sort_by = "last_indexed"; q.sort_order = "ASC"
        case .largest: q.sort_by = "size"; q.sort_order = "DESC"
        case .random(let seed): q.sort_by = "random"; q.sort_random_seed = seed
        }
        // Media
        switch viewModel.selectedMediaType {
        case .all: break
        case .photos: q.filter_is_video = false
        case .videos: q.filter_is_video = true
        case .trash: q.filter_trashed_only = true
        }
        // Favorites
        if viewModel.showFavoritesOnly { q.filter_favorite = true }
        // Faces (AND by default)
        if !viewModel.selectedFaces.isEmpty {
            q.filter_faces = Array(viewModel.selectedFaces).joined(separator: ",")
        }
        // Location
        if let c = viewModel.country { q.filter_country = c }
        if let city = viewModel.city { q.filter_city = city }
        // Time range (inclusive end-of-day)
        if let s = viewModel.dateStart { q.filter_date_from = Int64(s.timeIntervalSince1970) }
        if let e = viewModel.dateEnd {
            let cal = Calendar.current
            let endOfDay = cal.date(bySettingHour: 23, minute: 59, second: 59, of: e) ?? e
            q.filter_date_to = Int64(endOfDay.timeIntervalSince1970)
        }
        // Types
        if viewModel.typeScreenshot { q.filter_screenshot = true }
        if viewModel.typeLive { q.filter_live_photo = true }
        // Rating
        if let r = viewModel.ratingMin, r >= 1, r <= 5 { q.filter_rating_min = r }
        // Locked-only
        if viewModel.showLockedOnly { q.filter_locked_only = true; q.include_locked = true }
        // Album selection (multi supported)
        let ids = Array(viewModel.selectedAlbumIds)
        if ids.count == 1 { q.album_id = ids.first }
        if ids.count > 1 { q.album_ids = ids }
        q.album_subtree = viewModel.includeSubalbums
        return q
    }

    // MARK: - Chip Views
    private func ChipSimple(label: String, systemImage: String? = nil, tint: Color? = nil, onClear: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            if let sf = systemImage { Image(systemName: sf).foregroundColor(tint ?? .accentColor) }
            Text(label).lineLimit(1)
            Button(action: onClear) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.blue.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.blue.opacity(0.35)))
        .font(.caption)
    }

    private func ChipAlbum(album: ServerAlbum, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            if let aid = album.cover_asset_id {
                let url = AuthorizedHTTPClient.shared.buildURL(path: "/api/thumbnails/" + (aid.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? aid))
                AuthImage(url: url)
                    .frame(width: 18, height: 18)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color(.separator)))
            }
            HStack(spacing: 4) {
                if album.is_live { Image(systemName: "sparkles").foregroundColor(.purple) }
                Text(album.name).lineLimit(1)
            }
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(.separator)))
        .font(.caption)
    }

    private func ChipFace(personId: String, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            if let url = ServerPhotosService.shared.getFaceThumbnailUrl(personId: personId) {
                AuthImage(url: url)
                    .frame(width: 20, height: 20)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color(.separator)))
            }
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.blue.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.blue.opacity(0.35)))
        .font(.caption)
    }

    /// Icon-only chip for space-constrained filters (e.g., Favorites).
    /// Displays a single icon with a close button in a compact circular design.
    private func ChipIconOnly(systemImage: String, tint: Color? = nil, onClear: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundColor(tint ?? .accentColor)
                .font(.system(size: 14, weight: .semibold))
            Button(action: onClear) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.blue.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.blue.opacity(0.35)))
    }
}

// MARK: - Authenticated Image Loader (shared)
final class AuthImageLoader: ObservableObject {
    static let shared = AuthImageLoader()
    private init() {}
    private let cache = NSCache<NSURL, UIImage>()

    func load(url: URL) async -> UIImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        var req = URLRequest(url: url)
        do {
            let (data, _) = try await AuthorizedHTTPClient.shared.request(req)
            if let img = UIImage(data: data) { cache.setObject(img, forKey: url as NSURL); return img }
        } catch { }
        return nil
    }
}

struct AuthImage: View {
    let url: URL
    @State private var image: UIImage? = nil
    private let loader = AuthImageLoader.shared

    var body: some View {
        ZStack {
            Color(.systemGray6)
            if let ui = image { Image(uiImage: ui).resizable().scaledToFill() }
        }
        .task(id: url) { image = await loader.load(url: url) }
    }
}
