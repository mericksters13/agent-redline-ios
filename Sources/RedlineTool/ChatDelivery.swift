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

    static func save(_ delivery: ChatDelivery, in report: URL) throws {
        try HubPaths.encoder.encode(delivery).write(to: report.appending(path: Inbox.deliveryFile), options: .atomic)
    }

    static func load(from report: URL) -> ChatDelivery? {
        (try? Data(contentsOf: report.appending(path: Inbox.deliveryFile))).flatMap {
            try? HubPaths.decoder.decode(ChatDelivery.self, from: $0)
        }
    }
}
#endif
