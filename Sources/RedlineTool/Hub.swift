#if os(macOS)
import Foundation
import Network
import Security
import SystemConfiguration

/// Where the tool keeps things on the Mac.
///
/// - `inbox/<bundle ID>/<report>/`: reports taken off phones and simulators, each with a `source.json`
/// - `hub/state.json`: which reports each phone and simulator app has already given
/// - `hub/status.json`, `hub/hub.pid`, `hub/hub.log`: for `redline status`
struct HubPaths: Sendable {
    let root: URL

    static let standard = HubPaths(root: URL.applicationSupportDirectory.appending(path: "Redline", directoryHint: .isDirectory))

    var inbox: URL { root.appending(path: "inbox", directoryHint: .isDirectory) }
    var hub: URL { root.appending(path: "hub", directoryHint: .isDirectory) }
    var state: URL { hub.appending(path: "state.json") }
    var status: URL { hub.appending(path: "status.json") }
    var pid: URL { hub.appending(path: "hub.pid") }
    var log: URL { hub.appending(path: "hub.log") }
    /// The token each app on each phone was given; secret, readable only by the user.
    var tokens: URL { hub.appending(path: "tokens.json") }

    /// What `moveFromOldName` did.
    enum OldFolderMove: Equatable {
        /// Nothing had to stop: the folder moved, or there was nothing to move.
        case done
        /// The folder moved once the earlier version's hub stopped. This version's has to take
        /// over, watching the apps that hub was given on the command line.
        case stoppedHub(fixedApps: [String])
        /// The folder couldn't move yet, for the reason given. Nothing may use this version's
        /// folder until it has, or what the earlier version kept would stay behind for good.
        case blocked(String)
    }

    /// Moves the folder an earlier version kept under its old name, iOSAgenticDebuggingKit, to
    /// this one, so reports, chats and settings carry over. Only while nothing is here yet. A hub
    /// of the earlier version that is still running knows only the old folder, so it's stopped
    /// first; if it doesn't stop in time, such as while it hands a report over, nothing moves
    /// and the result says why. Only a process holding the old PID file's lock is that hub, so a
    /// pid left behind by a hub that crashed, and since reused, is never signaled.
    /// The old name is left as a link to the new folder: an MCP server of the earlier version
    /// still serving an open chat knows only the old folder, and through the link it keeps
    /// reading the same inbox and chat records as this version's hub.
    @discardableResult
    static func moveFromOldName(to paths: HubPaths) -> OldFolderMove {
        let old = HubPaths(root: paths.root.deletingLastPathComponent().appending(path: "iOSAgenticDebuggingKit", directoryHint: .isDirectory))
        let files = FileManager.default
        guard files.fileExists(atPath: old.root.path), !files.fileExists(atPath: paths.root.path) else { return .done }
        var stoppedHub = false
        var fixedApps: [String] = []
        if let running = HubProcess.running(old), running != getpid() {
            // Read before it stops: the apps it was given on the command line. A hub from before
            // fixedApps was saved lists them only among all its apps.
            if let status = HubWindowModel.savedStatus(old), status.pid == running { fixedApps = status.fixedApps ?? status.apps }
            kill(running, SIGTERM)
            for _ in 0..<30 where HubProcess.running(old) != nil { usleep(100_000) }
            guard HubProcess.running(old) == nil else {
                return .blocked("The hub of an earlier version (pid \(running)) is still running, so its folder can't move to Redline's yet. It stops on its own once the reports it's handing over reach their chats; run redline again then.")
            }
            stoppedHub = true
        }
        do {
            try files.moveItem(at: old.root, to: paths.root)
        } catch {
            return .blocked("Couldn't move \(old.root.path) to \(paths.root.path): \(error.localizedDescription)")
        }
        do {
            try files.createSymbolicLink(at: old.root, withDestinationURL: paths.root)
        } catch {
            FileHandle.standardError.write(Data("Couldn't leave a link to \(paths.root.path) at \(old.root.path): \(error.localizedDescription)\n".utf8))
        }
        return stoppedHub ? .stoppedHub(fixedApps: fixedApps) : .done
    }
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

/// What the hub tells `redline status`.
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
    /// The apps given on the command line, which a hub taking over keeps watching.
    var fixedApps: [String]? = nil
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
    /// The PID file, held open and locked while the hub runs.
    private var pidFile: Int32?
    /// Held while the hub stops; `stopped` once it has.
    private let stopping = NSLock()
    private var stopped = false

