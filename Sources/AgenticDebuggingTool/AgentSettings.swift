#if os(macOS)
import Foundation

/// Adds this tool's hooks to each agent's user hook settings, keeping every other hook there,
/// and takes them out again. Running it twice changes nothing.
enum AgentSettings {
    static func file(_ agent: Agent) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch agent {
        case .claude: return home.appending(path: ".claude/settings.json")
        case .codex: return home.appending(path: ".codex/hooks.json")
        case .cursor: return home.appending(path: ".cursor/hooks.json")
        }
    }

    /// The agent's settings folder exists, so the agent has been used on this Mac.
    static func isPresent(_ agent: Agent) -> Bool {
        FileManager.default.fileExists(atPath: file(agent).deletingLastPathComponent().path)
    }

    static func command(_ executable: String, _ agent: Agent, _ event: HookEvent) -> String {
        "'\(executable.replacingOccurrences(of: "'", with: "'\\''"))' hook \(agent.rawValue) \(event.rawValue)"
    }

    /// This tool's hooks, by the agent's event name.
    static func hooks(_ agent: Agent, executable: String) -> [(event: String, hooks: [[String: Any]])] {
        func hook(_ event: HookEvent, _ extra: [String: Any] = [:]) -> [String: Any] {
            var hook: [String: Any] = ["command": command(executable, agent, event)]
            if agent != .cursor { hook["type"] = "command" }
            return hook.merging(extra) { $1 }
        }
        // A little longer than the hold, so the agent never cuts it short.
        let holdTimeout = Int(AgentHooks.holdOpen) + 60
        switch agent {
        case .claude:
            // Claude Code enforces a timeout even on a background hook; a week, renewed after every reply.
            let wait = hook(.wait, ["asyncRewake": true, "timeout": 604_800])
            return [("SessionStart", [hook(.start), wait]), ("UserPromptSubmit", [hook(.prompt)]), ("Stop", [wait]), ("SessionEnd", [hook(.end)])]
        case .codex:
            return [("SessionStart", [hook(.start)]), ("UserPromptSubmit", [hook(.prompt)]),
                    ("Stop", [hook(.stop, ["timeout": holdTimeout, "statusMessage": "Waiting for phone reports"])]),
                    ("SessionEnd", [hook(.end)])]
        case .cursor:
            return [("sessionStart", [hook(.start)]), ("beforeSubmitPrompt", [hook(.prompt)]),
                    ("stop", [hook(.stop, ["timeout": holdTimeout, "loop_limit": NSNull()])]), ("sessionEnd", [hook(.end)])]
        }
    }

    static func isOurs(_ hook: Any, executable: String) -> Bool {
        let prefix = "'\(executable.replacingOccurrences(of: "'", with: "'\\''"))' hook "
        return ((hook as? [String: Any])?["command"] as? String)?.hasPrefix(prefix) ?? false
    }

    /// The settings with this tool's hooks in place, replacing any older copy of them.
    static func adding(_ agent: Agent, to settings: [String: Any], executable: String) -> [String: Any] {
        var settings = removing(agent, from: settings, executable: executable)
        var events = settings["hooks"] as? [String: Any] ?? [:]
        for (event, hooks) in self.hooks(agent, executable: executable) {
            var entries = events[event] as? [Any] ?? []
            // Claude Code and Codex group hooks under a matcher; Cursor lists them directly.
            entries += agent == .cursor ? hooks : [["hooks": hooks]]
            events[event] = entries
        }
        settings["hooks"] = events
        if agent == .cursor, settings["version"] == nil { settings["version"] = 1 }
        return settings
    }

    /// The settings without this tool's hooks; everything else stays.
    static func removing(_ agent: Agent, from settings: [String: Any], executable: String) -> [String: Any] {
        var settings = settings
        guard var events = settings["hooks"] as? [String: Any] else { return settings }
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
            events[event] = kept.isEmpty ? nil : kept
        }
        settings["hooks"] = events.isEmpty ? nil : events
        return settings
    }

    /// Reads, changes and writes an agent's settings, keeping a copy of the file as it was the
    /// first time this tool changed it.
    static func update(_ agent: Agent, _ change: ([String: Any]) -> [String: Any]) throws {
        let file = file(agent)
        let files = FileManager.default
        try files.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var current: [String: Any] = [:]
        if let data = try? Data(contentsOf: file) {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: file.path])
            }
            current = object
            let backup = file.appendingPathExtension("before-agentic-debugging")
            if !files.fileExists(atPath: backup.path) { try data.write(to: backup) }
        }
        let data = try JSONSerialization.data(withJSONObject: change(current), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: file, options: .atomic)
    }
}
#endif
