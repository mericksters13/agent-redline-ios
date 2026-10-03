#if AGENTIC_DEBUGGING
import CoreGraphics

/// Tells whether two captures of a screen look the same, by comparing small grayscale
/// versions of them. Small enough to ignore a ticking clock or a blinking cursor, large
/// enough to notice a scroll, new data or another screen.
enum PictureComparison {
    /// Below this share of differing pixels, two whole captures count as the same picture.
    static let samePicture = 0.02
    /// Below this, the stretch two scrolled captures share counts as the same content.
    static let sameOverlap = 0.05

    private static let width = 48
    /// How far apart two gray levels must be to count as a difference.
    private static let tolerance = 24

    /// The share of pixels that differ noticeably, from 0 (identical) to 1.
    /// `rowsA` and `rowsB` pick the rows to compare, in pixels; whole pictures by default.
    static func difference(_ a: CGImage, rows rowsA: Range<Int>? = nil, _ b: CGImage, rows rowsB: Range<Int>? = nil) -> Double {
        guard let first = crop(a, rows: rowsA), let second = crop(b, rows: rowsB) else { return 1 }
        let height = max(1, Int((Double(first.height) / Double(first.width) * Double(width)).rounded()))
        guard let x = gray(first, height: height), let y = gray(second, height: height) else { return 1 }
        let differing = zip(x, y).count { abs(Int($0) - Int($1)) > tolerance }
        return Double(differing) / Double(x.count)
    }

    private static func crop(_ image: CGImage, rows: Range<Int>?) -> CGImage? {
        guard let rows else { return image }
        let clamped = rows.clamped(to: 0..<image.height)
        guard !clamped.isEmpty else { return nil }
        return image.cropping(to: CGRect(x: 0, y: clamped.lowerBound, width: image.width, height: clamped.count))
    }

    private static func gray(_ image: CGImage, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }
}
#endif
