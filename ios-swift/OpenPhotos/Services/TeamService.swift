import Foundation

/// Service for team/organization management operations (Enterprise Edition feature).
/// Provides methods for managing users, groups, and organization settings.
/// All endpoints require admin role and Enterprise Edition enabled on the server.
final class TeamService {
    static let shared = TeamService()

    private init() {}

    // MARK: - Organization Management

    /// Get organization information.
    /// GET /api/team/org
    ///
    /// - Returns: OrgInfo containing organization ID, name, and creator user ID
    /// - Throws: Network or authorization errors
    func getOrgInfo() async throws -> OrgInfo {
        let url = AuthorizedHTTPClient.shared.buildURL(path: "/api/team/org")
        return try await AuthorizedHTTPClient.shared.getJSON(url)
    }

    /// Update organization name (creator-only operation).
    /// PATCH /api/team/org
    ///
    /// - Parameter name: New organization name
    /// - Returns: Updated OrgInfo
    /// - Throws: Network or authorization errors (403 if not creator)
    func updateOrg(name: String) async throws -> OrgInfo {
        let request = UpdateOrgRequest(name: name)
        return try await AuthorizedHTTPClient.shared.postJSON(
            path: "/api/team/org",
            body: request,
            method: "PATCH"
        )
    }

    // MARK: - User Management

    /// List all users in the organization.
    /// GET /api/team/users
    ///
    /// Returns users with computed statistics (media count, storage usage).
    ///
    /// - Returns: Array of TeamUser objects
    /// - Throws: Network or authorization errors
    func listUsers() async throws -> [TeamUser] {
        let url = AuthorizedHTTPClient.shared.buildURL(path: "/api/team/users")
        return try await AuthorizedHTTPClient.shared.getJSON(url)
    }

    /// Create a new user in the organization.
    /// POST /api/team/users
    ///
    /// - Parameter request: CreateUserRequest with user details and initial password
    /// - Returns: Created TeamUser with computed statistics
    /// - Throws: Network or validation errors (e.g., duplicate email)
    func createUser(_ request: CreateUserRequest) async throws -> TeamUser {
        return try await AuthorizedHTTPClient.shared.postJSON(
            path: "/api/team/users",
            body: request
        )
    }

    /// Update an existing user's properties.
    /// PATCH /api/team/users/:user_id
    ///
    /// Business rules enforced by server:
    /// - Cannot modify organization creator (except name by self)
    /// - Cannot change admin/owner role or status unless caller is owner
    ///
    /// - Parameters:
    ///   - userId: User's UUID string
    ///   - request: UpdateUserRequest with fields to update
    /// - Returns: Updated TeamUser
    /// - Throws: Network or authorization errors
    func updateUser(userId: String, request: UpdateUserRequest) async throws -> TeamUser {
        return try await AuthorizedHTTPClient.shared.postJSON(
            path: "/api/team/users/\(userId)",
            body: request,
            method: "PATCH"
        )
    }

    /// Delete a user (hard delete).
    /// DELETE /api/team/users/:id?hard=true
    ///
    /// Permanently removes user, their data directory, sessions, and tokens.
    ///
    /// Business rules enforced by server:
    /// - Cannot delete organization creator
    /// - Cannot delete self
    /// - Cannot delete admin/owner unless caller is owner
    ///
    /// - Parameters:
    ///   - id: User's numeric ID
    ///   - hard: Whether to permanently delete (default: true)
    /// - Throws: Network or authorization errors
    func deleteUser(id: Int, hard: Bool = true) async throws {
        let url = AuthorizedHTTPClient.shared.buildURL(
            path: "/api/team/users/\(id)",
            queryItems: hard ? [URLQueryItem(name: "hard", value: "true")] : []
        )
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        _ = try await AuthorizedHTTPClient.shared.request(req)
    }

    /// Reset a user's password.
    /// POST /api/team/users/:id/reset-password
    ///
    /// Two modes:
    /// 1. Admin resetting another user: only new_password required
    /// 2. User resetting own password: both new_password and current_password required
    ///
    /// Invalidates all sessions and refresh tokens after reset.
    ///
    /// - Parameters:
    ///   - userId: User's numeric ID
    ///   - request: ResetPasswordRequest with new password and optional current password
    /// - Throws: Network or validation errors (e.g., incorrect current password)
    func resetPassword(userId: Int, request: ResetPasswordRequest) async throws {
        let url = AuthorizedHTTPClient.shared.buildURL(
            path: "/api/team/users/\(userId)/reset-password"
        )
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(request)
        _ = try await AuthorizedHTTPClient.shared.request(req)
    }

