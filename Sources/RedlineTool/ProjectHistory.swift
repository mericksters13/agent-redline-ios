#if os(macOS)
import Foundation

/// The agent and folder last used for an app, so the hub keeps taking its reports after the chat
/// closes and can start a chat there when one arrives.
struct ProjectUse: Codable, Equatable, Sendable {
    var agent: String
    var folder: String
    var usedAt: Date

    private enum CodingKeys: String, CodingKey {
        case agent, folder
        case usedAt = "at"
    }
}

/// The apps chats have worked on, by bundle ID, kept in `hub/projects.json`.
enum ProjectHistory {
    static func fileURL(_ paths: HubPaths) -> URL { paths.hub.appending(path: "projects.json") }

    /// Every app a chat has worked on.
    ///
    /// A file that can't be read is moved aside, so noting the next chat doesn't write over it.
    static func all(_ paths: HubPaths) -> [String: ProjectUse] {
        StoredFile.load([String: ProjectUse].self, from: fileURL(paths), decoder: HubPaths.decoder) { printError($0) }
            ?? [:]
    }

    /// Notes the chat's apps as worked on in its folder, by its agent, now.
    static func note(_ chat: ChatRecord, paths: HubPaths) throws {
        var uses = all(paths)
        for bundleID in chat.bundleIDs {
            uses[bundleID] = ProjectUse(agent: chat.agent, folder: chat.folder, usedAt: .now)
        }
        try FileManager.default.createDirectory(at: paths.hub, withIntermediateDirectories: true)
        try HubPaths.encoder.encode(uses).write(to: fileURL(paths), options: .atomic)
    }
}
#endif
