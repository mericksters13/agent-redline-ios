#if os(macOS)
import Foundation

/// Where a report goes.
enum Destination: Equatable {
    /// An open chat: the one the user picked on the phone, or the only chat working in the
    /// worktree the app was built from.
    case chat(Agent, id: String)
    /// A new chat in the worktree the app was built from: picked on the phone, or because no
    /// chat works there.
    case newChat(Agent, folder: String)
    /// Nothing says where: several chats work in the worktree and none was picked, or the
    /// report doesn't say where the app was built. It waits in the inbox.
    case undecided(String)
}

enum Routing {
    /// What the phone saved with the report: the user's pick, and the worktree the app was
    /// built from.
    struct Listing: Decodable {
        struct App: Decodable { var sourceFile: String? }
        struct Pick: Decodable {
            var agent: String
            /// Nil for a new chat.
            var chat: String?
        }
        var app: App
        var destination: Pick?
    }

    static func worktree(of report: URL) -> String? {
        (try? Data(contentsOf: report.appending(path: "report.json"))).flatMap { try? JSONDecoder().decode(Listing.self, from: $0) }?
            .app.sourceFile.map(Worktree.root(of:))
    }

    static func destination(of report: URL, bundleID: String, paths: HubPaths,
                            list: (String, String?) -> HubMessage.ChatList) -> Destination {
        let listing = (try? Data(contentsOf: report.appending(path: "report.json"))).flatMap { try? JSONDecoder().decode(Listing.self, from: $0) }
        let worktree = listing?.app.sourceFile.map(Worktree.root(of:))
        if let pick = listing?.destination, let agent = Agent(rawValue: pick.agent) {
            if let chat = pick.chat { return .chat(agent, id: chat) }
            guard let worktree else { return .undecided("The report doesn't say which worktree the app was built from") }
            return .newChat(agent, folder: worktree)
        }
        guard let worktree else { return .undecided("The report doesn't say which worktree the app was built from") }
        let directory = list(bundleID, listing?.app.sourceFile)
        let here = directory.chats.filter(\.sameWorktree)
        if here.count == 1, let chat = here.first, let agent = Agent(rawValue: chat.agent) { return .chat(agent, id: chat.id) }
        if here.isEmpty, let agent = directory.agents.first.flatMap(Agent.init(rawValue:)) { return .newChat(agent, folder: worktree) }
        return .undecided("\(here.count) chats work in \(URL(fileURLWithPath: worktree).lastPathComponent); pick one on the phone")
    }
}

/// Sends each report where the user picked on the phone, or else to the chat working in the
/// worktree the app was built from. A Claude Code chat gets it through its socket, which
/// starts a turn even when the chat is idle. A Codex chat gets it through the Codex app with
/// its pictures attached. A Cursor chat gets it when its hooks next run. A new chat starts in
/// the worktree and looks into the report without changing code.
final class Handoff: @unchecked Sendable {
    private unowned let hub: Hub
    private let queue = DispatchQueue(label: "handoff")

    init(hub: Hub) {
        self.hub = hub
    }

    func reportFiled(_ folder: URL, source: ReportSource) {
        queue.async { [self] in
            guard let report = InboxQueue.waiting(for: [source.bundleID], paths: hub.paths).first(where: { $0.folder == folder }) else { return }
            deliver(report)
        }
    }

    /// Hands over reports that arrived shortly before the hub started and no chat took.
    func handOverRecent(within interval: TimeInterval = 3600) {
        queue.async { [self] in
            let apps = Set(Chats.live(hub.paths).flatMap(\.bundleIDs) + ProjectHistory.all(hub.paths).keys)
            for report in InboxQueue.waiting(for: Array(apps), paths: hub.paths)
            where Date().timeIntervalSince(report.source.receivedAt) < interval && InboxQueue.address(of: report.folder) == nil {
                deliver(report)
            }
        }
    }

