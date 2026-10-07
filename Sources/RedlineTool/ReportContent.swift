#if os(macOS)
import Foundation

/// What a chat gets for one report: who sent it and where its files are, the summary to read first,
/// then every snapshot.
///
/// Snapshots also go by path, for agents that don't show images.
enum ReportContent {
    enum Item: Equatable {
        case text(String)
        case image(file: URL, data: Data)
    }

    /// The snapshots a report refers to, in the order its summary lists them: each screen's
    /// snapshots, then each note's own snapshots.
    ///
    /// Without a report.json that lists them, the folder's snapshots in name order, which for
    /// UUID names says nothing about the report's order. Only regular files directly in the
    /// report's folder: the phone or simulator wrote report.json, so a name that leads out of the
    /// folder, or a link to another file on the Mac, is left out.
    static func snapshots(in folder: URL) -> [URL] {
        snapshots(in: folder, listing: ReportListing.load(from: folder))
    }

    /// The same, from a listing already read; nil when the report has none.
    static func snapshots(in folder: URL, listing: ReportListing?) -> [URL] {
        let names: [String]
        if let listing, let screens = listing.screens, let items = listing.items,
            let attachments = items.map(\.attachments).allPresent()
        {
            let screenSnapshots = screens.flatMap { $0.snapshots.map(\.file) }
            names =
                screenSnapshots
                + zip(items, attachments).flatMap { item, attachments in
                    ownSnapshots(snapshot: item.snapshot, attachments: attachments, screenSnapshots: screenSnapshots)
                }
        } else {
            names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
                .filter { $0.hasSuffix(".jpg") || $0.hasSuffix(".png") }.sorted()
        }
        return names.compactMap { file($0, in: folder) }.filter {
            (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.type] as? FileAttributeType == .typeRegular
        }
    }

    /// A note's snapshots that aren't a screen's: its attachments, and the picture of an element
    /// note made before notes on one screen shared its snapshot.
    static func ownSnapshots(snapshot: String?, attachments: [String], screenSnapshots: [String]) -> [String] {
        (snapshot.map { screenSnapshots.contains($0) ? [] : [$0] } ?? []) + attachments
    }

    /// The file a report names, when the name is a plain file name in its folder.
    private static func file(_ name: String, in folder: URL) -> URL? {
        Hub.isSafeName(name) ? folder.appending(path: name) : nil
    }

    /// The report as an agent reads it in a chat: each snapshot's path, then, for an earlier state
    /// of a screen or a part of a tall snapshot, the screen and what the snapshot shows, then the
    /// notes on it, numbered like the outlines drawn in the snapshot, with the element each note is
    /// about.
    ///
    /// Nothing else. Without a complete report.json, the header and report.md. A long text is cut
    /// at `longestText`, pointing to report.md for the rest, so it fits in a command's arguments
    /// and a chat message.
    static func text(for report: InboxReport) -> String {
        shortened(
            fullText(for: report),
            to: longestText,
            rest: "\n\nThe rest is in \(report.folder.appending(path: "report.md").path)."
        )
    }

