import Foundation
import CryptoKit
import UIKit

/// DiskImageCache provides a simple, production‑oriented disk cache for image/video bytes.
///
/// - Location: NSCachesDirectory/OpenPhotos/{server_hash}/{user_id}/
/// - Buckets: thumbs/, images/, faces/, videos/
/// - LRU: Evicts oldest files by modification date when bucket exceeds configured cap.
/// - E2EE: For locked items we persist the decrypted bytes with FileProtection.complete.
/// - Threading: Lightweight and synchronous for simplicity; file IO happens on caller context.
final class DiskImageCache {
    static let shared = DiskImageCache()

    enum Bucket: String { case thumbs = "thumbs", images = "images", faces = "faces", videos = "videos" }

    // MARK: - Public configuration
    struct Caps {
        var thumbsBytes: Int64
        var imagesBytes: Int64
        var videosBytes: Int64

        static let defaults = Caps(
            thumbsBytes: 200 * 1024 * 1024, // 200 MB
            imagesBytes: 1024 * 1024 * 1024, // 1 GB
            videosBytes: 2 * 1024 * 1024 * 1024 // 2 GB
        )
    }

    private init() {}

    // MARK: - Public API

    /// Reads cached bytes for a given key/bucket, if present. Updates LRU timestamp on hit.
    func readData(bucket: Bucket, key: String) -> Data? {
        // NOTE: Cache keys are logical identifiers (e.g. server `asset_id`). We may store files on disk
        // with or without a file extension (e.g. `.webp`, `.jpg`, `.mov`) depending on the caller.
        // To avoid “cold start always re-downloads” behavior, reads must be extension-agnostic.
        guard let url = resolveExistingURL(bucket: bucket, key: key) else {
            print("[CACHE] Cache miss: \(bucket.rawValue)/\(key)")
            return nil
        }
        // Touch file to bump LRU (modification date)
        touch(url: url)
        if let data = try? Data(contentsOf: url) {
            print("[CACHE] ✓ Cache hit: \(bucket.rawValue)/\(key) (\(data.count) bytes)")
            return data
        }
        print("[CACHE] ✗ Failed to read: \(bucket.rawValue)/\(key)")
        return nil
    }

