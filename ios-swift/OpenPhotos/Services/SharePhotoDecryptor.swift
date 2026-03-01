//
//  SharePhotoDecryptor.swift
//  OpenPhotos
//
//  Helper for decrypting locked photos in shares using SMK and DEK wraps.
//

import Foundation
import UIKit

/// Helper class for decrypting locked photos in shares
@MainActor
class SharePhotoDecryptor: ObservableObject {
    private let e2eeManager = ShareE2EEManager.shared
    private let shareService = ShareService.shared

    // Cache of SMK keys per share
    private var smkCache: [String: Data] = [:]

    /// Decrypt thumbnail data for a locked asset
    func decryptThumbnail(shareId: String, assetId: String, encryptedData: Data) async throws -> Data {
        // Get SMK for share
        let smk = try await getSMK(for: shareId)

        // Fetch DEK wrap for thumbnail
        let wraps = try await shareService.fetchWraps(
            shareId: shareId,
            assetIds: [assetId],
            variant: "thumb"
        )

        guard let wrap = wraps.first else {
            throw ShareE2EEError.dekWrapNotFound
        }

        // Decrypt using E2EE manager's worker
        // TODO: Integrate with existing E2EEManager worker
        // For now, return encrypted data (will be implemented in full E2EE integration)
        return encryptedData
    }

    /// Decrypt original image data for a locked asset
    func decryptOriginal(shareId: String, assetId: String, encryptedData: Data) async throws -> Data {
        // Get SMK for share
        let smk = try await getSMK(for: shareId)

        // Fetch DEK wrap for original
        let wraps = try await shareService.fetchWraps(
            shareId: shareId,
            assetIds: [assetId],
            variant: "orig"
        )

        guard let wrap = wraps.first else {
            throw ShareE2EEError.dekWrapNotFound
        }

        // Decrypt using E2EE manager's worker
        // TODO: Integrate with existing E2EEManager worker
        // For now, return encrypted data (will be implemented in full E2EE integration)
        return encryptedData
    }

    /// Get or fetch SMK for a share
    private func getSMK(for shareId: String) async throws -> Data {
        // Check cache first
        if let cached = smkCache[shareId] {
            return cached
        }

        // Ensure identity keypair exists
        _ = try await e2eeManager.ensureIdentityKeyPair()

        // Fetch and unwrap SMK
        let smk = try await e2eeManager.fetchAndUnwrapSMK(shareId: shareId)

        // Cache it
        smkCache[shareId] = smk

        return smk
    }

    /// Check if data appears to be encrypted (PAE3 container)
    func isEncrypted(_ data: Data) -> Bool {
        // Check for PAE3 magic header
        guard data.count >= 5 else { return false }
        let magic = data.prefix(4)
        return magic == Data("PAE3".utf8)
    }

    /// Clear SMK cache for a share
    func clearCache(for shareId: String) {
        smkCache.removeValue(forKey: shareId)
    }

    /// Clear all SMK caches
    func clearAllCaches() {
        smkCache.removeAll()
    }
}

// MARK: - ShareService Extension for Wraps

extension ShareService {
    /// Fetch DEK wraps (convenience wrapper)
    fileprivate func fetchWraps(shareId: String, assetIds: [String], variant: String) async throws -> [DEKWrap] {
        return try await ShareE2EEManager.shared.fetchShareWraps(
            shareId: shareId,
            assetIds: assetIds,
            variant: variant
        )
    }
}
