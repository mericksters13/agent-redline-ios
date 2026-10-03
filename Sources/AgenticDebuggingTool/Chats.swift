#if os(macOS)
import Foundation

/// An open chat, registered with the hub by its MCP copy or its agent's hooks.
struct ChatRecord: Codable, Equatable, Sendable {
    var id: String
    /// The agent: `claude`, `codex` or `cursor` when registered by hooks, or the name it gave
    /// when its MCP copy connected.
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

/// Held by the one process waiting for a chat's reports, so a chat never has two. Released
/// when the process ends, however it ends.
final class WaitLock {
    private let descriptor: Int32

    init?(chat: String, paths: HubPaths) {
        try? FileManager.default.createDirectory(at: Chats.folder(paths), withIntermediateDirectories: true)
        let descriptor = open(Chats.folder(paths).appending(path: "\(chat).lock").path, O_RDWR | O_CREAT, 0o600)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }
}

/// The agent and folder last used for each app, so the hub can start a chat there when a
/// report arrives and none is open.
struct ProjectUse: Codable, Equatable, Sendable {
    var agent: String
    var folder: String
    var at: Date
}

enum ProjectHistory {
    static func file(_ paths: HubPaths) -> URL { paths.hub.appending(path: "projects.json") }

    static func all(_ paths: HubPaths) -> [String: ProjectUse] {
        (try? Data(contentsOf: file(paths))).flatMap { try? Chats.decoder.decode([String: ProjectUse].self, from: $0) } ?? [:]
    }

    static func note(_ chat: ChatRecord, paths: HubPaths) {
        var uses = all(paths)
        for bundleID in chat.bundleIDs { uses[bundleID] = ProjectUse(agent: chat.agent, folder: chat.folder, at: Date()) }
        try? FileManager.default.createDirectory(at: paths.hub, withIntermediateDirectories: true)
        try? Chats.coder.encode(uses).write(to: file(paths), options: .atomic)
    }
}

/// The inbox as chats see it: reports waiting for an app, and claiming one so no other chat gets it.
enum InboxQueue {
    static let claimFile = "claim.json"

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
#endif
