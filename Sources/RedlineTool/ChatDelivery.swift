#if os(macOS)
import Foundation

/// Where the hub sent a report, saved next to it so the hub's window shows exactly what
/// happened: the agent, its chat and the chat's title.
struct ChatDelivery: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// Put into an open chat.
        case sent
        /// A chat the hub started for it.
        case newChat
        /// Waiting for the chat's next message or reply.
        case nextMessage
        /// Waiting in the inbox; `title` says why.
        case waiting
    }

    var agent: String?
    var chat: String?
    var title: String
    var kind: Kind
    var deliveredAt = Date.now

    private enum CodingKeys: String, CodingKey {
        case agent, chat, title, kind
        case deliveredAt = "at"
    }

    init(agent: Agent?, chat: String?, title: String, kind: Kind) {
        self.agent = agent?.rawValue
        self.chat = chat
        self.title = title
        self.kind = kind
    }

    /// Not in a chat yet: a chat that takes the report later records a claim.
    var isPending: Bool { kind == .waiting || kind == .nextMessage }

    /// Saves where the report went.
    ///
    /// One not in a chat yet is saved only while no chat holds the report, and no chat can take it
    /// meanwhile: a chat that took it first, such as one whose wait woke when the report was filed,
    /// keeps showing, and a chat that takes it later is always newer than this.
    static func save(_ delivery: ChatDelivery, in report: URL) throws {
        func write() throws {
            try HubPaths.encoder.encode(delivery).write(
                to: report.appending(path: Inbox.deliveryFile),
                options: .atomic
            )
        }
        if delivery.isPending { try Inbox.unlessTaken(report, write) } else { try write() }
    }

    static func load(from report: URL) -> ChatDelivery? {
        (try? Data(contentsOf: report.appending(path: Inbox.deliveryFile))).flatMap {
            try? HubPaths.decoder.decode(ChatDelivery.self, from: $0)
        }
    }
}
#endif
