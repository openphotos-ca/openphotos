import SwiftUI
import Photos
import UIKit // UIImage for image rendering; haptics moved to CoreHaptics via HapticsManager
import AVKit
import AVFoundation

struct FullScreenPhotoView: View {
    let assets: [PHAsset]
    let initialIndex: Int
    let onShowSelected: (() -> Void)?
    @State private var currentIndex: Int
    @State private var fullSizeImages: [Int: UIImage] = [:]
    @State private var isLoading: [Int: Bool] = [:]
    @State private var isFavorite: Bool = false
    @State private var isLocked: Bool = false
    // Albums state for current asset
    @State private var membershipAlbums: [Album] = []
    @State private var recentAlbums: [Album] = []
    @State private var allAlbums: [Album] = []
    @State private var showingAlbumTree: Bool = false
    @State private var selectedAlbumIdForTree: Int64? = nil
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var viewModel: GalleryViewModel
    
    init(assets: [PHAsset], initialIndex: Int, onShowSelected: (() -> Void)? = nil) {
        self.assets = assets
        self.initialIndex = initialIndex
        self.onShowSelected = onShowSelected
        self._currentIndex = State(initialValue: initialIndex)
    }
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            // Current photo display with swipe navigation
            // Add padding to ensure photo doesn't go under the UI elements
            FullScreenMediaView(
                asset: assets[currentIndex],
                image: fullSizeImages[currentIndex],
                isLoading: isLoading[currentIndex] ?? true,
                onSwipeLeft: {
                    // Swipe left -> Next photo
                    if currentIndex < assets.count - 1 {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            currentIndex += 1
                            preloadAdjacentImages()
                        }
                    }
                },
                onSwipeRight: {
                    // Swipe right -> Previous photo
                    if currentIndex > 0 {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            currentIndex -= 1
                            preloadAdjacentImages()
                        }
                    }
                },
                onSwipeUp: {
                    // Swipe up -> Add to collection and go to next
                    addToCollectionAndNext()
                }
            )
            .id(assets[currentIndex].localIdentifier) // reset per-asset playback/zoom state cleanly
            .padding(.top, 60) // Space for back button
            .padding(.bottom, 100) // Space for action bar and home indicator
            .onAppear {
                // Preload current and adjacent images
                loadFullSizeImage(at: currentIndex)
                if currentIndex > 0 {
                    loadFullSizeImage(at: currentIndex - 1)
                }
                if currentIndex < assets.count - 1 {
                    loadFullSizeImage(at: currentIndex + 1)
                }
                updateFavoriteStatus()
                updateLockedStatus()
                loadAlbumsState()
            }
            .onChange(of: currentIndex) { _ in
                updateFavoriteStatus()
                updateLockedStatus()
                loadAlbumsState()
            }
            
            // Top overlay with back button
            VStack {
                HStack {
                    Button(action: {
                        dismiss()
                    }) {
                        Image(systemName: "arrow.left")
                            .font(.system(size: 18))
                            .foregroundColor(.white)
                            .padding(8)
                            .background(Color.black.opacity(0.4))
                            .clipShape(Circle())
                    }
                    .padding(.leading, 16)
                    
                    Spacer()
                    // Lock/Unlock toggle
                    Button(action: { toggleLocked() }) {
                        Image(systemName: isLocked ? "lock.fill" : "lock.open")
                            .font(.system(size: 18))
                            .foregroundColor(.white)
                            .padding(8)
                            .background(Color.black.opacity(0.4))
                            .clipShape(Circle())
                            .accessibilityLabel(isLocked ? "Unlock item" : "Lock item")
                    }
                    .padding(.trailing, 16)
                }
                .padding(.top, 50) // Account for status bar
                
                Spacer()
                
                // Membership bar (current item's albums)
                if !membershipAlbums.isEmpty {
                    MembershipChipsBar(
                        albums: membershipAlbums,
                        nameById: Dictionary(uniqueKeysWithValues: allAlbums.map { ($0.id, $0.name) }),
                        onRemove: { album in
                            removeCurrentAsset(from: album)
                        }
                    )
                }

                // Bottom bar: heart | recent album chips | album tree
                FullScreenBottomBar(
                    isFavorite: $isFavorite,
                    recentAlbums: visibleRecentAlbums(),
                    nameById: Dictionary(uniqueKeysWithValues: allAlbums.map { ($0.id, $0.name) }),
                    onToggleFavorite: { toggleFavorite() },
                    onTapRecent: { album in assignCurrentAsset(to: album) },
                    onOpenAlbumTree: { showingAlbumTree = true }
                )
            }
        }
        .statusBarHidden()
        .navigationBarHidden(true)
        .sheet(isPresented: $showingAlbumTree) {
            AlbumTreeView(
                isPresented: $showingAlbumTree,
                selectedAlbumId: $selectedAlbumIdForTree,
                onAlbumSelected: { albumId in
                    if let album = allAlbums.first(where: { $0.id == albumId }) {
                        assignCurrentAsset(to: album)
                    }
                },
                onAlbumsChanged: {
                    // Refresh album lists
                    loadAlbumsState()
                },
                onAlbumCreated: { newAlbumId in
                    // Immediately assign and bump recency
                    if let album = AlbumService.shared.getAllAlbums().first(where: { $0.id == newAlbumId }) {
                        assignCurrentAsset(to: album)
                    } else {
                        loadAlbumsState()
                    }
                }
            )
            .presentationDetents([.medium, .large])
        }
    }
    
    private func updateFavoriteStatus() {
        guard currentIndex >= 0 && currentIndex < assets.count else { return }
        let asset = assets[currentIndex]
        
        // Fetch the current asset to get the latest favorite status
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [asset.localIdentifier], options: nil)
        if let updatedAsset = fetchResult.firstObject {
            isFavorite = updatedAsset.isFavorite
        } else {
            isFavorite = asset.isFavorite
        }
    }

    private func updateLockedStatus() {
        guard currentIndex >= 0 && currentIndex < assets.count else { return }
        let asset = assets[currentIndex]
        let scopeSelectedOnly = (AuthManager.shared.syncScope == .selectedAlbums)
        let locked = AlbumService.shared.isAssetLocked(assetLocalIdentifier: asset.localIdentifier, scopeSelectedOnly: scopeSelectedOnly)
        self.isLocked = locked
    }
    
    private func toggleFavorite() {
        guard currentIndex >= 0 && currentIndex < assets.count else { return }
        let asset = assets[currentIndex]
        let newFavoriteStatus = !asset.isFavorite
        
        PHPhotoLibrary.shared().performChanges({
            let request = PHAssetChangeRequest(for: asset)
            request.isFavorite = newFavoriteStatus
        }) { success, error in
            if success {
                DispatchQueue.main.async {
                    self.isFavorite = newFavoriteStatus
                    // Refresh the photos in the view model to reflect the change
                    self.viewModel.refreshPhotos()
                }
            } else if let error = error {
                print("Failed to update favorite status: \(error)")
            }
        }
    }

    private func toggleLocked() {
        guard currentIndex >= 0 && currentIndex < assets.count else { return }
        let asset = assets[currentIndex]
        let targetLocked = !isLocked

        func applyLockChange(locked: Bool) {
            SyncRepository.shared.setLockOverrideForLocalIdentifier(asset.localIdentifier, override: locked)
            self.isLocked = locked
            HapticsManager.shared.playAdd()
            if locked {
                ToastManager.shared.show("Marked as Locked — will encrypt on next sync")
            } else {
                ToastManager.shared.show("Marked as Unlocked — will upload unencrypted")
            }
            viewModel.refreshPhotos()
        }

        if targetLocked {
            // Ensure we have UMK prior to marking as locked
            if E2EEManager.shared.hasValidUMKRespectingTTL() || E2EEManager.shared.unlockWithDeviceKey(prompt: "Unlock to lock item") {
                applyLockChange(locked: true)
                return
            }
            // Prompt typed unlock asynchronously; do not block the main thread
            E2EEUnlockController.shared.requireUnlock(reason: "Unlock to lock this item") { success in
                DispatchQueue.main.async {
                    if success {
                        applyLockChange(locked: true)
                    } else {
                        HapticsManager.shared.playError()
                    }
                }
            }
        } else {
            applyLockChange(locked: false)
        }
    }

    private func loadAlbumsState() {
        guard currentIndex >= 0 && currentIndex < assets.count else { return }
        let asset = assets[currentIndex]
        // Load all, memberships, and recents from DB (local-only)
        let all = AlbumService.shared.getAllAlbums()
        let memberships = AlbumService.shared.getAlbumsForAsset(assetId: asset.localIdentifier)
        var recents = AlbumService.shared.getAlbumsOrderedByRecentUse()
        // Filter out albums already in memberships and limit to 10
        let membershipIds = Set(memberships.map { $0.id })
        recents = recents.filter { !membershipIds.contains($0.id) }
        if recents.count > 10 { recents = Array(recents.prefix(10)) }

        DispatchQueue.main.async {
            self.allAlbums = all
            self.membershipAlbums = memberships
            self.recentAlbums = recents
        }
    }

    private func visibleRecentAlbums() -> [Album] {
        // Ensure we always hide current memberships and cap at 10
        let membershipIds = Set(membershipAlbums.map { $0.id })
        let filtered = recentAlbums.filter { !membershipIds.contains($0.id) }
        return filtered.count > 10 ? Array(filtered.prefix(10)) : filtered
    }

    private func assignCurrentAsset(to album: Album) {
        guard currentIndex >= 0 && currentIndex < assets.count else { return }
        let asset = assets[currentIndex]
        let ok = AlbumService.shared.addPhotosToAlbum(albumId: album.id, assetIds: [asset.localIdentifier])
        if ok {
            // Optimistic: update membership and recency ordering immediately
            if !membershipAlbums.contains(where: { $0.id == album.id }) {
                membershipAlbums.append(album)
            }
            // Bump album to front of recent list
            if let idx = recentAlbums.firstIndex(where: { $0.id == album.id }) {
                let a = recentAlbums.remove(at: idx)
                recentAlbums.insert(a, at: 0)
            } else {
                recentAlbums.insert(album, at: 0)
            }
            // Feedback via CoreHaptics
            HapticsManager.shared.playAdd()
            ToastManager.shared.show("Added to \(displayTitle(for: album))")
            // Refresh from DB to keep counts and order fresh
            loadAlbumsState()
            // Also refresh gallery-level albums so chip counts update
            viewModel.loadDbAlbums()
        } else {
            HapticsManager.shared.playError()
            ToastManager.shared.show("Failed to add to \(displayTitle(for: album))")
        }
    }

    private func removeCurrentAsset(from album: Album) {
        guard currentIndex >= 0 && currentIndex < assets.count else { return }
        let asset = assets[currentIndex]
        let ok = AlbumService.shared.removePhotosFromAlbum(albumId: album.id, photoIds: [asset.localIdentifier])
        if ok {
            membershipAlbums.removeAll { $0.id == album.id }
            HapticsManager.shared.playRemove()
            ToastManager.shared.show("Removed from \(displayTitle(for: album))")
            // Refresh recents so album is eligible again
            loadAlbumsState()
            viewModel.loadDbAlbums()
        } else {
            HapticsManager.shared.playError()
            ToastManager.shared.show("Failed to remove from \(displayTitle(for: album))")
        }
    }

    private func displayTitle(for album: Album) -> String {
        if let pid = album.parentId, let parent = allAlbums.first(where: { $0.id == pid }) {
            return "\(parent.name).\(album.name)"
        }
        return album.name
    }
    
    private func addToCollectionAndNext() {
        guard currentIndex >= 0 && currentIndex < assets.count else { return }
        let currentAsset = assets[currentIndex]
        
        // Add to collection if not already present (duplicate check)
        if !viewModel.selectedPhotos.contains(currentAsset) {
            viewModel.selectedPhotos.insert(currentAsset)
        }
        
        // Move to next photo
        if currentIndex < assets.count - 1 {
            withAnimation(.easeInOut(duration: 0.3)) {
                currentIndex += 1
                preloadAdjacentImages()
            }
        }
    }
    
    private func preloadAdjacentImages() {
        // Preload adjacent images when swiping
        if currentIndex > 0 {
            loadFullSizeImage(at: currentIndex - 1)
        }
        if currentIndex < assets.count - 1 {
            loadFullSizeImage(at: currentIndex + 1)
        }
    }
    
    private func loadFullSizeImage(at index: Int) {
        guard index >= 0 && index < assets.count else { return }
        guard fullSizeImages[index] == nil else { return } // Already loaded
        
        let asset = assets[index]
        isLoading[index] = true
        
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .none
        options.isNetworkAccessAllowed = true
        
        // Request full screen size image
        let targetSize = CGSize(width: UIScreen.main.bounds.width * 2, 
                               height: UIScreen.main.bounds.height * 2)
        
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFit,
            options: options
        ) { image, _ in
            DispatchQueue.main.async {
                self.fullSizeImages[index] = image
                self.isLoading[index] = false
            }
        }
    }
}

