#if AGENTIC_DEBUGGING
import Foundation

/// The screen's main vertical scroll view at the moment of a capture.
struct ScrollState: Codable, Equatable, Sendable {
    /// Its frame on screen, in points.
    var frame: CGRect
    var offsetY: CGFloat
    /// How much of its top and bottom sits under bars.
    var insetTop: CGFloat
    var insetBottom: CGFloat
    var contentHeight: CGFloat

    /// Where a point on screen sits in the scrolled content.
    func contentY(ofScreenY y: CGFloat) -> CGFloat { y - frame.minY + offsetY }

    /// Where a point in the scrolled content shows on screen.
    func screenY(ofContentY y: CGFloat) -> CGFloat { y - offsetY + frame.minY }

    /// The same scroll view as in another capture: same place and size on screen.
    func isSameView(as other: ScrollState) -> Bool {
        abs(frame.minX - other.frame.minX) < 2 && abs(frame.minY - other.frame.minY) < 2
            && abs(frame.width - other.frame.width) < 2 && abs(frame.height - other.frame.height) < 2
    }
}

/// One picture of a screen, kept without outlines. Outlines are drawn when the picture is
/// shown or sent, so every note on the screen can share it.
struct Capture: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var file: String
    /// The screen's size, in points.
    var size: CGSize
    var scroll: ScrollState?
    /// What was on screen, to find notes again and to tell bars from scrolled content.
    var elements: [ElementSnapshot]
    /// Captures in the same group are stitched into one picture. A new group starts when
    /// the screen's content changed rather than scrolled.
    var group: Int
}

/// Every capture of one screen in the draft, oldest first.
struct ScreenRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var info: ScreenInfo
    var captures: [Capture]

    /// The captures of each group, oldest group first.
    var groups: [[Capture]] {
        Dictionary(grouping: captures, by: \.group).sorted { $0.key < $1.key }.map(\.value)
    }
}

/// What a new note's capture does to its screen's picture.
enum CaptureMerge {
    enum Decision: Equatable {
        /// Nothing changed: the note uses the screen's existing picture.
        case reuse(UUID)
        /// The screen scrolled: the new capture is stitched into the screen's picture.
        case stitch
        /// The content changed: the new capture becomes the screen's picture, and earlier
        /// notes move onto it when their elements can be found there.
        case replace
    }

    /// - Parameters:
    ///   - picturesMatch: the two pictures look the same.
    ///   - overlapMatches: where a scrolled capture overlaps the previous one, the content
    ///     looks the same; nil when they don't overlap enough to tell.
    static func decide(previous: Capture, new: Capture, picturesMatch: Bool, overlapMatches: Bool?) -> Decision {
        guard previous.size == new.size else { return .replace }
        if let before = previous.scroll, let after = new.scroll, before.isSameView(as: after),
           abs(before.offsetY - after.offsetY) > 2 {
            return overlapMatches == false ? .replace : .stitch
        }
        return picturesMatch ? .reuse(previous.id) : .replace
    }
}

/// How one picture of a screen is put together from its captures, in screen points.
struct ImagePlan: Equatable, Sendable {
    /// Rows copied from a capture into the picture.
    struct Segment: Equatable, Sendable {
        var capture: UUID
        var sourceMinY: CGFloat
        var height: CGFloat
        var destinationY: CGFloat
    }

    /// A stretch of scrolled content and where it starts in the picture.
    struct Run: Equatable, Sendable {
        var contentStart: CGFloat
        var contentEnd: CGFloat
        var destinationY: CGFloat
    }

    var size: CGSize
    var segments: [Segment]
    /// Stretches of the screen scrolled past without a capture.
    var gaps: [CGRect]
    var stitchedFrom: Int
    /// Where content scrolls, in screen points. Nil for a picture of one capture.
    var band: ClosedRange<CGFloat>?
    var runs: [Run]
    /// Where the bottom bars start in the picture.
    var footerY: CGFloat
    var captures: [UUID: Capture]

