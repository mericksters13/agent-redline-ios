#if os(macOS)
import Foundation
import Network
import Synchronization

/// Where apps send their reports: an offer, the hub's answer, the reports it asked for, and its
/// reply, one line of JSON each, over the local network.
///
/// Thread safety: `listener` and `browser` are written once in `start()` and read only in `stop()`.
final class HubListener: @unchecked Sendable {
    static let port: UInt16 = 47361
    /// The listener's queue, and the one every connection's queue targets.
    static let network = DispatchQueue(label: "Redline.hub.network", qos: .utility)

    private unowned let hub: Hub
    private let queue = HubListener.network
    private var listener: NWListener?
    private var browser: NWBrowser?

    init(hub: Hub) {
        self.hub = hub
    }

    func start() {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let port = NWEndpoint.Port(rawValue: Self.port), let listener = try? NWListener(using: parameters, on: port) else {
            hub.log("Couldn't listen on port \(Self.port)")
            return
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let lines = Lines(connection: connection)
            Task {
                await self.serve(lines)
                lines.close()
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state { self?.hub.log("Stopped listening: \(error)") }
        }
        listener.start(queue: queue)
        self.listener = listener
        watchForWakingPhones()
    }

    func stop() {
        listener?.cancel()
        browser?.cancel()
    }

    private func serve(_ lines: Lines) async {
        guard await lines.open() else { return }
        guard let first = await lines.read() else { return }
        // Before sending, the app asks where a report can go.
        if let request = HubMessage.decode(HubMessage.ChatsRequest.self, from: first), request.kind == "chats" {
            _ = await lines.send(HubMessage.encode(await hub.chats(request)))
            return
        }
        guard let offer = HubMessage.decode(HubMessage.Offer.self, from: first) else {
            hub.log("A connection didn't start with an offer from an app")
            return
        }
        let answer = await hub.answer(offer)
        guard await lines.send(HubMessage.encode(answer)), !answer.want.isEmpty else { return }
        var waiting = Set(answer.want)
        while !waiting.isEmpty {
            guard let line = await lines.read(), let upload = HubMessage.decode(HubMessage.Upload.self, from: line), waiting.contains(upload.id) else {
                hub.log("\(offer.bundleID) stopped sending before \(waiting.count == 1 ? "a report" : "\(waiting.count) reports") arrived")
                break
            }
            waiting.remove(upload.id)
            await hub.store(upload, offeredIn: offer)
        }
        let finished = offer.reports.map { FinishedReport(id: $0.id, finishedAt: $0.finishedAt) }
        let delivered = await hub.settled(device: offer.device, bundleID: offer.bundleID, finished: finished)
        _ = await lines.send(HubMessage.encode(HubMessage.Reply(delivered: delivered)))
    }

    /// Phones announce Xcode's wireless link whenever they wake. The announcement doesn't say
    /// which paired phone it is, so every phone still waiting for its address gets a try.
    private func watchForWakingPhones() {
        let browser = NWBrowser(for: .bonjour(type: "_remotepairing._tcp", domain: "local."), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] _, changes in
            let woke = changes.contains { change in
                if case .added = change { return true }
                return false
            }
            if woke { self?.hub.phoneWoke() }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    /// One app's connection, read and written a line at a time. Cancelling the task that waits
    /// on it cancels the connection, which ends the wait.
    ///
    /// Thread safety: `buffer` is read and written only on `queue`.
    private final class Lines: @unchecked Sendable {
        private let connection: NWConnection
        private let queue = DispatchQueue(label: "Redline.hub.connection", target: HubListener.network)
        private var buffer = LineBuffer()

        /// The longest line taken: one report, its pictures encoded in the line.
        static let longestLine = Hub.largestReport * 4 / 3 + 65_536

        init(connection: NWConnection) {
            self.connection = connection
        }

        func open() async -> Bool {
            let once = Once<Bool>()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    once.set(continuation)
                    connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready: once.resume(true)
                        case .failed, .cancelled: once.resume(false)
                        case .setup, .preparing, .waiting: break
                        @unknown default: break
                        }
                    }
                    connection.start(queue: queue)
                    once.timeout(after: 10, on: queue, with: false)
                }
            } onCancel: {
                connection.cancel()
            }
        }

        /// Sends `data`; false when the connection fails or the app stops reading for 30 seconds.
        func send(_ data: Data) async -> Bool {
            let once = Once<Bool>()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    once.set(continuation)
                    connection.send(content: data, completion: .contentProcessed { error in once.resume(error == nil) })
                    once.timeout(after: 30, on: queue, with: false)
                }
            } onCancel: {
                connection.cancel()
            }
        }

        /// The next line, without its newline; nil when the connection ends, the line is too
        /// long, or 60 seconds pass.
        func read() async -> Data? {
            let once = Once<Data?>()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    once.set(continuation)
                    queue.async {
                        if let line = self.buffer.takeLine() { return once.resume(line) }
                        once.timeout(after: 60, on: self.queue, with: nil)
                        self.receive(once)
                    }
                }
            } onCancel: {
                connection.cancel()
            }
        }

        func close() {
            connection.cancel()
        }

        private func receive(_ once: Once<Data?>) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [self] data, _, isComplete, error in
                queue.async {
                    if let data { self.buffer.append(data) }
                    if let line = self.buffer.takeLine() {
                        once.resume(line)
                    } else if isComplete || error != nil || self.buffer.count > Self.longestLine {
                        once.resume(nil)
                    } else {
                        self.receive(once)
                    }
                }
            }
        }
    }
}

/// Resumes a continuation once, whichever of several callbacks comes first, and cancels its
/// timeout when it does.
final class Once<T: Sendable>: Sendable {
    private struct Waiting {
        var continuation: CheckedContinuation<T, Never>?
        var timeout: DispatchWorkItem?
    }

    private let waiting = Mutex(Waiting())

    func set(_ continuation: CheckedContinuation<T, Never>) {
        waiting.withLock { $0.continuation = continuation }
    }

    /// Resumes with `value` after `seconds`, unless something resumes first.
    func timeout(after seconds: TimeInterval, on queue: DispatchQueue, with value: T) {
        waiting.withLock { waiting in
            guard waiting.continuation != nil else { return }
            let item = DispatchWorkItem { self.resume(value) }
            waiting.timeout = item
            queue.asyncAfter(deadline: .now() + seconds, execute: item)
        }
    }

    func resume(_ value: T) {
        let waiting = waiting.withLock { waiting in
            defer { waiting = Waiting() }
            return waiting
        }
        waiting.timeout?.cancel()
        waiting.continuation?.resume(returning: value)
    }
}

/// The bytes read from a connection, taken a line at a time. Each byte is looked at once for a
/// newline, however many pieces a long line arrives in.
struct LineBuffer {
    private var bytes = Data()
    /// How far the search for a newline has got.
    private var scanned = 0

    var count: Int { bytes.count }

    mutating func append(_ data: Data) {
        bytes.append(data)
    }

    /// The next line, without its newline; nil until one is complete.
    mutating func takeLine() -> Data? {
        guard let newline = bytes[(bytes.startIndex + scanned)...].firstIndex(of: UInt8(ascii: "\n")) else {
            scanned = bytes.count
            return nil
        }
        let line = Data(bytes[bytes.startIndex..<newline])
        bytes = Data(bytes[(newline + 1)...])
        scanned = 0
        return line
    }
}
#endif
