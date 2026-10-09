#if os(macOS)
import Darwin
import Foundation
import Synchronization
import Testing
@testable import RedlineTool

struct CodexAppTests {
    /// A stand-in for the Codex app: its socket, what the client sent it, a signal when the
    /// client answers the app's question to every client, and one when the client hangs up.
    private final class FakeApp: Sendable {
        let path: String
        let seen = Mutex<[Data]>([])
        let answered = DispatchSemaphore(value: 0)
        let closed = DispatchSemaphore(value: 0)

        init(path: String) {
            self.path = path
        }

        var requests: [[String: Any]] {
            seen.withLock { $0 }.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
    }

    /// A socket file of its own in the temporary folder, bound, and listening unless `isListening`
    /// is false.
    private func boundSocket(isListening: Bool = true) throws -> (server: Int32, path: String) {
        let path = FileManager.default.temporaryDirectory.appending(path: "cx-\(UUID().uuidString.prefix(8)).sock").path
        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            Array(path.utf8CString).withUnsafeBytes { target.copyMemory(from: $0) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(bound == 0)
        if isListening { listen(server, 1) }
        return (server, path)
    }

    /// Answers `initialize` with `hello`, or never when it is nil, asks the client the question
    /// the app asks every client, then answers the turn with `answer`.
    private func fakeApp(
        answer: [String: Any] = [:],
        hello: [String: Any]? = ["resultType": "success", "result": ["clientId": "hub-1"]]
    ) throws -> FakeApp {
        let (server, path) = try boundSocket()
        let app = FakeApp(path: path)
        // Handed to the app's thread as data, which is Sendable.
        let answerData = try JSONSerialization.data(withJSONObject: answer)
        let helloData = try hello.map { try JSONSerialization.data(withJSONObject: $0) }
        Thread.detachNewThread {
            let client = accept(server, nil, nil)
            // Connected: the socket's file isn't needed any more.
            unlink(path)
            defer {
                close(client)
                close(server)
                app.closed.signal()
            }
            let answer = (try? JSONSerialization.jsonObject(with: answerData) as? [String: Any]) ?? [:]
            let hello = helloData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            var buffer = Data()
            func next() -> Data? {
                while true {
                    if buffer.count >= 4 {
                        let length = Int(buffer.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
                        if buffer.count >= 4 + length {
                            let json = buffer.subdata(in: 4..<(4 + length))
                            buffer.removeSubrange(0..<(4 + length))
                            return json
                        }
                    }
                    var chunk = [UInt8](repeating: 0, count: 65_536)
                    let count = read(client, &chunk, chunk.count)
                    guard count > 0 else { return nil }
                    buffer.append(contentsOf: chunk[0..<count])
                }
            }
            func send(_ message: [String: Any]) {
                guard let data = CodexApp.frame(message) else { return }
                _ = data.withUnsafeBytes { write(client, $0.baseAddress, data.count) }
            }
            while let json = next() {
                app.seen.withLock { $0.append(json) }
                guard let message = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { continue }
                if message["type"] as? String == "client-discovery-response" { app.answered.signal() }
                let id = message["requestId"] as? String ?? ""
                switch message["method"] as? String {
                case "initialize":
                    if let hello {
                        send(hello.merging(["type": "response", "requestId": id, "method": "initialize"]) { $1 })
                    }
                case "thread-follower-start-turn":
                    send(["type": "client-discovery-request", "requestId": "q-1", "request": ["method": "something"]])
                    send(["type": "broadcast", "method": "thread-stream-state-changed"])
                    send(answer.merging(["type": "response", "requestId": id]) { $1 })
                default:
                    break
                }
            }
        }
        return app
    }

    @Test func aTurnGoesToTheChatWithItsSnapshots() async throws {
        let app = try fakeApp(answer: [
            "resultType": "success", "result": ["result": ["turn": ["status": "inProgress"]]],
        ])
        let snapshot = URL(filePath: "/tmp/screen-1.jpg")
        #expect(
            await offPool {
                CodexApp.startTurn(
                    thread: "t-1",
                    text: "A report",
                    snapshots: [snapshot],
                    socketPath: app.path,
                    timeout: 5
                )
            } == .started
        )
        // The app's question to every client was answered. The stand-in reads the answer on its
        // own thread, so wait for it.
        #expect(await offPool { app.answered.wait(timeout: .now() + 5) == .success })
        let requests = app.requests
        let turn = try #require(requests.first { $0["method"] as? String == "thread-follower-start-turn" })
        #expect(turn["sourceClientId"] as? String == "hub-1")
        #expect(turn["version"] as? Int == 2)
        let request = ((turn["params"] as? [String: Any])?["turnStart"] as? [String: Any])?["request"] as? [String: Any]
        #expect(request?["threadId"] as? String == "t-1")
        let input = request?["input"] as? [[String: Any]]
        #expect(input?.first?["text"] as? String == "A report")
        #expect(input?.last?["type"] as? String == "localImage")
        #expect(input?.last?["path"] as? String == snapshot.path)
        // This client handles nothing for the app.
        #expect(
            requests.contains {
                $0["type"] as? String == "client-discovery-response"
                    && ($0["response"] as? [String: Any])?["canHandle"] as? Bool == false
            }
        )
    }

