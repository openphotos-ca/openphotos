import Foundation
import SQLite3
import CryptoKit

enum CloudItemStatus: Int {
    case unknown = 0
    case backedUp = 1
    case deletedInCloud = 2
    case missing = 3
}

final class SyncRepository {
    static let shared = SyncRepository()
    private let db = DatabaseManager.shared
    private let notifyQueue = DispatchQueue(label: "syncrepo.notify")
    private var notifyScheduled: Bool = false

    private init() {}

    // Notification name for stats updates
    static let statsChangedNotification = Notification.Name("SyncStatsChangedNotification")
    // Notification name for per-photo lock override changes.
    //
    // This is intentionally separate from `statsChangedNotification` so views can react to
    // lock badge changes without causing an update storm during active syncing.
    static let lockOverrideChangedNotification = Notification.Name("LockOverrideChangedNotification")

    // Notification name for per-photo cloud backup status changes.
    //
    // Views use this to update cloud badges without per-cell DB reads.
    static let cloudStatusChangedNotification = Notification.Name("CloudStatusChangedNotification")
    // Notification name for bulk cloud backup status updates (e.g., after a full-library check).
    static let cloudBulkStatusChangedNotification = Notification.Name("CloudBulkStatusChangedNotification")

    enum LockOverrideUserInfoKey {
        static let localIdentifier = "localIdentifier"
        // Value type: NSNumber(Bool) or NSNull() when cleared.
        static let overrideValue = "overrideValue"
    }

    enum CloudStatusUserInfoKey {
        static let localIdentifier = "localIdentifier"
        // Value type: NSNumber(Int)
        static let cloudStatus = "cloudStatus"
    }