struct FullScreenMediaView: View {
    let asset: PHAsset
    let image: UIImage?
    let isLoading: Bool
    let onSwipeLeft: () -> Void
    let onSwipeRight: () -> Void
    let onSwipeUp: () -> Void
    
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastScale: CGFloat = 1.0
    @State private var lastOffset: CGSize = .zero
    @State private var dragTranslation: CGSize = .zero

    @State private var livePlayer: AVPlayer? = nil
    @State private var livePlaybackEnded: Bool = false
    @State private var liveExportedURL: URL? = nil
    @State private var liveLoadToken: UUID = UUID()

    private var isLivePhoto: Bool {
        asset.mediaType == .image && asset.mediaSubtypes.contains(.photoLive)
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image = image {
                    if asset.mediaType == .video {
                        // Full video player with controls
                        VideoPlayerView(asset: asset)
                            .ignoresSafeArea()
                    } else {
                        // Photo (and Live Photo still) with zoom capability
                        ZStack {
                            Image(uiImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .scaleEffect(scale)
                                .offset(scale > 1.0 ? offset : .zero)
                                .clipped()

                            if isLivePhoto, let p = livePlayer, !livePlaybackEnded {
                                LivePhotoVideoSurface(player: p)
                                    .scaleEffect(scale)
                                    .offset(scale > 1.0 ? offset : .zero)
                                    .clipped()
                                    .onReceive(
                                        NotificationCenter.default.publisher(
                                            for: .AVPlayerItemDidPlayToEndTime,
                                            object: p.currentItem
                                        )
                                    ) { _ in
                                        livePlaybackEnded = true
                                        p.pause()
                                        p.seek(to: .zero)
                                        MediaAudioSession.shared.deactivateAfterPlayback()
                                    }
                                    .allowsHitTesting(false)
                            }
                        }
                        .task {
                            if isLivePhoto, livePlayer == nil {
                                await autoplayLivePhotoMotionIfAvailable()
                            }
                        }
                    }
                } else if isLoading {
                    VStack(spacing: 20) {
                        ProgressView()
                            .scaleEffect(1.5)
                            .tint(.white)
                        
                        Text("Loading...")
                            .foregroundColor(.white)
                    }
                } else {
                    // Error state
                    VStack(spacing: 20) {
                        Image(systemName: "photo")
                            .font(.system(size: 50))
                            .foregroundColor(.gray)
                        
                        Text("Unable to load image")
                            .foregroundColor(.gray)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .offset(scale <= 1.0 ? CGSize(width: dragTranslation.width * 0.3, height: 0) : offset)
            .gesture(
                SimultaneousGesture(
                    MagnificationGesture()
                        .onChanged { value in
                            // Only apply zoom for images
                            if asset.mediaType == .image {
                                scale = lastScale * value
                            }
                        }
                        .onEnded { value in
                            if asset.mediaType == .image {
                                lastScale = scale
                                // Reset if zoomed out too much
                                if scale < 1.0 {
                                    withAnimation(.easeInOut(duration: 0.3)) {
                                        scale = 1.0
                                        lastScale = 1.0
                                        offset = .zero
                                        lastOffset = .zero
                                    }
                                }
                            }
                        },
                    DragGesture()
                        .onChanged { value in
                            if asset.mediaType == .image {
                                if scale > 1.0 {
                                    // Panning when zoomed in
                                    offset = CGSize(
                                        width: lastOffset.width + value.translation.width,
                                        height: lastOffset.height + value.translation.height
                                    )
                                } else {
                                    // Show drag feedback when not zoomed
                                    dragTranslation = value.translation
                                }
                            } else {
                                // For videos, show drag feedback for swipe navigation
                                dragTranslation = value.translation
                            }
                        }
                        .onEnded { value in
                            dragTranslation = .zero
                            if asset.mediaType == .image {
                                if scale > 1.0 {
                                    // Handle panning when zoomed in
                                    lastOffset = offset
                                } else {
                                    // Handle swipe navigation when not zoomed
                                    let threshold: CGFloat = 50
                                    if abs(value.translation.width) > abs(value.translation.height) {
                                        // Horizontal swipe
                                        if value.translation.width > threshold {
                                            onSwipeRight()
                                        } else if value.translation.width < -threshold {
                                            onSwipeLeft()
                                        }
                                    } else if value.translation.height < -threshold {
                                        // Swipe up
                                        onSwipeUp()
                                    }
                                }
                            } else {
                                // For videos, handle swipe navigation
                                let threshold: CGFloat = 50
                                if abs(value.translation.width) > abs(value.translation.height) {
                                    // Horizontal swipe
                                    if value.translation.width > threshold {
                                        onSwipeRight()
                                    } else if value.translation.width < -threshold {
                                        onSwipeLeft()
                                    }
                                } else if value.translation.height < -threshold {
                                    // Swipe up
                                    onSwipeUp()
                                }
                            }
                        }
                )
            )
            .onTapGesture(count: 2) {
                // Double tap to zoom - only for photos
                if asset.mediaType == .image {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        if scale > 1.0 {
                            scale = 1.0
                            lastScale = 1.0
                            offset = .zero
                            lastOffset = .zero
                        } else {
                            scale = 2.0
                            lastScale = 2.0
                        }
                    }
                }
            }
            .onDisappear {
                // Best-effort cleanup for Live Photo temp exports.
                liveLoadToken = UUID()
                livePlayer?.pause()
                livePlayer = nil
                livePlaybackEnded = false
                if let url = liveExportedURL {
                    try? FileManager.default.removeItem(at: url)
                }
                liveExportedURL = nil
            }
        }
    }

    private func autoplayLivePhotoMotionIfAvailable() async {
        let token = UUID()
        await MainActor.run {
            liveLoadToken = token
            livePlaybackEnded = false
            MediaAudioSession.shared.configureForVideoPlaybackIfNeeded()
        }

        do {
            let url = try await exportPairedLiveVideoURL()
            if Task.isCancelled { return }
            await MainActor.run {
                guard liveLoadToken == token else { return }
                liveExportedURL = url
                let p = AVPlayer(url: url)
                livePlayer = p
                livePlaybackEnded = false
                p.play()
            }
        } catch {
            // If export fails (e.g. missing paired resource), just keep showing the still photo.
            await MainActor.run {
                guard liveLoadToken == token else { return }
                livePlayer = nil
                livePlaybackEnded = false
            }
        }
    }

    private func exportPairedLiveVideoURL() async throws -> URL {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let paired = resources.first(where: { $0.type == .pairedVideo }) else {
            throw NSError(domain: "LIVE", code: 1, userInfo: [NSLocalizedDescriptionKey: "Paired video resource not found"])
        }
        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        do {
            return try await withCheckedThrowingContinuation { cont in
                PHAssetResourceManager.default().writeData(for: paired, toFile: outURL, options: options) { err in
                    if let err = err {
                        cont.resume(throwing: err)
                    } else {
                        cont.resume(returning: outURL)
                    }
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: outURL)
            throw error
        }
    }
}

/// Minimal player surface for inline Live Photo motion playback (no system controls).
private struct LivePhotoVideoSurface: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.showsPlaybackControls = false
        vc.videoGravity = .resizeAspect
        return vc
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        if uiViewController.player !== player {
            uiViewController.player = player
        }
    }

