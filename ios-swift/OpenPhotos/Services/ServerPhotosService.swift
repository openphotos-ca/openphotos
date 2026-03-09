import Foundation
import UIKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// ServerPhotosService wraps the server photo/album APIs used by the server-backed Photos tab.
/// It uses AuthorizedHTTPClient to include auth headers and token refresh.
final class ServerPhotosService {
    static let shared = ServerPhotosService()
    private init() {}

    // MARK: - Core fetchers

    func listPhotos(query: ServerPhotoListQuery) async throws -> ServerPhotoListResponse {
        let url = AuthorizedHTTPClient.shared.buildURL(path: "/api/photos", queryItems: query.asQueryItems())
        do {
            return try await AuthorizedHTTPClient.shared.getJSON(url)
        } catch {
            let ns = error as NSError
            if ns.domain == "HTTP" && ns.code == 401 {
                throw error
            }
            // Fallback to legacy alias
            let url2 = AuthorizedHTTPClient.shared.buildURL(path: "/api/media", queryItems: query.asQueryItems())
            return try await AuthorizedHTTPClient.shared.getJSON(url2)
        }
    }

    func getMediaCounts(query: ServerPhotoListQuery) async throws -> ServerMediaCounts {
        let url = AuthorizedHTTPClient.shared.buildURL(path: "/api/media/counts", queryItems: query.asQueryItems())
        return try await AuthorizedHTTPClient.shared.getJSON(url)
    }

    func bucketYears(query: ServerPhotoListQuery) async throws -> [ServerYearBucket] {
        let url = AuthorizedHTTPClient.shared.buildURL(path: "/api/buckets/years", queryItems: query.asQueryItems())
        return try await AuthorizedHTTPClient.shared.getJSON(url)
    }

    func listAlbums() async throws -> [ServerAlbum] {
        try await AuthorizedHTTPClient.shared.getJSON(AuthorizedHTTPClient.shared.buildURL(path: "/api/albums"))
    }

    // List albums for a specific photo (numeric id)
    func getAlbumsForPhoto(photoId: Int) async throws -> [ServerAlbum] {
        let url = AuthorizedHTTPClient.shared.buildURL(path: "/api/photos/\(photoId)/albums")
        return try await AuthorizedHTTPClient.shared.getJSON(url)
    }

    // MARK: - Filters metadata (faces, locations, cameras)
    func getFilterMetadata() async throws -> ServerFilterMetadata {
        try await AuthorizedHTTPClient.shared.getJSON(path: "/api/filters/metadata")
    }

    /// Build an authenticated URL for a face thumbnail by person id. The caller should use
    /// AuthorizedHTTPClient to attach auth headers when fetching bytes.
    func getFaceThumbnailUrl(personId: String) -> URL? {
        return AuthorizedHTTPClient.shared.buildURL(path: "/api/face-thumbnail", queryItems: [URLQueryItem(name: "personId", value: personId)])
    }

    // MARK: - Album management

    func createAlbum(name: String, description: String? = nil, parentId: Int? = nil) async throws -> ServerAlbum {
        struct Req: Encodable { let name: String; let description: String?; let parent_id: Int? }
        return try await AuthorizedHTTPClient.shared.postJSON(path: "/api/albums", body: Req(name: name, description: description, parent_id: parentId))
    }

    func createLiveAlbum(name: String, description: String? = nil, parentId: Int? = nil, criteria: ServerPhotoListQuery) async throws -> ServerAlbum {
        struct Req: Encodable { let name: String; let description: String?; let parent_id: Int?; let criteria: ServerPhotoListQuery }
        return try await AuthorizedHTTPClient.shared.postJSON(path: "/api/albums/live", body: Req(name: name, description: description, parent_id: parentId, criteria: criteria))
    }

