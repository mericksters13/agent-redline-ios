#if os(macOS)
import Foundation
import Testing
@testable import RedlineTool

struct ReportFolderTests {
    @Test func onlyFinishedReportsAreCopied() {
        let at = Date(timeIntervalSince1970: 1_791_030_000)
        let entries: [(path: String, modified: Date?)] = [
            ("20261003-150846", at), ("20261003-150846/report.json", at), ("20261003-150846/screen-1.jpg", at),
            // Still being drawn: its draft hasn't been removed yet.
            ("20261003-202235", at), ("20261003-202235/report.json", at), ("20261003-202235/draft", at),
            // Just started: no report.json yet.
            ("20261003-202300", at), ("20261003-202300/draft/annotations.json", at),
            // Already on a Mac.
            ("20261002-135144", at), ("20261002-135144/report.json", at), ("20261002-135144/delivered", at),
        ]
        #expect(ReportFolder.finishedReports(in: entries) == [FinishedReport(id: "20261003-150846", finishedAt: at)])
    }

    @Test func aSimulatorReportIsFoundFromAnyFileInIt() {
        let container =
            "/Users/me/Library/Developer/CoreSimulator/Devices/198F6C2F-B757-44A8-88BB-A574EC16F621/data/Containers/Data/Application/17364006-587A-45B0-86EC-941E51A550D1"
        let path = container + "/Library/Application Support/Redline/reports/20261003-151826/report.md"
        #expect(
            SimulatorReportPath.parse(path)
                == SimulatorReportPath(
                    container: container,
                    device: "198F6C2F-B757-44A8-88BB-A574EC16F621",
                    reportID: "20261003-151826"
                )
        )
        #expect(SimulatorReportPath.parse(container + "/Library/Caches/whatever") == nil)
        // A build from before the rename keeps its reports under the old name.
        let earlier =
            container + "/Library/Application Support/iOSAgenticDebuggingKit/reports/20261003-151826/report.md"
        #expect(
            SimulatorReportPath.parse(earlier)
                == SimulatorReportPath(
                    container: container,
                    device: "198F6C2F-B757-44A8-88BB-A574EC16F621",
                    reportID: "20261003-151826",
                    folder: ReportFolder.earlierPath
                )
        )
    }

    @Test func aSimulatorIsFoundFromItsContainerWhateverTheHomeFolderIsCalled() {
        let container =
            "/Users/Devices/Library/Developer/CoreSimulator/Devices/198F6C2F-B757-44A8-88BB-A574EC16F621/data/Containers/Data/Application/17364006-587A-45B0-86EC-941E51A550D1"
        #expect(SimulatorReportPath.device(ofContainer: container) == "198F6C2F-B757-44A8-88BB-A574EC16F621")
    }

    @Test func aSimulatorAppsKitFoldersAreWatchedUnderEitherName() throws {
        let files = FileManager.default
        let container = files.temporaryDirectory.appending(
            path: "ReportFolderTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? files.removeItem(at: container) }
        let support = container.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        try files.createDirectory(at: container, withIntermediateDirectories: true)
        let path = container.path
        // Until the kit has written anything, the whole container.
        #expect(SimulatorWatcher.roots(for: [path]) == [path])
        // A build from before the rename, still running after the Mac tool is updated, while the hub
        // has left its address under the new name.
        try files.createDirectory(
            at: support.appending(path: "iOSAgenticDebuggingKit/reports"),
            withIntermediateDirectories: true
        )
        try files.createDirectory(at: support.appending(path: "Redline"), withIntermediateDirectories: true)
        #expect(
            SimulatorWatcher.roots(for: [path])
                == [path + "/" + HubMessage.kitFolder, path + "/" + HubMessage.earlierKitFolder].sorted()
        )
    }

    @Test func aBuildFromBeforeTheRenameGetsTheAddressUnderItsOldName() throws {
        let files = FileManager.default
        let container = files.temporaryDirectory.appending(
            path: "ReportFolderTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? files.removeItem(at: container) }
        let renamed = container.appending(path: "Library/Application Support/Redline/hub.json")
        let earlier = container.appending(path: "Library/Application Support/iOSAgenticDebuggingKit/hub.json")
        // Next to the reports folder of a build from before the rename, as that build reads it.
        #expect(
            HubMessage.earlierAddressPath == (ReportFolder.earlierPath as NSString).deletingLastPathComponent
                + "/hub.json"
        )
        // A renamed build, or one that hasn't written anything yet: only the new name.
        try files.createDirectory(at: container, withIntermediateDirectories: true)
        let path = container.path
        #expect(SimulatorWatcher.addressFiles(in: path).map(\.path) == [renamed.path])
        // A build from before the rename has its folder there.
        try files.createDirectory(at: earlier.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(SimulatorWatcher.addressFiles(in: path).map(\.path) == [renamed.path, earlier.path])
    }
}
#endif
