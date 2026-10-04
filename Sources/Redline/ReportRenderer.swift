#if REDLINE && canImport(UIKit)
import UIKit

/// Draws a screen's snapshot from its captures, with each note's outline and number.
///
/// Safe to use off the main thread.
enum ReportRenderer {
    /// Pixels per point in sent snapshots.
    ///
    /// A phone screen comes out about 1,200 pixels tall: sharp enough to read every label, small
    /// enough that agents don't shrink it and its JPEG stays near 90 KB.
    static let sendScale: CGFloat = 1.4

    /// A note's outline and number, drawn on a snapshot.
    struct Outline: Sendable {
        enum Style: Sendable {
            /// In a sent report: every note drawn the same.
            case normal
            /// In the phone's viewer: the note being looked at.
            case current
            /// In the phone's viewer: the other notes on the same screen.
            case quiet
        }

        var number: Int
        var rect: CGRect
        var style: Style
    }

    /// Draws the rows `rows` of the plan's snapshot, all of it by default.
    ///
    /// The pieces are placed on whole pixels. A piece that starts or ends partway through a
    /// pixel leaves that pixel row or column partly uncovered, and the background shows
    /// through as a faint line.
    static func render(
        _ plan: ImagePlan,
        captures images: [UUID: UIImage],
        outlines: [Outline],
        rows: ClosedRange<CGFloat>? = nil,
        scale: CGFloat
    ) -> UIImage {
        func pixel(_ points: CGFloat) -> CGFloat { (points * scale).rounded() }
        let rows = rows ?? 0...plan.size.height
        let visible = CGRect(
            x: 0,
            y: rows.lowerBound,
            width: plan.size.width,
            height: rows.upperBound - rows.lowerBound
        )
        let top = pixel(rows.lowerBound)
        let size = CGSize(width: pixel(plan.size.width), height: pixel(rows.upperBound) - top)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
            for segment in plan.segments where segment.height > 0 {
                let minY = pixel(segment.destinationY) - top
                let destination = CGRect(
                    x: 0,
                    y: minY,
                    width: size.width,
                    height: pixel(segment.destinationY + segment.height) - top - minY
                )
                guard destination.maxY > 0, destination.minY < size.height, let source = images[segment.captureID],
                    let capture = plan.captures[segment.captureID]
                else { continue }
                draw(
                    source,
                    pointWidth: capture.size.width,
                    rowsFrom: segment.sourceMinY,
                    height: segment.height,
                    into: destination
                )
            }
            context.cgContext.translateBy(x: 0, y: -top)
            context.cgContext.scaleBy(x: scale, y: scale)
            for gap in plan.gaps.map(\.rect) where gap.intersects(visible) {
                drawGap(
                    CGRect(
                        x: 0,
                        y: pixel(gap.minY) / scale,
                        width: size.width / scale,
                        height: (pixel(gap.maxY) - pixel(gap.minY)) / scale
                    )
                )
            }
            for outline in outlines where outline.rect.insetBy(dx: -12, dy: -12).intersects(visible) {
                draw(outline, within: visible)
            }
        }
        guard let pixels = image.cgImage else { return image }
        return UIImage(cgImage: pixels, scale: scale, orientation: .up)
    }

    static func jpeg(_ image: UIImage) -> Data? {
        image.jpegData(compressionQuality: 0.75)
    }

    /// An image no wider than `maxPixels`, for attachments sent as they are.
    static func shrunk(_ image: UIImage, maxPixels: CGFloat) -> UIImage {
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        guard pixels.width > maxPixels else { return image }
        let size = CGSize(width: maxPixels, height: (pixels.height * maxPixels / pixels.width).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// Copies rows of a capture, given in points, into the snapshot, on whole pixels of both.
    private static func draw(
        _ capture: UIImage,
        pointWidth: CGFloat,
        rowsFrom minY: CGFloat,
        height: CGFloat,
        into destination: CGRect
    ) {
        guard let image = capture.cgImage, pointWidth > 0 else { return }
        let ratio = CGFloat(image.width) / pointWidth
        let first = (minY * ratio).rounded()
        let source = CGRect(
            x: 0,
            y: first,
            width: CGFloat(image.width),
            height: ((minY + height) * ratio).rounded() - first
        )
        .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !source.isEmpty, let rows = image.cropping(to: source) else { return }
        UIImage(cgImage: rows).draw(in: destination)
    }

    /// Where the screen was scrolled past without a capture.
    private static func drawGap(_ gap: CGRect) {
        UIColor(white: 0.9, alpha: 1).setFill()
        UIRectFill(gap)
        let text = "Scrolled past" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: UIColor(white: 0.45, alpha: 1),
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: CGPoint(x: gap.midX - size.width / 2, y: gap.midY - size.height / 2), withAttributes: attributes)
    }

    /// A red outline with the note's number in a red circle at its top-left corner.
    ///
    /// Red reads on almost any app and is the usual color for markup.
    private static func draw(_ outline: Outline, within visible: CGRect) {
        let quiet = outline.style == .quiet
        let red = UIColor.systemRed.withAlphaComponent(quiet ? 0.55 : 1)
        let box = UIBezierPath(roundedRect: outline.rect.insetBy(dx: -3, dy: -3), cornerRadius: 6)
        box.lineWidth = quiet ? 2 : 3
        red.setStroke()
        box.stroke()

        let diameter: CGFloat = 22
        let center = CGPoint(
            x: min(max(outline.rect.minX - 3, visible.minX + diameter / 2 + 2), visible.maxX - diameter / 2 - 2),
            y: min(max(outline.rect.minY - 3, visible.minY + diameter / 2 + 2), visible.maxY - diameter / 2 - 2)
        )
        let badge = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
        UIColor.white.withAlphaComponent(quiet ? 0.7 : 1).setFill()
        UIBezierPath(ovalIn: badge.insetBy(dx: -1.5, dy: -1.5)).fill()
        red.setFill()
        UIBezierPath(ovalIn: badge).fill()
        let number = "\(outline.number)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold),
            .foregroundColor: UIColor.white,
        ]
        let size = number.size(withAttributes: attributes)
        number.draw(
            at: CGPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2),
            withAttributes: attributes
        )
    }
}
#endif