    private func deliver(_ report: InboxReport) {
        let source = report.source
        let paths = hub.paths
        let destination = Routing.destination(of: report.folder, bundleID: source.bundleID, paths: paths) { bundleID, sourceFile in
            ChatDirectory.list(bundleID: bundleID, sourceFile: sourceFile, paths: paths)
        }
        let worktree = Routing.worktree(of: report.folder)
        switch destination {
        case .chat(.claude, let id):
            sendToClaude(report, session: id, worktree: worktree)
        case .chat(.codex, let id):
            sendToCodex(report, thread: id)
        case .chat(.cursor, let id):
            InboxQueue.setAddress(Address(chat: "cursor-\(id)", agent: Agent.cursor.rawValue, folder: worktree ?? ""), of: report.folder)
            InboxQueue.signal(source.bundleID, paths: paths)
            hub.log("Report \(source.reportID) goes to the Cursor chat \(id) when its hooks next run")
            Self.notify(title: "Report from \(source.deviceName)", message: "Goes to the Cursor chat after its next reply or with your next message there.")
        case .newChat(let agent, let folder):
            startChat(agent, in: folder, for: report)
        case .undecided(let reason):
            hub.log("Report \(source.reportID) waits in the inbox: \(reason)")
            Self.notify(title: "Report from \(source.deviceName)", message: "\(reason).")
        }
    }

    /// Puts the report into a Claude Code chat through its socket. If the chat closed, a new
    /// one starts in the worktree.
    private func sendToClaude(_ report: InboxReport, session id: String, worktree: String?) {
        let source = report.source
        guard let session = ClaudeSessions.open().first(where: { $0.id == id }) else {
            hub.log("The Claude Code chat for report \(source.reportID) is closed")
            if let worktree { startChat(.claude, in: worktree, for: report) }
            return
        }
        let chat = ChatRecord(id: "claude-\(id)", agent: Agent.claude.rawValue, folder: session.folder, bundleIDs: [source.bundleID],
                              pid: getpid(), registeredAt: Date(), lastActiveAt: Date())
        guard InboxQueue.claim(report, for: chat) else { return }
        let name = session.title ?? Self.folderName(session.folder)
        if ClaudeSessions.send(AgentHooks.reportPrompt(ReportContent.text(for: report)), to: session) {
            hub.log("Sent report \(source.reportID) to the Claude Code chat \(name), in \(session.folder)")
            Self.notify(title: "Report from \(source.deviceName)", message: "Sent to the Claude Code chat \(name).")
        } else {
            try? FileManager.default.removeItem(at: report.folder.appending(path: InboxQueue.claimFile))
            hub.log("The Claude Code chat \(name) didn't take report \(source.reportID); it waits in the inbox")
            Self.notify(title: "Report from \(source.deviceName)", message: "The Claude Code chat \(name) didn't take it. It waits in the inbox.")
        }
    }

    /// Starts a turn with the report, pictures attached, in a Codex chat. A chat no Codex window
    /// has open is opened first. If the app can't take it, the chat's own hook hands it over
    /// with the next message.
    private func sendToCodex(_ report: InboxReport, thread: String) {
        let source = report.source
        let chat = ChatRecord(id: "codex-\(thread)", agent: Agent.codex.rawValue, folder: "", bundleIDs: [source.bundleID], pid: getpid(),
                              registeredAt: Date(), lastActiveAt: Date())
        guard InboxQueue.claim(report, for: chat) else { return }
        let pictures = ReportContent.pictures(in: report.folder)
        let text = AgentHooks.reportPrompt(ReportContent.text(for: report), picturesAttached: true)
        var outcome = CodexApp.startTurn(thread: thread, text: text, pictures: pictures)
        if outcome == .notOpen {
            hub.log("The Codex chat for report \(source.reportID) isn't open; opening it")
            Self.open("codex://threads/\(thread)")
            Thread.sleep(forTimeInterval: 5)
            outcome = CodexApp.startTurn(thread: thread, text: text, pictures: pictures)
        }
        if outcome == .started {
            hub.log("Sent report \(source.reportID) with \(pictures.count) pictures to the Codex chat \(thread)")
            Self.notify(title: "Report from \(source.deviceName)", message: "Sent to the Codex chat, with its pictures.")
            return
        }
        try? FileManager.default.removeItem(at: report.folder.appending(path: InboxQueue.claimFile))
        InboxQueue.setAddress(Address(chat: chat.id, agent: chat.agent, folder: ""), of: report.folder)
        hub.log("The Codex app didn't take report \(source.reportID) (\(outcome)); it goes in with the chat's next message")
        Self.notify(title: "Report from \(source.deviceName)", message: "Goes to the Codex chat with your next message there.")
    }

