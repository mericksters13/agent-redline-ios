#if os(macOS)
import Foundation
import Testing
@testable import AgenticDebuggingTool

struct ReportSourcesTests {
    @Test func messagesMatchTheKitsExactly() {
        // The kit writes exactly this line; see the kit's ReportStoreTests.
        let line = #"{"bundleID":"com.example.app","device":"00008150-00123C360CF3C01C","reports":[{"finishedAt":"2026-10-03T04:00:00Z","id":"20261003-215826"}]}"#
        let offer = HubMessage.decode(HubMessage.Offer.self, from: Data(line.utf8))
        #expect(offer == HubMessage.Offer(device: "00008150-00123C360CF3C01C", bundleID: "com.example.app",
                                          reports: [.init(id: "20261003-215826", finishedAt: Date(timeIntervalSince1970: 1_791_000_000))]))
        #expect(String(decoding: HubMessage.encode(HubMessage.Reply(delivered: ["20261003-215826"])), as: UTF8.self) == #"{"delivered":["20261003-215826"]}"# + "\n")
    }

    @Test func onlyFinishedReportsAreCopied() {
        let at = Date(timeIntervalSince1970: 1_791_030_000)
        let entries: [(path: String, modified: Date?)] = [
            ("20261003-150846", at), ("20261003-150846/report.json", at), ("20261003-150846/screen-1.jpg", at),
            // Still being drawn: its draft hasn't been removed yet.
            ("20261003-202235", at), ("20261003-202235/report.json", at), ("20261003-202235/draft", at),
            // Just started: no report.json yet.
            ("20261003-202300", at), ("20261003-202300/draft/annotations.json", at),
        ]
        #expect(ReportFolder.finished(in: entries) == [FinishedReport(id: "20261003-150846", finishedAt: at)])
    }

    @Test func reportsFromBeforeTheHubFirstLookedStayOnThePhone() {
        let since = Date(timeIntervalSince1970: 1_791_030_000)
        var state = SourceState(since: since)
        let old = FinishedReport(id: "20261002-135144", finishedAt: since.addingTimeInterval(-86_400))
        let new = FinishedReport(id: "20261003-202235", finishedAt: since.addingTimeInterval(30))
        #expect(state.toCopy(from: [old, new]) == ["20261003-202235"])
        state.delivered.append("20261003-202235")
        #expect(state.toCopy(from: [old, new]).isEmpty)
        // The app can stop offering both: one is on the Mac, the other is from before.
        #expect(state.settled([old, new]) == ["20261002-135144", "20261003-202235"])
    }

    @Test func aSimulatorReportIsFoundFromAnyFileInIt() {
        let container = "/Users/me/Library/Developer/CoreSimulator/Devices/198F6C2F-B757-44A8-88BB-A574EC16F621/data/Containers/Data/Application/17364006-587A-45B0-86EC-941E51A550D1"
        let path = container + "/Library/Application Support/iOSAgenticDebuggingKit/reports/20261003-151826/report.md"
        #expect(SimulatorReportPath.parse(path) == SimulatorReportPath(container: container, device: "198F6C2F-B757-44A8-88BB-A574EC16F621", reportID: "20261003-151826"))
        #expect(SimulatorReportPath.parse(container + "/Library/Caches/whatever") == nil)
    }

    @Test func inboxFoldersSortByTimeAndKeepPhonesApart() {
        // Two iPhones of one model share the start of their UDID, so the end tells them apart.
        #expect(Inbox.folderName(reportID: "20261003-202235", device: "00008150-00123C360CF3C01C") == "20261003-202235-0CF3C01C")
        #expect(Inbox.folderName(reportID: "20261003-202235", device: "00008150-001018CE3C0B001C") == "20261003-202235-3C0B001C")
    }
}
#endif
