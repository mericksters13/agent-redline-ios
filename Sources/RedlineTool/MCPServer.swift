#if os(macOS)
import Foundation
import Synchronization

/// The MCP server one agent chat runs: JSON-RPC over standard input and output, one message
/// per line. It registers the chat with the hub and hands over the reports for its project.
final class MCPServer: Sendable {
    let session: ChatSession
    /// Writes one response line; standard output unless a test passes its own.
    private let write: @Sendable (Data) -> Void
    /// Waits in progress, by request ID, so a cancel notification can stop one.
    private let waiters = Mutex<[String: ChatSession.Waiter]>([:])
    /// Answers every request except waits, one at a time, in order.
    private let work = DispatchQueue(label: "Redline.mcp", qos: .userInitiated)
    /// Keeps responses whole when a wait's thread and `work` answer at the same time.
    private let outputQueue = DispatchQueue(label: "Redline.mcp.output")
    private let inFlight = DispatchGroup()

    /// The most picture bytes in one reply. Agent apps cap a tool result's size; Claude's
    /// desktop app refuses results over 1 MB, and pictures grow by a third when encoded.
    static let budget = 700_000
    static let defaultWait: TimeInterval = 50
    static let longestWait: TimeInterval = 600

    static let instructions = """
    Delivers UI reports the user sends from their iPhone or a simulator with Redline, for the app this project builds. \
    A report has numbered notes about elements on screen, and screenshots where each note's element is outlined in red with the same number. \
    Call check_messages when the user mentions a report, notes or screenshots from their phone, or asks you to check. \
    Find the code for a note by the element's identifier or label, and its parents.
    """

    /// A parsed request, handed to the queue or thread that answers it. JSONSerialization's
    /// dictionary isn't Sendable, but each request is read by one thread at a time.
    private struct Request: @unchecked Sendable {
        let message: [String: Any]
    }

    init(session: ChatSession, write: @escaping @Sendable (Data) -> Void = { try? FileHandle.standardOutput.write(contentsOf: $0) }) {
        self.session = session
        self.write = write
    }

    // MARK: - Requests

    /// Reads requests until the chat closes its end, then unregisters the chat.
    func run() {
        while let line = readLine(strippingNewline: true) {
            receive(line)
        }
        finish()
    }

    /// Takes one line from the chat. A wait gets a thread of its own, so it never holds up other
    /// requests; everything else is answered on `work`, in order.
    func receive(_ line: String) {
        guard let data = line.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        guard let id = message["id"] else {
            notice(message)
            return
        }
        let request = Request(message: message)
        if Self.isWait(message) {
            // Registered here, on the reading thread, so a cancel read right after it finds it.
            let waiter = ChatSession.Waiter()
            let key = Self.key(id)
            waiters.withLock { $0[key] = waiter }
            inFlight.enter()
            Thread {
                defer { self.inFlight.leave() }
                defer { _ = self.waiters.withLock { $0.removeValue(forKey: key) } }
                self.send(self.respond(to: request.message, waiter: waiter))
            }.start()
            return
        }
        work.async(group: inFlight) {
            self.send(self.respond(to: request.message))
        }
    }

    /// The chat closed its end: stops any waits, answers what's in flight, then unregisters.
    func finish() {
        for waiter in waiters.withLock({ Array($0.values) }) {
            waiter.cancel()
        }
        inFlight.wait()
        session.unregister()
    }

    private static func isWait(_ message: [String: Any]) -> Bool {
        message["method"] as? String == "tools/call" && (message["params"] as? [String: Any])?["name"] as? String == "wait_for_message"
    }

    /// A request ID as a key: a number and a string that read the same stay apart.
    private static func key(_ id: Any) -> String {
        id is String ? "s:\(id)" : "n:\(id)"
    }

