import SwiftUI

/// Server-backed Album Tree picker. Mirrors the Gallery's AlbumTreeView UI but
/// loads and mutates albums via server endpoints.
struct ServerAlbumTreeView: View {
    @Binding var isPresented: Bool
    @Binding var includeSubalbums: Bool
    @Binding var selectedAlbumId: Int?

    // Callbacks
    let onAlbumSelected: ((Int) -> Void)?
    let onAlbumSelectedWithName: ((Int, String) -> Void)?
    let onAlbumsChanged: (() -> Void)?

    @State private var albumTree: [ServerTreeNode] = []
    @State private var expanded: Set<Int> = []
    @State private var showAddSheet: Bool = false
    @State private var addParentId: Int? = nil
    @State private var newAlbumName: String = ""
    @State private var showDeleteAlert: Bool = false
    @State private var pendingDeleteId: Int? = nil
    @State private var pendingDeleteName: String = ""

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Include sub‑albums toggle
                HStack {
                    Toggle("Include sub‑albums", isOn: $includeSubalbums)
                        .toggleStyle(SwitchToggleStyle(tint: .accentColor))
                        .font(.subheadline)
                }
                .padding(.horizontal)
                .padding(.bottom, 6)

                Divider()

                // Root row with add button
                HStack(spacing: 12) {
                    Image(systemName: "house.fill").foregroundColor(.blue).frame(width: 24, height: 24).padding(.leading, 12)
                    Text("Root").font(.system(size: 15)).foregroundColor(.primary)
                    Spacer()
                    Button { addParentId = nil; newAlbumName = ""; showAddSheet = true } label: {
                        Image(systemName: "plus.circle.fill").font(.system(size: 22, weight: .semibold)).foregroundColor(.accentColor)
                    }.buttonStyle(PlainButtonStyle()).padding(.trailing, 12)
                }
                .padding(.vertical, 8)
                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(albumTree, id: \.id) { node in
                            ServerAlbumTreeRow(node: node,
                                               selectedAlbumId: $selectedAlbumId,
                                               expanded: $expanded,
                                               onSelect: { id in selectedAlbumId = id },
                                               onAddChild: { pid in addParentId = pid; newAlbumName = ""; showAddSheet = true },
                                               onDelete: { id, name in pendingDeleteId = id; pendingDeleteName = name; showDeleteAlert = true })
                        }
                    }
                    .padding(.vertical, 8)
                }

                Divider()

                // Bottom actions
                HStack {
                    Button("Cancel") { isPresented = false }.buttonStyle(BorderedButtonStyle())
                    Spacer()
                    Button {
                        if let id = selectedAlbumId {
                            if let name = findAlbumName(id: id), onAlbumSelectedWithName != nil {
                                onAlbumSelectedWithName?(id, name)
                            } else {
                                onAlbumSelected?(id)
                            }
                        }
                        isPresented = false
                    } label: {
                        Label("OK", systemImage: "checkmark")
                    }.buttonStyle(BorderedProminentButtonStyle()).disabled(selectedAlbumId == nil)
                }
                .padding()
            }
            .navigationTitle("Choose an album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button { isPresented = false } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) } }
            }
        }
        .onAppear { Task { await reloadTree() } }
        .sheet(isPresented: $showAddSheet) { addAlbumSheet }
        .alert("Delete \(pendingDeleteName)?", isPresented: $showDeleteAlert) {
            Button("Delete", role: .destructive) { Task { await deleteAlbum() } }
            Button("Cancel", role: .cancel) { pendingDeleteId = nil; pendingDeleteName = "" }
        } message: { Text("This removes the album and its sub‑albums. Photos are not deleted.") }
    }

    // MARK: - Sheets
    private var addAlbumSheet: some View {
        NavigationView {
            Form { TextField("Album name", text: $newAlbumName) }
                .navigationTitle("New Album")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showAddSheet = false } }
                    ToolbarItem(placement: .confirmationAction) { Button("Create") { Task { await createAlbum() } }.disabled(newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                }
        }
        .presentationDetents([.fraction(0.25)])
    }

    // MARK: - Data
    @MainActor
    private func applyTree(_ albums: [ServerAlbum]) {
        // Build tree by parent_id
        let byParent = Dictionary(grouping: albums, by: { $0.parent_id ?? -1 })
        func build(_ parent: Int?, depth: Int) -> [ServerTreeNode] {
            let key = parent ?? -1
            let children = (byParent[key] ?? []).sorted { ($0.position ?? 0) < ($1.position ?? 0) }
            return children.map { a in
                ServerTreeNode(album: a, depth: depth, children: build(a.id, depth: depth+1))
            }
        }
        let roots = build(nil, depth: 0)
        self.albumTree = roots
        // Expand root level
        self.expanded = Set(roots.map { $0.id })
    }

    private func reloadTree() async {
        do { let list = try await ServerPhotosService.shared.listAlbums(); await applyTree(list) } catch { await applyTree([]) }
    }

    private func findAlbumName(id: Int) -> String? {
        func walk(_ nodes: [ServerTreeNode]) -> String? {
            for n in nodes {
                if n.id == id { return n.album.name }
                if let found = walk(n.children) { return found }
            }
            return nil
        }
        return walk(albumTree)
    }

    private func createAlbum() async {
        let name = newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        _ = try? await ServerPhotosService.shared.createAlbum(name: name, parentId: addParentId)
        await MainActor.run { showAddSheet = false; newAlbumName = "" }
        await reloadTree()
        await MainActor.run { onAlbumsChanged?() }
    }

    private func deleteAlbum() async {
        guard let id = pendingDeleteId else { return }
        _ = try? await ServerPhotosService.shared.deleteAlbum(id: id)
        await MainActor.run { pendingDeleteId = nil; pendingDeleteName = "" }
        await reloadTree()
        await MainActor.run { onAlbumsChanged?() }
    }
}

