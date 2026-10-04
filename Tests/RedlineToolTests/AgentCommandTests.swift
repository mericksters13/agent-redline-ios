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
            AgentCommand.arguments(.codex, folder: "/w", prompt: "p", pictures: [URL(filePath: "/a.jpg")]).suffix(4)
                == ["-i", "/a.jpg", "--", "p"]
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
}
#endif
