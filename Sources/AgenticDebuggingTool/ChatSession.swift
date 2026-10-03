#if os(macOS)
import Foundation

/// One chat's side of the hub: its registration, which tells the hub which apps to take
/// reports from, and taking the reports that arrive for them.
final class ChatSession: @unchecked Sendable {
    let paths: HubPaths
    /// Off in tests, which have no hub to start.
    private let startsHub: Bool
    private let lock = NSLock()
    private var record: ChatRecord

    var chat: ChatRecord { lock.withLock { record } }

    init(paths: HubPaths, folder: URL, extraApps: [String], agent: String, startsHub: Bool = true) {
        self.paths = paths
        self.startsHub = startsHub
        let apps = Array(Set(ProjectApps.bundleIDs(in: folder) + extraApps)).sorted()
        record = ChatRecord(id: UUID().uuidString, agent: agent, folder: folder.path, bundleIDs: apps,
                            pid: getpid(), registeredAt: Date(), lastActiveAt: Date())
    }

    /// Registers the chat and starts the hub if it isn't running. A chat whose project builds
    /// no iOS app stays out of it: the server is set up for every project, and most aren't apps.
    func register(agent: String? = nil) {
        lock.withLock { if let agent { record.agent = agent } }
        guard !chat.bundleIDs.isEmpty else { return }
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

    /// Takes the reports waiting for this chat's apps, oldest first. Always takes at least one
    /// waiting report; takes more while their pictures fit in `budget` bytes.
    func take(budget: Int) -> (items: [ReportContent.Item], taken: Int, remaining: Int) {
        let chat = self.chat
        var items: [ReportContent.Item] = []
        var used = 0
        var taken = 0
        for report in InboxQueue.waiting(for: chat.bundleIDs, paths: paths) {
            if taken > 0, used >= budget { break }
            // Another chat may have taken it a moment ago.
            guard InboxQueue.claim(report, for: chat) else { continue }
            let content = ReportContent.items(for: report, budget: max(budget - used, 0))
            items += content.items
            used += content.bytes
            taken += 1
        }
        return (items, taken, InboxQueue.waiting(for: chat.bundleIDs, paths: paths).count)
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

    /// Waits until a report for this chat's apps is waiting, `timeout` passes or the waiter is
    /// cancelled. Woken by the inbox changing, not by checking on a timer. True when one is waiting.
    func waitForReport(timeout: TimeInterval?, waiter: Waiter) -> Bool {
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
            if !InboxQueue.waiting(for: chat.bundleIDs, paths: paths).isEmpty { return true }
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

    private func save() {
        do {
            try Chats.register(chat, paths: paths)
        } catch {
            FileHandle.standardError.write(Data("Couldn't register the chat: \(error.localizedDescription)\n".utf8))
        }
    }
}

/// Starting the hub from a chat, so nothing has to be started by hand.
enum HubProcess {
    /// The pid of a hub that's running, if any.
    static func running(_ paths: HubPaths) -> Int32? {
        guard let text = try? String(contentsOf: paths.pid, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              kill(pid, 0) == 0
        else { return nil }
        return pid
    }

    /// Starts the hub in its own session, so it keeps running after the chat that started it
    /// closes, with nothing attached to the chat's input and output.
    static func startIfNeeded(_ paths: HubPaths) {
        guard running(paths) == nil, let executable = Bundle.main.executablePath else { return }
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
