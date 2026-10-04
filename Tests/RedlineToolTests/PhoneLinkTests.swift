#if os(macOS)
import Foundation
import Testing
@testable import RedlineTool

struct PhoneLinkTests {
    private let temporary = TemporaryFolder("PhoneLinkTests")
    private var paths: HubPaths { HubPaths(root: temporary.url) }
    private let phone = "00000000-0000000000000001"
    private let app = "com.example.app"

    /// The hub's state for the phone once `done` accepts it, waiting up to five seconds. The hub
    /// publishes no event when a phone's state changes, only the status file, so this polls it.
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
        let link = PhoneLink(phone: .init(udid: phone, name: "Test iPhone", model: "iPhone 17 Pro"), hub: hub)

        link.update(hosts: ["192.168.1.2"], port: 47361, includingNewApps: true)
        #expect(try await state(of: hub) { $0.hasPrefix("Not reachable") }?.hasPrefix("Not reachable, trying again in 30 s") == true)
        // The phone wakes long before the 30 seconds are up, and gets its address right away.
        try Data().write(to: awake)
        link.phoneDidWake()
        #expect(try await state(of: hub) { $0.hasPrefix("Ready") } == "Ready for \(app)")
        hub.flushWrites()
    }
}
#endif
