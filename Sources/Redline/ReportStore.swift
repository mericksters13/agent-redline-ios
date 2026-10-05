#if REDLINE
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
        /// The whole screen, captured by Redline or when a screenshot was taken in the app.
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
    /// Attached images, in order: the captured screen or the images picked from Photos.
    /// Element notes made before screens shared one screenshot keep theirs here, outlined.
    var screenshots: [String]
    /// For an element note, the capture of its screen it was made on. Every note on a
    /// screen shares the screen's picture; outlines are drawn when it's shown or sent.
    var captureID: UUID? = nil

    /// How many pictures the note shows in the viewer.
    var imageCount: Int { captureID != nil ? 1 : screenshots.count }
}

extension Annotation {
    private enum CodingKeys: String, CodingKey {
        case id, createdAt, note, kind, element, ancestors, screen, screenshots, captureID
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
        captureID = try container.decodeIfPresent(UUID.self, forKey: .captureID)
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
        try container.encodeIfPresent(captureID, forKey: .captureID)
    }

    /// What the item shows as its name in Redline.
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

    var title: String { Self.title(kind: kind, element: element, screen: screen, imageCount: imageCount) }
    var subtitle: String { Self.subtitle(kind: kind, element: element, screen: screen) }
}

/// What Send produces, for the agent: one picture per screen with every note on it outlined
/// and numbered, and every note and attachment in the order the phone numbered them.
/// Screens, pictures and notes point at each other, so the agent can go either way.
struct Report: Codable, Sendable {
    struct App: Codable, Sendable {
        var bundleIdentifier: String?
        var name: String?
        var version: String?
        var build: String?
        /// The project file that attached the kit, naming the worktree the app was built from.
        var sourceFile: String? = nil
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
        func sameChoice(as other: Destination?) -> Bool {
            other?.agent == agent && other?.chat == chat
        }
    }

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
        /// Usually one picture. A screen that scrolled may be stitched into one tall picture
        /// sent in parts; a screen whose content changed between notes keeps a picture of its
        /// earlier state for the notes that weren't on the newer one.
        var images: [Picture]
    }

    struct Picture: Codable, Equatable, Sendable {
        var file: String
        /// Which part of the screen's picture this is, counting from 1, and how many parts.
        var part: Int
        var parts: Int
        /// How many captures at different scroll positions were stitched into the picture.
        var stitchedFrom: Int
        /// True for a picture of the screen before its content changed.
        var earlierState: Bool
        /// The notes outlined on this part.
        var notes: [Int]
        var width: Int
        var height: Int
        /// Points of content scrolled past between captures and not shown, marked
        /// "Scrolled past" in the picture. Nil when nothing was skipped.
        var scrolledPast: Int? = nil
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
        let notes = items.count == 1 ? "1 note" : "\(items.count) notes"
        guard !screens.isEmpty else { return notes }
        return notes + ", " + (screens.count == 1 ? "1 screen" : "\(screens.count) screens")
    }
}

/// A report already sent, read back to show on the phone.
struct SentReport: Identifiable, Sendable {
    var report: Report
    /// Where its pictures are.
    var folder: URL
    /// The Mac has confirmed it has the report.
    var delivered = false
    var id: String { report.id }
}

/// The last attempt to hand reports to the Mac, kept so the phone can say why one isn't there.
struct Delivery: Codable, Equatable, Sendable {
    var at: Date
    var outcome: HubLink.Outcome
}

