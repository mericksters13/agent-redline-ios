#if os(macOS)
import Foundation
import Testing
@testable import RedlineTool

struct ChatSessionTests {
    private let temporary = TemporaryFolder("ChatSessionTests")
    private var root: URL { temporary.url }
    private var paths: HubPaths { HubPaths(root: root.appending(path: "hub-root", directoryHint: .isDirectory)) }

    /// A project folder with two ways of setting bundle IDs.
    private func project() throws -> URL {
        let folder = root.appending(path: "ExampleApp", directoryHint: .isDirectory)
        let files = FileManager.default
        try files.createDirectory(at: folder.appending(path: "App/App.xcodeproj"), withIntermediateDirectories: true)
        try files.createDirectory(
            at: folder.appending(path: "Pods/Vendor.xcodeproj"),
            withIntermediateDirectories: true
        )
        try "targets:\n  App:\n    settings:\n      PRODUCT_BUNDLE_IDENTIFIER: com.example.app\n".write(
            to: folder.appending(path: "App/project.yml"),
            atomically: true,
            encoding: .utf8
        )
        try """
        { objects = {
            T1 = {isa = PBXNativeTarget; productType = "com.apple.product-type.application"; buildConfigurationList = L1; };
            L1 = {isa = XCConfigurationList; buildConfigurations = (C1); };
            C1 = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_BUNDLE_IDENTIFIER = com.example.app; }; };
        }; }
        """.write(to: folder.appending(path: "App/App.xcodeproj/project.pbxproj"), atomically: true, encoding: .utf8)
        // Other people's code doesn't count.
        try """
        { objects = {
            T1 = {isa = PBXNativeTarget; productType = "com.apple.product-type.application"; buildConfigurationList = L1; };
            L1 = {isa = XCConfigurationList; buildConfigurations = (C1); };
            C1 = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_BUNDLE_IDENTIFIER = org.cocoapods.vendor; }; };
        }; }
        """.write(
            to: folder.appending(path: "Pods/Vendor.xcodeproj/project.pbxproj"),
            atomically: true,
            encoding: .utf8
        )
        return folder
    }

    /// A report in the inbox with a screen picture and one attached to a note, `pictureBytes` each.
    @discardableResult
    private func inboxReport(_ id: String, bundleID: String = "com.example.app", pictureBytes: Int = 10) throws -> URL {
        let listing: [String: Any] = [
            "screens": [["images": [["file": "screen-1.jpg"]]]],
            "items": [["attachments": [String]()], ["attachments": ["note-2.jpg"]]],
        ]
        return try fileInboxReport(
            "\(id)-00000001",
            bundleID: bundleID,
            in: paths,
            listing: listing,
            pictures: [
                "screen-1.jpg": Data(repeating: 0xFF, count: pictureBytes),
                "note-2.jpg": Data(repeating: 0xD8, count: pictureBytes),
            ],
            summary: "# UI report: Example\n\n1. **Milk stash**: Test.\n",
            receivedAt: Date(timeIntervalSince1970: 1_791_000_000)
        )
    }

    private func session(_ folder: URL) -> ChatSession {
        ChatSession(paths: paths, folder: folder, extraApps: [], agent: "test", startsHub: false)
    }

    /// A process waiting on the record lock while another removes the chat locks the file that
    /// replaces it, the one later processes lock too, not the removed one.
    @Test func theRecordLockFollowsALockFileRemovedWhileWaiting() async throws {
        try FileManager.default.createDirectory(at: Chats.folder(paths), withIntermediateDirectories: true)
        let path = Chats.recordLock("claude-1", paths: paths).path
        let removed = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        try #require(removed >= 0)
        #expect(flock(removed, LOCK_EX) == 0)
        var removedFile = stat()
        #expect(fstat(removed, &removedFile) == 0)
        let paths = self.paths
        let waiting = DispatchSemaphore(value: 0)
        async let locked: ino_t? = offPool {
            waiting.signal()
            return Chats.withRecordLock("claude-1", paths: paths) {
                var file = stat()
                return stat(path, &file) == 0 ? file.st_ino : nil
            }
        }
        await offPool {
            waiting.wait()
            Thread.sleep(forTimeInterval: 0.2)
        }
        unlink(path)
        close(removed)
        let lockedFile = try #require(await locked)
        #expect(lockedFile != removedFile.st_ino)
    }

