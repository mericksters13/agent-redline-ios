#if os(macOS)
import Darwin
import Foundation

/// Adds this tool's hooks to each agent's user hook settings, keeping every other hook there, and
/// takes them out again.
///
/// Running it twice changes nothing.
enum AgentSettings {
    /// The home folder in `HOME`, where the agents themselves keep their settings and chats.
    ///
    /// Every home-relative path Redline uses comes from here, so Redline run with another `HOME`
    /// uses the settings, chats, app and data there.
    ///
    /// Foundation's home folder ignores `HOME` on macOS. Only an absolute path counts: an empty or
    /// relative one would point at the current folder.
    static func homeDirectory(in environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        guard let home = environment["HOME"], home.hasPrefix("/") else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(filePath: home, directoryHint: .isDirectory)
    }

    /// The agent's user hook settings file.
    static func fileURL(for agent: Agent) -> URL {
        let home = homeDirectory()
        switch agent {
        case .claude: return home.appending(path: ".claude/settings.json")
        case .codex: return home.appending(path: ".codex/hooks.json")
        }
    }

    /// The agent's settings folder exists, so the agent has been used on this Mac.
    static func isPresent(_ agent: Agent) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: agent).deletingLastPathComponent().path)
    }

    private static func command(running executable: String, agent: Agent, event: HookEvent) -> String {
        "'\(executable.replacing("'", with: "'\\''"))' hook \(agent.rawValue) \(event.rawValue)"
    }

    /// This tool's hooks, by the agent's event name, with the matcher that limits them to
    /// commands and MCP tools where an agent supports one.
    static func hooks(_ agent: Agent, executable: String) -> [(event: String, matcher: String?, hooks: [[String: Any]])]
    {
        func hook(_ event: HookEvent, _ extra: [String: Any] = [:]) -> [String: Any] {
            ["type": "command", "command": command(running: executable, agent: agent, event: event)].merging(extra) {
                $1
            }
        }
        switch agent {
        case .claude:
            // Claude Code chats are found from their own session records and reached through their socket.
            return []
        case .codex:
            // Codex chats are reached through the Codex app. This hook is the safety net for a
            // report the app didn't take: it goes in with the chat's next message.
            return [("UserPromptSubmit", nil, [hook(.prompt, ["statusMessage": "Report delivery"])])]
        }
    }

    /// Cursor's hook settings file.
    ///
    /// Cursor isn't supported, but an earlier setup added hooks there. Setup and remove take them
    /// out, so none is left running a command that is later removed.
    static func cursorFileURL() -> URL {
        homeDirectory().appending(path: ".cursor/hooks.json")
    }

    /// The earlier version's command name.
    ///
    /// Setup replaces its hooks, so the installer can remove that command.
    private static let earlierCommandName = "agentic-debugging"

    /// Every agent and event a hook of an earlier version ran with, Cursor's included: `wait` and
    /// `built` from the first versions too.
    private static let earlierHookArguments: (agents: Set<String>, events: Set<String>) = (
        ["claude", "codex", "cursor"], ["start", "prompt", "wait", "built", "stop", "end"]
    )

    /// This tool's hook: one that runs this executable, or one the earlier version left under its
    /// name, `agentic-debugging`, with exactly a hook's arguments.
    ///
    /// A command of another tool, even one also named `redline` in another folder, is never taken for
    /// it.
    private static func isOurs(_ hook: Any, executable: String) -> Bool {
        guard let command = (hook as? [String: Any])?["command"] as? String else { return false }
        if command.hasPrefix("'\(executable.replacing("'", with: "'\\''"))' hook ") { return true }
        guard command.hasPrefix("'"), let end = command.range(of: "' hook ") else { return false }
        let path = String(command[command.index(after: command.startIndex)..<end.lowerBound]).replacing(
            "'\\''",
            with: "'"
        )
        let arguments = command[end.upperBound...].split(separator: " ", omittingEmptySubsequences: false)
        return URL(filePath: path).lastPathComponent == earlierCommandName && arguments.count == 2
            && earlierHookArguments.agents.contains(String(arguments[0]))
            && earlierHookArguments.events.contains(String(arguments[1]))
    }

    /// The settings with this tool's hooks in place, replacing any older copy of them.
    static func adding(_ agent: Agent, to settings: [String: Any], executable: String) -> [String: Any] {
        var settings = removing(from: settings, executable: executable)
        let hooks = self.hooks(agent, executable: executable)
        guard !hooks.isEmpty else { return settings }
        var events = settings["hooks"] as? [String: Any] ?? [:]
        for (event, matcher, hooks) in hooks {
            var entries = events[event] as? [Any] ?? []
            // Claude Code and Codex group hooks under a matcher.
            var group: [String: Any] = ["hooks": hooks]
            if let matcher { group["matcher"] = matcher }
            entries.append(group)
            events[event] = entries
        }
        settings["hooks"] = events.isEmpty ? nil : events
        return settings
    }

    /// The settings without this tool's hooks; everything else stays.
    static func removing(from settings: [String: Any], executable: String) -> [String: Any] {
        var settings = settings
        guard var events = settings["hooks"] as? [String: Any] else { return settings }
        var removedAny = false
        for (event, value) in events {
            guard let entries = value as? [Any] else { continue }
            let kept: [Any] = entries.compactMap { entry in
                if isOurs(entry, executable: executable) { return nil }
                guard var group = entry as? [String: Any], let hooks = group["hooks"] as? [Any] else { return entry }
                let others = hooks.filter { !isOurs($0, executable: executable) }
                if others.isEmpty { return nil }
                group["hooks"] = others
                return group
            }
            guard kept.count != entries.count || !NSArray(array: kept).isEqual(to: entries) else { continue }
            removedAny = true
            events[event] = kept.isEmpty ? nil : kept
        }
        // Without any of this tool's hooks, the user's settings stay exactly as they were.
        guard removedAny else { return settings }
        settings["hooks"] = events.isEmpty ? nil : events
        return settings
    }

    /// True when the settings hold one of this tool's hooks; false when removing them would change
    /// nothing.
    static func containsHooks(in settings: [String: Any], executable: String) -> Bool {
        !NSDictionary(dictionary: removing(from: settings, executable: executable)).isEqual(to: settings)
    }

    /// True when the settings file holds one of this tool's hooks; false when it holds none or
    /// doesn't exist.
    ///
    /// A file that exists but can't be read or isn't a JSON object throws.
    static func containsHooks(inFile file: URL, executable: String) throws -> Bool {
        guard let data = try StoredFile.read(file) else { return false }
        guard let settings = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: file.path])
        }
        return containsHooks(in: settings, executable: executable)
    }

    /// Reads, changes and writes an agent's settings, keeping a copy of the file as it was the
    /// first time this tool changed it.
    static func update(_ agent: Agent, applying change: (_ settings: [String: Any]) -> [String: Any]) throws {
        try update(fileURL(for: agent), applying: change)
    }

    /// Changes a settings file.
    ///
    /// A change that leaves the settings as they were writes nothing, not even the copy, so the
    /// file keeps its own formatting. A file that exists but can't be read throws, so it's never
    /// written over as if it were empty.
    static func update(_ file: URL, applying change: (_ settings: [String: Any]) -> [String: Any]) throws {
        let files = FileManager.default
        var current: [String: Any] = [:]
        let data = try StoredFile.read(file)
        if let data {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: file.path])
            }
            current = object
        }
        let changed = change(current)
        if data != nil, NSDictionary(dictionary: changed).isEqual(to: current) { return }
        try files.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data {
            let backup = file.appendingPathExtension("before-redline")
            if !files.fileExists(atPath: backup.path) { try data.write(to: backup) }
        }
        let output = try JSONSerialization.data(
            withJSONObject: changed,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try output.write(to: file, options: .atomic)
    }
}
#endif
