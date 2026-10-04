#if os(macOS)
import Foundation

/// An open chat, registered with the hub by its MCP copy or its agent's hooks.
struct ChatRecord: Codable, Equatable, Sendable {
    var id: String
    /// The agent: `claude` or `codex` when registered by hooks, or the name it gave when its MCP
    /// copy connected.
    var agent: String
    var folder: String
    var bundleIDs: [String]
    /// The process the chat lives in; the chat counts as closed once it's gone.
    var pid: Int32
    var registeredAt: Date
    var lastActiveAt: Date
    /// The process waiting for reports for this chat, which hands one over the moment it arrives.
    var waiter: Int32? = nil

    /// True while a process is waiting for reports for this chat.
    var isWaiting: Bool { waiter.map(Chats.isRunning) ?? false }
}

/// The IDs chats go by in the hub's files: `claude-<session>` and `codex-<thread>` for an
/// agent's own chat, `started-<agent>-<report folder>` for a chat the hub starts for a report.
enum ChatID {
    static func make(_ agent: Agent, _ id: String) -> String {
        "\(agent.rawValue)-\(id)"
    }

    static func started(_ agent: Agent, report: URL) -> String {
        "started-\(agent.rawValue)-\(report.lastPathComponent)"
    }

    static func isStarted(_ chat: String) -> Bool {
        chat.hasPrefix("started-")
    }

    /// The agent's own ID for one of its chats; nil for any other ID, such as a started chat's.
    static func agentID(of chat: String, agent: Agent) -> String? {
        let prefix = "\(agent.rawValue)-"
        return chat.hasPrefix(prefix) ? String(chat.dropFirst(prefix.count)) : nil
    }
}

/// Which chat took a report.
struct Claim: Codable, Equatable, Sendable {
    var chat: String
    var agent: String
    var folder: String
    var claimedAt: Date
}

/// A report in the inbox.
struct InboxReport: Sendable {
    var folder: URL
    var source: ReportSource
    var claim: Claim?
}

/// Open chats, each as a file under `hub/chats/`, written by its MCP copy. The hub watches the
/// folder for the apps it should take reports from.
enum Chats {
    static func folder(_ paths: HubPaths) -> URL { paths.hub.appending(path: "chats", directoryHint: .isDirectory) }

    static func register(_ chat: ChatRecord, paths: HubPaths) throws {
        try FileManager.default.createDirectory(at: folder(paths), withIntermediateDirectories: true)
        try HubPaths.encoder.encode(chat).write(to: folder(paths).appending(path: "\(chat.id).json"), options: .atomic)
    }

    static func unregister(_ id: String, paths: HubPaths) {
        try? FileManager.default.removeItem(at: folder(paths).appending(path: "\(id).json"))
        try? FileManager.default.removeItem(at: folder(paths).appending(path: "\(id).lock"))
    }

    static func record(_ id: String, paths: HubPaths) -> ChatRecord? {
        (try? Data(contentsOf: folder(paths).appending(path: "\(id).json"))).flatMap { try? HubPaths.decoder.decode(ChatRecord.self, from: $0) }
    }

    static func isRunning(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Removes the files of chats whose process is gone, such as an MCP copy that was killed,
    /// and returns the chats still open.
    @discardableResult
    static func removeClosedChats(_ paths: HubPaths) -> [ChatRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder(paths), includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            guard let data = try? Data(contentsOf: file), let chat = try? HubPaths.decoder.decode(ChatRecord.self, from: data) else { return nil }
            guard isRunning(chat.pid) else {
                unregister(chat.id, paths: paths)
                return nil
            }
            return chat
        }
    }

}

/// The chat a report is addressed to: kept in its folder's to.json.
struct ReportRecipient: Codable, Equatable, Sendable {
    var chat: String
    var agent: String
    var folder: String
}