    private static func fullText(for report: InboxReport) -> String {
        guard let listing = ReportListing.load(from: report.folder), let app = listing.app,
            let screens = listing.screens,
            let snapshots = screens.flatMap({ screen in
                screen.snapshots.map { snapshot in
                    snapshot.notes.map { notes in
                        (
                            file: snapshot.file, detail: snapshot.detail.map { "\(screen.title ?? "Screen"), \($0)" },
                            notes: notes
                        )
                    }
                }
            }).allPresent(),
            let items = listing.items?.map(Note.init).allPresent()
        else { return header(for: report) + "\n" + summary(of: report).trimmingCharacters(in: .whitespacesAndNewlines) }
        let byNumber = Dictionary(items.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
        var blocks: [String] = []
        for snapshot in snapshots {
            let notes = snapshot.notes.compactMap { byNumber[$0] }.map(line)
            let path = file(snapshot.file, in: report.folder)?.path
            blocks.append(([path, snapshot.detail].compactMap { $0 } + notes).joined(separator: "\n"))
        }
        let screenSnapshots = snapshots.map(\.file)
        for item in items {
            let own = ownSnapshots(
                snapshot: item.snapshot,
                attachments: item.attachments,
                screenSnapshots: screenSnapshots
            )
            guard !own.isEmpty else { continue }
            blocks.append(
                (own.compactMap { file($0, in: report.folder)?.path } + [line(item)]).joined(separator: "\n")
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
        /// For a drawing, the named elements it encloses; nil for other kinds.
        var encloses: [ReportListing.Item.Element]?
        var enclosedCount: Int?
        /// The snapshot its outline is drawn on.
        var snapshot: String?
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
            encloses = item.encloses
            enclosedCount = item.enclosedCount
            snapshot = item.snapshot
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
        // A group with no name of its own: what it holds is what to search the source for.
        let holding = element.flatMap { element -> String? in
            guard element.label == nil, element.identifier == nil, let contents = element.contents else { return nil }
            return "holding " + contents.map { "\"\($0)\"" }.joined(separator: ", ")
        }
        let details = [element?.role, element?.identifier == name ? nil : element?.identifier, holding]
            .compactMap { $0 }.joined(separator: ", ")
        // What a drawing encloses is what to search the source for.
        let enclosing = item.encloses.map { encloses -> String in
            let named = encloses.compactMap(\.description)
            guard !named.isEmpty else { return ", enclosing nothing named" }
            let more = max((item.enclosedCount ?? named.count) - named.count, 0)
            return ", enclosing " + named.joined(separator: ", ") + (more > 0 ? " and \(more) more" : "")
        }
        let inside = item.ancestors.compactMap(\.description)
        let note = item.note.isEmpty ? "No note" : item.note
        return "\(item.number). \(name)\(details.isEmpty ? "" : " (\(details))")" + (enclosing ?? "")
            + (inside.isEmpty ? "" : ", in " + inside.joined(separator: " in ")) + ": \(note)"
    }

    /// The most of a report's text a reply carries; the rest stays in its report.md.
    ///
    /// Notes are typed on a phone, so this is far more than one has unless a long text was pasted in.
    static let longestText = 50_000

    /// The report's items, with snapshots attached while `budget` bytes allow; the rest are named by
    /// path while that fits, then counted in one line.
    ///
    /// Returns the items and the bytes of text and snapshots they hold.
    static func items(for report: InboxReport, budget: Int) -> (items: [Item], bytes: Int) {
        let snapshots = snapshots(in: report.folder)
        var header = header(for: report)
        if !snapshots.isEmpty {
            header += "Snapshots: " + snapshots.map(\.lastPathComponent).joined(separator: ", ") + ", attached below.\n"
        }
        let text = shortened(
            header + "\n" + summary(of: report),
            to: longestText,
            rest: "\n\nThe rest is in \(report.folder.appending(path: "report.md").path)."
        )
        var items: [Item] = [.text(text)]
        var used = text.utf8.count
        var unnamed = 0
        for snapshot in snapshots {
            // Mapped rather than read: the command line names snapshots by path and never reads
            // their bytes, so a backlog of large reports doesn't fill memory.
            guard let data = try? Data(contentsOf: snapshot, options: .mappedIfSafe) else { continue }
            let label = snapshot.lastPathComponent + ":"
            if used + label.utf8.count + data.count > budget {
                let notice =
                    "\(snapshot.lastPathComponent) isn't attached, to keep this reply small. Open it at \(snapshot.path)."
                guard used + notice.utf8.count <= budget else {
                    unnamed += 1
                    continue
                }
                items.append(.text(notice))
                used += notice.utf8.count
                continue
            }
            items.append(.text(label))
            items.append(.image(file: snapshot, data: data))
            used += label.utf8.count + data.count
        }
        if unnamed > 0 {
            let notice =
                "\(unnamed) more \(unnamed == 1 ? "snapshot isn't" : "snapshots aren't") attached, to keep this reply small. Open them in \(report.folder.path)."
            items.append(.text(notice))
            used += notice.utf8.count
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
