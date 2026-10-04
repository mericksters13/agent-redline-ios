#if os(macOS)
import Foundation

/// A worktree of its own for a chat the hub starts: a new branch from the repository's main branch,
/// fetched first so it's current, in the repository the app was built from.
///
/// The chat works without touching any other worktree. It goes where the agent keeps its own
/// worktrees, so the chat looks like one it made.
enum NewWorktree {
    enum Failure: Error, LocalizedError {
        /// The folder isn't in a git repository.
        case notARepository(String)
        /// Neither origin's default branch nor a local main or master can be found.
        case noMainBranch(String)
        /// Git refused or didn't finish in time.
        case gitFailed(arguments: [String])

        var errorDescription: String? {
            switch self {
            case .notARepository(let folder): "\(folder) isn't in a git repository"
            case .noMainBranch(let folder): "\(folder) has no main branch to start from"
            case .gitFailed(let arguments): "git \(arguments.joined(separator: " ")) failed"
            }
        }
    }

    /// Makes the worktree and returns its path.
    ///
    /// Throws when the folder isn't in a git repository, its main branch can't be told, or git
    /// refuses.
    static func create(from source: String, name: String, agent: Agent) throws -> String {
        guard let top = git(["rev-parse", "--show-toplevel"], in: source),
            let common = git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: source)
        else { throw Failure.notARepository(source) }
        let commonURL = URL(filePath: common)
        let repository = commonURL.lastPathComponent == ".git" ? commonURL.deletingLastPathComponent().path : top
        // The folder is named "report-<ID>", its branch "report/<ID>".
        let id = name.hasPrefix("report-") ? String(name.dropFirst("report-".count)) : name
        var path = folder(for: agent, repository: repository, name: name)
        var branch = "report/\(id)"
        // A name already taken, by an earlier report with the same name, gets a number.
        var attempt = 1
        while FileManager.default.fileExists(atPath: path)
            || git(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], in: top) != nil
        {
            attempt += 1
            path = folder(for: agent, repository: repository, name: "\(name)-\(attempt)")
            branch = "report/\(id)-\(attempt)"
        }
        fetchMainBranch(of: top)
        // Never the checkout's own branch: a report's chat starts from main, not from whatever the
        // app was built from.
        guard let base = mainBranch(of: top)?.ref else { throw Failure.noMainBranch(top) }
        try FileManager.default.createDirectory(
            at: URL(filePath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try excludeWorktrees(of: agent, in: commonURL)
        let add = ["worktree", "add", "-b", branch, path, base]
        guard git(add, in: top) != nil else { throw Failure.gitFailed(arguments: add) }
        return path
    }

    /// Keeps the agent's worktrees folder inside the repository out of `git status` in the main
    /// checkout, through the repository's own exclude file rather than any tracked file.
    private static func excludeWorktrees(of agent: Agent, in commonDirectory: URL) throws {
        let pattern: String
        switch agent {
        case .claude: pattern = "/.claude/worktrees/"
        case .codex: return
        }
        let exclude = commonDirectory.appending(path: "info/exclude")
        let existing =
            FileManager.default.fileExists(atPath: exclude.path(percentEncoded: false))
            ? try String(contentsOf: exclude, encoding: .utf8) : ""
        guard !existing.split(separator: "\n").contains(Substring(pattern)) else { return }
        try FileManager.default.createDirectory(
            at: exclude.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        try (existing + separator + pattern + "\n").write(to: exclude, atomically: true, encoding: .utf8)
    }

    /// Copies a report's files into `.redline/<report>` in a worktree, a folder git ignores there,
    /// so a chat in the worktree reads them without asking.
    ///
    /// Returns the copy.
    static func copyReport(_ report: URL, into worktree: String) throws -> String {
        let folder = URL(filePath: worktree).appending(path: ".redline", directoryHint: .isDirectory)
        let copy = folder.appending(path: report.lastPathComponent, directoryHint: .isDirectory)
        let files = FileManager.default
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        // An earlier copy of the same report is replaced.
        try? files.removeItem(at: copy)
        try files.copyItem(at: report, to: copy)
        // Ignored by git without touching the repository's own .gitignore.
        try "*\n".write(to: folder.appending(path: ".gitignore"), atomically: true, encoding: .utf8)
        return copy.path
    }

    /// Takes back a worktree made for a chat that didn't start, and its branch, which holds
    /// nothing but main's commit.
    static func remove(_ path: String) {
        let branch = git(["branch", "--show-current"], in: path)
        guard let common = git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: path) else { return }
        let repository = URL(filePath: common).deletingLastPathComponent().path
        _ = git(["worktree", "remove", "--force", path], in: repository)
        if let branch, branch.hasPrefix("report/") { _ = git(["branch", "-D", branch], in: repository) }
    }

    /// Fetches origin's default branch, so a new worktree starts from it as it is now.
    ///
    /// A clone can lack origin's default branch locally, so origin is asked which it is first.
    /// Best effort, and never waiting for a password: without the network, the last fetch is used.
    static func fetchMainBranch(of folder: String) {
        func originDefault() -> String? {
            git(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: folder)
                .flatMap { $0.hasPrefix("origin/") ? String($0.dropFirst("origin/".count)) : nil }
        }
        var name = originDefault()
        if name == nil, git(["remote", "set-head", "origin", "--auto"], in: folder, timeout: 20) != nil {
            name = originDefault()
        }
        guard let name else { return }
        _ = git(["fetch", "--quiet", "origin", name], in: folder, timeout: 20)
    }

    /// The repository's main branch: origin's default branch, else a local main or master. `name`
    /// is what the phone shows.
    ///
    /// Nil when none of these can be told. Changes nothing.
    static func mainBranch(of folder: String) -> (ref: String, name: String)? {
        if let remote = git(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: folder),
            remote.hasPrefix("origin/")
        {
            return (remote, String(remote.dropFirst("origin/".count)))
        }
        for name in ["main", "master"]
        where git(["rev-parse", "--verify", "--quiet", "refs/heads/\(name)"], in: folder) != nil {
            return (name, name)
        }
        return nil
    }

    /// Where the agent keeps its own worktrees for the repository.
    static func folder(for agent: Agent, repository: String, name: String) -> String {
        switch agent {
        case .claude: "\(repository)/.claude/worktrees/\(name)"
        case .codex:
            AgentSettings.homeDirectory()
                .appending(path: ".codex/worktrees/\(name)/\(URL(filePath: repository).lastPathComponent)").path
        }
    }

    /// A git command's output, trimmed; nil when it fails or runs past `timeout`.
    private static func git(_ arguments: [String], in folder: String, timeout: TimeInterval = 60) -> String? {
        run("/usr/bin/git", arguments: ["-C", folder] + arguments, timeout: timeout)
            .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// Where git's deadlines run.
    private static let deadlines = DispatchQueue(label: "Redline.git.deadlines", qos: .utility)

    /// A command's standard output; nil when it fails or runs past `timeout`.
    private static func run(_ executable: String, arguments: [String], timeout: TimeInterval = 60) -> Data? {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        // Git never stops to ask for a password or passphrase: there's nobody to answer.
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["GIT_TERMINAL_PROMPT": "0", "GIT_SSH_COMMAND": "ssh -o BatchMode=yes"]) { $1 }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        deadlines.asyncAfter(deadline: .now() + timeout, execute: deadline)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // Done in time: the deadline doesn't keep the process around for the rest of the timeout.
        deadline.cancel()
        return process.terminationStatus == 0 ? data : nil
    }
}
#endif
