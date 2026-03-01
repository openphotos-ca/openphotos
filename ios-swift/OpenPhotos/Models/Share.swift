//
//  Share.swift
//  OpenPhotos
//
//  Data models for Enterprise Edition sharing features.
//  Supports account-based shares, public links, comments, likes, and E2EE.
//

import Foundation

// MARK: - Share Models

/// Represents a share of an album or asset with recipients
struct Share: Identifiable, Codable, Hashable {
    let id: String
    let ownerOrgId: Int
    let ownerUserId: String
    let objectKind: ObjectKind
    let objectId: String
    let defaultPermissions: Int
    let expiresAt: Date?
    let status: Status
    let createdAt: Date
    let updatedAt: Date
    let name: String
    let includeFaces: Bool
    let includeSubtree: Bool
    let recipients: [ShareRecipient]

    /// Type of object being shared
    enum ObjectKind: String, Codable {
        case album
        case asset
    }

    /// Share status
    enum Status: String, Codable {
        case active
        case revoked
    }

    enum CodingKeys: String, CodingKey {
        case id
        case ownerOrgId = "owner_org_id"
        case ownerUserId = "owner_user_id"
        case objectKind = "object_kind"
        case objectId = "object_id"
        case defaultPermissions = "default_permissions"
        case expiresAt = "expires_at"
        case status
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case name
        case includeFaces = "include_faces"
        case includeSubtree = "include_subtree"
        case recipients
    }

    /// Check if share is expired
    var isExpired: Bool {
        guard let expiresAt = expiresAt else { return false }
        return expiresAt < Date()
    }

    /// Check if current user is owner
    func isOwner(userId: String) -> Bool {
        return ownerUserId == userId
    }
}

/// Recipient of a share (user, group, or external email)
struct ShareRecipient: Identifiable, Codable, Hashable {
    let id: String
    let recipientType: RecipientType
    let recipientUserId: String?
    let recipientGroupId: Int?
    let externalEmail: String?
    let externalOrgId: Int?
    let permissions: Int?
    let invitationStatus: InvitationStatus
    let createdAt: Date

    /// Type of recipient
    enum RecipientType: String, Codable {
        case user
        case group
        case externalEmail = "external_email"
    }

    /// Invitation status for recipient
    enum InvitationStatus: String, Codable {
        case active
        case pending
        case revoked
    }

    enum CodingKeys: String, CodingKey {
        case id
        case recipientType = "recipient_type"
        case recipientUserId = "recipient_user_id"
        case recipientGroupId = "recipient_group_id"
        case externalEmail = "external_email"
        case externalOrgId = "external_org_id"
        case permissions
        case invitationStatus = "invitation_status"
        case createdAt = "created_at"
    }

    /// Get display label for recipient
    var displayLabel: String {
        switch recipientType {
        case .user:
            return recipientUserId ?? "Unknown User"
        case .group:
            return "Group #\(recipientGroupId ?? 0)"
        case .externalEmail:
            return externalEmail ?? "Unknown Email"
        }
    }

    /// Get recipient identifier (for backwards compatibility with UI code)
    var recipientIdentifier: String {
        return displayLabel
    }
}

/// Public link for URL-based sharing without accounts
struct PublicLink: Identifiable, Codable, Hashable {
    let id: String
    let ownerOrgId: Int?  // Optional - not always returned on creation
    let ownerUserId: String?  // Optional - not always returned on creation
    let name: String
    let scopeKind: String
    let scopeAlbumId: Int?
    let uploadsAlbumId: Int?
    let url: String?
    let permissions: Int
    let expiresAt: Date?
    let status: String?  // Optional - not always returned on creation
    let coverAssetId: String?  // Optional - may be null
    let moderationEnabled: Bool
    let pendingCount: Int?
    let hasPin: Bool?
    let key: String?  // Public link encryption key
    let createdAt: Date?  // Optional - not always returned on creation
    let updatedAt: Date?  // Optional - not always returned on creation

    enum CodingKeys: String, CodingKey {
        case id
        case ownerOrgId = "owner_org_id"
        case ownerUserId = "owner_user_id"
        case name
        case scopeKind = "scope_kind"
        case scopeAlbumId = "scope_album_id"
        case uploadsAlbumId = "uploads_album_id"
        case url
        case permissions
        case expiresAt = "expires_at"
        case status
        case coverAssetId = "cover_asset_id"
        case moderationEnabled = "moderation_enabled"
        case pendingCount = "pending_count"
        case hasPin = "has_pin"
        case key
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    /// Check if link is expired
    var isExpired: Bool {
        guard let expiresAt = expiresAt else { return false }
        return expiresAt < Date()
    }

