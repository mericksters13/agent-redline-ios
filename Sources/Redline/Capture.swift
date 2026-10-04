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

/// One picture of a screen, kept without outlines.
///
/// Outlines are drawn when the picture is shown or sent, so every note on the screen can share it.
struct Capture: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var file: String
    /// The screen's size, in points.
    var size: CGSize
    var scroll: ScrollState?
    /// What was on screen, to find notes again and to tell bars from scrolled content.
    var elements: [ElementSnapshot]
    /// Captures in the same group are stitched into one picture.
    ///
    /// A new group starts when the screen's content changed rather than scrolled.
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
#endif
