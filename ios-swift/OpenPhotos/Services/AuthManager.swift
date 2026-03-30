import Foundation
import Combine
import Network
import Darwin

private actor RefreshCoordinator {
    private var inFlight = false
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    func run(operation: @escaping () async -> Bool) async -> Bool {
        if inFlight {
            return await withCheckedContinuation { cont in
                waiters.append(cont)
            }
        }
        inFlight = true
        let result = await operation()
        inFlight = false
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.resume(returning: result)
        }
        return result
    }
}

final class AuthManager: ObservableObject {
    static let shared = AuthManager()
    private static let demoEmail = "demo@openphotos.ca"

    enum ManualPreferredEndpoint: String, CaseIterable, Identifiable {
        case `public`
        case local

        var id: String { rawValue }
    }

    enum ActiveEndpoint: String {
        case none
        case `public`
        case local
    }

    enum NetworkTransportKind: String {
        case offline
        case wifi
        case ethernet
        case cellular
        case other
    }

    @Published private(set) var serverURL: String
    @Published private(set) var publicBaseURL: String
    @Published private(set) var localBaseURL: String
    @Published private(set) var autoSwitchEnabled: Bool
    @Published private(set) var manualPreferredEndpoint: ManualPreferredEndpoint
    @Published private(set) var activeEndpoint: ActiveEndpoint = .none
    @Published private(set) var networkTransport: NetworkTransportKind = .offline
    @Published private(set) var lastLocalProbeSucceeded: Bool?
    @Published private(set) var lastLocalProbeMessage: String?
    @Published private(set) var lastLocalProbeAt: Date?
    @Published private(set) var token: String?
    @Published private(set) var refreshToken: String?
    @Published private(set) var expiresAt: Date?
    @Published private(set) var userId: String?
    @Published private(set) var userName: String?
    @Published private(set) var userEmail: String?
    @Published private(set) var isAuthenticated: Bool = false
    var isDemoUser: Bool { (userEmail ?? "").lowercased() == Self.demoEmail }
    // Sync settings
    enum SyncScope: String { case all, selectedAlbums }
    @Published var syncUseCellularPhotos: Bool = false
    @Published var syncUseCellularVideos: Bool = false
    @Published var syncPreserveAlbum: Bool = true
    @Published var syncPhotosOnly: Bool = false
    @Published var syncScope: SyncScope = .all
    @Published var syncIncludeUnassigned: Bool = false
    @Published var syncUnassignedLocked: Bool = false
    @Published var autoStartSyncOnOpen: Bool = true
    @Published var autoStartWifiOnly: Bool = true
    @Published var autoRetryBgMinutes: Int = 5
    @Published private(set) var syncEnabledAfterManualStart: Bool = false
    private let refreshCoordinator = RefreshCoordinator()

    private let keychain = KeychainHelper.shared
    private let tokenService = "com.openphotos.auth"
    private let tokenAccount = "jwt"
    private let refreshAccount = "refresh"
    private let expiresAccount = "expires"
    private let credentialsService = "com.openphotos.auth.credentials"
    private let credentialEmailAccount = "email"
    private let credentialPasswordAccount = "password"
    private let credentialOrgIdAccount = "organization_id"
    private let credentialServerAccount = "server_url"
    private let userIdDefaultsKey = "auth.userId"
    private let userNameDefaultsKey = "auth.userName"
    private let userEmailDefaultsKey = "auth.userEmail"
    private let lastLoginEmailDefaultsKey = "auth.lastLoginEmail"
    private let serverURLDefaultsKey = "server.baseURL"
    private let publicServerURLDefaultsKey = "network.publicBaseURL"
    private let localServerURLDefaultsKey = "network.localBaseURL"
    private let autoSwitchDefaultsKey = "network.autoSwitchEnabled"
    private let manualPreferredEndpointDefaultsKey = "network.manualPreferredEndpoint"
    private let serverSchemeDefaultsKey = "server.scheme"
    private let serverHostDefaultsKey = "server.host"
    private let serverPortDefaultsKey = "server.port"
    private let serverRecentsDefaultsKey = "server.recents"
    private let syncEnabledDefaultsKey = "sync.enabledAfterManualStart"

