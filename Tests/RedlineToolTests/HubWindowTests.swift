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

        let rows = HubWindowModel.readReports(paths: paths).rows
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

    @Test func devicesKeepTheirLastReportWhenAnotherFillsTheList() throws {
        let quiet = Date(timeIntervalSince1970: 1_791_000_000)
        _ = try report("20261004-080000", at: quiet, device: "Quiet iPhone")
        for minute in 0..<3 {
            _ = try report("20261004-09\(minute)000", at: quiet.addingTimeInterval(TimeInterval(60 * (minute + 1))))
        }

        let (rows, lastReport) = HubWindowModel.readReports(paths: paths, limit: 2)
        #expect(rows.count == 2)
        #expect(!rows.contains { $0.device == "Quiet iPhone" })
        #expect(lastReport["D-Quiet iPhone"] == quiet)
        #expect(lastReport["D-Mark iPhone"] == quiet.addingTimeInterval(180))
    }

    @Test func aChatThatTakesAWaitingReportShowsOverTheWait() throws {
        let waiting = try report("20261004-110000", at: Date())
        ReportDelivery.save(.init(agent: nil, chat: nil, title: "2 chats work in wt; pick one on the phone", kind: .waiting), in: waiting)
        #expect(HubWindowModel.destination(of: waiting).waiting)
        let claim = Claim(chat: "started-claude-1", agent: "claude", folder: "/repo/wt", claimedAt: Date().addingTimeInterval(5))
        try Chats.coder.encode(claim).write(to: waiting.appending(path: InboxQueue.claimFile))
        let taken = HubWindowModel.destination(of: waiting)
        #expect(taken.agent == "Claude Code")
        #expect(taken.chat == "New chat in wt")
        #expect(!taken.waiting)

        // A report sent to a chat keeps the hub's record, which names the chat best.
        let sent = try report("20261004-113000", at: Date())
        try Chats.coder.encode(Claim(chat: "claude-s-1", agent: "claude", folder: "/repo/wt", claimedAt: Date())).write(to: sent.appending(path: InboxQueue.claimFile))
        ReportDelivery.save(.init(agent: .claude, chat: "s-1", title: "Untitled session", kind: .sent), in: sent)
        #expect(HubWindowModel.destination(of: sent).chat == "Untitled session")
    }

    @Test func aClaimInTheSameSecondAsItsDeliveryStillShows() throws {
        let folder = try report("20261004-133000", at: Date())
        let delivered = Date(timeIntervalSince1970: 1_791_120_672.1)
        var delivery = ReportDelivery(agent: .cursor, chat: "c-1", title: "Fix the chart", kind: .nextMessage)
        delivery.at = delivered
        ReportDelivery.save(delivery, in: folder)
        let claim = Claim(chat: "cursor-c-1", agent: "cursor", folder: "/repo/wt", claimedAt: delivered.addingTimeInterval(0.5))
        try Chats.coder.encode(claim).write(to: folder.appending(path: InboxQueue.claimFile))
        #expect(!HubWindowModel.destination(of: folder).waiting)
        // In the same millisecond, or dated a moment before the wait it came after, the claim still shows.
        for offset in [0.0002, -0.01] {
            let taken = Claim(chat: "cursor-c-1", agent: "cursor", folder: "/repo/wt", claimedAt: delivered.addingTimeInterval(offset))
            try Chats.coder.encode(taken).write(to: folder.appending(path: InboxQueue.claimFile))
            #expect(HubWindowModel.destination(of: folder) == ("Cursor", "wt", false))
        }
        // Dates saved before milliseconds were kept still read.
        let older = Data(#"{"agent":"claude","chat":"c","claimedAt":"2026-10-04T13:31:12Z","folder":"/repo"}"#.utf8)
        #expect(try Chats.decoder.decode(Claim.self, from: older).claimedAt == Date(timeIntervalSince1970: 1_791_120_672))
    }

    @Test func aReportForAChatsNextMessageShowsAsNotThereYet() throws {
        let folder = try report("20261004-135000", at: Date())
        ReportDelivery.save(.init(agent: .codex, chat: "t-1", title: "Fix the chart", kind: .nextMessage), in: folder)
        let pending = HubWindowModel.destination(of: folder)
        #expect(pending.agent == "Codex")
        #expect(pending.chat == "Fix the chart (next message)")
        #expect(pending.waiting)
        // Once the chat's hook takes it, it's in the chat.
        try Chats.coder.encode(Claim(chat: "codex-t-1", agent: "codex", folder: "", claimedAt: Date().addingTimeInterval(1)))
            .write(to: folder.appending(path: InboxQueue.claimFile))
        #expect(!HubWindowModel.destination(of: folder).waiting)
    }

    @Test func aClaimWhoseHandOverWasInterruptedLeavesTheReportWaiting() throws {
        let folder = try report("20261004-134000", at: Date())
        let ended = Process()
        ended.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try ended.run()
        ended.waitUntilExit()
        let stranded = Claim(chat: "gone", agent: "claude", folder: "/repo/wt", claimedAt: Date(), handingOverIn: ended.processIdentifier)
        try Chats.coder.encode(stranded).write(to: folder.appending(path: InboxQueue.claimFile))
        let destination = HubWindowModel.destination(of: folder)
        #expect(destination.chat == "Waiting in the inbox")
        #expect(destination.waiting)
    }

    @Test func aWaitSavedAfterAChatTookTheReportDoesntHideIt() throws {
        // A chat whose wait woke when the report was filed took it before the hub decided.
        let taken = try report("20261004-140000", at: Date())
        try Chats.coder.encode(Claim(chat: "claude-s-2", agent: "claude", folder: "/repo/wt", claimedAt: Date()))
            .write(to: taken.appending(path: InboxQueue.claimFile))
        ReportDelivery.save(.init(agent: nil, chat: nil, title: "2 chats work in wt; pick one on the phone", kind: .waiting), in: taken)
        ReportDelivery.save(.init(agent: .cursor, chat: "c-1", title: "Cursor chat", kind: .nextMessage), in: taken)
        #expect(ReportDelivery.load(from: taken) == nil)
        let destination = HubWindowModel.destination(of: taken)
        #expect(destination.chat == "wt")
        #expect(!destination.waiting)

        // A hand-over this process claimed and couldn't finish still says why the report waits.
        let failed = try report("20261004-141000", at: Date())
        let chat = ChatRecord(id: "claude-s-3", agent: "claude", folder: "/repo/wt", bundleIDs: ["com.example.app"], pid: getpid(),
                              registeredAt: Date(), lastActiveAt: Date())
        let inbox = try #require(InboxQueue.reports(for: ["com.example.app"], paths: paths).first { $0.folder == failed })
        #expect(InboxQueue.claim(inbox, for: chat))
        ReportDelivery.save(.init(agent: .claude, chat: "s-3", title: "wt didn't take it", kind: .waiting), in: failed)
        InboxQueue.release(inbox)
        #expect(HubWindowModel.destination(of: failed).chat == "wt didn't take it")
        #expect(HubWindowModel.destination(of: failed).waiting)
    }

    @Test func aStoppingHubWaitsOnlyForTheReportsItIsHandingOver() throws {
        let first = try report("20261004-150000", at: Date())
        _ = try report("20261004-151000", at: Date())
        let chat = ChatRecord(id: "claude-s-4", agent: "claude", folder: "/repo/wt", bundleIDs: ["com.example.app"], pid: getpid(),
                              registeredAt: Date(), lastActiveAt: Date())
        #expect(InboxQueue.handingOver(by: getpid(), paths: paths) == 0)
        let inbox = try #require(InboxQueue.reports(for: ["com.example.app"], paths: paths).first { $0.folder == first })
        #expect(InboxQueue.claim(inbox, for: chat))
        #expect(InboxQueue.handingOver(by: getpid(), paths: paths) == 1)
        // Another process's hand-over isn't this one's to wait for.
        #expect(InboxQueue.handingOver(by: getpid() + 1, paths: paths) == 0)
        // Stopping waits until the chat has the report.
        let hub = Hub(paths: paths, devicectl: Devicectl(executable: URL(fileURLWithPath: "/usr/bin/false")), apps: [], claudeChats: { [] })
        let handoff = Handoff(hub: hub)
        let started = Date()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) { InboxQueue.handedOver(inbox) }
        handoff.finish()
        #expect(Date().timeIntervalSince(started) >= 0.6)
        #expect(InboxQueue.handingOver(by: getpid(), paths: paths) == 0)
        withExtendedLifetime(hub) {}
    }

    @Test func thePanelFitsOnShortScreens() {
        #expect(HubPanel.largestContentHeight(screen: 1_400) == 720)
        // On a short screen the header and footer stay on it.
        #expect(HubPanel.largestContentHeight(screen: 640) == 480)
        #expect(HubPanel.largestContentHeight(screen: nil) == 520)
    }

    @Test func theHeaderSaysWhereAppsReachTheHubOnlyWhileItCan() {
        var status = HubStatus(pid: 1, startedAt: Date(), apps: [], hosts: ["192.168.1.20", "mac.local"], port: 8765, phones: [],
                               simulatorContainers: 0)
        #expect(HubWindowModel.reach(nil) == "Starting")
        #expect(HubWindowModel.reach(status) == "Apps reach it at 192.168.1.20 · port 8765")
        // The Mac left its network: the old address is gone.
        status.hosts = []
        #expect(HubWindowModel.reach(status) == "Not on a network, so apps can't reach it")
    }

    @Test func phonesSayWhyTheyCantTakeReports() {
        #expect(HubWindowModel.phoneState("Ready for com.example.app") == "Ready")
        #expect(HubWindowModel.phoneState("Not reachable, trying again in 30 s or when a phone wakes") == "Not reachable")
        #expect(HubWindowModel.phoneState("None of the watched apps installed") == "No watched app installed")
        #expect(HubWindowModel.phoneState(PhoneLink.macOfflineState) == "Mac offline")
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

    @Test func theViewerShowsEachPictureWithTheNotesItShows() throws {
        let folder = try report("20261004-130000", at: Date())
        try Data([0xFF, 0xD8]).write(to: folder.appending(path: "note-2.jpg"))
        let pictures = HubWindowModel.pictures(in: folder)
        // Screens' pictures first, then pictures attached to notes, as the agent gets them.
        #expect(pictures == [
            .init(file: folder.appending(path: "screen-1.jpg"), title: "Screen", notes: [1]),
            .init(file: folder.appending(path: "note-2.jpg"), title: "History", notes: [2]),
        ])
        #expect(pictures.map(\.file) == ReportContent.pictures(in: folder))
        #expect(HubWindowModel.picture(showing: 1, in: pictures) == folder.appending(path: "screen-1.jpg"))
        #expect(HubWindowModel.picture(showing: 2, in: pictures) == folder.appending(path: "note-2.jpg"))
        #expect(HubWindowModel.picture(showing: 3, in: pictures) == nil)
    }

    @Test func aNoteOnASplitScreenScrollsToThePartThatShowsMostOfIt() throws {
        let folder = try report("20261004-130050", at: Date())
        let listing: [String: Any] = [
            "screens": [["title": "Today", "images": [["file": "screen-1-1.jpg", "notes": [1]], ["file": "screen-1-2.jpg", "notes": [1]]]]],
            "items": [["number": 1, "title": "List", "picture": "screen-1-2.jpg", "attachments": [String]()]],
        ]
        try JSONSerialization.data(withJSONObject: listing).write(to: folder.appending(path: "report.json"))
        for file in ["screen-1-1.jpg", "screen-1-2.jpg"] {
            try Data([0xFF, 0xD8]).write(to: folder.appending(path: file))
        }
        let pictures = HubWindowModel.pictures(in: folder)
        #expect(pictures.map(\.mainFor) == [[], [1]])
        #expect(HubWindowModel.picture(showing: 1, in: pictures) == folder.appending(path: "screen-1-2.jpg"))
    }

    @Test func theViewerShowsOnlyPicturesInTheReportsOwnFolder() throws {
        let folder = try report("20261004-130100", at: Date())
        let secret = paths.inbox.appending(path: "secret.jpg")
        try Data([0xFF, 0xD8]).write(to: secret)
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "link.jpg"), withDestinationURL: secret)
        try FileManager.default.createDirectory(at: folder.appending(path: "folder.jpg"), withIntermediateDirectories: true)
        let escape = "../../secret.jpg"
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: escape).path))
        let listing: [String: Any] = [
            "screens": [["images": [["file": escape, "notes": [1]], ["file": "screen-1.jpg", "notes": [1]]]]],
            "items": [["number": 1, "title": "History", "attachments": ["link.jpg", "folder.jpg", secret.path]]],
        ]
        try JSONSerialization.data(withJSONObject: listing).write(to: folder.appending(path: "report.json"))
        #expect(HubWindowModel.pictures(in: folder).map(\.file) == [folder.appending(path: "screen-1.jpg")])
    }

    @Test func theViewerOpensTheChatAReportWentTo() throws {
        func claim(_ chat: String, agent: String, folder: String = "", in report: URL) throws {
            try Chats.coder.encode(Claim(chat: chat, agent: agent, folder: folder, claimedAt: Date())).write(to: report.appending(path: InboxQueue.claimFile))
        }
        // What the hub saved when it delivered it, with the folder of the chat that took it.
        let sent = try report("20261004-140000", at: Date())
        try claim("claude-s-1", agent: "claude", folder: "/repo", in: sent)
        ReportDelivery.save(.init(agent: .claude, chat: "s-1", title: "Untitled session", kind: .sent), in: sent)
        let chat = try #require(HubWindowModel.chat(of: sent))
        #expect(chat.agent == .claude && chat.id == "s-1" && chat.folder == "/repo")

        // Taken before deliveries were saved: the chat that took it.
        let taken = try report("20261004-140100", at: Date())
        try claim("codex-t-1", agent: "codex", in: taken)
        let codex = try #require(HubWindowModel.chat(of: taken))
        #expect(codex.agent == .codex && codex.id == "t-1" && codex.folder == nil)

        // A chat the hub started: its ID from what the command printed.
        let started = try report("20261004-140200", at: Date())
        try claim("started-codex-20261004-140200", agent: "codex", folder: "/repo", in: started)
        try #"{"type":"thread.started","thread_id":"t-2"}"#.write(to: started.appending(path: "new-chat-output.jsonl"), atomically: true, encoding: .utf8)
        #expect(HubWindowModel.chat(of: started)?.id == "t-2")
        // It took the report before its worktree existed, and is resumed from the worktree.
        InboxQueue.moveClaim(of: started, to: "/repo-worktrees/report-1")
        #expect(HubWindowModel.chat(of: started)?.folder == "/repo-worktrees/report-1")
        #expect(HubWindowModel.chat(of: started)?.id == "t-2")

        // Waiting, or with Cursor: nothing to open.
        let waiting = try report("20261004-140300", at: Date())
        ReportDelivery.save(.init(agent: .claude, chat: nil, title: "Waiting for claude auth login", kind: .waiting), in: waiting)
        #expect(HubWindowModel.chat(of: waiting) == nil)
        let cursor = try report("20261004-140400", at: Date())
        ReportDelivery.save(.init(agent: .cursor, chat: "c-1", title: "Cursor chat", kind: .nextMessage), in: cursor)
        #expect(HubWindowModel.chat(of: cursor) == nil)
        #expect(HubWindowModel.chat(of: try report("20261004-140500", at: Date())) == nil)
    }

    @Test func theViewerOpensTheSameChatTheReportRowNames() throws {
        let ended = Process()
        ended.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try ended.run()
        ended.waitUntilExit()
        let delivered = Date(timeIntervalSince1970: 1_791_120_000)
        let later = delivered.addingTimeInterval(60)

        // The hub exited after claiming the report but before handing it over: no chat has it.
        let stranded = try report("20261004-141000", at: Date())
        try Chats.coder.encode(Claim(chat: "claude-gone", agent: "claude", folder: "/repo", claimedAt: later, handingOverIn: ended.processIdentifier))
            .write(to: stranded.appending(path: InboxQueue.claimFile))
        #expect(HubWindowModel.destination(of: stranded).waiting)
        #expect(HubWindowModel.chat(of: stranded) == nil)

        // The same, after the hub had left it waiting.
        var waiting = ReportDelivery(agent: nil, chat: nil, title: "Waiting for claude auth login", kind: .waiting)
        waiting.at = delivered
        ReportDelivery.save(waiting, in: stranded)
        #expect(HubWindowModel.destination(of: stranded).waiting)
        #expect(HubWindowModel.chat(of: stranded) == nil)

        // Left waiting, then taken by a chat: the row and the viewer both name that chat.
        let taken = try report("20261004-141100", at: Date())
        ReportDelivery.save(waiting, in: taken)
        try Chats.coder.encode(Claim(chat: "codex-t-3", agent: "codex", folder: "/repo", claimedAt: later))
            .write(to: taken.appending(path: InboxQueue.claimFile))
        #expect(!HubWindowModel.destination(of: taken).waiting)
        let chat = try #require(HubWindowModel.chat(of: taken))
        #expect(chat.agent == .codex && chat.id == "t-3" && chat.folder == "/repo")
    }

    @Test func chatsOpenInTheirAgentsAppWhenItIsInstalled() {
        #expect(Handoff.appLink(.claude, id: "c28a077b-d80c-4c2b-844e-c544401d77ec", hasClaudeApp: true, hasCodexApp: false)
            == "claude://resume?session=c28a077b-d80c-4c2b-844e-c544401d77ec")
        #expect(Handoff.appLink(.codex, id: "01a0e409-5a20", hasClaudeApp: false, hasCodexApp: true) == "codex://threads/01a0e409-5a20")
        // Without the app, a terminal resumes the chat instead.
        #expect(Handoff.appLink(.claude, id: "s-1", hasClaudeApp: false, hasCodexApp: true) == nil)
        #expect(Handoff.appLink(.codex, id: "t-1", hasClaudeApp: true, hasCodexApp: false) == nil)
        #expect(Handoff.appLink(.cursor, id: "c-1", hasClaudeApp: true, hasCodexApp: true) == nil)
    }
}
#endif
