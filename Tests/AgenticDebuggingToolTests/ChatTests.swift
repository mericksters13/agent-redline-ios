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
        let content = ReportContent.items(for: report, budget: 1_000)
        // The summary, then the first picture; the second doesn't fit and is named by path.
        #expect(content.bytes == 600)
        guard case .text(let summary) = content.items[0] else { Issue.record("No summary first"); return }
        #expect(summary.contains("from Mark iPhone (iPhone)"))
        #expect(summary.contains("1. **Milk stash**: Test."))
        #expect(content.items.contains { if case .image(let file, _) = $0 { file.lastPathComponent == "screen-1.jpg" } else { false } })
        #expect(content.items.contains { if case .text(let text) = $0 { text.contains("note-2.jpg isn't attached") } else { false } })
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
}
#endif