    /// Where a note made on `capture` sits in this picture.
    func place(_ frame: CGRect, from captureID: UUID) -> CGRect? {
        guard let capture = captures[captureID] else { return nil }
        guard let band, let scroll = capture.scroll else { return frame }
        if frame.midY < band.lowerBound { return frame }
        if frame.midY > band.upperBound {
            return frame.offsetBy(dx: 0, dy: footerY - band.upperBound)
        }
        let content = scroll.contentY(ofScreenY: frame.minY)
        let run = runs.first { content >= $0.contentStart - 0.5 && content <= $0.contentEnd + 0.5 }
            ?? runs.min { abs($0.contentStart - content) < abs($1.contentStart - content) }
        guard let run else { return nil }
        return CGRect(x: frame.minX, y: run.destinationY + content - run.contentStart, width: frame.width, height: frame.height)
    }
}

enum ScreenComposition {
    /// Height of the band that marks content scrolled past without a capture.
    static let gapHeight: CGFloat = 32

    /// Where content scrolls, in screen points: the scroll view without the bars over it.
    /// Bars that float over the content without insets, such as a custom tab bar, are found
    /// as elements that stay put while the content scrolls under them.
    static func band(for captures: [Capture]) -> ClosedRange<CGFloat>? {
        guard let first = captures.first, let scroll = first.scroll else { return nil }
        var top = max(scroll.frame.minY + scroll.insetTop, 0)
        var bottom = min(scroll.frame.maxY - scroll.insetBottom, first.size.height)
        guard bottom > top else { return nil }
        let scrolled = captures.filter { $0.scroll != nil }.sorted { $0.scroll!.offsetY < $1.scroll!.offsetY }
        if let low = scrolled.first, let high = scrolled.last, high.scroll!.offsetY - low.scroll!.offsetY > 10 {
            let middle = (top + bottom) / 2
            for element in high.elements where !element.isContainer {
                let frame = element.frame
                guard frame.height < (bottom - top) * 0.25, frame.maxY > top, frame.minY < bottom,
                      let match = ElementSelection.match(element, in: low.elements),
                      abs(match.frame.minY - frame.minY) < 1.5, abs(match.frame.minX - frame.minX) < 1.5
                else { continue }
                if frame.midY > middle { bottom = min(bottom, frame.minY) } else { top = max(top, frame.maxY) }
            }
        }
        return bottom > top ? top...bottom : nil
    }