/// The report as text the agent reads first: what was reported, on which screen, and
/// which picture shows each note.
enum ReportSummary {
    static func markdown(_ report: Report) -> String {
        var lines: [String] = []
        let app = [report.app.name ?? report.app.bundleIdentifier ?? "App", report.app.version.map { "\($0)" }, report.app.build.map { "(\($0))" }]
            .compactMap { $0 }.joined(separator: " ")
        lines.append("# UI report: \(app)")
        lines.append("")
        let count = report.items.count
        let screens = report.screens.count
        lines.append("\(report.device.model), \(report.device.systemName) \(report.device.systemVersion). "
            + "\(count == 1 ? "1 note" : "\(count) notes")"
            + (screens > 0 ? " on \(screens == 1 ? "1 screen" : "\(screens) screens")" : "") + ". "
            + "Numbers match the red numbered outlines in the pictures.")
        let items = Dictionary(uniqueKeysWithValues: report.items.map { ($0.number, $0) })

        for screen in report.screens {
            lines.append("")
            lines.append("## Screen: \(screen.title ?? screen.viewController ?? "Untitled")")
            lines.append("")
            let current = screen.images.filter { !$0.earlierState }
            if let first = current.first {
                var description = "One screenshot of this screen"
                if first.stitchedFrom > 1 { description += ", stitched from \(first.stitchedFrom) scroll positions" }
                if current.count > 1 {
                    description += ", in \(current.count) parts: " + current.map(\.file).joined(separator: ", ")
                } else {
                    description += ": \(first.file)"
                }
                let numbers = Array(Set(current.flatMap(\.notes))).sorted()
                let outlined = numbers.count == 1 ? "Note \(list(numbers)) is" : "Notes \(list(numbers)) are"
                lines.append("\(description). \(outlined) outlined and numbered on it.")
                let skipped = current.compactMap(\.scrolledPast).reduce(0, +)
                if skipped > 0 {
                    lines.append("The notes are far apart: about \(skipped) pt of the screen between them wasn't captured and is marked \"Scrolled past\". Those parts aren't next to each other in the layout.")
                }
            }
            for earlier in screen.images where earlier.earlierState {
                lines.append("An earlier state of the same screen, before its content changed: \(earlier.file), with \(earlier.notes.count == 1 ? "note" : "notes") \(list(earlier.notes)).")
            }
            lines.append("")
            for number in screen.notes {
                guard let item = items[number] else { continue }
                lines.append(line(for: item))
            }
        }

        let attachments = report.items.filter { $0.screen == nil }
        if !attachments.isEmpty {
            lines.append("")
            lines.append("## Attachments")
            lines.append("")
            for item in attachments { lines.append(line(for: item)) }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func line(for item: Report.Item) -> String {
        var text = "\(item.number). **\(item.title)**"
        if let element = item.element {
            var details = [element.role]
            if let identifier = element.identifier { details.append("identifier `\(identifier)`") }
            if element.label != nil, element.label != item.title { details.append("label \"\(element.label!)\"") }
            text += " (\(details.joined(separator: ", ")))"
        }
        // The elements holding it, such as the row or card with the identifier, tell apart
        // elements that share a label.
        let inside = item.ancestors.compactMap { ancestor -> String? in
            guard ancestor.label != nil || ancestor.identifier != nil else { return nil }
            return [ancestor.role, ancestor.label.map { "\"\($0)\"" }, ancestor.identifier.map { "`\($0)`" }].compactMap { $0 }.joined(separator: " ")
        }
        if !inside.isEmpty { text += ", in " + inside.joined(separator: " in ") }
        if item.note.isEmpty {
            text += ". No note."
        } else {
            let ended = item.note.last.map { ".!?".contains($0) } ?? false
            text += ": \(item.note)\(ended ? "" : ".")"
        }
        if let picture = item.picture { text += " See \(picture)." }
        if !item.attachments.isEmpty { text += " Images: \(item.attachments.joined(separator: ", "))." }
        return text
    }

    private static func list(_ numbers: [Int]) -> String {
        let words = numbers.map(String.init)
        guard words.count > 1 else { return words.first ?? "" }
        return words.dropLast().joined(separator: ", ") + " and " + words.last!
    }
}

/// Keeps the unsent draft and sent reports on disk, so a draft survives the app
/// being killed or reinstalled by a rebuild.
///
/// Layout under `root`:
/// - `draft/annotations.json`, `draft/screens.json`, the screen captures and attached images
/// - `reports/<id>/report.json`, `reports/<id>/report.md` and the pictures they refer to
struct ReportStore: Sendable {
    /// A draft note whose screenshot file is gone. Sending stops so the draft stays
    /// for recovery instead of producing a report that points at a missing file.
    struct MissingScreenshot: Error, Equatable {
        var annotationID: UUID
    }

    let root: URL

    static let standard: ReportStore = {
        let store = ReportStore(root: URL.applicationSupportDirectory.appending(path: "Redline", directoryHint: .isDirectory))
        store.moveFromOldName()
        return store
    }()

    /// Moves what an earlier version kept under its old name, iOSAgenticDebuggingKit, here, so
    /// the draft and the reports the Mac hasn't collected carry over a rebuild with the new name.
    /// The hub may already have left its address here, so each item moves on its own, and only
    /// when nothing of that name is here yet.
    func moveFromOldName() {
        let old = root.deletingLastPathComponent().appending(path: "iOSAgenticDebuggingKit", directoryHint: .isDirectory)
        let files = FileManager.default
        guard files.fileExists(atPath: old.path) else { return }
        try? files.createDirectory(at: root, withIntermediateDirectories: true)
        func move(from source: URL, to destination: URL) {
            for item in (try? files.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)) ?? [] {
                let target = destination.appending(path: item.lastPathComponent)
                if !files.fileExists(atPath: target.path) { try? files.moveItem(at: item, to: target) }
            }
        }
        move(from: old, to: root)
        // Reports were already here: the old ones join them, each in its own folder.
        move(from: old.appending(path: "reports"), to: reportsDirectory)
        // An older hub address is the only thing left that a newer one replaces. The folders go
        // only when empty (rmdir), so anything else left stays where it is.
        try? files.removeItem(at: old.appending(path: "hub.json"))
        rmdir(old.appending(path: "reports").path)
        rmdir(old.path)
    }

    /// Moves the settings an earlier version saved under its old prefix, AgenticDebugging, to
    /// Redline's, so a report waiting to reach the Mac is still offered again, and the button
    /// stays where it was put. Only what the app saved moves, not launch arguments, and a
    /// setting already saved under the new name is kept.
    static func moveSettingsFromOldName(in defaults: UserDefaults, domain: String) {
        let oldPrefix = "AgenticDebugging"
        guard let saved = defaults.persistentDomain(forName: domain) else { return }
        for (key, value) in saved where key.hasPrefix(oldPrefix) {
            let renamed = "Redline" + key.dropFirst(oldPrefix.count)
            if saved[renamed] == nil { defaults.set(value, forKey: renamed) }
            defaults.removeObject(forKey: key)
        }
    }

    var draftDirectory: URL { root.appending(path: "draft", directoryHint: .isDirectory) }
    var reportsDirectory: URL { root.appending(path: "reports", directoryHint: .isDirectory) }
    /// Drafts that could not be read, each kept whole in its own folder for recovery.
    var unreadableDraftsDirectory: URL { root.appending(path: "unreadable-drafts", directoryHint: .isDirectory) }
    private var draftFile: URL { draftDirectory.appending(path: "annotations.json") }
    private var screensFile: URL { draftDirectory.appending(path: "screens.json") }

    /// The saved draft. A draft whose notes or screens file no longer decodes, such as after
    /// a change to the format, is moved with its screenshots to `unreadableDraftsDirectory`
    /// and an empty draft starts, so the next note can't write over it. Notes on a capture
    /// need the screens file to find their picture, so it can't be dropped on its own.
    func loadDraft() -> [Annotation] {
        guard let data = try? Data(contentsOf: draftFile) else { return [] }
        if let annotations = try? Self.decoder.decode([Annotation].self, from: data), Self.screensAreReadable(in: draftDirectory) {
            return annotations
        }
        let files = FileManager.default
        try? files.createDirectory(at: unreadableDraftsDirectory, withIntermediateDirectories: true)
        try? files.moveItem(at: draftDirectory, to: unreadableDraftsDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory))
        return []
    }

