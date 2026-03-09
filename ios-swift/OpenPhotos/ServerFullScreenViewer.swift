import SwiftUI
import AVKit
import AVFoundation
import UIKit
import Photos

/// A full-featured, server-backed full screen viewer for photos/videos.
/// - Gestures: swipe left/right (when zoom==1), swipe down to save, pinch/double‑tap zoom, pan with inertia
/// - Video controls: play/pause, mute, scrubbing
/// - Info panel: metadata, editable caption/description, rating stars (0–5), people list
/// - Albums: membership chips with inline remove, Album Tree picker to add
/// - People: Update Face(s) (replace face + add person)
/// - EE Share: Inline share sheet (basic options) when capabilities.ee == true
struct ServerFullScreenViewer: View {
    private static let fileSizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useGB, .useMB, .useKB, .useBytes]
        f.countStyle = .file
        return f
    }()

    // Input list and initial index
    @State private var photos: [ServerPhoto]
    @State private var currentIndex: Int
    // Paging: parent supplies next page loader; returns newly added items
    let onRequestNextPage: (() async -> [ServerPhoto]?)?
    let onDismiss: (() -> Void)?

    // UI State
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var isPanning = false
    @State private var lastTap: (Date, CGPoint)? = nil
    @State private var showInfo = false
    @State private var showAlbumTree = false
    @State private var albumTreeSelectedId: Int? = nil
    @State private var showUpdatePerson = false
    @State private var showShareSheet = false
    @State private var isSaving = false
    @State private var membership: [ServerAlbum] = []
    @State private var rating: Int? = nil
    @State private var captionText: String = ""
    @State private var descriptionText: String = ""
    @State private var isFavorite: Bool = false
    @State private var eeEnabled: Bool = false

    // Video state
    @State private var player: AVPlayer? = nil
    @State private var isVideoPaused: Bool = true
    @State private var isVideoMuted: Bool = false
    @State private var videoDuration: Double = 0
    @State private var videoTime: Double = 0
    @State private var scrubbing: Bool = false
    @State private var videoTimeObserverToken: Any? = nil
    @State private var videoLoadToken: UUID = UUID()
    @State private var lastAssetId: String = ""
    @State private var viewerIsActive: Bool = true
    @State private var videoItemStatusObserver: NSKeyValueObservation? = nil
    @State private var videoPlayerTimeControlObserver: NSKeyValueObservation? = nil
    @State private var videoItemKeepUpObserver: NSKeyValueObservation? = nil
    @State private var videoItemBufferEmptyObserver: NSKeyValueObservation? = nil
    @State private var videoErrorMessage: String? = nil
    @State private var isVideoBuffering: Bool = false
    @State private var livePlaybackEnded: Bool = false

    // Cache: light cache for full images
    @State private var imageCache: [String: UIImage] = [:]
    @State private var isLoadingImage: Bool = false
    // Prevent tight retry loops for permanently broken assets (corrupt bytes, missing file, etc).
    @State private var failedImageAssetIds: Set<String> = []
    // Track in-flight loads to avoid duplicate fetches (e.g. hydrateUI + view `.task`).
    @State private var inFlightImageAssetIds: Set<String> = []

    init(photos: [ServerPhoto], index: Int, onRequestNextPage: (() async -> [ServerPhoto]?)? = nil, onDismiss: (() -> Void)? = nil) {
        let safePhotos = photos
        let safeIndex: Int
        if safePhotos.isEmpty {
            safeIndex = 0
        } else if index < 0 {
            safeIndex = 0
        } else if index >= safePhotos.count {
            safeIndex = safePhotos.count - 1
        } else {
            safeIndex = index
        }
        _photos = State(initialValue: safePhotos)
        _currentIndex = State(initialValue: safeIndex)
        self.onRequestNextPage = onRequestNextPage
        self.onDismiss = onDismiss
    }

    private var current: ServerPhoto {
        if photos.indices.contains(currentIndex) {
            return photos[currentIndex]
        } else if let first = photos.first {
            return first
        } else {
            // Fallback placeholder; viewer should not normally be shown with an empty list.
            return ServerPhoto(
                id_num: nil,
                asset_id: "",
                filename: nil,
                mime_type: "image/jpeg",
                created_at: 0,
                modified_at: nil,
                size: nil,
                width: nil,
                height: nil,
                favorites: nil,
                locked: nil,
                delete_time: nil,
                is_video: false,
                is_live_photo: nil,
                duration_ms: nil,
                is_screenshot: nil,
                caption: nil,
                description: nil,
                rating: nil,
                camera_make: nil,
                camera_model: nil,
                iso: nil,
                aperture: nil,
                shutter_speed: nil,
                focal_length: nil,
                latitude: nil,
                longitude: nil,
                altitude: nil,
                location_name: nil,
                city: nil,
                province: nil,
                country: nil
            )
        }
    }
    private var isVideo: Bool { current.is_video || (current.is_live_photo ?? false) }
    private var isLive: Bool { (current.is_live_photo ?? false) && !current.is_video }

    var body: some View {
        NavigationView {
            ZStack {
                Color.black

                Group {
                    if isVideo {
                        videoSurface
                    } else {
                        imageSurface
                    }
                }

                // Bottom overlay: video controls (if video)
                if isVideo { videoControls }

                // Modal progress overlay for long-running saves (especially large videos).
                if isSaving { savingOverlay }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color.black.opacity(0.6), for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { close() }) { Image(systemName: "xmark") }
                }
                ToolbarItem(placement: .navigationBarTrailing) { actionsMenu }
            }
            .onAppear {
                viewerIsActive = true
                Task { await hydrateUI(); await prefetchNeighbors() }
            }
            .onChange(of: currentIndex) { _ in Task { await hydrateUI(); await prefetchNeighbors() } }
            .onDisappear {
                viewerIsActive = false
                cleanupOnDismiss()
            }
            .fullScreenCover(isPresented: $showInfo) { infoPanel }
            .sheet(isPresented: $showAlbumTree) { albumTreeSheet }
            .sheet(isPresented: $showUpdatePerson) { UpdatePersonOverlay(assetId: current.asset_id, onDone: { showUpdatePerson = false }) }
            .sheet(isPresented: $showShareSheet) { EEInlineShareSheet(assetId: current.asset_id, filename: current.filename ?? current.asset_id) }
        }
    }

    private var savingOverlay: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().tint(.white)
                Text("Saving to Photos…")
                    .foregroundColor(.white)
                    .font(.headline)
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.75)))
        }
        // Block interactions while saving to avoid confusing UI state.
        .allowsHitTesting(true)
    }

    // MARK: - Surfaces
    private var imageSurface: some View {
        GeometryReader { geo in
            ZStack {
                if let img = imageCache[current.asset_id] {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(panAndPinchGestures())
                        .gesture(doubleTapZoom(in: geo))
                        .contentShape(Rectangle())
                        .simultaneousGesture(swipeNavGesture(height: geo.size.height))
                } else if failedImageAssetIds.contains(current.asset_id) {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 34))
                            .foregroundColor(.yellow)
                        Text("Unable to load image")
                            .foregroundColor(.white)
                            .font(.headline)
                        Button("Retry") {
                            failedImageAssetIds.remove(current.asset_id)
                            Task { await loadCurrentImage() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                } else if isLoadingImage {
                    ProgressView().tint(.white)
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    Color.black.frame(width: geo.size.width, height: geo.size.height)
                        .onAppear {
                            let assetId = current.asset_id
                            guard !assetId.isEmpty else { return }
                            // Use an unstructured task here. A `.task` attached to this branch gets
                            // canceled immediately when `isLoadingImage` flips true (branch swap),
                            // causing an endless cancel/restart loop.
                            if imageCache[assetId] == nil && !failedImageAssetIds.contains(assetId) {
                                Task { await loadImage(assetId: assetId) }
                            }
                        }
                }
                if isLive {
                    liveBadge
                        .padding(.top, 12)
                        .padding(.leading, 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
    }

    private var videoSurface: some View {
        ZStack {
            if let msg = videoErrorMessage {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 44))
                        .foregroundColor(.yellow)
                    Text("Unable to play video")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text(msg)
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Button("Close") { close() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.vertical, 28)
            } else if isLive, livePlaybackEnded, let img = imageCache[current.asset_id] {
                // After the Live Photo's motion finishes, return to the still portion.
                Image(uiImage: img).resizable().scaledToFit().background(Color.black)
                    .gesture(swipeNavGesture(height: UIScreen.main.bounds.height))
            } else if let p = player {
                // Use a controls-free surface so we can render a single custom control strip
                // (avoids duplicate system scrubbers/volume bars).
                ControlsFreePlayerSurface(player: p)
                    .id(current.asset_id) // ensure fresh mount per asset to avoid stale player state
                    .onDisappear { p.pause() }
                    .onReceive(
                        NotificationCenter.default.publisher(
                            for: .AVPlayerItemDidPlayToEndTime,
                            object: p.currentItem
                        )
                    ) { _ in
                        isVideoPaused = true
                        isVideoBuffering = false
                        if isLive {
                            livePlaybackEnded = true
                            // Prep for quick replay (otherwise play() at EOF is a no-op).
                            p.pause()
                            p.seek(to: .zero)
                            MediaAudioSession.shared.deactivateAfterPlayback()
                        }
                    }
                if isVideoBuffering {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.2)
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.55)))
                        .allowsHitTesting(false)
                }
            } else if let img = imageCache[current.asset_id] {
                Image(uiImage: img).resizable().scaledToFit().background(Color.black)
                    .gesture(swipeNavGesture(height: UIScreen.main.bounds.height))
                    .task {
                        // Autoplay the Live Photo's motion only once; after it ends we stay on the still.
                        if !(isLive && livePlaybackEnded) {
                            await prepareVideo()
                        }
                    }
            } else {
                // Start video playback ASAP; avoid blocking on any image fetch (which could be large for videos).
                ProgressView().tint(.white).task {
                    let assetId = current.asset_id
                    if isLive && imageCache[assetId] == nil {
                        await loadImage(assetId: assetId)
                    }
                    await prepareVideo()
                }
            }
            if isLive && (player == nil || livePlaybackEnded) {
                liveBadge
                    .padding(.top, 12)
                    .padding(.leading, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .simultaneousGesture(swipeNavGesture(height: UIScreen.main.bounds.height))
    }

    private var liveBadge: some View {
        HStack(spacing: 6) {
            Circle().stroke(Color.white, lineWidth: 2).frame(width: 12, height: 12)
            Text("Live").foregroundColor(.white).font(.footnote).bold()
        }
        .padding(6)
        .background(Color.black.opacity(0.5)).clipShape(Capsule())
    }

    // MARK: - Top Bar
    private var topBar: some View {
        HStack { EmptyView() }
    }

    // Actions menu used in the navigation bar
    private var actionsMenu: some View {
        Menu {
            Button(isFavorite ? "Unfavorite" : "Favorite") { Task { await toggleFavorite() } }
            Button("Info") { showInfo = true }
            if (current.locked ?? false) {
                Button("Unlock") { Task { await unlock() } }
            } else {
                Button("Lock") { Task { await lock() } }
            }
            Button("Download to Photos") { Task { await onSave() } }
            Button("Add to Album…") { albumTreeSelectedId = nil; showAlbumTree = true }
            Button("Update Faces…") { showUpdatePerson = true }
            if eeEnabled { Button("Share…") { showShareSheet = true } }
            if !membership.isEmpty {
                Section(header: Text("Albums")) {
                    ForEach(membership, id: \.id) { a in
                        Button {
                            Task { await removeFromAlbum(a.id) }
                        } label: {
                            HStack {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                                Text(a.name)
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
    }

    // MARK: - Video Controls
    private var videoControls: some View {
        VStack {
            Spacer()
            VStack(spacing: 12) {
                if videoDuration.isFinite && videoDuration > 0 {
                    VideoScrubber(
                        currentTime: $videoTime,
                        duration: videoDuration,
                        scrubbing: $scrubbing,
                        onSeek: { t in seek(to: t) }
                    )
                    .padding(.horizontal, 16)
                }
                HStack(spacing: 12) {
                    Button(action: { togglePlayPause() }) {
                        Image(systemName: isVideoPaused ? "play.fill" : "pause.fill").foregroundColor(.white)
                            .padding(10).background(Color.black.opacity(0.5)).clipShape(Circle())
                    }
                    Button(action: { toggleMute() }) {
                        Image(systemName: isVideoMuted ? "speaker.slash.fill" : "speaker.2.fill").foregroundColor(.white)
                            .padding(10).background(Color.black.opacity(0.5)).clipShape(Circle())
                    }
                    Button(action: { replay() }) {
                        Image(systemName: "arrow.counterclockwise").foregroundColor(.white)
                            .padding(10).background(Color.black.opacity(0.5)).clipShape(Circle())
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 34)
        }
    }

    // MARK: - Info Panel Sheet
    private var infoPanel: some View {
        NavigationView {
            Form {
                Section(header: Text("File")) {
                    HStack { Text("Name"); Spacer(); Text(current.filename ?? current.asset_id).foregroundColor(.secondary) }
                    HStack { Text("Asset ID"); Spacer(); Text(current.asset_id).foregroundColor(.secondary) }
                    if let size = current.size { HStack { Text("Size"); Spacer(); Text(Self.fileSizeFormatter.string(fromByteCount: size)).foregroundColor(.secondary) } }
                    if let w = current.width, let h = current.height { HStack { Text("Dimensions"); Spacer(); Text("\(w) × \(h)").foregroundColor(.secondary) } }
                }
                Section(header: Text("Camera")) {
                    HStack { Text("Make/Model"); Spacer(); Text("\(current.camera_make ?? "") \(current.camera_model ?? "")").foregroundColor(.secondary) }
                    HStack { Text("ISO"); Spacer(); Text(current.iso != nil ? "ISO \(current.iso!)" : "—").foregroundColor(.secondary) }
                    HStack { Text("Aperture"); Spacer(); Text(current.aperture != nil ? "f/\(current.aperture!)" : "—").foregroundColor(.secondary) }
                    HStack { Text("Shutter"); Spacer(); Text(current.shutter_speed ?? "—").foregroundColor(.secondary) }
                    HStack { Text("Focal"); Spacer(); Text(current.focal_length != nil ? "\(current.focal_length!)mm" : "—").foregroundColor(.secondary) }
                }
                Section(header: Text("Dates")) {
                    HStack { Text("Taken"); Spacer(); Text(Date(timeIntervalSince1970: TimeInterval(current.created_at)).formatted()).foregroundColor(.secondary) }
                    if let m = current.modified_at { HStack { Text("Modified"); Spacer(); Text(Date(timeIntervalSince1970: TimeInterval(m)).formatted()).foregroundColor(.secondary) } }
                }
                Section(header: Text("Location")) {
                    Text(current.location_name ?? [current.city, current.province, current.country].compactMap { $0 }.joined(separator: ", ")).foregroundColor(.secondary)
                }
                Section(header: Text("Rating")) { ratingStars }
                Section(header: Text("Caption")) {
                    TextField("Caption", text: $captionText)
                        .onSubmit { Task { await saveMetadata() } }
                        .onChange(of: captionText) { _ in }
                }
                Section(header: Text("Description")) {
                    TextEditor(text: $descriptionText)
                        .frame(minHeight: 80)
                }
                Section(header: Text("People")) {
                    PeopleListView(assetId: current.asset_id)
                }
            }
            .navigationTitle("Info")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: { showInfo = false }) {
                        Image(systemName: "xmark")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await saveMetadata(); showInfo = false } }
                }
            }
        }
    }

    private var ratingStars: some View {
        HStack(spacing: 8) {
            ForEach(1...5, id: \.self) { i in
                Image(systemName: (rating ?? 0) >= i ? "star.fill" : "star")
                    .foregroundColor(.yellow)
                    .onTapGesture { Task { await setRating(i) } }
            }
            if rating != nil { Button("Clear") { Task { await setRating(nil) } } }
        }
    }

    // MARK: - Album Tree Sheet
    private var albumTreeSheet: some View {
        ServerAlbumTreeView(
            isPresented: $showAlbumTree,
            includeSubalbums: .constant(true),
            selectedAlbumId: $albumTreeSelectedId,
            onAlbumSelected: { id in
                Task { await addToAlbum(id) }
            },
            onAlbumSelectedWithName: nil,
            onAlbumsChanged: {
                Task { await reloadMembership() }
            }
        )
    }

    // MARK: - Gestures
    private func panAndPinchGestures() -> some Gesture {
        let drag = DragGesture(minimumDistance: 0)
            .onChanged { v in if scale > 1 { isPanning = true; offset = v.translation } }
            .onEnded { _ in isPanning = false }
        let pinch = MagnificationGesture()
            .onChanged { s in
                scale = max(1, min(5, s))
            }
        return SimultaneousGesture(drag, pinch)
    }

    private func doubleTapZoom(in geo: GeometryProxy) -> some Gesture {
        TapGesture(count: 2).onEnded {
            if scale > 1 { scale = 1; offset = .zero }
            else { scale = 2 }
        }
    }

    private func swipeNavGesture(height: CGFloat) -> some Gesture {
        DragGesture()
            .onEnded { v in
                // Swipe down to save
                if abs(v.translation.height) > 80 && v.translation.height > 0 && scale == 1 {
                    Task { await onSave() }
                    return
                }
                // Horizontal navigation at 1x
                if scale == 1 && abs(v.translation.width) > 50 {
                    if v.translation.width < 0 { next() } else { prev() }
                }
            }
    }

    // MARK: - Actions
    private func close() {
        // Stop any ongoing playback immediately before dismissing the viewer.
        // This avoids cases where the player continues audio briefly while SwiftUI tears down the hierarchy.
        viewerIsActive = false
        cleanupOnDismiss()
        onDismiss?()
        dismiss()
    }

    @MainActor
    private func stopPlayback() {
        // Stop observing the old item. Observers must be invalidated before the player/item is released.
        videoItemStatusObserver?.invalidate()
        videoItemStatusObserver = nil
        videoPlayerTimeControlObserver?.invalidate()
        videoPlayerTimeControlObserver = nil
        videoItemKeepUpObserver?.invalidate()
        videoItemKeepUpObserver = nil
        videoItemBufferEmptyObserver?.invalidate()
        videoItemBufferEmptyObserver = nil

        // Remove the periodic time observer (otherwise it can keep firing after we swap items).
        if let token = videoTimeObserverToken, let p = player {
            p.removeTimeObserver(token)
        }
        videoTimeObserverToken = nil

        player?.pause()
        // Release the current item to stop any in-flight streaming pipeline immediately.
        player?.replaceCurrentItem(with: nil)
        player = nil

        // Ensure audio stops immediately even if an AVPlayer teardown race occurs.
        MediaAudioSession.shared.deactivateAfterPlayback()

        isVideoPaused = true
        isVideoMuted = false
        videoDuration = 0
        videoTime = 0
        scrubbing = false
        isVideoBuffering = false
    }

    @MainActor
    private func attachVideoItemObserver(for player: AVPlayer, token: UUID) {
        // Ensure we observe only the currently playing item.
        videoItemStatusObserver?.invalidate()
        videoItemStatusObserver = nil
        videoPlayerTimeControlObserver?.invalidate()
        videoPlayerTimeControlObserver = nil
        videoItemKeepUpObserver?.invalidate()
        videoItemKeepUpObserver = nil
        videoItemBufferEmptyObserver?.invalidate()
        videoItemBufferEmptyObserver = nil

        guard let item = player.currentItem else { return }
        videoItemStatusObserver = item.observe(\.status, options: [.initial, .new]) { item, _ in
            guard item.status == .failed else { return }
            let message = item.error?.localizedDescription ?? "Unknown playback error"
            Task { @MainActor in
                // If the user dismissed/navigated away, ignore late failures.
                guard viewerIsActive && videoLoadToken == token else { return }
                videoErrorMessage = message
                stopPlayback()
            }
        }

        videoPlayerTimeControlObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) { player, _ in
            Task { @MainActor in
                guard viewerIsActive && videoLoadToken == token else { return }
                updateVideoBufferingState(for: player, token: token)
            }
        }

        videoItemKeepUpObserver = item.observe(\.isPlaybackLikelyToKeepUp, options: [.initial, .new]) { _, _ in
            Task { @MainActor in
                guard viewerIsActive && videoLoadToken == token else { return }
                updateVideoBufferingState(for: player, token: token)
            }
        }

        videoItemBufferEmptyObserver = item.observe(\.isPlaybackBufferEmpty, options: [.initial, .new]) { _, _ in
            Task { @MainActor in
                guard viewerIsActive && videoLoadToken == token else { return }
                updateVideoBufferingState(for: player, token: token)
            }
        }
    }

    @MainActor
    private func updateVideoBufferingState(for player: AVPlayer, token: UUID) {
        guard viewerIsActive && videoLoadToken == token else { return }
        // Only show buffering when we intend to be playing. If the user paused, hide the indicator.
        guard !isVideoPaused else {
            isVideoBuffering = false
            return
        }
        guard let item = player.currentItem else {
            isVideoBuffering = true
            return
        }
        if item.status != .readyToPlay {
            isVideoBuffering = true
            return
        }
        if item.isPlaybackBufferEmpty {
            isVideoBuffering = true
            return
        }
        if !item.isPlaybackLikelyToKeepUp {
            isVideoBuffering = true
            return
        }
        isVideoBuffering = (player.timeControlStatus == .waitingToPlayAtSpecifiedRate)
    }

    private func cleanupOnDismiss() {
        // Release heavy resources and reset transient state so subsequent openings are fresh.
        // Invalidate in-flight async work (e.g. network fetch finishing after dismiss).
        viewerIsActive = false
        videoLoadToken = UUID()
        stopPlayback()
        videoErrorMessage = nil
        imageCache.removeAll()
        inFlightImageAssetIds.removeAll()
        isLoadingImage = false
        scale = 1
        offset = .zero
    }

    private func next() {
        if currentIndex < photos.count - 1 {
            withAnimation(.easeInOut(duration: 0.2)) { currentIndex += 1; resetZoom() }
        } else {
            Task { await loadNextPageAndAdvance() }
        }
    }
    private func prev() {
        if currentIndex > 0 {
            withAnimation(.easeInOut(duration: 0.2)) { currentIndex -= 1; resetZoom() }
        }
    }
    private func resetZoom() { scale = 1; offset = .zero }

    private func togglePlayPause() {
        guard let p = player else { return }
        if isLive && livePlaybackEnded {
            replay()
            livePlaybackEnded = false
            return
        }
        if isVideoPaused {
            isVideoBuffering = true
            p.play()
        } else {
            p.pause()
            isVideoBuffering = false
        }
        isVideoPaused.toggle()
    }
    private func toggleMute() {
        guard let p = player else { return }
        p.isMuted.toggle(); isVideoMuted = p.isMuted
    }
    private func replay() {
        // Replay from the beginning and resume playback. This is useful after reaching end and
        // matches common gallery app behavior.
        guard let p = player else { return }
        livePlaybackEnded = false
        p.seek(to: .zero) { _ in
            p.play()
        }
        isVideoPaused = false
        videoTime = 0
    }
    private func seek(to t: Double) { guard let p = player else { return }; p.seek(to: CMTime(seconds: t, preferredTimescale: 600)) }

    private func onSave() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            if isLive { try await PhotoSaveHelper.saveLivePhoto(assetId: current.asset_id, filename: current.filename) }
            else if isVideo { try await PhotoSaveHelper.saveVideo(assetId: current.asset_id, filename: current.filename) }
            else { try await PhotoSaveHelper.saveImage(assetId: current.asset_id, filename: current.filename) }
            HapticsManager.shared.playAdd(); ToastManager.shared.show("Saved to Photos")
        } catch {
            HapticsManager.shared.playError(); ToastManager.shared.show("Save failed: \(error.localizedDescription)")
        }
    }

    private func toggleFavorite() async {
        do {
            let next = !(isFavorite)
            try await ServerPhotosService.shared.setFavorite(assetId: current.asset_id, favorite: next)
            await MainActor.run { isFavorite = next }
        } catch { ToastManager.shared.show("Favorite failed") }
    }

    private func setRating(_ value: Int?) async {
        do {
            try await ServerPhotosService.shared.updateRating(assetId: current.asset_id, rating: value)
            await MainActor.run { rating = value }
        } catch { ToastManager.shared.show("Rating failed") }
    }

    private func saveMetadata() async {
        do { try await ServerPhotosService.shared.updateMetadata(assetId: current.asset_id, caption: captionText, description: descriptionText); ToastManager.shared.show("Saved") } catch { ToastManager.shared.show("Save failed") }
    }

    private func reloadMembership() async {
        do {
            // Resolve numeric ID via by-ids hydrator
            let mapped = try await ServerPhotosService.shared.getPhotosByAssetIds([current.asset_id])
            if let nid = mapped.first?.id_num { let a = try await ServerPhotosService.shared.getAlbumsForPhoto(photoId: nid); await MainActor.run { membership = a } }
        } catch { await MainActor.run { membership = [] } }
    }

    private func addToAlbum(_ albumId: Int) async {
        do {
            // Use numeric id resolve for album op
            let mapped = try await ServerPhotosService.shared.getPhotosByAssetIds([current.asset_id])
            if let nid = mapped.first?.id_num {
                _ = try await ServerPhotosService.shared.addPhotosToAlbum(albumId: albumId, assetIds: [current.asset_id])
                await reloadMembership()
                ToastManager.shared.show("Added to album")
            }
        } catch { ToastManager.shared.show("Add failed") }
    }
    private func removeFromAlbum(_ albumId: Int) async {
        do {
            _ = try await ServerPhotosService.shared.removePhotosFromAlbum(albumId: albumId, assetIds: [current.asset_id])
            await reloadMembership()
            ToastManager.shared.show("Removed from album")
        } catch { ToastManager.shared.show("Remove failed") }
    }

    private func lock() async {
        guard E2EEManager.shared.hasValidUMKRespectingTTL() || E2EEManager.shared.unlockWithDeviceKey(prompt: "Unlock to lock item") else { ToastManager.shared.show("Unlock required"); return }
        do {
            try await ServerPhotosService.shared.lockWithEncryption(photo: current)
            await hydrateUI()
            ToastManager.shared.show("Locked")
        } catch {
            let msg = (error as NSError).localizedDescription
            ToastManager.shared.show(msg.isEmpty ? "Lock failed" : msg)
        }
    }
    private func unlock() async {
        // Unlock is server-side via metadata change path; in OSS we support one-way lock. Keep UI feedback only.
        ToastManager.shared.show("Unlock not supported on server")
    }

    // MARK: - Data hydration / prefetch
    private func hydrateUI() async {
        // If the viewed asset changed (or we're opening for the first time), stop any previous playback.
        // This avoids “audio continues from previous item” and ensures `videoSurface` can start a fresh load.
        let assetId = current.asset_id
        await MainActor.run {
            if lastAssetId != assetId {
                // Invalidate any in-flight async work for the previous asset.
                videoLoadToken = UUID()
                videoErrorMessage = nil
                livePlaybackEnded = false
                stopPlayback()
                lastAssetId = assetId
            }
        }

        await MainActor.run {
            isFavorite = (current.favorites ?? 0) > 0
            rating = current.rating
            captionText = current.caption ?? ""
            descriptionText = current.description ?? ""
        }
        await reloadMembership()
        do { let caps = try await CapabilitiesService.shared.get(force: true); await MainActor.run { eeEnabled = (caps.ee ?? false) } } catch { await MainActor.run { eeEnabled = false } }
        // Only fetch original image bytes for non-video assets. Fetching `/api/images/:asset_id` for
        // videos can be huge and can delay video startup if awaited.
        if imageCache[assetId] == nil && !current.is_video { await loadCurrentImage() }
        // Video playback is initiated by `videoSurface` via `.task { await prepareVideo() }`.
    }

    private func prefetchNeighbors() async {
        let i = currentIndex
        for idx in [i + 1, i - 1] {
            guard idx >= 0 && idx < photos.count else { continue }
            // Avoid fetching original bytes for videos; thumbnails are handled elsewhere.
            if photos[idx].is_video { continue }
            let id = photos[idx].asset_id
            if imageCache[id] == nil { await loadImage(assetId: id) }
        }
    }

    private func loadCurrentImage() async { await loadImage(assetId: current.asset_id) }
    private func loadImage(assetId: String) async {
        let isCurrentAtStart = await MainActor.run { assetId == current.asset_id }
        let didStart = await MainActor.run { () -> Bool in
            if inFlightImageAssetIds.contains(assetId) { return false }
            inFlightImageAssetIds.insert(assetId)
            if isCurrentAtStart {
                isLoadingImage = true
                // Clear prior failure so a user-initiated retry can succeed.
                failedImageAssetIds.remove(assetId)
            }
            return true
        }
        guard didStart else { return }
        defer {
            // Detached so cleanup runs even if this load task is cancelled.
            Task.detached { @MainActor in
                inFlightImageAssetIds.remove(assetId)
                if isCurrentAtStart && assetId == current.asset_id {
                    isLoadingImage = false
                }
            }
        }

        // 1) Disk cache first
        if let data = DiskImageCache.shared.readData(bucket: .images, key: assetId), let img = UIImage(data: data) {
            await MainActor.run {
                imageCache[assetId] = img
                failedImageAssetIds.remove(assetId)
                if isCurrentAtStart && assetId == current.asset_id { isLoadingImage = false }
            }
            return
        } else if let url = DiskImageCache.shared.readURL(bucket: .images, key: assetId), let img = UIImage(contentsOfFile: url.path) {
            await MainActor.run {
                imageCache[assetId] = img
                failedImageAssetIds.remove(assetId)
                if isCurrentAtStart && assetId == current.asset_id { isLoadingImage = false }
            }
            return
        }

        let maxAttempts = isCurrentAtStart ? 2 : 1
        for attempt in 0..<maxAttempts {
            // 2) Fetch original image bytes; handle locked via PAE3 decrypt. Use AuthorizedHTTPClient for auth/refresh.
            let url = AuthorizedHTTPClient.shared.buildURL(path: "/api/images/" + (assetId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? assetId))
            var req = URLRequest(url: url)
            req.timeoutInterval = 30
            // Prefer original HEIC when supported by the client
            req.setValue("image/heic, image/*;q=0.8", forHTTPHeaderField: "Accept")

            do {
                let (data, http) = try await AuthorizedHTTPClient.shared.request(req)
                let ct = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()

                if ct.starts(with: "application/octet-stream") {
                    guard let umk = E2EEManager.shared.umk, let userId = AuthManager.shared.userId else {
                        throw NSError(domain: "E2EE", code: 1, userInfo: [NSLocalizedDescriptionKey: "Locked item not yet unlocked"])
                    }
                    let encURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pae3")
                    let outURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    try data.write(to: encURL)
                    try pae3DecryptFile(umk: umk, userIdKey: Data(userId.utf8), input: encURL, output: outURL)
                    guard let plain = try? Data(contentsOf: outURL) else {
                        try? FileManager.default.removeItem(at: encURL); try? FileManager.default.removeItem(at: outURL)
                        throw NSError(domain: "E2EE", code: 2, userInfo: [NSLocalizedDescriptionKey: "Decrypt failed"])
                    }
                    // Persist decrypted image with strong protection; attempt to infer extension from filename
                    let ext = (current.filename as NSString?)?.pathExtension
                    if DiskImageCache.shared.write(bucket: .images, key: assetId, data: plain, ext: ext?.isEmpty == false ? ext : nil, protection: .complete) == nil {
                        print("[FULLSCREEN] ⚠️ Cache write failed for locked image asset=\(assetId)")
                    }
                    let decodedOK = await MainActor.run { () -> Bool in
                        guard let img = UIImage(data: plain) else { return false }
                        imageCache[assetId] = img
                        failedImageAssetIds.remove(assetId)
                        return true
                    }
                    try? FileManager.default.removeItem(at: encURL); try? FileManager.default.removeItem(at: outURL)
                    if !decodedOK {
                        throw NSError(domain: "IMG", code: 1, userInfo: [NSLocalizedDescriptionKey: "Image decode failed"])
                    }
                    return
                } else {
                    // Persist as-is to disk; choose extension by content-type when possible
                    let ext: String? = ct.contains("image/heic") ? "heic" : (ct.contains("jpeg") ? "jpg" : (ct.contains("png") ? "png" : nil))
                    if DiskImageCache.shared.write(bucket: .images, key: assetId, data: data, ext: ext) == nil {
                        print("[FULLSCREEN] ⚠️ Cache write failed for unlocked image asset=\(assetId)")
                    }
                    let decodedOK = await MainActor.run { () -> Bool in
                        guard let img = UIImage(data: data) else { return false }
                        imageCache[assetId] = img
                        failedImageAssetIds.remove(assetId)
                        return true
                    }
                    if !decodedOK {
                        throw NSError(domain: "IMG", code: 1, userInfo: [NSLocalizedDescriptionKey: "Image decode failed"])
                    }
                    return
                }
            } catch {
                if (error is CancellationError) || (error as? URLError)?.code == .cancelled {
                    return
                }
                let ns = error as NSError
                if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
                    return
                }

                if isCurrentAtStart, attempt < (maxAttempts - 1), isRetryableImageLoadError(error) {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    continue
                }

                if isCurrentAtStart {
                    await MainActor.run { failedImageAssetIds.insert(assetId) }
                    ToastManager.shared.show("Failed to load image")
                }
                return
            }
        }
    }

    private func isRetryableImageLoadError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet, .dnsLookupFailed:
                return true
            default:
                return false
            }
        }
        let ns = error as NSError
        if ns.domain == "HTTP" {
            if ns.code == 408 || ns.code == 429 { return true }
            if (500...599).contains(ns.code) { return true }
        }
        if ns.domain == "E2EE" {
            return true
        }
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
        return false
    }

    private func prepareVideo() async {
        // Ensure audio session is configured so video playback has sound even in silent mode.
        // This is a no-op after the first call.
        await MainActor.run { MediaAudioSession.shared.configureForVideoPlaybackIfNeeded() }

        // Token-gate this async load so a late completion cannot restart playback after the user dismisses.
        let token = UUID()
        let activated = await MainActor.run { () -> Bool in
            guard viewerIsActive else { return false }
            videoLoadToken = token
            videoErrorMessage = nil
            return true
        }
        guard activated else { return }

        func stillCurrent() async -> Bool {
            await MainActor.run { viewerIsActive && videoLoadToken == token }
        }

        func failVideo(_ message: String) async {
            await MainActor.run {
                guard viewerIsActive && videoLoadToken == token else { return }
                videoErrorMessage = message
                stopPlayback()
            }
        }

        // Watchdog: AVPlayer can sometimes stay in an indeterminate loading state (no readyToPlay, no failed).
        // Avoid an infinite spinner by timing out and presenting an error the user can act on.
        Task { [token] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            await MainActor.run {
                guard viewerIsActive && videoLoadToken == token else { return }
                guard videoErrorMessage == nil else { return }
                if let item = player?.currentItem {
                    if item.status != .readyToPlay {
                        videoErrorMessage = "Timed out loading video"
                        stopPlayback()
                    }
                } else if player == nil {
                    videoErrorMessage = "Unable to start video playback"
                    stopPlayback()
                }
            }
        }

        // Prefer cached local video when available. For v1 we cache /api/live only.
        let enc = current.asset_id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? current.asset_id
        if let local = DiskImageCache.shared.readURL(bucket: .videos, key: current.asset_id) {
            let p = AVPlayer(url: local)
            await MainActor.run {
                guard viewerIsActive && videoLoadToken == token else { return }
                stopPlayback()
                player = p
                isVideoMuted = p.isMuted
                attachVideoItemObserver(for: p, token: token)
                isVideoBuffering = true
                p.play(); isVideoPaused = false
            }
            Task {
                guard await stillCurrent(), !Task.isCancelled else { return }
                let d = (try? await p.currentItem?.asset.load(.duration)) ?? .zero
                let secs = CMTimeGetSeconds(d)
                await MainActor.run {
                    guard viewerIsActive && videoLoadToken == token else { return }
                    if secs.isFinite, secs > 0 { videoDuration = secs }
                    let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
                    videoTimeObserverToken = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { t in
                        if !scrubbing { videoTime = CMTimeGetSeconds(t) }
                    }
                }
            }
            return
        }

        // Live items:
        // - Locked: must download + decrypt before playback (no server-side access to plaintext for streaming).
        // - Unlocked: stream with Range support so playback can start before the full file is downloaded.
        if isLive {
            if (current.locked ?? false) {
                // Locked live: fetch PAE3 and decrypt to MOV
                guard let userId = AuthManager.shared.userId else {
                    await failVideo("Not logged in")
                    return
                }
                if E2EEManager.shared.umk == nil {
                    let unlocked = await MainActor.run {
                        E2EEManager.shared.hasValidUMKRespectingTTL() || E2EEManager.shared.unlockWithDeviceKey(prompt: "Unlock to play locked Live Photo")
                    }
                    if !unlocked || E2EEManager.shared.umk == nil {
                        await failVideo("Unlock required to play locked Live Photo")
                        return
                    }
                }
                guard let umk = E2EEManager.shared.umk else {
                    await failVideo("Unlock required to play locked Live Photo")
                    return
                }
                let url = AuthorizedHTTPClient.shared.buildURL(path: "/api/live-locked/\(enc)")
                var req = URLRequest(url: url)
                AuthManager.shared.authHeader().forEach { k, v in req.setValue(v, forHTTPHeaderField: k) }
                do {
                    let (data, resp) = try await URLSession.shared.data(for: req)
                    if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        await failVideo("Locked Live Photo download failed (\(http.statusCode))")
                        return
                    }
                    guard await stillCurrent(), !Task.isCancelled else { return }
                    let encURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pae3")
                    let outURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
                    try data.write(to: encURL)
                    try pae3DecryptFile(umk: umk, userIdKey: Data(userId.utf8), input: encURL, output: outURL)
                    if let plain = try? Data(contentsOf: outURL) {
                        if let local = DiskImageCache.shared.write(bucket: .videos, key: current.asset_id, data: plain, ext: "mov", protection: .complete) {
                            let p = AVPlayer(url: local)
                            await MainActor.run {
                                guard viewerIsActive && videoLoadToken == token else { return }
                                stopPlayback()
                                player = p
                                isVideoMuted = p.isMuted
                                attachVideoItemObserver(for: p, token: token)
                                isVideoBuffering = true
                                p.play()
                                isVideoPaused = false
                            }
                            Task {
                                guard await stillCurrent(), !Task.isCancelled else { return }
                                let d = (try? await p.currentItem?.asset.load(.duration)) ?? .zero
                                let secs = CMTimeGetSeconds(d)
                                await MainActor.run {
                                    guard viewerIsActive && videoLoadToken == token else { return }
                                    if secs.isFinite, secs > 0 { videoDuration = secs }
                                    let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
                                    videoTimeObserverToken = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { t in
                                        if !scrubbing { videoTime = CMTimeGetSeconds(t) }
                                    }
                                }
                            }
                        } else {
                            print("[VIDEO] ⚠️ Cache write failed for locked live video asset=\(current.asset_id)")
                            await failVideo("Unable to cache decrypted Live Photo video")
                            try? FileManager.default.removeItem(at: encURL); try? FileManager.default.removeItem(at: outURL)
                            return
                        }
                    }
                    try? FileManager.default.removeItem(at: encURL); try? FileManager.default.removeItem(at: outURL)
                    return
                } catch {
                    await failVideo("Locked Live Photo decrypt failed: \(error.localizedDescription)")
                    return
                }
            } else {
                // Unlocked live: prefer streaming so playback can start as soon as enough bytes are buffered.
                // The server supports HTTP range requests for `/api/live/:asset_id`, enabling progressive playback.
                // If needed later, we can add background caching; we intentionally avoid blocking playback here.
            }
        }

        // Fallback to streaming (non-live or failures)
        let path = (isLive && !(current.is_video)) ? "/api/live/\(enc)" : "/api/images/\(enc)"
        let url = AuthorizedHTTPClient.shared.buildURL(path: path)
        let headers = AuthManager.shared.authHeader()
        // Use the documented AVURLAsset option key as a string to keep compatibility across SDKs.
        let opts: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": headers]
        let asset = AVURLAsset(url: url, options: opts)
        let item = AVPlayerItem(asset: asset)
        // Buffering policy:
        // - The old fixed value (8s) caused huge initial Range requests for high‑bitrate videos, which
        //   increased startup latency and made playback look “stuck on the first frame”.
        // - Use a small, bitrate-aware buffer window to start quickly while still reducing stalls.
        let forwardBufferSeconds: Double = {
            guard let size = current.size, let ms = current.duration_ms, size > 0, ms > 0 else {
                return 2
            }
            let secs = Double(ms) / 1000.0
            guard secs > 0 else { return 2 }
            let avgMbps = (Double(size) * 8.0) / (secs * 1_000_000.0)
            if avgMbps >= 25 { return 1 }
            if avgMbps >= 12 { return 1.5 }
            if avgMbps >= 6 { return 2 }
            return 3
        }()
        item.preferredForwardBufferDuration = forwardBufferSeconds
        let p = AVPlayer(playerItem: item)
        await MainActor.run {
            guard viewerIsActive && videoLoadToken == token else { return }
            stopPlayback()
            player = p
            isVideoMuted = p.isMuted
            attachVideoItemObserver(for: p, token: token)
            isVideoBuffering = true
            p.play()
            isVideoPaused = false
        }
        Task {
            guard await stillCurrent(), !Task.isCancelled else { return }
            let d = (try? await asset.load(.duration)) ?? .zero
            let secs = CMTimeGetSeconds(d)
            await MainActor.run {
                guard viewerIsActive && videoLoadToken == token else { return }
                if secs.isFinite, secs > 0 { videoDuration = secs }
                let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
                videoTimeObserverToken = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { t in
                    if !scrubbing { videoTime = CMTimeGetSeconds(t) }
                }
            }
        }
    }

    private func loadNextPageAndAdvance() async {
        guard let callback = onRequestNextPage else { return }
        if let added = await callback(), !added.isEmpty {
            await MainActor.run {
                photos.append(contentsOf: added)
                currentIndex = min(currentIndex + 1, photos.count - 1)
                resetZoom()
            }
        }
    }
}

