//
//  CreatePublicLinkSheet.swift
//  OpenPhotos
//
//  Sheet for creating a new public link.
//

import SwiftUI

/// Sheet for creating a public link
struct CreatePublicLinkSheet: View {
    @State private var linkName = ""
    @State private var scopeKind: String = "album"
    @State private var scopeAlbumId: String = ""
    @State private var coverAssetId: String = ""
    @State private var permissions: SharePermissions = .viewer
    @State private var pin: String = ""
    @State private var hasPin = false
    @State private var expiryDate: Date?
    @State private var hasExpiry = false

    @State private var isCreating = false
    @State private var error: String?
    @State private var createdLink: PublicLink?
    @State private var showQRView = false
    @Environment(\.dismiss) private var dismiss

    private let shareService = ShareService.shared
    private let e2eeManager = ShareE2EEManager.shared

    var body: some View {
        NavigationStack {
            Form {
                // Link name
                Section("Name") {
                    TextField("Link name", text: $linkName)
                }

                // Scope selection
                Section {
                    Picker("Type", selection: $scopeKind) {
                        Text("Album").tag("album")
                        Text("Asset").tag("asset")
                    }
                    .pickerStyle(.segmented)

                    if scopeKind == "album" {
                        TextField("Album ID", text: $scopeAlbumId)
                            .keyboardType(.numberPad)
                    } else {
                        TextField("Asset ID", text: $coverAssetId)
                    }
                } header: {
                    Text("Scope")
                } footer: {
                    Text("Select what to share via this public link")
                }

                // Cover asset
                if scopeKind == "album" {
                    Section {
                        TextField("Cover Asset ID (optional)", text: $coverAssetId)
                    } header: {
                        Text("Cover Asset")
                    } footer: {
                        Text("Asset to use as cover image")
                    }
                }

                // Permissions
                Section {
                    SharePermissionsView(permissions: $permissions)
                }

                // PIN protection
                Section {
                    Toggle("PIN Protection", isOn: $hasPin)

                    if hasPin {
                        TextField("8-digit PIN", text: $pin)
                            .keyboardType(.numberPad)
                            .onChange(of: pin) { _, newValue in
                                // Limit to 8 characters
                                if newValue.count > 8 {
                                    pin = String(newValue.prefix(8))
                                }
                            }
                    }
                } header: {
                    Text("Security")
                } footer: {
                    if hasPin {
                        Text("Enter an 8-digit PIN. Users will need this PIN to access the link.")
                    }
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
            .navigationTitle("Create Public Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            await createPublicLink()
                        }
                    }
                    .disabled(!canCreate || isCreating)
                }
            }
            .sheet(isPresented: $showQRView) {
                if let link = createdLink {
                    PublicLinkQRView(link: link, onDismiss: {
                        dismiss()
                    })
                }
            }
        }
    }

    // MARK: - Validation

    private var canCreate: Bool {
        let hasValidName = !linkName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasValidScope = (scopeKind == "album" && !scopeAlbumId.isEmpty) ||
                           (scopeKind == "asset" && !coverAssetId.isEmpty)
        let hasValidPin = !hasPin || pin.count == 8

        return hasValidName && hasValidScope && hasValidPin
    }

    // MARK: - Create Public Link

    private func createPublicLink() async {
        guard canCreate else { return }

        isCreating = true
        error = nil

        do {
            // Generate SMK and VK for E2EE
            let (smk, vk) = e2eeManager.generatePublicLinkKeys()

            // Build request
            let request = CreatePublicLinkRequest(
                name: linkName,
                scopeKind: scopeKind,
                scopeAlbumId: scopeKind == "album" ? Int(scopeAlbumId) : nil,
                permissions: permissions.rawValue,
                expiresAt: hasExpiry ? expiryDate?.ISO8601Format() : nil,
                pin: hasPin ? pin : nil,
                coverAssetId: coverAssetId.isEmpty ? "" : coverAssetId,
                moderationEnabled: nil
            )

            // Create public link
            let link = try await shareService.createPublicLink(request)

            // Append VK to the URL
            var urlWithVK = link.url ?? ""
            if !urlWithVK.contains("#vk=") {
                urlWithVK += "#vk=\(vk.base64EncodedString())"
            }

            // Update link with VK in URL
            createdLink = PublicLink(
                id: link.id,
                ownerOrgId: link.ownerOrgId,
                ownerUserId: link.ownerUserId,
                name: link.name,
                scopeKind: link.scopeKind,
                scopeAlbumId: link.scopeAlbumId,
                uploadsAlbumId: link.uploadsAlbumId,
                url: urlWithVK,
                permissions: link.permissions,
                expiresAt: link.expiresAt,
                status: link.status,
                coverAssetId: link.coverAssetId,
                moderationEnabled: link.moderationEnabled,
                pendingCount: link.pendingCount,
                hasPin: link.hasPin,
                key: link.key,
                createdAt: link.createdAt,
                updatedAt: link.updatedAt
            )

            isCreating = false
            showQRView = true
        } catch {
            self.error = error.localizedDescription
            isCreating = false
        }
    }
}

#Preview {
    CreatePublicLinkSheet()
}
