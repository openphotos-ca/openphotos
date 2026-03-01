import Foundation

struct Album: Identifiable, Hashable {
    let id: Int64
    var name: String
    var description: String?
    var parentId: Int64?
    var position: Int
    var isSystem: Bool
    var isLive: Bool
    var liveCriteria: String?
    var createdAt: Date
    var updatedAt: Date
    
    var children: [Album] = []
    var isExpanded: Bool = false
    var depth: Int = 0
    var photoCount: Int = 0
    
    init(id: Int64, 
         name: String, 
         description: String? = nil,
         parentId: Int64? = nil, 
         position: Int = 0,
         isSystem: Bool = false, 
         isLive: Bool = false,
         liveCriteria: String? = nil,
         createdAt: Date = Date(), 
         updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.description = description
        self.parentId = parentId
        self.position = position
        self.isSystem = isSystem
        self.isLive = isLive
        self.liveCriteria = liveCriteria
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
    
    static func == (lhs: Album, rhs: Album) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

class AlbumTreeNode: ObservableObject, Identifiable {
    let album: Album
    @Published var children: [AlbumTreeNode]
    @Published var isExpanded: Bool
    let depth: Int
    weak var parent: AlbumTreeNode?
    
    init(album: Album, depth: Int = 0, parent: AlbumTreeNode? = nil) {
        self.album = album
        self.children = []
        self.isExpanded = album.isExpanded
        self.depth = depth
        self.parent = parent
    }
    
    var id: Int64 { album.id }
    
    func toggleExpansion() {
        isExpanded.toggle()
    }
    
    func addChild(_ node: AlbumTreeNode) {
        children.append(node)
        node.parent = self
    }
    
    func removeChild(_ node: AlbumTreeNode) {
        children.removeAll { $0.id == node.id }
    }
    
    func sortChildren() {
        children.sort { $0.album.position < $1.album.position }
    }
}

struct AlbumPhoto {
    let albumId: Int64
    let assetId: String
    let photoId: String
    let addedAt: Date
    let position: Int?
    
    init(albumId: Int64, assetId: String, photoId: String, addedAt: Date = Date(), position: Int? = nil) {
        self.albumId = albumId
        self.assetId = assetId
        self.photoId = photoId
        self.addedAt = addedAt
        self.position = position
    }
}