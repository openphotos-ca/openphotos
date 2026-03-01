import Foundation
import SwiftUI

/// View model for team/organization management UI.
/// Manages state for users, groups, filters, selection, and modal presentation.
/// All network operations are performed via TeamService.
@MainActor
class TeamManagementViewModel: ObservableObject {

    // MARK: - Published State

    // Data
    @Published var users: [TeamUser] = []
    @Published var groups: [TeamGroup] = []
    @Published var org: OrgInfo?
    @Published var groupMembers: [Int: [GroupMember]] = [:]

    // UI State
    @Published var activeTab: Tab = .users
    @Published var loading: Bool = false
    @Published var error: String?

    // Filters (Users tab)
    @Published var roleFilter: RoleFilter = .all
    @Published var statusFilter: StatusFilter = .all

    // Selection
    @Published var selectedUser: TeamUser?
    @Published var selectedGroup: TeamGroup?

    // Modal States
    @Published var showAddUser = false
    @Published var showAddGroup = false
    @Published var showResetPassword: (show: Bool, user: TeamUser?) = (false, nil)
    @Published var showMemberPicker: (show: Bool, group: TeamGroup?) = (false, nil)
    @Published var showDeleteUserConfirm: (show: Bool, user: TeamUser?) = (false, nil)
    @Published var showDeleteGroupConfirm: (show: Bool, group: TeamGroup?) = (false, nil)

    // MARK: - Enums

    enum Tab {
        case users
        case groups
    }

    enum RoleFilter: String, CaseIterable {
        case all = "All roles"
        case admin = "admin"
        case regular = "regular"
    }

    enum StatusFilter: String, CaseIterable {
        case all = "All status"
        case active = "active"
        case disabled = "disabled"
    }

    // MARK: - Computed Properties

    /// Filtered users based on current role and status filters.
    var filteredUsers: [TeamUser] {
        users.filter { user in
            let roleMatch = (roleFilter == .all) || (user.role == roleFilter.rawValue)
            let statusMatch = (statusFilter == .all) || (user.status == statusFilter.rawValue)
            return roleMatch && statusMatch
        }
    }

    // MARK: - Data Loading

    /// Load all data: organization info, users, and groups.
    /// Called on view appear and manual refresh.
    func loadAll() async {
        loading = true
        error = nil

        async let orgTask = TeamService.shared.getOrgInfo()
        async let usersTask = TeamService.shared.listUsers()
        async let groupsTask = TeamService.shared.listGroups()

        do {
            let (orgInfo, usersList, groupsList) = try await (orgTask, usersTask, groupsTask)
            self.org = orgInfo
            self.users = usersList
            self.groups = groupsList
        } catch {
            self.error = "Failed to load data: \(error.localizedDescription)"
        }

        loading = false
    }

    /// Refresh users list only.
    func refreshUsers() async {
        do {
            users = try await TeamService.shared.listUsers()
        } catch {
            self.error = "Failed to refresh users: \(error.localizedDescription)"
        }
    }

    /// Refresh groups list only.
    func refreshGroups() async {
        do {
            groups = try await TeamService.shared.listGroups()
        } catch {
            self.error = "Failed to refresh groups: \(error.localizedDescription)"
        }
    }

    /// Load members for a specific group.
    /// Results are cached in groupMembers dictionary.
    func loadGroupMembers(groupId: Int) async {
        do {
            let members = try await TeamService.shared.listGroupMembers(groupId: groupId)
            groupMembers[groupId] = members
        } catch {
            self.error = "Failed to load group members: \(error.localizedDescription)"
        }
    }

    // MARK: - User Operations

    /// Create a new user.
    func createUser(_ request: CreateUserRequest) async throws {
        let newUser = try await TeamService.shared.createUser(request)
        users.append(newUser)
        ToastManager.shared.show("User '\(newUser.name)' created")
    }

    /// Update an existing user's properties.
    func updateUser(userId: String, request: UpdateUserRequest) async throws {
        let updated = try await TeamService.shared.updateUser(userId: userId, request: request)
        if let index = users.firstIndex(where: { $0.user_id == userId }) {
            users[index] = updated
        }
        // Don't update selectedUser here - let the caller handle dismissal
        ToastManager.shared.show("User updated")
    }

    /// Delete a user (hard delete).
    func deleteUser(_ user: TeamUser) async throws {
        try await TeamService.shared.deleteUser(id: user.id, hard: true)
        users.removeAll { $0.id == user.id }
        if selectedUser?.id == user.id {
            selectedUser = nil
        }
        ToastManager.shared.show("User '\(user.name)' deleted")
    }

    /// Reset a user's password.
    func resetPassword(user: TeamUser, newPassword: String, currentPassword: String?) async throws {
        let request = ResetPasswordRequest(
            new_password: newPassword,
            current_password: currentPassword
        )
        try await TeamService.shared.resetPassword(userId: user.id, request: request)
        ToastManager.shared.show("Password reset for '\(user.name)'")
    }

    // MARK: - Group Operations

    /// Create a new group.
    func createGroup(_ request: CreateGroupRequest) async throws {
        let newGroup = try await TeamService.shared.createGroup(request)
        groups.append(newGroup)
        ToastManager.shared.show("Group '\(newGroup.name)' created")
    }

