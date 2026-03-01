import SwiftUI

/// Bottom sheet displaying selected group details with inline editing and member management.
struct GroupDetailPanel: View {
    @EnvironmentObject var viewModel: TeamManagementViewModel
    @Environment(\.dismiss) var dismiss

    let group: TeamGroup

    @State private var isEditing = false
    @State private var editName: String
    @State private var editDescription: String

    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showMemberPicker = false

    init(group: TeamGroup) {
        self.group = group
        _editName = State(initialValue: group.name)
        _editDescription = State(initialValue: group.description ?? "")
    }

    var body: some View {
        NavigationView {
            Form {
                // Group ID
                Section("Group ID") {
                    Text("\(group.id)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Name and Description
                Section("Information") {
                    if isEditing {
                        TextField("Group Name", text: $editName)
                            .disabled(isSaving)
                        TextField("Description (Optional)", text: $editDescription, axis: .vertical)
                            .lineLimit(3...6)
                            .disabled(isSaving)
                    } else {
                        LabeledContent("Name", value: group.name)
                        if let description = group.description, !description.isEmpty {
                            LabeledContent("Description", value: description)
                        }
                    }
                }

                // Members
                Section {
                    HStack {
                        Text("Members")
                            .font(.headline)
                        Spacer()
                        Button {
                            showMemberPicker = true
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .foregroundColor(.blue)
                        }
                    }

                    if let members = viewModel.groupMembers[group.id], !members.isEmpty {
                        ForEach(members, id: \.user_id) { member in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(member.name)
                                        .font(.body)
                                    if let email = member.email {
                                        Text(email)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                RoleBadge(role: member.role)
                                Button {
                                    Task {
                                        try? await viewModel.removeMemberFromGroup(
                                            groupId: group.id,
                                            userId: member.user_id
                                        )
                                    }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.red)
                                }
                            }
                        }
                    } else {
                        Text("No members yet")
                            .font(.caption)
                            .foregroundColor(.secondary)
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
            .navigationTitle("Group Details")
            .navigationBarTitleDisplayMode(.inline)
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
                            Task { await saveChanges() }
                        }
                        .disabled(isSaving)
                    } else {
                        Button("Edit") {
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
            .task {
                // Load members when panel opens
                await viewModel.loadGroupMembers(groupId: group.id)
            }
            .sheet(isPresented: $showMemberPicker) {
                MemberPickerSheet(group: group)
                    .environmentObject(viewModel)
            }
        }
    }

    // MARK: - Actions

    private func saveChanges() async {
        errorMessage = nil
        isSaving = true

        let trimmedName = editName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "Group name cannot be empty"
            isSaving = false
            return
        }

        let trimmedDescription = editDescription.trimmingCharacters(in: .whitespacesAndNewlines)

        let request = UpdateGroupRequest(
            name: trimmedName != group.name ? trimmedName : nil,
            description: trimmedDescription != (group.description ?? "") ? trimmedDescription : nil
        )

        do {
            try await viewModel.updateGroup(id: group.id, request: request)
            // Clear selectedGroup to dismiss the sheet
            viewModel.selectedGroup = nil
            isEditing = false
        } catch {
            errorMessage = "Failed to update group: \(error.localizedDescription)"
            isSaving = false
        }
    }
}
