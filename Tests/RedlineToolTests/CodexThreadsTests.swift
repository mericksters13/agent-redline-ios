#if os(macOS)
import Foundation
import Testing
@testable import RedlineTool

struct CodexThreadsTests {
    private let temporary = TemporaryFolder("CodexThreadsTests")
    private var root: URL { temporary.url }
    private var paths: HubPaths { HubPaths(root: root.appending(path: "hub-root", directoryHint: .isDirectory)) }

    @Test func theNewestDatabaseIsTheOneWithTheHighestNumber() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["state_9.sqlite", "state_10.sqlite", "state_2.sqlite", "other.sqlite"] {
            try Data().write(to: root.appending(path: name))
        }
        #expect(CodexThreads.newestDatabase(in: root)?.lastPathComponent == "state_10.sqlite")
        #expect(CodexThreads.newestDatabase(in: root.appending(path: "missing")) == nil)
    }

    @Test func codexChatsLeaveOutWhatCodexRunsOnItsOwn() async throws {
        let database = root.appending(path: "state_5.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let now = Int64(Date.now.timeIntervalSince1970 * 1000)
        let old = now - 30 * 86_400_000
        let sql = """
            CREATE TABLE threads (id TEXT, name TEXT, title TEXT, first_user_message TEXT, cwd TEXT, updated_at_ms INTEGER,
                                  archived INTEGER, agent_role TEXT, thread_source TEXT, source TEXT);
            INSERT INTO threads VALUES ('t-user', 'Fix the paywall', 'Fix the paywall', 'fix it', '/p', \(now), 0, NULL, 'user', 'vscode');
            INSERT INTO threads VALUES ('t-older', '', '', 'Why is the outline wide', '/p', \(now - 1000), 0, NULL, NULL, 'vscode');
            INSERT INTO threads VALUES ('t-no-source', 'Tidy the list', '', '', '/p', \(now - 2000), 0, NULL, NULL, NULL);
            INSERT INTO threads VALUES ('t-guardian', 'Guardian review', '', '', '/p', \(now), 0, NULL, 'guardian_review', '{"subagent":{"other":"guardian"}}');
            INSERT INTO threads VALUES ('t-auto', 'Nightly', '', '', '/p', \(now), 0, NULL, 'automation', 'vscode');
            INSERT INTO threads VALUES ('t-archived', 'Old', '', '', '/p', \(now), 1, NULL, 'user', 'vscode');
            INSERT INTO threads VALUES ('t-stale', 'Stale', '', '', '/p', \(old), 0, NULL, 'user', 'vscode');
            """
        try await runProcess("/usr/bin/sqlite3", [database.path, sql])
        let threads = CodexThreads.recent(in: database)
        #expect(threads.map(\.id) == ["t-user", "t-older", "t-no-source"])
        // A chat without a name goes by its first message.
        #expect(threads[1].title == "Why is the outline wide")
        // The viewer reopens a Codex chat in the folder Codex keeps for it.
        #expect(CodexThreads.folder(of: "t-user", in: database) == "/p")
        #expect(CodexThreads.folder(of: "t-missing", in: database) == nil)
        #expect(CodexThreads.title(of: "t-older", in: database) == "Why is the outline wide")
    }
}
#endif
