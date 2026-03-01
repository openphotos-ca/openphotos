import Foundation
import Photos
import CryptoKit
import SQLite3

class AlbumService {
    static let shared = AlbumService()
    private let db = DatabaseManager.shared
    
    private init() {}
    
    // MARK: - Album CRUD Operations
    
    func createAlbum(name: String, description: String? = nil, parentId: Int64? = nil, isLive: Bool = false, liveCriteria: String? = nil) -> Album? {
        let now = Int64(Date().timeIntervalSince1970)
        
        db.beginTransaction()
        
        // Get next position for siblings
        let position = getNextPosition(parentId: parentId)
        
        // Insert album
        let query = """
            INSERT INTO albums (name, description, parent_id, position, is_system, is_live, live_criteria, created_at, updated_at)
            VALUES (?, ?, ?, ?, 0, ?, ?, ?, ?)
        """
        
        let parameters: [Any] = [
            name,
            description ?? NSNull(),
            parentId ?? NSNull(),
            position,
            isLive,
            liveCriteria ?? NSNull(),
            now,
            now
        ]
        
        guard db.executeQuery(query, parameters: parameters) else {
            db.rollbackTransaction()
            return nil
        }
        
        let albumId = db.getLastInsertedId()
        
        // Update closure table
        if !updateClosureTableForNewAlbum(albumId: albumId, parentId: parentId) {
            db.rollbackTransaction()
            return nil
        }
        
        db.commitTransaction()
        
        return Album(
            id: albumId,
            name: name,
            description: description,
            parentId: parentId,
            position: position,
            isSystem: false,
            isLive: isLive,
            liveCriteria: liveCriteria,
            createdAt: Date(timeIntervalSince1970: TimeInterval(now)),
            updatedAt: Date(timeIntervalSince1970: TimeInterval(now))
        )
    }
    
    private func updateClosureTableForNewAlbum(albumId: Int64, parentId: Int64?) -> Bool {
        // Self-reference
        var query = "INSERT INTO album_closure (ancestor_id, descendant_id, depth) VALUES (?, ?, 0)"
        if !db.executeQuery(query, parameters: [albumId, albumId]) {
            return false
        }
        
        // If has parent, inherit ancestors
        if let parentId = parentId {
            query = """
                INSERT INTO album_closure (ancestor_id, descendant_id, depth)
                SELECT ancestor_id, ?, depth + 1
                FROM album_closure
                WHERE descendant_id = ?
            """
            if !db.executeQuery(query, parameters: [albumId, parentId]) {
                return false
            }
        }
        
        return true
    }
    
    func deleteAlbum(albumId: Int64) -> Bool {
        db.beginTransaction()
        
        // Get all descendants
        let descendants = getDescendantIds(albumId: albumId)
        
        // Delete album photos for all descendants
        for id in descendants {
            let query = "DELETE FROM album_photos WHERE album_id = ?"
            if !db.executeQuery(query, parameters: [id]) {
                db.rollbackTransaction()
                return false
            }
        }
        
        // Delete from closure table
        let closureQuery = """
            DELETE FROM album_closure 
            WHERE ancestor_id IN (\(descendants.map { String($0) }.joined(separator: ",")))
            OR descendant_id IN (\(descendants.map { String($0) }.joined(separator: ",")))
        """
        if !db.executeQuery(closureQuery) {
            db.rollbackTransaction()
            return false
        }
        
        // Delete albums
        let albumQuery = "DELETE FROM albums WHERE id IN (\(descendants.map { String($0) }.joined(separator: ",")))"
        if !db.executeQuery(albumQuery) {
            db.rollbackTransaction()
            return false
        }
        
        db.commitTransaction()
        return true
    }
    
