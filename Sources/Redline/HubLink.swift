#if REDLINE
import CryptoKit
import Foundation
import Network

/// Sends this app's reports to the Mac's hub over the local network. The hub leaves its address
/// and a token in the app's folder over Xcode's device link, once; the token shows the hub that
/// the reports come from a phone paired with that Mac. iOS asks once per app for local network
/// access, the first time a report is sent.
///
/// One connection, one line of JSON per message:
/// 1. The app says who it is (`Hello`), and the hub proves it holds the app's token
///    (`Challenge`). The token itself never crosses the network, so whatever answers at an old
///    address learns nothing it could use, and is sent nothing until it proves it's the hub.
/// 2. The app offers the reports the Mac hasn't confirmed (`Offer`), with its own proof.
/// 3. The hub answers which it wants and which it already has (`Answer`).
/// 4. The app sends each wanted report's files (`Upload`).
/// 5. The hub confirms what it now has (`Reply`).
enum HubLink {
    /// What the hub leaves in the app's folder.
    struct Address: Codable, Equatable, Sendable {
        /// This phone's UDID, which an app can't find out on its own.
        var device: String
        var hosts: [String]
        var port: UInt16
        /// Proves to the hub that an offer comes from this phone and app. Missing from addresses
        /// left by an older hub, which the hub turns down until it leaves a new one.
        var token: String?
        /// False in a simulator, where the hub takes reports from the app's folder: the app only
        /// asks which chats a report can go to.
        var uploads: Bool? = nil
    }

    /// The app's first line on every connection: which phone and app, so the hub knows whose
    /// token to prove it holds, and a fresh random value for that proof.
    struct Hello: Codable, Equatable, Sendable {
        /// Always "hello".
        var kind = "hello"
        var device: String
        var bundleID: String
        var nonce: String
    }

    /// The hub's reply to `Hello`: proof that it holds the app's token, and a fresh random value
    /// of its own for the app's proof.
    struct Challenge: Codable, Equatable, Sendable {
        var nonce: String
        /// Nil when the hub turned the app down.
        var proof: String? = nil
        /// Why the hub turned the app down, when it did.
        var refused: String? = nil
    }

    struct Offer: Codable, Equatable, Sendable {
        struct Report: Codable, Equatable, Sendable {
            var id: String
            var finishedAt: Date
        }

        var device: String
        var bundleID: String
        /// Proves the offer comes from the phone and app the token was given to.
        var proof: String
        var reports: [Report]
    }

    struct Answer: Codable, Equatable, Sendable {
        /// Reports to send now.
        var want: [String]
        /// Reports the Mac already has, or doesn't take: the app can stop offering them.
        var delivered: [String]
        /// Why the hub turned the offer down, when it did.
        var refused: String?
    }

    struct Upload: Codable, Equatable, Sendable {
        var id: String
        /// File name to contents. Encoded as base64 in the line.
        var files: [String: Data]
    }

    struct Reply: Codable, Equatable, Sendable {
        var delivered: [String]
    }

    /// Before the user sends, the app asks which chats a report can go to.
    struct ChatsRequest: Codable, Equatable, Sendable {
        /// Always "chats": tells this request from an offer.
        var kind = "chats"
        var device: String
        var bundleID: String
        var proof: String
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
        var sameWorktree: Bool
        var lastActive: Date
    }

    struct ChatList: Codable, Equatable, Sendable {
        /// The agents on the Mac reports can go to, in the order to show them.
        var agents: [String]
        var chats: [Chat]
        /// The last part of the worktree the app was built from.
        var worktree: String?
        /// The branch a new chat's worktree starts from, such as "main".
        var newChatBase: String? = nil
        /// The agents that can start a new chat; nil, from an older Mac, for every agent.
        var newChats: [String]? = nil
        var refused: String?

        func startsNewChats(_ agent: String) -> Bool { newChats?.contains(agent) ?? true }

