//
//  PublicLinksTab.swift
//  OpenPhotos
//
//  Tab showing public links created by the current user.
//

import SwiftUI

/// Tab displaying public links created by user
struct PublicLinksTab: View {
    @ObservedObject var viewModel: SharingViewModel
    @State private var showCreateLink = false

    var body: some View {
        Group {
            if viewModel.isLoadingPublicLinks && viewModel.publicLinks.isEmpty {
                ProgressView("Loading public links...")
            } else if let error = viewModel.publicLinksError {
                ErrorView(message: error) {
                    Task {
                        await viewModel.loadPublicLinks(forceRefresh: true)
                    }
                }
            } else if viewModel.publicLinks.isEmpty {
                ShareEmptyStateView(
                    icon: "link",
                    title: "No Public Links",
                    message: "Create a public link to share via URL"
                ) {
                    Button("Create Public Link") {
                        showCreateLink = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    ForEach(viewModel.publicLinks) { link in
                        PublicLinkRowView(link: link) {
                            // Refresh the public links when a link is updated
                            Task { @MainActor in
                                await viewModel.loadPublicLinks(forceRefresh: true)
                            }
                        }
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                            .listRowSeparator(.visible)
                    }
                }
                .listStyle(.plain)
                .refreshable {
                    await viewModel.loadPublicLinks(forceRefresh: true)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showCreateLink = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .task {
            if viewModel.publicLinks.isEmpty {
                await viewModel.loadPublicLinks()
            }
        }
        .sheet(isPresented: $showCreateLink) {
            CreatePublicLinkSheet()
        }
    }
}

#Preview {
    PublicLinksTab(viewModel: SharingViewModel())
}