    @Test func anAppThatKeepsTalkingButNeverAnswersIsGivenUpOnInTime() async throws {
        let (server, path) = try boundSocket()
        // Asks the client a question every 0.2 seconds, and never answers it.
        Thread.detachNewThread {
            let client = accept(server, nil, nil)
            unlink(path)
            defer {
                close(client)
                close(server)
            }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            for _ in 0..<50 {
                guard
                    let data = CodexApp.frame([
                        "type": "client-discovery-request", "requestId": "q", "request": [String: Any](),
                    ]),
                    data.withUnsafeBytes({ write(client, $0.baseAddress, data.count) }) == data.count
                else { return }
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
        let started = Date.now
        #expect(
            await offPool {
                CodexApp.startTurn(thread: "t-1", text: "A report", snapshots: [], socketPath: path, timeout: 1)
            } == .failed("The Codex app didn't answer")
        )
        // Gives up near the 1 s timeout, not the 30 s default; the margin covers a busy CI machine.
        #expect(Date.now.timeIntervalSince(started) < 5)
    }

    @Test func aChatNoWindowHasOpenIsReported() async throws {
        let app = try fakeApp(answer: [
            "resultType": "error", "error": "no-client-found: no client can handle the request",
        ])
        #expect(
            await offPool {
                CodexApp.startTurn(thread: "t-1", text: "A report", snapshots: [], socketPath: app.path, timeout: 5)
            } == .notOpen
        )
        #expect(
            CodexApp.startTurn(
                thread: "t-1",
                text: "A report",
                snapshots: [],
                socketPath: "/tmp/no-such-\(UUID().uuidString.prefix(6)).sock",
                timeout: 1
            )
                == .notRunning
        )
    }

    // MARK: - Handshake

    @Test func theCheckStopsAfterTheHandshakeWithAnAppThatAnswers() async throws {
        let app = try fakeApp()
        #expect(await offPool { CodexApp.checkHandshake(socketPath: app.path, timeout: 5) } == .answered)
        // Once the check hangs up, everything it sent has been read: only the handshake, no turn.
        #expect(await offPool { app.closed.wait(timeout: .now() + 5) == .success })
        #expect(app.requests.map { $0["method"] as? String } == ["initialize"])
    }

    @Test func theCheckSaysWhenNothingListens() throws {
        // No socket at all.
        #expect(
            CodexApp.checkHandshake(socketPath: "/tmp/no-such-\(UUID().uuidString.prefix(6)).sock", timeout: 1)
                == .notListening
        )
        // A socket left behind by an app that quit: nothing takes the connection.
        let (server, path) = try boundSocket(isListening: false)
        close(server)
        defer { unlink(path) }
        #expect(CodexApp.checkHandshake(socketPath: path, timeout: 1) == .notListening)
    }

    @Test func anAppThatTakesTheConnectionButNeverAnswersIsNotAnswering() async throws {
        let app = try fakeApp(hello: nil)
        let started = Date.now
        #expect(await offPool { CodexApp.checkHandshake(socketPath: app.path, timeout: 1) } == .notAnswering)
        // Gives up near the 1 s timeout, not the 30 s default; the margin covers a busy CI machine.
        #expect(Date.now.timeIntervalSince(started) < 5)
    }

    @Test func anAppThatAnswersWithoutAClientIsNotAnswering() async throws {
        let app = try fakeApp(hello: ["resultType": "error", "error": "unknown method"])
        #expect(await offPool { CodexApp.checkHandshake(socketPath: app.path, timeout: 5) } == .notAnswering)
    }
}
#endif
