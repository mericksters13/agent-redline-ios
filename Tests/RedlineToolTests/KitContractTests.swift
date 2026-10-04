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
                    images: [
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
                    picture: "screen-1.jpg",
                    outline: nil,
                    attachments: []
                ),
                .init(
                    number: 2,
                    kind: .photo,
                    note: "",
                    createdAt: date,
                    title: "Image from Photos",
                    element: nil,
                    ancestors: [],
                    screen: nil,
                    screenTitle: nil,
                    picture: nil,
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
        #expect(listing.screens?.first?.images.first?.notes == [1])
        #expect(listing.items?.first?.element?.identifier == "editor.save")
        #expect(listing.items?.last?.attachments == ["note-2.jpg"])

        // Every reader gets the whole report, not its fallback.
        #expect(ReportContent.pictures(in: folder).map(\.lastPathComponent) == ["screen-1.jpg", "note-2.jpg"])
        #expect(HubWindowModel.pictures(in: folder).map(\.title) == ["Editor", "Image from Photos"])
        #expect(HubWindowModel.notes(in: folder).map(\.text) == ["Save: Too small", "Image from Photos: No note"])
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
    @Test func everyReaderUsesTheImageNamesTheReportGives() throws {
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
        func image(_ index: Int, part: Int, parts: Int, earlier: Bool, notes: [Int]) -> Report.Picture {
            Report.Picture(
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
                picture: file,
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
                    images: [
                        image(2, part: 1, parts: 1, earlier: true, notes: [3]),
                        image(0, part: 1, parts: 2, earlier: false, notes: [1]),
                        image(1, part: 2, parts: 2, earlier: false, notes: [2]),
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
        #expect(ReportContent.pictures(in: folder).map(\.lastPathComponent) == order)
        #expect(HubWindowModel.pictures(in: folder).map(\.file.lastPathComponent) == order)
    }
}
#endif
