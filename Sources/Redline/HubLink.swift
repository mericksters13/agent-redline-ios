#if REDLINE
import Foundation
import Network

/// Sends this app's reports to the Mac's hub over the local network.
///
/// The hub leaves its address and a token in the app's folder over Xcode's device link, once; the
/// token shows the hub that the reports come from a phone paired with that Mac. iOS asks once per
/// app for local network access, the first time a report is sent.
///
/// One connection, one line of JSON per message:
/// 1. The app offers the reports the Mac hasn't confirmed (`Offer`).
/// 2. The hub answers which it wants and which it already has (`Answer`).
/// 3. The app sends each wanted report's files (`Upload`).
/// 4. The hub confirms what it now has (`Reply`).
enum HubLink {
    /// What the hub leaves in the app's folder.
    struct Address: Codable, Equatable, Sendable {
        /// This phone's UDID, which an app can't find out on its own.
        var device: String
        var hosts: [String]
        var port: UInt16
        /// Proves to the hub that an offer comes from this phone and app.
        ///
        /// Missing from addresses left by an older hub, which the hub turns down until it leaves a
        /// new one.
        var token: String?
        /// False in a simulator, where the hub takes reports from the app's folder: the app only
        /// asks which chats a report can go to.
        var uploads: Bool? = nil

        /// Whether the app sends the hub its reports' files.
        ///
        /// Older hubs leave `uploads` out; they always took uploads.
        var acceptsUploads: Bool { uploads ?? true }
    }

    /// A report the Mac hasn't confirmed, named by its folder.
    struct OfferedReport: Codable, Equatable, Sendable {
        var id: String
        var finishedAt: Date
    }

    /// Step 1: the reports the phone offers the hub, oldest first.
    struct Offer: Codable, Equatable, Sendable {
        var device: String
        var bundleID: String
        var token: String
        var reports: [OfferedReport]
    }

    /// Step 2: which offered reports the hub wants, and which it already has.
    struct Answer: Codable, Equatable, Sendable {
        /// Reports to send now.
        var wanted: [String]
        /// Reports the Mac already has, or doesn't take: the app can stop offering them.
        var delivered: [String]
        /// Why the hub turned the offer down, when it did.
        var refused: String?

        private enum CodingKeys: String, CodingKey {
            case wanted = "want"
            case delivered, refused
        }
    }

    /// Step 3: one wanted report's files.
    struct Upload: Codable, Equatable, Sendable {
        var id: String
        /// File name to contents.
        ///
        /// Encoded as base64 in the line.
        var files: [String: Data]
    }

    /// Step 4: the reports the hub now has.
    struct Reply: Codable, Equatable, Sendable {
        var delivered: [String]
    }

    /// Before the user sends, the app asks which chats a report can go to.
    struct ChatsRequest: Codable, Equatable, Sendable {
        /// Always "chats": tells this request from an offer.
        var kind = "chats"
        var device: String
        var bundleID: String
        var token: String
        var sourceFile: String?
    }

    /// An open chat a report can go to.
    struct Chat: Codable, Equatable, Sendable, Identifiable {
        var id: String
        /// `claude`, `codex` or `cursor`.
        var agent: String
        var title: String
        /// The last part of the chat's folder.
        var folder: String
        /// The chat works in the worktree the app was built from.
        var isSameWorktree: Bool
        var lastActive: Date

        private enum CodingKeys: String, CodingKey {
            case id, agent, title, folder, lastActive
            case isSameWorktree = "sameWorktree"
        }
    }

    /// The hub's answer to a chats request.
    struct ChatList: Codable, Equatable, Sendable {
        /// The agents on the Mac reports can go to, in the order to show them.
        var agents: [String]
        var chats: [Chat]
        /// The last part of the worktree the app was built from.
        var worktree: String?
        /// The branch a new chat's worktree starts from, such as "main".
        var newChatBase: String? = nil
        var refused: String?
    }

