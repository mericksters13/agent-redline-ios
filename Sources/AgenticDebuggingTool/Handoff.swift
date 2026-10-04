#if os(macOS)
import Foundation

/// Where a report goes: the chat that built the app it came from. The app sends its build's
/// UUIDs; the agents' hooks noted which chat built each one.
enum Destination: Equatable {
    /// The chat that built the app.
    case chat(BuildRecord)
    /// No chat built it (built in Xcode by hand, or before builds were noted): a new chat in
    /// the folder it was built from.
    case newChat(Agent, folder: String)
    /// Nothing tells where it's from, such as a report from an app with an older kit.
    case unknown
}

enum Routing {
    /// Reads where the report came from. `incoming` is its folder, before it's in the inbox.
    static func destination(of incoming: URL, bundleID: String, paths: HubPaths, roots: [URL]? = nil) -> Destination {
        struct Listing: Decodable {
            struct App: Decodable {
                var buildIDs: [String]?
                var sourceFile: String?
            }
            var app: App
        }
        let app = (try? Data(contentsOf: incoming.appending(path: "report.json"))).flatMap { try? JSONDecoder().decode(Listing.self, from: $0) }?.app
        let ids = app?.buildIDs ?? []
        if !ids.isEmpty, let build = Builds.find(ids, paths: paths) { return .chat(build) }
        let folder = (ids.isEmpty ? nil : Builds.folder(of: ids, bundleID: bundleID, roots: roots)) ?? app?.sourceFile.map(Builds.worktreeRoot)
        guard let folder else { return .unknown }
        let agent = ProjectHistory.all(paths)[bundleID].flatMap { Agent(rawValue: $0.agent) } ?? .claude
        return .newChat(agent, folder: folder)
    }
}

/// Sends each report to the chat that built the app it came from. An open Claude Code chat
/// gets it through its socket, which starts a turn even when the chat is idle. An open Codex
/// or Cursor chat gets it when its hooks next run: right away if the chat is waiting after a
/// reply, otherwise after its next reply or with the user's next message. If that chat is
/// closed, or no chat built the app, the hub starts a chat in the folder the app was built
/// from, which looks into the report and proposes a fix without changing code.
final class Handoff: @unchecked Sendable {
    private unowned let hub: Hub
    private let queue = DispatchQueue(label: "handoff")

    init(hub: Hub) {
        self.hub = hub
    }

    /// Decides where a report goes, before it appears in the inbox: a chat waiting for its
    /// reports sees it addressed the moment it arrives.
    func address(_ incoming: URL, source: ReportSource) -> Destination {
        let destination = Routing.destination(of: incoming, bundleID: source.bundleID, paths: hub.paths)
        if case .chat(let build) = destination {
            InboxQueue.setAddress(Address(chat: build.chat, agent: build.agent, folder: build.folder), of: incoming)
        }
        return destination
    }

    /// Delivers a report now in the inbox.
    func deliver(_ folder: URL, source: ReportSource, to destination: Destination) {
        queue.async { [self] in
            guard let report = InboxQueue.waiting(for: [source.bundleID], paths: hub.paths).first(where: { $0.folder == folder }) else { return }
            switch destination {
            case .chat(let build):
                deliver(report, to: build)
            case .newChat(let agent, let folder):
                hub.log("No chat built the app report \(source.reportID) came from; starting one in \(folder)")
                startChat(agent, in: folder, for: report)
            case .unknown:
                hub.log("Report \(source.reportID) doesn't say which build it came from; it waits in the inbox")
                Self.notify(title: "Report from \(source.deviceName)", message: "Rebuild the app with the newest kit so reports find the chat that built it.")
            }
        }
    }

    /// Hands over reports that arrived shortly before the hub started and no chat took.
    func handOverRecent(within interval: TimeInterval = 3600) {
        queue.async { [self] in
            let apps = Set(Chats.live(hub.paths).flatMap(\.bundleIDs) + ProjectHistory.all(hub.paths).keys)
            for report in InboxQueue.waiting(for: Array(apps), paths: hub.paths) where Date().timeIntervalSince(report.source.receivedAt) < interval {
                let destination = address(report.folder, source: report.source)
                // Already in the inbox: wake a chat waiting for it.
                InboxQueue.signal(report.source.bundleID, paths: hub.paths)
                deliver(report.folder, source: report.source, to: destination)
            }
        }
    }