    private func scheduleStatsChangedNotification() {
        notifyQueue.async {
            if self.notifyScheduled { return }
            self.notifyScheduled = true
            self.notifyQueue.asyncAfter(deadline: .now() + 0.5) {
                self.notifyScheduled = false
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: SyncRepository.statsChangedNotification, object: nil)
                }
            }
        }
    }

    func upsertPhoto(contentId: String,
                     localIdentifier: String,
                     mediaType: Int,
                     creationTs: Int64?,
                     pixelWidth: Int?,
                     pixelHeight: Int?,
                     estimatedBytes: Int64?) {
        // Insert if missing
        _ = db.executeQuery(
            "INSERT OR IGNORE INTO photos (content_id, local_identifier, media_type, creation_ts, pixel_width, pixel_height, estimated_bytes) VALUES (?, ?, ?, ?, ?, ?, ?)",
            parameters: [
                contentId,
                localIdentifier,
                mediaType,
                creationTs ?? NSNull(),
                pixelWidth ?? NSNull(),
                pixelHeight ?? NSNull(),
                estimatedBytes ?? NSNull()
            ]
        )
        // Always update mutable fields
        _ = db.executeQuery(
            "UPDATE photos SET local_identifier = ?, media_type = ?, creation_ts = ?, pixel_width = ?, pixel_height = ?, estimated_bytes = ? WHERE content_id = ?",
            parameters: [
                localIdentifier,
                mediaType,
                creationTs ?? NSNull(),
                pixelWidth ?? NSNull(),
                pixelHeight ?? NSNull(),
                estimatedBytes ?? NSNull(),
                contentId
            ]
        )
        scheduleStatsChangedNotification()
    }

    func setLocked(contentId: String, locked: Bool) {
        _ = db.executeQuery("UPDATE photos SET locked = ? WHERE content_id = ?", parameters: [locked, contentId])
        scheduleStatsChangedNotification()
    }

    func markUploading(contentId: String) {
        let now = Int64(Date().timeIntervalSince1970)
        // Do not downgrade assets that are already marked as fully synced (state=2)
        _ = db.executeQuery("UPDATE photos SET sync_state = 1, last_attempt_at = ? WHERE content_id = ? AND sync_state <> 2", parameters: [now, contentId])
        scheduleStatsChangedNotification()
    }

    func markSynced(contentId: String) {
        let now = Int64(Date().timeIntervalSince1970)
        _ = db.executeQuery("UPDATE photos SET sync_state = 2, sync_at = ?, attempts = 0, last_error = NULL WHERE content_id = ?", parameters: [now, contentId])
        scheduleStatsChangedNotification()
    }

    func markFailed(contentId: String, error: String?) {
        let now = Int64(Date().timeIntervalSince1970)
        // Do not downgrade assets that have already been successfully synced.
        _ = db.executeQuery("UPDATE photos SET sync_state = 3, attempts = attempts + 1, last_error = ?, last_attempt_at = ? WHERE content_id = ? AND sync_state <> 2", parameters: [error ?? "", now, contentId])
        scheduleStatsChangedNotification()
    }

    // Move an item back to pending without incrementing attempts.
    // Useful when transport succeeded but server-side ingest confirmation is still catching up.
    func markPending(contentId: String, note: String? = nil) {
        let now = Int64(Date().timeIntervalSince1970)
        // Do not downgrade assets that have already been successfully synced.
        _ = db.executeQuery(
            "UPDATE photos SET sync_state = 0, last_error = ?, last_attempt_at = ? WHERE content_id = ? AND sync_state <> 2",
            parameters: [note ?? "", now, contentId]
        )
        scheduleStatsChangedNotification()
    }

    func markBackgroundQueued(contentId: String) {
        let now = Int64(Date().timeIntervalSince1970)
        // Do not downgrade assets that are already fully synced.
        _ = db.executeQuery("UPDATE photos SET sync_state = 4, last_attempt_at = ? WHERE content_id = ? AND sync_state <> 2", parameters: [now, contentId])
        scheduleStatsChangedNotification()
    }

    func isLocalIdentifierSynced(_ localIdentifier: String) -> Bool {
        let rows: [Int] = db.executeSelect(
            "SELECT 1 FROM photos WHERE local_identifier = ? AND sync_state = 2 LIMIT 1",
            parameters: [localIdentifier]
        ) { _ in 1 }
        return !rows.isEmpty
    }

    func getMediaType(contentId: String) -> Int? {
        let rows: [Int] = db.executeSelect(
            "SELECT media_type FROM photos WHERE content_id = ? LIMIT 1",
            parameters: [contentId]
        ) { stmt in Int(sqlite3_column_int(stmt, 0)) }
        return rows.first
    }

    func getLockedForLocalIdentifier(_ localIdentifier: String) -> Bool? {
        let rows: [Int] = db.executeSelect(
            "SELECT CASE WHEN locked IS NULL THEN -1 WHEN locked THEN 1 ELSE 0 END FROM photos WHERE local_identifier = ? LIMIT 1",
            parameters: [localIdentifier]
        ) { stmt in Int(sqlite3_column_int(stmt, 0)) }
        guard let v = rows.first else { return nil }
        if v < 0 { return nil }
        return v == 1
    }

    // Ensure a photos row exists for the given local identifier; if missing, create a minimal row
    // using a deterministic content_id derived from the localIdentifier (Base58(MD5(localIdentifier))).
    private func ensurePhotoRow(localIdentifier: String) {
        let rows: [Int] = db.executeSelect(
            "SELECT 1 FROM photos WHERE local_identifier = ? LIMIT 1",
            parameters: [localIdentifier]
        ) { _ in 1 }
        guard rows.isEmpty else { return }
        // Compute deterministic content_id
        let digest = Insecure.MD5.hash(data: Data(localIdentifier.utf8))
        let cid = Base58.encode(Data(digest))
        _ = db.executeQuery(
            "INSERT OR IGNORE INTO photos (content_id, local_identifier, media_type) VALUES (?, ?, ?)",
            parameters: [cid, localIdentifier, 0]
        )
    }

    // Set or clear a per-photo lock override. When set, this value forces encryption decision
    // regardless of album lock flags. Passing nil clears the override (fall back to album rules).
    func setLockOverrideForLocalIdentifier(_ localIdentifier: String, override: Bool?) {
        ensurePhotoRow(localIdentifier: localIdentifier)
        if let o = override {
            _ = db.executeQuery("UPDATE photos SET lock_override = ? WHERE local_identifier = ?", parameters: [o, localIdentifier])
        } else {
            _ = db.executeQuery("UPDATE photos SET lock_override = NULL WHERE local_identifier = ?", parameters: [localIdentifier])
        }
        // Notify lightweight UI listeners immediately (e.g., lock badge overlays).
        let boxed: Any = override.map { NSNumber(value: $0) } ?? NSNull()
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: SyncRepository.lockOverrideChangedNotification,
                object: nil,
                userInfo: [
                    LockOverrideUserInfoKey.localIdentifier: localIdentifier,
                    LockOverrideUserInfoKey.overrideValue: boxed
                ]
            )
        }
        scheduleStatsChangedNotification()
    }

    func getLockOverrideForLocalIdentifier(_ localIdentifier: String) -> Bool? {
        let rows: [Int] = db.executeSelect(
            "SELECT CASE WHEN lock_override IS NULL THEN -1 WHEN lock_override THEN 1 ELSE 0 END FROM photos WHERE local_identifier = ? LIMIT 1",
            parameters: [localIdentifier]
        ) { stmt in Int(sqlite3_column_int(stmt, 0)) }
        guard let v = rows.first else { return nil }
        if v < 0 { return nil }
        return v == 1
    }

    // Fetch all explicit per-photo lock overrides (local_identifier -> override).
    //
    // The override set is usually small, so loading it once and then applying incremental
    // updates via `lockOverrideChangedNotification` avoids per-cell DB reads during scrolling.
    func getAllLockOverrides() -> [String: Bool] {
        let rows: [(String, Bool)] = db.executeSelect(
            """
            SELECT local_identifier,
                   CASE WHEN lock_override THEN 1 ELSE 0 END AS override_flag
            FROM photos
            WHERE local_identifier IS NOT NULL AND local_identifier <> ''
              AND lock_override IS NOT NULL
            """
        ) { stmt in
            guard let ptr = sqlite3_column_text(stmt, 0) else { return nil }
            let localId = String(cString: ptr)
            let flag = sqlite3_column_int(stmt, 1) == 1
            return (localId, flag)
        }
        var map: [String: Bool] = [:]
        map.reserveCapacity(rows.count)
        for (k, v) in rows { map[k] = v }
        return map
    }

    // MARK: - Cloud Backup Status

    /// Sets the cached server-side cloud status for a local asset.
    ///
    /// This is keyed by `PHAsset.localIdentifier` so it can be used for UI badges and Local-tab
    /// cleanup flows even when the asset has never been uploaded by this device.
    func setCloudStatusForLocalIdentifier(
        _ localIdentifier: String,
        status: CloudItemStatus,
        checkedAt: Int64? = nil,
        emitNotification: Bool = true
    ) {
        ensurePhotoRow(localIdentifier: localIdentifier)
        let ts: Any
        let backedUp: Any
        switch status {
        case .unknown:
            ts = NSNull()
            backedUp = NSNull()
        case .backedUp:
            ts = checkedAt ?? Int64(Date().timeIntervalSince1970)
            backedUp = true
        case .deletedInCloud, .missing:
            ts = checkedAt ?? Int64(Date().timeIntervalSince1970)
            backedUp = false
        }
        _ = db.executeQuery(
            "UPDATE photos SET cloud_status = ?, cloud_backed_up = ?, cloud_checked_at = ? WHERE local_identifier = ?",
            parameters: [status.rawValue, backedUp, ts, localIdentifier]
        )
        guard emitNotification else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: SyncRepository.cloudStatusChangedNotification,
                object: nil,
                userInfo: [
                    CloudStatusUserInfoKey.localIdentifier: localIdentifier,
                    CloudStatusUserInfoKey.cloudStatus: NSNumber(value: status.rawValue)
                ]
            )
        }
    }

    /// Backward-compatible helper for callers that only distinguish backed-up vs missing.
    func setCloudBackedUpForLocalIdentifier(
        _ localIdentifier: String,
        backedUp: Bool,
        checkedAt: Int64? = nil,
        emitNotification: Bool = true
    ) {
        setCloudStatusForLocalIdentifier(
            localIdentifier,
            status: backedUp ? .backedUp : .missing,
            checkedAt: checkedAt,
            emitNotification: emitNotification
        )
    }

    @discardableResult
    func setCloudStatusForLocalIdentifiers(
        _ localIdentifiers: Set<String>,
        status: CloudItemStatus,
        checkedAt: Int64? = nil,
        emitNotification: Bool = true
    ) -> Int {
        guard !localIdentifiers.isEmpty else { return 0 }
        let ids = Array(localIdentifiers)
        let chunkSize = 300
        let timestamp = checkedAt ?? Int64(Date().timeIntervalSince1970)
        var index = 0
        while index < ids.count {
            let end = min(index + chunkSize, ids.count)
            let chunk = Array(ids[index..<end])
            for localId in chunk {
                ensurePhotoRow(localIdentifier: localId)
            }
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let sql: String
            var params: [Any] = []
            switch status {
            case .unknown:
                sql = """
                UPDATE photos
                SET cloud_status = ?, cloud_backed_up = NULL, cloud_checked_at = NULL
                WHERE local_identifier IN (\(placeholders))
                """
                params.append(status.rawValue)
            case .backedUp:
                sql = """
                UPDATE photos
                SET cloud_status = ?, cloud_backed_up = 1, cloud_checked_at = ?
                WHERE local_identifier IN (\(placeholders))
                """
                params.append(status.rawValue)
                params.append(timestamp)
            case .deletedInCloud, .missing:
                sql = """
                UPDATE photos
                SET cloud_status = ?, cloud_backed_up = 0, cloud_checked_at = ?
                WHERE local_identifier IN (\(placeholders))
                """
                params.append(status.rawValue)
                params.append(timestamp)
            }
            params.append(contentsOf: chunk)
            _ = db.executeQuery(sql, parameters: params)
            index = end
        }
        guard emitNotification else { return ids.count }
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: SyncRepository.cloudBulkStatusChangedNotification,
                object: nil
            )
        }
        return ids.count
    }

    /// Loads all known "backed up" items (local_identifier -> true).
    ///
    /// This is expected to be a small subset of the full library; caching it avoids per-cell DB reads.
    func getAllCloudBackedUpLocalIdentifiers() -> Set<String> {
        let rows: [String] = db.executeSelect(
            """
            SELECT local_identifier
            FROM photos
            WHERE local_identifier IS NOT NULL AND local_identifier <> ''
              AND cloud_status = 1
            """
        ) { stmt in
            guard let ptr = sqlite3_column_text(stmt, 0) else { return nil }
            return String(cString: ptr)
        }
        return Set(rows)
    }

    /// Loads all known "checked but not present and not deleted in cloud" items.
    func getAllCloudMissingLocalIdentifiers() -> Set<String> {
        let rows: [String] = db.executeSelect(
            """
            SELECT local_identifier
            FROM photos
            WHERE local_identifier IS NOT NULL AND local_identifier <> ''
              AND cloud_status = 3
            """
        ) { stmt in
            guard let ptr = sqlite3_column_text(stmt, 0) else { return nil }
            return String(cString: ptr)
        }
        return Set(rows)
    }

    func getAllCloudDeletedLocalIdentifiers() -> Set<String> {
        let rows: [String] = db.executeSelect(
            """
            SELECT local_identifier
            FROM photos
            WHERE local_identifier IS NOT NULL AND local_identifier <> ''
              AND cloud_status = 2
            """
        ) { stmt in
            guard let ptr = sqlite3_column_text(stmt, 0) else { return nil }
            return String(cString: ptr)
        }
        return Set(rows)
    }

    /// Returns the subset of `localIdentifiers` currently marked as backed up in local cache.
    ///
    /// Query is chunked to keep SQLite placeholder count bounded.
    func getCloudBackedUpLocalIdentifiers(in localIdentifiers: [String]) -> Set<String> {
        guard !localIdentifiers.isEmpty else { return [] }
        let chunkSize = 300
        var result: Set<String> = []
        var index = 0
        while index < localIdentifiers.count {
            let end = min(index + chunkSize, localIdentifiers.count)
            let chunk = Array(localIdentifiers[index..<end])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let sql = """
            SELECT DISTINCT local_identifier
            FROM photos
            WHERE local_identifier IN (\(placeholders))
              AND cloud_status = 1
            """
            let rows: [String] = db.executeSelect(sql, parameters: chunk) { stmt in
                guard let ptr = sqlite3_column_text(stmt, 0) else { return nil }
                return String(cString: ptr)
            }
            result.formUnion(rows)
            index = end
        }
        return result
    }

    func getCloudDeletedLocalIdentifiers(in localIdentifiers: [String]) -> Set<String> {
        guard !localIdentifiers.isEmpty else { return [] }
        let chunkSize = 300
        var result: Set<String> = []
        var index = 0
        while index < localIdentifiers.count {
            let end = min(index + chunkSize, localIdentifiers.count)
            let chunk = Array(localIdentifiers[index..<end])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let sql = """
            SELECT DISTINCT local_identifier
            FROM photos
            WHERE local_identifier IN (\(placeholders))
              AND cloud_status = 2
            """
            let rows: [String] = db.executeSelect(sql, parameters: chunk) { stmt in
                guard let ptr = sqlite3_column_text(stmt, 0) else { return nil }
                return String(cString: ptr)
            }
            result.formUnion(rows)
            index = end
        }
        return result
    }

    /// Marks all rows for the given local identifiers as synced.
    ///
    /// This is used after cloud-check confirms server presence for a local asset.
    @discardableResult
    func markSyncedForLocalIdentifiers(_ localIdentifiers: Set<String>) -> Int {
        guard !localIdentifiers.isEmpty else { return 0 }
        let now = Int64(Date().timeIntervalSince1970)
        let ids = Array(localIdentifiers)
        let chunkSize = 300
        var index = 0
        while index < ids.count {
            let end = min(index + chunkSize, ids.count)
            let chunk = Array(ids[index..<end])
            for localId in chunk {
                ensurePhotoRow(localIdentifier: localId)
            }
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let sql = """
            UPDATE photos
            SET sync_state = 2, sync_at = ?, attempts = 0, last_error = NULL
            WHERE local_identifier IN (\(placeholders))
            """
            var params: [Any] = [now]
            params.append(contentsOf: chunk)
            _ = db.executeQuery(sql, parameters: params)
            index = end
        }
        scheduleStatsChangedNotification()
        return ids.count
    }
}

