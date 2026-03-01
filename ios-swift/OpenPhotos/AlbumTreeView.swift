import SwiftUI
import Photos

struct AlbumTreeView: View {
    @Binding var isPresented: Bool
    @Binding var selectedAlbumId: Int64?
    @EnvironmentObject var viewModel: GalleryViewModel
    @State private var albumTree: [AlbumTreeNode] = []
    @State private var newAlbumName: String = ""
    @State private var expandedAlbums: Set<Int64> = []
    @State private var isCreatingAlbum: Bool = false
    @State private var showAddSheet: Bool = false
    @State private var addParentId: Int64? = nil
    @State private var showDeleteAlert: Bool = false
    @State private var pendingDeleteId: Int64? = nil
    @State private var pendingDeleteName: String = ""
    
    let onAlbumSelected: ((Int64) -> Void)?
    let onAlbumsChanged: (() -> Void)?
    let onAlbumCreated: ((Int64) -> Void)?
    
    init(isPresented: Binding<Bool>, 
         selectedAlbumId: Binding<Int64?>,
         onAlbumSelected: ((Int64) -> Void)? = nil,
         onAlbumsChanged: (() -> Void)? = nil,
         onAlbumCreated: ((Int64) -> Void)? = nil) {
        self._isPresented = isPresented
        self._selectedAlbumId = selectedAlbumId
        self.onAlbumSelected = onAlbumSelected
        self.onAlbumsChanged = onAlbumsChanged
        self.onAlbumCreated = onAlbumCreated
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Album tree
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(albumTree, id: \.id) { node in
                            AlbumTreeRow(
                                node: node,
                                selectedAlbumId: $selectedAlbumId,
                                expandedAlbums: $expandedAlbums,
                                onSelect: selectAlbum,
                                onAddChild: { parentId in
                                    addParentId = parentId
                                    newAlbumName = ""
                                    showAddSheet = true
                                },
                                onDelete: { albumId, name in
                                    pendingDeleteId = albumId
                                    pendingDeleteName = name
                                    showDeleteAlert = true
                                }
                            )
                        }
                    }
                    .padding(.vertical, 8)
                }
                
                Divider()
                
                // Bottom buttons
                HStack {
                    Button("Cancel") {
                        isPresented = false
                    }
                    .buttonStyle(BorderedButtonStyle())
                    
                    Spacer()
                    
                    Button {
                        if let albumId = selectedAlbumId {
                            onAlbumSelected?(albumId)
                        }
                        isPresented = false
                    } label: {
                        Label("OK", systemImage: "checkmark")
                    }
                    .buttonStyle(BorderedProminentButtonStyle())
                    .disabled(selectedAlbumId == nil)
                }
                .padding()
            }
            .navigationTitle("Choose an album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .onAppear {
            loadAlbumTree()
        }
        // Add new album sheet
        .sheet(isPresented: $showAddSheet) {
            VStack(spacing: 12) {
                Text("New Album")
                    .font(.headline)
                TextField("Album name", text: $newAlbumName)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .padding(.horizontal)
                HStack {
                    Button("Cancel") { showAddSheet = false }
                        .buttonStyle(BorderedButtonStyle())
                    Spacer()
                    Button("Create") {
                        createNewAlbumUnder(addParentId)
                    }
                    .buttonStyle(BorderedProminentButtonStyle())
                    .disabled(newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding()
            }
            .presentationDetents([.fraction(0.25)])
        }
        // Delete confirmation
        .alert("Delete \(pendingDeleteName)?", isPresented: $showDeleteAlert) {
            Button("Delete", role: .destructive) {
                if let id = pendingDeleteId {
                    _ = AlbumService.shared.deleteAlbum(albumId: id)
                    loadAlbumTree()
                    if selectedAlbumId == id { selectedAlbumId = nil }
                    onAlbumsChanged?()
                }
                pendingDeleteId = nil
                pendingDeleteName = ""
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteId = nil
                pendingDeleteName = ""
            }
        } message: {
            Text("This removes the album and its sub‑albums. Photos are not deleted.")
        }
    }
    
    private func loadAlbumTree() {
        // Refresh the album database from the current iOS Photos albums
        // before constructing the tree. This ensures the tree reflects
        // the device's album structure (including new albums and updated
        // memberships) rather than a stale snapshot.
        DispatchQueue.global(qos: .userInitiated).async {
            AlbumService.shared.refreshSystemAlbumMemberships()
            let albums = AlbumService.shared.getAllAlbums()
            let tree = AlbumService.shared.buildAlbumTree(from: albums)
            DispatchQueue.main.async {
                albumTree = tree
                expandedAlbums = Set(tree.map { $0.id })
            }
        }
    }
    
    private func createNewAlbumUnder(_ parentId: Int64?) {
        let name = newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        isCreatingAlbum = true
        if let album = AlbumService.shared.createAlbum(name: name, description: nil, parentId: parentId) {
            showAddSheet = false
            newAlbumName = ""
            loadAlbumTree()
            if let pid = album.parentId { expandedAlbums.insert(pid) }
            selectedAlbumId = album.id
            onAlbumsChanged?()
            onAlbumCreated?(album.id)
        }
        isCreatingAlbum = false
    }
    
    private func selectAlbum(_ albumId: Int64) {
        selectedAlbumId = albumId
    }
}

