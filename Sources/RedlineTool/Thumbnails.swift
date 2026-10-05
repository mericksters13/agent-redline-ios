#if os(macOS)
import AppKit
import SwiftUI

/// Snapshots decoded at the size they're shown, off the main actor, kept in a bounded cache.
enum Thumbnails {
    private static let queue = DispatchQueue(label: "Redline.panel.thumbnails", qos: .userInitiated)
    /// Keeps the panel's rows and a few more, evicting on its own.
    ///
    /// Thread safety: NSCache is thread-safe, but the SDK doesn't mark it Sendable.
    nonisolated(unsafe) private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 60
        return cache
    }()

    /// The snapshot at `url`, no more than `maxPixels` on its longer side.
    ///
    /// Runs off the main actor.
    @concurrent
    static func load(_ url: URL, maxPixels: Int) async -> NSImage? {
        let key = "\(maxPixels):\(url.path)"
        if let image = cache.object(forKey: key as NSString) { return image }
        return await withCheckedContinuation { continuation in
            queue.async {
                let image = thumbnail(url, maxPixels: maxPixels).map {
                    NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
                }
                if let image { cache.setObject(image, forKey: key as NSString) }
                continuation.resume(returning: image)
            }
        }
    }

    /// Decodes the snapshot at `url` straight to `maxPixels`, upright, without keeping the full-size
    /// image around.
    static func thumbnail(_ url: URL, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            ] as CFDictionary
        )
    }
}
#endif
