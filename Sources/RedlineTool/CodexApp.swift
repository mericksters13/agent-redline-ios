#if os(macOS)
import Darwin
import Foundation

/// Starts a turn in a chat open in the Codex app, with the report's pictures attached the way the
/// app attaches a screenshot the user adds.
///
/// It goes through the app's own socket, so the app runs the turn: the chat wakes even when idle
/// and shows it live. The socket's protocol is the app's own, not a published one, so an update to
/// the app can change it.
enum CodexApp {
    static let socketPath = URL.homeDirectory.appending(path: ".codex/ipc/ipc.sock").path

    /// How starting a turn went.
    enum Outcome: Equatable {
        case started
        /// No Codex window has the chat open.
        case notOpen
        case failed(String)
    }

    /// The input the app takes for a turn: the text, then each picture by path.
    static func input(text: String, pictures: [URL]) -> [[String: Any]] {
        [["type": "text", "text": text, "text_elements": [Any]()]]
            + pictures.map { ["type": "localImage", "path": $0.path] }
    }

    /// Starts the turn, giving up once `timeout` seconds have passed in all, however much else
    /// the app sends meanwhile.
    static func startTurn(
        thread: String,
        text: String,
        pictures: [URL],
        socketPath: String = socketPath,
        timeout: TimeInterval = 30
    ) -> Outcome {
        let deadline = ContinuousClock.now + .milliseconds(Int(timeout * 1000))
        guard let connection = Connection(path: socketPath, deadline: deadline) else {
            return .failed("The Codex app isn't running")
        }
        let hello = UUID().uuidString
        guard
            connection.send([
                "type": "request", "requestId": hello, "method": "initialize", "params": ["clientType": "redline"],
            ]),
            let reply = connection.response(to: hello),
            let client = (reply["result"] as? [String: Any])?["clientId"] as? String
        else { return .failed("The Codex app didn't answer") }

        let turn = UUID().uuidString
        let request: [String: Any] = [
            "type": "request", "requestId": turn, "sourceClientId": client, "version": 2,
            "timeoutMs": Int(timeout * 1000),
            "method": "thread-follower-start-turn",
            "params": [
                "conversationId": thread,
                "turnStart": [
                    "request": ["threadId": thread, "input": input(text: text, pictures: pictures)],
                    "context": [String: Any](),
                ],
            ],
        ]
        guard connection.send(request), let answer = connection.response(to: turn) else {
            return .failed("The Codex app didn't answer")
        }
        if answer["resultType"] as? String == "success" { return .started }
        let error = answer["error"] as? String ?? "unknown error"
        return error.contains("no-client-found") ? .notOpen : .failed(error)
    }

    /// One length-prefixed JSON message: a 4-byte little-endian length, then the JSON.
    static func frame(_ message: [String: Any]) -> Data? {
        guard let json = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else {
            return nil
        }
        var length = UInt32(json.count).littleEndian
        return Data(bytes: &length, count: 4) + json
    }

    /// A message longer than this is taken as a broken connection rather than read.
    static let longestMessage = 8_000_000

    private final class Connection {
        private let descriptor: Int32
        private let deadline: ContinuousClock.Instant
        private var buffer = Data()
        private var chunk = [UInt8](repeating: 0, count: 65_536)

        init?(path: String, deadline: ContinuousClock.Instant) {
            guard let descriptor = UnixSocket.connect(path: path) else { return nil }
            self.descriptor = descriptor
            self.deadline = deadline
        }

        deinit {
            close(descriptor)
        }

        /// Sets the socket's timeout for one read or write to the time left; false once it's up.
        private func limit(_ option: Int32) -> Bool {
            let left = deadline - ContinuousClock.now
            guard left > .zero else { return false }
            let microseconds = max(
                left.components.seconds * 1_000_000 + left.components.attoseconds / 1_000_000_000_000,
                1
            )
            var wait = timeval(tv_sec: Int(microseconds / 1_000_000), tv_usec: Int32(microseconds % 1_000_000))
            return setsockopt(descriptor, SOL_SOCKET, option, &wait, socklen_t(MemoryLayout<timeval>.size)) == 0
        }

        /// Writes the whole frame: a write can take only part of it, or be interrupted.
        func send(_ message: [String: Any]) -> Bool {
            guard let data = CodexApp.frame(message), limit(SO_SNDTIMEO) else { return false }
            return data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return bytes.isEmpty }
                var sent = 0
                while sent < bytes.count {
                    let written = write(descriptor, base + sent, bytes.count - sent)
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else { return false }
                    sent += written
                }
                return true
            }
        }

        /// The response to a request, answering the app's questions to every client on the way.
        func response(to request: String) -> [String: Any]? {
            while let message = next() {
                if message["type"] as? String == "client-discovery-request", let id = message["requestId"] as? String {
                    // This client handles nothing for the app.
                    _ = send(["type": "client-discovery-response", "requestId": id, "response": ["canHandle": false]])
                } else if message["type"] as? String == "response", message["requestId"] as? String == request {
                    return message
                }
            }
            return nil
        }

        private func next() -> [String: Any]? {
            while true {
                if buffer.count >= 4 {
                    let length = Int(
                        buffer.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
                    )
                    guard length <= CodexApp.longestMessage else { return nil }
                    if buffer.count >= 4 + length {
                        let json = buffer.subdata(in: buffer.startIndex + 4..<buffer.startIndex + 4 + length)
                        buffer.removeSubrange(buffer.startIndex..<buffer.startIndex + 4 + length)
                        return try? JSONSerialization.jsonObject(with: json) as? [String: Any]
                    }
                }
                guard limit(SO_RCVTIMEO) else { return nil }
                let count = read(descriptor, &chunk, chunk.count)
                guard count > 0 else { return nil }
                buffer.append(contentsOf: chunk[0..<count])
            }
        }
    }
}
#endif
