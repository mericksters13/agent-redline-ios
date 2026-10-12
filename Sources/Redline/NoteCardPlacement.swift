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

    /// The widest the tag naming what is marked may be; longer text wraps.
    static func tagMaxWidth(screenWidth: CGFloat) -> CGFloat {
        max(screenWidth - 2 * margin, 0)
    }

    /// Where that tag goes: by the marked area's leading edge, on the side away from the card, and
    /// inside the screen however wide the tag is.
    static func tagOrigin(marked: CGRect, tag: CGSize, cardMidY: CGFloat, screenWidth: CGFloat, top: CGFloat)
        -> CGPoint
    {
        let x = max(min(marked.minX - 3, screenWidth - tag.width - margin), margin)
        let above = cardMidY > marked.midY
        return CGPoint(x: x, y: above ? max(marked.minY - margin - tag.height, top + 4) : marked.maxY + margin)
    }
}
#endif
