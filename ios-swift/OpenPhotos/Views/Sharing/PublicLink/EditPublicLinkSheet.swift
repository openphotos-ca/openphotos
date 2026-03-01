//
//  EditPublicLinkSheet.swift
//  OpenPhotos
//
//  Sheet for editing an existing public link.
//

import SwiftUI

/// Sheet for editing a public link
struct EditPublicLinkSheet: View {
    let link: PublicLink
    var onUpdate: (() -> Void)? = nil

    @State private var linkName: String
    @State private var permissions: SharePermissions
    @State private var expiryDate: Date?
    @State private var hasExpiry: Bool
    @State private var coverAssetId: String
    @State private var pin: String = ""
    @State private var hasPin: Bool
    @State private var hasLockedItems = false
    @State private var urlHasVK = false
    @State private var showUrlField = true
    @State private var coverImage: UIImage?
    @State private var newCoverAssetId: String? // Track new cover selection
    @State private var showCoverPicker = false
    @State private var moderationEnabled: Bool

    @State private var isUpdating = false
    @State private var isDeleting = false
    @State private var isRotatingKey = false
    @State private var showDeleteConfirmation = false
    @State private var showRotateKeyConfirmation = false
    @State private var showQRView = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    @StateObject private var toastManager = ToastManager.shared

    private let shareService = ShareService.shared

    init(link: PublicLink, onUpdate: (() -> Void)? = nil) {
        self.link = link
        self.onUpdate = onUpdate
        self._linkName = State(initialValue: link.name)
        self._permissions = State(initialValue: SharePermissions(rawValue: link.permissions))
        self._expiryDate = State(initialValue: link.expiresAt)
        self._hasExpiry = State(initialValue: link.expiresAt != nil)
        self._coverAssetId = State(initialValue: link.coverAssetId ?? "")
        self._hasPin = State(initialValue: link.hasPin ?? false)
        self._moderationEnabled = State(initialValue: link.moderationEnabled)

        // Check if link has locked items based on name or other indicators
        let nameIndicatesLocked = link.name.lowercased().contains("locked")
        self._hasLockedItems = State(initialValue: nameIndicatesLocked)

        // Check if URL has VK fragment
        let hasVK = link.url?.contains("#vk=") ?? false
        self._urlHasVK = State(initialValue: hasVK)

        // Show URL field only if not locked or has VK
        self._showUrlField = State(initialValue: !nameIndicatesLocked || hasVK)
    }

    var body: some View {
        NavigationStack {
            Form {
                // Link name
                Section("Name") {
                    TextField("Link name", text: $linkName)
                }

                // VK warning if needed
                if hasLockedItems && !urlHasVK {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text("Missing Encryption Key")
                                    .font(.headline)
                                    .foregroundColor(.orange)
                            }

                            Text("This URL lacks the encryption key. Viewers won't be able to decrypt locked items. The key is not available in this browser.")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Text("Consider recreating the link from the album/photo sharing menu.")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(.primary)
                        }
                        .padding(.vertical, 8)
                    } header: {
                        Text("Warning")
                    }
                }

                // Cover image
                Section("Cover Image") {
                    HStack(spacing: 12) {
                        // Cover image preview
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(.systemGray5))
                                .frame(width: 60, height: 60)

                            if let coverImage = coverImage {
                                Image(uiImage: coverImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 60, height: 60)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            } else if !coverAssetId.isEmpty {
                                // Show loading or placeholder for existing cover
                                ProgressView()
                                    .frame(width: 60, height: 60)
                            } else {
                                Image(systemName: "photo")
                                    .foregroundColor(.secondary)
                                    .font(.title2)
                            }
                        }

                        // Choose button to open library picker (same as web client)
                        Button {
                            showCoverPicker = true
                        } label: {
                            Text("Choose Cover")
                                .font(.body)
                                .foregroundColor(.accentColor)
                        }

