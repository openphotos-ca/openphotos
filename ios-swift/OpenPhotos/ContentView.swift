import SwiftUI
import Combine

struct ContentView: View {
    @StateObject private var galleryViewModel = GalleryViewModel()
    @StateObject private var photoService = PhotoService.shared
    @State private var selectedTab = 0
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var unlockCtl: E2EEUnlockController
    // Root-level auth gate: show Login as the whole root when unauthenticated.
    
    var body: some View {
        Group {
            if auth.isAuthenticated {
                TabView(selection: $selectedTab) {
                    // New server-backed Photos tab (first)
                    ServerGalleryView(isActiveTab: selectedTab == 0)
                        .environmentObject(auth)
                        .environmentObject(unlockCtl)
                        .tabItem {
                            Image(systemName: "house")
                            Text("Cloud")
                        }
                        .tag(0)

                    // Existing local Gallery moved to second position
                    GalleryView()
                        .environmentObject(galleryViewModel)
                        .tabItem {
                            Image(systemName: "photo.on.rectangle.angled")
                            Text("Photos")
                        }
                        .tag(1)
                    
                    SyncView()
                        .tabItem {
                            Image(systemName: "arrow.clockwise.icloud")
                            Text("Sync")
                        }
                        .tag(2)

                    SettingsView()
                        .tabItem {
                            Image(systemName: "gear")
                            Text("Settings")
                        }
                        .tag(3)
                }
            } else {
                // Root login flow — avoids sheet/overlay conflicts at startup
                LoginView().environmentObject(auth)
            }
        }
        .accentColor(.blue)
        .overlay(alignment: .top) { ToastBanner() }
        .sheet(isPresented: $unlockCtl.showUnlockSheet) {
            UnlockUMKSheet()
                .environmentObject(auth)
                .environmentObject(unlockCtl)
        }
    }
}

