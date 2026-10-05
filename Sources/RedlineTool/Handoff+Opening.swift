#if os(macOS)
import Foundation

/// Opening chats and links for the user: in the agent's app, or in a terminal window.
extension Handoff {
    /// Opens a terminal window in `folder` running `command`, with `arguments` and then `last`,
    /// through a `.command` file: it opens in the user's terminal and needs no permission to
    /// control one. `last` goes through a file, so no quoting can break it.
    static func openTerminal(in folder: String, running command: String, arguments: [String] = [], with last: String)
        throws
    {
        let scripts = URL(filePath: folder).appending(path: ".redline", directoryHint: .isDirectory)
        let name = "chat-\(UUID().uuidString.prefix(8))"
        let lastFile = scripts.appending(path: "\(name).txt")
        let script = scripts.appending(path: "\(name).command")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let ignore = scripts.appending(path: ".gitignore")
        if !FileManager.default.fileExists(atPath: ignore.path) {
            try "*\n".write(to: ignore, atomically: true, encoding: .utf8)
        }
        try last.write(to: lastFile, atomically: true, encoding: .utf8)
        try terminalScript(folder: folder, command: command, arguments: arguments, lastFile: lastFile.path).write(
            to: script,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        try openURL(script.path)
    }

    /// The script a terminal runs: into the folder, read the last argument from its file, remove
    /// the file and the script, then run the command.
    static func terminalScript(folder: String, command: String, arguments: [String], lastFile: String) -> String {
        func quoted(_ text: String) -> String { "'" + text.replacing("'", with: "'\\''") + "'" }
        return [
            "#!/bin/zsh",
            "cd \(quoted(folder)) || exit 1",
            "last=\"$(cat \(quoted(lastFile)))\"",
            "rm -f \(quoted(lastFile)) \"$0\"",
            "exec \(([command] + arguments).map(quoted).joined(separator: " ")) \"$last\"",
        ].joined(separator: "\n") + "\n"
    }

    /// Runs a command in a folder and waits for it.
    ///
    /// Throws when it can't start; returns whether it exited with status 0.
    @discardableResult
    static func run(_ executable: String, arguments: [String], in folder: String) throws -> Bool {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(filePath: folder)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationReason == .exit && process.terminationStatus == 0
    }

    /// Opens a chat where the user works with its agent: in the Claude or Codex app when it's
    /// installed, else in a terminal window in `folder` that resumes it.
    ///
    /// Throws when it can't: neither the app nor the command is there, a terminal is needed and
    /// there is no folder to open it in, or opening fails.
    static func openChat(_ agent: Agent, id: String, in folder: String?) throws {
        // The Claude app's link copies a chat started in one of its tabs into a second tab that
        // no longer follows the first, and no link opens the first one
        // (https://github.com/anthropics/claude-code/issues/80773), so the app only comes forward.
        if agent == .claude, AgentCommand.isClaudeAppInstalled(),
            ClaudeSessions.openSessions().contains(where: { $0.id == id && $0.isAppTab })
        {
            try runOpen(["-b", AgentCommand.claudeAppID])
            return
        }
        if let link = appLink(agent, id: id) {
            try openURL(link)
            return
        }
        guard let command = AgentCommand.locate(agent) else { throw OpenError.agentNotFound(agent) }
        guard let folder else { throw OpenError.folderUnknown }
        let resume =
            switch agent {
            case .codex: ["resume"]
            case .claude: ["--resume"]
            }
        try openTerminal(in: folder, running: command.path, arguments: resume, with: id)
    }

    /// Why a chat couldn't be opened.
    enum OpenError: Error, LocalizedError {
        case agentNotFound(Agent)
        /// A terminal is needed and the folder the chat worked in is gone or unknown.
        case folderUnknown
        /// macOS couldn't open the link or file, such as when no app takes it.
        case openFailed

        var errorDescription: String? {
            switch self {
            case .agentNotFound(let agent): "Redline found neither the \(agent.name) app nor its command on this Mac."
            case .folderUnknown:
                "The folder this chat worked in is gone or unknown, so Redline can't resume it in a terminal."
            case .openFailed: "macOS couldn't open the chat. No app took the link or file."
            }
        }
    }

    /// The link that opens a chat in its agent's app, when the app is installed.
    ///
    /// The Claude app's link is the one `claude --desktop --resume` opens: the app takes the chat
    /// over from the claude command.
    static func appLink(
        _ agent: Agent,
        id: String,
        isClaudeAppInstalled: Bool = AgentCommand.isClaudeAppInstalled(),
        isCodexAppInstalled: Bool = AgentCommand.isCodexAppInstalled()
    ) -> String? {
        switch agent {
        case .claude:
            guard isClaudeAppInstalled else { return nil }
            var link = URLComponents(string: "claude://resume")
            link?.queryItems = [URLQueryItem(name: "session", value: id)]
            return link?.string
        case .codex:
            guard isCodexAppInstalled else { return nil }
            return "codex://threads/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)"
        }
    }

    /// Opens a link or file with /usr/bin/open and waits for it.
    ///
    /// Throws when open can't start or fails, such as when no app takes the link.
    static func openURL(_ link: String) throws {
        try runOpen([link])
    }

    /// Runs /usr/bin/open with `arguments` and waits for it.
    ///
    /// Throws when open can't start or fails, such as when no app takes the link.
    private static func runOpen(_ arguments: [String]) throws {
        let open = Process()
        open.executableURL = URL(filePath: "/usr/bin/open")
        open.arguments = arguments
        open.standardInput = FileHandle.nullDevice
        try open.run()
        open.waitUntilExit()
        guard open.terminationReason == .exit, open.terminationStatus == 0 else { throw OpenError.openFailed }
    }
}
#endif
