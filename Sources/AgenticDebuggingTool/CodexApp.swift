#if os(macOS)
import Darwin
import Foundation

/// Starts a turn in a chat open in the Codex app, with the report's pictures attached the way
/// the app attaches a screenshot the user adds. It goes through the app's own socket, so the
/// app runs the turn: the chat wakes even when idle and shows it live. The socket's protocol
/// is the app's own, not a published one, so an update to the app can change it.
enum CodexApp {
    static var socketPath: String { NSHomeDirectory() + "/.codex/ipc/ipc.sock" }

    enum Outcome: Equatable {
        case started
        /// No Codex window has the chat open.
        case notOpen
        case failed(String)
    }

    /// The input the app takes for a turn: the text, then each picture by path.
    static func input(text: String, pictures: [URL]) -> [[String: Any]] {
        [["type": "text", "text": text, "text_elements": [Any]()]] + pictures.map { ["type": "localImage", "path": $0.path] }
    }

    static func startTurn(thread: String, text: String, pictures: [URL], socketPath: String = socketPath, timeout: TimeInterval = 30) -> Outcome {
        guard let connection = Connection(path: socketPath, timeout: timeout) else { return .failed("The Codex app isn't running") }
        let hello = UUID().uuidString
        guard connection.send(["type": "request", "requestId": hello, "method": "initialize", "params": ["clientType": "agentic-debugging"]]),
              let reply = connection.response(to: hello),
              let client = (reply["result"] as? [String: Any])?["clientId"] as? String
        else { return .failed("The Codex app didn't answer") }

        let turn = UUID().uuidString
        let request: [String: Any] = [
            "type": "request", "requestId": turn, "sourceClientId": client, "version": 2, "timeoutMs": Int(timeout * 1000),
            "method": "thread-follower-start-turn",
            "params": ["conversationId": thread,
                       "turnStart": ["request": ["threadId": thread, "input": input(text: text, pictures: pictures)], "context": [String: Any]()]],
        ]
        guard connection.send(request), let answer = connection.response(to: turn) else { return .failed("The Codex app didn't answer") }
        if answer["resultType"] as? String == "success" { return .started }
        let error = answer["error"] as? String ?? "unknown error"
        return error.contains("no-client-found") ? .notOpen : .failed(error)
    }

    /// One length-prefixed JSON message: a 4-byte little-endian length, then the JSON.
    static func frame(_ message: [String: Any]) -> Data? {
        guard let json = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return nil }
        var length = UInt32(json.count).littleEndian
        return Data(bytes: &length, count: 4) + json
    }

    private final class Connection {
        private let descriptor: Int32
        private var buffer = Data()

        init?(path: String, timeout: TimeInterval) {
            let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { return nil }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8CString)
            guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
                close(descriptor)
                return nil
            }
            withUnsafeMutableBytes(of: &address.sun_path) { target in bytes.withUnsafeBytes { target.copyMemory(from: $0) } }
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard connected == 0 else {
                close(descriptor)
                return nil
            }
            var wait = timeval(tv_sec: Int(timeout), tv_usec: 0)
            setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
            self.descriptor = descriptor
        }

        deinit {
            close(descriptor)
        }

        func send(_ message: [String: Any]) -> Bool {
            guard let data = CodexApp.frame(message) else { return false }
            return data.withUnsafeBytes { write(descriptor, $0.baseAddress, data.count) } == data.count
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
                    let length = Int(buffer.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
                    if buffer.count >= 4 + length {
                        let json = buffer.subdata(in: buffer.startIndex + 4..<buffer.startIndex + 4 + length)
                        buffer.removeSubrange(buffer.startIndex..<buffer.startIndex + 4 + length)
                        return try? JSONSerialization.jsonObject(with: json) as? [String: Any]
                    }
                }
                var chunk = [UInt8](repeating: 0, count: 65_536)
                let count = read(descriptor, &chunk, chunk.count)
                guard count > 0 else { return nil }
                buffer.append(contentsOf: chunk[0..<count])
            }
        }
    }
}
#endif