    func moveAlbum(albumId: Int64, newParentId: Int64?) -> Bool {
        // Check for cycles
        if let newParentId = newParentId {
            if isDescendant(ancestorId: albumId, descendantId: newParentId) {
                print("Cannot move album to its own descendant")
                return false
            }
        }
        
        db.beginTransaction()
        
        // Detach from old ancestors
        let detachQuery = """
            DELETE FROM album_closure
            WHERE descendant_id IN (
                SELECT descendant_id FROM album_closure WHERE ancestor_id = ?
            )
            AND ancestor_id NOT IN (
                SELECT descendant_id FROM album_closure WHERE ancestor_id = ?
            )
        """
        if !db.executeQuery(detachQuery, parameters: [albumId, albumId]) {
            db.rollbackTransaction()
            return false
        }
        
        // Reattach to new parent
        if let newParentId = newParentId {
            let attachQuery = """
                INSERT INTO album_closure (ancestor_id, descendant_id, depth)
                SELECT a.ancestor_id, d.descendant_id, a.depth + d.depth + 1
                FROM album_closure a
                JOIN album_closure d ON d.ancestor_id = ?
                WHERE a.descendant_id = ?
            """
            if !db.executeQuery(attachQuery, parameters: [albumId, newParentId]) {
                db.rollbackTransaction()
                return false
            }
        }
        
        // Update parent_id
        let updateQuery = "UPDATE albums SET parent_id = ?, updated_at = ? WHERE id = ?"
        let now = Int64(Date().timeIntervalSince1970)
        if !db.executeQuery(updateQuery, parameters: [newParentId ?? NSNull(), now, albumId]) {
            db.rollbackTransaction()
            return false
        }
        
        db.commitTransaction()
        return true
    }
    
    // MARK: - Album Photos
    
    func addPhotosToAlbum(albumId: Int64, assetIds: [String]) -> Bool {
        db.beginTransaction()
        
        for assetId in assetIds {
            let photoId = generatePhotoId(assetId: assetId)
            let query = """
                INSERT OR IGNORE INTO album_photos (album_id, asset_id, photo_id, added_at)
                VALUES (?, ?, ?, ?)
            """
            let now = Int64(Date().timeIntervalSince1970)
            if !db.executeQuery(query, parameters: [albumId, assetId, photoId, now]) {
                db.rollbackTransaction()
                return false
            }
        }
        
        db.commitTransaction()
        return true
    }
    
    func removePhotosFromAlbum(albumId: Int64, photoIds: [String]) -> Bool {
        let placeholders = photoIds.map { _ in "?" }.joined(separator: ",")
        let query = "DELETE FROM album_photos WHERE album_id = ? AND photo_id IN (\(placeholders))"
        var parameters: [Any] = [albumId]
        parameters.append(contentsOf: photoIds)
        return db.executeQuery(query, parameters: parameters)
    }
    
    // MARK: - Queries
    
    func getAllAlbums() -> [Album] {
        let query = """
            SELECT a.*, 
                   (SELECT COUNT(*) FROM album_photos WHERE album_id = a.id) as photo_count,
                   (SELECT MAX(depth) FROM album_closure WHERE descendant_id = a.id) as depth
            FROM albums a
            ORDER BY a.parent_id, a.position, a.name
        """
        
        let albums = db.executeSelect(query) { statement in
            return albumFromStatement(statement)
        }
        
        return albums
    }

    // Albums containing a given asset (by PHAsset.localIdentifier)
    func getAlbumsForAsset(assetId: String) -> [Album] {
        let query = """
            SELECT a.*,
                   (SELECT COUNT(*) FROM album_photos WHERE album_id = a.id) as photo_count,
                   (SELECT MAX(depth) FROM album_closure WHERE descendant_id = a.id) as depth
            FROM albums a
            JOIN album_photos ap ON ap.album_id = a.id
            WHERE ap.asset_id = ?
            ORDER BY a.parent_id, a.position, a.name
        """
        return db.executeSelect(query, parameters: [assetId]) { statement in
            return albumFromStatement(statement)
        }
    }

    // Albums ordered by most recent use (latest added photo time)
    func getAlbumsOrderedByRecentUse() -> [Album] {
        let query = """
            SELECT a.*,
                   (SELECT COUNT(*) FROM album_photos WHERE album_id = a.id) as photo_count,
                   (SELECT MAX(depth) FROM album_closure WHERE descendant_id = a.id) as depth,
                   IFNULL((SELECT MAX(added_at) FROM album_photos WHERE album_id = a.id), 0) as last_used
            FROM albums a
            ORDER BY last_used DESC, a.updated_at DESC, a.name ASC
        """
        return db.executeSelect(query) { statement in
            return albumFromStatement(statement)
        }
    }
    
