import SwiftUI
import Photos
import UniformTypeIdentifiers
import ImageIO
import AVFoundation

// Transferable wrapper for PHAsset that exports a JPEG image on demand.
struct SharedAsset: Transferable {
    let asset: PHAsset

    static var transferRepresentation: some TransferRepresentation {
        // Prefer HEIC for images when available; fall back to JPEG.
        DataRepresentation(exportedContentType: .heic) { shared in
            guard shared.asset.mediaType == .image else {
                // Not an image; this representation doesn't apply
                throw NSError(domain: "Share", code: -2, userInfo: nil)
            }
            if let data = exportImageData(shared.asset, preferredType: .heic) {
                return data
            }
            throw NSError(domain: "Share", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to export HEIC image"])
        }
        DataRepresentation(exportedContentType: .jpeg) { shared in
            guard shared.asset.mediaType == .image else {
                throw NSError(domain: "Share", code: -2, userInfo: nil)
            }
            if let data = exportImageData(shared.asset, preferredType: .jpeg) {
                return data
            }
            throw NSError(domain: "Share", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to export JPEG image"])
        }
        // Provide a movie file for videos by exporting to a temp MP4.
        FileRepresentation(exportedContentType: .mpeg4Movie) { shared in
            guard shared.asset.mediaType == .video else {
                throw NSError(domain: "Share", code: -3, userInfo: nil)
            }
            let url = try exportVideoToTempURL(shared.asset)
            return .init(url)
        }
    }

    private static func exportImageData(_ asset: PHAsset, preferredType: UTType) -> Data? {
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        let targetSize = CGSize(width: 2048, height: 2048)

        var outImage: UIImage?
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFit,
            options: options
        ) { image, _ in
            outImage = image
        }
        guard let image = outImage, let cgImage = image.cgImage else {
            return nil
        }
        if preferredType == .jpeg {
            return image.jpegData(compressionQuality: 0.9)
        }
        // Attempt HEIC via ImageIO
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, preferredType.identifier as CFString, 1, nil) else {
            return nil
        }
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        CGImageDestinationAddImage(dest, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    private static func exportVideoToTempURL(_ asset: PHAsset) throws -> URL {
        let semaphore = DispatchSemaphore(value: 0)
        var avAssetOut: AVAsset?
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
            avAssetOut = avAsset
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 30)
        guard let avAsset = avAssetOut else {
            throw NSError(domain: "Share", code: -10, userInfo: [NSLocalizedDescriptionKey: "Failed to obtain AVAsset"])
        }
        // Export to MP4 in a temporary file
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent("share_\(UUID().uuidString).mp4")
        guard let export = AVAssetExportSession(asset: avAsset, presetName: AVAssetExportPresetHighestQuality) else {
            throw NSError(domain: "Share", code: -11, userInfo: [NSLocalizedDescriptionKey: "Export not supported"])
        }
        export.outputFileType = .mp4
        export.outputURL = tmpURL
        let done = DispatchSemaphore(value: 0)
        export.exportAsynchronously {
            done.signal()
        }
        _ = done.wait(timeout: .now() + 120)
        guard export.status == .completed else {
            throw NSError(domain: "Share", code: -12, userInfo: [NSLocalizedDescriptionKey: "Export failed: \(export.error?.localizedDescription ?? "unknown")"])
        }
        return tmpURL
    }
}
