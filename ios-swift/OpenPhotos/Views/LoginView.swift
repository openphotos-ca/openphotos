import SwiftUI

struct LoginView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var auth: AuthManager

    @State private var email: String = ""
    @State private var password: String = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isRegister: Bool = false
    @State private var name: String = ""
    @State private var organizations: [Org] = []
    @State private var selectedOrgId: Int?
    @State private var mustChangePassword: Bool = false
    @State private var newPassword: String = ""
    @State private var serverValidationMessage: String?

    struct Org: Identifiable { let id: Int; let name: String }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Picker("Mode", selection: $isRegister) {
                        Text("Log In").tag(false)
                        Text("Create Account").tag(true)
                    }
                    .pickerStyle(.segmented)
                }

                Section("Server") {
                    ServerAddressEditor { message in
                        serverValidationMessage = message
                    }
                }

                Section {
                    if isRegister {
                        TextField("Full Name", text: $name)
                            .textContentType(.name)
                    }
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    SecureField("Password", text: $password)
                    if !organizations.isEmpty {
                        Picker("Organization", selection: Binding(get: { selectedOrgId ?? organizations.first?.id }, set: { selectedOrgId = $0 })) {
                            ForEach(organizations) { org in
                                Text(org.name).tag(org.id as Int?)
                            }
                        }
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundColor(.red)
                }

                Button(action: { isRegister ? onRegister() : onLogin() }) {
                    if isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text(isRegister ? "Create Account" : (organizations.isEmpty ? "Next" : "Log In"))
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(
                    isLoading ||
                    auth.currentEffectiveBaseURL().isEmpty ||
                    serverValidationMessage != nil ||
                    email.isEmpty ||
                    password.isEmpty ||
                    (isRegister && name.isEmpty)
                )
                if mustChangePassword {
                    Section(header: Text("Set New Password")) {
                        SecureField("New Password", text: $newPassword)
                        Button("Update Password") { onChangePassword() }
                            .disabled(newPassword.isEmpty || isLoading)
                    }
                }
            }
            .navigationTitle(isRegister ? "Create Account" : "Log In")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: {
                        auth.clearManualServerOverride()
                        dismiss()
                    }) {
                        Image(systemName: "xmark")
                            .imageScale(.medium)
                    }
                    .accessibilityLabel("Close")
                }
            }
            .onAppear {
                serverValidationMessage = nil
                loadLastUsedLoginValues()
                applyDemoDefaultsIfNeeded()
            }
            .onChange(of: auth.serverURL) { _ in
                // Changing servers invalidates the login-step state.
                organizations = []
                selectedOrgId = nil
                mustChangePassword = false
                errorMessage = nil
                applyDemoDefaultsIfNeeded()
            }
            .onDisappear {
                if !auth.isAuthenticated {
                    auth.clearManualServerOverride()
                }
            }
        }
    }

    private func onLogin() {
        errorMessage = nil
        isLoading = true
        Task {
            do {
                if organizations.isEmpty {
                    // Step 1: try two-step login discovery; if unavailable, fallback to password-only login.
                    do {
                        let accounts = try await auth.loginStart(email: email)
                        guard !accounts.isEmpty else {
                            throw NSError(
                                domain: "Auth",
                                code: 6,
                                userInfo: [NSLocalizedDescriptionKey: "No account for this email."]
                            )
                        }
                        if accounts.count == 1 {
                            let must = try await auth.loginFinish(email: email, organizationId: accounts[0].id, password: password)
                            await MainActor.run {
                                self.auth.commitManualServerOverride()
                                self.organizations = [Org(id: accounts[0].id, name: accounts[0].name)]
                                self.selectedOrgId = accounts[0].id
                                self.mustChangePassword = must
                            }
                            if !must {
                                await MainActor.run { dismiss() }
                            } else {
                                await MainActor.run { self.isLoading = false }
                            }
                        } else {
                            await MainActor.run {
                                self.organizations = accounts.map { Org(id: $0.id, name: $0.name) }
                                self.selectedOrgId = self.organizations.first?.id
                                self.isLoading = false
                            }
                        }
                    } catch {
                        if auth.shouldFallbackToSingleStepLogin(error) {
                            let must = try await auth.loginSingleStep(email: email, password: password)
                            await MainActor.run {
                                self.auth.commitManualServerOverride()
                                self.mustChangePassword = must
                            }
                            if !must {
                                await MainActor.run { dismiss() }
                            } else {
                                await MainActor.run { self.isLoading = false }
                            }
                        } else {
                            throw error
                        }
                    }
                } else {
                    guard let gid = selectedOrgId else { throw NSError(domain: "Auth", code: 5, userInfo: [NSLocalizedDescriptionKey: "Select organization"]) }
                    let must = try await auth.loginFinish(email: email, organizationId: gid, password: password)
                    await MainActor.run {
                        self.auth.commitManualServerOverride()
                        self.mustChangePassword = must
                    }
                    if !must { await MainActor.run { dismiss() } }
                    else { await MainActor.run { self.isLoading = false } }
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    private func onChangePassword() {
        errorMessage = nil
        isLoading = true
        Task {
            do {
                try await auth.changePassword(newPassword: newPassword)
                // After change, login again with new password
                if let gid = selectedOrgId ?? organizations.first?.id {
                    let _ = try await auth.loginFinish(email: email, organizationId: gid, password: newPassword)
                    await MainActor.run { dismiss() }
                } else {
                    let _ = try await auth.loginSingleStep(email: email, password: newPassword)
                    await MainActor.run { dismiss() }
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    private func loadLastUsedLoginValues() {
        if email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let lastEmail = auth.lastUsedLoginEmail() {
            email = lastEmail
        }
        password = ""
    }

    private func applyDemoDefaultsIfNeeded() {
        let config = auth.currentServerConfig()
        let host = AuthManager.normalizeHost(config.host).lowercased()
        guard host == "demo.openphotos.ca" else { return }

        email = "demo@openphotos.ca"
        password = "demo"
        isRegister = false
        organizations = []
        selectedOrgId = nil
        mustChangePassword = false
        errorMessage = nil
        newPassword = ""
    }
}

extension LoginView {
    private func onRegister() {
        errorMessage = nil
        isLoading = true
        Task {
            do {
                try await auth.register(name: name, email: email, password: password)
                await MainActor.run {
                    auth.commitManualServerOverride()
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }
}
