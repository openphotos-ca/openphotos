//
//  ShareViewerViewModel.swift
//  OpenPhotos
//
//  View model for viewing a single share with its photos, faces, comments, and likes.
//

import Foundation
import SwiftUI

/// View model for the share viewer
@MainActor
class ShareViewerViewModel: ObservableObject {
    let share: Share

    @Published var assetIds: [String] = []
    @Published var hasMore = false
    @Published var isLoadingAssets = false
    @Published var assetsError: String?

    @Published var faces: [ShareFace] = []
    @Published var isLoadingFaces = false
    @Published var selectedFaceId: String?

    @Published var isSelectionMode = false
    @Published var selectedAssetIds: Set<String> = []

    @Published var likeCounts: [String: ShareLikeCount] = [:]
    @Published var isLoadingLikes = false

    @Published var latestComments: [String: ShareComment?] = [:]
    @Published var isLoadingComments = false

    @Published var assetMetadata: [String: ShareAssetMetadata] = [:]
    @Published var isLoadingMetadata = false

    // Pagination
    private var currentPage = 1
    private let pageSize = 60

    private let shareService = ShareService.shared
    private let e2eeManager = ShareE2EEManager.shared

    init(share: Share) {
        self.share = share
    }

    // MARK: - Load Data

    /// Load initial data
    func loadInitialData() async {
        await loadAssets(page: 1)

        if share.includeFaces {
            await loadFaces()
        }

        // Load like counts, latest comments, and metadata after assets are loaded
        await loadLikeCounts()
        await loadLatestComments()
        await loadAssetMetadata()
    }

    /// Load assets for current page
    func loadAssets(page: Int) async {
        isLoadingAssets = true
        assetsError = nil

        do {
            let response = try await shareService.listShareAssets(
                shareId: share.id,
                page: page,
                limit: pageSize
            )

            if page == 1 {
                assetIds = response.assetIds
            } else {
                assetIds.append(contentsOf: response.assetIds)
            }

            hasMore = response.hasMore
            currentPage = page
            isLoadingAssets = false
        } catch {
            assetsError = error.localizedDescription
            isLoadingAssets = false
        }
    }

    /// Load next page if needed
    func loadNextPageIfNeeded() async {
        guard hasMore && !isLoadingAssets else { return }
        await loadAssets(page: currentPage + 1)
        // Load like counts, latest comments, and metadata for new assets
        await loadLikeCounts()
        await loadLatestComments()
        await loadAssetMetadata()
    }

    /// Reload assets
    func reload() async {
        await loadAssets(page: 1)
        await loadLikeCounts()
        await loadLatestComments()
        await loadAssetMetadata()
    }

    // MARK: - Faces

    /// Load faces for the share
    func loadFaces() async {
        isLoadingFaces = true

        do {
            faces = try await shareService.listShareFaces(shareId: share.id)
            isLoadingFaces = false
        } catch {
            print("Failed to load faces: \(error)")
            isLoadingFaces = false
        }
    }

    /// Filter by face
    func filterByFace(_ personId: String) async {
        selectedFaceId = personId
        isLoadingAssets = true

        do {
            let response = try await shareService.listShareFaceAssets(
                shareId: share.id,
                personId: personId
            )

            assetIds = response.assetIds
            hasMore = false
            isLoadingAssets = false
        } catch {
            assetsError = error.localizedDescription
            isLoadingAssets = false
        }
    }

    /// Clear face filter
    func clearFaceFilter() async {
        selectedFaceId = nil
        await loadAssets(page: 1)
    }

    // MARK: - Selection

    /// Toggle selection mode
    func toggleSelectionMode() {
        isSelectionMode.toggle()
        if !isSelectionMode {
            selectedAssetIds.removeAll()
        }
    }

    /// Toggle asset selection
    func toggleAssetSelection(_ assetId: String) {
        if selectedAssetIds.contains(assetId) {
            selectedAssetIds.remove(assetId)
        } else {
            selectedAssetIds.insert(assetId)
        }
    }