extension SyncRepository {
    struct SyncStats { let pending: Int; let uploading: Int; let bgQueued: Int; let failed: Int; let synced: Int; let lastSyncAt: Int64 }

    /// Stats scoped to current sync settings.
    ///
    /// - For `.all`, returns global stats across all known local identifiers.
    /// - For `.selectedAlbums`, returns stats only for assets currently selected via
    ///   albums.sync_enabled (plus unassigned assets when enabled).
    func getStats(scope: AuthManager.SyncScope, includeUnassigned: Bool) -> SyncStats {
        guard scope == .selectedAlbums else { return getStats() }

        let selectedSubquery = """
            SELECT DISTINCT ap.asset_id
            FROM album_photos ap
            WHERE EXISTS (
                SELECT 1 FROM album_closure ac
                JOIN albums a ON a.id = ac.ancestor_id
                WHERE ac.descendant_id = ap.album_id AND a.sync_enabled = 1
            )
        """
        let unassignedClause = " OR (? = 1 AND local_identifier NOT IN (SELECT DISTINCT asset_id FROM album_photos))"

        let sql = """
        SELECT
          SUM(CASE WHEN has1=1 THEN 1 ELSE 0 END) AS uploading,
          SUM(CASE WHEN has1=0 AND has4=1 THEN 1 ELSE 0 END) AS bg,
          SUM(CASE WHEN has1=0 AND has4=0 AND has3=1 THEN 1 ELSE 0 END) AS failed,
          SUM(CASE WHEN has1=0 AND has4=0 AND has3=0 AND has2=1 THEN 1 ELSE 0 END) AS synced,
          SUM(CASE WHEN has1=0 AND has4=0 AND has3=0 AND has2=0 THEN 1 ELSE 0 END) AS pending
        FROM (
          SELECT local_identifier,
            MAX(CASE WHEN sync_state=1 THEN 1 ELSE 0 END) AS has1,
            MAX(CASE WHEN sync_state=4 THEN 1 ELSE 0 END) AS has4,
            MAX(CASE WHEN sync_state=3 THEN 1 ELSE 0 END) AS has3,
            MAX(CASE WHEN sync_state=2 THEN 1 ELSE 0 END) AS has2
          FROM photos
          WHERE local_identifier IS NOT NULL AND local_identifier <> ''
            AND (
              local_identifier IN (\(selectedSubquery))
              \(unassignedClause)
            )
          GROUP BY local_identifier
        ) t
        """
        var uploading = 0, bgQueued = 0, failed = 0, synced = 0, pending = 0
        let vals: [(Int, Int, Int, Int, Int)] = db.executeSelect(
            sql,
            parameters: [includeUnassigned]
        ) { stmt in
            let up = Int(sqlite3_column_int(stmt, 0))
            let bg = Int(sqlite3_column_int(stmt, 1))
            let fl = Int(sqlite3_column_int(stmt, 2))
            let sy = Int(sqlite3_column_int(stmt, 3))
            let pe = Int(sqlite3_column_int(stmt, 4))
            return (up, bg, fl, sy, pe)
        }
        if let first = vals.first {
            uploading = first.0
            bgQueued = first.1
            failed = first.2
            synced = first.3
            pending = first.4
        }

        let lastSql = """
            SELECT IFNULL(MAX(sync_at), 0)
            FROM photos
            WHERE local_identifier IS NOT NULL AND local_identifier <> ''
              AND (
                local_identifier IN (\(selectedSubquery))
                \(unassignedClause)
              )
        """
        let last: Int64 = db.executeSelect(
            lastSql,
            parameters: [includeUnassigned]
        ) { stmt in
            sqlite3_column_int64(stmt, 0)
        }.first ?? 0

        AppLog.debug(
            AppLog.sync,
            "sync-stats scoped pending=\(pending) uploading=\(uploading) bgQueued=\(bgQueued) failed=\(failed) synced=\(synced) lastSyncAt=\(last) includeUnassigned=\(includeUnassigned)"
        )
        return SyncStats(
            pending: pending,
            uploading: uploading,
            bgQueued: bgQueued,
            failed: failed,
            synced: synced,
            lastSyncAt: last
        )
    }

