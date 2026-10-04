#if os(macOS)
import Foundation
import Synchronization

/// The chats a report can go to: the open chats, of the agents on this Mac, that work on the
/// report's app.
///
/// The phone shows them so the user picks where a report goes; the chat working in the worktree the
/// app was built from comes first.
enum ChatDirectory {
    /// The agents installed on this Mac, in the order to show them.
    static func agents() -> [Agent] {
        Agent.allCases.filter { agent in
            switch agent {
            case .claude:
                FileManager.default.fileExists(atPath: URL.homeDirectory.appending(path: ".claude/sessions").path)
            case .codex: AgentCommand.locate(.codex) != nil
            }
        }
    }

    /// What each folder's projects build, kept a while: reading a big folder's projects can
    /// take seconds, and the phone waits for the answer.
    private static let apps = FolderApps()

    private static let warming = DispatchQueue(label: "Redline.hub.warming", qos: .utility)

    /// Reads the folders of every open chat ahead of time, so the first question is quick too.
    static func warm(paths: HubPaths) {
        warming.async {
            for bundleID in Set(Chats.removeClosedChats(paths).flatMap(\.bundleIDs)) {
                _ = list(bundleID: bundleID, sourceFile: nil, paths: paths)
            }
        }
    }

    /// The open chats that work on the app, the ones in the worktree `sourceFile` is in first,
    /// for the phone to show.
    static func list(bundleID: String, sourceFile: String?, paths: HubPaths) -> HubMessage.ChatList {
        let worktree = sourceFile.map(Worktree.root(of:))
        func buildsApp(_ folder: String) -> Bool { apps.bundleIDs(in: folder).contains(bundleID) }
        func chat(_ agent: Agent, id: String, title: String, folder: String, lastActive: Date) -> HubMessage.Chat {
            HubMessage.Chat(
                id: id,
                agent: agent.rawValue,
                title: title,
                folder: URL(filePath: folder).lastPathComponent,
                isSameWorktree: worktree != nil && Worktree.root(of: folder) == worktree,
                lastActive: lastActive
            )
        }
        let agents = agents()
        var chats: [HubMessage.Chat] = []
        if agents.contains(.claude) {
            chats += ClaudeSessions.openSessions().filter { buildsApp($0.folder) }
                .map {
                    chat(.claude, id: $0.id, title: $0.title ?? "Untitled", folder: $0.folder, lastActive: $0.updatedAt)
                }
        }
        if agents.contains(.codex) {
            // Lazy, so projects are read only until 15 chats are found.
            chats += CodexThreads.recent(in: CodexThreads.newestDatabase()).lazy.filter { buildsApp($0.folder) }.prefix(
                15
            )
            .map { chat(.codex, id: $0.id, title: $0.title, folder: $0.folder, lastActive: $0.updatedAt) }
        }
        chats.sort { ($0.isSameWorktree ? 1 : 0, $0.lastActive) > ($1.isSameWorktree ? 1 : 0, $1.lastActive) }
        return HubMessage.ChatList(
            agents: agents.map(\.rawValue),
            chats: chats,
            worktree: worktree.map { URL(filePath: $0).lastPathComponent },
            newChatBase: worktree.flatMap { NewWorktree.mainBranch(of: $0)?.name }
        )
    }
}

/// The bundle IDs each folder's projects build, read at most every half hour per folder.
private final class FolderApps: Sendable {
    private struct CachedApps {
        var ids: [String]
        var readAt: Date
    }

    private let known = Mutex<[String: CachedApps]>([:])
    static let keepFor: TimeInterval = 1800

    /// The folder's apps, read again once the last read is older than `keepFor`.
    func bundleIDs(in folder: String) -> [String] {
        if let entry = known.withLock({ $0[folder] }), Date.now.timeIntervalSince(entry.readAt) < Self.keepFor {
            return entry.ids
        }
        let ids = ProjectApps.bundleIDs(in: URL(filePath: folder))
        known.withLock { $0[folder] = CachedApps(ids: ids, readAt: .now) }
        return ids
    }
}
#endif