    /// How often the hub looks for newly paired phones and newly installed apps. Changes to the
    /// Mac's network are noticed as they happen.
    static let discoveryInterval: TimeInterval = 1800

    /// The apps the hub takes reports from: those of the open chats and of chats before them,
    /// and any given on the command line.
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

    /// Starts the hub. False when another hub already holds the PID file.
    func start() -> Bool {
        try? FileManager.default.createDirectory(at: paths.hub, withIntermediateDirectories: true)
        guard let pidFile = HubProcess.claim(paths) else { return false }
        self.pidFile = pidFile
        updateApps(starting: true)
        // Before anything else, so the menu bar app taking over from this hub finds the apps
        // it was given on the command line.
        writeStatus()
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
        // A listener that failed at once has stopped the hub, and `whenListenerFails` says so.
        guard stopping.withLock({ !stopped }) else { return true }
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
        return true
    }

    /// Stops taking reports, lets the reports being handed over reach their chats, then lets go
    /// of the PID file. A hub that starts next, such as the menu bar app taking over, hands over
    /// again only what this one gave back, so no report starts two chats. Called again, it
    /// waits for the first call to finish.
    func stop() {
        stopping.lock()
        defer { stopping.unlock() }
        guard !stopped else { return }
        stopped = true
        discovery?.cancel()
        chatsWatcher?.cancel()
        network.cancel()
        listener?.stop()
        simulators?.stop()
        handoff?.finish()
        try? FileManager.default.removeItem(at: paths.pid)
        if let pidFile { close(pidFile) }
        log("Hub stopped")
    }

    /// Set before `start` by the menu bar app, which shows why the listener failed and then exits.
    var whenListenerFails: (@Sendable (String) -> Void)?

    /// The hub can't take reports without its listener: it stops, so the next chat starts a new
    /// one, and exits, or first tells `whenListenerFails`.
    func listenerFailed(_ reason: String) {
        log(reason)
        stop()
        guard let whenListenerFails else { exit(1) }
        whenListenerFails(reason)
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
        forgetPhones(except: Set(paired.map(\.udid)))
        for phone in paired {
            let link = link(for: phone)
            // Off every network, phones keep the address they have, which works again once the
            // Mac is back on theirs; the new address follows as soon as the Mac has one.
            if hosts.isEmpty {
                link.macOffline()
            } else {
                link.update(hosts: hosts, port: HubListener.port, rediscover: rediscover)
            }
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
        // Apps a chat worked on before stay watched after it closes, so their reports still
        // arrive and can start a new chat.
        let apps = Array(Set(fixedApps + Chats.live(paths).flatMap(\.bundleIDs) + ProjectHistory.all(paths).keys)).sorted()
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

    /// A report bigger than this isn't taken: a phone screen's picture is about 100 KB. The app
    /// checks its reports against the same size, `ReportStore.largestReport`, before sending.
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

    /// The Mac's IPv4 addresses on its local networks, then its `.local` name, which keeps
    /// working when the address changes and is the only way to reach the Mac on an IPv6-only
    /// network. None while no Wi-Fi or Ethernet link has an address, since phones can't reach
    /// the Mac by any of them then.
    static func addresses() -> [String] {
        var found: [String] = []
        var onNetwork = false
        var list: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&list) == 0, let first = list {
            defer { freeifaddrs(list) }
            for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
                let interface = pointer.pointee
                let flags = Int32(interface.ifa_flags)
                let name = String(cString: interface.ifa_name)
                // Wi-Fi and Ethernet, not VPN tunnels or AirDrop's own links.
                guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0, name.hasPrefix("en"),
                      let address = interface.ifa_addr
                else { continue }
                if address.pointee.sa_family == UInt8(AF_INET6) {
                    let ipv6 = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                    if isOnNetwork(ipv6) { onNetwork = true }
                    continue
                }
                guard address.pointee.sa_family == UInt8(AF_INET) else { continue }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    found.append(String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
                    onNetwork = true
                }
            }
        }
        // The name the Mac answers to over Bonjour, as set in Sharing settings.
        if onNetwork, let name = SCDynamicStoreCopyLocalHostName(nil) as String? { found.append("\(name).local") }
        return found
    }

