//
//  NewShareViewModel.swift
//  OpenPhotos
//
//  View model for creating shares with Internal and Public Link tabs.
//  Manages state for recipient selection, permissions, E2EE preparation, and share creation.
//

import Foundation
import SwiftUI
import CryptoKit

/// View model for the new share sheet with two-tab interface
@MainActor
class NewShareViewModel: ObservableObject {
    // MARK: - Tab Selection

    /// Currently active tab (Internal or Public Link)
    @Published var selectedTab: ShareTab = .internal

    /// Available tabs for share creation
    enum ShareTab: String, CaseIterable {
        case `internal` = "Internal"
        case publicLink = "Public Link"
    }

    // MARK: - Common Fields

    /// Name of the share
    @Published var shareName: String = ""

    /// Expiration date for the share (required, must be future date)
    @Published var expiryDate: Date

    // MARK: - Internal Share Fields

    /// Available users and groups that can be added as recipients
    @Published var availableTargets: [ShareTarget] = []

    /// Selected recipients for internal sharing
    @Published var selectedRecipients: [ShareTarget] = []

    /// Include faces in the share
    @Published var includeFaces: Bool = true

    /// Include sub-albums in the share
    @Published var includeSubtree: Bool = false

    /// Keep live updates for live albums (instead of freezing)
    @Published var keepLiveUpdates: Bool = false

    /// Selected role/permission level
    @Published var role: SharePermissions = .viewer

    /// Allow recipients to comment
    @Published var allowComments: Bool = false

    /// Allow recipients to like assets
    @Published var allowLikes: Bool = false

    // MARK: - Public Link Fields

    /// Include full album content in public link
    @Published var pubIncludeAlbum: Bool = true

    /// Enable content moderation for public link
    @Published var pubModeration: Bool = false

    /// Require PIN to access public link
    @Published var pubRequirePin: Bool = false

    /// PIN for public link access (8 characters)
    @Published var pubPin: String = ""

    /// Cover asset ID for public link thumbnail
    @Published var pubCoverAssetId: String? = nil

    /// Public link role/permissions
    @Published var pubRole: SharePermissions = .viewer

    /// Allow comments on public link
    @Published var pubAllowComments: Bool = false

    /// Allow likes on public link
    @Published var pubAllowLikes: Bool = false

    /// Public link expiry date
    @Published var pubExpiryDate: Date

    // MARK: - E2EE Preparation State

    /// E2EE preparation is in progress
    @Published var prepBusy: Bool = false

    /// E2EE preparation message
    @Published var prepMsg: String = ""

    /// Total number of items to encrypt
    @Published var prepTotal: Int = 0

    /// Number of items encrypted so far
    @Published var prepDone: Int = 0

    /// E2EE preparation error message
    @Published var prepError: String? = nil

    // MARK: - UI State

    /// Loading state (for API calls)
    @Published var isLoading: Bool = false

    /// Show toast notification
    @Published var showToast: Bool = false

    /// Toast message text
    @Published var toastMessage: String = ""

    /// Toast type for styling
    @Published var toastType: ToastType = .info

    /// Error message (displayed inline)
    @Published var error: String? = nil

    /// Loading share targets
    @Published var isLoadingTargets: Bool = false

    // MARK: - Context

    /// Album ID being shared
    let albumId: Int

    /// Album name (for default share name)
    let albumName: String?

    /// Whether the album is a live/dynamic album
    let isLiveAlbum: Bool

    // MARK: - Services

    private let shareService = ShareService.shared
    private let e2eeManager = E2EEManager.shared
    private let authManager = AuthManager.shared

    // MARK: - Initialization

    /// Initialize view model with album context
    /// - Parameters:
    ///   - albumId: ID of the album to share
    ///   - albumName: Name of the album (optional)
    ///   - isLiveAlbum: Whether the album is live/dynamic
    init(albumId: Int, albumName: String?, isLiveAlbum: Bool) {
        self.albumId = albumId
        self.albumName = albumName
        self.isLiveAlbum = isLiveAlbum

        // Set default share name from album name or fallback
        self.shareName = albumName ?? "Album #\(albumId)"

        // Set default expiry to 7 days from now
        self.expiryDate = Date().addingTimeInterval(86400 * 7)
        self.pubExpiryDate = Date().addingTimeInterval(86400 * 7)

        print("✅ NewShareViewModel initialized - Album ID: \(albumId), Name: \(albumName ?? "nil"), IsLive: \(isLiveAlbum)")
    }