    // MARK: - Group Management

    /// List all groups in the organization.
    /// GET /api/team/groups
    ///
    /// - Returns: Array of TeamGroup objects
    /// - Throws: Network or authorization errors
    func listGroups() async throws -> [TeamGroup] {
        let url = AuthorizedHTTPClient.shared.buildURL(path: "/api/team/groups")
        return try await AuthorizedHTTPClient.shared.getJSON(url)
    }

    /// Create a new group.
    /// POST /api/team/groups
    ///
    /// - Parameter request: CreateGroupRequest with group name and optional description
    /// - Returns: Created TeamGroup
    /// - Throws: Network or validation errors
    func createGroup(_ request: CreateGroupRequest) async throws -> TeamGroup {
        return try await AuthorizedHTTPClient.shared.postJSON(
            path: "/api/team/groups",
            body: request
        )
    }

    /// Update an existing group's properties.
    /// PATCH /api/team/groups/:id
    ///
    /// - Parameters:
    ///   - id: Group's numeric ID
    ///   - request: UpdateGroupRequest with fields to update
    /// - Returns: Updated TeamGroup
    /// - Throws: Network or authorization errors
    func updateGroup(id: Int, request: UpdateGroupRequest) async throws -> TeamGroup {
        return try await AuthorizedHTTPClient.shared.postJSON(
            path: "/api/team/groups/\(id)",
            body: request,
            method: "PATCH"
        )
    }

    /// Delete a group (soft delete).
    /// DELETE /api/team/groups/:id
    ///
    /// Sets deleted_at timestamp and removes all user associations.
    /// Does not delete users or their media.
    ///
    /// - Parameter id: Group's numeric ID
    /// - Throws: Network or authorization errors
    func deleteGroup(id: Int) async throws {
        let url = AuthorizedHTTPClient.shared.buildURL(path: "/api/team/groups/\(id)")
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        _ = try await AuthorizedHTTPClient.shared.request(req)
    }

    /// List members of a specific group.
    /// GET /api/team/groups/:id/users
    ///
    /// - Parameter groupId: Group's numeric ID
    /// - Returns: Array of GroupMember objects with user details
    /// - Throws: Network or authorization errors
    func listGroupMembers(groupId: Int) async throws -> [GroupMember] {
        let url = AuthorizedHTTPClient.shared.buildURL(path: "/api/team/groups/\(groupId)/users")
        return try await AuthorizedHTTPClient.shared.getJSON(url)
    }

    /// Modify group membership (add or remove users).
    /// POST /api/team/groups/:id/users
    ///
    /// Payload format: { "add": [user_ids], "remove": [user_ids] }
    ///
    /// - Parameters:
    ///   - groupId: Group's numeric ID
    ///   - request: ModifyGroupMembersRequest with user IDs to add/remove
    /// - Throws: Network or authorization errors
    func modifyGroupMembers(groupId: Int, request: ModifyGroupMembersRequest) async throws {
        let url = AuthorizedHTTPClient.shared.buildURL(path: "/api/team/groups/\(groupId)/users")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(request)
        _ = try await AuthorizedHTTPClient.shared.request(req)
    }
}

// MARK: - AuthorizedHTTPClient Extension for PATCH/custom methods

private extension AuthorizedHTTPClient {
    /// Generic POST/PATCH/PUT JSON helper with custom HTTP method.
    ///
    /// - Parameters:
    ///   - path: API path (e.g., "/api/team/users")
    ///   - body: Encodable request body
    ///   - method: HTTP method (default: "POST")
    /// - Returns: Decoded response of type T
    /// - Throws: Network or decoding errors
    func postJSON<T: Decodable, B: Encodable>(
        path: String,
        body: B,
        method: String = "POST"
    ) async throws -> T {
        let url = buildURL(path: path)
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        let (data, http) = try await request(req)
        guard (200..<300).contains(http.statusCode) else {
            throw NSError(
                domain: "TeamService",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Request failed with status \(http.statusCode)"]
            )
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
