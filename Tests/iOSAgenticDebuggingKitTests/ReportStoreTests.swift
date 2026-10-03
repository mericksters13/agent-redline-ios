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

    @Test func sendMovesEveryImageIntoTheReportAndClearsTheDraft() throws {
        let annotations = [annotation("Cut off"), photos("Same bug on another screen", count: 2), annotation("Wrong color")]
        for name in annotations.flatMap(\.screenshots) {
            try store.saveScreenshot(Data([1, 2, 3]), named: name)
        }
        try store.saveDraft(annotations)

        let app = Report.App(bundleIdentifier: "com.example.app", name: "Example", version: "1.0", build: "1")
        let device = Report.Device(model: "iPhone17,1", systemName: "iOS", systemVersion: "27.0")
        let folder = try store.send(annotations, app: app, device: device, date: Date(timeIntervalSince1970: 1_790_000_000))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(Report.self, from: Data(contentsOf: folder.appending(path: "report.json")))
        #expect(report.annotations == annotations)
        #expect(report.app.bundleIdentifier == "com.example.app")
        for name in annotations.flatMap(\.screenshots) {
            #expect(FileManager.default.fileExists(atPath: folder.appending(path: name).path))
        }
        #expect(store.loadDraft().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.draftDirectory.path))
    }
}
#endif
