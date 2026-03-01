//
//  ShareViewerView.swift
//  OpenPhotos
//
//  Full-screen view for viewing a share with photos, faces, comments, and likes.
//

import SwiftUI

/// Main view for viewing a share
struct ShareViewerView: View {
    let share: Share

    @StateObject private var viewModel: ShareViewerViewModel
    @State private var showImportConfirmation = false
    @State private var importSuccess = false
    @State private var showLogin = false
    @Environment(\.dismiss) private var dismiss

    init(share: Share) {
        self.share = share
        self._viewModel = StateObject(wrappedValue: ShareViewerViewModel(share: share))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Faces rail if enabled
                if share.includeFaces && !viewModel.faces.isEmpty {
                    ShareFacesRail(
                        faces: viewModel.faces,
                        selectedFaceId: viewModel.selectedFaceId,
                        shareId: share.id,
                        onFaceTap: { personId in
                            Task {
                                if viewModel.selectedFaceId == personId {
                                    await viewModel.clearFaceFilter()
                                } else {
                                    await viewModel.filterByFace(personId)
                                }
                            }
                        }
                    )
                    .frame(height: 100)

                    Divider()
                }

                // Photo grid
                if viewModel.isLoadingAssets && viewModel.assetIds.isEmpty {
                    ProgressView("Loading photos...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = viewModel.assetsError {
                    ErrorView(message: error) {
                        Task {
                            await viewModel.loadAssets(page: 1)
                        }
                    }
                } else if viewModel.assetIds.isEmpty {
                    ShareEmptyStateView(
                        icon: "photo.stack",
                        title: "No Photos",
                        message: "This share doesn't contain any photos"
                    )
                } else {
                    SharePhotoGrid(
                        share: share,
                        viewModel: viewModel
                    )
                }
            }
            .navigationTitle(share.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if !viewModel.isSelectionMode {
                            Button {
                                viewModel.toggleSelectionMode()
                            } label: {
                                Label("Select", systemImage: "checkmark.circle")
                            }
                        } else {
                            Button {
                                viewModel.selectAll()
                            } label: {
                                Label("Select All", systemImage: "checkmark.square")
                            }

                            Button {
                                viewModel.deselectAll()
                            } label: {
                                Label("Deselect All", systemImage: "square")
                            }

                            Button {
                                viewModel.toggleSelectionMode()
                            } label: {
                                Label("Cancel", systemImage: "xmark")
                            }
                        }

                        Divider()

                        Button {
                            Task {
                                await viewModel.reload()
                            }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if viewModel.isSelectionMode && !viewModel.selectedAssetIds.isEmpty {
                    selectionBar
                }
            }
            .task {
                await viewModel.loadInitialData()
            }
            .alert("Import Photos", isPresented: $showImportConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Import") {
                    Task {
                        do {
                            try await viewModel.importSelectedAssets()
                            importSuccess = true
                        } catch {
                            print("Import failed: \(error)")
                        }
                    }
                }
            } message: {
                Text("Import \(viewModel.selectedAssetIds.count) photo(s) to your library?")
            }
            .alert("Import Complete", isPresented: $importSuccess) {
                Button("OK") {}
            } message: {
                Text("Photos have been imported to your library")
            }
            .sheet(isPresented: $showLogin) {
                LoginView()
            }
            .onReceive(NotificationCenter.default.publisher(for: .authUnauthorized)) { _ in
                showLogin = true
            }
        }
    }

    // MARK: - Selection Bar

    private var selectionBar: some View {
        VStack(spacing: 0) {
            Divider()

            HStack {
                Text("\(viewModel.selectedAssetIds.count) selected")
                    .font(.subheadline)

                Spacer()

                Button {
                    showImportConfirmation = true
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .background(Color(.systemBackground))
        }
    }
}

#Preview {
    ShareViewerView(
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
            recipients: []
        )
    )
}
