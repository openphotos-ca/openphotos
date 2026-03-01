//
//  SharePermissionsView.swift
//  OpenPhotos
//
//  View for selecting share permissions and role.
//

import SwiftUI

/// View for selecting share permissions
struct SharePermissionsView: View {
    @Binding var permissions: SharePermissions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Permissions")
                .font(.headline)

            Picker("Role", selection: $permissions) {
                ForEach(SharePermissions.allRoles, id: \.rawValue) { role in
                    Text(role.displayName).tag(role)
                }
            }
            .pickerStyle(.segmented)

            // Permission details
            VStack(alignment: .leading, spacing: 8) {
                Text(permissions.description)
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                // Permission breakdown
                PermissionRow(
                    icon: "eye.fill",
                    label: "View photos",
                    enabled: permissions.canView
                )

                PermissionRow(
                    icon: "bubble.left.fill",
                    label: "Comment on photos",
                    enabled: permissions.canComment
                )

                PermissionRow(
                    icon: "heart.fill",
                    label: "Like photos",
                    enabled: permissions.canLike
                )

                PermissionRow(
                    icon: "arrow.down.circle.fill",
                    label: "Import photos",
                    enabled: permissions.canUpload
                )
            }
            .padding(.vertical, 8)
        }
    }
}

/// Row showing a permission capability
struct PermissionRow: View {
    let icon: String
    let label: String
    let enabled: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(enabled ? .green : .secondary)
                .frame(width: 20)

            Text(label)
                .font(.caption)
                .foregroundColor(enabled ? .primary : .secondary)

            Spacer()

            Image(systemName: enabled ? "checkmark.circle.fill" : "xmark.circle")
                .font(.caption)
                .foregroundColor(enabled ? .green : .secondary)
        }
    }
}

extension SharePermissions {
    /// All available roles
    static let allRoles: [SharePermissions] = [
        .viewer,
        .commenter,
        .contributor
    ]

    /// Display name for role
    var displayName: String {
        switch self {
        case SharePermissions.viewer: return "Viewer"
        case SharePermissions.commenter: return "Commenter"
        case SharePermissions.contributor: return "Contributor"
        default: return "Custom"
        }
    }

    /// Description of what the role can do
    var description: String {
        switch self {
        case SharePermissions.viewer:
            return "Can view photos only"
        case SharePermissions.commenter:
            return "Can view, comment, and like photos"
        case SharePermissions.contributor:
            return "Can view, comment, like, and import photos"
        default:
            return "Custom permissions"
        }
    }
}

#Preview {
    SharePermissionsView(permissions: .constant(.commenter))
        .padding()
}