    func getStats() -> SyncStats {
        // Aggregate by asset (local_identifier) with precedence:
        // uploading > bgQueued > failed > synced (any part) > pending (no parts synced)
        let sql = """
        SELECT
          SUM(CASE WHEN has1=1 THEN 1 ELSE 0 END) AS uploading,
          SUM(CASE WHEN has1=0 AND has4=1 THEN 1 ELSE 0 END) AS bg,
          SUM(CASE WHEN has1=0 AND has4=0 AND has3=1 THEN 1 ELSE 0 END) AS failed,
          SUM(CASE WHEN has1=0 AND has4=0 AND has3=0 AND has2=1 THEN 1 ELSE 0 END) AS synced,
          SUM(CASE WHEN has1=0 AND has4=0 AND has3=0 AND has2=0 THEN 1 ELSE 0 END) AS pending
        FROM (
          SELECT local_identifier,
            MAX(CASE WHEN sync_state=1 THEN 1 ELSE 0 END) AS has1,
            MAX(CASE WHEN sync_state=4 THEN 1 ELSE 0 END) AS has4,
            MAX(CASE WHEN sync_state=3 THEN 1 ELSE 0 END) AS has3,
            MAX(CASE WHEN sync_state=2 THEN 1 ELSE 0 END) AS has2
          FROM photos
          WHERE local_identifier IS NOT NULL AND local_identifier <> ''
          GROUP BY local_identifier
        ) t
        """
        var uploading = 0, bgQueued = 0, failed = 0, synced = 0, pending = 0
        let vals: [(Int, Int, Int, Int, Int)] = db.executeSelect(sql) { stmt in
            let up = Int(sqlite3_column_int(stmt, 0))
            let bg = Int(sqlite3_column_int(stmt, 1))
            let fl = Int(sqlite3_column_int(stmt, 2))
            let sy = Int(sqlite3_column_int(stmt, 3))
            let pe = Int(sqlite3_column_int(stmt, 4))
            return (up, bg, fl, sy, pe)
        }
        if let first = vals.first {
            uploading = first.0; bgQueued = first.1; failed = first.2; synced = first.3; pending = first.4
        }
        let last: Int64 = db.executeSelect("SELECT IFNULL(MAX(sync_at),0) FROM photos") { stmt in sqlite3_column_int64(stmt, 0) }.first ?? 0
        AppLog.debug(
            AppLog.sync,
            "sync-stats pending=\(pending) uploading=\(uploading) bgQueued=\(bgQueued) failed=\(failed) synced=\(synced) lastSyncAt=\(last)"
        )
        return SyncStats(pending: pending, uploading: uploading, bgQueued: bgQueued, failed: failed, synced: synced, lastSyncAt: last)
    }

