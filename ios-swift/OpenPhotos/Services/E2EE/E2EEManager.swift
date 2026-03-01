import Foundation
import CryptoKit
import LocalAuthentication
// Optional Argon2id via Sodium; used if available
#if canImport(Sodium)
import Sodium
#endif

// E2EEManager handles UMK envelope storage, unlock flows, and quick unlock keychain.
// Note: Argon2id derivation is not implemented here; a placeholder throws until integrated.

final class E2EEManager: ObservableObject {
    static let shared = E2EEManager()

    // In-memory UMK (never persisted in plaintext)
    @Published private(set) var umk: Data?
    @Published private(set) var isUnlocked: Bool = false
    private var lastUnlockedAt: Date?

    // Envelope cache (ciphertext) on disk
    private let envelopeDir: URL
    private let envelopeFile: URL

    // Device quick-unlock keychain ids
    private let kcService = "com.openphotos.e2ee"
    private let kcAccountUMK = "umk.deviceWrapped"
    private let lastEnvelopeHashKey = "e2ee.last_envelope_hash"

    // Argon2id params (match web defaults; can be tuned/calibrated)
    struct ArgonParams: Codable { let m: Int; let t: Int; let p: Int }
    struct Envelope: Codable {
        let kdf: String
        let salt_b64url: String
        let m: Int
        let t: Int
        let p: Int
        let info: String // "umk-wrap:v1"
        let wrap_iv_b64url: String
        let umk_wrapped_b64url: String
        let version: Int
        // Optional helpful context fields for clients (not part of AAD in this build)
        let accountId: String?
        let userId: String?
    }

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.envelopeDir = appSupport.appendingPathComponent("E2EE", isDirectory: true)
        self.envelopeFile = envelopeDir.appendingPathComponent("envelope.json")
        try? FileManager.default.createDirectory(at: envelopeDir, withIntermediateDirectories: true, attributes: [FileAttributeKey.protectionKey: FileProtectionType.complete])
    }

    func clearUMK() {
        umk = nil
        isUnlocked = false
        lastUnlockedAt = nil
    }

    func clearStoredEnvelopeHash() {
        UserDefaults.standard.removeObject(forKey: lastEnvelopeHashKey)
    }

    private func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func currentLocalEnvelopeHash() -> String? {
        guard FileManager.default.fileExists(atPath: envelopeFile.path), let d = try? Data(contentsOf: envelopeFile) else { return nil }
        return sha256Hex(d)
    }

    func getStoredEnvelopeHash() -> String? {
        return UserDefaults.standard.string(forKey: lastEnvelopeHashKey)
    }

    func updateStoredEnvelopeHashToCurrentLocal() {
        if let h = currentLocalEnvelopeHash() {
            UserDefaults.standard.set(h, forKey: lastEnvelopeHashKey)
        }
    }

    // MARK: - TTL handling
    func hasValidUMKRespectingTTL() -> Bool {
        // If device biometrics are unavailable, require PIN every time per spec
        if !SecurityPreferences.shared.biometricsAvailable() { return false }
        guard let _ = umk, isUnlocked else { return false }
        let ttl = SecurityPreferences.shared.rememberUnlockSeconds
        guard ttl > 0 else { return false }
        if let last = lastUnlockedAt { return Date().timeIntervalSince(last) < Double(ttl) }
        return false
    }

    func clearUMKIfExpired() {
        let ttl = SecurityPreferences.shared.rememberUnlockSeconds
        if ttl <= 0 { clearUMK(); return }
        if let last = lastUnlockedAt, Date().timeIntervalSince(last) >= Double(ttl) {
            clearUMK()
        }
    }

    private func markUnlockedNow() {
        lastUnlockedAt = Date()
    }

    // Expose a helper to install a freshly generated UMK when user sets a new PIN
    func installNewUMK(_ data: Data) {
        self.umk = data
        self.isUnlocked = true
        self.lastUnlockedAt = Date()
    }

    // MARK: - Envelope load/save
    func loadEnvelope() -> Envelope? {
        guard FileManager.default.fileExists(atPath: envelopeFile.path) else { return nil }
        guard let data = try? Data(contentsOf: envelopeFile) else { return nil }
        return try? JSONDecoder().decode(Envelope.self, from: data)
    }

    func hasEnvelope() -> Bool {
        let exists = FileManager.default.fileExists(atPath: envelopeFile.path)
        if exists { print("[E2EE] Local envelope present") } else { print("[E2EE] No local envelope") }
        return exists
    }

    func saveEnvelope(_ env: Envelope) {
        if let data = try? JSONEncoder().encode(env) {
            try? data.write(to: envelopeFile, options: [.atomic])
            // Apply complete protection
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: envelopeFile.path)
        }
    }

    // Pull envelope from server if available and cache locally
    func syncEnvelopeFromServer() async {
        do {
            guard let envAny = try await CryptoAPI.shared.getEnvelope() else { return }
            if let data = try? JSONSerialization.data(withJSONObject: envAny, options: []), let env = try? JSONDecoder().decode(Envelope.self, from: data) {
                saveEnvelope(env)
            }
        } catch { print("[E2EE] fetch envelope failed: \(error)") }
    }

    // Save current local envelope JSON blob to server
    func pushEnvelopeToServer() async {
        guard let env = loadEnvelope() else { return }
        do {
            // Build a simple dictionary excluding accountId/userId (server doesn't require)
            let dict: [String: Any] = [
                "kdf": env.kdf,
                "salt_b64url": env.salt_b64url,
                "m": env.m,
                "t": env.t,
                "p": env.p,
                "info": env.info,
                "wrap_iv_b64url": env.wrap_iv_b64url,
                "umk_wrapped_b64url": env.umk_wrapped_b64url,
                "version": env.version,
            ]
            let _ = try await CryptoAPI.shared.saveEnvelope(dict)
        } catch { print("[E2EE] save envelope failed: \(error)") }
    }

    // MARK: - Quick unlock (device-wrapped UMK)
    func saveDeviceWrappedUMK(_ umk: Data) -> Bool {
        // Store as generic password with biometry/user presence gate
        let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.userPresence], nil)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: kcService,
            kSecAttrAccount as String: kcAccountUMK,
        ]
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = umk
        if let access { query[kSecAttrAccessControl as String] = access }
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    func loadDeviceWrappedUMK(prompt: String = "Unlock") -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: kcService,
            kSecAttrAccount as String: kcAccountUMK,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        query[kSecUseOperationPrompt as String] = prompt
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data { return data }
        return nil
    }

    func clearDeviceWrappedUMK() {
        KeychainHelper.shared.remove(service: kcService, account: kcAccountUMK)
    }

    // MARK: - Derivation (Argon2id → HKDF)
    // Placeholder — integrate Argon2id library and match web params (m,t,p) in MiB, ops, parallelism.
    private func derivePWK(password: String, salt: Data, params: ArgonParams) throws -> Data {
        // Argon2id(password, salt, mMiB, t, p) -> HKDF-SHA256(info="umk-wrap:v1", L=32)
        // Use Sodium if available
        #if canImport(Sodium)
        let sodium = Sodium()
        let pwd: Bytes = Array(password.utf8)
        let saltBytes: Bytes = Array(salt)
        let memBytesInt: Int = Int(UInt64(params.m) * 1024 * 1024)
        let opsInt: Int = Int(UInt64(params.t))
        print("[E2EE] Argon2id derive mMiB=\(params.m) t=\(params.t) p=\(params.p) memBytes=\(memBytesInt) ops=\(opsInt) saltLen=\(salt.count)")
        guard let derived = sodium.pwHash.hash(
            outputLength: 32,
            passwd: pwd,
            salt: saltBytes,
            opsLimit: opsInt,
            memLimit: memBytesInt,
            alg: .Argon2ID13
        ) else {
            throw NSError(domain: "E2EE", code: -101, userInfo: [NSLocalizedDescriptionKey: "Argon2id derivation failed"])
        }
        let kdf = Data(derived)
        let pwk = hkdfSha256(ikm: kdf, info: Data("umk-wrap:v1".utf8), outLen: 32)
        return pwk
        #else
        throw NSError(domain: "E2EE", code: -100, userInfo: [NSLocalizedDescriptionKey: "Argon2id not available (Sodium missing)"])
        #endif
    }

    // MARK: - Wrap / Unwrap
    func wrapUMKForPassword(umk: Data, password: String, accountId: String?, userId: String?, params: ArgonParams) throws -> Envelope {
        let salt = randomData(count: 16)
        let pwk = try derivePWK(password: password, salt: salt, params: params)
        let wrapIv = randomData(count: 12)
        // AAD aligns with web worker (currently "umk:v1") for interoperability
        let aad = Data("umk:v1".utf8)
        let ct = try aesGcmEncryptRaw(key: pwk, iv: wrapIv, aad: aad, plain: umk)
        let env = Envelope(kdf: "argon2id",
                           salt_b64url: b64url(salt),
                           m: params.m, t: params.t, p: params.p,
                           info: "umk-wrap:v1",
                           wrap_iv_b64url: b64url(wrapIv),
                           umk_wrapped_b64url: b64url(ct),
                           version: 1,
                           accountId: accountId,
                           userId: userId)
        saveEnvelope(env)
        return env
    }

    func unlockWithPassword(password: String, envelope: Envelope) throws -> Bool {
        guard let salt = b64urlDecode(envelope.salt_b64url), let wrapIv = b64urlDecode(envelope.wrap_iv_b64url), let ct = b64urlDecode(envelope.umk_wrapped_b64url) else {
            throw NSError(domain: "E2EE", code: -2, userInfo: [NSLocalizedDescriptionKey: "Bad envelope fields"])
        }
        let pwk = try derivePWK(password: password, salt: salt, params: ArgonParams(m: envelope.m, t: envelope.t, p: envelope.p))
        let aad = Data("umk:v1".utf8)
        let umk = try aesGcmDecryptRaw(key: pwk, iv: wrapIv, aad: aad, ct: ct)
        self.umk = umk
        self.isUnlocked = true
        markUnlockedNow()
        return true
    }

    func unlockWithDeviceKey(prompt: String = "Unlock") -> Bool {
        guard let umk = loadDeviceWrappedUMK(prompt: prompt), umk.count == 32 else { return false }
        self.umk = umk
        self.isUnlocked = true
        markUnlockedNow()
        return true
    }

    // MARK: - Helpers (Crypto)
    private func b64url(_ d: Data) -> String {
        let s = d.base64EncodedString()
        return s.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private func b64urlDecode(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let pad = (4 - (t.count % 4)) % 4
        if pad > 0 { t.append(String(repeating: "=", count: pad)) }
        return Data(base64Encoded: t)
    }
    private func randomData(count: Int) -> Data { var b = Data(count: count); _ = b.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }; return b }
    private func aesGcmEncryptRaw(key: Data, iv: Data, aad: Data, plain: Data) throws -> Data {
        let nonce = try AES.GCM.Nonce(data: iv)
        let sealed = try AES.GCM.seal(plain, using: SymmetricKey(data: key), nonce: nonce, authenticating: aad)
        var out = Data(sealed.ciphertext); out.append(sealed.tag); return out
    }
    private func aesGcmDecryptRaw(key: Data, iv: Data, aad: Data, ct: Data) throws -> Data {
        guard ct.count >= 16 else { throw NSError(domain: "E2EE", code: -3, userInfo: [NSLocalizedDescriptionKey: "GCM ct too short"]) }
        let nonce = try AES.GCM.Nonce(data: iv)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ct.dropLast(16), tag: ct.suffix(16))
        return try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad)
    }

    // RFC5869 HKDF-SHA256
    private struct HMACSHA256Stream {
        private var inner = SHA256()
        private let opad: Data
        init(key: Data) {
            let blockSize = 64
            let k: Data = key.count > blockSize ? Data(SHA256.hash(data: key)) : key
            var keyBlock = k
            if keyBlock.count < blockSize {
                keyBlock.append(Data(repeating: 0, count: blockSize - keyBlock.count))
            }
            var ipad = Data(count: blockSize)
            var opad = Data(count: blockSize)
            for i in 0..<blockSize { ipad[i] = keyBlock[i] ^ 0x36; opad[i] = keyBlock[i] ^ 0x5c }
            self.opad = opad
            inner.update(data: ipad)
        }
        mutating func update(_ data: Data) { inner.update(data: data) }
        mutating func finalize() -> Data {
            let innerDigest = Data(inner.finalize())
            var outer = SHA256()
            outer.update(data: opad)
            outer.update(data: innerDigest)
            return Data(outer.finalize())
        }
    }
    private func hkdfSha256(ikm: Data, info: Data, outLen: Int, salt: Data? = nil) -> Data {
        let saltUse = salt ?? Data(repeating: 0, count: 32)
        var h = HMACSHA256Stream(key: saltUse)
        h.update(ikm)
        let prk = h.finalize()
        var t = Data()
        var okm = Data(capacity: outLen)
        var counter: UInt8 = 1
        while okm.count < outLen {
            var hm = HMACSHA256Stream(key: prk)
            hm.update(t)
            hm.update(info)
            hm.update(Data([counter]))
            t = hm.finalize()
            let need = min(t.count, outLen - okm.count)
            okm.append(t.prefix(need))
            counter &+= 1
        }
        return okm
    }
}
