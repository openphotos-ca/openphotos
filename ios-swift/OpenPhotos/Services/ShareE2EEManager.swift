//
//  ShareE2EEManager.swift
//  OpenPhotos
//
//  Manages end-to-end encryption for sharing locked photos.
//  Handles P-256 identity keypairs, SMK envelopes, and DEK wraps.
//

import Foundation
import CryptoKit
import Security

/// Manager for E2EE operations in sharing
final class ShareE2EEManager {
    static let shared = ShareE2EEManager()
    private let client = AuthorizedHTTPClient.shared

    // Keychain key for storing P-256 identity keypair
    private let identityKeychainKey = "com.openphotos.share.identity.p256"

    // In-memory cache of SMK keys per share
    private var smkCache: [String: Data] = [:]  // shareId -> SMK

    private init() {}

    // MARK: - Identity Key Management (P-256 ECDH)

    /// Ensure identity keypair exists, generate if needed
    func ensureIdentityKeyPair() async throws -> (publicKey: Data, privateKey: SecKey) {
        // Check if keypair exists in Keychain
        if let existing = try? loadIdentityKeyPair() {
            return existing
        }

        // Generate new P-256 keypair
        let privateKey = try generateP256PrivateKey()
        let publicKey = try extractPublicKey(from: privateKey)

        // Save to Keychain
        try saveIdentityKeyPair(privateKey: privateKey)

        // Upload public key to server
        try await uploadPublicKey(publicKey)

        return (publicKey, privateKey)
    }

