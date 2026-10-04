#if REDLINE && canImport(UIKit)
import UIKit

/// Turns a draft into the report the agent reads: one picture per screen with every note on it
/// outlined and numbered (stitched, and sent in parts, when the screen scrolled), each attachment,
/// and the links between screens, pictures and notes.
///
/// Runs off the main thread.
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

    /// A picture that couldn't be read or encoded.
    ///
    /// Building stops so the draft is restored and can be sent again, instead of sending a report
    /// with the picture left out.
    struct PictureFailed: LocalizedError, Equatable {
        var file: String

        var errorDescription: String? { "Couldn't make the picture \(file)" }
    }

    static func build(_ input: Input) throws -> Report {
        let scale = ReportRenderer.sendScale
        let numbers = Dictionary(uniqueKeysWithValues: input.annotations.enumerated().map { ($1.id, $0 + 1) })
        var items = Dictionary(
            uniqueKeysWithValues: input.annotations.enumerated().map { index, annotation in
                (
                    index + 1,
                    Report.Item(
                        number: index + 1,
                        kind: annotation.kind,
                        note: annotation.note,
                        createdAt: annotation.createdAt,
                        // The element's whole name: the agent searches the code for it, so nothing is cut short.
                        title: annotation.element?.fullName ?? annotation.title,
                        element: annotation.element,
                        ancestors: annotation.ancestors,
                        screen: nil,
                        screenTitle: annotation.screen?.title,
                        picture: nil,
                        outline: nil,
                        attachments: []
                    )
                )
            }
        )

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
                // The newest group is the screen as it is; older groups are its earlier states.
                let earlier = groupIndex < groups.count - 1
                let base = earlier ? "\(screenID)-earlier-\(groupIndex + 1)" : screenID
                // A capture that can't be read would leave part of the picture blank.
                var images: [UUID: UIImage] = [:]
                for capture in group {
                    guard
                        let image = UIImage(
                            contentsOfFile: input.draft.appending(path: capture.file).path(percentEncoded: false)
                        )
                    else {
                        Log.report.error("Couldn't load capture \(capture.file, privacy: .public)")
                        throw PictureFailed(file: "\(base).jpg")
                    }
                    images[capture.id] = image
                }
                let outlines = notes.compactMap { note -> ReportRenderer.Outline? in
                    guard let number = numbers[note.id], let frame = note.element?.frame,
                        let captureID = note.captureID,
                        let rect = plan.position(of: frame, from: captureID)
                    else { return nil }
                    return ReportRenderer.Outline(number: number, rect: rect, style: .normal)
                }
                screenNotes += outlines.map(\.number)

                // Everything that was on screen, where it sits in the picture, so cuts fall between rows and sections.
                let onScreen = group.flatMap { capture in
                    capture.elements.compactMap { plan.position(of: $0.frame, from: capture.id) }
                }
                let parts = ScreenComposition.parts(
                    height: plan.size.height,
                    maxHeight: group[0].size.height * ScreenComposition.screensPerPicture,
                    keepingWhole: outlines.map(\.rect),
                    avoiding: onScreen,
                    preferring: plan.gaps.map(\.rect.midY)
                )
                // One entry per part, so indices stay matched to `parts`.
                var files: [String] = []
                for (partIndex, rows) in parts.enumerated() {
                    let file = partIndex == 0 ? "\(base).jpg" : "\(base)-part-\(partIndex + 1).jpg"
                    let image = ReportRenderer.render(
                        plan,
                        pictures: images,
                        outlines: outlines,
                        rows: rows,
                        scale: scale
                    )
                    guard let data = ReportRenderer.jpeg(image) else {
                        Log.report.error("Couldn't encode \(file, privacy: .public)")
                        throw PictureFailed(file: file)
                    }
                    try data.write(to: input.folder.appending(path: file), options: .atomic)
                    files.append(file)
                    let shown = CGRect(
                        x: 0,
                        y: rows.lowerBound,
                        width: plan.size.width,
                        height: rows.upperBound - rows.lowerBound
                    )
                    let skipped = plan.gaps.filter { shown.intersects($0.rect) }.map(\.skippedHeight).reduce(0, +)
                    pictures.append(
                        Report.Picture(
                            file: file,
                            part: partIndex + 1,
                            parts: parts.count,
                            stitchedFrom: plan.stitchedFrom,
                            isEarlierState: earlier,
                            notes: outlines.filter { $0.rect.intersects(shown) }.map(\.number).sorted(),
                            width: Int((image.size.width * image.scale).rounded()),
                            height: Int((image.size.height * image.scale).rounded()),
                            scrolledPast: skipped > 0 ? Int(skipped.rounded()) : nil
                        )
                    )
                }
                // Each note points at the part that shows most of its outline.
                for outline in outlines {
                    let best =
                        parts.indices.max { overlap(outline.rect, parts[$0]) < overlap(outline.rect, parts[$1]) } ?? 0
                    guard files.indices.contains(best) else { continue }
                    let file = files[best]
                    let rect = outline.rect.offsetBy(dx: 0, dy: -parts[best].lowerBound)
                    items[outline.number]?.screen = screenID
                    items[outline.number]?.picture = file
                    items[outline.number]?.outline = Report.Box(
                        x: Int((rect.minX * scale).rounded()),
                        y: Int((rect.minY * scale).rounded()),
                        width: Int((rect.width * scale).rounded()),
                        height: Int((rect.height * scale).rounded())
                    )
                }
            }
            screens.append(
                Report.Screen(
                    id: screenID,
                    title: entry.record.info.title,
                    viewController: entry.record.info.viewController,
                    notes: Array(Set(screenNotes)).sorted(),
                    images: pictures
                )
            )
        }

        // Attachments, and element notes made before screens shared one picture, keep their own images.
        for annotation in input.annotations where annotation.captureID == nil {
            guard let number = numbers[annotation.id] else { continue }
            var files: [String] = []
            for (index, name) in annotation.screenshots.enumerated() {
                let file = annotation.screenshots.count == 1 ? "note-\(number).jpg" : "note-\(number)-\(index + 1).jpg"
                guard let image = UIImage(contentsOfFile: input.draft.appending(path: name).path(percentEncoded: false))
                else {
                    Log.report.error("Couldn't load attachment \(name, privacy: .public)")
                    throw PictureFailed(file: file)
                }
                // Captures of the app's own screen are sent at the same size as screen pictures.
                let pointWidth = image.size.width * image.scale / 2
                let sized =
                    annotation.kind == .photo
                    ? image : ReportRenderer.shrunk(image, maxPixels: (pointWidth * scale).rounded())
                guard let data = ReportRenderer.jpeg(sized) else {
                    Log.report.error("Couldn't encode \(file, privacy: .public)")
                    throw PictureFailed(file: file)
                }
                try data.write(to: input.folder.appending(path: file), options: .atomic)
                files.append(file)
            }
            if annotation.kind == .element, let file = files.first, let frame = annotation.element?.frame {
                items[number]?.picture = file
                items[number]?.outline = Report.Box(
                    x: Int((frame.minX * scale).rounded()),
                    y: Int((frame.minY * scale).rounded()),
                    width: Int((frame.width * scale).rounded()),
                    height: Int((frame.height * scale).rounded())
                )
            } else {
                items[number]?.attachments = files
            }
        }

        return Report(
            id: input.id,
            createdAt: input.date,
            app: input.app,
            device: input.device,
            screens: screens,
            items: items.keys.sorted().compactMap { items[$0] },
            destination: input.destination
        )
    }

    private static func overlap(_ rect: CGRect, _ rows: ClosedRange<CGFloat>) -> CGFloat {
        max(0, min(rect.maxY, rows.upperBound) - max(rect.minY, rows.lowerBound))
    }
}
#endif
