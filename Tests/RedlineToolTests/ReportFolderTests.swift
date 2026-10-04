#if os(macOS)
import Foundation
import Testing
@testable import RedlineTool

struct ReportFolderTests {
    @Test func onlyFinishedReportsAreCopied() {
        let at = Date(timeIntervalSince1970: 1_791_030_000)
        let entries: [(path: String, modified: Date?)] = [
            ("20261003-150846", at), ("20261003-150846/report.json", at), ("20261003-150846/screen-1.jpg", at),
            // Still being drawn: its draft hasn't been removed yet.
            ("20261003-202235", at), ("20261003-202235/report.json", at), ("20261003-202235/draft", at),
            // Just started: no report.json yet.
            ("20261003-202300", at), ("20261003-202300/draft/annotations.json", at),
        ]
        #expect(ReportFolder.finishedReports(in: entries) == [FinishedReport(id: "20261003-150846", finishedAt: at)])
    }

    @Test func aSimulatorReportIsFoundFromAnyFileInIt() {
        let container =
            "/Users/me/Library/Developer/CoreSimulator/Devices/198F6C2F-B757-44A8-88BB-A574EC16F621/data/Containers/Data/Application/17364006-587A-45B0-86EC-941E51A550D1"
        let path = container + "/Library/Application Support/Redline/reports/20261003-151826/report.md"
        #expect(
            SimulatorReportPath.parse(path)
                == SimulatorReportPath(
                    container: container,
                    device: "198F6C2F-B757-44A8-88BB-A574EC16F621",
                    reportID: "20261003-151826"
                )
        )
        #expect(SimulatorReportPath.parse(container + "/Library/Caches/whatever") == nil)
    }
}
#endif
