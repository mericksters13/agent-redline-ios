#if os(macOS)
import Foundation
import Synchronization

/// One chat's side of the hub: its registration, which tells the hub which apps to take
/// reports from, and taking the reports that arrive for them.
final class ChatSession: Sendable {
    let paths: HubPaths
    /// Off in tests, which have no hub to start.
    private let startsHub: Bool
    private let record: Mutex<ChatRecord>

    var chat: ChatRecord { record.withLock { $0 } }

    /// `id` names the chat, such as an agent's session ID, so each of its hooks finds the same
    /// record. `pid` is the process the chat lives in, when that isn't this one.
    init(
        paths: HubPaths,
        folder: URL,
        extraApps: [String],
        agent: String,
        id: String? = nil,
        pid: Int32? = nil,
        startsHub: Bool = true
    ) {
        self.paths = paths
        self.startsHub = startsHub
        let apps = Array(Set(ProjectApps.bundleIDs(in: folder) + extraApps)).sorted()
        record = Mutex(
            ChatRecord(
                id: id ?? UUID().uuidString,
                agent: agent,
                folder: folder.path,
                bundleIDs: apps,
                pid: pid ?? getpid(),
                registeredAt: .now,
                lastActiveAt: .now
            )
        )
    }

    /// Registers this process as the one waiting for the chat's reports.
    func registerWaiting() {
        record.withLock { $0.waiter = getpid() }
        register()
    }

    /// Registers the chat and starts the hub if it isn't running.
    ///
    /// A chat whose project builds no iOS app stays out of it: the server is set up for every
    /// project, and most aren't apps.
    func register(agent: String? = nil) {
        record.withLock { if let agent { $0.agent = agent } }
        guard !chat.bundleIDs.isEmpty else { return }
        // Noted before the chat's file appears, so the hub sees both when it looks.
        do {
            try ProjectHistory.note(chat, paths: paths)
        } catch {
            printError("Couldn't note the chat's apps for the hub: \(error.localizedDescription)")
        }
        save()
        if startsHub { HubProcess.startIfNeeded(paths) }
    }

    /// Removes the chat's record, so the hub stops taking reports for it.
    func unregister() {
        Chats.unregister(chat.id, paths: paths)
    }

    /// Notes that the chat was used just now, for picking the most recent chat.
    func touch() {
        record.withLock { $0.lastActiveAt = Date.now }
        guard !chat.bundleIDs.isEmpty else { return }
        save()
    }

    /// The most text one hook answer carries: two reports of the longest text.
    ///
    /// Reports past it wait for the chat's next hook.
    static let hookBudget = 2 * ReportContent.longestText

    /// Takes the reports sent to this chat, oldest first, as text with pictures named by path, for
    /// agents that get reports through hooks.
    ///
    /// Always takes at least one; takes more while their text fits in `budget` bytes. Nil when
    /// there's none. The reports stay claimed by this process until the caller has written the
    /// text out and calls `settle`.
    func takeAddressed(budget: Int = hookBudget) -> (text: String, reports: [InboxReport])? {
        let chat = self.chat
        var texts: [String] = []
        var used = 0
        var taken: [InboxReport] = []
        for report in Inbox.reportsAddressed(to: chat.id, bundleIDs: chat.bundleIDs, paths: paths) {
            let text = ReportContent.text(for: report)
            if !taken.isEmpty, used + text.utf8.count > budget { break }
            // Another of the chat's hooks may have taken it a moment ago.
            guard case .claimed = Inbox.claim(report, for: chat) else { continue }
            texts.append(text)
            used += text.utf8.count
            taken.append(report)
        }
        return taken.isEmpty ? nil : (texts.joined(separator: "\n\n"), taken)
    }

    /// Takes the reports waiting for this chat's apps that were sent to it or sent nowhere, oldest
    /// first.
    ///
    /// Always takes at least one such report; takes more while their text and pictures fit in
    /// `budget` bytes. The reports stay claimed by this process until the caller has written the
    /// items out and calls `settle`.
    func take(budget: Int) -> (items: [ReportContent.Item], reports: [InboxReport], remaining: Int) {
        let chat = self.chat
        var items: [ReportContent.Item] = []
        var used = 0
        var taken: [InboxReport] = []
        var lookedAt = 0
        let waiting = Inbox.takeableReports(by: chat, paths: paths)
        for report in waiting {
            // Another report's text, however long, must fit too.
            if !taken.isEmpty, budget - used < ReportContent.longestText { break }
            lookedAt += 1
            // Another chat may have taken it a moment ago.
            guard case .claimed = Inbox.claim(report, for: chat) else { continue }
            let content = ReportContent.items(for: report, budget: max(budget - used, 0))
            items += content.items
            used += content.bytes
            taken.append(report)
        }
        return (items, taken, waiting.count - lookedAt)
    }

