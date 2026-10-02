#if AGENTIC_DEBUGGING
import Foundation

/// Where the floating debugger button rests. It can be dragged anywhere, and on
/// release it snaps to the nearest edge of the screen.
enum FloatingButtonPlacement {
    static let size: CGFloat = 52
    /// Gap between the button and the edge of the safe area.
    static let margin: CGFloat = 8

    /// The rectangle the button's center can rest in: the screen minus its safe
    /// area insets, the margin and half the button, so the whole button stays visible.
    static func restingArea(screen: CGSize, top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) -> CGRect {
        let inset = margin + size / 2
        return CGRect(
            x: left + inset,
            y: top + inset,
            width: max(0, screen.width - left - right - 2 * inset),
            height: max(0, screen.height - top - bottom - 2 * inset)
        )
    }

    /// Moves `center` onto whichever edge of `area` is closest, keeping it within
    /// the area along that edge.
    static func snapped(_ center: CGPoint, within area: CGRect) -> CGPoint {
        let x = min(max(center.x, area.minX), area.maxX)
        let y = min(max(center.y, area.minY), area.maxY)
        let distances = [
            (abs(center.x - area.minX), CGPoint(x: area.minX, y: y)),
            (abs(area.maxX - center.x), CGPoint(x: area.maxX, y: y)),
            (abs(center.y - area.minY), CGPoint(x: x, y: area.minY)),
            (abs(area.maxY - center.y), CGPoint(x: x, y: area.maxY)),
        ]
        return distances.min { $0.0 < $1.0 }!.1
    }

    /// Where the button starts the first time: on the right edge, a little below the middle.
    static func defaultCenter(within area: CGRect) -> CGPoint {
        CGPoint(x: area.maxX, y: area.minY + area.height * 0.6)
    }

    /// The center as fractions of `area`, so a saved position survives a
    /// different screen size or a rotation.
    static func fraction(of center: CGPoint, within area: CGRect) -> CGPoint {
        CGPoint(
            x: area.width > 0 ? (center.x - area.minX) / area.width : 1,
            y: area.height > 0 ? (center.y - area.minY) / area.height : 0.6
        )
    }

    static func center(fromFraction fraction: CGPoint, within area: CGRect) -> CGPoint {
        snapped(CGPoint(x: area.minX + fraction.x * area.width, y: area.minY + fraction.y * area.height), within: area)
    }
}
#endif
