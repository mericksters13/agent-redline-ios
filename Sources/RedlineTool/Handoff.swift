#if os(macOS)
import Foundation
import UserNotifications

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
    static func worktree(of report: URL) -> String? {
        ReportListing.load(from: report)?.app?.sourceFile.map(Worktree.root(of:))
    }

    static func destination(of report: URL, bundleID: String, list: (String, String?) -> HubMessage.ChatList) -> Destination {
        // A listing without its app reads as if there were none, as it always has.
        let listing = ReportListing.load(from: report).flatMap { $0.app == nil ? nil : $0 }
        let worktree = listing?.app?.sourceFile.map(Worktree.root(of:))
        if let pick = listing?.destination, let agent = Agent(rawValue: pick.agent) {
            if let chat = pick.chat { return .chat(agent, id: chat) }
            guard let worktree else { return .undecided("The report doesn't say which worktree the app was built from") }
            return .newChat(agent, folder: worktree, pick: pick.newChat)
        }
        guard let worktree else { return .undecided("The report doesn't say which worktree the app was built from") }
        let directory = list(bundleID, listing?.app?.sourceFile)
        let here = directory.chats.filter(\.sameWorktree)
        if here.count == 1, let chat = here.first, let agent = Agent(rawValue: chat.agent) { return .chat(agent, id: chat.id) }
        if here.isEmpty, let agent = directory.agents.first.flatMap(Agent.init(rawValue:)) { return .newChat(agent, folder: worktree, pick: nil) }
        return .undecided("\(here.count) chats work in \(URL(fileURLWithPath: worktree).lastPathComponent); pick one on the phone")
    }
}

/// Sends each report where the user picked on the phone, or else to the chat working in the
/// worktree the app was built from. A Claude Code chat gets it through its socket, which
/// starts a turn even when the chat is idle. A Codex chat gets it through the Codex app with
/// its pictures attached. A new chat starts in the worktree and looks into the report without
/// changing code.
final class Handoff: Sendable {
    private unowned let hub: Hub
    private let queue = DispatchQueue(label: "Redline.hub.handoff", qos: .userInitiated)

    init(hub: Hub) {
        self.hub = hub
    }

    func reportFiled(_ folder: URL, source: ReportSource) {
        queue.async { [self] in
            guard let report = Inbox.waiting(for: [source.bundleID], paths: hub.paths).first(where: { $0.folder == folder }) else { return }
            deliver(report)
        }
    }

    /// Hands over reports that arrived shortly before the hub started and no chat took.
    func handOverRecent(within interval: TimeInterval = 3600) {
        queue.async { [self] in
            let apps = Set(Chats.live(hub.paths).flatMap(\.bundleIDs))
            for report in Inbox.waiting(for: Array(apps), paths: hub.paths)
            where Date().timeIntervalSince(report.source.receivedAt) < interval && Inbox.address(of: report.folder) == nil {
                deliver(report)
            }
        }
    }

    private func deliver(_ report: InboxReport) {
        let source = report.source
        let paths = hub.paths
        let destination = Routing.destination(of: report.folder, bundleID: source.bundleID) { bundleID, sourceFile in
            ChatDirectory.list(bundleID: bundleID, sourceFile: sourceFile, paths: paths)
        }
        let worktree = Routing.worktree(of: report.folder)
        switch destination {
        case .chat(.claude, let id):
            sendToClaude(report, session: id, worktree: worktree)
        case .chat(.codex, let id):
            sendToCodex(report, thread: id)
        case .newChat(let agent, let folder, let pick):
            // The chat this pick started for an earlier report, while its worktree exists.
            if let pick, let started = StartedChats.find(pick, paths: paths) {
                switch agent {
                case .codex: sendToCodex(report, thread: started.chat)
                case .claude: sendToClaude(report, session: started.chat, worktree: started.folder)
                }
            } else if agent == .claude, !ClaudeCLI.ready() {
                waitForClaudeSignIn(report)
            } else {
                startChat(agent, in: folder, for: report, pick: pick)
            }
        case .undecided(let reason):
            hub.log("Report \(source.reportID) waits in the inbox: \(reason)")
            record(.init(agent: nil, chat: nil, title: reason, kind: .waiting), for: report)
            Self.notify(title: Self.reportTitle(source), message: "\(reason).")
        }
    }

