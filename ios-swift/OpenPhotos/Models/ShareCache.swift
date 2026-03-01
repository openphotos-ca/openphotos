//
//  ShareCache.swift
//  OpenPhotos
//
//  SwiftData models for offline caching of shares, public links, and related data.
//

import Foundation
import SwiftData

// MARK: - Cached Share

/// SwiftData model for caching share metadata offline
@Model
final class CachedShare {
    @Attribute(.unique) var id: String
    var ownerUserId: String
    var objectKind: String
    var objectId: String
    var name: String
    var defaultPermissions: Int
    var expiresAt: Date?
    var status: String
    var includeFaces: Bool
    var createdAt: Date
    var updatedAt: Date
    var cachedAt: Date

    @Relationship(deleteRule: .cascade) var recipients: [CachedRecipient] = []
    @Relationship(deleteRule: .cascade) var assets: [CachedShareAsset] = []

    init(from share: Share) {
        self.id = share.id
        self.ownerUserId = share.ownerUserId
        self.objectKind = share.objectKind.rawValue
        self.objectId = share.objectId
        self.name = share.name
        self.defaultPermissions = share.defaultPermissions
        self.expiresAt = share.expiresAt
        self.status = share.status.rawValue
        self.includeFaces = share.includeFaces
        self.createdAt = share.createdAt
        self.updatedAt = share.updatedAt
        self.cachedAt = Date()
        self.recipients = share.recipients.map { CachedRecipient(from: $0) }
    }

    /// Convert back to Share model
    func toShare() -> Share {
        return Share(
            id: id,
            ownerOrgId: 0, // Not cached
            ownerUserId: ownerUserId,
            objectKind: Share.ObjectKind(rawValue: objectKind) ?? .album,
            objectId: objectId,
            defaultPermissions: defaultPermissions,
            expiresAt: expiresAt,
            status: Share.Status(rawValue: status) ?? .active,
            createdAt: createdAt,
            updatedAt: updatedAt,
            name: name,
            includeFaces: includeFaces,
            includeSubtree: false,
            recipients: recipients.map { $0.toShareRecipient() }
        )
    }

    /// Check if cache is stale (older than 15 minutes)
    var isStale: Bool {
        return Date().timeIntervalSince(cachedAt) > 900 // 15 minutes
    }
}

// MARK: - Cached Recipient

/// SwiftData model for caching share recipients
@Model
final class CachedRecipient {
    var id: String
    var recipientType: String
    var recipientUserId: String?
    var externalEmail: String?
    var permissions: Int?
    var invitationStatus: String

    @Relationship(inverse: \CachedShare.recipients) var share: CachedShare?

    init(from recipient: ShareRecipient) {
        self.id = recipient.id
        self.recipientType = recipient.recipientType.rawValue
        self.recipientUserId = recipient.recipientUserId
        self.externalEmail = recipient.externalEmail
        self.permissions = recipient.permissions
        self.invitationStatus = recipient.invitationStatus.rawValue
    }

    /// Convert back to ShareRecipient model
    func toShareRecipient() -> ShareRecipient {
        return ShareRecipient(
            id: id,
            recipientType: ShareRecipient.RecipientType(rawValue: recipientType) ?? .user,
            recipientUserId: recipientUserId,
            recipientGroupId: nil, // Not cached
            externalEmail: externalEmail,
            externalOrgId: nil,
            permissions: permissions,
            invitationStatus: ShareRecipient.InvitationStatus(rawValue: invitationStatus) ?? .active,
            createdAt: Date()
        )
    }
}

// MARK: - Cached Share Asset

/// SwiftData model for caching asset IDs in a share
@Model
final class CachedShareAsset {
    var assetId: String
    var shareId: String
    var position: Int
    var cachedAt: Date

    @Relationship(inverse: \CachedShare.assets) var share: CachedShare?

    init(assetId: String, shareId: String, position: Int) {
        self.assetId = assetId
        self.shareId = shareId
        self.position = position
        self.cachedAt = Date()
    }
}

// MARK: - Cached Public Link

/// SwiftData model for caching public links offline
@Model
final class CachedPublicLink {
    @Attribute(.unique) var id: String
    var ownerUserId: String
    var name: String
    var url: String?
    var permissions: Int
    var expiresAt: Date?
    var status: String
    var coverAssetId: String
    var hasPin: Bool
    var createdAt: Date
    var cachedAt: Date

    init(from link: PublicLink) {
        self.id = link.id
        self.ownerUserId = link.ownerUserId ?? ""
        self.name = link.name
        self.url = link.url
        self.permissions = link.permissions
        self.expiresAt = link.expiresAt
        self.status = link.status ?? "active"
        self.coverAssetId = link.coverAssetId ?? ""
        self.hasPin = link.hasPin ?? false
        self.createdAt = link.createdAt ?? Date()
        self.cachedAt = Date()
    }

    /// Convert back to PublicLink model
    func toPublicLink() -> PublicLink {
        return PublicLink(
            id: id,
            ownerOrgId: 0, // Not cached
            ownerUserId: ownerUserId,
            name: name,
            scopeKind: "album",
            scopeAlbumId: nil,
            uploadsAlbumId: nil,
            url: url,
            permissions: permissions,
            expiresAt: expiresAt,
            status: status,
            coverAssetId: coverAssetId,
            moderationEnabled: false,
            pendingCount: nil,
            hasPin: hasPin,
            key: nil, // Not cached
            createdAt: createdAt,
            updatedAt: Date()
        )
    }

    /// Check if cache is stale (older than 15 minutes)
    var isStale: Bool {
        return Date().timeIntervalSince(cachedAt) > 900 // 15 minutes
    }
}

// MARK: - Cached Thumbnail

/// SwiftData model for caching share asset thumbnails
@Model
final class CachedShareThumbnail {
    @Attribute(.unique) var key: String  // "share:{shareId}:asset:{assetId}"
    var assetId: String
    var shareId: String
    var imageData: Data
    var cachedAt: Date

    init(shareId: String, assetId: String, imageData: Data) {
        self.key = "share:\(shareId):asset:\(assetId)"
        self.shareId = shareId
        self.assetId = assetId
        self.imageData = imageData
        self.cachedAt = Date()
    }

    /// Check if cache is stale (older than 1 hour)
    var isStale: Bool {
        return Date().timeIntervalSince(cachedAt) > 3600 // 1 hour
    }
}

// MARK: - Cached Face Thumbnail

/// SwiftData model for caching face thumbnails in shares
@Model
final class CachedFaceThumbnail {
    @Attribute(.unique) var key: String  // "share:{shareId}:face:{personId}"
    var personId: String
    var shareId: String
    var imageData: Data
    var cachedAt: Date

    init(shareId: String, personId: String, imageData: Data) {
        self.key = "share:\(shareId):face:\(personId)"
        self.shareId = shareId
        self.personId = personId
        self.imageData = imageData
        self.cachedAt = Date()
    }

    /// Check if cache is stale (older than 1 day)
    var isStale: Bool {
        return Date().timeIntervalSince(cachedAt) > 86400 // 24 hours
    }
}
