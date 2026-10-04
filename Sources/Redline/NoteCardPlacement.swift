#if REDLINE
import Foundation

/// Where the note card sits while you type: next to the picked element when it
/// fits, never under the keyboard or the status bar, and hiding as little of the
/// element as possible when it can't sit beside it.
enum NoteCardPlacement {
    static let margin: CGFloat = 8

    /// The card's top edge, in screen points.
    /// - Parameters:
    ///   - element: the picked element's frame, or nil when editing a note from the list.
    ///   - height: the card's current height.
    ///   - reservedHeight: the height the card can grow to while typing. The side is
    ///     chosen for this height, so a growing note never flips the card to the other side.
    ///   - top: the highest the card may go, usually the bottom of the status bar.
    ///   - bottom: the lowest the card's bottom may go: the top of the keyboard, or the
    ///     home indicator when no keyboard is up.
    /// - Returns: The card's top edge, in screen points.
    static func top(element: CGRect?, height: CGFloat, reservedHeight: CGFloat, top: CGFloat, bottom: CGFloat)
        -> CGFloat
    {
        let reserved = max(height, reservedHeight)
        let minTop = top + margin
        let maxBottom = bottom - margin
        // The card resting right on the keyboard.
        let restingTop = maxBottom - height
        // Taller than the space left: keep its top visible.
        guard restingTop > minTop else { return minTop }
        // Editing from the list: no element on screen, so sit on the keyboard like a composer.
        guard let element else { return restingTop }

        // Below the element, with room to grow downward.
        if element.maxY + margin + reserved <= maxBottom {
            return max(element.maxY + margin, minTop)
        }
        // Above the element, growing upward. An element under the keyboard ends up here too,
        // and the card then rests on the keyboard.
        if element.minY - margin - reserved >= minTop {
            return min(element.minY - margin - height, restingTop)
        }
        // Neither side fits: rest on the keyboard or at the top, whichever hides less of the element.
        let overlap: (CGFloat) -> CGFloat = { cardTop in
            max(0, min(cardTop + reserved, element.maxY) - max(cardTop, element.minY))
        }
        return overlap(maxBottom - reserved) <= overlap(minTop) ? restingTop : minTop
    }
}
#endif
