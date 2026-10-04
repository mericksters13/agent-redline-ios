#if os(macOS)
import Foundation
import Testing
@testable import RedlineTool

struct HubWindowModelTests {
    private let temporary = TemporaryFolder("HubWindowModelTests")
    private var root: URL { temporary.url }
    private var paths: HubPaths { HubPaths(root: root.appending(path: "hub-root", directoryHint: .isDirectory)) }

    /// A report in the inbox, as the hub files it.
    private func report(_ id: String, at date: Date) throws -> URL {
        let listing: [String: Any] = [
            "app": ["name": "Example"],
            "screens": [["images": [["file": "screen-1.jpg", "notes": [1]]]]],
            "items": [
                ["number": 2, "title": "History", "note": "", "attachments": ["note-2.jpg"]],
                [
                    "number": 1, "title": "Log milestone", "note": "Too plain", "attachments": [String](),
                    "element": ["identifier": "today.milestones", "label": "Log milestone", "role": "Button"],
                ],
            ],
        ]
        return try fileInboxReport("\(id)-00000001", in: paths, listing: listing, receivedAt: date)
    }

    @Test func reportsShowWhereTheyWentNewestFirst() throws {
        let older = try report("20261004-090000", at: Date(timeIntervalSince1970: 1_791_000_000))
        let newer = try report("20261004-120000", at: Date(timeIntervalSince1970: 1_791_010_000))
        try ChatDelivery.save(.init(agent: .claude, chat: "s-1", title: "Untitled session", kind: .sent), in: newer)
        try ChatDelivery.save(
            .init(agent: nil, chat: nil, title: "2 chats work in wt; pick one on the phone", kind: .waiting),
            in: older
        )

        let rows = HubWindowModel.readReports(paths: paths).map(\.row)
        #expect(rows.map(\.folder) == [newer, older])
        #expect(rows[0].agent == "Claude Code")
        #expect(rows[0].chat == "Untitled session")
        #expect(!rows[0].isWaiting)
        #expect(rows[0].thumbnail == newer.appending(path: "screen-1.jpg"))
        // Notes in their numbers' order, with the element's name.
        #expect(
            rows[0].notes == [
                .init(number: 1, text: "Log milestone: Too plain"), .init(number: 2, text: "History: No note"),
            ]
        )
        #expect(rows[1].isWaiting)
        #expect(rows[1].chat == "2 chats work in wt; pick one on the phone")
    }

    @Test func onlyTheNewestReportsAreShown() throws {
        for minute in 0..<5 {
            _ = try report(
                "20261004-09\(minute)000",
                at: Date(timeIntervalSince1970: 1_791_000_000 + Double(minute) * 60)
            )
        }
        let rows = HubWindowModel.readReports(paths: paths, limit: 2).map(\.row)
        #expect(
            rows.map(\.receivedAt) == [
                Date(timeIntervalSince1970: 1_791_000_240), Date(timeIntervalSince1970: 1_791_000_180),
            ]
        )
    }

    @Test func aReportListingWithOnlyItsNotesStillShowsThem() throws {
        let folder = paths.root.appending(path: "minimal", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #"{"items":[{"number":1,"title":"Save","note":""}]}"#.write(
            to: folder.appending(path: "report.json"),
            atomically: true,
            encoding: .utf8
        )
        #expect(HubWindowModel.notes(in: folder) == [.init(number: 1, text: "Save: No note")])
        // Without screens, snapshots come from the folder; without an app, routing has no worktree.
        #expect(ReportContent.snapshots(in: folder).isEmpty)
        #expect(Routing.worktree(of: folder) == nil)
    }

    @Test func phonesSayWhyTheyCantTakeReports() {
        func phone(_ state: PhoneState?, text: String = "") -> HubStatus.Phone {
            HubStatus.Phone(name: "P", udid: "U", state: state?.description ?? text, phoneState: state)
        }
        #expect(HubWindowModel.phoneState(phone(.ready(apps: ["com.example.app"]))) == "Ready")
        #expect(HubWindowModel.phoneState(phone(.unreachable(retryInSeconds: 30))) == "Not reachable")
        #expect(HubWindowModel.phoneState(phone(.noWatchedApps)) == "No watched app installed")
        #expect(
            PhoneState.unreachable(retryInSeconds: 30).description
                == "Not reachable, trying again in 30 s or when a phone wakes"
        )
        // Saved by an earlier hub, as text only.
        #expect(HubWindowModel.phoneState(phone(nil, text: "Ready for com.example.app")) == "Ready")
        #expect(
            HubWindowModel.phoneState(phone(nil, text: "None of the watched apps installed"))
                == "No watched app installed"
        )
    }

    @Test func aReportTakenBeforeDeliveriesWereSavedNamesItsChat() throws {
        let folder = try report("20261004-100000", at: Date.now)
        let claim = Claim(
            chat: "started-claude-20261004-100000",
            agent: "claude",
            folder: "/repo/.claude/worktrees/report-1",
            claimedAt: .now
        )
        try HubPaths.encoder.encode(claim).write(to: folder.appending(path: Inbox.claimFile))
        let destination = HubWindowModel.destination(of: folder, codexDatabase: nil)
        #expect(destination.agent == "Claude Code")
        #expect(destination.chat == "New chat in report-1")
        // A Codex chat stored no folder: never the folder this process happens to be in.
        #expect(
            HubWindowModel.chatTitle(
                Claim(chat: "codex-unknown", agent: "codex", folder: "", claimedAt: .now),
                codexDatabase: nil
            ) == "Codex chat"
        )
    }

    @Test func theViewerShowsEachSnapshotWithTheNotesItShows() throws {
        let folder = try report("20261004-130000", at: Date.now)
        try Data([0xFF, 0xD8]).write(to: folder.appending(path: "note-2.jpg"))
        let snapshots = HubWindowModel.snapshots(in: folder)
        // Screens' snapshots first, then snapshots attached to notes, as the agent gets them.
        #expect(
            snapshots == [
                .init(file: folder.appending(path: "screen-1.jpg"), title: "Screen", notes: [1]),
                .init(file: folder.appending(path: "note-2.jpg"), title: "History", notes: [2]),
            ]
        )
        #expect(snapshots.map(\.file) == ReportContent.snapshots(in: folder))
        #expect(HubWindowModel.snapshot(showing: 1, in: snapshots) == folder.appending(path: "screen-1.jpg"))
        #expect(HubWindowModel.snapshot(showing: 2, in: snapshots) == folder.appending(path: "note-2.jpg"))
        #expect(HubWindowModel.snapshot(showing: 3, in: snapshots) == nil)
    }

    @Test func theViewerOpensTheChatAReportWentTo() throws {
        func claim(_ chat: String, agent: String, folder: String = "", in report: URL) throws {
            try HubPaths.encoder.encode(Claim(chat: chat, agent: agent, folder: folder, claimedAt: .now)).write(
                to: report.appending(path: Inbox.claimFile)
            )
        }
        // What the hub saved when it delivered it, with the folder of the chat that took it.
        let sent = try report("20261004-140000", at: Date.now)
        try claim("claude-s-1", agent: "claude", folder: "/repo", in: sent)
        try ChatDelivery.save(.init(agent: .claude, chat: "s-1", title: "Untitled session", kind: .sent), in: sent)
        let chat = try #require(HubWindowModel.chat(of: sent))
        #expect(chat.agent == .claude && chat.id == "s-1" && chat.folder == "/repo")

        // Taken before deliveries were saved: the chat that took it.
        let taken = try report("20261004-140100", at: Date.now)
        try claim("codex-t-1", agent: "codex", in: taken)
        let codex = try #require(HubWindowModel.chat(of: taken))
        #expect(codex.agent == .codex && codex.id == "t-1" && codex.folder == nil)

        // A chat the hub started: its ID from what the command printed.
        let started = try report("20261004-140200", at: Date.now)
        try claim("started-codex-20261004-140200", agent: "codex", folder: "/repo", in: started)
        try #"{"type":"thread.started","thread_id":"t-2"}"#.write(
            to: started.appending(path: "new-chat-output.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        #expect(HubWindowModel.chat(of: started)?.id == "t-2")

        // Waiting: nothing to open.
        let waiting = try report("20261004-140300", at: Date.now)
        try ChatDelivery.save(
            .init(agent: .claude, chat: nil, title: "Waiting for claude auth login", kind: .waiting),
            in: waiting
        )
        #expect(HubWindowModel.chat(of: waiting) == nil)
        #expect(HubWindowModel.chat(of: try report("20261004-140500", at: Date.now)) == nil)
    }
}
#endif
