#if os(macOS)
import Foundation
import Testing
@testable import RedlineTool

struct ClaudeCLITests {
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