// MARK: - Video surface helper
/// UIKit-backed player surface with built-in playback controls disabled.
///
/// SwiftUI's `VideoPlayer` always uses the system playback controls, which can introduce duplicate
/// scrubbers/progress UI when we overlay our own controls. Using `AVPlayerViewController` directly
/// lets us keep a single custom control strip.
private struct ControlsFreePlayerSurface: UIViewControllerRepresentable {
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
        // Ensure no retained controller keeps audio playing after SwiftUI removes the view.
        uiViewController.player = nil
    }
}

/// A single, lightweight scrubber used by the server-backed full-screen viewer.
///
/// This intentionally does not mirror the full system video player UI; it provides just enough
/// control to seek without showing duplicate system progress/volume bars.
private struct VideoScrubber: View {
    @Binding var currentTime: Double
    let duration: Double
    @Binding var scrubbing: Bool
    let onSeek: (Double) -> Void

    @State private var dragTime: Double? = nil

    private var progress: Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        let t = (dragTime ?? currentTime)
        if !t.isFinite { return 0 }
        return max(0, min(1, t / duration))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.25))
                    .frame(height: 4)

                Capsule()
                    .fill(Color.white)
                    .frame(width: geo.size.width * progress, height: 4)

                Circle()
                    .fill(Color.white)
                    .frame(width: 14, height: 14)
                    .offset(x: geo.size.width * progress - 7)
            }
            .frame(height: 14)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        scrubbing = true
                        let p = max(0, min(1, value.location.x / max(1, geo.size.width)))
                        dragTime = p * duration
                    }
                    .onEnded { value in
                        let p = max(0, min(1, value.location.x / max(1, geo.size.width)))
                        let t = p * duration
                        dragTime = nil
                        scrubbing = false
                        currentTime = t
                        onSeek(t)
                    }
            )
        }
        .frame(height: 18)
    }
}

