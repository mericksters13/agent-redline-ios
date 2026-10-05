#if os(macOS)
import CryptoKit
import Foundation

/// The messages between the kit and the hub, one line of JSON each.
///
/// Must match the kit's `HubLink` exactly. On one connection: the app's `Hello`, the hub's
/// `Challenge`, then the app's `Offer`, the hub's `Answer`, an `Upload` for each report the hub
/// wants, and the hub's `Reply`. Each side proves it holds the app's token without sending it.
enum HubMessage {
    /// What the hub leaves in each watched app's folder on a phone, over the device link.
    struct Address: Codable, Equatable, Sendable {
        /// The phone's UDID, which an app can't find out on its own.
        var device: String
        var hosts: [String]
        var port: UInt16
        /// Shared by the hub and the app the address was given to.
        ///
        /// Only a Mac paired with the phone can leave it there. Never sent over the network; each
        /// side proves it holds it.
        var token: String?
        /// False in a simulator app, whose reports the hub takes from its folder: the app only
        /// asks which chats a report can go to.
        var uploads: Bool? = nil
    }

    /// The app's first line on every connection: which phone and app, so the hub knows whose
    /// token to prove it holds, and a fresh random value for that proof.
    struct Hello: Codable, Equatable, Sendable {
        /// Always "hello".
        var kind: String
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

    /// Both sides' random values on one connection.
    struct Nonces: Equatable, Sendable {
        var app: String
        var hub: String
    }

    /// Sent by the app after the challenge: the reports the Mac hasn't confirmed.
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

    /// The hub's answer to an offer.
    struct Answer: Codable, Equatable, Sendable {
        /// Reports to send now.
        var want: [String]
        /// Reports the Mac already has, or doesn't take: the app can stop offering them.
        var delivered: [String]
        /// Why the offer was turned down, when it was.
        var refused: String?
    }

    /// Sent by the app for each report the hub wants, after the answer.
    struct Upload: Codable, Equatable, Sendable {
        var id: String
        /// File name to contents, base64 in the line.
        var files: [String: Data]
    }

    /// The hub's last line: the offered reports the app can stop offering.
    struct Reply: Codable, Equatable, Sendable {
        var delivered: [String]
    }

    /// Before the user sends, the app asks which chats a report can go to, in place of an offer.
    struct ChatsRequest: Codable, Equatable, Sendable {
        /// Always "chats": tells this request from an offer, which has no kind.
        var kind: String
        var device: String
        var bundleID: String
        var proof: String
        /// The project file that attached the kit, naming the worktree the app was built from.
        var sourceFile: String?
    }

    /// An open chat a report can go to.
    struct Chat: Codable, Equatable, Sendable {
        /// The agent's own ID for the chat: Claude Code's session ID, Codex's thread ID.
        var id: String
        /// `claude` or `codex`.
        var agent: String
        var title: String
        /// The last part of the chat's folder.
        var folder: String
        /// The chat works in the worktree the app was built from.
        var isSameWorktree: Bool
        var lastActive: Date

        private enum CodingKeys: String, CodingKey {
            case id, agent, title, folder, lastActive
            /// The kit reads this key.
            case isSameWorktree = "sameWorktree"
        }
    }

    /// The hub's answer to a question about chats.
    struct ChatList: Codable, Equatable, Sendable {
        /// The agents on this Mac reports can go to, in the order to show them.
        var agents: [String]
        /// The open chats on the app, those in the app's worktree first, then by last use.
        var chats: [Chat]
        /// The last part of the worktree the app was built from.
        var worktree: String?
        /// The branch a new chat's worktree starts from, such as "main".
        var newChatBase: String? = nil
        /// The agents whose command is on this Mac to start a new chat; nil for every agent.
        var newChats: [String]? = nil
        /// The branch the build's worktree is on when the phone asks, such as "feature/growth-card".
        ///
        /// Nil when that is `newChatBase`, the worktree is on no branch or can't be told, or no agent
        /// starts new chats.
        var buildBranch: String? = nil
        /// The first seven characters of the commit the build's worktree is on when it is on no
        /// branch, such as "1a2b3c4".
        ///
        /// Nil when the worktree is on a branch or can't be told, or no agent starts new chats.
        var buildCommit: String? = nil
        /// Why the request was turned down, when it was.
        var refused: String?
    }

    /// The kit's folder inside an app's data container: the app's Application Support, which is
    /// where the kit's ReportStore keeps its files.
    static let kitFolder = "Library/Application Support/Redline"

    /// The kit's folder in a build from before the rename.
    static let earlierKitFolder = "Library/Application Support/iOSAgenticDebuggingKit"

    /// Where the kit looks for the hub's address, inside an app's data container.
    static let addressPath = kitFolder + "/hub.json"

    /// Where a build from before the rename looks for it.
    ///
    /// The hub leaves the address there as well, so such a build installed after the Mac tool is
    /// updated still reaches the hub. A build with the new name removes that file when it moves its
    /// old folder over.
    static let earlierAddressPath = earlierKitFolder + "/hub.json"

    /// Which side proves it holds the token.
    ///
    /// Each side's proof is made differently, so neither can be passed off as the other's.
    enum Side: String, Sendable {
        case hub
        case app
    }

    /// Proof of holding `token` on one connection, made from both sides' random values, so it
    /// can't be used again on another.
    ///
    /// Must match the kit's `HubLink.proof`.
    static func proof(_ side: Side, token: String, nonces: Nonces) -> String {
        let code = HMAC<SHA256>.authenticationCode(
            for: Data("\(side.rawValue)|\(nonces.app)|\(nonces.hub)".utf8),
            using: SymmetricKey(data: Data(token.utf8))
        )
        return Data(code).map { String(format: "%02x", $0) }.joined()
    }

    /// A fresh random value for one connection.
    static func nonce() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
    }

    /// How every line is written: sorted keys, slashes as they are, ISO 8601 dates, as the kit's
    /// HubLink writes them.
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

    /// One line: the value's JSON and a newline.
    static func encode<T: Encodable>(_ value: T) -> Data {
        do {
            return try encoder.encode(value) + Data("\n".utf8)
        } catch {
            // The messages are plain structs of strings, numbers, dates and data, which always encode.
            assertionFailure("Couldn't encode \(T.self): \(error)")
            return Data("\n".utf8)
        }
    }

    /// Decodes one line.
    ///
    /// Throws a DecodingError that says which field was wrong.
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }

    /// Why a line didn't decode, short enough for the log.
    static func reason(_ error: any Error) -> String {
        switch error as? DecodingError {
        case .keyNotFound(let key, _): "no \(key.stringValue)"
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            context.codingPath.isEmpty
                ? context.debugDescription
                : "\(context.codingPath.map(\.stringValue).joined(separator: ".")): \(context.debugDescription)"
        case .none: error.localizedDescription
        @unknown default: error.localizedDescription
        }
    }
}
#endif
