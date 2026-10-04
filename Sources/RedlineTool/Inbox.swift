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
        // One process at a time replaces an interrupted claim, so two can't both take its report.
        // The lock is released when the descriptor closes.
        let lock = open(report.folder.appending(path: claimLockFile).path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard lock >= 0 else { return .failed(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)) }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { return .failed(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)) }
        if let existing = Self.claim(of: report.folder) {
            guard existing.isInterrupted else { return .takenByAnotherChat }
            guard unlink(file.path) == 0 || errno == ENOENT else {
                return .failed(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
            }
        }
        // Written whole under a name of its own, then linked into place: linking fails if a claim
        // is already there, so two chats can't both take it, and no chat ever sees half a claim.
        let draft = report.folder.appending(path: ".\(claimFile).\(UUID().uuidString)")
        defer { unlink(draft.path) }
        do {
            try HubPaths.encoder.encode(claim).write(to: draft)
        } catch {
            return .failed(error)
        }
        guard link(draft.path, file.path) == 0 else {
            return errno == EEXIST ? .takenByAnotherChat : .failed(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
        }
        return .claimed
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
