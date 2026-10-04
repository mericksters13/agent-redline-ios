#if os(macOS)
import Foundation
import Testing
@testable import RedlineTool

struct HubTests {
    private let paths = HubPaths(root: FileManager.default.temporaryDirectory.appending(path: "HubTests-\(UUID().uuidString)", directoryHint: .isDirectory))
    private let phone = "00008150-00123C360CF3C01C"
    private let app = "com.markbuot.AthenaTracker"

    /// A hub that's never started: no listener, no simulators, no devicectl.
    private func hub() throws -> Hub {
        try FileManager.default.createDirectory(at: paths.hub, withIntermediateDirectories: true)
        return Hub(paths: paths, devicectl: Devicectl(executable: URL(filePath: "/usr/bin/true")), apps: [app])
    }

    private func offer(token: String, reports: [HubMessage.Offer.Report]) -> HubMessage.Offer {
        HubMessage.Offer(device: phone, bundleID: app, token: token, reports: reports)
    }

    /// The hub's state for the phone once `done` accepts it, waiting up to five seconds.
    private func state(of hub: Hub, until done: (String) -> Bool) async throws -> String? {
        func saved() -> String? {
            (try? Data(contentsOf: paths.status)).flatMap { try? HubPaths.decoder.decode(HubStatus.self, from: $0) }?.phones.first?.state
        }
        for _ in 0..<50 {
            if let state = saved(), done(state) { return state }
            try await Task.sleep(for: .milliseconds(100))
        }
        return saved()
    }

    @Test func aPhoneThatWakesGetsItsAddressWithoutWaitingOutTheDelay() async throws {
        try FileManager.default.createDirectory(at: paths.hub, withIntermediateDirectories: true)
        // Stands in for devicectl: the app is installed, and copying to it works only once the phone is awake.
        let awake = paths.root.appending(path: "awake")
        let devicectl = paths.root.appending(path: "devicectl")
        try """
        #!/bin/sh
        command="$1 $2"
        while [ $# -gt 0 ]; do [ "$1" = "--json-output" ] && output="$2"; shift; done
        case "$command" in
          "device copy") [ -f '\(awake.path)' ] ;;
          "device info") printf '{"result":{"apps":[{"bundleIdentifier":"\(app)"}]}}' > "$output" ;;
          *) exit 1 ;;
        esac
        """.write(to: devicectl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: devicectl.path)
        let hub = Hub(paths: paths, devicectl: Devicectl(executable: devicectl), apps: [app])
        hub.updateApps(isStarting: true)
        let link = PhoneLink(phone: .init(udid: phone, name: "Mark iPhone", model: "iPhone 17 Pro"), hub: hub)

        link.update(hosts: ["192.168.1.2"], port: 47361, includingNewApps: true)
        #expect(try await state(of: hub) { $0.hasPrefix("Not reachable") }?.hasPrefix("Not reachable, trying again in 30 s") == true)
        // The phone wakes long before the 30 seconds are up, and gets its address right away.
        try Data().write(to: awake)
        link.phoneDidWake()
        #expect(try await state(of: hub) { $0.hasPrefix("Ready") } == "Ready for \(app)")
    }