    /// Takes the report for a chat. False, after logging why when it isn't another chat that
    /// took it first, when the report can't be taken.
    private func claim(_ report: InboxReport, for chat: ChatRecord) -> Bool {
        switch Inbox.claim(report, for: chat) {
        case .claimed:
            return true
        case .takenByAnotherChat:
            return false
        case .failed(let error):
            hub.log("Couldn't take report \(report.source.reportID) for \(chat.id): \(error.localizedDescription)")
            return false
        }
    }

    /// Lets the report go again, for a chat that opens later.
    private func release(_ report: InboxReport) {
        do {
            try FileManager.default.removeItem(at: report.folder.appending(path: Inbox.claimFile))
        } catch {
            hub.log("Couldn't let report \(report.source.reportID) go for another chat: \(error.localizedDescription)")
        }
    }

    /// Saves where the report went, for the panel and the viewer.
    private func record(_ delivery: ReportDelivery, for report: InboxReport) {
        do {
            try ReportDelivery.save(delivery, in: report.folder)
        } catch {
            hub.log("Couldn't save where report \(report.source.reportID) went: \(error.localizedDescription)")
        }
    }

    /// A chat record for a chat the hub hands a report to, as the claim names it.
    private static func claimant(id: String, agent: Agent, folder: String, bundleID: String) -> ChatRecord {
        ChatRecord(id: id, agent: agent.rawValue, folder: folder, bundleIDs: [bundleID], pid: getpid(), registeredAt: Date(), lastActiveAt: Date())
    }

    /// The title of every notification about a report.
    private static func reportTitle(_ source: ReportSource) -> String {
        "Report from \(source.deviceName)"
    }

    /// Puts the report into a Claude Code chat through its socket. If the chat closed, a new
    /// one starts in the worktree.
    private func sendToClaude(_ report: InboxReport, session id: String, worktree: String?) {
        let source = report.source
        guard let session = ClaudeSessions.open().first(where: { $0.id == id }) else {
            hub.log("The Claude Code chat for report \(source.reportID) is closed")
            // Continued where it left off, then reopened in the desktop app.
            if let worktree, ClaudeCLI.ready() {
                let chat = Self.claimant(id: ChatID.make(.claude, id), agent: .claude, folder: worktree, bundleID: source.bundleID)
                guard claim(report, for: chat) else { return }
                openClaude(id, in: worktree, thenSend: ReportContent.text(for: report), for: report)
            } else if worktree != nil {
                waitForClaudeSignIn(report)
            }
            return
        }
        let chat = Self.claimant(id: ChatID.make(.claude, id), agent: .claude, folder: session.folder, bundleID: source.bundleID)
        guard claim(report, for: chat) else { return }
        let name = session.title ?? Self.folderName(session.folder)
        if ClaudeSessions.send(ReportContent.text(for: report), to: session) {
            hub.log("Sent report \(source.reportID) to the Claude Code chat \(name), in \(session.folder)")
            record(.init(agent: .claude, chat: id, title: name, kind: .sent), for: report)
            Self.notify(title: Self.reportTitle(source), message: "Sent to the Claude Code chat \(name).")
        } else {
            release(report)
            hub.log("The Claude Code chat \(name) didn't take report \(source.reportID); it waits in the inbox")
            Self.notify(title: Self.reportTitle(source), message: "The Claude Code chat \(name) didn't take it. It waits in the inbox.")
        }
    }

