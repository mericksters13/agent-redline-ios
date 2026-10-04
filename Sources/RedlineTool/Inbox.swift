#if os(macOS)
import Darwin
import Foundation

/// A report in the inbox.
struct InboxReport: Sendable {
    var folder: URL
    var source: ReportSource
    var claim: Claim?
}

/// The chat a report is addressed to: kept in its folder's to.json.
struct ReportRecipient: Codable, Equatable, Sendable {
    var chat: String
    var agent: String
    var folder: String
}

/// The inbox's layout and the chats' view of it: reports waiting for an app, and claiming one so no
/// other chat gets it.
///
/// See HubPaths for every file in a report's folder.
enum Inbox {
    /// Where a report came from, written by the hub.
    static let sourceFile = "source.json"
    /// The chat that took a report.
    static let claimFile = "claim.json"
    /// Held while a claim is taken, so one process at a time replaces an interrupted one.
    static let claimLockFile = ".claim.lock"
    /// The chat a report is addressed to.
    static let recipientFile = "to.json"
    /// Where the hub sent a report.
    static let deliveryFile = "delivery.json"
    /// What the command of a chat the hub started printed.
    static let newChatOutputFile = "new-chat-output.jsonl"
    /// The answer a chat the hub started gave.
    static let answerFile = "answer.md"
    /// A report is filled under this prefix and renamed into place whole.
    static let incomingPrefix = ".incoming-"

    /// One report's folder in the inbox: sorts by time, and two phones sending in the same
    /// second don't collide.
    static func folderName(reportID: String, device: String) -> String {
        "\(reportID)-\(device.replacing("-", with: "").suffix(8))"
    }

    static func recipient(of report: URL) -> ReportRecipient? {
        (try? Data(contentsOf: report.appending(path: recipientFile))).flatMap {
            try? HubPaths.decoder.decode(ReportRecipient.self, from: $0)
        }
    }

    static func setRecipient(_ recipient: ReportRecipient, of report: URL) throws {
        try HubPaths.encoder.encode(recipient).write(to: report.appending(path: recipientFile), options: .atomic)
    }

    /// Reports for this chat that it hasn't taken yet, oldest first.
    static func reportsAddressed(to chat: String, bundleIDs: [String], paths: HubPaths) -> [InboxReport] {
        unclaimedReports(for: bundleIDs, paths: paths).filter { recipient(of: $0.folder)?.chat == chat }
    }

    /// The chat a report was sent to, as its chat record's ID: its recipient, or else the pick the
    /// phone saved with it, which the hub may still be handing over.
    ///
    /// A "New chat" pick names the chat it started, or no chat ("") until it has. Nil when nothing
    /// says where it goes.
    static func intendedChat(of report: URL, paths: HubPaths) -> String? {
        if let recipient = recipient(of: report) { return recipient.chat }
        guard let pick = Routing.pick(of: report), let agent = Agent(rawValue: pick.agent) else { return nil }
        if let chat = pick.chat { return ChatID.make(agent, chat) }
        return pick.newChat.flatMap { StartedChats.find($0, paths: paths) }.map { ChatID.make(agent, $0.chat) } ?? ""
    }

    /// Reports a chat may take, oldest first: those sent to it, and those sent nowhere.
    ///
    /// A report sent to another chat, or to a new one, is never taken by a chat that only builds
    /// its app.
    static func takeableReports(by chat: ChatRecord, paths: HubPaths) -> [InboxReport] {
        unclaimedReports(for: chat.bundleIDs, paths: paths).filter {
            intendedChat(of: $0.folder, paths: paths).map { $0 == chat.id } ?? true
        }
    }

    /// How many reports, of any app, the process `pid` has claimed and is still handing over.
    static func reportsHandedOver(by pid: Int32, paths: HubPaths) -> Int {
        reports(for: nil, paths: paths).count { report in
            report.claim.map { $0.handingOverIn == pid && !$0.isInterrupted } ?? false
        }
    }

    /// Every report for these apps, or every app's when `bundleIDs` is nil, oldest first.
    ///
    /// A folder without its source.json isn't a filed report.
    static func reports(for bundleIDs: [String]?, paths: HubPaths) -> [InboxReport] {
        let files = FileManager.default
        let apps =
            bundleIDs
            ?? ((try? files.contentsOfDirectory(atPath: paths.inbox.path)) ?? []).filter {
                !$0.hasPrefix(".")
            }
        var reports: [InboxReport] = []
        for bundleID in apps {
            let app = paths.inbox.appending(path: bundleID, directoryHint: .isDirectory)
            for name in (try? files.contentsOfDirectory(atPath: app.path)) ?? []
            where !name.hasPrefix(".") {
                let folder = app.appending(path: name, directoryHint: .isDirectory)
                guard let data = try? Data(contentsOf: folder.appending(path: sourceFile)),
                    let source = try? HubPaths.decoder.decode(ReportSource.self, from: data)
                else { continue }
                reports.append(InboxReport(folder: folder, source: source, claim: claim(of: folder)))
            }
        }
        return reports.sorted {
            ($0.source.receivedAt, $0.folder.lastPathComponent) < ($1.source.receivedAt, $1.folder.lastPathComponent)
        }
    }

