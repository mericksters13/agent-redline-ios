#if os(macOS) && REDLINE
import Foundation
import Testing
@testable import Redline
@testable import RedlineTool

/// The kit and the Mac each declare the messages between them and the report files, in their own
/// modules.
///
/// These tests write with one side and read with the other, so the two can't drift.
struct KitContractTests {
    private let date = Date(timeIntervalSince1970: 1_791_000_000)

    /// Encodes with the kit, decodes as the Mac's type, and back.
    private func kitToMac<Kit: Encodable, Mac: Codable>(_ value: Kit, as type: Mac.Type) throws -> Mac {
        let line = try HubLink.encode(value)
        let mac = try HubMessage.decode(type, from: line.dropLast())
        // The Mac writes the same bytes back.
        #expect(HubMessage.encode(mac) == line)
        return mac
    }

    @Test func everyMessageReadsTheSameOnBothSides() throws {
        let address = HubLink.Address(
            device: "D",
            hosts: ["192.168.1.2", "mac.local"],
            port: 47361,
            token: "t",
            uploads: false
        )
        #expect(
            try kitToMac(address, as: HubMessage.Address.self)
                == HubMessage.Address(
                    device: "D",
                    hosts: ["192.168.1.2", "mac.local"],
                    port: 47361,
                    token: "t",
                    uploads: false
                )
        )
        // The other way: what the hub leaves on the phone, the kit reads.
        let left = HubMessage.Address(device: "D", hosts: ["h"], port: 1, token: "t")
        #expect(
            try HubLink.decode(HubLink.Address.self, from: HubMessage.encode(left).dropLast())
                == HubLink.Address(device: "D", hosts: ["h"], port: 1, token: "t")
        )

        let offer = HubLink.Offer(
            device: "D",
            bundleID: "com.example.app",
            token: "t",
            reports: [.init(id: "20261003-215826", finishedAt: date)]
        )
        let macOffer = try kitToMac(offer, as: HubMessage.Offer.self)
        #expect(macOffer.reports.map(\.id) == ["20261003-215826"])
        #expect(macOffer.reports.first?.finishedAt == date)

        let answer = HubMessage.Answer(want: ["a"], delivered: ["b"], refused: "why")
        #expect(
            try HubLink.decode(HubLink.Answer.self, from: HubMessage.encode(answer).dropLast())
                == HubLink.Answer(wanted: ["a"], delivered: ["b"], refused: "why")
        )

        let upload = HubLink.Upload(
            id: "r",
            files: ["report.json": Data("{}".utf8), "screen-1.jpg": Data([0xFF, 0xD8])]
        )
        #expect(try kitToMac(upload, as: HubMessage.Upload.self) == HubMessage.Upload(id: "r", files: upload.files))

        let reply = HubMessage.Reply(delivered: ["r"])
        #expect(
            try HubLink.decode(HubLink.Reply.self, from: HubMessage.encode(reply).dropLast())
                == HubLink.Reply(delivered: ["r"])
        )

        let request = HubLink.ChatsRequest(
            device: "D",
            bundleID: "com.example.app",
            token: "t",
            sourceFile: "/w/App.swift"
        )
        #expect(
            try kitToMac(request, as: HubMessage.ChatsRequest.self)
                == HubMessage.ChatsRequest(
                    kind: "chats",
                    device: "D",
                    bundleID: "com.example.app",
                    token: "t",
                    sourceFile: "/w/App.swift"
                )
        )
        // An offer is never taken for a question about chats: it has no kind.
        #expect(throws: DecodingError.self) {
            try HubMessage.decode(HubMessage.ChatsRequest.self, from: try HubLink.encode(offer).dropLast())
        }

        let list = HubMessage.ChatList(
            agents: ["claude", "codex"],
            chats: [
                HubMessage.Chat(
                    id: "s1",
                    agent: "claude",
                    title: "Let",
                    folder: "wt",
                    isSameWorktree: true,
                    lastActive: date
                )
            ],
            worktree: "wt",
            newChatBase: "main"
        )
        let kitList = try HubLink.decode(HubLink.ChatList.self, from: HubMessage.encode(list).dropLast())
        #expect(kitList.agents == ["claude", "codex"])
        #expect(
            kitList.chats == [
                HubLink.Chat(
                    id: "s1",
                    agent: "claude",
                    title: "Let",
                    folder: "wt",
                    isSameWorktree: true,
                    lastActive: date
                )
            ]
        )
        #expect(kitList.worktree == "wt" && kitList.newChatBase == "main" && kitList.refused == nil)
    }

    @Test func theKitsFoldersAreWhereTheMacLooks() {
        let store = ReportStore(root: URL(filePath: "/container/Library/Application Support/Redline"))
        #expect(store.hubAddressFile.path == "/container/" + HubMessage.addressPath)
        #expect(store.reportsDirectory.path == "/container/" + ReportFolder.path)
    }

    @Test func theMacReadsEveryFieldItUsesFromTheKitsReport() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "KitContractTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "inbox/com.example.app/20261004-120950-00000001", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in ["screen-1.jpg", "note-2.jpg"] { try Data([0xFF, 0xD8]).write(to: folder.appending(path: file)) }
        let element = ElementSnapshot(
            role: "Button",
            label: "Save",
            value: nil,
            identifier: "editor.save",
            className: nil,
            isContainer: false,
            frame: .zero
        )
        let report = Report(
            id: "20261004-120950",
            createdAt: date,
            app: .init(
                bundleID: "com.example.app",
                name: "Example",
                version: "1.0",
                build: "1",
                sourceFile: "/w/App/AppMain.swift"
            ),
            device: .init(model: "iPhone", systemName: "iOS", systemVersion: "26.0"),
            screens: [
                .init(
                    id: "s1",
                    title: "Editor",
                    viewController: nil,
                    notes: [1],
                    snapshots: [
                        .init(
                            file: "screen-1.jpg",
                            part: 1,
                            parts: 1,
                            stitchedFrom: 1,
                            isEarlierState: false,
                            notes: [1],
                            width: 10,
                            height: 20
                        )
                    ]
                )
            ],
            items: [
                .init(
                    number: 1,
                    kind: .element,
                    note: "Too small",
                    createdAt: date,
                    title: "Save",
                    element: element,
                    ancestors: [],
                    screen: "s1",
                    screenTitle: "Editor",
                    snapshot: "screen-1.jpg",
                    outline: nil,
                    attachments: []
                ),
                .init(
                    number: 2,
                    kind: .photo,
                    note: "",
                    createdAt: date,
                    title: "Photo",
                    element: nil,
                    ancestors: [],
                    screen: nil,
                    screenTitle: nil,
                    snapshot: nil,
                    outline: nil,
                    attachments: ["note-2.jpg"]
                ),
            ],
            destination: .init(agent: "codex", chat: "t-1", title: "Fix it", newChat: nil)
        )
        try ReportStore(root: root).finishReport(report, in: folder)

        let listing = try #require(ReportListing.load(from: folder))
        #expect(listing.app?.name == "Example")
        #expect(listing.app?.sourceFile == "/w/App/AppMain.swift")
        #expect(listing.destination?.agent == "codex" && listing.destination?.chat == "t-1")
        #expect(listing.screens?.first?.title == "Editor")
        #expect(listing.screens?.first?.snapshots.first?.notes == [1])
        #expect(listing.items?.first?.element?.identifier == "editor.save")
        #expect(listing.items?.last?.attachments == ["note-2.jpg"])

        // Every reader gets the whole report, not its fallback.
        #expect(ReportContent.snapshots(in: folder).map(\.lastPathComponent) == ["screen-1.jpg", "note-2.jpg"])
        #expect(HubWindowModel.snapshots(in: folder).map(\.title) == ["Editor", "Photo"])
        #expect(HubWindowModel.notes(in: folder).map(\.text) == ["Save: Too small", "Photo: No note"])
        #expect(
            Routing.destination(of: folder, bundleID: "com.example.app") { _, _ in
                HubMessage.ChatList(agents: [], chats: [])
            } == .chat(.codex, id: "t-1")
        )
        let source = ReportSource(
            kind: .phone,
            device: "D",
            deviceName: "Test iPhone",
            bundleID: "com.example.app",
            reportID: report.id,
            receivedAt: date
        )
        let text = ReportContent.text(for: InboxReport(folder: folder, source: source, claim: nil))
        #expect(text.hasPrefix("UI report from Test iPhone · Example"))
        #expect(text.contains("1. Save (Button, editor.save): Too small"))
    }

    @Test func everyReaderUsesTheSnapshotNamesTheReportGives() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "KitContractTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "inbox/com.example.app/20261004-162330-00000001", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // As the kit names them: two parts of a stitched screen, its earlier state, two photos.
        let files = (0..<5).map { _ in Report.makeSnapshotFileName() }
        for file in files { try Data([0xFF, 0xD8]).write(to: folder.appending(path: file)) }
        func snapshot(_ index: Int, part: Int, parts: Int, earlier: Bool, notes: [Int]) -> Report.Snapshot {
            Report.Snapshot(
                file: files[index],
                part: part,
                parts: parts,
                stitchedFrom: parts,
                isEarlierState: earlier,
                notes: notes,
                width: 10,
                height: 20
            )
        }
        func item(_ number: Int, file: String?, attachments: [String] = []) -> Report.Item {
            Report.Item(
                number: number,
                kind: file == nil ? .photo : .element,
                note: "Note \(number)",
                createdAt: date,
                title: "Item \(number)",
                element: nil,
                ancestors: [],
                screen: file == nil ? nil : "screen-1",
                screenTitle: file == nil ? nil : "Patterns",
                snapshot: file,
                outline: nil,
                attachments: attachments
            )
        }
        let report = Report(
            id: "20261004-162330",
            createdAt: date,
            app: .init(bundleID: "com.example.app", name: "Example", version: "1.0", build: "1"),
            device: .init(model: "iPhone", systemName: "iOS", systemVersion: "26.0"),
            screens: [
                .init(
                    id: "screen-1",
                    title: "Patterns",
                    viewController: nil,
                    notes: [1, 2, 3],
                    snapshots: [
                        snapshot(2, part: 1, parts: 1, earlier: true, notes: [3]),
                        snapshot(0, part: 1, parts: 2, earlier: false, notes: [1]),
                        snapshot(1, part: 2, parts: 2, earlier: false, notes: [2]),
                    ]
                )
            ],
            items: [
                item(1, file: files[0]),
                item(2, file: files[1]),
                item(3, file: files[2]),
                item(4, file: nil, attachments: [files[3], files[4]]),
            ]
        )
        try ReportStore(root: root).finishReport(report, in: folder)

        let source = ReportSource(
            kind: .phone,
            device: "D",
            deviceName: "Test iPhone",
            bundleID: "com.example.app",
            reportID: report.id,
            receivedAt: date
        )
        let message = ReportContent.text(for: InboxReport(folder: folder, source: source, claim: nil))
        let summary = try String(contentsOf: folder.appending(path: "report.md"), encoding: .utf8)
        let json = try String(contentsOf: folder.appending(path: "report.json"), encoding: .utf8)
        for text in [message, summary, json] {
            let named = Set(text.matches(of: /[A-Za-z0-9-]+\.jpg/).map { String($0.output) })
            #expect(named == Set(files))
        }
        let order = [files[2], files[0], files[1], files[3], files[4]]
        #expect(ReportContent.snapshots(in: folder).map(\.lastPathComponent) == order)
        #expect(HubWindowModel.snapshots(in: folder).map(\.file.lastPathComponent) == order)

        // The names say nothing, so the agent and the viewer are told which snapshot is an earlier
        // state and which is a part.
        func path(_ index: Int) -> String { folder.appending(path: files[index]).path }
        #expect(message.contains(path(2) + "\nPatterns, earlier state, before the screen changed\n3. Item 3: Note 3"))
        #expect(message.contains(path(0) + "\nPatterns, part 1 of 2\n1. Item 1: Note 1"))
        #expect(message.contains(path(1) + "\nPatterns, part 2 of 2\n2. Item 2: Note 2"))
        #expect(message.contains(path(3) + "\n" + path(4) + "\n4. Item 4: Note 4"))
        #expect(
            HubWindowModel.snapshots(in: folder).map(\.title) == [
                "Patterns, earlier state, before the screen changed", "Patterns, part 1 of 2", "Patterns, part 2 of 2",
                "Item 4", "Item 4",
            ]
        )

        // Only version 2's keys are written.
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["version"] as? Int == 2)
        let screen = try #require((object["screens"] as? [[String: Any]])?.first)
        #expect(screen["snapshots"] != nil && screen["images"] == nil)
        let item = try #require((object["items"] as? [[String: Any]])?.first)
        #expect(item["snapshot"] as? String == files[0] && item["picture"] == nil)
    }

    /// A report written before images were called snapshots, as the phone keeps it among its sent
    /// reports and as the Mac keeps it in its inbox.
    @Test func aVersionOneReportReadsOnBothSides() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "KitContractTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let phone = ReportStore(root: root.appending(path: "phone", directoryHint: .isDirectory))
        let sent = phone.reportsDirectory.appending(path: VersionOneReport.id, directoryHint: .isDirectory)
        let inbox = root.appending(path: "inbox/com.example.app/20261004-162330-00000001", directoryHint: .isDirectory)
        for folder in [sent, inbox] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(VersionOneReport.json.utf8).write(to: folder.appending(path: "report.json"))
            try Data(VersionOneReport.markdown.utf8).write(to: folder.appending(path: "report.md"))
            for file in VersionOneReport.files { try Data([0xFF, 0xD8]).write(to: folder.appending(path: file)) }
        }

        // The phone: the list of sent reports and the report as sent.
        let report = try #require(phone.sentReports().first?.report)
        #expect(report.version == nil)
        #expect(
            report.screens.map { $0.snapshots.map(\.file) } == [
                ["screen-1-earlier-1.jpg", "screen-1.jpg"], ["screen-2.jpg"],
            ]
        )
        #expect(report.screens.first?.snapshots.first?.isEarlierState == true)
        #expect(
            report.items.map(\.snapshot) == [
                "screen-1-earlier-1.jpg", "screen-1.jpg", "screen-1.jpg", "screen-2.jpg", nil,
            ]
        )
        #expect(report.items.last?.attachments == ["note-5.jpg"])
        #expect(report.contents == "5 notes, 2 screens")

        // The Mac: the panel, the report viewer and the message to the agent.
        let listing = try #require(ReportListing.load(from: inbox))
        #expect(
            listing.screens?.map { $0.snapshots.map(\.file) } == [
                ["screen-1-earlier-1.jpg", "screen-1.jpg"], ["screen-2.jpg"],
            ]
        )
        #expect(ReportContent.snapshots(in: inbox).map(\.lastPathComponent) == VersionOneReport.files)
        #expect(
            HubWindowModel.snapshots(in: inbox).map(\.title) == [
                "Patterns, earlier state, before the screen changed", "Patterns", "History", "Today",
            ]
        )
        #expect(
            HubWindowModel.snapshot(showing: 1, in: HubWindowModel.snapshots(in: inbox))?.lastPathComponent
                == "screen-1-earlier-1.jpg"
        )
        #expect(HubWindowModel.notes(in: inbox).count == 5)
        let source = ReportSource(
            kind: .phone,
            device: "D",
            deviceName: "Test iPhone",
            bundleID: "com.example.app",
            reportID: VersionOneReport.id,
            receivedAt: date
        )
        let inboxReport = InboxReport(folder: inbox, source: source, claim: nil)
        let text = ReportContent.text(for: inboxReport)
        #expect(text.hasPrefix("UI report from Test iPhone · Tiny Tally"))
        #expect(
            text.contains(
                inbox.appending(path: "screen-1-earlier-1.jpg").path
                    + "\nPatterns, earlier state, before the screen changed\n1. Weight in kg by age"
            )
        )
        #expect(text.contains(inbox.appending(path: "note-5.jpg").path + "\n5. Today: Same bug in another app"))
        let attached = ReportContent.items(for: inboxReport, budget: 1_000_000).items.compactMap { item -> String? in
            if case .image(let file, _) = item { file.lastPathComponent } else { nil }
        }
        #expect(attached == VersionOneReport.files)
    }
}
#endif
