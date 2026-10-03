#if AGENTIC_DEBUGGING
import Foundation

/// The screen an annotation was made on.
struct ScreenInfo: Codable, Equatable, Sendable {
    var title: String?
    var viewController: String?
}

/// One item in a report: a note on a picked element, or an attachment.
struct Annotation: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// An element picked on the live screen.
        case element
        /// The whole screen, captured by the debugger or when a screenshot was taken in the app.
        case screen
        /// Images picked from Photos.
        case photo
    }

    var id: UUID
    var createdAt: Date
    var note: String
    var kind: Kind
    /// The picked element. Nil for attachments.
    var element: ElementSnapshot?
    /// Bigger elements holding the chosen one, innermost first.
    var ancestors: [ElementSnapshot]
    /// The screen it was made on. Nil for images from Photos, which can come from anywhere.
    var screen: ScreenInfo?
    /// Image file names, in order: the screenshot with the element outlined, the
    /// captured screen, or the images picked from Photos.
    var screenshots: [String]
}

extension Annotation {
    private enum CodingKeys: String, CodingKey {
        case id, createdAt, note, kind, element, ancestors, screen, screenshots
        /// The single screenshot of drafts saved before attachments existed.
        case screenshot
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        note = try container.decode(String.self, forKey: .note)
        element = try container.decodeIfPresent(ElementSnapshot.self, forKey: .element)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? (element == nil ? .screen : .element)
        ancestors = try container.decodeIfPresent([ElementSnapshot].self, forKey: .ancestors) ?? []
        screen = try container.decodeIfPresent(ScreenInfo.self, forKey: .screen)
        if let files = try container.decodeIfPresent([String].self, forKey: .screenshots) {
            screenshots = files
        } else {
            screenshots = [try container.decode(String.self, forKey: .screenshot)]
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(note, forKey: .note)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(element, forKey: .element)
        try container.encode(ancestors, forKey: .ancestors)
        try container.encodeIfPresent(screen, forKey: .screen)
        try container.encode(screenshots, forKey: .screenshots)
    }

    /// What the item shows as its name in the debugger.
    static func title(kind: Kind, element: ElementSnapshot?, screen: ScreenInfo?, imageCount: Int) -> String {
        switch kind {
        case .element: element?.shortName ?? element?.role ?? "Unnamed element"
        case .screen: screen?.title ?? "This screen"
        case .photo: imageCount == 1 ? "Image from Photos" : "\(imageCount) images from Photos"
        }
    }

    /// The line under the name: what kind of item it is and where it was made.
    static func subtitle(kind: Kind, element: ElementSnapshot?, screen: ScreenInfo?) -> String {
        switch kind {
        case .element: [element?.role, screen?.title].compactMap { $0 }.joined(separator: " · ")
        case .screen: "Whole screen"
        case .photo: "Attachment"
        }
    }

    var title: String { Self.title(kind: kind, element: element, screen: screen, imageCount: screenshots.count) }
    var subtitle: String { Self.subtitle(kind: kind, element: element, screen: screen) }
}

/// What Send produces: every element note and attachment, in the order the agent will number them.
struct Report: Codable, Sendable {
    struct App: Codable, Sendable {
        var bundleIdentifier: String?
        var name: String?
        var version: String?
        var build: String?
    }

    struct Device: Codable, Sendable {
        var model: String
        var systemName: String
        var systemVersion: String
    }

    var id: String
    var createdAt: Date
    var app: App
    var device: Device
    var annotations: [Annotation]
}

/// Keeps the unsent draft and sent reports on disk, so a draft survives the app
/// being killed or reinstalled by a rebuild.
///
/// Layout under `root`:
/// - `draft/annotations.json` and the images each item refers to
/// - `reports/<id>/report.json` and the images it refers to
struct ReportStore: Sendable {
    let root: URL

    static let standard = ReportStore(root: URL.applicationSupportDirectory.appending(path: "iOSAgenticDebuggingKit", directoryHint: .isDirectory))

    var draftDirectory: URL { root.appending(path: "draft", directoryHint: .isDirectory) }
    var reportsDirectory: URL { root.appending(path: "reports", directoryHint: .isDirectory) }
    private var draftFile: URL { draftDirectory.appending(path: "annotations.json") }

    func loadDraft() -> [Annotation] {
        guard let data = try? Data(contentsOf: draftFile) else { return [] }
        return (try? Self.decoder.decode([Annotation].self, from: data)) ?? []
    }

    func saveDraft(_ annotations: [Annotation]) throws {
        try FileManager.default.createDirectory(at: draftDirectory, withIntermediateDirectories: true)
        try Self.encoder.encode(annotations).write(to: draftFile, options: .atomic)
    }

    func saveScreenshot(_ data: Data, named name: String) throws {
        try FileManager.default.createDirectory(at: draftDirectory, withIntermediateDirectories: true)
        try data.write(to: draftDirectory.appending(path: name), options: .atomic)
    }

    func deleteScreenshot(named name: String) {
        try? FileManager.default.removeItem(at: draftDirectory.appending(path: name))
    }

    /// Moves the draft into a new report folder and clears the draft.
    /// Returns the report folder.
    func send(_ annotations: [Annotation], app: Report.App, device: Report.Device, date: Date) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let id = formatter.string(from: date)
        let folder = reportsDirectory.appending(path: id, directoryHint: .isDirectory)
        let files = FileManager.default
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in annotations.flatMap(\.screenshots) {
            let source = draftDirectory.appending(path: name)
            if files.fileExists(atPath: source.path) {
                try files.moveItem(at: source, to: folder.appending(path: name))
            }
        }
        let report = Report(id: id, createdAt: date, app: app, device: device, annotations: annotations)
        try Self.encoder.encode(report).write(to: folder.appending(path: "report.json"), options: .atomic)
        try? files.removeItem(at: draftDirectory)
        return folder
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
#endif