    private func deliver(_ report: InboxReport, to build: BuildRecord) {
        let source = report.source
        guard let agent = Agent(rawValue: build.agent) else { return }
        let place = Self.folderName(build.folder)
        switch agent {
        case .claude:
            let sessionID = build.chat.replacingOccurrences(of: "claude-", with: "", options: .anchored)
            guard let session = ClaudeSessions.open().first(where: { $0.id == sessionID }) else {
                hub.log("The Claude Code chat that built report \(source.reportID)'s app is closed; starting one in \(build.folder)")
                startChat(.claude, in: build.folder, for: report)
                return
            }
            let chat = ChatRecord(id: build.chat, agent: build.agent, folder: build.folder, bundleIDs: [source.bundleID], pid: getpid(),
                                  registeredAt: Date(), lastActiveAt: Date())
            guard InboxQueue.claim(report, for: chat) else { return }
            if ClaudeSessions.send(AgentHooks.reportPrompt(ReportContent.text(for: report)), to: session) {
                hub.log("Sent report \(source.reportID) to the Claude Code chat that built it, in \(session.folder)")
                Self.notify(title: "Report from \(source.deviceName)", message: "Sent to the Claude Code chat that built the app, in \(place).")
            } else {
                try? FileManager.default.removeItem(at: report.folder.appending(path: InboxQueue.claimFile))
                hub.log("The Claude Code chat in \(session.folder) didn't take report \(source.reportID); it waits in the inbox")
                Self.notify(title: "Report from \(source.deviceName)", message: "The Claude Code chat in \(place) didn't take it. It waits in the inbox.")
            }
        case .codex:
            sendToCodex(report, build: build, place: place)
        case .cursor:
            guard let chat = Chats.live(hub.paths).first(where: { $0.id == build.chat }) else {
                hub.log("The Cursor chat that built report \(source.reportID)'s app is closed; starting one in \(build.folder)")
                startChat(.cursor, in: build.folder, for: report)
                return
            }
            // A chat waiting after a reply takes it the moment it's in the inbox.
            guard !chat.isWaiting else { return }
            hub.log("Report \(source.reportID) goes to the Cursor chat in \(build.folder) when its hooks next run")
            Self.notify(title: "Report from \(source.deviceName)",
                        message: "Goes to the Cursor chat that built the app, in \(place), after its next reply or with your next message there.")
        }
    }

    /// Starts a turn with the report, pictures attached, in the Codex chat that built the app.
    /// A chat that isn't open in a Codex window is opened first. If the app can't take it, the
    /// report goes in with the chat's next message.
    private func sendToCodex(_ report: InboxReport, build: BuildRecord, place: String) {
        let source = report.source
        let thread = build.chat.replacingOccurrences(of: "codex-", with: "", options: .anchored)
        let chat = ChatRecord(id: build.chat, agent: build.agent, folder: build.folder, bundleIDs: [source.bundleID], pid: getpid(),
                              registeredAt: Date(), lastActiveAt: Date())
        guard InboxQueue.claim(report, for: chat) else { return }
        let pictures = ReportContent.pictures(in: report.folder)
        let text = AgentHooks.reportPrompt(ReportContent.text(for: report), picturesAttached: true)
        var outcome = CodexApp.startTurn(thread: thread, text: text, pictures: pictures)
        if outcome == .notOpen, let link = URL(string: "codex://threads/\(thread)") {
            hub.log("The Codex chat for report \(source.reportID) isn't open; opening it")
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = [link.absoluteString]
            try? open.run()
            open.waitUntilExit()
            Thread.sleep(forTimeInterval: 5)
            outcome = CodexApp.startTurn(thread: thread, text: text, pictures: pictures)
        }
        if outcome == .started {
            hub.log("Sent report \(source.reportID) with \(pictures.count) pictures to the Codex chat that built it, in \(build.folder)")
            Self.notify(title: "Report from \(source.deviceName)", message: "Sent to the Codex chat that built the app, in \(place).")
            return
        }
        // The chat's own hooks hand it over with the next message.
        try? FileManager.default.removeItem(at: report.folder.appending(path: InboxQueue.claimFile))
        hub.log("The Codex app didn't take report \(source.reportID) (\(outcome)); it goes in with the chat's next message")
        Self.notify(title: "Report from \(source.deviceName)", message: "Goes to the Codex chat that built the app, in \(place), with your next message there.")
    }

