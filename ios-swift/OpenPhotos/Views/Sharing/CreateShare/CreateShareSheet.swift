//
//  CreateShareSheet.swift
//  OpenPhotos
//
//  Sheet for creating a new share with Internal and Public Link tabs.
//

import SwiftUI

/// Sheet for creating a new share
struct CreateShareSheet: View {
    let objectKind: Share.ObjectKind
    let objectId: String
    let objectName: String?
    let selectionCount: Int
    let onShareCreated: (() -> Void)?

    @StateObject private var viewModel: CreateShareViewModel
    @State private var showSuccessAlert = false
    @Environment(\.dismiss) private var dismiss

    init(
        objectKind: Share.ObjectKind,
        objectId: String,
        objectName: String? = nil,
        selectionCount: Int = 1,
        onShareCreated: (() -> Void)? = nil
    ) {
        self.objectKind = objectKind
        self.objectId = objectId
        self.objectName = objectName
        self.selectionCount = selectionCount
        self.onShareCreated = onShareCreated
        self._viewModel = StateObject(wrappedValue: CreateShareViewModel(
            objectKind: objectKind,
            objectId: objectId,
            objectName: objectName,
            selectionCount: selectionCount
        ))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Tab picker
                Picker("Share Type", selection: $viewModel.selectedTab) {
                    ForEach(CreateShareViewModel.ShareTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 12)
                .background(Color(uiColor: .systemGroupedBackground))

                // Form content based on selected tab
                Form {
                    if viewModel.selectedTab == .internal {
                        internalTabContent
                    } else {
                        publicLinkTabContent
                    }

                    // Error message
                    if let error = viewModel.error {
                        Section {
                            Text(error)
                                .foregroundColor(.red)
                                .font(.caption)
                        }
                    }
                }

                // Bottom button
                Button {
                    Task {
                        do {
                            try await viewModel.createShare()
                            onShareCreated?()
                            showSuccessAlert = true
                        } catch {
                            // Error is displayed in form
                        }
                    }
                } label: {
                    Text(viewModel.createButtonTitle)
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(viewModel.canCreate ? Color.accentColor : Color.gray.opacity(0.5))
                        .cornerRadius(12)
                }
                .disabled(!viewModel.canCreate)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(uiColor: .systemGroupedBackground))
            }
            .navigationTitle("Share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .alert(viewModel.selectedTab == .internal ? "Share Created" : "Link Created", isPresented: $showSuccessAlert) {
                Button("OK") {
                    dismiss()
                }
            } message: {
                Text(viewModel.selectedTab == .internal
                     ? "Your share has been created successfully"
                     : "Your public link has been created successfully")
            }
        }
    }

    // MARK: - Internal Tab Content

    @ViewBuilder
    private var internalTabContent: some View {
        // Share name
        Section {
            TextField("Share name", text: $viewModel.shareName)
        } header: {
            Text("Name")
        } footer: {
            if let objectName = objectName {
                Text("Sharing: \(objectKind.rawValue) \"\(objectName)\"")
                    .font(.caption)
            }
        }

        // Recipients
        Section {
            RecipientInputView(recipients: $viewModel.recipients)
        } footer: {
            Text("Add people who can access this share")
        }

        // Permissions
        Section {
            SharePermissionsView(permissions: $viewModel.permissions)
        }

        // Options
        Section("Options") {
            // Expiry date
            Toggle("Set expiry date", isOn: $viewModel.hasExpiry)

            if viewModel.hasExpiry {
                DatePicker(
                    "Expires on",
                    selection: Binding(
                        get: { viewModel.expiryDate ?? Date().addingTimeInterval(86400 * 7) },
                        set: { viewModel.expiryDate = $0 }
                    ),
                    in: Date()...,
                    displayedComponents: [.date]
                )
            }

            // Include faces
            if objectKind == .album {
                Toggle("Include faces", isOn: $viewModel.includeFaces)
            }
        }
    }

    // MARK: - Public Link Tab Content

    @ViewBuilder
    private var publicLinkTabContent: some View {
        // Name section
        Section {
            TextField("Share name", text: $viewModel.shareName)
        } header: {
            Text("Name")
        }

        // Share mode (for multi-selection)
        if selectionCount > 1 {
            Section {
                Picker("Share Mode", selection: $viewModel.pubShareSelection) {
                    Text("Share selection (\(selectionCount) items)").tag(true)
                    Text("Share first item").tag(false)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }

        // Options section
        Section {
            Toggle("Contents moderation enabled", isOn: $viewModel.pubModeration)
        } header: {
            Text("Options")
        } footer: {
            Text("Moderation allows you to review uploads before they appear")
                .font(.caption)
        }

        // Role section
        Section {
            Picker("Role", selection: $viewModel.pubRole) {
                Text("Viewer").tag(SharePermissions.viewer)
                Text("Commenter").tag(SharePermissions.commenter)
                Text("Contributor").tag(SharePermissions.contributor)
            }
        } header: {
            Text("Permissions")
        }

        // Expires section
        Section {
            Toggle("Set expiry date", isOn: $viewModel.pubHasExpiry)

            if viewModel.pubHasExpiry {
                DatePicker(
                    "Expires",
                    selection: $viewModel.pubExpiryDate,
                    in: Date()...,
                    displayedComponents: [.date]
                )
                .datePickerStyle(.compact)
            }
        } footer: {
            if !viewModel.pubHasExpiry {
                Text("Link will never expire")
                    .font(.caption)
            }
        }

        // Security section
        Section {
            Toggle("Require 8-character PIN", isOn: $viewModel.pubRequirePin)

            if viewModel.pubRequirePin {
                SecureField("Enter PIN", text: $viewModel.pubPin)
                    .keyboardType(.numberPad)

                if !viewModel.pubPin.isEmpty && viewModel.pubPin.count != 8 {
                    Text("PIN must be exactly 8 characters")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
        } header: {
            Text("Security")
        }

        // Cover image section
        Section {
            HStack(spacing: 12) {
                // Cover thumbnail
                CoverThumbnailView(assetId: viewModel.pubCoverAssetId)
                    .frame(width: 64, height: 64)
                    .cornerRadius(8)

                Button("Choose cover") {
                    viewModel.showCoverPicker = true
                }
                .buttonStyle(.bordered)

                Spacer()
            }
        } header: {
            Text("Cover image (optional)")
        }
        .navigationDestination(isPresented: $viewModel.showCoverPicker) {
            CoverPhotoPickerView(onSelection: { assetId in
                viewModel.pubCoverAssetId = assetId
                viewModel.showCoverPicker = false
            }, onCancel: {
                viewModel.showCoverPicker = false
            })
        }
    }
}

// MARK: - Cover Thumbnail View

/// Displays a thumbnail for the selected cover photo
private struct CoverThumbnailView: View {
    let assetId: String?

    @State private var thumbnailImage: UIImage? = nil
    @State private var isLoading = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.2))

            if let image = thumbnailImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipped()
            } else if isLoading {
                ProgressView()
                    .scaleEffect(0.5)
            } else {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 24))
                    .foregroundColor(.gray)
            }
        }
        .onChange(of: assetId) { _, newValue in
            if newValue != nil {
                loadThumbnail()
            } else {
                thumbnailImage = nil
            }
        }
        .onAppear {
            if assetId != nil {
                loadThumbnail()
            }
        }
    }

    private func loadThumbnail() {
        guard let assetId = assetId, !isLoading else { return }

        isLoading = true

        Task {
            do {
                let client = AuthorizedHTTPClient.shared
                let url = client.buildURL(path: "/api/thumbnails/\(assetId)")
                var request = URLRequest(url: url)
                request.httpMethod = "GET"

                let (data, response) = try await client.request(request)

                if (200..<300).contains(response.statusCode),
                   let image = UIImage(data: data) {
                    await MainActor.run {
                        self.thumbnailImage = image
                        self.isLoading = false
                    }
                } else {
                    await MainActor.run {
                        self.isLoading = false
                    }
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                }
            }
        }
    }
}

#Preview("Internal Share") {
    CreateShareSheet(
        objectKind: .album,
        objectId: "42",
        objectName: "Trip Photos"
    )
}

#Preview("Public Link") {
    CreateShareSheet(
        objectKind: .asset,
        objectId: "123",
        objectName: "Beach Photo",
        selectionCount: 2
    )
}
