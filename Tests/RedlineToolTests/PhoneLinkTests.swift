#if os(macOS)
import Foundation
import Testing
@testable import RedlineTool

struct PhoneLinkTests {
    private let temporary = TemporaryFolder("PhoneLinkTests")
    private var paths: HubPaths { HubPaths(root: temporary.url) }
    private let phone = "00000000-0000000000000001"
    private let app = "com.example.app"

    /// The hub's state for the phone once `done` accepts it, waiting up to five seconds.
    ///
    /// The hub publishes no event when a phone's state changes, only the status file, so this polls
    /// it.
    private func state(of hub: Hub, until done: (String) -> Bool) async throws -> String? {
        func saved() -> String? {
            (try? Data(contentsOf: paths.status)).flatMap { try? HubPaths.decoder.decode(HubStatus.self, from: $0) }?
                .phones.first?.state
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
        let hub = Hub(paths: paths, devicectl: Devicectl(executable: devicectl), apps: [app], claudeChats: { [] })
        hub.updateApps(isStarting: true)
        let link = PhoneLink(phone: .init(udid: phone, name: "Test iPhone", model: "iPhone 17 Pro"), hub: hub)

        link.update(hosts: ["192.168.1.2"], port: 47361, includingNewApps: true)
        #expect(
            try await state(of: hub) { $0.hasPrefix("Not reachable") }?.hasPrefix("Not reachable, trying again in 30 s")
                == true
        )
        // The phone wakes long before the 30 seconds are up, and gets its address right away.
        try Data().write(to: awake)
        link.phoneDidWake()
        #expect(try await state(of: hub) { $0.hasPrefix("Ready") } == "Ready for \(app)")
        hub.flushWrites()
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
        noted="$command"
        while [ $# -gt 0 ]; do
          [ "$1" = "--json-output" ] && output="$2"
          [ "$1" = "--destination" ] && noted="$command $2"
          shift
        done
        echo "$noted" >> '\(calls.path)'
        [ -f '\(awake.path)' ] || exit 1
        case "$command" in
          "device copy") exit 0 ;;
          "device info") printf '{"result":{"apps":[{"bundleIdentifier":"\(app)"}]}}' > "$output" ;;
          *) exit 1 ;;
        esac
        """.write(to: devicectl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: devicectl.path)
        let hub = Hub(paths: paths, devicectl: Devicectl(executable: devicectl), apps: [app], claudeChats: { [] })
        hub.updateApps(isStarting: true)
        let link = PhoneLink(phone: .init(udid: phone, name: "Test iPhone", model: "iPhone 17 Pro"), hub: hub)
        func called() -> [String] {
            ((try? String(contentsOf: calls, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
        func waitForCalls(_ count: Int) async throws {
            for _ in 0..<50 where called().count < count { try await Task.sleep(for: .milliseconds(100)) }
        }

        try Data().write(to: awake)
        link.update(hosts: ["192.168.1.2"], port: 47361, includingNewApps: true)
        #expect(try await state(of: hub) { $0.hasPrefix("Ready") } == "Ready for \(app)")
        // The address goes under the new name and, for a build from before the rename, the old one.
        let given = ["device copy " + HubMessage.addressPath, "device copy " + HubMessage.earlierAddressPath]
        try await waitForCalls(2)
        #expect(called() == given)
        // The same address at the next discovery is written again, in case the app lost it.
        link.update(hosts: ["192.168.1.2"], port: 47361, includingNewApps: true)
        try await waitForCalls(4)
        #expect(called() == given + given)
        // A phone that can't be reached then keeps the address it has, with no retries.
        try FileManager.default.removeItem(at: awake)
        link.update(hosts: ["192.168.1.2"], port: 47361, includingNewApps: true)
        try await waitForCalls(6)
        try await Task.sleep(for: .milliseconds(300))
        #expect(called() == given + given + ["device copy " + HubMessage.addressPath, "device info"])
        #expect(try await state(of: hub) { _ in true } == "Ready for \(app)")
        // Without a discovery, nothing is written.
        link.update(hosts: ["192.168.1.2"], port: 47361, includingNewApps: false)
        try await Task.sleep(for: .milliseconds(300))
        #expect(called().count == 6)
        hub.flushWrites()
    }

    @Test func aPhoneSaysWhenTheMacIsOffEveryNetwork() async throws {
        try FileManager.default.createDirectory(at: paths.hub, withIntermediateDirectories: true)
        // Stands in for devicectl, noting each call; the phone always answers.
        let calls = paths.root.appending(path: "calls")
        let devicectl = paths.root.appending(path: "devicectl")
        try """
        #!/bin/sh
        echo "$1 $2" >> '\(calls.path)'
        [ "$1 $2" = "device copy" ]
        """.write(to: devicectl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: devicectl.path)
        let hub = Hub(paths: paths, devicectl: Devicectl(executable: devicectl), apps: [app], claudeChats: { [] })
        hub.updateApps(isStarting: true)
        let link = PhoneLink(phone: .init(udid: phone, name: "Test iPhone", model: "iPhone 17 Pro"), hub: hub)
        func called() -> Int {
            ((try? String(contentsOf: calls, encoding: .utf8)) ?? "").split(separator: "\n").count
        }
        let offline = PhoneState.macOffline.description

        // The hub started with the Mac off every network: the phone is listed, not left out.
        link.macDidGoOffline()
        #expect(try await state(of: hub) { _ in true } == offline)
        #expect(called() == 0)
        link.update(hosts: ["192.168.1.2"], port: 47361, includingNewApps: true)
        #expect(try await state(of: hub) { $0.hasPrefix("Ready") } == "Ready for \(app)")
        // The Mac leaves its network: the phone is no longer shown as ready.
        link.macDidGoOffline()
        #expect(try await state(of: hub) { $0 == offline } == offline)
        // Back on the same network, the phone is ready again without being given the address again:
        // the only copies are the first ones, under the new name and the one from before the rename.
        link.update(hosts: ["192.168.1.2"], port: 47361, includingNewApps: false)
        #expect(try await state(of: hub) { $0.hasPrefix("Ready") } == "Ready for \(app)")
        #expect(called() == 2)
        hub.flushWrites()
    }
}
#endif