    // Reset any lingering 'uploading' rows to 'pending' (e.g., after app restart)
    @discardableResult
    func recoverStuckUploading() -> Int {
        let rows: [Int] = db.executeSelect(
            "UPDATE photos SET sync_state = 0 WHERE sync_state = 1 RETURNING 1"
        ) { _ in 1 }
        if !rows.isEmpty {
            scheduleStatsChangedNotification()
        }
        return rows.count
    }

    // Mark all local photos as pending (e.g., after server reset)
    // Returns number of rows affected (approximate on older SQLite without RETURNING)
    @discardableResult
    func resetAllSyncStates() -> Int {
        // Count rows that are not already pending
        let count: Int = db.executeSelect("SELECT COUNT(*) FROM photos WHERE sync_state <> 0") { stmt in
            Int(sqlite3_column_int(stmt, 0))
        }.first ?? 0
        _ = db.executeQuery("UPDATE photos SET sync_state = 0, attempts = 0, last_error = NULL, last_attempt_at = NULL, sync_at = NULL")
        scheduleStatsChangedNotification()
        return count
    }

    // Retry items stuck in backgroundQueued (state=4) by marking them pending again.
    // Returns count of affected rows.
    @discardableResult
    func retryBackgroundQueued() -> Int {
        let count: Int = db.executeSelect("SELECT COUNT(*) FROM photos WHERE sync_state = 4") { stmt in
            Int(sqlite3_column_int(stmt, 0))
        }.first ?? 0
        _ = db.executeQuery("UPDATE photos SET sync_state = 0 WHERE sync_state = 4")
        scheduleStatsChangedNotification()
        return count
    }

