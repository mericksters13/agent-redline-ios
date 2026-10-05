#if REDLINE
import Foundation
import Network
import Synchronization
import Testing
@testable import Redline

/// The phone's side of a whole exchange, against a hub on the loopback interface that proves it
/// holds the app's token and answers each later line with the next line of a script.
struct HubLinkExchangeTests {
    private let store = ReportStore(
        root: FileManager.default.temporaryDirectory.appending(path: "HubLinkExchangeTests-\(UUID().uuidString)")
    )

    /// Files one finished report and returns its id.
    private func fileReport() throws -> String {
        try store.saveDraft([])
        let started = try store.beginReport(date: Date(timeIntervalSince1970: 1_790_000_000))
        try store.finishReport(Fixtures.report(id: started.id), in: started.folder)
        return started.id
    }

    private func address(port: UInt16) -> HubLink.Address {
        HubLink.Address(device: "D", hosts: ["127.0.0.1"], port: port, token: "t")
    }

    @Test func aReportTheHubWantsIsUploadedAndConfirmed() async throws {
        defer { try? FileManager.default.removeItem(at: store.root) }
        let id = try fileReport()
        let hub = try ScriptedHub(script: [
            #"{"delivered":[],"want":["\#(id)"]}"#,
            #"{"delivered":["\#(id)"]}"#,
        ])
        defer { hub.stop() }
        let port = try #require(await hub.start())
        let result = await HubLink.deliver(
            store.undeliveredReports(),
            bundleID: "com.example.app",
            address: address(port: port),
            files: { store.reportFiles($0) },
            patience: 5
        )
        #expect(result.outcome == .delivered)
        #expect(result.delivered == [id])
        let lines = hub.lines
        #expect(lines.count == 3)
        let hello = try HubLink.decode(HubLink.Hello.self, from: Data(lines[0].utf8))
        #expect(hello.device == "D")
        let offer = try HubLink.decode(HubLink.Offer.self, from: Data(lines[1].utf8))
        #expect(offer.reports.map(\.id) == [id])
        #expect(offer.proof == HubLink.proof(.app, token: "t", appNonce: hello.nonce, hubNonce: "h"))
        let upload = try HubLink.decode(HubLink.Upload.self, from: Data(lines[2].utf8))
        #expect(upload.files["report.json"] != nil)
    }

