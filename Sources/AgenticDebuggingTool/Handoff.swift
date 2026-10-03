#if os(macOS)
import Foundation

/// What happens to a report no open chat takes. If a chat on its project is open but can't be
/// woken, the report waits for that chat's next message and the Mac says so. If no chat is
/// open, the hub starts one with the agent last used on the project, which looks into the
/// report and proposes a fix without changing code.
final class Handoff: @unchecked Sendable {
    private unowned let hub: Hub
    private let queue = DispatchQueue(label: "handoff")

    /// How long a new report waits for an open chat to take it before the hub steps in.
    static let grace: TimeInterval = 10
    /// A chat not used for this long counts as closed, unless it's waiting for reports: some
    /// agents' chats live in a process that outlasts them.
    static let staleAfter: TimeInterval = 12 * 3600

    init(hub: Hub) {
        self.hub = hub
    }

    func reportFiled(_ folder: URL, source: ReportSource) {
        queue.asyncAfter(deadline: .now() + Self.grace) { [self] in
            guard let report = InboxQueue.waiting(for: [source.bundleID], paths: hub.paths).first(where: { $0.folder == folder }) else { return }
            handOver(report)
        }
    }

    private func handOver(_ report: InboxReport) {
        let source = report.source
        let open = Chats.live(hub.paths).filter { chat in
            chat.bundleIDs.contains(source.bundleID) && (chat.isWaiting || Date().timeIntervalSince(chat.lastActiveAt) < Self.staleAfter)
        }
        if let chat = open.max(by: { $0.lastActiveAt < $1.lastActiveAt }) {
            let name = Agent(rawValue: chat.agent)?.name ?? chat.agent
            hub.log("Report \(source.reportID) waits for the next message in the \(name) chat in \(chat.folder)")
            Self.notify(title: "Report from \(source.deviceName)", message: "Goes to the \(name) chat in \(Self.folderName(chat.folder)) with your next message.")
            return
        }
        guard let use = ProjectHistory.all(hub.paths)[source.bundleID], let agent = Agent(rawValue: use.agent) else {
            hub.log("Report \(source.reportID) waits: no chat has been open for \(source.bundleID) yet")
            Self.notify(title: "Report from \(source.deviceName)", message: "Open a Claude Code, Codex or Cursor chat in the app's project to get it.")
            return
        }
        startChat(agent, in: use.folder, for: report)
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
