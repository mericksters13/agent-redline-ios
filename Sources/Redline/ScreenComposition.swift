#if REDLINE
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
            // Joined only when it's proven the same content, scrolled.
            guard overlapMatches != false, isScroll(from: previous, to: new) else { return .replace }
            return .stitch
        }
        return picturesMatch && sameLayout(previous, new) ? .reuse(previous.id) : .replace
    }

    /// Whether two captures hold the same elements in the same places. A light menu over a
    /// light screen can look almost unchanged in a small picture, but its items are new
    /// elements. Text may change, like a time stamp, and a label's width with it.
    static func sameLayout(_ a: Capture, _ b: Capture) -> Bool {
        guard a.elements.count == b.elements.count else { return false }
        func ordered(_ capture: Capture) -> [ElementSnapshot] {
            capture.elements.sorted { ($0.frame.minY.rounded(), $0.frame.minX.rounded()) < ($1.frame.minY.rounded(), $1.frame.minX.rounded()) }
        }
        return zip(ordered(a), ordered(b)).allSatisfy { old, new in
            old.role == new.role && old.isContainer == new.isContainer
                && abs(old.frame.minX - new.frame.minX) <= 2 && abs(old.frame.minY - new.frame.minY) <= 2
                && abs(old.frame.height - new.frame.height) <= 2
        }
    }

    /// Whether two captures of one scroll view show the same content at two scroll positions,
    /// rather than different content under the same screen title (two detail pages both
    /// called "Feed"). Elements found whole in both captures must have moved by exactly the
    /// scroll distance; a few may stay put, like a pinned section header, but most must
    /// agree. With nothing in common, the content must be just as long.
    static func isScroll(from previous: Capture, to new: Capture) -> Bool {
        guard let before = previous.scroll, let after = new.scroll, before.isSameView(as: after) else { return false }
        let distance = after.offsetY - before.offsetY
        let band = ScreenComposition.band(for: [previous, new]) ?? 0...previous.size.height
        func inBand(_ frame: CGRect) -> Bool { frame.minY >= band.lowerBound && frame.maxY <= band.upperBound }
        var agreeing = 0
        var disagreeing = 0
        for element in new.elements where !element.isContainer && inBand(element.frame) {
            guard let match = ElementSelection.match(element, in: previous.elements), inBand(match.frame),
                  abs(match.frame.height - element.frame.height) < 1 else { continue }
            if abs(match.frame.minY - distance - element.frame.minY) <= 2 { agreeing += 1 } else { disagreeing += 1 }
        }
        if agreeing + disagreeing > 0 { return agreeing > 0 && agreeing >= disagreeing * 2 }
        let longer = max(before.contentHeight, after.contentHeight)
        return longer > 0 && (longer - min(before.contentHeight, after.contentHeight)) / longer <= 0.03
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
    /// How much content each gap stands for, in points.
    var skipped: [CGFloat] = []
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
        // A bar draws its border just outside its frame. Left in the band, a capture's border
        // would show as a line where its content meets another capture's.
        return bottom - top > 2 ? (top + 1)...(bottom - 1) : nil
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
        var skipped: [CGFloat] = []
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
                skipped.append(start - (lastEnd ?? start))
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
            segments: segments, gaps: gaps, skipped: skipped, stitchedFrom: captures.count, band: band, runs: runs,
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

    /// How many screens tall a picture can be and still be sent whole. Agents shrink large
    /// images (Claude to about 1,568 pixels on the long side); at two screens the text stays readable.
    static let screensPerPicture: CGFloat = 2

    /// Splits a picture taller than `maxHeight` into parts, so agents that shrink large images
    /// can still read them. A picture that fits is sent whole. Each cut goes in a gap between
    /// rows or sections, so no outline, row or card is sliced; only when there is no such gap
    /// in the lower half of a part does it cut at the limit.
    /// - Parameters:
    ///   - outlines: the notes' outlines, never cut.
    ///   - elements: everything on screen, in picture coordinates, cut through only when unavoidable.
    ///   - preferred: rows to cut at first when one falls in range, such as a "Scrolled past" band.
    static func parts(height: CGFloat, maxHeight: CGFloat, keepingWhole outlines: [CGRect], avoiding elements: [CGRect] = [], preferring preferred: [CGFloat] = []) -> [ClosedRange<CGFloat>] {
        guard height > maxHeight else { return [0...height] }
        var parts: [ClosedRange<CGFloat>] = []
        var start: CGFloat = 0
        while start < height - 0.5 {
            let limit = start + maxHeight
            if limit >= height {
                parts.append(start...height)
                break
            }
            let low = start + maxHeight * 0.5
            let cut = preferred.filter { $0 >= low && $0 <= limit }.max()
                ?? gap(between: low, and: limit, outlines: outlines, elements: elements) ?? limit
            parts.append(start...cut)
            start = cut
        }
        return parts
    }

    /// The lowest row between `low` and `high` that runs through nothing: first avoiding every
    /// outline, row and card; then only outlines and rows, since a long section may span the range.
    private static func gap(between low: CGFloat, and high: CGFloat, outlines: [CGRect], elements: [CGRect]) -> CGFloat? {
        let span = high - low
        let sections = elements.filter { $0.height < span }
        let rows = elements.filter { $0.height < span * 0.25 }
        let candidates = ([high] + (outlines + elements).flatMap { [$0.minY - 4, $0.maxY + 4] })
            .filter { $0 >= low && $0 <= high }
            .sorted(by: >)
        for blockers in [outlines + sections, outlines + rows] {
            if let row = candidates.first(where: { row in !blockers.contains { $0.minY < row && $0.maxY > row } }) {
                return row
            }
        }
        return nil
    }
}
#endif