// MARK: - People overlay: Update assignment
private struct UpdatePersonOverlay: View {
    let assetId: String
    let onDone: () -> Void
    @State private var faces: [ServerPhotosService.ServerAssetFace] = []
    @State private var persons: [ServerPhotosService.ServerPerson] = []
    @State private var selectedFace: String? = nil
    @State private var peopleMode: PeopleMode? = nil
    @State private var loading = true

    private enum PeopleMode: Equatable {
        case replace
        case add
    }

    var body: some View {
        NavigationView {
            VStack(alignment: .leading) {
                HStack {
                    Text("Faces in this photo")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(action: {
                        if peopleMode == .add {
                            peopleMode = nil
                        } else {
                            peopleMode = .add
                        }
                        selectedFace = nil
                    }) {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 28, height: 28)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color(.secondarySystemBackground)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add person to this photo")
                }
                .padding(.horizontal)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(faces, id: \.face_id) { f in
                            ZStack(alignment: .topTrailing) {
                                AssetFaceTile(face: f, size: 96)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke((peopleMode == .replace && selectedFace == f.face_id) ? Color.blue : Color.clear, lineWidth: 3)
                                    )

                                Button(action: {
                                    if peopleMode == .replace && selectedFace == f.face_id {
                                        peopleMode = nil
                                        selectedFace = nil
                                    } else {
                                        selectedFace = f.face_id
                                        peopleMode = .replace
                                    }
                                }) {
                                    Image(systemName: "pencil")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(.white)
                                        .padding(6)
                                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.55)))
                                }
                                .buttonStyle(.plain)
                                .padding(6)
                                .accessibilityLabel("Edit this face")
                            }
                        }
                    }
                    .padding(.horizontal)
                }

                if let mode = peopleMode {
                    Text(mode == .replace ? "Replace with" : "Add person to this photo")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .padding([.horizontal, .top])

                    if loading {
                        Text("Loading…").foregroundColor(.secondary).padding(.horizontal)
                    }

                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 10) {
                            ForEach(persons, id: \.person_id) { p in
                                Button(action: {
                                    Task {
                                        if mode == .add {
                                            await add(personId: p.person_id)
                                        } else {
                                            await replace(faceId: selectedFace, personId: p.person_id)
                                        }
                                    }
                                }) {
                                    VStack(spacing: 6) {
                                        RemoteFaceThumb(personId: p.person_id, size: 96)
                                        Text(p.display_name ?? p.person_id).lineLimit(1).font(.caption)
                                    }
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                        .padding(.horizontal)
                    }
                }

                Spacer()
            }
            .navigationTitle("Update Faces")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { onDone() } } }
        }
        .task { await load() }
    }

    private func load() async {
        await MainActor.run { loading = true }
        do {
            async let f = ServerPhotosService.shared.getFacesForAsset(assetId: assetId)
            async let p = ServerPhotosService.shared.getPersons()
            let (ff, pp) = try await (f, p)
            await MainActor.run {
                faces = ff
                persons = pp
                loading = false
            }
        } catch {
            await MainActor.run {
                faces = []
                persons = []
                loading = false
            }
        }
    }

    private func replace(faceId: String?, personId: String) async {
        guard let fid = faceId else {
            ToastManager.shared.show("Pick a face to edit first")
            return
        }
        do {
            try await ServerPhotosService.shared.assignFace(faceId: fid, personId: personId)
            ToastManager.shared.show("Face updated")
            await load()
            await MainActor.run {
                peopleMode = nil
                selectedFace = nil
            }
        } catch {
            ToastManager.shared.show("Update failed")
        }
    }

    private func add(personId: String) async {
        do {
            try await ServerPhotosService.shared.addPersonToPhoto(assetId: assetId, personId: personId)
            ToastManager.shared.show("Added person")
            await load()
            await MainActor.run { peopleMode = nil }
        } catch {
            ToastManager.shared.show("Add failed")
        }
    }
}

