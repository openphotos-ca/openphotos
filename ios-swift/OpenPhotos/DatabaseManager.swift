import Foundation
import SQLite3

// SQLite3 text binding constant
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

class DatabaseManager {
    static let shared = DatabaseManager()
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.openphotos.sqlite", qos: .userInitiated)
    
    private init() {
        openDatabase()
        createTables()
    }
    
    private func openDatabase() {
        let fileURL = try! FileManager.default
            .url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent("OpenPhotos.sqlite")
        
        if sqlite3_open(fileURL.path, &db) != SQLITE_OK {
            print("Error opening database")
        }
    }
    
    private func createTables() {
        createAlbumsTable()
        createAlbumClosureTable()
        createAlbumPhotosTable()
        createPhotosTable()
        createTusUploadsTable()
        createBackupIdCacheTable()
        migrateAddColumns()
        createIndices()
    }
    
    private func createAlbumsTable() {
        let createTableString = """
            CREATE TABLE IF NOT EXISTS albums (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                description TEXT,
                parent_id INTEGER,
                position INTEGER DEFAULT 0,
                is_system BOOLEAN DEFAULT 0,
                is_live BOOLEAN DEFAULT 0,
                live_criteria TEXT,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                FOREIGN KEY (parent_id) REFERENCES albums(id) ON DELETE CASCADE
            );
        """
        
        var createTableStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, createTableString, -1, &createTableStatement, nil) == SQLITE_OK {
            if sqlite3_step(createTableStatement) == SQLITE_DONE {
                print("Albums table created successfully")
            }
        }
        sqlite3_finalize(createTableStatement)
    }
    
    private func createAlbumClosureTable() {
        let createTableString = """
            CREATE TABLE IF NOT EXISTS album_closure (
                ancestor_id INTEGER NOT NULL,
                descendant_id INTEGER NOT NULL,
                depth INTEGER NOT NULL,
                PRIMARY KEY (ancestor_id, descendant_id),
                FOREIGN KEY (ancestor_id) REFERENCES albums(id) ON DELETE CASCADE,
                FOREIGN KEY (descendant_id) REFERENCES albums(id) ON DELETE CASCADE
            );
        """
        
        var createTableStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, createTableString, -1, &createTableStatement, nil) == SQLITE_OK {
            if sqlite3_step(createTableStatement) == SQLITE_DONE {
                print("Album closure table created successfully")
            }
        }
        sqlite3_finalize(createTableStatement)
    }
    
    private func createAlbumPhotosTable() {
        let createTableString = """
            CREATE TABLE IF NOT EXISTS album_photos (
                album_id INTEGER NOT NULL,
                asset_id TEXT NOT NULL,
                photo_id TEXT NOT NULL,
                added_at INTEGER NOT NULL,
                position INTEGER,
                PRIMARY KEY (album_id, photo_id),
                FOREIGN KEY (album_id) REFERENCES albums(id) ON DELETE CASCADE
            );
        """
        
        var createTableStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, createTableString, -1, &createTableStatement, nil) == SQLITE_OK {
            if sqlite3_step(createTableStatement) == SQLITE_DONE {
                print("Album photos table created successfully")
            }
        }
        sqlite3_finalize(createTableStatement)
    }
    
    private func createPhotosTable() {
        let createTableString = """
            CREATE TABLE IF NOT EXISTS photos (
                content_id TEXT PRIMARY KEY,
                local_identifier TEXT,
                media_type INTEGER NOT NULL,
                creation_ts INTEGER,
                pixel_width INTEGER,
                pixel_height INTEGER,
                estimated_bytes INTEGER,
                locked BOOLEAN,
                cloud_backed_up BOOLEAN,
                cloud_checked_at INTEGER,
                sync_state INTEGER NOT NULL DEFAULT 0,
                sync_at INTEGER,
                attempts INTEGER NOT NULL DEFAULT 0,
                last_error TEXT,
                last_attempt_at INTEGER
            );
        """

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, createTableString, -1, &stmt, nil) == SQLITE_OK {
            _ = sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    private func createTusUploadsTable() {
        let createTableString = """
            CREATE TABLE IF NOT EXISTS tus_uploads (
                content_id TEXT PRIMARY KEY,
                upload_url TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                last_used_at INTEGER NOT NULL
            );
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, createTableString, -1, &stmt, nil) == SQLITE_OK {
            _ = sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    private func createBackupIdCacheTable() {
        let createTableString = """
            CREATE TABLE IF NOT EXISTS backup_id_cache (
                user_id TEXT NOT NULL,
                local_identifier TEXT NOT NULL,
                fingerprint TEXT NOT NULL,
                candidates_json TEXT NOT NULL,
                updated_at INTEGER NOT NULL,
                PRIMARY KEY (user_id, local_identifier)
            );
        """

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, createTableString, -1, &stmt, nil) == SQLITE_OK {
            _ = sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    private func migrateAddColumns() {
        // albums.sync_enabled
        if !columnExists(table: "albums", column: "sync_enabled") {
            _ = executeQuery("ALTER TABLE albums ADD COLUMN sync_enabled BOOLEAN NOT NULL DEFAULT 0")
        }
        // albums.locked (per-album E2EE flag; iOS-only)
        if !columnExists(table: "albums", column: "locked") {
            _ = executeQuery("ALTER TABLE albums ADD COLUMN locked BOOLEAN NOT NULL DEFAULT 0")
        }
        // album_photos.synced_at
        if !columnExists(table: "album_photos", column: "synced_at") {
            _ = executeQuery("ALTER TABLE album_photos ADD COLUMN synced_at INTEGER")
        }
        // photos.last_attempt_at
        if !columnExists(table: "photos", column: "last_attempt_at") {
            _ = executeQuery("ALTER TABLE photos ADD COLUMN last_attempt_at INTEGER")
        }
        // photos.locked (last successfully synced lock state per asset; drives resync on changes)
        if !columnExists(table: "photos", column: "locked") {
            _ = executeQuery("ALTER TABLE photos ADD COLUMN locked BOOLEAN")
        }
        // photos.lock_override (user override to force lock/unlock regardless of album flags; NULL=no override)
        if !columnExists(table: "photos", column: "lock_override") {
            _ = executeQuery("ALTER TABLE photos ADD COLUMN lock_override BOOLEAN")
        }
        // photos.cloud_backed_up (true when server reports fully backed up; nil/false otherwise)
        if !columnExists(table: "photos", column: "cloud_backed_up") {
            _ = executeQuery("ALTER TABLE photos ADD COLUMN cloud_backed_up BOOLEAN")
        }
        // photos.cloud_checked_at (unix seconds of last successful check for this asset)
        if !columnExists(table: "photos", column: "cloud_checked_at") {
            _ = executeQuery("ALTER TABLE photos ADD COLUMN cloud_checked_at INTEGER")
        }
    }
    
    private func createIndices() {
        let indices = [
            "CREATE INDEX IF NOT EXISTS idx_album_closure_ancestor ON album_closure(ancestor_id);",
            "CREATE INDEX IF NOT EXISTS idx_album_closure_descendant ON album_closure(descendant_id);",
            "CREATE INDEX IF NOT EXISTS idx_albums_parent ON albums(parent_id);",
            "CREATE INDEX IF NOT EXISTS idx_album_photos_album ON album_photos(album_id);",
            "CREATE INDEX IF NOT EXISTS idx_album_photos_asset ON album_photos(asset_id);",
            // photos table
            "CREATE INDEX IF NOT EXISTS idx_photos_media_type ON photos(media_type);",
            "CREATE INDEX IF NOT EXISTS idx_photos_state ON photos(sync_state, sync_at);",
            "CREATE INDEX IF NOT EXISTS idx_photos_local_identifier ON photos(local_identifier);",
            "CREATE INDEX IF NOT EXISTS idx_photos_cloud_backed_up ON photos(cloud_backed_up);",
            // backup_id_cache table
            "CREATE INDEX IF NOT EXISTS idx_backup_id_cache_user ON backup_id_cache(user_id);"
        ]
        
        for indexString in indices {
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, indexString, -1, &statement, nil) == SQLITE_OK {
                sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
        }
    }
    
    func executeQuery(_ query: String, parameters: [Any] = []) -> Bool {
        return queue.sync {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
                print("Error preparing query: \(query)")
                return false
            }
            for (index, parameter) in parameters.enumerated() {
                let paramIndex = Int32(index + 1)
                if let value = parameter as? String {
                    sqlite3_bind_text(statement, paramIndex, value, -1, SQLITE_TRANSIENT)
                } else if let value = parameter as? Int {
                    sqlite3_bind_int64(statement, paramIndex, Int64(value))
                } else if let value = parameter as? Int64 {
                    sqlite3_bind_int64(statement, paramIndex, value)
                } else if let value = parameter as? Bool {
                    sqlite3_bind_int(statement, paramIndex, value ? 1 : 0)
                } else if parameter is NSNull {
                    sqlite3_bind_null(statement, paramIndex)
                }
            }
            let result = sqlite3_step(statement) == SQLITE_DONE
            sqlite3_finalize(statement)
            return result
        }
    }
    
    func executeSelect<T>(_ query: String, parameters: [Any] = [], mapper: (OpaquePointer) -> T?) -> [T] {
        return queue.sync {
            var statement: OpaquePointer?
            var results: [T] = []
            guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
                print("Error preparing select: \(query)")
                return results
            }
            for (index, parameter) in parameters.enumerated() {
                let paramIndex = Int32(index + 1)
                if let value = parameter as? String {
                    sqlite3_bind_text(statement, paramIndex, value, -1, SQLITE_TRANSIENT)
                } else if let value = parameter as? Int {
                    sqlite3_bind_int64(statement, paramIndex, Int64(value))
                } else if let value = parameter as? Int64 {
                    sqlite3_bind_int64(statement, paramIndex, value)
                } else if let value = parameter as? Bool {
                    sqlite3_bind_int(statement, paramIndex, value ? 1 : 0)
                } else if parameter is NSNull {
                    sqlite3_bind_null(statement, paramIndex)
                }
            }
            while sqlite3_step(statement) == SQLITE_ROW {
                if let result = mapper(statement!) {
                    results.append(result)
                }
            }
            sqlite3_finalize(statement)
            return results
        }
    }
    
    func getLastInsertedId() -> Int64 {
        return queue.sync { sqlite3_last_insert_rowid(db) }
    }
    
    func beginTransaction() { _ = executeQuery("BEGIN TRANSACTION") }
    
    func commitTransaction() { _ = executeQuery("COMMIT") }
    
    func rollbackTransaction() { _ = executeQuery("ROLLBACK") }

    // MARK: - Introspection helpers

    func columnExists(table: String, column: String) -> Bool {
        return queue.sync {
            var statement: OpaquePointer?
            let query = "PRAGMA table_info(\(table))"
            var exists = false
            if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
                while sqlite3_step(statement) == SQLITE_ROW {
                    if let namePtr = sqlite3_column_text(statement, 1) {
                        let name = String(cString: namePtr)
                        if name == column { exists = true; break }
                    }
                }
            }
            sqlite3_finalize(statement)
            return exists
        }
    }
}
