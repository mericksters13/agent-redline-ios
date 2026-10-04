#if REDLINE && canImport(UIKit)
import UIKit

/// Draws a screen's picture from its captures, with each note's outline and number.
/// Safe to use off the main thread.
enum ReportRenderer {
    /// Pixels per point in sent pictures. A phone screen comes out about 1,200 pixels tall:
    /// sharp enough to read every label, small enough that agents don't shrink it and its
    /// JPEG stays near 90 KB.
    static let sendScale: CGFloat = 1.4

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

    /// Draws the rows `rows` of the plan's picture, all of it by default.
    ///
    /// The pieces are placed on whole pixels. A piece that starts or ends partway through a
    /// pixel leaves that pixel row or column partly uncovered, and the background shows
    /// through as a faint line.
    static func render(_ plan: ImagePlan, pictures: [UUID: UIImage], outlines: [Outline], rows: ClosedRange<CGFloat>? = nil, scale: CGFloat) -> UIImage {
        func pixel(_ points: CGFloat) -> CGFloat { (points * scale).rounded() }
        let rows = rows ?? 0...plan.size.height
        let visible = CGRect(x: 0, y: rows.lowerBound, width: plan.size.width, height: rows.upperBound - rows.lowerBound)
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
                let destination = CGRect(x: 0, y: minY, width: size.width, height: pixel(segment.destinationY + segment.height) - top - minY)
                guard destination.maxY > 0, destination.minY < size.height, let picture = pictures[segment.capture],
                      let capture = plan.captures[segment.capture] else { continue }
                draw(picture, pointWidth: capture.size.width, rowsFrom: segment.sourceMinY, height: segment.height, into: destination)
            }
            context.cgContext.translateBy(x: 0, y: -top)
            context.cgContext.scaleBy(x: scale, y: scale)
            for gap in plan.gaps where gap.intersects(visible) {
                drawGap(CGRect(x: 0, y: pixel(gap.minY) / scale, width: size.width / scale, height: (pixel(gap.maxY) - pixel(gap.minY)) / scale))
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

    /// Copies rows of a capture, given in points, into the picture, on whole pixels of both.
    private static func draw(_ picture: UIImage, pointWidth: CGFloat, rowsFrom minY: CGFloat, height: CGFloat, into destination: CGRect) {
        guard let image = picture.cgImage, pointWidth > 0 else { return }
        let ratio = CGFloat(image.width) / pointWidth
        let first = (minY * ratio).rounded()
        let source = CGRect(x: 0, y: first, width: CGFloat(image.width), height: ((minY + height) * ratio).rounded() - first)
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

    /// A red outline with the note's number in a red circle at its top-left corner. Red reads
    /// on almost any app and is the usual color for markup.
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
        number.draw(at: CGPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2), withAttributes: attributes)
    }
}

/// Turns a draft into the report the agent reads: one picture per screen with every note on
/// it outlined and numbered (stitched, and sent in parts, when the screen scrolled), each
/// attachment, and the links between screens, pictures and notes. Runs off the main thread.
enum ReportBuilder {
    struct Input: Sendable {
        var id: String
        var date: Date
        var app: Report.App
        var device: Report.Device
        var annotations: [Annotation]
        var screens: [ScreenRecord]
        /// Where the draft's captures and images are.
        var draft: URL
        /// Where the report's pictures go.
        var folder: URL
        var destination: Report.Destination? = nil
    }

