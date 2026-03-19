import Foundation
import Combine

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

    @Published var serverURL: String
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
    private let serverURLDefaultsKey = "server.baseURL"
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

    private init() {
        // Default server URL; prefer structured persisted value if present, else fall back to legacy baseURL.
        let defaults = UserDefaults.standard
        let persistedScheme = defaults.string(forKey: serverSchemeDefaultsKey)
        let persistedHost = defaults.string(forKey: serverHostDefaultsKey)
        let persistedPort = defaults.object(forKey: serverPortDefaultsKey) as? Int
        if let persistedScheme, let persistedHost,
           let base = AuthManager.buildBaseURL(scheme: persistedScheme, host: persistedHost, port: persistedPort) {
            self.serverURL = base
            defaults.set(base, forKey: serverURLDefaultsKey)
            defaults.set(persistedScheme.lowercased(), forKey: serverSchemeDefaultsKey)
            defaults.set(AuthManager.normalizeHost(persistedHost), forKey: serverHostDefaultsKey)
            defaults.set(persistedPort ?? AuthManager.defaultServerPort, forKey: serverPortDefaultsKey)
        } else if let persistedURL = defaults.string(forKey: serverURLDefaultsKey),
                  let parsed = AuthManager.parseBaseURL(persistedURL) {
            self.serverURL = AuthManager.buildBaseURL(
                scheme: parsed.scheme,
                host: parsed.host,
                port: parsed.port
            ) ?? persistedURL
            defaults.set(parsed.scheme, forKey: serverSchemeDefaultsKey)
            defaults.set(parsed.host, forKey: serverHostDefaultsKey)
            defaults.set(parsed.port ?? AuthManager.defaultServerPort, forKey: serverPortDefaultsKey)
        } else {
            // Fresh installs should not prefill server settings.
            self.serverURL = ""
            defaults.removeObject(forKey: serverURLDefaultsKey)
            defaults.removeObject(forKey: serverSchemeDefaultsKey)
            defaults.removeObject(forKey: serverHostDefaultsKey)
            defaults.removeObject(forKey: serverPortDefaultsKey)
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
    }

    func setServerURL(_ url: String) {
        guard let parsed = AuthManager.parseBaseURL(url) else { return }
        _ = setServerConfig(scheme: parsed.scheme, host: parsed.host, port: parsed.port)
    }

    struct ServerConfig: Equatable {
        var scheme: String
        var host: String
        var port: Int
    }

    func currentServerConfig() -> ServerConfig {
        if let parsed = AuthManager.parseBaseURL(serverURL) {
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
        let resolvedPort = port ?? AuthManager.defaultServerPort
        guard let base = AuthManager.buildBaseURL(scheme: scheme, host: host, port: resolvedPort) else { return false }
        serverURL = base
        let defaults = UserDefaults.standard
        defaults.set(base, forKey: serverURLDefaultsKey)
        defaults.set(scheme.lowercased(), forKey: serverSchemeDefaultsKey)
        defaults.set(AuthManager.normalizeHost(host), forKey: serverHostDefaultsKey)
        defaults.set(resolvedPort, forKey: serverPortDefaultsKey)
        return true
    }

    func recentServers() -> [String] {
        UserDefaults.standard.stringArray(forKey: serverRecentsDefaultsKey) ?? []
    }

    func addRecentServer(_ baseURL: String) {
        guard let parsed = AuthManager.parseBaseURL(baseURL),
              let normalized = AuthManager.buildBaseURL(scheme: parsed.scheme, host: parsed.host, port: parsed.port ?? AuthManager.defaultServerPort)
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
        saveUserEmail(trimmedEmail)
        keychain.set(Data(trimmedEmail.utf8), service: credentialsService, account: credentialEmailAccount)
        keychain.set(Data(password.utf8), service: credentialsService, account: credentialPasswordAccount)
        if let organizationId {
            keychain.set(Data(String(organizationId).utf8), service: credentialsService, account: credentialOrgIdAccount)
        } else {
            keychain.remove(service: credentialsService, account: credentialOrgIdAccount)
        }
        keychain.set(Data(serverURL.utf8), service: credentialsService, account: credentialServerAccount)
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
            let lhs = savedServer.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let rhs = serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard lhs == rhs else { return nil }
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
        let snapshot = await MainActor.run {
            AuthSnapshot(
                serverURL: self.serverURL,
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

        let (data, resp) = try await URLSession.shared.data(for: req)
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
        guard let url = URL(string: serverURL + "/api/auth/login/start") else {
            throw NSError(domain: "Auth", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid server URL"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = ["email": email]
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        let (data, resp) = try await URLSession.shared.data(for: req)
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
        guard let url = URL(string: serverURL + "/api/auth/login/finish") else {
            throw NSError(domain: "Auth", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid server URL"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["email": email, "organization_id": organizationId, "password": password]
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        let (data, resp) = try await URLSession.shared.data(for: req)
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
        guard let url = URL(string: serverURL + "/api/auth/login") else {
            throw NSError(domain: "Auth", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid server URL"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = ["email": email, "password": password]
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        let (data, resp) = try await URLSession.shared.data(for: req)
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
        guard let url = URL(string: serverURL + "/api/auth/password/change") else {
            throw NSError(domain: "Auth", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid server URL"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        var body: [String: Any] = ["new_password": newPassword]
        if let currentPassword, !currentPassword.isEmpty { body["current_password"] = currentPassword }
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        let (data, resp) = try await URLSession.shared.data(for: req)
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
        guard let url = URL(string: serverURL + "/api/auth/register") else {
            throw NSError(domain: "Auth", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid server URL"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "name": name,
            "email": email,
            "password": password
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, resp) = try await URLSession.shared.data(for: req)
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
        guard let host = comps.host, !host.isEmpty else { return nil }
        let port = comps.port ?? AuthManager.defaultServerPort
        return ParsedBaseURL(scheme: scheme, host: host, port: port)
    }

    static func buildBaseURL(scheme: String, host: String, port: Int?) -> String? {
        let schemeNorm = scheme.lowercased().replacingOccurrences(of: "://", with: "")
        let hostNorm = normalizeHost(host)
        guard !schemeNorm.isEmpty, !hostNorm.isEmpty else { return nil }
        let resolvedPort = port ?? AuthManager.defaultServerPort

        var comps = URLComponents()
        comps.scheme = schemeNorm
        comps.host = hostNorm
        comps.port = resolvedPort
        guard let url = comps.url else { return nil }
        var s = url.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
