#if os(macOS)
import Foundation
import Testing
@testable import RedlineTool

struct SimulatorWatcherTests {
    private let temporary = TemporaryFolder("SimulatorWatcherTests")
    private var paths: HubPaths { HubPaths(root: temporary.url.appending(path: "hub", directoryHint: .isDirectory)) }
    /// A folder named like CoreSimulator's, which `SimulatorReportPath` finds the simulator by.
    private var devices: URL { temporary.url.appending(path: "Devices", directoryHint: .isDirectory) }
    private let simulator = "00000000-0000-0000-0000-00000000000A"
    private let app = "com.example.app"

    private var applications: URL {
        devices.appending(path: "\(simulator)/data/Containers/Data/Application", directoryHint: .isDirectory)
    }

    /// A hub that's never started, taking reports from `app`.
    private func hub() throws -> Hub {
        try FileManager.default.createDirectory(at: paths.hub, withIntermediateDirectories: true)
        let hub = Hub(
            paths: paths,
            devicectl: Devicectl(executable: URL(filePath: "/usr/bin/true")),
            apps: [app],
            claudeChats: { [] }
        )
        hub.updateApps(isStarting: true)
        return hub
    }

    /// Installs `app` as an install does: the container is put together elsewhere and moved into
    /// place whole, with its metadata.
    private func install(named name: String) throws -> URL {
        let staging = temporary.url.appending(path: "Staging/\(name)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: staging.appending(path: "Library", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        let metadata = try PropertyListSerialization.data(
            fromPropertyList: ["MCMMetadataIdentifier": app],
            format: .xml,
            options: 0
        )
        try metadata.write(to: staging.appending(path: ".com.apple.mobile_container_manager.metadata.plist"))
        let container = applications.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: staging, to: container)
        return container
    }

    private func address(in container: URL) -> URL {
        container.appending(path: HubMessage.addressPath)
    }

    /// Waits up to five seconds for `condition`.
    ///
    /// The watcher has no event that says it has handled a change, and `flush()` can drain its
    /// queue before the file system event for an install arrives, so this checks the files it writes.
    private func eventually(_ condition: () -> Bool) async throws -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    @Test func eachSimulatorIsFollowedToItsContainers() throws {
        let files = FileManager.default
        try files.createDirectory(at: applications, withIntermediateDirectories: true)
        let neverBooted = devices.appending(path: "00000000-0000-0000-0000-00000000000B", directoryHint: .isDirectory)
        try files.createDirectory(at: neverBooted.appending(path: "data"), withIntermediateDirectories: true)
        let bare = devices.appending(path: "00000000-0000-0000-0000-00000000000C", directoryHint: .isDirectory)
        try files.createDirectory(at: bare, withIntermediateDirectories: true)
        try Data().write(to: devices.appending(path: "device_set.plist"))

        #expect(
            SimulatorWatcher.foldersToWatch(in: devices)
                == [devices.path, applications.path, neverBooted.appending(path: "data").path, bare.path].sorted()
        )
    }

    @Test func beforeXcodeMakesTheSimulatorsFolderItsParentIsWatched() throws {
        try FileManager.default.createDirectory(at: temporary.url, withIntermediateDirectories: true)
        #expect(SimulatorWatcher.foldersToWatch(in: devices) == [temporary.url.standardizedFileURL.path])
    }

    @Test func anInstallAndAnInstallOverItAreSetUpAsTheyHappen() async throws {
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        let hub = try hub()
        let watcher = SimulatorWatcher(hub: hub, devices: devices)
        // Queued writes land before the test's folder is removed.
        defer {
            watcher.stop()
            hub.flushWrites()
        }
        watcher.rescan()
        await offPool { watcher.flush() }

        let first = try install(named: "11111111-1111-1111-1111-111111111111")
        #expect(try await eventually { FileManager.default.fileExists(atPath: address(in: first).path) })

        // A report the hub hasn't taken yet moves with its container when a build is installed over
        // it, hub.json and all. The temporary folder's event paths start with /private, so the
        // watcher's event stream drops them and only the look the move starts can take the report.
        let id = "20261006-120000"
        let unsent = first.appending(path: ReportFolder.path + "/" + id, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: unsent, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: unsent.appending(path: "report.json"))
        let moved = applications.appending(path: "22222222-2222-2222-2222-222222222222", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: first, to: moved)

        let mark = moved.appending(path: ReportFolder.path + "/" + id + "/" + ReportFolder.deliveredMark)
        #expect(try await eventually { FileManager.default.fileExists(atPath: mark.path) })
        #expect(!FileManager.default.fileExists(atPath: first.path), "Something wrote into the container's old path")
    }

    @Test func aSimulatorThatBootsAfterTheHubStartsIsWatchedAsItsFoldersAppear() async throws {
        let device = devices.appending(path: simulator, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: device, withIntermediateDirectories: true)
        let hub = try hub()
        let watcher = SimulatorWatcher(hub: hub, devices: devices)
        // Queued writes land before the test's folder is removed.
        defer {
            watcher.stop()
            hub.flushWrites()
        }
        watcher.rescan()
        await offPool { watcher.flush() }

        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        let container = try install(named: "33333333-3333-3333-3333-333333333333")
        #expect(try await eventually { FileManager.default.fileExists(atPath: address(in: container).path) })
    }

    @Test func nothingIsWatchedOnceStopped() async throws {
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        let hub = try hub()
        let watcher = SimulatorWatcher(hub: hub, devices: devices)
        watcher.rescan()
        await offPool { watcher.stop() }

        let container = try install(named: "44444444-4444-4444-4444-444444444444")
        // As the hub's discovery can still ask for one while it stops.
        watcher.rescan()
        await offPool { watcher.flush() }
        #expect(!FileManager.default.fileExists(atPath: address(in: container).path))
    }

    @Test func theKitFolderIsMadeOnlyInsideAContainerThatExists() throws {
        let container = applications.appending(
            path: "55555555-5555-5555-5555-555555555555",
            directoryHint: .isDirectory
        )
        let kit = container.appending(path: HubMessage.kitFolder, directoryHint: .isDirectory)
        #expect(throws: (any Error).self) { try SimulatorWatcher.makeFolder(kit, inside: container.path) }
        #expect(!FileManager.default.fileExists(atPath: container.path))

        try FileManager.default.createDirectory(
            at: container.appending(path: "Library", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try SimulatorWatcher.makeFolder(kit, inside: container.path)
        #expect(FileManager.default.fileExists(atPath: kit.path))
    }
}
#endif
