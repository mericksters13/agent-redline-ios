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
        try coder.encode(chat).write(to: folder(paths).appending(path: "\(chat.id).json"), options: .atomic)
    }

    static func unregister(_ id: String, paths: HubPaths) {
        try? FileManager.default.removeItem(at: folder(paths).appending(path: "\(id).json"))
        try? FileManager.default.removeItem(at: folder(paths).appending(path: "\(id).lock"))
    }

    static func record(_ id: String, paths: HubPaths) -> ChatRecord? {
        (try? Data(contentsOf: folder(paths).appending(path: "\(id).json"))).flatMap { try? decoder.decode(ChatRecord.self, from: $0) }
    }

    static func isRunning(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Chats whose MCP copy is still running. Files left by a copy that was killed are removed.
    static func live(_ paths: HubPaths) -> [ChatRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder(paths), includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            guard let data = try? Data(contentsOf: file), let chat = try? decoder.decode(ChatRecord.self, from: data) else { return nil }
            guard isRunning(chat.pid) else {
                unregister(chat.id, paths: paths)
                return nil
            }
            return chat
        }
    }

    static let coder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// The chat a report is for: the one that built the app it came from.
struct Address: Codable, Equatable, Sendable {
    var chat: String
    var agent: String
    var folder: String
}

/// The inbox as chats see it: reports waiting for an app, and claiming one so no other chat gets it.
enum InboxQueue {
    static let claimFile = "claim.json"
    static let addressFile = "to.json"

    static func address(of report: URL) -> Address? {
        (try? Data(contentsOf: report.appending(path: addressFile))).flatMap { try? Chats.decoder.decode(Address.self, from: $0) }
    }

    static func setAddress(_ address: Address, of report: URL) {
        try? Chats.coder.encode(address).write(to: report.appending(path: addressFile), options: .atomic)
    }

    /// Reports for this chat that it hasn't taken yet, oldest first.
    static func addressed(to chat: String, bundleIDs: [String], paths: HubPaths) -> [InboxReport] {
        waiting(for: bundleIDs, paths: paths).filter { address(of: $0.folder)?.chat == chat }
    }

    /// Every report for these apps, oldest first.
    static func reports(for bundleIDs: [String], paths: HubPaths) -> [InboxReport] {
        let files = FileManager.default
        var reports: [InboxReport] = []
        for bundleID in bundleIDs {
            let app = paths.inbox.appending(path: bundleID, directoryHint: .isDirectory)
            for name in (try? files.contentsOfDirectory(atPath: app.path)) ?? [] where !name.hasPrefix(".") {
                let folder = app.appending(path: name, directoryHint: .isDirectory)
                guard let data = try? Data(contentsOf: folder.appending(path: "source.json")),
                      let source = try? Chats.decoder.decode(ReportSource.self, from: data)
                else { continue }
                let claim = (try? Data(contentsOf: folder.appending(path: claimFile))).flatMap { try? Chats.decoder.decode(Claim.self, from: $0) }
                reports.append(InboxReport(folder: folder, source: source, claim: claim))
            }
        }
        return reports.sorted { ($0.source.receivedAt, $0.folder.lastPathComponent) < ($1.source.receivedAt, $1.folder.lastPathComponent) }
    }

    /// Reports for these apps that no chat has taken yet, oldest first.
    static func waiting(for bundleIDs: [String], paths: HubPaths) -> [InboxReport] {
        reports(for: bundleIDs, paths: paths).filter { $0.claim == nil }
    }

    /// Takes a report for a chat. False when another chat took it first.
    static func claim(_ report: InboxReport, for chat: ChatRecord) -> Bool {
        let claim = Claim(chat: chat.id, agent: chat.agent, folder: chat.folder, claimedAt: Date())
        guard let data = try? Chats.coder.encode(claim) else { return false }
        // Created only if it doesn't exist yet, so two chats can't both take it.
        let descriptor = open(report.folder.appending(path: claimFile).path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        return data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) } == data.count
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
    var at = Date()

    init(agent: Agent?, chat: String?, title: String, kind: Kind) {
        self.agent = agent?.rawValue
        self.chat = chat
        self.title = title
        self.kind = kind
    }

    static let file = "delivery.json"

    static func save(_ delivery: ReportDelivery, in report: URL) {
        try? Chats.coder.encode(delivery).write(to: report.appending(path: file), options: .atomic)
    }

    static func load(from report: URL) -> ReportDelivery? {
        (try? Data(contentsOf: report.appending(path: file))).flatMap { try? Chats.decoder.decode(ReportDelivery.self, from: $0) }
    }
}
#endif
