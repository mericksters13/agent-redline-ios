#if os(macOS)
import Foundation
import Network

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

    /// Listens on `port` and watches for waking phones.
    func start() {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(integerLiteral: Self.port))
        } catch {
            hub.listenerFailed("Couldn't listen on port \(Self.port): \(error.localizedDescription)")
            return
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let lines = Lines(connection: connection)
            Task {
                await serve(lines)
                lines.close()
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            // Such as when another process has the port.
            if case .failed(let error) = state {
                self?.hub.listenerFailed("Stopped listening on port \(Self.port): \(error)")
            }
        }
        listener.start(queue: queue)
        self.listener = listener
        watchForWakingPhones()
    }

    /// Stops listening and watching.
    func stop() {
        listener?.cancel()
        browser?.cancel()
    }

    private func serve(_ lines: Lines) async {
        guard await lines.open() else { return }
        guard let first = await lines.read() else { return }
        // Before sending, the app asks where a report can go. An offer has no kind.
        if let request = try? HubMessage.decode(HubMessage.ChatsRequest.self, from: first), request.kind == "chats" {
            _ = await lines.send(HubMessage.encode(await hub.chats(request)))
            return
        }
        let offer: HubMessage.Offer
        do {
            offer = try HubMessage.decode(HubMessage.Offer.self, from: first)
        } catch {
            hub.log("A connection didn't start with an offer from an app: \(HubMessage.reason(error))")
            return
        }
        let answer = await hub.answer(offer)
        guard await lines.send(HubMessage.encode(answer)), !answer.want.isEmpty else { return }
        var waiting = Set(answer.want)
        while !waiting.isEmpty {
            let stopped =
                "\(offer.bundleID) stopped sending before \(waiting.count == 1 ? "a report" : "\(waiting.count) reports") arrived"
            guard let line = await lines.read() else {
                hub.log(stopped)
                break
            }
            let upload: HubMessage.Upload
            do {
                upload = try HubMessage.decode(HubMessage.Upload.self, from: line)
            } catch {
                hub.log("\(stopped): \(HubMessage.reason(error))")
                break
            }
            guard waiting.contains(upload.id) else {
                hub.log("\(stopped): it sent \(upload.id), which the hub didn't ask for")
                break
            }
            waiting.remove(upload.id)
            do {
                try await hub.store(upload, offeredIn: offer)
            } catch {
                // The hub logged why; the report isn't counted as delivered, so it's offered again.
            }
        }
        let finished = offer.reports.map { FinishedReport(id: $0.id, finishedAt: $0.finishedAt) }
        let delivered = await hub.settledReportIDs(device: offer.device, bundleID: offer.bundleID, finished: finished)
        _ = await lines.send(HubMessage.encode(HubMessage.Reply(delivered: delivered)))
    }

    /// Phones announce Xcode's wireless link whenever they wake.
    ///
    /// The announcement doesn't say which paired phone it is, so every phone still waiting for its
    /// address gets a try.
    private func watchForWakingPhones() {
        let browser = NWBrowser(for: .bonjour(type: "_remotepairing._tcp", domain: "local."), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] _, changes in
            let woke = changes.contains { change in
                if case .added = change { return true }
                return false
            }
            if woke { self?.hub.phoneDidWake() }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    /// One app's connection, read and written a line at a time.
    ///
    /// Cancelling the task that waits on it cancels the connection, which ends the wait.
    ///
    /// Thread safety: `buffer` is read and written only on `queue`.
    private final class Lines: @unchecked Sendable {
        private let connection: NWConnection
        private let queue = DispatchQueue(label: "Redline.hub.connection", target: HubListener.network)
        private var buffer = LineBuffer()

        /// The longest line taken: one report, its snapshots encoded in the line.
        static let longestLine = Hub.largestReport * 4 / 3 + 65_536
        /// How long a read waits with nothing received before it gives up.
        static let idleTimeout: TimeInterval = 60

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

        /// The next line, without its newline; nil when the connection ends, the line is too long, or
        /// `idleTimeout` passes with nothing received.
        ///
        /// A large report on a slow network keeps arriving well past `idleTimeout`, so only a stalled
        /// connection runs out.
        func read() async -> Data? {
            let once = Once<Data?>()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    once.set(continuation)
                    queue.async {
                        if let line = self.buffer.takeLine() { return once.resume(line) }
                        once.timeout(after: Self.idleTimeout, on: self.queue, with: nil)
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
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) {
                [self] data, _, isComplete, error in
                queue.async {
                    if let data { self.buffer.append(data) }
                    if let line = self.buffer.takeLine() {
                        once.resume(line)
                    } else if isComplete || error != nil || self.buffer.count > Self.longestLine {
                        once.resume(nil)
                    } else {
                        // More of the line arrived: the wait starts over.
                        if data?.isEmpty == false { once.timeout(after: Self.idleTimeout, on: self.queue, with: nil) }
                        self.receive(once)
                    }
                }
            }
        }
    }
}
#endif