    /// Reports for these apps that no chat has taken yet, oldest first, including those whose
    /// hand-over was interrupted.
    static func unclaimedReports(for bundleIDs: [String], paths: HubPaths) -> [InboxReport] {
        reports(for: bundleIDs, paths: paths).filter { $0.claim.map(\.isInterrupted) ?? true }
    }

    /// The chat that took a report, nil when none has.
    ///
    /// A claim that exists but can't be read still counts as taken: no other chat can take the
    /// report after it.
    static func claim(of report: URL) -> Claim? {
        let file = report.appending(path: claimFile)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        guard let data = try? Data(contentsOf: file), let claim = try? HubPaths.decoder.decode(Claim.self, from: data)
        else {
            return Claim(chat: "unknown", agent: "unknown", folder: "", claimedAt: .distantPast)
        }
        return claim
    }

    /// The chat that took a report and still has it: nil when none has, or when its hand-over was
    /// interrupted and the report is free again, as `unclaimedReports(for:paths:)` has it.
    static func activeClaim(of report: URL) -> Claim? {
        claim(of: report).flatMap { $0.isInterrupted ? nil : $0 }
    }

    /// Records where the chat that took a report works, once that is known: a chat the hub starts
    /// takes the report before its worktree exists, and is resumed from the worktree.
    static func moveClaim(of report: URL, to folder: String) throws {
        let file = report.appending(path: claimFile)
        var claim = try HubPaths.decoder.decode(Claim.self, from: Data(contentsOf: file))
        claim.folder = folder
        try HubPaths.encoder.encode(claim).write(to: file, options: .atomic)
    }

    enum ClaimResult {
        case claimed
        case takenByAnotherChat
        /// The claim couldn't be written; the report stays free for another try.
        case failed(any Error)
    }

    /// Takes a report for a chat, to be handed over by this process, so no other chat gets it.
    ///
    /// A claim left by a hand-over that was interrupted is replaced.
    static func claim(_ report: InboxReport, for chat: ChatRecord) -> ClaimResult {
        let claim = Claim(
            chat: chat.id,
            agent: chat.agent,
            folder: chat.folder,
            claimedAt: .now,
            handingOverIn: getpid()
        )
        let file = report.folder.appending(path: claimFile)
        do {
            // One process at a time replaces an interrupted claim, so two can't both take its report.
            return try withClaimLock(report.folder) {
                if let existing = Self.claim(of: report.folder) {
                    guard existing.isInterrupted else { return .takenByAnotherChat }
                    guard unlink(file.path) == 0 || errno == ENOENT else { throw lastPOSIXError() }
                }
                // Written whole under a name of its own, then linked into place: linking fails if a
                // claim is already there, so two chats can't both take it, and no chat ever sees half
                // a claim.
                let draft = report.folder.appending(path: ".\(claimFile).\(UUID().uuidString)")
                defer { unlink(draft.path) }
                try HubPaths.encoder.encode(claim).write(to: draft)
                guard link(draft.path, file.path) == 0 else {
                    if errno == EEXIST { return .takenByAnotherChat }
                    throw lastPOSIXError()
                }
                return .claimed
            }
        } catch {
            return .failed(error)
        }
    }

    /// Runs `body` unless a chat holds the report: a claim that wasn't interrupted, other than one
    /// this process is still handing over.
    ///
    /// Holds the lock claims take meanwhile, so a chat can't take the report while `body` runs.
    /// Throws when the lock can't be taken, or what `body` throws.
    static func unlessTaken(_ report: URL, _ body: () throws -> Void) throws {
        try withClaimLock(report) {
            if let claim = activeClaim(of: report), claim.handingOverIn != getpid() { return }
            try body()
        }
    }

    /// Lets a report go again, for a chat that takes it later.
    static func release(_ report: InboxReport) throws {
        try FileManager.default.removeItem(at: report.folder.appending(path: claimFile))
    }

    /// Runs `body` while this process alone decides who takes the report.
    ///
    /// The lock is released when the descriptor closes.
    private static func withClaimLock<T>(_ report: URL, _ body: () throws -> T) throws -> T {
        let lock = open(report.appending(path: claimLockFile).path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw lastPOSIXError() }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw lastPOSIXError() }
        return try body()
    }

    /// The error `errno` names.
    private static func lastPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    /// Notes that the chat has a report this process claimed, so the claim stands for good.
    static func handedOver(_ report: InboxReport) throws {
        let file = report.folder.appending(path: claimFile)
        var claim = try HubPaths.decoder.decode(Claim.self, from: Data(contentsOf: file))
        guard claim.handingOverIn == getpid() else { return }
        claim.handingOverIn = nil
        try HubPaths.encoder.encode(claim).write(to: file, options: .atomic)
    }
}
#endif
