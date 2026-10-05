#if os(macOS)
import Foundation
import XCTest
@testable import RedlineTool

/// The panel reads the inbox every two seconds while it's open, and chats scan it on every
/// hook and wait: these measure both on an inbox of 500 reports.
final class InboxPerformanceTests: XCTestCase {
    private var temporary: TemporaryFolder!
    private var paths: HubPaths { HubPaths(root: temporary.url) }

    override func setUpWithError() throws {
        temporary = TemporaryFolder("InboxPerformanceTests")
        let listing: [String: Any] = [
            "app": ["name": "Example"],
            "screens": [["title": "Editor", "images": [["file": "screen-1.jpg", "notes": [1, 2]]]]],
            "items": [
                [
                    "number": 1, "title": "Save", "note": "Too small", "attachments": [String](),
                    "element": ["label": "Save", "role": "Button"],
                ],
                ["number": 2, "title": "Cancel", "note": "", "attachments": [String]()],
            ],
        ]
        let start = Date(timeIntervalSince1970: 1_791_000_000)
        for index in 0..<500 {
            try fileInboxReport(
                String(format: "20261004-%06d-00000001", index),
                in: paths,
                listing: listing,
                snapshots: ["screen-1.jpg": Data(repeating: 0xFF, count: 100_000)],
                receivedAt: start.addingTimeInterval(Double(index))
            )
        }
    }

    override func tearDown() {
        temporary = nil
    }

    func testReadingTheNewestReportsForThePanel() {
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            XCTAssertEqual(HubWindowModel.readReports(paths: paths).rows.count, 30)
        }
    }

    func testScanningForUnclaimedReports() {
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            XCTAssertEqual(Inbox.unclaimedReports(for: ["com.example.app"], paths: paths).count, 500)
        }
    }
}
#endif
