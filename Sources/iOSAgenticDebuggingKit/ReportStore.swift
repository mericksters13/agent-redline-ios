#if AGENTIC_DEBUGGING
import Foundation

/// The screen an annotation was made on.
struct ScreenInfo: Codable, Equatable, Sendable {
    var title: String?
    var viewController: String?
}

struct Annotation: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var createdAt: Date
    var note: String
    var element: ElementSnapshot
    /// Bigger elements holding the chosen one, innermost first.
    var ancestors: [ElementSnapshot]
    var screen: ScreenInfo
    /// File name of the screenshot with the element outlined.
    var screenshot: String
}

/// What Send produces: every annotation, in the order the agent will number them.
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
/// - `draft/annotations.json` and one PNG per annotation
/// - `reports/<id>/report.json` and the PNGs it references
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

    /// Copies the draft into a new report folder and clears the draft once the report is
    /// complete. If any step fails, the draft stays as it was and no report is left behind.
    /// Returns the report folder.
    func send(_ annotations: [Annotation], app: Report.App, device: Report.Device, date: Date) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: date)
        let files = FileManager.default
        try files.createDirectory(at: reportsDirectory, withIntermediateDirectories: true)

        // Creating the folder itself fails when it exists, so two reports in the same
        // second, or a clock set back, get their own folders instead of sharing one.
        var id = stamp
        var folder = reportsDirectory.appending(path: id, directoryHint: .isDirectory)
        var attempt = 1
        while true {
            do {
                try files.createDirectory(at: folder, withIntermediateDirectories: false)
                break
            } catch CocoaError.fileWriteFileExists where attempt < 100 {
                attempt += 1
                id = "\(stamp)-\(attempt)"
                folder = reportsDirectory.appending(path: id, directoryHint: .isDirectory)
            }
        }

        do {
            for annotation in annotations {
                let source = draftDirectory.appending(path: annotation.screenshot)
                if files.fileExists(atPath: source.path) {
                    try files.copyItem(at: source, to: folder.appending(path: annotation.screenshot))
                }
            }
            let report = Report(id: id, createdAt: date, app: app, device: device, annotations: annotations)
            try Self.encoder.encode(report).write(to: folder.appending(path: "report.json"), options: .atomic)
        } catch {
            try? files.removeItem(at: folder)
            throw error
        }
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
