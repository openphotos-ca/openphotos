import SwiftUI

/// Modal sheet for creating a new user with validation.
/// Includes fields for email, name, password, role, and optional group assignment.
struct AddUserSheet: View {
    @EnvironmentObject var viewModel: TeamManagementViewModel
    @Environment(\.dismiss) var dismiss

    // Form fields
    @State private var email = ""
    @State private var name = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var selectedRole = "regular"
    @State private var mustChangePassword = true
    @State private var selectedGroups: Set<Int> = []

    // UI state
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationView {
            Form {
                // Basic Information
                Section("User Information") {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                        .disabled(isSubmitting)

                    TextField("Name", text: $name)
                        .textContentType(.name)
                        .disabled(isSubmitting)
                }

                // Password
                Section("Password") {
                    SecureField("Password (min 6 characters)", text: $password)
                        .textContentType(.newPassword)
                        .disabled(isSubmitting)

                    SecureField("Confirm Password", text: $confirmPassword)
                        .textContentType(.newPassword)
                        .disabled(isSubmitting)

                    Toggle("Must change password on first login", isOn: $mustChangePassword)
                        .disabled(isSubmitting)
                }

                // Role Selection
                Section("Role") {
                    Picker("Role", selection: $selectedRole) {
                        Text("Regular").tag("regular")
                        Text("Admin").tag("admin")
                    }
                    .pickerStyle(.segmented)
                    .disabled(isSubmitting)
                }

                // Optional Group Assignment
                if !viewModel.groups.isEmpty {
                    Section("Groups (Optional)") {
                        ForEach(viewModel.groups) { group in
                            Toggle(group.name, isOn: Binding(
                                get: { selectedGroups.contains(group.id) },
                                set: { isSelected in
                                    if isSelected {
                                        selectedGroups.insert(group.id)
                                    } else {
                                        selectedGroups.remove(group.id)
                                    }
                                }
                            ))
                            .disabled(isSubmitting)
                        }
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
            .navigationTitle("Add User")
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
                        Task { await createUser() }
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
        // Check all required fields
        guard !email.isEmpty,
              !name.isEmpty,
              !password.isEmpty,
              !confirmPassword.isEmpty else {
            return false
        }

        // Basic email validation
        guard email.contains("@") && email.contains(".") else {
            return false
        }

        // Password minimum length
        guard password.count >= 6 else {
            return false
        }

        // Password confirmation match
        guard password == confirmPassword else {
            return false
        }

        return true
    }

    // MARK: - Actions

    private func createUser() async {
        errorMessage = nil
        isSubmitting = true

        // Final validation before submission
        guard password == confirmPassword else {
            errorMessage = "Passwords do not match"
            isSubmitting = false
            return
        }

        guard password.count >= 6 else {
            errorMessage = "Password must be at least 6 characters"
            isSubmitting = false
            return
        }

        guard email.contains("@") && email.contains(".") else {
            errorMessage = "Please enter a valid email address"
            isSubmitting = false
            return
        }

        // Build request
        let request = CreateUserRequest(
            email: email.trimmingCharacters(in: .whitespacesAndNewlines),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            role: selectedRole,
            initial_password: password,
            must_change_password: mustChangePassword,
            groups: selectedGroups.isEmpty ? nil : Array(selectedGroups)
        )

        do {
            try await viewModel.createUser(request)
            dismiss()
        } catch {
            errorMessage = "Failed to create user: \(error.localizedDescription)"
            isSubmitting = false
        }
    }
}
