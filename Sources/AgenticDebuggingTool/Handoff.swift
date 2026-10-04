#if os(macOS)
import Foundation

/// Where a report goes.
enum Destination: Equatable {
    /// An open chat: the one the user picked on the phone, or the only chat working in the
    /// worktree the app was built from.
    case chat(Agent, id: String)
    /// A new chat, in a worktree of its own made from the one the app was built from: picked on
    /// the phone, or because no chat works there. `pick` names the phone's "New chat" pick: the
    /// first report with it starts the chat, later ones go to that chat.
    case newChat(Agent, folder: String, pick: String?)
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
            /// Names a "New chat" pick, so its later reports go to the chat its first one started.
            var newChat: String?
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
            return .newChat(agent, folder: worktree, pick: pick.newChat)
        }
        guard let worktree else { return .undecided("The report doesn't say which worktree the app was built from") }
        let directory = list(bundleID, listing?.app.sourceFile)
        let here = directory.chats.filter(\.sameWorktree)
        if here.count == 1, let chat = here.first, let agent = Agent(rawValue: chat.agent) { return .chat(agent, id: chat.id) }
        if here.isEmpty, let agent = directory.agents.first.flatMap(Agent.init(rawValue:)) { return .newChat(agent, folder: worktree, pick: nil) }
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
        case .newChat(let agent, let folder, let pick):
            // The chat this pick started for an earlier report, while its worktree exists.
            if let pick, let started = StartedChats.find(pick, paths: paths) {
                switch agent {
                case .codex: sendToCodex(report, thread: started.chat)
                case .claude: sendToClaude(report, session: started.chat, worktree: started.folder)
                case .cursor: startChat(agent, in: started.folder, for: report, resuming: started.chat)
                }
            } else if agent == .claude, !ClaudeCLI.ready() {
                // Without a signed-in claude command, only the desktop app's draft is possible.
                openClaudeChat(in: folder, for: report, pick: pick)
            } else {
                startChat(agent, in: folder, for: report, pick: pick)
            }
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
            // Continued where it left off, then reopened where the user uses Claude Code.
            if let worktree, ClaudeCLI.ready() {
                startChat(.claude, in: worktree, for: report, resuming: id)
            } else if let worktree {
                openClaudeChat(in: worktree, for: report, pick: nil)
            }
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

    /// Opens a terminal window in `folder` running `command`, with `arguments` and then `last`,
    /// through a `.command` file: it opens in the user's terminal and needs no permission to
    /// control one. `last` goes through a file, so no quoting can break it.
    @discardableResult
    static func openTerminal(in folder: String, running command: String, arguments: [String] = [], with last: String) -> Bool {
        let scripts = URL(fileURLWithPath: folder).appending(path: ".agentic-debugging", directoryHint: .isDirectory)
        let name = "chat-\(UUID().uuidString.prefix(8))"
        let lastFile = scripts.appending(path: "\(name).txt")
        let script = scripts.appending(path: "\(name).command")
        do {
            try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
            let ignore = scripts.appending(path: ".gitignore")
            if !FileManager.default.fileExists(atPath: ignore.path) { try "*\n".write(to: ignore, atomically: true, encoding: .utf8) }
            try last.write(to: lastFile, atomically: true, encoding: .utf8)
            try terminalScript(folder: folder, command: command, arguments: arguments, lastFile: lastFile.path).write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        } catch {
            return false
        }
        open(script.path)
        return true
    }

    /// The script a terminal runs: into the folder, read the last argument from its file, remove
    /// the file and the script, then run the command.
    static func terminalScript(folder: String, command: String, arguments: [String], lastFile: String) -> String {
        func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return [
            "#!/bin/zsh",
            "cd \(quoted(folder)) || exit 1",
            "last=\"$(cat \(quoted(lastFile)))\"",
            "rm -f \(quoted(lastFile)) \"$0\"",
            "exec \(([command] + arguments).map(quoted).joined(separator: " ")) \"$last\"",
        ].joined(separator: "\n") + "\n"
    }

    /// Runs a command in a folder and waits for it.
    static func run(_ executable: String, _ arguments: [String], in folder: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: folder)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    private static func open(_ link: String) {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = [link]
        try? open.run()
        open.waitUntilExit()
    }

    /// Opens a new Claude Code chat wherever the user uses Claude Code. In the desktop app, the
    /// app's new chat screen opens on the repository with the report filled in: the app makes the
    /// chat, and its worktree, only when the user presses Return, and doesn't send for anyone. In
    /// a terminal, `claude` starts at once with the report, in a worktree the hub makes from main
    /// with the report's files copied in. Once the chat starts, it's remembered for the pick, and
    /// later reports go straight into it, the same way in both.
    private func openClaudeChat(in folder: String, for report: InboxReport, pick: String?) {
        let source = report.source
        let desktop = ClaudeSessions.usesDesktopApp()
        let workFolder: String
        if desktop {
            // The app ignores a worktree folder in a link and makes its own from the repository.
            guard let repository = NewWorktree.repository(of: folder) else {
                hub.log("\(folder) isn't in a git repository; report \(source.reportID) waits in the inbox")
                return
            }
            workFolder = repository
        } else {
            guard let made = NewWorktree.create(from: folder, name: "report-\(source.reportID)", agent: .claude) else {
                hub.log("Couldn't make a worktree from \(folder) for report \(source.reportID); it waits in the inbox")
                Self.notify(title: "Report from \(source.deviceName)", message: "Couldn't make a worktree for a new chat. The report waits in the inbox.")
                return
            }
            workFolder = made
        }
        let chat = ChatRecord(id: "started-claude-\(report.folder.lastPathComponent)", agent: Agent.claude.rawValue, folder: workFolder,
                              bundleIDs: [source.bundleID], pid: getpid(), registeredAt: Date(), lastActiveAt: Date())
        guard InboxQueue.claim(report, for: chat) else { return }
        let files = desktop ? report.folder.path : (NewWorktree.copyReport(report.folder, into: workFolder) ?? report.folder.path)
        let prompt = "A UI report arrived from the user's \(source.kind == .phone ? "iPhone" : "simulator") through iOSAgenticDebuggingKit. "
            + "It's in \(files): read report.md there and open the pictures it lists. "
            + "Find the code for each noted element by its identifier or label, then tell me what you found and propose a fix before changing code."
        let opened = Date()
        if desktop {
            var link = URLComponents()
            link.scheme = "claude"
            link.host = "code"
            link.path = "/new"
            link.queryItems = [URLQueryItem(name: "folder", value: workFolder), URLQueryItem(name: "q", value: prompt)]
            guard let url = link.url?.absoluteString else { return }
            Self.open(url)
            hub.log("Opened the Claude app's new chat screen on \(workFolder) with report \(source.reportID); it starts when the user presses Return")
            Self.notify(title: "Report from \(source.deviceName)", message: "The Claude app has a new chat ready: press Return to start it. To start new chats by themselves, run claude auth login once.")
        } else {
            guard let claude = AgentCommand.locate(.claude), Self.openTerminal(in: workFolder, running: claude.path, with: prompt) else {
                try? FileManager.default.removeItem(at: report.folder.appending(path: InboxQueue.claimFile))
                hub.log("Couldn't open a terminal for a new Claude Code chat for report \(source.reportID); it waits in the inbox")
                return
            }
            hub.log("Opened a new Claude Code chat in a terminal in \(workFolder) for report \(source.reportID)")
            Self.notify(title: "Report from \(source.deviceName)", message: "A new Claude Code chat is looking into it in Terminal.")
        }
        // Once the chat starts, later reports with the same pick go to it: in the desktop app, the
        // first chat started in the repository after the screen opened.
        let paths = hub.paths
        queue.async {
            for _ in 0..<300 {
                let started = ClaudeSessions.open().first { session in
                    desktop ? session.startedAt >= opened.addingTimeInterval(-2) && NewWorktree.repository(of: session.folder) == workFolder
                        : Worktree.root(of: session.folder) == workFolder
                }
                if let started {
                    if let pick { StartedChats.remember(StartedChat(chat: started.id, folder: started.folder, at: Date()), for: pick, paths: paths) }
                    self.hub.log("The new Claude Code chat \(started.id) for report \(source.reportID) started in \(started.folder)")
                    return
                }
                Thread.sleep(forTimeInterval: 2)
            }
            self.hub.log("The new Claude Code chat for report \(source.reportID) wasn't started within 10 minutes")
        }
    }

    /// Starts a chat with the report. A new chat gets a worktree of its own made from `folder`,
    /// the worktree the app was built from; `resuming` continues a chat the hub started before,
    /// in its own worktree. `pick` is the phone's "New chat" pick, remembered with the new chat.
    private func startChat(_ agent: Agent, in folder: String, for report: InboxReport, pick: String? = nil, resuming: String? = nil) {
        let source = report.source
        guard let executable = AgentCommand.locate(agent) else {
            hub.log("Couldn't find \(agent.name)'s command to start a chat for report \(source.reportID)")
            Self.notify(title: "Report from \(source.deviceName)", message: "Couldn't find \(agent.name) to start a chat. The report waits in the inbox.")
            return
        }
        let chat = ChatRecord(id: "started-\(agent.rawValue)-\(report.folder.lastPathComponent)", agent: agent.rawValue, folder: folder,
                              bundleIDs: [source.bundleID], pid: getpid(), registeredAt: Date(), lastActiveAt: Date())
        guard InboxQueue.claim(report, for: chat) else { return }

        // A new chat works in a worktree of its own; a continued one is already in its own.
        let workFolder: String
        var madeWorktree = false
        if resuming == nil, let made = NewWorktree.create(from: folder, name: "report-\(source.reportID)", agent: agent) {
            workFolder = made
            madeWorktree = true
            hub.log("Made worktree \(made) for report \(source.reportID)")
        } else {
            workFolder = folder
        }
        let pictures = ReportContent.pictures(in: report.folder)
        var prompt = AgentHooks.reportPrompt(ReportContent.text(for: report), picturesAttached: agent == .codex)
        // A Claude Code chat reads the pictures from a copy in its worktree, without asking.
        if agent == .claude, resuming == nil, madeWorktree, let copy = NewWorktree.copyReport(report.folder, into: workFolder) {
            prompt = prompt.replacingOccurrences(of: report.folder.path, with: copy)
        }
        let output = report.folder.appending(path: "new-chat-output.jsonl")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let process = Process()
        process.executableURL = executable
        process.arguments = AgentCommand.arguments(agent, folder: workFolder, prompt: prompt, pictures: pictures, resuming: resuming)
        process.currentDirectoryURL = URL(fileURLWithPath: workFolder)
        process.environment = ProcessInfo.processInfo.environment.merging([AgentHooks.startedByHub: "1"]) { $1 }
        process.standardInput = FileHandle.nullDevice
        if let handle = try? FileHandle(forWritingTo: output) {
            process.standardOutput = handle
            process.standardError = handle
        }
        let paths = hub.paths
        let place = Self.folderName(workFolder)
        let madeWorktreeForThis = madeWorktree
        process.terminationHandler = { [hub] finished in
            let text = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
            let started = AgentCommand.startedChat(agent, in: text)
            guard finished.terminationStatus == 0, let started, !started.failed else {
                // Free the report for a chat that opens later, and take back the unused worktree.
                try? FileManager.default.removeItem(at: report.folder.appending(path: InboxQueue.claimFile))
                if madeWorktreeForThis { NewWorktree.remove(workFolder) }
                let reason = AgentCommand.failure(in: text)
                hub.log("The \(agent.name) chat for report \(source.reportID) failed (\(finished.terminationStatus)): \(reason)")
                Handoff.notify(title: "Couldn't start a \(agent.name) chat", message: "\(reason). The report waits in the inbox.")
                return
            }
            // Later reports with the same pick go to this chat.
            if let pick { StartedChats.remember(StartedChat(chat: started.chat, folder: workFolder, at: Date()), for: pick, paths: paths) }
            if let answer = started.answer {
                try? answer.write(to: report.folder.appending(path: "answer.md"), atomically: true, encoding: .utf8)
            }
            if agent == .codex {
                // Shown where the user uses Codex: the Codex app, or a terminal.
                if CodexThreads.usesDesktopApp() {
                    Handoff.open("codex://threads/\(started.chat)")
                } else {
                    Handoff.openTerminal(in: workFolder, running: executable.path, arguments: ["resume"], with: started.chat)
                }
                hub.log("The Codex chat \(started.chat) in \(workFolder) looked into report \(source.reportID)")
                Handoff.notify(title: "Codex looked into a report", message: "Opened in Codex, in worktree \(place).")
            } else if agent == .claude {
                // Moved where the user uses Claude Code, with what it found so far.
                if ClaudeSessions.usesDesktopApp() {
                    Handoff.run(executable.path, ["--desktop", "--resume", started.chat], in: workFolder)
                } else {
                    Handoff.openTerminal(in: workFolder, running: executable.path, arguments: ["--resume"], with: started.chat)
                }
                hub.log("The Claude Code chat \(started.chat) in \(workFolder) looked into report \(source.reportID) and was opened")
                Handoff.notify(title: "Claude Code looked into a report", message: "Opened in \(ClaudeSessions.usesDesktopApp() ? "the Claude app" : "Terminal"), in worktree \(place).")
            } else {
                hub.log("The \(agent.name) chat \(started.chat) in \(workFolder) looked into report \(source.reportID)")
                Handoff.notify(title: "\(agent.name) looked into a report", message: "Its answer is in the report's folder, answer.md. Worktree \(place).")
            }
        }
        do {
            try process.run()
            hub.log("\(resuming == nil ? "Started" : "Continued") a \(agent.name) chat in \(workFolder) for report \(source.reportID)")
            Self.notify(title: "\(agent.name) is looking into a report", message: "From \(source.deviceName), in worktree \(place).")
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
    /// Codex's desktop app, inside the ChatGPT app or on its own.
    static var hasCodexApp: Bool {
        ["/Applications/ChatGPT.app/Contents/Resources/codex-cli", "/Applications/Codex.app"].contains { FileManager.default.fileExists(atPath: $0) }
    }

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

    static func arguments(_ agent: Agent, folder: String, prompt: String, pictures: [URL] = [], resuming: String? = nil) -> [String] {
        switch agent {
        case .claude:
            ["-p", prompt, "--permission-mode", "plan", "--output-format", "json"] + (resuming.map { ["--resume", $0] } ?? [])
        // Pictures go in with the prompt; "--" ends them, so the prompt isn't read as one.
        case .codex:
            ["exec", "-C", folder, "--sandbox", "read-only", "--skip-git-repo-check", "--json"]
                + pictures.flatMap { ["-i", $0.path] } + ["--", prompt]
        // Without --force, Cursor's command line only proposes changes.
        case .cursor:
            ["-p", "--workspace", folder, "--output-format", "json", prompt] + (resuming.map { ["--resume", $0] } ?? [])
        }
    }

    /// The chat a command line run started or continued, its answer when it gives one, and
    /// whether the run reported an error: `codex exec --json`'s first event, or the result
    /// `claude -p --output-format json` prints.
    static func startedChat(_ agent: Agent, in output: String) -> (chat: String, answer: String?, failed: Bool)? {
        for line in output.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if agent == .codex, object["type"] as? String == "thread.started", let thread = object["thread_id"] as? String {
                return (thread, nil, false)
            }
            if agent != .codex, let session = object["session_id"] as? String ?? object["chatId"] as? String {
                return (session, object["result"] as? String, object["is_error"] as? Bool ?? false)
            }
        }
        return nil
    }

    /// Why a run failed, in the agent's own words where it gives them.
    static func failure(in output: String) -> String {
        for line in output.split(separator: "\n").reversed() {
            if let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] {
                if let result = object["result"] as? String, !result.isEmpty { return result }
                if let error = (object["error"] as? [String: Any])?["message"] as? String ?? object["message"] as? String { return error }
                continue
            }
            let text = line.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { return String(text.prefix(200)) }
        }
        return "It stopped without saying why"
    }

}
#endif