    // Retry items stuck in backgroundQueued (state=4) and failed (state=3) by marking them pending again.
    // Clears retry metadata so the next sync run starts cleanly.
    // Returns count of affected rows.
    @discardableResult
    func retryBackgroundQueuedAndFailed() -> Int {
        let count: Int = db.executeSelect("SELECT COUNT(*) FROM photos WHERE sync_state IN (3, 4)") { stmt in
            Int(sqlite3_column_int(stmt, 0))
        }.first ?? 0
        _ = db.executeQuery(
            "UPDATE photos SET sync_state = 0, attempts = 0, last_error = NULL, last_attempt_at = NULL WHERE sync_state IN (3, 4)"
        )
        scheduleStatsChangedNotification()
        return count
    }

    // Requeue background-queued rows older than the specified age (seconds).
    // Also requeue rows with NULL last_attempt_at for safety.
    @discardableResult
    func retryBackgroundQueued(olderThan seconds: Int64) -> Int {
        let now = Int64(Date().timeIntervalSince1970)
        let cutoff = now - seconds
        let count: Int = db.executeSelect(
            "SELECT COUNT(*) FROM photos WHERE sync_state = 4 AND (last_attempt_at IS NULL OR last_attempt_at <= ?)",
            parameters: [cutoff]
        ) { stmt in Int(sqlite3_column_int(stmt, 0)) }.first ?? 0
        _ = db.executeQuery(
            "UPDATE photos SET sync_state = 0 WHERE sync_state = 4 AND (last_attempt_at IS NULL OR last_attempt_at <= ?)",
            parameters: [cutoff]
        )
        scheduleStatsChangedNotification()
        return count
    }

