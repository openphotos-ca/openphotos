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
    private let photosService = ServerPhotosService.shared

    // Keychain key for storing P-256 identity keypair
    private let identityKeychainKey = "com.openphotos.share.identity.p256"

    // In-memory cache of SMK keys per share
    private var smkCache: [String: Data] = [:]  // shareId -> SMK

    private let wrapUploadChunkSize = 200
    private let lockedQueryPageSize = 200

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
                let smkHex: String?
                let ephemeralPubkeyB64: String?
                let epkB64url: String?
                let ivB64url: String?
                let smkWrappedB64url: String?
                let tagB64url: String?
                let ctB64url: String?

                enum CodingKeys: String, CodingKey {
                    case smkHex = "smk_hex"
                    case ephemeralPubkeyB64 = "ephemeral_pubkey_b64"
                    case epkB64url = "epk_b64url"
                    case ivB64url = "iv_b64url"
                    case smkWrappedB64url = "smk_wrapped_b64url"
                    case tagB64url = "tag_b64url"
                    case ctB64url = "ct_b64url"
                }
            }
        }

        let response: EnvelopeResponse = try await client.get(url: url)
        guard let envelope = response.env else {
            throw ShareE2EEError.smkEnvelopeNotFound
        }

        if let smkHex = envelope.smkHex,
           let smk = Data(hexString: smkHex),
           smk.count == 32 {
            smkCache[shareId] = smk
            return smk
        }

        guard let ephemeralPubKeyB64 = envelope.ephemeralPubkeyB64 ?? envelope.epkB64url,
              let ivB64 = envelope.ivB64url else {
            throw ShareE2EEError.invalidEnvelopeFormat
        }

        let smkWrappedB64: String
        let tagB64: String
        if let ctB64 = envelope.ctB64url,
           let combined = Data(base64URLEncoded: ctB64),
           combined.count > 16 {
            smkWrappedB64 = combined.dropLast(16).base64URLEncodedString()
            tagB64 = combined.suffix(16).base64URLEncodedString()
        } else {
            guard let wrapped = envelope.smkWrappedB64url,
                  let tag = envelope.tagB64url else {
                throw ShareE2EEError.invalidEnvelopeFormat
            }
            smkWrappedB64 = wrapped
            tagB64 = tag
        }

        // Unwrap SMK using ECIES
        let smk = try unwrapSMKWithECIES(
            ephemeralPubKeyB64: ephemeralPubKeyB64,
            ivB64: ivB64,
            smkWrappedB64: smkWrappedB64,
            tagB64: tagB64,
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

    /// Prepare account-share E2EE material (recipient envelopes + DEK wraps) for locked assets.
    /// This is the iOS equivalent of the web owner's auto-prepare path.
    func prepareOwnerShareE2EEIfNeeded(share: Share) async throws {
        let lockedAssetIds = try await collectLockedAssetIds(for: share)
        guard !lockedAssetIds.isEmpty else {
            print("[SHARE-E2EE] prep-skip share=\(share.id) reason=no-locked-assets")
            return
        }
        guard let umk = E2EEManager.shared.umk, umk.count == 32 else {
            print("[SHARE-E2EE] prep-failed share=\(share.id) reason=umk-unavailable")
            throw ShareE2EEError.umkUnavailable
        }

        let recipientUserIds = recipientUserIds(from: share)
        guard !recipientUserIds.isEmpty else {
            print("[SHARE-E2EE] prep-skip share=\(share.id) reason=no-recipients")
            return
        }

        print("[SHARE-E2EE] prep-start share=\(share.id) locked_assets=\(lockedAssetIds.count) recipients=\(recipientUserIds.count)")

        _ = try await ensureIdentityKeyPair()

        let smk = try randomData(count: 32)
        try await uploadRecipientEnvelopesForShare(
            shareId: share.id,
            recipientUserIds: recipientUserIds,
            smk: smk
        )
        try await uploadShareWrapsFromLockedAssets(
            shareId: share.id,
            ownerUserId: share.ownerUserId,
            assetIds: lockedAssetIds,
            umk: umk,
            smk: smk
        )

        smkCache[share.id] = smk
        print("[SHARE-E2EE] prep-done share=\(share.id)")
    }

    private func collectLockedAssetIds(for share: Share) async throws -> [String] {
        switch share.objectKind {
        case .asset:
            let rows = try await photosService.getPhotosByAssetIds([share.objectId], includeLocked: true)
            return rows.filter { $0.locked == true }.map { $0.asset_id }
        case .album:
            guard let albumId = Int(share.objectId) else {
                return []
            }
            var allAssetIds: [String] = []
            var page = 1
            while true {
                var q = ServerPhotoListQuery()
                q.album_id = albumId
                q.album_subtree = share.includeSubtree
                q.include_locked = true
                q.filter_locked_only = true
                q.page = page
                q.limit = lockedQueryPageSize
                let response = try await photosService.listPhotos(query: q)
                allAssetIds.append(contentsOf: response.photos.map { $0.asset_id })
                if !response.has_more || response.photos.isEmpty {
                    break
                }
                page += 1
            }
            var seen = Set<String>()
            return allAssetIds.filter { seen.insert($0).inserted }
        }
    }

    private func recipientUserIds(from share: Share) -> [String] {
        var ids = Set<String>()
        ids.insert(share.ownerUserId)
        for recipient in share.recipients where recipient.recipientType == .user {
            guard recipient.invitationStatus != .revoked else { continue }
            if let id = recipient.recipientUserId, !id.isEmpty {
                ids.insert(id)
            }
        }
        return Array(ids)
    }

    private struct RecipientPubKeyResponse: Decodable {
        let pubkeyB64: String?

        enum CodingKeys: String, CodingKey {
            case pubkeyB64 = "pubkey_b64"
        }
    }

    private struct ShareRecipientEnvelopeUploadItem: Encodable {
        let recipient_user_id: String
        let env: [String: String]
    }

    private struct ShareRecipientEnvelopeBatchRequest: Encodable {
        let items: [ShareRecipientEnvelopeUploadItem]
    }

    private struct SimpleOkResponse: Decodable {
        let ok: Bool?
        let upserted: Int?
    }

    private func uploadRecipientEnvelopesForShare(
        shareId: String,
        recipientUserIds: [String],
        smk: Data
    ) async throws {
        var items: [ShareRecipientEnvelopeUploadItem] = []
        for userId in recipientUserIds {
            if let recipientPubKey = try await fetchRecipientPublicKey(userId: userId) {
                let env = try makeRecipientEnvelope(recipientPublicKeyRaw: recipientPubKey, smk: smk)
                items.append(ShareRecipientEnvelopeUploadItem(recipient_user_id: userId, env: env))
            } else {
                // Dev-safe fallback that matches current web behavior when recipient key is unavailable.
                items.append(ShareRecipientEnvelopeUploadItem(
                    recipient_user_id: userId,
                    env: ["smk_hex": smk.hexString]
                ))
            }
        }
        guard !items.isEmpty else { return }
        let url = client.buildURL(path: "/api/ee/shares/\(shareId)/e2ee/recipient-envelopes")
        let _: SimpleOkResponse = try await client.post(
            url: url,
            body: ShareRecipientEnvelopeBatchRequest(items: items)
        )
        print("[SHARE-E2EE] envelopes-upserted share=\(shareId) count=\(items.count)")
    }

    private func fetchRecipientPublicKey(userId: String) async throws -> Data? {
        let url = client.buildURL(path: "/api/ee/e2ee/identity/pubkey/\(userId)")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        let (data, http) = try await client.request(req)
        if http.statusCode == 404 {
            return nil
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "HTTP", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: body])
        }
        let decoded = try JSONDecoder().decode(RecipientPubKeyResponse.self, from: data)
        guard let keyB64 = decoded.pubkeyB64,
              let keyData = Data(base64Encoded: keyB64),
              keyData.count == 65 else {
            return nil
        }
        return keyData
    }

    private func makeRecipientEnvelope(recipientPublicKeyRaw: Data, smk: Data) throws -> [String: String] {
        let ephemeralPrivate = try generateP256PrivateKey()
        let ephemeralPublicRaw = try extractPublicKey(from: ephemeralPrivate)

        let pubAttrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 256
        ]
        var error: Unmanaged<CFError>?
        guard let recipientPubKey = SecKeyCreateWithData(
            recipientPublicKeyRaw as CFData,
            pubAttrs as CFDictionary,
            &error
        ) else {
            throw error!.takeRetainedValue() as Error
        }

        guard let sharedSecret = SecKeyCopyKeyExchangeResult(
            ephemeralPrivate,
            .ecdhKeyExchangeStandard,
            recipientPubKey,
            [:] as CFDictionary,
            &error
        ) as Data? else {
            throw error!.takeRetainedValue() as Error
        }

        let kEnv = try hkdf(inputKey: sharedSecret, info: "share:smk:env:v1", outputLength: 32)
        let iv = try randomData(count: 12)
        let key = SymmetricKey(data: kEnv)
        let nonce = try AES.GCM.Nonce(data: iv)
        let sealed = try AES.GCM.seal(smk, using: key, nonce: nonce)
        var combined = Data(sealed.ciphertext)
        combined.append(sealed.tag)
        return [
            "alg": "ECIES-P256-AESGCM",
            "ephemeral_pubkey_b64": ephemeralPublicRaw.base64URLEncodedString(),
            "epk_b64url": ephemeralPublicRaw.base64URLEncodedString(),
            "iv_b64url": iv.base64URLEncodedString(),
            "smk_wrapped_b64url": sealed.ciphertext.base64URLEncodedString(),
            "tag_b64url": sealed.tag.base64URLEncodedString(),
            "ct_b64url": combined.base64URLEncodedString()
        ]
    }

    private func uploadShareWrapsFromLockedAssets(
        shareId: String,
        ownerUserId: String,
        assetIds: [String],
        umk: Data,
        smk: Data
    ) async throws {
        var thumbUploaded = 0
        var origUploaded = 0

        thumbUploaded = try await uploadVariantWraps(
            shareId: shareId,
            ownerUserId: ownerUserId,
            assetIds: assetIds,
            variant: "thumb",
            umk: umk,
            smk: smk
        )

        origUploaded = try await uploadVariantWraps(
            shareId: shareId,
            ownerUserId: ownerUserId,
            assetIds: assetIds,
            variant: "orig",
            umk: umk,
            smk: smk
        )

        print("[SHARE-E2EE] wraps-upserted share=\(shareId) thumb=\(thumbUploaded) orig=\(origUploaded)")
    }

    private func uploadVariantWraps(
        shareId: String,
        ownerUserId: String,
        assetIds: [String],
        variant: String,
        umk: Data,
        smk: Data
    ) async throws -> Int {
        var wrapsBatch: [DEKWrap] = []
        var totalUploaded = 0

        for assetId in assetIds {
            do {
                let container = try await fetchLockedContainer(assetId: assetId, variant: variant)
                let (wrapIvB64, dekWrappedB64) = try rekeyWrapForShare(
                    containerData: container,
                    umk: umk,
                    smk: smk
                )
                wrapsBatch.append(DEKWrap(
                    assetId: assetId,
                    variant: variant,
                    wrapIvB64: wrapIvB64,
                    dekWrappedB64: dekWrappedB64,
                    encryptedByUserId: ownerUserId
                ))
                if wrapsBatch.count >= wrapUploadChunkSize {
                    try await uploadShareWraps(shareId: shareId, wraps: wrapsBatch)
                    totalUploaded += wrapsBatch.count
                    wrapsBatch.removeAll(keepingCapacity: true)
                }
            } catch {
                print("[SHARE-E2EE] wrap-skip share=\(shareId) variant=\(variant) asset=\(assetId) err=\(error.localizedDescription)")
            }
        }

        if !wrapsBatch.isEmpty {
            try await uploadShareWraps(shareId: shareId, wraps: wrapsBatch)
            totalUploaded += wrapsBatch.count
        }
        return totalUploaded
    }

    private func fetchLockedContainer(assetId: String, variant: String) async throws -> Data {
        let encodedId = assetId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? assetId
        let path: String = variant == "thumb" ? "/api/thumbnails/\(encodedId)" : "/api/images/\(encodedId)"
        let url = client.buildURL(path: path)
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        let (data, http) = try await client.request(req)
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "HTTP", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: body])
        }
        return data
    }

    private struct PAE3OuterHeader: Decodable {
        let v: Int
        let asset_id: String
        let wrap_iv: String
        let dek_wrapped: String
    }

    private func rekeyWrapForShare(
        containerData: Data,
        umk: Data,
        smk: Data
    ) throws -> (wrapIvB64: String, dekWrappedB64: String) {
        guard containerData.count >= 10 else {
            throw ShareE2EEError.invalidLockedContainer
        }
        let magic = containerData.prefix(4)
        guard magic == Data("PAE3".utf8) else {
            throw ShareE2EEError.invalidLockedContainer
        }
        let version = containerData[4]
        guard version == 0x03 else {
            throw ShareE2EEError.invalidLockedContainer
        }

        let headerLen = Int(
            (UInt32(containerData[6]) << 24)
                | (UInt32(containerData[7]) << 16)
                | (UInt32(containerData[8]) << 8)
                | UInt32(containerData[9])
        )
        guard headerLen > 0, containerData.count >= 10 + headerLen else {
            throw ShareE2EEError.invalidLockedContainer
        }

        let headerBytes = containerData.subdata(in: 10..<(10 + headerLen))
        let header = try JSONDecoder().decode(PAE3OuterHeader.self, from: headerBytes)
        guard header.v == 3,
              let assetId = Data(base64URLEncoded: header.asset_id),
              assetId.count == 16,
              let oldWrapIv = Data(base64URLEncoded: header.wrap_iv),
              oldWrapIv.count == 12,
              let oldDekWrapped = Data(base64URLEncoded: header.dek_wrapped),
              oldDekWrapped.count > 16 else {
            throw ShareE2EEError.invalidLockedContainer
        }

        let aadWrap = Data("wrap:v3".utf8) + assetId
        let oldWrapKey = try hkdf(inputKey: umk, info: "hkdf:wrap:v3", outputLength: 32)
        let dek = try decryptAESGCMCombined(
            key: oldWrapKey,
            iv: oldWrapIv,
            aad: aadWrap,
            ciphertextAndTag: oldDekWrapped
        )

        let newWrapIv = try randomData(count: 12)
        let newWrapKey = try hkdf(inputKey: smk, info: "hkdf:wrap:v3", outputLength: 32)
        let newDekWrapped = try encryptAESGCMCombined(
            key: newWrapKey,
            iv: newWrapIv,
            aad: aadWrap,
            plaintext: dek
        )
        return (
            wrapIvB64: newWrapIv.base64URLEncodedString(),
            dekWrappedB64: newDekWrapped.base64URLEncodedString()
        )
    }

    private func decryptAESGCMCombined(
        key: Data,
        iv: Data,
        aad: Data,
        ciphertextAndTag: Data
    ) throws -> Data {
        guard ciphertextAndTag.count > 16 else {
            throw ShareE2EEError.invalidLockedContainer
        }
        let ciphertext = ciphertextAndTag.dropLast(16)
        let tag = ciphertextAndTag.suffix(16)
        let nonce = try AES.GCM.Nonce(data: iv)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        return try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad)
    }

    private func encryptAESGCMCombined(
        key: Data,
        iv: Data,
        aad: Data,
        plaintext: Data
    ) throws -> Data {
        let nonce = try AES.GCM.Nonce(data: iv)
        let sealed = try AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: key),
            nonce: nonce,
            authenticating: aad
        )
        var out = Data(sealed.ciphertext)
        out.append(sealed.tag)
        return out
    }

    private func randomData(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return data
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
    case umkUnavailable
    case invalidLockedContainer

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
        case .umkUnavailable:
            return "Unlock is required before sharing locked photos"
        case .invalidLockedContainer:
            return "Invalid locked container format"
        }
    }
}

// MARK: - Data Extensions

extension Data {
    /// Hex string (lowercase, no prefix)
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    /// Hex decoding
    init?(hexString: String) {
        let hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var idx = hex.startIndex
        for _ in 0..<(hex.count / 2) {
            let next = hex.index(idx, offsetBy: 2)
            guard let byte = UInt8(hex[idx..<next], radix: 16) else {
                return nil
            }
            data.append(byte)
            idx = next
        }
        self = data
    }

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
