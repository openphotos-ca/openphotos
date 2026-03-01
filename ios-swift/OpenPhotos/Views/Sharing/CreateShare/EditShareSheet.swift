//
//  EditShareSheet.swift
//  OpenPhotos
//
//  Sheet for editing an existing share.
//

import SwiftUI

/// Sheet for editing a share
struct EditShareSheet: View {
    let share: Share

    @State private var shareName: String
    @State private var recipients: [RecipientInput] = []
    @State private var permissions: SharePermissions
    @State private var expiryDate: Date?
    @State private var hasExpiry: Bool
    @State private var includeFaces: Bool

    @State private var isUpdating = false
    @State private var isDeleting = false
    @State private var showDeleteConfirmation = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    private let shareService = ShareService.shared

    init(share: Share) {
        self.share = share
        self._shareName = State(initialValue: share.name)
        self._permissions = State(initialValue: SharePermissions(rawValue: share.defaultPermissions))
        self._expiryDate = State(initialValue: share.expiresAt)
        self._hasExpiry = State(initialValue: share.expiresAt != nil)
        self._includeFaces = State(initialValue: share.includeFaces)
    }

    var body: some View {
        NavigationStack {
            Form {
                // Share name
                Section("Name") {
                    TextField("Share name", text: $shareName)
                }

                // Recipients
                Section {
                    RecipientInputView(recipients: $recipients)

                    // Existing recipients
                    if !share.recipients.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Current Recipients")
                                .font(.subheadline)
                                .foregroundColor(.secondary)

                            ForEach(share.recipients) { recipient in
                                HStack {
                                    Image(systemName: iconForRecipient(recipient))
                                        .font(.caption)

                                    Text(recipient.recipientIdentifier)
                                        .font(.subheadline)

                                    Spacer()

                                    Button {
                                        Task {
                                            await removeRecipient(recipient)
                                        }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.red)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Recipients")
                } footer: {
                    Text("Add or remove people who can access this share")
                }

                // Permissions
                Section {
                    SharePermissionsView(permissions: $permissions)
                }

                // Options
                Section("Options") {
                    // Expiry date
                    Toggle("Set expiry date", isOn: $hasExpiry)

                    if hasExpiry {
                        DatePicker(
                            "Expires on",
                            selection: Binding(
                                get: { expiryDate ?? Date().addingTimeInterval(86400 * 7) },
                                set: { expiryDate = $0 }
                            ),
                            in: Date()...,
                            displayedComponents: [.date]
                        )
                    }

                    // Include faces
                    if share.objectKind == .album {
                        Toggle("Include faces", isOn: $includeFaces)
                    }
                }

                // Delete section
                Section {
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        HStack {
                            Spacer()
                            if isDeleting {
                                ProgressView()
                            } else {
                                Text("Revoke Share")
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(isDeleting || isUpdating)
                }

                // Error message
                if let error = error {
                    Section {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Edit Share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await updateShare()
                        }
                    }
                    .disabled(isUpdating || isDeleting || !canSave)
                }
            }
            .confirmationDialog("Revoke Share", isPresented: $showDeleteConfirmation) {
                Button("Revoke", role: .destructive) {
                    Task {
                        await deleteShare()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Are you sure you want to revoke this share? Recipients will lose access immediately.")
            }
        }
        .task {
            // Load existing recipients into editable format
            recipients = share.recipients.map { recipient in
                RecipientInput(
                    type: RecipientInput.RecipientType(rawValue: recipient.recipientType.rawValue) ?? .user,
                    identifier: recipient.recipientIdentifier,
                    displayName: recipient.displayLabel
                )
            }
        }
    }

    // MARK: - Helpers

    private var canSave: Bool {
        return !shareName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func iconForRecipient(_ recipient: ShareRecipient) -> String {
        switch recipient.recipientType {
        case .user: return "person.fill"
        case .group: return "person.2.fill"
        case .externalEmail: return "envelope.fill"
        }
    }

    // MARK: - Actions

    /// Update share
    private func updateShare() async {
        guard canSave else { return }

        isUpdating = true
        error = nil

        do {
            // Add new recipients if any
            for recipient in recipients {
                // Check if not already in share.recipients
                let exists = share.recipients.contains { existing in
                    existing.recipientType.rawValue == recipient.type.rawValue &&
                    existing.recipientIdentifier == recipient.identifier
                }

                if !exists {
                    let recipientInput = CreateShareRequest.RecipientInput(
                        type: recipient.type.rawValue,
                        id: recipient.identifier,
                        email: nil,
                        permissions: nil
                    )
                    try await shareService.addRecipients(shareId: share.id, recipients: [recipientInput])
                }
            }

            // Update share details
            let request = UpdateShareRequest(
                name: shareName != share.name ? shareName : nil,
                defaultPermissions: permissions.rawValue != share.defaultPermissions ? permissions.rawValue : nil,
                expiresAt: hasExpiry ? expiryDate?.ISO8601Format() : nil,
                includeFaces: includeFaces != share.includeFaces ? includeFaces : nil
            )

            _ = try await shareService.updateShare(id: share.id, request)

            isUpdating = false
            dismiss()
        } catch {
            self.error = error.localizedDescription
            isUpdating = false
        }
    }

    /// Remove a recipient
    private func removeRecipient(_ recipient: ShareRecipient) async {
        do {
            try await shareService.removeRecipient(
                shareId: share.id,
                recipientId: recipient.id
            )

            // Update UI would normally happen via refresh, but we can optimistically update
            // In a production app, you'd refresh the share data here
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Delete the share
    private func deleteShare() async {
        isDeleting = true
        error = nil

        do {
            try await shareService.deleteShare(id: share.id)
            isDeleting = false
            dismiss()
        } catch {
            self.error = error.localizedDescription
            isDeleting = false
        }
    }
}

#Preview {
    EditShareSheet(
        share: Share(
            id: "1",
            ownerOrgId: 1,
            ownerUserId: "user123",
            objectKind: .album,
            objectId: "42",
            defaultPermissions: SharePermissions.commenter.rawValue,
            expiresAt: nil,
            status: .active,
            createdAt: Date(),
            updatedAt: Date(),
            name: "Trip Photos",
            includeFaces: true,
            includeSubtree: false,
            recipients: [
                ShareRecipient(
                    id: "1",
                    recipientType: .user,
                    recipientUserId: "john_doe",
                    recipientGroupId: nil,
                    externalEmail: nil,
                    externalOrgId: nil,
                    permissions: nil,
                    invitationStatus: .active,
                    createdAt: Date()
                ),
                ShareRecipient(
                    id: "2",
                    recipientType: .externalEmail,
                    recipientUserId: nil,
                    recipientGroupId: nil,
                    externalEmail: "jane@example.com",
                    externalOrgId: nil,
                    permissions: nil,
                    invitationStatus: .active,
                    createdAt: Date()
                )
            ]
        )
    )
}