    /// Generate a new P-256 private key
    private func generateP256PrivateKey() throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw error!.takeRetainedValue() as Error
        }
        return privateKey
    }

    /// Extract public key from private key
    private func extractPublicKey(from privateKey: SecKey) throws -> Data {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw ShareE2EEError.failedToExtractPublicKey
        }
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw error!.takeRetainedValue() as Error
        }
        return data
    }

    /// Save identity keypair to Keychain
    private func saveIdentityKeyPair(privateKey: SecKey) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: identityKeychainKey,
            kSecValueRef as String: privateKey,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    /// Load identity keypair from Keychain
    private func loadIdentityKeyPair() throws -> (publicKey: Data, privateKey: SecKey) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: identityKeychainKey,
            kSecReturnRef as String: true
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let privateKey = item as! SecKey? else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }

        let publicKey = try extractPublicKey(from: privateKey)
        return (publicKey, privateKey)
    }

    /// Upload public key to server
    private func uploadPublicKey(_ publicKey: Data) async throws {
        let url = client.buildURL(path: "/api/ee/e2ee/identity/pubkey")
        let body = ["pubkey_b64": publicKey.base64EncodedString()]

        struct Response: Codable {
            let ok: Bool?
        }

        let _: Response = try await client.post(url: url, body: body)
    }

    // MARK: - SMK Envelope (Recipient)

    /// Fetch and unwrap SMK envelope for a share
    func fetchAndUnwrapSMK(shareId: String) async throws -> Data {
        // Check cache first
        if let cached = smkCache[shareId] {
            return cached
        }

        // Ensure identity keypair exists
        let (_, privateKey) = try await ensureIdentityKeyPair()

        // Fetch envelope from server
        let url = client.buildURL(path: "/api/ee/shares/\(shareId)/e2ee/my-smk-envelope")

        struct EnvelopeResponse: Codable {
            let env: Envelope?

            struct Envelope: Codable {
                let ephemeralPubkeyB64: String
                let ivB64url: String
                let smkWrappedB64url: String
                let tagB64url: String

                enum CodingKeys: String, CodingKey {
                    case ephemeralPubkeyB64 = "ephemeral_pubkey_b64"
                    case ivB64url = "iv_b64url"
                    case smkWrappedB64url = "smk_wrapped_b64url"
                    case tagB64url = "tag_b64url"
                }
            }
        }

        let response: EnvelopeResponse = try await client.get(url: url)
        guard let envelope = response.env else {
            throw ShareE2EEError.smkEnvelopeNotFound
        }

        // Unwrap SMK using ECIES
        let smk = try unwrapSMKWithECIES(
            ephemeralPubKeyB64: envelope.ephemeralPubkeyB64,
            ivB64: envelope.ivB64url,
            smkWrappedB64: envelope.smkWrappedB64url,
            tagB64: envelope.tagB64url,
            privateKey: privateKey
        )

        // Cache for this session
        smkCache[shareId] = smk

        return smk
    }

    /// Unwrap SMK using ECIES (ECDH P-256 + AES-GCM)
    private func unwrapSMKWithECIES(
        ephemeralPubKeyB64: String,
        ivB64: String,
        smkWrappedB64: String,
        tagB64: String,
        privateKey: SecKey
    ) throws -> Data {
        // Decode components
        guard let ephemeralPubKeyData = Data(base64URLEncoded: ephemeralPubKeyB64),
              let iv = Data(base64URLEncoded: ivB64),
              let smkWrapped = Data(base64URLEncoded: smkWrappedB64),
              let tag = Data(base64URLEncoded: tagB64) else {
            throw ShareE2EEError.invalidEnvelopeFormat
        }

        // Import ephemeral public key
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 256
        ]
        var error: Unmanaged<CFError>?
        guard let ephemeralPubKey = SecKeyCreateWithData(ephemeralPubKeyData as CFData, attributes as CFDictionary, &error) else {
            throw error!.takeRetainedValue() as Error
        }

        // Perform ECDH to get shared secret
        guard let sharedSecret = SecKeyCopyKeyExchangeResult(
            privateKey,
            .ecdhKeyExchangeStandard,
            ephemeralPubKey,
            [:] as CFDictionary,
            &error
        ) as Data? else {
            throw error!.takeRetainedValue() as Error
        }

        // Derive encryption key using HKDF
        let kEnv = try hkdf(inputKey: sharedSecret, info: "share:smk:env:v1", outputLength: 32)

        // Decrypt SMK using AES-GCM
        let key = SymmetricKey(data: kEnv)
        let nonce = try AES.GCM.Nonce(data: iv)
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: smkWrapped, tag: tag)
        let smk = try AES.GCM.open(sealedBox, using: key)

        return smk
    }

    // MARK: - DEK Wraps

    /// Fetch DEK wraps for assets in a share
    func fetchShareWraps(shareId: String, assetIds: [String], variant: String = "thumb") async throws -> [DEKWrap] {
        let url = client.buildURL(path: "/api/ee/shares/\(shareId)/e2ee/wraps", queryItems: [
            URLQueryItem(name: "asset_ids", value: assetIds.joined(separator: ",")),
            URLQueryItem(name: "variant", value: variant)
        ])

        struct Response: Codable {
            let items: [WrapItem]

            struct WrapItem: Codable {
                let assetId: String
                let variant: String
                let wrapIvB64: String
                let dekWrappedB64: String
                let encryptedByUserId: String

                enum CodingKeys: String, CodingKey {
                    case assetId = "asset_id"
                    case variant
                    case wrapIvB64 = "wrap_iv_b64"
                    case dekWrappedB64 = "dek_wrapped_b64"
                    case encryptedByUserId = "encrypted_by_user_id"
                }
            }
        }

        let response: Response = try await client.get(url: url)

        return response.items.map { item in
            DEKWrap(
                assetId: item.assetId,
                variant: item.variant,
                wrapIvB64: item.wrapIvB64,
                dekWrappedB64: item.dekWrappedB64,
                encryptedByUserId: item.encryptedByUserId
            )
        }
    }

    /// Upload DEK wraps for assets in a share (owner)
    func uploadShareWraps(shareId: String, wraps: [DEKWrap]) async throws {
        let url = client.buildURL(path: "/api/ee/shares/\(shareId)/e2ee/dek-wraps/batch")

        let items = wraps.map { wrap in
            [
                "asset_id": wrap.assetId,
                "variant": wrap.variant,
                "wrap_iv_b64": wrap.wrapIvB64,
                "dek_wrapped_b64": wrap.dekWrappedB64,
                "encrypted_by_user_id": wrap.encryptedByUserId
            ]
        }

        struct Response: Codable {
            let upserted: Int
        }

        let _: Response = try await client.post(url: url, body: ["items": items])
    }

    // MARK: - Public Link E2EE

    /// Generate SMK and VK for a public link
    func generatePublicLinkKeys() -> (smk: Data, vk: Data) {
        var smk = Data(count: 32)
        var vk = Data(count: 32)
        _ = smk.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        _ = vk.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        return (smk, vk)
    }

    /// Create SMK envelope for a public link
    func createPublicLinkEnvelope(smk: Data, vk: Data) throws -> [String: String] {
        // Derive kEnv = HKDF(vk, info="env:v1")
        let kEnv = try hkdf(inputKey: vk, info: "env:v1", outputLength: 32)

        // Encrypt SMK with AES-GCM
        let key = SymmetricKey(data: kEnv)
        let sealedBox = try AES.GCM.seal(smk, using: key)

        return [
            "iv_b64url": sealedBox.nonce.withUnsafeBytes { Data($0).base64URLEncodedString() },
            "smk_wrapped_b64url": sealedBox.ciphertext.base64URLEncodedString(),
            "tag_b64url": sealedBox.tag.base64URLEncodedString()
        ]
    }

    /// Upload SMK envelope for a public link
    func uploadPublicLinkEnvelope(linkId: String, envelope: [String: String]) async throws {
        let url = client.buildURL(path: "/api/ee/public-links/\(linkId)/e2ee/smk-envelope")

        struct Response: Codable {
            let ok: Bool?
        }

        let _: Response = try await client.post(url: url, body: ["env": envelope])
    }

    /// Upload DEK wraps for a public link
    func uploadPublicLinkWraps(linkId: String, wraps: [DEKWrap]) async throws {
        let url = client.buildURL(path: "/api/ee/public-links/\(linkId)/e2ee/dek-wraps/batch")

        let items = wraps.map { wrap in
            [
                "asset_id": wrap.assetId,
                "variant": wrap.variant,
                "wrap_iv_b64": wrap.wrapIvB64,
                "dek_wrapped_b64": wrap.dekWrappedB64,
                "encrypted_by_user_id": wrap.encryptedByUserId
            ]
        }

        struct Response: Codable {
            let upserted: Int
        }

        let _: Response = try await client.post(url: url, body: ["items": items])
    }

    // MARK: - Utilities

    /// HKDF-SHA256 key derivation
    private func hkdf(inputKey: Data, info: String, outputLength: Int) throws -> Data {
        let salt = Data() // Empty salt
        let infoData = info.data(using: .utf8)!

        // HKDF-Extract
        let prk = HMAC<SHA256>.authenticationCode(for: inputKey, using: SymmetricKey(data: salt))

        // HKDF-Expand
        var okm = Data()
        var counter: UInt8 = 1
        var t = Data()

        while okm.count < outputLength {
            var input = t
            input.append(infoData)
            input.append(counter)
            t = Data(HMAC<SHA256>.authenticationCode(for: input, using: SymmetricKey(data: prk)))
            okm.append(t)
            counter += 1
        }

        return okm.prefix(outputLength)
    }

    /// Clear SMK cache for a share
    func clearSMKCache(shareId: String) {
        smkCache.removeValue(forKey: shareId)
    }

    /// Clear all SMK caches
    func clearAllSMKCaches() {
        smkCache.removeAll()
    }
}

