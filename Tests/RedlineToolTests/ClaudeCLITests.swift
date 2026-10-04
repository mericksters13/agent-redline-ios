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
}
#endif
