#if REDLINE
import Foundation
import Testing
@testable import Redline

struct ReportDeliveryTests {
    private let store = ReportStore(root: FileManager.default.temporaryDirectory.appending(path: "ReportDeliveryTests-\(UUID().uuidString)"))

    /// Files one finished report and returns its id.
    private func fileReport(at seconds: TimeInterval = 1_790_000_000) throws -> String {
        try store.saveDraft([])
        let started = try store.beginReport(date: Date(timeIntervalSince1970: seconds))
        let report = Report(
            id: started.id, createdAt: Date(timeIntervalSince1970: seconds), app: Report.App(),
            device: Report.Device(model: "iPhone18,1", systemName: "iOS", systemVersion: "27.0"), screens: [], items: []
        )
        try store.finishReport(report, in: started.folder)
        return started.id
    }

    private func writeHubAddress(_ json: String) throws {
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: store.hubAddressFile)
    }

    @Test func nothingToSendIsNoOutcome() async throws {
        defer { try? FileManager.default.removeItem(at: store.root) }
        #expect(await ReportDelivery.deliver(from: store, bundleID: "com.example.app", patience: 1) == nil)
        #expect(store.lastDelivery() == nil)
    }

    @Test func withoutABundleIDNothingIsSent() async throws {
        defer { try? FileManager.default.removeItem(at: store.root) }
        _ = try fileReport()
        #expect(await ReportDelivery.deliver(from: store, bundleID: nil, patience: 1) == nil)
        #expect(store.undeliveredReports().count == 1)
    }

    @Test func withoutAHubTheReportStaysOnThePhone() async throws {
        defer { try? FileManager.default.removeItem(at: store.root) }
        let id = try fileReport()
        #expect(await ReportDelivery.deliver(from: store, bundleID: "com.example.app", patience: 1) == .noHub)
        #expect(store.lastDelivery()?.outcome == .noHub)
        #expect(store.undeliveredReports().map(\.id) == [id])
    }

    @Test func aSimulatorHubTakesReportsFromTheFolder() async throws {
        defer { try? FileManager.default.removeItem(at: store.root) }
        _ = try fileReport(at: 1_790_000_000)
        _ = try fileReport(at: 1_790_000_600)
        try writeHubAddress(#"{"device":"S","hosts":["127.0.0.1"],"port":47361,"token":"t","uploads":false}"#)
        #expect(await ReportDelivery.deliver(from: store, bundleID: "com.example.app", patience: 1) == .delivered)
        #expect(store.undeliveredReports().isEmpty)
        #expect(store.lastDelivery()?.outcome == .delivered)
    }

    @Test func theToastSaysWhereTheReportWent() {
        #expect(ReportDelivery.toast(for: .delivered, notes: "2 notes", to: "Fix the paywall") == "Sent 2 notes to Fix the paywall")
        #expect(ReportDelivery.toast(for: .delivered, notes: "1 note") == "Sent 1 note to the Mac")
        #expect(ReportDelivery.toast(for: .noHub, notes: "1 note") == "Saved 1 note on this iPhone")
        #expect(ReportDelivery.toast(for: nil, notes: "3 notes") == "Saved 3 notes on this iPhone")
        #expect(ReportDelivery.toast(for: .unreachable, notes: "1 note") == "Saved on this iPhone. Couldn't reach the Mac")
        #expect(ReportDelivery.toast(for: .refused, notes: "1 note") == "Saved on this iPhone. The Mac didn't accept it")
        #expect(ReportDelivery.toast(for: .interrupted, notes: "1 note") == "Saved on this iPhone. Sending to the Mac stopped")
    }
}
#endif
