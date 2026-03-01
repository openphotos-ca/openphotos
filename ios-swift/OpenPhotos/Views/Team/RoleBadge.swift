import SwiftUI

// MARK: - Role Badge

/// Displays a user's role as a colored badge.
/// Roles: "owner" (purple), "admin" (blue), "regular" (gray).
struct RoleBadge: View {
    let role: String

    var body: some View {
        Text(role.capitalized)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(roleColor.opacity(0.2))
            .foregroundColor(roleColor)
            .cornerRadius(8)
    }

    private var roleColor: Color {
        switch role.lowercased() {
        case "owner":
            return .purple
        case "admin":
            return .blue
        case "regular":
            return .gray
        default:
            return .gray
        }
    }
}

// MARK: - Status Badge

/// Displays a user's status as a colored badge.
/// Status: "active" (green), "disabled" (orange).
struct StatusBadge: View {
    let status: String

    var body: some View {
        Text(status.capitalized)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(statusColor.opacity(0.2))
            .foregroundColor(statusColor)
            .cornerRadius(8)
    }

    private var statusColor: Color {
        switch status.lowercased() {
        case "active":
            return .green
        case "disabled":
            return .orange
        default:
            return .gray
        }
    }
}

// MARK: - Previews

#if DEBUG
struct BadgePreviews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                RoleBadge(role: "owner")
                RoleBadge(role: "admin")
                RoleBadge(role: "regular")
            }

            HStack(spacing: 8) {
                StatusBadge(status: "active")
                StatusBadge(status: "disabled")
            }
        }
        .padding()
        .previewLayout(.sizeThatFits)
    }
}
#endif
