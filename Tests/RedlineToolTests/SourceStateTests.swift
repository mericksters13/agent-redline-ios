#if os(macOS)
import Foundation
import Testing
@testable import RedlineTool

struct SourceStateTests {
    @Test func reportsFromBeforeTheHubFirstLookedStayOnThePhone() {
        let since = Date(timeIntervalSince1970: 1_791_030_000)
        var state = SourceState(since: since)
        let old = FinishedReport(id: "20261002-135144", finishedAt: since.addingTimeInterval(-86_400))
        let new = FinishedReport(id: "20261003-202235", finishedAt: since.addingTimeInterval(30))
        #expect(state.reportIDsToCopy(from: [old, new]) == ["20261003-202235"])
        state.delivered.append("20261003-202235")
        #expect(state.reportIDsToCopy(from: [old, new]).isEmpty)
        // The app can stop offering both: one is on the Mac, the other is from before.
        #expect(state.settledReportIDs(in: [old, new]) == ["20261002-135144", "20261003-202235"])
    }
}
#endif
