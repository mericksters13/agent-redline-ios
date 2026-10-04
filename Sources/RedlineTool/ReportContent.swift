#if os(macOS)
import Foundation

/// report.json as the kit writes it (the kit's `Report`), with every field the Mac reads, read
/// in one place. Fields that some reports leave out are optional, and each reader checks for
/// what it needs, so a report without them reads as it always did.
struct ReportListing: Decodable {
    struct App: Decodable {
        var name: String?
        /// The kit's `#filePath`, an absolute path on the Mac that built the app, in Debug builds.
        var sourceFile: String?
    }

    /// Where the user picked for the report to go, on the phone.
    struct Pick: Decodable {
        var agent: String
        /// Nil for a new chat.
        var chat: String?
        /// Names a "New chat" pick, so its later reports go to the chat its first one started.
        var newChat: String?
    }

    struct Screen: Decodable {
        struct Image: Decodable {
            var file: String
            var notes: [Int]?
        }

        var title: String?
        var images: [Image]
    }

    struct Item: Decodable {
        struct Element: Decodable {
            var identifier: String?
            var label: String?
            var role: String?
        }

        var number: Int?
        var title: String?
        var note: String?
        var element: Element?
        var screenTitle: String?
        var attachments: [String]?
    }

    var app: App?
    var destination: Pick?
    var screens: [Screen]?
    var items: [Item]?

    /// The report's listing; nil when its report.json is missing or isn't one.
    static func load(from folder: URL) -> ReportListing? {
        guard let data = try? Data(contentsOf: folder.appending(path: "report.json")) else { return nil }
        return try? HubPaths.decoder.decode(ReportListing.self, from: data)
    }
}

extension Array {
    /// The values, when none is nil.
    func allPresent<Value>() -> [Value]? where Element == Value? {
        var values: [Value] = []
        for value in self {
            guard let value else { return nil }
            values.append(value)
        }
        return values
    }
}

/// What a chat gets for one report: who sent it and where its files are, the summary to read
/// first, then every picture. Pictures also go by path, for agents that don't show images.
enum ReportContent {
    enum Item: Equatable {
        case text(String)
        case image(file: URL, data: Data)
    }

    /// The pictures a report refers to, in the order its summary lists them: each screen's
    /// pictures, then attachments. Without a report.json that lists them, the folder's pictures
    /// by name.
    static func pictures(in folder: URL) -> [URL] {
        pictures(in: folder, listing: ReportListing.load(from: folder))
    }

    /// The same, from a listing already read; nil when the report has none.
    static func pictures(in folder: URL, listing: ReportListing?) -> [URL] {
        let names: [String]
        if let listing, let screens = listing.screens, let items = listing.items,
           let attachments = items.map(\.attachments).allPresent() {
            names = screens.flatMap { $0.images.map(\.file) } + attachments.flatMap { $0 }
        } else {
            names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
                .filter { $0.hasSuffix(".jpg") || $0.hasSuffix(".png") }.sorted()
        }
        return names.map { folder.appending(path: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The report as an agent reads it in a chat: each picture's path, then the notes on it,
    /// numbered like the outlines drawn in the picture, with the element each note is about.
    /// Nothing else. Without a complete report.json, the header and report.md.
    static func text(for report: InboxReport) -> String {
        guard let listing = ReportListing.load(from: report.folder), let app = listing.app, let screens = listing.screens,
              let images = screens.flatMap(\.images).map({ image in image.notes.map { (file: image.file, notes: $0) } }).allPresent(),
              let items = listing.items?.map(Note.init).allPresent()
        else { return header(for: report) + "\n" + summary(of: report).trimmingCharacters(in: .whitespacesAndNewlines) }
        let byNumber = Dictionary(items.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
        var blocks: [String] = []
        for image in images {
            let notes = image.notes.compactMap { byNumber[$0] }.map(line)
            blocks.append(([report.folder.appending(path: image.file).path] + notes).joined(separator: "\n"))
        }
        for item in items where !item.attachments.isEmpty {
            blocks.append((item.attachments.map { report.folder.appending(path: $0).path } + [line(item)]).joined(separator: "\n"))
        }
        return (["UI report from \(report.source.deviceName) · \(app.name ?? report.source.bundleID)"] + blocks).joined(separator: "\n\n")
    }

    /// An item with everything the summary says about it.
    private struct Note {
        var number: Int
        var title: String
        var note: String
        var element: ReportListing.Item.Element?
        var attachments: [String]

        init?(_ item: ReportListing.Item) {
            guard let number = item.number, let title = item.title, let note = item.note, let attachments = item.attachments else { return nil }
            self.number = number
            self.title = title
            self.note = note
            element = item.element
            self.attachments = attachments
        }
    }

    /// "1. Log milestone (Button, today.milestones): This is ugly".
    private static func line(_ item: Note) -> String {
        let element = item.element
        let name = element?.label ?? element?.identifier ?? item.title
        let details = [element?.role, element?.identifier == name ? nil : element?.identifier].compactMap { $0 }.joined(separator: ", ")
        let note = item.note.isEmpty ? "No note" : item.note
        return "\(item.number). \(name)\(details.isEmpty ? "" : " (\(details))"): \(note)"
    }

    /// The report's items, with pictures attached while `budget` bytes allow; the rest are
    /// named by path. Returns the items and the bytes of pictures attached.
    static func items(for report: InboxReport, budget: Int) -> (items: [Item], bytes: Int) {
        let pictures = pictures(in: report.folder)
        var header = header(for: report)
        if !pictures.isEmpty {
            header += "Pictures: " + pictures.map(\.lastPathComponent).joined(separator: ", ") + ", attached below.\n"
        }
        var items: [Item] = [.text(header + "\n" + summary(of: report))]
        var used = 0
        for picture in pictures {
            guard let data = try? Data(contentsOf: picture) else { continue }
            if used + data.count > budget {
                items.append(.text("\(picture.lastPathComponent) isn't attached, to keep this reply small. Open it at \(picture.path)."))
                continue
            }
            items.append(.text(picture.lastPathComponent + ":"))
            items.append(.image(file: picture, data: data))
            used += data.count
        }
        return (items, used)
    }

    private static func header(for report: InboxReport) -> String {
        let source = report.source
        return "Report \(source.reportID) from \(source.deviceName) (\(source.kind == .phone ? "iPhone" : "simulator")), "
            + "app \(source.bundleID), received \(source.receivedAt.formatted(date: .abbreviated, time: .shortened)).\n"
            + "Folder: \(report.folder.path)\n"
    }

    private static func summary(of report: InboxReport) -> String {
        // A report without its summary reads as the header alone.
        (try? String(contentsOf: report.folder.appending(path: "report.md"), encoding: .utf8)) ?? ""
    }
}
#endif
