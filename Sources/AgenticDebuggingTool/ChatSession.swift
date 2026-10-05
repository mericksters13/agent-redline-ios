#if os(macOS)
import AppKit

/// One chat's side of the hub: its registration, which tells the hub which apps to take
/// reports from, and taking the reports that arrive for them.
final class ChatSession: @unchecked Sendable {
    let paths: HubPaths
    /// Off in tests, which have no hub to start.
    private let startsHub: Bool
    private let lock = NSLock()
    private var record: ChatRecord

    var chat: ChatRecord { lock.withLock { record } }

    /// `id` names the chat, such as an agent's session ID, so each of its hooks finds the same
    /// record. `pid` is the process the chat lives in, when that isn't this one.
    init(paths: HubPaths, folder: URL, extraApps: [String], agent: String, id: String? = nil, pid: Int32? = nil, startsHub: Bool = true) {
        self.paths = paths
        self.startsHub = startsHub
        let apps = Array(Set(ProjectApps.bundleIDs(in: folder) + extraApps)).sorted()
        record = ChatRecord(id: id ?? UUID().uuidString, agent: agent, folder: folder.path, bundleIDs: apps,
                            pid: pid ?? getpid(), registeredAt: Date(), lastActiveAt: Date())
    }

    /// Registers this process as the one waiting for the chat's reports.
    func registerWaiting() {
        lock.withLock { record.waiter = getpid() }
        register()
    }

    /// Registers the chat and starts the hub if it isn't running. A chat whose project builds
    /// no iOS app stays out of it: the server is set up for every project, and most aren't apps.
    func register(agent: String? = nil) {
        lock.withLock { if let agent { record.agent = agent } }
        guard !chat.bundleIDs.isEmpty else { return }
        // Noted before the chat's file appears, so the hub sees both when it looks.
        ProjectHistory.note(chat, paths: paths)
        save()
        if startsHub { HubProcess.startIfNeeded(paths) }
    }

    func unregister() {
        Chats.unregister(chat.id, paths: paths)
    }

    /// Notes that the chat was used just now, for picking the most recent chat.
    func touch() {
        lock.withLock { record.lastActiveAt = Date() }
        guard !chat.bundleIDs.isEmpty else { return }
        save()
    }

    /// The most text one hook answer carries: two reports of the longest text. Reports past it
    /// wait for the chat's next hook.
    static let hookBudget = 2 * ReportContent.longestText

    /// Takes the reports sent to this chat, oldest first, as text with pictures named by path,
    /// for agents that get reports through hooks. Always takes at least one; takes more while
    /// their text fits in `budget` bytes. Nil when there's none. The reports stay claimed by
    /// this process until the caller has written the text out and calls `settle`.
    func takeAddressed(budget: Int = hookBudget) -> (text: String, reports: [InboxReport])? {
        let chat = self.chat
        var texts: [String] = []
        var used = 0
        var taken: [InboxReport] = []
        for report in InboxQueue.addressed(to: chat.id, bundleIDs: chat.bundleIDs, paths: paths) {
            let text = ReportContent.text(for: report)
            if !taken.isEmpty, used + text.utf8.count > budget { break }
            // Another of the chat's hooks may have taken it a moment ago.
            guard InboxQueue.claim(report, for: chat) else { continue }
            texts.append(text)
            used += text.utf8.count
            taken.append(report)
        }
        guard !taken.isEmpty else { return nil }
        return (texts.joined(separator: "\n\n"), taken)
    }

    /// Settles reports this process took: they're the chat's once what carries them was
    /// written out (`delivered`); otherwise they're freed for the chat to take again.
    static func settle(_ reports: [InboxReport], delivered: Bool) {
        reports.forEach(delivered ? InboxQueue.handedOver : InboxQueue.release)
    }

    /// Waits until a report is sent to this chat, `timeout` passes or the waiter is cancelled.
    func waitForAddressed(timeout: TimeInterval?, waiter: Waiter) -> Bool {
        let chat = self.chat
        return wait(timeout: timeout, waiter: waiter) { !InboxQueue.addressed(to: chat.id, bundleIDs: chat.bundleIDs, paths: self.paths).isEmpty }
    }

