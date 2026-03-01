import SwiftUI
import UIKit

/// Full-screen slideshow view for server photos with crossfade transitions.
/// - Auto-advances through photos with configurable timing (3s/5s/10s)
/// - Tap to pause/resume
/// - Swipe left/right for manual navigation
/// - Auto-hide controls after inactivity
/// - Loops at the end
/// - Keeps screen awake during playback
struct SlideshowView: View {
    // Input: filtered photo array from parent
    let photos: [ServerPhoto]
    let startIndex: Int
    let onDismiss: () -> Void

    // Playback state
    @State private var currentIndex: Int
    @State private var isPlaying: Bool = true
    @State private var slideDuration: TimeInterval = 5.0  // Default 5 seconds
    @State private var timer: Timer? = nil

    // Image cache: current and next photos preloaded
    @State private var imageCache: [String: UIImage] = [:]
    @State private var isLoadingCurrent: Bool = false

    // UI state
    @State private var showControls: Bool = true
    @State private var controlsTimer: Timer? = nil

    // Crossfade animation: we maintain two image layers and crossfade between them
    @State private var currentImageId: String
    @State private var nextImageId: String? = nil
    @State private var crossfadeProgress: CGFloat = 0

    init(photos: [ServerPhoto], startIndex: Int = 0, onDismiss: @escaping () -> Void) {
        self.photos = photos
        self.startIndex = startIndex
        self.onDismiss = onDismiss
        _currentIndex = State(initialValue: startIndex)
        _currentImageId = State(initialValue: photos.indices.contains(startIndex) ? photos[startIndex].asset_id : "")
    }

