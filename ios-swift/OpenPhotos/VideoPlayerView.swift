import SwiftUI
import AVKit
import AVFoundation
import Photos

/// UIKit-backed player surface with built-in controls disabled.
///
/// SwiftUI's `VideoPlayer` wraps `AVPlayerViewController` but keeps the system playback controls.
/// When we draw our own overlay controls, this causes duplicate scrubbers/progress bars.
/// This wrapper gives us full control over the UI while still using AVPlayer/AVPlayerItem underneath.
private struct InlinePlayerSurface: UIViewControllerRepresentable {
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
        // Ensure no retained player keeps audio alive after SwiftUI removes the view.
        uiViewController.player = nil
    }
}

struct VideoPlayerView: View {
    let asset: PHAsset
    @StateObject private var playerViewModel = VideoPlayerViewModel()
    @State private var showControls = true
    @State private var controlsTimer: Timer?
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if let player = playerViewModel.player {
                InlinePlayerSurface(player: player)
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            showControls.toggle()
                            if showControls {
                                startControlsTimer()
                            }
                        }
                    }
                
                // Custom video controls overlay
                if showControls {
                    VideoControlsOverlay(
                        playerViewModel: playerViewModel,
                        onControlInteraction: {
                            startControlsTimer()
                        }
                    )
                }
            } else if playerViewModel.isLoading {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                    
                    Text("Loading Video...")
                        .foregroundColor(.white)
                }
            } else {
                VStack(spacing: 20) {
                    Image(systemName: "video.slash")
                        .font(.system(size: 50))
                        .foregroundColor(.gray)
                    
                    Text("Unable to load video")
                        .foregroundColor(.gray)
                }
            }
        }
        .onAppear {
            playerViewModel.loadVideo(from: asset)
            startControlsTimer()
        }
        .onDisappear {
            playerViewModel.cleanup()
            controlsTimer?.invalidate()
        }
    }
    
    private func startControlsTimer() {
        controlsTimer?.invalidate()
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
            withAnimation(.easeInOut(duration: 0.3)) {
                showControls = false
            }
        }
    }
}

struct VideoControlsOverlay: View {
    @ObservedObject var playerViewModel: VideoPlayerViewModel
    let onControlInteraction: () -> Void
    
    var body: some View {
        VStack {
            Spacer()
            
            // Bottom controls
            VStack(spacing: 16) {
                // Progress bar
                VideoProgressBar(
                    currentTime: playerViewModel.currentTime,
                    duration: playerViewModel.duration,
                    onSeek: { time in
                        playerViewModel.seek(to: time)
                        onControlInteraction()
                    }
                )
                
                // Control buttons
                HStack(spacing: 16) {
                    // Play/Pause button
                    Button(action: {
                        playerViewModel.togglePlayPause()
                        onControlInteraction()
                    }) {
                        Image(systemName: playerViewModel.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title)
                            .foregroundColor(.white)
                    }
                    .frame(width: 44, height: 44)
                    
                    Spacer()
                    
                    // Time display with fixed width to prevent truncation
                    Text("\(formatTime(playerViewModel.currentTime)) / \(formatTime(playerViewModel.duration))")
                        .foregroundColor(.white)
                        .font(.caption)
                        .monospacedDigit()
                        .frame(width: 90, alignment: .center)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.black.opacity(0.5))
                        )
                        .fixedSize()
                    
                    Spacer()
                    
                    // Mute/Unmute button
                    Button(action: {
                        playerViewModel.toggleMute()
                        onControlInteraction()
                    }) {
                        Image(systemName: playerViewModel.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.title2)
                            .foregroundColor(.white)
                    }
                    .frame(width: 44, height: 44)
                }
                .padding(.horizontal, 20)
            }
            .padding(.bottom, 40)
            .background(
                LinearGradient(
                    colors: [Color.clear, Color.black.opacity(0.7)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 120)
            )
        }
    }
    
    private func formatTime(_ time: Double) -> String {
        // Handle invalid or very small time values
        guard time.isFinite && time >= 0 else {
            return "0:00"
        }
        
        let totalSeconds = Int(time)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        
        // Format as M:SS or MM:SS depending on length
        if minutes < 10 {
            return String(format: "%d:%02d", minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
}

struct VideoProgressBar: View {
    let currentTime: Double
    let duration: Double
    let onSeek: (Double) -> Void
    
    @State private var isDragging = false
    @State private var dragTime: Double = 0
    
    private var progress: Double {
        guard duration > 0 else { return 0 }
        return isDragging ? dragTime / duration : currentTime / duration
    }
    
    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background track
                    Rectangle()
                        .fill(Color.white.opacity(0.3))
                        .frame(height: 4)
                        .cornerRadius(2)
                    
                    // Progress fill
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: geometry.size.width * progress, height: 4)
                        .cornerRadius(2)
                    
                    // Draggable thumb
                    Circle()
                        .fill(Color.white)
                        .frame(width: 16, height: 16)
                        .offset(x: geometry.size.width * progress - 8)
                        .scaleEffect(isDragging ? 1.2 : 1.0)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            isDragging = true
                            let newProgress = max(0, min(1, value.location.x / geometry.size.width))
                            dragTime = newProgress * duration
                        }
                        .onEnded { value in
                            let newProgress = max(0, min(1, value.location.x / geometry.size.width))
                            let seekTime = newProgress * duration
                            onSeek(seekTime)
                            isDragging = false
                        }
                )
            }
            .frame(height: 16)
        }
        .padding(.horizontal, 20)
    }
}

