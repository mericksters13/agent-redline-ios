#if os(macOS)
import Foundation

/// The chats the hub started for "New chat", by the phone's pick, so later reports with the same
/// pick go to that chat instead of starting another. Picking "New chat" again on the phone makes
/// a new pick, and a new chat.
struct StartedChat: Codable, Equatable, Sendable {
    /// Codex's thread ID or Claude Code's session ID.
    var chat: String
    /// The chat's own worktree.
    var folder: String
    var startedAt: Date

    private enum CodingKeys: String, CodingKey {
        case chat, folder
        case startedAt = "at"
    }
}

/// The started chats, kept in `hub/started-chats.json`.
enum StartedChats {
    static func fileURL(_ paths: HubPaths) -> URL { paths.hub.appending(path: "started-chats.json") }

    /// Every remembered chat. A file that can't be read is moved aside, so remembering the next
    /// one doesn't write over it.
    static func all(_ paths: HubPaths) -> [String: StartedChat] {
        StoredFile.load([String: StartedChat].self, from: fileURL(paths), decoder: HubPaths.decoder) { printError($0) } ?? [:]
    }

    /// The chat started for this pick, while its worktree still exists.
    static func find(_ pick: String, paths: HubPaths) -> StartedChat? {
        all(paths)[pick].flatMap { FileManager.default.fileExists(atPath: $0.folder) ? $0 : nil }
    }

    static func remember(_ chat: StartedChat, for pick: String, paths: HubPaths) throws {
        var chats = all(paths)
        chats[pick] = chat
        try FileManager.default.createDirectory(at: paths.hub, withIntermediateDirectories: true)
        try HubPaths.encoder.encode(chats).write(to: fileURL(paths), options: .atomic)
    }
}
#endif