// MARK: - Row
private struct ServerAlbumTreeRow: View {
    let node: ServerTreeNode
    @Binding var selectedAlbumId: Int?
    @Binding var expanded: Set<Int>
    let onSelect: (Int) -> Void
    let onAddChild: (Int) -> Void
    let onDelete: (Int, String) -> Void

    private var isExpanded: Bool { expanded.contains(node.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if node.depth > 0 { Spacer().frame(width: CGFloat(node.depth * 20)) }
                if !node.children.isEmpty {
                    Button { withAnimation(.easeInOut(duration: 0.2)) { if isExpanded { expanded.remove(node.id) } else { expanded.insert(node.id) } } } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right").font(.system(size: 12)).foregroundColor(.secondary).frame(width: 20, height: 20)
                    }.buttonStyle(PlainButtonStyle())
                } else { Spacer().frame(width: 20) }
                albumIcon
                    .font(.system(size: 16))
                    .frame(width: 24, height: 24)
                Text(node.album.name).font(.system(size: 15)).foregroundColor(selectedAlbumId == node.id ? .white : .primary)
                if node.album.photo_count > 0 { Text("(\(node.album.photo_count))").font(.system(size: 13)).foregroundColor(.secondary) }
                Spacer()
                if selectedAlbumId == node.id {
                    HStack(spacing: 10) {
                        Button { onAddChild(node.id) } label: { Image(systemName: "plus.circle.fill").font(.system(size: 20, weight: .semibold)) }
                            .buttonStyle(PlainButtonStyle())
                            .disabled(node.album.is_live)
                            .opacity(node.album.is_live ? 0.4 : 1.0)
                        Button { onDelete(node.id, node.album.name) } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 20, weight: .semibold)).foregroundColor(.red) }
                            .buttonStyle(PlainButtonStyle())
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(selectedAlbumId == node.id ? Color.accentColor.opacity(0.8) : Color.clear)
            .cornerRadius(6)
            .contentShape(Rectangle())
            .onTapGesture { onSelect(node.id) }

            if isExpanded && !node.children.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(node.children, id: \.id) { child in
                        ServerAlbumTreeRow(node: child, selectedAlbumId: $selectedAlbumId, expanded: $expanded, onSelect: onSelect, onAddChild: onAddChild, onDelete: onDelete)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var albumIcon: some View {
        if node.album.is_live {
            Image(systemName: "sparkles").foregroundColor(.purple)
        } else {
            Image(systemName: "folder.fill").foregroundColor(.orange)
        }
    }
}

private struct ServerTreeNode: Identifiable {
    let album: ServerAlbum
    let depth: Int
    let children: [ServerTreeNode]
    var id: Int { album.id }
}