    /// Returns a file URL for a cached item (commonly used for videos). Updates LRU timestamp on hit.
    func readURL(bucket: Bucket, key: String) -> URL? {
        guard let url = resolveExistingURL(bucket: bucket, key: key) else { return nil }
        touch(url: url)
        return url
    }

#if DEBUG
    /// Debug-only, opt-in validation for disk cache behavior across app relaunches.
    ///
    /// Enable by launching the app with environment variable `OPENPHOTOS_CACHE_SELFTEST=1`.
    ///
    /// What it validates:
    /// - Cache reads are **extension-agnostic**: callers may write `{hash}.webp` / `{hash}.jpg` / `{hash}.mov`,
    ///   but most read call sites only know the logical key (`asset_id`, `personId`, etc).
    /// - The fix works across **process restarts** (the key property needed to speed up cold app starts).
    ///
    /// How it works:
    /// - Run 1: writes a small file for each bucket with an extension and stores the keys in UserDefaults.
    /// - Run 2: attempts to read those keys using the normal `readData`/`readURL` APIs, then cleans up.
    ///
    /// This is intentionally lightweight and never runs in release builds.
    func runStartupSelfTestIfRequested() {
        guard ProcessInfo.processInfo.environment["OPENPHOTOS_CACHE_SELFTEST"] == "1" else { return }

        struct UD {
            static let state = "cache.selftest.state"
            static let pid = "cache.selftest.pid"
            static let thumbsKey = "cache.selftest.thumbsKey"
            static let imagesKey = "cache.selftest.imagesKey"
            static let facesKey = "cache.selftest.facesKey"
            static let videosKey = "cache.selftest.videosKey"
        }

        let defaults = UserDefaults.standard
        let state = defaults.string(forKey: UD.state)
        let currentPid = Int(ProcessInfo.processInfo.processIdentifier)
        let payload = Data("openphotos-cache-selftest".utf8)

        if state == nil {
            let thumbsKey = "selftest_thumbs_" + UUID().uuidString
            let imagesKey = "selftest_images_" + UUID().uuidString
            let facesKey = "selftest_faces_" + UUID().uuidString
            let videosKey = "selftest_videos_" + UUID().uuidString

            _ = write(bucket: .thumbs, key: thumbsKey, data: payload, ext: "webp")
            _ = write(bucket: .images, key: imagesKey, data: payload, ext: "jpg")
            _ = write(bucket: .faces, key: facesKey, data: payload, ext: "jpg")
            _ = write(bucket: .videos, key: videosKey, data: payload, ext: "mov")

            defaults.set("written", forKey: UD.state)
            defaults.set(currentPid, forKey: UD.pid)
            defaults.set(thumbsKey, forKey: UD.thumbsKey)
            defaults.set(imagesKey, forKey: UD.imagesKey)
            defaults.set(facesKey, forKey: UD.facesKey)
            defaults.set(videosKey, forKey: UD.videosKey)

            NSLog("[CACHE-SELFTEST] Phase 1/2: wrote test entries; relaunch to verify reads")
            return
        }

        guard state == "written" else {
            defaults.removeObject(forKey: UD.state)
            defaults.removeObject(forKey: UD.pid)
            defaults.removeObject(forKey: UD.thumbsKey)
            defaults.removeObject(forKey: UD.imagesKey)
            defaults.removeObject(forKey: UD.facesKey)
            defaults.removeObject(forKey: UD.videosKey)
            NSLog("[CACHE-SELFTEST] Reset unexpected state=%@", state ?? "nil")
            return
        }

        // Ensure phase 2 only runs after a real process restart; SwiftUI can re-trigger `.onAppear`.
        let writtenPid = defaults.integer(forKey: UD.pid)
        if writtenPid != 0 && writtenPid == currentPid {
            NSLog("[CACHE-SELFTEST] Phase 2/2 deferred: same process (pid=%d); terminate and relaunch to validate across restart", currentPid)
            return
        }

        let thumbsKey = defaults.string(forKey: UD.thumbsKey) ?? ""
        let imagesKey = defaults.string(forKey: UD.imagesKey) ?? ""
        let facesKey = defaults.string(forKey: UD.facesKey) ?? ""
        let videosKey = defaults.string(forKey: UD.videosKey) ?? ""

        func cleanup(bucket: Bucket, key: String) {
            guard let url = readURL(bucket: bucket, key: key) else { return }
            try? FileManager.default.removeItem(at: url)
        }

        var ok = true

        if let d = readData(bucket: .thumbs, key: thumbsKey) {
            ok = ok && (d == payload)
        } else {
            ok = false
        }

        if let d = readData(bucket: .images, key: imagesKey) {
            ok = ok && (d == payload)
        } else {
            ok = false
        }

        if let d = readData(bucket: .faces, key: facesKey) {
            ok = ok && (d == payload)
        } else {
            ok = false
        }

        if let url = readURL(bucket: .videos, key: videosKey), let d = try? Data(contentsOf: url) {
            ok = ok && (d == payload)
        } else {
            ok = false
        }

        cleanup(bucket: .thumbs, key: thumbsKey)
        cleanup(bucket: .images, key: imagesKey)
        cleanup(bucket: .faces, key: facesKey)
        cleanup(bucket: .videos, key: videosKey)

        defaults.removeObject(forKey: UD.state)
        defaults.removeObject(forKey: UD.pid)
        defaults.removeObject(forKey: UD.thumbsKey)
        defaults.removeObject(forKey: UD.imagesKey)
        defaults.removeObject(forKey: UD.facesKey)
        defaults.removeObject(forKey: UD.videosKey)

        if ok {
            NSLog("[CACHE-SELFTEST] ✅ PASS: extension-agnostic reads work across relaunch")
        } else {
            NSLog("[CACHE-SELFTEST] ❌ FAIL: extension-agnostic reads did not behave as expected")
        }
    }
#endif

