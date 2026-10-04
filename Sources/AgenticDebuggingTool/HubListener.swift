#if os(macOS)
import Foundation
import Network

/// Where apps send their reports: an offer, the hub's answer, the reports it asked for, and its
/// reply, one line of JSON each, over the local network.
final class HubListener: @unchecked Sendable {
    static let port: UInt16 = 47361

    private unowned let hub: Hub
    private let queue = DispatchQueue(label: "listener")
    private var listener: NWListener?
    private var browser: NWBrowser?

    init(hub: Hub) {
        self.hub = hub
    }

    func start() {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let port = NWEndpoint.Port(rawValue: Self.port), let listener = try? NWListener(using: parameters, on: port) else {
            hub.listenerFailed("Couldn't listen on port \(Self.port)")
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
            // Such as when another process has the port.
            if case .failed(let error) = state { self?.hub.listenerFailed("Stopped listening on port \(Self.port): \(error)") }
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
            _ = await lines.send(HubMessage.encode(hub.chats(request)))
            return
        }
        guard let offer = HubMessage.decode(HubMessage.Offer.self, from: first) else {
            hub.log("A connection didn't start with an offer from an app")
            return
        }
        let answer = hub.answer(offer)
        guard await lines.send(HubMessage.encode(answer)), !answer.want.isEmpty else { return }
        var waiting = Set(answer.want)
        while !waiting.isEmpty {
            guard let line = await lines.read(), let upload = HubMessage.decode(HubMessage.Upload.self, from: line), waiting.contains(upload.id) else {
                hub.log("\(offer.bundleID) stopped sending before \(waiting.count == 1 ? "a report" : "\(waiting.count) reports") arrived")
                break
            }
            waiting.remove(upload.id)
            hub.store(upload, offeredIn: offer)
        }
        let finished = offer.reports.map { FinishedReport(id: $0.id, finishedAt: $0.finishedAt) }
        _ = await lines.send(HubMessage.encode(HubMessage.Reply(delivered: hub.settled(device: offer.device, bundleID: offer.bundleID, finished: finished))))
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

    /// One app's connection, read and written a line at a time.
    private final class Lines: @unchecked Sendable {
        private let connection: NWConnection
        private let queue = DispatchQueue(label: "listener.connection")
        private var buffer = Data()

        /// The longest line taken: one report, its pictures encoded in the line.
        static let longestLine = Hub.largestReport * 4 / 3 + 65_536

        init(connection: NWConnection) {
            self.connection = connection
        }

        func open() async -> Bool {
            let once = Once<Bool>()
            return await withCheckedContinuation { continuation in
                once.set(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: once.resume(true)
                    case .failed, .cancelled: once.resume(false)
                    default: break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + 10) { once.resume(false) }
            }
        }

        func send(_ data: Data) async -> Bool {
            await withCheckedContinuation { continuation in
                connection.send(content: data, completion: .contentProcessed { error in continuation.resume(returning: error == nil) })
            }
        }

        /// The next line, without its newline; nil when the connection ends, the line is too
        /// long, or 60 seconds pass.
        func read() async -> Data? {
            let once = Once<Data?>()
            return await withCheckedContinuation { continuation in
                once.set(continuation)
                queue.async {
                    if let line = self.takeLine() { return once.resume(line) }
                    self.queue.asyncAfter(deadline: .now() + 60) { once.resume(nil) }
                    self.receive(once)
                }
            }
        }

        func close() {
            connection.cancel()
        }

        private func receive(_ once: Once<Data?>) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [self] data, _, isComplete, error in
                queue.async {
                    if let data { self.buffer.append(data) }
                    if let line = self.takeLine() {
                        once.resume(line)
                    } else if isComplete || error != nil || self.buffer.count > Self.longestLine {
                        once.resume(nil)
                    } else {
                        self.receive(once)
                    }
                }
            }
        }

        private func takeLine() -> Data? {
            guard let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            return line
        }
    }

    /// Resumes a continuation once, whichever of several callbacks comes first.
    private final class Once<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Never>?

        func set(_ continuation: CheckedContinuation<T, Never>) {
            lock.withLock { self.continuation = continuation }
        }

        func resume(_ value: T) {
            let continuation = lock.withLock {
                defer { self.continuation = nil }
                return self.continuation
            }
            continuation?.resume(returning: value)
        }
    }
}
#endif
