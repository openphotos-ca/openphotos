import Foundation

// MARK: - Server DTOs

/// Photo object returned by /api/photos
struct ServerPhoto: Identifiable, Decodable, Hashable {
    // Server does not require numeric id for most operations; use asset_id as identity
    var id: String { asset_id }

    /// Optional numeric id (when present in listing responses)
    let id_num: Int?

    let asset_id: String
    let filename: String?
    let mime_type: String?
    let has_gain_map: Bool?
    let hdr_kind: String?
    let created_at: Int64
    let modified_at: Int64?
    let size: Int64?
    let width: Int?
    let height: Int?
    let favorites: Int?
    let locked: Bool?
    let delete_time: Int64?
    let is_video: Bool
    let is_live_photo: Bool?
    let duration_ms: Int64?
    let is_screenshot: Int?
    let caption: String?
    let description: String?
    let rating: Int?
    // Optional camera + location fields for Info panel
    let camera_make: String?
    let camera_model: String?
    let iso: Int?
    let aperture: Float?
    let shutter_speed: String?
    let focal_length: Float?
    let latitude: Double?
    let longitude: Double?
    let altitude: Double?
    let location_name: String?
    let city: String?
    let province: String?
    let country: String?
    enum CodingKeys: String, CodingKey {
        case id_num = "id"
        case asset_id
        case filename
        case mime_type
        case has_gain_map
        case hdr_kind
        case created_at
        case modified_at
        case size
        case width
        case height
        case favorites
        case locked
        case delete_time
        case is_video
        case is_live_photo
        case duration_ms
        case is_screenshot
        case caption
        case description
        case rating
        case camera_make
        case camera_model
        case iso
        case aperture
        case shutter_speed
        case focal_length
        case latitude
        case longitude
        case altitude
        case location_name
        case city
        case province
        case country
    }
}

/// Response envelope for /api/photos
struct ServerPhotoListResponse: Decodable {
    let photos: [ServerPhoto]
    let total: Int
    let page: Int
    let limit: Int
    let has_more: Bool
}

/// Album object returned by /api/albums
struct ServerAlbum: Identifiable, Decodable, Hashable {
    let id: Int
    let name: String
    let description: String?
    let parent_id: Int?
    let position: Int?
    let cover_photo_id: Int?
    let cover_asset_id: String?
    let photo_count: Int
    let created_at: Int64
    let updated_at: Int64
    let depth: Int?
    let is_live: Bool
}

/// Media counts returned by /api/media/counts
struct ServerMediaCounts: Decodable {
    let all: Int
    let photos: Int
    let videos: Int
    let locked: Int
    let locked_photos: Int?
    let locked_videos: Int?
    let trash: Int?
}

/// Year bucket returned by /api/buckets/years
struct ServerYearBucket: Decodable, Hashable {
    let year: Int
    let count: Int64
    let first_ts: Int64
    let last_ts: Int64
}

/// Search response item
struct ServerTextSearchResponse: Decodable {
    struct Item: Decodable { let asset_id: String; let score: Double }
    let items: [Item]
    let total: Int
    let page: Int
    let has_more: Bool
}

/// Filter metadata used to build the Filters UI (faces, locations, cameras, date range)
struct ServerFilterMetadata: Decodable {
    struct DateRange: Decodable { let min: Int64; let max: Int64 }
    struct FaceMeta: Decodable {
        let person_id: String
        let name: String?
        let photo_count: Int
    }
    let cities: [String]
    let countries: [String]
    let date_range: DateRange?
    let faces: [FaceMeta]
    let cameras: [String]
}

// MARK: - Similar Media

/// Group of visually similar assets returned by /api/similar/groups and /api/video/similar/groups.
struct ServerSimilarGroup: Decodable {
    let representative: String
    let count: Int
    let members: [String]
}

/// Lightweight metadata for assets inside similar groups (used for sort/labels).
struct ServerSimilarAssetMeta: Decodable {
    let mime_type: String?
    let size: Int64?
    let created_at: Int64?
}

/// Paged response for similar groups endpoints.
struct ServerSimilarGroupsResponse: Decodable {
    let total_groups: Int
    let groups: [ServerSimilarGroup]
    let next_cursor: Int?
    let metadata: [String: ServerSimilarAssetMeta]?
}

// MARK: - Query Types

