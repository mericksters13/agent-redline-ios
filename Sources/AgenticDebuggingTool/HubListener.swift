#if os(macOS)
import Foundation
import Network

/// Where apps reach the hub: one line of JSON in, one line back, over the local network.
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
            hub.log("Couldn't listen on port \(Self.port)")
            return
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
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

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, received: Data())
        // A client that never finishes its line doesn't hold the connection open.
        queue.asyncAfter(deadline: .now() + 120) { connection.cancel() }
    }

    private func read(_ connection: NWConnection, received: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var received = received
            if let data { received.append(data) }
            if let newline = received.firstIndex(of: UInt8(ascii: "\n")) {
                guard let offer = HubMessage.decode(HubMessage.Offer.self, from: received[..<newline]) else {
                    connection.cancel()
                    return
                }
                self.hub.handle(offer) { reply in
                    connection.send(content: HubMessage.encode(reply), completion: .contentProcessed { _ in connection.cancel() })
                }
            } else if isComplete || error != nil || received.count > 1_000_000 {
                connection.cancel()
            } else {
                self.read(connection, received: received)
            }
        }
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
}
#endif