    /// Takes the reports waiting for this chat's apps that were sent to it or sent nowhere,
    /// oldest first. Always takes at least one such report; takes more while their text and
    /// pictures fit in `budget` bytes. The reports stay claimed by this process until the caller
    /// has written the items out and calls `settle`.
    func take(budget: Int) -> (items: [ReportContent.Item], reports: [InboxReport], remaining: Int) {
        let chat = self.chat
        var items: [ReportContent.Item] = []
        var used = 0
        var taken: [InboxReport] = []
        for report in InboxQueue.takeable(by: chat, paths: paths) {
            // Another report's text, however long, must fit too.
            if !taken.isEmpty, budget - used < ReportContent.longestText { break }
            // Another chat may have taken it a moment ago.
            guard InboxQueue.claim(report, for: chat) else { continue }
            let content = ReportContent.items(for: report, budget: max(budget - used, 0))
            items += content.items
            used += content.bytes
            taken.append(report)
        }
        return (items, taken, InboxQueue.takeable(by: chat, paths: paths).count)
    }

    /// How long a chat that wasn't used most recently waits for the one that was to take a
    /// report, before taking it itself.
    static let deferToRecentChat: TimeInterval = 4

    /// Waits until there's a report this chat should take. When several chats on the project
    /// are waiting, the one used most recently takes it; the others take it only if it's still
    /// waiting a moment later, such as when that chat is busy or gone.
    func waitForRoutedReport(timeout: TimeInterval?, waiter: Waiter) -> Bool {
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while true {
            let left = deadline.map { $0.timeIntervalSinceNow }
            if let left, left <= 0 { return false }
            guard waitForReport(timeout: left, waiter: waiter) else { return false }
            let me = Chats.live(paths).first { $0.id == chat.id } ?? chat
            let moreRecent = Chats.live(paths).contains { other in
                other.id != me.id && other.isWaiting && other.lastActiveAt > me.lastActiveAt
                    && !Set(other.bundleIDs).isDisjoint(with: me.bundleIDs)
            }
            guard moreRecent else { return true }
            _ = waiter.signal.wait(timeout: .now() + Self.deferToRecentChat)
            if waiter.isCancelled { return false }
            // Still there: the more recent chat didn't take it.
            if !InboxQueue.takeable(by: chat, paths: paths).isEmpty { return true }
        }
    }

    /// Something to wait on that can be stopped from another thread.
    final class Waiter: @unchecked Sendable {
        fileprivate let signal = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var stopped = false

        var isCancelled: Bool { lock.withLock { stopped } }

        func cancel() {
            lock.withLock { stopped = true }
            signal.signal()
        }
    }

    /// Waits until a report this chat may take is waiting, `timeout` passes or the waiter is
    /// cancelled. Woken by the inbox changing, not by checking on a timer. True when one is waiting.
    func waitForReport(timeout: TimeInterval?, waiter: Waiter) -> Bool {
        let chat = self.chat
        return wait(timeout: timeout, waiter: waiter) { !InboxQueue.takeable(by: chat, paths: self.paths).isEmpty }
    }

