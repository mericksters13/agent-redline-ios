#if REDLINE
import Foundation

/// Keeps the unsent draft and sent reports on disk, so a draft survives the app
/// being killed or reinstalled by a rebuild.
///
/// The layout under `root` is a contract with the Mac, which reads it over Xcode's device
/// link or from a simulator's folder (`ReportFolder` and `HubAddress` in the Mac tool):
/// - `draft/`: `annotations.json`, `screens.json`, the screen captures and attached images.
///   Only the phone reads it.
/// - `reports/<id>/`: one sent report, named by when it was sent, such as `20261003-215826`.
///   It is written in this order, and the order is load-bearing:
///   1. `beginReport` moves the draft into `reports/<id>/draft`.
///   2. The report's pictures are written beside it.
///   3. `report.md`, then `report.json`, are written.
///   4. `reports/<id>/draft` is removed.
///
///   A report is finished once `report.json` exists and `draft/` is gone; the Mac takes only
///   finished reports.
/// - `reports/<id>/delivered`: an empty file the phone writes once the Mac confirms it has
///   the report, so it isn't offered again.
/// - `hub.json`: written by the Mac's hub, once, with its addresses and a token.
/// - `delivery.json`: written by the phone after each attempt to hand reports to the Mac.
struct ReportStore: Sendable {
    /// A draft note whose picture is gone.
    ///
    /// Sending stops so the draft stays for recovery instead of producing a report that points at a
    /// missing file.
    struct MissingScreenshot: Error, Equatable {
        var annotationID: UUID
    }

    let root: URL

    static let standard: ReportStore = {
        let store = ReportStore(
            root: URL.applicationSupportDirectory.appending(path: "Redline", directoryHint: .isDirectory)
        )
        store.moveFromOldName()
        return store
    }()

