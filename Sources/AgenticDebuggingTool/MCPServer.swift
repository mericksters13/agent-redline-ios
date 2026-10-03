#if os(macOS)
import Foundation

/// The MCP server one agent chat runs: JSON-RPC over standard input and output, one message
/// per line. It registers the chat with the hub and hands over the reports for its project.
final class MCPServer: @unchecked Sendable {
    let session: ChatSession
    private let output = NSLock()
    private let lock = NSLock()
    private var waiters: [String: ChatSession.Waiter] = [:]
    private let work = DispatchQueue(label: "mcp", attributes: .concurrent)
    private let inFlight = DispatchGroup()

    /// The most picture bytes in one reply. Agent apps cap a tool result's size; Claude's
    /// desktop app refuses results over 1 MB, and pictures grow by a third when encoded.
    static let budget = 700_000
    static let defaultWait: TimeInterval = 50
    static let longestWait: TimeInterval = 600

    static let instructions = """
    Delivers UI reports the user sends from their iPhone or a simulator with iOSAgenticDebuggingKit, for the app this project builds. \
    A report has numbered notes about elements on screen, and screenshots where each note's element is outlined in red with the same number. \
    Call check_messages when the user mentions a report, notes or screenshots from their phone, or asks you to check. \
    Find the code for a note by the element's identifier or label, and its parents.
    """

    /// A parsed request, handed to the queue that answers it.
    private struct Request: @unchecked Sendable {
        let message: [String: Any]
    }

    init(session: ChatSession) {
        self.session = session
    }

    /// Reads requests until the chat closes its end, then unregisters the chat.
    func run() {
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            guard message["id"] != nil else {
                notice(message)
                continue
            }
            let request = Request(message: message)
            work.async(group: inFlight) {
                if let response = self.respond(to: request.message) { self.send(response) }
            }
        }
        // The chat closed its end: stop any waits, answer what's in flight, then go.
        lock.withLock { waiters.values }.forEach { $0.cancel() }
        inFlight.wait()
        session.unregister()
    }

    /// The response to one request.
    func respond(to message: [String: Any]) -> [String: Any]? {
        let id = message["id"] ?? NSNull()
        let params = message["params"] as? [String: Any] ?? [:]
        switch message["method"] as? String {
        case "initialize":
            let client = (params["clientInfo"] as? [String: Any])?["name"] as? String
            session.register(agent: client ?? "unknown")
            return result(id, [
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "agentic-debugging", "version": "0.1.0"],
                "instructions": Self.instructions,
            ])
        case "ping":
            return result(id, [String: Any]())
        case "tools/list":
            return result(id, ["tools": Self.tools])
        case "tools/call":
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            switch params["name"] as? String {
            case "check_messages":
                return result(id, check())
            case "wait_for_message":
                let seconds = (arguments["timeout_seconds"] as? NSNumber)?.doubleValue ?? Self.defaultWait
                return result(id, wait(seconds: min(max(seconds, 1), Self.longestWait), request: "\(id)"))
            default:
                return error(id, code: -32602, message: "Unknown tool")
            }
        default:
            return error(id, code: -32601, message: "Method not found")
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

    func check() -> [String: Any] {
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

    func wait(seconds: TimeInterval, request: String) -> [String: Any] {
        session.touch()
        let waiter = ChatSession.Waiter()
        lock.withLock { waiters[request] = waiter }
        defer { _ = lock.withLock { waiters.removeValue(forKey: request) } }
        guard session.waitForReport(timeout: seconds, waiter: waiter) else {
            return text("No report arrived in \(Int(seconds)) seconds.")
        }
        return check()
    }

    // MARK: - Messages

    /// A notification from the chat. A cancelled request stops its wait.
    private func notice(_ message: [String: Any]) {
        guard message["method"] as? String == "notifications/cancelled",
              let request = (message["params"] as? [String: Any])?["requestId"]
        else { return }
        lock.withLock { waiters["\(request)"] }?.cancel()
    }

    private func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
        output.withLock {
            FileHandle.standardOutput.write(data + Data("\n".utf8))
        }
    }

    private func result(_ id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func error(_ id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private func text(_ string: String) -> [String: Any] {
        ["content": [["type": "text", "text": string]]]
    }

    static func encode(_ item: ReportContent.Item) -> [String: Any] {
        switch item {
        case .text(let string):
            ["type": "text", "text": string]
        case .image(let file, let data):
            ["type": "image", "data": data.base64EncodedString(), "mimeType": file.pathExtension == "png" ? "image/png" : "image/jpeg"]
        }
    }
}
#endif
