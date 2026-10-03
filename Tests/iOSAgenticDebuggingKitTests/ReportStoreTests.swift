#if AGENTIC_DEBUGGING
import Foundation
import Testing
@testable import iOSAgenticDebuggingKit

struct ReportStoreTests {
    private let store = ReportStore(root: FileManager.default.temporaryDirectory.appending(path: "ReportStoreTests-\(UUID().uuidString)"))

    private func annotation(_ note: String) -> Annotation {
        let id = UUID()
        return Annotation(
            id: id,
            createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            note: note,
            kind: .element,
            element: ElementSnapshot(role: "Button", label: "Save", value: nil, identifier: "save", className: nil, isContainer: false, frame: CGRect(x: 1, y: 2, width: 3, height: 4)),
            ancestors: [],
            screen: ScreenInfo(title: "Settings", viewController: "SettingsController"),
            screenshots: ["\(id.uuidString).png"]
        )
    }

    private func photos(_ note: String, count: Int) -> Annotation {
        Annotation(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_790_000_100),
            note: note,
            kind: .photo,
            element: nil,
            ancestors: [],
            screen: nil,
            screenshots: (0..<count).map { _ in "\(UUID().uuidString).jpg" }
        )
    }

    @Test func draftSurvivesAReload() throws {
        let annotations = [annotation("Cut off"), annotation("Wrong color")]
        try store.saveDraft(annotations)
        #expect(store.loadDraft() == annotations)
    }

    @Test func notesAndAttachmentsMixInOneDraft() throws {
        let items = [annotation("Cut off"), photos("Flickers between these", count: 3), annotation("Wrong color")]
        try store.saveDraft(items)
        let loaded = store.loadDraft()
        #expect(loaded == items)
        #expect(loaded.map(\.kind) == [.element, .photo, .element])
        #expect(loaded[1].element == nil)
        #expect(loaded[1].screenshots.count == 3)
    }

    @Test func aDraftSavedBeforeAttachmentsStillLoads() throws {
        let legacy = """
        [{"id":"8FAD57B3-BD1A-4853-B238-DB8A7A6ED1AC","createdAt":"2026-10-02T23:59:39Z","note":"Date wraps badly",
          "element":{"role":"Button","label":"Use next","identifier":"milk.home.urgency","isContainer":false,"frame":[[20,468],[362,74]]},
          "ancestors":[],"screen":{"title":"Today","viewController":"NavigationStackHostingController"},
          "screenshot":"8FAD57B3-BD1A-4853-B238-DB8A7A6ED1AC.png"}]
        """
        try FileManager.default.createDirectory(at: store.draftDirectory, withIntermediateDirectories: true)
        try Data(legacy.utf8).write(to: store.draftDirectory.appending(path: "annotations.json"))
        let loaded = store.loadDraft()
        #expect(loaded.count == 1)
        #expect(loaded.first?.kind == .element)
        #expect(loaded.first?.element?.identifier == "milk.home.urgency")
        #expect(loaded.first?.screen?.title == "Today")
        #expect(loaded.first?.screenshots == ["8FAD57B3-BD1A-4853-B238-DB8A7A6ED1AC.png"])
    }

    @Test func missingDraftIsEmpty() {
        #expect(store.loadDraft().isEmpty)
    }

    @Test func aReportTakesTheWholeDraftAndLeavesAFreshOne() throws {
        let items = [annotation("Cut off"), photos("Same bug on another screen", count: 2)]
        for name in items.flatMap(\.screenshots) {
            try store.saveScreenshot(Data([1, 2, 3]), named: name)
        }
        try store.saveDraft(items)

        let started = try store.beginReport(date: Date(timeIntervalSince1970: 1_790_000_000))
        #expect(store.loadDraft().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.draftDirectory.path))
        for name in items.flatMap(\.screenshots) {
            #expect(FileManager.default.fileExists(atPath: started.draft.appending(path: name).path))
        }

        // A second report in the same second gets its own folder.
        try store.saveDraft([annotation("Later")])
        let second = try store.beginReport(date: Date(timeIntervalSince1970: 1_790_000_000))
        #expect(second.id != started.id)

        try store.finishReport(sampleReport(id: started.id), in: started.folder)
        #expect(FileManager.default.fileExists(atPath: started.folder.appending(path: "report.json").path))
        #expect(FileManager.default.fileExists(atPath: started.folder.appending(path: "report.md").path))
        #expect(!FileManager.default.fileExists(atPath: started.draft.path))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(Report.self, from: Data(contentsOf: started.folder.appending(path: "report.json")))
        #expect(report.screens.first?.images.first?.notes == [1, 2])
        #expect(report.items.first?.picture == "screen-1.jpg")
    }

    @Test func screensSurviveAReload() throws {
        let capture = Capture(id: UUID(), file: "capture.png", size: CGSize(width: 402, height: 874), scroll: nil, elements: [], group: 0)
        let screens = [ScreenRecord(id: UUID(), info: ScreenInfo(title: "Today", viewController: "Home"), captures: [capture])]
        try store.saveScreens(screens)
        #expect(store.loadScreens() == screens)
    }

    @Test func sentReportsAreListedNewestFirst() throws {
        for (id, seconds) in [("older", 1_790_000_000.0), ("newer", 1_790_000_600.0)] {
            try store.saveDraft([annotation(id)])
            let started = try store.beginReport(date: Date(timeIntervalSince1970: seconds))
            var report = sampleReport(id: id)
            report.createdAt = Date(timeIntervalSince1970: seconds)
            try store.finishReport(report, in: started.folder)
        }
        // Still being drawn: no report.json yet.
        try store.saveDraft([annotation("In progress")])
        _ = try store.beginReport(date: Date(timeIntervalSince1970: 1_790_001_000))
        // Saved before reports listed their screens.
        let old = store.reportsDirectory.appending(path: "20261002-135144")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data(#"{"id":"20261002-135144","annotations":[]}"#.utf8).write(to: old.appending(path: "report.json"))

        let sent = store.sentReports()
        #expect(sent.map(\.id) == ["newer", "older"])
        #expect(FileManager.default.fileExists(atPath: sent[0].folder.appending(path: "report.json").path))
    }

    @Test func reportsAreOfferedUntilTheMacHasThem() throws {
        var ids: [String] = []
        for seconds in [1_790_000_000.0, 1_790_000_600.0] {
            try store.saveDraft([annotation("Cut off")])
            let started = try store.beginReport(date: Date(timeIntervalSince1970: seconds))
            var report = sampleReport(id: started.id)
            report.createdAt = Date(timeIntervalSince1970: seconds)
            try store.finishReport(report, in: started.folder)
            ids.append(started.id)
        }
        // Oldest first, named by folder.
        #expect(store.undeliveredReports().map(\.id) == ids)
        #expect(store.undeliveredReports().first?.finishedAt == Date(timeIntervalSince1970: 1_790_000_000))
        store.markDelivered([ids[0]])
        #expect(store.undeliveredReports().map(\.id) == [ids[1]])
    }

    @Test func theHubsAddressAndMessagesRoundTrip() throws {
        #expect(store.hubAddress() == nil)
        let address = HubLink.Address(device: "00008150-00123C360CF3C01C", hosts: ["192.168.1.2", "mac.local"], port: 47361, token: "secret")
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        try HubLink.encode(address).write(to: store.hubAddressFile)
        #expect(store.hubAddress() == address)
        // An address left by an older hub has no token.
        try Data(#"{"device":"x","hosts":["mac.local"],"port":47361}"#.utf8).write(to: store.hubAddressFile)
        #expect(store.hubAddress()?.token == nil)
        // The hub reads exactly these lines; see the Mac tool's ReportSourcesTests.
        let offer = HubLink.Offer(device: address.device, bundleID: "com.example.app", token: "secret",
                                  reports: [.init(id: "20261003-215826", finishedAt: Date(timeIntervalSince1970: 1_791_000_000))])
        let line = String(decoding: HubLink.encode(offer), as: UTF8.self)
        #expect(line == #"{"bundleID":"com.example.app","device":"00008150-00123C360CF3C01C","reports":[{"finishedAt":"2026-10-03T04:00:00Z","id":"20261003-215826"}],"token":"secret"}"# + "\n")
        #expect(HubLink.decode(HubLink.Answer.self, from: Data(#"{"delivered":[],"want":["20261003-215826"]}"#.utf8))
                == HubLink.Answer(want: ["20261003-215826"], delivered: []))
        let upload = String(decoding: HubLink.encode(HubLink.Upload(id: "r", files: ["report.md": Data("# Hi".utf8)])), as: UTF8.self)
        #expect(upload == #"{"files":{"report.md":"IyBIaQ=="},"id":"r"}"# + "\n")
    }

    @Test func aReportsFilesAreSentWithoutItsDraftOrMark() throws {
        try store.saveDraft([annotation("Cut off")])
        let started = try store.beginReport(date: Date(timeIntervalSince1970: 1_790_000_000))
        try Data([1, 2, 3]).write(to: started.folder.appending(path: "screen-1.jpg"))
        try store.finishReport(sampleReport(id: started.id), in: started.folder)
        store.markDelivered([started.id])
        #expect(store.reportFiles(started.id).keys.sorted() == ["report.json", "report.md", "screen-1.jpg"])
        #expect(store.sentReports().first?.delivered == true)
    }

    @Test func theLastDeliveryIsRemembered() {
        #expect(store.lastDelivery() == nil)
        store.recordDelivery(.unreachable, at: Date(timeIntervalSince1970: 1_791_000_000))
        #expect(store.lastDelivery() == Delivery(at: Date(timeIntervalSince1970: 1_791_000_000), outcome: .unreachable))
    }

    @Test func aSentReportIsSummedUpForTheList() {
        let report = sampleReport(id: "r")
        #expect(report.screenNames == "Today")
        #expect(report.contents == "3 notes, 1 screen")
        var attachmentsOnly = report
        attachmentsOnly.screens = []
        attachmentsOnly.items = [report.items[2]]
        #expect(attachmentsOnly.screenNames == "Attachment")
        #expect(attachmentsOnly.contents == "1 note")
    }

    @Test func theSummaryTellsTheAgentWhichPictureShowsEachNote() {
        let text = ReportSummary.markdown(sampleReport(id: "r"))
        #expect(text.contains("## Screen: Today"))
        #expect(text.contains("One screenshot of this screen, stitched from 2 scroll positions, in 2 parts: screen-1.jpg, screen-1-part-2.jpg."))
        #expect(text.contains("Notes 1 and 2 are outlined and numbered on it."))
        #expect(text.contains("1. **Save** (Button, identifier `save`): Cut off. See screen-1.jpg."))
        #expect(text.contains("## Attachments"))
        #expect(text.contains("3. **2 images from Photos**: Same bug. Images: note-3-1.jpg, note-3-2.jpg."))
    }

    private func sampleReport(id: String) -> Report {
        let element = ElementSnapshot(role: "Button", label: "Save", value: nil, identifier: "save", className: nil, isContainer: false, frame: CGRect(x: 1, y: 2, width: 3, height: 4))
        func item(_ number: Int, _ note: String, picture: String) -> Report.Item {
            Report.Item(number: number, kind: .element, note: note, createdAt: Date(timeIntervalSince1970: 1_790_000_000), title: "Save",
                        element: element, ancestors: [], screen: "screen-1", screenTitle: "Today", picture: picture,
                        outline: Report.Box(x: 10, y: 20, width: 30, height: 40), attachments: [])
        }
        return Report(
            id: id,
            createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            app: Report.App(bundleIdentifier: "com.example.app", name: "Example", version: "1.0", build: "1"),
            device: Report.Device(model: "iPhone18,1", systemName: "iOS", systemVersion: "27.0"),
            screens: [Report.Screen(id: "screen-1", title: "Today", viewController: "Home", notes: [1, 2], images: [
                Report.Picture(file: "screen-1.jpg", part: 1, parts: 2, stitchedFrom: 2, earlierState: false, notes: [1, 2], width: 563, height: 1224),
                Report.Picture(file: "screen-1-part-2.jpg", part: 2, parts: 2, stitchedFrom: 2, earlierState: false, notes: [2], width: 563, height: 700),
            ])],
            items: [
                item(1, "Cut off", picture: "screen-1.jpg"),
                item(2, "Too faint", picture: "screen-1-part-2.jpg"),
                Report.Item(number: 3, kind: .photo, note: "Same bug", createdAt: Date(timeIntervalSince1970: 1_790_000_000), title: "2 images from Photos",
                            element: nil, ancestors: [], screen: nil, screenTitle: nil, picture: nil, outline: nil,
                            attachments: ["note-3-1.jpg", "note-3-2.jpg"]),
            ]
        )
    }
}
#endif