    /// Starts a turn with the report, pictures attached, in a Codex chat. A chat no Codex window
    /// has open is opened first. If the app can't take it, the chat's own hook hands it over
    /// with the next message.
    private func sendToCodex(_ report: InboxReport, thread: String) {
        let source = report.source
        let chat = Self.claimant(id: ChatID.make(.codex, thread), agent: .codex, folder: "", bundleID: source.bundleID)
        guard claim(report, for: chat) else { return }
        let pictures = ReportContent.pictures(in: report.folder)
        let text = ReportContent.text(for: report)
        var outcome = CodexApp.startTurn(thread: thread, text: text, pictures: pictures)
        if outcome == .notOpen {
            hub.log("The Codex chat for report \(source.reportID) isn't open; opening it")
            do {
                try Self.open(Self.appLink(.codex, id: thread, isClaudeAppInstalled: false, isCodexAppInstalled: true) ?? "codex://threads/\(thread)")
            } catch {
                hub.log("Couldn't open the Codex chat \(thread): \(error.localizedDescription)")
            }
            Thread.sleep(forTimeInterval: 5)
            outcome = CodexApp.startTurn(thread: thread, text: text, pictures: pictures)
        }
        if outcome == .started {
            hub.log("Sent report \(source.reportID) with \(pictures.count) pictures to the Codex chat \(thread)")
            record(.init(agent: .codex, chat: thread, title: CodexThreads.title(of: thread, in: CodexThreads.newestDatabase()) ?? "Codex chat", kind: .sent), for: report)
            Self.notify(title: Self.reportTitle(source), message: "Sent to the Codex chat, with its pictures.")
            return
        }
        do {
            // Addressed before it's let go, so no other chat takes it in between.
            try Inbox.setAddress(Address(chat: chat.id, agent: chat.agent, folder: ""), of: report.folder)
        } catch {
            hub.log("Couldn't address report \(source.reportID) to the Codex chat \(thread): \(error.localizedDescription)")
        }
        release(report)
        hub.log("The Codex app didn't take report \(source.reportID) (\(outcome)); it goes in with the chat's next message")
        record(.init(agent: .codex, chat: thread, title: CodexThreads.title(of: thread, in: CodexThreads.newestDatabase()) ?? "Codex chat", kind: .nextMessage), for: report)
        Self.notify(title: Self.reportTitle(source), message: "Goes to the Codex chat with your next message there.")
    }

