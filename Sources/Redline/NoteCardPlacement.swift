#if REDLINE
import Foundation

/// The vertical space available to a note card, clear of the selected component when possible.
enum NoteCardPlacement {
    static let margin: CGFloat = 8

    /// Choose a usable side independently of the content height, so expanding or typing cannot
    /// move the form through the component.
    ///
    /// The caller caps and scrolls the content in this space.
    /// If neither side holds the minimum usable form, use the viewport and hide as little as possible.
    static func space(
        element: CGRect?,
        minimumHeight: CGFloat,
        height: CGFloat,
        top: CGFloat,
        bottom: CGFloat
    ) -> (bounds: ClosedRange<CGFloat>, anchorsBottom: Bool) {
        let start = top + margin
        let end = max(start, bottom - margin)
        guard let element else { return (start...end, true) }
        let aboveEnd = min(max(element.minY - margin, start), end)
        let belowStart = min(max(element.maxY + margin, start), end)
        let above = aboveEnd - start
        let below = end - belowStart
        if below >= minimumHeight, below >= above {
            return (belowStart...end, false)
        }
        if above >= minimumHeight {
            return (start...aboveEnd, true)
        }
        let cappedHeight = min(height, end - start)
        let overlap: (CGFloat) -> CGFloat = { cardTop in
            max(0, min(cardTop + cappedHeight, element.maxY) - max(cardTop, element.minY))
        }
        return (start...end, overlap(end - cappedHeight) <= overlap(start))
    }

    /// The space clear of `box`, when a side of it can still hold the card; nil when the card
    /// would have to overlap it.
    ///
    /// For a box wider than the element itself, such as a hierarchy's owner or the element's
    /// measured frame: worth staying clear of, but never at the cost of covering the element.
    static func clearSpace(
        of box: CGRect,
        minimumHeight: CGFloat,
        height: CGFloat,
        top: CGFloat,
        bottom: CGFloat
    ) -> (bounds: ClosedRange<CGFloat>, anchorsBottom: Bool)? {
        let space = space(element: box, minimumHeight: minimumHeight, height: height, top: top, bottom: bottom)
        let isClear = space.bounds.upperBound <= box.minY - margin || space.bounds.lowerBound >= box.maxY + margin
        return isClear ? space : nil
    }

    /// The widest the tag naming what is marked may be; longer text wraps.
    static func tagMaxWidth(screenWidth: CGFloat) -> CGFloat {
        max(screenWidth - 2 * margin, 0)
    }

    /// Where that tag goes: by the marked area's leading edge, on the side away from the card, and
    /// inside the visible screen however wide or tall the tag is.
    ///
    /// Under an element at the bottom of the screen there is no room, so the tag moves up over the
    /// element's lower edge rather than off the screen.
    static func tagOrigin(
        marked: CGRect,
        tag: CGSize,
        cardMidY: CGFloat,
        screenWidth: CGFloat,
        top: CGFloat,
        bottom: CGFloat
    ) -> CGPoint {
        let x = max(min(marked.minX - 3, screenWidth - tag.width - margin), margin)
        let highest = top + 4
        let lowest = max(bottom - margin - tag.height, highest)
        let y = cardMidY > marked.midY ? marked.minY - margin - tag.height : marked.maxY + margin
        return CGPoint(x: x, y: min(max(y, highest), lowest))
    }
}
#endif
