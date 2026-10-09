#if os(macOS)
import Foundation
import Testing
@testable import RedlineTool

struct AgentCommandTests {
    @Test func theStartedChatIsReadFromEachCommandLine() {
        let codex = #"{"type":"thread.started","thread_id":"t-9"}"# + "\n" + #"{"type":"item.completed"}"#
        #expect(AgentCommand.startedChat(.codex, in: codex)?.chat == "t-9")
        let claude = #"{"type":"result","subtype":"success","result":"The button is too small.","session_id":"s-9"}"#
        #expect(AgentCommand.startedChat(.claude, in: claude)?.chat == "s-9")
        #expect(AgentCommand.startedChat(.claude, in: claude)?.answer == "The button is too small.")
        #expect(AgentCommand.startedChat(.claude, in: "Not logged in · Please run /login") == nil)
        // Claude Code prints a result even when it couldn't run: that's a failure, in its own words.
        let notSignedIn =
            #"{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login","session_id":"s-1"}"#
        #expect(AgentCommand.startedChat(.claude, in: notSignedIn)?.didFail == true)
        #expect(AgentCommand.failure(in: notSignedIn) == "Not logged in · Please run /login")
        #expect(AgentCommand.arguments(.claude, folder: "/w", prompt: "p").contains("plan"))
        #expect(
            AgentCommand.arguments(.codex, folder: "/w", prompt: "p", snapshots: [URL(filePath: "/a.jpg")]).suffix(4)
                == ["-i", "/a.jpg", "--", "p"]
        )
    }

    @Test func aCodexDesktopStartupLeavesTheReportForTheApp() {
        let snapshot = URL(filePath: "/tmp/report.jpg")
        let arguments = AgentCommand.arguments(
            .codex,
            folder: "/worktree",
            prompt: "Investigate the broken button",
            snapshots: [snapshot],
            isCodexAppInstalled: true
        )
        #expect(arguments.prefix(3) == ["exec", "-C", "/worktree"])
        #expect(arguments.contains("read-only"))
        #expect(!arguments.contains("-i"))
        #expect(!arguments.contains(snapshot.path))
        #expect(!arguments.contains("Investigate the broken button"))
        #expect(arguments.last?.contains("Do not inspect files or use tools") == true)
        #expect(arguments.last?.contains("Reply with just: Ready.") == true)
    }

    @Test func aCodexStartupWithoutTheAppStillReceivesTheReport() {
        let arguments = AgentCommand.arguments(
            .codex,
            folder: "/worktree",
            prompt: "Investigate the broken button",
            snapshots: [URL(filePath: "/tmp/report.jpg")],
            isCodexAppInstalled: false
        )
        #expect(arguments.suffix(4) == ["-i", "/tmp/report.jpg", "--", "Investigate the broken button"])
        #expect(arguments.contains("read-only"))
        #expect(
            AgentCommand.arguments(.claude, folder: "/worktree", prompt: "Ready", isCodexAppInstalled: true)
                == ["-p", "Ready", "--permission-mode", "plan", "--output-format", "json"]
        )
    }

    @Test func theClaudeCommandIsFoundInTheHomeFolderFromHOME() throws {
        let home = TemporaryFolder("agent-command-home")
        let bin = home.url.appending(path: ".local/bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let claude = bin.appending(path: "claude")
        try Data("#!/bin/sh\n".utf8).write(to: claude)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        #expect(AgentCommand.locate(.claude, environment: ["HOME": home.url.path])?.path == claude.path)
    }

    @Test func theClaudeCommandOnPATHComesFirst() throws {
        let folder = TemporaryFolder("agent-command-path")
        let bin = folder.url.appending(path: "nvm/bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let claude = bin.appending(path: "claude")
        try Data("#!/bin/sh\n".utf8).write(to: claude)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        // A relative folder on PATH is skipped.
        let environment = ["HOME": folder.url.path, "PATH": "relative/bin:\(bin.path):/usr/bin"]
        #expect(AgentCommand.locate(.claude, environment: environment)?.path == claude.path)
    }
}
#endif
