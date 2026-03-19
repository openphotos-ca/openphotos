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
    @State private var showDeleteAlert: Bool = false
    @State private var pendingDeleteId: Int64? = nil
    @State private var pendingDeleteName: String = ""
    
    let onAlbumSelected: ((Int64) -> Void)?
    let onAlbumsChanged: (() -> Void)?
    let onAlbumCreated: ((Int64) -> Void)?
    let pickerOnly: Bool
    
    init(isPresented: Binding<Bool>, 
         selectedAlbumId: Binding<Int64?>,
         pickerOnly: Bool = false,
         onAlbumSelected: ((Int64) -> Void)? = nil,
         onAlbumsChanged: (() -> Void)? = nil,
         onAlbumCreated: ((Int64) -> Void)? = nil) {
        self._isPresented = isPresented
        self._selectedAlbumId = selectedAlbumId
        self.pickerOnly = pickerOnly
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
                        // Root row with add button (iOS Photos does not support nested album creation)
                        HStack(spacing: 12) {
                            Image(systemName: "house.fill")
                                .foregroundColor(.blue)
                                .frame(width: 24, height: 24)
                                .padding(.leading, 12)
                            Text("Root")
                                .font(.system(size: 15))
                                .foregroundColor(.primary)
                            Spacer()
                            if !pickerOnly {
                                Button {
                                    newAlbumName = ""
                                    showAddSheet = true
                                } label: {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.system(size: 22, weight: .semibold))
                                        .foregroundColor(.accentColor)
                                }
                                .buttonStyle(PlainButtonStyle())
                                .padding(.trailing, 12)
                            }
                        }
                        .padding(.vertical, 8)

                        Divider()

                        ForEach(albumTree, id: \.id) { node in
                            AlbumTreeRow(
                                node: node,
                                selectedAlbumId: $selectedAlbumId,
                                expandedAlbums: $expandedAlbums,
                                onSelect: selectAlbum,
                                pickerOnly: pickerOnly,
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
                        createNewAlbum()
                    }
                    .buttonStyle(BorderedProminentButtonStyle())
                    .disabled(newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCreatingAlbum)
                }
                .padding()
            }
            .presentationDetents([.fraction(0.25)])
        }
        // Delete confirmation
        .alert("Delete \(pendingDeleteName)?", isPresented: $showDeleteAlert) {
            Button("Delete", role: .destructive) {
                let id = pendingDeleteId
                pendingDeleteId = nil
                pendingDeleteName = ""
                guard let deleteId = id else { return }
                let shouldClearSelection = (selectedAlbumId == deleteId)
                DispatchQueue.global(qos: .userInitiated).async {
                    let ok = AlbumService.shared.deleteAlbum(albumId: deleteId)
                    DispatchQueue.main.async {
                        guard ok else { return }
                        loadAlbumTree()
                        if shouldClearSelection { selectedAlbumId = nil }
                        onAlbumsChanged?()
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteId = nil
                pendingDeleteName = ""
            }
        } message: {
            Text("This removes the album from OpenPhotos and deletes the iPhone system album too. Photos are not deleted.")
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
    
    private func createNewAlbum() {
        let name = newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        guard !isCreatingAlbum else { return }
        isCreatingAlbum = true
        DispatchQueue.global(qos: .userInitiated).async {
            let created = AlbumService.shared.createAlbum(name: name, description: nil, parentId: nil)
            DispatchQueue.main.async {
                defer { isCreatingAlbum = false }
                guard let album = created else { return }
                showAddSheet = false
                newAlbumName = ""
                loadAlbumTree()
                if let pid = album.parentId { expandedAlbums.insert(pid) }
                selectedAlbumId = album.id
                onAlbumsChanged?()
                onAlbumCreated?(album.id)
            }
        }
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
    let pickerOnly: Bool
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
                    if !pickerOnly && selectedAlbumId == node.id {
                        HStack(spacing: 10) {
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
                            pickerOnly: pickerOnly,
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