    var body: some View {
        ZStack {
            // Full-screen black background
            Color.black.ignoresSafeArea()

            // Image layers for crossfade transition
            GeometryReader { geo in
                ZStack {
                    // Current image layer
                    if let currentImage = imageCache[currentImageId] {
                        Image(uiImage: currentImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .opacity(1.0 - Double(crossfadeProgress))
                    } else if isLoadingCurrent {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(1.4)
                            .frame(width: geo.size.width, height: geo.size.height)
                    }

                    // Next image layer (crossfading in)
                    if let nextId = nextImageId, let nextImage = imageCache[nextId] {
                        Image(uiImage: nextImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .opacity(Double(crossfadeProgress))
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                handleTap()
            }
            .gesture(
                DragGesture(minimumDistance: 50)
                    .onEnded { value in
                        handleSwipe(value)
                    }
            )

            // Top overlay: controls (auto-hide)
            if showControls {
                VStack(spacing: 0) {
                    topBar
                    Spacer()
                }
                .transition(.opacity)
            }
        }
        .statusBarHidden(!showControls)
        .onAppear {
            setupSlideshow()
        }
        .onDisappear {
            cleanup()
        }
    }

    // MARK: - Top Bar with Controls

    private var topBar: some View {
        VStack(spacing: 12) {
            // Top control row: close button, counter, speed control
            HStack(spacing: 16) {
                // Close button
                Button(action: {
                    onDismiss()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                }

                Spacer()

                // Photo counter
                Text("\(currentIndex + 1) / \(photos.count)")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(Color.black.opacity(0.5))
                    )
                    .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)

                Spacer()

                // Speed control button (3s/5s/10s toggle)
                Button(action: {
                    cycleSlideDuration()
                }) {
                    Text("\(Int(slideDuration))s")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .frame(minWidth: 44)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(Color.blue.opacity(0.7))
                        )
                        .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 50)

            // Play/pause indicator
            HStack(spacing: 8) {
                Image(systemName: isPlaying ? "play.fill" : "pause.fill")
                    .font(.caption)
                    .foregroundColor(.white)
                Text(isPlaying ? "Playing" : "Paused")
                    .font(.caption)
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.5))
            )
            .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
        }
    }

    // MARK: - Slideshow Logic

    /// Initial setup: load current image, start timer, enable keep-awake
    private func setupSlideshow() {
        // Keep screen awake during slideshow
        IdleTimerManager.shared.setDisabled(true)

        // Load initial images
        Task {
            await loadCurrentImage()
            await prefetchNextImages()
        }

        // Start auto-advance timer
        if isPlaying {
            startTimer()
        }

        // Auto-hide controls after 3 seconds
        scheduleControlsHide()
    }

    /// Cleanup: stop timers, re-enable screen sleep
    private func cleanup() {
        timer?.invalidate()
        timer = nil
        controlsTimer?.invalidate()
        controlsTimer = nil
        imageCache.removeAll()

        // Re-enable screen sleep
        IdleTimerManager.shared.setDisabled(false)
    }

    /// Start the auto-advance timer
    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: slideDuration, repeats: true) { _ in
            advanceToNext()
        }
    }

    /// Stop the auto-advance timer
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// Toggle play/pause
    private func togglePlayPause() {
        isPlaying.toggle()
        if isPlaying {
            startTimer()
        } else {
            stopTimer()
        }
    }

    /// Cycle through slide duration options: 3s → 5s → 10s → 3s
    private func cycleSlideDuration() {
        switch slideDuration {
        case 3.0:
            slideDuration = 5.0
        case 5.0:
            slideDuration = 10.0
        default:
            slideDuration = 3.0
        }

        // Restart timer with new duration if playing
        if isPlaying {
            startTimer()
        }

        // Show feedback
        ToastManager.shared.show("Speed: \(Int(slideDuration))s")

        // Keep controls visible briefly
        showControls = true
        scheduleControlsHide()
    }

    /// Advance to next photo with crossfade animation
    private func advanceToNext() {
        guard !photos.isEmpty else { return }

        // Calculate next index (loop at end)
        let nextIndex = (currentIndex + 1) % photos.count
        let nextPhoto = photos[nextIndex]

        // Set up crossfade animation
        nextImageId = nextPhoto.asset_id

        // Ensure next image is loaded
        if imageCache[nextPhoto.asset_id] == nil {
            Task {
                await loadImage(for: nextPhoto.asset_id)
            }
        }

        // Animate crossfade
        withAnimation(.easeInOut(duration: 0.6)) {
            crossfadeProgress = 1.0
        }

        // After animation completes, swap images and reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            currentImageId = nextPhoto.asset_id
            currentIndex = nextIndex
            nextImageId = nil
            crossfadeProgress = 0

            // Prefetch next images
            Task {
                await prefetchNextImages()
            }
        }
    }

    /// Go to previous photo
    private func goToPrevious() {
        guard !photos.isEmpty else { return }

        // Calculate previous index (loop at beginning)
        let prevIndex = currentIndex == 0 ? photos.count - 1 : currentIndex - 1

        // Jump immediately (no crossfade for manual navigation)
        currentIndex = prevIndex
        currentImageId = photos[prevIndex].asset_id
        nextImageId = nil
        crossfadeProgress = 0

        // Load current if not cached
        Task {
            await loadCurrentImage()
            await prefetchNextImages()
        }

        // Restart timer if playing
        if isPlaying {
            startTimer()
        }
    }

    /// Go to next photo (manual)
    private func goToNext() {
        // Stop timer and advance
        stopTimer()
        advanceToNext()

        // Restart timer if playing
        if isPlaying {
            // Delay restart to let animation complete
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                if self.isPlaying {
                    self.startTimer()
                }
            }
        }
    }

    // MARK: - Gesture Handlers

    /// Handle tap: toggle play/pause and show controls
    private func handleTap() {
        togglePlayPause()

        // Show controls briefly
        withAnimation(.easeInOut(duration: 0.2)) {
            showControls = true
        }
        scheduleControlsHide()
    }

    /// Handle swipe: navigate photos
    private func handleSwipe(_ value: DragGesture.Value) {
        // Horizontal swipe for navigation
        if abs(value.translation.width) > abs(value.translation.height) {
            if value.translation.width < 0 {
                // Swipe left: next photo
                goToNext()
            } else {
                // Swipe right: previous photo
                goToPrevious()
            }

            // Show controls briefly
            withAnimation(.easeInOut(duration: 0.2)) {
                showControls = true
            }
            scheduleControlsHide()
        }
    }

    /// Schedule auto-hide of controls after 3 seconds
    private func scheduleControlsHide() {
        controlsTimer?.invalidate()
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
            withAnimation(.easeInOut(duration: 0.3)) {
                showControls = false
            }
        }
    }

    // MARK: - Image Loading

    /// Load the current photo's image
    private func loadCurrentImage() async {
        guard photos.indices.contains(currentIndex) else { return }
        let photo = photos[currentIndex]

        if imageCache[photo.asset_id] == nil {
            await MainActor.run { isLoadingCurrent = true }
            await loadImage(for: photo.asset_id)
            await MainActor.run { isLoadingCurrent = false }
        }
    }

    /// Prefetch adjacent images (current, next, next+1) for smooth transitions
    private func prefetchNextImages() async {
        guard !photos.isEmpty else { return }

        // Prefetch current, next, and next+1
        let indicesToPrefetch = [
            currentIndex,
            (currentIndex + 1) % photos.count,
            (currentIndex + 2) % photos.count
        ]

        for idx in indicesToPrefetch {
            let photo = photos[idx]
            if imageCache[photo.asset_id] == nil {
                await loadImage(for: photo.asset_id)
            }
        }
    }

    /// Load a single image by asset_id
    /// Uses the same pattern as RemoteThumbnailView and ServerFullScreenViewer
    private func loadImage(for assetId: String) async {
        // 1) Check disk cache first (images bucket for full-res)
        if let data = DiskImageCache.shared.readData(bucket: .images, key: assetId),
           let img = UIImage(data: data) {
            await MainActor.run {
                imageCache[assetId] = img
            }
            return
        } else if let url = DiskImageCache.shared.readURL(bucket: .images, key: assetId),
                  let img = UIImage(contentsOfFile: url.path) {
            await MainActor.run {
                imageCache[assetId] = img
            }
            return
        }

        // 2) Fetch from server
        let encoded = assetId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? assetId
        let url = AuthorizedHTTPClient.shared.buildURL(path: "/api/images/" + encoded)
        var req = URLRequest(url: url)
        AuthManager.shared.authHeader().forEach { k, v in
            req.setValue(v, forHTTPHeaderField: k)
        }
        // Prefer HEIC when supported
        req.setValue("image/heic, image/*;q=0.8", forHTTPHeaderField: "Accept")

        do {
            let (data, http) = try await AuthorizedHTTPClient.shared.request(req)
            let ct = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()

            // Handle encrypted (locked) images
            if ct.starts(with: "application/octet-stream") {
                guard let umk = E2EEManager.shared.umk,
                      let userId = AuthManager.shared.userId else { return }

                let encURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pae3")
                let outURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try data.write(to: encURL)
                try pae3DecryptFile(umk: umk, userIdKey: Data(userId.utf8), input: encURL, output: outURL)

                if let plain = try? Data(contentsOf: outURL) {
                    // Persist decrypted image with strong protection
                    let _ = DiskImageCache.shared.write(bucket: .images, key: assetId, data: plain, ext: nil, protection: .complete)
                    if let img = UIImage(data: plain) {
                        await MainActor.run {
                            imageCache[assetId] = img
                        }
                    }
                }

                try? FileManager.default.removeItem(at: encURL)
                try? FileManager.default.removeItem(at: outURL)
            } else {
                // Persist unlocked image to disk cache
                let ext: String? = ct.contains("image/heic") ? "heic" : (ct.contains("jpeg") ? "jpg" : (ct.contains("png") ? "png" : nil))
                let _ = DiskImageCache.shared.write(bucket: .images, key: assetId, data: data, ext: ext)

                if let img = UIImage(data: data) {
                    await MainActor.run {
                        imageCache[assetId] = img
                    }
                }
            }
        } catch {
            // Silent failure for slideshow - skip photos that fail to load
            print("[SLIDESHOW] Failed to load image for \(assetId): \(error.localizedDescription)")
        }
    }
}
