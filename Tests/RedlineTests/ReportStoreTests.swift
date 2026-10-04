#if REDLINE
import Foundation
import Testing
@testable import Redline

struct ReportStoreTests {
    private let store = ReportStore(
        root: FileManager.default.temporaryDirectory.appending(path: "ReportStoreTests-\(UUID().uuidString)")
    )

    /// Each test gets its own folder; this removes it.
    private func removeStore() {
        try? FileManager.default.removeItem(at: store.root)
    }

    private func annotation(_ note: String) -> Annotation {
        let id = UUID()
        return Annotation(
            id: id,
            createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            note: note,
            kind: .element,
            element: ElementSnapshot(
                role: "Button",
                label: "Save",
                value: nil,
                identifier: "save",
                className: nil,
                isContainer: false,
                frame: CGRect(x: 1, y: 2, width: 3, height: 4)
            ),
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
        defer { removeStore() }
        let annotations = [annotation("Cut off"), annotation("Wrong color")]
        try store.saveDraft(annotations)
        #expect(try store.loadDraft() == annotations)
    }

    @Test func notesAndAttachmentsMixInOneDraft() throws {
        defer { removeStore() }
        let items = [annotation("Cut off"), photos("Flickers between these", count: 3), annotation("Wrong color")]
        try store.saveDraft(items)
        let loaded = try store.loadDraft()
        #expect(loaded == items)
        #expect(loaded.map(\.kind) == [.element, .photo, .element])
        #expect(loaded[1].element == nil)
        #expect(loaded[1].screenshots.count == 3)
    }

    @Test func aDraftSavedBeforeAttachmentsStillLoads() throws {
        defer { removeStore() }
        let legacy = """
            [{"id":"8FAD57B3-BD1A-4853-B238-DB8A7A6ED1AC","createdAt":"2026-10-02T23:59:39Z","note":"Date wraps badly",
              "element":{"role":"Button","label":"Use next","identifier":"milk.home.urgency","isContainer":false,"frame":[[20,468],[362,74]]},
              "ancestors":[],"screen":{"title":"Today","viewController":"NavigationStackHostingController"},
              "screenshot":"8FAD57B3-BD1A-4853-B238-DB8A7A6ED1AC.png"}]
            """
        try FileManager.default.createDirectory(at: store.draftDirectory, withIntermediateDirectories: true)
        try Data(legacy.utf8).write(to: store.draftDirectory.appending(path: "annotations.json"))
        let loaded = try store.loadDraft()
        #expect(loaded.count == 1)
        #expect(loaded.first?.kind == .element)
        #expect(loaded.first?.element?.identifier == "milk.home.urgency")
        #expect(loaded.first?.screen?.title == "Today")
        #expect(loaded.first?.screenshots == ["8FAD57B3-BD1A-4853-B238-DB8A7A6ED1AC.png"])
    }

    @Test func missingDraftIsEmpty() throws {
        defer { removeStore() }
        #expect(try store.loadDraft().isEmpty)
        #expect(try store.loadScreens().isEmpty)
    }

    @Test func anUnreadableDraftIsSetAsideInsteadOfOverwritten() throws {
        defer { removeStore() }
        let garbage = Data("not json".utf8)
        try FileManager.default.createDirectory(at: store.draftDirectory, withIntermediateDirectories: true)
        try garbage.write(to: store.draftFile)
        #expect(throws: (any Error).self) { try store.loadDraft() }

        let aside = try store.setAsideUnreadable(store.draftFile, at: Date(timeIntervalSince1970: 1_790_000_000))
        try store.saveDraft([])
        #expect(try Data(contentsOf: aside) == garbage)
        #expect(aside.lastPathComponent.hasPrefix("annotations-unreadable-"))
        #expect(aside.pathExtension == "json")
        #expect(try store.loadDraft().isEmpty)
    }

    @Test func aKindFromANewerKitStillLoads() throws {
        defer { removeStore() }
        let draft = """
            [{"id":"8FAD57B3-BD1A-4853-B238-DB8A7A6ED1AC","createdAt":"2026-10-02T23:59:39Z","note":"Shaky",
              "kind":"recording","ancestors":[],"screenshots":["a.mov"]},
             {"id":"9FAD57B3-BD1A-4853-B238-DB8A7A6ED1AC","createdAt":"2026-10-02T23:59:40Z","note":"Cut off",
              "kind":"futureKind","element":{"role":"Button","label":"Save","isContainer":false,"frame":[[1,2],[3,4]]},
              "ancestors":[],"screenshots":[]}]
            """
        try FileManager.default.createDirectory(at: store.draftDirectory, withIntermediateDirectories: true)
        try Data(draft.utf8).write(to: store.draftFile)
        #expect(try store.loadDraft().map(\.kind) == [.screen, .element])
    }

    @Test func aReportTakesTheWholeDraftAndLeavesAFreshOne() throws {
        defer { removeStore() }
        let items = [annotation("Cut off"), photos("Same bug on another screen", count: 2)]
        for name in items.flatMap(\.screenshots) {
            try store.saveScreenshot(Data([1, 2, 3]), named: name)
        }
        try store.saveDraft(items)

        let started = try store.beginReport(date: Date(timeIntervalSince1970: 1_790_000_000))
        #expect(try store.loadDraft().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.draftDirectory.path))
        for name in items.flatMap(\.screenshots) {
            #expect(FileManager.default.fileExists(atPath: started.draft.appending(path: name).path))
        }

        // A second report in the same second gets its own folder.
        try store.saveDraft([annotation("Later")])
        let second = try store.beginReport(date: Date(timeIntervalSince1970: 1_790_000_000))
        #expect(second.id != started.id)

        try store.finishReport(Fixtures.report(id: started.id), in: started.folder)
        #expect(FileManager.default.fileExists(atPath: started.folder.appending(path: "report.json").path))
        #expect(FileManager.default.fileExists(atPath: started.folder.appending(path: "report.md").path))
        #expect(!FileManager.default.fileExists(atPath: started.draft.path))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(
            Report.self,
            from: Data(contentsOf: started.folder.appending(path: "report.json"))
        )
        #expect(report.screens.first?.snapshots.first?.notes == [1, 2])
        #expect(report.items.first?.snapshot == Fixtures.snapshotFiles[0])
    }