    /// Opens a terminal window in `folder` running `command`, with `arguments` and then `last`,
    /// through a `.command` file: it opens in the user's terminal and needs no permission to
    /// control one. `last` goes through a file, so no quoting can break it.
    static func openTerminal(in folder: String, running command: String, arguments: [String] = [], with last: String) throws {
        let scripts = URL(fileURLWithPath: folder).appending(path: ".redline", directoryHint: .isDirectory)
        let name = "chat-\(UUID().uuidString.prefix(8))"
        let lastFile = scripts.appending(path: "\(name).txt")
        let script = scripts.appending(path: "\(name).command")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let ignore = scripts.appending(path: ".gitignore")
        if !FileManager.default.fileExists(atPath: ignore.path) { try "*\n".write(to: ignore, atomically: true, encoding: .utf8) }
        try last.write(to: lastFile, atomically: true, encoding: .utf8)
        try terminalScript(folder: folder, command: command, arguments: arguments, lastFile: lastFile.path).write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        try open(script.path)
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

    /// Runs a command in a folder and waits for it. Throws when it can't start.
    static func run(_ executable: String, arguments: [String], in folder: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: folder)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    /// Opens a chat where the user works with its agent: in the Claude or Codex app when it's
    /// installed, else in a terminal window in `folder` that resumes it. Throws when it can't.
    static func openChat(_ agent: Agent, id: String, in folder: String) throws {
        if let link = appLink(agent, id: id) {
            try open(link)
            return
        }
        guard let command = AgentCommand.locate(agent) else { throw OpenError.agentNotFound(agent) }
        let resume = switch agent {
        case .codex: ["resume"]
        case .claude: ["--resume"]
        }
        try openTerminal(in: folder, running: command.path, arguments: resume, with: id)
    }

    enum OpenError: Error, LocalizedError {
        case agentNotFound(Agent)

        var errorDescription: String? {
            switch self {
            case .agentNotFound(let agent): "Neither \(agent.name)'s app nor its command is installed"
            }
        }
    }

    /// The link that opens a chat in its agent's app, when the app is installed. The Claude
    /// app's link is the one `claude --desktop --resume` opens: the app takes the chat over from
    /// the claude command.
    static func appLink(_ agent: Agent, id: String, isClaudeAppInstalled: Bool = AgentCommand.isClaudeAppInstalled(),
                        isCodexAppInstalled: Bool = AgentCommand.isCodexAppInstalled()) -> String? {
        switch agent {
        case .claude:
            guard isClaudeAppInstalled else { return nil }
            var link = URLComponents(string: "claude://resume")
            link?.queryItems = [URLQueryItem(name: "session", value: id)]
            return link?.string
        case .codex:
            guard isCodexAppInstalled else { return nil }
            return "codex://threads/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)"
        }
    }

    /// Opens a link or file with /usr/bin/open and waits for it. Throws when open can't start.
    private static func open(_ link: String) throws {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = [link]
        try open.run()
        open.waitUntilExit()
    }

    /// Opens a Claude Code chat the claude command made: in the desktop app with
    /// `claude --desktop --resume`, or in a terminal without the app. Once the chat is open, sends
    /// it the report through its socket, so the user sees it start. If the chat doesn't open in
    /// time, the report goes in with the claude command instead.
    private func openClaude(_ id: String, in folder: String, thenSend text: String, for report: InboxReport) {
        let source = report.source
        guard let claude = AgentCommand.locate(.claude) else { return }
        let hasApp = AgentCommand.isClaudeAppInstalled()
        do {
            if hasApp {
                // claude --desktop refuses to run without a terminal; script gives it one.
                try Self.run("/usr/bin/script", arguments: ["-q", "/dev/null", claude.path, "--desktop", "--resume", id], in: folder)
            } else {
                try Self.openTerminal(in: folder, running: claude.path, arguments: ["--resume"], with: id)
            }
            hub.log("Opened the Claude Code chat \(id) in \(hasApp ? "the Claude app" : "a terminal"), in \(folder)")
        } catch {
            // The report still goes in below: through the socket if the chat opens anyway, else
            // with the claude command.
            hub.log("Couldn't open the Claude Code chat \(id) in \(hasApp ? "the Claude app" : "a terminal"): \(error.localizedDescription)")
        }
        let place = Self.folderName(folder)
        queue.async { [self] in
            for _ in 0..<60 {
                if let session = ClaudeSessions.open().first(where: { $0.id == id }), ClaudeSessions.send(text, to: session) {
                    hub.log("Sent report \(source.reportID) to the Claude Code chat \(id), now open")
                    record(.init(agent: .claude, chat: id, title: session.title ?? "New chat in \(place)", kind: .newChat), for: report)
                    Self.notify(title: Self.reportTitle(source), message: "Claude Code is looking into it in \(hasApp ? "the Claude app" : "Terminal"), in worktree \(place).")
                    return
                }
                Thread.sleep(forTimeInterval: 1)
            }
            // Not open after a minute: the report goes in anyway, and shows when the chat is opened.
            hub.log("The Claude Code chat \(id) didn't open in time; giving it report \(source.reportID) with the claude command")
            do {
                try Self.run(claude.path, arguments: ["-p", text, "--resume", id, "--permission-mode", "plan"], in: folder)
            } catch {
                hub.log("Couldn't run the claude command for report \(source.reportID): \(error.localizedDescription)")
                return
            }
            Self.notify(title: Self.reportTitle(source), message: "Claude Code looked into it. Open the chat in worktree \(place) to see it.")
        }
    }

    /// The claude command, which starts new Claude Code chats, isn't signed in: the report waits
    /// in the inbox, and the Mac says what to run once.
    private func waitForClaudeSignIn(_ report: InboxReport) {
        let source = report.source
        hub.log("Report \(source.reportID) waits: the claude command that starts new chats isn't signed in or is older than \(ClaudeCLI.desktopVersion.map(String.init).joined(separator: "."))")
        record(.init(agent: .claude, chat: nil, title: "Waiting for claude auth login", kind: .waiting), for: report)
        Self.notify(title: Self.reportTitle(source), message: "To start new Claude Code chats, run claude auth login once in Terminal. The report waits until then.")
    }

    /// Starts a chat with the report, in a worktree of its own made from `folder`, the worktree
    /// the app was built from. `pick` is the phone's "New chat" pick, remembered with the new chat.
    private func startChat(_ agent: Agent, in folder: String, for report: InboxReport, pick: String? = nil) {
        let source = report.source
        guard let executable = AgentCommand.locate(agent) else {
            hub.log("Couldn't find \(agent.name)'s command to start a chat for report \(source.reportID)")
            Self.notify(title: Self.reportTitle(source), message: "Couldn't find \(agent.name) to start a chat. The report waits in the inbox.")
            return
        }
        let chat = Self.claimant(id: ChatID.started(agent, report: report.folder), agent: agent, folder: folder, bundleID: source.bundleID)
        guard claim(report, for: chat) else { return }

        // A new chat works in a worktree of its own. Without one, such as for a folder that isn't
        // in a git repository, it works in the folder itself, where it can only look.
        let workFolder: String
        var madeWorktree = false
        do {
            workFolder = try NewWorktree.create(from: folder, name: "report-\(source.reportID)", agent: agent)
            madeWorktree = true
            hub.log("Made worktree \(workFolder) for report \(source.reportID)")
        } catch {
            workFolder = folder
            hub.log("Couldn't make a worktree for report \(source.reportID): \(error.localizedDescription); the chat starts in \(folder)")
        }
        let pictures = ReportContent.pictures(in: report.folder)
        var reportPrompt = ReportContent.text(for: report)
        // A Claude Code chat reads the pictures from a copy in its worktree, without asking.
        if agent == .claude, madeWorktree {
            do {
                let copy = try NewWorktree.copyReport(report.folder, into: workFolder)
                reportPrompt = reportPrompt.replacingOccurrences(of: report.folder.path, with: copy)
            } catch {
                hub.log("Couldn't copy report \(source.reportID) into \(workFolder): \(error.localizedDescription); the chat reads it from the inbox")
            }
        }
        // A Claude Code chat is only opened by the claude command, with a line that takes
        // seconds; it moves into the desktop app at once and gets the report there, where the
        // user watches it work. The app doesn't move a chat that's still running.
        let reportText = reportPrompt
        let prompt = switch agent {
        case .claude: "A UI report from the user's device comes in the next message. Reply with just: Ready."
        case .codex: reportPrompt
        }
        let output = report.folder.appending(path: Inbox.newChatOutputFile)
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let process = Process()
        process.executableURL = executable
        process.arguments = AgentCommand.arguments(agent, folder: workFolder, prompt: prompt, pictures: pictures)
        process.currentDirectoryURL = URL(fileURLWithPath: workFolder)
        process.environment = ProcessInfo.processInfo.environment.merging([AgentHooks.startedByHub: "1"]) { $1 }
        process.standardInput = FileHandle.nullDevice
        do {
            let handle = try FileHandle(forWritingTo: output)
            process.standardOutput = handle
            process.standardError = handle
        } catch {
            hub.log("Couldn't keep what the \(agent.name) command prints for report \(source.reportID): \(error.localizedDescription)")
        }
        let paths = hub.paths
        let place = Self.folderName(workFolder)
        let madeWorktreeForThis = madeWorktree
        process.terminationHandler = { [hub, self] finished in
            let text = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
            let started = AgentCommand.startedChat(agent, in: text)
            guard finished.terminationStatus == 0, let started, !started.failed else {
                // Free the report for a chat that opens later, and take back the unused worktree.
                release(report)
                if madeWorktreeForThis { NewWorktree.remove(workFolder) }
                let reason = AgentCommand.failure(in: text)
                hub.log("The \(agent.name) chat for report \(source.reportID) failed (\(finished.terminationStatus)): \(reason)")
                Handoff.notify(title: "Couldn't start a \(agent.name) chat", message: "\(reason). The report waits in the inbox.")
                return
            }
            // Later reports with the same pick go to this chat.
            if let pick {
                do {
                    try StartedChats.remember(StartedChat(chat: started.chat, folder: workFolder, at: Date()), for: pick, paths: paths)
                } catch {
                    hub.log("Couldn't remember the chat for the phone's pick \(pick); its next report starts another: \(error.localizedDescription)")
                }
            }
            if let answer = started.answer {
                do {
                    try answer.write(to: report.folder.appending(path: Inbox.answerFile), atomically: true, encoding: .utf8)
                } catch {
                    hub.log("Couldn't save the answer to report \(source.reportID): \(error.localizedDescription)")
                }
            }
            switch agent {
            case .codex:
                do {
                    try Handoff.openChat(.codex, id: started.chat, in: workFolder)
                } catch {
                    hub.log("Couldn't open the Codex chat \(started.chat): \(error.localizedDescription)")
                }
                hub.log("The Codex chat \(started.chat) in \(workFolder) looked into report \(source.reportID)")
                record(.init(agent: .codex, chat: started.chat, title: "New chat in \(place)", kind: .newChat), for: report)
                Handoff.notify(title: "Codex looked into a report", message: "Opened in Codex, in worktree \(place).")
            case .claude:
                openClaude(started.chat, in: workFolder, thenSend: reportText, for: report)
            }
        }
        do {
            try process.run()
            hub.log("Started a \(agent.name) chat in \(workFolder) for report \(source.reportID)")
            Self.notify(title: "\(agent.name) is looking into a report", message: "From \(source.deviceName), in worktree \(place).")
        } catch {
            release(report)
            hub.log("Couldn't start a \(agent.name) chat for report \(source.reportID): \(error.localizedDescription)")
        }
    }

    private static func folderName(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    /// Shows a notification. Inside Redline.app it comes from Redline; the bare command has no
    /// app of its own, so it goes through osascript.
    static func notify(title: String, message: String) {
        if Bundle.main.bundleURL.pathExtension == "app" {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = message
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            return
        }
        func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "display notification \(quoted(message)) with title \(quoted(title))"]
        // A notification that can't be shown is left out; the log says what happened.
        try? process.run()
    }
}

/// Starting a chat with each agent from the command line. Each runs without permission to
/// change files, so the chat can only look and propose.
enum AgentCommand {
    /// Claude's desktop app, where new Claude Code chats open, is installed. Checks the disk.
    static func isClaudeAppInstalled() -> Bool {
        FileManager.default.fileExists(atPath: "/Applications/Claude.app")
    }