    /// Check if link is active
    var isActive: Bool {
        return (status ?? "active") == "active" && !isExpired
    }
}

// MARK: - Permissions

/// Permission bitflags for share access control
struct SharePermissions: Hashable, Equatable {
    static let VIEW: Int = 1 << 0      // 1 - View metadata and media
    static let COMMENT: Int = 1 << 1   // 2 - Create/delete comments
    static let LIKE: Int = 1 << 2      // 4 - Like/unlike assets
    static let UPLOAD: Int = 1 << 3    // 8 - Contributor uploads

    let rawValue: Int

    /// Check if has view permission
    var canView: Bool { rawValue & SharePermissions.VIEW != 0 }

    /// Check if has comment permission
    var canComment: Bool { rawValue & SharePermissions.COMMENT != 0 }

    /// Check if has like permission
    var canLike: Bool { rawValue & SharePermissions.LIKE != 0 }

    /// Check if has upload permission
    var canUpload: Bool { rawValue & SharePermissions.UPLOAD != 0 }

    /// Individual permissions as instances
    static let view = SharePermissions(rawValue: VIEW)
    static let comment = SharePermissions(rawValue: COMMENT)
    static let like = SharePermissions(rawValue: LIKE)
    static let upload = SharePermissions(rawValue: UPLOAD)

    /// Viewer role (view only)
    static let viewer = SharePermissions(rawValue: VIEW)

    /// Commenter role (view, comment, like)
    static let commenter = SharePermissions(rawValue: VIEW | COMMENT | LIKE)

    /// Contributor role (all permissions)
    static let contributor = SharePermissions(rawValue: VIEW | COMMENT | LIKE | UPLOAD)

    /// Get role name for display
    var roleName: String {
        if rawValue == SharePermissions.contributor.rawValue { return "Contributor" }
        if rawValue == SharePermissions.commenter.rawValue { return "Commenter" }
        if rawValue == SharePermissions.viewer.rawValue { return "Viewer" }
        return "Custom"
    }
}

// MARK: - Comments & Likes

/// Comment on a shared asset
struct ShareComment: Identifiable, Codable, Hashable {
    let id: String
    let authorDisplayName: String
    let authorUserId: String?
    let viewerSessionId: String?
    let body: String
    let createdAt: Int64

    enum CodingKeys: String, CodingKey {
        case id
        case authorDisplayName = "author_display_name"
        case authorUserId = "author_user_id"
        case viewerSessionId = "viewer_session_id"
        case body
        case createdAt = "created_at"
    }

    /// Get formatted date
    var date: Date {
        return Date(timeIntervalSince1970: TimeInterval(createdAt))
    }

    /// Check if current user is author
    func isAuthor(userId: String) -> Bool {
        return authorUserId == userId
    }
}

/// Like count for a shared asset
struct ShareLikeCount: Codable, Hashable {
    let assetId: String
    let count: Int
    let likedByMe: Bool

    enum CodingKeys: String, CodingKey {
        case assetId = "asset_id"
        case count
        case likedByMe = "liked_by_me"
    }
}

// MARK: - Faces

/// Face/person in a share with asset count
struct ShareFace: Identifiable, Codable, Hashable {
    let personId: String
    let displayName: String?
    let count: Int

    var id: String { personId }

    enum CodingKeys: String, CodingKey {
        case personId = "person_id"
        case displayName = "display_name"
        case count
    }

    /// Get display label
    var label: String {
        return displayName ?? "Person \(personId)"
    }
}

// MARK: - Response Models

/// Response for share assets list
struct ShareAssetsResponse: Codable {
    let assetIds: [String]
    let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case assetIds = "asset_ids"
        case hasMore = "has_more"
    }
}

/// Response for face-filtered assets
struct ShareFaceAssetsResponse: Codable {
    let assetIds: [String]

    enum CodingKeys: String, CodingKey {
        case assetIds = "asset_ids"
    }
}

/// Metadata for a shared asset
struct ShareAssetMetadata: Codable {
    let assetId: String
    let filename: String
    let mimeType: String?
    let width: Int?
    let height: Int?
    let createdAt: Int64
    let favorites: Int
    let isVideo: Bool
    let isLivePhoto: Bool