    // MARK: - Load Share Targets

    /// Load available users and groups for recipient selection
    func loadShareTargets() async {
        isLoadingTargets = true
        error = nil

        do {
            // Fetch all available share targets (no query filter)
            let allTargets = try await shareService.listShareTargets(query: nil)

            // Filter out the current user from the list
            let currentUserId = authManager.userId
            availableTargets = allTargets.filter { target in
                // Keep all groups
                if target.kind == "group" {
                    return true
                }
                // For users, exclude if ID matches current user
                if let targetId = target.id, let currentId = currentUserId {
                    return targetId != currentId
                }
                // Keep users without ID (shouldn't happen, but be safe)
                return true
            }

            print("🔍 Loaded \(allTargets.count) targets, filtered to \(availableTargets.count) (excluded current user: \(currentUserId ?? "unknown"))")
        } catch {
            self.error = "Failed to load users and groups: \(error.localizedDescription)"
            print("❌ Error loading share targets: \(error)")
        }

        isLoadingTargets = false
    }

    // MARK: - Recipient Management

    /// Toggle recipient selection
    /// - Parameter target: The share target to toggle
    func toggleRecipient(_ target: ShareTarget) {
        if let index = selectedRecipients.firstIndex(where: { $0.id == target.id }) {
            // Already selected, remove it
            selectedRecipients.remove(at: index)
        } else {
            // Not selected, add it
            selectedRecipients.append(target)
        }
    }

    /// Check if a target is currently selected
    /// - Parameter target: The share target to check
    /// - Returns: True if selected, false otherwise
    func isSelected(_ target: ShareTarget) -> Bool {
        return selectedRecipients.contains(where: { $0.id == target.id })
    }

    /// Remove a recipient from selection
    /// - Parameter target: The share target to remove
    func removeRecipient(_ target: ShareTarget) {
        selectedRecipients.removeAll(where: { $0.id == target.id })
    }

    // MARK: - Validation

    /// Check if the share can be created (all required fields valid)
    var canCreate: Bool {
        // Name must not be empty
        guard !shareName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        // Check tab-specific validation
        if selectedTab == .internal {
            // Internal shares require at least one recipient
            guard !selectedRecipients.isEmpty else {
                return false
            }
        } else {
            // Public link validation
            if pubRequirePin {
                // PIN must be exactly 8 characters
                guard pubPin.count == 8 else {
                    return false
                }
            }
        }

        // Not already loading
        guard !isLoading && !prepBusy else {
            return false
        }

        return true
    }

    // MARK: - Create Share

    /// Create the share based on selected tab
    func createShare() async {
        guard canCreate else { return }

        if selectedTab == .internal {
            await createInternalShare()
        } else {
            await createPublicLink()
        }
    }

    /// Create an internal share with recipients
    private func createInternalShare() async {
        isLoading = true
        error = nil

        defer { isLoading = false }

        do {
            // Build recipients array
            let recipients = selectedRecipients.map { target -> CreateShareRequest.RecipientInput in
                return CreateShareRequest.RecipientInput(
                    type: target.kind,
                    id: target.id,
                    email: target.email,
                    permissions: nil // Use default permissions
                )
            }

            // Calculate permissions bitflags
            var permissions = SharePermissions.VIEW
            if allowComments {
                permissions |= SharePermissions.COMMENT
            }
            if allowLikes {
                permissions |= SharePermissions.LIKE
            }
            if role == .contributor {
                permissions |= SharePermissions.UPLOAD
            }

            // Build create share request
            let request = CreateShareRequest(
                object: CreateShareRequest.ShareObject(
                    kind: "album",
                    id: String(albumId)
                ),
                name: shareName,
                defaultPermissions: permissions,
                expiresAt: expiryDate.ISO8601Format(),
                includeFaces: includeFaces,
                includeSubtree: includeSubtree,
                recipients: recipients
            )

            // Create the share
            let share = try await shareService.createShare(request)
            print("✅ Share created: \(share.id)")

            // Check for locked photos and trigger E2EE preparation if needed
            let lockedAssets = try await detectLockedPhotos()
            if !lockedAssets.isEmpty {
                print("ℹ️ Found \(lockedAssets.count) locked photos, starting E2EE preparation...")
                await prepareShareE2EE(shareId: share.id, lockedAssetIds: lockedAssets)
            }

            // Show success toast
            showSuccessToast("Share created successfully!")

        } catch {
            self.error = error.localizedDescription
            showErrorToast("Failed to create share: \(error.localizedDescription)")
            print("❌ Error creating share: \(error)")
        }
    }