    @Test func aReportIsNamedByWhenItWasSent() throws {
        defer { removeStore() }
        try store.saveDraft([])
        // 2026-09-21 14:13:20 UTC, named in the phone's own time zone.
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let expected = String(
            format: "%04d%02d%02d-%02d%02d%02d",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0,
            parts.hour ?? 0,
            parts.minute ?? 0,
            parts.second ?? 0
        )
        #expect(try store.beginReport(date: date).id == expected)
    }

    @Test func screensSurviveAReload() throws {
        defer { removeStore() }
        let capture = Capture(
            id: UUID(),
            file: "capture.png",
            size: CGSize(width: 402, height: 874),
            scroll: nil,
            elements: [],
            group: 0
        )
        let screens = [
            ScreenRecord(id: UUID(), info: ScreenInfo(title: "Today", viewController: "Home"), captures: [capture])
        ]
        try store.saveScreens(screens)
        #expect(try store.loadScreens() == screens)
    }

    @Test func sentReportsAreListedNewestFirst() throws {
        defer { removeStore() }
        for (id, seconds) in [("older", 1_790_000_000.0), ("newer", 1_790_000_600.0)] {
            try store.saveDraft([annotation(id)])
            let started = try store.beginReport(date: Date(timeIntervalSince1970: seconds))
            var report = Fixtures.report(id: id)
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
        defer { removeStore() }
        var ids: [String] = []
        for seconds in [1_790_000_000.0, 1_790_000_600.0] {
            try store.saveDraft([annotation("Cut off")])
            let started = try store.beginReport(date: Date(timeIntervalSince1970: seconds))
            var report = Fixtures.report(id: started.id)
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

    @Test func anUnreadableHubAddressIsNoHub() throws {
        defer { removeStore() }
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        try Data(#"{"hosts":"not a list"}"#.utf8).write(to: store.hubAddressFile)
        #expect(store.hubAddress() == nil)
    }

    @Test func theHubsAddressIsReadFromTheAppsFolder() throws {
        defer { removeStore() }
        #expect(store.hubAddress() == nil)
        let address = HubLink.Address(
            device: "00008150-00123C360CF3C01C",
            hosts: ["192.168.1.2", "mac.local"],
            port: 47361,
            token: "secret"
        )
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        try HubLink.encode(address).write(to: store.hubAddressFile)
        #expect(store.hubAddress() == address)
        // An address left by an older hub has no token.
        try Data(#"{"device":"x","hosts":["mac.local"],"port":47361}"#.utf8).write(to: store.hubAddressFile)
        #expect(store.hubAddress()?.token == nil)
        // A simulator app's address says it doesn't upload.
        try Data(#"{"device":"S","hosts":["127.0.0.1"],"port":47361,"token":"t","uploads":false}"#.utf8).write(
            to: store.hubAddressFile
        )
        #expect(store.hubAddress()?.uploads == false)
    }

    @Test func theFolderIsWhereTheMacLooks() {
        defer { removeStore() }
        // Must match the Mac tool's ReportFolder.path and HubAddress.addressPath.
        let reports = ReportStore.standard.reportsDirectory.path(percentEncoded: false)
        #expect(
            reports.trimmingCharacters(in: CharacterSet(charactersIn: "/")).hasSuffix(
                "Library/Application Support/Redline/reports"
            )
        )
        #expect(
            ReportStore.standard.hubAddressFile.path(percentEncoded: false).hasSuffix(
                "Library/Application Support/Redline/hub.json"
            )
        )
    }

    @Test func reportFieldsKeepTheirNamesOnDisk() throws {
        defer { removeStore() }
        try store.saveDraft([])
        let started = try store.beginReport(date: Date(timeIntervalSince1970: 1_790_000_000))
        try store.finishReport(Fixtures.report(id: started.id), in: started.folder)
        let json = try String(decoding: Data(contentsOf: started.folder.appending(path: "report.json")), as: UTF8.self)
        #expect(json.contains(#""bundleIdentifier" : "com.example.app""#))
        #expect(json.contains(#""earlierState" : false"#))
        #expect(!json.contains("isEarlierState"))
        store.recordDelivery(.refused, at: Date(timeIntervalSince1970: 1_791_000_000))
        let delivery = try String(
            decoding: Data(contentsOf: store.root.appending(path: "delivery.json")),
            as: UTF8.self
        )
        #expect(delivery.contains(#""at" : "2026-10-03T04:00:00Z""#))
    }

    @Test func aReportSaysWhichVersionOfTheFormatItIs() throws {
        defer { removeStore() }
        try store.saveDraft([])
        let started = try store.beginReport(date: Date(timeIntervalSince1970: 1_790_000_000))
        try store.finishReport(Fixtures.report(id: started.id), in: started.folder)
        let json = try String(decoding: Data(contentsOf: started.folder.appending(path: "report.json")), as: UTF8.self)
        #expect(json.contains(#""version" : 1"#))
        // Reports written before the format had a version still list.
        let old = store.reportsDirectory.appending(path: "20261001-120000")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        var unversioned =
            try JSONSerialization.jsonObject(with: Data(contentsOf: started.folder.appending(path: "report.json")))
            as? [String: Any] ?? [:]
        unversioned["version"] = nil
        unversioned["id"] = "20261001-120000"
        try JSONSerialization.data(withJSONObject: unversioned).write(to: old.appending(path: "report.json"))
        #expect(Set(store.sentReports().map(\.id)) == [started.id, "20261001-120000"])
        #expect(store.sentReports().first { $0.id == "20261001-120000" }?.report.version == nil)
    }

    @Test func thePickedChatIsSavedWithTheReport() throws {
        defer { removeStore() }
        try store.saveDraft([])
        let started = try store.beginReport(date: Date(timeIntervalSince1970: 1_791_000_000))
        var report = Fixtures.report(id: started.id)
        report.app.sourceFile = "/w/App.swift"
        report.destination = Report.Destination(agent: "codex", chat: "t-1", title: "Fix the paywall")
        try store.finishReport(report, in: started.folder)
        let saved = try #require(store.sentReports().first?.report)
        #expect(saved.destination == report.destination)
        #expect(saved.app.sourceFile == "/w/App.swift")
    }

    @Test func aReportsFilesAreSentWithoutItsDraftOrMark() throws {
        defer { removeStore() }
        try store.saveDraft([annotation("Cut off")])
        let started = try store.beginReport(date: Date(timeIntervalSince1970: 1_790_000_000))
        try Data([1, 2, 3]).write(to: started.folder.appending(path: Fixtures.snapshotFiles[0]))
        try store.finishReport(Fixtures.report(id: started.id), in: started.folder)
        store.markDelivered([started.id])
        #expect(
            store.reportFiles(started.id).keys.sorted() == [Fixtures.snapshotFiles[0], "report.json", "report.md"]
        )
        #expect(store.sentReports().first?.isDelivered == true)
    }

    @Test func theLastDeliveryIsRemembered() {
        defer { removeStore() }
        #expect(store.lastDelivery() == nil)
        store.recordDelivery(.unreachable, at: Date(timeIntervalSince1970: 1_791_000_000))
        #expect(
            store.lastDelivery()
                == Delivery(attemptedAt: Date(timeIntervalSince1970: 1_791_000_000), outcome: .unreachable)
        )
    }

}
#endif
