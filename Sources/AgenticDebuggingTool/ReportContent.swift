#if os(macOS)
import Foundation

/// What a chat gets for one report: who sent it and where its files are, the summary to read
/// first, then every picture. Pictures also go by path, for agents that don't show images.
enum ReportContent {
    enum Item: Equatable {
        case text(String)
        case image(file: URL, data: Data)
    }

    /// The pictures a report refers to, in the order its summary lists them: each screen's
    /// pictures, then attachments. Only regular files directly in the report's folder: the
    /// phone or simulator wrote report.json, so a name that leads out of the folder, or a link
    /// to another file on the Mac, is left out.
    static func pictures(in folder: URL) -> [URL] {
        struct Listing: Decodable {
            struct Screen: Decodable { struct Picture: Decodable { var file: String }; var images: [Picture] }
            struct Item: Decodable { var attachments: [String] }
            var screens: [Screen]
            var items: [Item]
        }
        let listed = (try? Data(contentsOf: folder.appending(path: "report.json")))
            .flatMap { try? JSONDecoder().decode(Listing.self, from: $0) }
            .map { $0.screens.flatMap { $0.images.map(\.file) } + $0.items.flatMap(\.attachments) }
        let names = listed ?? ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix(".jpg") || $0.hasSuffix(".png") }.sorted()
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
    /// Nothing else.
    static func text(for report: InboxReport) -> String {
        guard let data = try? Data(contentsOf: report.folder.appending(path: "report.json")),
              let listing = try? JSONDecoder().decode(Listing.self, from: data)
        else { return header(for: report) + "\n" + summary(of: report).trimmingCharacters(in: .whitespacesAndNewlines) }
        let items = Dictionary(listing.items.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
        var blocks: [String] = []
        for image in listing.screens.flatMap(\.images) {
            let notes = image.notes.compactMap { items[$0] }.map(line)
            blocks.append(([file(image.file, in: report.folder)?.path].compactMap { $0 } + notes).joined(separator: "\n"))
        }
        for item in listing.items where !item.attachments.isEmpty {
            blocks.append((item.attachments.compactMap { file($0, in: report.folder)?.path } + [line(item)]).joined(separator: "\n"))
        }
        let app = listing.app.name ?? report.source.bundleID
        return (["UI report from \(report.source.deviceName) · \(app)"] + blocks).joined(separator: "\n\n")
    }

    /// "1. Log milestone (Button, today.milestones), in Cell "Milestones" (today.list): This is ugly".
    /// The elements holding it, innermost first, tell apart elements that share a label.
    private static func line(_ item: Listing.Item) -> String {
        let element = item.element
        let name = element?.label ?? element?.identifier ?? item.title
        let details = [element?.role, element?.identifier == name ? nil : element?.identifier].compactMap { $0 }.joined(separator: ", ")
        let inside = (item.ancestors ?? []).compactMap(\.description)
        let note = item.note.isEmpty ? "No note" : item.note
        return "\(item.number). \(name)\(details.isEmpty ? "" : " (\(details))")"
            + (inside.isEmpty ? "" : ", in " + inside.joined(separator: " in ")) + ": \(note)"
    }

    /// What `text(for:)` reads from report.json.
    private struct Listing: Decodable {
        struct App: Decodable { var name: String? }
        struct Screen: Decodable {
            struct Image: Decodable {
                var file: String
                var notes: [Int]
            }
            var images: [Image]
        }
        struct Item: Decodable {
            struct Element: Decodable {
                var identifier: String?
                var label: String?
                var role: String?

                /// `Cell "Milestones" (today.list)`; nil for an element with no label or identifier.
                var description: String? {
                    guard label != nil || identifier != nil else { return nil }
                    return [role, label.map { "\"\($0)\"" }, identifier.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
                }
            }
            var number: Int
            var title: String
            var note: String
            var element: Element?
            /// The elements holding it, innermost first. Missing in reports from before they were saved.
            var ancestors: [Element]?
            var attachments: [String]
        }
        var app: App
        var screens: [Screen]
        var items: [Item]
    }

    /// The most of a report's text a reply carries; the rest stays in its report.md. Notes are
    /// typed on a phone, so this is far more than one has unless a long text was pasted in.
    static let longestText = 50_000

    /// The report's items, with pictures attached while `budget` bytes allow; the rest are
    /// named by path. Returns the items and the bytes of text and pictures they hold.
    static func items(for report: InboxReport, budget: Int) -> (items: [Item], bytes: Int) {
        let pictures = pictures(in: report.folder)
        var header = header(for: report)
        if !pictures.isEmpty {
            header += "Pictures: " + pictures.map(\.lastPathComponent).joined(separator: ", ") + ", attached below.\n"
        }
        let text = shortened(header + "\n" + summary(of: report), to: longestText,
                             rest: "\n\nThe rest is in \(report.folder.appending(path: "report.md").path).")
        var items: [Item] = [.text(text)]
        var used = text.utf8.count
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
        return "Report \(source.reportID) from \(source.deviceName) (\(source.kind == .phone ? "iPhone" : "simulator")), "
            + "app \(source.bundleID), received \(source.receivedAt.formatted(date: .abbreviated, time: .shortened)).\n"
            + "Folder: \(report.folder.path)\n"
    }

    private static func summary(of report: InboxReport) -> String {
        (try? String(contentsOf: report.folder.appending(path: "report.md"), encoding: .utf8)) ?? ""
    }
}
#endif
