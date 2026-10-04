#if os(macOS)
import Foundation
import SQLite3
import Synchronization

/// The chats a report can go to: the open chats, of the agents on this Mac, that work on the
/// report's app. The phone shows them so the user picks where a report goes; the chat working
/// in the worktree the app was built from comes first.
enum ChatDirectory {
    /// The agents installed on this Mac, in the order to show them.
    static func agents() -> [Agent] {
        Agent.allCases.filter { agent in
            switch agent {
            case .claude: FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.claude/sessions")
            case .codex: AgentCommand.locate(.codex) != nil
            }
        }
    }

    /// What each folder's projects build, kept a while: reading a big folder's projects can
    /// take seconds, and the phone waits for the answer.
    private static let apps = FolderApps()

    /// Reads the folders of every open chat ahead of time, so the first question is quick too.
    static func warm(paths: HubPaths) {
        DispatchQueue.global(qos: .utility).async {
            for bundleID in Set(Chats.live(paths).flatMap(\.bundleIDs)) {
                _ = list(bundleID: bundleID, sourceFile: nil, paths: paths)
            }
        }
    }

    static func list(bundleID: String, sourceFile: String?, paths: HubPaths) -> HubMessage.ChatList {
        let worktree = sourceFile.map(Worktree.root(of:))
        func buildsApp(_ folder: String) -> Bool { apps.bundleIDs(in: folder).contains(bundleID) }
        func chat(_ agent: Agent, id: String, title: String, folder: String, lastActive: Date) -> HubMessage.Chat {
            HubMessage.Chat(id: id, agent: agent.rawValue, title: title, folder: URL(fileURLWithPath: folder).lastPathComponent,
                            sameWorktree: worktree != nil && Worktree.root(of: folder) == worktree, lastActive: lastActive)
        }
        let agents = agents()
        var chats: [HubMessage.Chat] = []
        if agents.contains(.claude) {
            chats += ClaudeSessions.open().filter { buildsApp($0.folder) }
                .map { chat(.claude, id: $0.id, title: $0.title ?? "Untitled", folder: $0.folder, lastActive: $0.updatedAt) }
        }
        if agents.contains(.codex) {
            chats += CodexThreads.recent().filter { buildsApp($0.folder) }.prefix(15)
                .map { chat(.codex, id: $0.id, title: $0.title, folder: $0.folder, lastActive: $0.updated) }
        }
        chats.sort { ($0.sameWorktree ? 1 : 0, $0.lastActive) > ($1.sameWorktree ? 1 : 0, $1.lastActive) }
        return HubMessage.ChatList(agents: agents.map(\.rawValue), chats: chats, worktree: worktree.map { URL(fileURLWithPath: $0).lastPathComponent },
                                   newChatBase: worktree.flatMap { NewWorktree.mainBranch(of: $0)?.name })
    }
}

/// The bundle IDs each folder's projects build, read at most every half hour per folder.
final class FolderApps: Sendable {
    private struct CachedApps {
        var ids: [String]
        var readAt: Date
    }

    private let known = Mutex<[String: CachedApps]>([:])
    static let keepFor: TimeInterval = 1800

    func bundleIDs(in folder: String) -> [String] {
        if let entry = known.withLock({ $0[folder] }), Date().timeIntervalSince(entry.readAt) < Self.keepFor { return entry.ids }
        let ids = ProjectApps.bundleIDs(in: URL(fileURLWithPath: folder))
        known.withLock { $0[folder] = CachedApps(ids: ids, readAt: Date()) }
        return ids
    }
}

/// The folder holding `.git` above a path: the worktree, which is what tells chats apart.
enum Worktree {
    static func root(of path: String) -> String {
        let files = FileManager.default
        var folder = URL(fileURLWithPath: path).standardizedFileURL
        var isFolder: ObjCBool = false
        if !files.fileExists(atPath: folder.path, isDirectory: &isFolder) || !isFolder.boolValue || folder.pathExtension == "xcodeproj" {
            folder = folder.deletingLastPathComponent()
        }
        var candidate = folder
        while candidate.path != "/" {
            if files.fileExists(atPath: candidate.appending(path: ".git").path) { return candidate.path }
            candidate = candidate.deletingLastPathComponent()
        }
        return folder.path
    }
}

/// Codex's chats, from the database the Codex app and its command line keep.
enum CodexThreads {
    struct Thread: Equatable {
        var id: String
        var title: String
        var folder: String
        var updated: Date
    }

    /// The newest of Codex's own databases of chats.
    static var database: URL? {
        let folder = URL(fileURLWithPath: NSHomeDirectory() + "/.codex")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasPrefix("state_") && $0.hasSuffix(".sqlite") }
        let newest = names.max { (Int($0.dropFirst(6).dropLast(7)) ?? 0) < (Int($1.dropFirst(6).dropLast(7)) ?? 0) }
        return newest.map { folder.appending(path: $0) }
    }

    /// A Codex chat's title.
    static func title(of thread: String, in database: URL? = database) -> String? {
        guard let database else { return nil }
        var connection: OpaquePointer?
        guard sqlite3_open_v2(database.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(connection)
            return nil
        }
        defer { sqlite3_close(connection) }
        var statement: OpaquePointer?
        let query = "SELECT COALESCE(NULLIF(name, ''), NULLIF(title, ''), SUBSTR(first_user_message, 1, 60)) FROM threads WHERE id = ?"
        guard sqlite3_prepare_v2(connection, query, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, thread, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_text(statement, 0).map { String(cString: $0) }
    }

    /// Chats the user had, used in the last `days`, newest first: not archived, and not the
    /// reviews, subagents and automations Codex runs on its own.
    static func recent(days: Double = 14, in database: URL? = database) -> [Thread] {
        guard let database else { return [] }
        var connection: OpaquePointer?
        guard sqlite3_open_v2(database.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(connection)
            return []
        }
        defer { sqlite3_close(connection) }
        let query = """
            SELECT id, COALESCE(NULLIF(name, ''), NULLIF(title, ''), SUBSTR(first_user_message, 1, 60), 'Untitled'), cwd, updated_at_ms
            FROM threads
            WHERE archived = 0 AND agent_role IS NULL AND (thread_source IS NULL OR thread_source = 'user')
              AND source NOT LIKE '%subagent%' AND updated_at_ms > ?
            ORDER BY updated_at_ms DESC LIMIT 200
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, query, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64((Date().timeIntervalSince1970 - days * 86_400) * 1000))
        var threads: [Thread] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func text(_ column: Int32) -> String { sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" }
            threads.append(Thread(id: text(0), title: text(1), folder: text(2),
                                  updated: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 3)) / 1000)))
        }
        return threads
    }
}
#endif
