#if os(macOS)
import Foundation
import Testing
@testable import RedlineTool

struct HandoffTests {
    private let temporary = TemporaryFolder("HandoffTests")
    private var root: URL { temporary.url }
    private var paths: HubPaths { HubPaths(root: root.appending(path: "hub-root", directoryHint: .isDirectory)) }

    @Test func aTerminalChatStartsWithTheReportWhateverTheFolderIsCalled() async throws {
        let folder = root.appending(path: "Someone's worktree", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lastFile = folder.appending(path: "last.txt")
        try "A report: it's \"broken\" $HOME".write(to: lastFile, atomically: true, encoding: .utf8)
        // Run with printf in place of the agent, to see exactly what it would get.
        let script = Handoff.terminalScript(
            folder: folder.path,
            command: "/usr/bin/printf",
            arguments: ["%s|%s", "resume"],
            lastFile: lastFile.path
        )
        let file = root.appending(path: "run.command")
        try script.write(to: file, atomically: true, encoding: .utf8)
        #expect(try await runProcess("/bin/zsh", [file.path]) == "resume|A report: it's \"broken\" $HOME")
        // The script and the argument's file are gone once it runs.
        #expect(!FileManager.default.fileExists(atPath: lastFile.path))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aNewCodexChatWaitsUntilTheAppCanStartItsTurn() {
        var starts = 0
        var opens = 0
        var waits = 0
        let outcome = Handoff.startCodexTurnWhenOpen(
            startTurn: {
                starts += 1
                return starts < 4 ? .notOpen : .started
            },
            openChat: { opens += 1 },
            wait: { waits += 1 }
        )
        #expect(outcome == .started)
        #expect(starts == 4)
        #expect(opens == 1)
        #expect(waits == 3)
    }

    @Test func aCodexAppThatIsNotRunningOpensBeforeItReceivesTheReport() {
        let outcomes: [CodexApp.Outcome] = [.notRunning, .notRunning, .notOpen, .started]
        var starts = 0
        var opens = 0
        let outcome = Handoff.startCodexTurnWhenOpen(
            startTurn: {
                defer { starts += 1 }
                return outcomes[starts]
            },
            openChat: { opens += 1 },
            wait: {}
        )
        #expect(outcome == .started)
        #expect(starts == 4)
        #expect(opens == 1)
    }

    @Test func aCodexTurnThatMayHaveStartedIsNeverSentAgain() {
        for terminalOutcome in [CodexApp.Outcome.started, .failed("The Codex app didn't answer")] {
            var starts = 0
            let outcome = Handoff.startCodexTurnWhenOpen(
                startTurn: {
                    starts += 1
                    return terminalOutcome
                },
                openChat: { Issue.record("A handled chat must not be opened again") },
                wait: { Issue.record("A handled chat must not be retried") }
            )
            #expect(outcome == terminalOutcome)
            #expect(starts == 1)
        }
        var starts = 0
        let outcome = Handoff.startCodexTurnWhenOpen(
            startTurn: {
                starts += 1
                return starts == 1 ? .notOpen : .failed("The Codex app didn't answer")
            },
            openChat: {},
            wait: {}
        )
        #expect(outcome == .failed("The Codex app didn't answer"))
        #expect(starts == 2)
    }

    @Test func aCodexChatThatNeverOpensStopsWaiting() {
        var starts = 0
        var waits = 0
        let outcome = Handoff.startCodexTurnWhenOpen(
            startTurn: {
                starts += 1
                return .notOpen
            },
            openChat: {},
            wait: { waits += 1 }
        )
        #expect(outcome == .notOpen)
        #expect(starts == 31)
        #expect(waits == 30)
    }

    @Test func aCodexChatThatCannotBeOpenedIsNotSentTheReportAgain() {
        var starts = 0
        let outcome = Handoff.startCodexTurnWhenOpen(
            startTurn: {
                starts += 1
                return .notOpen
            },
            openChat: { throw Handoff.OpenError.openFailed },
            wait: { Issue.record("Opening failed, so no retry should wait") }
        )
        #expect(outcome == .failed("Couldn't open the Codex chat: \(Handoff.OpenError.openFailed.localizedDescription)"))
        #expect(starts == 1)
    }

    @Test func chatsOpenInTheirAgentsAppWhenItIsInstalled() {
        #expect(
            Handoff.appLink(
                .claude,
                id: "c28a077b-d80c-4c2b-844e-c544401d77ec",
                isClaudeAppInstalled: true,
                isCodexAppInstalled: false
            )
                == "claude://resume?session=c28a077b-d80c-4c2b-844e-c544401d77ec"
        )
        #expect(
            Handoff.appLink(.codex, id: "01a0e409-5a20", isClaudeAppInstalled: false, isCodexAppInstalled: true)
                == "codex://threads/01a0e409-5a20"
        )
        // Without the app, a terminal resumes the chat instead.
        #expect(Handoff.appLink(.claude, id: "s-1", isClaudeAppInstalled: false, isCodexAppInstalled: true) == nil)
        #expect(Handoff.appLink(.codex, id: "t-1", isClaudeAppInstalled: true, isCodexAppInstalled: false) == nil)
    }
}
#endif