    // Requeue failed rows that look transient (timeouts / 5xx / temporary transport issues).
    // Keeps `attempts` intact so permanently unhealthy items eventually stop auto-retrying.
    @discardableResult
    func retryTransientFailed(maxAttempts: Int = 12) -> Int {
        let patterns = [
            "%timed out%",
            "%timeout%",
            "%network connection was lost%",
            "%not connected to the internet%",
            "%cannot connect to host%",
            "%temporarily unavailable%",
            "http 408%",
            "http 429%",
            "http 5%"
        ]
        let errorExpr = "lower(COALESCE(last_error, ''))"
        let transientClause = patterns.map { _ in "\(errorExpr) LIKE ?" }.joined(separator: " OR ")
        let whereClause = "sync_state = 3 AND attempts <= ? AND (\(transientClause))"
        var params: [Any] = [maxAttempts]
        params.append(contentsOf: patterns)

        let count: Int = db.executeSelect(
            "SELECT COUNT(*) FROM photos WHERE \(whereClause)",
            parameters: params
        ) { stmt in Int(sqlite3_column_int(stmt, 0)) }.first ?? 0
        guard count > 0 else { return 0 }

        _ = db.executeQuery(
            "UPDATE photos SET sync_state = 0 WHERE \(whereClause)",
            parameters: params
        )
        scheduleStatsChangedNotification()
        return count
    }

    // Mark only photos in currently selected albums as pending
    @discardableResult
    func resetSyncStatesForSelectedAlbums(includeUnassigned: Bool = false) -> Int {
        let selectedSubquery = """
            SELECT DISTINCT ap.asset_id
            FROM album_photos ap
            WHERE EXISTS (
                SELECT 1 FROM album_closure ac
                JOIN albums a ON a.id = ac.ancestor_id
                WHERE ac.descendant_id = ap.album_id AND a.sync_enabled = 1
            )
        """
        let unassignedClause = includeUnassigned ? " OR local_identifier NOT IN (SELECT DISTINCT asset_id FROM album_photos)" : ""

        let countSql = """
            SELECT COUNT(*) FROM photos
            WHERE local_identifier IN (
                \(selectedSubquery)
            )\(unassignedClause)
        """
        let count: Int = db.executeSelect(countSql) { stmt in Int(sqlite3_column_int(stmt, 0)) }.first ?? 0

        let updateSql = """
            UPDATE photos
            SET sync_state = 0, attempts = 0, last_error = NULL, last_attempt_at = NULL, sync_at = NULL
            WHERE local_identifier IN (
                \(selectedSubquery)
            )\(unassignedClause)
        """
        _ = db.executeQuery(updateSql)
        scheduleStatsChangedNotification()
        return count
    }

    struct SyncInfo { let state: Int; let attempts: Int; let lastAttemptAt: Int64 }

