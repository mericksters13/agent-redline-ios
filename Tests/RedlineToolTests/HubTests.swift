#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import RedlineTool

struct HubTests {
    private let paths = HubPaths(root: FileManager.default.temporaryDirectory.appending(path: "HubTests-\(UUID().uuidString)", directoryHint: .isDirectory))
    private let phone = "00008150-00123C360CF3C01C"
    private let app = "com.markbuot.AthenaTracker"

    /// A hub that's never started: no listener, no simulators, no devicectl.
    private func hub() throws -> Hub {
        try FileManager.default.createDirectory(at: paths.hub, withIntermediateDirectories: true)
        return Hub(paths: paths, devicectl: Devicectl(executable: URL(fileURLWithPath: "/usr/bin/true")), apps: [app])
    }

    private func offer(token: String, reports: [(String, Date)]) -> HubMessage.Offer {
        HubMessage.Offer(device: phone, bundleID: app, token: token, reports: reports.map { .init(id: $0.0, finishedAt: $0.1) })
    }

    /// The hub's state for the phone once `done` accepts it, waiting up to five seconds.
    private func state(of hub: Hub, until done: (String) -> Bool) async throws -> String? {
        func saved() -> String? {
            (try? Data(contentsOf: paths.status)).flatMap { try? Chats.decoder.decode(HubStatus.self, from: $0) }?.phones.first?.state
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
        hub.updateApps(starting: true)
        let link = PhoneLink(phone: .init(udid: phone, name: "Mark iPhone", model: "iPhone 17 Pro"), hub: hub)

        link.update(hosts: ["192.168.1.2"], port: 47361, rediscover: true)
        #expect(try await state(of: hub) { $0.hasPrefix("Not reachable") }?.hasPrefix("Not reachable, trying again in 30 s") == true)
        // The phone wakes long before the 30 seconds are up, and gets its address right away.
        try Data().write(to: awake)
        link.phoneWoke()
        #expect(try await state(of: hub) { $0.hasPrefix("Ready") } == "Ready for \(app)")
    }

    @Test func aReinstalledAppGetsTheAddressAgainAtTheNextDiscovery() async throws {
        try FileManager.default.createDirectory(at: paths.hub, withIntermediateDirectories: true)
        // Stands in for devicectl, noting each call; the phone answers only while it's awake.
        let awake = paths.root.appending(path: "awake")
        let calls = paths.root.appending(path: "calls")
        let devicectl = paths.root.appending(path: "devicectl")
        try """
        #!/bin/sh
        command="$1 $2"
        echo "$command" >> '\(calls.path)'
        while [ $# -gt 0 ]; do [ "$1" = "--json-output" ] && output="$2"; shift; done
        [ -f '\(awake.path)' ] || exit 1
        case "$command" in
          "device copy") exit 0 ;;
          "device info") printf '{"result":{"apps":[{"bundleIdentifier":"\(app)"}]}}' > "$output" ;;
          *) exit 1 ;;
        esac
        """.write(to: devicectl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: devicectl.path)
        let hub = Hub(paths: paths, devicectl: Devicectl(executable: devicectl), apps: [app])
        hub.updateApps(starting: true)
        let link = PhoneLink(phone: .init(udid: phone, name: "Mark iPhone", model: "iPhone 17 Pro"), hub: hub)
        func called() -> [String] { ((try? String(contentsOf: calls, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
        func waitForCalls(_ count: Int) async throws {
            for _ in 0..<50 where called().count < count { try await Task.sleep(for: .milliseconds(100)) }
        }

        try Data().write(to: awake)
        link.update(hosts: ["192.168.1.2"], port: 47361, rediscover: true)
        #expect(try await state(of: hub) { $0.hasPrefix("Ready") } == "Ready for \(app)")
        // The same address at the next discovery is written again, in case the app lost it.
        link.update(hosts: ["192.168.1.2"], port: 47361, rediscover: true)
        try await waitForCalls(2)
        #expect(called() == ["device copy", "device copy"])
        // A phone that can't be reached then keeps the address it has, with no retries.
        try FileManager.default.removeItem(at: awake)
        link.update(hosts: ["192.168.1.2"], port: 47361, rediscover: true)
        try await waitForCalls(4)
        try await Task.sleep(for: .milliseconds(300))
        #expect(called() == ["device copy", "device copy", "device copy", "device info"])
        #expect(try await state(of: hub) { _ in true } == "Ready for \(app)")
        // Without a discovery, nothing is written.
        link.update(hosts: ["192.168.1.2"], port: 47361, rediscover: false)
        try await Task.sleep(for: .milliseconds(300))
        #expect(called().count == 4)
    }

    /// The menu bar app taking over from this hub reads these and keeps watching them.
    @Test func theStatusNamesTheAppsGivenOnTheCommandLine() throws {
        #expect(try hub().statusSnapshot().fixedApps == [app])
    }

    @Test func aReportArrivingTwiceAtOnceIsFiledOnce() throws {
        let hub = try hub()
        let source = ReportSource(kind: .phone, device: phone, deviceName: "Mark iPhone", bundleID: app, reportID: "20261004-031600", receivedAt: Date())
        let results = Mutex<[Bool]>([])
        DispatchQueue.concurrentPerform(iterations: 8) { attempt in
            let result = hub.receive(source) { destination in
                do {
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                    try Data("{\"attempt\":\(attempt)}".utf8).write(to: destination.appending(path: "report.json"))
                    return true
                } catch {
                    return false
                }
            }
            results.withLock { $0.append(result) }
        }
        #expect(results.withLock { $0 } == Array(repeating: true, count: 8))
        let folder = paths.inbox.appending(path: app, directoryHint: .isDirectory)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["20261004-031600-0CF3C01C"])
        let report = folder.appending(path: "20261004-031600-0CF3C01C", directoryHint: .isDirectory)
        #expect(try FileManager.default.contentsOfDirectory(atPath: report.path).sorted() == ["report.json", "source.json"])
        let state = try Chats.decoder.decode([String: SourceState].self, from: Data(contentsOf: paths.state))
        #expect(state["\(phone)|\(app)"]?.delivered == ["20261004-031600"])
    }

    @Test func onlyAHubHoldingThePIDFileCountsAsRunning() throws {
        try FileManager.default.createDirectory(at: paths.hub, withIntermediateDirectories: true)
        // Left by a hub that crashed, naming a process that's running but isn't a hub.
        try Data("1\n".utf8).write(to: paths.pid)
        #expect(HubProcess.running(paths) == nil)
        let held = try #require(HubProcess.claim(paths))
        #expect(HubProcess.running(paths) == getpid())
        // A second hub can't start while the first holds it.
        #expect(HubProcess.claim(paths) == nil)
        close(held)
        #expect(HubProcess.running(paths) == nil)
    }

    @Test func aTokenOutlivesTheHub() throws {
        let token = try hub().token(device: phone, bundleID: app)
        #expect(token.count == 64)
        #expect(try hub().token(device: phone, bundleID: app) == token)
        let permissions = try FileManager.default.attributesOfItem(atPath: paths.tokens.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func anOfferWithoutTheRightTokenIsTurnedDown() throws {
        let hub = try hub()
        _ = hub.token(device: phone, bundleID: app)
        let answer = hub.answer(offer(token: "guess", reports: [("20261004-031600", Date())]))
        #expect(answer.refused != nil)
        #expect(answer.want.isEmpty)
        // An app this hub never gave an address to is turned down too.
        let stranger = HubMessage.Offer(device: "someone", bundleID: app, token: "x", reports: [])
        #expect(hub.answer(stranger).refused != nil)
    }

    @Test func theHubAsksOnlyForNewReportsAndFilesThemWhole() throws {
        let hub = try hub()
        let token = hub.token(device: phone, bundleID: app)
        let old = ("20261002-135144", Date().addingTimeInterval(-86_400))
        let new = ("20261004-031600", Date())
        let offered = offer(token: token, reports: [old, new])
        let answer = hub.answer(offered)
        #expect(answer.refused == nil)
        #expect(answer.want == ["20261004-031600"])
        // From before the hub first looked: the app can stop offering it.
        #expect(answer.delivered == ["20261002-135144"])

        // Unsafe file names and reports without their report.json are turned down.
        #expect(!hub.store(HubMessage.Upload(id: new.0, files: ["../escape.jpg": Data([1]), "report.json": Data("{}".utf8)]), offeredIn: offered))
        #expect(!hub.store(HubMessage.Upload(id: new.0, files: ["screen-1.jpg": Data([1])]), offeredIn: offered))

        let files = ["report.json": Data("{}".utf8), "report.md": Data("# Report".utf8), "screen-1.jpg": Data([0xFF, 0xD8])]
        #expect(hub.store(HubMessage.Upload(id: new.0, files: files), offeredIn: offered))
        let folder = paths.inbox.appending(path: "\(app)/20261004-031600-0CF3C01C", directoryHint: .isDirectory)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["report.json", "report.md", "screen-1.jpg", "source.json"])
        // Offered again, it's on the Mac now.
        let again = hub.answer(offered)
        #expect(again.want.isEmpty)
        #expect(Set(again.delivered) == ["20261002-135144", "20261004-031600"])
    }
}
#endif
