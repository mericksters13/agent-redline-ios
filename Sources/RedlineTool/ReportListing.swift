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
            /// Which part of a tall snapshot this is, counting from 1, and how many parts.
            var part: Int?
            var parts: Int?
            /// True for a snapshot of the screen before its content changed.
            var isEarlierState: Bool?

            private enum CodingKeys: String, CodingKey {
                case file, notes, part, parts
                case isEarlierState = "earlierState"
            }

            /// What the snapshot shows besides the screen as it was last, such as "earlier state,
            /// before the screen changed" or "part 2 of 3".
            ///
            /// Nil for the whole screen as it was last. Snapshot file names say nothing, so this is
            /// how a reader tells an earlier state or a part from another screen.
            var detail: String? {
                var details: [String] = []
                if isEarlierState == true { details.append("earlier state, before the screen changed") }
                if let part, let parts, parts > 1 { details.append("part \(part) of \(parts)") }
                return details.isEmpty ? nil : details.joined(separator: ", ")
            }
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
            /// For a group with no identifier or label: the names of the first elements inside it.
            var contents: [String]?
            /// How many named elements the group holds, of which `contents` lists the first.
            var contentCount: Int?

            /// `Cell "Milestones" (today.list)`, or `Group "Beyond the sky" and 2 more` for a group
            /// with no name of its own; nil for an element with no label, identifier or contents.
            var description: String? {
                guard label != nil || identifier != nil else {
                    return contentsName.map { [role, $0].compactMap { $0 }.joined(separator: " ") }
                }
                return [role, label.map { "\"\($0)\"" }, identifier.map { "(\($0))" }].compactMap { $0 }.joined(
                    separator: " "
                )
            }

            /// `"Beyond the sky"`, `"Beyond the sky" and "Unlock"`, or `"Beyond the sky" and 2 more`,
            /// as the kit's `ElementSnapshot.contentsName` names a group.
            var contentsName: String? {
                guard let first = contents?.first else { return nil }
                let count = max(contentCount ?? 0, contents?.count ?? 0)
                switch count {
                case ...1: return "\"\(first)\""
                case 2: return "\"\(first)\" and \"\(contents?.dropFirst().first ?? "")\""
                default: return "\"\(first)\" and \(count - 1) more"
                }
            }
        }

        var number: Int?
        var title: String?
        var note: String?
        var element: Element?
        /// The elements holding it, innermost first.
        ///
        /// Missing in reports from before they were saved.
        var ancestors: [Element]?
        var screenTitle: String?
        /// The snapshot that shows most of the note's outline.
        var snapshot: String?
        var attachments: [String]?

        private enum CodingKeys: String, CodingKey {
            case number, title, note, element, ancestors, screenTitle, snapshot, attachments
            /// The name version 1 of report.json used for `snapshot`.
            case picture
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            number = try container.decodeIfPresent(Int.self, forKey: .number)
            title = try container.decodeIfPresent(String.self, forKey: .title)
            note = try container.decodeIfPresent(String.self, forKey: .note)
            element = try container.decodeIfPresent(Element.self, forKey: .element)
            ancestors = try container.decodeIfPresent([Element].self, forKey: .ancestors)
            screenTitle = try container.decodeIfPresent(String.self, forKey: .screenTitle)
            snapshot =
                try container.decodeIfPresent(String.self, forKey: .snapshot)
                ?? container.decodeIfPresent(String.self, forKey: .picture)
            attachments = try container.decodeIfPresent([String].self, forKey: .attachments)
        }
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
