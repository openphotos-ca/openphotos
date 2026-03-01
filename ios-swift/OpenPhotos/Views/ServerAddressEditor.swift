import SwiftUI

struct ServerAddressEditor: View {
    @EnvironmentObject private var auth: AuthManager

    enum Scheme: String, CaseIterable, Identifiable {
        case http
        case https

        var id: String { rawValue }
        var display: String { "\(rawValue)://" }
    }

    let onValidationChanged: ((String?) -> Void)?

    @State private var scheme: Scheme = .http
    @State private var hostOrIP: String = ""
    @State private var portText: String = ""

    @State private var validationMessage: String?
    @State private var isTesting = false
    @State private var testMessage: String?

    init(onValidationChanged: ((String?) -> Void)? = nil) {
        self.onValidationChanged = onValidationChanged
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Picker("", selection: $scheme) {
                    ForEach(Scheme.allCases) { s in
                        Text(s.display).tag(s)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .font(.callout)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(minWidth: 96, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)

                TextField("IP / Hostname / IPv6", text: $hostOrIP)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .keyboardType(.URL)
                    .layoutPriority(1)

                Text(":")
                    .foregroundColor(.secondary)

                TextField("3003", text: $portText)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(minWidth: 56, maxWidth: 72)
            }

            HStack(spacing: 10) {
                Menu("Recent Servers") {
                    let recents = auth.recentServers()
                    if recents.isEmpty {
                        Text("No recent servers")
                    } else {
                        ForEach(recents, id: \.self) { url in
                            Button(url) { applyBaseURL(url) }
                        }
                        Divider()
                        Button("Clear Recents", role: .destructive) { auth.clearRecentServers() }
                    }
                }
                .buttonStyle(.borderless)

                Spacer()

                Button(action: testConnection) {
                    if isTesting {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Testing…")
                        }
                    } else {
                        Text("Test Connection")
                    }
                }
                .disabled(isTesting)
                .buttonStyle(.borderless)
            }

            if let validationMessage {
                Text(validationMessage)
                    .foregroundColor(.red)
                    .font(.footnote)
            }
            if let testMessage {
                Text(testMessage)
                    .foregroundColor(testMessage.hasPrefix("Success") ? .green : .red)
                    .font(.footnote)
            }
        }
        .onAppear { loadFromAuth() }
        .onChange(of: scheme) { _ in validateAndCommit() }
        .onChange(of: hostOrIP) { newValue in
            // If a full URL is pasted into the host field, parse it and split into components.
            if newValue.contains("://"), let parsed = AuthManager.parseBaseURL(newValue) {
                applyParsedBaseURL(parsed)
                return
            }
            // Support pasting "host:port" without a scheme (IPv4/hostname, or bracketed IPv6).
            if portText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let split = splitHostPort(newValue) {
                hostOrIP = split.host
                portText = split.port
                validateAndCommit()
                return
            }
            validateAndCommit()
        }
        .onChange(of: portText) { _ in validateAndCommit() }
    }
}

extension ServerAddressEditor {
    private func loadFromAuth() {
        let cfg = auth.currentServerConfig()
        scheme = Scheme(rawValue: cfg.scheme) ?? .http
        hostOrIP = cfg.host
        portText = (cfg.port == AuthManager.defaultServerPort) ? "" : String(cfg.port)
        validateAndCommit()
    }

    private func applyBaseURL(_ url: String) {
        guard let parsed = AuthManager.parseBaseURL(url) else { return }
        applyParsedBaseURL(parsed)
    }

    private func applyParsedBaseURL(_ parsed: AuthManager.ParsedBaseURL) {
        scheme = Scheme(rawValue: parsed.scheme) ?? .http
        hostOrIP = parsed.host
        let resolvedPort = parsed.port ?? AuthManager.defaultServerPort
        portText = (resolvedPort == AuthManager.defaultServerPort) ? "" : String(resolvedPort)
        validateAndCommit()
    }

