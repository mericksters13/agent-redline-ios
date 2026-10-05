#if os(macOS)
import AppKit
import Darwin
import Network
import SwiftUI
import Synchronization
import SystemConfiguration

/// Takes reports off paired phones and simulators and files them in the inbox.
///
/// An app on a phone offers its reports over the local network and the hub copies them over Xcode's
/// device link; simulator apps' folders are on the Mac, so the hub sees their reports as they're
/// saved.
///
/// Thread safety: everything that changes while the hub runs is in `state`, a `Mutex`, apart from
/// `chatsWatchers`, which has its own. `simulators`, `listener`, `handoff`, `discovery` and
/// `pidLock` are written once in `start()`, before any source, queue or listener that reads them
/// starts, and only read afterwards; `start()` and `stop()` run under `lifecycle`, so a stop
/// waits for a start under way, and `stop()` runs once and leaves `hub.pid` alone unless
/// `start()` took the lock.
/// `whenListenerFails` is set before `start()` and only read afterwards. `logDescriptor` is used
/// only on `writer`.
///
/// Lives for the whole process: PhoneLink, HubListener, SimulatorWatcher and Handoff hold it
/// unowned.
final class Hub: @unchecked Sendable {
    let paths: HubPaths
    let devicectl: Devicectl
    /// Apps given on the command line, watched whether or not a chat is open for them.
    private let fixedApps: [String]
    private let startedAt = Date.now
    private let state: Mutex<State>
    /// Watchers of the chat record folders; nil once the hub has stopped.
    ///
    /// The sessions folder's watcher can be added after `start()`, once Claude Code makes it.
    private let chatsWatchers = Mutex<[DispatchSourceFileSystemObject]?>([])
    /// Claude Code's open chats.
    ///
    /// It runs no hooks, so its chats are found from its own files.
    private let claudeChats: @Sendable () -> [ClaudeSessions.Session]
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
    /// Answers phones' questions about chats: project scans, the Codex database and git, which can
    /// take seconds.
    ///
    /// Its own queue, so an upload never waits behind one.
    private let directory = DispatchQueue(label: "Redline.hub.directory", qos: .userInitiated)
    /// Takes offers and files uploads for connections, which write up to `largestReport` bytes.
    private let inbox = DispatchQueue(label: "Redline.hub.inbox", qos: .userInitiated)
    private let network = NWPathMonitor()
    /// Held while the hub starts and while it stops.
    ///
    /// A stop asked for while the hub starts, such as by the menu bar app taking over as soon as
    /// the status is written, waits until everything it has to stop exists. A recursive lock
    /// rather than a `Mutex`: a listener that fails at once stops the hub from inside `start()`,
    /// on the same thread.
    private let lifecycle = NSRecursiveLock()
    /// True once `stop()` has run; only touched under `lifecycle`.
    private var isStopped = false

    private struct State {
        var currentApps: [String] = []
        var sources: [String: SourceState] = [:]
        var tokens: [String: String] = [:]
        var links: [String: PhoneLink] = [:]
        var phoneStates: [String: HubStatus.Phone] = [:]
        var hosts: [String] = []
        /// Files with a write already queued on `writer`, which takes the newest state when it runs.
        var queuedWrites: Set<SavedFile> = []
        /// Reports being moved into the inbox, by source key and report ID, so a second copy of one
        /// that arrives at the same time isn't filed too.
        var filing: Set<String> = []
        /// Set once `stop()` has drained the inbox: no report is filed after the last writes.
        var isStopping = false
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

    /// How often the hub looks for newly paired phones and newly installed apps.
    ///
    /// Changes to the Mac's network are noticed as they happen.
    static let discoveryInterval: TimeInterval = 1800
    /// hub.log is moved to hub.log.1 once it grows past this.
    static let largestLog = 5_000_000

    /// The apps the hub takes reports from: those of the open chats and of chats before them, and
    /// any given on the command line.
    var apps: [String] { state.withLock { $0.currentApps } }

