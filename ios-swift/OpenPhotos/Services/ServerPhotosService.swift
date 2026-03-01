import Foundation
import UIKit

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

    func updateRating(assetId: String, rating: Int?) async throws {
        struct Req: Encodable { let rating: Int? }
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
}
