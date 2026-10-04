#if os(macOS)
import Foundation
import Testing
@testable import RedlineTool

struct HubMessageTests {
    @Test func messagesMatchTheKitsExactly() throws {
        // The kit writes exactly these lines; see the kit's ReportStoreTests.
        let line =
            #"{"bundleID":"com.example.app","device":"00000000-0000000000000001","reports":[{"finishedAt":"2026-10-03T04:00:00Z","id":"20261003-215826"}],"token":"secret"}"#
        #expect(
            try HubMessage.decode(HubMessage.Offer.self, from: Data(line.utf8))
                == HubMessage.Offer(
                    device: "00000000-0000000000000001",
                    bundleID: "com.example.app",
                    token: "secret",
                    reports: [.init(id: "20261003-215826", finishedAt: Date(timeIntervalSince1970: 1_791_000_000))]
                )
        )
        #expect(
            String(
                decoding: HubMessage.encode(HubMessage.Answer(want: ["20261003-215826"], delivered: [])),
                as: UTF8.self
            )
                == #"{"delivered":[],"want":["20261003-215826"]}"# + "\n"
        )
        #expect(
            try HubMessage.decode(
                HubMessage.Upload.self,
                from: Data(#"{"files":{"report.md":"IyBIaQ=="},"id":"r"}"#.utf8)
            )
                == HubMessage.Upload(id: "r", files: ["report.md": Data("# Hi".utf8)])
        )
        let ask =
            #"{"bundleID":"com.example.app","device":"D","kind":"chats","sourceFile":"/w/App.swift","token":"secret"}"#
        #expect(
            try HubMessage.decode(HubMessage.ChatsRequest.self, from: Data(ask.utf8))
                == HubMessage.ChatsRequest(
                    kind: "chats",
                    device: "D",
                    bundleID: "com.example.app",
                    token: "secret",
                    sourceFile: "/w/App.swift"
                )
        )
        // An offer isn't taken for a question about chats.
        #expect(throws: DecodingError.self) {
            try HubMessage.decode(HubMessage.ChatsRequest.self, from: Data(line.utf8))
        }
        let list = HubMessage.ChatList(
            agents: ["claude"],
            chats: [
                HubMessage.Chat(
                    id: "s1",
                    agent: "claude",
                    title: "Let",
                    folder: "wt",
                    isSameWorktree: true,
                    lastActive: Date(timeIntervalSince1970: 1_791_000_000)
                )
            ],
            worktree: "wt"
        )
        #expect(
            String(decoding: HubMessage.encode(list), as: UTF8.self)
                == #"{"agents":["claude"],"chats":[{"agent":"claude","folder":"wt","id":"s1","lastActive":"2026-10-03T04:00:00Z","sameWorktree":true,"title":"Let"}],"worktree":"wt"}"#
                + "\n"
        )
    }
}
#endif
