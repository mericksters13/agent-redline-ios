#if os(macOS)
import Foundation

/// A worktree of its own for a chat the hub starts, made from the worktree the app was built
/// from: the same commit on a new branch, with that worktree's uncommitted changes, so the
/// chat reads the code that's on the device and works without touching any other worktree.
/// It goes where the agent keeps its own worktrees, so the chat looks like one it made.
enum NewWorktree {
    /// Returns the new worktree's path, or nil when the folder isn't in a git repository or
    /// git refuses.
    static func create(from source: String, name: String, agent: Agent) -> String? {
        guard let top = git(source, ["rev-parse", "--show-toplevel"]),
              let common = git(source, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
        else { return nil }
        let commonURL = URL(fileURLWithPath: common)
        let repository = commonURL.lastPathComponent == ".git" ? commonURL.deletingLastPathComponent().path : top
        var path = folder(for: agent, repository: repository, name: name)
        var branch = "report/\(name)"
        // A name already taken, by an earlier report with the same name, gets a number.
        var attempt = 1
        while FileManager.default.fileExists(atPath: path) || git(top, ["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"]) != nil {
            attempt += 1
            path = folder(for: agent, repository: repository, name: "\(name)-\(attempt)")
            branch = "report/\(name)-\(attempt)"
        }
        try? FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        guard git(top, ["worktree", "add", "-b", branch, path, "HEAD"]) != nil else { return nil }
        // What was built includes the source worktree's uncommitted changes.
        if let changes = run("/usr/bin/git", ["-C", top, "diff", "--binary", "HEAD"]), !changes.isEmpty {
            _ = run("/usr/bin/git", ["-C", path, "apply", "--whitespace=nowarn"], input: changes)
        }
        return path
    }

    static func folder(for agent: Agent, repository: String, name: String) -> String {
        switch agent {
        case .claude: "\(repository)/.claude/worktrees/\(name)"
        case .codex: "\(NSHomeDirectory())/.codex/worktrees/\(name)/\(URL(fileURLWithPath: repository).lastPathComponent)"
        case .cursor: "\(repository)/.cursor/worktrees/\(name)"
        }
    }

    /// A git command's output, trimmed; nil when it fails.
    private static func git(_ folder: String, _ arguments: [String]) -> String? {
        run("/usr/bin/git", ["-C", folder] + arguments).map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// A command's standard output; nil when it fails.
    private static func run(_ executable: String, _ arguments: [String], input: Data? = nil) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let stdin = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        do { try process.run() } catch { return nil }
        if let input {
            stdin.fileHandleForWriting.write(input)
            try? stdin.fileHandleForWriting.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}

/// The chats the hub started for "New chat", by the phone's pick, so later reports with the same
/// pick go to that chat instead of starting another. Picking "New chat" again on the phone makes
/// a new pick, and a new chat.
struct StartedChat: Codable, Equatable, Sendable {
    /// Codex's thread ID or Claude Code's session ID.
    var chat: String
    /// The chat's own worktree.
    var folder: String
    var at: Date
}

enum StartedChats {
    static func file(_ paths: HubPaths) -> URL { paths.hub.appending(path: "started-chats.json") }

    static func all(_ paths: HubPaths) -> [String: StartedChat] {
        (try? Data(contentsOf: file(paths))).flatMap { try? Chats.decoder.decode([String: StartedChat].self, from: $0) } ?? [:]
    }

    /// The chat started for this pick, while its worktree still exists.
    static func find(_ pick: String, paths: HubPaths) -> StartedChat? {
        all(paths)[pick].flatMap { FileManager.default.fileExists(atPath: $0.folder) ? $0 : nil }
    }

    static func remember(_ chat: StartedChat, for pick: String, paths: HubPaths) {
        var chats = all(paths)
        chats[pick] = chat
        try? FileManager.default.createDirectory(at: paths.hub, withIntermediateDirectories: true)
        try? Chats.coder.encode(chats).write(to: file(paths), options: .atomic)
    }
}
#endif
