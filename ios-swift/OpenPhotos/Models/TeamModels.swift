import Foundation

// MARK: - Team User Model

/// Represents a user within an organization/team context.
/// Returned by /api/team/users endpoints.
struct TeamUser: Identifiable, Codable, Hashable {
    let id: Int
    let user_id: String
    let name: String
    let email: String?
    let role: String              // "admin", "regular", "owner"
    let status: String            // "active", "disabled"
    let media_count: Int?
    let storage_bytes: Int64?
    let is_creator: Bool?

    /// Formatted storage size for display (e.g., "1.05 GB")
    var formattedStorage: String {
        guard let bytes = storage_bytes else { return "—" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Group Models

/// Represents a user group within an organization.
/// Returned by /api/team/groups endpoints.
struct TeamGroup: Identifiable, Codable, Hashable {
    let id: Int
    let name: String
    let description: String?
}

/// Represents a member of a group with their user details.
/// Returned by /api/team/groups/:id/users endpoint.
struct GroupMember: Codable, Hashable {
    let user_id: String
    let name: String
    let email: String?
    let role: String
}

// MARK: - Organization Model

/// Represents organization metadata.
/// Returned by /api/team/org endpoint.
struct OrgInfo: Codable {
    let id: Int
    var name: String
    let creator_user_id: String
}

// MARK: - Capabilities Model

/// Server capabilities response from /api/capabilities.
/// Used to detect Enterprise Edition features.
struct ServerCapabilities: Codable {
    let ee: Bool
    let version: String?
    let features: [String]?
}

// MARK: - Request DTOs

/// Request body for creating a new user.
/// POST /api/team/users
struct CreateUserRequest: Encodable {
    let email: String
    let name: String
    let role: String?                    // Optional, defaults to "regular"
    let initial_password: String         // Minimum 6 characters
    let must_change_password: Bool?      // Optional, defaults to true
    let groups: [Int]?                   // Optional group IDs to add user to
}

/// Request body for updating an existing user.
/// PATCH /api/team/users/:id
/// Note: Email cannot be updated via this endpoint
struct UpdateUserRequest: Encodable {
    let name: String?
    let role: String?
    let status: String?
}

/// Request body for resetting a user's password.
/// POST /api/team/users/:id/reset-password
struct ResetPasswordRequest: Encodable {
    let new_password: String             // Minimum 6 characters
    let current_password: String?        // Required when user is resetting own password
}

/// Request body for creating a new group.
/// POST /api/team/groups
struct CreateGroupRequest: Encodable {
    let name: String
    let description: String?
}

/// Request body for updating an existing group.
/// PATCH /api/team/groups/:id
struct UpdateGroupRequest: Encodable {
    let name: String?
    let description: String?
}

/// Request body for modifying group membership.
/// POST /api/team/groups/:id/users
struct ModifyGroupMembersRequest: Encodable {
    let add: [String]?      // Array of user_ids to add
    let remove: [String]?   // Array of user_ids to remove
}

/// Request body for updating organization name.
/// PATCH /api/team/org
struct UpdateOrgRequest: Encodable {
    let name: String
}
