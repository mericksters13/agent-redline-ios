#if os(macOS)
import Foundation
import Testing
@testable import AgenticDebuggingTool

struct ChatTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: "ChatTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    private var paths: HubPaths { HubPaths(root: root.appending(path: "hub-root", directoryHint: .isDirectory)) }

    /// A project folder with Tiny Tally's two ways of setting bundle IDs.
    private func project() throws -> URL {
        let folder = root.appending(path: "TinyTally", directoryHint: .isDirectory)
        let files = FileManager.default
        try files.createDirectory(at: folder.appending(path: "App/App.xcodeproj"), withIntermediateDirectories: true)
        try files.createDirectory(at: folder.appending(path: "Pods/Vendor.xcodeproj"), withIntermediateDirectories: true)
        try "targets:\n  App:\n    settings:\n      PRODUCT_BUNDLE_IDENTIFIER: com.markbuot.AthenaTracker\n".write(to: folder.appending(path: "App/project.yml"), atomically: true, encoding: .utf8)
        try """
        { objects = {
            T1 = {isa = PBXNativeTarget; productType = "com.apple.product-type.application"; buildConfigurationList = L1; };
            L1 = {isa = XCConfigurationList; buildConfigurations = (C1); };
            C1 = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_BUNDLE_IDENTIFIER = com.markbuot.AthenaTracker; }; };
        }; }
        """.write(to: folder.appending(path: "App/App.xcodeproj/project.pbxproj"), atomically: true, encoding: .utf8)
        // Other people's code doesn't count.
        try """
        { objects = {
            T1 = {isa = PBXNativeTarget; productType = "com.apple.product-type.application"; buildConfigurationList = L1; };
            L1 = {isa = XCConfigurationList; buildConfigurations = (C1); };
            C1 = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_BUNDLE_IDENTIFIER = org.cocoapods.vendor; }; };
        }; }
        """.write(to: folder.appending(path: "Pods/Vendor.xcodeproj/project.pbxproj"), atomically: true, encoding: .utf8)
        return folder
    }

    /// A report in the inbox, filed the way the hub files it: filled under a hidden name, then
    /// renamed into place whole.
    private func inboxReport(_ id: String, bundleID: String = "com.markbuot.AthenaTracker", pictureBytes: Int = 10) throws -> URL {
        let final = paths.inbox.appending(path: "\(bundleID)/\(id)-0CF3C01C", directoryHint: .isDirectory)
        let folder = paths.inbox.appending(path: "\(bundleID)/.incoming-\(id)-0CF3C01C", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "# UI report: Tiny Tally\n\n1. **Milk stash**: Test.\n".write(to: folder.appending(path: "report.md"), atomically: true, encoding: .utf8)
        try #"{"screens":[{"images":[{"file":"screen-1.jpg"}]}],"items":[{"attachments":[]},{"attachments":["note-2.jpg"]}]}"#
            .write(to: folder.appending(path: "report.json"), atomically: true, encoding: .utf8)
        try Data(repeating: 0xFF, count: pictureBytes).write(to: folder.appending(path: "screen-1.jpg"))
        try Data(repeating: 0xD8, count: pictureBytes).write(to: folder.appending(path: "note-2.jpg"))
        let source = ReportSource(kind: .phone, device: "00008150-00123C360CF3C01C", deviceName: "Mark iPhone",
                                  bundleID: bundleID, reportID: id, receivedAt: Date(timeIntervalSince1970: 1_791_000_000))
        try Chats.coder.encode(source).write(to: folder.appending(path: "source.json"))
        try FileManager.default.moveItem(at: folder, to: final)
        return final
    }

    private func session(_ folder: URL) -> ChatSession {
        ChatSession(paths: paths, folder: folder, extraApps: [], agent: "test", startsHub: false)
    }

    @Test func onlyAppTargetsCountWithEveryConfigurationsID() throws {
        let pbxproj = """
        // !$*UTF8*$!
        {
          archiveVersion = 1;
          objects = {
            T1 = {isa = PBXNativeTarget; productType = "com.apple.product-type.application"; buildConfigurationList = L1; };
            L1 = {isa = XCConfigurationList; buildConfigurations = (C1, C2); };
            C1 = {isa = XCBuildConfiguration; name = Debug; buildSettings = {PRODUCT_BUNDLE_IDENTIFIER = com.example.app.debug; }; };
            C2 = {isa = XCBuildConfiguration; name = Release; buildSettings = {PRODUCT_BUNDLE_IDENTIFIER = com.example.app; }; };
            T2 = {isa = PBXNativeTarget; productType = "com.apple.product-type.app-extension"; buildConfigurationList = L2; };
            L2 = {isa = XCConfigurationList; buildConfigurations = (C3); };
            C3 = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_BUNDLE_IDENTIFIER = com.example.app.widgets; }; };
            T3 = {isa = PBXNativeTarget; productType = "com.apple.product-type.bundle.unit-test"; buildConfigurationList = L3; };
            L3 = {isa = XCConfigurationList; buildConfigurations = (C4); };
            C4 = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_BUNDLE_IDENTIFIER = "$(PRODUCT_NAME)Tests"; }; };
            T4 = {isa = PBXNativeTarget; productType = "com.apple.product-type.application"; buildConfigurationList = L4; };
            L4 = {isa = XCConfigurationList; buildConfigurations = (C5); };
            C5 = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_BUNDLE_IDENTIFIER = com.example.app.watchkitapp; SDKROOT = watchos; }; };
          };
        }
        """
        // Debug builds often have their own ID, and the kit runs only in Debug builds.
        #expect(ProjectApps.appBundleIDs(inProject: Data(pbxproj.utf8)) == ["com.example.app", "com.example.app.debug"])
    }

    @Test func bundleIDsSetInXcconfigFilesAndFromOtherSettingsAreFound() throws {
        let folder = root.appending(path: "Configured", directoryHint: .isDirectory)
        let config = folder.appending(path: "Config", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder.appending(path: "App.xcodeproj"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try """
        // Shared by every target.
        APP_BUNDLE_ID = com.example.$(PRODUCT_NAME:rfc1034identifier)
        PRODUCT_BUNDLE_IDENTIFIER[sdk=macosx*] = com.example.mac
        """.write(to: config.appending(path: "Shared.xcconfig"), atomically: true, encoding: .utf8)
        try """
        #include "Shared.xcconfig"
        PRODUCT_BUNDLE_IDENTIFIER = $(APP_BUNDLE_ID) // the App Store ID
        """.write(to: config.appending(path: "App.xcconfig"), atomically: true, encoding: .utf8)
        try """
        // !$*UTF8*$!
        {
          archiveVersion = 1;
          rootObject = P1;
          objects = {
            P1 = {isa = PBXProject; mainGroup = G1; buildConfigurationList = L0; };
            L0 = {isa = XCConfigurationList; buildConfigurations = (C0); };
            C0 = {isa = XCBuildConfiguration; name = Debug; buildSettings = {SDKROOT = iphoneos; }; };
            G1 = {isa = PBXGroup; sourceTree = "<group>"; children = (G2); };
            G2 = {isa = PBXGroup; path = Config; sourceTree = "<group>"; children = (F1); };
            F1 = {isa = PBXFileReference; path = App.xcconfig; sourceTree = "<group>"; };
            T1 = {isa = PBXNativeTarget; name = "My App"; productType = "com.apple.product-type.application"; buildConfigurationList = L1; };
            L1 = {isa = XCConfigurationList; buildConfigurations = (C1, C2); };
            C1 = {isa = XCBuildConfiguration; name = Debug; baseConfigurationReference = F1; buildSettings = {PRODUCT_BUNDLE_IDENTIFIER = "$(APP_BUNDLE_ID).debug"; }; };
            C2 = {isa = XCBuildConfiguration; name = Release; baseConfigurationReference = F1; buildSettings = {}; };
            T2 = {isa = PBXNativeTarget; name = Other; productType = "com.apple.product-type.application"; buildConfigurationList = L2; };
            L2 = {isa = XCConfigurationList; buildConfigurations = (C3); };
            C3 = {isa = XCBuildConfiguration; name = Debug; buildSettings = {PRODUCT_BUNDLE_IDENTIFIER = "$(UNDEFINED_ID)"; }; };
          };
        }
        """.write(to: folder.appending(path: "App.xcodeproj/project.pbxproj"), atomically: true, encoding: .utf8)
        // A setting that names one nobody sets can't be worked out, so it's left out.
        #expect(ProjectApps.bundleIDs(in: folder) == ["com.example.My-App", "com.example.My-App.debug"])
    }

    @Test func settingReferencesAreFilledInAsXcodeDoes() {
        let settings = ["TARGET_NAME": "Tiny Tally", "PRODUCT_NAME": "$(TARGET_NAME)", "BASE": "com.example"]
        #expect(ProjectApps.expand("${BASE}.$(PRODUCT_NAME:rfc1034identifier:lower)", with: settings) == "com.example.tiny-tally")
        #expect(ProjectApps.expand("$(inherited)com.example.app", with: settings) == "com.example.app")
        #expect(ProjectApps.expand("$(MISSING).app", with: settings) == nil)
        // A setting that refers to itself doesn't loop.
        #expect(ProjectApps.expand("$(LOOP)", with: ["LOOP": "$(LOOP)"]) == nil)
    }

    @Test func withoutAnXcodeProjectTheSpecsIDsCountLessTests() throws {
        let folder = root.appending(path: "Spec", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "PRODUCT_BUNDLE_IDENTIFIER: com.trailxyz.trail\nPRODUCT_BUNDLE_IDENTIFIER: com.trail.TrailTests\n"
            .write(to: folder.appending(path: "project.yml"), atomically: true, encoding: .utf8)
        #expect(ProjectApps.bundleIDs(in: folder) == ["com.trailxyz.trail"])
    }

    @Test func aProjectsAppIsFoundInItsXcodeProject() throws {
        #expect(ProjectApps.bundleIDs(in: try project()) == ["com.markbuot.AthenaTracker"])
    }

    @Test func aChatOutsideAnAppProjectStaysOut() throws {
        let notes = root.appending(path: "Notes", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        session(notes).register(agent: "claude-code")
        #expect(Chats.live(paths).isEmpty)
    }

    @Test func onlyOneChatTakesAReport() throws {
        let folder = try project()
        _ = try inboxReport("20261003-223449")
        let first = session(folder), second = session(folder)
        #expect(first.take(budget: 1_000_000).taken == 1)
        #expect(second.take(budget: 1_000_000).taken == 0)
        let report = try #require(InboxQueue.reports(for: ["com.markbuot.AthenaTracker"], paths: paths).first)
        #expect(report.claim?.chat == first.chat.id)
    }

    @Test func aReportAnInterruptedHandOverClaimedIsFreeAgain() throws {
        let folder = try project()
        let inbox = try inboxReport("20261003-223449")
        // A process that has ended stands in for a chat's server that crashed mid hand-over.
        let ended = Process()
        ended.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try ended.run()
        ended.waitUntilExit()
        let stranded = Claim(chat: "gone", agent: "test", folder: folder.path, claimedAt: Date(), handingOverIn: ended.processIdentifier)
        try Chats.coder.encode(stranded).write(to: inbox.appending(path: InboxQueue.claimFile))
        #expect(InboxQueue.waiting(for: ["com.markbuot.AthenaTracker"], paths: paths).count == 1)

        let chat = session(folder)
        #expect(chat.take(budget: 1_000_000).taken == 1)
        let report = try #require(InboxQueue.reports(for: ["com.markbuot.AthenaTracker"], paths: paths).first)
        #expect(report.claim?.chat == chat.chat.id)
        // Handed over: the claim stands for good, and no other chat takes the report.
        #expect(report.claim?.handingOverIn == nil)
        #expect(session(folder).take(budget: 1_000_000).taken == 0)
    }

    @Test func aProcessThatReusedTheHandOversPIDDoesntHoldTheReport() throws {
        let folder = try project()
        let inbox = try inboxReport("20261003-223449")
        // This test's process stands in for a later process that got the crashed hand-over's PID:
        // it started long after the claim was made.
        let reused = Claim(chat: "gone", agent: "test", folder: folder.path, claimedAt: Date(timeIntervalSince1970: 0), handingOverIn: getpid())
        #expect(reused.isInterrupted)
        try Chats.coder.encode(reused).write(to: inbox.appending(path: InboxQueue.claimFile))
        #expect(InboxQueue.waiting(for: ["com.markbuot.AthenaTracker"], paths: paths).count == 1)
        // The process that made the claim, still handing the report over, holds it.
        #expect(!Claim(chat: "here", agent: "test", folder: folder.path, claimedAt: Date(), handingOverIn: getpid()).isInterrupted)
    }

    @Test func aTrailChatNeverGetsATinyTallyReport() throws {
        _ = try inboxReport("20261003-223449")
        let trail = root.appending(path: "Trail", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: trail, withIntermediateDirectories: true)
        try "PRODUCT_BUNDLE_IDENTIFIER: com.trailxyz.trail".write(to: trail.appending(path: "project.yml"), atomically: true, encoding: .utf8)
        #expect(session(trail).take(budget: 1_000_000).taken == 0)
    }

    @Test func picturesFollowTheSummaryInItsOrderWithinTheBudget() throws {
        let folder = try inboxReport("20261003-223449", pictureBytes: 600)
        #expect(ReportContent.pictures(in: folder).map(\.lastPathComponent) == ["screen-1.jpg", "note-2.jpg"])
        let report = try #require(InboxQueue.reports(for: ["com.markbuot.AthenaTracker"], paths: paths).first)
        let content = ReportContent.items(for: report, budget: 1_200)
        // The summary, then the first picture; the second doesn't fit and is named by path.
        guard case .text(let summary) = content.items[0] else { Issue.record("No summary first"); return }
        #expect(content.bytes == summary.utf8.count + 600)
        #expect(summary.contains("from Mark iPhone (iPhone)"))
        #expect(summary.contains("1. **Milk stash**: Test."))
        #expect(content.items.contains { if case .image(let file, _) = $0 { file.lastPathComponent == "screen-1.jpg" } else { false } })
        #expect(content.items.contains { if case .text(let text) = $0 { text.contains("note-2.jpg isn't attached") } else { false } })
    }

    @Test func aLongPastedNoteStaysWithinTheReplyBudget() throws {
        let folder = try inboxReport("20261003-223449")
        try ("# UI report\n\n1. **Log**: " + String(repeating: "é", count: 200_000)).write(to: folder.appending(path: "report.md"), atomically: true, encoding: .utf8)
        _ = try inboxReport("20261003-223500")
        let report = try #require(InboxQueue.reports(for: ["com.markbuot.AthenaTracker"], paths: paths).first)
        let content = ReportContent.items(for: report, budget: 700_000)
        guard case .text(let summary) = content.items[0] else { Issue.record("No summary first"); return }
        #expect(summary.utf8.count <= ReportContent.longestText)
        #expect(summary.hasSuffix("The rest is in \(folder.path)/report.md."))
        #expect(content.bytes == summary.utf8.count + 20)
        // Text counts toward the budget: the second report waits when its text might not fit.
        let taken = session(try project()).take(budget: ReportContent.longestText + 30)
        #expect(taken.taken == 1)
        #expect(taken.remaining == 1)
    }

    @Test func theMCPServerHandsOverReportsWithTheirPictures() throws {
        let server = MCPServer(session: session(try project()))
        let initialized = server.respond(to: ["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                              "params": ["protocolVersion": "2025-06-18", "clientInfo": ["name": "claude-code"]]])
        let result = initialized?["result"] as? [String: Any]
        #expect((result?["serverInfo"] as? [String: Any])?["name"] as? String == "agentic-debugging")
        #expect(Chats.live(paths).first?.agent == "claude-code")

        let tools = (server.respond(to: ["jsonrpc": "2.0", "id": 2, "method": "tools/list"])?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        #expect(tools?.compactMap { $0["name"] as? String } == ["check_messages", "wait_for_message"])

        _ = try inboxReport("20261003-223449")
        let call: [String: Any] = ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "check_messages", "arguments": [String: Any]()]]
        let content = ((server.respond(to: call)?["result"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
        #expect(content.first?["type"] as? String == "text")
        #expect(content.filter { $0["type"] as? String == "image" }.count == 2)
        #expect(content.first { $0["type"] as? String == "image" }?["mimeType"] as? String == "image/jpeg")

        // Taken: a second check finds nothing.
        let again = ((server.respond(to: call)?["result"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
        #expect((again.first?["text"] as? String)?.hasPrefix("No reports waiting") == true)
    }

    @Test func waitingReturnsWhenAReportArrives() throws {
        let chat = session(try project())
        let waiter = ChatSession.Waiter()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { _ = try? self.inboxReport("20261003-230000") }
        let started = Date()
        #expect(chat.waitForReport(timeout: 5, waiter: waiter))
        // Woken by the report arriving, not by the timeout.
        #expect(Date().timeIntervalSince(started) < 2)
        #expect(chat.take(budget: 1_000_000).taken == 1)
        // Nothing more: a short wait ends with no report.
        #expect(!chat.waitForReport(timeout: 0.2, waiter: ChatSession.Waiter()))
    }

    @Test func aPIDTakenByALaterProcessDoesNotKeepAChatOpen() throws {
        let started = try #require(Chats.startTime(of: getpid()))
        #expect(started <= Date())
        #expect(Chats.isRunning(getpid(), since: Date()))
        // Registered before this process started: the chat's process is gone and its PID reused.
        #expect(!Chats.isRunning(getpid(), since: started.addingTimeInterval(-60)))

        var chat = session(try project()).chat
        chat.registeredAt = started.addingTimeInterval(-60)
        try Chats.register(chat, paths: paths)
        #expect(Chats.live(paths).isEmpty)
        #expect(Chats.record(chat.id, paths: paths) == nil)
    }
}
#endif