    private func startChat(_ agent: Agent, in folder: String, for report: InboxReport) {
        let source = report.source
        guard let executable = AgentCommand.locate(agent) else {
            hub.log("Couldn't find \(agent.name)'s command to start a chat for report \(source.reportID)")
            Self.notify(title: "Report from \(source.deviceName)", message: "Couldn't find \(agent.name) to start a chat. Open one in \(Self.folderName(folder)).")
            return
        }
        let chat = ChatRecord(id: "started-\(agent.rawValue)-\(report.folder.lastPathComponent)", agent: agent.rawValue, folder: folder,
                              bundleIDs: [source.bundleID], pid: getpid(), registeredAt: Date(), lastActiveAt: Date())
        guard InboxQueue.claim(report, for: chat) else { return }

        let answer = report.folder.appending(path: "answer.md")
        FileManager.default.createFile(atPath: answer.path, contents: nil)
        let process = Process()
        process.executableURL = executable
        process.arguments = AgentCommand.arguments(agent, folder: folder, prompt: AgentHooks.reportPrompt(ReportContent.text(for: report)))
        process.currentDirectoryURL = URL(fileURLWithPath: folder)
        process.environment = ProcessInfo.processInfo.environment.merging([AgentHooks.startedByHub: "1"]) { $1 }
        process.standardInput = FileHandle.nullDevice
        if let output = try? FileHandle(forWritingTo: answer) {
            process.standardOutput = output
            process.standardError = output
        }
        process.terminationHandler = { [hub] finished in
            let text = (try? String(contentsOf: answer, encoding: .utf8)) ?? ""
            let lastLine = text.split(separator: "\n").last.map(String.init) ?? ""
            if finished.terminationStatus == 0 {
                hub.log("The \(agent.name) chat finished with report \(source.reportID); its answer is in \(answer.path)")
                Self.notify(title: "\(agent.name) looked into a report", message: "Its answer is in the report's folder: \(answer.lastPathComponent)")
            } else {
                // Free the report for the next chat that opens on the project.
                try? FileManager.default.removeItem(at: report.folder.appending(path: InboxQueue.claimFile))
                hub.log("The \(agent.name) chat for report \(source.reportID) failed (\(finished.terminationStatus)): \(lastLine)")
                Self.notify(title: "Couldn't start a \(agent.name) chat", message: lastLine.isEmpty ? "The report waits for a chat on the project." : lastLine)
            }
        }
        do {
            try process.run()
            hub.log("Started a \(agent.name) chat in \(folder) for report \(source.reportID)")
            Self.notify(title: "\(agent.name) is looking into a report", message: "From \(source.deviceName), in \(Self.folderName(folder)).")
        } catch {
            try? FileManager.default.removeItem(at: report.folder.appending(path: InboxQueue.claimFile))
            hub.log("Couldn't start a \(agent.name) chat for report \(source.reportID): \(error.localizedDescription)")
        }
    }

    private static func folderName(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    /// A Mac notification, through AppleScript so the tool needs no app bundle.
    static func notify(title: String, message: String) {
        func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "display notification \(quoted(message)) with title \(quoted(title))"]
        try? process.run()
    }
}

/// Starting a chat with each agent from the command line. Each runs without permission to
/// change files, so the chat can only look and propose.
enum AgentCommand {
    static func locate(_ agent: Agent) -> URL? {
        let home = NSHomeDirectory()
        let candidates: [String]
        switch agent {
        case .claude:
            candidates = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        case .codex:
            // The copy inside the ChatGPT app comes first: it updates with the app.
            candidates = ["/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                          "/Applications/Codex.app/Contents/Resources/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(home)/.local/bin/codex"]
        case .cursor:
            candidates = ["\(home)/.local/bin/cursor-agent", "\(home)/.local/bin/agent", "/opt/homebrew/bin/cursor-agent", "/usr/local/bin/cursor-agent"]
        }
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:))
    }

    static func arguments(_ agent: Agent, folder: String, prompt: String) -> [String] {
        switch agent {
        case .claude: ["-p", prompt, "--permission-mode", "plan"]
        case .codex: ["exec", "-C", folder, "--sandbox", "read-only", "--skip-git-repo-check", prompt]
        // Without --force, Cursor's command line only proposes changes.
        case .cursor: ["-p", "--workspace", folder, prompt]
        }
    }
}
#endif
