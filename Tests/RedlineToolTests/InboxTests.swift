#if os(macOS)
import Foundation
import Testing
@testable import RedlineTool

struct InboxTests {
    private let temporary = TemporaryFolder("InboxTests")
    private var root: URL { temporary.url }
    private var paths: HubPaths { HubPaths(root: root.appending(path: "hub-root", directoryHint: .isDirectory)) }

    /// A report in the inbox with one note, addressed to `recipient` when given.
    private func inboxReport(_ id: String, recipient: ReportRecipient? = nil) throws -> URL {
        let item: [String: Any] = [
            "number": 1, "title": "Save", "note": "Too small.", "attachments": [String](),
            "element": ["identifier": "editor.save", "label": "Save", "role": "Button"],
        ]
        let listing: [String: Any] = [
            "app": ["name": "Example"], "screens": [["images": [["file": "screen-1.jpg", "notes": [1]]]]],
            "items": [item],
        ]
        return try fileInboxReport(
            id,
            in: paths,
            listing: listing,
            summary: "1. **Save**: Too small.\n",
            recipient: recipient
        )
    }

    @Test func aClaimThatCantBeReadStillCountsAsTaken() throws {
        let folder = try inboxReport("20261004-120200")
        try Data("{\"chat\":\"cod".utf8).write(to: folder.appending(path: Inbox.claimFile))
        #expect(Inbox.unclaimedReports(for: ["com.example.app"], paths: paths).isEmpty)
        let chat = ChatRecord(
            id: "codex-A",
            agent: "codex",
            folder: "/w",
            bundleIDs: ["com.example.app"],
            pid: getpid(),
            registeredAt: .now,
            lastActiveAt: .now
        )
        let report = try #require(Inbox.reports(for: ["com.example.app"], paths: paths).first)
        guard case .takenByAnotherChat = Inbox.claim(report, for: chat) else {
            Issue.record("A second claim should find the first")
            return
        }
    }

    @Test func onlyTheAddressedChatTakesAReport() throws {
        let folder = root.appending(path: "App", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let builder = ChatSession(
            paths: paths,
            folder: folder,
            extraApps: ["com.example.app"],
            agent: "codex",
            id: "codex-A",
            startsHub: false
        )
        let other = ChatSession(
            paths: paths,
            folder: folder,
            extraApps: ["com.example.app"],
            agent: "codex",
            id: "codex-B",
            startsHub: false
        )
        let report = try inboxReport(
            "20261004-120000",
            recipient: ReportRecipient(chat: "codex-A", agent: "codex", folder: folder.path)
        )
        _ = try inboxReport("20261004-120100")

        // Another chat on the same app gets nothing, and an unaddressed report goes to no one.
        #expect(other.takeAddressed() == nil)
        let text = try #require(builder.takeAddressed())
        #expect(text.contains("1. Save (Button, editor.save): Too small."))
        #expect(text.contains(report.appending(path: "screen-1.jpg").path))
        #expect(builder.takeAddressed() == nil)
    }

    @Test func inboxFoldersSortByTimeAndKeepPhonesApart() {
        // Two iPhones of one model share the start of their UDID, so the end tells them apart.
        #expect(
            Inbox.folderName(reportID: "20261003-202235", device: "00000000-0000000000000001")
                == "20261003-202235-00000001"
        )
        #expect(
            Inbox.folderName(reportID: "20261003-202235", device: "00000000-0000000000000002")
                == "20261003-202235-00000002"
        )
    }
}
#endif