    private static func open(_ link: String) {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = [link]
        try? open.run()
        open.waitUntilExit()
    }

    private func startChat(_ agent: Agent, in folder: String, for report: InboxReport) {
        let source = report.source
        guard let executable = AgentCommand.locate(agent) else {
            hub.log("Couldn't find \(agent.name)'s command to start a chat for report \(source.reportID)")
            Self.notify(title: "Report from \(source.deviceName)", message: "Couldn't find \(agent.name) to start a chat. The report waits in the inbox.")
            return
        }
        let chat = ChatRecord(id: "started-\(agent.rawValue)-\(report.folder.lastPathComponent)", agent: agent.rawValue, folder: folder,
                              bundleIDs: [source.bundleID], pid: getpid(), registeredAt: Date(), lastActiveAt: Date())
        guard InboxQueue.claim(report, for: chat) else { return }

        let pictures = ReportContent.pictures(in: report.folder)
        let prompt = AgentHooks.reportPrompt(ReportContent.text(for: report), picturesAttached: agent == .codex)
        let output = report.folder.appending(path: agent == .codex ? "new-chat.jsonl" : "answer.md")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let process = Process()
        process.executableURL = executable
        process.arguments = AgentCommand.arguments(agent, folder: folder, prompt: prompt, pictures: pictures)
        process.currentDirectoryURL = URL(fileURLWithPath: folder)
        process.environment = ProcessInfo.processInfo.environment.merging([AgentHooks.startedByHub: "1"]) { $1 }
        process.standardInput = FileHandle.nullDevice
        if let handle = try? FileHandle(forWritingTo: output) {
            process.standardOutput = handle
            process.standardError = handle
        }
        process.terminationHandler = { [hub] finished in
            let text = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
            let lastLine = text.split(separator: "\n").last.map(String.init) ?? ""
            guard finished.terminationStatus == 0 else {
                // Free the report for a chat that opens later.
                try? FileManager.default.removeItem(at: report.folder.appending(path: InboxQueue.claimFile))
                hub.log("The new \(agent.name) chat for report \(source.reportID) failed (\(finished.terminationStatus)): \(lastLine)")
                Self.notify(title: "Couldn't start a \(agent.name) chat", message: lastLine.isEmpty ? "The report waits in the inbox." : lastLine)
                return
            }
            if agent == .codex, let thread = AgentCommand.codexThread(in: text) {
                // Shown in the Codex app, where the user can carry on.
                Handoff.open("codex://threads/\(thread)")
                hub.log("The new Codex chat \(thread) looked into report \(source.reportID)")
                Handoff.notify(title: "Codex looked into a report", message: "Opened in Codex.")
            } else {
                hub.log("The new \(agent.name) chat finished with report \(source.reportID); its answer is in \(output.path)")
                Handoff.notify(title: "\(agent.name) looked into a report", message: "Its answer is in the report's folder: \(output.lastPathComponent)")
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

    static func arguments(_ agent: Agent, folder: String, prompt: String, pictures: [URL] = []) -> [String] {
        switch agent {
        case .claude: ["-p", prompt, "--permission-mode", "plan"]
        // Pictures go in with the prompt; "--" ends them, so the prompt isn't read as one.
        case .codex: ["exec", "-C", folder, "--sandbox", "read-only", "--skip-git-repo-check", "--json"]
            + pictures.flatMap { ["-i", $0.path] } + ["--", prompt]
        // Without --force, Cursor's command line only proposes changes.
        case .cursor: ["-p", "--workspace", folder, prompt]
        }
    }

    /// The new chat's ID, from `codex exec --json`'s first event.
    static func codexThread(in output: String) -> String? {
        for line in output.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["type"] as? String == "thread.started" else { continue }
            return object["thread_id"] as? String
        }
        return nil
    }
}
#endif