    /// Settles reports this process took: they're the chat's once what carries them was written
    /// out (`isDelivered`); otherwise they're freed for the chat to take again.
    static func settle(_ reports: [InboxReport], isDelivered: Bool) {
        for report in reports {
            do {
                if isDelivered { try Inbox.handedOver(report) } else { try Inbox.release(report) }
            } catch {
                printError(
                    "Couldn't settle report \(report.source.reportID) for the chat: \(error.localizedDescription)"
                )
            }
        }
    }

    /// How long a chat that wasn't used most recently waits for the one that was to take a
    /// report, before taking it itself.
    static let deferToRecentChat: TimeInterval = 4

    /// Waits until there's a report this chat should take.
    ///
    /// When several chats on the project are waiting, the one used most recently takes it; the
    /// others take it only if it's still waiting a moment later, such as when that chat is busy or
    /// gone.
    func waitForRoutedReport(timeout: TimeInterval?, waiter: Waiter) -> Bool {
        let deadline = timeout.map { Date.now.addingTimeInterval($0) }
        while true {
            let left = deadline.map { $0.timeIntervalSinceNow }
            if let left, left <= 0 { return false }
            guard waitForReport(timeout: left, waiter: waiter) else { return false }
            let open = Chats.removeClosedChats(paths)
            let me = open.first { $0.id == chat.id } ?? chat
            let moreRecent = open.contains { other in
                other.id != me.id && other.isWaiting && other.lastActiveAt > me.lastActiveAt
                    && !Set(other.bundleIDs).isDisjoint(with: me.bundleIDs)
            }
            guard moreRecent else { return true }
            // Counts left from inbox changes already seen would cut the deferral short; no folder
            // is watched now, so after draining only cancel() can end it early.
            while waiter.signal.wait(timeout: .now()) == .success {}
            if waiter.isCancelled { return false }
            // Runs on `redline wait`'s main thread, never from a Task. Parks it for at most
            // deferToRecentChat (4 s).
            _ = waiter.signal.wait(timeout: .now() + Self.deferToRecentChat)
            if waiter.isCancelled { return false }
            // Still there: the more recent chat didn't take it.
            if !Inbox.takeableReports(by: chat, paths: paths).isEmpty { return true }
        }
    }

    /// Where inbox changes wake waits.
    private static let watching = DispatchQueue(label: "Redline.chat.inbox", qos: .utility)

    /// Something to wait on that can be stopped from another thread.
    final class Waiter: Sendable {
        fileprivate let signal = DispatchSemaphore(value: 0)
        private let isStopped = Mutex(false)

        var isCancelled: Bool { isStopped.withLock { $0 } }

        func cancel() {
            isStopped.withLock { $0 = true }
            signal.signal()
        }

        /// Makes a wait look again, as a change in the inbox does.
        func wake() {
            signal.signal()
        }
    }

    /// Waits until a report this chat may take is waiting, `timeout` passes or the waiter is
    /// cancelled.
    ///
    /// Woken by the inbox changing, not by checking on a timer. True when one is waiting.
    func waitForReport(timeout: TimeInterval?, waiter: Waiter) -> Bool {
        let chat = self.chat
        return wait(timeout: timeout, waiter: waiter) {
            !Inbox.takeableReports(by: chat, paths: self.paths).isEmpty
        }
    }

    private func wait(timeout: TimeInterval?, waiter: Waiter, until ready: () -> Bool) -> Bool {
        let chat = self.chat
        let deadline = timeout.map { Date.now.addingTimeInterval($0) }
        var sources: [DispatchSourceFileSystemObject] = []
        for bundleID in chat.bundleIDs {
            let folder = paths.inbox.appending(path: bundleID, directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let descriptor = open(folder.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: .write,
                queue: Self.watching
            )
            source.setEventHandler { waiter.wake() }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            sources.append(source)
        }
        defer {
            for source in sources { source.cancel() }
        }
        while true {
            if ready() { return true }
            if waiter.isCancelled { return false }
            // Runs on a wait's own thread in the MCP server or on `redline wait`'s main thread,
            // never from a Task. Parks that thread for at most the timeout: MCPServer.longestWait
            // (600 s) for the server, the --timeout given, or until cancelled for the command.
            if let deadline {
                let left = deadline.timeIntervalSinceNow
                guard left > 0 else { return false }
                _ = waiter.signal.wait(timeout: .now() + left)
            } else {
                waiter.signal.wait()
            }
            // One report makes several inbox changes; one scan covers them all.
            while waiter.signal.wait(timeout: .now()) == .success {}
        }
    }

    /// Saves the record, keeping the waiter and first registration another process saved for
    /// the same chat: each hook runs in its own process.
    ///
    /// One process at a time reads and rewrites the record, so none drops the waiter another just
    /// saved. The lock is released when the descriptor closes.
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
            printError("Couldn't register the chat: \(error.localizedDescription)")
        }
    }
}
#endif
