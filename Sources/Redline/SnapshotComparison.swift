#if REDLINE
import Accelerate
import CoreGraphics
import Foundation

/// Tells whether two captures of a screen look the same.
///
/// Whole captures are compared as small grayscale copies: small enough to ignore a ticking clock or
/// a blinking cursor, large enough to notice a scroll, new data or another screen. One element is
/// compared in detail and in color, because a note belongs to the state its element was in.
enum SnapshotComparison {
    /// Below this share of differing pixels, two whole captures count as the same snapshot.
    static let sameSnapshot = 0.02
    /// Below this, the stretch two scrolled captures share counts as the same content.
    static let sameOverlap = 0.05

    private static let width = 48
    /// How far apart two gray levels must be to count as a difference.
    private static let tolerance = 24

    /// The share of pixels that differ noticeably, from 0 (identical) to 1.
    /// `rowsA` and `rowsB` pick the rows to compare, in pixels; whole snapshots by default.
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
    /// element's frame in each capture, in pixels, and `ignored` are parts of it to leave out, such
    /// as a spinner, in pixels from its top left corner.
    ///
    /// Unlike whole captures, an element is compared in detail, at its own pixels and in color: a
    /// segment switch, a redrawn chart, a changed label or a new tint inside a card changes only a
    /// few percent of a small gray copy, but hundreds of pixels here. A pixel differs when its red,
    /// green or blue level is more than `elementTolerance` outside the range of the 3 by 3 pixels
    /// around the same place in the other capture, both ways. An edge drawn a fraction of a pixel
    /// away only changes how it's smoothed, which stays inside that range; a shrinking copy would
    /// blur such edges into differences, so only an element wider than `elementWidth` is shrunk.
    ///
    /// Counting stops once it passes `limit`.
    /// - Returns: The count, or `Int.max` when the element changed as a whole or can't be compared:
    ///   it changed size, it lies outside a capture, or it got evenly darker or lighter, like a dark,
    ///   plain card under a light dimmed backdrop, which moves no pixel past the tolerance.
    static func differingPixels(
        _ a: CGImage,
        in areaA: CGRect,
        _ b: CGImage,
        in areaB: CGRect,
        ignoring ignored: [CGRect] = [],
        upTo limit: Int = .max
    ) -> Int {
        let wholeA = areaA.integral
        let wholeB = areaB.integral
        let rectA = wholeA.intersection(CGRect(x: 0, y: 0, width: a.width, height: a.height))
        let rectB = wholeB.intersection(CGRect(x: 0, y: 0, width: b.width, height: b.height))
        // Where the element runs off a capture, only the same part of it is compared.
        let cutA = CGPoint(x: rectA.minX - wholeA.minX, y: rectA.minY - wholeA.minY)
        guard !rectA.isNull, !rectA.isEmpty, !rectB.isNull, rectA.size == rectB.size,
            cutA == CGPoint(x: rectB.minX - wholeB.minX, y: rectB.minY - wholeB.minY),
            let first = a.cropping(to: rectA), let second = b.cropping(to: rectB)
        else { return .max }
        let width = min(elementWidth, first.width)
        let height = max(1, Int((Double(first.height) * Double(width) / Double(first.width)).rounded()))
        let scale = CGFloat(width) / CGFloat(first.width)
        // In the copies' own coordinates, which count rows from the bottom.
        let masks = ignored.map { part in
            let rect = part.offsetBy(dx: -cutA.x, dy: -cutA.y).applying(CGAffineTransform(scaleX: scale, y: scale))
            return CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height).integral
        }
        let planeSize = width * height * 4
        // Seven planes: the two copies, the darkest and lightest levels around each pixel of each,
        // and one to work in.
        let memory = UnsafeMutableRawBufferPointer.allocate(byteCount: planeSize * 7, alignment: 16)
        defer { memory.deallocate() }
        guard let start = memory.baseAddress else { return .max }
        func plane(_ index: Int) -> vImage_Buffer {
            vImage_Buffer(
                data: start + index * planeSize,
                height: vImagePixelCount(height),
                width: vImagePixelCount(width),
                rowBytes: width * 4
            )
        }
        var x = plane(0)
        var y = plane(1)
        guard draw(first, into: x, masking: masks), draw(second, into: y, masking: masks) else { return .max }
        if memcmp(x.data, y.data, planeSize) == 0 { return 0 }
        if isEvenlyShifted(&x, &y) { return .max }
        var xRange = (darkest: plane(2), lightest: plane(3))
        var yRange = (darkest: plane(4), lightest: plane(5))
        var scratch = plane(6)
        guard widen(&x, into: &xRange), widen(&y, into: &yRange) else { return .max }
        // A level outside a range changes the range when blended with it: the lighter of the two
        // differs from the range's lightest, or the darker from its darkest. Rows where neither
        // happens are skipped whole.
        var isRowToCheck = [Bool](repeating: false, count: height)
        let flags = vImage_Flags(kvImageNoFlags)
        for (copy, range) in [(x, yRange), (y, xRange)] {
            var copy = copy
            var range = range
            guard
                vImagePremultipliedAlphaBlendLighten_RGBA8888(&copy, &range.lightest, &scratch, flags) == kvImageNoError
            else { return .max }
            markRows(&isRowToCheck, where: scratch, differsFrom: range.lightest)
            guard vImagePremultipliedAlphaBlendDarken_RGBA8888(&copy, &range.darkest, &scratch, flags) == kvImageNoError
            else { return .max }
            markRows(&isRowToCheck, where: scratch, differsFrom: range.darkest)
        }
        return countDiffering(x, y, xRange: xRange, yRange: yRange, rows: isRowToCheck, limit: limit)
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
    /// How far outside its neighbors' range a color level must be to count as a difference inside
    /// an element.
    ///
    /// Low enough that a dimmed backdrop over a dark card with text counts.
    private static let elementTolerance = 10
    /// How far the average of a color level may move before a whole element counts as changed:
    /// enough for a light dim over a dark, plain element, and far more than smoothing moves it.
    private static let evenShift = 3.0

