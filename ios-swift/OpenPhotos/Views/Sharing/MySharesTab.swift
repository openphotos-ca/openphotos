//
//  MySharesTab.swift
//  OpenPhotos
//
//  Tab showing shares created by the current user.
//

import SwiftUI

/// Tab displaying outgoing shares created by user
struct MySharesTab: View {
    @ObservedObject var viewModel: SharingViewModel
    @State private var showCreateShare = false

    var body: some View {
        Group {
            if viewModel.isLoadingOutgoing && viewModel.outgoingShares.isEmpty {
                ProgressView("Loading shares...")
            } else if let error = viewModel.outgoingError {
                ErrorView(message: error) {
                    Task {
                        await viewModel.loadOutgoingShares(forceRefresh: true)
                    }
                }
            } else if viewModel.outgoingShares.isEmpty {
                ShareEmptyStateView(
                    icon: "square.and.arrow.up",
                    title: "No Shares",
                    message: "Create a share to get started"
                ) {
                    Button("Create Share") {
                        showCreateShare = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                let columns = [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12)
                ]

                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(viewModel.outgoingShares) { share in
                            ShareCard(share: share, isOwner: true)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .refreshable {
                    await viewModel.loadOutgoingShares(forceRefresh: true)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showCreateShare = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .task {
            if viewModel.outgoingShares.isEmpty {
                await viewModel.loadOutgoingShares()
            }
        }
        .sheet(isPresented: $showCreateShare) {
            // Note: When opened from here, we don't have context
            // This will be properly implemented when adding share creation entry points (Step 17)
            CreateShareSheet(
                objectKind: .album,
                objectId: "", // No specific context from this tab
                objectName: nil
            )
        }
    }
}

#Preview {
    MySharesTab(viewModel: SharingViewModel())
}