    /// The plan for one group of captures: the newest capture whole, or, when the group
    /// scrolled, one tall picture with the top bars once, the scrolled content in between,
    /// newest capture first where they overlap, and the bottom bars once. Bars are often
    /// see-through, so the top ones come from the capture scrolled highest and the bottom
    /// ones from the capture scrolled lowest, where the content behind them matches.
    static func plan(for captures: [Capture]) -> ImagePlan? {
        guard let reference = captures.last else { return nil }
        let byID = Dictionary(captures.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard captures.count > 1, captures.allSatisfy({ $0.scroll != nil }), let band = band(for: captures) else {
            return ImagePlan(
                size: reference.size,
                segments: [.init(capture: reference.id, sourceMinY: 0, height: reference.size.height, destinationY: 0)],
                gaps: [], stitchedFrom: 1, band: nil, runs: [], footerY: reference.size.height,
                captures: [reference.id: reference]
            )
        }

        let topmost = captures.min { $0.scroll!.offsetY < $1.scroll!.offsetY } ?? reference
        let bottommost = captures.max { $0.scroll!.offsetY < $1.scroll!.offsetY } ?? reference
        var segments = [ImagePlan.Segment(capture: topmost.id, sourceMinY: 0, height: band.lowerBound, destinationY: 0)]
        let ranges = captures.map { capture -> (capture: Capture, range: ClosedRange<CGFloat>) in
            let scroll = capture.scroll!
            return (capture, scroll.contentY(ofScreenY: band.lowerBound)...scroll.contentY(ofScreenY: band.upperBound))
        }
        let points = Set(ranges.flatMap { [$0.range.lowerBound, $0.range.upperBound] }).sorted()
        var y = band.lowerBound
        var runs: [ImagePlan.Run] = []
        var gaps: [CGRect] = []
        var lastEnd: CGFloat?
        var pendingGap = false
        for (start, end) in zip(points, points.dropFirst()) where end - start > 0.5 {
            // The newest capture that shows this stretch.
            guard let owner = ranges.last(where: { $0.range.lowerBound <= start + 0.5 && $0.range.upperBound >= end - 0.5 }) else {
                if lastEnd != nil { pendingGap = true }
                continue
            }
            if pendingGap {
                gaps.append(CGRect(x: 0, y: y, width: reference.size.width, height: gapHeight))
                y += gapHeight
                pendingGap = false
            }
            let source = owner.capture.scroll!.screenY(ofContentY: start)
            if let last = segments.last, segments.count > 1, last.capture == owner.capture.id,
               abs(last.sourceMinY + last.height - source) < 0.5, abs(last.destinationY + last.height - y) < 0.5 {
                segments[segments.count - 1].height += end - start
            } else {
                segments.append(.init(capture: owner.capture.id, sourceMinY: source, height: end - start, destinationY: y))
            }
            if let last = runs.last, abs(last.contentEnd - start) < 0.5, abs(last.destinationY + (last.contentEnd - last.contentStart) - y) < 0.5 {
                runs[runs.count - 1].contentEnd = end
            } else {
                runs.append(.init(contentStart: start, contentEnd: end, destinationY: y))
            }
            y += end - start
            lastEnd = end
        }
        let footerY = y
        segments.append(.init(capture: bottommost.id, sourceMinY: band.upperBound, height: reference.size.height - band.upperBound, destinationY: y))
        y += reference.size.height - band.upperBound
        return ImagePlan(
            size: CGSize(width: reference.size.width, height: y),
            segments: segments, gaps: gaps, stitchedFrom: captures.count, band: band, runs: runs,
            footerY: footerY, captures: byID
        )
    }

    /// Where a note made on one capture shows on another capture of the same group, or nil
    /// when it's scrolled out of that capture's view.
    static func position(of frame: CGRect, from source: Capture, on target: Capture, band: ClosedRange<CGFloat>?) -> CGRect? {
        if source.id == target.id { return frame }
        guard let band, let from = source.scroll, let to = target.scroll else { return nil }
        if frame.midY < band.lowerBound || frame.midY > band.upperBound { return frame }
        let y = to.screenY(ofContentY: from.contentY(ofScreenY: frame.minY))
        let moved = CGRect(x: frame.minX, y: y, width: frame.width, height: frame.height)
        return moved.midY >= band.lowerBound && moved.midY <= band.upperBound ? moved : nil
    }

    /// Splits a tall picture into parts no taller than `maxHeight`, so agents that shrink
    /// large images can still read them. Cuts move up to the top of an outline instead of
    /// running through it, when that leaves the part at least half full.
    static func parts(height: CGFloat, maxHeight: CGFloat, keepingWhole outlines: [CGRect]) -> [ClosedRange<CGFloat>] {
        guard height > maxHeight * 1.1 else { return [0...height] }
        var parts: [ClosedRange<CGFloat>] = []
        var start: CGFloat = 0
        while start < height - 0.5 {
            var cut = start + maxHeight
            if cut >= height - maxHeight * 0.1 {
                parts.append(start...height)
                break
            }
            let crossing = outlines.filter { $0.minY < cut && $0.maxY > cut }
            if let top = crossing.map(\.minY).min(), top - 8 > start + maxHeight * 0.5 {
                cut = top - 8
            }
            parts.append(start...cut)
            start = cut
        }
        return parts
    }
}
#endif