    init(
        paths: HubPaths,
        devicectl: Devicectl,
        apps: [String],
        claudeChats: @escaping @Sendable () -> [ClaudeSessions.Session] = ClaudeSessions.openSessions
    ) {
        self.paths = paths
        self.devicectl = devicectl
        fixedApps = apps
        self.claudeChats = claudeChats
        state = Mutex(State())
        let sources = StoredFile.load([String: SourceState].self, from: paths.state, decoder: HubPaths.decoder) {
            log($0)
        }
        let tokens = StoredFile.load([String: String].self, from: paths.tokens, decoder: HubPaths.decoder) { log($0) }
        state.withLock { state in
            state.sources = sources ?? [:]
            state.tokens = tokens ?? [:]
        }
    }

    // MARK: - Lifecycle

    /// Starts taking reports.
    ///
    /// False when another hub holds the lock on `hub.pid`, or it can't be taken; then nothing
    /// starts.
    @discardableResult
    func start() -> Bool {
        lifecycle.lock()
        defer { lifecycle.unlock() }
        try? FileManager.default.createDirectory(at: paths.hub, withIntermediateDirectories: true)
        guard let pidLock = HubProcess.lock(paths) else {
            log(
                HubProcess.running(paths).map { "Another hub is running (pid \($0)); this one doesn't start" }
                    ?? "Couldn't open \(paths.pid.path); the hub doesn't start"
            )
            return false
        }
        self.pidLock = pidLock
        // Everything a source or queue reads is in place before any of them starts.
        handoff = Handoff(hub: self)
        simulators = SimulatorWatcher(hub: self)
        listener = HubListener(hub: self)
        let hosts = Self.addresses()
        state.withLock { $0.hosts = hosts }

        updateApps(isStarting: true)
        // Before anything else, so the menu bar app taking over from this hub finds the apps it was
        // given on the command line.
        writeStatus()
        log(apps.isEmpty ? "Hub started; no chats open yet" : "Hub started for \(apps.joined(separator: ", "))")
        watchChats()
        ChatDirectory.warm(paths: paths)
        handoff?.handOverRecent()
        simulators?.rescan()
        listener?.start()
        // A listener that failed at once has stopped the hub, and `whenListenerFails` says so.
        guard !isStopped else { return true }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Self.discoveryInterval, leeway: .seconds(60))
        timer.setEventHandler { [weak self] in self?.discover(includingNewApps: true) }
        timer.resume()
        discovery = timer
        // A new Wi-Fi network or address means apps need the new address.
        network.pathUpdateHandler = { [weak self] _ in
            guard let self, Self.addresses() != state.withLock({ $0.hosts }) else { return }
            discover(includingNewApps: false)
        }
        network.start(queue: queue)
        return true
    }

    /// Stops taking reports, lets the reports being handed over reach their chats and queued
    /// writes land, then releases `hub.pid`.
    ///
    /// A hub that starts next, such as the menu bar app taking over, hands over again only what
    /// this one gave back, so no report starts two chats. Called again, it waits for the first call
    /// to finish. A hub that never took the lock on `hub.pid`, because another hub runs, leaves
    /// that hub's file alone. Parks the calling thread while hand-overs finish, which can take
    /// minutes: called from a signal's queue, the panel's Quit off the main thread, or as the
    /// process ends.
    func stop() {
        lifecycle.withLock {
            guard !isStopped else { return }
            isStopped = true
            discovery?.cancel()
            chatsWatchers.withLock { watchers in
                for watcher in watchers ?? [] { watcher.cancel() }
                watchers = nil
            }
            network.cancel()
            listener?.stop()
            // Before the simulator watcher: stopping it waits for a rescan under way, and hand-overs
            // queued meanwhile, or reports that rescan finds, must not start new chats.
            handoff?.finish()
            simulators?.stop()
            // A connection the listener took can still be filing a report: it finishes, with its
            // delivered ID queued to write, and later uploads are turned down.
            inbox.sync { state.withLock { $0.isStopping = true } }
            let heldLock = pidLock >= 0
            if heldLock { log("Hub stopped") }
            // Queued writes land before the process exits.
            flushWrites()
            guard heldLock else { return }
            // The file goes first, then the lock, so no other hub ever reads this pid as running.
            try? FileManager.default.removeItem(at: paths.pid)
            close(pidLock)
            pidLock = -1
        }
    }

