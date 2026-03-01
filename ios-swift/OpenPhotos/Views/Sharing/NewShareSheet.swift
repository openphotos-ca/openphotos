//
//  NewShareSheet.swift
//  OpenPhotos
//
//  Main share sheet with Internal and Public Link tabs.
//  Provides comprehensive share creation UI with recipient selection,
//  permissions, E2EE support, and validation.
//

import SwiftUI

/// Main share sheet for creating internal shares and public links
struct NewShareSheet: View {
    // MARK: - Properties

    /// Album ID to share
    let albumId: Int

    /// Album name (optional)
    let albumName: String?

    /// Whether the album is a live/dynamic album
    let isLiveAlbum: Bool

    /// View model for share creation
    @StateObject private var viewModel: NewShareViewModel

    /// Environment dismiss action
    @Environment(\.dismiss) private var dismiss

    // MARK: - Initialization

    init(albumId: Int, albumName: String?, isLiveAlbum: Bool) {
        self.albumId = albumId
        self.albumName = albumName
        self.isLiveAlbum = isLiveAlbum

        // Initialize view model
        _viewModel = StateObject(wrappedValue: NewShareViewModel(
            albumId: albumId,
            albumName: albumName,
            isLiveAlbum: isLiveAlbum
        ))
    }

    // MARK: - Body

