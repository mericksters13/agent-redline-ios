#if REDLINE
import CoreGraphics
import Foundation

/// What a new note's capture does to its screen's snapshot.
///
/// A note keeps the capture of the state it was made on, unless its element looks identical in a
/// newer capture of the screen.
enum CaptureMerge {
    enum Decision: Equatable {
        /// Nothing changed: the note uses the screen's existing snapshot.
        case reuse(UUID)
        /// The screen scrolled: the new capture is stitched into the screen's snapshot.
        case stitch
        /// The content changed: the new capture becomes the screen's snapshot, and earlier
        /// notes move onto it when their elements can be found there and look identical.
        case replace
    }

    /// What filing a note's capture did.
    struct Filing: Equatable {
        /// The capture the note belongs to.
        var captureID: UUID
        /// True when the capture was added to its screen, so its image must be kept.
        var isNewCapture: Bool
        /// Earlier notes that moved onto the new capture.
        var movedNotes: [UUID]
    }

    /// How the stretch a scrolled capture shares with the previous one compares.
    enum OverlapCheck: Equatable, Sendable {
        case matches
        case differs
        /// They share too little to tell.
        case tooSmallToTell
    }

    /// Files a new note's capture under its screen, so each state of a screen gets its own snapshot.
    ///
    /// Reuses the screen's snapshot when nothing changed, stitches the new capture in when the screen
    /// scrolled, and otherwise makes the new capture the screen's snapshot and moves each earlier
    /// note onto it only when its element is still there and looks identical. Under a popup, a
    /// dimmed backdrop, or after a segment switch inside it, the element doesn't, and the note keeps
    /// the snapshot of the state it was made on.
    /// - Parameters:
    ///   - capture: the capture just taken, in group 0.
    ///   - image: its pixels.
    ///   - element: the element the new note is about.
    ///   - screen: the screen the capture is of.
    ///   - screens: the draft's screens, updated.
    ///   - annotations: the draft's notes, updated when earlier notes move onto the new capture.
    ///   - imageOf: the pixels of an earlier capture.
    /// - Returns: The capture the new note belongs to, and what changed.
    static func file(
        _ capture: Capture,
        image: CGImage?,
        element: ElementSnapshot,
        screen: ScreenInfo,
        screens: inout [ScreenRecord],
        annotations: inout [Annotation],
        imageOf: (_ capture: Capture) -> CGImage?
    ) -> Filing {
        var capture = capture
        guard let index = screens.firstIndex(where: { $0.info == screen }), let previous = screens[index].captures.last
        else {
            screens.append(ScreenRecord(id: UUID(), info: screen, captures: [capture]))
            return Filing(captureID: capture.id, isNewCapture: true, movedNotes: [])
        }
        let before = imageOf(previous)
        var snapshotsMatch = false
        var isElementUnchanged = false
        if let before, let image {
            snapshotsMatch = SnapshotComparison.difference(before, image) < SnapshotComparison.sameSnapshot
            // The new note's element must look identical in the snapshot it would share.
            isElementUnchanged = looksIdentical(
                element.frame,
                in: before,
                of: previous,
                as: element.frame,
                in: image,
                of: capture
            )
        }
        let overlap = overlapCheck(previous: previous, before: before, new: capture, after: image)

        switch decision(
            previous: previous,
            new: capture,
            snapshotsMatch: snapshotsMatch,
            isElementUnchanged: isElementUnchanged,
            overlap: overlap
        ) {
        case .reuse(let existing):
            return Filing(captureID: existing, isNewCapture: false, movedNotes: [])
        case .stitch:
            capture.group = previous.group
            screens[index].captures.append(capture)
            return Filing(captureID: capture.id, isNewCapture: true, movedNotes: [])
        case .replace:
            capture.group = previous.group + 1
            screens[index].captures.append(capture)
            let screenCaptures = screens[index].captures
            let onScreen = CGRect(origin: .zero, size: capture.size)
            var moved: [UUID] = []
            for i in annotations.indices {
                guard let image, let old = annotations[i].captureID, old != capture.id,
                    let oldCapture = screenCaptures.first(where: { $0.id == old }),
                    let oldImage = imageOf(oldCapture),
                    let element = annotations[i].element,
                    let match = ElementSelection.match(element, in: capture.elements),
                    onScreen.contains(match.frame.insetBy(dx: 1, dy: 1)),
                    looksIdentical(element.frame, in: oldImage, of: oldCapture, as: match.frame, in: image, of: capture)
                else { continue }
                annotations[i].captureID = capture.id
                annotations[i].element?.frame = match.frame
                moved.append(annotations[i].id)
            }
            return Filing(captureID: capture.id, isNewCapture: true, movedNotes: moved)
        }
    }

