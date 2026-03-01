import SwiftUI

/// Modal sheet for resetting a user's password.
/// Two modes:
/// 1. Admin resetting another user's password (only new password required)
/// 2. User resetting own password (current password + new password required)
struct ResetPasswordSheet: View {
    @EnvironmentObject var viewModel: TeamManagementViewModel
    @EnvironmentObject var auth: AuthManager
    @Environment(\.dismiss) var dismiss

    let user: TeamUser

    // Form fields
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""

    // UI state
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationView {
            Form {
                // Current Password (only for self-service)
                if isSelfReset {
                    Section("Current Password") {
                        SecureField("Current Password", text: $currentPassword)
                            .textContentType(.password)
                            .disabled(isSubmitting)
                    }
                }

                // New Password
                Section("New Password") {
                    SecureField("New Password (min 6 characters)", text: $newPassword)
                        .textContentType(.newPassword)
                        .disabled(isSubmitting)

                    SecureField("Confirm New Password", text: $confirmPassword)
                        .textContentType(.newPassword)
                        .disabled(isSubmitting)
                }

                // Info Text
                Section {
                    if isSelfReset {
                        Text("Enter your current password and choose a new password.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Setting a new password for \(user.name). The user will be required to change this password on next login.")
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
            .navigationTitle("Reset Password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Reset") {
                        Task { await resetPassword() }
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

    // MARK: - Computed Properties

    /// True if user is resetting their own password (requires current password).
    private var isSelfReset: Bool {
        user.user_id == auth.userId
    }

    // MARK: - Validation

    private var isFormValid: Bool {
        // For self-reset, current password is required
        if isSelfReset && currentPassword.isEmpty {
            return false
        }

        // New password and confirmation are always required
        guard !newPassword.isEmpty, !confirmPassword.isEmpty else {
            return false
        }

        // Password minimum length
        guard newPassword.count >= 6 else {
            return false
        }

        // Passwords must match
        guard newPassword == confirmPassword else {
            return false
        }

        return true
    }

    // MARK: - Actions

    private func resetPassword() async {
        errorMessage = nil
        isSubmitting = true

        // Validation
        guard newPassword == confirmPassword else {
            errorMessage = "Passwords do not match"
            isSubmitting = false
            return
        }

        guard newPassword.count >= 6 else {
            errorMessage = "Password must be at least 6 characters"
            isSubmitting = false
            return
        }

        do {
            try await viewModel.resetPassword(
                user: user,
                newPassword: newPassword,
                currentPassword: isSelfReset ? currentPassword : nil
            )
            dismiss()
        } catch {
            errorMessage = "Failed to reset password: \(error.localizedDescription)"
            isSubmitting = false
        }
    }
}
