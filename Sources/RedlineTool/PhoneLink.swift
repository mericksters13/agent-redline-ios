#if os(macOS)
import Foundation

/// One paired phone. Leaves the hub's address and a token in each watched app's folder on it,
/// once and again only when the address changes. The apps send their reports themselves, so
/// nothing runs while the phone is quiet.
///
/// Thread safety: `address`, `given`, `missing`, `retryDelay`, `retryAt` and `lastWakeTry` are
/// read and written only on `queue`.
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
    private var retryDelay = PhoneLink.firstRetry
    private var retryAt: Date?
    /// When a wake last made this phone try. One wake is often announced on more than one
    /// network interface, and should lead to one try.
    private var lastWakeTry = Date.distantPast

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

    /// Gives the address to every watched app that doesn't have it yet. `rediscover` looks
    /// again for apps that weren't installed.
    func update(hosts: [String], port: UInt16, rediscover: Bool) {
        queue.async {
            let address = HubMessage.Address(device: self.phone.udid, hosts: hosts, port: port)
            if address != self.address || rediscover {
                self.address = address
                self.missing = []
                self.retryDelay = Self.firstRetry
            }
            self.giveAddress()
        }
    }

    /// A phone woke up somewhere on the network. If this one is still waiting to try again, try
    /// now instead of waiting out the delay, which grows while a phone sleeps: it's awake and
    /// likely about to be used. The wake also starts the delays over, so a try made before the
    /// phone's link is fully up is followed soon by another.
    func phoneWoke() {
        queue.async {
            guard self.retryAt != nil, Date().timeIntervalSince(self.lastWakeTry) >= Self.wakeSpacing else { return }
            self.lastWakeTry = Date()
            self.retryDelay = Self.firstRetry
            self.giveAddress()
        }
    }

    private func giveAddress() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let address else { return }
        retryAt = nil
        var unreachable = false
        // Read once: an app added during this pass waits for the next one.
        let apps = hub.apps
        let addresses = Dictionary(uniqueKeysWithValues: apps.map { bundleID in
            var app = address
            app.token = hub.token(device: phone.udid, bundleID: bundleID)
            return (bundleID, app)
        })
        for (bundleID, address) in addresses.sorted(by: { $0.key < $1.key }) where given[bundleID] != address && !missing.contains(bundleID) {
            if hub.devicectl.write(HubMessage.encode(address), to: HubMessage.addressPath, of: bundleID, on: phone.udid) {
                given[bundleID] = address
                hub.log("Gave \(bundleID) on \(phone.name) the hub's address")
                continue
            }
            // Either the app isn't installed, or the phone can't be reached right now.
            switch hub.devicectl.installation(of: bundleID, on: phone.udid) {
            case .notInstalled: missing.insert(bundleID)
            case .installed, .unreachable: unreachable = true
            }
        }
        let ready = apps.filter { given[$0] == addresses[$0] }
        if unreachable {
            retryAt = Date().addingTimeInterval(retryDelay)
            hub.phoneChanged(phone, state: .unreachable(retryInSeconds: Int(retryDelay)))
            let delay = retryDelay
            retryDelay = min(retryDelay * 2, Self.longestRetry)
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let retryAt, Date() >= retryAt.addingTimeInterval(-1) else { return }
                giveAddress()
            }
        } else if ready.isEmpty {
            hub.phoneChanged(phone, state: .noWatchedApps)
        } else {
            retryDelay = Self.firstRetry
            hub.phoneChanged(phone, state: .ready(apps: ready))
        }
    }
}
#endif
