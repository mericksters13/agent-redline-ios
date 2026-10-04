#if os(macOS)
import Foundation
import Testing
@testable import RedlineTool

struct ReportSourcesTests {
    @Test func messagesMatchTheKitsExactly() {
        // The kit writes exactly these lines; see the kit's ReportStoreTests.
        let line = #"{"bundleID":"com.example.app","device":"00008150-00123C360CF3C01C","reports":[{"finishedAt":"2026-10-03T04:00:00Z","id":"20261003-215826"}],"token":"secret"}"#
        #expect(HubMessage.decode(HubMessage.Offer.self, from: Data(line.utf8)) == HubMessage.Offer(
            device: "00008150-00123C360CF3C01C", bundleID: "com.example.app", token: "secret",
            reports: [.init(id: "20261003-215826", finishedAt: Date(timeIntervalSince1970: 1_791_000_000))]))
        #expect(String(decoding: HubMessage.encode(HubMessage.Answer(want: ["20261003-215826"], delivered: [])), as: UTF8.self)
                == #"{"delivered":[],"want":["20261003-215826"]}"# + "\n")
        #expect(HubMessage.decode(HubMessage.Upload.self, from: Data(#"{"files":{"report.md":"IyBIaQ=="},"id":"r"}"#.utf8))
                == HubMessage.Upload(id: "r", files: ["report.md": Data("# Hi".utf8)]))
        let ask = #"{"bundleID":"com.example.app","device":"D","kind":"chats","sourceFile":"/w/App.swift","token":"secret"}"#
        #expect(HubMessage.decode(HubMessage.ChatsRequest.self, from: Data(ask.utf8))
                == HubMessage.ChatsRequest(kind: "chats", device: "D", bundleID: "com.example.app", token: "secret", sourceFile: "/w/App.swift"))
        // An offer isn't taken for a question about chats.
        #expect(HubMessage.decode(HubMessage.ChatsRequest.self, from: Data(line.utf8)) == nil)
        let list = HubMessage.ChatList(agents: ["claude"], chats: [HubMessage.Chat(id: "s1", agent: "claude", title: "Let", folder: "wt",
                                                                                 sameWorktree: true, lastActive: Date(timeIntervalSince1970: 1_791_000_000))], worktree: "wt")
        #expect(String(decoding: HubMessage.encode(list), as: UTF8.self) == #"{"agents":["claude"],"chats":[{"agent":"claude","folder":"wt","id":"s1","lastActive":"2026-10-03T04:00:00Z","sameWorktree":true,"title":"Let"}],"worktree":"wt"}"# + "\n")
    }

    @Test func onlyFinishedReportsAreCopied() {
        let at = Date(timeIntervalSince1970: 1_791_030_000)
        let entries: [(path: String, modified: Date?)] = [
            ("20261003-150846", at), ("20261003-150846/report.json", at), ("20261003-150846/screen-1.jpg", at),
            // Still being drawn: its draft hasn't been removed yet.
            ("20261003-202235", at), ("20261003-202235/report.json", at), ("20261003-202235/draft", at),
            // Just started: no report.json yet.
            ("20261003-202300", at), ("20261003-202300/draft/annotations.json", at),
            // Already on a Mac.
            ("20261002-135144", at), ("20261002-135144/report.json", at), ("20261002-135144/delivered", at),
        ]
        #expect(ReportFolder.finished(in: entries) == [FinishedReport(id: "20261003-150846", finishedAt: at)])
    }

    @Test func reportsAreSettledOnlyOnceCopied() {
        var state = SourceState()
        let old = FinishedReport(id: "20261002-135144", finishedAt: Date(timeIntervalSince1970: 1_791_030_000))
        let new = FinishedReport(id: "20261003-202235", finishedAt: Date(timeIntervalSince1970: 1_791_116_430))
        // However old, a report the app offers is one the Mac doesn't have yet.
        #expect(state.toCopy(from: [old, new]) == ["20261002-135144", "20261003-202235"])
        #expect(state.settled([old, new]).isEmpty)
        state.delivered.append("20261003-202235")
        #expect(state.toCopy(from: [old, new]) == ["20261002-135144"])
        #expect(state.settled([old, new]) == ["20261003-202235"])
    }

    @Test func aSimulatorReportIsFoundFromAnyFileInIt() {
        let container = "/Users/me/Library/Developer/CoreSimulator/Devices/198F6C2F-B757-44A8-88BB-A574EC16F621/data/Containers/Data/Application/17364006-587A-45B0-86EC-941E51A550D1"
        let path = container + "/Library/Application Support/Redline/reports/20261003-151826/report.md"
        #expect(SimulatorReportPath.parse(path) == SimulatorReportPath(container: container, device: "198F6C2F-B757-44A8-88BB-A574EC16F621", reportID: "20261003-151826"))
        #expect(SimulatorReportPath.parse(container + "/Library/Caches/whatever") == nil)
        // A build from before the rename keeps its reports under the old name.
        let earlier = container + "/Library/Application Support/iOSAgenticDebuggingKit/reports/20261003-151826/report.md"
        #expect(SimulatorReportPath.parse(earlier) == SimulatorReportPath(container: container, device: "198F6C2F-B757-44A8-88BB-A574EC16F621",
                                                                           reportID: "20261003-151826", folder: ReportFolder.earlierPath))
    }

    @Test func aSimulatorAppsKitFoldersAreWatchedUnderEitherName() throws {
        let files = FileManager.default
        let container = files.temporaryDirectory.appending(path: "ReportSourcesTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? files.removeItem(at: container) }
        let support = container.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        try files.createDirectory(at: container, withIntermediateDirectories: true)
        // Until the kit has written anything, the whole container.
        #expect(SimulatorWatcher.roots(for: [container.path]) == [container.path])
        // A build from before the rename, still running after the Mac tool is updated, while
        // the hub has left its address under the new name.
        try files.createDirectory(at: support.appending(path: "iOSAgenticDebuggingKit/reports"), withIntermediateDirectories: true)
        try files.createDirectory(at: support.appending(path: "Redline"), withIntermediateDirectories: true)
        #expect(SimulatorWatcher.roots(for: [container.path]) == [container.path + "/Library/Application Support/Redline",
                                                                  container.path + "/Library/Application Support/iOSAgenticDebuggingKit"].sorted())
    }

    @Test func inboxFoldersSortByTimeAndKeepPhonesApart() {
        // Two iPhones of one model share the start of their UDID, so the end tells them apart.
        #expect(Inbox.folderName(reportID: "20261003-202235", device: "00008150-00123C360CF3C01C") == "20261003-202235-0CF3C01C")
        #expect(Inbox.folderName(reportID: "20261003-202235", device: "00008150-001018CE3C0B001C") == "20261003-202235-3C0B001C")
    }
}
#endif
