#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import RedlineTool

@MainActor
struct HubPathsTests {
    private let temporary = TemporaryFolder("HubPathsTests")
    private var support: URL { temporary.url }

    private var oldPaths: HubPaths {
        HubPaths(root: support.appending(path: HubPaths.oldName, directoryHint: .isDirectory))
    }
    private var paths: HubPaths { HubPaths(root: support.appending(path: "Redline", directoryHint: .isDirectory)) }

    /// Starts `arguments` as a running hub of the earlier version.
    ///
    /// It holds the lock on the old folder's `hub.pid` through its input, with its pid in the file.
    private func startOldHub(_ arguments: [String], readyLine: Bool = false) throws -> Process {
        try FileManager.default.createDirectory(at: oldPaths.hub, withIntermediateDirectories: true)
        let descriptor = open(oldPaths.pid.path, O_RDWR | O_CREAT, 0o644)
        defer { close(descriptor) }
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        let hub = Process()
        hub.executableURL = URL(filePath: arguments[0])
        hub.arguments = Array(arguments.dropFirst())
        hub.standardInput = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let ready = Pipe()
        if readyLine { hub.standardOutput = ready }
        try hub.run()
        // Once it says so, it has set up what it does with a request to stop.
        if readyLine { _ = ready.fileHandleForReading.availableData }
        try "\(hub.processIdentifier)".write(to: oldPaths.pid, atomically: false, encoding: .utf8)
        return hub
    }

    @Test func theFolderFromBeforeTheRenameMovesOnce() throws {
        let oldInbox = oldPaths.inbox
        try FileManager.default.createDirectory(at: oldInbox, withIntermediateDirectories: true)
        try Data("report".utf8).write(to: oldInbox.appending(path: "old.txt"))
        // No hub was running, so none has to be started for it.
        #expect(HubPaths.moveFromOldName(to: paths) == .done)
        #expect(FileManager.default.fileExists(atPath: paths.inbox.appending(path: "old.txt").path))
        // The old name now leads to the new folder, so an MCP server of the earlier version still
        // serving a chat sees what this version's hub writes.
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: oldPaths.root.path) == paths.root.path)
        try Data("report".utf8).write(to: paths.inbox.appending(path: "new.txt"))
        #expect(FileManager.default.fileExists(atPath: oldInbox.appending(path: "new.txt").path))
        // Run again, nothing changes.
        #expect(HubPaths.moveFromOldName(to: paths) == .done)
        // Once there's a folder under the new name, an old one is left alone.
        try FileManager.default.removeItem(at: oldPaths.root)
        try FileManager.default.createDirectory(at: oldInbox, withIntermediateDirectories: true)
        #expect(HubPaths.moveFromOldName(to: paths) == .done)
        #expect(FileManager.default.fileExists(atPath: oldInbox.path))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: oldPaths.root.path)) == nil)
    }

    @Test func aRunningHubOfTheEarlierVersionStopsBeforeItsFolderMoves() throws {
        let hub = try startOldHub(["/bin/sleep", "30"])
        defer { if hub.isRunning { hub.terminate() } }
        // It was given an app on the command line, which it saved in its status.
        let status = HubStatus(
            pid: hub.processIdentifier,
            startedAt: .now,
            apps: ["com.example.chat", "com.example.kept"],
            fixedApps: ["com.example.kept"],
            hosts: [],
            port: 0,
            phones: [],
            simulatorContainers: 0
        )
        try HubPaths.encoder.encode(status).write(to: oldPaths.status)
        // It says it stopped the hub, so the command that moved the folder starts this version's,
        // watching the app that hub was given.
        #expect(HubPaths.moveFromOldName(to: paths) == .stoppedHub(fixedApps: ["com.example.kept"]))
        hub.waitUntilExit()
        #expect(hub.terminationReason == .uncaughtSignal)
        #expect(FileManager.default.fileExists(atPath: paths.status.path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: oldPaths.root.path) == paths.root.path)
    }

    @Test func nothingMovesWhileTheEarlierVersionsHubWontStop() throws {
        // Stands in for an old hub still handing a report over: it doesn't stop when asked to.
        let hub = try startOldHub(["/bin/sh", "-c", "trap '' TERM; echo ready; exec /bin/sleep 30"], readyLine: true)
        defer {
            kill(hub.processIdentifier, SIGKILL)
            hub.waitUntilExit()
        }
        guard case .blocked = HubPaths.moveFromOldName(to: paths) else {
            Issue.record("The folder moved while the earlier version's hub was running")
            return
        }
        // The old folder stays where the old hub uses it.
        #expect(hub.isRunning)
        #expect(!FileManager.default.fileExists(atPath: paths.root.path))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: oldPaths.root.path)) == nil)
    }

    @Test func aPidLeftByAnEarlierHubThatCrashedIsNeverSignaled() throws {
        try FileManager.default.createDirectory(at: oldPaths.hub, withIntermediateDirectories: true)
        // A process that has since been given the crashed hub's pid: it doesn't hold the lock.
        let other = Process()
        other.executableURL = URL(filePath: "/bin/sleep")
        other.arguments = ["30"]
        try other.run()
        defer { other.terminate() }
        try "\(other.processIdentifier)".write(to: oldPaths.pid, atomically: true, encoding: .utf8)
        #expect(HubPaths.moveFromOldName(to: paths) == .done)
        #expect(other.isRunning)
        #expect(FileManager.default.fileExists(atPath: paths.hub.path))
    }
}
#endif