    // Aggregate state across all rows for an asset (localIdentifier) with precedence:
    // uploading(1) > bgQueued(4) > failed(3) > synced(2) > pending(0)
    func getSyncInfoForLocalIdentifier(_ localIdentifier: String) -> SyncInfo? {
        let sql = """
        SELECT
            MAX(CASE WHEN sync_state = 1 THEN 1 ELSE 0 END) AS has1,
            MAX(CASE WHEN sync_state = 4 THEN 1 ELSE 0 END) AS has4,
            MAX(CASE WHEN sync_state = 3 THEN 1 ELSE 0 END) AS has3,
            MAX(CASE WHEN sync_state = 2 THEN 1 ELSE 0 END) AS has2,
            MAX(COALESCE(last_attempt_at, sync_at, 0)) AS latest_ts,
            MAX(attempts) AS max_attempts
        FROM photos
        WHERE local_identifier = ?
        """
        let rows: [(Int, Int, Int, Int, Int64, Int)] = db.executeSelect(sql, parameters: [localIdentifier]) { stmt in
            let h1 = Int(sqlite3_column_int(stmt, 0))
            let h4 = Int(sqlite3_column_int(stmt, 1))
            let h3 = Int(sqlite3_column_int(stmt, 2))
            let h2 = Int(sqlite3_column_int(stmt, 3))
            let ts = sqlite3_column_int64(stmt, 4)
            let att = Int(sqlite3_column_int(stmt, 5))
            return (h1, h4, h3, h2, ts, att)
        }
        guard let r = rows.first else { return nil }
        let state: Int = (r.0 > 0) ? 1 : (r.1 > 0) ? 4 : (r.2 > 0) ? 3 : (r.3 > 0) ? 2 : 0
        return SyncInfo(state: state, attempts: r.5, lastAttemptAt: r.4)
    }

    // MARK: - TUS upload URL persistence

    func setTusUploadURL(contentId: String, uploadURL: String) {
        let now = Int64(Date().timeIntervalSince1970)
        _ = db.executeQuery(
            "INSERT INTO tus_uploads(content_id, upload_url, created_at, last_used_at) VALUES (?, ?, ?, ?)\n             ON CONFLICT(content_id) DO UPDATE SET upload_url = excluded.upload_url, last_used_at = excluded.last_used_at",
            parameters: [contentId, uploadURL, now, now]
        )
    }

    func getTusUploadURL(contentId: String) -> String? {
        let rows: [String] = db.executeSelect(
            "SELECT upload_url FROM tus_uploads WHERE content_id = ?",
            parameters: [contentId]
        ) { stmt in
            if let c = sqlite3_column_text(stmt, 0) { return String(cString: c) }
            return nil
        }.compactMap { $0 }
        if let url = rows.first {
            let now = Int64(Date().timeIntervalSince1970)
            _ = db.executeQuery("UPDATE tus_uploads SET last_used_at = ? WHERE content_id = ?", parameters: [now, contentId])
            return url
        }
        return nil
    }

    func deleteTusUploadURL(contentId: String) {
        _ = db.executeQuery("DELETE FROM tus_uploads WHERE content_id = ?", parameters: [contentId])
    }

    func purgeOldTusUploadURLs(olderThan seconds: Int64 = 7 * 24 * 3600) {
        let cutoff = Int64(Date().timeIntervalSince1970) - seconds
        _ = db.executeQuery("DELETE FROM tus_uploads WHERE last_used_at < ?", parameters: [cutoff])
    }
}

extension SyncRepository {
    func getCachedBackupIdCandidates(userId: String, localIdentifier: String, fingerprint: String) -> [String]? {
        let rows: [(String, String)] = db.executeSelect(
            "SELECT fingerprint, candidates_json FROM backup_id_cache WHERE user_id = ? AND local_identifier = ? LIMIT 1",
            parameters: [userId, localIdentifier]
        ) { stmt in
            guard let fPtr = sqlite3_column_text(stmt, 0),
                  let jPtr = sqlite3_column_text(stmt, 1)
            else { return nil }
            return (String(cString: fPtr), String(cString: jPtr))
        }
        guard let (storedFingerprint, json) = rows.first, storedFingerprint == fingerprint else { return nil }
        guard let data = json.data(using: .utf8),
              let ids = try? JSONDecoder().decode([String].self, from: data),
              !ids.isEmpty
        else { return nil }
        return ids
    }

    func setCachedBackupIdCandidates(userId: String, localIdentifier: String, fingerprint: String, candidates: [String]) {
        guard !candidates.isEmpty else { return }
        guard let data = try? JSONEncoder().encode(candidates),
              let json = String(data: data, encoding: .utf8)
        else { return }
        let now = Int64(Date().timeIntervalSince1970)
        _ = db.executeQuery(
            """
            INSERT INTO backup_id_cache(user_id, local_identifier, fingerprint, candidates_json, updated_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(user_id, local_identifier) DO UPDATE SET
                fingerprint = excluded.fingerprint,
                candidates_json = excluded.candidates_json,
                updated_at = excluded.updated_at
            """,
            parameters: [userId, localIdentifier, fingerprint, json, now]
        )
    }
}
