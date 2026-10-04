#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import RedlineTool

struct HubTests {
    private let temporary = TemporaryFolder("HubTests")
    private var paths: HubPaths { HubPaths(root: temporary.url) }
    private let phone = "00000000-0000000000000001"
    private let app = "com.example.app"

    /// A hub that's never started: no listener, no simulators, no devicectl.
    private func hub() throws -> Hub {
        try FileManager.default.createDirectory(at: paths.hub, withIntermediateDirectories: true)
        return Hub(
            paths: paths,
            devicectl: Devicectl(executable: URL(filePath: "/usr/bin/true")),
            apps: [app],
            claudeChats: { [] }
        )
    }

    private func offer(token: String, reports: [HubMessage.Offer.Report]) -> HubMessage.Offer {
        HubMessage.Offer(device: phone, bundleID: app, token: token, reports: reports)
    }

    @Test func onlySafeNamesBecomeFiles() {
        #expect(Hub.isSafeName("20261004-031600"))
        #expect(Hub.isSafeName("screen-1.jpg"))
        for name in ["", ".hidden", "../escape", "a/b", "a b", "~home"] {
            #expect(!Hub.isSafeName(name), "\(name) should be turned down")
        }
    }

    @Test func tokensMatchOnlyWhenEqual() {
        #expect(Hub.constantTimeEquals("abc123", "abc123"))
        #expect(!Hub.constantTimeEquals("abc123", "abc124"))
        #expect(!Hub.constantTimeEquals("abc", "abc123"))
        #expect(Hub.constantTimeEquals("", ""))
    }

    @Test func anAppStaysWatchedAfterItsLastChatCloses() throws {
        let hub = try hub()
        let other = "com.example.other"
        let chat = ChatSession(paths: paths, folder: paths.root, extraApps: [other], agent: "test", startsHub: false)
        chat.register()
        hub.updateApps(isStarting: true)
        #expect(hub.apps.contains(other))
        chat.unregister()
        hub.updateApps(isStarting: true)
        #expect(hub.apps.contains(other))
    }