    /// Select all visible assets
    func selectAll() {
        selectedAssetIds = Set(assetIds)
    }

    /// Deselect all
    func deselectAll() {
        selectedAssetIds.removeAll()
    }

    // MARK: - Import

    /// Import selected assets
    func importSelectedAssets() async throws {
        let result = try await shareService.importAssets(
            shareId: share.id,
            assetIds: Array(selectedAssetIds)
        )

        // Clear selection after import
        selectedAssetIds.removeAll()
        isSelectionMode = false

        print("Imported \(result.imported) assets, skipped \(result.skipped), failed \(result.failed)")
    }

    // MARK: - Likes

    /// Load like counts for visible assets
    func loadLikeCounts() async {
        guard hasPermission(SharePermissions.like.rawValue) else { return }
        guard !assetIds.isEmpty else { return }

        isLoadingLikes = true

        do {
            let counts = try await shareService.getLikeCounts(
                shareId: share.id,
                assetIds: assetIds
            )

            // Update like counts dictionary
            for count in counts {
                likeCounts[count.assetId] = count
            }

            isLoadingLikes = false
        } catch {
            print("Failed to load like counts: \(error)")
            isLoadingLikes = false
        }
    }

    /// Toggle like for an asset
    func toggleLike(assetId: String) async {
        guard hasPermission(SharePermissions.like.rawValue) else { return }

        // Get current state
        let currentCount = likeCounts[assetId]
        let currentLiked = currentCount?.likedByMe ?? false

        // Optimistic update
        let optimisticCount = ShareLikeCount(
            assetId: assetId,
            count: (currentCount?.count ?? 0) + (currentLiked ? -1 : 1),
            likedByMe: !currentLiked
        )
        likeCounts[assetId] = optimisticCount

        do {
            // Sync with server
            let updated = try await shareService.toggleLike(
                shareId: share.id,
                assetId: assetId,
                like: !currentLiked
            )

            // Update with server response
            likeCounts[assetId] = updated
        } catch {
            print("Failed to toggle like: \(error)")
            // Revert on error
            if let currentCount = currentCount {
                likeCounts[assetId] = currentCount
            } else {
                likeCounts.removeValue(forKey: assetId)
            }
        }
    }

    // MARK: - Comments

    /// Load latest comments for visible assets
    func loadLatestComments() async {
        guard hasPermission(SharePermissions.comment.rawValue) else { return }
        guard !assetIds.isEmpty else { return }

        isLoadingComments = true

        do {
            let comments = try await shareService.getLatestComments(
                shareId: share.id,
                assetIds: assetIds
            )

            // Update latest comments dictionary
            latestComments = comments

            isLoadingComments = false
        } catch {
            print("Failed to load latest comments: \(error)")
            isLoadingComments = false
        }
    }

    // MARK: - Asset Metadata

    /// Load metadata for visible assets (to detect videos)
    func loadAssetMetadata() async {
        guard !assetIds.isEmpty else { return }

        isLoadingMetadata = true

        // Load metadata for assets we don't have yet
        let missingAssetIds = assetIds.filter { assetMetadata[$0] == nil }

        await withTaskGroup(of: (String, ShareAssetMetadata?).self) { group in
            for assetId in missingAssetIds {
                group.addTask {
                    do {
                        let metadata = try await self.shareService.getShareAssetMetadata(
                            shareId: self.share.id,
                            assetId: assetId
                        )
                        return (assetId, metadata)
                    } catch {
                        print("Failed to load metadata for asset \(assetId): \(error)")
                        return (assetId, nil)
                    }
                }
            }

            for await (assetId, metadata) in group {
                if let metadata = metadata {
                    assetMetadata[assetId] = metadata
                }
            }
        }

        isLoadingMetadata = false
    }

    // MARK: - Permissions

    /// Check if has permission
    func hasPermission(_ permission: Int) -> Bool {
        return (share.defaultPermissions & permission) != 0
    }
}