    /// Writes bytes to cache atomically. Applies file protection when provided.
    /// The `ext` parameter allows hinting a suitable extension for better OS interop (e.g. .webp, .jpg, .mov).
    @discardableResult
    func write(bucket: Bucket, key: String, data: Data, ext: String? = nil, protection: FileProtectionType? = nil) -> URL? {
        // First ensure Library/Caches itself is a directory
        ensureSystemCachesDirectory()

        let url = fileURL(bucket: bucket, key: key, ext: ext)

        // Try write with automatic recovery on failure
        var attempts = 0
        while attempts < 2 {
            attempts += 1

            do {
                // Ensure directory exists
                if let dir = url.deletingLastPathComponent() as URL? {
                    try createDirectoryFixingFilesInPath(at: dir)
                }
                try data.write(to: url, options: [.atomic])
                // Apply protection level if requested (e.g., .complete for decrypted E2EE)
                if let protection {
                    do {
                        try FileManager.default.setAttributes([.protectionKey: protection], ofItemAtPath: url.path)
                    } catch {
                        print("[CACHE] Warning: Failed to set file protection for \(bucket.rawValue)/\(key): \(error.localizedDescription)")
                    }
                }
                // Touch modification time
                touch(url: url)
                // Enforce cap for this bucket
                pruneIfNeeded(bucket: bucket)
                print("[CACHE] ✓ Wrote \(data.count) bytes to \(bucket.rawValue)/\(key)")
                return url
            } catch let error as NSError {
                print("[CACHE] ✗ Failed to write \(bucket.rawValue)/\(key) (attempt \(attempts)): \(error.localizedDescription)")
                print("[CACHE]   Path: \(url.path)")
                print("[CACHE]   Data size: \(data.count) bytes")
                print("[CACHE]   Error domain: \(error.domain), code: \(error.code)")

                // Check for POSIX error 20 "Not a directory" on first attempt
                if attempts == 1 {
                    if let underlyingError = error.userInfo[NSUnderlyingErrorKey] as? NSError,
                       underlyingError.domain == NSPOSIXErrorDomain && underlyingError.code == 20 {
                        print("[CACHE] ⚠️ Detected corrupted cache structure (POSIX 20), attempting recovery...")
                        forceRecreateSystemCachesDirectory()
                        continue // Retry the write
                    }
                }

                // If we've exhausted attempts, give up
                if attempts >= 2 {
                    return nil
                }
            }
        }

        return nil
    }

