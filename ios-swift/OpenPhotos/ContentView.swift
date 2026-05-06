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
                            Image(systemName: "cloud")
                            Text(L10n.tr("Cloud"))
                        }
                        .tag(0)

                    // Existing local Gallery moved to second position
                    GalleryView()
                        .environmentObject(galleryViewModel)
                        .tabItem {
                            Image(systemName: "photo.on.rectangle.angled")
                            Text(L10n.tr("Local"))
                        }
                        .tag(1)
                    
                    SyncView()
                        .tabItem {
                            Image(systemName: "arrow.up.circle")
                            Text(L10n.tr("Sync"))
                        }
                        .tag(2)

                    SettingsView()
                        .tabItem {
                            Image(systemName: "gear")
                            Text(L10n.tr("Settings"))
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
                Section(header: Text(L10n.tr("Server"))) {
                    NavigationLink(destination: NetworkSettingsView().environmentObject(auth)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.tr("Advanced Network"))
                            Text(auth.currentEffectiveBaseURL().isEmpty ? L10n.tr("Configure a public or local server URL.") : auth.currentEffectiveBaseURL())
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                    }
                    .disabled(isDemoReadOnly)

                    Text(L10n.tr(auth.networkStatusSummary()))
                        .font(.footnote)
                        .foregroundColor(.secondary)

                    HStack {
                        if auth.isAuthenticated {
                            Text(L10n.tr("Logged In"))
                                .foregroundColor(.green)
                        } else {
                            Text(L10n.tr("Logged Out"))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if auth.isAuthenticated {
                            Button(L10n.tr("Log Out"), role: .destructive) { auth.logout() }
                        } else {
                            Button(L10n.tr("Log In")) { showingLogin = true }
                        }
                    }
                    .buttonStyle(.borderless)
                }
                
                Section(header: Text(L10n.tr("Sync"))) {
                    HStack(spacing: 10) {
                        syncScopeControl
                            .frame(maxWidth: .infinity)

                        if auth.syncScope == .selectedAlbums {
                            Button {
                                showingManageSelectedAlbums = true
                            } label: {
                                Image(systemName: "slider.horizontal.3")
                            }
                            .buttonStyle(.bordered)
                            .accessibilityLabel(L10n.tr("Manage Selected Albums"))
                            .disabled(isDemoReadOnly)
                        }
                    }

                    Toggle(L10n.tr("Auto start sync on app open"), isOn: Binding(
                        get: { auth.autoStartSyncOnOpen },
                        set: { auth.setAutoStartSyncOnOpen($0) }
                    ))
                    .disabled(isDemoReadOnly)
                    if auth.autoStartSyncOnOpen {
                        Toggle(L10n.tr("Auto-start only on Wi‑Fi"), isOn: Binding(
                            get: { auth.autoStartWifiOnly },
                            set: { auth.setAutoStartWifiOnly($0) }
                        ))
                        .disabled(isDemoReadOnly)
                    }
                    Toggle(L10n.tr("Keep screen on during foreground uploads"), isOn: Binding(
                        get: { HybridUploadManager.shared.keepScreenOn },
                        set: { HybridUploadManager.shared.keepScreenOn = $0 }
                    ))
                    .disabled(isDemoReadOnly)
                    Toggle(L10n.tr("Use cellular data to sync photos"), isOn: Binding(
                        get: { auth.syncUseCellularPhotos },
                        set: { auth.setSyncUseCellularPhotos($0) }
                    ))
                    .disabled(isDemoReadOnly)
                    Toggle(L10n.tr("Use cellular data to sync videos"), isOn: Binding(
                        get: { auth.syncUseCellularVideos },
                        set: { auth.setSyncUseCellularVideos($0) }
                    ))
                    .disabled(isDemoReadOnly)
                    Toggle(L10n.tr("Preserve album structure"), isOn: Binding(
                        get: { auth.syncPreserveAlbum },
                        set: { auth.setSyncPreserveAlbum($0) }
                    ))
                    .disabled(isDemoReadOnly)
                    Toggle(L10n.tr("Sync photos only"), isOn: Binding(
                        get: { auth.syncPhotosOnly },
                        set: { auth.setSyncPhotosOnly($0) }
                    ))
                    .disabled(isDemoReadOnly)
                    // Auto-retry background configuration removed per spec
                }

                Section(header: Text(L10n.tr("Sync Status"))) {
                    SyncStatusView()
                }

                Section(header: Text(L10n.tr("Actions"))) {
                    centeredActionButton(
                        isSyncing ? "Stop Syncing" : "Sync Now",
                        disabled: isDemoReadOnly,
                        tint: isSyncing ? .red : .accentColor
                    ) {
                        if isSyncing {
                            SyncService.shared.stopCurrentSync()
                            isSyncing = false
                        } else {
                            SyncService.shared.syncNow(forceRetryFailed: true, userInitiated: true)
                            isSyncing = true
                        }
                    }

                    centeredActionButton("ReSync", disabled: isDemoReadOnly) {
                        showResetConfirm = true
                    }

                    centeredActionButton("Retry Stuck/Failed", disabled: isDemoReadOnly) {
                        showRetryBgConfirm = true
                    }
                }
            }
            .navigationTitle(L10n.tr("Sync"))
            .sheet(isPresented: $showingLogin) { LoginView().environmentObject(auth) }
            .navigationDestination(isPresented: $showingManageSelectedAlbums) {
                SyncAlbumsView()
            }
            .onAppear {
                isSyncing = SyncService.shared.isSyncBusyOrPendingResume()
            }
            .onReceive(syncBusyTimer) { _ in
                isSyncing = SyncService.shared.isSyncBusyOrPendingResume()
            }
            // Cache cleared alert moved to Settings
            .alert(L10n.tr("ReSync Entire Library?"), isPresented: $showResetConfirm) {
                Button(L10n.tr("Cancel"), role: .cancel) {}
                Button(L10n.tr("ReSync"), role: .destructive) {
                    if HybridUploadManager.shared.isSyncBusy() {
                        HybridUploadManager.shared.stopForResync()
                    }
                    let n = SyncRepository.shared.resetAllSyncStates()
                    let itemsWord = n == 1 ? "item" : "items"
                    ToastManager.shared.show("Marked \(n) \(itemsWord) as pending")
                    SyncService.shared.syncNow(forceRetryFailed: false, userInitiated: true)
                    isSyncing = true
                }
            } message: {
                Text(L10n.tr("This marks all photos as pending and starts syncing immediately. Large libraries may take a while."))
            }

            .alert(L10n.tr("Retry Stuck/Failed?"), isPresented: $showRetryBgConfirm) {
                Button(L10n.tr("Cancel"), role: .cancel) {}
                Button(L10n.tr("Retry"), role: .destructive) {
                    if HybridUploadManager.shared.isSyncBusy() {
                        HybridUploadManager.shared.stopForResync()
                    }
                    let n = SyncRepository.shared.retryBackgroundQueuedAndFailed()
                    let itemsWord = n == 1 ? "item" : "items"
                    ToastManager.shared.show("Requeued \(n) failed/background \(itemsWord)")
                    SyncService.shared.syncNow(forceRetryFailed: false, userInitiated: true)
                    isSyncing = true
                }
            } message: {
                Text(L10n.tr("Requeues failed and background-queued items as pending, then retries sync. Server deduplication prevents duplicates."))
            }
            .onReceive(NotificationCenter.default.publisher(for: .authUnauthorized)) { _ in
                showingLogin = true
            }
        }
    }

    private func centeredActionButton(
        _ title: String,
        disabled: Bool = false,
        tint: Color = .accentColor,
        action: @escaping () -> Void
    ) -> some View {
        GeometryReader { proxy in
            HStack {
                Spacer(minLength: 0)
                Button(action: action) {
                    Text(L10n.tr(title))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .multilineTextAlignment(.center)
                }
                .buttonStyle(.borderedProminent)
                .tint(tint)
                .frame(width: proxy.size.width * 0.9)
                .disabled(disabled)
                Spacer(minLength: 0)
            }
        }
        .frame(height: 44)
    }

    private var syncScopeControl: some View {
        HStack(spacing: 0) {
            syncScopeButton("All Photos", scope: .all)
            syncScopeButton("Selected Albums", scope: .selectedAlbums)
        }
        .padding(4)
        .background(Color(uiColor: .systemGray5))
        .clipShape(Capsule())
        .disabled(isDemoReadOnly)
        .opacity(isDemoReadOnly ? 0.6 : 1.0)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("Sync scope"))
    }

    private func syncScopeButton(_ title: String, scope: AuthManager.SyncScope) -> some View {
        let isSelected = auth.syncScope == scope
        return Button {
            auth.setSyncScope(scope)
        } label: {
            Text(L10n.tr(title))
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .foregroundColor(isSelected ? .white : .primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .padding(.horizontal, 8)
                .background(isSelected ? Color(uiColor: .systemGreen) : Color.clear)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension SyncView {
}

// New lightweight Settings view with dynamic logo and version info
struct SettingsView: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var localeController: LocaleController
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
    @State private var serverVersion: String? = nil
    @State private var isLoadingServerVersion = false
    @State private var serverUpdateStatus: ServerUpdateService.UpdateStatus? = nil
    @State private var isLoadingServerUpdate = false
    @State private var showServerUpdateSection = false
    @State private var serverUpdateError: String? = nil
    @State private var libraryStats: ServerMediaCounts? = nil
    @State private var isLoadingLibraryStats = false
    @State private var libraryStatsFailed = false
    private var isDemoReadOnly: Bool { auth.isDemoUser }
    private var accountName: String {
        if let name = auth.userName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if let email = auth.userEmail?.trimmingCharacters(in: .whitespacesAndNewlines),
           let prefix = email.split(separator: "@").first,
           !prefix.isEmpty {
            return String(prefix)
        }
        return "-"
    }
    private var accountEmail: String {
        let email = auth.userEmail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return email.isEmpty ? "-" : email
    }
    private var accountServerURL: String {
        let url = auth.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return url.isEmpty ? "-" : url
    }
    private var accountServerVersion: String {
        if isLoadingServerVersion {
            return L10n.tr("Loading…")
        }
        if let version = serverVersion, !version.isEmpty {
            return version
        }
        return L10n.tr("Unavailable")
    }
    private var serverUpdateStatusLabel: String {
        if isLoadingServerUpdate && serverUpdateStatus == nil {
            return L10n.tr("Loading…")
        }
        switch serverUpdateStatus?.status {
        case "disabled":
            return L10n.tr("Update checks disabled")
        case "check_failed":
            return L10n.tr("Check failed")
        case "unsupported_install_mode":
            return L10n.tr("Unsupported install mode")
        case "ok":
            return serverUpdateStatus?.available == true ? L10n.tr("Update available") : L10n.tr("Up to date")
        default:
            if serverUpdateError != nil {
                return L10n.tr("Unavailable")
            }
            return L10n.tr("Never checked")
        }
    }
    private var serverUpdateCurrentVersion: String {
        let version = serverUpdateStatus?.currentVersion.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !version.isEmpty {
            return version
        }
        return accountServerVersion
    }
    private var serverUpdateLatestVersion: String {
        let version = serverUpdateStatus?.latestVersion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !version.isEmpty {
            return version
        }
        if isLoadingServerUpdate && serverUpdateStatus == nil {
            return L10n.tr("Loading…")
        }
        return L10n.tr("Unavailable")
    }
    private var serverUpdateErrorMessage: String? {
        if let value = serverUpdateStatus?.lastError?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }
        if let value = serverUpdateError?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }
        return nil
    }
    private func libraryCountText(_ value: Int?) -> String {
        if isLoadingLibraryStats {
            return L10n.tr("Loading…")
        }
        guard !libraryStatsFailed, let value else {
            return L10n.tr("Unavailable")
        }
        return NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }
    private var librarySizeText: String {
        if isLoadingLibraryStats {
            return L10n.tr("Loading…")
        }
        guard !libraryStatsFailed, let bytes = libraryStats?.total_size_bytes else {
            return L10n.tr("Unavailable")
        }
        return formatLibrarySize(bytes)
    }
    private func formatLibrarySize(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var size = Double(max(0, bytes))
        var unitIndex = 0
        while size >= 1000, unitIndex < units.count - 1 {
            size /= 1000
            unitIndex += 1
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = unitIndex == 0 ? 0 : 2
        formatter.minimumFractionDigits = 0
        let formatted = formatter.string(from: NSNumber(value: size)) ?? "\(size)"
        return "\(formatted) \(units[unitIndex])"
    }

    var body: some View {
        NavigationStack {
            List {
                if isDemoReadOnly {
                    Section {
                        Text(L10n.tr("Demo account is read-only. Settings and security changes are disabled."))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                Section(L10n.tr("Language")) {
                    Picker(L10n.tr("Language"), selection: Binding(
                        get: { localeController.mode },
                        set: { localeController.setMode($0) }
                    )) {
                        Text(L10n.settings_language_system).tag(LocaleController.modeSystem)
                        Text(L10n.settings_language_english).tag(LocaleController.modeEnglish)
                        Text(L10n.settings_language_simplified_chinese).tag(LocaleController.modeSimplifiedChinese)
                        Text(L10n.settings_language_french).tag(LocaleController.modeFrench)
                        Text(L10n.settings_language_spanish).tag(LocaleController.modeSpanish)
                    }
                    Text(L10n.tr("Choose the display language for this device."))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                Section(L10n.tr("Cloud Library")) {
                    HStack {
                        Text(L10n.tr("Photos"))
                        Spacer()
                        Text(libraryCountText(libraryStats?.photos))
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text(L10n.tr("Videos"))
                        Spacer()
                        Text(libraryCountText(libraryStats?.videos))
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text(L10n.tr("Total Size"))
                        Spacer()
                        Text(librarySizeText)
                            .foregroundColor(.secondary)
                    }
                }
                // Cache settings
                Section(L10n.tr("Cache")) {
                    HStack { Text(L10n.tr("Thumbnails usage")); Spacer(); Text(ByteCountFormatter.string(fromByteCount: usageThumbs, countStyle: .file)).foregroundColor(.secondary) }
                    HStack { Text(L10n.tr("Images usage")); Spacer(); Text(ByteCountFormatter.string(fromByteCount: usageImages, countStyle: .file)).foregroundColor(.secondary) }
                    HStack { Text(L10n.tr("Videos usage")); Spacer(); Text(ByteCountFormatter.string(fromByteCount: usageVideos, countStyle: .file)).foregroundColor(.secondary) }
                    Stepper(value: $capsThumbsMB, in: 50...4096, step: 50) { Text(L10n.tr("Thumbnails cap: %d MB", capsThumbsMB)).foregroundColor(.secondary) }
                        .disabled(isDemoReadOnly)
                    Stepper(value: $capsImagesMB, in: 200...8192, step: 100) { Text(L10n.tr("Images cap: %d MB", capsImagesMB)).foregroundColor(.secondary) }
                        .disabled(isDemoReadOnly)
                    Stepper(value: $capsVideosMB, in: 500...20480, step: 500) { Text(L10n.tr("Videos cap: %d MB", capsVideosMB)).foregroundColor(.secondary) }
                        .disabled(isDemoReadOnly)
                    Button(L10n.tr("Apply Cache Caps")) {
                        let caps = DiskImageCache.Caps(
                            thumbsBytes: Int64(capsThumbsMB) * 1024 * 1024,
                            imagesBytes: Int64(capsImagesMB) * 1024 * 1024,
                            videosBytes: Int64(capsVideosMB) * 1024 * 1024
                        )
                        DiskImageCache.shared.setCaps(caps)
                        refreshCacheUsage()
                    }
                    .disabled(isDemoReadOnly)
                    Button(L10n.tr("Clear Cache"), role: .destructive) {
                        DiskImageCache.shared.clearAll()
                        let _ = uploader.clearCache() // also clear upload temp artifacts
                        showCacheCleared = true
                        refreshCacheUsage()
                    }
                    .disabled(isDemoReadOnly)
                    Button(L10n.tr("Refresh Usage")) { refreshCacheUsage() }
                }
                Section(L10n.tr("Security")) {
                    NavigationLink(destination: SecuritySettingsView().environmentObject(auth)) {
                        Text(L10n.tr("End-to-End Encryption"))
                    }
                    .disabled(isDemoReadOnly)
                }
                Section(L10n.tr("Network")) {
                    NavigationLink(destination: NetworkSettingsView().environmentObject(auth)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.tr("Advanced Network"))
                            Text(auth.currentEffectiveBaseURL().isEmpty ? L10n.tr("Configure a public or local server URL.") : auth.currentEffectiveBaseURL())
                                .foregroundColor(.secondary)
                                .font(.footnote)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                    }
                    .disabled(isDemoReadOnly)
                }
                Section(L10n.tr("Account")) {
                    HStack {
                        Text(L10n.tr("Name"))
                        Spacer()
                        Text(accountName)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text(L10n.tr("Email"))
                        Spacer()
                        Text(accountEmail)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    HStack(alignment: .top) {
                        Text(L10n.tr("Server URL"))
                        Spacer()
                        Text(accountServerURL)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.trailing)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    HStack {
                        Text(L10n.tr("Server Version"))
                        Spacer()
                        Text(accountServerVersion)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    NavigationLink(destination: ChangePasswordView().environmentObject(auth)) {
                        Text(L10n.tr("Change Password"))
                    }
                    .disabled(isDemoReadOnly)
                }
                if showServerUpdateSection {
                    Section(L10n.tr("Server Update")) {
                        HStack {
                            Text(L10n.tr("Status"))
                            Spacer()
                            Text(serverUpdateStatusLabel)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                        HStack {
                            Text(L10n.tr("Current Version"))
                            Spacer()
                            Text(serverUpdateCurrentVersion)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                        HStack {
                            Text(L10n.tr("Latest Version"))
                            Spacer()
                            Text(serverUpdateLatestVersion)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                        if let errorMessage = serverUpdateErrorMessage {
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                        Text(L10n.tr("Install updates from the web admin UI or directly on the server host."))
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }

                Section(L10n.tr("About")) {
                    HStack {
                        Text(L10n.tr("Version"))
                        Spacer()
                        Text(versionString)
                            .foregroundColor(.secondary)
                    }
                    if let url = AppLinks.website {
                        Link(L10n.tr("Website"), destination: url)
                    }
                    if let url = AppLinks.privacyPolicy {
                        Link(L10n.tr("Privacy Policy"), destination: url)
                    }
                    if let url = AppLinks.terms {
                        Link(L10n.tr("Terms of Service"), destination: url)
                    }
                    if let url = AppLinks.github {
                        Link("GitHub", destination: url)
                    }
                    if let url = AppLinks.supportEmail {
                        HStack {
                            Button {
                                openURL(url)
                            } label: {
                                Text(L10n.tr("Support Email"))
                            }
                            .buttonStyle(.plain)
                            Spacer()
                            Button {
                                Clipboard.copy(AppLinks.supportEmailAddress)
                                ToastManager.shared.show(L10n.tr("Support email copied"))
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(L10n.tr("Copy support email"))
                        }
                    }
                }
            }
            .navigationTitle(L10n.tr("Settings"))
            .alert(L10n.tr("Cache Cleared"), isPresented: $showCacheCleared) {
                Button(L10n.tr("OK"), role: .cancel) { showCacheCleared = false }
            } message: {
                Text(L10n.tr("Image cache and temp artifacts cleared"))
            }
            .onAppear {
                refreshCacheUsage()
                Task { await refreshLibraryStats() }
                Task { await refreshServerVersion(force: true) }
                Task { await refreshServerUpdateStatus() }
            }
            .onChange(of: auth.serverURL) {
                Task { await refreshLibraryStats() }
                Task { await refreshServerVersion(force: true) }
                Task { await refreshServerUpdateStatus() }
            }
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

    private func refreshLibraryStats() async {
        let requestedServerURL = await MainActor.run {
            auth.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !requestedServerURL.isEmpty else {
            await MainActor.run {
                libraryStats = nil
                libraryStatsFailed = true
                isLoadingLibraryStats = false
            }
            return
        }

        await MainActor.run {
            isLoadingLibraryStats = true
            libraryStatsFailed = false
        }

        do {
            var query = ServerPhotoListQuery()
            query.include_locked = true
            let stats = try await ServerPhotosService.shared.getMediaCounts(query: query)
            await MainActor.run {
                guard auth.serverURL.trimmingCharacters(in: .whitespacesAndNewlines) == requestedServerURL else { return }
                libraryStats = stats
                libraryStatsFailed = false
                isLoadingLibraryStats = false
            }
        } catch {
            await MainActor.run {
                guard auth.serverURL.trimmingCharacters(in: .whitespacesAndNewlines) == requestedServerURL else { return }
                libraryStats = nil
                libraryStatsFailed = true
                isLoadingLibraryStats = false
            }
        }
    }

    private func refreshServerVersion(force: Bool) async {
        let requestedServerURL = await MainActor.run {
            auth.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !requestedServerURL.isEmpty else {
            await MainActor.run {
                isLoadingServerVersion = false
                serverVersion = nil
            }
            return
        }

        await MainActor.run {
            isLoadingServerVersion = true
        }

        do {
            let caps = try await CapabilitiesService.shared.get(force: force)
            let resolvedVersion = caps.version?.trimmingCharacters(in: .whitespacesAndNewlines)
            let currentServerURL = await MainActor.run {
                auth.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard currentServerURL == requestedServerURL else { return }
            await MainActor.run {
                serverVersion = (resolvedVersion?.isEmpty == false) ? resolvedVersion : nil
                isLoadingServerVersion = false
            }
        } catch {
            let currentServerURL = await MainActor.run {
                auth.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard currentServerURL == requestedServerURL else { return }
            await MainActor.run {
                serverVersion = nil
                isLoadingServerVersion = false
            }
        }
    }

    private func refreshServerUpdateStatus() async {
        let requestedServerURL = await MainActor.run {
            auth.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !requestedServerURL.isEmpty else {
            await MainActor.run {
                showServerUpdateSection = false
                serverUpdateStatus = nil
                serverUpdateError = nil
                isLoadingServerUpdate = false
            }
            return
        }

        await MainActor.run {
            isLoadingServerUpdate = true
        }

        let result = await ServerUpdateService.shared.getStatus()
        let currentServerURL = await MainActor.run {
            auth.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard currentServerURL == requestedServerURL else { return }

        await MainActor.run {
            switch result {
            case .authorized(let status):
                serverUpdateStatus = status
                serverUpdateError = nil
                showServerUpdateSection = true
            case .forbidden:
                serverUpdateStatus = nil
                serverUpdateError = nil
                showServerUpdateSection = false
            case .failure(let message):
                serverUpdateError = message
                showServerUpdateSection = true
            }
            isLoadingServerUpdate = false
        }
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
