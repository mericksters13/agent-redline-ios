#if os(macOS)
import Foundation
import Testing
@testable import RedlineTool

struct NewWorktreeTests {
    private let temporary = TemporaryFolder("NewWorktreeTests")
    private var root: URL { temporary.url }
    private var paths: HubPaths { HubPaths(root: root.appending(path: "hub-root", directoryHint: .isDirectory)) }

    @Test func aNewChatGetsItsOwnWorktreeFromMain() async throws {
        let repository = root.appending(path: "repo", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        func git(_ arguments: String...) async throws {
            try await runProcess(
                "/usr/bin/git",
                ["-C", repository.path, "-c", "user.name=Test", "-c", "user.email=test@example.com"] + arguments
            )
        }
        try await git("init", "-q", "-b", "main")
        try "one\n".write(to: repository.appending(path: "App.swift"), atomically: true, encoding: .utf8)
        try await git("add", ".")
        try await git("commit", "-q", "-m", "First")
        // The app was built from a feature branch, with a change not committed yet.
        try await git("checkout", "-q", "-b", "feature")
        try "one\ntwo\n".write(to: repository.appending(path: "App.swift"), atomically: true, encoding: .utf8)
        try await git("commit", "-q", "-am", "Second")
        try "one\ntwo\nthree\n".write(to: repository.appending(path: "App.swift"), atomically: true, encoding: .utf8)
        let source = repository.path
        #expect(await offPool { NewWorktree.mainBranch(of: source)?.name } == "main")

        // The new chat's worktree starts from main.
        let made = try await offPool { try NewWorktree.create(from: source, name: "report-1", agent: .claude) }
        #expect(made.hasSuffix("/.claude/worktrees/report-1"))
        let branch = try await runProcess("/usr/bin/git", ["-C", made, "branch", "--show-current"])
        #expect(branch.trimmingCharacters(in: .whitespacesAndNewlines) == "report/1")
        #expect(try String(contentsOfFile: made + "/App.swift", encoding: .utf8) == "one\n")
        // The main checkout shows only its own change, not the folder the worktree is in.
        #expect(try await runProcess("/usr/bin/git", ["-C", source, "status", "--porcelain"]) == " M App.swift\n")
        // The same name again gets a number rather than failing.
        let again = try await offPool { try NewWorktree.create(from: source, name: "report-1", agent: .claude) }
        #expect(again.hasSuffix("/report-1-2"))
        // Reports with the same name that start chats at the same time each get a worktree.
        let together = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    try await offPool { try NewWorktree.create(from: source, name: "report-3", agent: .claude) }
                }
            }
            return try await group.reduce(into: Set<String>()) { $0.insert($1) }
        }
        #expect(together.count == 3)
        for folder in together { await offPool { NewWorktree.remove(folder) } }

        // A report copied into the worktree is ignored by git there.
        let report = root.appending(path: "inbox-report", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: report, withIntermediateDirectories: true)
        try "# Report".write(to: report.appending(path: "report.md"), atomically: true, encoding: .utf8)
        let copy = try NewWorktree.copyReport(report, into: made)
        #expect(FileManager.default.fileExists(atPath: copy + "/report.md"))
        #expect(try await runProcess("/usr/bin/git", ["-C", made, "status", "--porcelain"]).isEmpty)

        // A worktree for a chat that didn't start is taken back, with its branch.
        await offPool { NewWorktree.remove(again) }
        #expect(!FileManager.default.fileExists(atPath: again))
        let notARepository = root.appending(path: "not-a-repo").path
        await #expect(throws: NewWorktree.Failure.self) {
            try await offPool { try NewWorktree.create(from: notARepository, name: "x", agent: .claude) }
        }
        // With no main branch to start from, no worktree is made from the checkout's own branch.
        try await git("branch", "-q", "-m", "main", "trunk")
        #expect(await offPool { NewWorktree.mainBranch(of: source) } == nil)
        await #expect(throws: NewWorktree.Failure.self) {
            try await offPool { try NewWorktree.create(from: source, name: "report-2", agent: .claude) }
        }
        try await git("branch", "-q", "-m", "trunk", "main")

        // The chat it started is found by the phone's pick while its worktree exists.
        try StartedChats.remember(StartedChat(chat: "s-1", folder: made, startedAt: .now), for: "N1", paths: paths)
        #expect(StartedChats.find("N1", paths: paths)?.chat == "s-1")
        #expect(StartedChats.find("N2", paths: paths) == nil)
        try FileManager.default.removeItem(atPath: made)
        #expect(StartedChats.find("N1", paths: paths) == nil)
        // Chats started for different picks that finish together are all remembered.
        let paths = self.paths
        DispatchQueue.concurrentPerform(iterations: 40) { index in
            #expect(throws: Never.self) {
                try StartedChats.remember(
                    StartedChat(chat: "s-\(index)", folder: source, startedAt: .now),
                    for: "P\(index)",
                    paths: paths
                )
            }
        }
        #expect(StartedChats.all(paths).count == 41)
    }
}
#endif
