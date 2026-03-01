//
//  PublicLinkRowView.swift
//  OpenPhotos
//
//  Row view for displaying a public link in a list.
//

import SwiftUI

/// Row view for displaying a public link in a list
struct PublicLinkRowView: View {
    let link: PublicLink
    var onUpdate: (() -> Void)? = nil

    var body: some View {
        NavigationLink {
            EditPublicLinkView(link: link, onUpdate: onUpdate)
        } label: {
            HStack(spacing: 12) {
                // Link info section
                VStack(alignment: .leading, spacing: 4) {
                    // Link name
                    Text(link.name)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    // Status badges and info
                    HStack(spacing: 6) {
                        // Permission role badge
                        let permissions = SharePermissions(rawValue: link.permissions)
                        Text(permissions.roleName)
                            .font(.caption)
                            .foregroundColor(.secondary)

                        // PIN indicator
                        if link.hasPin == true {
                            Image(systemName: "lock.fill")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }

                        // Expiry indicator
                        if let expiresAt = link.expiresAt {
                            if link.isExpired {
                                Text("Expired")
                                    .font(.caption)
                                    .foregroundColor(.red)
                            } else {
                                Image(systemName: "clock.fill")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }
                        }

                        // Moderation pending indicator
                        if link.moderationEnabled, let pending = link.pendingCount, pending > 0 {
                            Label("\(pending)", systemImage: "exclamationmark.circle.fill")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                }

                Spacer()

                // Chevron is automatically added by NavigationLink
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    NavigationStack {
        List {
            PublicLinkRowView(
            link: PublicLink(
                id: "link1",
                ownerOrgId: 1,
                ownerUserId: "user123",
                name: "Summer Photos",
                scopeKind: "album",
                scopeAlbumId: 42,
                uploadsAlbumId: nil,
                url: "https://example.com/public?k=abc123#vk=xyz789",
                permissions: SharePermissions.commenter.rawValue,
                expiresAt: Date().addingTimeInterval(86400 * 30),
                status: "active",
                coverAssetId: "asset123",
                moderationEnabled: false,
                pendingCount: nil,
                hasPin: true,
                key: "abc123",
                createdAt: Date(),
                updatedAt: Date()
            )
        )

        PublicLinkRowView(
            link: PublicLink(
                id: "link2",
                ownerOrgId: 1,
                ownerUserId: "user123",
                name: "Family Album",
                scopeKind: "album",
                scopeAlbumId: 43,
                uploadsAlbumId: nil,
                url: "https://example.com/public?k=def456#vk=abc123",
                permissions: SharePermissions.viewer.rawValue,
                expiresAt: nil,
                status: "active",
                coverAssetId: "asset456",
                moderationEnabled: true,
                pendingCount: 3,
                hasPin: false,
                key: "def456",
                createdAt: Date(),
                updatedAt: Date()
            )
        )

        PublicLinkRowView(
            link: PublicLink(
                id: "link3",
                ownerOrgId: 1,
                ownerUserId: "user123",
                name: "Expired Link",
                scopeKind: "album",
                scopeAlbumId: 44,
                uploadsAlbumId: nil,
                url: "https://example.com/public?k=ghi789#vk=def456",
                permissions: SharePermissions.contributor.rawValue,
                expiresAt: Date().addingTimeInterval(-86400),
                status: "active",
                coverAssetId: "asset789",
                moderationEnabled: false,
                pendingCount: nil,
                hasPin: true,
                key: "ghi789",
                createdAt: Date(),
                updatedAt: Date()
            )
        )
        }
        .listStyle(.plain)
    }
}