#if os(macOS)
import Darwin
import Foundation

/// Adds this tool's hooks to each agent's user hook settings, keeping every other hook there, and
/// takes them out again.
///
/// Running it twice changes nothing.
enum AgentSettings {
    /// The agent's user hook settings file.
    static func fileURL(for agent: Agent) -> URL {
        let home = URL.homeDirectory
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

    /// The tool's command name.
    ///
    /// A hook that runs it, from any folder, is a copy of this tool's, such as one from before a
    /// move.
    private static let commandName = "redline"

    private static func isOurs(_ hook: Any) -> Bool {
        guard let command = (hook as? [String: Any])?["command"] as? String, command.hasPrefix("'"),
            let end = command.range(of: "' hook ")
        else { return false }
        let path = String(command[command.index(after: command.startIndex)..<end.lowerBound]).replacing(
            "'\\''",
            with: "'"
        )
        return URL(filePath: path).lastPathComponent == commandName
    }

    /// The settings with this tool's hooks in place, replacing any older copy of them.
    static func adding(_ agent: Agent, to settings: [String: Any], executable: String) -> [String: Any] {
        var settings = removing(agent, from: settings)
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
    static func removing(_ agent: Agent, from settings: [String: Any]) -> [String: Any] {
        var settings = settings
        guard var events = settings["hooks"] as? [String: Any] else { return settings }
        var removedAny = false
        for (event, value) in events {
            guard let entries = value as? [Any] else { continue }
            let kept: [Any] = entries.compactMap { entry in
                if isOurs(entry) { return nil }
                guard var group = entry as? [String: Any], let hooks = group["hooks"] as? [Any] else { return entry }
                let others = hooks.filter { !isOurs($0) }
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
