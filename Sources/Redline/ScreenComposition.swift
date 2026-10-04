#if REDLINE
import Foundation

/// Puts a screen's picture together from its captures: where content scrolls, how the
/// captures are stitched, and where a tall picture is cut into parts.
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
        let scrolled = scrolls(of: captures).sorted { $0.scroll.offsetY < $1.scroll.offsetY }
        if let low = scrolled.first, let high = scrolled.last, high.scroll.offsetY - low.scroll.offsetY > 10 {
            let middle = (top + bottom) / 2
            for element in high.capture.elements where !element.isContainer {
                let frame = element.frame
                guard frame.height < (bottom - top) * 0.25, frame.maxY > top, frame.minY < bottom,
                      let match = ElementSelection.match(element, in: low.capture.elements),
                      abs(match.frame.minY - frame.minY) < 1.5, abs(match.frame.minX - frame.minX) < 1.5
                else { continue }
                if frame.midY > middle {
                    bottom = min(bottom, frame.minY)
                } else {
                    top = max(top, frame.maxY)
                }
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
        let scrolls = scrolls(of: captures)
        guard captures.count > 1, scrolls.count == captures.count, let band = band(for: captures) else {
            return ImagePlan(
                size: reference.size,
                segments: [.init(capture: reference.id, sourceMinY: 0, height: reference.size.height, destinationY: 0)],
                gaps: [], stitchedFrom: 1, band: nil, runs: [], footerY: reference.size.height,
                captures: [reference.id: reference]
            )
        }

        let topmost = scrolls.min { $0.scroll.offsetY < $1.scroll.offsetY }?.capture ?? reference
        let bottommost = scrolls.max { $0.scroll.offsetY < $1.scroll.offsetY }?.capture ?? reference
        var segments = [ImagePlan.Segment(capture: topmost.id, sourceMinY: 0, height: band.lowerBound, destinationY: 0)]
        let ranges = scrolls.map { entry -> (capture: Capture, scroll: ScrollState, range: ClosedRange<CGFloat>) in
            (entry.capture, entry.scroll, entry.scroll.contentY(ofScreenY: band.lowerBound)...entry.scroll.contentY(ofScreenY: band.upperBound))
        }
        let points = Set(ranges.flatMap { [$0.range.lowerBound, $0.range.upperBound] }).sorted()
        var y = band.lowerBound
        var runs: [ImagePlan.Run] = []
        var gaps: [ImagePlan.Gap] = []
        var lastEnd: CGFloat?
        var pendingGap = false
        for (start, end) in zip(points, points.dropFirst()) where end - start > 0.5 {
            // The newest capture that shows this stretch.
            guard let owner = ranges.last(where: { $0.range.lowerBound <= start + 0.5 && $0.range.upperBound >= end - 0.5 }) else {
                if lastEnd != nil { pendingGap = true }
                continue
            }
            if pendingGap {
                gaps.append(ImagePlan.Gap(
                    rect: CGRect(x: 0, y: y, width: reference.size.width, height: gapHeight),
                    skippedHeight: start - (lastEnd ?? start)
                ))
                y += gapHeight
                pendingGap = false
            }
            let source = owner.scroll.screenY(ofContentY: start)
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

    /// The captures that know their scroll position, with that position.
    private static func scrolls(of captures: [Capture]) -> [(capture: Capture, scroll: ScrollState)] {
        captures.compactMap { capture in capture.scroll.map { (capture: capture, scroll: $0) } }
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