    /// The response to one request. `waiter` stops a wait early; the server passes the one it
    /// registered for the request.
    func respond(to message: [String: Any], waiter: ChatSession.Waiter = ChatSession.Waiter()) -> [String: Any] {
        let id = message["id"] ?? NSNull()
        let params = message["params"] as? [String: Any] ?? [:]
        switch message["method"] as? String {
        case "initialize":
            let client = (params["clientInfo"] as? [String: Any])?["name"] as? String
            session.register(agent: client ?? "unknown")
            return response(id: id, result: [
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "redline", "version": version],
                "instructions": Self.instructions,
            ])
        case "ping":
            return response(id: id, result: [String: Any]())
        case "tools/list":
            return response(id: id, result: ["tools": Self.tools])
        case "tools/call":
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            switch params["name"] as? String {
            case "check_messages":
                return response(id: id, result: takeReports())
            case "wait_for_message":
                let seconds = (arguments["timeout_seconds"] as? NSNumber)?.doubleValue ?? Self.defaultWait
                return response(id: id, result: wait(seconds: min(max(seconds, 1), Self.longestWait), waiter: waiter))
            default:
                return errorResponse(id: id, code: -32602, message: "Unknown tool")
            }
        default:
            return errorResponse(id: id, code: -32601, message: "Method not found")
        }
    }

    // MARK: - Tools

    static var tools: [[String: Any]] { [
        [
            "name": "check_messages",
            "description": """
            Returns the UI reports waiting for the app this project builds, sent from the user's iPhone or a simulator, \
            and marks them as taken by this chat. Each has numbered notes and screenshots with matching numbered outlines. \
            Call it when the user mentions a report or notes from their phone, or asks you to check.
            """,
            "inputSchema": ["type": "object", "properties": [String: Any]()],
        ],
        [
            "name": "wait_for_message",
            "description": """
            Waits for the next UI report for this project and returns it, for when the user is about to send one. \
            Returns after timeout_seconds with no report if none arrived; that isn't an error.
            """,
            "inputSchema": [
                "type": "object",
                "properties": ["timeout_seconds": ["type": "number", "description": "How long to wait, 1 to 600 seconds. Default 50."]],
            ],
        ],
    ] }

    private func takeReports() -> [String: Any] {
        session.touch()
        let chat = session.chat
        guard !chat.bundleIDs.isEmpty else {
            return text("""
            No app found for this project: no PRODUCT_BUNDLE_IDENTIFIER in an Xcode project or project.yml under \(chat.folder). \
            Add `--app <bundle ID>` to this MCP server's arguments.
            """)
        }
        let taken = session.take(budget: Self.budget)
        guard taken.taken > 0 else {
            return text("No reports waiting for \(chat.bundleIDs.joined(separator: ", ")).")
        }
        var content = taken.items.map(Self.encode)
        if taken.remaining > 0 {
            content.append(["type": "text", "text": "\(taken.remaining) more \(taken.remaining == 1 ? "report is" : "reports are") waiting. Call check_messages again."])
        }
        return ["content": content]
    }

    /// Runs on a thread of its own, started for this request.
    private func wait(seconds: TimeInterval, waiter: ChatSession.Waiter) -> [String: Any] {
        session.touch()
        guard session.waitForReport(timeout: seconds, waiter: waiter) else {
            return text("No report arrived in \(Int(seconds)) seconds.")
        }
        return takeReports()
    }

    // MARK: - Messages

    /// A notification from the chat. A cancelled request stops its wait.
    private func notice(_ message: [String: Any]) {
        guard message["method"] as? String == "notifications/cancelled",
              let request = (message["params"] as? [String: Any])?["requestId"]
        else { return }
        waiters.withLock { $0[Self.key(request)] }?.cancel()
    }

    private func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
        outputQueue.sync { write(data + Data("\n".utf8)) }
    }

    private func response(id: Any, result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func errorResponse(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private func text(_ string: String) -> [String: Any] {
        ["content": [["type": "text", "text": string]]]
    }

    private static func encode(_ item: ReportContent.Item) -> [String: Any] {
        switch item {
        case .text(let string):
            ["type": "text", "text": string]
        case .image(let file, let data):
            ["type": "image", "data": data.base64EncodedString(), "mimeType": file.pathExtension == "png" ? "image/png" : "image/jpeg"]
        }
    }
}
#endif
