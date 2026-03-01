import SwiftUI
import Security

final class E2EEUnlockController: ObservableObject {
    static let shared = E2EEUnlockController()
    @Published var showUnlockSheet: Bool = false
    @Published var reason: String = ""
    fileprivate var pending: [(Bool) -> Void] = []

    func requireUnlock(reason: String, completion: @escaping (Bool) -> Void) {
        // Respect TTL: clear if expired, and return success only if still valid
        E2EEManager.shared.clearUMKIfExpired()
        if E2EEManager.shared.hasValidUMKRespectingTTL() { completion(true); return }
        // Try quick unlock with Face/Touch ID (do not fallback to device passcode if biometrics absent per spec)
        if SecurityPreferences.shared.biometricsAvailable() {
            if E2EEManager.shared.unlockWithDeviceKey(prompt: "Unlock to continue") { completion(true); return }
        }
        // Present the sheet immediately. If no envelope exists (no PIN configured yet),
        // the UI will offer to set a PIN; otherwise it will prompt to unlock.
        DispatchQueue.main.async {
            self.reason = reason
            self.pending.append(completion)
            self.showUnlockSheet = true
        }
        if E2EEManager.shared.loadEnvelope() == nil {
            Task { await E2EEManager.shared.syncEnvelopeFromServer() }
        }
    }

    func complete(_ ok: Bool) {
        let callbacks = pending
        pending.removeAll()
        showUnlockSheet = false
        for cb in callbacks { cb(ok) }
    }
}

struct UnlockUMKSheet: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var controller: E2EEUnlockController
    @State private var pin8: String = ""
    @State private var newPin8: String = ""
    @State private var confirmPin8: String = ""
    @State private var setupStep: Int = 0 // 0 = enter, 1 = confirm
    @State private var error: String?
    @State private var isProcessing: Bool = false
    @State private var isFetchingEnvelope: Bool = false
    @State private var hasEnvelope: Bool = (E2EEManager.shared.loadEnvelope() != nil)

    var body: some View {
        VStack(spacing: 16) {
            if hasEnvelope {
                Text("Unlock Encrypted Items").font(.headline)
                if !controller.reason.isEmpty { Text(controller.reason).font(.subheadline).foregroundColor(.secondary) }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Enter your 8-character PIN").font(.subheadline)
                    PinBoxesView(text: $pin8, length: 8, asciiOnly: true, isEnabled: !isProcessing, onCommit: {
                        if pin8.count == 8 { unlock() }
                    })
                }
            } else {
                Text("Set an 8-character PIN").font(.headline)
                Text("This protects locked items. Use 8 characters.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                if setupStep == 0 {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("PIN").font(.subheadline)
                        PinBoxesView(text: $newPin8, length: 8, asciiOnly: true, isEnabled: !isProcessing, onCommit: {
                            if newPin8.count == 8 { setupStep = 1 }
                        })
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Confirm PIN").font(.subheadline)
                        PinBoxesView(text: $confirmPin8, length: 8, asciiOnly: true, isEnabled: !isProcessing, onCommit: {
                            if confirmPin8.count == 8 { setPin() }
                        })
                    }
                }
            }

            if let e = error { Text(e).foregroundColor(.red).font(.footnote) }
            if isFetchingEnvelope && !hasEnvelope {
                ProgressView().scaleEffect(0.9)
            }
            HStack {
                Button("Cancel") { controller.complete(false) }
                Spacer()
                if hasEnvelope {
                    Button("Unlock") { unlock() }
                        .buttonStyle(.borderedProminent)
                        .disabled(pin8.count != 8 || isProcessing)
                } else {
                    if setupStep == 0 {
                        Button("Next") {
                            if newPin8.count == 8 { setupStep = 1 }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(newPin8.count != 8 || isProcessing)
                    } else {
                        Button("Back") {
                            setupStep = 0
                            confirmPin8 = ""
                            error = nil
                        }
                        .buttonStyle(.bordered)
                        .disabled(isProcessing)
                        Button("Save") { setPin() }
                            .buttonStyle(.borderedProminent)
                            .disabled(confirmPin8.count != 8 || isProcessing)
                    }
                }
            }
        }
        .padding()
        .padding(.top, 12)
        .presentationDetents([.fraction(0.38)])
        .presentationDragIndicator(.visible)
        .onAppear {
            refreshEnvelopeStatus()
            if !hasEnvelope { fetchEnvelopeIfNeeded() }
        }
    }

    private func unlock() {
        if isProcessing { return }
        isProcessing = true
        guard let env = E2EEManager.shared.loadEnvelope() else { self.error = "No envelope available"; self.isProcessing = false; return }
        let secret = String(pin8.prefix(8))
        if secret.count != 8 { self.error = "Enter 8 characters"; isProcessing = false; return }
        do {
            let ok = try E2EEManager.shared.unlockWithPassword(password: secret, envelope: env)
            // On success, persist UMK to device keychain for biometric quick unlock next time
            if ok, let umk = E2EEManager.shared.umk, umk.count == 32 {
                _ = E2EEManager.shared.saveDeviceWrappedUMK(umk)
                // Mark current envelope as last-seen so freshness checks don't prompt needlessly
                E2EEManager.shared.updateStoredEnvelopeHashToCurrentLocal()
            }
            controller.complete(ok)
        } catch {
            self.error = error.localizedDescription
            self.isProcessing = false
        }
    }

    private func setPin() {
        if isProcessing { return }
        isProcessing = true
        error = nil

        let p = String(newPin8.prefix(8))
        let c = String(confirmPin8.prefix(8))
        guard p.count == 8, c.count == 8, p == c else {
            error = "PINs do not match"
            isProcessing = false
            return
        }

        // Ensure we have a UMK. If none present (first set), generate one.
        var umkData = E2EEManager.shared.umk
        if umkData == nil || umkData!.count != 32 {
            var d = Data(count: 32)
            _ = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
            E2EEManager.shared.installNewUMK(d)
            umkData = d
        }
        guard let umk = umkData, umk.count == 32 else { error = "No key material"; isProcessing = false; return }

        do {
            _ = try E2EEManager.shared.wrapUMKForPassword(
                umk: umk,
                password: p,
                accountId: nil,
                userId: auth.userId,
                params: .init(m: 128, t: 3, p: 1)
            )
            Task { await E2EEManager.shared.pushEnvelopeToServer() }
            _ = E2EEManager.shared.saveDeviceWrappedUMK(umk)
            E2EEManager.shared.updateStoredEnvelopeHashToCurrentLocal()
            controller.complete(true)
        } catch {
            self.error = error.localizedDescription
            self.isProcessing = false
        }
    }

    private func refreshEnvelopeStatus() {
        hasEnvelope = (E2EEManager.shared.loadEnvelope() != nil)
        if hasEnvelope {
            setupStep = 0
            newPin8 = ""
            confirmPin8 = ""
        }
    }

    private func fetchEnvelopeIfNeeded() {
        if isFetchingEnvelope { return }
        isFetchingEnvelope = true
        Task {
            await E2EEManager.shared.syncEnvelopeFromServer()
            await MainActor.run {
                self.isFetchingEnvelope = false
                self.refreshEnvelopeStatus()
            }
        }
    }
}
