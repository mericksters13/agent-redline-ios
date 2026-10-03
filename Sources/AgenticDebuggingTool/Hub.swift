#if os(macOS)
import Foundation
import Network

/// Where the tool keeps things on the Mac.
///
/// - `inbox/<bundle ID>/<report>/`: reports taken off phones and simulators, each with a `source.json`
/// - `hub/state.json`: which reports each phone and simulator app has already given
/// - `hub/status.json`, `hub/hub.pid`, `hub/hub.log`: for `agentic-debugging status`
struct HubPaths: Sendable {
    let root: URL

    static let standard = HubPaths(root: URL.applicationSupportDirectory.appending(path: "iOSAgenticDebuggingKit", directoryHint: .isDirectory))

    var inbox: URL { root.appending(path: "inbox", directoryHint: .isDirectory) }
    var hub: URL { root.appending(path: "hub", directoryHint: .isDirectory) }
    var state: URL { hub.appending(path: "state.json") }
    var status: URL { hub.appending(path: "status.json") }
    var pid: URL { hub.appending(path: "hub.pid") }
    var log: URL { hub.appending(path: "hub.log") }
}

/// Where a report came from, saved next to it in the inbox.
struct ReportSource: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case phone, simulator }

    var kind: Kind
    /// The phone's or simulator's UDID.
    var device: String
    var deviceName: String
    var bundleID: String
    var reportID: String
    var receivedAt: Date
}

/// What the hub tells `agentic-debugging status`.
struct HubStatus: Codable, Sendable {
    struct Phone: Codable, Sendable {
        var name: String
        var udid: String
        var state: String
    }

    var pid: Int32
    var startedAt: Date
    var apps: [String]
    /// Where apps reach the hub.
    var hosts: [String]
    var port: UInt16
    var phones: [Phone]
    var simulatorContainers: Int
}

/// Takes reports off paired phones and simulators and files them in the inbox. An app on a
/// phone offers its reports over the local network and the hub copies them over Xcode's device
/// link; simulator apps' folders are on the Mac, so the hub sees their reports as they're saved.
final class Hub: @unchecked Sendable {
    let paths: HubPaths
    let devicectl: Devicectl
    let apps: [String]
    private let startedAt = Date()
    private let lock = NSLock()
    private var state: [String: SourceState] = [:]
    private var links: [String: PhoneLink] = [:]
    private var phoneStates: [String: HubStatus.Phone] = [:]
    private var hosts: [String] = []
    private var simulators: SimulatorWatcher?
    private var listener: HubListener?
    private let queue = DispatchQueue(label: "hub")
    private var discovery: DispatchSourceTimer?
    private let network = NWPathMonitor()

    /// A report finished up to this long before the hub first looked at its app still counts
    /// as new: the phone's clock and the Mac's can disagree by a little.
    static let firstLookMargin: TimeInterval = 120
    /// How often the hub looks for newly paired phones and newly installed apps. Changes to the
    /// Mac's network are noticed as they happen.
    static let discoveryInterval: TimeInterval = 1800

    init(paths: HubPaths, devicectl: Devicectl, apps: [String]) {
        self.paths = paths
        self.devicectl = devicectl
        self.apps = apps
        if let data = try? Data(contentsOf: paths.state), let saved = try? Self.decoder.decode([String: SourceState].self, from: data) {
            state = saved
        }
    }

