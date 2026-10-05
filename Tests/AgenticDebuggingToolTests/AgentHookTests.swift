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
        // Codex chats are woken through the Codex app: no stop hook holds them open.
        #expect(commands(added, "Stop") == ["node hook.mjs"])
        #expect(commands(added, "PostToolUse") == ["node hook.mjs"])
        // One hook for Codex: the safety net for a report the Codex app didn't take.
        #expect(commands(added, "UserPromptSubmit") == ["'\(executable)' hook codex prompt"])
        #expect((added["hooks"] as? [String: Any])?.keys.sorted() == ["PostToolUse", "Stop", "UserPromptSubmit"])
        // Run again, nothing changes.
        #expect(json(AgentSettings.adding(.codex, to: added, executable: executable)) == json(added))
        // Removed, the file is as it was.
        #expect(json(AgentSettings.removing(.codex, from: added, executable: executable)) == json(codexSettings))
    }

    @Test func hooksFromAnEarlierInstallAreReplacedAndRemoved() {
        let moved = AgentSettings.adding(.codex, to: codexSettings, executable: "/Users/someone/Downloads/it's here/agentic-debugging")
        var settings = moved
        // Another tool's command that also runs `hook` stays.
        var events = settings["hooks"] as? [String: Any] ?? [:]
        events["SessionStart"] = [["hooks": [["type": "command", "command": "'/usr/local/bin/other-tool' hook codex start"]]]]
        settings["hooks"] = events
        let added = AgentSettings.adding(.codex, to: settings, executable: executable)
        #expect(commands(added, "UserPromptSubmit") == ["'\(executable)' hook codex prompt"])
        #expect(commands(added, "SessionStart") == ["'/usr/local/bin/other-tool' hook codex start"])
        let removed = AgentSettings.removing(.codex, from: moved, executable: executable)
        #expect(json(removed) == json(codexSettings))
    }

    @Test func eachAgentGetsItsOwnShape() {
        // Claude Code chats are found from their own records: no hooks, and the file is left as it was.
        #expect(json(AgentSettings.adding(.claude, to: ["model": "opus"], executable: executable)) == json(["model": "opus"]))

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
        // In a window with several folders, the one holding the chat's working folder comes first.
        let roots = HookInput(.cursor, json: Data(#"{"conversation_id":"c1","workspace_roots":["/docs","/w","/w/App"],"cwd":"/w/App/Sources"}"#.utf8))
        #expect(roots?.folders == ["/w/App", "/docs", "/w"])
        let noCwd = HookInput(.cursor, json: Data(#"{"conversation_id":"c1","workspace_roots":["/docs","/w"]}"#.utf8))
        #expect(noCwd?.folders == ["/docs", "/w"])
        #expect(HookInput(.cursor, json: Data(#"{"conversation_id":"c1","cwd":"/w"}"#.utf8))?.folders == ["/w"])
        #expect(HookInput(.claude, json: Data("not json".utf8)) == nil)
    }

    @Test func aChatWithSeveralFoldersTakesReportsFromEachFoldersApp() throws {
        let docs = root.appending(path: "docs", directoryHint: .isDirectory)
        let first = root.appending(path: "first", directoryHint: .isDirectory)
        let second = root.appending(path: "second", directoryHint: .isDirectory)
        for folder in [docs, first, second] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try "targets:\n  A:\n    settings:\n      PRODUCT_BUNDLE_IDENTIFIER: com.example.first\n"
            .write(to: first.appending(path: "project.yml"), atomically: true, encoding: .utf8)
        try "targets:\n  B:\n    settings:\n      PRODUCT_BUNDLE_IDENTIFIER: com.example.second\n"
            .write(to: second.appending(path: "project.yml"), atomically: true, encoding: .utf8)
        let roots = [docs, first, second].map(\.path)
        let json = try JSONSerialization.data(withJSONObject: ["conversation_id": "c1", "workspace_roots": roots])
        let input = try #require(HookInput(.cursor, json: json))
        let session = try #require(AgentHooks.session(for: input, agent: .cursor, id: "cursor-c1", pid: nil, paths: paths, startsHub: false))
        // The chat works in the first folder that builds an app, and takes both apps' reports.
        #expect(session.chat.folder == first.path)
        #expect(session.chat.bundleIDs == ["com.example.first", "com.example.second"])
        let none = try #require(HookInput(.cursor, json: try JSONSerialization.data(withJSONObject: ["conversation_id": "c2", "workspace_roots": [docs.path]])))
        #expect(AgentHooks.session(for: none, agent: .cursor, id: "cursor-c2", pid: nil, paths: paths, startsHub: false) == nil)
    }

    @Test func aRestartedHubReplaysPromisedReportsHoweverOld() throws {
        let old = Date().addingTimeInterval(-86_400)
        let source = ReportSource(kind: .phone, device: "D", deviceName: "Mark iPhone", bundleID: "com.example.app", reportID: "r", receivedAt: old)
        func waiting(_ folder: URL, claim: Claim? = nil) -> InboxReport { InboxReport(folder: folder, source: source, claim: claim) }
        // Sent nowhere: only while recent, since a chat started for it a day later would surprise.
        let unpicked = try report(sourceFile: "/w/App.swift", pick: nil)
        #expect(!Handoff.replays(waiting(unpicked), within: 3600))
        #expect(Handoff.replays(waiting(unpicked), within: 3600, now: old.addingTimeInterval(60)))
        // Picked on the phone, or cut off mid hand-over: however old.
        #expect(Handoff.replays(waiting(try report(sourceFile: "/w/App.swift", pick: ["agent": "cursor", "chat": "c1"])), within: 3600))
        let cutOff = Claim(chat: "claude-s1", agent: "claude", folder: "/w", claimedAt: old, handingOverIn: Int32.max)
        #expect(Handoff.replays(waiting(unpicked, claim: cutOff), within: 3600))
        // Addressed to a chat: its hooks take it.
        let addressed = try report(sourceFile: "/w/App.swift", pick: ["agent": "cursor", "chat": "c1"])
        InboxQueue.setAddress(Address(chat: "cursor-c1", agent: "cursor", folder: "/w"), of: addressed)
        #expect(!Handoff.replays(waiting(addressed), within: 3600))
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
        let item: [String: Any] = ["number": 1, "title": "Save", "note": "Too small.", "attachments": [String](),
                                   "element": ["identifier": "editor.save", "label": "Save", "role": "Button"]]
        let listing: [String: Any] = ["app": app.merging(["name": "Example"]) { $1 }, "screens": [["images": [["file": "screen-1.jpg", "notes": [1]]]]],
                                      "items": [item]]
        try JSONSerialization.data(withJSONObject: listing).write(to: incoming.appending(path: "report.json"))
        try Data([0xFF]).write(to: incoming.appending(path: "screen-1.jpg"))
        let source = ReportSource(kind: .phone, device: "D", deviceName: "Mark iPhone", bundleID: bundleID, reportID: id, receivedAt: Date())
        try Chats.coder.encode(source).write(to: incoming.appending(path: "source.json"))
        if let address { InboxQueue.setAddress(address, of: incoming) }
        let final = paths.inbox.appending(path: "\(bundleID)/\(id)", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: incoming, to: final)
        return final
    }

    /// A report folder with what the phone saved: the worktree's file and the user's pick.
    private func report(sourceFile: String?, pick: [String: Any]?) throws -> URL {
        let folder = root.appending(path: "report-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var listing: [String: Any] = ["app": sourceFile.map { ["sourceFile": $0] } ?? [String: Any]()]
        if let pick { listing["destination"] = pick }
        try JSONSerialization.data(withJSONObject: listing).write(to: folder.appending(path: "report.json"))
        return folder
    }

    private func chat(_ id: String, _ agent: String, sameWorktree: Bool) -> HubMessage.Chat {
        HubMessage.Chat(id: id, agent: agent, title: id, folder: "wt", sameWorktree: sameWorktree, lastActive: Date())
    }

    @Test func aReportGoesWhereThePhonePickedOrElseToItsWorktreesChat() throws {
        let worktree = root.appending(path: "worktree-a", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: worktree.appending(path: ".git"), withIntermediateDirectories: true)
        try "targets:\n  App:\n    settings:\n      PRODUCT_BUNDLE_IDENTIFIER: com.example.app\n"
            .write(to: worktree.appending(path: "project.yml"), atomically: true, encoding: .utf8)
        let file = worktree.appending(path: "App/AppMain.swift").path
        let folder = worktree.standardizedFileURL.path
        func route(_ report: URL, _ chats: [HubMessage.Chat]) -> Destination {
            Routing.destination(of: report, bundleID: "com.example.app", paths: paths) { _, _ in
                HubMessage.ChatList(agents: ["claude", "codex"], chats: chats)
            }
        }
        let others = [chat("A", "claude", sameWorktree: true), chat("B", "codex", sameWorktree: false)]

        // The user's pick wins, even over the chat in the worktree.
        #expect(route(try report(sourceFile: file, pick: ["agent": "codex", "chat": "B"]), others) == .chat(.codex, id: "B"))
        #expect(route(try report(sourceFile: file, pick: ["agent": "codex"]), others) == .newChat(.codex, folder: folder, pick: nil))
        #expect(route(try report(sourceFile: file, pick: ["agent": "claude", "newChat": "N1"]), others) == .newChat(.claude, folder: folder, pick: "N1"))
        // No pick: the one chat in the worktree, or a new chat there with the first agent.
        #expect(route(try report(sourceFile: file, pick: nil), others) == .chat(.claude, id: "A"))
        #expect(route(try report(sourceFile: file, pick: nil), [chat("B", "codex", sameWorktree: false)]) == .newChat(.claude, folder: folder, pick: nil))
        // Only an agent that can start a chat is given a new one.
        let cursorFirst = Routing.destination(of: try report(sourceFile: file, pick: nil), bundleID: "com.example.app", paths: paths) { _, _ in
            HubMessage.ChatList(agents: ["cursor", "codex"], chats: [], newChats: ["codex"])
        }
        #expect(cursorFirst == .newChat(.codex, folder: folder, pick: nil))
        // A new chat starts with the agent last used on the app, while it can start one.
        ProjectHistory.note(ChatRecord(id: "codex-X", agent: "codex", folder: folder, bundleIDs: ["com.example.app"], pid: getpid(),
                                       registeredAt: Date(), lastActiveAt: Date()), paths: paths)
        #expect(route(try report(sourceFile: file, pick: nil), []) == .newChat(.codex, folder: folder, pick: nil))
        let codexGone = Routing.destination(of: try report(sourceFile: file, pick: nil), bundleID: "com.example.app", paths: paths) { _, _ in
            HubMessage.ChatList(agents: ["claude", "codex"], chats: [], newChats: ["claude"])
        }
        #expect(codexGone == .newChat(.claude, folder: folder, pick: nil))
        // Several chats in the worktree and no pick: no guessing.
        if case .undecided = route(try report(sourceFile: file, pick: nil), others + [chat("C", "codex", sameWorktree: true)]) {} else {
            Issue.record("Two chats in the worktree should leave the report undecided")
        }
        if case .undecided = route(try report(sourceFile: nil, pick: nil), others) {} else {
            Issue.record("A report without its worktree should be undecided")
        }
        // The phone writes the report: a folder that doesn't build the app gets no new chat.
        let elsewhere = root.appending(path: "other-project", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: elsewhere.appending(path: ".git"), withIntermediateDirectories: true)
        let foreign = elsewhere.appending(path: "Sources/Main.swift").path
        for pick: [String: Any]? in [["agent": "codex"], ["agent": "claude", "newChat": "N2"], nil] {
            if case .undecided = route(try report(sourceFile: foreign, pick: pick), []) {} else {
                Issue.record("A worktree that doesn't build the app should leave the report undecided")
            }
        }
    }

    @Test func aNewChatGetsItsOwnWorktreeFromMain() throws {
        let repository = root.appending(path: "repo", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        func git(_ arguments: String...) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", repository.path, "-c", "user.name=Test", "-c", "user.email=test@example.com"] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
        }
        try git("init", "-q", "-b", "main")
        try "one\n".write(to: repository.appending(path: "App.swift"), atomically: true, encoding: .utf8)
        try git("add", ".")
        try git("commit", "-q", "-m", "First")
        // The app was built from a feature branch, with a change not committed yet.
        try git("checkout", "-q", "-b", "feature")
        try "one\ntwo\n".write(to: repository.appending(path: "App.swift"), atomically: true, encoding: .utf8)
        try git("commit", "-q", "-am", "Second")
        try "one\ntwo\nthree\n".write(to: repository.appending(path: "App.swift"), atomically: true, encoding: .utf8)
        #expect(NewWorktree.mainBranch(of: repository.path)?.name == "main")

        // The new chat's worktree starts from main.
        let made = try #require(NewWorktree.create(from: repository.path, name: "report-1", agent: .claude))
        #expect(made.hasSuffix("/.claude/worktrees/report-1"))
        let branch = Process()
        branch.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        branch.arguments = ["-C", made, "branch", "--show-current"]
        let pipe = Pipe()
        branch.standardOutput = pipe
        try branch.run()
        branch.waitUntilExit()
        #expect(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "report/1")
        #expect(try String(contentsOfFile: made + "/App.swift", encoding: .utf8) == "one\n")
        // The main checkout shows only its own change, not the folder the worktree is in.
        let mainStatus = Process()
        mainStatus.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        mainStatus.arguments = ["-C", repository.path, "status", "--porcelain"]
        let mainStatusPipe = Pipe()
        mainStatus.standardOutput = mainStatusPipe
        try mainStatus.run()
        mainStatus.waitUntilExit()
        #expect(String(decoding: mainStatusPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == " M App.swift\n")
        // The same name again gets a number rather than failing.
        let again = try #require(NewWorktree.create(from: repository.path, name: "report-1", agent: .claude))
        #expect(again.hasSuffix("/report-1-2"))
        // Its repository is the main checkout, from the worktree too.
        #expect(NewWorktree.repository(of: made) == NewWorktree.repository(of: repository.path))
        #expect(NewWorktree.repository(of: made)?.hasSuffix("/repo") == true)

        // A report copied into the worktree is ignored by git there.
        let report = root.appending(path: "inbox-report", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: report, withIntermediateDirectories: true)
        try "# Report".write(to: report.appending(path: "report.md"), atomically: true, encoding: .utf8)
        let copy = try #require(NewWorktree.copyReport(report, into: made))
        #expect(FileManager.default.fileExists(atPath: copy + "/report.md"))
        let status = Process()
        status.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        status.arguments = ["-C", made, "status", "--porcelain"]
        let statusPipe = Pipe()
        status.standardOutput = statusPipe
        try status.run()
        status.waitUntilExit()
        #expect(statusPipe.fileHandleForReading.readDataToEndOfFile().isEmpty)

        // A worktree for a chat that didn't start is taken back, with its branch.
        NewWorktree.remove(again)
        #expect(!FileManager.default.fileExists(atPath: again))
        #expect(NewWorktree.create(from: root.appending(path: "not-a-repo").path, name: "x", agent: .claude) == nil)
        // With no main branch to start from, no worktree is made from the checkout's own branch.
        try git("branch", "-q", "-m", "main", "trunk")
        #expect(NewWorktree.mainBranch(of: repository.path, fetching: true) == nil)
        #expect(NewWorktree.create(from: repository.path, name: "report-2", agent: .claude) == nil)
        try git("branch", "-q", "-m", "trunk", "main")

        // The chat it started is found by the phone's pick while its worktree exists.
        StartedChats.remember(StartedChat(chat: "s-1", folder: made, at: Date()), for: "N1", paths: paths)
        #expect(StartedChats.find("N1", paths: paths)?.chat == "s-1")
        #expect(StartedChats.find("N2", paths: paths) == nil)
        try FileManager.default.removeItem(atPath: made)
        #expect(StartedChats.find("N1", paths: paths) == nil)
        // Chats started for different picks that finish together are all remembered.
        DispatchQueue.concurrentPerform(iterations: 40) { index in
            StartedChats.remember(StartedChat(chat: "s-\(index)", folder: repository.path, at: Date()), for: "P\(index)", paths: paths)
        }
        #expect(StartedChats.all(paths).count == 41)
    }

    @Test func theStartedChatIsReadFromEachCommandLine() {
        let codex = #"{"type":"thread.started","thread_id":"t-9"}"# + "\n" + #"{"type":"item.completed"}"#
        #expect(AgentCommand.startedChat(.codex, in: codex)?.chat == "t-9")
        let claude = #"{"type":"result","subtype":"success","result":"The button is too small.","session_id":"s-9"}"#
        #expect(AgentCommand.startedChat(.claude, in: claude)?.chat == "s-9")
        #expect(AgentCommand.startedChat(.claude, in: claude)?.answer == "The button is too small.")
        #expect(AgentCommand.startedChat(.claude, in: "Not logged in · Please run /login") == nil)
        // Claude Code prints a result even when it couldn't run: that's a failure, in its own words.
        let notSignedIn = #"{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login","session_id":"s-1"}"#
        #expect(AgentCommand.startedChat(.claude, in: notSignedIn)?.failed == true)
        #expect(AgentCommand.failure(in: notSignedIn) == "Not logged in · Please run /login")
        #expect(AgentCommand.arguments(.claude, folder: "/w", prompt: "p", resuming: "s-9").suffix(2) == ["--resume", "s-9"])
        #expect(AgentCommand.arguments(.codex, folder: "/w", prompt: "p", pictures: [URL(fileURLWithPath: "/a.jpg")]).suffix(4) == ["-i", "/a.jpg", "--", "p"])
    }

    @Test func aTerminalChatStartsWithTheReportWhateverTheFolderIsCalled() throws {
        let folder = root.appending(path: "Mark's worktree", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lastFile = folder.appending(path: "last.txt")
        try "A report: it's \"broken\" $HOME".write(to: lastFile, atomically: true, encoding: .utf8)
        // Run with printf in place of the agent, to see exactly what it would get.
        let script = Handoff.terminalScript(folder: folder.path, command: "/usr/bin/printf", arguments: ["%s|%s", "resume"], lastFile: lastFile.path)
        let file = root.appending(path: "run.command")
        try script.write(to: file, atomically: true, encoding: .utf8)
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = [file.path]
        let pipe = Pipe()
        shell.standardOutput = pipe
        try shell.run()
        shell.waitUntilExit()
        #expect(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "resume|A report: it's \"broken\" $HOME")
        // The script and the argument's file are gone once it runs.
        #expect(!FileManager.default.fileExists(atPath: lastFile.path))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func theClaudeCommandIsNewEnoughForTheDesktopApp() {
        #expect(ClaudeCLI.version(in: "2.1.289 (Claude Code)") == [2, 1, 289])
        #expect(ClaudeCLI.version(in: "not a version") == nil)
        #expect(![2, 1, 289].lexicographicallyPrecedes(ClaudeCLI.desktopVersion))
        #expect([2, 1, 114].lexicographicallyPrecedes(ClaudeCLI.desktopVersion))
    }

    @Test func aReportReadsAsPicturesAndTheirNotes() throws {
        let report = paths.inbox.appending(path: "com.example.app/20261004-120950-0CF3C01C", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: report, withIntermediateDirectories: true)
        let listing: [String: Any] = [
            "app": ["name": "Tiny Tally", "version": "1.0.9", "build": "41"],
            "screens": [["images": [["file": "screen-1.jpg", "notes": [1]]]], ["images": [["file": "screen-2.jpg", "notes": [3]]]]],
            "items": [
                ["number": 1, "title": "Log milestone", "note": "This is ugly", "attachments": [String](), "picture": "screen-1.jpg",
                 "element": ["identifier": "today.milestones", "label": "Log milestone", "role": "Button"],
                 "ancestors": [["role": "Group"], ["identifier": "today.card", "label": "Milestones", "role": "Group"]]],
                ["number": 2, "title": "History", "note": "The list breaks", "attachments": ["note-2.jpg"]],
                ["number": 3, "title": "growth.card", "note": "", "attachments": [String](), "element": ["identifier": "growth.card", "role": "Group"]],
                // An element note made before notes on one screen shared its picture keeps its own.
                ["number": 4, "title": "Save", "note": "Too small", "attachments": [String](), "picture": "note-4.jpg",
                 "element": ["label": "Save", "role": "Button"]],
            ],
        ]
        try JSONSerialization.data(withJSONObject: listing).write(to: report.appending(path: "report.json"))
        let source = ReportSource(kind: .phone, device: "D", deviceName: "Mark iPhone", bundleID: "com.example.app", reportID: "20261004-120950", receivedAt: Date())
        let text = ReportContent.text(for: InboxReport(folder: report, source: source, claim: nil))
        #expect(text == """
            UI report from Mark iPhone · Tiny Tally

            \(report.path)/screen-1.jpg
            1. Log milestone (Button, today.milestones), in Group "Milestones" (today.card): This is ugly

            \(report.path)/screen-2.jpg
            3. growth.card (Group): No note

            \(report.path)/note-2.jpg
            2. History: The list breaks

            \(report.path)/note-4.jpg
            4. Save (Button): Too small
            """)
        for file in ["screen-1.jpg", "screen-2.jpg", "note-2.jpg", "note-4.jpg"] {
            FileManager.default.createFile(atPath: report.appending(path: file).path, contents: Data([0xFF]))
        }
        #expect(ReportContent.pictures(in: report).map(\.lastPathComponent) == ["screen-1.jpg", "screen-2.jpg", "note-2.jpg", "note-4.jpg"])

        // A long pasted note is cut, so the text fits in a command's arguments; report.md has the rest.
        var long = listing
        long["items"] = [["number": 1, "title": "Log milestone", "note": String(repeating: "pasted ", count: 20_000), "attachments": [String]()]]
        try JSONSerialization.data(withJSONObject: long).write(to: report.appending(path: "report.json"))
        let cut = ReportContent.text(for: InboxReport(folder: report, source: source, claim: nil))
        #expect(cut.utf8.count <= ReportContent.longestText)
        #expect(cut.hasSuffix("The rest is in \(report.path)/report.md."))
    }

    @Test func codexChatsLeaveOutWhatCodexRunsOnItsOwn() throws {
        let database = root.appending(path: "state_5.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let old = now - 30 * 86_400_000
        let sql = """
            CREATE TABLE threads (id TEXT, name TEXT, title TEXT, first_user_message TEXT, cwd TEXT, updated_at_ms INTEGER,
                                  archived INTEGER, agent_role TEXT, thread_source TEXT, source TEXT);
            INSERT INTO threads VALUES ('t-user', 'Fix the paywall', 'Fix the paywall', 'fix it', '/p', \(now), 0, NULL, 'user', 'vscode');
            INSERT INTO threads VALUES ('t-older', '', '', 'Why is the outline wide', '/p', \(now - 1000), 0, NULL, NULL, 'vscode');
            INSERT INTO threads VALUES ('t-no-source', 'Tidy the list', '', '', '/p', \(now - 2000), 0, NULL, NULL, NULL);
            INSERT INTO threads VALUES ('t-guardian', 'Guardian review', '', '', '/p', \(now), 0, NULL, 'guardian_review', '{"subagent":{"other":"guardian"}}');
            INSERT INTO threads VALUES ('t-auto', 'Nightly', '', '', '/p', \(now), 0, NULL, 'automation', 'vscode');
            INSERT INTO threads VALUES ('t-archived', 'Old', '', '', '/p', \(now), 1, NULL, 'user', 'vscode');
            INSERT INTO threads VALUES ('t-stale', 'Stale', '', '', '/p', \(old), 0, NULL, 'user', 'vscode');
            """
        let sqlite = Process()
        sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        sqlite.arguments = [database.path, sql]
        try sqlite.run()
        sqlite.waitUntilExit()
        let threads = CodexThreads.recent(in: database)
        #expect(threads.map(\.id) == ["t-user", "t-older", "t-no-source"])
        // A chat without a name goes by its first message.
        #expect(threads[1].title == "Why is the outline wide")
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
        let taken = try #require(builder.takeAddressed())
        #expect(taken.text.contains("1. Save (Button, editor.save): Too small."))
        #expect(taken.text.contains(report.appending(path: "screen-1.jpg").path))
        #expect(builder.takeAddressed() == nil)
        // An answer that couldn't be written frees the report for the chat to take again.
        ChatSession.settle(taken.reports, delivered: false)
        #expect(builder.takeAddressed()?.reports.count == 1)
    }

    @Test func aHookAnswerCarriesOnlyWhatFitsAndLeavesTheRestWaiting() throws {
        let folder = root.appending(path: "App", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let chat = ChatSession(paths: paths, folder: folder, extraApps: ["com.example.app"], agent: "codex", id: "codex-A", startsHub: false)
        let address = Address(chat: "codex-A", agent: "codex", folder: folder.path)
        let first = try inboxReport("20261004-120000", address: address)
        let second = try inboxReport("20261004-120100", address: address)
        // Both fit in the usual budget.
        let both = try #require(chat.takeAddressed())
        #expect(both.reports.count == 2)
        ChatSession.settle(both.reports, delivered: false)

        // With room for one, the oldest goes and the next waits for the chat's next hook.
        let budget = ReportContent.text(for: both.reports[0]).utf8.count
        let one = try #require(chat.takeAddressed(budget: budget))
        #expect(one.reports.map(\.folder.lastPathComponent) == [first.lastPathComponent])
        let next = try #require(chat.takeAddressed(budget: budget))
        #expect(next.reports.map(\.folder.lastPathComponent) == [second.lastPathComponent])
        #expect(chat.takeAddressed() == nil)
    }
}
#endif