    /// Clears all cached buckets for current server/user.
    func clearAll() {
        let root = baseRoot()
        if FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// Computes the current on-disk usage for a bucket.
    func usageBytes(bucket: Bucket) -> Int64 {
        let dir = bucketURL(bucket)
        guard let files = try? FileManager.default.subpathsOfDirectory(atPath: dir.path) else { return 0 }
        var total: Int64 = 0
        for rel in files {
            let fp = dir.appendingPathComponent(rel).path
            if let sz = (try? FileManager.default.attributesOfItem(atPath: fp)[.size] as? NSNumber)?.int64Value {
                total += sz
            }
        }
        return total
    }

    /// Returns the effective caps (bytes) pulling from UserDefaults when set.
    func caps() -> Caps {
        let d = UserDefaults.standard
        func g(_ k: String, _ def: Int64) -> Int64 { let v = d.object(forKey: k) as? NSNumber; return v?.int64Value ?? def }
        return Caps(
            thumbsBytes: g(UDKeys.capThumbs, Caps.defaults.thumbsBytes),
            imagesBytes: g(UDKeys.capImages, Caps.defaults.imagesBytes),
            videosBytes: g(UDKeys.capVideos, Caps.defaults.videosBytes)
        )
    }

    /// Persists new caps (bytes) to UserDefaults.
    func setCaps(_ caps: Caps) {
        let d = UserDefaults.standard
        d.set(NSNumber(value: caps.thumbsBytes), forKey: UDKeys.capThumbs)
        d.set(NSNumber(value: caps.imagesBytes), forKey: UDKeys.capImages)
        d.set(NSNumber(value: caps.videosBytes), forKey: UDKeys.capVideos)
    }

    /// Diagnostic function to check cache health and report issues
    func diagnostics() -> String {
        var report: [String] = []
        report.append("=== DiskImageCache Diagnostics ===")

        // Check auth state
        let serverURL = AuthManager.shared.serverURL
        let userId = AuthManager.shared.userId ?? "nil"
        report.append("Server URL: \(serverURL)")
        report.append("User ID: \(userId)")
        report.append("Server Hash: \(serverHash())")

        // First, fix the system Library/Caches if it's corrupted
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        report.append("\n=== Library/Caches Check ===")
        report.append("Path: \(cachesDir.path)")

        // Do multiple checks to understand what's happening
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: cachesDir.path, isDirectory: &isDir)
        report.append("Exists: \(exists), IsDirectory: \(isDir.boolValue)")

        // Check file attributes
        if let attrs = try? FileManager.default.attributesOfItem(atPath: cachesDir.path) {
            report.append("Type: \(attrs[.type] ?? "unknown")")
            report.append("Size: \(attrs[.size] ?? "unknown")")

            // Try to list contents if it's supposedly a directory
            if isDir.boolValue {
                do {
                    let contents = try FileManager.default.contentsOfDirectory(atPath: cachesDir.path)
                    report.append("Contents count: \(contents.count)")
                    if contents.count > 0 && contents.count < 10 {
                        report.append("Contents: \(contents.joined(separator: ", "))")
                    }
                } catch {
                    report.append("⚠️ Can't list contents: \(error.localizedDescription)")
                }
            }
        }

        // Force recreate if something is wrong
        if exists && !isDir.boolValue {
            report.append("⚠️ CRITICAL: Library/Caches is a FILE, not a directory!")
            report.append("  Attempting to fix...")
            do {
                try FileManager.default.removeItem(at: cachesDir)
                report.append("  ✓ Removed file")
                try FileManager.default.createDirectory(at: cachesDir, withIntermediateDirectories: true)
                report.append("  ✓ Created directory")
            } catch {
                report.append("  ✗ Failed to fix: \(error)")
            }
        } else if !exists {
            report.append("Library/Caches doesn't exist, creating...")
            do {
                try FileManager.default.createDirectory(at: cachesDir, withIntermediateDirectories: true)
                report.append("  ✓ Created Library/Caches")
            } catch {
                report.append("  ✗ Failed to create: \(error)")
            }
        } else {
            // It says it's a directory, but let's try to recreate it anyway since writes are failing
            report.append("Library/Caches claims to be a directory, but writes fail with 'Not a directory'")
            report.append("⚠️ Forcing recreation...")
            do {
                try FileManager.default.removeItem(at: cachesDir)
                report.append("  ✓ Removed existing Library/Caches")
                try FileManager.default.createDirectory(at: cachesDir, withIntermediateDirectories: true)
                report.append("  ✓ Recreated Library/Caches as directory")

                // Verify
                var checkDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: cachesDir.path, isDirectory: &checkDir) {
                    report.append("  ✓ Verified: exists=true, isDir=\(checkDir.boolValue)")
                }
            } catch {
                report.append("  ✗ Failed to recreate: \(error)")
            }
        }
        report.append("")

        // Check base root
        let root = baseRoot()
        report.append("Cache Root: \(root.path)")
        let rootExists = FileManager.default.fileExists(atPath: root.path)
        report.append("Root Exists: \(rootExists)")

        // Check each bucket
        for bucket in [Bucket.thumbs, Bucket.images, Bucket.faces, Bucket.videos] {
            let dir = bucketURL(bucket)
            let exists = FileManager.default.fileExists(atPath: dir.path)
            let usage = usageBytes(bucket: bucket)
            report.append("\(bucket.rawValue): exists=\(exists), usage=\(ByteCountFormatter.string(fromByteCount: usage, countStyle: .file))")
        }

        // Test write with detailed error reporting
        report.append("\nTesting write capability...")

        // Ensure Library/Caches is a directory before testing
        ensureSystemCachesDirectory()

        let testData = Data("test".utf8)
        let testKey = "diagnostic_test_\(UUID().uuidString)"
        let testURL = fileURL(bucket: .thumbs, key: testKey)

