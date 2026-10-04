#if os(macOS)
import Foundation

/// What a chat gets for one report: who sent it and where its files are, the summary to read first,
/// then every picture.
///
/// Pictures also go by path, for agents that don't show images.
enum ReportContent {
    enum Item: Equatable {
        case text(String)
        case image(file: URL, data: Data)
    }

    /// The pictures a report refers to, in the order its summary lists them: each screen's
    /// pictures, then attachments.
    ///
    /// Without a report.json that lists them, the folder's pictures by name. Only regular files
    /// directly in the report's folder: the phone or simulator wrote report.json, so a name that
    /// leads out of the folder, or a link to another file on the Mac, is left out.
    static func pictures(in folder: URL) -> [URL] {
        pictures(in: folder, listing: ReportListing.load(from: folder))
    }

    /// The same, from a listing already read; nil when the report has none.
    static func pictures(in folder: URL, listing: ReportListing?) -> [URL] {
        let names: [String]
        if let listing, let screens = listing.screens, let items = listing.items,
            let attachments = items.map(\.attachments).allPresent()
        {
            names = screens.flatMap { $0.images.map(\.file) } + attachments.flatMap { $0 }
        } else {
            names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
                .filter { $0.hasSuffix(".jpg") || $0.hasSuffix(".png") }.sorted()
        }
        return names.compactMap { file($0, in: folder) }.filter {
            (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.type] as? FileAttributeType == .typeRegular
        }
    }

    /// The file a report names, when the name is a plain file name in its folder.
    private static func file(_ name: String, in folder: URL) -> URL? {
        Hub.isSafeName(name) ? folder.appending(path: name) : nil
    }

    /// The report as an agent reads it in a chat: each picture's path, then the notes on it,
    /// numbered like the outlines drawn in the picture, with the element each note is about.
    ///
    /// Nothing else. Without a complete report.json, the header and report.md.
    static func text(for report: InboxReport) -> String {
        guard let listing = ReportListing.load(from: report.folder), let app = listing.app,
            let screens = listing.screens,
            let images = screens.flatMap(\.images).map({ image in image.notes.map { (file: image.file, notes: $0) } })
                .allPresent(),
            let items = listing.items?.map(Note.init).allPresent()
        else { return header(for: report) + "\n" + summary(of: report).trimmingCharacters(in: .whitespacesAndNewlines) }
        let byNumber = Dictionary(items.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
        var blocks: [String] = []
        for image in images {
            let notes = image.notes.compactMap { byNumber[$0] }.map(line)
            blocks.append(
                ([file(image.file, in: report.folder)?.path].compactMap { $0 } + notes).joined(separator: "\n")
            )
        }
        for item in items where !item.attachments.isEmpty {
            blocks.append(
                (item.attachments.compactMap { file($0, in: report.folder)?.path } + [line(item)]).joined(
                    separator: "\n"
                )
            )
        }
        return (["UI report from \(report.source.deviceName) · \(app.name ?? report.source.bundleID)"] + blocks).joined(
            separator: "\n\n"
        )
    }

    /// An item with everything the summary says about it.
    private struct Note {
        var number: Int
        var title: String
        var note: String
        var element: ReportListing.Item.Element?
        /// The elements holding it, innermost first.
        var ancestors: [ReportListing.Item.Element]
        var attachments: [String]

        init?(_ item: ReportListing.Item) {
            guard let number = item.number, let title = item.title, let note = item.note,
                let attachments = item.attachments
            else { return nil }
            self.number = number
            self.title = title
            self.note = note
            element = item.element
            ancestors = item.ancestors ?? []
            self.attachments = attachments
        }
    }

    /// "1. Log milestone (Button, today.milestones), in Cell "Milestones" (today.list): This is
    /// ugly".
    ///
    /// The elements holding it, innermost first, tell apart elements that share a label.
    private static func line(_ item: Note) -> String {
        let element = item.element
        let name = element?.label ?? element?.identifier ?? item.title
        let details = [element?.role, element?.identifier == name ? nil : element?.identifier].compactMap { $0 }.joined(
            separator: ", "
        )
        let inside = item.ancestors.compactMap(\.description)
        let note = item.note.isEmpty ? "No note" : item.note
        return "\(item.number). \(name)\(details.isEmpty ? "" : " (\(details))")"
            + (inside.isEmpty ? "" : ", in " + inside.joined(separator: " in ")) + ": \(note)"
    }

    /// The most of a report's text a reply carries; the rest stays in its report.md.
    ///
    /// Notes are typed on a phone, so this is far more than one has unless a long text was pasted in.
    static let longestText = 50_000

    /// The report's items, with pictures attached while `budget` bytes allow; the rest are named by
    /// path.
    ///
    /// Returns the items and the bytes of text and pictures they hold.
    static func items(for report: InboxReport, budget: Int) -> (items: [Item], bytes: Int) {
        let pictures = pictures(in: report.folder)
        var header = header(for: report)
        if !pictures.isEmpty {
            header += "Pictures: " + pictures.map(\.lastPathComponent).joined(separator: ", ") + ", attached below.\n"
        }
        let text = shortened(
            header + "\n" + summary(of: report),
            to: longestText,
            rest: "\n\nThe rest is in \(report.folder.appending(path: "report.md").path)."
        )
        var items: [Item] = [.text(text)]
        var used = text.utf8.count
        for picture in pictures {
            guard let data = try? Data(contentsOf: picture) else { continue }
            if used + data.count > budget {
                items.append(
                    .text(
                        "\(picture.lastPathComponent) isn't attached, to keep this reply small. Open it at \(picture.path)."
                    )
                )
                continue
            }
            items.append(.text(picture.lastPathComponent + ":"))
            items.append(.image(file: picture, data: data))
            used += data.count
        }
        return (items, used)
    }

    /// `text` cut to at most `limit` bytes of UTF-8, ending with `rest` when cut.
    static func shortened(_ text: String, to limit: Int, rest: String) -> String {
        guard text.utf8.count > limit else { return text }
        var length = max(limit - rest.utf8.count, 0)
        // Cut where a character starts.
        while length > 0, String(text.utf8.prefix(length)) == nil { length -= 1 }
        return (String(text.utf8.prefix(length)) ?? "") + rest
    }

    private static func header(for report: InboxReport) -> String {
        let source = report.source
        return
            "Report \(source.reportID) from \(source.deviceName) (\(source.kind == .phone ? "iPhone" : "simulator")), "
            + "app \(source.bundleID), received \(source.receivedAt.formatted(date: .abbreviated, time: .shortened)).\n"
            + "Folder: \(report.folder.path)\n"
    }

    private static func summary(of report: InboxReport) -> String {
        // A report without its summary reads as the header alone.
        (try? String(contentsOf: report.folder.appending(path: "report.md"), encoding: .utf8)) ?? ""
    }
}
#endif
