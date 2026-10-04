#if REDLINE
import Foundation
import Testing
@testable import Redline

/// The phone's side of the hub protocol.
///
/// The hub reads and writes exactly these lines; the Mac tool's ReportSourcesTests pins the same
/// strings for HubMessage.
struct HubLinkTests {
    private let finishedAt = Date(timeIntervalSince1970: 1_791_000_000)

    @Test func offerEncodesAsOneSortedLine() throws {
        let offer = HubLink.Offer(
            device: "00008150-00123C360CF3C01C",
            bundleID: "com.example.app",
            token: "secret",
            reports: [.init(id: "20261003-215826", finishedAt: finishedAt)]
        )
        let line = String(decoding: try HubLink.encode(offer), as: UTF8.self)
        #expect(
            line
                == #"{"bundleID":"com.example.app","device":"00008150-00123C360CF3C01C","reports":[{"finishedAt":"2026-10-03T04:00:00Z","id":"20261003-215826"}],"token":"secret"}"#
                + "\n"
        )
    }

    @Test func answerDecodes() throws {
        let answer = try HubLink.decode(
            HubLink.Answer.self,
            from: Data(#"{"delivered":[],"want":["20261003-215826"]}"#.utf8)
        )
        #expect(answer == HubLink.Answer(wanted: ["20261003-215826"], delivered: []))
        let refused = try HubLink.decode(
            HubLink.Answer.self,
            from: Data(#"{"delivered":["a"],"refused":"Pair again","want":[]}"#.utf8)
        )
        #expect(refused.refused == "Pair again")
    }

    @Test func uploadEncodesFilesAsBase64() throws {
        let upload = String(
            decoding: try HubLink.encode(HubLink.Upload(id: "r", files: ["report.md": Data("# Hi".utf8)])),
            as: UTF8.self
        )
        #expect(upload == #"{"files":{"report.md":"IyBIaQ=="},"id":"r"}"# + "\n")
    }

    @Test func replyDecodes() throws {
        #expect(
            try HubLink.decode(HubLink.Reply.self, from: Data(#"{"delivered":["r"]}"#.utf8))
                == HubLink.Reply(delivered: ["r"])
        )
    }

    @Test func chatsRequestEncodes() throws {
        let request = HubLink.ChatsRequest(
            device: "D",
            bundleID: "com.example.app",
            token: "secret",
            sourceFile: "/w/App.swift"
        )
        let line = String(decoding: try HubLink.encode(request), as: UTF8.self)
        #expect(
            line
                == #"{"bundleID":"com.example.app","device":"D","kind":"chats","sourceFile":"/w/App.swift","token":"secret"}"#
                + "\n"
        )
    }

    @Test func chatListDecodes() throws {
        let list =
            #"{"agents":["claude"],"chats":[{"agent":"claude","folder":"wt","id":"s1","lastActive":"2026-10-03T04:00:00Z","sameWorktree":true,"title":"Let"}],"worktree":"wt"}"#
        #expect(
            try HubLink.decode(HubLink.ChatList.self, from: Data(list.utf8))
                == HubLink.ChatList(
                    agents: ["claude"],
                    chats: [
                        HubLink.Chat(
                            id: "s1",
                            agent: "claude",
                            title: "Let",
                            folder: "wt",
                            isSameWorktree: true,
                            lastActive: finishedAt
                        )
                    ],
                    worktree: "wt"
                )
        )
    }

    @Test func renamedFieldsKeepTheirWireNames() throws {
        let chat = HubLink.Chat(
            id: "s1",
            agent: "codex",
            title: "Let",
            folder: "wt",
            isSameWorktree: false,
            lastActive: finishedAt
        )
        let line = String(decoding: try HubLink.encode(chat), as: UTF8.self)
        #expect(
            line
                == #"{"agent":"codex","folder":"wt","id":"s1","lastActive":"2026-10-03T04:00:00Z","sameWorktree":false,"title":"Let"}"#
                + "\n"
        )
        let answer = String(decoding: try HubLink.encode(HubLink.Answer(wanted: ["r"], delivered: [])), as: UTF8.self)
        #expect(answer == #"{"delivered":[],"want":["r"]}"# + "\n")
    }

    @Test func aMalformedLineThrows() {
        #expect(throws: (any Error).self) { try HubLink.decode(HubLink.Answer.self, from: Data("{".utf8)) }
    }
}
#endif
