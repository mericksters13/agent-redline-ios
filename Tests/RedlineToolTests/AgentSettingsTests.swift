#if os(macOS)
import Foundation
import Testing
@testable import RedlineTool

struct AgentSettingsTests {
    private let temporary = TemporaryFolder("AgentSettingsTests")
    private var root: URL { temporary.url }
    private var paths: HubPaths { HubPaths(root: root.appending(path: "hub-root", directoryHint: .isDirectory)) }
    private let executable = "/Users/someone/.local/bin/redline"

    /// Codex's hooks.json with another tool's hooks.
    private let codexSettings: [String: Any] = [
        "hooks": [
            "PostToolUse": [
                [
                    "matcher": "Edit|Write|apply_patch",
                    "hooks": [["type": "command", "command": "node hook.mjs", "timeout": 5]],
                ]
            ],
            "Stop": [
                ["hooks": [["type": "command", "command": "node hook.mjs", "timeout": 30, "statusMessage": "Review"]]]
            ],
        ]
    ]

    private func commands(_ settings: [String: Any], _ event: String) -> [String] {
        let entries = (settings["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
        return entries.flatMap { entry in
            (entry["hooks"] as? [[String: Any]]).map { $0.compactMap { $0["command"] as? String } }
                ?? [entry["command"] as? String].compactMap { $0 }
        }
    }

    @Test func setupKeepsOtherHooksAndRemovesCleanly() throws {
        let added = AgentSettings.adding(.codex, to: codexSettings, executable: executable)
        // Codex chats are woken through the Codex app: no stop hook holds them open.
        #expect(commands(added, "Stop") == ["node hook.mjs"])
        #expect(commands(added, "PostToolUse") == ["node hook.mjs"])
        // One hook for Codex: the safety net for a report the Codex app didn't take.
        #expect(commands(added, "UserPromptSubmit") == ["'\(executable)' hook codex prompt"])
        #expect((added["hooks"] as? [String: Any])?.keys.sorted() == ["PostToolUse", "Stop", "UserPromptSubmit"])
        // Run again, nothing changes.
        #expect(try sortedJSON(AgentSettings.adding(.codex, to: added, executable: executable)) == sortedJSON(added))
        // Removed, the file is as it was.
        #expect(
            try sortedJSON(AgentSettings.removing(from: added, executable: executable)) == sortedJSON(codexSettings)
        )
        // A command of another tool that happens to have a hook subcommand stays.
        let other: [String: Any] = [
            "hooks": ["Stop": [["hooks": [["type": "command", "command": "'/opt/bin/other' hook stop"]]]]]
        ]
        #expect(try sortedJSON(AgentSettings.removing(from: other, executable: executable)) == sortedJSON(other))
        // Nor does another tool's command that is also named redline, in another folder.
        let namesake: [String: Any] = [
            "hooks": ["Stop": [["hooks": [["type": "command", "command": "'/opt/bin/redline' hook codex stop"]]]]]
        ]
        #expect(try sortedJSON(AgentSettings.removing(from: namesake, executable: executable)) == sortedJSON(namesake))
        // Nor a command under the earlier name with other arguments.
        let lookalike: [String: Any] = [
            "hooks": [
                "Stop": [["hooks": [["type": "command", "command": "'/opt/bin/agentic-debugging' hook stop --all"]]]]
            ]
        ]
        #expect(
            try sortedJSON(AgentSettings.removing(from: lookalike, executable: executable)) == sortedJSON(lookalike)
        )
        // A hook the earlier version left, from any folder, is replaced.
        let earlier: [String: Any] = [
            "hooks": [
                "UserPromptSubmit": [
                    ["hooks": [["type": "command", "command": "'/opt/old/agentic-debugging' hook codex prompt"]]]
                ]
            ]
        ]
        #expect(
            commands(AgentSettings.adding(.codex, to: earlier, executable: executable), "UserPromptSubmit") == [
                "'\(executable)' hook codex prompt"
            ]
        )
    }

    @Test func settingsThatDontChangeAreNotWritten() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "settings.json")
        let original = Data("{\n  \"model\" : \"opus\",\n  \"hooks\" : {}\n}\n".utf8)
        try original.write(to: file)
        try AgentSettings.update(file) { AgentSettings.adding(.claude, to: $0, executable: executable) }
        #expect(try Data(contentsOf: file) == original)
        #expect(!FileManager.default.fileExists(atPath: file.path + ".before-redline"))
        // A file that exists but can't be read stops the update; nothing is written over it.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        #expect(throws: (any Error).self) {
            try AgentSettings.update(file) { AgentSettings.adding(.codex, to: $0, executable: executable) }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func aHookFromAFolderWithAnApostropheIsStillRecognized() throws {
        let executable = "/Users/someone/Someone's tools/redline"
        let added = AgentSettings.adding(.codex, to: codexSettings, executable: executable)
        #expect(
            commands(added, "UserPromptSubmit") == ["'/Users/someone/Someone'\\''s tools/redline' hook codex prompt"]
        )
        // Recognized as this tool's, so removing gives back the settings as they were.
        #expect(
            try sortedJSON(AgentSettings.removing(from: added, executable: executable)) == sortedJSON(codexSettings)
        )
        // And a second setup replaces it rather than adding another.
        #expect(
            commands(AgentSettings.adding(.codex, to: added, executable: executable), "UserPromptSubmit").count == 1
        )
    }

    @Test func setupTakesOutCursorHooksFromAnEarlierSetup() throws {
        // Cursor's hooks.json, as an earlier setup left it.
        let cursor: [String: Any] = [
            "version": 1, "hooks": ["stop": [["command": "'\(executable)' hook cursor stop"]]],
        ]
        #expect(AgentSettings.containsHooks(in: cursor, executable: executable))
        #expect(
            try sortedJSON(AgentSettings.removing(from: cursor, executable: executable)) == sortedJSON(["version": 1])
        )
        // Hooks of the earlier version's command count as this tool's.
        let earlier: [String: Any] = [
            "version": 1,
            "hooks": ["stop": [["command": "'/Users/someone/.local/bin/agentic-debugging' hook cursor stop"]]],
        ]
        #expect(AgentSettings.containsHooks(in: earlier, executable: executable))
        let others: [String: Any] = ["version": 1, "hooks": ["stop": [["command": "/usr/local/bin/other-tool"]]]]
        #expect(!AgentSettings.containsHooks(in: others, executable: executable))
        // Read from the file: none when it doesn't exist, and a broken file throws.
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "hooks.json")
        #expect(try !AgentSettings.containsHooks(inFile: file, executable: executable))
        try JSONSerialization.data(withJSONObject: cursor).write(to: file)
        #expect(try AgentSettings.containsHooks(inFile: file, executable: executable))
        try Data("[]".utf8).write(to: file)
        #expect(throws: (any Error).self) { try AgentSettings.containsHooks(inFile: file, executable: executable) }
    }

    @Test func settingsFollowTheHomeFolderInHOME() {
        #expect(AgentSettings.homeDirectory(in: ["HOME": "/tmp/sandbox"]).path == "/tmp/sandbox")
        #expect(AgentSettings.homeDirectory(in: [:]) == FileManager.default.homeDirectoryForCurrentUser)
        // An empty or relative HOME would mean the current folder, so it doesn't count.
        #expect(AgentSettings.homeDirectory(in: ["HOME": ""]) == FileManager.default.homeDirectoryForCurrentUser)
        #expect(
            AgentSettings.homeDirectory(in: ["HOME": "sandbox"]) == FileManager.default.homeDirectoryForCurrentUser
        )
    }

    @Test func eachAgentGetsItsOwnShape() throws {
        // Claude Code chats are found from their own records: no hooks, and the file is left as it was.
        #expect(
            try sortedJSON(AgentSettings.adding(.claude, to: ["model": "opus"], executable: executable))
                == sortedJSON(["model": "opus"])
        )
    }
}
#endif
