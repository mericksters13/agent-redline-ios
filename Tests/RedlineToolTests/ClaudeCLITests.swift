#if os(macOS)
import Foundation
import Testing
@testable import RedlineTool

struct ClaudeCLITests {
    private let temporary = TemporaryFolder("ClaudeCLITests")

    /// A stand-in for the claude command, in a folder of its own, running `script` as its shell
    /// script after noting its arguments.
    private func fakeClaude(_ script: String) throws -> URL {
        let folder = temporary.url.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let claude = folder.appending(path: "claude")
        try Data("#!/bin/sh\necho \"$*\" >> \"$0.calls\"\n\(script)\n".utf8).write(to: claude)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        return claude
    }

    /// A claude command that prints `version` and is signed in, or not.
    private func fakeClaude(version: String, isSignedIn: Bool) throws -> URL {
        try fakeClaude(
            """
            case "$1" in
            --version) echo "\(version) (Claude Code)" ;;
            auth) exit \(isSignedIn ? 0 : 1) ;;
            *) exit 2 ;;
            esac
            """
        )
    }

    /// The arguments the fake `claude` ran with, a line each.
    private func calls(of claude: URL) throws -> [String] {
        try String(contentsOf: URL(filePath: claude.path + ".calls"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }

    @Test func aClaudeCommandThatRunsAndIsSignedInIsReady() async throws {
        let claude = try fakeClaude(version: "2.1.300", isSignedIn: true)
        #expect(await offPool { ClaudeCLI.checkReadiness(of: claude, isClaudeAppInstalled: true) } == .ready)
        // Only questions the command answers itself: nothing reaches a chat.
        #expect(try calls(of: claude) == ["--version", "auth status"])
    }

    @Test func aClaudeCommandThatFailsDoesNotRun() async throws {
        let claude = try fakeClaude("exit 1")
        #expect(await offPool { ClaudeCLI.checkReadiness(of: claude, isClaudeAppInstalled: true) } == .doesNotRun)
    }

    @Test func aClaudeCommandRemovedSinceItWasFoundDoesNotRun() async {
        let claude = temporary.url.appending(path: "removed/claude")
        #expect(await offPool { ClaudeCLI.checkReadiness(of: claude, isClaudeAppInstalled: true) } == .doesNotRun)
    }

    @Test func aClaudeCommandThatRunsCanStillNeedUpdatingOrSigningIn() async throws {
        let old = try fakeClaude(version: "2.1.100", isSignedIn: true)
        #expect(await offPool { ClaudeCLI.checkReadiness(of: old, isClaudeAppInstalled: true) } == .needs(.update))
        // Without the Claude app, an old command only opens chats in a terminal, which it can.
        #expect(await offPool { ClaudeCLI.checkReadiness(of: old, isClaudeAppInstalled: false) } == .ready)
        let signedOut = try fakeClaude(version: "2.1.300", isSignedIn: false)
        #expect(
            await offPool { ClaudeCLI.checkReadiness(of: signedOut, isClaudeAppInstalled: true) } == .needs(.signIn)
        )
    }

    @Test func theClaudeCommandIsNewEnoughForTheDesktopApp() {
        #expect(ClaudeCLI.version(in: "2.1.289 (Claude Code)") == [2, 1, 289])
        #expect(ClaudeCLI.version(in: "not a version") == nil)
        #expect(![2, 1, 289].lexicographicallyPrecedes(ClaudeCLI.desktopVersion))
        #expect([2, 1, 114].lexicographicallyPrecedes(ClaudeCLI.desktopVersion))
    }

    @Test func setupListsWhatTheClaudeCommandStillNeeds() {
        let current = [2, 1, 289]
        let old = [2, 1, 200]
        #expect(
            ClaudeCLI.needs(isInstalled: false, version: [], isSignedIn: false, isClaudeAppInstalled: true) == [
                .install
            ]
        )
        #expect(
            ClaudeCLI.needs(isInstalled: true, version: current, isSignedIn: true, isClaudeAppInstalled: true).isEmpty
        )
        #expect(
            ClaudeCLI.needs(isInstalled: true, version: current, isSignedIn: false, isClaudeAppInstalled: true)
                == [.signIn]
        )
        #expect(
            ClaudeCLI.needs(isInstalled: true, version: old, isSignedIn: false, isClaudeAppInstalled: true)
                == [.update, .signIn]
        )
        // An old claude command is fine without the Claude app: it only opens chats in a terminal.
        #expect(ClaudeCLI.needs(isInstalled: true, version: old, isSignedIn: true, isClaudeAppInstalled: false).isEmpty)
        // Each need comes with the command to run.
        #expect(ClaudeCLI.instruction(for: .install).hasSuffix("curl -fsSL https://claude.ai/install.sh | bash"))
        #expect(ClaudeCLI.instruction(for: .update).hasSuffix("claude update"))
        #expect(ClaudeCLI.instruction(for: .signIn).hasSuffix("claude auth login"))
    }
}
#endif