struct SyncView: View {
    @EnvironmentObject var auth: AuthManager
    @State private var showingLogin = false
    @State private var showingManageSelectedAlbums = false
    @State private var showResetConfirm = false
    @State private var showRetryBgConfirm = false
    @State private var isSyncing = false
    private let syncBusyTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()
    private var isDemoReadOnly: Bool { auth.isDemoUser }
    var body: some View {
        NavigationStack {
            List {
                if isDemoReadOnly {
                    Section {
                        Text("Demo account is read-only. Sync configuration and actions are locked.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                Section("Server") {
                    ServerAddressEditor()
                        .environmentObject(auth)
                        .disabled(isDemoReadOnly)

                    HStack {
                        if auth.isAuthenticated {
                            Text("Logged In")
                                .foregroundColor(.green)
                        } else {
                            Text("Logged Out")
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if auth.isAuthenticated {
                            Button("Log Out", role: .destructive) { auth.logout() }
                        } else {
                            Button("Log In") { showingLogin = true }
                        }
                    }
                    .buttonStyle(.borderless)
                }
                
                Section("Sync") {
                    HStack(spacing: 10) {
                        Picker("Scope", selection: Binding(
                            get: { auth.syncScope },
                            set: { auth.setSyncScope($0) }
                        )) {
                            Text("All Photos").tag(AuthManager.SyncScope.all)
                            Text("Selected Albums").tag(AuthManager.SyncScope.selectedAlbums)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: .infinity)
                        .disabled(isDemoReadOnly)

                        if auth.syncScope == .selectedAlbums {
                            Button {
                                showingManageSelectedAlbums = true
                            } label: {
                                Image(systemName: "slider.horizontal.3")
                            }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("Manage Selected Albums")
                            .disabled(isDemoReadOnly)
                        }
                    }

                    Toggle("Auto start sync on app open", isOn: Binding(
                        get: { auth.autoStartSyncOnOpen },
                        set: { auth.setAutoStartSyncOnOpen($0) }
                    ))
                    .disabled(isDemoReadOnly)
                    if auth.autoStartSyncOnOpen {
                        Toggle("Auto-start only on Wi‑Fi", isOn: Binding(
                            get: { auth.autoStartWifiOnly },
                            set: { auth.setAutoStartWifiOnly($0) }
                        ))
                        .disabled(isDemoReadOnly)
                    }
                    Toggle("Keep screen on during foreground uploads", isOn: Binding(
                        get: { HybridUploadManager.shared.keepScreenOn },
                        set: { HybridUploadManager.shared.keepScreenOn = $0 }
                    ))
                    .disabled(isDemoReadOnly)
                    Toggle("Use cellular data to sync photos", isOn: Binding(
                        get: { auth.syncUseCellularPhotos },
                        set: { auth.setSyncUseCellularPhotos($0) }
                    ))
                    .disabled(isDemoReadOnly)
                    Toggle("Use cellular data to sync videos", isOn: Binding(
                        get: { auth.syncUseCellularVideos },
                        set: { auth.setSyncUseCellularVideos($0) }
                    ))
                    .disabled(isDemoReadOnly)
                    Toggle("Preserve album structure", isOn: Binding(
                        get: { auth.syncPreserveAlbum },
                        set: { auth.setSyncPreserveAlbum($0) }
                    ))
                    .disabled(isDemoReadOnly)
                    Toggle("Sync photos only", isOn: Binding(
                        get: { auth.syncPhotosOnly },
                        set: { auth.setSyncPhotosOnly($0) }
                    ))
                    .disabled(isDemoReadOnly)
                    // Auto-retry background configuration removed per spec
                }

                Section("Sync Status") {
                    SyncStatusView()
                }

                Section("Actions") {
                    centeredActionButton(isSyncing ? "Syncing..." : "Sync Now", disabled: isSyncing || isDemoReadOnly) {
                        SyncService.shared.syncNow(forceRetryFailed: true, userInitiated: true)
                        isSyncing = HybridUploadManager.shared.isSyncBusy()
                    }

                    centeredActionButton("ReSync", disabled: isDemoReadOnly) {
                        showResetConfirm = true
                    }

                    centeredActionButton("Retry Stuck/Failed", disabled: isDemoReadOnly) {
                        showRetryBgConfirm = true
                    }
                }
            }
            .navigationTitle("Sync")
            .sheet(isPresented: $showingLogin) { LoginView().environmentObject(auth) }
            .navigationDestination(isPresented: $showingManageSelectedAlbums) {
                SyncAlbumsView()
            }
            .onAppear {
                isSyncing = HybridUploadManager.shared.isSyncBusy()
            }
            .onReceive(syncBusyTimer) { _ in
                isSyncing = HybridUploadManager.shared.isSyncBusy()
            }
            // Cache cleared alert moved to Settings
            .alert("ReSync Entire Library?", isPresented: $showResetConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("ReSync", role: .destructive) {
                    if HybridUploadManager.shared.isSyncBusy() {
                        HybridUploadManager.shared.stopForResync()
                    }
                    let n = SyncRepository.shared.resetAllSyncStates()
                    let itemsWord = n == 1 ? "item" : "items"
                    ToastManager.shared.show("Marked \(n) \(itemsWord) as pending")
                    SyncService.shared.syncNow(forceRetryFailed: false, userInitiated: true)
                }
            } message: {
                Text("This marks all photos as pending and starts syncing immediately. Large libraries may take a while.")
            }

            .alert("Retry Stuck/Failed?", isPresented: $showRetryBgConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Retry", role: .destructive) {
                    if HybridUploadManager.shared.isSyncBusy() {
                        HybridUploadManager.shared.stopForResync()
                    }
                    let n = SyncRepository.shared.retryBackgroundQueuedAndFailed()
                    let itemsWord = n == 1 ? "item" : "items"
                    ToastManager.shared.show("Requeued \(n) failed/background \(itemsWord)")
                    SyncService.shared.syncNow(forceRetryFailed: false, userInitiated: true)
                }
            } message: {
                Text("Requeues failed and background-queued items as pending, then retries sync. Server deduplication prevents duplicates.")
            }
            .onReceive(NotificationCenter.default.publisher(for: .authUnauthorized)) { _ in
                showingLogin = true
            }
        }
    }

    private func centeredActionButton(_ title: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        GeometryReader { proxy in
            HStack {
                Spacer(minLength: 0)
                Button(action: action) {
                    Text(title)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .multilineTextAlignment(.center)
                }
                .buttonStyle(.borderedProminent)
                .frame(width: proxy.size.width * 0.9)
                .disabled(disabled)
                Spacer(minLength: 0)
            }
        }
        .frame(height: 44)
    }
}

extension SyncView {
}

// New lightweight Settings view with dynamic logo and version info
struct SettingsView: View {
    @EnvironmentObject var auth: AuthManager
    @Environment(\.openURL) private var openURL
    @ObservedObject private var uploader = HybridUploadManager.shared
    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let ver = (info?["CFBundleShortVersionString"] as? String) ?? "-"
        let build = (info?["CFBundleVersion"] as? String) ?? "-"
        return "\(ver) (\(build))"
    }
    @State private var capsThumbsMB: Int = Int(DiskImageCache.shared.caps().thumbsBytes / (1024*1024))
    @State private var capsImagesMB: Int = Int(DiskImageCache.shared.caps().imagesBytes / (1024*1024))
    @State private var capsVideosMB: Int = Int(DiskImageCache.shared.caps().videosBytes / (1024*1024))
    @State private var showCacheCleared: Bool = false
    @State private var usageThumbs: Int64 = 0
    @State private var usageImages: Int64 = 0
    @State private var usageVideos: Int64 = 0
    private var isDemoReadOnly: Bool { auth.isDemoUser }

    var body: some View {
        NavigationStack {
            List {
                if isDemoReadOnly {
                    Section {
                        Text("Demo account is read-only. Settings and security changes are disabled.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                // Cache settings
                Section("Cache") {
                    HStack { Text("Thumbnails usage"); Spacer(); Text(ByteCountFormatter.string(fromByteCount: usageThumbs, countStyle: .file)).foregroundColor(.secondary) }
                    HStack { Text("Images usage"); Spacer(); Text(ByteCountFormatter.string(fromByteCount: usageImages, countStyle: .file)).foregroundColor(.secondary) }
                    HStack { Text("Videos usage"); Spacer(); Text(ByteCountFormatter.string(fromByteCount: usageVideos, countStyle: .file)).foregroundColor(.secondary) }
                    Stepper(value: $capsThumbsMB, in: 50...4096, step: 50) { Text("Thumbnails cap: \(capsThumbsMB) MB").foregroundColor(.secondary) }
                        .disabled(isDemoReadOnly)
                    Stepper(value: $capsImagesMB, in: 200...8192, step: 100) { Text("Images cap: \(capsImagesMB) MB").foregroundColor(.secondary) }
                        .disabled(isDemoReadOnly)
                    Stepper(value: $capsVideosMB, in: 500...20480, step: 500) { Text("Videos cap: \(capsVideosMB) MB").foregroundColor(.secondary) }
                        .disabled(isDemoReadOnly)
                    Button("Apply Cache Caps") {
                        let caps = DiskImageCache.Caps(
                            thumbsBytes: Int64(capsThumbsMB) * 1024 * 1024,
                            imagesBytes: Int64(capsImagesMB) * 1024 * 1024,
                            videosBytes: Int64(capsVideosMB) * 1024 * 1024
                        )
                        DiskImageCache.shared.setCaps(caps)
                        refreshCacheUsage()
                    }
                    .disabled(isDemoReadOnly)
                    Button("Clear Cache", role: .destructive) {
                        DiskImageCache.shared.clearAll()
                        let _ = uploader.clearCache() // also clear upload temp artifacts
                        showCacheCleared = true
                        refreshCacheUsage()
                    }
                    .disabled(isDemoReadOnly)
                    Button("Refresh Usage") { refreshCacheUsage() }
                }
                Section("Security") {
                    NavigationLink(destination: SecuritySettingsView().environmentObject(auth)) {
                        Text("End-to-End Encryption")
                    }
                    .disabled(isDemoReadOnly)
                }
                Section("Account") {
                    NavigationLink(destination: ChangePasswordView().environmentObject(auth)) {
                        Text("Change Password")
                    }
                    .disabled(isDemoReadOnly)
                }
                Section("Server") {
                    HStack {
                        Text("Server URL")
                        Spacer()
                        if let url = URL(string: auth.serverURL) {
                            Link(auth.serverURL, destination: url)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Text(auth.serverURL)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Button {
                        Clipboard.copy(auth.serverURL)
                        ToastManager.shared.show("Server URL copied")
                    } label: {
                        Text("Copy Server URL")
                    }
                }

                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(versionString)
                            .foregroundColor(.secondary)
                    }
                    if let url = AppLinks.website {
                        Link("Website", destination: url)
                    }
                    if let url = AppLinks.privacyPolicy {
                        Link("Privacy Policy", destination: url)
                    }
                    if let url = AppLinks.terms {
                        Link("Terms of Service", destination: url)
                    }
                    if let url = AppLinks.github {
                        Link("GitHub", destination: url)
                    }
                    if let url = AppLinks.supportEmail {
                        Button {
                            openURL(url)
                        } label: {
                            HStack {
                                Text("Support Email")
                                Spacer()
                                Text(AppLinks.supportEmailAddress)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .alert("Cache Cleared", isPresented: $showCacheCleared) { Button("OK", role: .cancel) { showCacheCleared = false } } message: { Text("Image cache and temp artifacts cleared") }
            .onAppear { refreshCacheUsage() }
        }
    }
}

extension SettingsView {
    private func refreshCacheUsage() {
        let thumbs = DiskImageCache.shared.usageBytes(bucket: .thumbs) + DiskImageCache.shared.usageBytes(bucket: .faces)
        let images = DiskImageCache.shared.usageBytes(bucket: .images)
        let videos = DiskImageCache.shared.usageBytes(bucket: .videos)
        usageThumbs = thumbs
        usageImages = images
        usageVideos = videos
    }
}

struct EventsView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 30) {
                Image(systemName: "calendar.badge.plus")
                    .font(.system(size: 80))
                    .foregroundColor(.blue)
                
                VStack(spacing: 10) {
                    Text("Events Coming Soon")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text("Create and share photo events with friends and family")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
            }
            .navigationTitle("Events")
        }
    }
}

#Preview {
    ContentView()
}