// MARK: - DEK Wrap Model

/// Represents a DEK wrap for decrypting locked assets
struct DEKWrap {
    let assetId: String
    let variant: String  // "orig" or "thumb"
    let wrapIvB64: String
    let dekWrappedB64: String
    let encryptedByUserId: String
}

// MARK: - Errors

enum ShareE2EEError: LocalizedError {
    case failedToExtractPublicKey
    case smkEnvelopeNotFound
    case invalidEnvelopeFormat
    case dekWrapNotFound

    var errorDescription: String? {
        switch self {
        case .failedToExtractPublicKey:
            return "Failed to extract public key from private key"
        case .smkEnvelopeNotFound:
            return "SMK envelope not found for this share"
        case .invalidEnvelopeFormat:
            return "Invalid SMK envelope format"
        case .dekWrapNotFound:
            return "DEK wrap not found for asset"
        }
    }
}

// MARK: - Data Extensions

extension Data {
    /// Base64 URL-safe encoding
    func base64URLEncodedString() -> String {
        return self.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Base64 URL-safe decoding
    init?(base64URLEncoded: String) {
        var base64 = base64URLEncoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        // Add padding if needed
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 = base64.padding(toLength: base64.count + 4 - remainder, withPad: "=", startingAt: 0)
        }

        self.init(base64Encoded: base64)
    }
}