    @Test func somethingThatCantProveItIsTheHubIsSentNothing() async throws {
        defer { try? FileManager.default.removeItem(at: store.root) }
        _ = try fileReport()
        // Such as whatever answers at an old address: a made-up proof, then it would take anything.
        let hub = try ScriptedHub(
            token: nil,
            script: [#"{"nonce":"h","proof":"guess"}"#, #"{"delivered":[],"want":[]}"#]
        )
        defer { hub.stop() }
        let port = try #require(await hub.start())
        let result = await HubLink.deliver(
            store.undeliveredReports(),
            bundleID: "com.example.app",
            address: address(port: port),
            files: { store.reportFiles($0) },
            patience: 5
        )
        #expect(result.outcome == .interrupted)
        #expect(result.delivered.isEmpty)
        // Only the hello, which holds neither the token nor a report.
        #expect(hub.lines.count == 1)
    }

    @Test func aHubThatDoesntKnowTheAppIsRefused() async throws {
        defer { try? FileManager.default.removeItem(at: store.root) }
        _ = try fileReport()
        let hub = try ScriptedHub(token: nil, script: [#"{"nonce":"h","refused":"Pair again"}"#])
        defer { hub.stop() }
        let port = try #require(await hub.start())
        let result = await HubLink.deliver(
            store.undeliveredReports(),
            bundleID: "com.example.app",
            address: address(port: port),
            files: { store.reportFiles($0) },
            patience: 5
        )
        #expect(result.outcome == .refused)
        #expect(hub.lines.count == 1)
    }

    @Test func aHubThatTurnsTheOfferDownIsRefused() async throws {
        defer { try? FileManager.default.removeItem(at: store.root) }
        _ = try fileReport()
        let hub = try ScriptedHub(script: [#"{"delivered":[],"refused":"Pair again","want":[]}"#])
        defer { hub.stop() }
        let port = try #require(await hub.start())
        let result = await HubLink.deliver(
            store.undeliveredReports(),
            bundleID: "com.example.app",
            address: address(port: port),
            files: { store.reportFiles($0) },
            patience: 5
        )
        #expect(result.outcome == .refused)
    }

    @Test func aHubThatHangsUpMidwayInterrupts() async throws {
        defer { try? FileManager.default.removeItem(at: store.root) }
        let id = try fileReport()
        // Wants the report, then closes the connection when it arrives.
        let hub = try ScriptedHub(script: [#"{"delivered":[],"want":["\#(id)"]}"#, nil])
        defer { hub.stop() }
        let port = try #require(await hub.start())
        let result = await HubLink.deliver(
            store.undeliveredReports(),
            bundleID: "com.example.app",
            address: address(port: port),
            files: { store.reportFiles($0) },
            patience: 5
        )
        #expect(result.outcome == .interrupted)
        #expect(result.delivered.isEmpty)
    }

    @Test func nobodyListeningIsUnreachableOncePatienceRunsOut() async throws {
        defer { try? FileManager.default.removeItem(at: store.root) }
        _ = try fileReport()
        // Port 1 is reserved and nothing listens on it. A port freed by another test's hub could
        // be handed to the next one while tests run in parallel.
        let clock = ContinuousClock()
        let start = clock.now
        let result = await HubLink.deliver(
            store.undeliveredReports(),
            bundleID: "com.example.app",
            address: address(port: 1),
            files: { store.reportFiles($0) },
            patience: 0.5
        )
        #expect(result.outcome == .unreachable)
        #expect(clock.now - start < .seconds(10))
    }

    @Test func cancellingAChatsRequestEndsItPromptly() async throws {
        // Reads the hello and never answers; the read would otherwise wait 30 seconds.
        let hub = try ScriptedHub(token: nil, script: [])
        defer { hub.stop() }
        let port = try #require(await hub.start())
        let address = address(port: port)
        let request = Task {
            await HubLink.requestChats(bundleID: "com.example.app", address: address, sourceFile: nil, patience: 5)
        }
        _ = await hub.nextLine()
        let clock = ContinuousClock()
        let start = clock.now
        request.cancel()
        #expect(await request.value == nil)
        #expect(clock.now - start < .seconds(10))
    }
}

/// A hub on the loopback interface.
///
/// With a token, it answers an app's hello with proof that it holds it. Each other line it receives
/// gets the next line of the script as its answer; nil closes the connection, and once the script
/// runs out it stays quiet.
private final class ScriptedHub: Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "Redline.tests.hub")
    private let token: String?
    private let script: [String?]
    private let received = Mutex<[String]>([])
    private let arrivals: AsyncStream<String>
    private let arrival: AsyncStream<String>.Continuation

    init(token: String? = "t", script: [String?]) throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters, on: .any)
        self.token = token
        self.script = script
        (arrivals, arrival) = AsyncStream.makeStream(of: String.self)
    }

    /// Starts listening.
    ///
    /// Returns the port, or nil when the listener couldn't start.
    func start() async -> UInt16? {
        let once = Once<UInt16?>()
        return await withCheckedContinuation { continuation in
            once.set(continuation)
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready: once.resume(listener.port?.rawValue)
                case .failed, .cancelled: once.resume(nil)
                default: break
                }
            }
            listener.newConnectionHandler = { [self] connection in
                connection.start(queue: queue)
                receive(Peer(connection: connection))
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        arrival.finish()
    }

    /// Every line received so far.
    var lines: [String] { received.withLock { $0 } }

    /// Waits for the next line to arrive.
    func nextLine() async -> String? {
        var iterator = arrivals.makeAsyncIterator()
        return await iterator.next()
    }

    /// One connection's unread bytes and place in the script.
    ///
    /// Thread safety: `buffer`, `isGreeted` and `next` are touched only on the hub's queue, where
    /// every connection callback runs.
    private final class Peer: Sendable {
        let connection: NWConnection
        nonisolated(unsafe) var buffer = Data()
        nonisolated(unsafe) var isGreeted = false
        nonisolated(unsafe) var next = 0

        init(connection: NWConnection) { self.connection = connection }
    }

    private func receive(_ peer: Peer) {
        peer.connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) {
            [self] data, _, isComplete, error in
            if let data { peer.buffer.append(data) }
            while let newline = peer.buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(decoding: peer.buffer[peer.buffer.startIndex..<newline], as: UTF8.self)
                peer.buffer.removeSubrange(peer.buffer.startIndex...newline)
                received.withLock { $0.append(line) }
                arrival.yield(line)
                if let token, !peer.isGreeted {
                    peer.isGreeted = true
                    let hello = try? HubLink.decode(HubLink.Hello.self, from: Data(line.utf8))
                    let proof = hello.map { HubLink.proof(.hub, token: token, appNonce: $0.nonce, hubNonce: "h") }
                    if let challenge = try? HubLink.encode(HubLink.Challenge(nonce: "h", proof: proof)) {
                        peer.connection.send(content: challenge, completion: .contentProcessed { _ in })
                    }
                    continue
                }
                let step = peer.next
                peer.next += 1
                guard script.indices.contains(step) else { continue }
                guard let reply = script[step] else {
                    peer.connection.cancel()
                    return
                }
                peer.connection.send(content: Data((reply + "\n").utf8), completion: .contentProcessed { _ in })
            }
            guard !isComplete, error == nil else { return }
            receive(peer)
        }
    }
}
#endif
