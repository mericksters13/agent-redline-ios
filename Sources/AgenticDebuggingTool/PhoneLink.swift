#if os(macOS)
import Foundation

/// One paired phone. Leaves the hub's address and a token in each watched app's folder on it,
/// once and again only when the address changes. The apps send their reports themselves, so
/// nothing runs while the phone is quiet.
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

    static let firstRetry: TimeInterval = 30
    static let longestRetry: TimeInterval = 1800

    init(phone: Devicectl.Phone, hub: Hub) {
        self.phone = phone
        self.hub = hub
        queue = DispatchQueue(label: "phone.\(phone.udid)")
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

    /// A phone woke up somewhere on the network. If this one still needs its address and its
    /// wait is over, try now: it's awake and likely about to be used.
    func phoneWoke() {
        queue.async {
            guard let retryAt = self.retryAt, Date() >= retryAt else { return }
            self.giveAddress()
        }
    }

    private func giveAddress() {
        guard let address else { return }
        retryAt = nil
        var unreachable = false
        let addresses = Dictionary(uniqueKeysWithValues: hub.apps.map { bundleID in
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
            if hub.devicectl.isInstalled(bundleID, on: phone.udid) == false {
                missing.insert(bundleID)
            } else {
                unreachable = true
            }
        }
        let ready = hub.apps.filter { given[$0] == addresses[$0] }
        if unreachable {
            retryAt = Date().addingTimeInterval(retryDelay)
            hub.phoneChanged(phone, state: "Not reachable, trying again in \(Int(retryDelay)) s or when a phone wakes")
            let delay = retryDelay
            retryDelay = min(retryDelay * 2, Self.longestRetry)
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let retryAt = self.retryAt, Date() >= retryAt.addingTimeInterval(-1) else { return }
                self.giveAddress()
            }
        } else if ready.isEmpty {
            hub.phoneChanged(phone, state: "None of the watched apps installed")
        } else {
            retryDelay = Self.firstRetry
            hub.phoneChanged(phone, state: "Ready for \(ready.joined(separator: ", "))")
        }
    }
}
#endif