    @Test func aChatOutsideAnAppProjectStaysOut() throws {
        let notes = root.appending(path: "Notes", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        session(notes).register(agent: "claude-code")
        #expect(Chats.removeClosedChats(paths).isEmpty)
    }

    @Test func aPIDTakenByALaterProcessDoesNotKeepAChatOpen() throws {
        let started = try #require(Chats.startTime(of: getpid()))
        #expect(started <= Date.now)
        #expect(Chats.isRunning(getpid(), since: Date.now))
        // Registered before this process started: the chat's process is gone and its PID reused.
        #expect(!Chats.isRunning(getpid(), since: started.addingTimeInterval(-60)))

        var chat = session(try project()).chat
        chat.registeredAt = started.addingTimeInterval(-60)
        try Chats.register(chat, paths: paths)
        #expect(Chats.removeClosedChats(paths).isEmpty)
        #expect(Chats.record(chat.id, paths: paths) == nil)
    }

    @Test func onlyOneChatTakesAReport() throws {
        let folder = try project()
        _ = try inboxReport("20261003-223449")
        let first = session(folder)
        let second = session(folder)
        #expect(first.take(budget: 1_000_000).reports.count == 1)
        #expect(second.take(budget: 1_000_000).reports.isEmpty)
        let report = try #require(Inbox.reports(for: ["com.example.app"], paths: paths).first)
        #expect(report.claim?.chat == first.chat.id)
    }

    @Test func aReportAnInterruptedHandOverClaimedIsFreeAgain() throws {
        let folder = try project()
        let inbox = try inboxReport("20261003-223449")
        // A process that has ended stands in for a chat's server that crashed mid hand-over.
        let ended = Process()
        ended.executableURL = URL(filePath: "/usr/bin/true")
        try ended.run()
        ended.waitUntilExit()
        let stranded = Claim(
            chat: "gone",
            agent: "test",
            folder: folder.path,
            claimedAt: .now,
            handingOverIn: ended.processIdentifier
        )
        try HubPaths.encoder.encode(stranded).write(to: inbox.appending(path: Inbox.claimFile))
        #expect(Inbox.unclaimedReports(for: ["com.example.app"], paths: paths).count == 1)

        let chat = session(folder)
        let taken = chat.take(budget: 1_000_000)
        #expect(taken.reports.count == 1)
        // Held by this process until what carries it is written out: if it quit first, the claim
        // would be interrupted and the report taken again.
        #expect(Inbox.claim(of: inbox)?.handingOverIn == getpid())
        ChatSession.settle(taken.reports, isDelivered: true)
        let report = try #require(Inbox.reports(for: ["com.example.app"], paths: paths).first)
        #expect(report.claim?.chat == chat.chat.id)
        // Handed over: the claim stands for good, and no other chat takes the report.
        #expect(report.claim?.handingOverIn == nil)
        #expect(session(folder).take(budget: 1_000_000).reports.isEmpty)
    }

    @Test func aProcessThatReusedTheHandOversPIDDoesntHoldTheReport() throws {
        let folder = try project()
        let inbox = try inboxReport("20261003-223449")
        // This test's process stands in for a later process that got the crashed hand-over's PID: it
        // started long after the claim was made.
        let reused = Claim(
            chat: "gone",
            agent: "test",
            folder: folder.path,
            claimedAt: Date(timeIntervalSince1970: 0),
            handingOverIn: getpid()
        )
        #expect(reused.isInterrupted)
        try HubPaths.encoder.encode(reused).write(to: inbox.appending(path: Inbox.claimFile))
        #expect(Inbox.unclaimedReports(for: ["com.example.app"], paths: paths).count == 1)
        // The process that made the claim, still handing the report over, holds it.
        let held = Claim(chat: "here", agent: "test", folder: folder.path, claimedAt: .now, handingOverIn: getpid())
        #expect(!held.isInterrupted)
    }

    @Test func reportsWaitingForClaudeGoOnlyIfNoChatTookThemMeanwhile() throws {
        let folder = try project()
        try inboxReport("20261003-223449")
        try inboxReport("20261003-223450")
        let other = try inboxReport("20261003-223451", bundleID: "com.example.other")
        let waited = Inbox.unclaimedReports(for: ["com.example.app", "com.example.other"], paths: paths)
        #expect(waited.count == 3)
        // While the claude command wasn't ready, a chat took the oldest and the other app's report was
        // removed.
        let chat = session(folder)
        let taken = chat.take(budget: 1)
        #expect(taken.reports.map(\.folder.lastPathComponent) == ["20261003-223449-00000001"])
        ChatSession.settle(taken.reports, isDelivered: true)
        try FileManager.default.removeItem(at: other)

        let still = Handoff.stillWaiting(waited, paths: paths)
        #expect(still.map(\.folder.lastPathComponent) == ["20261003-223450-00000001"])
    }

    @Test func aChatTakesOnlyReportsSentToItOrSentNowhere() throws {
        let folder = try project()
        let app = "com.example.app"
        let nowhere = try inboxReport("20261003-223449")
        let pickedForCodex = try inboxReport("20261003-223450")
        let addressedToCodex = try inboxReport("20261003-223451")
        let pickedForNewChat = try inboxReport("20261003-223452")
        func pick(_ report: URL, _ destination: String) throws {
            try #"{"app":{},"destination":\#(destination),"screens":[],"items":[]}"#.write(
                to: report.appending(path: "report.json"),
                atomically: true,
                encoding: .utf8
            )
        }
        // Picked on the phone, before the hub has handed it over.
        try pick(pickedForCodex, #"{"agent":"codex","chat":"c1"}"#)
        try Inbox.setRecipient(ReportRecipient(chat: "codex-t1", agent: "codex", folder: ""), of: addressedToCodex)
        try pick(pickedForNewChat, #"{"agent":"claude","newChat":"p1"}"#)
        func claimant(_ report: URL) -> String? {
            Inbox.reports(for: [app], paths: paths).first { $0.folder.lastPathComponent == report.lastPathComponent }?
                .claim?.chat
        }

        let other = session(folder)
        let taken = other.take(budget: 1_000_000)
        #expect(taken.reports.count == 1 && taken.remaining == 0)
        #expect(claimant(nowhere) == other.chat.id)
        #expect(!other.waitForReport(timeout: 0.1, waiter: ChatSession.Waiter()))

        // Each picked chat takes its own.
        let picked = ChatSession(
            paths: paths,
            folder: folder,
            extraApps: [],
            agent: "codex",
            id: "codex-c1",
            startsHub: false
        )
        #expect(picked.take(budget: 1_000_000).reports.count == 1)
        #expect(claimant(pickedForCodex) == "codex-c1")
        let codex = ChatSession(
            paths: paths,
            folder: folder,
            extraApps: [],
            agent: "codex",
            id: "codex-t1",
            startsHub: false
        )
        #expect(codex.takeAddressed() != nil)
        #expect(claimant(addressedToCodex) == "codex-t1")
        // The new chat's report waits for the chat the hub starts.
        #expect(claimant(pickedForNewChat) == nil)
    }

    @Test func aChatOnAnotherAppNeverGetsTheReport() throws {
        _ = try inboxReport("20261003-223449")
        let other = root.appending(path: "Other", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try "PRODUCT_BUNDLE_IDENTIFIER: com.example.other".write(
            to: other.appending(path: "project.yml"),
            atomically: true,
            encoding: .utf8
        )
        #expect(session(other).take(budget: 1_000_000).reports.isEmpty)
    }

    @Test func theMoreRecentChatGetsTheReportEvenAfterEarlierChanges() async throws {
        let folder = try project()
        let older = ChatSession(
            paths: paths,
            folder: folder,
            extraApps: [],
            agent: "test",
            id: "older",
            startsHub: false
        )
        older.registerWaiting()
        // Used a minute ago: saved times have whole seconds.
        var record = older.chat
        record.lastActiveAt = Date.now.addingTimeInterval(-60)
        try Chats.register(record, paths: paths)
        let recent = ChatSession(
            paths: paths,
            folder: folder,
            extraApps: [],
            agent: "test",
            id: "recent",
            startsHub: false
        )
        recent.registerWaiting()
        _ = try inboxReport("20261003-231000")
        // A change the older chat's wait already counted, left over from before.
        let waiter = ChatSession.Waiter()
        waiter.wake()
        // The more recent chat takes it during the older one's deferral.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { _ = recent.take(budget: 1_000_000) }
        let tookIt = await offPool { older.waitForRoutedReport(timeout: 2, waiter: waiter) }
        #expect(!tookIt)
        #expect(older.take(budget: 1_000_000).reports.isEmpty)
    }

    @Test func waitingReturnsWhenAReportArrives() async throws {
        let chat = session(try project())
        let waiter = ChatSession.Waiter()
        let started = Date.now
        async let arrived = offPool { chat.waitForReport(timeout: 30, waiter: waiter) }
        try await Task.sleep(for: .milliseconds(300))
        try inboxReport("20261003-230000")
        #expect(await arrived)
        // Woken by the report arriving, long before the timeout.
        #expect(Date.now.timeIntervalSince(started) < 10)
        #expect(chat.take(budget: 1_000_000).reports.count == 1)
        // Nothing more: a short wait ends with no report.
        #expect(await offPool { !chat.waitForReport(timeout: 0.2, waiter: ChatSession.Waiter()) })
    }

    @Test func anotherHookKeepsTheChatsWaiter() throws {
        let folder = root.appending(path: "App", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let waiting = ChatSession(
            paths: paths,
            folder: folder,
            extraApps: ["com.example.app"],
            agent: "claude",
            id: "claude-s1",
            startsHub: false
        )
        waiting.registerWaiting()
        // A prompt hook, in another process, saves the same chat without a waiter of its own.
        let prompt = ChatSession(
            paths: paths,
            folder: folder,
            extraApps: ["com.example.app"],
            agent: "claude",
            id: "claude-s1",
            startsHub: false
        )
        prompt.touch()
        let saved = try #require(Chats.record("claude-s1", paths: paths))
        #expect(saved.waiter == getpid())
        #expect(saved.isWaiting)
        // A waiter that's gone doesn't count.
        var gone = saved
        gone.waiter = Int32.max
        #expect(!gone.isWaiting)
    }

    @Test func hooksSavingAtOnceKeepTheChatsWaiter() throws {
        let folder = root.appending(path: "App", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let paths = self.paths
        // Each stands in for a hook's own process: the file lock is per open file, not per process.
        DispatchQueue.concurrentPerform(iterations: 40) { index in
            let hook = ChatSession(
                paths: paths,
                folder: folder,
                extraApps: ["com.example.app"],
                agent: "claude",
                id: "claude-s1",
                startsHub: false
            )
            if index == 20 { hook.registerWaiting() } else { hook.touch() }
        }
        #expect(try #require(Chats.record("claude-s1", paths: paths)).waiter == getpid())
    }

    @Test func anotherReportWaitsWhenItsTextMightNotFit() throws {
        let folder = try inboxReport("20261003-223449")
        try ("# UI report\n\n1. **Log**: " + String(repeating: "é", count: 200_000)).write(
            to: folder.appending(path: "report.md"),
            atomically: true,
            encoding: .utf8
        )
        try inboxReport("20261003-223500")
        let taken = session(try project()).take(budget: ReportContent.longestText + 30)
        #expect(taken.reports.count == 1)
        #expect(taken.remaining == 1)
    }
}
#endif
