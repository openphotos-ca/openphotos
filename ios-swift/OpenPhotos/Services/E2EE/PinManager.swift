import Foundation
import CryptoKit
import LocalAuthentication

// PIN is a UI gate only; not used to wrap UMK. We store a salted hash and verify locally.
// Argon2 is not integrated; we use repeated SHA256 rounds for a slow hash.

final class PinManager {
    static let shared = PinManager()
    private init() {}

    private let kc = KeychainHelper.shared
    private let svc = "com.openphotos.pin"
    private let acctHash = "hash"
    private let acctSalt = "salt"
    private let acctBio = "biometricToken"

    // In-memory session gating (avoid re-prompting PIN repeatedly)
    private var sessionVerifiedUntil: Date?
    private let sessionTTLSeconds: TimeInterval = 15 * 60 // 15 minutes

    // User preference: enable Face ID/Touch ID for PIN quick verify
    private let useBiometricsKey = "security.pin.useBiometrics"

    func hasPin() -> Bool {
        let hasH = kc.get(service: svc, account: acctHash) != nil
        let hasS = kc.get(service: svc, account: acctSalt) != nil
        print("[PIN] hasPin hash=\(hasH) salt=\(hasS)")
        return hasH && hasS
    }

    func setPin(_ pin: String) {
        let trimmed = pin.trimmingCharacters(in: .whitespacesAndNewlines)
        let salt = randomData(16)
        let digest = slowHash(pin: trimmed, salt: salt)
        kc.set(digest, service: svc, account: acctHash)
        kc.set(salt, service: svc, account: acctSalt)
        print("[PIN] setPin len=\(trimmed.count) saltLen=\(salt.count) hashFirst8=\(digest.prefix(8).base64EncodedString())")
    }

    func verifyPin(_ pin: String) -> Bool {
        guard let salt = kc.get(service: svc, account: acctSalt), let expected = kc.get(service: svc, account: acctHash) else {
            print("[PIN] verifyPin missing keychain items")
            return false
        }
        let trimmed = pin.trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = slowHash(pin: trimmed, salt: salt)
        let ok = (digest == expected)
        print("[PIN] verifyPin len=\(trimmed.count) saltLen=\(salt.count) inputFirst8=\(digest.prefix(8).base64EncodedString()) expectedFirst8=\(expected.prefix(8).base64EncodedString()) ok=\(ok)")
        if ok { markSessionVerified() }
        return ok
    }

    private func slowHash(pin: String, salt: Data) -> Data {
        var data = Data(); data.append(salt); data.append(pin.data(using: .utf8)!)
        var hash = Data(SHA256.hash(data: data))
        // 100k rounds SHA256 over previous output + salt
        for _ in 0..<100_000 {
            var d = Data(); d.append(salt); d.append(hash)
            hash = Data(SHA256.hash(data: d))
        }
        return hash
    }

    private func randomData(_ n: Int) -> Data { var d = Data(count: n); _ = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, n, $0.baseAddress!) }; return d }

    // MARK: - Session helpers
    func isSessionVerified() -> Bool {
        if let until = sessionVerifiedUntil { return Date() < until }
        return false
    }
    func markSessionVerified() { sessionVerifiedUntil = Date().addingTimeInterval(sessionTTLSeconds) }
    func clearSession() { sessionVerifiedUntil = nil }

    // MARK: - Biometric quick verify
    func isBiometricsEnabled() -> Bool {
        if UserDefaults.standard.object(forKey: useBiometricsKey) == nil { return true } // default on
        return UserDefaults.standard.bool(forKey: useBiometricsKey)
    }
    func setBiometricsEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: useBiometricsKey)
        if enabled {
            _ = ensureBiometricToken()
        } else {
            removeBiometricToken()
        }
    }

    func canUseBiometricQuickVerify() -> Bool {
        guard isBiometricsEnabled() else { return false }
        var error: NSError?
        let ctx = LAContext()
        let ok = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        return ok && hasBiometricToken()
    }

    @discardableResult
    func quickVerifyWithBiometrics(prompt: String = "Verify with Face ID") -> Bool {
        if isBiometricsEnabled() && !hasBiometricToken() { _ = ensureBiometricToken() }
        guard canUseBiometricQuickVerify() else { return false }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: svc,
            kSecAttrAccount as String: acctBio,
            kSecReturnData as String: true,
            kSecUseOperationPrompt as String: prompt
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess {
            print("[PIN] Biometric quick verify success")
            markSessionVerified()
            return true
        }
        print("[PIN] Biometric quick verify failed status=\(status)")
        return false
    }

    @discardableResult
    func ensureBiometricToken() -> Bool {
        if hasBiometricToken() { return true }
        let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.userPresence], nil)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: svc,
            kSecAttrAccount as String: acctBio,
            kSecValueData as String: randomData(32)
        ]
        if let access { query[kSecAttrAccessControl as String] = access }
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: svc,
                       kSecAttrAccount as String: acctBio] as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess { print("[PIN] Biometric token created") ; return true }
        print("[PIN] Biometric token create failed status=\(status)")
        return false
    }

    func removeBiometricToken() {
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: svc,
                                    kSecAttrAccount as String: acctBio] as CFDictionary)
        print("[PIN] Biometric token removed status=\(status)")
    }

    private func hasBiometricToken() -> Bool {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: svc,
            kSecAttrAccount as String: acctBio,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        let status = SecItemCopyMatching(q as CFDictionary, nil)
        return status == errSecSuccess
    }
}
