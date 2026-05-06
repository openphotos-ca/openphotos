import SwiftUI

struct ChangePasswordView: View {
    @EnvironmentObject var auth: AuthManager

    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""

    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private var isFormValid: Bool {
        !currentPassword.isEmpty &&
            newPassword.count >= 6 &&
            newPassword == confirmPassword
    }

    var body: some View {
        Form {
            Section(L10n.tr("Current Password")) {
                SecureField(L10n.tr("Current Password"), text: $currentPassword)
                    .textContentType(.password)
                    .disabled(isSubmitting)
            }

            Section(L10n.tr("New Password")) {
                SecureField(L10n.tr("New Password (min 6 characters)"), text: $newPassword)
                    .textContentType(.newPassword)
                    .disabled(isSubmitting)

                SecureField(L10n.tr("Confirm New Password"), text: $confirmPassword)
                    .textContentType(.newPassword)
                    .disabled(isSubmitting)
            }

            Section {
                Text(L10n.tr("Changing your password will sign you out on this device."))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }

            Section {
                Button {
                    Task { await submit() }
                } label: {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Text(L10n.tr("Change Password"))
                    }
                }
                .disabled(!isFormValid || isSubmitting)
            }
        }
        .navigationTitle(L10n.tr("Change Password"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func submit() async {
        errorMessage = nil
        guard !currentPassword.isEmpty else {
            errorMessage = L10n.tr("Current password is required")
            return
        }
        guard newPassword.count >= 6 else {
            errorMessage = L10n.tr("Password must be at least 6 characters")
            return
        }
        guard newPassword == confirmPassword else {
            errorMessage = L10n.tr("Passwords do not match")
            return
        }

        isSubmitting = true
        defer { isSubmitting = false }

        do {
            try await auth.changePassword(newPassword: newPassword, currentPassword: currentPassword)
            ToastManager.shared.show(L10n.tr("Password changed. Please sign in again."))
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