    func saveDraft(_ annotations: [Annotation]) throws {
        try FileManager.default.createDirectory(at: draftDirectory, withIntermediateDirectories: true)
        try Self.encoder.encode(annotations).write(to: draftFile, options: .atomic)
    }

    /// The draft's screens. Call after `loadDraft`, which sets aside a draft whose screens
    /// file doesn't decode.
    func loadScreens() -> [ScreenRecord] {
        guard let data = try? Data(contentsOf: screensFile) else { return [] }
        return (try? Self.decoder.decode([ScreenRecord].self, from: data)) ?? []
    }

    /// False when `folder` has a screens file that doesn't decode.
    private static func screensAreReadable(in folder: URL) -> Bool {
        let file = folder.appending(path: "screens.json")
        return !FileManager.default.fileExists(atPath: file.path) || load([ScreenRecord].self, from: file) != nil
    }

    func saveScreens(_ screens: [ScreenRecord]) throws {
        try FileManager.default.createDirectory(at: draftDirectory, withIntermediateDirectories: true)
        try Self.encoder.encode(screens).write(to: screensFile, options: .atomic)
    }

    func saveScreenshot(_ data: Data, named name: String) throws {
        try FileManager.default.createDirectory(at: draftDirectory, withIntermediateDirectories: true)
        try data.write(to: draftDirectory.appending(path: name), options: .atomic)
    }

