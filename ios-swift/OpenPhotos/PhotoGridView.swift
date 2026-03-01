import SwiftUI
import Photos
import Combine

struct PhotoGridView: View {
    @EnvironmentObject var viewModel: GalleryViewModel
    
    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]
    
    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(viewModel.filteredMedia, id: \.localIdentifier) { photo in
                    PhotoThumbnailView(
                        asset: photo,
                        isSelected: viewModel.selectedPhotos.contains(photo),
                        isSelectionMode: viewModel.isSelectionMode
                    ) {
                        if viewModel.isSelectionMode {
                            viewModel.toggleSelection(for: photo)
                        } else {
                            // In full app, this would navigate to photo detail
                            print("Open photo detail for: \(photo.localIdentifier)")
                        }
                    }
                }
            }
            .padding(.horizontal, 1)
        }
    }
}

struct PhotoThumbnailView: View {
    let asset: PHAsset
    let isSelected: Bool
    let isSelectionMode: Bool
    let onTap: () -> Void
    
    @State private var image: UIImage?
    @State private var isLoading = true
    @State private var cancellables = Set<AnyCancellable>()
    
    private let photoService = PhotoService.shared
    
    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.gray.opacity(0.2))
                .aspectRatio(1, contentMode: .fit)
            
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipped()
            } else if isLoading {
                ProgressView()
                    .scaleEffect(0.8)
            }
            
            // Selection overlay
            if isSelectionMode {
                VStack {
                    HStack {
                        Spacer()
                        
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.8))
                                .frame(width: 24, height: 24)
                            
                            if isSelected {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.blue)
                                    .font(.system(size: 20))
                            } else {
                                Circle()
                                    .stroke(Color.gray, lineWidth: 2)
                                    .frame(width: 18, height: 18)
                            }
                        }
                    }
                    
                    Spacer()
                }
                .padding(8)
            }
            
            // Video indicator
            if asset.mediaType == .video {
                VStack {
                    Spacer()
                    
                    HStack {
                        Image(systemName: "play.fill")
                            .foregroundColor(.white)
                            .font(.caption)
                        
                        Text(formatDuration(asset.duration))
                            .foregroundColor(.white)
                            .font(.caption)
                            .fontWeight(.medium)
                        
                        Spacer()
                    }
                    .padding(4)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(4)
                }
                .padding(4)
            }
        }
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 3)
        )
        .onTapGesture {
            onTap()
        }
        .onAppear {
            loadThumbnail()
        }
    }
    
    private func loadThumbnail() {
        photoService.loadThumbnail(for: asset)
            .receive(on: DispatchQueue.main)
            .sink { loadedImage in
                self.image = loadedImage
                self.isLoading = false
            }
            .store(in: &cancellables)
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

#Preview {
    PhotoGridView()
        .environmentObject(GalleryViewModel())
}
