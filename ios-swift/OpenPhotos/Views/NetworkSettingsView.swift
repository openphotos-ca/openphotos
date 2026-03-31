import SwiftUI

struct NetworkSettingsView: View {
    @EnvironmentObject private var auth: AuthManager

    @State private var publicURLText: String = ""
    @State private var localURLText: String = ""
    @State private var validationMessage: String?
    @State private var publicTestMessage: String?
    @State private var localTestMessage: String?
    @State private var isTestingPublic = false
    @State private var isTestingLocal = false
    @State private var isRefreshing = false

    var body: some View {
        Form {
            Section("Current Connection") {
                labeledValue("Active URL", value: auth.currentEffectiveBaseURL().isEmpty ? "-" : auth.currentEffectiveBaseURL())
                labeledValue("Routing", value: auth.networkStatusSummary())
                labeledValue("Transport", value: transportLabel(auth.networkTransport))
                if let lastLocalProbeAt = auth.lastLocalProbeAt {
                    labeledValue("Last Local Probe", value: lastLocalProbeAt.formatted(date: .abbreviated, time: .shortened))
                }
                if let lastLocalProbeMessage = auth.lastLocalProbeMessage, !lastLocalProbeMessage.isEmpty {
                    Text(lastLocalProbeMessage)
                        .font(.footnote)
                        .foregroundColor((auth.lastLocalProbeSucceeded ?? false) ? .green : .secondary)
                }

                Button(isRefreshing ? "Refreshing…" : "Refresh") {
                    isRefreshing = true
                    Task {
                        await auth.refreshNetworkRouting()
                        await MainActor.run { isRefreshing = false }
                    }
                }
                .disabled(isRefreshing)

                Button("Use Current Connection") {
                    auth.useCurrentConnection()
                    syncFieldsFromAuth()
                }
                .disabled(auth.activeEndpoint == .none)
            }

            Section("Routing") {
                Toggle("Auto-switch URL", isOn: Binding(
                    get: { auth.autoSwitchEnabled },
                    set: { auth.setAutoSwitchEnabled($0) }
                ))

                if !auth.autoSwitchEnabled {
                    Picker("Preferred URL", selection: Binding(
                        get: { auth.manualPreferredEndpoint },
                        set: { auth.setManualPreferredEndpoint($0) }
                    )) {
                        Text("External Network").tag(AuthManager.ManualPreferredEndpoint.public)
                        Text("Local Network").tag(AuthManager.ManualPreferredEndpoint.local)
                    }
                }
            }

            Section("External Network") {
                networkURLField(
                    text: $publicURLText,
                    placeholder: "https://example.openphotos.ca"
                )

                Button("Save External URL") {
                    saveSettings(successMessage: "External URL saved.")
                }

                Button(isTestingPublic ? "Testing…" : "Test Public") {
                    test(endpoint: .public)
                }
                .disabled(isTestingPublic)

                if let publicTestMessage {
                    Text(publicTestMessage)
                        .font(.footnote)
                        .foregroundColor(publicTestMessage.hasPrefix("Success") ? .green : .secondary)
                }
            }

            Section("Local Network") {
                networkURLField(
                    text: $localURLText,
                    placeholder: "http://192.168.2.249:3003"
                )

                Button("Save Local URL") {
                    saveSettings(successMessage: "Local URL saved.")
                }

                Button(isTestingLocal ? "Testing…" : "Test Local") {
                    test(endpoint: .local)
                }
                .disabled(isTestingLocal)

                if let localTestMessage {
                    Text(localTestMessage)
                        .font(.footnote)
                        .foregroundColor(localTestMessage.hasPrefix("Success") ? .green : .secondary)
                }
            }

            if let validationMessage {
                Section {
                    Text(validationMessage)
                        .font(.footnote)
                        .foregroundColor(.red)
                }
            }
        }
        .navigationTitle("Advanced Network")
        .onAppear { syncFieldsFromAuth() }
        .onChange(of: auth.publicBaseURL) { _ in syncFieldsFromAuth() }
        .onChange(of: auth.localBaseURL) { _ in syncFieldsFromAuth() }
    }
}

private extension NetworkSettingsView {
    func labeledValue(_ label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
        }
    }

    func transportLabel(_ transport: AuthManager.NetworkTransportKind) -> String {
        switch transport {
        case .offline:
            return "Offline"
        case .wifi:
            return "Wi-Fi"
        case .ethernet:
            return "Ethernet"
        case .cellular:
            return "Cellular"
        case .other:
            return "Other"
        }
    }

    func syncFieldsFromAuth() {
        publicURLText = auth.publicBaseURL
        localURLText = auth.localBaseURL
        validationMessage = nil
    }

    func networkURLField(text: Binding<String>, placeholder: String) -> some View {
        ZStack(alignment: .leading) {
            if text.wrappedValue.isEmpty {
                Text(placeholder)
                    .foregroundStyle(.secondary)
                    .allowsHitTesting(false)
            }

            TextField("", text: text)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .keyboardType(.URL)
                .foregroundColor(.primary)
        }
    }

    func saveSettings(successMessage: String) {
        let trimmedPublic = publicURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLocal = localURLText.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmedPublic.isEmpty && AuthManager.parseBaseURL(trimmedPublic) == nil {
            validationMessage = "External URL is invalid."
            ToastManager.shared.show("External URL is invalid.")
            return
        }
        if !trimmedLocal.isEmpty && AuthManager.parseBaseURL(trimmedLocal) == nil {
            validationMessage = "Local URL is invalid."
            ToastManager.shared.show("Local URL is invalid.")
            return
        }

        validationMessage = nil
        auth.saveConfiguredBaseURLs(publicBaseURL: trimmedPublic, localBaseURL: trimmedLocal)
        syncFieldsFromAuth()
        ToastManager.shared.show(successMessage)
    }

    func test(endpoint: AuthManager.ManualPreferredEndpoint) {
        if endpoint == .public {
            isTestingPublic = true
            publicTestMessage = nil
        } else {
            isTestingLocal = true
            localTestMessage = nil
        }

        Task {
            let result = await auth.testConfiguredEndpoint(endpoint)
            await MainActor.run {
                if endpoint == .public {
                    isTestingPublic = false
                    publicTestMessage = result.message
                } else {
                    isTestingLocal = false
                    localTestMessage = result.message
                }
            }
        }
    }
}
