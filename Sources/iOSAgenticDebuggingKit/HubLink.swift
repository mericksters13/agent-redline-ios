#if AGENTIC_DEBUGGING
import Foundation
import Network

/// Offers this app's reports to the Mac's hub. The hub leaves its address in the app's folder
/// over Xcode's device link; when the app has reports, it says so over Wi-Fi, and the hub
/// copies them over the device link. iOS asks once per app for local network access, the
/// first time a report is sent.
enum HubLink {
    /// What the hub leaves in the app's folder.
    struct Address: Codable, Equatable, Sendable {
        /// This phone's UDID, which an app can't find out on its own.
        var device: String
        var hosts: [String]
        var port: UInt16
    }

    /// The app's offer: the reports the Mac hasn't confirmed yet.
    struct Offer: Codable, Equatable, Sendable {
        struct Report: Codable, Equatable, Sendable {
            var id: String
            var finishedAt: Date
        }

        var device: String
        var bundleID: String
        var reports: [Report]
    }

    /// The hub's answer.
    struct Reply: Codable, Equatable, Sendable {
        /// Reports the Mac has, now or from before, so the app can stop offering them.
        var delivered: [String]
    }

    /// One line of JSON.
    static func encode<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return ((try? encoder.encode(value)) ?? Data()) + Data("\n".utf8)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    /// Offers reports to the hub and waits for its answer: nil when it can't be reached within
    /// `patience` at any of its addresses.
    static func send(_ offer: Offer, to address: Address, patience: TimeInterval) async -> Reply? {
        for host in address.hosts {
            guard let port = NWEndpoint.Port(rawValue: address.port) else { return nil }
            if let reply = await Attempt(host: host, port: port, offer: offer).run(patience: patience) {
                return reply
            }
        }
        return nil
    }

    /// One connection to one of the hub's addresses.
    private final class Attempt: @unchecked Sendable {
        private let connection: NWConnection
        private let offer: Offer
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Reply?, Never>?
        private var received = Data()

        init(host: String, port: NWEndpoint.Port, offer: Offer) {
            connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
            self.offer = offer
        }

        func run(patience: TimeInterval) async -> Reply? {
            await withCheckedContinuation { continuation in
                lock.withLock { self.continuation = continuation }
                let queue = DispatchQueue(label: "hub-link")
                connection.stateUpdateHandler = { [self] state in
                    switch state {
                    case .ready:
                        connection.send(content: HubLink.encode(offer), completion: .contentProcessed { _ in })
                        receive()
                    case .failed, .cancelled:
                        finish(nil)
                    default:
                        // `.waiting` while iOS asks about local network access, or with no route:
                        // keep waiting until `patience` runs out.
                        break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + patience) { [self] in finish(nil) }
            }
        }

        private func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, isComplete, error in
                if let data { received.append(data) }
                if let newline = received.firstIndex(of: UInt8(ascii: "\n")) {
                    finish(HubLink.decode(Reply.self, from: received[..<newline]))
                } else if isComplete || error != nil || received.count > 1_000_000 {
                    finish(nil)
                } else {
                    receive()
                }
            }
        }

        private func finish(_ reply: Reply?) {
            let continuation = lock.withLock {
                defer { self.continuation = nil }
                return self.continuation
            }
            guard let continuation else { return }
            connection.cancel()
            continuation.resume(returning: reply)
        }
    }
}
#endif
