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
        #expect(commands(added, "PostToolUse") == ["node hook.mjs", "'\(executable)' hook codex built"])
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
        // Claude Code chats are reached through their socket: only builds are noted.
        #expect((claude["hooks"] as? [String: Any])?.keys.sorted() == ["PostToolUse"])
        #expect(commands(claude, "PostToolUse") == ["'\(executable)' hook claude built"])
        let group = ((claude["hooks"] as? [String: Any])?["PostToolUse"] as? [[String: Any]])?.first
        #expect(group?["matcher"] as? String == "Bash|mcp__.*")

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

    /// A report in the inbox the way the hub files it, with the build UUIDs the app sends.
    private func inboxReport(_ id: String, bundleID: String = "com.example.app", buildIDs: [String]? = nil, sourceFile: String? = nil,
                             address: Address? = nil) throws -> URL {
        let incoming = paths.inbox.appending(path: "\(bundleID)/.incoming-\(id)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        try "1. **Save**: Too small.\n".write(to: incoming.appending(path: "report.md"), atomically: true, encoding: .utf8)
        let app: [String: Any] = ["buildIDs": buildIDs as Any, "sourceFile": sourceFile as Any].compactMapValues { $0 is NSNull ? nil : $0 }
        let listing: [String: Any] = ["app": app, "screens": [["images": [["file": "screen-1.jpg"]]]], "items": []]
        try JSONSerialization.data(withJSONObject: listing).write(to: incoming.appending(path: "report.json"))
        try Data([0xFF]).write(to: incoming.appending(path: "screen-1.jpg"))
        let source = ReportSource(kind: .phone, device: "D", deviceName: "Mark iPhone", bundleID: bundleID, reportID: id, receivedAt: Date())
        try Chats.coder.encode(source).write(to: incoming.appending(path: "source.json"))
        if let address { InboxQueue.setAddress(address, of: incoming) }
        let final = paths.inbox.appending(path: "\(bundleID)/\(id)", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: incoming, to: final)
        return final
    }

    /// A derived data folder with one built app, as Xcode leaves it.
    private func derivedData(project: URL, executable: URL) throws -> URL {
        let root = root.appending(path: "DerivedData/App-abc", directoryHint: .isDirectory)
        let app = root.appending(path: "Build/Products/Debug-iphoneos/App.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try (["WorkspacePath": project.appending(path: "App.xcodeproj").path] as NSDictionary).write(to: root.appending(path: "info.plist"))
        try (["CFBundleIdentifier": "com.example.app", "CFBundleExecutable": "App"] as NSDictionary).write(to: app.appending(path: "Info.plist"))
        try FileManager.default.copyItem(at: executable, to: app.appending(path: "App"))
        // Just built.
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: app.appending(path: "App").path)
        return root
    }

    @Test func buildUUIDsMatchWhatXcodeToolsRead() throws {
        let binary = URL(fileURLWithPath: "/usr/bin/true")
        let dwarfdump = Process()
        dwarfdump.executableURL = URL(fileURLWithPath: "/usr/bin/dwarfdump")
        dwarfdump.arguments = ["--uuid", binary.path]
        let pipe = Pipe()
        dwarfdump.standardOutput = pipe
        try dwarfdump.run()
        dwarfdump.waitUntilExit()
        let expected = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").compactMap { $0.split(separator: " ").dropFirst().first.map(String.init) }
        #expect(!expected.isEmpty)
        #expect(Builds.machOUUIDs(binary) == expected)
    }

    @Test func aReportGoesToTheChatThatBuiltTheApp() throws {
        let project = root.appending(path: "worktree-a", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: project.appending(path: ".git"), withIntermediateDirectories: true)
        let derived = try derivedData(project: project, executable: URL(fileURLWithPath: "/usr/bin/true"))
        let ids = Builds.machOUUIDs(URL(fileURLWithPath: "/usr/bin/true"))

        // The chat's hook runs after its build command.
        let recorded = Builds.record(chat: "codex-A", agent: "codex", folder: project.appending(path: "App").path, paths: paths,
                                     roots: [derived]) { ["com.example.app"] }
        let build = try #require(recorded.first)
        #expect(recorded.count == 1)
        #expect(build.folder == project.standardizedFileURL.path)
        // Another chat's next command doesn't take the credit, even a build command elsewhere.
        #expect(Builds.record(chat: "claude-B", agent: "claude", folder: project.path, paths: paths, roots: [derived]) { ["com.example.app"] }.isEmpty)
        #expect(Builds.record(chat: "claude-B", agent: "claude", folder: "/elsewhere", paths: paths, roots: [derived], anyFolder: true) { [] }.isEmpty)
        // A build command in a chat working elsewhere counts for the build it just made.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)],
                                              ofItemAtPath: derived.appending(path: "Build/Products/Debug-iphoneos/App.app/App").path)
        #expect(Builds.record(chat: "claude-C", agent: "claude", folder: "/elsewhere", paths: paths, roots: [derived], now: Date().addingTimeInterval(6)) { [] }.isEmpty)
        let elsewhere = Builds.record(chat: "claude-C", agent: "claude", folder: "/elsewhere", paths: paths, roots: [derived],
                                      now: Date().addingTimeInterval(6), anyFolder: true) { [] }
        #expect(elsewhere.first?.folder == project.standardizedFileURL.path)
        #expect(HookInput(.claude, json: Data(#"{"session_id":"s","cwd":"/p","tool_name":"Bash","tool_input":{"command":"cd x && xcodebuild -scheme App build"}}"#.utf8))?.ranABuild == true)
        #expect(HookInput(.codex, json: Data(#"{"session_id":"s","cwd":"/p","tool_name":"mcp__XcodeBuildMCP__build_sim"}"#.utf8))?.ranABuild == true)
        #expect(HookInput(.claude, json: Data(#"{"session_id":"s","cwd":"/p","tool_name":"Bash","tool_input":{"command":"ls"}}"#.utf8))?.ranABuild == false)

        let incoming = root.appending(path: "incoming", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["app": ["buildIDs": [try #require(ids.first)]]]).write(to: incoming.appending(path: "report.json"))
        // The newest build with the UUID wins: the one on the device.
        #expect(Routing.destination(of: incoming, bundleID: "com.example.app", paths: paths) == .chat(try #require(elsewhere.first)))
        _ = build

        // A build no chat made: a new chat in the folder it was built from.
        try JSONSerialization.data(withJSONObject: ["app": ["buildIDs": ["00000000-0000-0000-0000-000000000000"],
                                                            "sourceFile": project.appending(path: "App/AppMain.swift").path]])
            .write(to: incoming.appending(path: "report.json"))
        #expect(Routing.destination(of: incoming, bundleID: "com.example.app", paths: paths, roots: []) == .newChat(.claude, folder: project.standardizedFileURL.path))
        // An app with an older kit says nothing about its build.
        try JSONSerialization.data(withJSONObject: ["app": [String: Any]()]).write(to: incoming.appending(path: "report.json"))
        #expect(Routing.destination(of: incoming, bundleID: "com.example.app", paths: paths, roots: []) == .unknown)
    }

    @Test func onlyTheAddressedChatTakesAReport() throws {
        let folder = root.appending(path: "App", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let builder = ChatSession(paths: paths, folder: folder, extraApps: ["com.example.app"], agent: "codex", id: "codex-A", startsHub: false)
        let other = ChatSession(paths: paths, folder: folder, extraApps: ["com.example.app"], agent: "codex", id: "codex-B", startsHub: false)
        let report = try inboxReport("20261004-120000", address: Address(chat: "codex-A", agent: "codex", folder: folder.path))
        _ = try inboxReport("20261004-120100")

        // Another chat on the same app gets nothing, and an unaddressed report goes to no one.
        #expect(other.takeAddressed() == nil)
        let text = try #require(builder.takeAddressed())
        #expect(text.contains("**Save**: Too small."))
        #expect(text.contains(report.appending(path: "screen-1.jpg").path))
        #expect(builder.takeAddressed() == nil)
    }
}
#endif
