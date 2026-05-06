import SwiftUI

/// Main container view for Users & Groups management (Enterprise Edition feature).
/// Shows organization name editing (creator-only), tab switcher, and tab content.
struct TeamManagementView: View {
    @StateObject private var viewModel = TeamManagementViewModel()
    @EnvironmentObject var auth: AuthManager
    @Binding var isPresented: Bool

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Organization Name Section (creator-only)
                if let org = viewModel.org, isCreator {
                    orgNameSection
                }

                // Tab Picker
                Picker(L10n.tr("Tab"), selection: $viewModel.activeTab) {
                    Text(L10n.tr("Users")).tag(TeamManagementViewModel.Tab.users)
                    Text(L10n.tr("Groups")).tag(TeamManagementViewModel.Tab.groups)
                }
                .pickerStyle(.segmented)
                .padding()

                // Tab Content
                if viewModel.activeTab == .users {
                    UsersTabView()
                        .environmentObject(viewModel)
                        .environmentObject(auth)
                } else {
                    GroupsTabView()
                        .environmentObject(viewModel)
                }
            }
            .navigationTitle(L10n.tr("Users & Groups"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await viewModel.loadAll() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(viewModel.loading)
                }
            }
            .onAppear {
                Task {
                    await viewModel.loadAll()
                }
            }
            .overlay {
                if let error = viewModel.error {
                    VStack {
                        Spacer()
                        HStack {
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.white)
                                .padding()
                                .background(Color.red)
                                .cornerRadius(8)
                                .padding()
                        }
                    }
                }
            }
            .overlay(alignment: .top) {
                ToastBanner()
            }
        }
    }

    // MARK: - Organization Name Section

    private var orgNameSection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Text(L10n.tr("Organization Name"))
                    .font(.caption)
                    .foregroundColor(.secondary)

                TextField(L10n.tr("Organization Name"), text: Binding(
                    get: { viewModel.org?.name ?? "" },
                    set: { newValue in
                        if var org = viewModel.org {
                            org.name = newValue
                            viewModel.org = org
                        }
                    }
                ))
                .textFieldStyle(.roundedBorder)

                Button(L10n.tr("Save")) {
                    Task {
                        guard let name = viewModel.org?.name, !name.isEmpty else { return }
                        try? await viewModel.updateOrgName(name)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.loading)
            }
            .padding()
            .background(Color(.systemGroupedBackground))

            Divider()
        }
    }

    // MARK: - Helpers

    private var isCreator: Bool {
        guard let org = viewModel.org, let userId = auth.userId else {
            return false
        }
        return userId == org.creator_user_id
    }
}
