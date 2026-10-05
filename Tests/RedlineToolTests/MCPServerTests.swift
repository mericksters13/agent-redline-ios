#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import RedlineTool

struct MCPServerTests {
    private let temporary = TemporaryFolder("MCPServerTests")
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

    /// A report in the inbox with a screen snapshot and one attached to a note, `snapshotBytes` each.
    @discardableResult
    private func inboxReport(_ id: String, bundleID: String = "com.example.app", snapshotBytes: Int = 10) throws -> URL
    {
        let listing: [String: Any] = [
            "screens": [["images": [["file": "screen-1.jpg"]]]],
            "items": [["attachments": [String]()], ["attachments": ["note-2.jpg"]]],
        ]
        return try fileInboxReport(
            "\(id)-00000001",
            bundleID: bundleID,
            in: paths,
            listing: listing,
            snapshots: [
                "screen-1.jpg": Data(repeating: 0xFF, count: snapshotBytes),
                "note-2.jpg": Data(repeating: 0xD8, count: snapshotBytes),
            ],
            summary: "# UI report: Example\n\n1. **Milk stash**: Test.\n",
            receivedAt: Date(timeIntervalSince1970: 1_791_000_000)
        )
    }

    private func session(_ folder: URL) -> ChatSession {
        ChatSession(paths: paths, folder: folder, extraApps: [], agent: "test", startsHub: false)
    }

    /// Collects the server's responses, as each one's first text ("" when it has none), and
    /// wakes a test when one arrives.
    private final class Responses: Sendable {
        private let texts = Mutex<[Int: String]>([:])
        private let arrived = DispatchSemaphore(value: 0)

        func take(_ data: Data) {
            guard let line = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let id = line["id"] as? Int
            else { return }
            let content = (line["result"] as? [String: Any])?["content"] as? [[String: Any]]
            texts.withLock { $0[id] = content?.first?["text"] as? String ?? "" }
            arrived.signal()
        }

        /// The response to request `id`, waiting up to `timeout` seconds for it.
        func response(to id: Int, timeout: TimeInterval) -> String? {
            let deadline = Date.now.addingTimeInterval(timeout)
            while true {
                if let text = texts.withLock({ $0[id] }) { return text }
                guard arrived.wait(timeout: .now() + deadline.timeIntervalSinceNow) == .success else { return nil }
            }
        }
    }

    private func line(_ message: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self)
    }

    @Test func theMCPServerHandsOverReportsWithTheirSnapshots() throws {
        let server = MCPServer(session: session(try project()))
        let initialized = server.respond(to: [
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-06-18", "clientInfo": ["name": "claude-code"]],
        ]).message
        let result = initialized["result"] as? [String: Any]
        #expect((result?["serverInfo"] as? [String: Any])?["name"] as? String == "redline")
        #expect(Chats.removeClosedChats(paths).first?.agent == "claude-code")

        let tools =
            (server.respond(to: ["jsonrpc": "2.0", "id": 2, "method": "tools/list"]).message["result"] as? [String: Any])?[
                "tools"
            ] as? [[String: Any]]
        #expect(tools?.compactMap { $0["name"] as? String } == ["check_messages", "wait_for_message"])

        _ = try inboxReport("20261003-223449")
        let call: [String: Any] = [
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": ["name": "check_messages", "arguments": [String: Any]()],
        ]
        let checked = server.respond(to: call)
        let content = ((checked.message["result"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
        #expect(content.first?["type"] as? String == "text")
        #expect(content.count(where: { $0["type"] as? String == "image" }) == 2)
        #expect(content.first { $0["type"] as? String == "image" }?["mimeType"] as? String == "image/jpeg")

        // Taken: a second check finds nothing.
        #expect(checked.reports.count == 1)
        let again =
            ((server.respond(to: call).message["result"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
        #expect((again.first?["text"] as? String)?.hasPrefix("No reports waiting") == true)
    }

    @Test func aReportWhoseResponseCantBeWrittenIsFreedAgain() async throws {
        struct Closed: Error {}
        let server = MCPServer(session: session(try project())) { _ in throw Closed() }
        try inboxReport("20261003-223449")
        let call: [String: Any] = [
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": ["name": "check_messages", "arguments": [String: Any]()],
        ]
        server.receive(try line(call))
        await offPool { server.finish() }
        // The chat never got it, so it can take it again.
        #expect(Inbox.unclaimedReports(for: ["com.example.app"], paths: paths).count == 1)
        #expect(Inbox.claim(of: try #require(Inbox.reports(for: nil, paths: paths).first).folder) == nil)
    }

    @Test func aWaitStopsWhenCancelledAndNeverHoldsUpOtherRequests() async throws {
        let responses = Responses()
        let server = MCPServer(session: session(try project())) { responses.take($0) }
        let wait: [String: Any] = [
            "jsonrpc": "2.0", "id": 7, "method": "tools/call",
            "params": ["name": "wait_for_message", "arguments": ["timeout_seconds": 30]],
        ]
        server.receive(try line(wait))
        // Other requests are answered while the wait goes on.
        server.receive(try line(["jsonrpc": "2.0", "id": 8, "method": "ping"]))
        #expect(await offPool { responses.response(to: 8, timeout: 5) } != nil)
        #expect(await offPool { responses.response(to: 7, timeout: 0.2) } == nil)
        // Cancelled, the wait answers at once instead of after 30 seconds.
        server.receive(try line(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 7]]))
        let answered = await offPool { responses.response(to: 7, timeout: 5) }
        #expect(answered?.hasPrefix("No report arrived") == true)
        await offPool { server.finish() }
    }

    @Test func unknownToolsAndMethodsAreErrors() throws {
        let server = MCPServer(session: session(try project())) { _ in }
        let tool = server.respond(to: [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "no_such_tool"],
        ]).message
        #expect((tool["error"] as? [String: Any])?["code"] as? Int == -32602)
        let method = server.respond(to: ["jsonrpc": "2.0", "id": 2, "method": "no/such/method"]).message
        #expect((method["error"] as? [String: Any])?["code"] as? Int == -32601)
    }

    @Test func aWaitIsAtLeastOneSecond() async throws {
        let responses = Responses()
        let server = MCPServer(session: session(try project())) { responses.take($0) }
        let wait: [String: Any] = [
            "jsonrpc": "2.0", "id": 5, "method": "tools/call",
            "params": ["name": "wait_for_message", "arguments": ["timeout_seconds": 0.01]],
        ]
        server.receive(try line(wait))
        #expect(await offPool { responses.response(to: 5, timeout: 5) } == "No report arrived in 1 seconds.")
        await offPool { server.finish() }
    }

    @Test func aCancelSentRightAfterAWaitStopsIt() async throws {
        let responses = Responses()
        let server = MCPServer(session: session(try project())) { responses.take($0) }
        let wait: [String: Any] = [
            "jsonrpc": "2.0", "id": 9, "method": "tools/call",
            "params": ["name": "wait_for_message", "arguments": ["timeout_seconds": 30]],
        ]
        server.receive(try line(wait))
        server.receive(try line(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 9]]))
        #expect(await offPool { responses.response(to: 9, timeout: 5) } != nil)
        await offPool { server.finish() }
    }
}
#endif
