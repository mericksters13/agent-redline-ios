#if os(macOS)
import Foundation
import SQLite3

/// Codex's chats, from the database the Codex app and its command line keep.
enum CodexThreads {
    /// A Codex chat, as its database lists it.
    struct CodexThread: Equatable {
        var id: String
        var title: String
        var folder: String
        var updatedAt: Date
    }

    /// The newest of Codex's own databases of chats.
    ///
    /// Lists ~/.codex, so callers look it up once and pass it on.
    static func newestDatabase(
        in folder: URL = AgentSettings.homeDirectory().appending(path: ".codex", directoryHint: .isDirectory)
    ) -> URL? {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasPrefix("state_") && $0.hasSuffix(".sqlite") }
        let newest = names.max { (Int($0.dropFirst(6).dropLast(7)) ?? 0) < (Int($1.dropFirst(6).dropLast(7)) ?? 0) }
        return newest.map { folder.appending(path: $0) }
    }

    /// A Codex chat's title.
    static func title(of thread: String, in database: URL?) -> String? {
        value(
            "COALESCE(NULLIF(name, ''), NULLIF(title, ''), SUBSTR(first_user_message, 1, 60))",
            of: thread,
            in: database
        )
    }

    /// The folder a Codex chat works in, which `codex resume` should start in to reopen it there.
    static func folder(of thread: String, in database: URL?) -> String? {
        value("NULLIF(cwd, '')", of: thread, in: database)
    }

    /// One column `expression` of a chat's row; nil when the database, the chat or the value is
    /// missing.
    private static func value(_ expression: String, of thread: String, in database: URL?) -> String? {
        guard let database else { return nil }
        var connection: OpaquePointer?
        guard sqlite3_open_v2(database.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(connection)
            return nil
        }
        defer { sqlite3_close(connection) }
        var statement: OpaquePointer?
        let query = "SELECT \(expression) FROM threads WHERE id = ?"
        guard sqlite3_prepare_v2(connection, query, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, thread, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_text(statement, 0).map { String(cString: $0) }
    }

    /// Chats the user had, used in the last `days`, newest first: not archived, and not the
    /// reviews, subagents and automations Codex runs on its own.
    static func recent(days: Double = 14, in database: URL?) -> [CodexThread] {
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
              AND (source IS NULL OR source NOT LIKE '%subagent%') AND updated_at_ms > ?
            ORDER BY updated_at_ms DESC LIMIT 200
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, query, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64((Date.now.timeIntervalSince1970 - days * 86_400) * 1000))
        var threads: [CodexThread] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func text(_ column: Int32) -> String {
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            }
            threads.append(
                CodexThread(
                    id: text(0),
                    title: text(1),
                    folder: text(2),
                    updatedAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 3)) / 1000)
                )
            )
        }
        return threads
    }
}
#endif