struct AlbumTreeRow: View {
    @ObservedObject var node: AlbumTreeNode
    @Binding var selectedAlbumId: Int64?
    @Binding var expandedAlbums: Set<Int64>
    let onSelect: (Int64) -> Void
    let onAddChild: (Int64) -> Void
    let onDelete: (Int64, String) -> Void
    
    private var isExpanded: Bool {
        expandedAlbums.contains(node.id)
    }
    
    private var indentationLevel: CGFloat {
        CGFloat(node.depth * 20)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                    // Indentation
                    if indentationLevel > 0 {
                        Spacer()
                            .frame(width: indentationLevel)
                    }
                    
                    // Expand/collapse chevron
                    if !node.children.isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if isExpanded {
                                    expandedAlbums.remove(node.id)
                                } else {
                                    expandedAlbums.insert(node.id)
                                }
                            }
                        } label: {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(PlainButtonStyle())
                    } else {
                        Spacer()
                            .frame(width: 20)
                    }
                    
                    // Album icon
                    albumIcon
                        .font(.system(size: 16))
                        .frame(width: 24, height: 24)
                    
                    // Album name
                    Text(node.album.name)
                        .font(.system(size: 15))
                        .foregroundColor(selectedAlbumId == node.id ? .white : .primary)
                    
                    // Photo count
                    if node.album.photoCount > 0 {
                        Text("(\(node.album.photoCount))")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    // Trailing actions when selected
                    if selectedAlbumId == node.id {
                        HStack(spacing: 10) {
                            // Add child (disabled for live albums)
                            Button {
                                onAddChild(node.id)
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 20, weight: .semibold))
                            }
                            .buttonStyle(PlainButtonStyle())
                            .disabled(node.album.isLive)
                            .opacity(node.album.isLive ? 0.4 : 1.0)
                            
                            // Delete album (allowed for live albums)
                            Button {
                                onDelete(node.id, node.album.name)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                selectedAlbumId == node.id
                    ? Color.accentColor.opacity(0.8)
                    : Color.clear
            )
            .cornerRadius(6)
            .contentShape(Rectangle())
            .onTapGesture { onSelect(node.id) }
            
            // Children
            if isExpanded && !node.children.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(node.children, id: \.id) { childNode in
                        AlbumTreeRow(
                            node: childNode,
                            selectedAlbumId: $selectedAlbumId,
                            expandedAlbums: $expandedAlbums,
                            onSelect: onSelect,
                            onAddChild: onAddChild,
                            onDelete: onDelete
                        )
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private var albumIcon: some View {
        if node.album.name.lowercased().contains("liveyou") {
            Image(systemName: "sparkles")
                .foregroundColor(.purple)
        } else if node.album.isSystem {
            Image(systemName: "folder.fill.badge.gearshape")
                .foregroundColor(.blue)
        } else if node.album.isLive {
            Image(systemName: "sparkles")
                .foregroundColor(.purple)
        } else {
            Image(systemName: "folder.fill")
                .foregroundColor(.orange)
        }
    }
}

// Preview
struct AlbumTreeView_Previews: PreviewProvider {
    static var previews: some View {
        AlbumTreeView(
            isPresented: .constant(true),
            selectedAlbumId: .constant(nil)
        )
        .environmentObject(GalleryViewModel())
    }
}
