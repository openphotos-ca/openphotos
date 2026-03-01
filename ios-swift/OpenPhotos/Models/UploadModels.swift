import Foundation
import Photos

enum UploadStatus: String {
    case queued
    case exporting
    case uploading
    case backgroundQueued
    case completed
    case failed
    case canceled
}

struct UploadItem: Identifiable, Hashable {
    let id: UUID
    let assetLocalIdentifier: String
    let filename: String
    let mimeType: String
    let isVideo: Bool
    let isLiveComponent: Bool // true for the paired .mov when part of a Live Photo
    let isFavorite: Bool

    // Sync metadata
    var contentId: String
    var creationTs: Int64
    let enqueuedAt: Int64
    var albumPathsJSON: String?
    var caption: String?
    var longDescription: String?

    var totalBytes: Int64
    var sentBytes: Int64
    var status: UploadStatus
    var tusURL: URL?
    var tempFileURL: URL

    // Unlocked/plain uploads: precomputed asset_id (Base58 HMAC) used for preflight skip and upload metadata.
    var assetId: String?

    // Locked upload fields (optional). When set, uploader must send locked metadata and encrypted blob.
    var isLocked: Bool = false
    var lockedKind: String? // "orig" or "thumb"
    var assetIdB58: String?
    var outerHeaderB64Url: String?
    var lockedMetadata: [String: String]? // coarse fields for TUS metadata

    init(assetLocalIdentifier: String,
         filename: String,
         mimeType: String,
         isVideo: Bool,
         isLiveComponent: Bool,
         isFavorite: Bool,
         contentId: String,
         creationTs: Int64,
         enqueuedAt: Int64 = Int64(Date().timeIntervalSince1970),
         albumPathsJSON: String? = nil,
         caption: String? = nil,
         longDescription: String? = nil,
         totalBytes: Int64,
         sentBytes: Int64 = 0,
         status: UploadStatus = .queued,
         tusURL: URL? = nil,
         tempFileURL: URL,
         assetId: String? = nil,
         isLocked: Bool = false,
         lockedKind: String? = nil,
         assetIdB58: String? = nil,
         outerHeaderB64Url: String? = nil,
         lockedMetadata: [String: String]? = nil) {
        self.id = UUID()
        self.assetLocalIdentifier = assetLocalIdentifier
        self.filename = filename
        self.mimeType = mimeType
        self.isVideo = isVideo
        self.isLiveComponent = isLiveComponent
        self.isFavorite = isFavorite
        self.contentId = contentId
        self.creationTs = creationTs
        self.enqueuedAt = enqueuedAt
        self.albumPathsJSON = albumPathsJSON
        self.caption = caption
        self.longDescription = longDescription
        self.totalBytes = totalBytes
        self.sentBytes = sentBytes
        self.status = status
        self.tusURL = tusURL
        self.tempFileURL = tempFileURL
        self.assetId = assetId
        self.isLocked = isLocked
        self.lockedKind = lockedKind
        self.assetIdB58 = assetIdB58
        self.outerHeaderB64Url = outerHeaderB64Url
        self.lockedMetadata = lockedMetadata
    }
}