    private func wait(timeout: TimeInterval?, waiter: Waiter, until ready: () -> Bool) -> Bool {
        let chat = self.chat
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        var sources: [DispatchSourceFileSystemObject] = []
        for bundleID in chat.bundleIDs {
            let folder = paths.inbox.appending(path: bundleID, directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let descriptor = open(folder.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .global())
            source.setEventHandler { waiter.signal.signal() }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            sources.append(source)
        }
        defer { sources.forEach { $0.cancel() } }
        while true {
            if ready() { return true }
            if waiter.isCancelled { return false }
            if let deadline {
                let left = deadline.timeIntervalSinceNow
                guard left > 0 else { return false }
                _ = waiter.signal.wait(timeout: .now() + left)
            } else {
                waiter.signal.wait()
            }
        }
    }

    /// Saves the record, keeping the waiter and first registration another process saved for
    /// the same chat: each hook runs in its own process. One process at a time reads and
    /// rewrites the record, so none drops the waiter another just saved. Released when the
    /// descriptor closes.
    private func save() {
        var chat = self.chat
        try? FileManager.default.createDirectory(at: Chats.folder(paths), withIntermediateDirectories: true)
        let lock = open(Chats.recordLock(chat.id, paths: paths).path, O_RDWR | O_CREAT, 0o600)
        if lock >= 0 { flock(lock, LOCK_EX) }
        defer { if lock >= 0 { close(lock) } }
        if let saved = Chats.record(chat.id, paths: paths) {
            // The first registration of this process: the hub checks the PID against it.
            if saved.pid == chat.pid { chat.registeredAt = saved.registeredAt }
            if chat.waiter == nil { chat.waiter = saved.waiter }
        }
        do {
            try Chats.register(chat, paths: paths)
        } catch {
            FileHandle.standardError.write(Data("Couldn't register the chat: \(error.localizedDescription)\n".utf8))
        }
    }
}

/// Starting the hub from a chat, so nothing has to be started by hand.
enum HubProcess {
    /// The pid of a hub that's running, if any. A running hub holds a lock on its PID file, so
    /// a file left by a hub that crashed doesn't count, even once another process has its pid.
    static func running(_ paths: HubPaths) -> Int32? {
        let descriptor = open(paths.pid.path, O_RDONLY)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_SH | LOCK_NB) != 0 else { return nil }
        guard let text = try? String(contentsOf: paths.pid, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Locks the PID file and writes this process's pid in it, for the hub to hold open while it
    /// runs. Nil when another hub holds it.
    static func claim(_ paths: HubPaths) -> Int32? {
        let descriptor = open(paths.pid.path, O_RDWR | O_CREAT, 0o644)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        let pid = Array("\(getpid())\n".utf8)
        ftruncate(descriptor, 0)
        _ = pid.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
        return descriptor
    }

    /// The menu bar app's bundle identifier, as scripts/build-hub-app.sh sets it.
    static let appBundleID = "com.iosagenticdebuggingkit.hub"

    /// The menu bar app, which is the hub, when it's installed: in ~/Applications, where
    /// scripts/build-hub-app.sh puts it by default, or wherever else Launch Services knows it by
    /// its identifier, such as /Applications. With more than one copy, the newest build.
    static var app: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications/Agentic Debugging.app")
        return newestApp(among: [home] + NSWorkspace.shared.urlsForApplications(withBundleIdentifier: appBundleID))
    }

    /// The copy whose program was built last. Every build has the same version, so a copy left
    /// in one folder by an earlier install would otherwise be as likely to open as the one
    /// installed since in another. Copies in the Trash don't count: ~/.Trash, or .Trashes on
    /// another volume.
    static func newestApp(among copies: [URL]) -> URL? {
        let dated = copies.compactMap { app -> (app: URL, built: Date)? in
            let program = app.appending(path: "Contents/MacOS/agentic-debugging")
            let folders = app.standardizedFileURL.pathComponents
            guard !folders.contains(".Trash"), !folders.contains(".Trashes"),
                  let built = (try? FileManager.default.attributesOfItem(atPath: program.path))?[.modificationDate] as? Date
            else { return nil }
            return (app, built)
        }
        return dated.max { $0.built < $1.built }?.app
    }

    /// Starts the hub in its own session, so it keeps running after the chat that started it
    /// closes, with nothing attached to the chat's input and output. The menu bar app is the
    /// hub when it's installed. When it can't be opened, such as over SSH with no one logged
    /// in, the command-line hub starts instead.
    static func startIfNeeded(_ paths: HubPaths) {
        guard running(paths) == nil else { return }
        if let app {
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-g", app.path]
            open.standardOutput = FileHandle.nullDevice
            open.standardError = FileHandle.nullDevice
            if (try? open.run()) != nil {
                open.waitUntilExit()
                if open.terminationStatus == 0 { return }
            }
        }
        guard let executable = Bundle.main.executablePath else { return }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        var files: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&files)
        defer { posix_spawn_file_actions_destroy(&files) }
        for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            posix_spawn_file_actions_addopen(&files, descriptor, "/dev/null", descriptor == STDIN_FILENO ? O_RDONLY : O_WRONLY, 0)
        }
        var pid: pid_t = 0
        let arguments = [executable, "hub"]
        var argv = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        posix_spawn(&pid, executable, &files, &attributes, &argv, environ)
    }
}
#endif