    /// Set before `start()` by the menu bar app, which shows why the listener failed and then exits.
    var whenListenerFails: (@Sendable (String) -> Void)?

    /// The hub can't take reports without its listener: it stops, so the next chat starts a new
    /// one, and exits, or first tells `whenListenerFails`.
    func listenerFailed(_ reason: String) {
        log(reason)
        stop()
        guard let whenListenerFails else { exit(1) }
        whenListenerFails(reason)
    }

    /// Waits until every file write queued so far has landed.
    func flushWrites() {
        writer.sync {}
    }

    // MARK: - Discovery

    /// Gives every paired phone's watched apps the hub's current address. `includingNewApps` also
    /// looks again for newly paired phones' apps and simulator apps installed since the last look.
    private func discover(includingNewApps: Bool) {
        let hosts = Self.addresses()
        state.withLock { $0.hosts = hosts }
        if includingNewApps { simulators?.rescan() }
        // Phones already known still get the new address when the paired list can't be read.
        let links: [PhoneLink]
        do {
            let paired = try devicectl.pairedPhones()
            forgetPhones(except: Set(paired.map(\.udid)))
            links = paired.map { link(for: $0) }
        } catch {
            log("Couldn't list paired phones: \(error.localizedDescription)")
            links = state.withLock { Array($0.links.values) }
        }
        for link in links {
            // Off every network, phones keep the address they have, which works again once the Mac
            // is back on theirs; the new address follows as soon as the Mac has one.
            if hosts.isEmpty {
                link.macDidGoOffline()
            } else {
                link.update(hosts: hosts, port: HubListener.port, includingNewApps: includingNewApps)
            }
        }
        writeStatus()
    }

    /// A chat opening or closing changes the apps to take reports from: the hub's own chat
    /// records, and the session files of Claude Code's chats.
    private func watchChats() {
        let folder = Chats.folder(paths)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for folder in [folder.path] + ClaudeSessions.configFolders.map({ $0 + "/sessions" }) {
            watch(folder)
        }
    }

    /// Watches a folder of chat records.
    ///
    /// Claude Code makes its sessions folder with its first chat, which can come after the hub
    /// starts: until then the folder above it is watched, and the sessions folder once it appears.
    private func watch(_ folder: String) {
        let descriptor = open(folder, O_EVTONLY)
        if descriptor >= 0 {
            addWatcher(descriptor) { [weak self] _ in self?.updateApps(isStarting: false) }
            return
        }
        let parent = open(URL(filePath: folder).deletingLastPathComponent().path, O_EVTONLY)
        guard parent >= 0 else { return }
        addWatcher(parent) { [weak self] source in
            guard let self, FileManager.default.fileExists(atPath: folder) else { return }
            source.cancel()
            watch(folder)
            updateApps(isStarting: false)
        }
    }