    /// Whether an element looks identical in two captures.
    ///
    /// Frames are in points.
    static func looksIdentical(
        _ frame: CGRect,
        in image: CGImage,
        of capture: Capture,
        as newFrame: CGRect,
        in newImage: CGImage,
        of newCapture: Capture
    ) -> Bool {
        func pixels(_ rect: CGRect, of snapshot: CGImage, width: CGFloat) -> CGRect {
            let ratio = CGFloat(snapshot.width) / width
            return CGRect(
                x: rect.minX * ratio,
                y: rect.minY * ratio,
                width: rect.width * ratio,
                height: rect.height * ratio
            )
        }
        return SnapshotComparison.differingPixels(
            image,
            in: pixels(frame, of: image, width: capture.size.width),
            newImage,
            in: pixels(newFrame, of: newImage, width: newCapture.size.width),
            upTo: SnapshotComparison.sameElementPixels
        ) <= SnapshotComparison.sameElementPixels
    }

    /// Whether the content two captures of a scrolled screen share looks the same.
    static func overlapCheck(previous: Capture, before: CGImage?, new: Capture, after: CGImage?) -> OverlapCheck {
        guard let from = previous.scroll, let to = new.scroll, from.isSameView(as: to),
            let band = ScreenComposition.band(for: [previous, new]),
            let old = before, let current = after
        else { return .tooSmallToTell }
        let low = max(from.contentY(ofScreenY: band.lowerBound), to.contentY(ofScreenY: band.lowerBound))
        let high = min(from.contentY(ofScreenY: band.upperBound), to.contentY(ofScreenY: band.upperBound))
        guard high - low >= 40 else { return .tooSmallToTell }
        func pixelRows(_ scroll: ScrollState, in image: CGImage, width: CGFloat) -> Range<Int> {
            let ratio = CGFloat(image.width) / width
            return Int(
                (scroll.screenY(ofContentY: low) * ratio).rounded()
            )..<Int((scroll.screenY(ofContentY: high) * ratio).rounded())
        }
        let difference = SnapshotComparison.difference(
            old,
            rows: pixelRows(from, in: old, width: previous.size.width),
            current,
            rows: pixelRows(to, in: current, width: new.size.width)
        )
        return difference < SnapshotComparison.sameOverlap ? .matches : .differs
    }

    /// Whether a new capture reuses, extends or replaces the screen's snapshot.
    /// - Parameters:
    ///   - previous: the screen's capture so far.
    ///   - new: the capture just taken.
    ///   - snapshotsMatch: the two snapshots look the same.
    ///   - isElementUnchanged: the new note's element looks identical in both. A segment switch
    ///     inside a card barely changes the whole snapshot, but the note belongs to the new state.
    ///   - overlap: how the content compares where a scrolled capture overlaps the previous one.
    /// - Returns: What to do with the new capture.
    static func decision(
        previous: Capture,
        new: Capture,
        snapshotsMatch: Bool,
        isElementUnchanged: Bool,
        overlap: OverlapCheck
    ) -> Decision {
        guard previous.size == new.size else { return .replace }
        if let before = previous.scroll, let after = new.scroll, before.isSameView(as: after),
            abs(before.offsetY - after.offsetY) > 2
        {
            // Joined only when it's proven the same content, scrolled.
            guard overlap != .differs, isScroll(from: previous, to: new) else { return .replace }
            return .stitch
        }
        return snapshotsMatch && isElementUnchanged && isSameLayout(previous, as: new) ? .reuse(previous.id) : .replace
    }

    /// Whether two captures hold the same elements in the same places.
    ///
    /// A light menu over a light screen can look almost unchanged in a small copy, but its items
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