    @Test func aTokenOutlivesTheHub() throws {
        let first = try hub()
        let token = first.issueToken(device: phone, bundleID: app)
        // Files are written on the hub's writer queue.
        first.flushWrites()
        #expect(token.count == 64)
        #expect(try hub().issueToken(device: phone, bundleID: app) == token)
        let permissions = try FileManager.default.attributesOfItem(atPath: paths.tokens.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func anUnreadableStateFileIsMovedAsideNotWrittenOver() throws {
        try FileManager.default.createDirectory(at: paths.hub, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: paths.state)
        let hub = try hub()
        // Filing a report saves the state.
        let source = ReportSource(
            kind: .phone,
            device: phone,
            deviceName: "Test iPhone",
            bundleID: app,
            reportID: "20261004-031600",
            receivedAt: .now
        )
        try hub.receive(source) { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true) }
        hub.flushWrites()
        let names = try FileManager.default.contentsOfDirectory(atPath: paths.hub.path)
        let aside = try #require(names.first { $0.hasPrefix("state-unreadable-") && $0.hasSuffix(".json") })
        #expect(try Data(contentsOf: paths.hub.appending(path: aside)) == Data("not json".utf8))
        // A fresh state.json was written beside it.
        #expect(names.contains("state.json"))
    }

    @Test func aReportWhoseSourceCantBeSavedIsNotFiled() throws {
        let hub = try hub()
        let source = ReportSource(
            kind: .phone,
            device: phone,
            deviceName: "Test iPhone",
            bundleID: app,
            reportID: "20261004-031600",
            receivedAt: .now
        )
        // The copy works, but source.json can't be written: a folder is in its place.
        #expect(throws: (any Error).self) {
            try hub.receive(source) { destination in
                try FileManager.default.createDirectory(
                    at: destination.appending(path: "source.json"),
                    withIntermediateDirectories: true
                )
            }
        }
        let inbox = paths.inbox.appending(path: app)
        #expect(try FileManager.default.contentsOfDirectory(atPath: inbox.path).isEmpty)
        // Not counted as delivered, so it's offered again.
        #expect(
            hub.reportIDsToCopy(
                device: phone,
                bundleID: app,
                finished: [FinishedReport(id: "20261004-031600", finishedAt: Date.now)]
            ) == ["20261004-031600"]
        )
        // Queued writes land before the test's folder is removed.
        hub.flushWrites()
    }

    @Test func aPhoneNoLongerPairedLeavesTheStatus() async throws {
        let hub = try hub()
        let kept = Devicectl.Phone(udid: phone, name: "Test iPhone", model: "iPhone 17 Pro")
        let unpaired = Devicectl.Phone(udid: "00000000-0000000000000002", name: "Old iPhone", model: "iPhone 15")
        hub.phoneDidChange(kept, state: .ready(apps: [app]))
        hub.phoneDidChange(unpaired, state: .ready(apps: [app]))
        hub.forgetPhones(except: [phone])
        #expect(hub.statusSnapshot().phones.map(\.udid) == [phone])

        // A link whose phone was unpaired stops trying, and so never reports the phone again.
        let link = PhoneLink(phone: unpaired, hub: hub)
        await withCheckedContinuation { done in link.unpair { done.resume() } }
        link.update(hosts: ["192.168.1.2"], port: 47361, includingNewApps: true)
        link.phoneDidWake()
        await withCheckedContinuation { done in link.unpair { done.resume() } }
        #expect(hub.statusSnapshot().phones.map(\.udid) == [phone])
        hub.flushWrites()
    }

    @Test func reportsSentBeforeTheHubSetTheAppUpAreTakenNotJustSettled() throws {
        let hub = try hub()
        let token = hub.issueToken(device: phone, bundleID: app)
        // Sent a day before any Mac gave the app its address, offered now that one has.
        let early = offer(
            token: token,
            reports: [.init(id: "20261003-120000", finishedAt: Date.now.addingTimeInterval(-86_400))]
        )
        let first = hub.answerNow(early)
        #expect(first.want == ["20261003-120000"])
        // Not confirmed until the hub has it.
        #expect(first.delivered.isEmpty)
        try hub.storeNow(
            HubMessage.Upload(id: "20261003-120000", files: ["report.json": Data("{}".utf8)]),
            offeredIn: early
        )
        #expect(hub.answerNow(early).delivered == ["20261003-120000"])
        hub.flushWrites()
    }

    @Test func reportsReceivedInTheSameSecondShowNewestFirst() throws {
        let hub = try hub()
        let second = Date(timeIntervalSince1970: 1_791_000_000)
        // Named so that their names sort the other way from when they arrived.
        for (id, offset) in [("b-first", 0.2), ("a-second", 0.7)] {
            let source = ReportSource(
                kind: .phone,
                device: phone,
                deviceName: "Test iPhone",
                bundleID: app,
                reportID: id,
                receivedAt: second.addingTimeInterval(offset)
            )
            try hub.receive(source) {
                try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
            }
        }
        let rows = HubWindowModel.readReports(paths: paths).rows
        #expect(rows.map(\.folder.lastPathComponent) == ["a-second-00000001", "b-first-00000001"])
        hub.flushWrites()
    }

    @Test func anIPv6OnlyNetworkCountsAsANetwork() {
        func ipv6(_ text: String) -> in6_addr {
            var address = in6_addr()
            #expect(inet_pton(AF_INET6, text, &address) == 1)
            return address
        }
        #expect(Hub.isOnNetwork(ipv6("2001:db8::1")))
        #expect(Hub.isOnNetwork(ipv6("fd12:3456:789a::1")))
        // Every interface that's up has one of these, network or not.
        #expect(!Hub.isOnNetwork(ipv6("fe80::1")))
        #expect(!Hub.isOnNetwork(ipv6("febf::1")))
        #expect(!Hub.isOnNetwork(ipv6("::")))
        // On a network, the `.local` name is last, after any IPv4 address.
        let hosts = Hub.addresses()
        #expect(hosts.isEmpty || hosts.last?.hasSuffix(".local") == true)
    }

    @Test func chatsOpenTheNewestInstalledCopyOfTheMenuBarApp() throws {
        func install(_ folder: String, builtAt date: Date) throws -> URL {
            let app = paths.root.appending(path: "\(folder)/Redline.app", directoryHint: .isDirectory)
            let program = app.appending(path: "Contents/MacOS/redline")
            try FileManager.default.createDirectory(
                at: program.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: program)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: program.path)
            return app
        }
        let home = try install("home/Applications", builtAt: Date.now.addingTimeInterval(-86_400))
        let system = try install("Applications", builtAt: .now)
        let trashed = try install(".Trash", builtAt: Date.now.addingTimeInterval(60))
        let missing = paths.root.appending(path: "Elsewhere/Redline.app", directoryHint: .isDirectory)
        // Installed in ~/Applications first, then in /Applications: the later install opens.
        #expect(HubProcess.newestApp(among: [home, system, trashed, missing]) == system)
        #expect(HubProcess.newestApp(among: [home, missing]) == home)
        #expect(HubProcess.newestApp(among: [missing]) == nil)
    }

    @Test func anOpenClaudeChatsAppIsWatched() throws {
        try FileManager.default.createDirectory(at: paths.hub, withIntermediateDirectories: true)
        let project = paths.root.appending(path: "claude-project", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "targets:\n  App:\n    settings:\n      PRODUCT_BUNDLE_IDENTIFIER: com.example.claude\n"
            .write(to: project.appending(path: "project.yml"), atomically: true, encoding: .utf8)
        let session = ClaudeSessions.Session(id: "s1", folder: project.path, socket: "/tmp/none", updatedAt: .now)
        let hub = Hub(
            paths: paths,
            devicectl: Devicectl(executable: URL(filePath: "/usr/bin/true")),
            apps: [],
            claudeChats: { [session] }
        )
        hub.updateApps(isStarting: true)
        #expect(hub.apps == ["com.example.claude"])
        // Claude Code runs no hooks: the app is noted for it, so it stays watched once the chat closes.
        #expect(ProjectHistory.all(paths)["com.example.claude"]?.agent == "claude")
    }

    @Test func chatsNotingTheirAppsAtOnceKeepEachOthers() {
        let paths = self.paths
        // Each stands in for a chat's own process: the file lock is per open file, not per process.
        DispatchQueue.concurrentPerform(iterations: 40) { index in
            let chat = ChatRecord(
                id: "c\(index)",
                agent: "test",
                folder: "/p\(index)",
                bundleIDs: ["com.example.app\(index)"],
                pid: getpid(),
                registeredAt: .now,
                lastActiveAt: .now
            )
            #expect(throws: Never.self) { try ProjectHistory.note(chat, paths: paths) }
        }
        #expect(ProjectHistory.all(paths).count == 40)
    }

    @Test func aSimulatorReportWithALinkIsNotTaken() throws {
        let files = FileManager.default
        let folder = paths.root.appending(path: "copied", directoryHint: .isDirectory)
        try files.createDirectory(at: folder.appending(path: "draft"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appending(path: "report.json"))
        try Data("# Hi".utf8).write(to: folder.appending(path: "draft/report.md"))
        #expect(SimulatorWatcher.holdsOnlyFilesAndFolders(folder))
        // A link to a file elsewhere on the Mac, at any depth.
        try files.createSymbolicLink(
            atPath: folder.appending(path: "draft/new-chat-output.jsonl").path,
            withDestinationPath: "/etc/hosts"
        )
        #expect(!SimulatorWatcher.holdsOnlyFilesAndFolders(folder))
        try files.removeItem(at: folder.appending(path: "draft/new-chat-output.jsonl"))
        // A hard link shares the file it names, so writing to it writes there.
        let outside = paths.root.appending(path: "outside.txt")
        try Data("secret".utf8).write(to: outside)
        try files.linkItem(at: outside, to: folder.appending(path: "report.md"))
        #expect(!SimulatorWatcher.holdsOnlyFilesAndFolders(folder))
        try files.removeItem(at: folder.appending(path: "report.md"))
        #expect(SimulatorWatcher.holdsOnlyFilesAndFolders(folder))
        // The report folder itself a link.
        let linked = paths.root.appending(path: "linked")
        try files.createSymbolicLink(at: linked, withDestinationURL: folder)
        #expect(!SimulatorWatcher.holdsOnlyFilesAndFolders(linked))
    }

    @Test func aReportArrivingTwiceAtOnceIsFiledOnce() throws {
        let hub = try hub()
        let source = ReportSource(
            kind: .phone,
            device: phone,
            deviceName: "Test iPhone",
            bundleID: app,
            reportID: "20261004-031600",
            receivedAt: .now
        )
        let failures = Mutex(0)
        DispatchQueue.concurrentPerform(iterations: 8) { attempt in
            do {
                try hub.receive(source) { destination in
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                    try Data("{\"attempt\":\(attempt)}".utf8).write(to: destination.appending(path: "report.json"))
                }
            } catch {
                failures.withLock { $0 += 1 }
            }
        }
        #expect(failures.withLock { $0 } == 0)
        let folder = paths.inbox.appending(path: app, directoryHint: .isDirectory)
        let name = Inbox.folderName(reportID: source.reportID, device: phone)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [name])
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: folder.appending(path: name).path).sorted() == [
                "report.json", "source.json",
            ]
        )
        hub.flushWrites()
        let state = try HubPaths.decoder.decode([String: SourceState].self, from: Data(contentsOf: paths.state))
        #expect(state["\(phone)|\(app)"]?.delivered == [source.reportID])
    }

    @Test func theStatusNamesTheAppsGivenOnTheCommandLine() throws {
        // The menu bar app taking over from this hub reads these and keeps watching them.
        #expect(try hub().statusSnapshot().fixedApps == [app])
    }

    @Test func anOfferWithoutTheRightTokenIsTurnedDown() throws {
        let hub = try hub()
        _ = hub.issueToken(device: phone, bundleID: app)
        let answer = hub.answerNow(offer(token: "guess", reports: [.init(id: "20261004-031600", finishedAt: .now)]))
        #expect(answer.refused != nil)
        #expect(answer.want.isEmpty)
        // An app this hub never gave an address to is turned down too.
        let stranger = HubMessage.Offer(device: "someone", bundleID: app, token: "x", reports: [])
        #expect(hub.answerNow(stranger).refused != nil)
        // Queued writes land before the test's folder is removed.
        hub.flushWrites()
    }

    @Test func theHubAsksOnlyForNewReportsAndFilesThemWhole() throws {
        let hub = try hub()
        let token = hub.issueToken(device: phone, bundleID: app)
        let old = HubMessage.Offer.Report(id: "20261002-135144", finishedAt: Date.now.addingTimeInterval(-86_400))
        let new = HubMessage.Offer.Report(id: "20261004-031600", finishedAt: .now)
        let offered = offer(token: token, reports: [old, new])
        // The old one was sent before this hub set the app up, and is still waiting for a Mac.
        try hub.storeNow(HubMessage.Upload(id: old.id, files: ["report.json": Data("{}".utf8)]), offeredIn: offered)
        let answer = hub.answerNow(offered)
        #expect(answer.refused == nil)
        #expect(answer.want == ["20261004-031600"])
        #expect(answer.delivered == ["20261002-135144"])

        // Unsafe file names and reports without their report.json are turned down.
        #expect(throws: Hub.FilingError.unusableUpload) {
            try hub.storeNow(
                HubMessage.Upload(id: new.id, files: ["../escape.jpg": Data([1]), "report.json": Data("{}".utf8)]),
                offeredIn: offered
            )
        }
        #expect(throws: Hub.FilingError.unusableUpload) {
            try hub.storeNow(HubMessage.Upload(id: new.id, files: ["screen-1.jpg": Data([1])]), offeredIn: offered)
        }

        let files = [
            "report.json": Data("{}".utf8), "report.md": Data("# Report".utf8), "screen-1.jpg": Data([0xFF, 0xD8]),
        ]
        try hub.storeNow(HubMessage.Upload(id: new.id, files: files), offeredIn: offered)
        let folder = paths.inbox.appending(path: "\(app)/20261004-031600-00000001", directoryHint: .isDirectory)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == [
                "report.json", "report.md", "screen-1.jpg", "source.json",
            ]
        )
        // Offered again, it's on the Mac now.
        let again = hub.answerNow(offered)
        #expect(again.want.isEmpty)
        #expect(Set(again.delivered) == ["20261002-135144", "20261004-031600"])
        // Queued writes land before the test's folder is removed.
        hub.flushWrites()
    }

    @Test func aStoppedHubHasSavedWhatItFiledAndTakesNoMore() throws {
        let hub = try hub()
        let token = hub.issueToken(device: phone, bundleID: app)
        let first = HubMessage.Offer.Report(id: "20261004-031600", finishedAt: .now)
        let second = HubMessage.Offer.Report(id: "20261004-031700", finishedAt: .now)
        let offered = offer(token: token, reports: [first, second])
        _ = hub.answerNow(offered)
        try hub.storeNow(HubMessage.Upload(id: first.id, files: ["report.json": Data("{}".utf8)]), offeredIn: offered)
        hub.stop()
        let saved = try HubPaths.decoder.decode([String: SourceState].self, from: Data(contentsOf: paths.state))
        #expect(saved.values.flatMap(\.delivered) == [first.id])
        // An upload that arrives after the stop is offered again to the next hub.
        #expect(throws: Hub.FilingError.stopping) {
            try hub.storeNow(
                HubMessage.Upload(id: second.id, files: ["report.json": Data("{}".utf8)]),
                offeredIn: offered
            )
        }
        let folder = paths.inbox.appending(path: "\(app)/20261004-031700-00000001", directoryHint: .isDirectory)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
}
#endif
