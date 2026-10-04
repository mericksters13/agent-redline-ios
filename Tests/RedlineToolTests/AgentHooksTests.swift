#if os(macOS)
import Foundation
import Testing
@testable import RedlineTool

struct AgentHooksTests {
    @Test func hooksFindTheChatInEachAgentsInput() {
        let input = HookInput(json: Data(#"{"session_id":"s1","cwd":"/p","hook_event_name":"UserPromptSubmit"}"#.utf8))
        #expect(input == HookInput(json: Data(#"{"session_id":"s1","cwd":"/p"}"#.utf8)))
        #expect(input?.chat == "s1")
        #expect(input?.folder == "/p")
        #expect(HookInput(json: Data("not json".utf8)) == nil)
    }

    @Test func eachAgentReadsTheReportWhereItLooks() throws {
        let output = try #require(AgentHooks.output(for: .prompt, text: "r"))
        #expect(try sortedJSON(output) == sortedJSON(["hookSpecificOutput": ["hookEventName": "UserPromptSubmit", "additionalContext": "r"]]))
        // Nothing to say, nothing printed.
        #expect(AgentHooks.output(for: .prompt, text: nil) == nil)
    }
}
#endif