    /// Update an existing group's properties.
    func updateGroup(id: Int, request: UpdateGroupRequest) async throws {
        let updated = try await TeamService.shared.updateGroup(id: id, request: request)
        if let index = groups.firstIndex(where: { $0.id == id }) {
            groups[index] = updated
        }
        // Don't update selectedGroup here - let the caller handle dismissal
        ToastManager.shared.show("Group updated")
    }

    /// Delete a group.
    func deleteGroup(_ group: TeamGroup) async throws {
        try await TeamService.shared.deleteGroup(id: group.id)
        groups.removeAll { $0.id == group.id }
        if selectedGroup?.id == group.id {
            selectedGroup = nil
        }
        groupMembers.removeValue(forKey: group.id)
        ToastManager.shared.show("Group '\(group.name)' deleted")
    }

    /// Add members to a group.
    func addMembersToGroup(groupId: Int, userIds: [String]) async throws {
        let request = ModifyGroupMembersRequest(add: userIds, remove: nil)
        try await TeamService.shared.modifyGroupMembers(groupId: groupId, request: request)
        // Reload members for this group
        await loadGroupMembers(groupId: groupId)
        ToastManager.shared.show("Members added to group")
    }

    /// Remove a member from a group.
    func removeMemberFromGroup(groupId: Int, userId: String) async throws {
        let request = ModifyGroupMembersRequest(add: nil, remove: [userId])
        try await TeamService.shared.modifyGroupMembers(groupId: groupId, request: request)
        // Update cached members
        groupMembers[groupId]?.removeAll { $0.user_id == userId }
        ToastManager.shared.show("Member removed from group")
    }

    // MARK: - Organization Operations

    /// Update organization name (creator-only).
    func updateOrgName(_ name: String) async throws {
        let updated = try await TeamService.shared.updateOrg(name: name)
        org = updated
        ToastManager.shared.show("Organization name updated")
    }

    // MARK: - Business Rules & Permissions

    /// Check if current user can edit the specified user.
    ///
    /// Rules:
    /// - Cannot edit creator (except self can edit own name/email)
    /// - Admins cannot edit other admins
    ///
    /// - Parameters:
    ///   - user: User to check permissions for
    ///   - currentUserId: Currently authenticated user ID
    /// - Returns: True if editing is allowed
    func canEditUser(_ user: TeamUser, currentUserId: String?) -> Bool {
        guard let currentUserId = currentUserId else { return false }

        // Creator can edit themselves (name/email only)
        if user.is_creator == true && user.user_id == currentUserId {
            return true
        }

        // Cannot edit creator
        if user.is_creator == true && user.user_id != currentUserId {
            return false
        }

        // For other protections, assume admin access (server will enforce final rules)
        return true
    }

    /// Check if current user can delete the specified user.
    ///
    /// Rules:
    /// - Cannot delete self
    /// - Cannot delete creator
    ///
    /// - Parameters:
    ///   - user: User to check permissions for
    ///   - currentUserId: Currently authenticated user ID
    /// - Returns: True if deletion is allowed
    func canDeleteUser(_ user: TeamUser, currentUserId: String?) -> Bool {
        guard let currentUserId = currentUserId else { return false }

        // Cannot delete self
        if user.user_id == currentUserId {
            return false
        }

        // Cannot delete creator
        if user.is_creator == true {
            return false
        }

        return true
    }

    /// Check if current user can reset the specified user's password.
    ///
    /// Rules:
    /// - Can always reset own password
    /// - Cannot reset creator's password unless you are the creator
    ///
    /// - Parameters:
    ///   - user: User to check permissions for
    ///   - currentUserId: Currently authenticated user ID
    /// - Returns: True if password reset is allowed
    func canResetPassword(_ user: TeamUser, currentUserId: String?) -> Bool {
        guard let currentUserId = currentUserId else { return false }

        // Can always reset own password
        if user.user_id == currentUserId {
            return true
        }

        // Cannot reset creator's password unless you are the creator
        if user.is_creator == true && user.user_id != currentUserId {
            return false
        }

        return true
    }

    /// Check if current user can edit the specified user's role.
    ///
    /// Rules:
    /// - Cannot change creator's role
    ///
    /// - Parameters:
    ///   - user: User to check permissions for
    ///   - currentUserId: Currently authenticated user ID
    /// - Returns: True if role editing is allowed
    func canEditUserRole(_ user: TeamUser, currentUserId: String?) -> Bool {
        guard let currentUserId = currentUserId else { return false }

        // Cannot change creator's role
        if user.is_creator == true {
            return false
        }

        return true
    }

    /// Check if current user can edit the specified user's status.
    ///
    /// Rules:
    /// - Cannot change creator's status
    ///
    /// - Parameters:
    ///   - user: User to check permissions for
    ///   - currentUserId: Currently authenticated user ID
    /// - Returns: True if status editing is allowed
    func canEditUserStatus(_ user: TeamUser, currentUserId: String?) -> Bool {
        guard let currentUserId = currentUserId else { return false }

        // Cannot change creator's status
        if user.is_creator == true {
            return false
        }

        return true
    }
}
