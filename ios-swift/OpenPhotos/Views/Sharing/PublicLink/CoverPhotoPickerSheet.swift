//
//  CoverPhotoPickerSheet.swift
//  OpenPhotos
//
//  Sheet for selecting a cover photo from existing library photos.
//  Based on how the web client works - picks from existing photos only.
//

import SwiftUI

/// Photo model for the picker
struct PickerPhoto: Identifiable, Codable {
    let id: String
    let asset_id: String
    let filename: String?
    let created_at: Int?
    let is_video: Bool?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.asset_id = try container.decode(String.self, forKey: .asset_id)
        self.id = asset_id  // Use asset_id as the ID
        self.filename = try container.decodeIfPresent(String.self, forKey: .filename)
        self.created_at = try container.decodeIfPresent(Int.self, forKey: .created_at)
        self.is_video = try container.decodeIfPresent(Bool.self, forKey: .is_video)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(asset_id, forKey: .asset_id)
        try container.encodeIfPresent(filename, forKey: .filename)
        try container.encodeIfPresent(created_at, forKey: .created_at)
        try container.encodeIfPresent(is_video, forKey: .is_video)
    }

    enum CodingKeys: String, CodingKey {
        case asset_id
        case filename
        case created_at
        case is_video
    }
}

/// Sheet for selecting a cover photo from existing library photos
struct CoverPhotoPickerSheet: View {
    @Binding var isPresented: Bool
    let onSelection: (String) -> Void  // Returns asset ID

    @State private var photos: [PickerPhoto] = []
    @State private var selectedAssetId: String? = nil
    @State private var isLoading = false
    @State private var error: String? = nil
    @State private var page = 1
    @State private var hasMore = true

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Group {
                if isLoading && photos.isEmpty {
                    ProgressView("Loading photos...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = error {
                    VStack(spacing: 16) {
                        Text("Failed to load photos")
                            .font(.headline)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Button("Retry") {
                            Task {
                                await loadPhotos()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                } else {
                    ScrollView {
                        LazyVGrid(columns: [
                            GridItem(.adaptive(minimum: 100, maximum: 150), spacing: 4)
                        ], spacing: 4) {
                            ForEach(photos) { photo in
                                CoverPhotoThumbnailView(
                                    photo: photo,
                                    isSelected: selectedAssetId == photo.asset_id
                                ) {
                                    selectedAssetId = photo.asset_id
                                }
                                .onAppear {
                                    // Load more when reaching the end
                                    if photo.id == photos.last?.id && hasMore && !isLoading {
                                        Task {
                                            await loadMorePhotos()
                                        }
                                    }
                                }
                            }
                        }
                        .padding(4)

                        if isLoading && !photos.isEmpty {
                            ProgressView()
                                .padding()
                        }
                    }
                }
            }
            .navigationTitle("Choose Cover Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Select") {
                        if let assetId = selectedAssetId {
                            onSelection(assetId)
                            dismiss()
                        }
                    }
                    .disabled(selectedAssetId == nil)
                    .fontWeight(.semibold)
                }
            }
        }
        .onAppear {
            Task {
                await loadPhotos()
            }
        }
    }

    private func loadPhotos() async {
        isLoading = true
        error = nil
        page = 1
        photos = []

        do {
            let client = AuthorizedHTTPClient.shared
            let url = client.buildURL(path: "/api/photos", queryItems: [
                URLQueryItem(name: "page", value: "1"),
                URLQueryItem(name: "limit", value: "60"),
                URLQueryItem(name: "sort_by", value: "created_at"),
                URLQueryItem(name: "sort_order", value: "desc")
            ])

            var request = URLRequest(url: url)
            request.httpMethod = "GET"

            let (data, response) = try await client.request(request)

            guard (200..<300).contains(response.statusCode) else {
                throw NSError(domain: "CoverPicker", code: response.statusCode,
                            userInfo: [NSLocalizedDescriptionKey: "Failed to load photos"])
            }

            struct PhotosResponse: Codable {
                let photos: [PickerPhoto]
                let has_more: Bool?
            }

            let decoder = JSONDecoder()
            let photosResponse = try decoder.decode(PhotosResponse.self, from: data)

            // Filter out videos
            photos = photosResponse.photos.filter { !($0.is_video ?? false) }
            hasMore = photosResponse.has_more ?? false

            isLoading = false
        } catch {
            self.error = error.localizedDescription
            isLoading = false
        }
    }

