#if AGENTIC_DEBUGGING && canImport(UIKit)
import ImageIO
import Photos
import UIKit

/// Reads recent screenshots from Photos, only when the app already has Photos access
/// for its own reasons. The kit never asks for it: asking needs a usage description in
/// the host app's Info.plist, and the kit must work with nothing but its one line of setup.
/// Without access, nothing here touches the library, so no prompt can appear.
@MainActor
enum PhotoLibrary {
    /// The longest side of an attached image, in pixels. Enough to read any text on a
    /// screenshot while keeping reports light.
    nonisolated static let maxPixels: CGFloat = 2048

    static var canRead: Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return status == .authorized || status == .limited
    }

    /// The newest screenshots, newest first. Loads no images.
    static func newestScreenshots(limit: Int) -> [PHAsset] {
        guard canRead else { return [] }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "(mediaSubtypes & %d) != 0", PHAssetMediaSubtype.photoScreenshot.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = limit
        var assets: [PHAsset] = []
        PHAsset.fetchAssets(with: .image, options: options).enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    /// The asset's image, no bigger than `pixels` on its longest side. Images only in
    /// iCloud are skipped rather than downloaded.
    static func image(for asset: PHAsset, pixels: CGFloat, fill: Bool = false) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        // One call back, with the final image.
        options.deliveryMode = .highQualityFormat
        options.resizeMode = fill ? .fast : .exact
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: pixels, height: pixels),
                contentMode: fill ? .aspectFill : .aspectFit,
                options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    /// An image from the system photo picker, decoded no bigger than `maxPixels`
    /// and turned upright.
    nonisolated static func downscaled(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}
#endif
