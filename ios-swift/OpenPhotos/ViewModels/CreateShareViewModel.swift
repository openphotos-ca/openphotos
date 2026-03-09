//
//  CreateShareViewModel.swift
//  OpenPhotos
//
//  View model for creating and editing shares.
//

import Foundation
import SwiftUI

/// View model for share creation and editing
@MainActor
class CreateShareViewModel: ObservableObject {
    // MARK: - Tab Selection

    /// Currently active tab
    @Published var selectedTab: ShareTab = .internal

    /// Available tabs
    enum ShareTab: String, CaseIterable {
        case `internal` = "Internal"
        case publicLink = "Public Link"
    }

    // MARK: - Common Fields

    /// Share name
    @Published var shareName = ""

    // MARK: - Internal Share Fields

    @Published var recipients: [RecipientInput] = []
    @Published var permissions: SharePermissions = .commenter
    @Published var expiryDate: Date?
    @Published var hasExpiry = false
    @Published var includeFaces = true

    // MARK: - Public Link Fields

    /// Share mode: selection vs first item
    @Published var pubShareSelection = true

    /// Number of items in selection
    @Published var selectionCount: Int = 1

    /// Enable content moderation
    @Published var pubModeration = false

    /// Role/permission level
    @Published var pubRole: SharePermissions = .viewer

    /// Whether to set an expiry date
    @Published var pubHasExpiry = false

    /// Expiry date for public link (only used if pubHasExpiry is true)
    @Published var pubExpiryDate: Date = Date().addingTimeInterval(86400 * 7)

    /// Require PIN for access
    @Published var pubRequirePin = false

    /// PIN value (8 characters)
    @Published var pubPin = ""

    /// Cover asset ID
    @Published var pubCoverAssetId: String? = nil

    /// Show cover picker sheet
    @Published var showCoverPicker = false

    // MARK: - UI State

    @Published var isCreating = false
    @Published var error: String?

    // MARK: - Context

    let objectKind: Share.ObjectKind
    let objectId: String
    let objectName: String?

    private let shareService = ShareService.shared
    private let photosService = ServerPhotosService.shared
    private let shareE2EEManager = ShareE2EEManager.shared

    init(objectKind: Share.ObjectKind, objectId: String, objectName: String? = nil, selectionCount: Int = 1) {
        self.objectKind = objectKind
        self.objectId = objectId
        self.objectName = objectName
        self.selectionCount = selectionCount
    }

    // MARK: - Recipient Management

    /// Add a recipient
    func addRecipient(type: RecipientInput.RecipientType, identifier: String, displayName: String) {
        let recipient = RecipientInput(type: type, identifier: identifier, displayName: displayName)
        if !recipients.contains(where: { $0.identifier == identifier && $0.type == type }) {
            recipients.append(recipient)
        }
    }

    /// Remove a recipient
    func removeRecipient(_ recipient: RecipientInput) {
        recipients.removeAll { $0.id == recipient.id }
    }

    // MARK: - Validation

    /// Check if can create share
    var canCreate: Bool {
        // Name must not be empty
        guard !shareName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        // Not already creating
        guard !isCreating else {
            return false
        }

        // Tab-specific validation
        if selectedTab == .internal {
            // Internal shares require at least one recipient
            return !recipients.isEmpty
        } else {
            // Public link validation
            if pubRequirePin {
                // PIN must be exactly 8 characters
                return pubPin.count == 8
            }
            return true
        }
    }

    /// Button title based on selected tab
    var createButtonTitle: String {
        selectedTab == .internal ? "Create" : "Create Link"
    }

    // MARK: - Create Share

    /// Create the share based on selected tab
    func createShare() async throws {
        guard canCreate else { return }

        if selectedTab == .internal {
            try await createInternalShare()
        } else {
            try await createPublicLink()
        }
    }