    private func loadMorePhotos() async {
        guard !isLoading else { return }

        isLoading = true
        page += 1

        do {
            let client = AuthorizedHTTPClient.shared
            let url = client.buildURL(path: "/api/photos", queryItems: [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "limit", value: "60"),
                URLQueryItem(name: "sort_by", value: "created_at"),
                URLQueryItem(name: "sort_order", value: "desc")
            ])

            var request = URLRequest(url: url)
            request.httpMethod = "GET"

            let (data, response) = try await client.request(request)

            guard (200..<300).contains(response.statusCode) else {
                throw NSError(domain: "CoverPicker", code: response.statusCode,
                            userInfo: [NSLocalizedDescriptionKey: "Failed to load more photos"])
            }

            struct PhotosResponse: Codable {
                let photos: [PickerPhoto]
                let has_more: Bool?
            }

            let decoder = JSONDecoder()
            let photosResponse = try decoder.decode(PhotosResponse.self, from: data)

            // Filter out videos and append
            let newPhotos = photosResponse.photos.filter { !($0.is_video ?? false) }
            photos.append(contentsOf: newPhotos)
            hasMore = photosResponse.has_more ?? false

            isLoading = false
        } catch {
            // Don't show error for pagination failures
            isLoading = false
            hasMore = false
        }
    }
}

/// Individual photo thumbnail in the picker
struct CoverPhotoThumbnailView: View {
    let photo: PickerPhoto
    let isSelected: Bool
    let onTap: () -> Void

    @State private var thumbnailImage: UIImage? = nil
    @State private var isLoadingThumbnail = false

    var body: some View {
        Button(action: onTap) {
            ZStack {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .aspectRatio(1, contentMode: .fit)

                if let image = thumbnailImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                        .aspectRatio(1, contentMode: .fill)
                        .clipped()
                } else if isLoadingThumbnail {
                    ProgressView()
                        .scaleEffect(0.5)
                } else {
                    Image(systemName: "photo")
                        .foregroundColor(.gray)
                }

                // Selection indicator
                if isSelected {
                    ZStack {
                        Rectangle()
                            .stroke(Color.accentColor, lineWidth: 3)

                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.accentColor)
                                    .background(Circle().fill(Color.white))
                                    .padding(4)
                            }
                        }
                    }
                }
            }
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .onAppear {
            loadThumbnail()
        }
    }

    private func loadThumbnail() {
        guard thumbnailImage == nil && !isLoadingThumbnail else { return }

        isLoadingThumbnail = true

        Task {
            do {
                let client = AuthorizedHTTPClient.shared
                let url = client.buildURL(path: "/api/thumbnails/\(photo.asset_id)")
                var request = URLRequest(url: url)
                request.httpMethod = "GET"

                let (data, response) = try await client.request(request)

                if (200..<300).contains(response.statusCode),
                   let image = UIImage(data: data) {
                    await MainActor.run {
                        self.thumbnailImage = image
                        self.isLoadingThumbnail = false
                    }
                } else {
                    await MainActor.run {
                        self.isLoadingThumbnail = false
                    }
                }
            } catch {
                await MainActor.run {
                    self.isLoadingThumbnail = false
                }
            }
        }
    }
}

// MARK: - Navigation-compatible Cover Photo Picker

/// View for selecting a cover photo, designed to be pushed via NavigationStack
/// Use this instead of CoverPhotoPickerSheet when presenting from within another sheet
struct CoverPhotoPickerView: View {
    let onSelection: (String) -> Void  // Returns asset ID
    let onCancel: () -> Void

    @State private var photos: [PickerPhoto] = []
    @State private var selectedAssetId: String? = nil
    @State private var isLoading = false
    @State private var error: String? = nil
    @State private var page = 1
    @State private var hasMore = true

