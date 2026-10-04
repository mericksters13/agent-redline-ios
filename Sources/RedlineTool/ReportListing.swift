#if os(macOS)
import AppKit
import SwiftUI

/// report.json as the kit writes it (the kit's `Report`), with every field the Mac reads, read in
/// one place.
///
/// Fields that some reports leave out are optional, and each reader checks for what it needs, so a
/// report without them reads as it always did.
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
        struct ListedSnapshot: Decodable {
            var file: String
            var notes: [Int]?
        }

        var title: String?
        var snapshots: [ListedSnapshot]

        private enum CodingKeys: String, CodingKey {
            case title, snapshots
            /// The name version 1 of report.json used for `snapshots`.
            case images
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = try container.decodeIfPresent(String.self, forKey: .title)
            snapshots =
                try container.decodeIfPresent([ListedSnapshot].self, forKey: .snapshots)
                ?? container.decode([ListedSnapshot].self, forKey: .images)
        }
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
#endif