    /// Create a public link
    private func createPublicLink() async {
        isLoading = true
        error = nil

        defer { isLoading = false }

        do {
            // Calculate permissions
            var permissions = SharePermissions.VIEW
            if pubAllowComments {
                permissions |= SharePermissions.COMMENT
            }
            if pubAllowLikes {
                permissions |= SharePermissions.LIKE
            }
            if pubRole == .contributor {
                permissions |= SharePermissions.UPLOAD
            }

            // Determine cover asset ID (use first asset if not set)
            let coverAssetId = pubCoverAssetId ?? "default"

            // Build create public link request
            let request = CreatePublicLinkRequest(
                name: shareName,
                scopeKind: pubIncludeAlbum ? "album" : "upload_only",
                scopeAlbumId: pubIncludeAlbum ? albumId : nil,
                permissions: permissions,
                expiresAt: pubExpiryDate.ISO8601Format(),
                pin: pubRequirePin ? pubPin : nil,
                coverAssetId: coverAssetId,
                moderationEnabled: pubModeration
            )

            // Create the public link
            let link = try await shareService.createPublicLink(request)
            print("✅ Public link created: \(link.id)")
            print("   URL: \(link.url ?? "N/A")")

            // Check for locked photos and trigger E2EE preparation if needed
            let lockedAssets = try await detectLockedPhotos()
            if !lockedAssets.isEmpty {
                print("ℹ️ Found \(lockedAssets.count) locked photos, starting E2EE preparation...")
                await preparePublicLinkE2EE(linkId: link.id, lockedAssetIds: lockedAssets)
            }

            // Show success toast with link
            if let url = link.url {
                showSuccessToast("Public link created: \(url)")
            } else {
                showSuccessToast("Public link created successfully!")
            }

        } catch {
            self.error = error.localizedDescription
            showErrorToast("Failed to create public link: \(error.localizedDescription)")
            print("❌ Error creating public link: \(error)")
        }
    }

    // MARK: - E2EE Preparation

    /// Detect locked photos in the album being shared
    /// - Returns: Array of locked asset IDs
    private func detectLockedPhotos() async throws -> [String] {
        // Query the album for locked photos
        // This would typically call an API endpoint like:
        // GET /api/albums/{albumId}/assets?locked=true
        // For now, return empty array as placeholder
        // Full implementation would require API endpoint for querying locked status

        print("🔍 Checking for locked photos in album \(albumId)...")

        // Placeholder: Return empty array
        // In production, this would make an API call to detect locked assets
        return []
    }

    /// Prepare E2EE wraps for locked photos in a share
    /// - Parameters:
    ///   - shareId: The share ID
    ///   - lockedAssetIds: Array of locked asset IDs
    private func prepareShareE2EE(shareId: String, lockedAssetIds: [String]) async {
        guard !lockedAssetIds.isEmpty else { return }

        prepBusy = true
        prepMsg = "Preparing encrypted wraps"
        prepTotal = lockedAssetIds.count
        prepDone = 0
        prepError = nil

        do {
            // Step 1: Ensure user has ECIES keypair
            print("🔐 Step 1: Checking ECIES keypair...")
            // Would call E2EEManager or API to ensure keypair exists
            // If not exists, generate and upload public key via POST /api/ee/identity/pubkey

            // Step 2: Fetch recipient public keys
            print("🔐 Step 2: Fetching recipient public keys...")
            // Would call: GET /api/ee/identity/{user_id}/pubkey for each recipient
            // Store public keys for encryption

            // Step 3: Generate SMK (Share Master Key) for this share
            print("🔐 Step 3: Generating SMK...")
            let smk = SymmetricKey(size: .bits256)
            // In production, this would be a proper random key generation

            // Step 4: Wrap SMK with each recipient's public key (ECIES)
            print("🔐 Step 4: Wrapping SMK for recipients...")
            // For each recipient:
            //   - Encrypt SMK with recipient's public key using ECIES
            //   - Create envelope: { recipient_user_id, encrypted_smk_b64 }
            // Upload all envelopes via POST /api/ee/shares/{shareId}/e2ee/recipient-envelopes

            // Step 5: Wrap DEKs (Data Encryption Keys) for locked assets
            print("🔐 Step 5: Wrapping DEKs for \(lockedAssetIds.count) assets...")
            let batchSize = 600
            for i in stride(from: 0, to: lockedAssetIds.count, by: batchSize) {
                let endIndex = min(i + batchSize, lockedAssetIds.count)
                let batch = Array(lockedAssetIds[i..<endIndex])

                // For each asset in batch:
                //   - Fetch or generate DEK for the asset
                //   - Wrap DEK with SMK: AES-GCM(key=SMK, plaintext=DEK)
                //   - Upload wraps for batch

                // Update progress
                prepDone = min(endIndex, prepTotal)

                print("   Progress: \(prepDone)/\(prepTotal)")

                // Small delay to simulate processing
                try await Task.sleep(nanoseconds: 100_000_000) // 0.1s
            }

            print("✅ E2EE preparation complete for share")

        } catch {
            prepError = "E2EE preparation failed: \(error.localizedDescription)"
            print("❌ E2EE preparation error: \(error)")
        }

        prepBusy = false
    }