    static func dismantleUIViewController(_ uiViewController: AVPlayerViewController, coordinator: ()) {
        uiViewController.player = nil
    }
}

// MARK: - Membership bar (solid chips) and Bottom bar

private struct MembershipChipsBar: View {
    let albums: [Album]
    let nameById: [Int64: String]
    let onRemove: (Album) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(albums, id: \.id) { album in
                    let title = displayTitle(album)
                    HStack(spacing: 4) {
                        Text(title)
                            .font(.system(size: 13))
                            .foregroundColor(.blue)
                            .lineLimit(1)
                        Button(action: { onRemove(album) }) {
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
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.15))
    }

    private func displayTitle(_ album: Album) -> String {
        if let pid = album.parentId, let parent = nameById[pid] { return "\(parent).\(album.name)" }
        return album.name
    }
}

private struct FullScreenBottomBar: View {
    @Binding var isFavorite: Bool
    let recentAlbums: [Album]
    let nameById: [Int64: String]
    let onToggleFavorite: () -> Void
    let onTapRecent: (Album) -> Void
    let onOpenAlbumTree: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Heart button
            Button(action: onToggleFavorite) {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .font(.system(size: 20))
                    .foregroundColor(isFavorite ? .red : .white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.black.opacity(0.4)))
            }

            // Recent album chips (outline style)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(recentAlbums, id: \.id) { album in
                        let title = displayTitle(album)
                        Button(action: { onTapRecent(album) }) {
                            Text(title)
                                .font(.subheadline)
                                .lineLimit(1)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 16)
                                        .fill(Color(.systemGray6).opacity(0.9))
                                )
                        }
                        .buttonStyle(PlainButtonStyle())
                        .accessibilityLabel("Add to \(title)")
                    }
                }
            }

            // Album tree button
            Button(action: onOpenAlbumTree) {
                ZStack {
                    Circle().fill(Color.black.opacity(0.4))
                    PineTreeIcon(lineWidth: 1.5)
                        .foregroundColor(.white)
                        .padding(6)
                }
                .frame(width: 36, height: 36)
                .accessibilityLabel("Open album tree")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .padding(.bottom, 34)
        .background(
            LinearGradient(
                gradient: Gradient(colors: [Color.black.opacity(0.0), Color.black.opacity(0.45)]),
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private func displayTitle(_ album: Album) -> String {
        if let pid = album.parentId, let parent = nameById[pid] { return "\(parent).\(album.name)" }
        return album.name
    }
}

#Preview {
    FullScreenPhotoView(assets: [], initialIndex: 0)
        .environmentObject(GalleryViewModel())
}
