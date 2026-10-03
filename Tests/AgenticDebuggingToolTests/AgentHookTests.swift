#if os(macOS)
import Foundation
import Testing
@testable import AgenticDebuggingTool

struct AgentHookTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: "AgentHookTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    private var paths: HubPaths { HubPaths(root: root.appending(path: "hub-root", directoryHint: .isDirectory)) }
    private let executable = "/Users/someone/.local/bin/agentic-debugging"

    /// Codex's hooks.json as it was on the Mac this was built on: another tool's hooks.
    private let codexSettings: [String: Any] = [
        "hooks": [
            "PostToolUse": [["matcher": "Edit|Write|apply_patch", "hooks": [["type": "command", "command": "node hook.mjs", "timeout": 5]]]],
            "Stop": [["hooks": [["type": "command", "command": "node hook.mjs", "timeout": 30, "statusMessage": "Design deep pass"]]]],
        ],
    ]

    private func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    private func commands(_ settings: [String: Any], _ event: String) -> [String] {
        let entries = (settings["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
        return entries.flatMap { entry in
            (entry["hooks"] as? [[String: Any]]).map { $0.compactMap { $0["command"] as? String } } ?? [entry["command"] as? String].compactMap { $0 }
        }
    }

    @Test func setupKeepsOtherHooksAndRemovesCleanly() {
        let added = AgentSettings.adding(.codex, to: codexSettings, executable: executable)
        #expect(commands(added, "Stop") == ["node hook.mjs", "'\(executable)' hook codex stop"])
        #expect(commands(added, "PostToolUse") == ["node hook.mjs"])
        #expect(commands(added, "SessionStart") == ["'\(executable)' hook codex start"])
        #expect(commands(added, "UserPromptSubmit") == ["'\(executable)' hook codex prompt"])
        #expect(commands(added, "SessionEnd") == ["'\(executable)' hook codex end"])
        // Run again, nothing changes.
        #expect(json(AgentSettings.adding(.codex, to: added, executable: executable)) == json(added))
        // Removed, the file is as it was.
        #expect(json(AgentSettings.removing(.codex, from: added, executable: executable)) == json(codexSettings))
    }

    @Test func eachAgentGetsItsOwnShape() {
        let claude = AgentSettings.adding(.claude, to: ["model": "opus"], executable: executable)
        #expect(claude["model"] as? String == "opus")
        #expect(commands(claude, "SessionStart") == ["'\(executable)' hook claude start", "'\(executable)' hook claude wait"])
        let wait = ((((claude["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])?.first?["hooks"]) as? [[String: Any]])?.first
        #expect(wait?["asyncRewake"] as? Bool == true)

        let cursor = AgentSettings.adding(.cursor, to: [:], executable: executable)
        #expect(cursor["version"] as? Int == 1)
        let stop = ((cursor["hooks"] as? [String: Any])?["stop"] as? [[String: Any]])?.first
        #expect(stop?["command"] as? String == "'\(executable)' hook cursor stop")
        #expect(stop?["loop_limit"] is NSNull)
        #expect(stop?["timeout"] as? Int == Int(AgentHooks.holdOpen) + 60)
        #expect(json(AgentSettings.removing(.cursor, from: cursor, executable: executable)) == json(["version": 1]))
    }

    @Test func hooksFindTheChatInEachAgentsInput() {
        let claude = HookInput(.claude, json: Data(#"{"session_id":"s1","cwd":"/p","hook_event_name":"Stop"}"#.utf8))
        #expect(claude == HookInput(.codex, json: Data(#"{"session_id":"s1","cwd":"/p"}"#.utf8)))
        #expect(claude?.chat == "s1")
        let cursor = HookInput(.cursor, json: Data(#"{"conversation_id":"c1","workspace_roots":["/w"],"status":"completed"}"#.utf8))
        #expect(cursor?.chat == "c1")
        #expect(cursor?.folder == "/w")
        #expect(HookInput(.claude, json: Data("not json".utf8)) == nil)
    }

    @Test func eachAgentReadsTheReportWhereItLooks() {
        #expect(json(AgentHooks.output(.claude, .prompt, "r")!) == json(["hookSpecificOutput": ["hookEventName": "UserPromptSubmit", "additionalContext": "r"]]))
        #expect(json(AgentHooks.output(.codex, .stop, "r")!) == json(["decision": "block", "reason": "r"]))
        #expect(json(AgentHooks.output(.cursor, .stop, "r")!) == json(["followup_message": "r"]))
        #expect(json(AgentHooks.output(.cursor, .start, "r")!) == json(["additional_context": "r"]))
        // Nothing to say, nothing printed; except Cursor's prompt hook, which must let the prompt through.
        #expect(AgentHooks.output(.codex, .stop, nil) == nil)
        #expect(json(AgentHooks.output(.cursor, .prompt, nil)!) == json(["continue": true]))
    }

    @Test func anotherHookKeepsTheChatsWaiter() throws {
        let folder = root.appending(path: "App", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let waiting = ChatSession(paths: paths, folder: folder, extraApps: ["com.example.app"], agent: "claude", id: "claude-s1", startsHub: false)
        waiting.registerWaiting()
        // A prompt hook, in another process, saves the same chat without a waiter of its own.
        let prompt = ChatSession(paths: paths, folder: folder, extraApps: ["com.example.app"], agent: "claude", id: "claude-s1", startsHub: false)
        prompt.touch()
        let saved = try #require(Chats.record("claude-s1", paths: paths))
        #expect(saved.waiter == getpid())
        #expect(saved.isWaiting)
        // A waiter that's gone doesn't count.
        var gone = saved
        gone.waiter = Int32.max
        #expect(!gone.isWaiting)
    }

    @Test func onlyOneProcessWaitsForAChat() {
        let first = WaitLock(chat: "claude-s1", paths: paths)
        #expect(first != nil)
        #expect(WaitLock(chat: "claude-s1", paths: paths) == nil)
        #expect(WaitLock(chat: "claude-s2", paths: paths) != nil)
        withExtendedLifetime(first) {}
    }

    @Test func aHookChatGetsTheReportAsTextWithPicturePaths() throws {
        let folder = root.appending(path: "App", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let chat = ChatSession(paths: paths, folder: folder, extraApps: ["com.example.app"], agent: "codex", id: "codex-s1", startsHub: false)
        #expect(chat.takeText() == nil)

        let report = paths.inbox.appending(path: "com.example.app/20261004-120000-0CF3C01C", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: report, withIntermediateDirectories: true)
        try "1. **Save**: Too small.\n".write(to: report.appending(path: "report.md"), atomically: true, encoding: .utf8)
        try #"{"screens":[{"images":[{"file":"screen-1.jpg"}]}],"items":[]}"#.write(to: report.appending(path: "report.json"), atomically: true, encoding: .utf8)
        try Data([0xFF]).write(to: report.appending(path: "screen-1.jpg"))
        let source = ReportSource(kind: .phone, device: "D", deviceName: "Mark iPhone", bundleID: "com.example.app", reportID: "20261004-120000", receivedAt: Date())
        try Chats.coder.encode(source).write(to: report.appending(path: "source.json"))

        let text = try #require(chat.takeText())
        #expect(text.contains("**Save**: Too small."))
        #expect(text.contains(report.appending(path: "screen-1.jpg").path))
        // Taken: it doesn't come again, here or in another chat.
        #expect(chat.takeText() == nil)
    }
}
#endif
