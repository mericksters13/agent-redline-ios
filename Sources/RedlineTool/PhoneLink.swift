#if os(macOS)
import Foundation

/// One paired phone.
///
/// Leaves the hub's address and a token in each watched app's folder on it, again when the address
/// changes, and again at each discovery in case an app was reinstalled. The apps send their
/// reports themselves, so nothing runs while the phone is quiet.
///
/// Thread safety: `address`, `given`, `missing`, `recheck`, `retryDelay`, `retryAt` and
/// `lastWakeTry` and `isUnpaired` are read and written only on `queue`.
final class PhoneLink: @unchecked Sendable {
    let phone: Devicectl.Phone
    private unowned let hub: Hub
    /// Blocking `devicectl` calls for this phone run here, one at a time.
    private let queue: DispatchQueue
    private var address: HubMessage.Address?
    /// The address each app was given.
    private var given: [String: HubMessage.Address] = [:]
    /// Apps not on the phone at the last look; looked for again at the next discovery.
    private var missing = Set<String>()
    /// Apps given the address before the last discovery.
    ///
    /// Each gets it again, in case it was reinstalled since and lost it; a phone that can't be
    /// reached is left until the next discovery.
    private var recheck = Set<String>()
    private var retryDelay = PhoneLink.firstRetry
    private var retryAt: Date?
    /// When a wake last made this phone try.
    ///
    /// One wake is often announced on more than one network interface, and should lead to one try.
    private var lastWakeTry = Date.distantPast
    /// Set once the phone is no longer paired: the link stops trying and stops reporting.
    private var isUnpaired = false

    static let firstRetry: TimeInterval = 30
    /// The longest wait between tries, for a phone whose waking isn't announced, such as one
    /// that comes back into Wi-Fi range already awake.
    static let longestRetry: TimeInterval = 300
    static let wakeSpacing: TimeInterval = 10
    /// Every phone's blocking `devicectl` calls run on queues that target this one.
    private static let devices = DispatchQueue(label: "Redline.hub.devices", qos: .utility, attributes: .concurrent)

    init(phone: Devicectl.Phone, hub: Hub) {
        self.phone = phone
        self.hub = hub
        queue = DispatchQueue(label: "Redline.hub.phone", target: Self.devices)
    }

    /// Gives the address to every watched app that doesn't have it yet. `includingNewApps` looks
    /// again for apps that weren't installed, and gives it again to those that have it.
    func update(hosts: [String], port: UInt16, includingNewApps: Bool) {
        queue.async {
            let address = HubMessage.Address(device: self.phone.udid, hosts: hosts, port: port)
            if address != self.address || includingNewApps {
                self.address = address
                self.missing = []
                self.retryDelay = Self.firstRetry
            }
            if includingNewApps { self.recheck = Set(self.given.keys) }
            self.giveAddress()
        }
    }

    /// A phone woke up somewhere on the network.
    ///
    /// If this one is still waiting to try again, try now instead of waiting out the delay, which
    /// grows while a phone sleeps: it's awake and likely about to be used. The wake also starts the
    /// delays over, so a try made before the phone's link is fully up is followed soon by another.
    func phoneDidWake() {
        queue.async {
            guard self.retryAt != nil, Date.now.timeIntervalSince(self.lastWakeTry) >= Self.wakeSpacing else { return }
            self.lastWakeTry = Date.now
            self.retryDelay = Self.firstRetry
            self.giveAddress()
        }
    }

    /// The phone is no longer paired: the link stops trying, and `done` runs once a try in progress
    /// has finished, so nothing it reports comes after.
    func unpair(then done: @escaping @Sendable () -> Void) {
        queue.async {
            self.isUnpaired = true
            self.retryAt = nil
            done()
        }
    }

    private func giveAddress() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isUnpaired, let address else { return }
        retryAt = nil
        var unreachable = false
        // Read once: an app added during this pass waits for the next one.
        let apps = hub.apps
        let addresses = Dictionary(
            uniqueKeysWithValues: apps.map { bundleID in
                var app = address
                app.token = hub.issueToken(device: phone.udid, bundleID: bundleID)
                return (bundleID, app)
            }
        )
        for (bundleID, address) in addresses.sorted(by: { $0.key < $1.key })
        where (given[bundleID] != address || recheck.contains(bundleID)) && !missing.contains(bundleID) {
            let isRechecking = recheck.remove(bundleID) != nil && given[bundleID] == address
            if hub.devicectl.write(HubMessage.encode(address), to: HubMessage.addressPath, of: bundleID, on: phone.udid)
            {
                if !isRechecking { hub.log("Gave \(bundleID) on \(phone.name) the hub's address") }
                given[bundleID] = address
                continue
            }
            // Either the app isn't installed, or the phone can't be reached right now.
            switch hub.devicectl.installation(of: bundleID, on: phone.udid) {
            case .notInstalled:
                missing.insert(bundleID)
                given[bundleID] = nil
            case .installed, .unreachable:
                // Rechecked, it most likely still has the address; the next discovery checks again.
                if !isRechecking { unreachable = true }
            }
        }
        let ready = apps.filter { given[$0] == addresses[$0] }
        if unreachable {
            retryAt = Date.now.addingTimeInterval(retryDelay)
            hub.phoneDidChange(phone, state: .unreachable(retryInSeconds: Int(retryDelay)))
            let delay = retryDelay
            retryDelay = min(retryDelay * 2, Self.longestRetry)
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let retryAt, Date.now >= retryAt.addingTimeInterval(-1) else { return }
                giveAddress()
            }
        } else if ready.isEmpty {
            hub.phoneDidChange(phone, state: .noWatchedApps)
        } else {
            retryDelay = Self.firstRetry
            hub.phoneDidChange(phone, state: .ready(apps: ready))
        }
    }
}
#endif