    /// Create an internal share with recipients
    private func createInternalShare() async throws {
        isCreating = true
        error = nil

        defer { isCreating = false }

        do {
            // Build recipients array
            let shareRecipients = recipients.map { input in
                CreateShareRequest.RecipientInput(
                    type: input.type.rawValue,
                    id: input.identifier,
                    email: nil,
                    permissions: nil
                )
            }

            // Build request
            let request = CreateShareRequest(
                object: CreateShareRequest.ShareObject(
                    kind: objectKind.rawValue,
                    id: objectId
                ),
                name: shareName,
                defaultPermissions: permissions.rawValue,
                expiresAt: hasExpiry ? expiryDate?.ISO8601Format() : nil,
                includeFaces: includeFaces,
                includeSubtree: false,
                recipients: shareRecipients
            )

            // Call API
            let share = try await runWithTransientRetry(label: "create-share") {
                try await self.shareService.createShare(request)
            }

            // If this share contains locked assets, publish share E2EE material (envelopes + wraps)
            // so recipients can render locked thumbnails immediately.
            do {
                try await shareE2EEManager.prepareOwnerShareE2EEIfNeeded(share: share)
            } catch {
                print("[SHARE-E2EE] prep failed share=\(share.id) err=\(error.localizedDescription)")
            }
        } catch {
            self.error = error.localizedDescription
            throw error
        }
    }

    /// Create a public link
    private func createPublicLink() async throws {
        isCreating = true
        error = nil

        defer { isCreating = false }

        do {
            // Calculate permissions
            var permissionValue = SharePermissions.VIEW
            if pubRole == .commenter {
                permissionValue |= SharePermissions.COMMENT | SharePermissions.LIKE
            } else if pubRole == .contributor {
                permissionValue |= SharePermissions.COMMENT | SharePermissions.LIKE | SharePermissions.UPLOAD
            }

            let resolved = try await resolvePublicLinkScope()

            // Build request
            let request = CreatePublicLinkRequest(
                name: shareName,
                scopeKind: resolved.scopeKind,
                scopeAlbumId: resolved.scopeAlbumId,
                permissions: permissionValue,
                expiresAt: pubHasExpiry ? pubExpiryDate.ISO8601Format() : nil,
                pin: pubRequirePin ? pubPin : nil,
                coverAssetId: resolved.coverAssetId,
                moderationEnabled: pubModeration
            )

            // Call API
            _ = try await runWithTransientRetry(label: "create-public-link") {
                try await self.shareService.createPublicLink(request)
            }
        } catch {
            self.error = error.localizedDescription
            throw error
        }
    }

    /// Public links only support `album` / `upload_only` scopes on backend.
    /// For single-asset shares, auto-create a one-item album and link to that album.
    private func resolvePublicLinkScope() async throws -> (scopeKind: String, scopeAlbumId: Int?, coverAssetId: String) {
        if objectKind == .album {
            guard let albumId = Int(objectId) else {
                throw NSError(
                    domain: "CreateShareViewModel",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid album id for public link"]
                )
            }
            return ("album", albumId, pubCoverAssetId ?? "default")
        }

        let title = shareName.trimmingCharacters(in: .whitespacesAndNewlines)
        let albumName = title.isEmpty ? "Shared Photo" : title
        let album = try await runWithTransientRetry(label: "create-public-link-album") {
            try await self.photosService.createAlbum(
                name: albumName,
                description: "Auto-created for public link"
            )
        }
        try await runWithTransientRetry(label: "add-public-link-photo-to-album") {
            try await self.photosService.addPhotosToAlbum(albumId: album.id, assetIds: [self.objectId])
            return ()
        }
        return ("album", album.id, pubCoverAssetId ?? objectId)
    }

    private func runWithTransientRetry<T>(label: String, operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch {
            guard isTransientNetworkError(error) else {
                throw error
            }
            let ns = error as NSError
            print("[SHARE] \(label) transient failure code=\(ns.code) domain=\(ns.domain) retry=1")
            try await Task.sleep(nanoseconds: 400_000_000)
            return try await operation()
        }
    }

    private func isTransientNetworkError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorTimedOut,
                NSURLErrorCannotFindHost,
                NSURLErrorCannotConnectToHost,
                NSURLErrorNetworkConnectionLost,
                NSURLErrorNotConnectedToInternet,
                NSURLErrorDNSLookupFailed:
                return true
            default:
                break
            }
        }

        let text = ns.localizedDescription.lowercased()
        return text.contains("network connection was lost")
            || text.contains("timed out")
            || text.contains("not connected to internet")
            || text.contains("cannot connect to host")
    }
}

/// Recipient input for UI
struct RecipientInput: Identifiable, Equatable {
    let id = UUID()
    let type: RecipientType
    let identifier: String
    let displayName: String

    enum RecipientType: String, CaseIterable {
        case user = "user"
        case group = "group"

        var typeLabel: String {
            switch self {
            case .user: return "User"
            case .group: return "Group"
            }
        }
    }
}
