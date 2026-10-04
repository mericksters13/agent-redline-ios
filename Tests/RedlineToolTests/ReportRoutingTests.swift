#if os(macOS)
import Foundation
import Testing
@testable import RedlineTool

struct ReportRoutingTests {
    private let temporary = TemporaryFolder("ReportRoutingTests")
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
    }
}
#endif
