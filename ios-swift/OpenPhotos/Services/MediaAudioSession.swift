import Foundation
import AVFAudio

/// Centralized audio session configuration for media playback.
///
/// Problem this solves:
/// - If an app never configures `AVAudioSession`, iOS uses a default category that *respects the silent switch*
///   (commonly perceived as “videos have no sound” when the device is in silent mode).
/// - For a photo/video gallery app, video audio is expected to play reliably, even in silent mode.
///
/// Approach:
/// - Configure the app-wide audio session category to `.playback` + `.moviePlayback`.
/// - Include `.mixWithOthers` so starting video playback does not abruptly stop other audio (e.g., Music/Podcasts).
/// - Keep this method idempotent; call it early during app startup.
///
/// Notes:
/// - We intentionally do **not** call `setActive(true)` here; `AVPlayer` will activate the session when playback starts.
///   Activating at startup can have side effects (e.g., stealing audio focus) when the user isn't playing a video yet.
@MainActor
final class MediaAudioSession {
    static let shared = MediaAudioSession()

    private var configured = false

    private init() {}

    /// Ensures the app's audio session is configured for video playback with sound.
    func configureForVideoPlaybackIfNeeded() {
        guard !configured else { return }
        configured = true

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playback,
                mode: .moviePlayback,
                options: [
                    .mixWithOthers,
                    .allowAirPlay,
                    .allowBluetoothA2DP
                ]
            )
        } catch {
            // Best-effort: if configuration fails, video may still play but could remain silent in some device states.
            NSLog("[AUDIO] Failed to configure AVAudioSession for video playback: %@", error.localizedDescription)
        }
    }

    /// Best-effort deactivation of the audio session after in-app video playback ends.
    ///
    /// Why this exists:
    /// - Some AVPlayer / SwiftUI teardown paths can briefly keep audio alive even after the UI is dismissed.
    /// - Explicitly deactivating the session ensures audio stops immediately and other audio apps can resume
    ///   full control (`.notifyOthersOnDeactivation`).
    ///
    /// This is safe to call even if the session was never activated.
    func deactivateAfterPlayback() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            NSLog("[AUDIO] Failed to deactivate AVAudioSession: %@", error.localizedDescription)
        }
    }
}
