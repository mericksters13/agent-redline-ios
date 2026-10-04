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

    @Test func sendPutsScreenshotsInTheReportAndClearsTheDraft() throws {
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

    private let app = Report.App(bundleIdentifier: "com.example.app", name: "Example", version: "1.0", build: "1")
    private let device = Report.Device(model: "iPhone17,1", systemName: "iOS", systemVersion: "27.0")

    @Test func reportsInTheSameSecondGetTheirOwnFolders() throws {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let first = try store.send([annotation("Cut off")], app: app, device: device, date: date)
        let second = try store.send([annotation("Wrong color")], app: app, device: device, date: date)
        #expect(first != second)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let firstReport = try decoder.decode(Report.self, from: Data(contentsOf: first.appending(path: "report.json")))
        let secondReport = try decoder.decode(Report.self, from: Data(contentsOf: second.appending(path: "report.json")))
        #expect(firstReport.annotations.map(\.note) == ["Cut off"])
        #expect(secondReport.annotations.map(\.note) == ["Wrong color"])
        #expect(firstReport.id != secondReport.id)
    }

    @Test func aFailedSendLeavesTheDraftWhole() throws {
        let kept = annotation("Cut off")
        var broken = annotation("Wrong color")
        // A screenshot in a subfolder the report doesn't have, so copying it fails
        // after the first screenshot has already been copied.
        broken.screenshot = "nested/\(broken.screenshot)"
        try store.saveScreenshot(Data([1]), named: kept.screenshot)
        try FileManager.default.createDirectory(at: store.draftDirectory.appending(path: "nested"), withIntermediateDirectories: true)
        try store.saveScreenshot(Data([2]), named: broken.screenshot)
        try store.saveDraft([kept, broken])

        #expect(throws: (any Error).self) {
            try store.send([kept, broken], app: app, device: device, date: .now)
        }
        #expect(store.loadDraft() == [kept, broken])
        #expect(FileManager.default.fileExists(atPath: store.draftDirectory.appending(path: kept.screenshot).path))
        #expect(FileManager.default.fileExists(atPath: store.draftDirectory.appending(path: broken.screenshot).path))
        let reports = try FileManager.default.contentsOfDirectory(atPath: store.reportsDirectory.path)
        #expect(reports.isEmpty)
    }
}
#endif