// MARK: - Remote Face Thumb (auth headers)
private final class InlineFaceThumbLoader: ObservableObject {
    static let shared = InlineFaceThumbLoader(); private init() {}
    private let cache = NSCache<NSString, UIImage>()
    func image(for personId: String, url: URL) async -> UIImage? {
        if let c = cache.object(forKey: personId as NSString) { return c }
        if let data = DiskImageCache.shared.readData(bucket: .faces, key: personId), let ui = UIImage(data: data) { cache.setObject(ui, forKey: personId as NSString); return ui }
        var req = URLRequest(url: url)
        do {
            let (data, _) = try await AuthorizedHTTPClient.shared.request(req)
            if let ui = UIImage(data: data) {
                if DiskImageCache.shared.write(bucket: .faces, key: personId, data: data, ext: "jpg") == nil {
                    print("[FACE] ⚠️ Cache write failed for face thumbnail person=\(personId)")
                }
                cache.setObject(ui, forKey: personId as NSString)
                return ui
            }
        } catch {}
        return nil
    }
}
private struct RemoteFaceThumb: View {
    let personId: String
    let size: CGFloat
    @ObservedObject private var loader = InlineFaceThumbLoader.shared
    @State private var image: UIImage? = nil
    var body: some View {
        ZStack {
            Color(.systemGray6)
            if let img = image { Image(uiImage: img).resizable().scaledToFill() } else { Image(systemName: "person.crop.square").font(.system(size: size/3)).foregroundColor(.secondary) }
        }
        .frame(width: size, height: size)
        .clipped()
        .task(id: personId) { await load() }
    }
    private func load() async {
        guard let url = ServerPhotosService.shared.getFaceThumbnailUrl(personId: personId) else { return }
        if let ui = await loader.image(for: personId, url: url) { await MainActor.run { image = ui } }
    }
}

