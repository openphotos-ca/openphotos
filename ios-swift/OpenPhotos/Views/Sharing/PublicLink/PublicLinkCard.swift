//
//  PublicLinkCard.swift
//  OpenPhotos
//
//  Card view for displaying a public link in a grid.
//

import SwiftUI

/// Card view for displaying a public link
struct PublicLinkCard: View {
    let link: PublicLink

    @State private var coverImage: UIImage?
    @State private var isLoadingCover = false
    @State private var showEditSheet = false
    @State private var showQRSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Cover thumbnail
            ZStack {
                if let coverImage = coverImage {
                    Image(uiImage: coverImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else if isLoadingCover {
                    ProgressView()
                } else {
                    Image(systemName: "link.circle")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                }
            }
            .frame(height: 160)
            .frame(maxWidth: .infinity)
            .background(Color.gray.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .onTapGesture {
                openLinkInSafari()
            }

            // Link info
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "link")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text(link.name)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    Spacer()

                    Menu {
                        Button {
                            showQRSheet = true
                        } label: {
                            Label("Show QR Code", systemImage: "qrcode")
                        }

                        Button {
                            copyLinkToClipboard()
                        } label: {
                            Label("Copy Link", systemImage: "doc.on.doc")
                        }

                        Button {
                            showEditSheet = true
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.subheadline)
                    }
                }

                // Status badges
                HStack(spacing: 4) {
                    if link.hasPin == true {
                        Label("PIN", systemImage: "lock")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2))
                            .clipShape(Capsule())
                    }

                    let permissions = SharePermissions(rawValue: link.permissions)
                    Text(permissions.roleName)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.2))
                        .clipShape(Capsule())

                    if link.moderationEnabled {
                        if let pending = link.pendingCount, pending > 0 {
                            Text("\(pending)")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.red.opacity(0.2))
                                .clipShape(Capsule())
                        }
                    }
                }

                // Expiry date if set
                if let expiresAt = link.expiresAt {
                    Text(expiryText(expiresAt))
                        .font(.caption2)
                        .foregroundColor(link.isExpired ? .red : .orange)
                }

                // Status
                if !link.isActive, let status = link.status {
                    Text(status.uppercased())
                        .font(.caption2)
                        .foregroundColor(.red)
                }
            }
        }
        .task {
            await loadCoverThumbnail()
        }
        .sheet(isPresented: $showEditSheet) {
            EditPublicLinkSheet(link: link)
        }
        .sheet(isPresented: $showQRSheet) {
            PublicLinkQRView(link: link, onDismiss: {
                showQRSheet = false
            })
        }
    }

    /// Load cover thumbnail
    private func loadCoverThumbnail() async {
        isLoadingCover = true
        defer { isLoadingCover = false }

        do {
            // Get cover asset thumbnail from share service
            // Note: Public links use the owner's library, so we fetch via normal photo routes
            // TODO: Implement proper cover thumbnail fetching
            print("Loading cover for asset: \(link.coverAssetId)")
        } catch {
            print("Failed to load cover thumbnail: \(error)")
        }
    }

    /// Open link in Safari
    private func openLinkInSafari() {
        guard let url = link.url, let linkURL = URL(string: url) else { return }
        UIApplication.shared.open(linkURL)
    }

    /// Copy link to clipboard
    private func copyLinkToClipboard() {
        guard let url = link.url else { return }
        UIPasteboard.general.string = url
    }

    /// Format expiry date text
    private func expiryText(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short

        if date < Date() {
            return "Expired"
        } else {
            return "Expires \(formatter.localizedString(for: date, relativeTo: Date()))"
        }
    }
}

#Preview {
    PublicLinkCard(
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
    .frame(width: 160)
    .padding()
}
