#if os(macOS)
import Foundation
import Network
import Security

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
    /// The token each app on each phone was given; secret, readable only by the user.
    var tokens: URL { hub.appending(path: "tokens.json") }
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
        /// "iPhone 17 Pro": tells apart phones with the same name.
        var model: String? = nil
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
    /// Apps given on the command line, watched whether or not a chat is open for them.
    private let fixedApps: [String]
    private var currentApps: [String] = []
    private var chatsWatcher: DispatchSourceFileSystemObject?
    private let startedAt = Date()
    private let lock = NSLock()
    private var state: [String: SourceState] = [:]
    private var tokens: [String: String] = [:]
    private var links: [String: PhoneLink] = [:]
    private var phoneStates: [String: HubStatus.Phone] = [:]
    private var hosts: [String] = []
    private var simulators: SimulatorWatcher?
    private var listener: HubListener?
    private var handoff: Handoff?
    private let queue = DispatchQueue(label: "hub")
    private var discovery: DispatchSourceTimer?
    private let network = NWPathMonitor()

    /// A report finished up to this long before the hub first looked at its app still counts
    /// as new: the phone's clock and the Mac's can disagree by a little.
    static let firstLookMargin: TimeInterval = 120
    /// How often the hub looks for newly paired phones and newly installed apps. Changes to the
    /// Mac's network are noticed as they happen.
    static let discoveryInterval: TimeInterval = 1800

    /// The apps the hub takes reports from: those of the open chats, and any given on the command line.
    var apps: [String] { lock.withLock { currentApps } }

    init(paths: HubPaths, devicectl: Devicectl, apps: [String]) {
        self.paths = paths
        self.devicectl = devicectl
        fixedApps = apps
        if let data = try? Data(contentsOf: paths.state), let saved = try? Self.decoder.decode([String: SourceState].self, from: data) {
            state = saved
        }
        if let data = try? Data(contentsOf: paths.tokens), let saved = try? Self.decoder.decode([String: String].self, from: data) {
            tokens = saved
        }
    }

    func start() {
        try? FileManager.default.createDirectory(at: paths.hub, withIntermediateDirectories: true)
        try? Data("\(getpid())".utf8).write(to: paths.pid, options: .atomic)
        updateApps(starting: true)
        log(apps.isEmpty ? "Hub started; no chats open yet" : "Hub started for \(apps.joined(separator: ", "))")
        watchChats()
        handoff = Handoff(hub: self)
        ChatDirectory.warm(paths: paths)
        handoff?.handOverRecent()
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
        chatsWatcher?.cancel()
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

    /// A chat opening or closing changes the apps to take reports from.
    private func watchChats() {
        let folder = Chats.folder(paths)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: queue)
        source.setEventHandler { [weak self] in self?.updateApps(starting: false) }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        chatsWatcher = source
    }

    func updateApps(starting: Bool) {
        let apps = Array(Set(fixedApps + Chats.live(paths).flatMap(\.bundleIDs))).sorted()
        let changed = lock.withLock {
            defer { currentApps = apps }
            return currentApps != apps
        }
        guard changed, !starting else { return }
        log(apps.isEmpty ? "No chats open" : "Taking reports from \(apps.joined(separator: ", "))")
        // New apps' simulator folders to watch and phones to give the address to.
        simulators?.rescan()
        queue.async { self.discover(rediscover: true) }
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

    // MARK: - Offers from apps

    /// The token for an app on a phone. Made once and kept, so the address the app has stays
    /// good when the hub restarts.
    func token(device: String, bundleID: String) -> String {
        lock.withLock {
            let key = "\(device)|\(bundleID)"
            if let token = tokens[key] { return token }
            var bytes = [UInt8](repeating: 0, count: 32)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            let token = bytes.map { String(format: "%02x", $0) }.joined()
            tokens[key] = token
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? encoder.encode(tokens).write(to: paths.tokens, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.tokens.path)
            return token
        }
    }

    /// The hub's answer to an app's offer: the reports to send now, and the ones the app can
    /// stop offering. Only an app that was given this hub's address, and so is on a phone paired
    /// with this Mac, can deliver.
    func answer(_ offer: HubMessage.Offer) -> HubMessage.Answer {
        let expected = lock.withLock { tokens["\(offer.device)|\(offer.bundleID)"] }
        guard let expected, Self.same(expected, offer.token) else {
            log("Turned down \(offer.bundleID) from \(phoneName(offer.device)): \(expected == nil ? "this hub never gave it an address" : "its token doesn't match")")
            return HubMessage.Answer(want: [], delivered: [], refused: "The app needs this Mac's address again; it gets it the next time Xcode can reach the phone.")
        }
        // Report IDs become folder names in the inbox.
        guard offer.reports.allSatisfy({ Self.isSafeName($0.id) }) else {
            log("Turned down \(offer.bundleID) from \(phoneName(offer.device)): a report name it can't use")
            return HubMessage.Answer(want: [], delivered: [], refused: "Report names")
        }
        let finished = offer.reports.map { FinishedReport(id: $0.id, finishedAt: $0.finishedAt) }
        let want = toCopy(device: offer.device, bundleID: offer.bundleID, finished: finished)
        log("\(phoneName(offer.device)) offered \(offer.reports.count) of \(offer.bundleID)'s reports; \(want.isEmpty ? "the Mac has them all" : "taking \(want.count)")")
        return HubMessage.Answer(want: want, delivered: settled(device: offer.device, bundleID: offer.bundleID, finished: finished))
    }

    /// The chats a report from this app can go to, for the phone to show before the user sends.
    func chats(_ request: HubMessage.ChatsRequest) -> HubMessage.ChatList {
        let expected = lock.withLock { tokens["\(request.device)|\(request.bundleID)"] }
        guard let expected, Self.same(expected, request.token) else {
            log("Turned down \(request.bundleID)'s question about chats from \(phoneName(request.device)): its token doesn't match")
            return HubMessage.ChatList(agents: [], chats: [], refused: "The app needs this Mac's address again.")
        }
        return ChatDirectory.list(bundleID: request.bundleID, sourceFile: request.sourceFile, paths: paths)
    }

    /// Files a report the hub asked for. False when it can't be filed.
    @discardableResult
    func store(_ upload: HubMessage.Upload, offeredIn offer: HubMessage.Offer) -> Bool {
        let total = upload.files.values.reduce(0) { $0 + $1.count }
        guard Self.isSafeName(upload.id), upload.files.keys.allSatisfy(Self.isSafeName), total <= Self.largestReport,
              upload.files["report.json"] != nil
        else {
            log("Couldn't use report \(upload.id) of \(offer.bundleID): missing its report.json, a file name it can't use, or over \(Self.largestReport / 1_000_000) MB")
            return false
        }
        let source = ReportSource(kind: .phone, device: offer.device, deviceName: phoneName(offer.device), bundleID: offer.bundleID,
                                  reportID: upload.id, receivedAt: Date())
        return receive(source) { destination in
            do {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                for (name, data) in upload.files { try data.write(to: destination.appending(path: name)) }
                return true
            } catch {
                return false
            }
        }
    }

    /// A report bigger than this isn't taken: a phone screen's picture is about 100 KB.
    static let largestReport = 50_000_000

    private func phoneName(_ udid: String) -> String {
        lock.withLock { links[udid]?.phone.name } ?? "A phone"
    }

    /// File and report names: letters, digits, dots, dashes and underscores, not starting with a dot.
    static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
    }

    /// Compares tokens in time that doesn't depend on where they differ.
    static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
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
    /// appears in the inbox only once it's complete. False when it couldn't be filed.
    @discardableResult
    func receive(_ source: ReportSource, copy: (URL) -> Bool) -> Bool {
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
            return false
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
            return false
        }
        lock.withLock {
            state["\(source.device)|\(source.bundleID)", default: SourceState(since: startedAt)].delivered.append(source.reportID)
            saveState()
        }
        log(String(format: "Received %@ from %@ (%@) in %.2f s", source.reportID, source.deviceName, source.bundleID, Date().timeIntervalSince(started)))
        handoff?.reportFiled(destination, source: source)
        return true
    }

    // MARK: - Status

    func phoneChanged(_ phone: Devicectl.Phone, state description: String) {
        lock.withLock { phoneStates[phone.udid] = HubStatus.Phone(name: phone.name, udid: phone.udid, state: description,
                                                                             model: phone.model.isEmpty ? nil : phone.model) }
        writeStatus()
    }

    /// What the hub is doing now, as `status` and the menu bar panel show it.
    func statusSnapshot() -> HubStatus {
        let containers = simulators?.containerCount ?? 0
        return lock.withLock {
            HubStatus(pid: getpid(), startedAt: startedAt, apps: currentApps, hosts: hosts, port: HubListener.port,
                      phones: phoneStates.values.sorted { $0.name < $1.name }, simulatorContainers: containers)
        }
    }

    /// The simulators with a watched app installed.
    func watchedSimulators() -> Set<String> {
        simulators?.simulatorIDs ?? []
    }

    func writeStatus() {
        let status = statusSnapshot()
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