    /// Moves what an earlier version kept under its old name, iOSAgenticDebuggingKit, here, so the
    /// draft and the reports the Mac hasn't collected carry over a rebuild with the new name.
    ///
    /// The hub may already have left its address here, so each item moves on its own, and only
    /// when nothing of that name is here yet.
    func moveFromOldName() {
        let old = root.deletingLastPathComponent()
            .appending(path: "iOSAgenticDebuggingKit", directoryHint: .isDirectory)
        let files = FileManager.default
        guard files.fileExists(atPath: old.path(percentEncoded: false)) else { return }
        try? files.createDirectory(at: root, withIntermediateDirectories: true)
        func move(from source: URL, to destination: URL) {
            for item in (try? files.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)) ?? [] {
                let target = destination.appending(path: item.lastPathComponent)
                if !files.fileExists(atPath: target.path(percentEncoded: false)) {
                    try? files.moveItem(at: item, to: target)
                }
            }
        }
        move(from: old, to: root)
        // Reports were already here: the old ones join them, each in its own folder.
        move(from: old.appending(path: "reports"), to: reportsDirectory)
        // An older hub address is the only thing left that a newer one replaces. The folders go
        // only when empty (rmdir), so anything else left stays where it is.
        try? files.removeItem(at: old.appending(path: "hub.json"))
        rmdir(old.appending(path: "reports").path(percentEncoded: false))
        rmdir(old.path(percentEncoded: false))
    }

    /// Moves the settings an earlier version saved under its old prefix, AgenticDebugging, to
    /// Redline's, so a report waiting to reach the Mac is still offered again, and the button stays
    /// where it was put.
    ///
    /// Only what the app saved moves, not launch arguments, and a setting already saved under the
    /// new name is kept.
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
    var draftFile: URL { draftDirectory.appending(path: "annotations.json") }
    var screensFile: URL { draftDirectory.appending(path: "screens.json") }

    /// The draft's notes; empty when there is no draft.
    ///
    /// Throws when the file is there but can't be read, so a caller never mistakes it for an empty
    /// draft and saves over it.
    func loadDraft() throws -> [Annotation] {
        guard let data = try Self.contents(of: draftFile) else { return [] }
        return try Self.decoder.decode([Annotation].self, from: data)
    }

    func saveDraft(_ annotations: [Annotation]) throws {
        try FileManager.default.createDirectory(at: draftDirectory, withIntermediateDirectories: true)
        try Self.draftEncoder.encode(annotations).write(to: draftFile, options: .atomic)
    }

    /// The draft's screens and captures; empty when there is no draft.
    ///
    /// Throws like `loadDraft()`.
    func loadScreens() throws -> [ScreenRecord] {
        guard let data = try Self.contents(of: screensFile) else { return [] }
        return try Self.decoder.decode([ScreenRecord].self, from: data)
    }

    /// Moves a draft file that can't be read out of the way, next to where it was, so the next save
    /// starts fresh without destroying it.
    ///
    /// Returns where it went.
    @discardableResult
    func setAsideUnreadable(_ file: URL, at date: Date = .now) throws -> URL {
        let name =
            "\(file.deletingPathExtension().lastPathComponent)-unreadable-\(Self.timestampFormatter.string(from: date))"
        let destination = file.deletingLastPathComponent().appending(path: name).appendingPathExtension(
            file.pathExtension
        )
        try FileManager.default.moveItem(at: file, to: destination)
        return destination
    }

    /// A file's contents, or nil when there is no such file.
    ///
    /// Any other failure throws.
    private static func contents(of file: URL) throws -> Data? {
        do {
            return try Data(contentsOf: file)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    func saveScreens(_ screens: [ScreenRecord]) throws {
        try FileManager.default.createDirectory(at: draftDirectory, withIntermediateDirectories: true)
        try Self.draftEncoder.encode(screens).write(to: screensFile, options: .atomic)
    }

    func saveScreenshot(_ data: Data, named name: String) throws {
        try FileManager.default.createDirectory(at: draftDirectory, withIntermediateDirectories: true)
        try data.write(to: draftDirectory.appending(path: name), options: .atomic)
    }

    func deleteScreenshot(named name: String) {
        try? FileManager.default.removeItem(at: draftDirectory.appending(path: name))
    }

    /// Throws `MissingScreenshot` for the first note whose picture isn't on disk: a capture that's
    /// gone or no longer listed, or an attached image.
    ///
    /// Checked before a report takes the draft, so the draft stays for the note to be deleted and
    /// the rest sent.
    func checkScreenshots(of annotations: [Annotation], screens: [ScreenRecord]) throws {
        let files = FileManager.default
        let captures = Dictionary(
            screens.flatMap(\.captures).map { ($0.id, $0.file) },
            uniquingKeysWith: { first, _ in first }
        )
        for annotation in annotations {
            var needed = annotation.screenshots
            if let captureID = annotation.captureID {
                guard let file = captures[captureID] else { throw MissingScreenshot(annotationID: annotation.id) }
                needed.append(file)
            }
            if needed.contains(where: {
                !files.fileExists(atPath: draftDirectory.appending(path: $0).path(percentEncoded: false))
            }) {
                throw MissingScreenshot(annotationID: annotation.id)
            }
        }
    }

    /// Starts a report: moves the whole draft into a new report folder, so new notes go into a
    /// fresh draft while the report's pictures are drawn from the old one.
    ///
    /// If the move fails, the draft stays as it was and no report folder is left behind. Returns
    /// the report's id, its folder and where the draft now is.
    func beginReport(date: Date) throws -> (id: String, folder: URL, draft: URL) {
        let files = FileManager.default
        let stamp = Self.timestampFormatter.string(from: date)
        try files.createDirectory(at: reportsDirectory, withIntermediateDirectories: true)

        // Creating the folder itself fails when it exists, so two reports in the same second, or a
        // clock set back, get their own folders instead of sharing one.
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
    /// `Hub.largestReport`.
    ///
    /// Checked before the report is finished, while its notes can still go back into the draft for
    /// photos to be taken out.
    static let largestReport = 50_000_000

    /// A report too big for the Mac to take.
    struct TooLarge: Error, Equatable {
        var bytes: Int
    }

    /// Checks that a report drawn in `folder`, with the summary and listing `finishReport` adds,
    /// fits what the Mac takes.
    ///
    /// Call before `finishReport`: a finished report can't be changed.
    func checkSize(of report: Report, in folder: URL, limit: Int = Self.largestReport) throws {
        var bytes = Data(ReportSummary.markdown(report).utf8).count + (try Self.encoder.encode(report)).count
        let contents = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]
        )
        for file in contents where !file.lastPathComponent.hasPrefix(".") {
            let values = try file.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            // The draft the pictures were drawn from isn't sent.
            if values.isDirectory == true { continue }
            bytes += values.fileSize ?? 0
        }
        if bytes > limit { throw TooLarge(bytes: bytes) }
    }

    /// Finishes a report: writes `report.md` and `report.json` and removes the old draft.
    ///
    /// `report.json` goes last, so a report is listed as sent only once it is complete.
    func finishReport(_ report: Report, in folder: URL) throws {
        try Data(ReportSummary.markdown(report).utf8).write(to: folder.appending(path: "report.md"), options: .atomic)
        try Self.encoder.encode(report).write(to: folder.appending(path: "report.json"), options: .atomic)
        do {
            try FileManager.default.removeItem(at: folder.appending(path: "draft"))
        } catch {
            // The report stays unfinished for the hub until its draft is gone.
            Log.store.error(
                "Couldn't remove the draft of \(folder.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Takes back the pictures of a report that couldn't be finished, so its notes can go back into
    /// the draft and be sent again.
    ///
    /// Copies every picture of the report's old draft into the current one, next to any made since;
    /// their names are unique, so none collide. The report folder stays until `discardReport`, once
    /// the notes are saved in the draft again.
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
    ///
    /// Best effort: a folder left behind still has its draft, so it never counts as finished.
    func discardReport(_ folder: URL) {
        do {
            try FileManager.default.removeItem(at: folder)
        } catch {
            Log.store.error(
                "Couldn't remove the unfinished report \(folder.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Brings back reports cut short, such as by the app being killed while their pictures were
    /// drawn.
    ///
    /// A finished one only loses the draft it was drawn from. An unfinished one's notes, screens
    /// and pictures go back into the draft, ahead of any made since, so they can be sent again.
    /// Call at launch only, before any report starts. Safe to run again after being cut short
    /// itself: notes and screens already back in the draft aren't added twice. A report whose
    /// notes can't be read, or whose notes can't go back into a draft that can't be read, is left
    /// as it is for the next launch.
    func recoverInterruptedReports() {
        let files = FileManager.default
        let folders =
            (try? files.contentsOfDirectory(at: reportsDirectory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        // Newest first, so each older report's notes go ahead of it.
        for folder in folders.sorted(by: { $0.lastPathComponent > $1.lastPathComponent })
        where (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let old = folder.appending(path: "draft", directoryHint: .isDirectory)
            let isFinished = files.fileExists(atPath: folder.appending(path: "report.json").path(percentEncoded: false))
            guard files.fileExists(atPath: old.path(percentEncoded: false)) else {
                // Cut short before the draft moved in: there's nothing to bring back.
                if !isFinished { discardReport(folder) }
                continue
            }
            do {
                if isFinished {
                    try files.removeItem(at: old)
                    continue
                }
                let annotations =
                    try Self.contents(of: old.appending(path: draftFile.lastPathComponent)).map {
                        try Self.decoder.decode([Annotation].self, from: $0)
                    } ?? []
                let screens =
                    try Self.contents(of: old.appending(path: screensFile.lastPathComponent)).map {
                        try Self.decoder.decode([ScreenRecord].self, from: $0)
                    } ?? []
                try reclaimPictures(from: folder)
                // Screens first, as when a note is added: a listed screen no note uses is harmless.
                let currentScreens = try loadScreens()
                let screenIDs = Set(currentScreens.map(\.id))
                try saveScreens(screens.filter { !screenIDs.contains($0.id) } + currentScreens)
                let draft = try loadDraft()
                let noteIDs = Set(draft.map(\.id))
                try saveDraft(annotations.filter { !noteIDs.contains($0.id) } + draft)
                discardReport(folder)
            } catch {
                // Left as it is, to be tried again at the next launch.
                Log.store.error(
                    "Couldn't recover the report \(folder.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    /// Where the Mac's hub leaves its address, over Xcode's device link.
    var hubAddressFile: URL { root.appending(path: "hub.json") }

    /// The hub's address; nil when no hub has set this app up, or when the file can't be read.
    func hubAddress() -> HubLink.Address? {
        do {
            guard let data = try Self.contents(of: hubAddressFile) else { return nil }
            return try HubLink.decode(HubLink.Address.self, from: data)
        } catch {
            Log.store.error(
                "hub.json could not be read; the hub may be newer: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// Sent reports the Mac hasn't confirmed yet, oldest first.
    ///
    /// Delivered reports are skipped before anything is read, and only each report's id and date
    /// are decoded.
    func undeliveredReports() -> [HubLink.OfferedReport] {
        /// The little of a report needed to offer it.
        struct Stamp: Decodable {
            var id: String
            var createdAt: Date
        }
        // No reports folder yet: nothing has been sent.
        let folders =
            (try? FileManager.default.contentsOfDirectory(at: reportsDirectory, includingPropertiesForKeys: nil)) ?? []
        let waiting = folders.compactMap { folder -> (folder: String, stamp: Stamp)? in
            guard
                !FileManager.default.fileExists(atPath: folder.appending(path: "delivered").path(percentEncoded: false))
            else { return nil }
            do {
                // No report.json yet: still being drawn.
                guard let data = try Self.contents(of: folder.appending(path: "report.json")) else { return nil }
                return (folder.lastPathComponent, try Self.decoder.decode(Stamp.self, from: data))
            } catch {
                Log.store.notice(
                    "Skipped report \(folder.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                return nil
            }
        }
        return
            waiting
            .sorted { ($0.stamp.createdAt, $0.stamp.id) < ($1.stamp.createdAt, $1.stamp.id) }
            // Named by folder: the hub copies the report's folder.
            .map { HubLink.OfferedReport(id: $0.folder, finishedAt: $0.stamp.createdAt) }
    }

    /// A sent report's files, as the hub keeps them: everything in its folder but the draft
    /// and the delivery mark.
    ///
    /// Empty when any of them can't be read: the hub turns down a report without its
    /// `report.json`, so the report stays on the phone and is offered again, rather than reaching
    /// the Mac without a picture it names.
    func reportFiles(_ id: String) -> [String: Data] {
        let folder = reportsDirectory.appending(path: id, directoryHint: .isDirectory)
        var files: [String: Data] = [:]
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isDirectoryKey]
            )
            for file in contents where file.lastPathComponent != "delivered" && !file.lastPathComponent.hasPrefix(".") {
                if try file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true { continue }
                files[file.lastPathComponent] = try Data(contentsOf: file)
            }
        } catch {
            Log.store.error(
                "Couldn't read report \(id, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return [:]
        }
        return files
    }

    private var deliveryFile: URL { root.appending(path: "delivery.json") }

    /// The last attempt to hand reports to the Mac; nil before the first, or when it can't be read.
    func lastDelivery() -> Delivery? {
        do {
            guard let data = try Self.contents(of: deliveryFile) else { return nil }
            return try Self.decoder.decode(Delivery.self, from: data)
        } catch {
            Log.store.error("Couldn't read the last delivery: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func recordDelivery(_ outcome: HubLink.Outcome, at date: Date = .now) {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Self.encoder.encode(Delivery(attemptedAt: date, outcome: outcome)).write(
                to: deliveryFile,
                options: .atomic
            )
        } catch {
            Log.store.error("Couldn't record the delivery: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Notes that the Mac has these reports, so they aren't offered again.
    func markDelivered(_ ids: [String]) {
        for id in ids {
            let folder = reportsDirectory.appending(path: id, directoryHint: .isDirectory)
            guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else { continue }
            do {
                try Data().write(to: folder.appending(path: "delivered"))
            } catch {
                // The report is offered again next time, and the hub says it already has it.
                Log.store.error(
                    "Couldn't mark \(id, privacy: .public) delivered: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    /// Reports already sent, newest first.
    ///
    /// One still being drawn isn't listed yet, nor one saved in an earlier format.
    func sentReports() -> [SentReport] {
        let folders =
            (try? FileManager.default.contentsOfDirectory(at: reportsDirectory, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder in
            let report: Report
            do {
                // No report.json yet: still being drawn.
                guard let data = try Self.contents(of: folder.appending(path: "report.json")) else { return nil }
                report = try Self.decoder.decode(Report.self, from: data)
            } catch {
                Log.store.notice(
                    "Skipped report \(folder.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                return nil
            }
            let delivered = FileManager.default.fileExists(
                atPath: folder.appending(path: "delivered").path(percentEncoded: false)
            )
            return SentReport(report: report, folder: folder, isDelivered: delivered)
        }
        .sorted { ($0.report.createdAt, $0.id) > ($1.report.createdAt, $1.id) }
    }

    /// For report.json and delivery.json, which people and agents read.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    /// For the draft's files, which only the phone reads and which are rewritten on every change.
    private static let draftEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// Names reports and set-aside files by when they were made, such as 20261003-215826.
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
#endif