    static let defaultServerPort: Int = 3003
    static let defaultServerScheme: String = "http"
    private let firstRunMarkerKey = "app.firstRunMarker"
    private var lastAutoLoginAttemptAt: Date?
    private let autoLoginCooldownSeconds: TimeInterval = 20
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "openphotos.auth.network")
    private let routeDecisionTTL: TimeInterval = 30
    private let localProbeFailureBackoff: TimeInterval = 60
    private var currentUsesWiFiOrEthernet = false
    private var currentHasPrivateOrLoopbackLANAddress = false
    private var networkGeneration: Int = 0
    private var lastProbeNetworkGeneration: Int = -1
    private var hasManualServerOverride = false
    private var manualServerOverrideBaseURL: String = ""

    private init() {
        let defaults = UserDefaults.standard
        let legacyBaseURL = AuthManager.migratedLegacyServerURL(defaults: defaults)
        let persistedPublicBaseURL = AuthManager.normalizedBaseURL(defaults.string(forKey: publicServerURLDefaultsKey))
        let persistedLocalBaseURL = AuthManager.normalizedBaseURL(defaults.string(forKey: localServerURLDefaultsKey))
        let initialConfiguredBaseURLs = AuthManager.repartitionConfiguredBaseURLs(
            publicBaseURL: !persistedPublicBaseURL.isEmpty ? persistedPublicBaseURL : legacyBaseURL,
            localBaseURL: persistedLocalBaseURL
        )
        let resolvedPublicBaseURL = initialConfiguredBaseURLs.publicBaseURL
        let resolvedLocalBaseURL = initialConfiguredBaseURLs.localBaseURL
        let autoSwitch = defaults.object(forKey: autoSwitchDefaultsKey) as? Bool ?? true
        let manualPreferredRaw = defaults.string(forKey: manualPreferredEndpointDefaultsKey) ?? ManualPreferredEndpoint.public.rawValue
        let manualPreferred = ManualPreferredEndpoint(rawValue: manualPreferredRaw) ?? .public
        let initialServerURL = AuthManager.initialResolvedBaseURL(
            publicBaseURL: resolvedPublicBaseURL,
            localBaseURL: resolvedLocalBaseURL,
            autoSwitchEnabled: autoSwitch,
            manualPreferredEndpoint: manualPreferred
        )
        self.publicBaseURL = resolvedPublicBaseURL
        self.localBaseURL = resolvedLocalBaseURL
        self.autoSwitchEnabled = autoSwitch
        self.manualPreferredEndpoint = manualPreferred
        self.serverURL = initialServerURL
        self.activeEndpoint = AuthManager.endpointType(
            for: initialServerURL,
            publicBaseURL: resolvedPublicBaseURL,
            localBaseURL: resolvedLocalBaseURL
        )
        defaults.set(resolvedPublicBaseURL, forKey: publicServerURLDefaultsKey)
        defaults.set(resolvedLocalBaseURL, forKey: localServerURLDefaultsKey)
        defaults.set(autoSwitch, forKey: autoSwitchDefaultsKey)
        defaults.set(manualPreferred.rawValue, forKey: manualPreferredEndpointDefaultsKey)
        defaults.set(initialServerURL, forKey: serverURLDefaultsKey)
        if let parsed = AuthManager.parseBaseURL(resolvedPublicBaseURL.isEmpty ? initialServerURL : resolvedPublicBaseURL) {
            defaults.set(parsed.scheme, forKey: serverSchemeDefaultsKey)
            defaults.set(parsed.host, forKey: serverHostDefaultsKey)
            defaults.set(parsed.port ?? AuthManager.defaultServerPort, forKey: serverPortDefaultsKey)
        }

        // Keychain items (including auth tokens) can survive uninstall/reinstall.
        // On a true "first run" (no marker), purge auth tokens so the app doesn't boot into a stale session.
        if defaults.string(forKey: firstRunMarkerKey) == nil {
            keychain.remove(service: tokenService, account: tokenAccount)
            keychain.remove(service: tokenService, account: refreshAccount)
            keychain.remove(service: tokenService, account: expiresAccount)
            clearLoginCredentials()
            defaults.removeObject(forKey: userIdDefaultsKey)
            defaults.removeObject(forKey: userNameDefaultsKey)
            defaults.removeObject(forKey: userEmailDefaultsKey)
            defaults.removeObject(forKey: lastLoginEmailDefaultsKey)
            token = nil
            refreshToken = nil
            expiresAt = nil
            userId = nil
            userName = nil
            userEmail = nil
            isAuthenticated = false
        }

        if let data = keychain.get(service: tokenService, account: tokenAccount),
           let str = String(data: data, encoding: .utf8), !str.isEmpty {
            self.token = str
            self.isAuthenticated = true
        }
        if let r = keychain.get(service: tokenService, account: refreshAccount),
           let s = String(data: r, encoding: .utf8), !s.isEmpty {
            self.refreshToken = s
        }
        if let e = keychain.get(service: tokenService, account: expiresAccount),
           let s = String(data: e, encoding: .utf8), let ts = TimeInterval(s) {
            self.expiresAt = Date(timeIntervalSince1970: ts)
        }
        // Load user_id (from previous session if available)
        self.userId = UserDefaults.standard.string(forKey: userIdDefaultsKey)
        self.userName = UserDefaults.standard.string(forKey: userNameDefaultsKey)
        self.userEmail = UserDefaults.standard.string(forKey: userEmailDefaultsKey)
        if self.userEmail == nil, let saved = loadSavedCredentials() {
            self.userEmail = saved.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        // Load sync prefs
        let photosCell = UserDefaults.standard.object(forKey: "sync.useCellularPhotos") as? Bool
        self.syncUseCellularPhotos = photosCell ?? false
        let videosCell = UserDefaults.standard.object(forKey: "sync.useCellularVideos") as? Bool
        self.syncUseCellularVideos = videosCell ?? false
        let preserve = UserDefaults.standard.object(forKey: "sync.preserveAlbum") as? Bool
        self.syncPreserveAlbum = preserve ?? true
        let photosOnly = UserDefaults.standard.object(forKey: "sync.photosOnly") as? Bool
        self.syncPhotosOnly = photosOnly ?? false
        let scopeStr = (UserDefaults.standard.string(forKey: "sync.scope") ?? SyncScope.all.rawValue)
        self.syncScope = SyncScope(rawValue: scopeStr) ?? .all
        let includeUnassigned = UserDefaults.standard.object(forKey: "sync.includeUnassigned") as? Bool
        self.syncIncludeUnassigned = includeUnassigned ?? false
        let unassignedLocked = UserDefaults.standard.object(forKey: "sync.unassignedLocked") as? Bool
        self.syncUnassignedLocked = unassignedLocked ?? false
        let autoStart = UserDefaults.standard.object(forKey: "sync.autoStartOnOpen") as? Bool
        self.autoStartSyncOnOpen = autoStart ?? true
        let autoWifi = UserDefaults.standard.object(forKey: "sync.autoStartWifiOnly") as? Bool
        self.autoStartWifiOnly = autoWifi ?? true
        // Background auto-retry threshold (minutes)
        let retryMins = UserDefaults.standard.object(forKey: "sync.autoRetryBgMinutes") as? Int
        self.autoRetryBgMinutes = retryMins ?? 5
        let syncEnabled = UserDefaults.standard.object(forKey: syncEnabledDefaultsKey) as? Bool
        self.syncEnabledAfterManualStart = syncEnabled ?? false

        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            Task { @MainActor in
                self.handleNetworkPathUpdate(path)
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
        Task {
            await refreshEffectiveServerURL(reason: "startup", forceProbe: true)
        }
    }

    func setServerURL(_ url: String) {
        updateSingleConfiguredBaseURL(url)
    }

    struct ServerConfig: Equatable {
        var scheme: String
        var host: String
        var port: Int
    }

    func currentServerConfig() -> ServerConfig {
        if hasManualServerOverride,
           let parsed = AuthManager.parseBaseURL(manualServerOverrideBaseURL.isEmpty ? serverURL : manualServerOverrideBaseURL) {
            return ServerConfig(
                scheme: parsed.scheme,
                host: parsed.host,
                port: parsed.port ?? AuthManager.defaultServerPort
            )
        }
        let preferredBaseURL = preferredConfiguredBaseURL()
        if let parsed = AuthManager.parseBaseURL(preferredBaseURL) {
            return ServerConfig(
                scheme: parsed.scheme,
                host: parsed.host,
                port: parsed.port ?? AuthManager.defaultServerPort
            )
        }
        // Fallback: attempt to reconstruct from defaults, else a safe default.
        let defaults = UserDefaults.standard
        let scheme = defaults.string(forKey: serverSchemeDefaultsKey) ?? AuthManager.defaultServerScheme
        let host = defaults.string(forKey: serverHostDefaultsKey) ?? ""
        let port = (defaults.object(forKey: serverPortDefaultsKey) as? Int) ?? AuthManager.defaultServerPort
        return ServerConfig(scheme: scheme, host: host, port: port)
    }

    @discardableResult
    func setServerConfig(scheme: String, host: String, port: Int?) -> Bool {
        let hostTrim = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedScheme = scheme.isEmpty ? AuthManager.defaultServerScheme : scheme
        let resolvedPort = port ?? AuthManager.defaultServerPort

        guard !hostTrim.isEmpty else {
            hasManualServerOverride = true
            manualServerOverrideBaseURL = ""
            applyResolvedBaseURL("", endpoint: .none)
            return true
        }

        guard let base = AuthManager.buildBaseURL(scheme: resolvedScheme, host: hostTrim, port: resolvedPort) else { return false }
        hasManualServerOverride = true
        manualServerOverrideBaseURL = base
        applyResolvedBaseURL(
            base,
            endpoint: AuthManager.endpointType(
                for: base,
                publicBaseURL: publicBaseURL,
                localBaseURL: localBaseURL
            )
        )
        return true
    }

    func commitManualServerOverride() {
        guard hasManualServerOverride else { return }
        let submittedBaseURL = AuthManager.normalizedBaseURL(
            manualServerOverrideBaseURL.isEmpty ? serverURL : manualServerOverrideBaseURL
        )
        hasManualServerOverride = false
        manualServerOverrideBaseURL = ""
        guard !submittedBaseURL.isEmpty else {
            applyImmediateResolvedBaseURL()
            return
        }
        updateSingleConfiguredBaseURL(submittedBaseURL)
    }

    private func commitSuccessfulManualServerOverrideIfNeeded() {
        guard hasManualServerOverride else { return }
        commitManualServerOverride()
    }

    func clearManualServerOverride() {
        guard hasManualServerOverride else { return }
        hasManualServerOverride = false
        manualServerOverrideBaseURL = ""
        applyImmediateResolvedBaseURL()
    }

    func currentEffectiveBaseURL() -> String {
        serverURL
    }

    func effectiveBaseURL() async -> String {
        await refreshEffectiveServerURL(reason: "on-demand")
    }

    func networkStatusSummary() -> String {
        switch activeEndpoint {
        case .local:
            return "Using Local Network"
        case .public:
            return "Using External Network"
        case .none:
            return "Not Configured"
        }
    }

    func setPublicBaseURL(_ rawURL: String) {
        updateSingleConfiguredBaseURL(rawURL)
    }

    func setLocalBaseURL(_ rawURL: String) {
        updateConfiguredBaseURLs(publicBaseURL: publicBaseURL, localBaseURL: rawURL)
    }

    func saveConfiguredBaseURLs(publicBaseURL rawPublicBaseURL: String, localBaseURL rawLocalBaseURL: String) {
        applyConfiguredBaseURLs(
            publicBaseURL: rawPublicBaseURL,
            localBaseURL: rawLocalBaseURL,
            refreshCurrentConnection: false,
            refreshReason: nil
        )
    }

    func updateConfiguredBaseURLs(publicBaseURL rawPublicBaseURL: String, localBaseURL rawLocalBaseURL: String) {
        applyConfiguredBaseURLs(
            publicBaseURL: rawPublicBaseURL,
            localBaseURL: rawLocalBaseURL,
            refreshCurrentConnection: true,
            refreshReason: "configured-base-url-change"
        )
    }

    func updateSingleConfiguredBaseURL(_ rawURL: String) {
        let normalized = AuthManager.normalizedBaseURL(rawURL)
        hasManualServerOverride = false
        manualServerOverrideBaseURL = ""
        if normalized.isEmpty {
            publicBaseURL = ""
            localBaseURL = ""
        } else if AuthManager.isLocalEndpointURL(normalized) {
            let repartitioned = AuthManager.repartitionConfiguredBaseURLs(
                publicBaseURL: publicBaseURL,
                localBaseURL: normalized
            )
            publicBaseURL = repartitioned.publicBaseURL
            localBaseURL = repartitioned.localBaseURL
        } else {
            let repartitioned = AuthManager.repartitionConfiguredBaseURLs(
                publicBaseURL: normalized,
                localBaseURL: localBaseURL
            )
            publicBaseURL = repartitioned.publicBaseURL
            localBaseURL = repartitioned.localBaseURL
        }

        applyImmediateResolvedBaseURL()
        persistNetworkProfile()

        if !normalized.isEmpty {
            addRecentServer(normalized)
            if let parsed = AuthManager.parseBaseURL(normalized) {
                UserDefaults.standard.set(parsed.scheme, forKey: serverSchemeDefaultsKey)
                UserDefaults.standard.set(parsed.host, forKey: serverHostDefaultsKey)
                UserDefaults.standard.set(parsed.port ?? AuthManager.defaultServerPort, forKey: serverPortDefaultsKey)
            }
        }

        Task {
            await refreshEffectiveServerURL(reason: "single-base-url-change", forceProbe: true)
        }
    }

    func setAutoSwitchEnabled(_ enabled: Bool) {
        autoSwitchEnabled = enabled
        persistNetworkProfile()
        Task {
            await refreshEffectiveServerURL(reason: "auto-switch-change", forceProbe: true)
        }
    }

    func setManualPreferredEndpoint(_ endpoint: ManualPreferredEndpoint) {
        manualPreferredEndpoint = endpoint
        persistNetworkProfile()
        Task {
            await refreshEffectiveServerURL(reason: "manual-endpoint-change", forceProbe: true)
        }
    }

    func useCurrentConnection() {
        switch activeEndpoint {
        case .local:
            autoSwitchEnabled = false
            manualPreferredEndpoint = .local
        case .public:
            autoSwitchEnabled = false
            manualPreferredEndpoint = .public
        case .none:
            break
        }
        persistNetworkProfile()
        Task {
            await refreshEffectiveServerURL(reason: "use-current-connection", forceProbe: true)
        }
    }

    func refreshNetworkRouting() async {
        _ = await refreshEffectiveServerURL(reason: "manual-refresh", forceProbe: true)
    }

    func testConfiguredEndpoint(_ endpoint: ManualPreferredEndpoint) async -> (success: Bool, message: String) {
        let baseURL = endpoint == .local ? localBaseURL : publicBaseURL
        guard !baseURL.isEmpty else {
            return (false, endpoint == .local ? "Local URL is not configured." : "Public URL is not configured.")
        }
        let result = await pingBaseURL(baseURL)
        if endpoint == .local {
            await MainActor.run {
                self.lastLocalProbeSucceeded = result.success
                self.lastLocalProbeMessage = result.message
                self.lastLocalProbeAt = Date()
                self.lastProbeNetworkGeneration = self.networkGeneration
            }
        }
        return result
    }

    func recentServers() -> [String] {
        UserDefaults.standard.stringArray(forKey: serverRecentsDefaultsKey) ?? []
    }

    func addRecentServer(_ baseURL: String) {
        guard let parsed = AuthManager.parseBaseURL(baseURL),
              let normalized = AuthManager.buildBaseURL(scheme: parsed.scheme, host: parsed.host, port: parsed.port)
        else { return }
        var recents = recentServers()
        recents.removeAll(where: { $0 == normalized })
        recents.insert(normalized, at: 0)
        if recents.count > 10 { recents = Array(recents.prefix(10)) }
        UserDefaults.standard.set(recents, forKey: serverRecentsDefaultsKey)
    }

    func clearRecentServers() {
        UserDefaults.standard.removeObject(forKey: serverRecentsDefaultsKey)
    }

    func authHeader() -> [String: String] {
        guard let token else { return [:] }
        return ["Authorization": "Bearer \(token)"]
    }

    // MARK: - Token Handling

    private func saveTokens(token: String, refresh: String?, expiresIn: Int64?) {
        self.token = token
        self.isAuthenticated = true
        keychain.set(Data(token.utf8), service: tokenService, account: tokenAccount)
        if let refresh = refresh {
            self.refreshToken = refresh
            keychain.set(Data(refresh.utf8), service: tokenService, account: refreshAccount)
        }
        if let expiresIn = expiresIn {
            let ts = Date().addingTimeInterval(TimeInterval(expiresIn))
            self.expiresAt = ts
            keychain.set(Data(String(ts.timeIntervalSince1970).utf8), service: tokenService, account: expiresAccount)
        }
    }

    private func saveUserId(_ id: String?) {
        self.userId = id
        if let id = id, !id.isEmpty {
            UserDefaults.standard.set(id, forKey: userIdDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: userIdDefaultsKey)
        }
    }

    private func saveUserEmail(_ email: String?) {
        let normalized = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.userEmail = normalized
        if let normalized, !normalized.isEmpty {
            UserDefaults.standard.set(normalized, forKey: userEmailDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: userEmailDefaultsKey)
        }
    }

    private func saveUserName(_ name: String?) {
        let normalized = Self.normalizeUserName(name)
        self.userName = normalized
        if let normalized, !normalized.isEmpty {
            UserDefaults.standard.set(normalized, forKey: userNameDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: userNameDefaultsKey)
        }
    }

    private struct SavedCredentials {
        let email: String
        let password: String
        let organizationId: Int?
    }

    private func saveLoginCredentials(email: String, password: String, organizationId: Int?) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty, !password.isEmpty else { return }
        saveLastLoginEmail(trimmedEmail)
        saveUserEmail(trimmedEmail)
        keychain.set(Data(trimmedEmail.utf8), service: credentialsService, account: credentialEmailAccount)
        keychain.set(Data(password.utf8), service: credentialsService, account: credentialPasswordAccount)
        if let organizationId {
            keychain.set(Data(String(organizationId).utf8), service: credentialsService, account: credentialOrgIdAccount)
        } else {
            keychain.remove(service: credentialsService, account: credentialOrgIdAccount)
        }
        let serverIdentity = credentialServerIdentity()
        if !serverIdentity.isEmpty {
            keychain.set(Data(serverIdentity.utf8), service: credentialsService, account: credentialServerAccount)
        }
    }

    private func loadSavedCredentials() -> SavedCredentials? {
        guard
            let emailData = keychain.get(service: credentialsService, account: credentialEmailAccount),
            let email = String(data: emailData, encoding: .utf8),
            !email.isEmpty,
            let passwordData = keychain.get(service: credentialsService, account: credentialPasswordAccount),
            let password = String(data: passwordData, encoding: .utf8),
            !password.isEmpty
        else {
            return nil
        }

        if let serverData = keychain.get(service: credentialsService, account: credentialServerAccount),
           let savedServer = String(data: serverData, encoding: .utf8),
           !savedServer.isEmpty {
            let normalizedSavedServer = savedServer.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
            guard currentCredentialServerKeys().contains(normalizedSavedServer) else { return nil }
        }

        var organizationId: Int? = nil
        if let orgData = keychain.get(service: credentialsService, account: credentialOrgIdAccount),
           let orgStr = String(data: orgData, encoding: .utf8),
           let org = Int(orgStr) {
            organizationId = org
        }
        return SavedCredentials(email: email, password: password, organizationId: organizationId)
    }

    private func clearLoginCredentials() {
        keychain.remove(service: credentialsService, account: credentialEmailAccount)
        keychain.remove(service: credentialsService, account: credentialPasswordAccount)
        keychain.remove(service: credentialsService, account: credentialOrgIdAccount)
        keychain.remove(service: credentialsService, account: credentialServerAccount)
    }

    private func saveLastLoginEmail(_ email: String?) {
        let normalized = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let normalized, !normalized.isEmpty {
            UserDefaults.standard.set(normalized, forKey: lastLoginEmailDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: lastLoginEmailDefaultsKey)
        }
    }

    func lastUsedLoginEmail() -> String? {
        let normalized = UserDefaults.standard.string(forKey: lastLoginEmailDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let normalized, !normalized.isEmpty else { return nil }
        return normalized
    }

    private func canAttemptAutoLogin(now: Date = Date()) -> Bool {
        if let lastAutoLoginAttemptAt, now.timeIntervalSince(lastAutoLoginAttemptAt) < autoLoginCooldownSeconds {
            return false
        }
        lastAutoLoginAttemptAt = now
        return true
    }

    private func tryAutoLoginWithSavedCredentials() async -> Bool {
        guard let creds = loadSavedCredentials(), canAttemptAutoLogin() else {
            return false
        }
        do {
            if let orgId = creds.organizationId {
                do {
                    _ = try await loginFinish(email: creds.email, organizationId: orgId, password: creds.password)
                    return true
                } catch {
                    // Fall through to alternate login paths if org mapping changed.
                }
            }

            do {
                _ = try await loginSingleStep(email: creds.email, password: creds.password)
                return true
            } catch {
                let accounts = try await loginStart(email: creds.email)
                if let orgId = creds.organizationId,
                   let matched = accounts.first(where: { $0.id == orgId }) {
                    _ = try await loginFinish(email: creds.email, organizationId: matched.id, password: creds.password)
                    return true
                }
                guard accounts.count == 1 else { return false }
                _ = try await loginFinish(email: creds.email, organizationId: accounts[0].id, password: creds.password)
                return true
            }
        } catch {
            return false
        }
    }

    // Expose a safe public method for helpers to apply rotated tokens
    func applyRefreshedTokens(token: String, refresh: String?, expiresIn: Int64?) {
        saveTokens(token: token, refresh: refresh, expiresIn: expiresIn)
    }

    func refreshIfNeeded() async {
        _ = await refreshAccessToken(force: false)
    }

    func forceRefresh() async -> Bool {
        await refreshAccessToken(force: true)
    }

    private struct AuthSnapshot {
        let serverURL: String
        let accessToken: String?
        let refreshToken: String?
        let expiresAt: Date?
    }

    private struct RefreshUser: Decodable { let user_id: String? }
    private struct RefreshResponse: Decodable {
        let token: String
        let refresh_token: String?
        let expires_in: Int64?
        let user: RefreshUser?
    }
    private struct LoginUser: Decodable {
        let user_id: String?
        let name: String?
        let display_name: String?
        let user_name: String?
        let email: String?
    }
    private struct LoginResponse: Decodable {
        let token: String
        let refresh_token: String?
        let expires_in: Int64?
        let user: LoginUser?
        let password_change_required: Bool?
    }

    private func refreshAccessToken(force: Bool) async -> Bool {
        await refreshCoordinator.run { [weak self] in
            guard let self else { return false }
            return await self.performRefresh(force: force)
        }
    }

    private func performRefresh(force: Bool) async -> Bool {
        let resolvedBaseURL = await refreshEffectiveServerURL(reason: "auth-refresh", forceProbe: force)
        let snapshot = await MainActor.run {
            AuthSnapshot(
                serverURL: resolvedBaseURL.isEmpty ? self.serverURL : resolvedBaseURL,
                accessToken: self.token,
                refreshToken: self.refreshToken,
                expiresAt: self.expiresAt
            )
        }

        if !force {
            guard let exp = snapshot.expiresAt else { return true }
            if Date().addingTimeInterval(60) < exp { return true }
        }

        guard snapshot.accessToken != nil || snapshot.refreshToken != nil else {
            if force {
                return await tryAutoLoginWithSavedCredentials()
            }
            return false
        }

        let base = snapshot.serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/api/auth/refresh") else { return false }

        do {
            let refreshed: RefreshResponse?
            if let rt = snapshot.refreshToken, !rt.isEmpty {
                let firstTry = try await requestRefresh(
                    url: url,
                    accessToken: snapshot.accessToken,
                    refreshToken: rt
                )
                if let firstTry {
                    refreshed = firstTry
                } else {
                    refreshed = try await requestRefresh(
                        url: url,
                        accessToken: snapshot.accessToken,
                        refreshToken: nil
                    )
                }
            } else {
                refreshed = try await requestRefresh(
                    url: url,
                    accessToken: snapshot.accessToken,
                    refreshToken: nil
                )
            }
            guard let decoded = refreshed else {
                if force {
                    return await tryAutoLoginWithSavedCredentials()
                }
                return false
            }
            await MainActor.run {
                self.saveTokens(token: decoded.token, refresh: decoded.refresh_token, expiresIn: decoded.expires_in)
                if let uid = decoded.user?.user_id { self.saveUserId(uid) }
            }
            return true
        } catch {
            if force {
                return await tryAutoLoginWithSavedCredentials()
            }
            return false
        }
    }

    private static func normalizeUserName(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func resolvedUserName(from user: LoginUser?) -> String? {
        normalizeUserName(user?.name)
            ?? normalizeUserName(user?.display_name)
            ?? normalizeUserName(user?.user_name)
    }

    private func urlForPath(_ path: String, forceProbe: Bool = false) async throws -> URL {
        let baseURL = await refreshEffectiveServerURL(reason: path, forceProbe: forceProbe)
        guard !baseURL.isEmpty, let url = URL(string: baseURL + path) else {
            throw NSError(domain: "Auth", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid server URL"])
        }
        return url
    }

    private func performData(for request: URLRequest, allowPublicFallback: Bool = true) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch {
            guard allowPublicFallback, let fallbackRequest = fallbackRequest(for: request, error: error) else {
                throw error
            }
            return try await URLSession.shared.data(for: fallbackRequest)
        }
    }

    func dataForResolvedRequest(_ request: URLRequest, allowPublicFallback: Bool = true) async throws -> (Data, URLResponse) {
        try await performData(for: request, allowPublicFallback: allowPublicFallback)
    }

    private func fallbackRequest(for request: URLRequest, error: Error) -> URLRequest? {
        guard shouldFallbackToPublic(after: error),
              !publicBaseURL.isEmpty,
              !localBaseURL.isEmpty,
              let requestURL = request.url
        else {
            return nil
        }

        let localPrefix = localBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let publicPrefix = publicBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let requestAbsoluteString = requestURL.absoluteString
        guard !localPrefix.isEmpty,
              !publicPrefix.isEmpty,
              requestAbsoluteString.hasPrefix(localPrefix)
        else {
            return nil
        }

        let suffix = String(requestAbsoluteString.dropFirst(localPrefix.count))
        guard let fallbackURL = URL(string: publicPrefix + suffix) else { return nil }

        lastLocalProbeSucceeded = false
        lastLocalProbeMessage = (error as NSError).localizedDescription
        lastLocalProbeAt = Date()
        lastProbeNetworkGeneration = networkGeneration
        applyResolvedBaseURL(publicPrefix, endpoint: .public)

        var fallbackRequest = request
        fallbackRequest.url = fallbackURL
        return fallbackRequest
    }

    private func shouldFallbackToPublic(after error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    private func requestRefresh(
        url: URL,
        accessToken: String?,
        refreshToken: String?
    ) async throws -> RefreshResponse? {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let at = accessToken, !at.isEmpty {
            req.setValue("Bearer \(at)", forHTTPHeaderField: "Authorization")
        }
        if let rt = refreshToken, !rt.isEmpty {
            req.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": rt], options: [])
        } else {
            req.httpBody = try JSONSerialization.data(withJSONObject: [String: String](), options: [])
        }

        let (data, resp) = try await performData(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return nil
        }
        return try JSONDecoder().decode(RefreshResponse.self, from: data)
    }

    func login(email: String, password: String) async throws {
        // Two-step: start -> list accounts, then finish with selected org
        do {
            let accounts = try await loginStart(email: email)
            guard accounts.count > 0 else {
                throw NSError(domain: "Auth", code: 6, userInfo: [NSLocalizedDescriptionKey: "No account for this email"])
            }
            if accounts.count == 1 {
                _ = try await loginFinish(email: email, organizationId: accounts[0].id, password: password)
            } else {
                // Defer completion to caller to select org; surface as error for now
                throw NSError(domain: "Auth", code: 409, userInfo: [NSLocalizedDescriptionKey: "Multiple accounts. Please select organization."])
            }
        } catch {
            if shouldFallbackToSingleStepLogin(error) {
                _ = try await loginSingleStep(email: email, password: password)
            } else {
                throw error
            }
        }
    }

    struct OrgAccount { let id: Int; let name: String }

    func loginStart(email: String) async throws -> [OrgAccount] {
        let url = try await urlForPath("/api/auth/login/start", forceProbe: true)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = ["email": email]
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        let (data, resp) = try await performData(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw NSError(domain: "Auth", code: 2, userInfo: [NSLocalizedDescriptionKey: "No response"])
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "Login start failed"
            throw NSError(domain: "Auth", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        // { accounts: [{ organization_id, organization_name, display_name? }] }
        var out: [OrgAccount] = []
        if let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let arr = dict["accounts"] as? [[String: Any]] {
            for a in arr {
                if let id = a["organization_id"] as? Int {
                    let name = (a["display_name"] as? String) ?? (a["organization_name"] as? String) ?? ""
                    out.append(OrgAccount(id: id, name: name))
                }
            }
        }
        addRecentServer(serverURL)
        return out
    }

    // Returns true if password change is required
    func loginFinish(email: String, organizationId: Int, password: String) async throws -> Bool {
        let url = try await urlForPath("/api/auth/login/finish", forceProbe: true)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["email": email, "organization_id": organizationId, "password": password]
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        let (data, resp) = try await performData(for: req)
        guard let http = resp as? HTTPURLResponse else { throw NSError(domain: "Auth", code: 2, userInfo: [NSLocalizedDescriptionKey: "No response"]) }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "Login failed"
            throw NSError(domain: "Auth", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        let decoded = try JSONDecoder().decode(LoginResponse.self, from: data)
        guard !decoded.token.isEmpty else {
            throw NSError(domain: "Auth", code: 3, userInfo: [NSLocalizedDescriptionKey: "Token missing"])
        }
        let must = decoded.password_change_required ?? false
        await MainActor.run {
            self.commitSuccessfulManualServerOverrideIfNeeded()
            self.saveTokens(token: decoded.token, refresh: decoded.refresh_token, expiresIn: decoded.expires_in)
            self.saveUserId(decoded.user?.user_id)
            self.saveUserName(Self.resolvedUserName(from: decoded.user))
            self.saveUserEmail(decoded.user?.email ?? email)
            self.saveLoginCredentials(email: email, password: password, organizationId: organizationId)
        }
        addRecentServer(serverURL)
        // After login, try to pull the E2EE envelope so offline unlock works
        Task { await E2EEManager.shared.syncEnvelopeFromServer() }
        return must
    }

    // Returns true if password change is required
    func loginSingleStep(email: String, password: String) async throws -> Bool {
        let url = try await urlForPath("/api/auth/login", forceProbe: true)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = ["email": email, "password": password]
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        let (data, resp) = try await performData(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw NSError(domain: "Auth", code: 2, userInfo: [NSLocalizedDescriptionKey: "No response"])
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "Login failed"
            throw NSError(domain: "Auth", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        let decoded = try JSONDecoder().decode(LoginResponse.self, from: data)
        guard !decoded.token.isEmpty else {
            throw NSError(domain: "Auth", code: 3, userInfo: [NSLocalizedDescriptionKey: "Token missing"])
        }
        let must = decoded.password_change_required ?? false
        await MainActor.run {
            self.commitSuccessfulManualServerOverrideIfNeeded()
            self.saveTokens(token: decoded.token, refresh: decoded.refresh_token, expiresIn: decoded.expires_in)
            self.saveUserId(decoded.user?.user_id)
            self.saveUserName(Self.resolvedUserName(from: decoded.user))
            self.saveUserEmail(decoded.user?.email ?? email)
            self.saveLoginCredentials(email: email, password: password, organizationId: nil)
        }
        addRecentServer(serverURL)
        // After login, try to pull the E2EE envelope so offline unlock works
        Task { await E2EEManager.shared.syncEnvelopeFromServer() }
        return must
    }

    func shouldFallbackToSingleStepLogin(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == "Auth" && [404, 405, 501].contains(ns.code) {
            return true
        }
        let msg = ns.localizedDescription.lowercased()
        if ns.domain == "Auth" && (msg.contains("not found") || msg.contains("no route")) {
            return true
        }
        return false
    }

    func changePassword(newPassword: String, currentPassword: String? = nil) async throws {
        let url = try await urlForPath("/api/auth/password/change", forceProbe: true)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        var body: [String: Any] = ["new_password": newPassword]
        if let currentPassword, !currentPassword.isEmpty { body["current_password"] = currentPassword }
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        let (data, resp) = try await performData(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw NSError(domain: "Auth", code: 4, userInfo: [NSLocalizedDescriptionKey: "No response"])
        }
        guard (200..<300).contains(http.statusCode) else {
            var message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                if let m = json["message"] as? String, !m.isEmpty {
                    message = m
                } else if let e = json["error"] as? String, !e.isEmpty {
                    message = e
                }
            }
            if message.isEmpty { message = "Password change failed" }
            throw NSError(domain: "Auth", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
        }
        // Upon success, tokens are revoked server-side; clear them locally
        await MainActor.run { self.logout() }
    }

    func register(name: String, email: String, password: String) async throws {
        let url = try await urlForPath("/api/auth/register", forceProbe: true)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "name": name,
            "email": email,
            "password": password
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, resp) = try await performData(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw NSError(domain: "Auth", code: 2, userInfo: [NSLocalizedDescriptionKey: "No response"])
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "Register failed"
            throw NSError(domain: "Auth", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        let dict = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        guard let token = dict?["token"] as? String, !token.isEmpty else {
            throw NSError(domain: "Auth", code: 3, userInfo: [NSLocalizedDescriptionKey: "Token missing"])
        }
        let refresh = dict?["refresh_token"] as? String
        let expiresIn = (dict?["expires_in"] as? NSNumber)?.int64Value
        let uid = (dict?["user"] as? [String: Any])?["user_id"] as? String
        await MainActor.run {
            self.commitSuccessfulManualServerOverrideIfNeeded()
            self.saveTokens(token: token, refresh: refresh, expiresIn: expiresIn)
            self.saveUserId(uid)
            self.saveUserName(name)
            self.saveUserEmail(email)
            self.saveLoginCredentials(email: email, password: password, organizationId: nil)
        }
        addRecentServer(serverURL)
    }

    func logout() {
        token = nil
        refreshToken = nil
        expiresAt = nil
        isAuthenticated = false
        keychain.remove(service: tokenService, account: tokenAccount)
        keychain.remove(service: tokenService, account: refreshAccount)
        keychain.remove(service: tokenService, account: expiresAccount)
        clearLoginCredentials()
        saveUserId(nil)
        saveUserName(nil)
        saveUserEmail(nil)
        clearSyncEnabledAfterManualStart()
    }

    private func handleNetworkPathUpdate(_ path: NWPath) {
        if path.status != .satisfied {
            networkTransport = .offline
            currentUsesWiFiOrEthernet = false
            currentHasPrivateOrLoopbackLANAddress = false
        } else if path.usesInterfaceType(.wifi) {
            networkTransport = .wifi
            currentUsesWiFiOrEthernet = true
            currentHasPrivateOrLoopbackLANAddress = currentLANInterfaceHasPrivateOrLoopbackAddress(for: path)
        } else if path.usesInterfaceType(.wiredEthernet) {
            networkTransport = .ethernet
            currentUsesWiFiOrEthernet = true
            currentHasPrivateOrLoopbackLANAddress = currentLANInterfaceHasPrivateOrLoopbackAddress(for: path)
        } else if path.usesInterfaceType(.cellular) {
            networkTransport = .cellular
            currentUsesWiFiOrEthernet = false
            currentHasPrivateOrLoopbackLANAddress = false
        } else {
            networkTransport = .other
            currentUsesWiFiOrEthernet = false
            currentHasPrivateOrLoopbackLANAddress = false
        }
        networkGeneration += 1
        Task {
            await refreshEffectiveServerURL(reason: "network-path-update", forceProbe: true)
        }
    }

    private func currentLANInterfaceHasPrivateOrLoopbackAddress(for path: NWPath) -> Bool {
        let interfaceNames = Set(
            path.availableInterfaces
                .filter { $0.type == .wifi || $0.type == .wiredEthernet }
                .map(\.name)
        )
        return AuthManager.interfaceHasPrivateOrLoopbackAddress(interfaceNames: interfaceNames)
    }

    private func persistNetworkProfile() {
        let defaults = UserDefaults.standard
        defaults.set(publicBaseURL, forKey: publicServerURLDefaultsKey)
        defaults.set(localBaseURL, forKey: localServerURLDefaultsKey)
        defaults.set(autoSwitchEnabled, forKey: autoSwitchDefaultsKey)
        defaults.set(manualPreferredEndpoint.rawValue, forKey: manualPreferredEndpointDefaultsKey)
    }

    private func applyConfiguredBaseURLs(
        publicBaseURL rawPublicBaseURL: String,
        localBaseURL rawLocalBaseURL: String,
        refreshCurrentConnection: Bool,
        refreshReason: String?
    ) {
        let repartitioned = AuthManager.repartitionConfiguredBaseURLs(
            publicBaseURL: rawPublicBaseURL,
            localBaseURL: rawLocalBaseURL
        )
        hasManualServerOverride = false
        manualServerOverrideBaseURL = ""
        publicBaseURL = repartitioned.publicBaseURL
        localBaseURL = repartitioned.localBaseURL
        if refreshCurrentConnection {
            applyImmediateResolvedBaseURL()
        }
        persistNetworkProfile()

        let preferredConfiguredBaseURL = AuthManager.configuredPreferredBaseURL(
            publicBaseURL: repartitioned.publicBaseURL,
            localBaseURL: repartitioned.localBaseURL
        )
        if !preferredConfiguredBaseURL.isEmpty {
            addRecentServer(preferredConfiguredBaseURL)
            if let parsed = AuthManager.parseBaseURL(preferredConfiguredBaseURL) {
                UserDefaults.standard.set(parsed.scheme, forKey: serverSchemeDefaultsKey)
                UserDefaults.standard.set(parsed.host, forKey: serverHostDefaultsKey)
                UserDefaults.standard.set(parsed.port ?? AuthManager.defaultServerPort, forKey: serverPortDefaultsKey)
            }
        }

        guard refreshCurrentConnection, let refreshReason else { return }
        Task {
            await refreshEffectiveServerURL(reason: refreshReason, forceProbe: true)
        }
    }

    private func applyResolvedBaseURL(_ baseURL: String, endpoint: ActiveEndpoint) {
        let normalized = AuthManager.normalizedBaseURL(baseURL)
        serverURL = normalized
        activeEndpoint = endpoint
        if !hasManualServerOverride {
            UserDefaults.standard.set(normalized, forKey: serverURLDefaultsKey)
        }
    }

    private func applyImmediateResolvedBaseURL() {
        let immediate = AuthManager.initialResolvedBaseURL(
            publicBaseURL: publicBaseURL,
            localBaseURL: localBaseURL,
            autoSwitchEnabled: autoSwitchEnabled,
            manualPreferredEndpoint: manualPreferredEndpoint
        )
        applyResolvedBaseURL(
            immediate,
            endpoint: AuthManager.endpointType(
                for: immediate,
                publicBaseURL: publicBaseURL,
                localBaseURL: localBaseURL
            )
        )
    }

    private func preferredConfiguredBaseURL() -> String {
        if !publicBaseURL.isEmpty {
            return publicBaseURL
        }
        if !localBaseURL.isEmpty {
            return localBaseURL
        }
        return serverURL
    }

    private func credentialServerIdentity() -> String {
        if !publicBaseURL.isEmpty {
            return publicBaseURL.lowercased()
        }
        if !localBaseURL.isEmpty {
            return localBaseURL.lowercased()
        }
        return serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
    }

    private func currentCredentialServerKeys() -> Set<String> {
        var keys: Set<String> = []
        for candidate in [publicBaseURL, localBaseURL, serverURL, credentialServerIdentity()] {
            let normalized = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
            if !normalized.isEmpty {
                keys.insert(normalized)
            }
        }
        return keys
    }

    @discardableResult
    func refreshEffectiveServerURL(reason: String, forceProbe: Bool = false) async -> String {
        let manualOverrideBaseURL = await MainActor.run { () -> String? in
            guard self.hasManualServerOverride else { return nil }
            return self.manualServerOverrideBaseURL
        }
        if let manualOverrideBaseURL {
            return manualOverrideBaseURL
        }

        let configuredPublic = publicBaseURL
        let configuredLocal = localBaseURL

        if configuredPublic.isEmpty && configuredLocal.isEmpty {
            await MainActor.run {
                self.applyResolvedBaseURL("", endpoint: .none)
            }
            return ""
        }

        if !autoSwitchEnabled {
            let resolved = AuthManager.manualResolvedBaseURL(
                publicBaseURL: configuredPublic,
                localBaseURL: configuredLocal,
                manualPreferredEndpoint: manualPreferredEndpoint
            )
            let endpoint = AuthManager.endpointType(
                for: resolved,
                publicBaseURL: configuredPublic,
                localBaseURL: configuredLocal
            )
            await MainActor.run {
                self.applyResolvedBaseURL(resolved, endpoint: endpoint)
            }
            return resolved
        }

        if configuredLocal.isEmpty {
            let resolved = configuredPublic
            await MainActor.run {
                self.applyResolvedBaseURL(resolved, endpoint: .public)
            }
            return resolved
        }

        if configuredPublic.isEmpty {
            let resolved = configuredLocal
            await MainActor.run {
                self.applyResolvedBaseURL(resolved, endpoint: .local)
            }
            return resolved
        }

        if !currentUsesWiFiOrEthernet || !currentHasPrivateOrLoopbackLANAddress {
            await MainActor.run {
                self.applyResolvedBaseURL(configuredPublic, endpoint: .public)
            }
            return configuredPublic
        }

        if !forceProbe,
           let probeAt = lastLocalProbeAt,
           lastProbeNetworkGeneration == networkGeneration {
            let age = Date().timeIntervalSince(probeAt)
            if lastLocalProbeSucceeded == true, age < routeDecisionTTL {
                await MainActor.run {
                    self.applyResolvedBaseURL(configuredLocal, endpoint: .local)
                }
                return configuredLocal
            }
            if lastLocalProbeSucceeded == false, age < localProbeFailureBackoff {
                await MainActor.run {
                    self.applyResolvedBaseURL(configuredPublic, endpoint: .public)
                }
                return configuredPublic
            }
        }

        let probe = await pingBaseURL(configuredLocal)
        await MainActor.run {
            self.lastLocalProbeSucceeded = probe.success
            self.lastLocalProbeMessage = "\(reason): \(probe.message)"
            self.lastLocalProbeAt = Date()
            self.lastProbeNetworkGeneration = self.networkGeneration
            self.applyResolvedBaseURL(
                probe.success ? configuredLocal : configuredPublic,
                endpoint: probe.success ? .local : .public
            )
        }
        return probe.success ? configuredLocal : configuredPublic
    }

    private func pingBaseURL(_ baseURL: String) async -> (success: Bool, message: String) {
        let normalized = AuthManager.normalizedBaseURL(baseURL)
        guard !normalized.isEmpty, let url = URL(string: normalized + "/ping") else {
            return (false, "Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 1.5

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return (false, "No response")
            }
            let body = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if (200..<300).contains(http.statusCode) {
                return (true, body.isEmpty ? "Success (\(http.statusCode))" : "Success (\(http.statusCode)): \(body)")
            }
            return (false, body.isEmpty ? "HTTP \(http.statusCode)" : "HTTP \(http.statusCode): \(body)")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    func setSyncUseCellularPhotos(_ enabled: Bool) {
        syncUseCellularPhotos = enabled
        UserDefaults.standard.set(enabled, forKey: "sync.useCellularPhotos")
    }

    func setSyncUseCellularVideos(_ enabled: Bool) {
        syncUseCellularVideos = enabled
        UserDefaults.standard.set(enabled, forKey: "sync.useCellularVideos")
    }

    func setSyncPreserveAlbum(_ enabled: Bool) {
        syncPreserveAlbum = enabled
        UserDefaults.standard.set(enabled, forKey: "sync.preserveAlbum")
    }

    func setSyncPhotosOnly(_ enabled: Bool) {
        syncPhotosOnly = enabled
        UserDefaults.standard.set(enabled, forKey: "sync.photosOnly")
    }

    func setSyncScope(_ scope: SyncScope) {
        syncScope = scope
        UserDefaults.standard.set(scope.rawValue, forKey: "sync.scope")
    }

    func setSyncIncludeUnassigned(_ enabled: Bool) {
        syncIncludeUnassigned = enabled
        UserDefaults.standard.set(enabled, forKey: "sync.includeUnassigned")
    }

    func setSyncUnassignedLocked(_ locked: Bool) {
        syncUnassignedLocked = locked
        UserDefaults.standard.set(locked, forKey: "sync.unassignedLocked")
    }

    func setAutoStartSyncOnOpen(_ enabled: Bool) {
        autoStartSyncOnOpen = enabled
        UserDefaults.standard.set(enabled, forKey: "sync.autoStartOnOpen")
    }

    func setAutoStartWifiOnly(_ enabled: Bool) {
        autoStartWifiOnly = enabled
        UserDefaults.standard.set(enabled, forKey: "sync.autoStartWifiOnly")
    }

    func setAutoRetryBgMinutes(_ minutes: Int) {
        let clamped = max(1, min(240, minutes))
        autoRetryBgMinutes = clamped
        UserDefaults.standard.set(clamped, forKey: "sync.autoRetryBgMinutes")
    }

    func enableSyncAfterManualStart() {
        guard !syncEnabledAfterManualStart else { return }
        syncEnabledAfterManualStart = true
        UserDefaults.standard.set(true, forKey: syncEnabledDefaultsKey)
    }

    func clearSyncEnabledAfterManualStart() {
        syncEnabledAfterManualStart = false
        UserDefaults.standard.removeObject(forKey: syncEnabledDefaultsKey)
    }
}

extension AuthManager {
    struct ConfiguredBaseURLs {
        let publicBaseURL: String
        let localBaseURL: String
    }

    struct ParsedBaseURL: Equatable {
        let scheme: String
        let host: String
        let port: Int?
    }

    static func normalizeHost(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    static func parseBaseURL(_ raw: String) -> ParsedBaseURL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard let comps = URLComponents(string: withScheme) else { return nil }
        let scheme = (comps.scheme ?? "http").lowercased()
        guard let host = comps.host, !host.isEmpty, isValidParsedHost(host) else { return nil }
        let port = comps.port
        return ParsedBaseURL(scheme: scheme, host: host, port: port)
    }

    static func buildBaseURL(scheme: String, host: String, port: Int?) -> String? {
        let schemeNorm = scheme.lowercased().replacingOccurrences(of: "://", with: "")
        let hostNorm = normalizeHost(host)
        guard !schemeNorm.isEmpty, !hostNorm.isEmpty, isValidParsedHost(hostNorm) else { return nil }

        var comps = URLComponents()
        comps.scheme = schemeNorm
        comps.host = hostNorm
        comps.port = port
        guard let url = comps.url else { return nil }
        var s = url.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    static func normalizedBaseURL(_ raw: String?) -> String {
        guard let raw, let parsed = parseBaseURL(raw) else { return "" }
        return buildBaseURL(scheme: parsed.scheme, host: parsed.host, port: parsed.port) ?? ""
    }

    static func migratedLegacyServerURL(defaults: UserDefaults) -> String {
        let persistedScheme = defaults.string(forKey: "server.scheme")
        let persistedHost = defaults.string(forKey: "server.host")
        let persistedPort = defaults.object(forKey: "server.port") as? Int
        if let persistedScheme, let persistedHost,
           let base = buildBaseURL(scheme: persistedScheme, host: persistedHost, port: persistedPort) {
            defaults.set(base, forKey: "server.baseURL")
            defaults.set(persistedScheme.lowercased(), forKey: "server.scheme")
            defaults.set(normalizeHost(persistedHost), forKey: "server.host")
            defaults.set(persistedPort ?? AuthManager.defaultServerPort, forKey: "server.port")
            return base
        }
        if let persistedURL = defaults.string(forKey: "server.baseURL") {
            return normalizedBaseURL(persistedURL)
        }
        return ""
    }

    static func repartitionConfiguredBaseURLs(publicBaseURL rawPublicBaseURL: String, localBaseURL rawLocalBaseURL: String) -> ConfiguredBaseURLs {
        let normalizedPublicBaseURL = normalizedBaseURL(rawPublicBaseURL)
        let normalizedLocalBaseURL = normalizedBaseURL(rawLocalBaseURL)

        var resolvedPublicBaseURL = !normalizedPublicBaseURL.isEmpty && !isLocalEndpointURL(normalizedPublicBaseURL)
            ? normalizedPublicBaseURL
            : ""
        var resolvedLocalBaseURL = !normalizedLocalBaseURL.isEmpty && isLocalEndpointURL(normalizedLocalBaseURL)
            ? normalizedLocalBaseURL
            : ""

        if resolvedPublicBaseURL.isEmpty,
           !normalizedLocalBaseURL.isEmpty,
           !isLocalEndpointURL(normalizedLocalBaseURL) {
            resolvedPublicBaseURL = normalizedLocalBaseURL
        }

        if resolvedLocalBaseURL.isEmpty,
           !normalizedPublicBaseURL.isEmpty,
           isLocalEndpointURL(normalizedPublicBaseURL) {
            resolvedLocalBaseURL = normalizedPublicBaseURL
        }

        return ConfiguredBaseURLs(
            publicBaseURL: resolvedPublicBaseURL,
            localBaseURL: resolvedLocalBaseURL
        )
    }

    static func isLocalEndpointURL(_ rawURL: String) -> Bool {
        guard let parsed = parseBaseURL(rawURL) else { return false }
        return isLocalHost(parsed.host)
    }

    static func isLocalHost(_ rawHost: String) -> Bool {
        let host = normalizeHost(rawHost).lowercased()
        guard !host.isEmpty else { return false }

        if host == "localhost" || host == "::1" || host == "0:0:0:0:0:0:0:1" || host.hasSuffix(".local") {
            return true
        }

        if let ipv4 = ipv4Octets(for: host) {
            let first = ipv4[0]
            let second = ipv4[1]
            if first == 10 || first == 127 || first == 192 && second == 168 {
                return true
            }
            if first == 172 && (16...31).contains(second) {
                return true
            }
            if first == 169 && second == 254 {
                return true
            }
        }

        if host.contains(":") {
            if host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd") {
                return true
            }
        }

        return false
    }

    private static func ipv4Octets(for host: String) -> [Int]? {
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else { return nil }

        var octets: [Int] = []
        octets.reserveCapacity(4)
        for component in components {
            guard let octet = Int(component), (0...255).contains(octet) else { return nil }
            octets.append(octet)
        }
        return octets
    }

    private static func isValidParsedHost(_ rawHost: String) -> Bool {
        let host = normalizeHost(rawHost)
        guard !host.isEmpty else { return false }

        if host.contains(":") {
            return true
        }

        if host.allSatisfy({ $0.isNumber || $0 == "." }) {
            return ipv4Octets(for: host) != nil
        }

        return isValidDNSHost(host)
    }

    private static func isValidDNSHost(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return false }

        for label in labels {
            guard !label.isEmpty, label.count <= 63 else { return false }
            guard let first = label.first, let last = label.last else { return false }
            guard first.isLetter || first.isNumber else { return false }
            guard last.isLetter || last.isNumber else { return false }
            for character in label where !(character.isLetter || character.isNumber || character == "-") {
                return false
            }
        }

        return true
    }

    private static func interfaceHasPrivateOrLoopbackAddress(interfaceNames: Set<String>) -> Bool {
        var addressList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addressList) == 0, let firstAddress = addressList else { return false }
        defer { freeifaddrs(addressList) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let current = pointer {
            let interface = current.pointee
            let interfaceName = String(cString: interface.ifa_name)
            let shouldInspect = interfaceNames.isEmpty
                ? isLikelyLANInterfaceName(interfaceName)
                : interfaceNames.contains(interfaceName)
            guard shouldInspect, let socketAddress = interface.ifa_addr else {
                pointer = interface.ifa_next
                continue
            }

            let family = Int32(socketAddress.pointee.sa_family)
            if family == AF_INET || family == AF_INET6,
               let address = numericHost(from: socketAddress),
               isLocalHost(address) {
                return true
            }

            pointer = interface.ifa_next
        }

        return false
    }

    private static func isLikelyLANInterfaceName(_ interfaceName: String) -> Bool {
        interfaceName.hasPrefix("en") || interfaceName.hasPrefix("bridge")
    }

    private static func numericHost(from socketAddress: UnsafePointer<sockaddr>) -> String? {
        let family = Int32(socketAddress.pointee.sa_family)
        let length: socklen_t
        switch family {
        case AF_INET:
            length = socklen_t(MemoryLayout<sockaddr_in>.size)
        case AF_INET6:
            length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        default:
            return nil
        }

        var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(
            socketAddress,
            length,
            &hostBuffer,
            socklen_t(hostBuffer.count),
            nil,
            0,
            NI_NUMERICHOST
        )
        guard result == 0 else { return nil }
        return String(cString: hostBuffer)
    }

    static func initialResolvedBaseURL(
        publicBaseURL: String,
        localBaseURL: String,
        autoSwitchEnabled: Bool,
        manualPreferredEndpoint: ManualPreferredEndpoint
    ) -> String {
        if autoSwitchEnabled {
            if !publicBaseURL.isEmpty { return publicBaseURL }
            return localBaseURL
        }
        return manualResolvedBaseURL(
            publicBaseURL: publicBaseURL,
            localBaseURL: localBaseURL,
            manualPreferredEndpoint: manualPreferredEndpoint
        )
    }

    static func configuredPreferredBaseURL(publicBaseURL: String, localBaseURL: String) -> String {
        if !publicBaseURL.isEmpty {
            return publicBaseURL
        }
        return localBaseURL
    }

    static func manualResolvedBaseURL(
        publicBaseURL: String,
        localBaseURL: String,
        manualPreferredEndpoint: ManualPreferredEndpoint
    ) -> String {
        switch manualPreferredEndpoint {
        case .public:
            return !publicBaseURL.isEmpty ? publicBaseURL : localBaseURL
        case .local:
            return !localBaseURL.isEmpty ? localBaseURL : publicBaseURL
        }
    }

    static func endpointType(
        for baseURL: String,
        publicBaseURL: String,
        localBaseURL: String
    ) -> ActiveEndpoint {
        let normalized = normalizedBaseURL(baseURL)
        if normalized.isEmpty {
            return .none
        }
        if normalized == normalizedBaseURL(localBaseURL) {
            return .local
        }
        if normalized == normalizedBaseURL(publicBaseURL) {
            return .public
        }
        return .none
    }
}