    /// Whether an IPv6 address comes from a network rather than only from the link being up:
    /// every active interface has a link-local address (fe80::/10), with or without a network.
    static func isOnNetwork(_ address: in6_addr) -> Bool {
        let bytes = withUnsafeBytes(of: address) { Array($0) }
        let linkLocal = bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80
        return !linkLocal && bytes != Array(repeating: 0, count: 16)
    }

    // MARK: - Delivery

    /// The reports from one app on one device still to copy. A phone offers only reports the
    /// Mac hasn't confirmed, and a simulator's reports without the delivered mark are the same,
    /// so every one is taken, including those sent before this hub first saw the app.
    func toCopy(device: String, bundleID: String, finished: [FinishedReport]) -> [String] {
        lock.withLock { (state["\(device)|\(bundleID)"] ?? SourceState()).toCopy(from: finished) }
    }

    /// The offered reports the app can stop offering.
    func settled(device: String, bundleID: String, finished: [FinishedReport]) -> [String] {
        lock.withLock { state["\(device)|\(bundleID)"]?.settled(finished) ?? [] }
    }

    /// Files a report in the inbox. `copy` fills a folder that doesn't exist yet; the report
    /// appears in the inbox only once it's complete. False when it couldn't be filed.
    ///
    /// The same report can arrive twice at once, such as from two offers sent back to back.
    /// Each copy fills its own folder, and the first to finish is the one filed.
    @discardableResult
    func receive(_ source: ReportSource, copy: (URL) -> Bool) -> Bool {
        let folder = paths.inbox.appending(path: source.bundleID, directoryHint: .isDirectory)
        let name = Inbox.folderName(reportID: source.reportID, device: source.device)
        let incoming = folder.appending(path: ".incoming-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        let destination = folder.appending(path: name, directoryHint: .isDirectory)
        let files = FileManager.default
        try? files.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: incoming) }
        let started = Date()
        guard copy(incoming) else {
            log("Couldn't copy report \(source.reportID) of \(source.bundleID) from \(source.deviceName)")
            return false
        }
        // The inbox lists a report only by its source.json, so without one it isn't filed. Its
        // date keeps milliseconds, so reports received in the same second stay in order.
        do {
            try Chats.coder.encode(source).write(to: incoming.appending(path: "source.json"))
        } catch {
            log("Couldn't file report \(source.reportID): \(error.localizedDescription)")
            return false
        }
        let key = "\(source.device)|\(source.bundleID)"
        let filed: Bool? = lock.withLock {
            if state[key]?.delivered.contains(source.reportID) == true { return nil }
            // Left by an attempt whose filing wasn't recorded, such as one cut short by a crash.
            try? files.removeItem(at: destination)
            do {
                try files.moveItem(at: incoming, to: destination)
            } catch {
                log("Couldn't file report \(source.reportID): \(error.localizedDescription)")
                return false
            }
            state[key, default: SourceState()].delivered.append(source.reportID)
            saveState()
            return true
        }
        guard let filed else { return true }
        guard filed else { return false }
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

    /// Phones no longer paired leave the status, and their links stop giving them the address.
    /// A link's state goes once the try it has in progress is over, so that try can't bring it back.
    func forgetPhones(except paired: Set<String>) {
        let unpaired = lock.withLock {
            let gone = links.filter { !paired.contains($0.key) }
            for udid in gone.keys { links[udid] = nil }
            for udid in phoneStates.keys where !paired.contains(udid) && gone[udid] == nil { phoneStates[udid] = nil }
            return Array(gone.values)
        }
        for link in unpaired {
            link.unpair { [weak self] in
                guard let self else { return }
                let udid = link.phone.udid
                // Paired again meanwhile: the new link's state stays.
                lock.withLock { if links[udid] == nil { phoneStates[udid] = nil } }
                writeStatus()
            }
        }
        writeStatus()
    }

    /// What the hub is doing now, as `status` and the menu bar panel show it.
    func statusSnapshot() -> HubStatus {
        let containers = simulators?.containerCount ?? 0
        return lock.withLock {
            HubStatus(pid: getpid(), startedAt: startedAt, apps: currentApps, fixedApps: fixedApps, hosts: hosts, port: HubListener.port,
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
