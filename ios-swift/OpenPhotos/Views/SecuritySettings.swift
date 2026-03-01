import SwiftUI

struct SecuritySettingsView: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var unlockCtl: E2EEUnlockController

    @State private var ttlSeconds: Int = SecurityPreferences.shared.rememberUnlockSeconds
    @State private var showPinSheet: Bool = false
    @State private var pinMode: PinEditMode = .set
    @State private var toast: String = ""

    private let ttlOptions: [(label: String, seconds: Int)] = [
        ("15 minutes", 15 * 60),
        ("1 hour", 60 * 60),
        ("24 hours", 24 * 60 * 60)
    ]

    var body: some View {
        Form {
            Section("Set or Change PIN") {
                Button {
                    if E2EEManager.shared.loadEnvelope() != nil {
                        // Require unlock (biometric or PIN) before allowing change
                        E2EEUnlockController.shared.requireUnlock(reason: "Authenticate to change PIN") { ok in
                            if ok { pinMode = .change; showPinSheet = true }
                        }
                    } else {
                        pinMode = .set
                        showPinSheet = true
                    }
                } label: {
                    Text("Set or Change PIN code")
                }
            }

            Section(header: Text("Metadata included in locked media")) {
                // Always included (non-editable)
                HStack { Text("Capture time"); Spacer(); Image(systemName: "checkmark.circle.fill").foregroundColor(.blue) }
                HStack { Text("Dimensions"); Spacer(); Image(systemName: "checkmark.circle.fill").foregroundColor(.blue) }
                HStack { Text("Media type"); Spacer(); Image(systemName: "checkmark.circle.fill").foregroundColor(.blue) }
                HStack { Text("File size"); Spacer(); Image(systemName: "checkmark.circle.fill").foregroundColor(.blue) }
                HStack { Text("Orientation"); Spacer(); Image(systemName: "checkmark.circle.fill").foregroundColor(.blue) }

                // Optional
                Toggle("Location data (GPS)", isOn: Binding(get: { SecurityPreferences.shared.includeLocation }, set: { SecurityPreferences.shared.includeLocation = $0 }))
                Toggle("Description", isOn: Binding(get: { SecurityPreferences.shared.includeDescription }, set: { SecurityPreferences.shared.includeDescription = $0 }))
                Toggle("Caption", isOn: Binding(get: { SecurityPreferences.shared.includeCaption }, set: { SecurityPreferences.shared.includeCaption = $0 }))
                Text("Only coordinates are sent; server resolves place names.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            Section("Remember unlock") {
                Picker("Duration", selection: $ttlSeconds) {
                    ForEach(ttlOptions, id: \.seconds) { opt in
                        Text(opt.label).tag(opt.seconds)
                    }
                }
                .onChange(of: ttlSeconds) { v in
                    SecurityPreferences.shared.rememberUnlockSeconds = v
                }
                Text("If enabled, your device remembers the unlocked key locally and won’t prompt for PIN again until it expires.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("Security")
        .sheet(isPresented: $showPinSheet) {
            ChangePinSheet(mode: pinMode) { msg in
                if let m = msg { ToastManager.shared.show(m) }
            }
            .environmentObject(auth)
        }
    }
}

private enum PinEditMode { case set, change }

private struct ChangePinSheet: View {
    let mode: PinEditMode
    let onDone: (String?) -> Void
    @EnvironmentObject var auth: AuthManager
    @Environment(\.dismiss) private var dismiss
    @State private var newPin: String = ""
    @State private var confirmPin: String = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 16) {
            Text(mode == .change ? "Change PIN" : "Set PIN").font(.headline)
            // 8-box input for new PIN (matches web)
            VStack(alignment: .leading, spacing: 8) {
                Text("New PIN").font(.subheadline)
                PinBoxesView(text: $newPin, length: 8, asciiOnly: true, isEnabled: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Confirm PIN").font(.subheadline)
                PinBoxesView(text: $confirmPin, length: 8, asciiOnly: true, isEnabled: true)
            }
            if let e = error { Text(e).foregroundColor(.red).font(.footnote) }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .padding(.top, 12)
        .presentationDetents([.fraction(0.36)])
        .presentationDragIndicator(.visible)
    }

    private func save() {
        let pin = String(newPin.prefix(8))
        let c = String(confirmPin.prefix(8))
        guard pin.count == 8, c.count == 8, pin == c else { error = "PINs do not match"; return }
        // Ensure we have a UMK. If none present (first set), generate one.
        var umkData = E2EEManager.shared.umk
        if umkData == nil || umkData!.count != 32 {
            var d = Data(count: 32)
            _ = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
            E2EEManager.shared.installNewUMK(d)
            umkData = d
        }
        guard let umk = umkData, umk.count == 32 else { error = "No key material"; return }
        do {
            // Re-wrap UMK with the new PIN and save/push envelope
            let env = try E2EEManager.shared.wrapUMKForPassword(umk: umk, password: pin, accountId: nil, userId: auth.userId, params: .init(m: 128, t: 3, p: 1))
            // Save to server asynchronously
            Task { await E2EEManager.shared.pushEnvelopeToServer() }
            // Save quick-unlock copy
            _ = E2EEManager.shared.saveDeviceWrappedUMK(umk)
            E2EEManager.shared.updateStoredEnvelopeHashToCurrentLocal()
            onDone(mode == .change ? "PIN updated" : "PIN set")
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