/// The inbox's layout and the chats' view of it: reports waiting for an app, and claiming one so
/// no other chat gets it. See HubPaths for every file in a report's folder.
enum Inbox {
    /// Where a report came from, written by the hub.
    static let sourceFile = "source.json"
    /// The chat that took a report.
    static let claimFile = "claim.json"
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
        (try? Data(contentsOf: report.appending(path: recipientFile))).flatMap { try? HubPaths.decoder.decode(ReportRecipient.self, from: $0) }
    }

    static func setRecipient(_ recipient: ReportRecipient, of report: URL) throws {
        try HubPaths.encoder.encode(recipient).write(to: report.appending(path: recipientFile), options: .atomic)
    }

    /// Reports for this chat that it hasn't taken yet, oldest first.
    static func reportsAddressed(to chat: String, bundleIDs: [String], paths: HubPaths) -> [InboxReport] {
        unclaimedReports(for: bundleIDs, paths: paths).filter { recipient(of: $0.folder)?.chat == chat }
    }

    /// Every report for these apps, or every app's when `bundleIDs` is nil, oldest first. A
    /// folder without its source.json isn't a filed report.
    static func reports(for bundleIDs: [String]?, paths: HubPaths) -> [InboxReport] {
        let files = FileManager.default
        let apps = bundleIDs ?? ((try? files.contentsOfDirectory(atPath: paths.inbox.path)) ?? []).filter { !$0.hasPrefix(".") }
        var reports: [InboxReport] = []
        for bundleID in apps {
            let app = paths.inbox.appending(path: bundleID, directoryHint: .isDirectory)
            for name in (try? files.contentsOfDirectory(atPath: app.path)) ?? [] where !name.hasPrefix(".") {
                let folder = app.appending(path: name, directoryHint: .isDirectory)
                guard let data = try? Data(contentsOf: folder.appending(path: sourceFile)),
                      let source = try? HubPaths.decoder.decode(ReportSource.self, from: data)
                else { continue }
                reports.append(InboxReport(folder: folder, source: source, claim: claim(of: folder)))
            }
        }
        return reports.sorted { ($0.source.receivedAt, $0.folder.lastPathComponent) < ($1.source.receivedAt, $1.folder.lastPathComponent) }
    }

    /// Reports for these apps that no chat has taken yet, oldest first.
    static func unclaimedReports(for bundleIDs: [String], paths: HubPaths) -> [InboxReport] {
        reports(for: bundleIDs, paths: paths).filter { $0.claim == nil }
    }

    /// The chat that took a report, nil when none has. A claim that exists but can't be read
    /// still counts as taken: no other chat can take the report after it.
    static func claim(of report: URL) -> Claim? {
        let file = report.appending(path: claimFile)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        guard let data = try? Data(contentsOf: file), let claim = try? HubPaths.decoder.decode(Claim.self, from: data) else {
            return Claim(chat: "unknown", agent: "unknown", folder: "", claimedAt: .distantPast)
        }
        return claim
    }

    enum ClaimResult {
        case claimed
        case takenByAnotherChat
        /// The claim couldn't be written; the report stays free for another try.
        case failed(any Error)
    }

    /// Takes a report for a chat, so no other chat gets it.
    static func claim(_ report: InboxReport, for chat: ChatRecord) -> ClaimResult {
        let claim = Claim(chat: chat.id, agent: chat.agent, folder: chat.folder, claimedAt: .now)
        let file = report.folder.appending(path: claimFile)
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
}

/// Where the hub sent a report, saved next to it so the hub's window shows exactly what
/// happened: the agent, its chat and the chat's title.
struct ReportDelivery: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// Put into an open chat.
        case sent
        /// A chat the hub started for it.
        case newChat
        /// Waiting for the chat's next message or reply.
        case nextMessage
        /// Waiting in the inbox; `title` says why.
        case waiting
    }

    var agent: String?
    var chat: String?
    var title: String
    var kind: Kind
    var deliveredAt = Date.now

    private enum CodingKeys: String, CodingKey {
        case agent, chat, title, kind
        case deliveredAt = "at"
    }

    init(agent: Agent?, chat: String?, title: String, kind: Kind) {
        self.agent = agent?.rawValue
        self.chat = chat
        self.title = title
        self.kind = kind
    }

    static func save(_ delivery: ReportDelivery, in report: URL) throws {
        try HubPaths.encoder.encode(delivery).write(to: report.appending(path: Inbox.deliveryFile), options: .atomic)
    }

    static func load(from report: URL) -> ReportDelivery? {
        (try? Data(contentsOf: report.appending(path: Inbox.deliveryFile))).flatMap { try? HubPaths.decoder.decode(ReportDelivery.self, from: $0) }
    }
}
#endif
