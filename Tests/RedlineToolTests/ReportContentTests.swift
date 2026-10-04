#if os(macOS)
import Foundation
import Testing
@testable import RedlineTool

struct ReportContentTests {
    private let temporary = TemporaryFolder("ReportContentTests")
    private var root: URL { temporary.url }
    private var paths: HubPaths { HubPaths(root: root.appending(path: "hub-root", directoryHint: .isDirectory)) }

    /// A report in the inbox with a screen picture and one attached to a note, `pictureBytes` each.
    @discardableResult
    private func inboxReport(_ id: String, bundleID: String = "com.example.app", pictureBytes: Int = 10) throws -> URL {
        let listing: [String: Any] = [
            "screens": [["images": [["file": "screen-1.jpg"]]]],
            "items": [["attachments": [String]()], ["attachments": ["note-2.jpg"]]],
        ]
        return try fileInboxReport(
            "\(id)-00000001",
            bundleID: bundleID,
            in: paths,
            listing: listing,
            pictures: [
                "screen-1.jpg": Data(repeating: 0xFF, count: pictureBytes),
                "note-2.jpg": Data(repeating: 0xD8, count: pictureBytes),
            ],
            summary: "# UI report: Example\n\n1. **Milk stash**: Test.\n",
            receivedAt: Date(timeIntervalSince1970: 1_791_000_000)
        )
    }

    @Test func aReportReadsAsPicturesAndTheirNotes() throws {
        let report = paths.inbox.appending(
            path: "com.example.app/20261004-120950-00000001",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: report, withIntermediateDirectories: true)
        let listing: [String: Any] = [
            "app": ["name": "Example", "version": "1.0.9", "build": "41"],
            "screens": [
                ["images": [["file": "screen-1.jpg", "notes": [1]]]],
                ["images": [["file": "screen-2.jpg", "notes": [3]]]],
            ],
            "items": [
                [
                    "number": 1, "title": "Log milestone", "note": "This is ugly", "attachments": [String](),
                    "element": ["identifier": "today.milestones", "label": "Log milestone", "role": "Button"],
                ],
                ["number": 2, "title": "History", "note": "The list breaks", "attachments": ["note-2.jpg"]],
                [
                    "number": 3, "title": "growth.card", "note": "", "attachments": [String](),
                    "element": ["identifier": "growth.card", "role": "Group"],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: listing).write(to: report.appending(path: "report.json"))
        let source = ReportSource(
            kind: .phone,
            device: "D",
            deviceName: "Test iPhone",
            bundleID: "com.example.app",
            reportID: "20261004-120950",
            receivedAt: .now
        )
        let text = ReportContent.text(for: InboxReport(folder: report, source: source, claim: nil))
        #expect(
            text == """
                UI report from Test iPhone · Example

                \(report.path)/screen-1.jpg
                1. Log milestone (Button, today.milestones): This is ugly

                \(report.path)/screen-2.jpg
                3. growth.card (Group): No note

                \(report.path)/note-2.jpg
                2. History: The list breaks
                """
        )
    }

    @Test func picturesFollowTheSummaryInItsOrderWithinTheBudget() throws {
        let folder = try inboxReport("20261003-223449", pictureBytes: 600)
        #expect(ReportContent.pictures(in: folder).map(\.lastPathComponent) == ["screen-1.jpg", "note-2.jpg"])
        let report = try #require(Inbox.reports(for: ["com.example.app"], paths: paths).first)
        let content = ReportContent.items(for: report, budget: 1_000)
        // The summary, then the first picture; the second doesn't fit and is named by path.
        #expect(content.bytes == 600)
        guard case .text(let summary) = content.items[0] else {
            Issue.record("No summary first")
            return
        }
        #expect(summary.contains("from Test iPhone (iPhone)"))
        #expect(summary.contains("1. **Milk stash**: Test."))
        #expect(
            content.items.contains {
                if case .image(let file, _) = $0 { file.lastPathComponent == "screen-1.jpg" } else { false }
            }
        )
        #expect(
            content.items.contains {
                if case .text(let text) = $0 { text.contains("note-2.jpg isn't attached") } else { false }
            }
        )
    }
}
#endif
