//
//  ShareService.swift
//  OpenPhotos
//
//  Service layer for Enterprise Edition sharing API endpoints.
//  Handles shares, public links, comments, likes, faces, and import operations.
//

import Foundation

/// Service for managing shares and public links
final class ShareService {
    static let shared = ShareService()
    private let client = AuthorizedHTTPClient.shared

    private init() {}

    // MARK: - Share Management

    /// List shares created by current user (outgoing)
    func listOutgoingShares() async throws -> [Share] {
        let url = client.buildURL(path: "/api/ee/shares/outgoing")
        return try await client.get(url: url)
    }

    /// List shares received by current user (incoming)
    func listReceivedShares() async throws -> [Share] {
        let url = client.buildURL(path: "/api/ee/shares/received")
        return try await client.get(url: url)
    }

    /// Get detailed information about a specific share
    func getShare(id: String) async throws -> Share {
        let url = client.buildURL(path: "/api/ee/shares/\(id)")
        return try await client.get(url: url)
    }

    /// Create a new share
    func createShare(_ request: CreateShareRequest) async throws -> Share {
        let url = client.buildURL(path: "/api/ee/shares")
        return try await client.post(url: url, body: request)
    }

    /// Update an existing share
    func updateShare(id: String, _ request: UpdateShareRequest) async throws -> Share {
        let url = client.buildURL(path: "/api/ee/shares/\(id)")
        return try await client.patch(url: url, body: request)
    }

    /// Delete/revoke a share
    func deleteShare(id: String) async throws {
        let url = client.buildURL(path: "/api/ee/shares/\(id)")
        try await client.delete(url: url)
    }

    // MARK: - Share Targets

    /// List available share targets (users and groups) for recipient selection
    /// - Parameter query: Optional search query to filter targets
    /// - Returns: Array of ShareTarget objects (users and groups)
    func listShareTargets(query: String? = nil) async throws -> [ShareTarget] {
        var queryItems: [URLQueryItem] = []
        if let query = query, !query.isEmpty {
            queryItems.append(URLQueryItem(name: "q", value: query))
        }

        let url = client.buildURL(path: "/api/ee/share-targets", queryItems: queryItems)
        return try await client.get(url: url)
    }

    // MARK: - Recipients

    /// Add recipients to a share
    func addRecipients(shareId: String, recipients: [CreateShareRequest.RecipientInput]) async throws -> Share {
        let url = client.buildURL(path: "/api/ee/shares/\(shareId)/recipients")
        let body = AddRecipientsRequest(recipients: recipients)
        return try await client.post(url: url, body: body)
    }

    /// Remove a recipient from a share
    func removeRecipient(shareId: String, recipientId: String) async throws {
        let url = client.buildURL(path: "/api/ee/shares/\(shareId)/recipients/\(recipientId)")
        try await client.delete(url: url)
    }

    // MARK: - Share Assets

