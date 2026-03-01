import SwiftUI

/// Users tab view with filters, user list, and inline actions.
/// Shows role/status filters at top, user table with inline "Reset PW" and "Delete" buttons.
struct UsersTabView: View {
    @EnvironmentObject var viewModel: TeamManagementViewModel
    @EnvironmentObject var auth: AuthManager

    var body: some View {
        VStack(spacing: 0) {
            // Filters
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    // Role Filter
                    Picker("Role", selection: $viewModel.roleFilter) {
                        ForEach(TeamManagementViewModel.RoleFilter.allCases, id: \.self) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .pickerStyle(.menu)

                    // Status Filter
                    Picker("Status", selection: $viewModel.statusFilter) {
                        ForEach(TeamManagementViewModel.StatusFilter.allCases, id: \.self) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .pickerStyle(.menu)

                    Spacer()

                    // Add User Button
                    Button {
                        viewModel.showAddUser = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                            .foregroundColor(.blue)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)

                Divider()
            }
            .background(Color(.systemGroupedBackground))

            // Users List
            if viewModel.loading && viewModel.users.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.filteredUsers.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "person.3")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No users match your filters")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    // Table Header
                    UsersTableHeader()

                    Divider()

                    // User Rows
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(viewModel.filteredUsers) { user in
                                UserRow(user: user)
                                    .environmentObject(viewModel)
                                    .environmentObject(auth)
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $viewModel.showAddUser) {
            AddUserSheet()
                .environmentObject(viewModel)
        }
        .sheet(item: Binding(
            get: { viewModel.selectedUser },
            set: { viewModel.selectedUser = $0 }
        )) { user in
            UserDetailPanel(user: user)
                .environmentObject(viewModel)
                .environmentObject(auth)
        }
        .sheet(isPresented: Binding(
            get: { viewModel.showResetPassword.show },
            set: { show in viewModel.showResetPassword = (show, show ? viewModel.showResetPassword.user : nil) }
        )) {
            if let user = viewModel.showResetPassword.user {
                ResetPasswordSheet(user: user)
                    .environmentObject(viewModel)
                    .environmentObject(auth)
            }
        }
        .confirmationDialog(
            "Delete User",
            isPresented: Binding(
                get: { viewModel.showDeleteUserConfirm.show },
                set: { show in viewModel.showDeleteUserConfirm = (show, show ? viewModel.showDeleteUserConfirm.user : nil) }
            ),
            presenting: viewModel.showDeleteUserConfirm.user
        ) { user in
            Button("Delete '\(user.name)'", role: .destructive) {
                Task {
                    try? await viewModel.deleteUser(user)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { user in
            Text("This will permanently delete the user and all their data. This cannot be undone.")
        }
    }
}

// MARK: - Table Header

/// Table header row with column labels aligned with user data columns
private struct UsersTableHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            // Name column (wider)
            Text("Name")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Role column
            Text("Role")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
                .frame(width: 70, alignment: .center)

            // Status column
            Text("Status")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
                .frame(width: 70, alignment: .center)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(.systemGroupedBackground))
    }
}

// MARK: - User Row

private struct UserRow: View {
    @EnvironmentObject var viewModel: TeamManagementViewModel
    @EnvironmentObject var auth: AuthManager

    let user: TeamUser

    var body: some View {
        Button {
            viewModel.selectedUser = user
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    // Name column: two rows (name + email)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(user.name)
                            .font(.body)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        if let email = user.email {
                            Text(email)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Role column
                    RoleBadge(role: user.role)
                        .frame(width: 70, alignment: .center)

                    // Status column
                    StatusBadge(status: user.status)
                        .frame(width: 70, alignment: .center)
                }
                .padding(.horizontal)
                .padding(.vertical, 12)

                Divider()
            }
        }
        .buttonStyle(.plain)
    }
}
