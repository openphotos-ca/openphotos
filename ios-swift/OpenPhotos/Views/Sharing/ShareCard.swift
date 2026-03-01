//
//  ShareCard.swift
//  OpenPhotos
//
//  Reusable card component for displaying a share in a grid.
//

import SwiftUI

/// Card view for displaying a share
struct ShareCard: View {
    let share: Share
    let isOwner: Bool

    @State private var coverImage: UIImage?
    @State private var isLoadingCover = false
    @State private var showEditSheet = false
    @State private var showShareViewer = false

    var body: some View {
        VStack(spacing: 0) {
            // Cover thumbnail with internal padding so adjacent
            // cells in a grid have visible spacing between images.
            ZStack {
                // Thumbnail background
                ZStack {
                    if let coverImage = coverImage {
                        Image(uiImage: coverImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else if isLoadingCover {
                        ProgressView()
                    } else {
                        Image(systemName: "photo.stack")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                    }
                }
                .frame(height: 160)
                .frame(maxWidth: .infinity)
                .background(Color.gray.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 4)
            .padding(.top, 4)

            // Share info
            VStack(alignment: .leading, spacing: 4) {
                // Title row
                HStack(spacing: 4) {
                    Image(systemName: share.objectKind == .album ? "folder" : "photo")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 16)

                    Text(share.name)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if isOwner {
                        Button {
                            showEditSheet = true
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Owner or recipient count
                if isOwner {
                    Text("\(share.recipients.count) recipient\(share.recipients.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("From \(share.ownerUserId)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                // Expiry date if set
                if let expiresAt = share.expiresAt {
                    Text(expiryText(expiresAt))
                        .font(.caption2)
                        .foregroundColor(share.isExpired ? .red : .orange)
                }

                // Status badges
                HStack(spacing: 4) {
                    if share.includeFaces {
                        Label("Faces", systemImage: "person.2")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.2))
                            .clipShape(Capsule())
                    }

                    let permissions = SharePermissions(rawValue: share.defaultPermissions)
                    Text(permissions.roleName)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.2))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .background(Color(UIColor.systemBackground))
        .cornerRadius(12)
        .padding(4)
        .contentShape(Rectangle())
        .onTapGesture {
            showShareViewer = true
        }
        .task {
            await loadCoverThumbnail()
        }
        .sheet(isPresented: $showEditSheet) {
            EditShareSheet(share: share)
        }
        .fullScreenCover(isPresented: $showShareViewer) {
            ShareViewerView(share: share)
        }
    }

    /// Load cover thumbnail for share
    private func loadCoverThumbnail() async {
        isLoadingCover = true
        defer { isLoadingCover = false }

        do {
            // Get first asset from share
            let response = try await ShareService.shared.listShareAssets(
                shareId: share.id,
                page: 1,
                limit: 1
            )

            guard let firstAssetId = response.assetIds.first else { return }

            // Fetch thumbnail
            let data = try await ShareService.shared.getShareAssetThumbnail(
                shareId: share.id,
                assetId: firstAssetId
            )

            // TODO: Check if locked and decrypt if needed

            coverImage = UIImage(data: data)
        } catch {
            print("Failed to load cover thumbnail: \(error)")
        }
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
    ShareCard(
        share: Share(
            id: "1",
            ownerOrgId: 1,
            ownerUserId: "user123",
            objectKind: .album,
            objectId: "42",
            defaultPermissions: SharePermissions.commenter.rawValue,
            expiresAt: Date().addingTimeInterval(86400 * 7),
            status: .active,
            createdAt: Date(),
            updatedAt: Date(),
            name: "Trip Photos",
            includeFaces: true,
            includeSubtree: false,
            recipients: []
        ),
        isOwner: true
    )
    .frame(width: 160)
    .padding()
}
