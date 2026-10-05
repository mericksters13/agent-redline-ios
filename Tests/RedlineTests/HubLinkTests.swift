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

    @Test func helloEncodesAndChallengeDecodes() throws {
        let hello = HubLink.Hello(device: "D", bundleID: "com.example.app", nonce: "a")
        let line = String(decoding: try HubLink.encode(hello), as: UTF8.self)
        #expect(line == #"{"bundleID":"com.example.app","device":"D","kind":"hello","nonce":"a"}"# + "\n")
        #expect(
            try HubLink.decode(HubLink.Challenge.self, from: Data(#"{"nonce":"h","proof":"p"}"#.utf8))
                == HubLink.Challenge(nonce: "h", proof: "p")
        )
    }

    @Test func offerEncodesAsOneSortedLine() throws {
        let offer = HubLink.Offer(
            device: "00008150-00123C360CF3C01C",
            bundleID: "com.example.app",
            proof: "p",
            reports: [.init(id: "20261003-215826", finishedAt: finishedAt)]
        )
        let line = String(decoding: try HubLink.encode(offer), as: UTF8.self)
        #expect(
            line
                == #"{"bundleID":"com.example.app","device":"00008150-00123C360CF3C01C","proof":"p","reports":[{"finishedAt":"2026-10-03T04:00:00Z","id":"20261003-215826"}]}"#
                + "\n"
        )
    }

    @Test func theAppSendsNothingUntilTheHubProvesItHoldsTheToken() {
        // The hub makes exactly these proofs; see the Mac tool's HubTests.
        let appProof = "4401046e18c86d9341f3fd816d12b80347958cf02338a89bfd5ec2f8a335a707"
        let hubProof = "f4a6ae4aee48255a3141214cd10e0808b632de322c281bd5a839403249bc7c0a"
        #expect(HubLink.proof(.app, token: "secret", appNonce: "a", hubNonce: "h") == appProof)
        #expect(HubLink.proof(.hub, token: "secret", appNonce: "a", hubNonce: "h") == hubProof)
        let hello = HubLink.Hello(device: "D", bundleID: "com.example.app", nonce: "a")
        let hub = HubLink.Challenge(nonce: "h", proof: hubProof)
        #expect(HubLink.appProof(after: hub, to: hello, token: "secret") == appProof)
        // Something that doesn't hold the token, such as whatever answers at an old address.
        #expect(HubLink.appProof(after: hub, to: hello, token: "another") == nil)
        let guess = HubLink.Challenge(nonce: "h", proof: "guess")
        #expect(HubLink.appProof(after: guess, to: hello, token: "secret") == nil)
        #expect(HubLink.appProof(after: HubLink.Challenge(nonce: "h"), to: hello, token: "secret") == nil)
        // A proof made for another connection's random value isn't taken.
        let otherHello = HubLink.Hello(device: "D", bundleID: "com.example.app", nonce: "b")
        #expect(HubLink.appProof(after: hub, to: otherHello, token: "secret") == nil)
        // The app's own proof can't stand in for the hub's.
        let reflected = HubLink.Challenge(nonce: "h", proof: appProof)
        #expect(HubLink.appProof(after: reflected, to: hello, token: "secret") == nil)
        #expect(HubLink.nonce().count == 64)
        #expect(HubLink.nonce() != HubLink.nonce())
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
            proof: "p",
            sourceFile: "/w/App.swift"
        )
        let line = String(decoding: try HubLink.encode(request), as: UTF8.self)
        #expect(
            line
                == #"{"bundleID":"com.example.app","device":"D","kind":"chats","proof":"p","sourceFile":"/w/App.swift"}"#
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

    @Test func aChatListSaysWhichAgentsStartNewChats() throws {
        // A Mac from before newChats offers new chats with every agent; a newer one names them.
        let older = try HubLink.decode(HubLink.ChatList.self, from: Data(#"{"agents":["claude"],"chats":[]}"#.utf8))
        #expect(older.startsNewChats("codex"))
        let named = try HubLink.decode(
            HubLink.ChatList.self,
            from: Data(#"{"agents":["claude","codex"],"chats":[],"newChats":["claude"]}"#.utf8)
        )
        #expect(named.startsNewChats("claude"))
        #expect(!named.startsNewChats("codex"))
        // With no open chat and no agent that starts one, there's nothing to pick.
        #expect(named.offersDestination)
        let none = try HubLink.decode(
            HubLink.ChatList.self,
            from: Data(#"{"agents":["codex"],"chats":[],"newChats":[]}"#.utf8)
        )
        #expect(!none.offersDestination)
        let empty = try HubLink.decode(HubLink.ChatList.self, from: Data(#"{"agents":[],"chats":[]}"#.utf8))
        #expect(!empty.offersDestination)
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