        do {
            // Try to create directory structure manually
            let dir = testURL.deletingLastPathComponent()
            report.append("Test file path: \(testURL.path)")
            report.append("Test directory: \(dir.path)")

            try createDirectoryFixingFilesInPath(at: dir)
            report.append("✓ Directory creation succeeded")

            try testData.write(to: testURL, options: [.atomic])
            report.append("✓ File write succeeded")

            // Verify we can read it back
            if let readBack = try? Data(contentsOf: testURL), readBack == testData {
                report.append("✓ File read verification succeeded")
            } else {
                report.append("✗ File read verification FAILED")
            }

            // Clean up
            try? FileManager.default.removeItem(at: testURL)
            report.append("✓ Test cleanup succeeded")
        } catch {
            report.append("✗ Test write FAILED: \(error.localizedDescription)")
            report.append("   Error details: \(error)")

            // Check parent directory permissions
            let parent = testURL.deletingLastPathComponent().deletingLastPathComponent()
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDir) {
                report.append("   Parent exists: \(isDir.boolValue ? "directory" : "file")")
                if let attrs = try? FileManager.default.attributesOfItem(atPath: parent.path) {
                    report.append("   Parent attributes: \(attrs)")
                }
            } else {
                report.append("   Parent directory does not exist: \(parent.path)")
            }
        }

        return report.joined(separator: "\n")
    }

    // MARK: - Internals

    private enum UDKeys {
        static let capThumbs = "cache.cap.thumbs"
        static let capImages = "cache.cap.images"
        static let capVideos = "cache.cap.videos"
    }

    /// Ensures the system Library/Caches directory exists and is a directory (not a file)
    private func ensureSystemCachesDirectory() {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        print("[CACHE-FIX] ensureSystemCachesDirectory called")
        print("[CACHE-FIX] Checking path: \(cachesDir.path)")

        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: cachesDir.path, isDirectory: &isDir)
        print("[CACHE-FIX] Exists: \(exists), IsDirectory: \(isDir.boolValue)")

        if exists {
            if !isDir.boolValue {
                print("[CACHE-FIX] ⚠️ CRITICAL: Library/Caches is a FILE!")
                print("[CACHE-FIX] Attempting to remove file at: \(cachesDir.path)")
                do {
                    try FileManager.default.removeItem(at: cachesDir)
                    print("[CACHE-FIX] ✓ Removed file")
                    try FileManager.default.createDirectory(at: cachesDir, withIntermediateDirectories: true)
                    print("[CACHE-FIX] ✓ Created directory")
                } catch {
                    print("[CACHE-FIX] ✗ Failed: \(error)")
                }
            } else {
                print("[CACHE-FIX] ✓ Library/Caches is already a directory")
            }
        } else {
            print("[CACHE-FIX] Library/Caches doesn't exist, creating...")
            do {
                try FileManager.default.createDirectory(at: cachesDir, withIntermediateDirectories: true)
                print("[CACHE-FIX] ✓ Created Library/Caches directory")
            } catch {
                print("[CACHE-FIX] ✗ Failed to create: \(error)")
            }
        }

        // Double-check the result
        var checkDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: cachesDir.path, isDirectory: &checkDir) {
            print("[CACHE-FIX] Final check - Exists: true, IsDirectory: \(checkDir.boolValue)")
        } else {
            print("[CACHE-FIX] Final check - DOES NOT EXIST!")
        }
    }

    /// Force recreates the Library/Caches directory when it's corrupted
    private func forceRecreateSystemCachesDirectory() {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        print("[CACHE-RECOVERY] Force recreating Library/Caches at: \(cachesDir.path)")

        // First, try to remove whatever exists at this path (file or directory)
        do {
            if FileManager.default.fileExists(atPath: cachesDir.path) {
                print("[CACHE-RECOVERY] Removing existing item at path...")
                try FileManager.default.removeItem(at: cachesDir)
                print("[CACHE-RECOVERY] ✓ Removed existing item")
            }
        } catch {
            print("[CACHE-RECOVERY] ⚠️ Could not remove existing item: \(error)")
            // Continue anyway - we'll try to create the directory
        }

        // Now recreate the directory fresh
        do {
            print("[CACHE-RECOVERY] Creating fresh Library/Caches directory...")
            try FileManager.default.createDirectory(at: cachesDir, withIntermediateDirectories: true, attributes: nil)
            print("[CACHE-RECOVERY] ✓ Created fresh Library/Caches directory")

            // Verify it worked
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: cachesDir.path, isDirectory: &isDir) {
                print("[CACHE-RECOVERY] Verification: Exists=true, IsDirectory=\(isDir.boolValue)")

                // Test a simple write to make sure it actually works
                let testFile = cachesDir.appendingPathComponent("test_\(UUID().uuidString).txt")
                let testData = Data("test".utf8)
                do {
                    try testData.write(to: testFile)
                    try FileManager.default.removeItem(at: testFile)
                    print("[CACHE-RECOVERY] ✓✓✓ Write test successful! Cache directory is now functional.")
                } catch {
                    print("[CACHE-RECOVERY] ⚠️ Write test failed: \(error)")
                }
            } else {
                print("[CACHE-RECOVERY] ⚠️ Directory creation reported success but directory doesn't exist!")
            }
        } catch {
            print("[CACHE-RECOVERY] ✗ Failed to create directory: \(error)")
        }
    }

    /// Normalizes server URL and returns an 10‑hex SHA256 prefix for namespacing cache root.
    private func serverHash() -> String {
        let raw = AuthManager.shared.serverURL
        guard let url = URL(string: raw) else { return "unknown" }
        var hostPort = (url.scheme ?? "http") + "://" + (url.host ?? "")
        if let p = url.port { hostPort += ":\(p)" }
        let digest = SHA256.hash(data: Data(hostPort.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(10).description
    }

    private func baseRoot() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let server = serverHash()
        let uid = AuthManager.shared.userId ?? "anon"
        return caches.appendingPathComponent("OpenPhotos").appendingPathComponent(server).appendingPathComponent(uid)
    }

    /// Returns the on-disk URL for a cached item if it exists.
    ///
    /// Why this exists:
    /// - Callers write cache files with optional extensions (e.g. thumbnails as `.webp`, faces as `.jpg`,
    ///   videos as `.mov/.mp4`). Historically, reads assumed “no extension”, which makes disk cache
    ///   effectively unusable after an app relaunch (memory cache is empty and disk lookups miss).
    /// - We resolve by checking the no-extension path first (most stable) and then a short list of
    ///   expected extensions per bucket.
    private func resolveExistingURL(bucket: Bucket, key: String) -> URL? {
        let fm = FileManager.default

        let base = fileURL(bucket: bucket, key: key, ext: nil)
        if fm.fileExists(atPath: base.path) { return base }

        for ext in candidateExtensions(bucket: bucket) {
            let u = fileURL(bucket: bucket, key: key, ext: ext)
            if fm.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    /// Bucket-specific extension candidates used by `resolveExistingURL`.
    /// Keep this list small (hot path during scrolling) while covering current write patterns.
    private func candidateExtensions(bucket: Bucket) -> [String] {
        switch bucket {
        case .thumbs:
            // Current thumbnails are stored as WebP; include common fallbacks for compatibility.
            return ["webp", "jpg", "jpeg", "png"]
        case .images:
            // Original assets may be HEIC/JPEG/PNG, and the server may serve AVIF for HEIC in some cases.
            return ["heic", "heif", "avif", "jpg", "jpeg", "png", "webp"]
        case .faces:
            return ["jpg", "jpeg", "png", "webp"]
        case .videos:
            return ["mov", "mp4", "m4v"]
        }
    }

    private func bucketURL(_ bucket: Bucket) -> URL {
        return baseRoot().appendingPathComponent(bucket.rawValue, isDirectory: true)
    }

    /// Builds a stable file URL with 2‑level sharding from a hashed key. If `ext` is provided it is appended.
    private func fileURL(bucket: Bucket, key: String, ext: String? = nil) -> URL {
        // Hash the key for safe filenames and stable shard
        let digest = SHA256.hash(data: Data(key.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let a = String(hex.prefix(2))
        let b = String(hex.dropFirst(2).prefix(2))
        var name = hex
        if let ext, !ext.isEmpty { name += "." + ext }
        return bucketURL(bucket).appendingPathComponent(a, isDirectory: true).appendingPathComponent(b, isDirectory: true).appendingPathComponent(name, isDirectory: false)
    }

    /// Updates the modification date of a file to now to approximate an access timestamp.
    private func touch(url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    /// Creates a directory, fixing any files that exist in the path where directories should be.
    /// This handles the case where `Library/Caches` or other path components are files instead of directories.
    private func createDirectoryFixingFilesInPath(at url: URL) throws {
        let fm = FileManager.default

        print("[CACHE] createDirectoryFixingFilesInPath called for: \(url.path)")

        // Try normal directory creation first
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            print("[CACHE] ✓ Normal directory creation succeeded")
            return
        } catch let error as NSError {
            print("[CACHE] ✗ Directory creation failed with error")
            print("[CACHE]   Error domain: \(error.domain)")
            print("[CACHE]   Error code: \(error.code)")
            print("[CACHE]   Error description: \(error.localizedDescription)")
            print("[CACHE]   UserInfo keys: \(error.userInfo.keys)")

            // Check if this is the "Not a directory" error (POSIX error 20)
            if let underlyingError = error.userInfo[NSUnderlyingErrorKey] as? NSError {
                print("[CACHE]   Found underlying error:")
                print("[CACHE]     Domain: \(underlyingError.domain)")
                print("[CACHE]     Code: \(underlyingError.code)")

                if underlyingError.domain == NSPOSIXErrorDomain && underlyingError.code == 20 {
                    print("[CACHE] ✓ Detected POSIX error 20 'Not a directory' - fixing corrupted path")
                    print("[CACHE]   Target path: \(url.path)")

                    // Walk through the path components and fix any that are files
                    let components = url.pathComponents
                    var currentURL = URL(fileURLWithPath: "/")

                    for (index, component) in components.enumerated() {
                        if component == "/" {
                            continue // Skip root
                        }

                        currentURL.appendPathComponent(component)
                        let currentPath = currentURL.path

                        var isDirectory: ObjCBool = false
                        if fm.fileExists(atPath: currentPath, isDirectory: &isDirectory) {
                            print("[CACHE]   Checking: \(currentPath) (isDir=\(isDirectory.boolValue))")
                            if !isDirectory.boolValue {
                                // This component is a file but should be a directory - remove it
                                print("[CACHE]   ✗ Found file blocking directory: \(currentPath)")
                                print("[CACHE]     → Removing file...")
                                try fm.removeItem(atPath: currentPath)
                                print("[CACHE]     → Creating directory...")
                                try fm.createDirectory(atPath: currentPath, withIntermediateDirectories: false)
                                print("[CACHE]     ✓ Fixed: \(currentPath)")
                            }
                        }
                    }

                    // Now try creating the full path again
                    print("[CACHE]   Retrying full directory creation...")
                    try fm.createDirectory(at: url, withIntermediateDirectories: true)
                    print("[CACHE] ✓✓✓ Successfully fixed and created directory!")
                } else {
                    print("[CACHE]   Underlying error is not POSIX 20")
                    throw error
                }
            } else {
                print("[CACHE]   No underlying error found")
                throw error
            }
        }
    }

    /// Enforces the per‑bucket size cap by deleting oldest files first (LRU approximation via mtime).
    private func pruneIfNeeded(bucket: Bucket) {
        let capBytes: Int64
        switch bucket {
        case .thumbs, .faces:
            // Faces share the thumbs cap
            capBytes = caps().thumbsBytes
        case .images:
            capBytes = caps().imagesBytes
        case .videos:
            capBytes = caps().videosBytes
        }
        let dir = bucketURL(bucket)
        guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
        var files: [(url: URL, mtime: Date, size: Int64)] = []
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let res = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey])
            if res?.isRegularFile == true {
                let m = res?.contentModificationDate ?? Date.distantPast
                let s = Int64(res?.fileSize ?? 0)
                files.append((url, m, s)); total += s
            }
        }
        if total <= capBytes { return }
        // Oldest first
        files.sort { $0.mtime < $1.mtime }
        for f in files {
            try? FileManager.default.removeItem(at: f.url)
            total -= f.size
            if total <= capBytes { break }
        }
    }
}