    /// Runs `changed` on the hub's queue each time the folder open at `descriptor` changes.
    ///
    /// Once the hub has stopped, the folder is not watched.
    private func addWatcher(_ descriptor: Int32, changed: @escaping (DispatchSourceFileSystemObject) -> Void) {
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: .write,
            queue: queue
        )
        source.setEventHandler { [unowned source] in changed(source) }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        chatsWatchers.withLock { watchers in
            guard watchers != nil else { return source.cancel() }
            watchers?.append(source)
        }
    }

    /// Takes reports from the apps of the open chats and of chats before them, and the ones given on
    /// the command line.
    ///
    /// Apps a chat worked on before stay watched after it closes, so their reports still arrive and
    /// can start a new chat. When they change after the start, looks for the new apps on phones and
    /// simulators.
    func updateApps(isStarting: Bool) {
        noteClaudeChats()
        let open = Chats.removeClosedChats(paths).flatMap(\.bundleIDs)
        let apps = Array(Set(fixedApps + open + ProjectHistory.all(paths).keys)).sorted()
        let changed = state.withLock { state in
            defer { state.currentApps = apps }
            return state.currentApps != apps
        }
        guard changed, !isStarting else { return }
        log(apps.isEmpty ? "No chats open" : "Taking reports from \(apps.joined(separator: ", "))")
        // New apps' simulator folders to watch and phones to give the address to; discovery
        // rescans the simulators too.
        queue.async { self.discover(includingNewApps: true) }
    }

    /// Notes the apps open Claude Code chats work on, so the hub watches them.
    ///
    /// Other agents' chats note theirs when they register. A new chat for one of these apps starts
    /// with the agent used last, so apps not noted since the chat was last active are written too.
    private func noteClaudeChats() {
        let known = ProjectHistory.all(paths)
        for session in claudeChats() {
            let new = ChatDirectory.apps.bundleIDs(in: session.folder).filter {
                known[$0].map { $0.usedAt < session.updatedAt } ?? true
            }
            guard !new.isEmpty else { continue }
            let chat = ChatRecord(
                id: ChatID.make(.claude, session.id),
                agent: Agent.claude.rawValue,
                folder: session.folder,
                bundleIDs: new,
                pid: getpid(),
                registeredAt: .now,
                lastActiveAt: session.updatedAt
            )
            do {
                try ProjectHistory.note(chat, paths: paths)
            } catch {
                log("Couldn't note the apps of the Claude Code chat \(session.id): \(error.localizedDescription)")
            }
        }
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
    func phoneDidWake() {
        for link in state.withLock({ Array($0.links.values) }) {
            link.phoneDidWake()
        }
    }

    // MARK: - Offers from apps

    /// The key of one app on one device, in state.json and tokens.json.
    private static func key(device: String, bundleID: String) -> String {
        "\(device)|\(bundleID)"
    }

    /// The token for an app on a phone.
    ///
    /// Made once and kept, so the address the app has stays good when the hub restarts.
    func issueToken(device: String, bundleID: String) -> String {
        state.withLock { state in
            let key = Self.key(device: device, bundleID: bundleID)
            if let token = state.tokens[key] { return token }
            // The system's generator is cryptographically secure and can't fail.
            var generator = SystemRandomNumberGenerator()
            let token = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }
                .joined()
            state.tokens[key] = token
            queueWrite(.tokens, in: &state)
            return token
        }
    }

    /// True when `token` is the one this hub gave the app on the device.
    private func hasValidToken(_ token: String, device: String, bundleID: String) -> Bool {
        let expected = state.withLock { $0.tokens[Self.key(device: device, bundleID: bundleID)] }
        return expected.map { Self.constantTimeEquals($0, token) } ?? false
    }

    /// The hub's answer to an app's offer: the reports to send now, and the ones the app can stop
    /// offering.
    ///
    /// Only an app that was given this hub's address, and so is on a phone paired with this Mac,
    /// can deliver.
    func answerNow(_ offer: HubMessage.Offer) -> HubMessage.Answer {
        guard hasValidToken(offer.token, device: offer.device, bundleID: offer.bundleID) else {
            let known = state.withLock { $0.tokens[Self.key(device: offer.device, bundleID: offer.bundleID)] != nil }
            log(
                "Turned down \(offer.bundleID) from \(phoneName(offer.device)): \(known ? "its token doesn't match" : "this hub never gave it an address")"
            )
            return HubMessage.Answer(
                want: [],
                delivered: [],
                refused: "The app needs this Mac's address again; it gets it the next time Xcode can reach the phone."
            )
        }
        // Report IDs become folder names in the inbox.
        guard offer.reports.allSatisfy({ Self.isSafeName($0.id) }) else {
            log("Turned down \(offer.bundleID) from \(phoneName(offer.device)): a report name it can't use")
            return HubMessage.Answer(want: [], delivered: [], refused: "Report names")
        }
        let finished = offer.reports.map { FinishedReport(id: $0.id, finishedAt: $0.finishedAt) }
        let want = reportIDsToCopy(device: offer.device, bundleID: offer.bundleID, finished: finished)
        log(
            "\(phoneName(offer.device)) offered \(offer.reports.count) of \(offer.bundleID)'s reports; \(want.isEmpty ? "the Mac has them all" : "taking \(want.count)")"
        )
        return HubMessage.Answer(
            want: want,
            delivered: settledReportIDs(device: offer.device, bundleID: offer.bundleID, finished: finished)
        )
    }

    /// The chats a report from this app can go to, for the phone to show before the user sends.
    func chatsNow(_ request: HubMessage.ChatsRequest) -> HubMessage.ChatList {
        guard hasValidToken(request.token, device: request.device, bundleID: request.bundleID) else {
            log(
                "Turned down \(request.bundleID)'s question about chats from \(phoneName(request.device)): its token doesn't match"
            )
            return HubMessage.ChatList(agents: [], chats: [], refused: "The app needs this Mac's address again.")
        }
        return ChatDirectory.list(bundleID: request.bundleID, sourceFile: request.sourceFile, paths: paths)
    }

    /// Files a report the hub asked for.
    ///
    /// Throws, after logging why, when it can't be filed.
    func storeNow(_ upload: HubMessage.Upload, offeredIn offer: HubMessage.Offer) throws {
        let total = upload.files.values.reduce(0) { $0 + $1.count }
        guard Self.isSafeName(upload.id), upload.files.keys.allSatisfy(Self.isSafeName), total <= Self.largestReport,
            upload.files["report.json"] != nil
        else {
            log(
                "Couldn't use report \(upload.id) of \(offer.bundleID): missing its report.json, a file name it can't use, or over \(Self.largestReport / 1_000_000) MB"
            )
            throw FilingError.unusableUpload
        }
        let source = ReportSource(
            kind: .phone,
            device: offer.device,
            deviceName: phoneName(offer.device),
            bundleID: offer.bundleID,
            reportID: upload.id,
            receivedAt: .now
        )
        try receive(source) { destination in
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for (name, data) in upload.files { try data.write(to: destination.appending(path: name)) }
        }
    }

    /// Why a report wasn't filed, beyond the file system's own errors.
    enum FilingError: Error {
        /// No report.json, a file name the hub can't use, or too big.
        case unusableUpload
        /// The hub is stopping; the report is offered again to the next hub.
        case stopping
    }

    // Connections are served from Swift tasks, which must never block their thread: these run
    // the blocking work above on the hub's own queues and resume when it's done.

    /// `answerNow`, on the inbox queue.
    func answer(_ offer: HubMessage.Offer) async -> HubMessage.Answer {
        await withCheckedContinuation { continuation in
            inbox.async { continuation.resume(returning: self.answerNow(offer)) }
        }
    }

    /// `chatsNow`, on the directory queue.
    func chats(_ request: HubMessage.ChatsRequest) async -> HubMessage.ChatList {
        await withCheckedContinuation { continuation in
            directory.async { continuation.resume(returning: self.chatsNow(request)) }
        }
    }

    /// `storeNow`, on the inbox queue.
    func store(_ upload: HubMessage.Upload, offeredIn offer: HubMessage.Offer) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            inbox.async { continuation.resume(with: Result { try self.storeNow(upload, offeredIn: offer) }) }
        }
    }

    /// `settledReportIDs`, on the inbox queue, after the uploads before it.
    func settledReportIDs(device: String, bundleID: String, finished: [FinishedReport]) async -> [String] {
        await withCheckedContinuation { continuation in
            inbox.async {
                continuation.resume(
                    returning: self.settledReportIDs(device: device, bundleID: bundleID, finished: finished)
                )
            }
        }
    }

    /// A report bigger than this isn't taken: a phone screen's picture is about 100 KB.
    ///
    /// The app checks its reports against the same size, `ReportStore.largestReport`, before
    /// sending.
    static let largestReport = 50_000_000

    private func phoneName(_ udid: String) -> String {
        state.withLock { $0.links[udid]?.phone.name } ?? "A phone"
    }

    /// File and report names: letters, digits, dots, dashes and underscores, not starting with a dot.
    static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".")
            && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
    }

    /// Compares tokens in time that doesn't depend on where they differ.
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8)
        let y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// The Mac's IPv4 addresses on its local networks, then its `.local` name, which keeps working
    /// when the address changes and is the only way to reach the Mac on an IPv6-only network.
    ///
    /// None while no Wi-Fi or Ethernet link has an address, since phones can't reach the Mac by any
    /// of them then.
    static func addresses() -> [String] {
        var found: [String] = []
        var isOnNetwork = false
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
                    if Self.isOnNetwork(ipv6) { isOnNetwork = true }
                    continue
                }
                guard address.pointee.sa_family == UInt8(AF_INET) else { continue }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(
                    address,
                    socklen_t(address.pointee.sa_len),
                    &host,
                    socklen_t(host.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                ) == 0 {
                    found.append(String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
                    isOnNetwork = true
                }
            }
        }
        // The name the Mac answers to over Bonjour, as set in Sharing settings.
        if isOnNetwork, let name = SCDynamicStoreCopyLocalHostName(nil) as String? { found.append("\(name).local") }
        return found
    }

    /// Whether an IPv6 address comes from a network rather than only from the link being up: every
    /// active interface has a link-local address (fe80::/10), with or without a network.
    static func isOnNetwork(_ address: in6_addr) -> Bool {
        let bytes = withUnsafeBytes(of: address) { Array($0) }
        let isLinkLocal = bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80
        return !isLinkLocal && bytes != Array(repeating: 0, count: 16)
    }

    // MARK: - Delivery

    /// The finished reports from one app on one device still to copy.
    ///
    /// A phone offers only reports the Mac hasn't confirmed, and a simulator's reports without the
    /// delivered mark are the same, so every one is taken, including those sent before this hub
    /// first saw the app. Changes nothing.
    func reportIDsToCopy(device: String, bundleID: String, finished: [FinishedReport]) -> [String] {
        state.withLock {
            ($0.sources[Self.key(device: device, bundleID: bundleID)] ?? SourceState()).reportIDsToCopy(from: finished)
        }
    }

    /// The offered reports the app can stop offering.
    func settledReportIDs(device: String, bundleID: String, finished: [FinishedReport]) -> [String] {
        state.withLock {
            $0.sources[Self.key(device: device, bundleID: bundleID)]?.settledReportIDs(in: finished) ?? []
        }
    }

    /// Files a report in the inbox. `copy` fills a folder that doesn't exist yet; the report
    /// appears in the inbox only once it's complete, with its source.json.
    ///
    /// The same report can arrive twice at once, such as from two offers sent back to back. Each
    /// copy fills its own folder, and the first to finish is the one filed; the others are dropped.
    ///
    /// Throws, after logging why, when it couldn't be filed; then nothing is left in the inbox and
    /// the report isn't counted as delivered, so it's offered again.
    func receive(_ source: ReportSource, copy: (_ destination: URL) throws -> Void) throws {
        let folder = paths.inbox.appending(path: source.bundleID, directoryHint: .isDirectory)
        let name = Inbox.folderName(reportID: source.reportID, device: source.device)
        let incoming = folder.appending(
            path: Inbox.incomingPrefix + name + "-" + UUID().uuidString,
            directoryHint: .isDirectory
        )
        let destination = folder.appending(path: name, directoryHint: .isDirectory)
        let key = Self.key(device: source.device, bundleID: source.bundleID)
        let filingKey = key + "|" + source.reportID
        let files = FileManager.default
        let started = Date.now
        guard !state.withLock({ $0.isStopping }) else {
            log("Didn't file report \(source.reportID) of \(source.bundleID): the hub is stopping")
            throw FilingError.stopping
        }
        // The menu bar app has no window, so App Nap would slow filing a report the user just sent.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Filing a report from a device"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }
        // Whatever happens, this attempt's own folder doesn't stay.
        defer { try? files.removeItem(at: incoming) }
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            try copy(incoming)
            try HubPaths.encoder.encode(source).write(to: incoming.appending(path: Inbox.sourceFile))
        } catch {
            log(
                "Couldn't file report \(source.reportID) of \(source.bundleID) from \(source.deviceName): \(error.localizedDescription)"
            )
            throw error
        }
        // Another copy of this report was filed, or is being filed, first.
        let isFirst = state.withLock { state in
            guard state.sources[key]?.delivered.contains(source.reportID) != true else { return false }
            return state.filing.insert(filingKey).inserted
        }
        guard isFirst else { return }
        do {
            // Left by an attempt whose filing wasn't recorded, such as one cut short by a crash.
            if files.fileExists(atPath: destination.path) { try files.removeItem(at: destination) }
            try files.moveItem(at: incoming, to: destination)
        } catch {
            state.withLock { _ = $0.filing.remove(filingKey) }
            log(
                "Couldn't file report \(source.reportID) of \(source.bundleID) from \(source.deviceName): \(error.localizedDescription)"
            )
            throw error
        }
        state.withLock { state in
            state.filing.remove(filingKey)
            state.sources[key, default: SourceState()].delivered.append(source.reportID)
            queueWrite(.state, in: &state)
        }
        log(
            String(
                format: "Received %@ from %@ (%@) in %.2f s",
                source.reportID,
                source.deviceName,
                source.bundleID,
                Date.now.timeIntervalSince(started)
            )
        )
        handoff?.reportDidArrive(at: destination, source: source)
    }

    // MARK: - Status

    /// Records where a phone stands, for the panel and `redline status`.
    func phoneDidChange(_ phone: Devicectl.Phone, state phoneState: PhoneState) {
        let phone = HubStatus.Phone(
            name: phone.name,
            udid: phone.udid,
            state: phoneState.description,
            model: phone.model.isEmpty ? nil : phone.model,
            phoneState: phoneState
        )
        state.withLock { state in
            // A pass that changes nothing writes nothing.
            guard state.phoneStates.updateValue(phone, forKey: phone.udid) != phone else { return }
            queueWrite(.status, in: &state)
        }
    }

    /// What the hub is doing now, as `status` and the menu bar panel show it.
    ///
    /// Memory only.
    func statusSnapshot() -> HubStatus {
        let containers = simulators?.containerCount ?? 0
        return state.withLock { state in
            HubStatus(
                pid: getpid(),
                startedAt: startedAt,
                apps: state.currentApps,
                fixedApps: fixedApps,
                hosts: state.hosts,
                port: HubListener.port,
                phones: state.phoneStates.values.sorted { $0.name < $1.name },
                simulatorContainers: containers
            )
        }
    }

    /// The simulators with a watched app installed.
    func watchedSimulators() -> Set<String> {
        simulators?.simulatorIDs ?? []
    }

    /// Phones no longer paired leave the status, and their links stop giving them the address.
    ///
    /// A link's state goes once the try it has in progress is over, so that try can't bring it
    /// back.
    func forgetPhones(except paired: Set<String>) {
        let unpaired = state.withLock { state in
            let gone = state.links.filter { !paired.contains($0.key) }
            for udid in gone.keys { state.links[udid] = nil }
            for udid in state.phoneStates.keys where !paired.contains(udid) && gone[udid] == nil {
                state.phoneStates[udid] = nil
            }
            return Array(gone.values)
        }
        for link in unpaired {
            link.unpair { [weak self] in
                guard let self else { return }
                let udid = link.phone.udid
                // Paired again meanwhile: the new link's state stays.
                state.withLock { state in
                    if state.links[udid] == nil { state.phoneStates[udid] = nil }
                }
                writeStatus()
            }
        }
        writeStatus()
    }

    /// Saves the status for `redline status` and a panel in another process.
    func writeStatus() {
        state.withLock { queueWrite(.status, in: &$0) }
    }

    // MARK: - Persistence

    /// Queues a write of `file` while the lock is held, so writes land in the order the state
    /// changed.
    ///
    /// At most one write per file waits; it saves the newest state when it runs.
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

    /// Writes a line, with the time, to standard output and hub.log.
    func log(_ message: String) {
        let line = Data("\(Date.now.formatted(.iso8601)) \(message)\n".utf8)
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