                        Spacer()
                    }
                }

                // Permissions
                Section {
                    SharePermissionsView(permissions: $permissions)
                }

                // PIN protection
                Section {
                    Toggle("PIN Protection", isOn: $hasPin)

                    if hasPin {
                        TextField("8-digit PIN", text: $pin)
                            .keyboardType(.numberPad)
                            .onChange(of: pin) { _, newValue in
                                // Limit to 8 characters
                                if newValue.count > 8 {
                                    pin = String(newValue.prefix(8))
                                }
                            }
                    }
                } header: {
                    Text("Security")
                } footer: {
                    if hasPin {
                        Text("Enter an 8-digit PIN to update. Leave empty to keep current PIN.")
                    }
                }

                // Options
                Section("Options") {
                    // Expiry date
                    Toggle("Set expiry date", isOn: $hasExpiry)

                    if hasExpiry {
                        DatePicker(
                            "Expires on",
                            selection: Binding(
                                get: { expiryDate ?? Date().addingTimeInterval(86400 * 7) },
                                set: { expiryDate = $0 }
                            ),
                            in: Date()...,
                            displayedComponents: [.date]
                        )
                    }
                }

                // Link actions - only show if not locked or has VK
                if !hasLockedItems || urlHasVK {
                    Section("Link Actions") {
                        Button {
                            showQRView = true
                        } label: {
                            Label("Show QR Code", systemImage: "qrcode")
                        }

                        Button {
                            openLinkInBrowser()
                        } label: {
                            Label("Open Link", systemImage: "arrow.up.forward.square")
                        }

                        Button {
                            copyLinkToClipboard()
                        } label: {
                            Label("Copy Link", systemImage: "doc.on.doc")
                        }
                    }
                } else {
                    // Show explanation when URL is hidden
                    Section {
                        HStack {
                            Image(systemName: "link.circle.fill")
                                .foregroundColor(.secondary)
                            Text("URL and QR code are hidden because the encryption key is missing.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    } header: {
                        Text("Link Actions")
                    }
                }

                // Dangerous actions
                Section {
                    // Only show rotate key if we have a VK to rotate
                    if !hasLockedItems || urlHasVK {
                        Button(role: .destructive) {
                            showRotateKeyConfirmation = true
                        } label: {
                            HStack {
                                if isRotatingKey {
                                    ProgressView()
                                        .frame(width: 20, height: 20)
                                    Text("Rotating Key...")
                                } else {
                                    Label("Rotate Viewer Key", systemImage: "arrow.triangle.2.circlepath")
                                }
                            }
                        }
                        .disabled(isRotatingKey || isUpdating || isDeleting)
                    }

                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        HStack {
                            Spacer()
                            if isDeleting {
                                ProgressView()
                                Text("Deleting...")
                            } else {
                                Text("Delete Link")
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(isDeleting || isUpdating || isRotatingKey)
                }

                // Error message
                if let error = error {
                    Section {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Edit Public Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(isUpdating ? "Saving..." : "Save") {
                        Task {
                            await updateLink()
                        }
                    }
                    .disabled(isUpdating || isDeleting || isRotatingKey || !canSave)
                }
            }
            .confirmationDialog("Delete Link", isPresented: $showDeleteConfirmation) {
                Button("Delete", role: .destructive) {
                    Task {
                        await deleteLink()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Are you sure you want to delete this public link? This action cannot be undone and will remove access for everyone.")
            }
            .confirmationDialog("Rotate Viewer Key", isPresented: $showRotateKeyConfirmation) {
                Button("Rotate", role: .destructive) {
                    Task {
                        await rotateKey()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will invalidate the current URL and generate a new one. All existing links will stop working.")
            }
            .sheet(isPresented: $showQRView) {
                PublicLinkQRView(link: link, onDismiss: {
                    showQRView = false
                })
            }
            .navigationDestination(isPresented: $showCoverPicker) {
                CoverPhotoPickerView(onSelection: { selectedAssetId in
                    print("[EditPublicLink] User selected cover asset: \(selectedAssetId)")
                    // Set the new cover asset ID
                    newCoverAssetId = selectedAssetId
                    coverAssetId = selectedAssetId

                    // Load the thumbnail for preview
                    Task {
                        await loadCoverImage()
                    }

                    // Dismiss the picker
                    showCoverPicker = false
                }, onCancel: {
                    showCoverPicker = false
                })
            }
            .onAppear {
                print("[EditPublicLink] === SHEET APPEARED ===")
                print("[EditPublicLink] Initial state:")
                print("[EditPublicLink]   - link.id: \(link.id)")
                print("[EditPublicLink]   - link.coverAssetId: \(link.coverAssetId ?? "nil")")
                print("[EditPublicLink]   - coverAssetId (state): \(coverAssetId)")
                print("[EditPublicLink]   - newCoverAssetId: \(newCoverAssetId ?? "nil")")
                print("[EditPublicLink]   - coverImage exists: \(coverImage != nil)")

                // Reset state for fresh load
                newCoverAssetId = nil
                coverImage = nil

                // Update coverAssetId from the link to get the latest value
                if let latestCoverAssetId = link.coverAssetId, !latestCoverAssetId.isEmpty {
                    coverAssetId = latestCoverAssetId
                }

                print("[EditPublicLink] After reset:")
                print("[EditPublicLink]   - coverAssetId (state): \(coverAssetId)")
                print("[EditPublicLink]   - loading cover image...")

                loadCoverImage()
            }
        }
    }

    // MARK: - Validation

    private var canSave: Bool {
        let hasValidName = !linkName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasValidPin = !hasPin || pin.isEmpty || pin.count == 8
        return hasValidName && hasValidPin
    }

    // MARK: - Actions

    /// Update link
    private func updateLink() async {
        guard canSave else { return }

        isUpdating = true
        error = nil

        do {
            // Use newCoverAssetId if a new cover was selected
            // If no new cover was selected, fall back to existing cover so the server
            // always receives an explicit cover_asset_id (matches web behaviour).
            let updatedCoverAssetId: String? = newCoverAssetId ?? link.coverAssetId

            print("[EditPublicLink] === UPDATE LINK DEBUG ===")
            print("[EditPublicLink] Current state:")
            print("[EditPublicLink]   - coverAssetId (state): \(coverAssetId)")
            print("[EditPublicLink]   - newCoverAssetId: \(newCoverAssetId ?? "nil")")
            print("[EditPublicLink]   - link.coverAssetId: \(link.coverAssetId ?? "nil")")
            print("[EditPublicLink]   - updatedCoverAssetId (to send): \(updatedCoverAssetId ?? "nil")")
            print("[EditPublicLink]   - coverImage exists: \(coverImage != nil)")

            let request = UpdatePublicLinkRequest(
                name: linkName != link.name ? linkName : nil,
                permissions: permissions.rawValue != link.permissions ? permissions.rawValue : nil,
                expiresAt: hasExpiry ? expiryDate?.ISO8601Format() : nil,
                coverAssetId: updatedCoverAssetId,
                pin: hasPin && !pin.isEmpty ? pin : nil,
                clearPin: !hasPin && link.hasPin == true ? true : nil,
                moderationEnabled: moderationEnabled != link.moderationEnabled ? moderationEnabled : nil
            )

            // Log the request
            if let jsonData = try? JSONEncoder().encode(request),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                print("[EditPublicLink] Request JSON: \(jsonString)")
            }

            _ = try await shareService.updatePublicLink(id: link.id, request)

            isUpdating = false
            await MainActor.run {
                toastManager.show("Link updated successfully")
                // Call the update callback to refresh the parent view
                onUpdate?()
            }
            dismiss()
        } catch {
            print("[EditPublicLink] Update failed: \(error)")
            self.error = error.localizedDescription
            isUpdating = false
            await MainActor.run {
                toastManager.show("Failed to update link")
            }
        }
    }

    /// Rotate viewer key
    private func rotateKey() async {
        isRotatingKey = true
        error = nil

        do {
            _ = try await shareService.rotatePublicLinkKey(id: link.id)
            isRotatingKey = false
            dismiss()
        } catch {
            self.error = error.localizedDescription
            isRotatingKey = false
        }
    }

    /// Delete link
    private func deleteLink() async {
        isDeleting = true
        error = nil

        do {
            try await shareService.deletePublicLink(id: link.id)
            isDeleting = false
            await MainActor.run {
                // Call the update callback to refresh the parent view
                onUpdate?()
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
            isDeleting = false
        }
    }

    /// Copy link to clipboard
    private func copyLinkToClipboard() {
        guard let url = link.url else { return }
        UIPasteboard.general.string = url
        toastManager.show("Link copied to clipboard")
    }

    /// Open link in browser
    private func openLinkInBrowser() {
        guard let urlString = link.url,
              let url = URL(string: urlString) else { return }
        UIApplication.shared.open(url)
    }

    /// Load cover image from asset ID
    private func loadCoverImage() {
        print("[EditPublicLink] loadCoverImage called with coverAssetId: '\(coverAssetId)'")
        guard !coverAssetId.isEmpty else {
            print("[EditPublicLink] coverAssetId is empty, skipping load")
            return
        }

        Task {
            do {
                // Build the URL and create request
                let client = AuthorizedHTTPClient.shared
                let url = client.buildURL(path: "/api/thumbnails/\(coverAssetId)")
                print("[EditPublicLink] Loading cover image from URL: \(url.absoluteString)")
                let req = URLRequest(url: url)

                // Fetch the thumbnail data
                let (data, response) = try await client.request(req)

                // Check for success
                if (200..<300).contains(response.statusCode) {
                    print("[EditPublicLink] Cover image data received, size: \(data.count) bytes")
                    if let image = UIImage(data: data) {
                        print("[EditPublicLink] Cover UIImage created, size: \(image.size)")
                        await MainActor.run {
                            self.coverImage = image
                            print("[EditPublicLink] Cover image set in UI")
                        }
                    } else {
                        print("[EditPublicLink] Failed to create UIImage from thumbnail data")
                    }
                } else {
                    print("[EditPublicLink] Failed to load cover image: HTTP \(response.statusCode)")
                }
            } catch {
                // If loading fails, show a placeholder
                print("[EditPublicLink] Failed to load cover image: \(error)")
                await MainActor.run {
                    // Could set a placeholder image here
                    self.coverImage = nil
                }
            }
        }
    }

    /* Deprecated - No longer needed since we pick from existing library photos
    private func loadSelectedPhoto(from item: Any?) async {
        guard let item = item else {
            print("[EditPublicLink] loadSelectedPhoto called with nil item")
            return
        }

        print("[EditPublicLink] Starting photo load and upload process")

        await MainActor.run {
            self.isUploadingCover = true
            self.error = nil
        }

        // Load the image data
        print("[EditPublicLink] Loading image data from PhotosPickerItem")
        if let data = try? await item.loadTransferable(type: Data.self) {
            print("[EditPublicLink] Image data loaded, size: \(data.count) bytes")
            if let uiImage = UIImage(data: data) {
                print("[EditPublicLink] UIImage created successfully, size: \(uiImage.size)")
                await MainActor.run {
                    self.coverImage = uiImage
                    print("[EditPublicLink] Cover image set in UI")
                }

                // Upload the image to get a real asset ID
                do {
                    print("[EditPublicLink] Starting cover image upload")
                    print("[EditPublicLink] Current coverAssetId: \(coverAssetId)")
                    print("[EditPublicLink] Original link.coverAssetId: \(link.coverAssetId ?? "nil")")

                    let assetId = try await uploadCoverImage(data)
                    print("[EditPublicLink] Upload successful, received asset ID: \(assetId)")

                    if assetId == link.coverAssetId {
                        print("[EditPublicLink] WARNING: New asset ID is the same as the original!")
                        print("[EditPublicLink]   This might mean the same image was selected")
                    }

                    await MainActor.run {
                        self.newCoverAssetId = assetId
                        self.isUploadingCover = false
                        print("[EditPublicLink] newCoverAssetId set to: \(assetId)")
                    }
                } catch {
                    print("[EditPublicLink] Failed to upload cover image: \(error)")
                    let errorMessage = (error as NSError).localizedDescription
                    await MainActor.run {
                        // Check if it's the server ingestion issue
                        if errorMessage.contains("server is not processing uploaded files") {
                            self.error = "Cover upload issue: Server is not processing new uploads. Using an existing photo as cover instead."
                            // Keep the selected image displayed even though we're using a different asset ID
                            // This provides better UX - the user sees their selection
                        } else {
                            self.error = "Failed to upload cover image: \(errorMessage)"
                            self.coverImage = nil
                            self.newCoverAssetId = nil
                        }
                        self.isUploadingCover = false
                    }
                }
            } else {
                print("[EditPublicLink] Failed to create UIImage from data")
                await MainActor.run {
                    self.isUploadingCover = false
                }
            }
        } else {
            print("[EditPublicLink] Failed to load data from PhotosPickerItem")
            await MainActor.run {
                self.isUploadingCover = false
            }
        }
    }

    /// This function is no longer needed - we'll pick from existing photos instead
    @available(*, deprecated, message: "Use photo picker from library instead")
    private func uploadCoverImage(_ imageData: Data) async throws -> String {
        // Ensure we have the server URL
        let auth = AuthManager.shared
        guard let filesURL = URL(string: auth.serverURL + "/files") else {
            throw NSError(domain: "EditPublicLink", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid server URL"])
        }

        // Create TUS client
        let tusClient = TUSClient(baseURL: filesURL, headersProvider: {
            auth.authHeader()
        }, chunkSize: 2 * 1024 * 1024) // 2MB chunks for smaller files

        // Save image to temporary file
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        try imageData.write(to: tempURL)
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        // Create TUS upload
        let fileSize = Int64(imageData.count)
        let uniqueId = UUID().uuidString
        let filename = "cover_\(uniqueId).jpg"
        let uploadId = UUID().uuidString

        print("[EditPublicLink] Upload filename will be: \(filename)")

        let createResponse = try await tusClient.create(
            fileSize: fileSize,
            filename: filename,
            mimeType: "image/jpeg",
            metadata: ["purpose": "public_link_cover", "unique_id": uniqueId]
        )

        // Upload the file
        var uploadedBytes: Int64 = 0
        try await tusClient.upload(
            fileURL: tempURL,
            uploadURL: createResponse.uploadURL,
            startOffset: 0,
            fileSize: fileSize,
            progress: { sent, total in
                uploadedBytes = sent
                print("Upload progress: \(sent)/\(total)")
            },
            isCancelled: { false }
        )

        // Extract upload ID from the upload URL
        print("[EditPublicLink] Upload URL: \(createResponse.uploadURL.absoluteString)")
        let pathComponents = createResponse.uploadURL.pathComponents
        print("[EditPublicLink] Path components: \(pathComponents)")

        // Get the upload ID from the URL
        var extractedUploadId: String? = nil
        if let filesIndex = pathComponents.firstIndex(of: "files"),
           filesIndex + 1 < pathComponents.count {
            extractedUploadId = pathComponents[filesIndex + 1]
            print("[EditPublicLink] Extracted upload ID: \(extractedUploadId ?? "nil")")
        }

        // Wait for the server to process the upload and retry if needed
        var retryCount = 0
        let maxRetries = 3
        var foundAssetId: String? = nil

        while retryCount < maxRetries && foundAssetId == nil {
            // Wait before checking (longer on first try to give server time to process)
            let waitTime: UInt64 = retryCount == 0 ? 3_000_000_000 : 2_000_000_000 // 3 seconds first, then 2 seconds
            print("[EditPublicLink] Waiting \(waitTime/1_000_000_000) seconds for server to process upload (attempt \(retryCount + 1)/\(maxRetries))")
            try await Task.sleep(nanoseconds: waitTime)

            // Now query for the most recent photo to get the actual asset ID
            let client = AuthorizedHTTPClient.shared
            let photosURL = client.buildURL(path: "/api/photos", queryItems: [
                URLQueryItem(name: "limit", value: "20"),  // Increased to 20 to have better chance of finding our upload
                URLQueryItem(name: "sort", value: "newest")
            ])

            var request = URLRequest(url: photosURL)
            request.httpMethod = "GET"

            let (data, response) = try await client.request(request)

            guard (200..<300).contains(response.statusCode) else {
                print("[EditPublicLink] Failed to fetch photos: HTTP \(response.statusCode)")
                retryCount += 1
                continue
            }

            // Parse the response to find our uploaded photo
            struct PhotosResponse: Codable {
                let photos: [PhotoItem]

                struct PhotoItem: Codable {
                    let asset_id: String
                    let filename: String?
                    let created_at: Int?
                }
            }

            let decoder = JSONDecoder()
            let photosResponse = try decoder.decode(PhotosResponse.self, from: data)

            print("[EditPublicLink] Retry \(retryCount + 1): Fetched \(photosResponse.photos.count) recent photos")
            for (index, photo) in photosResponse.photos.prefix(5).enumerated() {
                print("[EditPublicLink]   Photo \(index): asset_id=\(photo.asset_id), filename=\(photo.filename ?? "nil")")
            }

            // Try to find our uploaded photo by exact filename match
            print("[EditPublicLink] Looking for exact filename: \(filename)")
            if let uploadedPhoto = photosResponse.photos.first(where: { photo in
                if let photoFilename = photo.filename {
                    // Look for exact match or filename within the path
                    let exactMatch = photoFilename == filename
                    let pathMatch = photoFilename.hasSuffix("/" + filename) || photoFilename.contains("__" + filename)
                    let matches = exactMatch || pathMatch
                    if matches {
                        print("[EditPublicLink] Filename EXACT match: '\(photoFilename)' matches '\(filename)'")
                    }
                    return matches
                }
                return false
            }) {
                print("[EditPublicLink] ✅ Found uploaded photo by exact filename with asset ID: \(uploadedPhoto.asset_id) on retry \(retryCount + 1)")
                foundAssetId = uploadedPhoto.asset_id
                break  // Exit the retry loop
            }

            print("[EditPublicLink] No exact filename match found on retry \(retryCount + 1), trying partial match with unique ID")

            // If exact match fails, try to find by the unique ID portion of the filename
            let filenameComponents = filename.components(separatedBy: "_")
            if filenameComponents.count >= 2 {
                let uniqueIdFromFilename = filenameComponents[1].replacingOccurrences(of: ".jpg", with: "")
                if let uploadedPhoto = photosResponse.photos.first(where: { photo in
                    if let photoFilename = photo.filename {
                        return photoFilename.contains(uniqueIdFromFilename)
                    }
                    return false
                }) {
                    print("[EditPublicLink] ✅ Found uploaded photo by unique ID with asset ID: \(uploadedPhoto.asset_id) on retry \(retryCount + 1)")
                    foundAssetId = uploadedPhoto.asset_id
                    break  // Exit the retry loop
                }
            }

            print("[EditPublicLink] Photo not found yet on retry \(retryCount + 1)")
            retryCount += 1
        }

        // After all retries, check if we found the asset ID
        if let assetId = foundAssetId {
            print("[EditPublicLink] Successfully found asset ID after retries: \(assetId)")
            return assetId
        }

        // If we still haven't found it after retries, the server hasn't ingested the TUS upload
        print("[EditPublicLink] ⚠️ Could not find uploaded photo after \(maxRetries) retries")
        print("[EditPublicLink] ⚠️ IMPORTANT: The server is not automatically ingesting TUS uploads into the photos database")
        print("[EditPublicLink] ⚠️ The uploaded file exists at: \(uploadURL) but has no asset ID")

        // For now, we'll select an existing photo as a placeholder
        // This is a temporary workaround until the server properly ingests TUS uploads
        print("[EditPublicLink] Attempting to use an existing photo as temporary cover...")

        // Try to get the list of photos to pick one as cover
        let client = AuthorizedHTTPClient.shared
        let photosURL = client.buildURL(path: "/api/photos", queryItems: [
            URLQueryItem(name: "limit", value: "20"),
            URLQueryItem(name: "sort", value: "newest")
        ])

        var request = URLRequest(url: photosURL)
        request.httpMethod = "GET"

        if let (data, response) = try? await client.request(request),
           (200..<300).contains(response.statusCode) {

            struct PhotosResponse: Codable {
                let photos: [PhotoItem]

                struct PhotoItem: Codable {
                    let asset_id: String
                    let filename: String?
                    let is_video: Bool?
                }
            }

            let decoder = JSONDecoder()
            if let photosResponse = try? decoder.decode(PhotosResponse.self, from: data) {
                // Find a suitable non-video photo to use as cover
                if let coverCandidate = photosResponse.photos.first(where: { photo in
                    // Skip videos and screenshots for cover
                    if photo.is_video == true { return false }
                    if let filename = photo.filename,
                       filename.lowercased().contains("screenshot") { return false }
                    return true
                }) {
                    print("[EditPublicLink] ⚠️ Using existing photo as temporary cover: \(coverCandidate.asset_id)")
                    print("[EditPublicLink]   Filename: \(coverCandidate.filename ?? "unknown")")
                    print("[EditPublicLink]   NOTE: The user's selected image was uploaded but cannot be used due to server limitations")
                    return coverCandidate.asset_id
                }

                // If no good candidate, just use the first photo
                if let firstPhoto = photosResponse.photos.first {
                    print("[EditPublicLink] ⚠️ Using first available photo as fallback cover: \(firstPhoto.asset_id)")
                    return firstPhoto.asset_id
                }
            }
        }

        // If all else fails, return nil and show error
        print("[EditPublicLink] ❌ ERROR: Could not find any photo to use as cover")
        throw NSError(domain: "EditPublicLink", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "Cover image upload failed. The server is not processing uploaded files correctly. Please try using an existing photo from your library instead."
        ])
    }
    */
}


// MARK: - Navigation-compatible Edit Public Link View

/// View for editing a public link, designed to be pushed via NavigationStack
/// Use this instead of EditPublicLinkSheet when presenting from within another sheet
struct EditPublicLinkView: View {
    let link: PublicLink
    var onUpdate: (() -> Void)? = nil

    @State private var linkName: String
    @State private var permissions: SharePermissions
    @State private var expiryDate: Date?
    @State private var hasExpiry: Bool
    @State private var coverAssetId: String
    @State private var pin: String = ""
    @State private var hasPin: Bool
    @State private var hasLockedItems = false
    @State private var urlHasVK = false
    @State private var showUrlField = true
    @State private var coverImage: UIImage?
    @State private var newCoverAssetId: String?
    @State private var showCoverPicker = false
    @State private var moderationEnabled: Bool

    @State private var isUpdating = false
    @State private var isDeleting = false
    @State private var isRotatingKey = false
    @State private var showDeleteConfirmation = false
    @State private var showRotateKeyConfirmation = false
    @State private var showQRView = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    @StateObject private var toastManager = ToastManager.shared

    private let shareService = ShareService.shared

    init(link: PublicLink, onUpdate: (() -> Void)? = nil) {
        self.link = link
        self.onUpdate = onUpdate
        self._linkName = State(initialValue: link.name)
        self._permissions = State(initialValue: SharePermissions(rawValue: link.permissions))
        self._expiryDate = State(initialValue: link.expiresAt)
        self._hasExpiry = State(initialValue: link.expiresAt != nil)
        self._coverAssetId = State(initialValue: link.coverAssetId ?? "")
        self._hasPin = State(initialValue: link.hasPin ?? false)
        self._moderationEnabled = State(initialValue: link.moderationEnabled)

        let nameIndicatesLocked = link.name.lowercased().contains("locked")
        self._hasLockedItems = State(initialValue: nameIndicatesLocked)

        let hasVK = link.url?.contains("#vk=") ?? false
        self._urlHasVK = State(initialValue: hasVK)

        self._showUrlField = State(initialValue: !nameIndicatesLocked || hasVK)
    }

    var body: some View {
        Form {
            // Link name
            Section("Name") {
                TextField("Link name", text: $linkName)
            }

            // VK warning if needed
            if hasLockedItems && !urlHasVK {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("Missing Encryption Key")
                                .font(.headline)
                                .foregroundColor(.orange)
                        }

                        Text("This URL lacks the encryption key. Viewers won't be able to decrypt locked items. The key is not available in this browser.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Text("Consider recreating the link from the album/photo sharing menu.")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                    }
                    .padding(.vertical, 8)
                } header: {
                    Text("Warning")
                }
            }

            // Cover image
            Section("Cover Image") {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(.systemGray5))
                            .frame(width: 60, height: 60)

                        if let coverImage = coverImage {
                            Image(uiImage: coverImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 60, height: 60)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        } else if !coverAssetId.isEmpty {
                            ProgressView()
                                .frame(width: 60, height: 60)
                        } else {
                            Image(systemName: "photo")
                                .foregroundColor(.secondary)
                                .font(.title2)
                        }
                    }

                    Button {
                        showCoverPicker = true
                    } label: {
                        Text("Choose Cover")
                            .font(.body)
                            .foregroundColor(.accentColor)
                    }

                    Spacer()
                }
            }

            // Permissions
            Section {
                SharePermissionsView(permissions: $permissions)
            }

            // PIN protection
            Section {
                Toggle("PIN Protection", isOn: $hasPin)

                if hasPin {
                    TextField("8-digit PIN", text: $pin)
                        .keyboardType(.numberPad)
                        .onChange(of: pin) { _, newValue in
                            if newValue.count > 8 {
                                pin = String(newValue.prefix(8))
                            }
                        }
                }
            } header: {
                Text("Security")
            } footer: {
                if hasPin {
                    Text("Enter an 8-digit PIN to update. Leave empty to keep current PIN.")
                }
            }

            // Options
            Section("Options") {
                Toggle("Set expiry date", isOn: $hasExpiry)

                if hasExpiry {
                    DatePicker(
                        "Expires on",
                        selection: Binding(
                            get: { expiryDate ?? Date().addingTimeInterval(86400 * 7) },
                            set: { expiryDate = $0 }
                        ),
                        in: Date()...,
                        displayedComponents: [.date]
                    )
                }
            }

            // Link actions
            if !hasLockedItems || urlHasVK {
                Section("Link Actions") {
                    Button {
                        showQRView = true
                    } label: {
                        Label("Show QR Code", systemImage: "qrcode")
                    }

                    Button {
                        openLinkInBrowser()
                    } label: {
                        Label("Open Link", systemImage: "arrow.up.forward.square")
                    }

                    Button {
                        copyLinkToClipboard()
                    } label: {
                        Label("Copy Link", systemImage: "doc.on.doc")
                    }
                }
            } else {
                Section {
                    HStack {
                        Image(systemName: "link.circle.fill")
                            .foregroundColor(.secondary)
                        Text("URL and QR code are hidden because the encryption key is missing.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Link Actions")
                }
            }

            // Dangerous actions
            Section {
                if !hasLockedItems || urlHasVK {
                    Button(role: .destructive) {
                        showRotateKeyConfirmation = true
                    } label: {
                        HStack {
                            if isRotatingKey {
                                ProgressView()
                                    .frame(width: 20, height: 20)
                                Text("Rotating Key...")
                            } else {
                                Label("Rotate Viewer Key", systemImage: "arrow.triangle.2.circlepath")
                            }
                        }
                    }
                    .disabled(isRotatingKey || isUpdating || isDeleting)
                }

                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    HStack {
                        Spacer()
                        if isDeleting {
                            ProgressView()
                            Text("Deleting...")
                        } else {
                            Text("Delete Link")
                                .fontWeight(.semibold)
                        }
                        Spacer()
                    }
                }
                .disabled(isDeleting || isUpdating || isRotatingKey)
            }

            // Error message
            if let error = error {
                Section {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }
        }
        .navigationTitle("Edit Public Link")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(isUpdating ? "Saving..." : "Save") {
                    Task {
                        await updateLink()
                    }
                }
                .disabled(isUpdating || isDeleting || isRotatingKey || !canSave)
            }
        }
        .confirmationDialog("Delete Link", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                Task {
                    await deleteLink()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete this public link? This action cannot be undone and will remove access for everyone.")
        }
        .confirmationDialog("Rotate Viewer Key", isPresented: $showRotateKeyConfirmation) {
            Button("Rotate", role: .destructive) {
                Task {
                    await rotateKey()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will invalidate the current URL and generate a new one. All existing links will stop working.")
        }
        .navigationDestination(isPresented: $showQRView) {
            PublicLinkQRNavigationView(link: link, onDismiss: {
                showQRView = false
            })
        }
        .navigationDestination(isPresented: $showCoverPicker) {
            CoverPhotoPickerView(onSelection: { selectedAssetId in
                newCoverAssetId = selectedAssetId
                coverAssetId = selectedAssetId
                Task {
                    await loadCoverImage()
                }
                showCoverPicker = false
            }, onCancel: {
                showCoverPicker = false
            })
        }
        .onAppear {
            newCoverAssetId = nil
            coverImage = nil

            if let latestCoverAssetId = link.coverAssetId, !latestCoverAssetId.isEmpty {
                coverAssetId = latestCoverAssetId
            }

            loadCoverImage()
        }
    }

    // MARK: - Validation

    private var canSave: Bool {
        let hasValidName = !linkName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasValidPin = !hasPin || pin.isEmpty || pin.count == 8
        return hasValidName && hasValidPin
    }

    // MARK: - Actions

    private func updateLink() async {
        guard canSave else { return }

        isUpdating = true
        error = nil

        do {
            let updatedCoverAssetId: String? = newCoverAssetId ?? link.coverAssetId

            let request = UpdatePublicLinkRequest(
                name: linkName != link.name ? linkName : nil,
                permissions: permissions.rawValue != link.permissions ? permissions.rawValue : nil,
                expiresAt: hasExpiry ? expiryDate?.ISO8601Format() : nil,
                coverAssetId: updatedCoverAssetId,
                pin: hasPin && !pin.isEmpty ? pin : nil,
                clearPin: !hasPin && link.hasPin == true ? true : nil,
                moderationEnabled: moderationEnabled != link.moderationEnabled ? moderationEnabled : nil
            )

            _ = try await shareService.updatePublicLink(id: link.id, request)

            isUpdating = false
            await MainActor.run {
                toastManager.show("Link updated successfully")
                onUpdate?()
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
            isUpdating = false
            await MainActor.run {
                toastManager.show("Failed to update link")
            }
        }
    }

    private func rotateKey() async {
        isRotatingKey = true
        error = nil

        do {
            _ = try await shareService.rotatePublicLinkKey(id: link.id)
            isRotatingKey = false
            dismiss()
        } catch {
            self.error = error.localizedDescription
            isRotatingKey = false
        }
    }

    private func deleteLink() async {
        isDeleting = true
        error = nil

        do {
            try await shareService.deletePublicLink(id: link.id)
            isDeleting = false
            await MainActor.run {
                onUpdate?()
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
            isDeleting = false
        }
    }

    private func copyLinkToClipboard() {
        guard let url = link.url else { return }
        UIPasteboard.general.string = url
        toastManager.show("Link copied to clipboard")
    }

    private func openLinkInBrowser() {
        guard let urlString = link.url,
              let url = URL(string: urlString) else { return }
        UIApplication.shared.open(url)
    }

    private func loadCoverImage() {
        guard !coverAssetId.isEmpty else { return }

        Task {
            do {
                let client = AuthorizedHTTPClient.shared
                let url = client.buildURL(path: "/api/thumbnails/\(coverAssetId)")
                let req = URLRequest(url: url)

                let (data, response) = try await client.request(req)

                if (200..<300).contains(response.statusCode) {
                    if let image = UIImage(data: data) {
                        await MainActor.run {
                            self.coverImage = image
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.coverImage = nil
                }
            }
        }
    }
}

#Preview("Sheet Version") {
    EditPublicLinkSheet(
        link: PublicLink(
            id: "link1",
            ownerOrgId: 1,
            ownerUserId: "user123",
            name: "Summer Photos",
            scopeKind: "album",
            scopeAlbumId: 42,
            uploadsAlbumId: nil,
            url: "https://example.com/public?k=abc123#vk=xyz789",
            permissions: SharePermissions.commenter.rawValue,
            expiresAt: Date().addingTimeInterval(86400 * 30),
            status: "active",
            coverAssetId: "asset123",
            moderationEnabled: false,
            pendingCount: nil,
            hasPin: true,
            key: "abc123",
            createdAt: Date(),
            updatedAt: Date()
        )
    )
}

#Preview("Navigation Version") {
    NavigationStack {
        EditPublicLinkView(
            link: PublicLink(
                id: "link1",
                ownerOrgId: 1,
                ownerUserId: "user123",
                name: "Summer Photos",
                scopeKind: "album",
                scopeAlbumId: 42,
                uploadsAlbumId: nil,
                url: "https://example.com/public?k=abc123#vk=xyz789",
                permissions: SharePermissions.commenter.rawValue,
                expiresAt: Date().addingTimeInterval(86400 * 30),
                status: "active",
                coverAssetId: "asset123",
                moderationEnabled: false,
                pendingCount: nil,
                hasPin: true,
                key: "abc123",
                createdAt: Date(),
                updatedAt: Date()
            )
        )
    }
}