    func getRootAlbums() -> [Album] {
        let query = """
            SELECT a.*,
                   (SELECT COUNT(*) FROM album_photos WHERE album_id = a.id) as photo_count,
                   0 as depth
            FROM albums a
            WHERE a.parent_id IS NULL
            ORDER BY a.position, a.name
        """
        
        return db.executeSelect(query) { statement in
            return albumFromStatement(statement)
        }
    }
    
    func getChildAlbums(parentId: Int64) -> [Album] {
        let query = """
            SELECT a.*,
                   (SELECT COUNT(*) FROM album_photos WHERE album_id = a.id) as photo_count,
                   (SELECT MAX(depth) FROM album_closure WHERE descendant_id = a.id) as depth
            FROM albums a
            WHERE a.parent_id = ?
            ORDER BY a.position, a.name
        """
        
        return db.executeSelect(query, parameters: [parentId]) { statement in
            return albumFromStatement(statement)
        }
    }
    
    func getAlbumPhotos(albumId: Int64, includeSubtree: Bool = false) -> [String] {
        var query: String
        var parameters: [Any] = []
        
        if includeSubtree {
            query = """
                SELECT DISTINCT ap.asset_id
                FROM album_photos ap
                JOIN album_closure ac ON ap.album_id = ac.descendant_id
                WHERE ac.ancestor_id = ?
                ORDER BY ap.added_at DESC
            """
            parameters = [albumId]
        } else {
            query = """
                SELECT asset_id
                FROM album_photos
                WHERE album_id = ?
                ORDER BY added_at DESC
            """
            parameters = [albumId]
        }
        
        return db.executeSelect(query, parameters: parameters) { statement in
            guard let assetId = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: assetId)
        }
    }
    
    // MARK: - System Albums Import

    func importSystemAlbums() {
        print("Starting user albums import...")
        
        let fetchOptions = PHFetchOptions()
        // Only fetch user-created albums, not smart albums
        let userAlbums = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .albumRegular,
            options: fetchOptions
        )
        
        print("Found \(userAlbums.count) user-created albums")
        
        db.beginTransaction()
        
        var importedCount = 0
        
        // Import only user-created albums
        userAlbums.enumerateObjects { collection, _, _ in
            if self.importSystemAlbum(collection: collection, isSystem: false) {
                importedCount += 1
            }
        }
        
        db.commitTransaction()
        print("Imported \(importedCount) user albums successfully")
    }

    // Incrementally refresh existing user-created albums and their memberships.
    // - Creates any new albums not yet in the DB
    // - Adds any missing asset memberships for existing albums (idempotent)
    func refreshSystemAlbumMemberships() {
        let fetchOptions = PHFetchOptions()
        let userAlbums = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .albumRegular,
            options: fetchOptions
        )

        db.beginTransaction()
        let now = Int64(Date().timeIntervalSince1970)
        var created = 0
        var updated = 0

        userAlbums.enumerateObjects { collection, _, _ in
            guard let title = collection.localizedTitle, !title.isEmpty else { return }
            // Find existing album id (user-created)
            let existingId: Int64? = self.db.executeSelect(
                "SELECT id FROM albums WHERE name = ? AND is_system = 0 LIMIT 1",
                parameters: [title]
            ) { stmt in sqlite3_column_int64(stmt, 0) }.first

            if let albumId = existingId {
                // Upsert memberships (INSERT OR IGNORE)
                let assets = PHAsset.fetchAssets(in: collection, options: nil)
                var ids: [String] = []
                ids.reserveCapacity(assets.count)
                assets.enumerateObjects { asset, _, _ in ids.append(asset.localIdentifier) }
                _ = self.addPhotosToAlbum(albumId: albumId, assetIds: ids)
                _ = self.db.executeQuery("UPDATE albums SET updated_at = ? WHERE id = ?", parameters: [now, albumId])
                updated += 1
            } else {
                // Create album and attach photos
                let position = self.getNextPosition(parentId: nil)
                let ok = self.db.executeQuery(
                    "INSERT INTO albums (name, description, parent_id, position, is_system, is_live, created_at, updated_at) VALUES (?, NULL, NULL, ?, 0, 0, ?, ?)",
                    parameters: [title, position, now, now]
                )
                if ok {
                    let newId = self.db.getLastInsertedId()
                    // Self link in closure table
                    _ = self.db.executeQuery("INSERT INTO album_closure (ancestor_id, descendant_id, depth) VALUES (?, ?, 0)", parameters: [newId, newId])
                    let assets = PHAsset.fetchAssets(in: collection, options: nil)
                    var ids: [String] = []
                    ids.reserveCapacity(assets.count)
                    assets.enumerateObjects { asset, _, _ in ids.append(asset.localIdentifier) }
                    _ = self.addPhotosToAlbum(albumId: newId, assetIds: ids)
                    created += 1
                }
            }
        }

        db.commitTransaction()
        print("Refreshed user albums — created: \(created), updated: \(updated)")
    }
    
    private func importSystemAlbum(collection: PHAssetCollection, isSystem: Bool) -> Bool {
        guard let title = collection.localizedTitle else { 
            print("Skipping album with no title")
            return false
        }
        
        
        // Check if album already exists
        let checkQuery = "SELECT id FROM albums WHERE name = ? AND is_system = ?"
        let exists = db.executeSelect(checkQuery, parameters: [title, isSystem]) { statement in
            return sqlite3_column_int64(statement, 0)
        }.first
        
        if exists != nil { 
            return false
        }
        
        // Create album
        let now = Int64(Date().timeIntervalSince1970)
        let position = getNextPosition(parentId: nil)
        
        let insertQuery = """
            INSERT INTO albums (name, parent_id, position, is_system, is_live, created_at, updated_at)
            VALUES (?, NULL, ?, ?, 0, ?, ?)
        """
        
        
        if !db.executeQuery(insertQuery, parameters: [title, position, isSystem, now, now]) {
            return false
        }
        
        let albumId = db.getLastInsertedId()
        
        // Add self-reference to closure table
        db.executeQuery(
            "INSERT INTO album_closure (ancestor_id, descendant_id, depth) VALUES (?, ?, 0)",
            parameters: [albumId, albumId]
        )
        
        // Import photos from this album
        let assets = PHAsset.fetchAssets(in: collection, options: nil)
        var photoCount = 0
        assets.enumerateObjects { asset, _, _ in
            if self.addPhotosToAlbum(albumId: albumId, assetIds: [asset.localIdentifier]) {
                photoCount += 1
            }
        }
        
        return true
    }
    
    // MARK: - Helper Methods
    
    private func getNextPosition(parentId: Int64?) -> Int {
        let query: String
        let parameters: [Any]
        
        if let parentId = parentId {
            query = "SELECT MAX(position) FROM albums WHERE parent_id = ?"
            parameters = [parentId]
        } else {
            query = "SELECT MAX(position) FROM albums WHERE parent_id IS NULL"
            parameters = []
        }
        
        let maxPosition = db.executeSelect(query, parameters: parameters) { statement in
            return Int(sqlite3_column_int(statement, 0))
        }.first ?? 0
        
        return maxPosition + 1
    }
    
    private func getDescendantIds(albumId: Int64) -> [Int64] {
        let query = "SELECT descendant_id FROM album_closure WHERE ancestor_id = ?"
        return db.executeSelect(query, parameters: [albumId]) { statement in
            return sqlite3_column_int64(statement, 0)
        }
    }
    
    private func isDescendant(ancestorId: Int64, descendantId: Int64) -> Bool {
        let query = "SELECT 1 FROM album_closure WHERE ancestor_id = ? AND descendant_id = ? LIMIT 1"
        return !db.executeSelect(query, parameters: [ancestorId, descendantId]) { statement in
            return 1
        }.isEmpty
    }
    
    private func generatePhotoId(assetId: String) -> String {
        // Use the new asset ID scheme directly
        // Base58(first16(HMAC-SHA256(user_id, file_bytes))) computed by the uploader
        return assetId
    }
    
    private func albumFromStatement(_ statement: OpaquePointer) -> Album? {
        let id = sqlite3_column_int64(statement, 0)

        guard let namePtr = sqlite3_column_text(statement, 1) else {
            return nil
        }
        let name = String(cString: namePtr)

        var description: String? = nil
        if sqlite3_column_type(statement, 2) != SQLITE_NULL, let descPtr = sqlite3_column_text(statement, 2) {
            description = String(cString: descPtr)
        }

        var parentId: Int64? = nil
        if sqlite3_column_type(statement, 3) != SQLITE_NULL {
            parentId = sqlite3_column_int64(statement, 3)
        }

        let position = Int(sqlite3_column_int(statement, 4))
        let isSystem = sqlite3_column_int(statement, 5) == 1
        let isLive = sqlite3_column_int(statement, 6) == 1

        var liveCriteria: String? = nil
        if sqlite3_column_type(statement, 7) != SQLITE_NULL, let criteriaPtr = sqlite3_column_text(statement, 7) {
            liveCriteria = String(cString: criteriaPtr)
        }

        let createdAt = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 8)))
        let updatedAt = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 9)))
        
        var album = Album(
            id: id,
            name: name,
            description: description,
            parentId: parentId,
            position: position,
            isSystem: isSystem,
            isLive: isLive,
            liveCriteria: liveCriteria,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        
        // Map dynamic columns by name to avoid index drift
        let colCount = sqlite3_column_count(statement)
        for i in 0..<colCount {
            if let cname = sqlite3_column_name(statement, i) {
                let nameStr = String(cString: cname)
                if nameStr == "photo_count" {
                    album.photoCount = Int(sqlite3_column_int(statement, i))
                } else if nameStr == "depth" {
                    album.depth = Int(sqlite3_column_int(statement, i))
                }
            }
        }
        
        return album
    }

    // Sync selection helpers
    func setAlbumSyncEnabled(albumId: Int64, enabled: Bool) -> Bool {
        db.executeQuery("UPDATE albums SET sync_enabled = ?, updated_at = ? WHERE id = ?", parameters: [enabled, Int64(Date().timeIntervalSince1970), albumId])
    }

    func getSyncEnabledMap() -> [Int64: Bool] {
        let rows: [(Int64, Bool)] = db.executeSelect("SELECT id, IFNULL(sync_enabled,0) FROM albums") { stmt in
            (sqlite3_column_int64(stmt, 0), sqlite3_column_int(stmt, 1) == 1)
        }
        var map: [Int64: Bool] = [:]
        for (id, flag) in rows { map[id] = flag }
        return map
    }

    // Locked flag helpers (per-album E2EE)
    func setAlbumLocked(albumId: Int64, locked: Bool) -> Bool {
        db.executeQuery("UPDATE albums SET locked = ?, updated_at = ? WHERE id = ?", parameters: [locked, Int64(Date().timeIntervalSince1970), albumId])
    }

    func getLockedMap() -> [Int64: Bool] {
        let rows: [(Int64, Bool)] = db.executeSelect("SELECT id, IFNULL(locked,0) FROM albums") { stmt in
            (sqlite3_column_int64(stmt, 0), sqlite3_column_int(stmt, 1) == 1)
        }
        var map: [Int64: Bool] = [:]
        for (id, flag) in rows { map[id] = flag }
        return map
    }

    // Is an asset locked? If sync scope is selectedAlbums, require that any album containing the asset has both sync_enabled=1 and locked=1.
    // Otherwise (sync all), any album with locked=1 containing the asset will mark it locked.
    func isAssetLocked(assetLocalIdentifier: String, scopeSelectedOnly: Bool) -> Bool {
        // First: honor per-photo override when present
        if let o = SyncRepository.shared.getLockOverrideForLocalIdentifier(assetLocalIdentifier) {
            return o
        }
        if scopeSelectedOnly {
            let rows: [Int] = db.executeSelect(
                """
                SELECT 1 FROM album_photos ap
                JOIN albums a ON a.id = ap.album_id
                WHERE ap.asset_id = ? AND a.sync_enabled = 1 AND a.locked = 1
                LIMIT 1
                """,
                parameters: [assetLocalIdentifier]
            ) { _ in 1 }
            if !rows.isEmpty { return true }

            // Unassigned scope lock: when syncing selected albums and "Unassigned" is enabled,
            // allow locking all photos that are not in any album.
            let includeUnassigned = UserDefaults.standard.bool(forKey: "sync.includeUnassigned")
            let unassignedLocked = UserDefaults.standard.bool(forKey: "sync.unassignedLocked")
            if includeUnassigned && unassignedLocked {
                let inAnyAlbum: [Int] = db.executeSelect(
                    "SELECT 1 FROM album_photos WHERE asset_id = ? LIMIT 1",
                    parameters: [assetLocalIdentifier]
                ) { _ in 1 }
                if inAnyAlbum.isEmpty { return true }
            }
            return false
        } else {
            let rows: [Int] = db.executeSelect(
                "SELECT 1 FROM album_photos ap JOIN albums a ON a.id = ap.album_id WHERE ap.asset_id = ? AND a.locked = 1 LIMIT 1",
                parameters: [assetLocalIdentifier]
            ) { _ in 1 }
            return !rows.isEmpty
        }
    }
    
    // Build full paths (root -> leaf) for albums containing the given asset.
    // If onlySyncEnabled is true, include only paths where any node in the path has sync_enabled=1.
    func getAlbumPathsForAsset(assetLocalIdentifier: String, onlySyncEnabled: Bool) -> [[String]] {
        // Find album_ids containing this asset
        let albumIds: [Int64] = db.executeSelect(
            "SELECT DISTINCT album_id FROM album_photos WHERE asset_id = ?",
            parameters: [assetLocalIdentifier]
        ) { stmt in sqlite3_column_int64(stmt, 0) }
        var paths: [[String]] = []
        for albumId in albumIds {
            // Optionally filter to albums selected for sync (or any ancestor selected)
            if onlySyncEnabled {
                let selected: [Int] = db.executeSelect(
                    "SELECT 1 FROM album_closure ac JOIN albums a ON a.id = ac.ancestor_id WHERE ac.descendant_id = ? AND a.sync_enabled = 1 LIMIT 1",
                    parameters: [albumId]
                ) { _ in 1 }
                if selected.isEmpty { continue }
            }
            // Fetch ancestor chain for this album (root has max depth). Build names from root -> leaf.
            let rows: [(Int64, Int)] = db.executeSelect(
                "SELECT ac.ancestor_id, ac.depth FROM album_closure ac WHERE ac.descendant_id = ? ORDER BY ac.depth DESC",
                parameters: [albumId]
            ) { stmt in (sqlite3_column_int64(stmt, 0), Int(sqlite3_column_int(stmt, 1))) }
            var path: [String] = []
            for (ancestorId, _) in rows {
                let names: [String] = db.executeSelect(
                    "SELECT name FROM albums WHERE id = ? LIMIT 1",
                    parameters: [ancestorId]
                ) { s in String(cString: sqlite3_column_text(s, 0)) }
                if let name = names.first { path.append(name) }
            }
            if !path.isEmpty { paths.append(path) }
        }
        return paths
    }

    func setSubtreeSyncEnabled(albumId: Int64, enabled: Bool) -> Bool {
        let now = Int64(Date().timeIntervalSince1970)
        let query = """
            UPDATE albums
            SET sync_enabled = ?, updated_at = ?
            WHERE id IN (
                SELECT descendant_id FROM album_closure WHERE ancestor_id = ?
            )
        """
        return db.executeQuery(query, parameters: [enabled, now, albumId])
    }
    
    func buildAlbumTree(from albums: [Album]) -> [AlbumTreeNode] {
        var albumDict: [Int64: AlbumTreeNode] = [:]
        var rootNodes: [AlbumTreeNode] = []
        
        // Create nodes
        for album in albums {
            let node = AlbumTreeNode(album: album, depth: album.depth)
            albumDict[album.id] = node
        }
        
        // Build tree structure
        for album in albums {
            if let parentId = album.parentId,
               let parentNode = albumDict[parentId],
               let node = albumDict[album.id] {
                parentNode.addChild(node)
            } else if let node = albumDict[album.id] {
                rootNodes.append(node)
            }
        }
        
        // Sort children
        for node in albumDict.values {
            node.sortChildren()
        }
        
        return rootNodes.sorted { $0.album.position < $1.album.position }
    }
}
