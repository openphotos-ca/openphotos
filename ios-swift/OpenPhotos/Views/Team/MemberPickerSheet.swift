import SwiftUI

/// Multi-select sheet for adding members to a group.
/// Shows active users with checkboxes, excluding current group members.
struct MemberPickerSheet: View {
    @EnvironmentObject var viewModel: TeamManagementViewModel
    @Environment(\.dismiss) var dismiss

    let group: TeamGroup

    @State private var selectedUserIds: Set<String> = []
    @State private var isSubmitting = false

    var body: some View {
        NavigationView {
            List {
                if availableUsers.isEmpty {
                    Section {
                        Text("No users available to add")
                            .foregroundColor(.secondary)
                    }
                } else {
                    Section("Select Members") {
                        ForEach(availableUsers) { user in
                            Button {
                                toggleSelection(user.user_id)
                            } label: {
                                HStack {
                                    Image(systemName: selectedUserIds.contains(user.user_id) ? "checkmark.square.fill" : "square")
                                        .foregroundColor(selectedUserIds.contains(user.user_id) ? .blue : .gray)

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(user.name)
                                            .foregroundColor(.primary)
                                        if let email = user.email {
                                            Text(email)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }

                                    Spacer()

                                    RoleBadge(role: user.role)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Add Members")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add (\(selectedUserIds.count))") {
                        Task { await addMembers() }
                    }
                    .disabled(selectedUserIds.isEmpty || isSubmitting)
                }
            }
            .overlay {
                if isSubmitting {
                    ProgressView()
                        .scaleEffect(1.5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.2))
                }
            }
        }
    }

    // MARK: - Computed Properties

    /// Users available to add: active users not already in the group.
    private var availableUsers: [TeamUser] {
        let currentMembers = Set(viewModel.groupMembers[group.id]?.map { $0.user_id } ?? [])
        return viewModel.users.filter { user in
            user.status == "active" && !currentMembers.contains(user.user_id)
        }
    }

    // MARK: - Actions

    private func toggleSelection(_ userId: String) {
        if selectedUserIds.contains(userId) {
            selectedUserIds.remove(userId)
        } else {
            selectedUserIds.insert(userId)
        }
    }

    private func addMembers() async {
        isSubmitting = true

        do {
            try await viewModel.addMembersToGroup(
                groupId: group.id,
                userIds: Array(selectedUserIds)
            )
            dismiss()
        } catch {
            // Error shown via ViewModel toast
            isSubmitting = false
        }
    }
}
