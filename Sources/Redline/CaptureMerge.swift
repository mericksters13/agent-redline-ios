#if REDLINE
import CoreGraphics
import Foundation

/// What a new note's capture does to its screen's snapshot.
///
/// A note keeps the capture of the state it was made on, unless what it marks looks identical in a
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

    /// Places a new note's capture under its screen, so each state of a screen gets its own
    /// snapshot.
    ///
    /// Reuses the screen's snapshot when nothing changed, stitches the new capture in when the screen
    /// scrolled, and otherwise makes the new capture the screen's snapshot and moves each earlier
    /// note onto it only when its element is still there and looks identical. Under a popup, a
    /// dimmed backdrop, or after a segment switch inside it, the element doesn't, and the note keeps
    /// the snapshot of the state it was made on. A scroll is stitched only when every earlier note
    /// the new capture would draw over still looks identical in it.
    /// - Parameters:
    ///   - capture: the capture just taken, in group 0.
    ///   - image: its pixels.
    ///   - element: the element the new note is about; nil for a drawing.
    ///   - frame: the area the new note marks: the element's frame, or the box around the drawing.
    ///   - screen: the screen the capture is of.
    ///   - screens: the draft's screens, updated.
    ///   - annotations: the draft's notes, updated when earlier notes move onto the new capture.
    ///   - loadImage: the pixels of an earlier capture.
    /// - Returns: The capture the new note belongs to, and what changed.
    static func place(
        _ capture: Capture,
        image: CGImage?,
        element: ElementSnapshot?,
        frame: CGRect,
        screen: ScreenInfo,
        screens: inout [ScreenRecord],
        annotations: inout [Annotation],
        loadImage: (_ capture: Capture) -> CGImage?
    ) -> Filing {
        var capture = capture
        guard let index = screens.firstIndex(where: { $0.info == screen }), let previous = screens[index].captures.last
        else {
            screens.append(ScreenRecord(id: UUID(), info: screen, captures: [capture]))
            return Filing(captureID: capture.id, isNewCapture: true, movedNotes: [])
        }
        let before = loadImage(previous)
        var snapshotsMatch = false
        if let before, let image {
            snapshotsMatch = SnapshotComparison.difference(before, image) < SnapshotComparison.sameSnapshot
        }
        let overlap = overlapCheck(previous: previous, before: before, new: capture, after: image)
        var result = decision(previous: previous, new: capture, snapshotsMatch: snapshotsMatch, overlap: overlap) {
            guard let before, let image else { return false }
            // A drawing marks a place, not an element: the same place must look identical.
            guard let element else {
                return looksIdentical(frame, in: before, of: previous, as: frame, in: image, of: capture)
            }
            // The new note's element must look identical in the snapshot it would share, found
            // there by itself, since layout may have moved it by a fraction of a point.
            guard let old = ElementSelection.match(element, in: previous.elements) else { return false }
            return looksIdentical(old.frame, in: before, of: previous, as: frame, in: image, of: capture)
        }
        if result == .stitch {
            let group = screens[index].captures.filter { $0.group == previous.group }
            if !keepsEarlierStates(
                stitching: capture,
                image: image,
                newNoteFrame: frame,
                onto: group,
                annotations: annotations,
                loadImage: loadImage
            ) {
                result = .replace
            }
        }

        switch result {
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
                    let oldImage = loadImage(oldCapture)
                else { continue }
                if let element = annotations[i].element {
                    guard let match = ElementSelection.match(element, in: capture.elements),
                        onScreen.contains(match.frame.insetBy(dx: 1, dy: 1)),
                        looksIdentical(
                            element.frame,
                            in: oldImage,
                            of: oldCapture,
                            as: match.frame,
                            in: image,
                            of: capture
                        )
                    else { continue }
                    annotations[i].element?.frame = match.frame
                } else {
                    // A drawing stays where it was drawn, so it moves only onto a capture of the
                    // same size, scrolled to the same place, that looks identical there. A finger
                    // can draw to the screen's edge; only the part on screen is compared.
                    guard let frame = annotations[i].frame, !annotations[i].strokes.isEmpty,
                        oldCapture.size == capture.size, isSameScroll(oldCapture.scroll, capture.scroll),
                        frame.intersects(onScreen),
                        looksIdentical(frame, in: oldImage, of: oldCapture, as: frame, in: image, of: capture)
                    else { continue }
                }
                annotations[i].captureID = capture.id
                moved.append(annotations[i].id)
            }
            return Filing(captureID: capture.id, isNewCapture: true, movedNotes: moved)
        }
    }

    /// Whether stitching a scrolled capture onto a group keeps every earlier note's state.
    ///
    /// The newest capture draws the content it shows, and the top or bottom bars when it is scrolled
    /// highest or lowest. Where that covers an earlier note's element, the element must look
    /// identical in it; after a segment switch, or a change in a bar, it doesn't, and the scrolled
    /// capture starts a new snapshot instead. The same holds the other way for the new note: on a
    /// bar an earlier capture would draw, its element must look identical in that capture.
    static func keepsEarlierStates(
        stitching capture: Capture,
        image: CGImage?,
        newNoteFrame: CGRect,
        onto group: [Capture],
        annotations: [Annotation],
        loadImage: (_ capture: Capture) -> CGImage?
    ) -> Bool {
        guard let image, let to = capture.scroll, let plan = ScreenComposition.plan(for: group + [capture]),
            let band = plan.band
        else { return false }
        // The plan's first and last parts are the top and bottom bars, each taken from one capture.
        let bars = [plan.segments.first, plan.segments.last].compactMap { segment -> CGRect? in
            guard let segment, segment.captureID == capture.id else { return nil }
            return CGRect(x: 0, y: segment.sourceMinY, width: capture.size.width, height: segment.height)
        }
        // A new note on a bar that an earlier capture draws.
        if newNoteFrame.midY < band.lowerBound || newNoteFrame.midY > band.upperBound {
            for segment in [plan.segments.first, plan.segments.last] {
                guard let segment, segment.captureID != capture.id else { continue }
                let bar = CGRect(x: 0, y: segment.sourceMinY, width: capture.size.width, height: segment.height)
                let shown = newNoteFrame.intersection(bar)
                guard !shown.isNull, shown.height >= 1 else { continue }
                guard let owner = group.first(where: { $0.id == segment.captureID }), let ownerImage = loadImage(owner),
                    looksIdentical(shown, in: image, of: capture, as: shown, in: ownerImage, of: owner)
                else { return false }
            }
        }
        for annotation in annotations {
            guard let source = group.first(where: { $0.id == annotation.captureID }), let from = source.scroll,
                let frame = annotation.frame
            else { continue }
            // The marked pixels as the note was made, and where the new capture would draw them.
            var compared: [(shown: CGRect, drawn: CGRect)] = []
            // The element's content rows that both captures show between the bars.
            let top = max(
                from.contentY(ofScreenY: max(frame.minY, band.lowerBound)),
                to.contentY(ofScreenY: band.lowerBound)
            )
            let bottom = min(
                from.contentY(ofScreenY: min(frame.maxY, band.upperBound)),
                to.contentY(ofScreenY: band.upperBound)
            )
            if bottom - top >= 1 {
                let height = bottom - top
                compared.append(
                    (
                        shown: CGRect(
                            x: frame.minX,
                            y: from.screenY(ofContentY: top),
                            width: frame.width,
                            height: height
                        ),
                        drawn: CGRect(x: frame.minX, y: to.screenY(ofContentY: top), width: frame.width, height: height)
                    )
                )
            }
            // A note on a bar stays where it was made, over the bar the new capture would draw.
            if frame.midY < band.lowerBound || frame.midY > band.upperBound {
                for bar in bars {
                    let shown = frame.intersection(bar)
                    if !shown.isNull, shown.height >= 1 { compared.append((shown: shown, drawn: shown)) }
                }
            }
            guard !compared.isEmpty else { continue }
            guard let sourceImage = loadImage(source) else { return false }
            for pair in compared
            where !looksIdentical(pair.shown, in: sourceImage, of: source, as: pair.drawn, in: image, of: capture) {
                return false
            }
        }
        return true
    }

    /// Whether two reads of the main scroll view are at the same place, within 2 points; true when
    /// neither had one.
    static func isSameScroll(_ a: ScrollState?, _ b: ScrollState?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case (let a?, let b?): a.isSameView(as: b) && abs(a.offsetY - b.offsetY) <= 2
        default: false
        }
    }

    /// Whether an element looks identical in two captures.
    ///
    /// Frames are in points. Content inside it that changes on its own, such as a spinner, is left
    /// out.
    static func looksIdentical(
        _ frame: CGRect,
        in image: CGImage,
        of capture: Capture,
        as newFrame: CGRect,
        in newImage: CGImage,
        of newCapture: Capture
    ) -> Bool {
        // Origin and size are rounded on their own, so the size never depends on where the element
        // sits: layout on a 3x screen moves frames by thirds of a point.
        func pixels(_ rect: CGRect, ratio: CGFloat) -> CGRect {
            CGRect(
                x: (rect.minX * ratio).rounded(),
                y: (rect.minY * ratio).rounded(),
                width: (rect.width * ratio).rounded(),
                height: (rect.height * ratio).rounded()
            )
        }
        let ratio = CGFloat(image.width) / capture.size.width
        let newRatio = CGFloat(newImage.width) / newCapture.size.width
        // Live content in each capture, from the element's top left corner.
        let oldLive = capture.elements.filter { $0.updatesFrequently == true }.map {
            $0.frame.offsetBy(dx: -frame.minX, dy: -frame.minY)
        }
        let newLive = newCapture.elements.filter { $0.updatesFrequently == true }.map {
            $0.frame.offsetBy(dx: -newFrame.minX, dy: -newFrame.minY)
        }
        // An element that is live as a whole, like a running timer, has nothing else to compare,
        // and its size may change with its content, from 9:59 to 10:00.
        func covers(_ live: [CGRect], _ size: CGSize) -> Bool {
            live.contains { $0.insetBy(dx: -1, dy: -1).contains(CGRect(origin: .zero, size: size)) }
        }
        if covers(oldLive, frame.size) || covers(newLive, newFrame.size) { return true }
        let inElement = (oldLive + newLive).filter { $0.intersects(CGRect(origin: .zero, size: frame.size)) }
        return SnapshotComparison.differingPixels(
            image,
            in: pixels(frame, ratio: ratio),
            newImage,
            in: pixels(newFrame, ratio: newRatio),
            ignoring: inElement.map { pixels($0, ratio: ratio).insetBy(dx: -1, dy: -1) },
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
    ///   - overlap: how the content compares where a scrolled capture overlaps the previous one.
    ///   - isElementUnchanged: whether the new note's element looks identical in both. A segment
    ///     switch inside a card barely changes the whole snapshot, but the note belongs to the new
    ///     state. Asked last, only when everything else allows a reuse, since it compares pixels in
    ///     detail.
    /// - Returns: What to do with the new capture.
    static func decision(
        previous: Capture,
        new: Capture,
        snapshotsMatch: Bool,
        overlap: OverlapCheck,
        isElementUnchanged: () -> Bool
    ) -> Decision {
        guard previous.size == new.size else { return .replace }
        if let before = previous.scroll, let after = new.scroll, before.isSameView(as: after),
            abs(before.offsetY - after.offsetY) > 2
        {
            // Joined only when it's proven the same content, scrolled.
            guard overlap != .differs, isScroll(from: previous, to: new) else { return .replace }
            return .stitch
        }
        return snapshotsMatch && isSameLayout(previous, as: new) && isElementUnchanged()
            ? .reuse(previous.id) : .replace
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
