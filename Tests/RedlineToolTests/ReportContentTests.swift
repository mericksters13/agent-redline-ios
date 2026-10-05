#if os(macOS)
import Foundation
import Testing
@testable import RedlineTool

struct ReportContentTests {
    private let temporary = TemporaryFolder("ReportContentTests")
    private var root: URL { temporary.url }
    private var paths: HubPaths { HubPaths(root: root.appending(path: "hub-root", directoryHint: .isDirectory)) }

    /// A report in the inbox with a screen snapshot and one attached to a note, `snapshotBytes` each.
    @discardableResult
    private func inboxReport(_ id: String, bundleID: String = "com.example.app", snapshotBytes: Int = 10) throws -> URL
    {
        let listing: [String: Any] = [
            "screens": [["images": [["file": "screen-1.jpg"]]]],
            "items": [["attachments": [String]()], ["attachments": ["note-2.jpg"]]],
        ]
        return try fileInboxReport(
            "\(id)-00000001",
            bundleID: bundleID,
            in: paths,
            listing: listing,
            snapshots: [
                "screen-1.jpg": Data(repeating: 0xFF, count: snapshotBytes),
                "note-2.jpg": Data(repeating: 0xD8, count: snapshotBytes),
            ],
            summary: "# UI report: Example\n\n1. **Milk stash**: Test.\n",
            receivedAt: Date(timeIntervalSince1970: 1_791_000_000)
        )
    }

    @Test func aReportReadsAsSnapshotsAndTheirNotes() throws {
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
                    "picture": "screen-1.jpg",
                    "element": ["identifier": "today.milestones", "label": "Log milestone", "role": "Button"],
                    // Unnamed holders are left out.
                    "ancestors": [
                        ["role": "Group"], ["identifier": "today.card", "label": "Milestones", "role": "Group"],
                    ],
                ],
                ["number": 2, "title": "History", "note": "The list breaks", "attachments": ["note-2.jpg"]],
                [
                    "number": 3, "title": "growth.card", "note": "", "attachments": [String](),
                    "element": ["identifier": "growth.card", "role": "Group"],
                ],
                // An element note made before notes on one screen shared its picture keeps its own.
                [
                    "number": 4, "title": "Save", "note": "Too small", "attachments": [String](),
                    "picture": "note-4.jpg", "element": ["label": "Save", "role": "Button"],
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
                1. Log milestone (Button, today.milestones), in Group "Milestones" (today.card): This is ugly

                \(report.path)/screen-2.jpg
                3. growth.card (Group): No note

                \(report.path)/note-2.jpg
                2. History: The list breaks

                \(report.path)/note-4.jpg
                4. Save (Button): Too small
                """
        )
        for file in ["screen-1.jpg", "screen-2.jpg", "note-2.jpg", "note-4.jpg"] {
            FileManager.default.createFile(atPath: report.appending(path: file).path, contents: Data([0xFF]))
        }
        #expect(
            ReportContent.snapshots(in: report).map(\.lastPathComponent) == [
                "screen-1.jpg", "screen-2.jpg", "note-2.jpg", "note-4.jpg",
            ]
        )

        // A long pasted note is cut, so the text fits in a command's arguments; report.md has the rest.
        var long = listing
        long["items"] = [
            [
                "number": 1, "title": "Log milestone", "note": String(repeating: "pasted ", count: 20_000),
                "attachments": [String](),
            ]
        ]
        try JSONSerialization.data(withJSONObject: long).write(to: report.appending(path: "report.json"))
        let cut = ReportContent.text(for: InboxReport(folder: report, source: source, claim: nil))
        #expect(cut.utf8.count <= ReportContent.longestText)
        #expect(cut.hasSuffix("The rest is in \(report.path)/report.md."))
    }

    @Test func onlySnapshotsInTheReportsOwnFolderAreRead() throws {
        let folder = try inboxReport("20261003-223449")
        let secret = root.appending(path: "secret.txt")
        try "private".write(to: secret, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "link.jpg"), withDestinationURL: secret)
        try FileManager.default.createDirectory(
            at: folder.appending(path: "folder.jpg"),
            withIntermediateDirectories: true
        )
        let escape = "../../../../secret.txt"
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: escape).path))
        try
            #"{"screens":[{"images":[{"file":"\#(escape)"},{"file":"screen-1.jpg"}]}],"items":[{"attachments":["link.jpg","folder.jpg","\#(secret.path)"]}]}"#
            .write(to: folder.appending(path: "report.json"), atomically: true, encoding: .utf8)
        #expect(ReportContent.snapshots(in: folder).map(\.lastPathComponent) == ["screen-1.jpg"])
    }

    @Test func snapshotsFollowTheSummaryInItsOrderWithinTheBudget() throws {
        let folder = try inboxReport("20261003-223449", snapshotBytes: 600)
        #expect(ReportContent.snapshots(in: folder).map(\.lastPathComponent) == ["screen-1.jpg", "note-2.jpg"])
        let report = try #require(Inbox.reports(for: ["com.example.app"], paths: paths).first)
        let content = ReportContent.items(for: report, budget: 1_200)
        // The summary, then the first snapshot; the second doesn't fit and is named by path.
        guard case .text(let summary) = content.items[0] else {
            Issue.record("No summary first")
            return
        }
        #expect(content.bytes == summary.utf8.count + 600)
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

    @Test func aLongPastedNoteIsCutToTheLongestText() throws {
        let folder = try inboxReport("20261003-223449")
        try ("# UI report\n\n1. **Log**: " + String(repeating: "é", count: 200_000)).write(
            to: folder.appending(path: "report.md"),
            atomically: true,
            encoding: .utf8
        )
        let report = try #require(Inbox.reports(for: ["com.example.app"], paths: paths).first)
        let content = ReportContent.items(for: report, budget: 700_000)
        guard case .text(let summary) = content.items[0] else {
            Issue.record("No summary first")
            return
        }
        #expect(summary.utf8.count <= ReportContent.longestText)
        #expect(summary.hasSuffix("The rest is in \(folder.path)/report.md."))
        // The text counts toward the budget, with both snapshots.
        #expect(content.bytes == summary.utf8.count + 20)
    }
}
#endif
