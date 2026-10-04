#if os(macOS)
import Foundation

/// A worktree of its own for a chat the hub starts: a new branch from the repository's main
/// branch, fetched first so it's current, in the repository the app was built from. The chat
/// works without touching any other worktree. It goes where the agent keeps its own worktrees,
/// so the chat looks like one it made.
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
        let base = mainBranch(of: top, fetching: true)?.ref ?? "HEAD"
        guard git(top, ["worktree", "add", "-b", branch, path, base]) != nil else { return nil }
        return path
    }

    /// Takes back a worktree made for a chat that didn't start, and its branch, which holds
    /// nothing but main's commit.
    static func remove(_ path: String) {
        let branch = git(path, ["branch", "--show-current"])
        guard let common = git(path, ["rev-parse", "--path-format=absolute", "--git-common-dir"]) else { return }
        let repository = URL(fileURLWithPath: common).deletingLastPathComponent().path
        _ = git(repository, ["worktree", "remove", "--force", path])
        if let branch, branch.hasPrefix("report/") { _ = git(repository, ["branch", "-D", branch]) }
    }

    /// The repository's main branch: origin's default branch, fetched first when `fetching`,
    /// else a local main or master. `name` is what the phone shows.
    static func mainBranch(of folder: String, fetching: Bool = false) -> (ref: String, name: String)? {
        if let remote = git(folder, ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"]), remote.hasPrefix("origin/") {
            let name = String(remote.dropFirst("origin/".count))
            // Best effort, and never waiting for a password: without the network, the last fetch is used.
            if fetching { _ = git(folder, ["fetch", "--quiet", "origin", name], timeout: 20) }
            return (remote, name)
        }
        for name in ["main", "master"] where git(folder, ["rev-parse", "--verify", "--quiet", "refs/heads/\(name)"]) != nil {
            return (name, name)
        }
        return nil
    }

    static func folder(for agent: Agent, repository: String, name: String) -> String {
        switch agent {
        case .claude: "\(repository)/.claude/worktrees/\(name)"
        case .codex: "\(NSHomeDirectory())/.codex/worktrees/\(name)/\(URL(fileURLWithPath: repository).lastPathComponent)"
        case .cursor: "\(repository)/.cursor/worktrees/\(name)"
        }
    }

    /// A git command's output, trimmed; nil when it fails or runs past `timeout`.
    private static func git(_ folder: String, _ arguments: [String], timeout: TimeInterval = 60) -> String? {
        run("/usr/bin/git", ["-C", folder] + arguments, timeout: timeout)
            .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// A command's standard output; nil when it fails or runs past `timeout`.
    private static func run(_ executable: String, _ arguments: [String], input: Data? = nil, timeout: TimeInterval = 60) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // Git never stops to ask for a password or passphrase: there's nobody to answer.
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["GIT_TERMINAL_PROMPT": "0", "GIT_SSH_COMMAND": "ssh -o BatchMode=yes"]) { $1 }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let stdin = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        do { try process.run() } catch { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
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
