#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import AgenticDebuggingTool

struct CodexAppTests {
    /// A stand-in for the Codex app's socket: answers `initialize`, asks the client the
    /// question the app asks every client, then answers the turn with `answer`.
    private func fakeApp(answer: [String: Any]) throws -> (path: String, requests: () -> [[String: Any]]) {
        let path = FileManager.default.temporaryDirectory.appending(path: "cx-\(UUID().uuidString.prefix(8)).sock").path
        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { target in Array(path.utf8CString).withUnsafeBytes { target.copyMemory(from: $0) } }
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        try #require(bound == 0)
        listen(server, 1)
        let lock = NSLock()
        nonisolated(unsafe) var seen: [[String: Any]] = []
        Thread.detachNewThread {
            let client = accept(server, nil, nil)
            defer { close(client); close(server) }
            var buffer = Data()
            func next() -> [String: Any]? {
                while true {
                    if buffer.count >= 4 {
                        let length = Int(buffer.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
                        if buffer.count >= 4 + length {
                            let json = buffer.subdata(in: 4..<(4 + length))
                            buffer.removeSubrange(0..<(4 + length))
                            return try? JSONSerialization.jsonObject(with: json) as? [String: Any]
                        }
                    }
                    var chunk = [UInt8](repeating: 0, count: 65_536)
                    let count = read(client, &chunk, chunk.count)
                    guard count > 0 else { return nil }
                    buffer.append(contentsOf: chunk[0..<count])
                }
            }
            func send(_ message: [String: Any]) {
                let data = CodexApp.frame(message)!
                _ = data.withUnsafeBytes { write(client, $0.baseAddress, data.count) }
            }
            while let message = next() {
                lock.withLock { seen.append(message) }
                let id = message["requestId"] as? String ?? ""
                switch message["method"] as? String {
                case "initialize":
                    send(["type": "response", "requestId": id, "resultType": "success", "method": "initialize", "result": ["clientId": "hub-1"]])
                case "thread-follower-start-turn":
                    send(["type": "client-discovery-request", "requestId": "q-1", "request": ["method": "something"]])
                    send(["type": "broadcast", "method": "thread-stream-state-changed"])
                    send(answer.merging(["type": "response", "requestId": id]) { $1 })
                default:
                    break
                }
            }
        }
        return (path, { lock.withLock { seen } })
    }

    @Test func aTurnGoesToTheChatWithItsPictures() throws {
        let app = try fakeApp(answer: ["resultType": "success", "result": ["result": ["turn": ["status": "inProgress"]]]])
        let picture = URL(fileURLWithPath: "/tmp/screen-1.jpg")
        #expect(CodexApp.startTurn(thread: "t-1", text: "A report", pictures: [picture], socketPath: app.path, timeout: 5) == .started)
        let requests = app.requests()
        let turn = try #require(requests.first { $0["method"] as? String == "thread-follower-start-turn" })
        #expect(turn["sourceClientId"] as? String == "hub-1")
        #expect(turn["version"] as? Int == 2)
        let request = ((turn["params"] as? [String: Any])?["turnStart"] as? [String: Any])?["request"] as? [String: Any]
        #expect(request?["threadId"] as? String == "t-1")
        let input = request?["input"] as? [[String: Any]]
        #expect(input?.first?["text"] as? String == "A report")
        #expect(input?.last?["type"] as? String == "localImage")
        #expect(input?.last?["path"] as? String == picture.path)
        // The app's question to every client was answered: this client handles nothing.
        #expect(requests.contains { $0["type"] as? String == "client-discovery-response" && ($0["response"] as? [String: Any])?["canHandle"] as? Bool == false })
    }

    @Test func aChatNoWindowHasOpenIsReported() throws {
        let app = try fakeApp(answer: ["resultType": "error", "error": "no-client-found: no client can handle the request"])
        #expect(CodexApp.startTurn(thread: "t-1", text: "A report", pictures: [], socketPath: app.path, timeout: 5) == .notOpen)
        #expect(CodexApp.startTurn(thread: "t-1", text: "A report", pictures: [], socketPath: "/tmp/no-such-\(UUID().uuidString.prefix(6)).sock", timeout: 1)
            == .failed("The Codex app isn't running"))
    }
}
#endif
