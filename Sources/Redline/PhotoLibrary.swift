#if REDLINE && canImport(UIKit)
import ImageIO
import Photos
import UIKit

/// Reads recent photos and screenshots from Photos with the app's own Photos access.
/// Asking for access needs a usage description in the app's Info.plist, which the kit
/// can't add, so it asks only in apps that already declare one, and only when the person
/// taps to see their photos. Without access, nothing here touches the library.
@MainActor
enum PhotoLibrary {
    /// The longest side of an attached image, in pixels. Enough to read any text on a
    /// screenshot while keeping reports light.
    nonisolated static let maxPixels: CGFloat = 2048

    static var canRead: Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return status == .authorized || status == .limited
    }

    /// True when the app hasn't been asked yet and declares why it uses Photos.
    /// Asking without that declaration would crash the app.
    static var canAsk: Bool {
        PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined
            && Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryUsageDescription") != nil
    }

    /// Shows the system's Photos prompt, with the app's own wording.
    static func requestAccess() async -> Bool {
        guard canAsk else { return canRead }
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
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

    /// The newest photos and screenshots, newest first. Loads no images.
    static func newestPhotos(limit: Int) -> [PHAsset] {
        guard canRead else { return [] }
        let options = PHFetchOptions()
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
        let image: UIImage? = await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: pixels, height: pixels),
                contentMode: fill ? .aspectFill : .aspectFit,
                options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
        // Decoded here, off the main thread, so drawing it later never stalls an animation.
        return await image?.byPreparingForDisplay() ?? image
    }

    /// An image from the system photo picker, decoded no bigger than `maxPixels`
    /// and turned upright. Slow for a large photo, so it's never called on the main thread.
    nonisolated static func downscaled(_ data: Data) -> UIImage? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}
#endif
