#if os(macOS)
import Foundation
import Testing
@testable import RedlineTool

struct HubWindowTests {
    private let paths = HubPaths(root: FileManager.default.temporaryDirectory.appending(path: "HubWindowTests-\(UUID().uuidString)", directoryHint: .isDirectory))

    /// A report in the inbox, as the hub files it.
    private func report(_ id: String, at date: Date, device: String = "Mark iPhone") throws -> URL {
        let folder = paths.inbox.appending(path: "com.example.app/\(id)-0CF3C01C", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let listing: [String: Any] = [
            "app": ["name": "Tiny Tally"],
            "screens": [["images": [["file": "screen-1.jpg", "notes": [1]]]]],
            "items": [
                ["number": 2, "title": "History", "note": "", "attachments": ["note-2.jpg"]],
                ["number": 1, "title": "Log milestone", "note": "Too plain", "attachments": [String](),
                 "element": ["identifier": "today.milestones", "label": "Log milestone", "role": "Button"]],
            ],
        ]
        try JSONSerialization.data(withJSONObject: listing).write(to: folder.appending(path: "report.json"))
        try Data([0xFF, 0xD8]).write(to: folder.appending(path: "screen-1.jpg"))
        let source = ReportSource(kind: .phone, device: "D-\(device)", deviceName: device, bundleID: "com.example.app", reportID: id, receivedAt: date)
        try Chats.coder.encode(source).write(to: folder.appending(path: "source.json"))
        return folder
    }

    @Test func reportsShowWhereTheyWentNewestFirst() throws {
        let older = try report("20261004-090000", at: Date(timeIntervalSince1970: 1_791_000_000))
        let newer = try report("20261004-120000", at: Date(timeIntervalSince1970: 1_791_010_000))
        ReportDelivery.save(.init(agent: .claude, chat: "s-1", title: "Untitled session", kind: .sent), in: newer)
        ReportDelivery.save(.init(agent: nil, chat: nil, title: "2 chats work in wt; pick one on the phone", kind: .waiting), in: older)

        let rows = HubWindowModel.readReports(paths: paths).map(\.row)
        #expect(rows.map(\.folder) == [newer, older])
        #expect(rows[0].agent == "Claude Code")
        #expect(rows[0].chat == "Untitled session")
        #expect(!rows[0].waiting)
        #expect(rows[0].thumbnail == newer.appending(path: "screen-1.jpg"))
        // Notes in their numbers' order, with the element's name.
        #expect(rows[0].notes == [.init(number: 1, text: "Log milestone: Too plain"), .init(number: 2, text: "History: No note")])
        #expect(rows[1].waiting)
        #expect(rows[1].chat == "2 chats work in wt; pick one on the phone")
    }

    @Test func phonesSayWhyTheyCantTakeReports() {
        #expect(HubWindowModel.phoneState("Ready for com.example.app") == "Ready")
        #expect(HubWindowModel.phoneState("Not reachable, trying again in 30 s or when a phone wakes") == "Not reachable")
        #expect(HubWindowModel.phoneState("None of the watched apps installed") == "No watched app installed")
    }

    @Test func aReportTakenBeforeDeliveriesWereSavedNamesItsChat() throws {
        let folder = try report("20261004-100000", at: Date())
        let claim = Claim(chat: "started-claude-20261004-100000", agent: "claude", folder: "/repo/.claude/worktrees/report-1", claimedAt: Date())
        try Chats.coder.encode(claim).write(to: folder.appending(path: InboxQueue.claimFile))
        let destination = HubWindowModel.destination(of: folder)
        #expect(destination.agent == "Claude Code")
        #expect(destination.chat == "New chat in report-1")
        // A Codex chat stored no folder: never the folder this process happens to be in.
        #expect(HubWindowModel.chatTitle(Claim(chat: "codex-unknown", agent: "codex", folder: "", claimedAt: Date())) == "Codex chat")
    }
}
#endif
