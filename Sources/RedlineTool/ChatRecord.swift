#if os(macOS)
import Darwin
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
    /// The ID of the agent's chat `id`.
    static func make(_ agent: Agent, _ id: String) -> String {
        "\(agent.rawValue)-\(id)"
    }

    /// The ID of a chat the hub started for a report.
    static func started(_ agent: Agent, report: URL) -> String {
        "started-\(agent.rawValue)-\(report.lastPathComponent)"
    }

    /// True for a chat the hub started.
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
    /// The process handing the report over, until the chat has it; nil once it has.
    var handingOverIn: Int32? = nil

    /// True when the process handing the report over ended before the chat had it, such as when it
    /// crashed: the report is free for another chat to take.
    var isInterrupted: Bool { handingOverIn.map { !Chats.isRunning($0) } ?? false }
}

/// Open chats, each as a file under `hub/chats/`, written by its MCP copy.
///
/// The hub watches the folder for the apps it should take reports from.
enum Chats {
    /// The folder of chat records.
    static func folder(_ paths: HubPaths) -> URL { paths.hub.appending(path: "chats", directoryHint: .isDirectory) }

    /// Saves the chat's record, which the hub watches for.
    static func register(_ chat: ChatRecord, paths: HubPaths) throws {
        try FileManager.default.createDirectory(at: folder(paths), withIntermediateDirectories: true)
        try HubPaths.encoder.encode(chat).write(to: folder(paths).appending(path: "\(chat.id).json"), options: .atomic)
    }

    /// Removes the chat's record and its lock; already gone is fine.
    static func unregister(_ id: String, paths: HubPaths) {
        try? FileManager.default.removeItem(at: folder(paths).appending(path: "\(id).json"))
        try? FileManager.default.removeItem(at: folder(paths).appending(path: "\(id).lock"))
    }

    /// The chat's saved record, if it has one.
    static func record(_ id: String, paths: HubPaths) -> ChatRecord? {
        (try? Data(contentsOf: folder(paths).appending(path: "\(id).json"))).flatMap {
            try? HubPaths.decoder.decode(ChatRecord.self, from: $0)
        }
    }

    /// True while the process exists, even one this user may not signal.
    static func isRunning(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// True when the process that was running at `date` still is.
    ///
    /// A process with the same PID that started later only reuses it. Dates are saved to the
    /// second, so a little slack.
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
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid
        else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }

    /// Removes the files of chats whose process is gone, such as an MCP copy that was killed,
    /// and returns the chats still open.
    @discardableResult
    static func removeClosedChats(_ paths: HubPaths) -> [ChatRecord] {
        let files =
            (try? FileManager.default.contentsOfDirectory(at: folder(paths), includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            guard let data = try? Data(contentsOf: file),
                let chat = try? HubPaths.decoder.decode(ChatRecord.self, from: data)
            else { return nil }
            guard isRunning(chat.pid, since: chat.registeredAt) else {
                unregister(chat.id, paths: paths)
                return nil
            }
            return chat
        }
    }

}
#endif
