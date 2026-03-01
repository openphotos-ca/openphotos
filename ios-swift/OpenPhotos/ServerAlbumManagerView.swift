import SwiftUI

/// Server album manager with basic create/rename/move/delete and live album creation.
struct ServerAlbumManagerView: View {
    @Binding var isPresented: Bool
    @State var albums: [ServerAlbum]
    let refresh: () -> Void
    // Optional criteria for creating a live album from current filters
    let liveCriteria: ServerPhotoListQuery?

    @State private var selectedId: Int? = nil
    @State private var showCreate = false
    @State private var newName: String = ""
    @State private var createAsLive: Bool = false
    @State private var isRenaming: Bool = false
    @State private var moveTargetId: Int? = nil
    @State private var showMoveSheet = false

    var body: some View {
        NavigationView {
            List(selection: Binding(get: { selectedId.map { Set([$0]) } ?? [] }, set: { s in selectedId = s.first })) {
                ForEach(buildTreeRoots(), id: \.id) { node in
                    treeRow(node: node, depth: 0)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Albums")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { isPresented = false } }
                ToolbarItem(placement: .confirmationAction) { Button("Add") { showCreate = true } }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Rename") { Task { await renameSelected() } }.disabled(selectedId == nil)
                    Button("Move") { showMoveSheet = true }.disabled(selectedId == nil)
                    Button("Delete") { Task { await deleteSelected() } }.disabled(selectedId == nil)
                }
            }
            .sheet(isPresented: $showCreate) { createSheet }
            .sheet(isPresented: $showMoveSheet) { moveSheet }
        }
    }

    // MARK: - Tree building
    private func buildTreeRoots() -> [TreeNode] {
        let byParent = Dictionary(grouping: albums, by: { $0.parent_id ?? -1 })
        func build(id: Int?, depth: Int) -> [TreeNode] {
            let key = id ?? -1
            let children = (byParent[key] ?? []).sorted { ($0.position ?? 0) < ($1.position ?? 0) }
            return children.map { a in
                TreeNode(album: a, id: a.id, children: build(id: a.id, depth: depth+1), depth: depth)
            }
        }
        return build(id: nil, depth: 0)
    }

    private func treeRow(node: TreeNode, depth: Int) -> AnyView {
        let header = HStack {
            ForEach(0..<node.depth, id: \.self) { _ in Spacer().frame(width: 16) }
            Image(systemName: node.album.is_live ? "sparkles" : "folder.fill").foregroundColor(node.album.is_live ? .purple : .orange)
            Text(node.album.name)
            Spacer()
            if selectedId == node.id { Image(systemName: "checkmark") }
        }
        .contentShape(Rectangle())
        .onTapGesture { selectedId = (selectedId == node.id ? nil : node.id) }

        let childrenView = Group {
            if !node.children.isEmpty {
                ForEach(node.children, id: \.id) { c in
                    treeRow(node: c, depth: c.depth)
                }
            }
        }

        return AnyView(
            VStack(alignment: .leading, spacing: 4) {
                header
                childrenView
            }
        )
    }

    // MARK: - Actions
    private var createSheet: some View {
        NavigationView {
            Form {
                TextField("Album name", text: $newName)
                if !isRenaming { Toggle("Create as Live album", isOn: $createAsLive) }
            }
            .navigationTitle(isRenaming ? "Rename Album" : "Create Album")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showCreate = false; isRenaming = false } }
                ToolbarItem(placement: .confirmationAction) { Button(isRenaming ? "Save" : "Create") { Task { await commitCreateOrRename() } } .disabled(newName.isEmpty) }
            }
        }
    }

    private var moveSheet: some View {
        NavigationView {
            List {
                ForEach(albums, id: \.id) { a in
                    HStack { Text(a.name); Spacer(); if moveTargetId == a.id { Image(systemName: "checkmark") } }
                        .contentShape(Rectangle())
                        .onTapGesture { moveTargetId = a.id }
                }
            }
            .navigationTitle("Move To…")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showMoveSheet = false } }
                ToolbarItem(placement: .confirmationAction) { Button("Move") { Task { await moveSelected() } } .disabled(moveTargetId == nil || moveTargetId == selectedId) }
            }
        }
    }

    private func commitCreateOrRename() async {
        defer { showCreate = false; isRenaming = false }
        do {
            if isRenaming, let id = selectedId, let existing = albums.first(where: { $0.id == id }) {
                if existing.is_live {
                    _ = try await ServerPhotosService.shared.updateLiveAlbum(id: id, name: newName)
                } else {
                    _ = try await ServerPhotosService.shared.updateAlbum(id: id, name: newName)
                }
            } else {
                if createAsLive, let crit = liveCriteria {
                    _ = try await ServerPhotosService.shared.createLiveAlbum(name: newName, description: nil, parentId: selectedId, criteria: crit)
                } else {
                    _ = try await ServerPhotosService.shared.createAlbum(name: newName, description: nil, parentId: selectedId)
                }
            }
            await MainActor.run { refresh() }
        } catch {}
    }

    private func renameSelected() async {
        guard let id = selectedId, let current = albums.first(where: { $0.id == id }) else { return }
        newName = current.name
        createAsLive = false
        isRenaming = true
        await MainActor.run { showCreate = true }
    }

    private func moveSelected() async {
        guard let id = selectedId, let target = moveTargetId, let album = albums.first(where: { $0.id == id }) else { return }
        do {
            if album.is_live {
                _ = try await ServerPhotosService.shared.updateLiveAlbum(id: id, parent_id: target)
            } else {
                _ = try await ServerPhotosService.shared.updateAlbum(id: id, parentId: target)
            }
            await MainActor.run { refresh() }
        } catch { }
        await MainActor.run { showMoveSheet = false }
    }

    private func deleteSelected() async {
        guard let id = selectedId else { return }
        do { try await ServerPhotosService.shared.deleteAlbum(id: id); await MainActor.run { refresh() } } catch {}
    }
}

private struct TreeNode { let album: ServerAlbum; let id: Int; let children: [TreeNode]; let depth: Int }