    /// The agent's name as the user knows it.
    static func agentName(_ agent: String) -> String {
        switch agent {
        case "claude": "Claude Code"
        case "codex": "Codex"
        case "cursor": "Cursor"
        default: agent
        }
    }

    /// Asks the hub which chats a report from this app can go to.
    ///
    /// Nil when the hub can't be reached or turns the question down.
    static func requestChats(bundleID: String, address: Address, sourceFile: String?, patience: TimeInterval) async
        -> ChatList?
    {
        guard let token = address.token, let port = NWEndpoint.Port(rawValue: address.port) else { return nil }
        let request: Data
        do {
            request = try encode(
                ChatsRequest(device: address.device, bundleID: bundleID, token: token, sourceFile: sourceFile)
            )
        } catch {
            Log.hubLink.error("Couldn't write the chats request: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        for host in address.hosts {
            let line = Line(host: host, port: port)
            // Runs at the end of each pass, `continue` included, so a line that never opened is closed too.
            defer { line.close() }
            guard await line.open(patience: patience) else {
                Log.hubLink.info("Couldn't reach the hub at \(host, privacy: .private)")
                continue
            }
            guard await line.send(request), let data = await line.read() else { return nil }
            do {
                let list = try decode(ChatList.self, from: data)
                if let refused = list.refused {
                    Log.hubLink.notice("The hub turned down the chats request: \(refused, privacy: .public)")
                    return nil
                }
                return list
            } catch {
                Log.hubLink.error("Couldn't read the hub's chat list: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        return nil
    }

    /// How an attempt to deliver went, kept so the phone can say why a report isn't on the Mac.
    enum Outcome: String, Codable, Sendable {
        /// The Mac has every report it was offered.
        case delivered
        /// No hub has set this app up yet.
        case noHub
        /// The hub couldn't be reached at any of its addresses.
        case unreachable
        /// The hub turned the reports down, such as for a token from an older hub.
        case refused
        /// The connection ended before the hub confirmed.
        case interrupted
    }

    /// One line of JSON, ending in a newline.
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        var data = try encoder.encode(value)
        data.append(UInt8(ascii: "\n"))
        return data
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Delivers the reports the Mac hasn't confirmed. `patience` is how long to wait for the
    /// connection, which includes iOS asking about local network access the first time.
    ///
    /// Returns how it went and the reports the Mac now has. Runs off the main actor. Add
    /// @concurrent when the tools version reaches 6.2.
    static func deliver(
        _ reports: [OfferedReport],
        bundleID: String,
        address: Address,
        files: @Sendable (_ reportID: String) -> [String: Data],
        patience: TimeInterval
    ) async -> (outcome: Outcome, delivered: [String]) {
        guard let token = address.token, let port = NWEndpoint.Port(rawValue: address.port) else {
            return (.refused, [])
        }
        let offer: Data
        do {
            offer = try encode(Offer(device: address.device, bundleID: bundleID, token: token, reports: reports))
        } catch {
            Log.hubLink.error("Couldn't write the offer: \(error.localizedDescription, privacy: .public)")
            return (.interrupted, [])
        }
        for host in address.hosts {
            let line = Line(host: host, port: port)
            // Runs at the end of each pass, `continue` included, so a line that never opened is closed too.
            defer { line.close() }
            guard await line.open(patience: patience) else {
                Log.hubLink.info("Couldn't reach the hub at \(host, privacy: .private)")
                continue
            }
            guard await line.send(offer), let answerData = await line.read() else { return (.interrupted, []) }
            let answer: Answer
            do {
                answer = try decode(Answer.self, from: answerData)
            } catch {
                Log.hubLink.error("Couldn't read the hub's answer: \(error.localizedDescription, privacy: .public)")
                return (.interrupted, [])
            }
            if let refused = answer.refused {
                Log.hubLink.notice("The hub turned down the reports: \(refused, privacy: .public)")
                return (.refused, answer.delivered)
            }
            var delivered = answer.delivered
            guard !answer.wanted.isEmpty else { return (.delivered, delivered) }
            for id in answer.wanted {
                let upload: Data
                do {
                    upload = try encode(Upload(id: id, files: files(id)))
                } catch {
                    Log.hubLink.error(
                        "Couldn't write report \(id, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                    return (.interrupted, delivered)
                }
                guard await line.send(upload) else { return (.interrupted, delivered) }
            }
            guard let replyData = await line.read() else { return (.interrupted, delivered) }
            let reply: Reply
            do {
                reply = try decode(Reply.self, from: replyData)
            } catch {
                Log.hubLink.error("Couldn't read the hub's reply: \(error.localizedDescription, privacy: .public)")
                return (.interrupted, delivered)
            }
            delivered += reply.delivered
            let offered = Set(reports.map(\.id))
            return (offered.isSubset(of: Set(delivered)) ? .delivered : .interrupted, delivered)
        }
        return (.unreachable, [])
    }

    /// A connection that sends and reads whole lines.
    ///
    /// Thread safety: `buffer` is read and written only on `queue`. The connection is
    /// Sendable, and everything else is a `let`.
    private final class Line: Sendable {
        /// Every connection's callbacks run on this queue, at background priority.
        private static let network = DispatchQueue(label: "Redline.link", qos: .utility)

        private let connection: NWConnection
        private let queue = DispatchQueue(label: "Redline.link.line", target: Line.network)
        nonisolated(unsafe) private var buffer = Data()

        init(host: String, port: NWEndpoint.Port) {
            connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        }

        /// Waits for the connection. `.waiting` (no route yet, or iOS still asking about local
        /// network access) keeps waiting until `patience` runs out.
        ///
        /// A connection that doesn't open, or whose task is cancelled, is cancelled too.
        func open(patience: TimeInterval) async -> Bool {
            guard !Task.isCancelled else {
                connection.cancel()
                return false
            }
            let once = Once<Bool>()
            let opened = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    once.set(continuation)
                    once.resume(false, after: .seconds(patience))
                    connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            once.resume(true)
                        case .failed, .cancelled:
                            once.resume(false)
                        case .setup, .preparing, .waiting:
                            break  // Keep waiting until patience runs out.
                        @unknown default:
                            break
                        }
                    }
                    connection.start(queue: queue)
                }
            } onCancel: {
                connection.cancel()  // Leads to .cancelled, which resumes once.
            }
            // A connection left waiting keeps retrying until it is cancelled.
            if !opened { connection.cancel() }
            return opened
        }

        /// Sends one line.
        ///
        /// False when it couldn't be sent or the task was cancelled.
        func send(_ data: Data) async -> Bool {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    connection.send(
                        content: data,
                        completion: .contentProcessed { error in
                            continuation.resume(returning: error == nil)
                        }
                    )
                }
            } onCancel: {
                connection.cancel()  // The pending send then completes with an error.
            }
        }

        /// The next line, without its newline; nil when the connection ends first, the task is
        /// cancelled or 30 seconds pass.
        func read() async -> Data? {
            let once = Once<Data?>()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    once.set(continuation)
                    once.resume(nil, after: .seconds(30))
                    queue.async {
                        if let line = self.takeLine() {
                            once.resume(line)
                        } else {
                            self.receive(once)
                        }
                    }
                }
            } onCancel: {
                connection.cancel()  // The pending receive then completes with an error.
            }
        }

        func close() {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }

        private func receive(_ once: Once<Data?>) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) {
                [self] data, _, isComplete, error in
                queue.async {
                    if let data { self.buffer.append(data) }
                    if let line = self.takeLine() {
                        once.resume(line)
                    } else if isComplete || error != nil {
                        once.resume(nil)
                    } else {
                        self.receive(once)
                    }
                }
            }
        }

        private func takeLine() -> Data? {
            dispatchPrecondition(condition: .onQueue(queue))
            guard let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            return Data(line)
        }
    }
}
#endif
