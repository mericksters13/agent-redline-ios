#if REDLINE
import Foundation

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

    /// How the stretch a scrolled capture shares with the previous one compares.
    enum OverlapCheck: Equatable, Sendable {
        case matches
        case differs
        /// They share too little to tell.
        case tooSmallToTell
    }

    /// Whether a new capture reuses, extends or replaces the screen's picture.
    /// - Parameters:
    ///   - previous: the screen's capture so far.
    ///   - new: the capture just taken.
    ///   - picturesMatch: the two pictures look the same.
    ///   - overlap: how the content compares where a scrolled capture overlaps the previous one.
    /// - Returns: What to do with the new capture.
    static func decision(previous: Capture, new: Capture, picturesMatch: Bool, overlap: OverlapCheck) -> Decision {
        guard previous.size == new.size else { return .replace }
        if let before = previous.scroll, let after = new.scroll, before.isSameView(as: after),
            abs(before.offsetY - after.offsetY) > 2
        {
            // Joined only when it's proven the same content, scrolled.
            guard overlap != .differs, isScroll(from: previous, to: new) else { return .replace }
            return .stitch
        }
        return picturesMatch && isSameLayout(previous, as: new) ? .reuse(previous.id) : .replace
    }

    /// Whether two captures hold the same elements in the same places.
    ///
    /// A light menu over a light screen can look almost unchanged in a small picture, but its items
    /// are new elements. Text may change, like a time stamp, and a label's width with it.
    static func isSameLayout(_ a: Capture, as b: Capture) -> Bool {
        guard a.elements.count == b.elements.count else { return false }
        func ordered(_ capture: Capture) -> [ElementSnapshot] {
            capture.elements.sorted {
                ($0.frame.minY.rounded(), $0.frame.minX.rounded()) < ($1.frame.minY.rounded(), $1.frame.minX.rounded())
            }
        }
        return zip(ordered(a), ordered(b)).allSatisfy { old, new in
            old.role == new.role && old.isContainer == new.isContainer
                && abs(old.frame.minX - new.frame.minX) <= 2 && abs(old.frame.minY - new.frame.minY) <= 2
                && abs(old.frame.height - new.frame.height) <= 2
        }
    }

    /// Whether two captures of one scroll view show the same content at two scroll positions,
    /// rather than different content under the same screen title (two detail pages both called
    /// "Feed").
    ///
    /// Elements found whole in both captures must have moved by exactly the scroll distance; a few
    /// may stay put, like a pinned section header, but most must agree. With nothing in common, the
    /// content must be just as long.
    static func isScroll(from previous: Capture, to new: Capture) -> Bool {
        guard let before = previous.scroll, let after = new.scroll, before.isSameView(as: after) else { return false }
        let distance = after.offsetY - before.offsetY
        let band = ScreenComposition.band(for: [previous, new]) ?? 0...previous.size.height
        func inBand(_ frame: CGRect) -> Bool { frame.minY >= band.lowerBound && frame.maxY <= band.upperBound }
        var agreeing = 0
        var disagreeing = 0
        for element in new.elements where !element.isContainer && inBand(element.frame) {
            guard let match = ElementSelection.match(element, in: previous.elements), inBand(match.frame),
                abs(match.frame.height - element.frame.height) < 1
            else { continue }
            if abs(match.frame.minY - distance - element.frame.minY) <= 2 {
                agreeing += 1
            } else {
                disagreeing += 1
            }
        }
        if agreeing + disagreeing > 0 { return agreeing > 0 && agreeing >= disagreeing * 2 }
        let longer = max(before.contentHeight, after.contentHeight)
        return longer > 0 && (longer - min(before.contentHeight, after.contentHeight)) / longer <= 0.03
    }
}
#endif
