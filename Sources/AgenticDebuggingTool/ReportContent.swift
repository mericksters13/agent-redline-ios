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
    /// pictures, then attachments.
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
        return names.map { folder.appending(path: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The report as text, its pictures named by path for the agent to open: for agents that
    /// get reports through hooks.
    static func text(for report: InboxReport) -> String {
        let pictures = pictures(in: report.folder)
        var text = header(for: report) + "\n" + summary(of: report).trimmingCharacters(in: .whitespacesAndNewlines)
        if !pictures.isEmpty {
            text += "\n\nPictures, in the order above:\n" + pictures.map(\.path).joined(separator: "\n")
        }
        return text
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
        (try? String(contentsOf: report.folder.appending(path: "report.md"), encoding: .utf8)) ?? ""
    }
}
#endif
