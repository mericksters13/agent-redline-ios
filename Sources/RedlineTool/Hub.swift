#if os(macOS)
import Foundation
import Network
import Synchronization

/// Where the tool keeps things on the Mac.
///
/// - `inbox/<bundle ID>/<report>/`: reports taken off phones and simulators. Each holds the
///   report's own files (`report.json`, `report.md`, pictures) and the hub's: `source.json`
///   (where it came from), `claim.json` (the chat that took it), `to.json` (the chat it's
///   addressed to), `delivery.json` (where the hub sent it), and for a chat the hub started,
///   `new-chat-output.jsonl` and `answer.md`. A report is filled under `.incoming-<name>` and
///   renamed into place whole.
/// - `hub/chats/<chat>.json`: the open chats, written by their MCP copies, hooks and waits
/// - `hub/state.json`: which reports each phone and simulator app has already given
/// - `hub/tokens.json`: the token each app on each phone was given; secret
/// - `hub/started-chats.json`: the chats the hub started for the phone's "New chat" picks
/// - `hub/status.json`, `hub/hub.pid`, `hub/hub.log` (and `hub/hub.log.1`): for `redline status`
///   and the panel; the hub holds a lock on `hub.pid` while it runs
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

    /// How the hub and the chats write their JSON files: ISO 8601 dates, pretty-printed with
    /// sorted keys, so people can read them.
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// Reading the hub's own files, where a missing file is normal and any other failure isn't.
enum StoredFile {
    /// The file's contents, or nil when it doesn't exist. Any other failure, such as a file the
    /// user can't read, throws, so it's never mistaken for an empty one and written over.
    static func read(_ url: URL) throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
    }

    /// Moves a file that can't be read or decoded out of the way, so starting fresh doesn't
    /// write over what might still be recovered. Returns where it went.
    @discardableResult
    static func moveAside(_ url: URL) -> URL? {
        let stamp = Date().formatted(.iso8601).replacingOccurrences(of: ":", with: "-")
        let aside = url.deletingLastPathComponent().appending(path: "\(url.lastPathComponent).unreadable-\(stamp)")
        return (try? FileManager.default.moveItem(at: url, to: aside)) == nil ? nil : aside
    }

    /// The decoded file; nil when it doesn't exist. A file that can't be read or decoded is
    /// moved aside, with `report` told why, and treated as missing.
    static func load<T: Decodable>(_ type: T.Type, from url: URL, decoder: JSONDecoder, report: (String) -> Void) -> T? {
        do {
            guard let data = try read(url) else { return nil }
            return try decoder.decode(type, from: data)
        } catch {
            let aside = moveAside(url)
            report("Couldn't read \(url.path): \(error.localizedDescription). \(aside.map { "Moved it to \($0.lastPathComponent); starting fresh" } ?? "Starting fresh").")
            return nil
        }
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

/// Where a paired phone stands, as the hub and the panel show it.
enum PhoneState: Codable, Equatable, Sendable, CustomStringConvertible {
    /// The watched apps on it have the hub's address.
    case ready(apps: [String])
    /// The phone couldn't be reached; it's tried again after the delay or when a phone wakes.
    case unreachable(retryInSeconds: Int)
    case noWatchedApps

    /// For `redline status` and the log.
    var description: String {
        switch self {
        case .ready(let apps): "Ready for \(apps.joined(separator: ", "))"
        case .unreachable(let seconds): "Not reachable, trying again in \(seconds) s or when a phone wakes"
        case .noWatchedApps: "None of the watched apps installed"
        }
    }

    /// For the panel.
    var shortDescription: String {
        switch self {
        case .ready: "Ready"
        case .unreachable: "Not reachable"
        case .noWatchedApps: "No watched app installed"
        }
    }

    var isReady: Bool {
        switch self {
        case .ready: true
        case .unreachable, .noWatchedApps: false
        }
    }
}

/// What the hub tells `redline status`.
struct HubStatus: Codable, Sendable {
    struct Phone: Codable, Equatable, Sendable {
        var name: String
        var udid: String
        var state: String
        /// "iPhone 17 Pro": tells apart phones with the same name.
        var model: String? = nil
        /// The state as a value, for the panel. `state` stays the text, which a `redline status`
        /// of an earlier version reads; nil in a status.json an earlier hub wrote.
        var phoneState: PhoneState? = nil
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
///
/// Thread safety: everything that changes while the hub runs is in `state`, a `Mutex`.
/// `simulators`, `listener`, `handoff`, `chatsWatcher`, `discovery` and `pidLock` are written once
/// in `start()`, before any source, queue or listener that reads them starts, and only read
/// afterwards; `stop()` runs after `start()`. `logDescriptor` is used only on `writer`.
///
/// Lives for the whole process: PhoneLink, HubListener, SimulatorWatcher and Handoff hold it
/// unowned.
final class Hub: @unchecked Sendable {
    let paths: HubPaths
    let devicectl: Devicectl
    /// Apps given on the command line, watched whether or not a chat is open for them.
    private let fixedApps: [String]
    private let startedAt = Date()
    private let state: Mutex<State>
    private var chatsWatcher: DispatchSourceFileSystemObject?
    private var simulators: SimulatorWatcher?
    private var listener: HubListener?
    private var handoff: Handoff?
    private var discovery: DispatchSourceTimer?
    /// The descriptor that holds the lock on `hub.pid` while the hub runs.
    private var pidLock: Int32 = -1
    /// hub.log, open for appending; only touched on `writer`.
    private var logDescriptor: Int32 = -1
    private let queue = DispatchQueue(label: "Redline.hub", qos: .utility)
    /// Writes the hub's files, in order, outside the lock: state.json, tokens.json, status.json
    /// and the log.
    private let writer = DispatchQueue(label: "Redline.hub.writer", qos: .utility)
    /// Answers phones' questions about chats: project scans, the Codex database and git, which
    /// can take seconds. Its own queue, so an upload never waits behind one.
    private let directory = DispatchQueue(label: "Redline.hub.directory", qos: .userInitiated)
    /// Takes offers and files uploads for connections, which write up to `largestReport` bytes.
    private let inbox = DispatchQueue(label: "Redline.hub.inbox", qos: .userInitiated)
    private let network = NWPathMonitor()

    private struct State {
        var currentApps: [String] = []
        var sources: [String: SourceState] = [:]
        var tokens: [String: String] = [:]
        var links: [String: PhoneLink] = [:]
        var phoneStates: [String: HubStatus.Phone] = [:]
        var hosts: [String] = []
        /// Files with a write already queued on `writer`, which takes the newest state when it runs.
        var queuedWrites: Set<SavedFile> = []
    }

    private enum SavedFile: CustomStringConvertible {
        case state, tokens, status

        var description: String {
            switch self {
            case .state: "state.json"
            case .tokens: "tokens.json"
            case .status: "status.json"
            }
        }
    }

    /// A report finished up to this long before the hub first looked at its app still counts
    /// as new: the phone's clock and the Mac's can disagree by a little.
    static let firstLookMargin: TimeInterval = 120
    /// How often the hub looks for newly paired phones and newly installed apps. Changes to the
    /// Mac's network are noticed as they happen.
    static let discoveryInterval: TimeInterval = 1800
    /// hub.log is moved to hub.log.1 once it grows past this.
    static let largestLog = 5_000_000

    /// The apps the hub takes reports from: those of the open chats, and any given on the command line.
    var apps: [String] { state.withLock { $0.currentApps } }

    init(paths: HubPaths, devicectl: Devicectl, apps: [String]) {
        self.paths = paths
        self.devicectl = devicectl
        fixedApps = apps
        state = Mutex(State())
        let sources = StoredFile.load([String: SourceState].self, from: paths.state, decoder: HubPaths.decoder) { log($0) }
        let tokens = StoredFile.load([String: String].self, from: paths.tokens, decoder: HubPaths.decoder) { log($0) }
        state.withLock { state in
            state.sources = sources ?? [:]
            state.tokens = tokens ?? [:]
        }
    }

    /// Starts taking reports. False when another hub holds the lock on `hub.pid`, or it can't
    /// be taken; then nothing starts.
    @discardableResult
    func start() -> Bool {
        try? FileManager.default.createDirectory(at: paths.hub, withIntermediateDirectories: true)
        guard let pidLock = HubProcess.lock(paths) else {
            log(HubProcess.running(paths).map { "Another hub is running (pid \($0)); this one doesn't start" }
                ?? "Couldn't open \(paths.pid.path); the hub doesn't start")
            return false
        }
        self.pidLock = pidLock
        // Everything a source or queue reads is in place before any of them starts.
        handoff = Handoff(hub: self)
        simulators = SimulatorWatcher(hub: self)
        listener = HubListener(hub: self)
        let hosts = Self.addresses()
        state.withLock { $0.hosts = hosts }

        updateApps(starting: true)
        log(apps.isEmpty ? "Hub started; no chats open yet" : "Hub started for \(apps.joined(separator: ", "))")
        watchChats()
        ChatDirectory.warm(paths: paths)
        handoff?.handOverRecent()
        simulators?.rescan()
        listener?.start()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Self.discoveryInterval, leeway: .seconds(60))
        timer.setEventHandler { [weak self] in self?.discover(rediscover: true) }
        timer.resume()
        discovery = timer
        // A new Wi-Fi network or address means apps need the new address.
        network.pathUpdateHandler = { [weak self] _ in
            guard let self, Self.addresses() != state.withLock({ $0.hosts }) else { return }
            discover(rediscover: false)
        }
        network.start(queue: queue)
        return true
    }

    func stop() {
        discovery?.cancel()
        chatsWatcher?.cancel()
        network.cancel()
        listener?.stop()
        simulators?.stop()
        log("Hub stopped")
        // Queued writes land before the process exits.
        flushWrites()
        // The file goes first, then the lock, so no other hub ever reads this pid as running.
        try? FileManager.default.removeItem(at: paths.pid)
        if pidLock >= 0 { close(pidLock) }
        pidLock = -1
    }

    /// Waits until every file write queued so far has landed.
    func flushWrites() {
        writer.sync {}
    }

    /// Gives every paired phone's watched apps the hub's current address. `rediscover` also
    /// looks again for newly paired phones' apps and simulator apps installed since the last look.
    private func discover(rediscover: Bool) {
        let hosts = Self.addresses()
        state.withLock { $0.hosts = hosts }
        if rediscover { simulators?.rescan() }
        let paired: [Devicectl.Phone]
        do {
            paired = try devicectl.pairedPhones()
        } catch {
            log("Couldn't list paired phones: \(error.localizedDescription)")
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
        let changed = state.withLock { state in
            defer { state.currentApps = apps }
            return state.currentApps != apps
        }
        guard changed, !starting else { return }
        log(apps.isEmpty ? "No chats open" : "Taking reports from \(apps.joined(separator: ", "))")
        // New apps' simulator folders to watch and phones to give the address to; discovery
        // rescans the simulators too.
        queue.async { self.discover(rediscover: true) }
    }

    private func link(for phone: Devicectl.Phone) -> PhoneLink {
        state.withLock { state in
            if let link = state.links[phone.udid] { return link }
            let link = PhoneLink(phone: phone, hub: self)
            state.links[phone.udid] = link
            return link
        }
    }

    /// Some phone on the network woke up.
    func phoneWoke() {
        for link in state.withLock({ Array($0.links.values) }) {
            link.phoneWoke()
        }
    }

    // MARK: - Offers from apps

    /// The key of one app on one device, in state.json and tokens.json.
    private static func key(device: String, bundleID: String) -> String {
        "\(device)|\(bundleID)"
    }

    /// The token for an app on a phone. Made once and kept, so the address the app has stays
    /// good when the hub restarts.
    func token(device: String, bundleID: String) -> String {
        state.withLock { state in
            let key = Self.key(device: device, bundleID: bundleID)
            if let token = state.tokens[key] { return token }
            // The system's generator is cryptographically secure and can't fail.
            var generator = SystemRandomNumberGenerator()
            let token = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
            state.tokens[key] = token
            queueWrite(.tokens, in: &state)
            return token
        }
    }

    /// True when `token` is the one this hub gave the app on the device.
    private func hasValidToken(_ token: String, device: String, bundleID: String) -> Bool {
        let expected = state.withLock { $0.tokens[Self.key(device: device, bundleID: bundleID)] }
        return expected.map { Self.same($0, token) } ?? false
    }

    /// The hub's answer to an app's offer: the reports to send now, and the ones the app can
    /// stop offering. Only an app that was given this hub's address, and so is on a phone paired
    /// with this Mac, can deliver.
    func answerNow(_ offer: HubMessage.Offer) -> HubMessage.Answer {
        guard hasValidToken(offer.token, device: offer.device, bundleID: offer.bundleID) else {
            let known = state.withLock { $0.tokens[Self.key(device: offer.device, bundleID: offer.bundleID)] != nil }
            log("Turned down \(offer.bundleID) from \(phoneName(offer.device)): \(known ? "its token doesn't match" : "this hub never gave it an address")")
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
    func chatsNow(_ request: HubMessage.ChatsRequest) -> HubMessage.ChatList {
        guard hasValidToken(request.token, device: request.device, bundleID: request.bundleID) else {
            log("Turned down \(request.bundleID)'s question about chats from \(phoneName(request.device)): its token doesn't match")
            return HubMessage.ChatList(agents: [], chats: [], refused: "The app needs this Mac's address again.")
        }
        return ChatDirectory.list(bundleID: request.bundleID, sourceFile: request.sourceFile, paths: paths)
    }

    /// Files a report the hub asked for. Throws, after logging why, when it can't be filed.
    func storeNow(_ upload: HubMessage.Upload, offeredIn offer: HubMessage.Offer) throws {
        let total = upload.files.values.reduce(0) { $0 + $1.count }
        guard Self.isSafeName(upload.id), upload.files.keys.allSatisfy(Self.isSafeName), total <= Self.largestReport,
              upload.files["report.json"] != nil
        else {
            log("Couldn't use report \(upload.id) of \(offer.bundleID): missing its report.json, a file name it can't use, or over \(Self.largestReport / 1_000_000) MB")
            throw FilingError.unusableUpload
        }
        let source = ReportSource(kind: .phone, device: offer.device, deviceName: phoneName(offer.device), bundleID: offer.bundleID,
                                  reportID: upload.id, receivedAt: Date())
        try receive(source) { destination in
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for (name, data) in upload.files { try data.write(to: destination.appending(path: name)) }
        }
    }

    /// Why a report wasn't filed, beyond the file system's own errors.
    enum FilingError: Error {
        /// No report.json, a file name the hub can't use, or too big.
        case unusableUpload
    }

    // Connections are served from Swift tasks, which must never block their thread: these run
    // the blocking work above on the hub's own queues and resume when it's done.

    func answer(_ offer: HubMessage.Offer) async -> HubMessage.Answer {
        await withCheckedContinuation { continuation in
            inbox.async { continuation.resume(returning: self.answerNow(offer)) }
        }
    }

    func chats(_ request: HubMessage.ChatsRequest) async -> HubMessage.ChatList {
        await withCheckedContinuation { continuation in
            directory.async { continuation.resume(returning: self.chatsNow(request)) }
        }
    }

    func store(_ upload: HubMessage.Upload, offeredIn offer: HubMessage.Offer) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            inbox.async { continuation.resume(with: Result { try self.storeNow(upload, offeredIn: offer) }) }
        }
    }

    func settled(device: String, bundleID: String, finished: [FinishedReport]) async -> [String] {
        await withCheckedContinuation { continuation in
            inbox.async { continuation.resume(returning: self.settled(device: device, bundleID: bundleID, finished: finished)) }
        }
    }

    /// A report bigger than this isn't taken: a phone screen's picture is about 100 KB.
    static let largestReport = 50_000_000

    private func phoneName(_ udid: String) -> String {
        state.withLock { $0.links[udid]?.phone.name } ?? "A phone"
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
        state.withLock { state in
            let key = Self.key(device: device, bundleID: bundleID)
            let isNew = state.sources[key] == nil
            let source = state.sources[key, default: SourceState(since: startedAt.addingTimeInterval(-Self.firstLookMargin))]
            if isNew {
                state.sources[key] = source
                queueWrite(.state, in: &state)
            }
            return source.toCopy(from: finished)
        }
    }

    /// The offered reports the app can stop offering.
    func settled(device: String, bundleID: String, finished: [FinishedReport]) -> [String] {
        state.withLock { $0.sources[Self.key(device: device, bundleID: bundleID)]?.settled(finished) ?? [] }
    }

    /// Files a report in the inbox. `copy` fills a folder that doesn't exist yet; the report
    /// appears in the inbox only once it's complete, with its source.json. Throws, after logging
    /// why, when it couldn't be filed; then nothing is left in the inbox and the report isn't
    /// counted as delivered, so it's offered again.
    func receive(_ source: ReportSource, copy: (_ destination: URL) throws -> Void) throws {
        let folder = paths.inbox.appending(path: source.bundleID, directoryHint: .isDirectory)
        let name = Inbox.folderName(reportID: source.reportID, device: source.device)
        let incoming = folder.appending(path: Inbox.incomingPrefix + name, directoryHint: .isDirectory)
        let destination = folder.appending(path: name, directoryHint: .isDirectory)
        let files = FileManager.default
        let started = Date()
        // The menu bar app has no window, so App Nap would slow filing a report the user just sent.
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Filing a report from a device")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            // Left by an earlier try that didn't finish.
            try? files.removeItem(at: incoming)
            try copy(incoming)
            try HubPaths.encoder.encode(source).write(to: incoming.appending(path: Inbox.sourceFile))
            // The same report sent again replaces the earlier copy.
            try? files.removeItem(at: destination)
            try files.moveItem(at: incoming, to: destination)
        } catch {
            try? files.removeItem(at: incoming)
            log("Couldn't file report \(source.reportID) of \(source.bundleID) from \(source.deviceName): \(error.localizedDescription)")
            throw error
        }
        state.withLock { state in
            state.sources[Self.key(device: source.device, bundleID: source.bundleID), default: SourceState(since: startedAt)].delivered.append(source.reportID)
            queueWrite(.state, in: &state)
        }
        log(String(format: "Received %@ from %@ (%@) in %.2f s", source.reportID, source.deviceName, source.bundleID, Date().timeIntervalSince(started)))
        handoff?.reportFiled(destination, source: source)
    }

    // MARK: - Status

    func phoneChanged(_ phone: Devicectl.Phone, state phoneState: PhoneState) {
        let phone = HubStatus.Phone(name: phone.name, udid: phone.udid, state: phoneState.description, model: phone.model.isEmpty ? nil : phone.model,
                                    phoneState: phoneState)
        state.withLock { state in
            // A pass that changes nothing writes nothing.
            guard state.phoneStates.updateValue(phone, forKey: phone.udid) != phone else { return }
            queueWrite(.status, in: &state)
        }
    }

    /// What the hub is doing now, as `status` and the menu bar panel show it. Memory only.
    func statusSnapshot() -> HubStatus {
        let containers = simulators?.containerCount ?? 0
        return state.withLock { state in
            HubStatus(pid: getpid(), startedAt: startedAt, apps: state.currentApps, hosts: state.hosts, port: HubListener.port,
                      phones: state.phoneStates.values.sorted { $0.name < $1.name }, simulatorContainers: containers)
        }
    }

    /// The simulators with a watched app installed.
    func watchedSimulators() -> Set<String> {
        simulators?.simulatorIDs ?? []
    }

    /// Saves the status for `redline status` and a panel in another process.
    func writeStatus() {
        state.withLock { queueWrite(.status, in: &$0) }
    }

    // MARK: - Persistence

    /// Queues a write of `file` while the lock is held, so writes land in the order the state
    /// changed. At most one write per file waits; it saves the newest state when it runs.
    private func queueWrite(_ file: SavedFile, in state: inout State) {
        guard state.queuedWrites.insert(file).inserted else { return }
        writer.async { self.save(file) }
    }

    /// Runs on `writer`: takes the newest state under the lock, then encodes and writes it outside.
    private func save(_ file: SavedFile) {
        dispatchPrecondition(condition: .onQueue(writer))
        let encoder = HubPaths.encoder
        let url: URL
        do {
            switch file {
            case .state:
                url = paths.state
                let sources = state.withLock { state in
                    state.queuedWrites.remove(.state)
                    return state.sources
                }
                try encoder.encode(sources).write(to: url, options: .atomic)
            case .tokens:
                url = paths.tokens
                let tokens = state.withLock { state in
                    state.queuedWrites.remove(.tokens)
                    return state.tokens
                }
                try encoder.encode(tokens).write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            case .status:
                url = paths.status
                state.withLock { _ = $0.queuedWrites.remove(.status) }
                try encoder.encode(statusSnapshot()).write(to: url, options: .atomic)
            }
        } catch {
            log("Couldn't save \(file): \(error.localizedDescription)")
        }
    }

    // MARK: - Logging

    func log(_ message: String) {
        let line = Data("\(Date().formatted(.iso8601)) \(message)\n".utf8)
        try? FileHandle.standardOutput.write(contentsOf: line)
        writer.async { self.appendToLog(line) }
    }

    /// Runs on `writer`: appends one line to hub.log with a single write, moving the log to
    /// hub.log.1 once it passes `largestLog`.
    private func appendToLog(_ line: Data) {
        dispatchPrecondition(condition: .onQueue(writer))
        if logDescriptor < 0 {
            logDescriptor = open(paths.log.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
            guard logDescriptor >= 0 else { return }
        }
        _ = line.withUnsafeBytes { write(logDescriptor, $0.baseAddress, $0.count) }
        if lseek(logDescriptor, 0, SEEK_END) > Self.largestLog {
            close(logDescriptor)
            logDescriptor = -1
            let old = paths.hub.appending(path: "hub.log.1")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: paths.log, to: old)
        }
    }
}
#endif