    func updateLiveAlbum(id: Int, name: String? = nil, description: String? = nil, parent_id: Int? = nil, position: Int? = nil, criteria: ServerPhotoListQuery? = nil) async throws -> ServerAlbum {
        struct Req: Encodable {
            let id: Int
            let name: String?
            let description: String?
            let parent_id: Int?
            let position: Int?
            let criteria: ServerPhotoListQuery?
        }
        let payload = Req(id: id, name: name, description: description, parent_id: parent_id, position: position, criteria: criteria)
        return try await AuthorizedHTTPClient.shared.postJSON(path: "/api/albums/live/update", body: payload)
    }

    func updateAlbum(id: Int, name: String? = nil, description: String? = nil, parentId: Int? = nil, position: Int? = nil) async throws -> ServerAlbum {
        struct Req: Encodable { let id: Int; let name: String?; let description: String?; let parent_id: Int?; let position: Int? }
        return try await AuthorizedHTTPClient.shared.postJSON(path: "/api/albums/update", body: Req(id: id, name: name, description: description, parent_id: parentId, position: position))
    }

    /// Freeze a live album to a new static album id.
    func freezeAlbum(id: Int, name: String?) async throws -> ServerAlbum {
        struct Req: Encodable { let name: String? }
        let url = AuthorizedHTTPClient.shared.buildURL(path: "/api/albums/\(id)/freeze")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(Req(name: name))
        let (data, http) = try await AuthorizedHTTPClient.shared.request(req)
        guard (200..<300).contains(http.statusCode) else { throw NSError(domain: "Server", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "freeze failed"]) }
        return try JSONDecoder().decode(ServerAlbum.self, from: data)
    }

    func deleteAlbum(id: Int) async throws {
        var req = URLRequest(url: AuthorizedHTTPClient.shared.buildURL(path: "/api/albums/\(id)"))
        req.httpMethod = "DELETE"
        _ = try await AuthorizedHTTPClient.shared.request(req)
    }

    func addPhotosToAlbum(albumId: Int, assetIds: [String]) async throws {
        struct Req: Encodable { let photo_ids: [Int] }
        let numericIds = try await resolvePhotoIds(assetIds: assetIds)
        let url = AuthorizedHTTPClient.shared.buildURL(path: "/api/albums/\(albumId)/photos")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(Req(photo_ids: numericIds))
        _ = try await AuthorizedHTTPClient.shared.request(req)
    }

    func removePhotosFromAlbum(albumId: Int, assetIds: [String]) async throws {
        struct Req: Encodable { let photo_ids: [Int] }
        let numericIds = try await resolvePhotoIds(assetIds: assetIds)
        let url = AuthorizedHTTPClient.shared.buildURL(path: "/api/albums/\(albumId)/photos/remove")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(Req(photo_ids: numericIds))
        _ = try await AuthorizedHTTPClient.shared.request(req)
    }

    // MARK: - Photo mutations

    func setFavorite(assetId: String, favorite: Bool) async throws {
        struct Req: Encodable { let favorite: Bool }
        let path = "/api/photos/\(assetId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? assetId)/favorite"
        let url = URL(string: AuthManager.shared.serverURL + path)!
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(Req(favorite: favorite))
        _ = try await AuthorizedHTTPClient.shared.request(req)
    }

    func lock(assetId: String) async throws {
        let path = "/api/photos/\(assetId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? assetId)/lock"
        let url = URL(string: AuthManager.shared.serverURL + path)!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        _ = try await AuthorizedHTTPClient.shared.request(req)
    }

    /// Encrypt and replace an existing server photo as a locked item using the client-side UMK.
    /// This avoids the legacy flag-only lock API path which can leave undecryptable rows.
    /// If a row is already marked locked but content is not PAE3, this path repairs it in place.
    func lockWithEncryption(photo: ServerPhoto) async throws {
        print("[LOCKED] start asset=\(photo.asset_id) locked=\(photo.locked == true) video=\(photo.is_video) live=\(photo.is_live_photo == true)")
        if photo.is_video {
            throw NSError(
                domain: "ServerLock",
                code: 1001,
                userInfo: [NSLocalizedDescriptionKey: "Lock from iOS currently supports photos only"]
            )
        }
        if photo.is_live_photo == true {
            throw NSError(
                domain: "ServerLock",
                code: 1002,
                userInfo: [NSLocalizedDescriptionKey: "Lock for Live Photos is not supported in iOS Cloud tab yet"]
            )
        }
        let (rawData, fetchedMime) = try await fetchOriginalBytes(assetId: photo.asset_id)
        print("[LOCKED] fetched original asset=\(photo.asset_id) bytes=\(rawData.count) mime=\(fetchedMime ?? "unknown")")
        if rawData.starts(with: Data("PAE3".utf8)) {
            // Already a valid locked container.
            print("[LOCKED] skip already-encrypted asset=\(photo.asset_id)")
            return
        }
        if photo.locked == true {
            print("[LOCKED] repairing legacy non-PAE3 locked row asset=\(photo.asset_id)")
        }
        guard let userId = AuthManager.shared.userId, !userId.isEmpty else {
            throw NSError(
                domain: "ServerLock",
                code: 1003,
                userInfo: [NSLocalizedDescriptionKey: "Missing user id"]
            )
        }
        guard let umk = E2EEManager.shared.umk, umk.count == 32 else {
            throw NSError(
                domain: "ServerLock",
                code: 1004,
                userInfo: [NSLocalizedDescriptionKey: "Unlock required before locking"]
            )
        }

        let fm = FileManager.default
        let inputExt = fileExtension(fromMime: fetchedMime ?? photo.mime_type, filename: photo.filename, fallback: "bin")
        let plainOriginal = uploadTempFileURL(name: UUID().uuidString + "." + inputExt)
        try rawData.write(to: plainOriginal, options: .atomic)

        var cleanupURLs: [URL] = [plainOriginal]
        defer {
            for url in cleanupURLs {
                try? fm.removeItem(at: url)
            }
        }

        var plainURL = plainOriginal
        var plainMime = fetchedMime ?? photo.mime_type ?? "application/octet-stream"
        var pixelWidth = max(0, photo.width ?? 0)
        var pixelHeight = max(0, photo.height ?? 0)
        let durationSec = max(0, Int((photo.duration_ms ?? 0) / 1000))

        // Match web behavior: convert HEIC/HEIF to JPEG before encrypting for broad compatibility.
        if shouldConvertHeicToJpeg(mimeType: plainMime, filename: photo.filename ?? "") {
            if let converted = convertHEICtoJPEG(inputURL: plainURL, quality: 0.9) {
                plainURL = converted.url
                plainMime = "image/jpeg"
                pixelWidth = converted.width
                pixelHeight = converted.height
                cleanupURLs.append(converted.url)
            }
        }

        let createdAt = photo.created_at > 0 ? photo.created_at : Int64(Date().timeIntervalSince1970)
        let ymd = utcYmdString(epochSeconds: createdAt)
        let plainBytes = (try? fm.attributesOfItem(atPath: plainURL.path)[.size] as? NSNumber)?.int64Value ?? Int64(rawData.count)

        var headerMeta: [String: JSONValue] = [
            "capture_ymd": .string(ymd),
            "size_kb": .number(Double(max(1, Int((plainBytes + 1023) / 1024)))),
            "width": .number(Double(pixelWidth)),
            "height": .number(Double(pixelHeight)),
            "orientation": .number(1),
            "is_video": .number(0),
            "duration_s": .number(Double(durationSec)),
            "mime_hint": .string(plainMime),
            "kind": .string("orig"),
        ]

        var tusMeta: [String: String] = [
            "locked": "1",
            "crypto_version": "3",
            "kind": "orig",
            // Use existing server asset id so lock operation replaces in place (no duplicate row).
            "asset_id_b58": photo.asset_id,
            "capture_ymd": ymd,
            "size_kb": String(max(1, Int((plainBytes + 1023) / 1024))),
            "width": String(pixelWidth),
            "height": String(pixelHeight),
            "orientation": "1",
            "is_video": "0",
            "duration_s": String(durationSec),
            "mime_hint": plainMime,
            "created_at": String(createdAt),
        ]

        if let bid = BackupId.computeBackupId(fileURL: plainURL, userId: userId) {
            tusMeta["backup_id"] = bid
        }

        // Optional plaintext metadata retained according to user preference.
        let prefs = SecurityPreferences.shared
        if prefs.includeCaption, let cap = photo.caption, !cap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            headerMeta["caption"] = .string(cap)
            tusMeta["caption"] = cap
        }
        if prefs.includeDescription, let desc = photo.description, !desc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            headerMeta["description"] = .string(desc)
            tusMeta["description"] = desc
        }
        if prefs.includeLocation {
            if let latitude = photo.latitude {
                headerMeta["latitude"] = .number(latitude)
                tusMeta["latitude"] = String(latitude)
            }
            if let longitude = photo.longitude {
                headerMeta["longitude"] = .number(longitude)
                tusMeta["longitude"] = String(longitude)
            }
            if let altitude = photo.altitude {
                headerMeta["altitude"] = .number(altitude)
                tusMeta["altitude"] = String(altitude)
            }
            if let locationName = photo.location_name, !locationName.isEmpty {
                headerMeta["location_name"] = .string(locationName)
                tusMeta["location_name"] = locationName
            }
            if let city = photo.city, !city.isEmpty {
                headerMeta["city"] = .string(city)
                tusMeta["city"] = city
            }
            if let province = photo.province, !province.isEmpty {
                headerMeta["province"] = .string(province)
                tusMeta["province"] = province
            }
            if let country = photo.country, !country.isEmpty {
                headerMeta["country"] = .string(country)
                tusMeta["country"] = country
            }
        }

        let origEncryptedURL = uploadTempFileURL(name: UUID().uuidString + ".pae3")
        cleanupURLs.append(origEncryptedURL)
        _ = try pae3EncryptFileReturningInfo(
            umk: umk,
            userIdKey: Data(userId.utf8),
            input: plainURL,
            output: origEncryptedURL,
            headerMetadata: headerMeta,
            chunkSize: PAE3_DEFAULT_CHUNK_SIZE
        )

        let filesBaseURL = URL(string: AuthManager.shared.serverURL + "/files/")!
        let tusClient = TUSClient(baseURL: filesBaseURL, headersProvider: {
            AuthManager.shared.authHeader()
        })

        // Upload encrypted original first. If thumb later fails, web can still decrypt via orig fallback.
        try await uploadLockedContainer(
            tusClient: tusClient,
            containerURL: origEncryptedURL,
            filename: photo.asset_id + ".pae3",
            metadata: tusMeta
        )
        print("[LOCKED] uploaded orig asset=\(photo.asset_id)")

        // Best-effort encrypted thumb. Keep lock successful even if thumb generation/upload fails.
        if let thumb = generateImageThumbnail(url: plainURL, maxDim: 512) {
            cleanupURLs.append(thumb.url)
            var thumbHeader = headerMeta
            thumbHeader["kind"] = .string("thumb")
            let thumbEncryptedURL = uploadTempFileURL(name: UUID().uuidString + "_t.pae3")
            cleanupURLs.append(thumbEncryptedURL)
            do {
                _ = try pae3EncryptFileReturningInfo(
                    umk: umk,
                    userIdKey: Data(userId.utf8),
                    input: thumb.url,
                    output: thumbEncryptedURL,
                    headerMetadata: thumbHeader,
                    chunkSize: 256 * 1024
                )
                var thumbMeta = tusMeta
                thumbMeta["kind"] = "thumb"
                thumbMeta["mime_hint"] = "image/jpeg"
                thumbMeta["width"] = String(thumb.width)
                thumbMeta["height"] = String(thumb.height)
                thumbMeta["size_kb"] = String(max(1, Int((thumb.size + 1023) / 1024)))
                try await uploadLockedContainer(
                    tusClient: tusClient,
                    containerURL: thumbEncryptedURL,
                    filename: photo.asset_id + "_t.pae3",
                    metadata: thumbMeta
                )
                print("[LOCKED] uploaded thumb asset=\(photo.asset_id)")
            } catch {
                print("[LOCKED] thumb upload failed asset=\(photo.asset_id) err=\(error.localizedDescription)")
            }
        }
        print("[LOCKED] done asset=\(photo.asset_id)")
    }

    func updateRating(assetId: String, rating: Int?) async throws {
        struct Req: Encodable {
            let rating: Int?
            private enum CodingKeys: String, CodingKey { case rating }
            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                if let rating {
                    try container.encode(rating, forKey: .rating)
                } else {
                    try container.encodeNil(forKey: .rating)
                }
            }
        }
        let path = "/api/photos/\(assetId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? assetId)/rating"
        let url = URL(string: AuthManager.shared.serverURL + path)!
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(Req(rating: rating))
        _ = try await AuthorizedHTTPClient.shared.request(req)
    }

    func updateMetadata(assetId: String, caption: String?, description: String?) async throws {
        struct Req: Encodable { let caption: String?; let description: String? }
        let path = "/api/photos/\(assetId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? assetId)/metadata"
        let url = URL(string: AuthManager.shared.serverURL + path)!
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(Req(caption: caption, description: description))
        _ = try await AuthorizedHTTPClient.shared.request(req)
    }

    func deletePhotos(assetIds: [String]) async throws {
        struct Req: Encodable { let asset_ids: [String] }
        let url = AuthorizedHTTPClient.shared.buildURL(path: "/api/photos/delete")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(Req(asset_ids: assetIds))
        _ = try await AuthorizedHTTPClient.shared.request(req)
    }

    func restorePhotos(assetIds: [String]) async throws {
        struct Req: Encodable { let asset_ids: [String] }
        let url = AuthorizedHTTPClient.shared.buildURL(path: "/api/photos/restore")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(Req(asset_ids: assetIds))
        _ = try await AuthorizedHTTPClient.shared.request(req)
    }

    func emptyTrash() async throws -> Int {
        struct Resp: Decodable { let purged: Int }
        let url = AuthorizedHTTPClient.shared.buildURL(path: "/api/photos/purge-all")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        let (data, http) = try await AuthorizedHTTPClient.shared.request(req)
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "HTTP", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: body])
        }
        let decoded = try JSONDecoder().decode(Resp.self, from: data)
        return decoded.purged
    }

    // MARK: - Faces/People

    struct ServerAssetFace: Decodable {
        let face_id: String
        let bbox: [Int]
        let confidence: Float
        let person_id: String?
        let thumbnail: String?
    }

    struct ServerPerson: Decodable, Hashable, Identifiable {
        let person_id: String
        let display_name: String?
        let birth_date: String?
        let face_count: Int?
        var id: String { person_id }
    }

    func getFacesForAsset(assetId: String) async throws -> [ServerAssetFace] {
        let enc = assetId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? assetId
        let url = AuthorizedHTTPClient.shared.buildURL(path: "/api/photos/\(enc)/faces")
        return try await AuthorizedHTTPClient.shared.getJSON(url)
    }

    func getPersons() async throws -> [ServerPerson] {
        try await AuthorizedHTTPClient.shared.getJSON(path: "/api/faces")
    }

    func getPersonsForAsset(assetId: String) async throws -> [ServerPerson] {
        let enc = assetId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? assetId
        return try await AuthorizedHTTPClient.shared.getJSON(path: "/api/photos/\(enc)/persons")
    }

    /// Update a person's display name and/or birth date via `/api/faces/{personId}`.
    /// The server treats `display_name` / `birth_date` as optional; omitting a field leaves it unchanged.
    func updatePerson(personId: String, displayName: String?, birthDate: String?) async throws {
        struct Req: Encodable {
            let display_name: String?
            let birth_date: String?
        }
        let enc = personId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? personId
        let url = AuthorizedHTTPClient.shared.buildURL(path: "/api/faces/\(enc)")
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(Req(display_name: displayName, birth_date: birthDate))
        _ = try await AuthorizedHTTPClient.shared.request(req)
    }

    func assignFace(faceId: String, personId: String?) async throws {
        struct Req: Encodable { let person_id: String? }
        let enc = faceId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? faceId
        let url = AuthorizedHTTPClient.shared.buildURL(path: "/api/faces/\(enc)/assign")
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(Req(person_id: personId))
        _ = try await AuthorizedHTTPClient.shared.request(req)
    }

    func addPersonToPhoto(assetId: String, personId: String) async throws {
        struct Req: Encodable { let person_id: String }
        let enc = assetId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? assetId
        let url = AuthorizedHTTPClient.shared.buildURL(path: "/api/photos/\(enc)/assign-person")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(Req(person_id: personId))
        _ = try await AuthorizedHTTPClient.shared.request(req)
    }

    /// Merge one or more source persons into a primary person via `/api/faces/merge`.
    /// Mirrors the web client's `photosApi.mergeFaces` behavior.
    func mergeFaces(targetPersonId: String, sourcePersonIds: [String]) async throws {
        struct Req: Encodable {
            let target_person_id: String
            let source_person_ids: [String]
        }
        guard !sourcePersonIds.isEmpty else { return }
        let url = AuthorizedHTTPClient.shared.buildURL(path: "/api/faces/merge")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(Req(target_person_id: targetPersonId, source_person_ids: sourcePersonIds))
        _ = try await AuthorizedHTTPClient.shared.request(req)
    }

    /// Delete one or more persons via `/api/faces/delete`.
    /// This removes their face clusters from the global faces index.
    func deletePersons(personIds: [String]) async throws {
        struct Req: Encodable { let person_ids: [String] }
        guard !personIds.isEmpty else { return }
        let url = AuthorizedHTTPClient.shared.buildURL(path: "/api/faces/delete")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(Req(person_ids: personIds))
        _ = try await AuthorizedHTTPClient.shared.request(req)
    }

    // MARK: - Search

    /// Text search with optional filters (media, locked, date range) to mirror Android behavior and web.
    func textSearch(query: String, media: String? = nil, locked: Bool? = nil, dateFrom: Int64? = nil, dateTo: Int64? = nil, page: Int = 1, limit: Int = 100) async throws -> ServerTextSearchResponse {
        struct Req: Encodable {
            let q: String
            let media: String?
            let locked: Bool?
            let date_from: Int64?
            let date_to: Int64?
            let page: Int
            let limit: Int
        }
        let body = Req(q: query, media: media, locked: locked, date_from: dateFrom, date_to: dateTo, page: page, limit: limit)
        return try await AuthorizedHTTPClient.shared.postJSON(path: "/api/search", body: body)
    }

    // MARK: - Cloud Existence

    /// Returns the subset of `assetIds` that exist on the server and are considered "fully backed up"
    /// (not in Trash; locked items require both orig+thumb).
    func existsFullyBackedUp(assetIds: [String]) async throws -> Set<String> {
        struct Req: Encodable { let asset_ids: [String] }
        struct Resp: Decodable { let present_asset_ids: [String] }
        guard !assetIds.isEmpty else { return [] }
        let resp: Resp = try await AuthorizedHTTPClient.shared.postJSON(
            path: "/api/photos/exists",
            body: Req(asset_ids: assetIds)
        )
        return Set(resp.present_asset_ids)
    }

    /// Returns the subset of `backupIds` that exist on the server and are considered "fully backed up"
    /// (not in Trash; locked items require both orig+thumb). This uses the server's `photos.backup_id`.
    func existsFullyBackedUp(backupIds: [String]) async throws -> Set<String> {
        struct Req: Encodable { let backup_ids: [String] }
        struct Resp: Decodable { let present_backup_ids: [String]? }
        guard !backupIds.isEmpty else { return [] }
        let resp: Resp = try await AuthorizedHTTPClient.shared.postJSON(
            path: "/api/photos/exists",
            body: Req(backup_ids: backupIds)
        )
        return Set(resp.present_backup_ids ?? [])
    }

    func getPhotosByAssetIds(_ assetIds: [String], includeLocked: Bool = false) async throws -> [ServerPhoto] {
        struct Req: Encodable { let asset_ids: [String]; let include_locked: Bool }
        struct Resp: Decodable { let photos: [ServerPhoto] }
        // Server returns raw array for by-ids; match axum route in server
        let url = AuthorizedHTTPClient.shared.buildURL(path: "/api/photos/by-ids")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = Req(asset_ids: assetIds, include_locked: includeLocked)
        req.httpBody = try JSONEncoder().encode(body)
        let (data, http) = try await AuthorizedHTTPClient.shared.request(req)
        guard (200..<300).contains(http.statusCode) else { throw NSError(domain: "Server", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "by-ids failed"]) }
        if let obj = try? JSONDecoder().decode([ServerPhoto].self, from: data) {
            return obj
        }
        if let obj = try? JSONDecoder().decode(Resp.self, from: data) {
            return obj.photos
        }
        return []
    }

    // MARK: - Similar Media

    /// Fetch paged similar photo groups for the current user.
    func getSimilarPhotoGroups(threshold: Int = 8, minGroupSize: Int = 2, limit: Int = 50, cursor: Int = 0) async throws -> ServerSimilarGroupsResponse {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "threshold", value: String(threshold)),
            URLQueryItem(name: "min_group_size", value: String(minGroupSize)),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "cursor", value: String(cursor))
        ]
        let url = AuthorizedHTTPClient.shared.buildURL(path: "/api/similar/groups", queryItems: items)
        return try await AuthorizedHTTPClient.shared.getJSON(url)
    }

    /// Fetch paged similar video groups for the current user.
    func getSimilarVideoGroups(minGroupSize: Int = 2, limit: Int = 50, cursor: Int = 0) async throws -> ServerSimilarGroupsResponse {
        let items: [URLQueryItem] = [
            URLQueryItem(name: "min_group_size", value: String(minGroupSize)),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "cursor", value: String(cursor))
        ]
        let url = AuthorizedHTTPClient.shared.buildURL(path: "/api/video/similar/groups", queryItems: items)
        return try await AuthorizedHTTPClient.shared.getJSON(url)
    }

    // MARK: - Utility

    /// Resolve numeric photo ids from asset ids so album mutations can be sent to numeric endpoints.
    private func resolvePhotoIds(assetIds: [String]) async throws -> [Int] {
        // Fetch by ids to retrieve numeric `id` fields when present
        // Fallback to 0 if ids are not present (server supports album ops by numeric id)
        let photos = try await getPhotosByAssetIds(assetIds)
        let pairs: [(String, Int)] = photos.compactMap { (p) -> (String, Int)? in
            guard let nid = p.id_num else { return nil }
            return (p.asset_id, nid)
        }
        let map = Dictionary(uniqueKeysWithValues: pairs)
        return assetIds.compactMap { map[$0] }
    }

    private static func encodeQuery(_ q: ServerPhotoListQuery) -> [String:String] {
        var dict: [String:String] = [:]
        for item in q.asQueryItems() {
            if let value = item.value { dict[item.name] = value }
        }
        return dict
    }

    private func fetchOriginalBytes(assetId: String) async throws -> (Data, String?) {
        let enc = assetId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? assetId
        let url = AuthorizedHTTPClient.shared.buildURL(path: "/api/images/\(enc)")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        let (data, http) = try await AuthorizedHTTPClient.shared.request(req)
        guard (200..<300).contains(http.statusCode) else {
            throw NSError(
                domain: "ServerLock",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Failed to fetch original (\(http.statusCode))"]
            )
        }
        return (data, http.value(forHTTPHeaderField: "Content-Type"))
    }

    private func uploadLockedContainer(
        tusClient: TUSClient,
        containerURL: URL,
        filename: String,
        metadata: [String: String]
    ) async throws {
        let size = (try? FileManager.default.attributesOfItem(atPath: containerURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else {
            throw NSError(
                domain: "ServerLock",
                code: 1010,
                userInfo: [NSLocalizedDescriptionKey: "Encrypted output is empty"]
            )
        }
        let create = try await tusClient.create(
            fileSize: size,
            filename: filename,
            mimeType: "application/octet-stream",
            metadata: metadata
        )
        _ = try await tusClient.upload(
            fileURL: containerURL,
            uploadURL: create.uploadURL,
            startOffset: 0,
            fileSize: size,
            progress: { _, _ in },
            isCancelled: { false }
        )
    }

    private func fileExtension(fromMime mimeType: String?, filename: String?, fallback: String) -> String {
        if let filename, let ext = filename.split(separator: ".").last, !ext.isEmpty {
            return String(ext).lowercased()
        }
        guard let mimeType else { return fallback }
        switch mimeType.lowercased() {
        case "image/jpeg": return "jpg"
        case "image/heic", "image/heif": return "heic"
        case "image/png": return "png"
        case "video/quicktime": return "mov"
        case "video/mp4": return "mp4"
        default: return fallback
        }
    }

    private func uploadTempFileURL(name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(name)
    }

    private func shouldConvertHeicToJpeg(mimeType: String, filename: String) -> Bool {
        let mime = mimeType.lowercased()
        let fn = filename.lowercased()
        return mime.contains("heic") || mime.contains("heif") || fn.hasSuffix(".heic") || fn.hasSuffix(".heif")
    }

    private func utcYmdString(epochSeconds: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(epochSeconds))
        let comps = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: date)
        let y = comps.year ?? 1970
        let m = String(format: "%02d", comps.month ?? 1)
        let d = String(format: "%02d", comps.day ?? 1)
        return "\(y)-\(m)-\(d)"
    }

    private func imageByRemovingAlphaForJPEG(_ image: CGImage) -> CGImage {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return image
        default:
            break
        }
        let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue).union(.byteOrder32Big)
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            return image
        }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage() ?? image
    }

    private func convertHEICtoJPEG(inputURL: URL, quality: CGFloat) -> (url: URL, width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithURL(inputURL as CFURL, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as NSDictionary?
        let w = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let h = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let maxSide = max(1, max(w, h))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        let jpegReady = imageByRemovingAlphaForJPEG(cgImage)
        let destURL = uploadTempFileURL(name: UUID().uuidString + ".jpg")
        guard let dest = CGImageDestinationCreateWithURL(destURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, jpegReady, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (destURL, jpegReady.width, jpegReady.height)
    }

    private func generateImageThumbnail(url: URL, maxDim: Int) -> (url: URL, width: Int, height: Int, size: Int64)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as NSDictionary?
        let w = max(1, (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 1)
        let h = max(1, (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 1)
        let scale = w > h ? Double(maxDim) / Double(w) : Double(maxDim) / Double(h)
        let outW = max(1, Int(Double(w) * scale))
        let outH = max(1, Int(Double(h) * scale))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(outW, outH),
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        let jpegReady = imageByRemovingAlphaForJPEG(thumb)
        let destURL = uploadTempFileURL(name: UUID().uuidString + "_thumb.jpg")
        guard let dest = CGImageDestinationCreateWithURL(destURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, jpegReady, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        let size = (try? FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        return (destURL, jpegReady.width, jpegReady.height, size)
    }
}
