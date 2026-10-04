#if REDLINE
import Foundation

/// What Send produces, for the agent: one picture per screen with every note on it outlined and
/// numbered, and every note and attachment in the order the phone numbered them.
///
/// Screens, pictures and notes point at each other, so the agent can go either way.
struct Report: Codable, Sendable {
    /// The app the report came from.
    struct App: Codable, Sendable {
        var bundleID: String?
        var name: String?
        var version: String?
        var build: String?
        /// The project file that attached the kit, naming the worktree the app was built from.
        var sourceFile: String? = nil

        private enum CodingKeys: String, CodingKey {
            case bundleID = "bundleIdentifier"
            case name, version, build, sourceFile
        }
    }

    /// Where the user picked for the report to go, on the phone.
    struct Destination: Codable, Equatable, Sendable {
        /// `claude`, `codex` or `cursor`.
        var agent: String
        /// The agent's ID for the chat; nil for a new chat in the worktree the app was built from.
        var chat: String?
        /// What the phone showed, for its own messages.
        var title: String
        /// Names a "New chat" pick: its first report starts the chat, later ones go to that chat,
        /// until the user picks again.
        var newChat: String? = nil

        /// The same choice in the picker: the same chat, or "New chat" for the same agent.
        func isSameChoice(as other: Destination?) -> Bool {
            other?.agent == agent && other?.chat == chat
        }
    }

    /// The phone the report came from.
    struct Device: Codable, Sendable {
        var model: String
        var systemName: String
        var systemVersion: String
    }

    /// A screen notes were made on, and its pictures.
    struct Screen: Codable, Equatable, Sendable {
        var id: String
        var title: String?
        var viewController: String?
        /// The numbers of the notes made on this screen.
        var notes: [Int]
        /// Usually one picture.
        ///
        /// A screen that scrolled may be stitched into one tall picture sent in parts; a screen
        /// whose content changed between notes keeps a picture of its earlier state for the notes
        /// that weren't on the newer one.
        var images: [Picture]
    }

    /// One picture of a screen, or one part of a tall one.
    struct Picture: Codable, Equatable, Sendable {
        var file: String
        /// Which part of the screen's picture this is, counting from 1, and how many parts.
        var part: Int
        var parts: Int
        /// How many captures at different scroll positions were stitched into the picture.
        var stitchedFrom: Int
        /// True for a picture of the screen before its content changed.
        var isEarlierState: Bool
        /// The notes outlined on this part.
        var notes: [Int]
        var width: Int
        var height: Int
        /// Points of content scrolled past between captures and not shown, marked "Scrolled past"
        /// in the picture.
        ///
        /// Nil when nothing was skipped.
        var scrolledPast: Int? = nil

        private enum CodingKeys: String, CodingKey {
            case file, part, parts, stitchedFrom, notes, width, height, scrolledPast
            case isEarlierState = "earlierState"
        }
    }

    /// A box in a picture's pixels.
    struct Box: Codable, Equatable, Sendable {
        var x: Int
        var y: Int
        var width: Int
        var height: Int
    }

    /// A note or an attachment, numbered as on the phone.
    struct Item: Codable, Equatable, Sendable {
        var number: Int
        var kind: Annotation.Kind
        var note: String
        var createdAt: Date
        var title: String
        var element: ElementSnapshot?
        var ancestors: [ElementSnapshot]
        /// The screen it was made on, matching a `Screen.id`.
        var screen: String?
        var screenTitle: String?
        /// The picture its outline is drawn on, and where.
        var picture: String?
        var outline: Box?
        /// Attached images, for whole-screen captures and photos.
        var attachments: [String]
    }

    var id: String
    var createdAt: Date
    var app: App
    var device: Device
    var screens: [Screen]
    var items: [Item]
    /// Nil when the user didn't pick: the Mac sends it to the chat working in the worktree.
    var destination: Destination? = nil
    /// The version of this format, raised when a field changes meaning or is removed.
    ///
    /// Nil in reports written before the format had a version, which read as version 1.
    var version: Int? = 1
}

extension Report {
    /// The screens it covers, for the list of sent reports.
    var screenNames: String {
        var seen = Set<String>()
        let names = screens.map { $0.title ?? $0.viewController ?? "Untitled" }.filter { seen.insert($0).inserted }
        guard !names.isEmpty else { return items.count == 1 ? "Attachment" : "Attachments" }
        return names.joined(separator: ", ")
    }

    /// How much it holds, such as "3 notes, 1 screen".
    var contents: String {
        let notes = countPhrase(items.count, singular: "note", plural: "notes")
        guard !screens.isEmpty else { return notes }
        return notes + ", " + countPhrase(screens.count, singular: "screen", plural: "screens")
    }
}
#endif