    var body: some View {
        let _ = print("🔍 NewShareSheet body rendering - selectedTab: \(viewModel.selectedTab.rawValue)")

        return NavigationStack {
            VStack(spacing: 0) {
                // Tab picker outside of Form for better rendering
                Picker("Share Type", selection: $viewModel.selectedTab) {
                    ForEach(NewShareViewModel.ShareTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 12)
                .background(Color(uiColor: .systemGroupedBackground))
                .onAppear {
                    print("🔍 Picker appeared")
                }

                // Form content
                Form {
                    let _ = print("🔍 Form rendering - tab: \(viewModel.selectedTab.rawValue)")

                    // Conditional content based on selected tab
                    if viewModel.selectedTab == .internal {
                        let _ = print("🔍 Rendering internal tab content")
                        internalTabContent
                    } else {
                        let _ = print("🔍 Rendering public link tab content")
                        publicLinkTabContent
                    }

                    // Error display
                    if let error = viewModel.error {
                        Section {
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                }
                .onAppear {
                    print("🔍 Form appeared")
                }
            }
            .navigationTitle("Share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Share") {
                        Task {
                            await viewModel.createShare()
                        }
                    }
                    .disabled(!viewModel.canCreate)
                }
            }
            .onAppear {
                print("✅ NewShareSheet appeared - Album ID: \(albumId), Name: \(albumName ?? "nil")")
                Task {
                    await viewModel.loadShareTargets()
                }
            }
            .overlay {
                if viewModel.isLoading {
                    ZStack {
                        Color.black.opacity(0.3)
                        ProgressView()
                            .tint(.white)
                    }
                    .ignoresSafeArea()
                }
            }
            .overlay(alignment: .top) {
                // Toast overlay directly on NavigationStack
                if viewModel.showToast {
                    ToastView(
                        message: viewModel.toastMessage,
                        isShowing: $viewModel.showToast,
                        duration: 3.0,
                        type: viewModel.toastType
                    )
                    .padding(.top, 8)
                    .zIndex(999)
                }
            }
        }
    }

    // MARK: - Internal Tab Content

    /// Content for the Internal sharing tab
    @ViewBuilder
    private var internalTabContent: some View {
        let _ = print("🔍 internalTabContent builder called - shareName: \(viewModel.shareName)")

        // Name section
        Section {
            TextField("Share name", text: $viewModel.shareName)
                .onAppear {
                    print("🔍 Name TextField appeared")
                }
        } header: {
            Text("Name")
        } footer: {
            if let albumName = albumName {
                Text("Sharing album \"\(albumName)\"")
                    .font(.caption)
            }
        }

        // Invite people or groups section
        Section {
            ShareTargetsList(
                targets: viewModel.availableTargets,
                selectedTargets: viewModel.selectedRecipients,
                isLoading: viewModel.isLoadingTargets,
                onToggle: { target in
                    viewModel.toggleRecipient(target)
                }
            )
        } header: {
            Text("Invite people or groups")
        }

        // Selected recipients chips
        if !viewModel.selectedRecipients.isEmpty {
            Section {
                RecipientChipsView(
                    recipients: viewModel.selectedRecipients,
                    onRemove: { target in
                        viewModel.removeRecipient(target)
                    }
                )
            }
        }

        // Options section
        Section {
            Toggle("Include Faces", isOn: $viewModel.includeFaces)

            Toggle("Include sub-albums", isOn: $viewModel.includeSubtree)

            // Show "Keep Live Updates" only for live albums
            if isLiveAlbum && viewModel.includeSubtree {
                Toggle("Keep Live Updates", isOn: $viewModel.keepLiveUpdates)
                    .disabled(!viewModel.includeSubtree)
            }
        } header: {
            Text("Options")
        }

        // Permissions section
        Section {
            // Role picker
            Picker("Role", selection: $viewModel.role) {
                Text("Viewer").tag(SharePermissions.viewer)
                Text("Commenter").tag(SharePermissions.commenter)
                Text("Contributor").tag(SharePermissions.contributor)
            }

            // Only show comment/like toggles for non-Viewer roles
            if viewModel.role != .viewer {
                Toggle("Allow comments", isOn: $viewModel.allowComments)
                Toggle("Allow likes", isOn: $viewModel.allowLikes)
            }
        } header: {
            Text("Permissions")
        }

        // Expires section
        Section {
            DatePicker(
                "Expiration Date",
                selection: $viewModel.expiryDate,
                in: Date()...,
                displayedComponents: [.date]
            )
            .datePickerStyle(.compact)
        } header: {
            Text("Expires")
        } footer: {
            Text("Share will expire on the selected date")
                .font(.caption)
        }
    }

    // MARK: - Public Link Tab Content

    /// Content for the Public Link tab
    @ViewBuilder
    private var publicLinkTabContent: some View {
        // Name section
        Section {
            TextField("Public link name", text: $viewModel.shareName)
        } header: {
            Text("Name")
        } footer: {
            if let albumName = albumName {
                Text("Sharing album \"\(albumName)\"")
                    .font(.caption)
            }
        }

        // Options section
        Section {
            Toggle("Include album content", isOn: $viewModel.pubIncludeAlbum)

            Toggle("Contents moderation enabled", isOn: $viewModel.pubModeration)
        } header: {
            Text("Options")
        } footer: {
            Text("Moderation allows you to review and approve uploads before they appear")
                .font(.caption)
        }

        // Permissions section
        Section {
            // Role picker
            Picker("Role", selection: $viewModel.pubRole) {
                Text("Viewer").tag(SharePermissions.viewer)
                Text("Commenter").tag(SharePermissions.commenter)
                Text("Contributor").tag(SharePermissions.contributor)
            }

            // Only show comment/like toggles for non-Viewer roles
            if viewModel.pubRole != .viewer {
                Toggle("Allow comments", isOn: $viewModel.pubAllowComments)
                Toggle("Allow likes", isOn: $viewModel.pubAllowLikes)
            }
        } header: {
            Text("Permissions")
        }

        // Expires section
        Section {
            DatePicker(
                "Expiration Date",
                selection: $viewModel.pubExpiryDate,
                in: Date()...,
                displayedComponents: [.date]
            )
            .datePickerStyle(.compact)
        } header: {
            Text("Expires")
        } footer: {
            Text("Public link will expire on the selected date")
                .font(.caption)
        }

        // Security section
        Section {
            Toggle("Require PIN", isOn: $viewModel.pubRequirePin)

            if viewModel.pubRequirePin {
                SecureField("8-character PIN", text: $viewModel.pubPin)
                    .keyboardType(.numberPad)

                if !viewModel.pubPin.isEmpty && viewModel.pubPin.count != 8 {
                    Text("PIN must be exactly 8 characters")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
        } header: {
            Text("Security")
        } footer: {
            if viewModel.pubRequirePin {
                Text("Users will need to enter this PIN to access the public link")
                    .font(.caption)
            }
        }

        // Cover Image section - Auto-selected from album
        Section {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 64, height: 64)
                    .overlay(
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 24))
                            .foregroundColor(.gray)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text("Auto-selected")
                        .font(.subheadline)
                        .foregroundColor(.primary)

                    Text("First album photo will be used")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
        } header: {
            Text("Cover Image")
        } footer: {
            Text("The first photo from the album will be used as the cover image")
                .font(.caption)
        }

        // E2EE Preparation Progress (if active)
        if viewModel.prepBusy {
            Section {
                VStack(spacing: 12) {
                    ProgressView(value: Double(viewModel.prepDone), total: Double(viewModel.prepTotal))
                        .progressViewStyle(.linear)

                    Text("\(viewModel.prepMsg): \(viewModel.prepDone)/\(viewModel.prepTotal)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
            }
        }
    }
}

// MARK: - Preview

#Preview("Internal Share") {
    NewShareSheet(
        albumId: 42,
        albumName: "Summer Vacation 2024",
        isLiveAlbum: false
    )
}

#Preview("Public Link") {
    struct PreviewWrapper: View {
        @State private var showSheet = true

        var body: some View {
            Color.gray
                .sheet(isPresented: $showSheet) {
                    NewShareSheet(
                        albumId: 42,
                        albumName: "Summer Vacation 2024",
                        isLiveAlbum: false
                    )
                }
        }
    }

    return PreviewWrapper()
}