    private func validateAndCommit() {
        let hostTrim = hostOrIP.trimmingCharacters(in: .whitespacesAndNewlines)
        let portTrim = portText.trimmingCharacters(in: .whitespacesAndNewlines)

        var message: String?
        var portInt: Int?

        if hostTrim.isEmpty {
            message = "Enter an IP/hostname/IPv6 address."
        } else if hostTrim.contains(where: { $0.isWhitespace }) {
            message = "Host cannot contain spaces."
        }

        if message == nil, !portTrim.isEmpty {
            guard let p = Int(portTrim) else {
                message = "Port must be a number."
                validationMessage = message
                onValidationChanged?(message)
                return
            }
            guard (1...65535).contains(p) else {
                message = "Port must be between 1 and 65535."
                validationMessage = message
                onValidationChanged?(message)
                return
            }
            portInt = p
        }

        let normalizedHost = AuthManager.normalizeHost(hostTrim).lowercased()
        let isDemoHost = normalizedHost == "demo.openphotos.ca"
        let effectiveScheme = isDemoHost ? Scheme.https.rawValue : scheme.rawValue
        let effectivePort = isDemoHost ? 443 : (portInt ?? AuthManager.defaultServerPort)

        if message == nil {
            if isDemoHost {
                if scheme != .https {
                    scheme = .https
                }
                if portText != "443" {
                    portText = "443"
                }
            }
            guard let _ = AuthManager.buildBaseURL(
                scheme: effectiveScheme,
                host: hostTrim,
                port: effectivePort
            ) else {
                message = "Invalid server address."
                validationMessage = message
                onValidationChanged?(message)
                return
            }
            _ = auth.setServerConfig(scheme: effectiveScheme, host: hostTrim, port: effectivePort)
        }

        validationMessage = message
        onValidationChanged?(message)
    }

    private func testConnection() {
        validateAndCommit()
        guard validationMessage == nil else {
            testMessage = "Fix the server address and try again."
            return
        }
        let base = auth.serverURL
        guard let url = URL(string: base + "/ping") else {
            testMessage = "Invalid URL."
            return
        }

        isTesting = true
        testMessage = nil

        var req = URLRequest(url: url)
        req.timeoutInterval = 8

        Task {
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse else {
                    throw NSError(domain: "HTTP", code: -1, userInfo: [NSLocalizedDescriptionKey: "No response"])
                }
                let body = String(data: data, encoding: .utf8) ?? ""
                await MainActor.run {
                    isTesting = false
                    if (200..<300).contains(http.statusCode) {
                        testMessage = body.isEmpty ? "Success (\(http.statusCode))" : "Success (\(http.statusCode)): \(body)"
                        auth.addRecentServer(base)
                    } else {
                        testMessage = "HTTP \(http.statusCode): \(body)"
                    }
                }
            } catch {
                await MainActor.run {
                    isTesting = false
                    testMessage = "Error: \(error.localizedDescription)"
                }
            }
        }
    }

    private func splitHostPort(_ raw: String) -> (host: String, port: String)? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains("://") else { return nil }

        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            let after = s.index(after: close)
            guard after < s.endIndex, s[after] == ":" else { return nil }
            let portStart = s.index(after: after)
            let hostPart = String(s[s.startIndex...close])
            let portPart = String(s[portStart...])
            guard !portPart.isEmpty, portPart.allSatisfy({ $0.isNumber }) else { return nil }
            // Keep brackets here; AuthManager will normalize as needed.
            return (host: hostPart, port: portPart)
        }

        let colonCount = s.filter { $0 == ":" }.count
        guard colonCount == 1, let idx = s.lastIndex(of: ":") else { return nil }
        let hostPart = String(s[..<idx])
        let portPart = String(s[s.index(after: idx)...])
        guard !hostPart.isEmpty, !portPart.isEmpty, portPart.allSatisfy({ $0.isNumber }) else { return nil }
        return (host: hostPart, port: portPart)
    }
}