/// Query builder for /api/photos and related endpoints. Matches server PhotoListQuery keys.
struct ServerPhotoListQuery: Encodable {
    var q: String?
    var page: Int?
    var limit: Int?
    var sort_by: String?
    var sort_order: String?
    var sort_random_seed: Int?
    var filter_city: String?
    var filter_country: String?
    var filter_date_from: Int64?
    var filter_date_to: Int64?
    var filter_screenshot: Bool?
    var filter_live_photo: Bool?
    var filter_favorite: Bool?
    var filter_is_video: Bool?
    var filter_faces: String?
    var filter_faces_mode: String?
    var filter_rating_min: Int?
    var album_id: Int?
    var album_ids: [Int] = [] // AND semantics
    var album_subtree: Bool?
    var include_locked: Bool?
    var filter_locked_only: Bool?
    var include_trashed: Bool?
    var filter_trashed_only: Bool?

    // Custom encoding to only include non-nil/non-empty values
    enum CodingKeys: String, CodingKey {
        case q, page, limit, sort_by, sort_order, sort_random_seed
        case filter_city, filter_country, filter_date_from, filter_date_to
        case filter_screenshot, filter_live_photo, filter_favorite, filter_is_video
        case filter_faces, filter_faces_mode, filter_rating_min
        case album_id, album_ids, album_subtree
        case include_locked, filter_locked_only
        case include_trashed, filter_trashed_only
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(q, forKey: .q)
        try container.encodeIfPresent(page, forKey: .page)
        try container.encodeIfPresent(limit, forKey: .limit)
        try container.encodeIfPresent(sort_by, forKey: .sort_by)
        try container.encodeIfPresent(sort_order, forKey: .sort_order)
        try container.encodeIfPresent(sort_random_seed, forKey: .sort_random_seed)
        try container.encodeIfPresent(filter_city, forKey: .filter_city)
        try container.encodeIfPresent(filter_country, forKey: .filter_country)
        try container.encodeIfPresent(filter_date_from, forKey: .filter_date_from)
        try container.encodeIfPresent(filter_date_to, forKey: .filter_date_to)
        try container.encodeIfPresent(filter_screenshot, forKey: .filter_screenshot)
        try container.encodeIfPresent(filter_live_photo, forKey: .filter_live_photo)
        try container.encodeIfPresent(filter_favorite, forKey: .filter_favorite)
        try container.encodeIfPresent(filter_is_video, forKey: .filter_is_video)
        try container.encodeIfPresent(filter_faces, forKey: .filter_faces)
        try container.encodeIfPresent(filter_faces_mode, forKey: .filter_faces_mode)
        try container.encodeIfPresent(filter_rating_min, forKey: .filter_rating_min)
        try container.encodeIfPresent(album_id, forKey: .album_id)
        if !album_ids.isEmpty {
            try container.encode(album_ids, forKey: .album_ids)
        }
        try container.encodeIfPresent(album_subtree, forKey: .album_subtree)
        try container.encodeIfPresent(include_locked, forKey: .include_locked)
        try container.encodeIfPresent(filter_locked_only, forKey: .filter_locked_only)
        try container.encodeIfPresent(include_trashed, forKey: .include_trashed)
        try container.encodeIfPresent(filter_trashed_only, forKey: .filter_trashed_only)
    }

    func asQueryItems() -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        func add(_ name: String, _ value: CustomStringConvertible?) {
            if let v = value { items.append(URLQueryItem(name: name, value: String(describing: v))) }
        }
        add("q", q)
        add("page", page)
        add("limit", limit)
        add("sort_by", sort_by)
        add("sort_order", sort_order)
        add("sort_random_seed", sort_random_seed)
        add("filter_city", filter_city)
        add("filter_country", filter_country)
        add("filter_date_from", filter_date_from)
        add("filter_date_to", filter_date_to)
        add("filter_screenshot", filter_screenshot)
        add("filter_live_photo", filter_live_photo)
        add("filter_favorite", filter_favorite)
        add("filter_is_video", filter_is_video)
        add("filter_faces", filter_faces)
        add("filter_faces_mode", filter_faces_mode)
        add("filter_rating_min", filter_rating_min)
        add("album_id", album_id)
        if !album_ids.isEmpty {
            add("album_ids", album_ids.map(String.init).joined(separator: ","))
        }
        add("album_subtree", album_subtree)
        add("include_locked", include_locked)
        add("filter_locked_only", filter_locked_only)
        add("include_trashed", include_trashed)
        add("filter_trashed_only", filter_trashed_only)
        return items
    }
}