    /// List assets in a share with pagination
    func listShareAssets(shareId: String, page: Int = 1, limit: Int = 60, sort: String = "newest") async throws -> ShareAssetsResponse {
        let url = client.buildURL(path: "/api/ee/shares/\(shareId)/assets", queryItems: [
            URLQueryItem(name: "page", value: "\(page)"),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "sort", value: sort)
        ])
        return try await client.get(url: url)
    }

    /// Get thumbnail for an asset in a share
    func getShareAssetThumbnail(shareId: String, assetId: String) async throws -> Data {
        let url = client.buildURL(path: "/api/ee/shares/\(shareId)/assets/\(assetId)/thumbnail")
        return try await client.getData(url: url)
    }

    /// Get full image/video for an asset in a share
    func getShareAssetImage(shareId: String, assetId: String) async throws -> Data {
        let url = client.buildURL(path: "/api/ee/shares/\(shareId)/assets/\(assetId)/image")
        return try await client.getData(url: url)
    }

    /// Get metadata for a specific asset in a share
    func getShareAssetMetadata(shareId: String, assetId: String) async throws -> ShareAssetMetadata {
        let url = client.buildURL(path: "/api/ee/shares/\(shareId)/assets/\(assetId)")
        return try await client.get(url: url)
    }

    // MARK: - Faces

    /// List top faces in a share
    func listShareFaces(shareId: String, top: Int = 20) async throws -> [ShareFace] {
        let url = client.buildURL(path: "/api/ee/shares/\(shareId)/faces", queryItems: [
            URLQueryItem(name: "top", value: "\(top)")
        ])
        return try await client.get(url: url)
    }

    /// List assets for a specific person in a share
    func listShareFaceAssets(shareId: String, personId: String) async throws -> ShareFaceAssetsResponse {
        let url = client.buildURL(path: "/api/ee/shares/\(shareId)/faces/\(personId)/assets")
        return try await client.get(url: url)
    }

    /// Get thumbnail for a person in a share
    func getShareFaceThumbnail(shareId: String, personId: String) async throws -> Data {
        let url = client.buildURL(path: "/api/ee/shares/\(shareId)/faces/\(personId)/thumbnail")
        return try await client.getData(url: url)
    }

    // MARK: - Comments

    /// List comments for an asset in a share
    func listComments(shareId: String, assetId: String, limit: Int = 50, before: Int64? = nil) async throws -> [ShareComment] {
        var queryItems = [
            URLQueryItem(name: "asset_id", value: assetId),
            URLQueryItem(name: "limit", value: "\(limit)")
        ]
        if let before = before {
            queryItems.append(URLQueryItem(name: "before", value: "\(before)"))
        }

        let url = client.buildURL(path: "/api/ee/shares/\(shareId)/comments", queryItems: queryItems)
        return try await client.get(url: url)
    }

    /// Create a comment on an asset in a share
    func createComment(shareId: String, assetId: String, body: String) async throws -> ShareComment {
        let url = client.buildURL(path: "/api/ee/shares/\(shareId)/comments")
        let request = CreateCommentRequest(assetId: assetId, body: body)
        return try await client.post(url: url, body: request)
    }

    /// Delete a comment
    func deleteComment(shareId: String, commentId: String) async throws {
        let url = client.buildURL(path: "/api/ee/shares/\(shareId)/comments/\(commentId)")
        try await client.delete(url: url)
    }

    /// Get latest comment for multiple assets (batch)
    func getLatestComments(shareId: String, assetIds: [String]) async throws -> [String: ShareComment?] {
        let url = client.buildURL(path: "/api/ee/shares/\(shareId)/comments/latest-by-assets")

        struct Response: Codable {
            let assetId: String
            let latest: ShareComment?

            enum CodingKeys: String, CodingKey {
                case assetId = "asset_id"
                case latest
            }
        }

        let responses: [Response] = try await client.post(url: url, body: ["asset_ids": assetIds])

        var result: [String: ShareComment?] = [:]
        for response in responses {
            result[response.assetId] = response.latest
        }
        return result
    }

    // MARK: - Likes

    /// Toggle like on an asset in a share
    func toggleLike(shareId: String, assetId: String, like: Bool) async throws -> ShareLikeCount {
        let url = client.buildURL(path: "/api/ee/shares/\(shareId)/likes/toggle")
        let request = ToggleLikeRequest(assetId: assetId, like: like)
        return try await client.post(url: url, body: request)
    }

    /// Get like counts for multiple assets (batch)
    func getLikeCounts(shareId: String, assetIds: [String]) async throws -> [ShareLikeCount] {
        let url = client.buildURL(path: "/api/ee/shares/\(shareId)/likes/counts-by-assets")
        return try await client.post(url: url, body: ["asset_ids": assetIds])
    }

    // MARK: - Import

    /// Import assets from a share to user's library
    func importAssets(shareId: String, assetIds: [String]) async throws -> ImportResult {
        let url = client.buildURL(path: "/api/ee/shares/\(shareId)/import")
        let request = ImportAssetsRequest(assetIds: assetIds)

        struct Response: Codable {
            let imported: Int
            let skipped: Int?
            let failed: Int?
            let errors: [String]?
        }

        let response: Response = try await client.post(url: url, body: request)
        return ImportResult(
            imported: response.imported,
            skipped: response.skipped ?? 0,
            failed: response.failed ?? 0,
            errors: response.errors ?? []
        )
    }

    /// Result of an import operation
    struct ImportResult {
        let imported: Int
        let skipped: Int
        let failed: Int
        let errors: [String]
    }

    // MARK: - Public Links

    /// List all public links created by current user
    func listPublicLinks() async throws -> [PublicLink] {
        let url = client.buildURL(path: "/api/ee/public-links")
        return try await client.get(url: url)
    }

    /// Create a new public link
    func createPublicLink(_ request: CreatePublicLinkRequest) async throws -> PublicLink {
        let url = client.buildURL(path: "/api/ee/public-links")
        return try await client.post(url: url, body: request)
    }

    /// Update a public link
    func updatePublicLink(id: String, _ request: UpdatePublicLinkRequest) async throws -> PublicLink {
        let url = client.buildURL(path: "/api/ee/public-links/\(id)")
        return try await client.patch(url: url, body: request)
    }

    /// Rotate the access key for a public link (invalidates old URL)
    func rotatePublicLinkKey(id: String) async throws -> PublicLink {
        let url = client.buildURL(path: "/api/ee/public-links/\(id)/rotate-key")
        return try await client.post(url: url, body: [:] as [String: String])
    }

    /// Delete/revoke a public link
    func deletePublicLink(id: String) async throws {
        let url = client.buildURL(path: "/api/ee/public-links/\(id)")
        try await client.delete(url: url)
    }
}

