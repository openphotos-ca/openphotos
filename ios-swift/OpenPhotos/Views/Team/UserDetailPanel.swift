import SwiftUI

/// Bottom sheet displaying selected user details with inline editing.
/// Enforces business rules for role/status/email editing based on permissions.
struct UserDetailPanel: View {
    @EnvironmentObject var viewModel: TeamManagementViewModel
    @EnvironmentObject var auth: AuthManager
    @Environment(\.dismiss) var dismiss

    let user: TeamUser

    @State private var isEditing = false
    @State private var editName: String
    @State private var editRole: String
    @State private var editStatus: String

    @State private var isSaving = false
    @State private var errorMessage: String?

    init(user: TeamUser) {
        self.user = user
        _editName = State(initialValue: user.name)
        _editRole = State(initialValue: user.role)
        _editStatus = State(initialValue: user.status)
    }

    var body: some View {
        NavigationView {
            Form {
                // User ID
                Section("User ID") {
                    Text(user.user_id)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Name and Email
                Section("Information") {
                    if isEditing {
                        TextField("Name", text: $editName)
                            .disabled(isSaving)
                    } else {
                        LabeledContent("Name", value: user.name)
                    }

                    // Email is read-only (cannot be updated)
                    if let email = user.email {
                        LabeledContent("Email", value: email)
                    }
                }

                // Role and Status
                Section("Role & Status") {
                    if isEditing && canEditRole {
                        Picker("Role", selection: $editRole) {
                            Text("Regular").tag("regular")
                            Text("Admin").tag("admin")
                        }
                        .disabled(isSaving)
                    } else {
                        HStack {
                            Text("Role")
                            Spacer()
                            RoleBadge(role: user.role)
                        }
                    }

                    if isEditing && canEditStatus {
                        Picker("Status", selection: $editStatus) {
                            Text("Active").tag("active")
                            Text("Disabled").tag("disabled")
                        }
                        .disabled(isSaving)
                    } else {
                        HStack {
                            Text("Status")
                            Spacer()
                            StatusBadge(status: user.status)
                        }
                    }
                }

                // Statistics
                Section("Statistics") {
                    LabeledContent("Media Count", value: "\(user.media_count ?? 0)")
                    LabeledContent("Storage", value: user.formattedStorage)
                }

                // Actions
                Section("Actions") {
                    // Reset Password
                    if canResetPassword {
                        Button {
                            viewModel.showResetPassword = (true, user)
                            dismiss()
                        } label: {
                            HStack {
                                Label("Reset Password", systemImage: "lock.rotation")
                                    .foregroundColor(.blue)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    // Delete User
                    if canDelete {
                        Button(role: .destructive) {
                            viewModel.showDeleteUserConfirm = (true, user)
                            dismiss()
                        } label: {
                            HStack {
                                Label("Delete User", systemImage: "trash")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }

                // Creator Badge
                if user.is_creator == true {
                    Section {
                        Label("Organization Creator", systemImage: "star.fill")
                            .foregroundColor(.purple)
                    }
                }

                // Error Message
                if let errorMessage = errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("User Details")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                print("DEBUG: UserDetailPanel appeared - isEditing: \(isEditing), canEdit: \(canEdit), isSaving: \(isSaving)")
            }
            .onChange(of: isEditing) { newValue in
                print("DEBUG: isEditing changed to: \(newValue)")
            }
            .onChange(of: isSaving) { newValue in
                print("DEBUG: isSaving changed to: \(newValue)")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.body)
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .primaryAction) {
                    if isEditing {
                        Button("Save") {
                            print("DEBUG: Save button tapped!")
                            Task {
                                print("DEBUG: Task started")
                                await saveChanges()
                                print("DEBUG: Task completed")
                            }
                        }
                        .disabled(isSaving)
                    } else if canEdit {
                        Button("Edit") {
                            print("DEBUG: Edit button tapped!")
                            isEditing = true
                        }
                    }
                }
            }
            .overlay {
                if isSaving {
                    ProgressView()
                        .scaleEffect(1.5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.2))
                }
            }
        }
    }

    // MARK: - Permissions

    private var canEdit: Bool {
        viewModel.canEditUser(user, currentUserId: auth.userId)
    }

    private var canEditRole: Bool {
        viewModel.canEditUserRole(user, currentUserId: auth.userId)
    }

    private var canEditStatus: Bool {
        viewModel.canEditUserStatus(user, currentUserId: auth.userId)
    }

    private var canResetPassword: Bool {
        viewModel.canResetPassword(user, currentUserId: auth.userId)
    }

    private var canDelete: Bool {
        viewModel.canDeleteUser(user, currentUserId: auth.userId)
    }

    // MARK: - Actions

    private func saveChanges() async {
        print("DEBUG: saveChanges() called")
        print("DEBUG: editName = '\(editName)'")
        print("DEBUG: user.name = '\(user.name)'")

        errorMessage = nil
        isSaving = true

        let trimmedName = editName.trimmingCharacters(in: .whitespacesAndNewlines)

        print("DEBUG: trimmedName = '\(trimmedName)'")

        guard !trimmedName.isEmpty else {
            print("DEBUG: Validation failed - name is empty")
            errorMessage = "Name cannot be empty"
            isSaving = false
            return
        }

        print("DEBUG: Validation passed")
        print("DEBUG: editRole = '\(editRole)', user.role = '\(user.role)'")
        print("DEBUG: editStatus = '\(editStatus)', user.status = '\(user.status)'")

        let request = UpdateUserRequest(
            name: trimmedName != user.name ? trimmedName : nil,
            role: editRole != user.role ? editRole : nil,
            status: editStatus != user.status ? editStatus : nil
        )

        // Debug: Check if request has any changes
        print("DEBUG: Update request - name: \(request.name ?? "nil"), role: \(request.role ?? "nil"), status: \(request.status ?? "nil")")
        print("DEBUG: Calling PATCH /api/team/users/\(user.user_id)")

        do {
            try await viewModel.updateUser(userId: user.user_id, request: request)
            print("DEBUG: Update succeeded, clearing selectedUser")
            // Clear selectedUser to dismiss the sheet
            viewModel.selectedUser = nil
            isEditing = false
            isSaving = false
            print("DEBUG: Set selectedUser = nil, isEditing = false, isSaving = false")
        } catch {
            print("DEBUG: Update failed - \(error.localizedDescription)")
            errorMessage = "Failed to update user: \(error.localizedDescription)"
            isSaving = false
        }
    }
}
