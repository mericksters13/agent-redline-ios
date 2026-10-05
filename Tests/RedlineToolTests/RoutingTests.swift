#if os(macOS)
import Foundation
import Testing
@testable import RedlineTool

struct RoutingTests {
    private let temporary = TemporaryFolder("RoutingTests")
    private var root: URL { temporary.url }
    private var paths: HubPaths { HubPaths(root: root.appending(path: "hub-root", directoryHint: .isDirectory)) }

    /// A report folder with what the phone saved: the worktree's file and the user's pick.
    private func report(sourceFile: String?, pick: [String: Any]?) throws -> URL {
        let folder = root.appending(path: "report-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var listing: [String: Any] = ["app": sourceFile.map { ["sourceFile": $0] } ?? [String: Any]()]
        if let pick { listing["destination"] = pick }
        try JSONSerialization.data(withJSONObject: listing).write(to: folder.appending(path: "report.json"))
        return folder
    }

    private func chat(_ id: String, _ agent: String, sameWorktree: Bool) -> HubMessage.Chat {
        HubMessage.Chat(
            id: id,
            agent: agent,
            title: id,
            folder: "wt",
            isSameWorktree: sameWorktree,
            lastActive: Date.now
        )
    }

    @Test func aReportGoesWhereThePhonePickedOrElseToItsWorktreesChat() throws {
        let worktree = root.appending(path: "worktree-a", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: worktree.appending(path: ".git"), withIntermediateDirectories: true)
        try "targets:\n  App:\n    settings:\n      PRODUCT_BUNDLE_IDENTIFIER: com.example.app\n"
            .write(to: worktree.appending(path: "project.yml"), atomically: true, encoding: .utf8)
        let file = worktree.appending(path: "App/AppMain.swift").path
        let folder = worktree.standardizedFileURL.path
        func route(_ report: URL, _ chats: [HubMessage.Chat]) -> ReportDestination {
            Routing.destination(of: report, bundleID: "com.example.app") { _, _ in
                HubMessage.ChatList(agents: ["claude", "codex"], chats: chats)
            }
        }
        let others = [chat("A", "claude", sameWorktree: true), chat("B", "codex", sameWorktree: false)]

        // The user's pick wins, even over the chat in the worktree.
        #expect(
            route(try report(sourceFile: file, pick: ["agent": "codex", "chat": "B"]), others) == .chat(.codex, id: "B")
        )
        #expect(
            route(try report(sourceFile: file, pick: ["agent": "codex"]), others)
                == .newChat(.codex, folder: folder, pick: nil)
        )
        #expect(
            route(try report(sourceFile: file, pick: ["agent": "claude", "newChat": "N1"]), others)
                == .newChat(.claude, folder: folder, pick: "N1")
        )
        // No pick: the one chat in the worktree, or a new chat there with the first agent.
        #expect(route(try report(sourceFile: file, pick: nil), others) == .chat(.claude, id: "A"))
        #expect(
            route(try report(sourceFile: file, pick: nil), [chat("B", "codex", sameWorktree: false)])
                == .newChat(.claude, folder: folder, pick: nil)
        )
        // Only an agent that can start a chat is given a new one.
        let codexOnly = Routing.destination(of: try report(sourceFile: file, pick: nil), bundleID: "com.example.app") {
            _,
            _ in
            HubMessage.ChatList(agents: ["claude", "codex"], chats: [], newChats: ["codex"])
        }
        #expect(codexOnly == .newChat(.codex, folder: folder, pick: nil))
        // A new chat starts with the agent last used on the app, while it can start one.
        let lastCodex = Routing.destination(
            of: try report(sourceFile: file, pick: nil),
            bundleID: "com.example.app",
            lastAgent: "codex"
        ) { _, _ in
            HubMessage.ChatList(agents: ["claude", "codex"], chats: [])
        }
        #expect(lastCodex == .newChat(.codex, folder: folder, pick: nil))
        let codexGone = Routing.destination(
            of: try report(sourceFile: file, pick: nil),
            bundleID: "com.example.app",
            lastAgent: "codex"
        ) { _, _ in
            HubMessage.ChatList(agents: ["claude", "codex"], chats: [], newChats: ["claude"])
        }
        #expect(codexGone == .newChat(.claude, folder: folder, pick: nil))
        // Several chats in the worktree and no pick: no guessing.
        if case .undecided = route(
            try report(sourceFile: file, pick: nil),
            others + [chat("C", "codex", sameWorktree: true)]
        ) {
        } else {
            Issue.record("Two chats in the worktree should leave the report undecided")
        }
        if case .undecided = route(try report(sourceFile: nil, pick: nil), others) {
        } else {
            Issue.record("A report without its worktree should be undecided")
        }
        // The phone writes the report: a folder that doesn't build the app gets no new chat.
        let elsewhere = root.appending(path: "other-project", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: elsewhere.appending(path: ".git"),
            withIntermediateDirectories: true
        )
        let foreign = elsewhere.appending(path: "Sources/Main.swift").path
        for pick: [String: Any]? in [["agent": "codex"], ["agent": "claude", "newChat": "N2"], nil] {
            if case .undecided = route(try report(sourceFile: foreign, pick: pick), []) {
            } else {
                Issue.record("A worktree that doesn't build the app should leave the report undecided")
            }
        }
        #expect(Routing.worktree(of: try report(sourceFile: foreign, pick: nil), bundleID: "com.example.app") == nil)
        #expect(Routing.worktree(of: try report(sourceFile: file, pick: nil), bundleID: "com.example.app") == folder)
    }

    @Test func aRestartedHubReplaysPromisedReportsHoweverOld() throws {
        let old = Date.now.addingTimeInterval(-86_400)
        let source = ReportSource(
            kind: .phone,
            device: "D",
            deviceName: "Test iPhone",
            bundleID: "com.example.app",
            reportID: "r",
            receivedAt: old
        )
        func waiting(_ folder: URL, claim: Claim? = nil) -> InboxReport {
            InboxReport(folder: folder, source: source, claim: claim)
        }
        // Sent nowhere: only while recent, since a chat started for it a day later would surprise.
        let unpicked = try report(sourceFile: "/w/App.swift", pick: nil)
        #expect(!Handoff.isReplayed(waiting(unpicked), within: 3600))
        #expect(Handoff.isReplayed(waiting(unpicked), within: 3600, now: old.addingTimeInterval(60)))
        // Picked on the phone, or cut off mid hand-over: however old.
        let picked = try report(sourceFile: "/w/App.swift", pick: ["agent": "codex", "chat": "c1"])
        #expect(Handoff.isReplayed(waiting(picked), within: 3600))
        let cutOff = Claim(chat: "claude-s1", agent: "claude", folder: "/w", claimedAt: old, handingOverIn: Int32.max)
        #expect(Handoff.isReplayed(waiting(unpicked, claim: cutOff), within: 3600))
        // A pick for an agent the hub doesn't send reports to isn't a promise.
        let elsewhere = try report(sourceFile: "/w/App.swift", pick: ["agent": "cursor", "chat": "c1"])
        #expect(!Handoff.isReplayed(waiting(elsewhere), within: 3600))
        // Addressed to a chat: its hooks take it.
        try Inbox.setRecipient(ReportRecipient(chat: "codex-c1", agent: "codex", folder: "/w"), of: picked)
        #expect(!Handoff.isReplayed(waiting(picked), within: 3600))
    }
}
#endif
