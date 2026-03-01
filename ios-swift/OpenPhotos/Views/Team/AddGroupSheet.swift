import SwiftUI

/// Modal sheet for creating a new group.
/// Simple form with name (required) and description (optional).
struct AddGroupSheet: View {
    @EnvironmentObject var viewModel: TeamManagementViewModel
    @Environment(\.dismiss) var dismiss

    // Form fields
    @State private var groupName = ""
    @State private var description = ""

    // UI state
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationView {
            Form {
                Section("Group Information") {
                    TextField("Group Name", text: $groupName)
                        .disabled(isSubmitting)

                    TextField("Description (Optional)", text: $description, axis: .vertical)
                        .lineLimit(3...6)
                        .disabled(isSubmitting)
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
            .navigationTitle("Add Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task { await createGroup() }
                    }
                    .disabled(!isFormValid || isSubmitting)
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

    // MARK: - Validation

    private var isFormValid: Bool {
        !groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Actions

    private func createGroup() async {
        errorMessage = nil
        isSubmitting = true

        let trimmedName = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "Group name is required"
            isSubmitting = false
            return
        }

        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = CreateGroupRequest(
            name: trimmedName,
            description: trimmedDescription.isEmpty ? nil : trimmedDescription
        )

        do {
            try await viewModel.createGroup(request)
            dismiss()
        } catch {
            errorMessage = "Failed to create group: \(error.localizedDescription)"
            isSubmitting = false
        }
    }
}
