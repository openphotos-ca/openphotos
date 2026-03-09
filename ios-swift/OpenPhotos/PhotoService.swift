import Photos
import UIKit
import Combine

class PhotoService: NSObject, ObservableObject {
    static let shared = PhotoService()
    
    @Published var authorizationStatus: PHAuthorizationStatus = .notDetermined
    @Published var photos: [PHAsset] = []
    @Published var isLoading = false
    
    private var cancellables = Set<AnyCancellable>()
    private var fetchResult: PHFetchResult<PHAsset>?
    private var isObserving = false
    
    private override init() {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        super.init()
    }
    
    // MARK: - Permissions
    
    func requestPermissions() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
            DispatchQueue.main.async {
                self?.authorizationStatus = status
                if status == .authorized || status == .limited {
                    self?.prepareFetchAndObservation()
                    self?.loadPhotos()
                }
            }
        }
    }
    
    var hasPermission: Bool {
        authorizationStatus == .authorized || authorizationStatus == .limited
    }
    
    // MARK: - Photo Loading
    
    func loadPhotos() {
        guard hasPermission else {
            print("No photo permission")
            return
        }
        
        // Ensure we are observing changes and have a fetch result
        prepareFetchAndObservation()

        isLoading = true
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            // Ensure we have a tracked fetch result so we can observe changes
            if self.fetchResult == nil {
                let fetchOptions = PHFetchOptions()
                fetchOptions.sortDescriptors = [
                    NSSortDescriptor(key: "creationDate", ascending: false)
                ]
                // No artificial limit; let PhotoKit stream results safely
                fetchOptions.fetchLimit = 0
                self.fetchResult = PHAsset.fetchAssets(with: fetchOptions)
            }
            
            var assets: [PHAsset] = []
            if let fetchResult = self.fetchResult {
                fetchResult.enumerateObjects { asset, _, _ in
                    assets.append(asset)
                }
            }
            
            DispatchQueue.main.async {
                self.photos = assets
                self.isLoading = false
                print("Loaded \(assets.count) photos")
            }
        }
    }
    
    // MARK: - Image Loading
    
    func loadImage(for asset: PHAsset, targetSize: CGSize) -> AnyPublisher<UIImage?, Never> {
        Future { promise in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                promise(.success(image))
            }
        }
        .eraseToAnyPublisher()
    }
    
    func loadThumbnail(for asset: PHAsset) -> AnyPublisher<UIImage?, Never> {
        loadImage(for: asset, targetSize: CGSize(width: 200, height: 200))
    }
    
    // MARK: - Photo Deletion
    
    func deletePhotos(_ assets: [PHAsset]) -> AnyPublisher<Bool, Error> {
        Future { promise in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.deleteAssets(assets as NSArray)
            }) { success, error in
                if let error = error {
                    promise(.failure(error))
                } else {
                    promise(.success(success))
                }
            }
        }
        .eraseToAnyPublisher()
    }
    
    // MARK: - Sync (stub)
    
    /// Stub for future server sync. Invoked when photo library changes are observed.
    func sync() {
        // Trigger sync orchestration
        SyncService.shared.syncOnLibraryChange()
    }

    // MARK: - Change Observation
    
    private func prepareFetchAndObservation() {
        // Initialize fetch result if needed and start observing changes
        if fetchResult == nil {
            let fetchOptions = PHFetchOptions()
            fetchOptions.sortDescriptors = [
                NSSortDescriptor(key: "creationDate", ascending: false)
            ]
            fetchOptions.fetchLimit = 0
            fetchResult = PHAsset.fetchAssets(with: fetchOptions)
        }
        
        if !isObserving {
            PHPhotoLibrary.shared().register(self)
            isObserving = true
        }
    }
    
    deinit {
        if isObserving {
            PHPhotoLibrary.shared().unregisterChangeObserver(self)
        }
    }
}

// MARK: - PHPhotoLibraryChangeObserver

extension PhotoService: PHPhotoLibraryChangeObserver {
    func photoLibraryDidChange(_ changeInstance: PHChange) {
        guard let currentFetch = fetchResult,
              let details = changeInstance.changeDetails(for: currentFetch) else {
            return
        }

        let insertedCount = details.insertedIndexes?.count ?? 0
        let removedCount = details.removedIndexes?.count ?? 0
        let changedCount = details.changedIndexes?.count ?? 0
        let shouldTriggerSync = insertedCount > 0 || removedCount > 0 || details.hasMoves
        
        // Hop to main for UI updates
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.fetchResult = details.fetchResultAfterChanges
            
            // Rebuild the published assets array from the updated fetch result
            var updated: [PHAsset] = []
            self.fetchResult?.enumerateObjects { asset, _, _ in
                updated.append(asset)
            }
            self.photos = updated

            print(
                "[SYNC] photoLibraryDidChange inserted=\(insertedCount) removed=\(removedCount) changed=\(changedCount) moves=\(details.hasMoves ? 1 : 0) trigger_sync=\(shouldTriggerSync ? 1 : 0)"
            )

            // Avoid rerun storms from metadata-only churn (for example iCloud bookkeeping updates).
            if shouldTriggerSync {
                self.sync()
            }
        }
    }
}