    enum CodingKeys: String, CodingKey {
        case assetId = "asset_id"
        case filename
        case mimeType = "mime_type"
        case width
        case height
        case createdAt = "created_at"
        case favorites
        case isVideo = "is_video"
        case isLivePhoto = "is_live_photo"
    }
}

// MARK: - Request Models

/// Request to create a new share
struct CreateShareRequest: Codable {
    let object: ShareObject
    let name: String
    let defaultPermissions: Int?
    let expiresAt: String?
    let includeFaces: Bool?
    let includeSubtree: Bool?
    let recipients: [RecipientInput]?

    /// Object being shared
    struct ShareObject: Codable {
        let kind: String  // "album" or "asset"
        let id: String
    }

    /// Recipient to add to share
    struct RecipientInput: Codable {
        let type: String  // "user", "group", or "external_email"
        let id: String?
        let email: String?
        let permissions: Int?
    }

    enum CodingKeys: String, CodingKey {
        case object
        case name
        case defaultPermissions = "default_permissions"
        case expiresAt = "expires_at"
        case includeFaces = "include_faces"
        case includeSubtree = "include_subtree"
        case recipients
    }
}

/// Request to update an existing share
struct UpdateShareRequest: Codable {
    let name: String?
    let defaultPermissions: Int?
    let expiresAt: String?
    let includeFaces: Bool?

    enum CodingKeys: String, CodingKey {
        case name
        case defaultPermissions = "default_permissions"
        case expiresAt = "expires_at"
        case includeFaces = "include_faces"
    }
}

/// Request to add recipients to a share
struct AddRecipientsRequest: Codable {
    let recipients: [CreateShareRequest.RecipientInput]
}

/// Request to create a public link
struct CreatePublicLinkRequest: Codable {
    let name: String
    let scopeKind: String  // "album" or "upload_only"
    let scopeAlbumId: Int?
    let permissions: Int
    let expiresAt: String?
    let pin: String?
    let coverAssetId: String
    let moderationEnabled: Bool?

    enum CodingKeys: String, CodingKey {
        case name
        case scopeKind = "scope_kind"
        case scopeAlbumId = "scope_album_id"
        case permissions
        case expiresAt = "expires_at"
        case pin
        case coverAssetId = "cover_asset_id"
        case moderationEnabled = "moderation_enabled"
    }
}

/// Request to update a public link
struct UpdatePublicLinkRequest: Codable {
    let name: String?
    let permissions: Int?
    let expiresAt: String?
    let coverAssetId: String?
    let pin: String?
    let clearPin: Bool?
    let moderationEnabled: Bool?

    enum CodingKeys: String, CodingKey {
        case name
        case permissions
        case expiresAt = "expires_at"
        case coverAssetId = "cover_asset_id"
        case pin
        case clearPin = "clear_pin"
        case moderationEnabled = "moderation_enabled"
    }
}

/// Request to toggle like on an asset
struct ToggleLikeRequest: Codable {
    let assetId: String
    let like: Bool

    enum CodingKeys: String, CodingKey {
        case assetId = "asset_id"
        case like
    }
}

/// Request to create a comment
struct CreateCommentRequest: Codable {
    let assetId: String
    let body: String

    enum CodingKeys: String, CodingKey {
        case assetId = "asset_id"
        case body
    }
}

/// Request to import assets from share
struct ImportAssetsRequest: Codable {
    let assetIds: [String]

    enum CodingKeys: String, CodingKey {
        case assetIds = "asset_ids"
    }
}

// MARK: - Share Targets

/// Represents a user or group that can be added as a share recipient
/// Returned by the /api/ee/share-targets endpoint for recipient selection
struct ShareTarget: Identifiable, Codable, Hashable {
    /// Type of target: "user" or "group"
    let kind: String

    /// User ID or group ID (optional for external emails)
    let id: String?

    /// Display label (name of user/group)
    let label: String

    /// Email address (for users only)
    let email: String?

    /// Display name for UI (returns label)
    var displayName: String {
        return label
    }

    /// Icon name for SF Symbols based on kind
    var iconName: String {
        switch kind {
        case "group":
            return "person.3.fill"
        case "user":
            return "person.fill"
        default:
            return "person.crop.circle"
        }
    }
}
