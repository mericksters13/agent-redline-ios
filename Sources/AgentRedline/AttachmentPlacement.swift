#if AGENT_REDLINE
import Foundation

/// Where the photo panel sits. It grows out of the attachment button: it starts at the
/// button's edge and opens toward the middle of the screen, so it follows the button
/// wherever it is.
enum AttachmentPlacement {
    static let margin: CGFloat = 12

    /// The corner the surface grows from, the one at the attachment button.
    enum Corner: Equatable {
        case topLeading, topTrailing, bottomLeading, bottomTrailing

        var isTop: Bool { self == .topLeading || self == .topTrailing }
        var isLeading: Bool { self == .topLeading || self == .bottomLeading }
    }

    /// The corner at the button: top when the button is in the upper half of the
    /// space, trailing when it is in the right half.
    static func corner(for anchor: CGRect, in bounds: CGRect) -> Corner {
        let top = anchor.midY < bounds.midY
        let leading = anchor.midX < bounds.midX
        switch (top, leading) {
        case (true, true): return .topLeading
        case (true, false): return .topTrailing
        case (false, true): return .bottomLeading
        case (false, false): return .bottomTrailing
        }
    }

    /// How tall the opened grid may get for its width: room for two full rows of
    /// phone-shaped tiles on a phone.
    static let maxHeightRatio: CGFloat = 1.75

    /// The opened photo grid at its largest: the full width of `bounds` less the
    /// margins, starting at the button's edge and stopping a margin short of the far edge.
    static func expanded(anchor: CGRect, in bounds: CGRect) -> CGRect {
        let width = bounds.width - 2 * margin
        let corner = corner(for: anchor, in: bounds)
        let start = corner.isTop ? max(anchor.minY, bounds.minY) : min(anchor.maxY, bounds.maxY)
        let room = corner.isTop ? bounds.maxY - margin - start : start - bounds.minY - margin
        let height = max(min(width * maxHeightRatio, room), 0)
        return CGRect(x: bounds.minX + margin, y: corner.isTop ? start : start - height, width: width, height: height)
    }

    /// The opened photo grid, no taller than its content, still anchored at the button's edge.
    static func expanded(anchor: CGRect, in bounds: CGRect, contentHeight: CGFloat) -> CGRect {
        let largest = expanded(anchor: anchor, in: bounds)
        let height = min(largest.height, max(contentHeight, 0))
        let y = corner(for: anchor, in: bounds).isTop ? largest.minY : largest.maxY - height
        return CGRect(x: largest.minX, y: y, width: largest.width, height: height)
    }
}
#endif