    static func build(_ input: Input) throws -> Report {
        let scale = ReportRenderer.sendScale
        let numbers = Dictionary(uniqueKeysWithValues: input.annotations.enumerated().map { ($1.id, $0 + 1) })
        var items = Dictionary(uniqueKeysWithValues: input.annotations.enumerated().map { index, annotation in
            (index + 1, Report.Item(
                number: index + 1, kind: annotation.kind, note: annotation.note, createdAt: annotation.createdAt,
                // The element's whole name: the agent searches the code for it, so nothing is cut short.
                title: annotation.element.flatMap { $0.label ?? $0.identifier ?? $0.value } ?? annotation.title,
                element: annotation.element, ancestors: annotation.ancestors,
                screen: nil, screenTitle: annotation.screen?.title, picture: nil, outline: nil, attachments: []
            ))
        })

        // Screens in the order of their first note.
        let ordered = input.screens.compactMap { record -> (record: ScreenRecord, first: Int)? in
            let ids = Set(record.captures.map(\.id))
            let first = input.annotations.compactMap { annotation in
                annotation.captureID.flatMap { ids.contains($0) ? numbers[annotation.id] : nil }
            }.min()
            return first.map { (record, $0) }
        }.sorted { $0.first < $1.first }

        var screens: [Report.Screen] = []
        for (screenIndex, entry) in ordered.enumerated() {
            let screenID = "screen-\(screenIndex + 1)"
            let groups = entry.record.groups
            var pictures: [Report.Picture] = []
            var screenNotes: [Int] = []
            for (groupIndex, group) in groups.enumerated() {
                let ids = Set(group.map(\.id))
                let notes = input.annotations.filter { $0.captureID.map(ids.contains) ?? false }
                guard !notes.isEmpty, let plan = ScreenComposition.plan(for: group) else { continue }
                let images = Dictionary(uniqueKeysWithValues: group.compactMap { capture in
                    UIImage(contentsOfFile: input.draft.appending(path: capture.file).path).map { (capture.id, $0) }
                })
                let outlines = notes.compactMap { note -> ReportRenderer.Outline? in
                    guard let number = numbers[note.id], let frame = note.element?.frame, let captureID = note.captureID,
                          let rect = plan.place(frame, from: captureID) else { return nil }
                    return ReportRenderer.Outline(number: number, rect: rect, style: .normal)
                }
                screenNotes += outlines.map(\.number)

                // The newest group is the screen as it is; older groups are its earlier states.
                let earlier = groupIndex < groups.count - 1
                let base = earlier ? "\(screenID)-earlier-\(groupIndex + 1)" : screenID
                // Everything that was on screen, where it sits in the picture, so cuts fall between rows and sections.
                let onScreen = group.flatMap { capture in
                    capture.elements.compactMap { plan.place($0.frame, from: capture.id) }
                }
                let parts = ScreenComposition.parts(
                    height: plan.size.height,
                    maxHeight: group[0].size.height * ScreenComposition.screensPerPicture,
                    keepingWhole: outlines.map(\.rect),
                    avoiding: onScreen,
                    preferring: plan.gaps.map(\.midY)
                )
                var files: [String] = []
                for (partIndex, rows) in parts.enumerated() {
                    let file = partIndex == 0 ? "\(base).jpg" : "\(base)-part-\(partIndex + 1).jpg"
                    let image = ReportRenderer.render(plan, pictures: images, outlines: outlines, rows: rows, scale: scale)
                    guard let data = ReportRenderer.jpeg(image) else { continue }
                    try data.write(to: input.folder.appending(path: file), options: .atomic)
                    files.append(file)
                    let shown = CGRect(x: 0, y: rows.lowerBound, width: plan.size.width, height: rows.upperBound - rows.lowerBound)
                    let skipped = zip(plan.gaps, plan.skipped).filter { shown.intersects($0.0) }.map(\.1).reduce(0, +)
                    pictures.append(Report.Picture(
                        file: file, part: partIndex + 1, parts: parts.count, stitchedFrom: plan.stitchedFrom, earlierState: earlier,
                        notes: outlines.filter { $0.rect.intersects(shown) }.map(\.number).sorted(),
                        width: Int((image.size.width * image.scale).rounded()), height: Int((image.size.height * image.scale).rounded()),
                        scrolledPast: skipped > 0 ? Int(skipped.rounded()) : nil
                    ))
                }
                // Each note points at the part that shows most of its outline.
                for outline in outlines {
                    let best = parts.indices.max { overlap(outline.rect, parts[$0]) < overlap(outline.rect, parts[$1]) } ?? 0
                    guard files.indices.contains(best) else { continue }
                    let rect = outline.rect.offsetBy(dx: 0, dy: -parts[best].lowerBound)
                    items[outline.number]?.screen = screenID
                    items[outline.number]?.picture = files[best]
                    items[outline.number]?.outline = Report.Box(
                        x: Int((rect.minX * scale).rounded()), y: Int((rect.minY * scale).rounded()),
                        width: Int((rect.width * scale).rounded()), height: Int((rect.height * scale).rounded())
                    )
                }
            }
            screens.append(Report.Screen(
                id: screenID, title: entry.record.info.title, viewController: entry.record.info.viewController,
                notes: Array(Set(screenNotes)).sorted(), images: pictures
            ))
        }

        // Attachments, and element notes made before screens shared one picture, keep their own images.
        for annotation in input.annotations where annotation.captureID == nil {
            guard let number = numbers[annotation.id] else { continue }
            var files: [String] = []
            for (index, name) in annotation.screenshots.enumerated() {
                guard let image = UIImage(contentsOfFile: input.draft.appending(path: name).path) else { continue }
                // Captures of the app's own screen are sent at the same size as screen pictures.
                let pointWidth = image.size.width * image.scale / 2
                let sized = annotation.kind == .photo ? image : ReportRenderer.shrunk(image, maxPixels: (pointWidth * scale).rounded())
                guard let data = ReportRenderer.jpeg(sized) else { continue }
                let file = annotation.screenshots.count == 1 ? "note-\(number).jpg" : "note-\(number)-\(index + 1).jpg"
                try data.write(to: input.folder.appending(path: file), options: .atomic)
                files.append(file)
            }
            if annotation.kind == .element, let file = files.first, let frame = annotation.element?.frame {
                items[number]?.picture = file
                items[number]?.outline = Report.Box(
                    x: Int((frame.minX * scale).rounded()), y: Int((frame.minY * scale).rounded()),
                    width: Int((frame.width * scale).rounded()), height: Int((frame.height * scale).rounded())
                )
            } else {
                items[number]?.attachments = files
            }
        }

        return Report(
            id: input.id, createdAt: input.date, app: input.app, device: input.device,
            screens: screens, items: items.keys.sorted().compactMap { items[$0] }, destination: input.destination
        )
    }

    private static func overlap(_ rect: CGRect, _ rows: ClosedRange<CGFloat>) -> CGFloat {
        max(0, min(rect.maxY, rows.upperBound) - max(rect.minY, rows.lowerBound))
    }
}
#endif