    var body: some View {
        Group {
            if isLoading && photos.isEmpty {
                ProgressView("Loading photos...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = error {
                VStack(spacing: 16) {
                    Text("Failed to load photos")
                        .font(.headline)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button("Retry") {
                        Task {
                            await loadPhotos()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            } else {
                ScrollView {
                    LazyVGrid(columns: [
                        GridItem(.adaptive(minimum: 100, maximum: 150), spacing: 4)
                    ], spacing: 4) {
                        ForEach(photos) { photo in
                            CoverPhotoThumbnailView(
                                photo: photo,
                                isSelected: selectedAssetId == photo.asset_id
                            ) {
                                selectedAssetId = photo.asset_id
                            }
                            .onAppear {
                                // Load more when reaching the end
                                if photo.id == photos.last?.id && hasMore && !isLoading {
                                    Task {
                                        await loadMorePhotos()
                                    }
                                }
                            }
                        }
                    }
                    .padding(4)

                    if isLoading && !photos.isEmpty {
                        ProgressView()
                            .padding()
                    }
                }
            }
        }
        .navigationTitle("Choose Cover Photo")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Cancel") {
                    onCancel()
                }
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Select") {
                    if let assetId = selectedAssetId {
                        onSelection(assetId)
                    }
                }
                .disabled(selectedAssetId == nil)
                .fontWeight(.semibold)
            }
        }
        .onAppear {
            Task {
                await loadPhotos()
            }
        }
    }

    private func loadPhotos() async {
        isLoading = true
        error = nil
        page = 1
        photos = []

        do {
            let client = AuthorizedHTTPClient.shared
            let url = client.buildURL(path: "/api/photos", queryItems: [
                URLQueryItem(name: "page", value: "1"),
                URLQueryItem(name: "limit", value: "60"),
                URLQueryItem(name: "sort_by", value: "created_at"),
                URLQueryItem(name: "sort_order", value: "desc")
            ])

            var request = URLRequest(url: url)
            request.httpMethod = "GET"

            let (data, response) = try await client.request(request)

            guard (200..<300).contains(response.statusCode) else {
                throw NSError(domain: "CoverPicker", code: response.statusCode,
                            userInfo: [NSLocalizedDescriptionKey: "Failed to load photos"])
            }

            struct PhotosResponse: Codable {
                let photos: [PickerPhoto]
                let has_more: Bool?
            }

            let decoder = JSONDecoder()
            let photosResponse = try decoder.decode(PhotosResponse.self, from: data)

            // Filter out videos
            photos = photosResponse.photos.filter { !($0.is_video ?? false) }
            hasMore = photosResponse.has_more ?? false

            isLoading = false
        } catch {
            self.error = error.localizedDescription
            isLoading = false
        }
    }

    private func loadMorePhotos() async {
        guard !isLoading else { return }

        isLoading = true
        page += 1

        do {
            let client = AuthorizedHTTPClient.shared
            let url = client.buildURL(path: "/api/photos", queryItems: [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "limit", value: "60"),
                URLQueryItem(name: "sort_by", value: "created_at"),
                URLQueryItem(name: "sort_order", value: "desc")
            ])

            var request = URLRequest(url: url)
            request.httpMethod = "GET"

            let (data, response) = try await client.request(request)

            guard (200..<300).contains(response.statusCode) else {
                throw NSError(domain: "CoverPicker", code: response.statusCode,
                            userInfo: [NSLocalizedDescriptionKey: "Failed to load more photos"])
            }

            struct PhotosResponse: Codable {
                let photos: [PickerPhoto]
                let has_more: Bool?
            }

            let decoder = JSONDecoder()
            let photosResponse = try decoder.decode(PhotosResponse.self, from: data)

            // Filter out videos and append
            let newPhotos = photosResponse.photos.filter { !($0.is_video ?? false) }
            photos.append(contentsOf: newPhotos)
            hasMore = photosResponse.has_more ?? false

            isLoading = false
        } catch {
            // Don't show error for pagination failures
            isLoading = false
            hasMore = false
        }
    }
}

#Preview("Sheet Version") {
    CoverPhotoPickerSheet(isPresented: .constant(true)) { assetId in
        print("Selected asset: \(assetId)")
    }
}

#Preview("Navigation Version") {
    NavigationStack {
        CoverPhotoPickerView(
            onSelection: { assetId in
                print("Selected asset: \(assetId)")
            },
            onCancel: {
                print("Cancelled")
            }
        )
    }
}