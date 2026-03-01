//
//  SharingView.swift
//  OpenPhotos
//
//  Main sharing view with 3 tabs: My Shares, Shared with me, Public Links.
//

import SwiftUI

/// Main sharing view with tabbed interface
struct SharingView: View {
    @StateObject private var viewModel = SharingViewModel()
    @State private var showLogin = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Tab picker
                Picker("Sharing Type", selection: $viewModel.selectedTab) {
                    Text("My Shares").tag(ShareTab.myShares)
                    Text("Shared with me").tag(ShareTab.sharedWithMe)
                    Text("Public Links").tag(ShareTab.publicLinks)
                }
                .pickerStyle(.segmented)
                .padding()

                // Tab content
                TabView(selection: $viewModel.selectedTab) {
                    MySharesTab(viewModel: viewModel)
                        .tag(ShareTab.myShares)

                    SharedWithMeTab(viewModel: viewModel)
                        .tag(ShareTab.sharedWithMe)

                    PublicLinksTab(viewModel: viewModel)
                        .tag(ShareTab.publicLinks)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            .navigationTitle("Sharing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                    }
                }
            }
            .sheet(isPresented: $showLogin) {
                LoginView()
            }
            .onReceive(NotificationCenter.default.publisher(for: .authUnauthorized)) { _ in
                showLogin = true
            }
        }
    }
}

/// Tab selection enum
enum ShareTab {
    case myShares
    case sharedWithMe
    case publicLinks
}

#Preview {
    SharingView()
}
