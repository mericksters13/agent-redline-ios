#if REDLINE
import Foundation

/// How one picture of a screen is put together from its captures, in screen points.
struct ImagePlan: Equatable, Sendable {
    /// Rows copied from a capture into the picture.
    struct Segment: Equatable, Sendable {
        var captureID: UUID
        var sourceMinY: CGFloat
        var height: CGFloat
        var destinationY: CGFloat
    }

    /// A stretch of scrolled content and where it starts in the picture.
    struct Run: Equatable, Sendable {
        var contentStart: CGFloat
        var contentEnd: CGFloat
        var destinationY: CGFloat
    }

    /// A stretch of the screen scrolled past without a capture, marked "Scrolled past".
    struct Gap: Equatable, Sendable {
        /// Where the mark goes in the picture.
        var rect: CGRect
        /// How much content it stands for, in points.
        var skippedHeight: CGFloat
    }

    var size: CGSize
    var segments: [Segment]
    var gaps: [Gap]
    var stitchedFrom: Int
    /// Where content scrolls, in screen points. Nil for a picture of one capture.
    var band: ClosedRange<CGFloat>?
    var runs: [Run]
    /// Where the bottom bars start in the picture.
    var footerY: CGFloat
    var captures: [UUID: Capture]

    /// Where a note made on `capture` sits in this picture.
    func position(of frame: CGRect, from captureID: UUID) -> CGRect? {
        guard let capture = captures[captureID] else { return nil }
        guard let band, let scroll = capture.scroll else { return frame }
        if frame.midY < band.lowerBound { return frame }
        if frame.midY > band.upperBound {
            return frame.offsetBy(dx: 0, dy: footerY - band.upperBound)
        }
        let content = scroll.contentY(ofScreenY: frame.minY)
        let run = runs.first { content >= $0.contentStart - 0.5 && content <= $0.contentEnd + 0.5 }
            ?? runs.min { abs($0.contentStart - content) < abs($1.contentStart - content) }
        guard let run else { return nil }
        return CGRect(x: frame.minX, y: run.destinationY + content - run.contentStart, width: frame.width, height: frame.height)
    }
}
#endif