    func deleteScreenshot(named name: String) {
        try? FileManager.default.removeItem(at: draftDirectory.appending(path: name))
    }

    /// Throws `MissingScreenshot` for the first note whose picture isn't on disk: a capture
    /// that's gone or no longer listed, or an attached image. Checked before a report takes
    /// the draft, so the draft stays for the note to be deleted and the rest sent.
    func checkScreenshots(of annotations: [Annotation], screens: [ScreenRecord]) throws {
        let files = FileManager.default
        let captures = Dictionary(screens.flatMap(\.captures).map { ($0.id, $0.file) }, uniquingKeysWith: { first, _ in first })
        for annotation in annotations {
            var needed = annotation.screenshots
            if let captureID = annotation.captureID {
                guard let file = captures[captureID] else { throw MissingScreenshot(annotationID: annotation.id) }
                needed.append(file)
            }
            if needed.contains(where: { !files.fileExists(atPath: draftDirectory.appending(path: $0).path) }) {
                throw MissingScreenshot(annotationID: annotation.id)
            }
        }
    }

    /// Starts a report: moves the whole draft into a new report folder, so new notes go into
    /// a fresh draft while the report's pictures are drawn from the old one. If the move
    /// fails, the draft stays as it was and no report folder is left behind.
    /// Returns the report's id, its folder and where the draft now is.
    func beginReport(date: Date) throws -> (id: String, folder: URL, draft: URL) {
        let files = FileManager.default
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: date)
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
        let draft = folder.appending(path: "draft", directoryHint: .isDirectory)
        do {
            try files.moveItem(at: draftDirectory, to: draft)
        } catch {
            try? files.removeItem(at: folder)
            throw error
        }
        return (id, folder, draft)
    }

    /// The most a report's files may add up to: the Mac's hub turns down a bigger one, as
    /// `Hub.largestReport`. Checked before the report is finished, while its notes can still go
    /// back into the draft for photos to be taken out.
    static let largestReport = 50_000_000

    /// A report too big for the Mac to take.
    struct TooLarge: Error, Equatable {
        var bytes: Int
    }

    /// Checks that a report drawn in `folder`, with the summary and listing `finishReport` adds,
    /// fits what the Mac takes. Call before `finishReport`: a finished report can't be changed.
    func checkSize(of report: Report, in folder: URL, limit: Int = Self.largestReport) throws {
        var bytes = Data(ReportSummary.markdown(report).utf8).count + (try Self.encoder.encode(report)).count
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where !name.hasPrefix(".") {
            let values = try? folder.appending(path: name).resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true { continue }
            bytes += values?.fileSize ?? 0
        }
        if bytes > limit { throw TooLarge(bytes: bytes) }
    }

    /// Finishes a report: writes `report.md` and `report.json` and removes the old draft.
    /// `report.json` goes last, so a report is listed as sent only once it is complete.
    func finishReport(_ report: Report, in folder: URL) throws {
        try Data(ReportSummary.markdown(report).utf8).write(to: folder.appending(path: "report.md"), options: .atomic)
        try Self.encoder.encode(report).write(to: folder.appending(path: "report.json"), options: .atomic)
        try? FileManager.default.removeItem(at: folder.appending(path: "draft"))
    }

    /// Takes back the pictures of a report that couldn't be finished, so its notes can go back
    /// into the draft and be sent again. Copies every picture of the report's old draft into
    /// the current one, next to any made since; their names are unique, so none collide. The
    /// report folder stays until `discardReport`, once the notes are saved in the draft again.
    func reclaimPictures(from folder: URL) throws {
        let files = FileManager.default
        let old = folder.appending(path: "draft", directoryHint: .isDirectory)
        let lists = [draftFile.lastPathComponent, screensFile.lastPathComponent]
        try files.createDirectory(at: draftDirectory, withIntermediateDirectories: true)
        for name in try files.contentsOfDirectory(atPath: old.path) where !lists.contains(name) {
            let target = draftDirectory.appending(path: name)
            guard !files.fileExists(atPath: target.path) else { continue }
            try files.copyItem(at: old.appending(path: name), to: target)
        }
    }

    /// Removes a report that was never finished.
    func discardReport(_ folder: URL) {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Brings back reports cut short, such as by the app being killed while their pictures were
    /// drawn. A finished one only loses the draft it was drawn from. An unfinished one's notes,
    /// screens and pictures go back into the draft, ahead of any made since, so they can be sent
    /// again. Call at launch only, before any report starts. Safe to run again after being cut
    /// short itself: notes and screens already back in the draft aren't added twice.
    func recoverInterruptedReports() {
        let files = FileManager.default
        let folders = (try? files.contentsOfDirectory(at: reportsDirectory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        // Newest first, so each older report's notes go ahead of it.
        for folder in folders.sorted(by: { $0.lastPathComponent > $1.lastPathComponent })
        where (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let old = folder.appending(path: "draft", directoryHint: .isDirectory)
            let finished = files.fileExists(atPath: folder.appending(path: "report.json").path)
            guard files.fileExists(atPath: old.path) else {
                // Cut short before the draft moved in: there's nothing to bring back.
                if !finished { discardReport(folder) }
                continue
            }
            if finished {
                try? files.removeItem(at: old)
                continue
            }
            let notesFile = old.appending(path: draftFile.lastPathComponent)
            // Notes or screens that are there but no longer decode, such as after a change to
            // the format, are kept with their pictures for recovery, as an unreadable draft is.
            if (files.fileExists(atPath: notesFile.path) && Self.load([Annotation].self, from: notesFile) == nil)
                || !Self.screensAreReadable(in: old) {
                try? files.createDirectory(at: unreadableDraftsDirectory, withIntermediateDirectories: true)
                if (try? files.moveItem(at: old, to: unreadableDraftsDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory))) != nil {
                    discardReport(folder)
                }
                continue
            }
            do {
                let annotations = Self.load([Annotation].self, from: notesFile) ?? []
                let screens = Self.load([ScreenRecord].self, from: old.appending(path: screensFile.lastPathComponent)) ?? []
                try reclaimPictures(from: folder)
                // The draft is read first, so one that can't be read is set aside before its
                // screens file is written over. Screens are saved first, as when a note is
                // added: a listed screen no note uses is harmless.
                let draft = loadDraft()
                let currentScreens = loadScreens()
                let screenIDs = Set(currentScreens.map(\.id))
                try saveScreens(screens.filter { !screenIDs.contains($0.id) } + currentScreens)
                let noteIDs = Set(draft.map(\.id))
                try saveDraft(annotations.filter { !noteIDs.contains($0.id) } + draft)
                discardReport(folder)
            } catch {
                // Left as it is, to be tried again at the next launch.
                continue
            }
        }
    }

    private static func load<T: Decodable>(_ type: T.Type, from file: URL) -> T? {
        (try? Data(contentsOf: file)).flatMap { try? decoder.decode(type, from: $0) }
    }

    /// Where the Mac's hub leaves its address, over Xcode's device link.
    var hubAddressFile: URL { root.appending(path: "hub.json") }

    func hubAddress() -> HubLink.Address? {
        (try? Data(contentsOf: hubAddressFile)).flatMap { HubLink.decode(HubLink.Address.self, from: $0) }
    }

    /// Sent reports the Mac hasn't confirmed yet, oldest first.
    func undeliveredReports() -> [HubLink.Offer.Report] {
        sentReports()
            .filter { !$0.delivered }
            // Named by folder: the hub copies the report's folder.
            .map { HubLink.Offer.Report(id: $0.folder.lastPathComponent, finishedAt: $0.report.createdAt) }
            .reversed()
    }

    /// A sent report's files, as the hub keeps them: everything in its folder but the draft
    /// and the delivery mark. Empty when any of them can't be read: the hub turns down a report
    /// without its `report.json`, so the report stays on the phone and is offered again,
    /// rather than reaching the Mac without a picture it names.
    func reportFiles(_ id: String) -> [String: Data] {
        let folder = reportsDirectory.appending(path: id, directoryHint: .isDirectory)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [:] }
        var files: [String: Data] = [:]
        for name in names where name != "delivered" && !name.hasPrefix(".") {
            let file = folder.appending(path: name)
            if (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
            guard let data = try? Data(contentsOf: file) else { return [:] }
            files[name] = data
        }
        return files
    }

    var deliveryFile: URL { root.appending(path: "delivery.json") }

    func lastDelivery() -> Delivery? {
        (try? Data(contentsOf: deliveryFile)).flatMap { try? Self.decoder.decode(Delivery.self, from: $0) }
    }

    func recordDelivery(_ outcome: HubLink.Outcome, at date: Date = .now) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? Self.encoder.encode(Delivery(at: date, outcome: outcome)).write(to: deliveryFile, options: .atomic)
    }

    /// Notes that the Mac has these reports, so they aren't offered again.
    func markDelivered(_ ids: [String]) {
        for id in ids {
            let folder = reportsDirectory.appending(path: id, directoryHint: .isDirectory)
            guard FileManager.default.fileExists(atPath: folder.path) else { continue }
            FileManager.default.createFile(atPath: folder.appending(path: "delivered").path, contents: nil)
        }
    }

    /// The Mac has confirmed the report in `folder`.
    func isDelivered(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appending(path: "delivered").path)
    }

    /// How many reports the Mac already has stay on the phone, for the Sent reports list.
    static let keptDeliveredReports = 20

    /// Removes reports the Mac already has, all but the newest `keeping`, so their pictures
    /// don't pile up in the app's container. A report the Mac hasn't confirmed always stays.
    func pruneDeliveredReports(keeping: Int = Self.keptDeliveredReports) {
        for sent in sentReports().filter(\.delivered).dropFirst(keeping) {
            try? FileManager.default.removeItem(at: sent.folder)
        }
    }

    /// Reports already sent, newest first. One still being drawn isn't listed yet, nor one
    /// saved in an earlier format.
    func sentReports() -> [SentReport] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: reportsDirectory, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appending(path: "report.json")),
                  let report = try? Self.decoder.decode(Report.self, from: data)
            else { return nil }
            let delivered = isDelivered(folder)
            return SentReport(report: report, folder: folder, delivered: delivered)
        }
        .sorted { ($0.report.createdAt, $0.id) > ($1.report.createdAt, $1.id) }
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