    func start() {
        try? FileManager.default.createDirectory(at: paths.hub, withIntermediateDirectories: true)
        try? Data("\(getpid())".utf8).write(to: paths.pid, options: .atomic)
        log("Hub started for \(apps.joined(separator: ", "))")
        let simulators = SimulatorWatcher(hub: self)
        self.simulators = simulators
        let listener = HubListener(hub: self)
        listener.start()
        self.listener = listener
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Self.discoveryInterval, leeway: .seconds(60))
        timer.setEventHandler { [weak self] in self?.discover(rediscover: true) }
        timer.resume()
        discovery = timer
        // A new Wi-Fi network or address means apps need the new address.
        network.pathUpdateHandler = { [weak self] _ in
            guard let self, Self.addresses() != self.lock.withLock({ self.hosts }) else { return }
            self.discover(rediscover: false)
        }
        network.start(queue: queue)
    }

    func stop() {
        discovery?.cancel()
        network.cancel()
        listener?.stop()
        simulators?.stop()
        try? FileManager.default.removeItem(at: paths.pid)
        log("Hub stopped")
    }

    /// Gives every paired phone's watched apps the hub's current address. `rediscover` also
    /// looks again for newly paired phones' apps and simulator apps installed since the last look.
    private func discover(rediscover: Bool) {
        let hosts = Self.addresses()
        lock.withLock { self.hosts = hosts }
        if rediscover { simulators?.rescan() }
        guard let paired = devicectl.pairedPhones() else {
            log("Couldn't list paired phones")
            return
        }
        for phone in paired {
            link(for: phone).update(hosts: hosts, port: HubListener.port, rediscover: rediscover)
        }
        writeStatus()
    }

    private func link(for phone: Devicectl.Phone) -> PhoneLink {
        lock.withLock {
            if let link = links[phone.udid] { return link }
            let link = PhoneLink(phone: phone, hub: self)
            links[phone.udid] = link
            return link
        }
    }

    /// Some phone on the network woke up.
    func phoneWoke() {
        lock.withLock { links.values }.forEach { $0.phoneWoke() }
    }

    /// An app's offer of reports. Only reports from phones paired with this Mac are copied.
    func handle(_ offer: HubMessage.Offer, reply: @escaping @Sendable (HubMessage.Reply) -> Void) {
        queue.async {
            // Report IDs become paths on the phone and in the inbox.
            let safe = offer.reports.allSatisfy { $0.id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } && !$0.id.isEmpty }
            var link = self.lock.withLock { self.links[offer.device] }
            if link == nil, safe, let phone = self.devicectl.pairedPhones()?.first(where: { $0.udid == offer.device }) {
                link = self.link(for: phone)
            }
            guard safe, let link else {
                self.log("Ignored an offer from \(offer.device), not a phone paired with this Mac")
                reply(HubMessage.Reply(delivered: []))
                return
            }
            link.deliver(offer, reply: reply)
        }
    }

    /// The Mac's addresses on its local networks, then its `.local` name, which keeps working
    /// when the address changes.
    static func addresses() -> [String] {
        var found: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&list) == 0, let first = list {
            defer { freeifaddrs(list) }
            for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
                let interface = pointer.pointee
                let flags = Int32(interface.ifa_flags)
                let name = String(cString: interface.ifa_name)
                // Wi-Fi and Ethernet, not VPN tunnels or AirDrop's own links.
                guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0, name.hasPrefix("en"),
                      let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET)
                else { continue }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    found.append(String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
                }
            }
        }
        let name = ProcessInfo.processInfo.hostName
        if name.hasSuffix(".local") { found.append(name) }
        return found
    }

    // MARK: - Delivery

    /// The reports from one app on one device still to copy. The first look at a source only
    /// takes reports finished from about then on, so old ones aren't delivered as new.
    func toCopy(device: String, bundleID: String, finished: [FinishedReport]) -> [String] {
        lock.withLock {
            let key = "\(device)|\(bundleID)"
            if state[key] == nil {
                state[key] = SourceState(since: startedAt.addingTimeInterval(-Self.firstLookMargin))
                saveState()
            }
            return state[key]!.toCopy(from: finished)
        }
    }

    /// The offered reports the app can stop offering.
    func settled(device: String, bundleID: String, finished: [FinishedReport]) -> [String] {
        lock.withLock { state["\(device)|\(bundleID)"]?.settled(finished) ?? [] }
    }

    /// Files a report in the inbox. `copy` fills a folder that doesn't exist yet; the report
    /// appears in the inbox only once it's complete.
    func receive(_ source: ReportSource, copy: (URL) -> Bool) {
        let folder = paths.inbox.appending(path: source.bundleID, directoryHint: .isDirectory)
        let name = Inbox.folderName(reportID: source.reportID, device: source.device)
        let incoming = folder.appending(path: ".incoming-\(name)", directoryHint: .isDirectory)
        let destination = folder.appending(path: name, directoryHint: .isDirectory)
        let files = FileManager.default
        try? files.createDirectory(at: folder, withIntermediateDirectories: true)
        try? files.removeItem(at: incoming)
        let started = Date()
        guard copy(incoming) else {
            try? files.removeItem(at: incoming)
            log("Couldn't copy report \(source.reportID) of \(source.bundleID) from \(source.deviceName)")
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(source).write(to: incoming.appending(path: "source.json"))
        try? files.removeItem(at: destination)
        do {
            try files.moveItem(at: incoming, to: destination)
        } catch {
            log("Couldn't file report \(source.reportID): \(error.localizedDescription)")
            return
        }
        lock.withLock {
            state["\(source.device)|\(source.bundleID)", default: SourceState(since: startedAt)].delivered.append(source.reportID)
            saveState()
        }
        log(String(format: "Received %@ from %@ (%@) in %.2f s", source.reportID, source.deviceName, source.bundleID, Date().timeIntervalSince(started)))
    }

    // MARK: - Status

    func phoneChanged(_ phone: Devicectl.Phone, state description: String) {
        lock.withLock { phoneStates[phone.udid] = HubStatus.Phone(name: phone.name, udid: phone.udid, state: description) }
        writeStatus()
    }

    func writeStatus() {
        let containers = simulators?.containerCount ?? 0
        let status = lock.withLock {
            HubStatus(pid: getpid(), startedAt: startedAt, apps: apps, hosts: hosts, port: HubListener.port,
                      phones: phoneStates.values.sorted { $0.name < $1.name }, simulatorContainers: containers)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(status).write(to: paths.status, options: .atomic)
    }

    // MARK: - Helpers

    /// Called with the lock held.
    private func saveState() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(state).write(to: paths.state, options: .atomic)
    }

    func log(_ message: String) {
        let line = "\(Date().formatted(.iso8601)) \(message)\n"
        FileHandle.standardOutput.write(Data(line.utf8))
        if let handle = try? FileHandle(forWritingTo: paths.log) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: paths.log)
        }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
#endif
