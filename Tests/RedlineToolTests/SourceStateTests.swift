#if os(macOS)
import Foundation
import Testing
@testable import RedlineTool

struct SourceStateTests {
    @Test func everyOfferedReportIsTakenUntilTheMacHasIt() {
        var state = SourceState()
        // Sent a day before any Mac set the app up: still waiting for one.
        let old = FinishedReport(id: "20261002-135144", finishedAt: Date(timeIntervalSince1970: 1_790_943_600))
        let new = FinishedReport(id: "20261003-202235", finishedAt: Date(timeIntervalSince1970: 1_791_030_030))
        #expect(state.reportIDsToCopy(from: [old, new]) == [old.id, new.id])
        #expect(state.settledReportIDs(in: [old, new]).isEmpty)
        state.delivered.append(new.id)
        #expect(state.reportIDsToCopy(from: [old, new]) == [old.id])
        // The app can stop offering only the one the Mac has.
        #expect(state.settledReportIDs(in: [old, new]) == [new.id])
    }

    @Test func aStateSavedWithItsFirstLookStillLoads() throws {
        let saved = Data(#"{"delivered":["20261003-202235"],"since":"2026-10-03T12:00:00Z"}"#.utf8)
        #expect(try HubPaths.decoder.decode(SourceState.self, from: saved).delivered == ["20261003-202235"])
    }
}
#endif
