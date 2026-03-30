import SwiftUI
import Photos

@main
struct OpenPhotosApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        do {
            let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            if let cachesDir {
                let urlCacheDir = cachesDir.appendingPathComponent("openphotos", isDirectory: true)
                try FileManager.default.createDirectory(at: urlCacheDir, withIntermediateDirectories: true)
            }
        } catch {}

        // Configure audio session once for reliable video sound playback.
        // Without this, iOS may default to an "ambient" category that respects the silent switch,
        // which can make in-app video playback appear to have no audio.
        Task { @MainActor in
            MediaAudioSession.shared.configureForVideoPlaybackIfNeeded()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
#if DEBUG
                    // Optional debug-only validation for disk cache correctness across app relaunches.
                    // Enable by launching with `OPENPHOTOS_CACHE_SELFTEST=1` (simctl: `SIMCTL_CHILD_...`).
                    DiskImageCache.shared.runStartupSelfTestIfRequested()
#endif
                    // One-time first-run check: purge persisted secrets that may survive uninstall (Keychain)
                    let markerKey = "app.firstRunMarker"
                    if UserDefaults.standard.string(forKey: markerKey) == nil {
                        // Purge device-wrapped UMK (quick unlock) and local PIN artifacts
                        KeychainHelper.shared.remove(service: "com.openphotos.e2ee", account: "umk.deviceWrapped")
                        KeychainHelper.shared.remove(service: "com.openphotos.pin", account: "hash")
                        KeychainHelper.shared.remove(service: "com.openphotos.pin", account: "salt")
                        KeychainHelper.shared.remove(service: "com.openphotos.pin", account: "biometricToken")
                        // Clear in-memory UMK and last-seen envelope hash marker
                        E2EEManager.shared.clearUMK()
                        E2EEManager.shared.clearStoredEnvelopeHash()
                        UserDefaults.standard.set(UUID().uuidString, forKey: markerKey)
                        print("[APP] First run detected — purged keychain items and E2EE markers")
                    }
                    LocalNetworkPermissionRequester.shared.requestOnFirstLaunchIfNeeded()
                    PhotoService.shared.requestPermissions()
                    // Kick off a sync if authenticated and allowed
                    SyncService.shared.syncOnAppOpen()
                    // Clear any lingering 'uploading' rows from a previous session
                    SyncRepository.shared.recoverStuckUploading()
                    Task {
                        await AuthManager.shared.refreshIfNeeded()
                        // Warm session and demonstrate authorized helper (401→refresh→retry)
                        if AuthManager.shared.isAuthenticated,
                           !AuthManager.shared.currentEffectiveBaseURL().isEmpty {
                            let url = AuthorizedHTTPClient.shared.buildURL(path: "/api/auth/me")
                            struct MeDTO: Decodable { let id: Int? }
                            _ = try? await AuthorizedHTTPClient.shared.getJSON(url) as MeDTO
                        }
                    }
                }
                .environmentObject(AuthManager.shared)
                .environmentObject(HybridUploadManager.shared)
                .environmentObject(E2EEUnlockController.shared)
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .background:
                print("[UPLOAD] scenePhase=background → switch to background uploads")
                HybridUploadManager.shared.switchToBackgroundUploads()
                // Clear PIN session cache on background
                PinManager.shared.clearSession()
            case .inactive:
                // No-op; handled by willResignActive as well
                break
            case .active:
                // On resume, repair any stale 'uploading' state
                SyncRepository.shared.recoverStuckUploading()
                HybridUploadManager.shared.handleSceneDidBecomeActive()
                // Auto-retry background-queued items older than N minutes
                let mins = max(1, AuthManager.shared.autoRetryBgMinutes)
                let requeuedBg = SyncRepository.shared.retryBackgroundQueued(olderThan: Int64(mins * 60))
                let requeuedTransientFailed = SyncRepository.shared.retryTransientFailed()
                let requeuedTotal = requeuedBg + requeuedTransientFailed
                if requeuedTotal > 0 {
                    let itemsWord = requeuedTotal == 1 ? "item" : "items"
                    if requeuedTransientFailed > 0 {
                        print(
                            "[UPLOAD] foreground auto-retry requeued transient failed items=\(requeuedTransientFailed) bgQueued=\(requeuedBg)"
                        )
                    }
                    ToastManager.shared.show("Requeued \(requeuedTotal) stalled \(itemsWord)")
                    // Kick a normal sync pass (respects current network policy)
                    SyncService.shared.syncNow(forceRetryFailed: false)
                } else {
                    let stats = SyncRepository.shared.getStats(
                        scope: AuthManager.shared.syncScope,
                        includeUnassigned: AuthManager.shared.syncIncludeUnassigned
                    )
                    if stats.pending > 0 || stats.uploading > 0 || stats.bgQueued > 0 {
                        // Resume interrupted runs promptly after app returns to foreground.
                        SyncService.shared.syncNow(forceRetryFailed: false)
                    }
                }
            @unknown default:
                break
            }
        }
    }
}