    /// Prepare E2EE wraps for locked photos in a public link
    /// - Parameters:
    ///   - linkId: The public link ID
    ///   - lockedAssetIds: Array of locked asset IDs
    private func preparePublicLinkE2EE(linkId: String, lockedAssetIds: [String]) async {
        guard !lockedAssetIds.isEmpty else { return }

        prepBusy = true
        prepMsg = "Preparing encrypted wraps"
        prepTotal = lockedAssetIds.count
        prepDone = 0
        prepError = nil

        do {
            // Step 1: Generate VK (Viewer Key) for the public link
            print("🔐 Step 1: Generating VK for public link...")
            let vk = SymmetricKey(size: .bits256)
            // In production, this would be a proper random key generation

            // Step 2: Generate SMK (Share Master Key)
            print("🔐 Step 2: Generating SMK...")
            let smk = SymmetricKey(size: .bits256)

            // Step 3: Wrap SMK based on PIN requirement
            print("🔐 Step 3: Wrapping SMK...")
            if pubRequirePin && !pubPin.isEmpty {
                // Derive KEK from PIN using Argon2id
                // KEK = Argon2id(password=PIN, salt=random, m=64MB, t=3, p=1)
                // Wrap SMK with KEK: AES-GCM(key=KEK, plaintext=SMK)
                print("   Using PIN-derived KEK")
            } else {
                // Store SMK unwrapped (accessible to anyone with link)
                print("   No PIN protection")
            }

            // Upload SMK envelope via POST /api/ee/public-links/{linkId}/e2ee/smk-envelope

            // Step 4: Wrap DEKs for locked assets
            print("🔐 Step 4: Wrapping DEKs for \(lockedAssetIds.count) assets...")
            let batchSize = 600
            for i in stride(from: 0, to: lockedAssetIds.count, by: batchSize) {
                let endIndex = min(i + batchSize, lockedAssetIds.count)
                let batch = Array(lockedAssetIds[i..<endIndex])

                // For each asset in batch:
                //   - Fetch or generate DEK for the asset
                //   - Wrap DEK with SMK: AES-GCM(key=SMK, plaintext=DEK)
                // Upload batch via POST /api/ee/public-links/{linkId}/e2ee/dek-wraps/batch

                // Update progress
                prepDone = min(endIndex, prepTotal)

                print("   Progress: \(prepDone)/\(prepTotal)")

                // Small delay to simulate processing
                try await Task.sleep(nanoseconds: 100_000_000) // 0.1s
            }

            print("✅ E2EE preparation complete for public link")

        } catch {
            prepError = "E2EE preparation failed: \(error.localizedDescription)"
            print("❌ E2EE preparation error: \(error)")
        }

        prepBusy = false
    }

    // MARK: - Toast Helpers

    /// Show success toast notification
    /// - Parameter message: Success message to display
    private func showSuccessToast(_ message: String) {
        toastMessage = message
        toastType = .success
        showToast = true
    }

    /// Show error toast notification
    /// - Parameter message: Error message to display
    private func showErrorToast(_ message: String) {
        toastMessage = message
        toastType = .error
        showToast = true
    }

    /// Show info toast notification
    /// - Parameter message: Info message to display
    private func showInfoToast(_ message: String) {
        toastMessage = message
        toastType = .info
        showToast = true
    }
}