// MARK: - Asset face tile (data URL thumb or person thumb)
private struct AssetFaceTile: View {
    let face: ServerPhotosService.ServerAssetFace
    let size: CGFloat

    var body: some View {
        ZStack {
            Color(.systemGray6)
            if let pid = face.person_id {
                RemoteFaceThumb(personId: pid, size: size)
            } else if let dataURL = face.thumbnail {
                DataURLImage(dataURL: dataURL, size: size)
            } else {
                Image(systemName: "person.crop.square")
                    .font(.system(size: size / 3))
                    .foregroundColor(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct DataURLImage: View {
    let dataURL: String
    let size: CGFloat
    @State private var image: UIImage? = nil

    var body: some View {
        ZStack {
            if let img = image {
                Image(uiImage: img).resizable().scaledToFill()
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .task(id: dataURL) { await decode() }
    }

    private func decode() async {
        guard let comma = dataURL.firstIndex(of: ",") else { return }
        let b64 = String(dataURL[dataURL.index(after: comma)...])
        guard let data = Data(base64Encoded: b64), let ui = UIImage(data: data) else { return }
        await MainActor.run { image = ui }
    }
}

private struct PeopleListView: View {
    let assetId: String
    @State private var persons: [ServerPhotosService.ServerPerson] = []
    var body: some View {
        if persons.isEmpty {
            Text("No people detected").foregroundColor(.secondary)
                .task { await load() }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(persons, id: \.person_id) { p in
                    HStack { Text(p.display_name ?? p.person_id); if let b = p.birth_date { Spacer(); Text(b).foregroundColor(.secondary).font(.footnote) } }
                }
            }
            .task { await load() }
        }
    }
    private func load() async {
        do { let list = try await ServerPhotosService.shared.getPersonsForAsset(assetId: assetId); await MainActor.run { persons = list } } catch { await MainActor.run { persons = [] } }
    }
}

// MARK: - EE Inline Share (basic)
private struct EEInlineShareSheet: View {
    let assetId: String
    let filename: String
    @Environment(\.dismiss) private var dismiss
    @State private var email: String = ""
    @State private var linkURL: String? = nil
    private let shareService = ShareService.shared
    private let photosService = ServerPhotosService.shared
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Account Share")) {
                    TextField("Recipient email or user id", text: $email)
                    Button("Share") { Task { await createBasicShare() } }.disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Section(header: Text("Public Link")) {
                    Button("Create Public Link") { Task { await createPublicLink() } }
                    if let u = linkURL { Text(u).textSelection(.enabled).font(.footnote) }
                }
            }.navigationTitle("Share")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
    private func createBasicShare() async {
        do {
            let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                ToastManager.shared.show("Enter a recipient first")
                return
            }

            let recipient: CreateShareRequest.RecipientInput
            if trimmed.contains("@") {
                recipient = CreateShareRequest.RecipientInput(
                    type: "external_email",
                    id: nil,
                    email: trimmed,
                    permissions: nil
                )
            } else {
                recipient = CreateShareRequest.RecipientInput(
                    type: "user",
                    id: trimmed,
                    email: nil,
                    permissions: nil
                )
            }

            let request = CreateShareRequest(
                object: CreateShareRequest.ShareObject(kind: "asset", id: assetId),
                name: filename,
                defaultPermissions: SharePermissions.commenter.rawValue,
                expiresAt: nil,
                includeFaces: nil,
                includeSubtree: false,
                recipients: [recipient]
            )

            let share = try await shareService.createShare(request)
            do {
                try await ShareE2EEManager.shared.prepareOwnerShareE2EEIfNeeded(share: share)
            } catch {
                print("[SHARE-E2EE] inline prep failed share=\(share.id) err=\(error.localizedDescription)")
            }
            ToastManager.shared.show("Share created")
        } catch { ToastManager.shared.show("Share failed") }
    }
    private func createPublicLink() async {
        do {
            let cleanName = filename.trimmingCharacters(in: .whitespacesAndNewlines)
            let albumName = cleanName.isEmpty ? "Shared Photo" : cleanName
            let album = try await photosService.createAlbum(
                name: albumName,
                description: "Auto-created for public link"
            )
            try await photosService.addPhotosToAlbum(albumId: album.id, assetIds: [assetId])

            let request = CreatePublicLinkRequest(
                name: albumName,
                scopeKind: "album",
                scopeAlbumId: album.id,
                permissions: SharePermissions.VIEW,
                expiresAt: nil,
                pin: nil,
                coverAssetId: assetId,
                moderationEnabled: nil
            )

            let link = try await shareService.createPublicLink(request)
            await MainActor.run {
                linkURL = link.url
            }
            ToastManager.shared.show("Link created")
        } catch { ToastManager.shared.show("Create link failed") }
    }
}
