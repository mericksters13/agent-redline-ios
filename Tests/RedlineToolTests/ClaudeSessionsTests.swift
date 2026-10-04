#if os(macOS)
import Foundation
import Testing
@testable import RedlineTool

struct ClaudeSessionsTests {
    private func file(kind: String = "interactive", pid: Int32 = getpid(), updatedAt: Double? = 1_791_000_000_500)
        throws -> Data
    {
        var object: [String: Any] = [
            "sessionId": "s-1", "cwd": "/w", "messagingSocketPath": "/tmp/s.sock", "pid": pid, "kind": kind,
            "name": "Fix the paywall", "startedAt": 1_791_000_000_000,
        ]
        if let updatedAt { object["updatedAt"] = updatedAt }
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test func aRunningInteractiveChatIsReadWithItsTimesInMilliseconds() throws {
        let session = try #require(ClaudeSessions.session(from: file()))
        #expect(
            session
                == ClaudeSessions.Session(
                    id: "s-1",
                    folder: "/w",
                    socket: "/tmp/s.sock",
                    updatedAt: Date(timeIntervalSince1970: 1_791_000_000.5),
                    title: "Fix the paywall"
                )
        )
        // Without updatedAt, when it started.
        #expect(
            try ClaudeSessions.session(from: file(updatedAt: nil))?.updatedAt
                == Date(timeIntervalSince1970: 1_791_000_000)
        )
    }

    @Test func otherChatsAreLeftOut() throws {
        #expect(try ClaudeSessions.session(from: file(kind: "print")) == nil)
        #expect(try ClaudeSessions.session(from: file(pid: Int32.max)) == nil)
        #expect(ClaudeSessions.session(from: Data("not json".utf8)) == nil)
    }
}
#endif