    @Test func aTokenOutlivesTheHub() throws {
        let first = try hub()
        let token = first.issueToken(device: phone, bundleID: app)
        // Files are written on the hub's writer queue.
        first.flushWrites()
        #expect(token.count == 64)
        #expect(try hub().issueToken(device: phone, bundleID: app) == token)
        let permissions = try FileManager.default.attributesOfItem(atPath: paths.tokens.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

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

    @Test func anUnreadableStateFileIsMovedAsideNotWrittenOver() throws {
        try FileManager.default.createDirectory(at: paths.hub, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: paths.state)
        let hub = try hub()
        hub.startTrackingIfNeeded(device: phone, bundleID: app)
        hub.flushWrites()
        let names = try FileManager.default.contentsOfDirectory(atPath: paths.hub.path)
        let aside = try #require(names.first { $0.hasPrefix("state.json.unreadable-") })
        #expect(try Data(contentsOf: paths.hub.appending(path: aside)) == Data("not json".utf8))
        // A fresh state.json was written beside it.
        #expect(names.contains("state.json"))
    }

    @Test func aReportWhoseSourceCantBeSavedIsNotFiled() throws {
        let hub = try hub()
        let source = ReportSource(kind: .phone, device: phone, deviceName: "Test iPhone", bundleID: app, reportID: "20261004-031600", receivedAt: .now)
        // The copy works, but source.json can't be written: a folder is in its place.
        #expect(throws: (any Error).self) {
            try hub.receive(source) { destination in
                try FileManager.default.createDirectory(at: destination.appending(path: "source.json"), withIntermediateDirectories: true)
            }
        }
        let inbox = paths.inbox.appending(path: app)
        #expect(try FileManager.default.contentsOfDirectory(atPath: inbox.path).isEmpty)
        // Not counted as delivered, so it's offered again.
        hub.startTrackingIfNeeded(device: phone, bundleID: app)
        #expect(hub.reportIDsToCopy(device: phone, bundleID: app, finished: [FinishedReport(id: "20261004-031600", finishedAt: Date.now)]) == ["20261004-031600"])
    }

    @Test func anOfferWithoutTheRightTokenIsTurnedDown() throws {
        let hub = try hub()
        _ = hub.issueToken(device: phone, bundleID: app)
        let answer = hub.answerNow(offer(token: "guess", reports: [.init(id: "20261004-031600", finishedAt: .now)]))
        #expect(answer.refused != nil)
        #expect(answer.want.isEmpty)
        // An app this hub never gave an address to is turned down too.
        let stranger = HubMessage.Offer(device: "someone", bundleID: app, token: "x", reports: [])
        #expect(hub.answerNow(stranger).refused != nil)
    }

    @Test func theHubAsksOnlyForNewReportsAndFilesThemWhole() throws {
        let hub = try hub()
        let token = hub.issueToken(device: phone, bundleID: app)
        let old = HubMessage.Offer.Report(id: "20261002-135144", finishedAt: Date.now.addingTimeInterval(-86_400))
        let new = HubMessage.Offer.Report(id: "20261004-031600", finishedAt: .now)
        let offered = offer(token: token, reports: [old, new])
        let answer = hub.answerNow(offered)
        #expect(answer.refused == nil)
        #expect(answer.want == ["20261004-031600"])
        // From before the hub first looked: the app can stop offering it.
        #expect(answer.delivered == ["20261002-135144"])

        // Unsafe file names and reports without their report.json are turned down.
        #expect(throws: Hub.FilingError.unusableUpload) {
            try hub.storeNow(HubMessage.Upload(id: new.id, files: ["../escape.jpg": Data([1]), "report.json": Data("{}".utf8)]), offeredIn: offered)
        }
        #expect(throws: Hub.FilingError.unusableUpload) { try hub.storeNow(HubMessage.Upload(id: new.id, files: ["screen-1.jpg": Data([1])]), offeredIn: offered) }

        let files = ["report.json": Data("{}".utf8), "report.md": Data("# Report".utf8), "screen-1.jpg": Data([0xFF, 0xD8])]
        try hub.storeNow(HubMessage.Upload(id: new.id, files: files), offeredIn: offered)
        let folder = paths.inbox.appending(path: "\(app)/20261004-031600-0CF3C01C", directoryHint: .isDirectory)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["report.json", "report.md", "screen-1.jpg", "source.json"])
        // Offered again, it's on the Mac now.
        let again = hub.answerNow(offered)
        #expect(again.want.isEmpty)
        #expect(Set(again.delivered) == ["20261002-135144", "20261004-031600"])
    }
}
#endif