@MainActor
class VideoPlayerViewModel: ObservableObject {
    @Published var player: AVPlayer?
    @Published var isPlaying = false
    @Published var isMuted = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isLoading = false
    
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    
    func loadVideo(from asset: PHAsset) {
        isLoading = true
        
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        
        PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { [weak self] avAsset, audioMix, info in
            guard let avAsset = avAsset else {
                DispatchQueue.main.async {
                    self?.isLoading = false
                }
                return
            }
            
            DispatchQueue.main.async {
                self?.setupPlayer(with: avAsset)
            }
        }
    }
    
    private func setupPlayer(with asset: AVAsset) {
        let playerItem = AVPlayerItem(asset: asset)
        player = AVPlayer(playerItem: playerItem)
        
        // Set up time observer
        setupTimeObserver()
        
        // Set up status observer
        setupStatusObserver()
        
        // Get duration
        Task {
            do {
                let duration = try await asset.load(.duration)
                await MainActor.run {
                    self.duration = CMTimeGetSeconds(duration)
                    self.isLoading = false
                    
                    // Auto-play the video
                    self.play()
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                }
            }
        }
    }
    
    private func setupTimeObserver() {
        guard let player = player else { return }
        
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC)),
            queue: .main
        ) { [weak self] time in
            self?.currentTime = CMTimeGetSeconds(time)
        }
    }
    
    private func setupStatusObserver() {
        guard let player = player else { return }
        
        statusObserver = player.observe(\.timeControlStatus, options: [.new, .old]) { [weak self] player, _ in
            DispatchQueue.main.async {
                self?.isPlaying = player.timeControlStatus == .playing
            }
        }
    }
    
    func togglePlayPause() {
        guard let player = player else { return }
        
        if player.timeControlStatus == .playing {
            pause()
        } else {
            play()
        }
    }
    
    func play() {
        player?.play()
    }
    
    func pause() {
        player?.pause()
    }
    
    func toggleMute() {
        guard let player = player else { return }
        player.isMuted.toggle()
        isMuted = player.isMuted
    }
    
    func seek(to time: Double) {
        let cmTime = CMTime(seconds: time, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        player?.seek(to: cmTime)
    }
    
    func cleanup() {
        if let timeObserver = timeObserver {
            player?.removeTimeObserver(timeObserver)
        }
        statusObserver?.invalidate()
        player?.pause()
        player = nil
    }
}

#Preview {
    VideoPlayerView(asset: PHAsset())
}