    /// Codex's desktop app, inside the ChatGPT app or on its own, is installed. Checks the disk.
    static func isCodexAppInstalled() -> Bool {
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
        }
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:))
    }

    static func arguments(_ agent: Agent, folder: String, prompt: String, pictures: [URL] = []) -> [String] {
        switch agent {
        case .claude:
            ["-p", prompt, "--permission-mode", "plan", "--output-format", "json"]
        // Pictures go in with the prompt; "--" ends them, so the prompt isn't read as one.
        case .codex:
            ["exec", "-C", folder, "--sandbox", "read-only", "--skip-git-repo-check", "--json"]
                + pictures.flatMap { ["-i", $0.path] } + ["--", prompt]
        }
    }

    /// The chat a command line run started or continued, its answer when it gives one, and
    /// whether the run reported an error: `codex exec --json`'s first event, or the result
    /// `claude -p --output-format json` prints.
    static func startedChat(_ agent: Agent, in output: String) -> (chat: String, answer: String?, failed: Bool)? {
        for line in output.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            switch agent {
            case .codex:
                if object["type"] as? String == "thread.started", let thread = object["thread_id"] as? String { return (thread, nil, false) }
            case .claude:
                if let session = object["session_id"] as? String ?? object["chatId"] as? String {
                    return (session, object["result"] as? String, object["is_error"] as? Bool ?? false)
                }
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
