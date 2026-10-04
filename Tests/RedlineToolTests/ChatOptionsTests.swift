#if os(macOS)
import Foundation
import Testing
@testable import RedlineTool

struct ChatOptionsTests {
    @Test func flagsAreReadAndUnknownOnesTurnedDown() throws {
        let options = try #require(
            ChatOptions.parse([
                "--project", "/w", "--app", "com.example.app", "--app", "com.example.other",
                "--timeout", "30", "--session", "s-1", "--agent", "codex",
            ])
        )
        #expect(options.project.path == "/w")
        #expect(options.apps == ["com.example.app", "com.example.other"])
        #expect(options.timeout == 30)
        #expect(options.session == "s-1")
        #expect(options.agent == "codex")
        #expect(ChatOptions.parse(["--verbose"]) == nil)
        // A flag without its value.
        #expect(ChatOptions.parse(["--app"]) == nil)
        #expect(ChatOptions.parse([])?.apps == [])
    }
}
#endif