    /// Draws an element's crop into a plane as RGBA, top row first, with the parts to leave out
    /// painted black.
    private static func draw(_ image: CGImage, into plane: vImage_Buffer, masking masks: [CGRect]) -> Bool {
        guard
            let context = CGContext(
                data: plane.data,
                width: Int(plane.width),
                height: Int(plane.height),
                bitsPerComponent: 8,
                bytesPerRow: plane.rowBytes,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return false }
        context.interpolationQuality = .medium
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: Int(plane.width), height: Int(plane.height)))
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(masks)
        return true
    }

    /// The darkest and lightest level of each color around each pixel, over the 3 by 3 pixels
    /// centered on it, moved out by `elementTolerance`.
    private static func widen(
        _ plane: inout vImage_Buffer,
        into range: inout (darkest: vImage_Buffer, lightest: vImage_Buffer)
    )
        -> Bool
    {
        let tolerance = elementTolerance
        let lower = (0..<256).map { Pixel_8(max($0 - tolerance, 0)) }
        let raise = (0..<256).map { Pixel_8(min($0 + tolerance, 255)) }
        let same = (0..<256).map { Pixel_8($0) }
        let flags = vImage_Flags(kvImageNoFlags)
        // The tables go by byte position; the fourth byte is alpha.
        return vImageMin_ARGB8888(&plane, &range.darkest, nil, 0, 0, 3, 3, flags) == kvImageNoError
            && vImageMax_ARGB8888(&plane, &range.lightest, nil, 0, 0, 3, 3, flags) == kvImageNoError
            && vImageTableLookUp_ARGB8888(&range.darkest, &range.darkest, lower, lower, lower, same, flags)
                == kvImageNoError
            && vImageTableLookUp_ARGB8888(&range.lightest, &range.lightest, raise, raise, raise, same, flags)
                == kvImageNoError
    }

    /// Marks the rows where two planes differ.
    private static func markRows(_ rows: inout [Bool], where plane: vImage_Buffer, differsFrom other: vImage_Buffer) {
        for row in rows.indices where !rows[row] {
            rows[row] =
                memcmp(plane.data + row * plane.rowBytes, other.data + row * other.rowBytes, plane.rowBytes) != 0
        }
    }

    /// The pixels of `x` outside `yRange`, or of `y` outside `xRange`, in the rows to check,
    /// counted until there are more than `limit`.
    private static func countDiffering(
        _ x: vImage_Buffer,
        _ y: vImage_Buffer,
        xRange: (darkest: vImage_Buffer, lightest: vImage_Buffer),
        yRange: (darkest: vImage_Buffer, lightest: vImage_Buffer),
        rows: [Bool],
        limit: Int
    ) -> Int {
        let first = x.data.assumingMemoryBound(to: UInt8.self)
        let second = y.data.assumingMemoryBound(to: UInt8.self)
        let firstDarkest = xRange.darkest.data.assumingMemoryBound(to: UInt8.self)
        let firstLightest = xRange.lightest.data.assumingMemoryBound(to: UInt8.self)
        let secondDarkest = yRange.darkest.data.assumingMemoryBound(to: UInt8.self)
        let secondLightest = yRange.lightest.data.assumingMemoryBound(to: UInt8.self)
        var differing = 0
        for row in rows.indices where rows[row] {
            for pixel in stride(from: row * x.rowBytes, to: (row + 1) * x.rowBytes, by: 4) {
                // Red, green and blue; the fourth byte is alpha.
                for channel in pixel..<(pixel + 3)
                where first[channel] > secondLightest[channel] || first[channel] < secondDarkest[channel]
                    || second[channel] > firstLightest[channel] || second[channel] < firstDarkest[channel]
                {
                    differing += 1
                    if differing > limit { return differing }
                    break
                }
            }
        }
        return differing
    }

    /// Whether the average red, green or blue level moved by more than `evenShift`.
    private static func isEvenlyShifted(_ x: inout vImage_Buffer, _ y: inout vImage_Buffer) -> Bool {
        guard let first = averageLevels(&x), let second = averageLevels(&y) else { return true }
        return zip(first, second).prefix(3).contains { abs($0 - $1) > evenShift }
    }

    /// The average level of each of the four channels, from Accelerate's histograms.
    private static func averageLevels(_ plane: inout vImage_Buffer) -> [Double]? {
        // Four histograms of 256 levels, one after the other.
        var counts = [vImagePixelCount](repeating: 0, count: 4 * 256)
        let isDone = counts.withUnsafeMutableBufferPointer { histograms -> Bool in
            guard let start = histograms.baseAddress else { return false }
            var channels: [UnsafeMutablePointer<vImagePixelCount>?] = (0..<4).map { start + $0 * 256 }
            return vImageHistogramCalculation_ARGB8888(&plane, &channels, vImage_Flags(kvImageNoFlags))
                == kvImageNoError
        }
        guard isDone else { return nil }
        let pixelCount = Double(plane.width * plane.height)
        return (0..<4).map { channel in
            var total = 0.0
            for level in 0..<256 { total += Double(level) * Double(counts[channel * 256 + level]) }
            return total / pixelCount
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
