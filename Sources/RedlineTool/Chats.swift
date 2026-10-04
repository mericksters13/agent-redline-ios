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
    /// The process handing the report over, until the chat has it; nil once it has.
    var handingOverIn: Int32? = nil

    /// True when the process handing the report over ended before the chat had it, such as
    /// when it crashed: the report is free for another chat to take. A process that started
    /// after the claim only reuses the PID, so it doesn't hold the report.
    var isInterrupted: Bool { handingOverIn.map { !Chats.isRunning($0, since: claimedAt) } ?? false }
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

    /// True when the process that was running at `date` still is: a process with the same PID
    /// that started later only reuses it. Dates are saved to the second, so a little slack.
    static func isRunning(_ pid: Int32, since date: Date) -> Bool {
        guard isRunning(pid) else { return false }
        guard let started = startTime(of: pid) else { return true }
        return started <= date.addingTimeInterval(2)
    }

    /// When the process started, from the kernel.
    static func startTime(of pid: Int32) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }

    /// Chats whose MCP copy is still running. Files left by a copy that was killed are removed.
    static func live(_ paths: HubPaths) -> [ChatRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder(paths), includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            guard let data = try? Data(contentsOf: file), let chat = try? decoder.decode(ChatRecord.self, from: data) else { return nil }
            guard isRunning(chat.pid, since: chat.registeredAt) else {
                unregister(chat.id, paths: paths)
                return nil
            }
            return chat
        }
    }

    /// Dates keep their milliseconds, so reports received in the same second stay in order.
    static let coder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(preciseDates))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    /// Reads dates with or without milliseconds, so files saved before they were kept still load.
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = (try? preciseDates.parse(text)) ?? (try? Date.ISO8601FormatStyle().parse(text)) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 date: \(text)")
        }
        return decoder
    }()

    private static let preciseDates = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
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
        try? FileManager.default.createDirectory(at: paths.hub, withIntermediateDirectories: true)
        // Each chat notes its apps from its own process: one at a time reads and rewrites the
        // file, so none drops the apps another just added. Released when the descriptor closes.
        let lock = open(paths.hub.appending(path: "projects.lock").path, O_RDWR | O_CREAT, 0o600)
        guard lock >= 0 else { return }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { return }
        var uses = all(paths)
        for bundleID in chat.bundleIDs { uses[bundleID] = ProjectUse(agent: chat.agent, folder: chat.folder, at: Date()) }
        try? Chats.coder.encode(uses).write(to: file(paths), options: .atomic)
    }
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

    /// The chat a report was sent to, as its chat record's ID: its address, or else the pick
    /// the phone saved with it, which the hub may still be handing over. A "New chat" pick names
    /// the chat it started, or no chat ("") until it has. Nil when nothing says where it goes.
    static func recipient(of report: URL, paths: HubPaths) -> String? {
        if let address = address(of: report) { return address.chat }
        guard let pick = Routing.pick(of: report) else { return nil }
        if let chat = pick.chat { return "\(pick.agent)-\(chat)" }
        return pick.newChat.flatMap { StartedChats.find($0, paths: paths) }.map { "\(pick.agent)-\($0.chat)" } ?? ""
    }

    /// Reports a chat may take, oldest first: those sent to it, and those sent nowhere. A report
    /// sent to another chat, or to a new one, is never taken by a chat that only builds its app.
    static func takeable(by chat: ChatRecord, paths: HubPaths) -> [InboxReport] {
        waiting(for: chat.bundleIDs, paths: paths).filter { recipient(of: $0.folder, paths: paths).map { $0 == chat.id } ?? true }
    }

    /// Wakes chats waiting on an app's reports, after a report already in the inbox changed.
    static func signal(_ bundleID: String, paths: HubPaths) {
        let marker = paths.inbox.appending(path: "\(bundleID)/.changed-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: marker.path, contents: nil)
        try? FileManager.default.removeItem(at: marker)
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

    /// Reports for these apps that no chat has taken yet, oldest first, including those whose
    /// hand-over was interrupted.
    static func waiting(for bundleIDs: [String], paths: HubPaths) -> [InboxReport] {
        reports(for: bundleIDs, paths: paths).filter { $0.claim.map(\.isInterrupted) ?? true }
    }

    /// How many reports, of any app, the process `pid` has claimed and is still handing over.
    static func handingOver(by pid: Int32, paths: HubPaths) -> Int {
        let apps = ((try? FileManager.default.contentsOfDirectory(atPath: paths.inbox.path)) ?? []).filter { !$0.hasPrefix(".") }
        return reports(for: apps, paths: paths).count { $0.claim.map { $0.handingOverIn == pid && !$0.isInterrupted } ?? false }
    }

    /// Takes a report for a chat, to be handed over by this process. False when another chat
    /// took it first. A claim left by a hand-over that was interrupted is replaced.
    static func claim(_ report: InboxReport, for chat: ChatRecord) -> Bool {
        let claim = Claim(chat: chat.id, agent: chat.agent, folder: chat.folder, claimedAt: Date(), handingOverIn: getpid())
        guard let data = try? Chats.coder.encode(claim) else { return false }
        // One process at a time decides who takes the report, so two can't both replace the
        // same interrupted claim.
        return withClaimLock(report.folder) {
            let file = report.folder.appending(path: claimFile)
            if FileManager.default.fileExists(atPath: file.path) {
                // A claim that can't be read was cut off mid-write, which only an interrupted process leaves.
                if let existing = (try? Data(contentsOf: file)).flatMap({ try? Chats.decoder.decode(Claim.self, from: $0) }),
                   !existing.isInterrupted { return false }
                try? FileManager.default.removeItem(at: file)
            }
            let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
            guard descriptor >= 0 else { return false }
            defer { close(descriptor) }
            return data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) } == data.count
        } ?? false
    }

    /// Runs `body` unless a chat holds the report: a claim that wasn't interrupted, other than
    /// one this process is still handing over. Holds the lock claims take meanwhile, so a chat
    /// can't take the report while `body` runs. False when a chat holds it or the lock failed.
    @discardableResult
    static func unlessTaken(_ report: URL, _ body: () -> Void) -> Bool {
        withClaimLock(report) {
            let claim = (try? Data(contentsOf: report.appending(path: claimFile))).flatMap { try? Chats.decoder.decode(Claim.self, from: $0) }
            if let claim, !claim.isInterrupted, claim.handingOverIn != getpid() { return false }
            body()
            return true
        } ?? false
    }

    /// Runs `body` while this process alone decides who takes the report. Nil when the lock
    /// can't be taken. The lock is released when the descriptor closes.
    private static func withClaimLock<T>(_ report: URL, _ body: () -> T) -> T? {
        let lock = open(report.appending(path: ".claim.lock").path, O_RDWR | O_CREAT, 0o600)
        guard lock >= 0 else { return nil }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { return nil }
        return body()
    }

    /// Records where the chat that took a report works, once that is known: a chat the hub
    /// starts takes the report before its worktree exists, and is resumed from the worktree.
    static func moveClaim(of report: URL, to folder: String) {
        let file = report.appending(path: claimFile)
        guard var claim = (try? Data(contentsOf: file)).flatMap({ try? Chats.decoder.decode(Claim.self, from: $0) }) else { return }
        claim.folder = folder
        try? Chats.coder.encode(claim).write(to: file, options: .atomic)
    }

    /// Notes that the chat has a report this process claimed, so the claim stands for good.
    static func handedOver(_ report: InboxReport) {
        let file = report.folder.appending(path: claimFile)
        guard var claim = (try? Data(contentsOf: file)).flatMap({ try? Chats.decoder.decode(Claim.self, from: $0) }),
              claim.handingOverIn == getpid() else { return }
        claim.handingOverIn = nil
        try? Chats.coder.encode(claim).write(to: file, options: .atomic)
    }

    /// Frees a report this process claimed but couldn't hand over, for another chat to take.
    static func release(_ report: InboxReport) {
        try? FileManager.default.removeItem(at: report.folder.appending(path: claimFile))
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

    /// Not in a chat yet: a chat that takes the report later records a claim.
    var pending: Bool { kind == .waiting || kind == .nextMessage }

    static let file = "delivery.json"

    /// Saves where the report went. One not in a chat yet is saved only while no chat holds
    /// the report, and no chat can take it meanwhile: a chat that took it first, such as one
    /// whose wait woke when the report was filed, keeps showing, and a chat that takes it later
    /// is always newer than this.
    static func save(_ delivery: ReportDelivery, in report: URL) {
        let write = { _ = try? Chats.coder.encode(delivery).write(to: report.appending(path: file), options: .atomic) }
        if delivery.pending { InboxQueue.unlessTaken(report, write) } else { write() }
    }

    static func load(from report: URL) -> ReportDelivery? {
        (try? Data(contentsOf: report.appending(path: file))).flatMap { try? Chats.decoder.decode(ReportDelivery.self, from: $0) }
    }
}
#endif
