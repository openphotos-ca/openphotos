import SwiftUI

/// Groups tab view with group list and inline actions.
/// Shows groups with name and description, tap to show detail panel.
struct GroupsTabView: View {
    @EnvironmentObject var viewModel: TeamManagementViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Header with Add Button
            HStack {
                Text("Groups")
                    .font(.headline)
                Spacer()
                Button {
                    viewModel.showAddGroup = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundColor(.blue)
                }
            }
            .padding()
            .background(Color(.systemGroupedBackground))

            Divider()

            // Groups List
            if viewModel.loading && viewModel.groups.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.groups.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "person.3")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No groups yet")
                        .foregroundColor(.secondary)
                    Button("Create First Group") {
                        viewModel.showAddGroup = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.groups) { group in
                            GroupRow(group: group)
                                .environmentObject(viewModel)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $viewModel.showAddGroup) {
            AddGroupSheet()
                .environmentObject(viewModel)
        }
        .sheet(item: Binding(
            get: { viewModel.selectedGroup },
            set: { viewModel.selectedGroup = $0 }
        )) { group in
            GroupDetailPanel(group: group)
                .environmentObject(viewModel)
        }
        .confirmationDialog(
            "Delete Group",
            isPresented: Binding(
                get: { viewModel.showDeleteGroupConfirm.show },
                set: { show in viewModel.showDeleteGroupConfirm = (show, show ? viewModel.showDeleteGroupConfirm.group : nil) }
            ),
            presenting: viewModel.showDeleteGroupConfirm.group
        ) { group in
            Button("Delete '\(group.name)'", role: .destructive) {
                Task {
                    try? await viewModel.deleteGroup(group)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { group in
            Text("This will delete the group and remove all member associations. Members and their media will not be deleted.")
        }
    }
}

// MARK: - Group Row

private struct GroupRow: View {
    @EnvironmentObject var viewModel: TeamManagementViewModel

    let group: TeamGroup

    var body: some View {
        Button {
            viewModel.selectedGroup = group
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    // Group Info
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.name)
                            .font(.body)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                        if let description = group.description, !description.isEmpty {
                            Text(description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                    }

                    Spacer()

                    // Member Count
                    if let members = viewModel.groupMembers[group.id] {
                        Text("\(members.count) members")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    // Delete Button
                    Button {
                        viewModel.showDeleteGroupConfirm = (true, group)
                    } label: {
                        Text("Delete")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.red.opacity(0.1))
                            .foregroundColor(.red)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
                .padding()

                Divider()
            }
        }
        .buttonStyle(.plain)
    }
}
