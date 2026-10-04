#if os(macOS)
import Foundation
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
        return Hub(paths: paths, devicectl: Devicectl(executable: URL(filePath: "/usr/bin/true")), apps: [app])
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
        hub.startTrackingIfNeeded(device: phone, bundleID: app)
        hub.flushWrites()
        let names = try FileManager.default.contentsOfDirectory(atPath: paths.hub.path)
        let aside = try #require(names.first { $0.hasPrefix("state.json.unreadable-") })
        #expect(try Data(contentsOf: paths.hub.appending(path: aside)) == Data("not json".utf8))
        // A fresh state.json was written beside it.
        #expect(names.contains("state.json"))
    }

    @Test func aReportWhoseSourceCantBeSavedIsNotFiled() throws {
        let hub = try hub()
        let source = ReportSource(kind: .phone, device: phone, deviceName: "Test iPhone", bundleID: app, reportID: "20261004-031600", receivedAt: .now)
        // The copy works, but source.json can't be written: a folder is in its place.
        #expect(throws: (any Error).self) {
            try hub.receive(source) { destination in
                try FileManager.default.createDirectory(at: destination.appending(path: "source.json"), withIntermediateDirectories: true)
            }
        }
        let inbox = paths.inbox.appending(path: app)
        #expect(try FileManager.default.contentsOfDirectory(atPath: inbox.path).isEmpty)
        // Not counted as delivered, so it's offered again.
        hub.startTrackingIfNeeded(device: phone, bundleID: app)
        #expect(hub.reportIDsToCopy(device: phone, bundleID: app, finished: [FinishedReport(id: "20261004-031600", finishedAt: Date.now)]) == ["20261004-031600"])
        // Queued writes land before the test's folder is removed.
        hub.flushWrites()
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
        let answer = hub.answerNow(offered)
        #expect(answer.refused == nil)
        #expect(answer.want == ["20261004-031600"])
        // From before the hub first looked: the app can stop offering it.
        #expect(answer.delivered == ["20261002-135144"])

        // Unsafe file names and reports without their report.json are turned down.
        #expect(throws: Hub.FilingError.unusableUpload) {
            try hub.storeNow(HubMessage.Upload(id: new.id, files: ["../escape.jpg": Data([1]), "report.json": Data("{}".utf8)]), offeredIn: offered)
        }
        #expect(throws: Hub.FilingError.unusableUpload) { try hub.storeNow(HubMessage.Upload(id: new.id, files: ["screen-1.jpg": Data([1])]), offeredIn: offered) }

        let files = ["report.json": Data("{}".utf8), "report.md": Data("# Report".utf8), "screen-1.jpg": Data([0xFF, 0xD8])]
        try hub.storeNow(HubMessage.Upload(id: new.id, files: files), offeredIn: offered)
        let folder = paths.inbox.appending(path: "\(app)/20261004-031600-00000001", directoryHint: .isDirectory)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["report.json", "report.md", "screen-1.jpg", "source.json"])
        // Offered again, it's on the Mac now.
        let again = hub.answerNow(offered)
        #expect(again.want.isEmpty)
        #expect(Set(again.delivered) == ["20261002-135144", "20261004-031600"])
        // Queued writes land before the test's folder is removed.
        hub.flushWrites()
    }
}
#endif
