#if os(macOS)
import Foundation
import Testing
@testable import RedlineTool

struct HubProcessTests {
    private let temporary = TemporaryFolder("HubProcessTests")
    private var paths: HubPaths { HubPaths(root: temporary.url) }

    @Test func onlyTheHubHoldingTheLockCountsAsRunning() throws {
        try FileManager.default.createDirectory(at: paths.hub, withIntermediateDirectories: true)
        let lock = try #require(HubProcess.lock(paths))
        #expect(HubProcess.running(paths) == getpid())
        // A second hub can't take it.
        #expect(HubProcess.lock(paths) == nil)
        close(lock)
        #expect(HubProcess.running(paths) == nil)
        // A pid file left behind, naming a process that is alive, names no hub.
        try "\(getppid())".write(to: paths.pid, atomically: true, encoding: .utf8)
        #expect(HubProcess.running(paths) == nil)
    }
}
#endif