        /// Some agent has an open chat or can start a new one, so there's something to pick.
        var offersDestination: Bool {
            agents.contains { agent in startsNewChats(agent) || chats.contains { $0.agent == agent } }
        }
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

    /// Which side proves it holds the token. Each side's proof is made differently, so neither
    /// can be passed off as the other's.
    enum Side: String, Sendable {
        case hub
        case app
    }

    /// Proof of holding `token` on one connection, made from both sides' random values, so it
    /// can't be used again on another.
    static func proof(_ side: Side, token: String, appNonce: String, hubNonce: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data("\(side.rawValue)|\(appNonce)|\(hubNonce)".utf8), using: SymmetricKey(data: Data(token.utf8)))
        return Data(code).map { String(format: "%02x", $0) }.joined()
    }

    /// A fresh random value for one connection.
    static func nonce() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
    }

    /// The app's proof for its next line, when the challenge proves that what answered holds
    /// `token`; nil when it doesn't, or turned the app down.
    static func appProof(after challenge: Challenge, to hello: Hello, token: String) -> String? {
        guard let proof = challenge.proof, !challenge.nonce.isEmpty,
              same(proof, Self.proof(.hub, token: token, appNonce: hello.nonce, hubNonce: challenge.nonce)) else { return nil }
        return Self.proof(.app, token: token, appNonce: hello.nonce, hubNonce: challenge.nonce)
    }

    /// Compares proofs in time that doesn't depend on where they differ.
    private static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private enum Greeting {
        /// The hub proved itself; the app's proof for its next line.
        case proven(String)
        /// The hub doesn't know this app, such as one set up by another Mac.
        case refused
        /// Something that isn't this app's hub answered, or nothing did.
        case notTheHub
    }

    /// Opens the exchange on `line`: the app says who it is and checks the hub's proof.
    private static func greet(_ line: Line, device: String, bundleID: String, token: String) async -> Greeting {
        let hello = Hello(device: device, bundleID: bundleID, nonce: nonce())
        guard await line.send(encode(hello)), let data = await line.read(), let challenge = decode(Challenge.self, from: data) else { return .notTheHub }
        if challenge.refused != nil { return .refused }
        return appProof(after: challenge, to: hello, token: token).map(Greeting.proven) ?? .notTheHub
    }

    /// Asks the hub which chats a report from this app can go to. Nil when the hub can't be
    /// reached or turns the question down.
    static func chats(bundleID: String, address: Address, sourceFile: String?, patience: TimeInterval) async -> ChatList? {
        guard let token = address.token, let port = NWEndpoint.Port(rawValue: address.port) else { return nil }
        for host in address.hosts {
            let line = Line(host: host, port: port)
            guard await line.open(patience: patience) else { continue }
            defer { line.close() }
            // Something else may answer at an old address; the hub may be at the next one.
            guard case .proven(let proof) = await greet(line, device: address.device, bundleID: bundleID, token: token) else { continue }
            let request = ChatsRequest(device: address.device, bundleID: bundleID, proof: proof, sourceFile: sourceFile)
            guard await line.send(encode(request)), let data = await line.read(), let list = decode(ChatList.self, from: data) else { continue }
            return list.refused == nil ? list : nil
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

    /// Delivers the reports the Mac hasn't confirmed. `patience` is how long to wait for the
    /// connection, which includes iOS asking about local network access the first time.
    /// Returns how it went and the reports the Mac now has.
    static func deliver(_ reports: [Offer.Report], bundleID: String, address: Address,
                        files: @Sendable (String) -> [String: Data], patience: TimeInterval) async -> (outcome: Outcome, delivered: [String]) {
        guard let token = address.token, let port = NWEndpoint.Port(rawValue: address.port) else { return (.refused, []) }
        // Even the hub is only trusted with the reports it was offered: an ID it makes up could
        // name a folder outside the reports folder.
        let offered = Set(reports.map(\.id))
        var outcome = Outcome.unreachable
        for host in address.hosts {
            let line = Line(host: host, port: port)
            guard await line.open(patience: patience) else { continue }
            defer { line.close() }
            // Something else may answer at an old address; the hub may be at the next one.
            let proof: String
            switch await greet(line, device: address.device, bundleID: bundleID, token: token) {
            case .proven(let made): proof = made
            case .refused:
                outcome = .refused
                continue
            case .notTheHub:
                outcome = .interrupted
                continue
            }
            let offer = Offer(device: address.device, bundleID: bundleID, proof: proof, reports: reports)
            guard await line.send(encode(offer)), let answerData = await line.read(), let answer = decode(Answer.self, from: answerData) else {
                outcome = .interrupted
                continue
            }
            var delivered = answer.delivered.filter(offered.contains)
            if answer.refused != nil { return (.refused, delivered) }
            guard !answer.want.isEmpty else { return (.delivered, delivered) }
            guard Set(answer.want).isSubset(of: offered) else { return (.refused, delivered) }
            for id in answer.want {
                guard await line.send(encode(Upload(id: id, files: files(id)))) else { return (.interrupted, delivered) }
            }
            guard let replyData = await line.read(), let reply = decode(Reply.self, from: replyData) else { return (.interrupted, delivered) }
            delivered += reply.delivered.filter(offered.contains)
            return (offered.isSubset(of: Set(delivered)) ? .delivered : .interrupted, delivered)
        }
        return (outcome, [])
    }

    /// A connection that sends and reads whole lines.
    private final class Line: @unchecked Sendable {
        private let connection: NWConnection
        private let queue = DispatchQueue(label: "hub-link")
        private var buffer = Data()

        /// The longest line the hub sends: an answer, a reply or a list of chats takes a few
        /// kilobytes. Anything longer isn't from the hub, and isn't kept in memory.
        static let longestLine = 1 << 20

        init(host: String, port: NWEndpoint.Port) {
            connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        }

        /// Waits for the connection. `.waiting` (no route yet, or iOS still asking about local
        /// network access) keeps waiting until `patience` runs out.
        func open(patience: TimeInterval) async -> Bool {
            let once = Once<Bool>()
            return await withCheckedContinuation { continuation in
                once.set(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: once.resume(true)
                    case .failed, .cancelled: once.resume(false)
                    default: break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + patience) { once.resume(false) }
            }
        }

        func send(_ data: Data) async -> Bool {
            await withCheckedContinuation { continuation in
                connection.send(content: data, completion: .contentProcessed { error in continuation.resume(returning: error == nil) })
            }
        }

        /// The next line, without its newline; nil when the connection ends first, the line is too
        /// long, or 30 seconds pass.
        func read() async -> Data? {
            if let line = takeLine() { return line }
            let once = Once<Data?>()
            return await withCheckedContinuation { continuation in
                once.set(continuation)
                queue.asyncAfter(deadline: .now() + 30) { once.resume(nil) }
                receive(once)
            }
        }

        func close() {
            connection.cancel()
        }

        private func receive(_ once: Once<Data?>) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [self] data, _, isComplete, error in
                queue.async {
                    if let data { self.buffer.append(data) }
                    if let line = self.takeLine() {
                        once.resume(line)
                    } else if isComplete || error != nil || self.buffer.count > Self.longestLine {
                        once.resume(nil)
                    } else {
                        self.receive(once)
                    }
                }
            }
        }

        private func takeLine() -> Data? {
            guard let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            return Data(line)
        }
    }

    /// Resumes a continuation once, whichever of several callbacks comes first.
    private final class Once<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Never>?

        func set(_ continuation: CheckedContinuation<T, Never>) {
            lock.withLock { self.continuation = continuation }
        }

        func resume(_ value: T) {
            let continuation = lock.withLock {
                defer { self.continuation = nil }
                return self.continuation
            }
            continuation?.resume(returning: value)
        }
    }
}
#endif
