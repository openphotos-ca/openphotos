//
//  ShareFacesRail.swift
//  OpenPhotos
//
//  Horizontal scrolling rail of faces for filtering photos in a share.
//

import SwiftUI

/// Horizontal scrolling faces rail
struct ShareFacesRail: View {
    let faces: [ShareFace]
    let selectedFaceId: String?
    let shareId: String
    let onFaceTap: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(faces) { face in
                    FaceTile(
                        face: face,
                        shareId: shareId,
                        isSelected: selectedFaceId == face.personId
                    )
                    .onTapGesture {
                        onFaceTap(face.personId)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }
}

/// Individual face tile in the rail
struct FaceTile: View {
    let face: ShareFace
    let shareId: String
    let isSelected: Bool

    @State private var thumbnail: UIImage?
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                if let thumbnail = thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 60, height: 60)
                        .clipShape(Circle())
                } else if isLoading {
                    Circle()
                        .fill(Color.gray.opacity(0.2))
                        .frame(width: 60, height: 60)
                        .overlay(ProgressView())
                } else {
                    Circle()
                        .fill(Color.gray.opacity(0.2))
                        .frame(width: 60, height: 60)
                        .overlay(
                            Image(systemName: "person.fill")
                                .foregroundColor(.gray)
                        )
                }

                if isSelected {
                    Circle()
                        .stroke(Color.blue, lineWidth: 3)
                        .frame(width: 60, height: 60)
                }
            }

            Text(face.label)
                .font(.caption2)
                .lineLimit(1)
                .frame(width: 60)

            Text("\(face.count)")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .task {
            await loadThumbnail()
        }
    }

    /// Load face thumbnail
    private func loadThumbnail() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let data = try await ShareService.shared.getShareFaceThumbnail(
                shareId: shareId,
                personId: face.personId
            )

            thumbnail = UIImage(data: data)
        } catch {
            print("Failed to load face thumbnail for \(face.personId): \(error)")
        }
    }
}

#Preview {
    ShareFacesRail(
        faces: [
            ShareFace(personId: "1", displayName: "John Doe", count: 45),
            ShareFace(personId: "2", displayName: "Jane Smith", count: 32),
            ShareFace(personId: "3", displayName: nil, count: 18)
        ],
        selectedFaceId: "1",
        shareId: "share123",
        onFaceTap: { _ in }
    )
    .frame(height: 100)
}
