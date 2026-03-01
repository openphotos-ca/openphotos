//
//  SharedWithMeTab.swift
//  OpenPhotos
//
//  Tab showing shares received from other users.
//

import SwiftUI

/// Tab displaying incoming shares received by user
struct SharedWithMeTab: View {
    @ObservedObject var viewModel: SharingViewModel

    var body: some View {
        Group {
            if viewModel.isLoadingReceived && viewModel.receivedShares.isEmpty {
                ProgressView("Loading shares...")
            } else if let error = viewModel.receivedError {
                ErrorView(message: error) {
                    Task {
                        await viewModel.loadReceivedShares(forceRefresh: true)
                    }
                }
            } else if viewModel.receivedShares.isEmpty {
                ShareEmptyStateView(
                    icon: "tray.2",
                    title: "No Shared Items",
                    message: "Items shared with you will appear here"
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: [
                        GridItem(.adaptive(minimum: 160), spacing: 16)
                    ], spacing: 16) {
                        ForEach(viewModel.receivedShares) { share in
                            ShareCard(share: share, isOwner: false)
                        }
                    }
                    .padding(8)
                }
                .refreshable {
                    await viewModel.loadReceivedShares(forceRefresh: true)
                }
            }
        }
        .task {
            if viewModel.receivedShares.isEmpty {
                await viewModel.loadReceivedShares()
            }
        }
    }
}

#Preview {
    SharedWithMeTab(viewModel: SharingViewModel())
}
