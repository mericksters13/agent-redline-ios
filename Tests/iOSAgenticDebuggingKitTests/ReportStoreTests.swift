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
            element: ElementSnapshot(role: "Button", label: "Save", value: nil, identifier: "save", className: nil, isContainer: false, frame: CGRect(x: 1, y: 2, width: 3, height: 4)),
            ancestors: [],
            screen: ScreenInfo(title: "Settings", viewController: "SettingsController"),
            screenshot: "\(id.uuidString).png"
        )
    }

    @Test func draftSurvivesAReload() throws {
        let annotations = [annotation("Cut off"), annotation("Wrong color")]
        try store.saveDraft(annotations)
        #expect(store.loadDraft() == annotations)
    }

    @Test func missingDraftIsEmpty() {
        #expect(store.loadDraft().isEmpty)
    }

    @Test func sendMovesScreenshotsIntoTheReportAndClearsTheDraft() throws {
        let annotations = [annotation("Cut off"), annotation("Wrong color")]
        for item in annotations {
            try store.saveScreenshot(Data([1, 2, 3]), named: item.screenshot)
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
        for item in annotations {
            #expect(FileManager.default.fileExists(atPath: folder.appending(path: item.screenshot).path))
        }
        #expect(store.loadDraft().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.draftDirectory.path))
    }
}
#endif