// MARK: - Flexible Date Decoder

/// Date decoding strategy that handles multiple formats:
/// - ISO8601: "2025-12-04T23:50:41Z"
/// - Space-separated: "2025-12-04 23:50:41"
private enum FlexibleDateDecoder {
    static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let iso8601FormatterNoFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static let spaceSeparatedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    static func decode(_ decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let dateString = try container.decode(String.self)

        // Try ISO8601 with fractional seconds
        if let date = iso8601Formatter.date(from: dateString) {
            return date
        }

        // Try ISO8601 without fractional seconds
        if let date = iso8601FormatterNoFraction.date(from: dateString) {
            return date
        }

        // Try space-separated format
        if let date = spaceSeparatedFormatter.date(from: dateString) {
            return date
        }

        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Cannot decode date string '\(dateString)'"
        )
    }
}

// MARK: - AuthorizedHTTPClient Extensions

extension AuthorizedHTTPClient {
    /// Perform GET request with decodable response
    func get<T: Decodable>(url: URL) async throws -> T {
        let req = URLRequest(url: url)
        let (data, httpResponse) = try await request(req)

        // Log the raw JSON response for debugging
        if let jsonString = String(data: data, encoding: .utf8) {
            print("📥 GET \(url.path)")
            print("📄 Response JSON: \(jsonString)")
        }

        print("📊 Status Code: \(httpResponse.statusCode)")
        if httpResponse.statusCode >= 400 {
            print("❌ HTTP Error: \(httpResponse.statusCode)")
        }

        // Configure decoder with flexible date strategy
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(FlexibleDateDecoder.decode)

        do {
            return try decoder.decode(T.self, from: data)
        } catch let DecodingError.keyNotFound(key, context) {
            print("❌ Decoding Error: Key '\(key.stringValue)' not found")
            print("   Context: \(context.debugDescription)")
            print("   CodingPath: \(context.codingPath.map { $0.stringValue }.joined(separator: " -> "))")
            throw DecodingError.keyNotFound(key, context)
        } catch let DecodingError.typeMismatch(type, context) {
            print("❌ Decoding Error: Type mismatch for type \(type)")
            print("   Context: \(context.debugDescription)")
            print("   CodingPath: \(context.codingPath.map { $0.stringValue }.joined(separator: " -> "))")
            throw DecodingError.typeMismatch(type, context)
        } catch let DecodingError.valueNotFound(type, context) {
            print("❌ Decoding Error: Value not found for type \(type)")
            print("   Context: \(context.debugDescription)")
            print("   CodingPath: \(context.codingPath.map { $0.stringValue }.joined(separator: " -> "))")
            throw DecodingError.valueNotFound(type, context)
        } catch let DecodingError.dataCorrupted(context) {
            print("❌ Decoding Error: Data corrupted")
            print("   Context: \(context.debugDescription)")
            print("   CodingPath: \(context.codingPath.map { $0.stringValue }.joined(separator: " -> "))")
            throw DecodingError.dataCorrupted(context)
        } catch {
            print("❌ Unknown decoding error: \(error)")
            throw error
        }
    }

    /// Perform POST request with encodable body and decodable response
    func post<T: Decodable, B: Encodable>(url: URL, body: B) async throws -> T {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)

        let (data, httpResponse) = try await request(req)

        // Log the response
        if let jsonString = String(data: data, encoding: .utf8) {
            print("📥 POST \(url.path)")
            print("📄 Response JSON: \(jsonString)")
        }

        print("📊 Status Code: \(httpResponse.statusCode)")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(FlexibleDateDecoder.decode)
        return try decoder.decode(T.self, from: data)
    }

    /// Perform PATCH request with encodable body and decodable response
    func patch<T: Decodable, B: Encodable>(url: URL, body: B) async throws -> T {
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoder = JSONEncoder()
        req.httpBody = try encoder.encode(body)

        // Log the request for debugging
        if let jsonData = req.httpBody,
           let jsonString = String(data: jsonData, encoding: .utf8) {
            print("📤 PATCH \(url.path)")
            print("📄 Request JSON: \(jsonString)")
        }

        let (data, httpResponse) = try await request(req)

        // Log the response
        if let jsonString = String(data: data, encoding: .utf8) {
            print("📥 PATCH Response")
            print("📄 Response JSON: \(jsonString)")
        }
        print("📊 Status Code: \(httpResponse.statusCode)")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(FlexibleDateDecoder.decode)
        return try decoder.decode(T.self, from: data)
    }

    /// Perform DELETE request
    func delete(url: URL) async throws {
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        _ = try await request(req)
    }

    /// Get raw data from URL
    func getData(url: URL) async throws -> Data {
        let req = URLRequest(url: url)
        let (data, _) = try await request(req)
        return data
    }
}
