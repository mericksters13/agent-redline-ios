#if REDLINE
import CoreGraphics
import Foundation

/// Tells whether two captures of a screen look the same, by comparing grayscale copies of them.
///
/// Whole captures are compared small: small enough to ignore a ticking clock or a blinking cursor,
/// large enough to notice a scroll, new data or another screen. One element is compared in detail,
/// because a note belongs to the state its element was in.
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
    static func difference(_ a: CGImage, rows rowsA: Range<Int>? = nil, _ b: CGImage, rows rowsB: Range<Int>? = nil)
        -> Double
    {
        guard let first = crop(a, rows: rowsA), let second = crop(b, rows: rowsB) else { return 1 }
        let height = max(1, Int((Double(first.height) / Double(first.width) * Double(width)).rounded()))
        guard let x = gray(first, width: width, height: height), let y = gray(second, width: width, height: height)
        else { return 1 }
        let differing = zip(x, y).count { abs(Int($0) - Int($1)) > tolerance }
        return Double(differing) / Double(x.count)
    }

    /// How many of an element's pixels differ between two captures. `areaA` and `areaB` are the
    /// element's frame in each capture, in pixels.
    ///
    /// Unlike whole captures, an element is compared in detail, at its own pixels: a segment switch,
    /// a redrawn chart or a changed label inside a card changes only a few percent of a small copy,
    /// but hundreds of pixels here. A pixel differs when its gray level is more than
    /// `elementTolerance` outside the range of the 3 by 3 pixels around the same place in the other
    /// capture, both ways. An edge drawn a fraction of a pixel away only changes how it's smoothed,
    /// which stays inside that range; a shrinking copy would blur such edges into differences, so
    /// only an element wider than `elementWidth` is shrunk. An element that changed size differs in
    /// every pixel.
    ///
    /// Counting stops once it passes `limit`.
    static func differingPixels(
        _ a: CGImage,
        in areaA: CGRect,
        _ b: CGImage,
        in areaB: CGRect,
        upTo limit: Int = .max
    ) -> Int {
        let boundsA = CGRect(x: 0, y: 0, width: a.width, height: a.height)
        let boundsB = CGRect(x: 0, y: 0, width: b.width, height: b.height)
        let rectA = areaA.integral.intersection(boundsA)
        let rectB = areaB.integral.intersection(boundsB)
        let all = max(Int(rectA.width * rectA.height), Int(rectB.width * rectB.height), 1)
        guard rectA.size == rectB.size, let first = a.cropping(to: rectA), let second = b.cropping(to: rectB) else {
            return all
        }
        let width = min(elementWidth, first.width)
        let height = max(1, Int((Double(first.height) * Double(width) / Double(first.width)).rounded()))
        guard let x = gray(first, width: width, height: height), let y = gray(second, width: width, height: height)
        else { return all }
        return countDiffering(x, y, width: width, limit: limit)
    }

    /// Up to this many differing pixels, an element looks identical in two captures.
    ///
    /// A few stray pixels, nothing a person would see. One changed digit in a 17 pt label is about
    /// 35.
    static let sameElementPixels = 8

    /// The widest an element is compared at, in pixels.
    ///
    /// Wider elements, which only an iPad has, are shrunk to it.
    private static let elementWidth = 1024
    /// How far outside its neighbors' range a gray level must be to count as a difference inside an
    /// element.
    ///
    /// Low enough that a dimmed backdrop over a dark card counts.
    private static let elementTolerance = 10

    /// The pixels of `x` outside the range of their neighbors in `y`, or the other way around,
    /// counted until there are more than `limit`.
    ///
    /// A pixel within `elementTolerance` of the same pixel in the other image is inside that range,
    /// so only rows that differ are looked at closely. Identical renders take one quick pass, which
    /// matters because the kit runs in Debug builds, where pixel loops are slow.
    private static func countDiffering(_ x: [UInt8], _ y: [UInt8], width: Int, limit: Int) -> Int {
        let height = x.count / width
        let tolerance = elementTolerance
        return x.withUnsafeBufferPointer { first -> Int in
            y.withUnsafeBufferPointer { second -> Int in
                guard let first = first.baseAddress, let second = second.baseAddress else { return 0 }
                // Whether `value` is outside the gray range of the 3 by 3 pixels around a place in `image`.
                func isOutside(_ value: Int, atRow row: Int, column: Int, in image: UnsafePointer<UInt8>) -> Bool {
                    var darkest = 255
                    var lightest = 0
                    for neighborRow in max(row - 1, 0)...min(row + 1, height - 1) {
                        for neighborColumn in max(column - 1, 0)...min(column + 1, width - 1) {
                            let gray = Int(image[neighborRow * width + neighborColumn])
                            if gray < darkest { darkest = gray }
                            if gray > lightest { lightest = gray }
                        }
                    }
                    return value < darkest - tolerance || value > lightest + tolerance
                }
                var differing = 0
                for row in 0..<height where memcmp(first + row * width, second + row * width, width) != 0 {
                    for column in 0..<width {
                        let a = Int(first[row * width + column])
                        let b = Int(second[row * width + column])
                        guard abs(a - b) > tolerance,
                            isOutside(a, atRow: row, column: column, in: second)
                                || isOutside(b, atRow: row, column: column, in: first)
                        else { continue }
                        differing += 1
                        if differing > limit { return differing }
                    }
                }
                return differing
            }
        }
    }

    private static func crop(_ image: CGImage, rows: Range<Int>?) -> CGImage? {
        guard let rows else { return image }
        let clamped = rows.clamped(to: 0..<image.height)
        guard !clamped.isEmpty else { return nil }
        return image.cropping(to: CGRect(x: 0, y: clamped.lowerBound, width: image.width, height: clamped.count))
    }

    private static func gray(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                )
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }
}
#endif
