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

    /// The user's pick, saved with the report on the phone. Nil when there's none.
    static func pick(of report: URL) -> Listing.Pick? {
        (try? Data(contentsOf: report.appending(path: "report.json"))).flatMap { try? JSONDecoder().decode(Listing.self, from: $0) }?
            .destination.flatMap { Agent(rawValue: $0.agent) == nil ? nil : $0 }
    }

    /// The worktree the app was built from, as the report says, when that folder builds the
    /// report's app. The phone writes the report, so a path to any other project isn't used:
    /// the hub makes worktrees and starts chats in this folder.
    static func worktree(of report: URL, bundleID: String) -> String? {
        let listing = (try? Data(contentsOf: report.appending(path: "report.json"))).flatMap { try? JSONDecoder().decode(Listing.self, from: $0) }
        return worktree(of: listing, bundleID: bundleID)
    }

    private static func worktree(of listing: Listing?, bundleID: String) -> String? {
        guard let worktree = listing?.app.sourceFile.map(Worktree.root(of:)), ChatDirectory.apps.bundleIDs(in: worktree).contains(bundleID) else { return nil }
        return worktree
    }

    static func destination(of report: URL, bundleID: String, paths: HubPaths,
                            list: (String, String?) -> HubMessage.ChatList) -> Destination {
        let listing = (try? Data(contentsOf: report.appending(path: "report.json"))).flatMap { try? JSONDecoder().decode(Listing.self, from: $0) }
        let worktree = worktree(of: listing, bundleID: bundleID)
        let unknown = listing?.app.sourceFile == nil ? "The report doesn't say which worktree the app was built from"
            : "The worktree the report names doesn't build \(bundleID)"
        if let pick = listing?.destination, let agent = Agent(rawValue: pick.agent) {
            if let chat = pick.chat { return .chat(agent, id: chat) }
            guard let worktree else { return .undecided(unknown) }
            return .newChat(agent, folder: worktree, pick: pick.newChat)
        }
        guard let worktree else { return .undecided(unknown) }
        let directory = list(bundleID, listing?.app.sourceFile)
        let here = directory.chats.filter(\.sameWorktree)
        if here.count == 1, let chat = here.first, let agent = Agent(rawValue: chat.agent) { return .chat(agent, id: chat.id) }
        // A new chat with the agent last used on the app, while it can start one; else the first that can.
        let startable = directory.newChats ?? directory.agents
        let last = ProjectHistory.all(paths)[bundleID]?.agent
        if here.isEmpty, let agent = (startable.first { $0 == last } ?? startable.first).flatMap(Agent.init(rawValue:)) {
            return .newChat(agent, folder: worktree, pick: nil)
        }
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
    /// "New chat" picks whose first report is still starting the chat, with the reports that
    /// arrived for them meanwhile. They go to that chat once it's started. Used on `queue`.
    private var startingPicks: [String: [InboxReport]] = [:]
    /// Reports for a new Claude Code chat that wait until the claude command is signed in and
    /// new enough. Used on `queue`.
    private var waitingForClaude: [InboxReport] = []
    /// Set once the hub is stopping: no new hand-over starts. Set outside `queue`, so work
    /// already queued there sees it at once rather than after it has run.
    private let finishing = NSLock()
    private var isFinishing = false

    /// How often the hub checks whether the claude command is ready, while reports wait for it.
    static let claudeRecheckInterval: TimeInterval = 60

    init(hub: Hub) {
        self.hub = hub
    }

    /// Starts no new hand-overs, and waits for those under way to reach their chats or give
    /// their reports back. A hand-over cut off by the hub exiting looks interrupted, and the
    /// next hub would hand the report over again while the chat or command this one started
    /// still has it. The reports not handed over wait in the inbox for the next hub.
    func finish() {
        finishing.withLock { isFinishing = true }
        // A hand-over that started before the flag was set has made its claim once this returns,
        // so the wait below sees it.
        queue.sync {}
        var logged = false
        while true {
            let count = InboxQueue.handingOver(by: getpid(), paths: hub.paths)
            guard count > 0 else { return }
            if !logged {
                hub.log("Stopping once \(count == 1 ? "the report being handed over reaches its chat" : "the \(count) reports being handed over reach their chats")")
                logged = true
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    func reportFiled(_ folder: URL, source: ReportSource) {
        queue.async { [self] in
            guard let report = InboxQueue.waiting(for: [source.bundleID], paths: hub.paths).first(where: { $0.folder == folder }) else { return }
            deliver(report)
        }
    }

    /// Hands over the reports no chat took while the hub was down: those sent to a chat on the
    /// phone or cut off mid hand-over, however long ago, and the others that arrived shortly
    /// before the hub started.
    func handOverRecent(within interval: TimeInterval = 3600) {
        queue.async { [self] in
            // Every watched app, including those given on the command line.
            for report in InboxQueue.waiting(for: hub.apps, paths: hub.paths) where Self.replays(report, within: interval) {
                deliver(report)
            }
        }
    }

    /// Whether a report waiting when the hub starts is handed over again. One already addressed
    /// to a chat waits for that chat's hooks. One the user sent to a chat, or whose hand-over was
    /// cut off, was promised to a chat. Any other goes only while recent: a chat started for it
    /// long after it was sent would surprise the user.
    static func replays(_ report: InboxReport, within interval: TimeInterval, now: Date = Date()) -> Bool {
        guard InboxQueue.address(of: report.folder) == nil else { return false }
        return report.claim != nil || Routing.pick(of: report.folder) != nil || now.timeIntervalSince(report.source.receivedAt) < interval
    }

    private func deliver(_ report: InboxReport) {
        let source = report.source
        guard !finishing.withLock({ isFinishing }) else {
            hub.log("Report \(source.reportID) waits in the inbox for the next hub: this one is stopping")
            return
        }
        let paths = hub.paths
        let destination = Routing.destination(of: report.folder, bundleID: source.bundleID, paths: paths) { bundleID, sourceFile in
            ChatDirectory.list(bundleID: bundleID, sourceFile: sourceFile, paths: paths)
        }
        let worktree = Routing.worktree(of: report.folder, bundleID: source.bundleID)
        switch destination {
        case .chat(.claude, let id):
            sendToClaude(report, session: id, worktree: worktree)
        case .chat(.codex, let id):
            sendToCodex(report, thread: id)
        case .chat(.cursor, let id):
            // A Cursor chat gets reports only through its own hooks. One that closed since the
            // phone listed it runs them again when the user reopens it, so it's addressed too.
            InboxQueue.setAddress(Address(chat: "cursor-\(id)", agent: Agent.cursor.rawValue, folder: worktree ?? ""), of: report.folder)
            // Saved before the chat's hook wakes, so a claim it makes is always newer than this.
            ReportDelivery.save(.init(agent: .cursor, chat: id, title: "Cursor chat", kind: .nextMessage), in: report.folder)
            InboxQueue.signal(source.bundleID, paths: paths)
            if Chats.live(paths).contains(where: { $0.id == "cursor-\(id)" }) {
                hub.log("Report \(source.reportID) goes to the Cursor chat \(id) when its hooks next run")
                Self.notify(title: "Report from \(source.deviceName)", message: "Goes to the Cursor chat after its next reply or with your next message there.")
            } else {
                hub.log("The Cursor chat \(id) for report \(source.reportID) is closed; it gets the report when it's reopened")
                Self.notify(title: "Report from \(source.deviceName)",
                            message: "The Cursor chat it was sent to is closed. It gets the report after you reopen it and send a message there.")
            }
        case .newChat(let agent, let folder, let pick):
            // The chat this pick started for an earlier report, while its worktree exists.
            if let pick, let started = StartedChats.find(pick, paths: paths) {
                switch agent {
                case .codex: sendToCodex(report, thread: started.chat)
                case .claude: sendToClaude(report, session: started.chat, worktree: started.folder)
                case .cursor: startChat(agent, in: started.folder, for: report, resuming: started.chat)
                }
            } else if let pick, startingPicks[pick] != nil {
                startingPicks[pick, default: []].append(report)
                hub.log("Report \(source.reportID) waits for the \(agent.name) chat its pick is starting")
                Self.leaveWaiting(report, agent: agent, chat: nil, because: "Waiting for the new chat to start")
            } else if agent == .claude, !ClaudeCLI.ready() {
                waitForClaudeSignIn(report)
            } else {
                if let pick { startingPicks[pick] = [] }
                startChat(agent, in: folder, for: report, pick: pick)
            }
        case .undecided(let reason):
            hub.log("Report \(source.reportID) waits in the inbox: \(reason)")
            Self.leaveWaiting(report, agent: nil, chat: nil, because: reason)
            Self.notify(title: "Report from \(source.deviceName)", message: "\(reason).")
        }
    }

    /// Puts the report into a Claude Code chat through its socket. If the chat closed, a new
    /// one starts in the worktree.
    private func sendToClaude(_ report: InboxReport, session id: String, worktree: String?) {
        let source = report.source
        guard let session = ClaudeSessions.open().first(where: { $0.id == id }) else {
            hub.log("The Claude Code chat for report \(source.reportID) is closed")
            // Continued where it left off, then reopened in the desktop app.
            if let worktree, ClaudeCLI.ready() {
                let chat = ChatRecord(id: "claude-\(id)", agent: Agent.claude.rawValue, folder: worktree, bundleIDs: [source.bundleID],
                                      pid: getpid(), registeredAt: Date(), lastActiveAt: Date())
                guard InboxQueue.claim(report, for: chat) else { return }
                openClaude(id, in: worktree, thenSend: ReportContent.text(for: report), for: report, reopening: true)
            } else if worktree != nil {
                waitForClaudeSignIn(report)
            } else {
                hub.log("Report \(source.reportID) waits in the inbox: it doesn't say where the app was built, to reopen the chat there")
                Self.leaveWaiting(report, agent: .claude, chat: id, because: "The chat is closed")
            }
            return
        }
        let chat = ChatRecord(id: "claude-\(id)", agent: Agent.claude.rawValue, folder: session.folder, bundleIDs: [source.bundleID],
                              pid: getpid(), registeredAt: Date(), lastActiveAt: Date())
        guard InboxQueue.claim(report, for: chat) else { return }
        let name = session.title ?? Self.folderName(session.folder)
        if ClaudeSessions.send(ReportContent.text(for: report), to: session) {
            InboxQueue.handedOver(report)
            hub.log("Sent report \(source.reportID) to the Claude Code chat \(name), in \(session.folder)")
            ReportDelivery.save(.init(agent: .claude, chat: id, title: name, kind: .sent), in: report.folder)
            Self.notify(title: "Report from \(source.deviceName)", message: "Sent to the Claude Code chat \(name).")
        } else {
            Self.leaveWaiting(report, agent: .claude, chat: id, because: "\(name) didn't take it")
            InboxQueue.release(report)
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
        // Off the handoff queue: an app that doesn't answer holds this for its timeout, and
        // opening the chat waits seconds more, while other reports go on. The claim covers it.
        DispatchQueue.global(qos: .utility).async { [self] in
            let pictures = ReportContent.pictures(in: report.folder)
            let text = ReportContent.text(for: report)
            var outcome = CodexApp.startTurn(thread: thread, text: text, pictures: pictures)
            if outcome == .notOpen {
                hub.log("The Codex chat for report \(source.reportID) isn't open; opening it")
                Self.open("codex://threads/\(thread)")
                Thread.sleep(forTimeInterval: 5)
                outcome = CodexApp.startTurn(thread: thread, text: text, pictures: pictures)
            }
            if outcome == .started {
                InboxQueue.handedOver(report)
                hub.log("Sent report \(source.reportID) with \(pictures.count) pictures to the Codex chat \(thread)")
                ReportDelivery.save(.init(agent: .codex, chat: thread, title: CodexThreads.title(of: thread) ?? "Codex chat", kind: .sent), in: report.folder)
                Self.notify(title: "Report from \(source.deviceName)", message: "Sent to the Codex chat, with its pictures.")
                return
            }
            // Saved and addressed before the report is free, so a claim the chat's hook makes is
            // always newer than this, and no other chat can take it in between.
            ReportDelivery.save(.init(agent: .codex, chat: thread, title: CodexThreads.title(of: thread) ?? "Codex chat", kind: .nextMessage), in: report.folder)
            InboxQueue.setAddress(Address(chat: chat.id, agent: chat.agent, folder: ""), of: report.folder)
            InboxQueue.release(report)
            hub.log("The Codex app didn't take report \(source.reportID) (\(outcome)); it goes in with the chat's next message")
            Self.notify(title: "Report from \(source.deviceName)", message: "Goes to the Codex chat with your next message there.")
        }
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

    /// Runs a command in a folder and waits for it. True when it ran and exited with status 0.
    @discardableResult
    static func run(_ executable: String, _ arguments: [String], in folder: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: folder)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationReason == .exit && process.terminationStatus == 0
    }

    private static func open(_ link: String) {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = [link]
        try? open.run()
        open.waitUntilExit()
    }

    /// Opens a Claude Code chat the claude command made: in the desktop app with
    /// `claude --desktop --resume`, or in a terminal without the app. Once the chat is open, sends
    /// it the report through its socket, so the user sees it start. If the chat doesn't open in
    /// time, the report goes in with the claude command instead. `reopening` is a chat that
    /// closed, rather than one the hub just started.
    private func openClaude(_ id: String, in folder: String, thenSend text: String, for report: InboxReport, pick: String? = nil,
                            reopening: Bool = false) {
        let source = report.source
        guard let claude = AgentCommand.locate(.claude) else {
            pickSettled(pick)
            Self.leaveWaiting(report, agent: .claude, chat: id, because: "Couldn't find the claude command")
            InboxQueue.release(report)
            hub.log("Couldn't find the claude command to open the chat for report \(source.reportID); it waits in the inbox")
            return
        }
        let place = Self.folderName(folder)
        let kind: ReportDelivery.Kind = reopening ? .sent : .newChat
        let title = reopening ? place : "New chat in \(place)"
        // Off the handoff queue: opening the chat, waiting for it, and the claude command after
        // it can take minutes, and other reports go on meanwhile. `pickSettled` goes back to the queue.
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { pickSettled(pick) }
            if AgentCommand.hasClaudeApp {
                // claude --desktop refuses to run without a terminal; script gives it one.
                Self.run("/usr/bin/script", ["-q", "/dev/null", claude.path, "--desktop", "--resume", id], in: folder)
            } else {
                Self.openTerminal(in: folder, running: claude.path, arguments: ["--resume"], with: id)
            }
            hub.log("Opened the Claude Code chat \(id) in \(AgentCommand.hasClaudeApp ? "the Claude app" : "a terminal"), in \(folder)")
            for _ in 0..<60 {
                if let session = ClaudeSessions.open().first(where: { $0.id == id }), ClaudeSessions.send(text, to: session) {
                    InboxQueue.handedOver(report)
                    hub.log("Sent report \(source.reportID) to the Claude Code chat \(id), now open")
                    ReportDelivery.save(.init(agent: .claude, chat: id, title: session.title ?? title, kind: kind), in: report.folder)
                    Self.notify(title: "Report from \(source.deviceName)", message: "Claude Code is looking into it in \(AgentCommand.hasClaudeApp ? "the Claude app" : "Terminal"), in worktree \(place).")
                    return
                }
                Thread.sleep(forTimeInterval: 1)
            }
            // Not open after a minute: the report goes in anyway, and shows when the chat is opened.
            hub.log("The Claude Code chat \(id) didn't open in time; giving it report \(source.reportID) with the claude command")
            guard Self.run(claude.path, ["-p", text, "--resume", id, "--permission-mode", "plan"], in: folder) else {
                // Such as when the claude command's sign-in expired: the chat doesn't have it.
                Self.leaveWaiting(report, agent: .claude, chat: id, because: "Claude Code didn't take it")
                InboxQueue.release(report)
                hub.log("The claude command didn't give report \(source.reportID) to the Claude Code chat \(id); it waits in the inbox")
                Self.notify(title: "Report from \(source.deviceName)", message: "Claude Code didn't take it. It waits in the inbox.")
                return
            }
            InboxQueue.handedOver(report)
            // The claim names the folder the chat was started from, not its worktree: this says where it ran.
            ReportDelivery.save(.init(agent: .claude, chat: id, title: title, kind: kind), in: report.folder)
            Self.notify(title: "Report from \(source.deviceName)", message: "Claude Code looked into it. Open the chat in worktree \(place) to see it.")
        }
    }

    /// The chat a "New chat" pick was starting has started or failed: the reports that waited
    /// for it go on, to that chat once it's remembered, or else to start one again.
    private func pickSettled(_ pick: String?) {
        guard let pick else { return }
        queue.async { [self] in
            startingPicks.removeValue(forKey: pick)?.forEach(deliver)
        }
    }

    /// The report stays in the inbox for a chat to take later; the panel shows why. Saved before
    /// a claim is released, so a chat that takes the report next is always newer than this, and
    /// not saved when a chat already took it, such as one whose wait woke when it was filed.
    private static func leaveWaiting(_ report: InboxReport, agent: Agent?, chat: String?, because reason: String) {
        ReportDelivery.save(.init(agent: agent, chat: chat, title: reason, kind: .waiting), in: report.folder)
    }

    /// The claude command, which starts new Claude Code chats, isn't signed in or is too old: the
    /// report waits in the inbox, the Mac says what to run once, and the hub hands the report
    /// over when the command is ready.
    private func waitForClaudeSignIn(_ report: InboxReport) {
        let source = report.source
        hub.log("Report \(source.reportID) waits: the claude command that starts new chats isn't signed in or is older than \(ClaudeCLI.desktopVersion.map(String.init).joined(separator: "."))")
        Self.leaveWaiting(report, agent: .claude, chat: nil, because: "Waiting for claude auth login")
        Self.notify(title: "Report from \(source.deviceName)", message: "To start new Claude Code chats, run claude auth login once in Terminal. The report waits until then.")
        guard !waitingForClaude.contains(where: { $0.folder == report.folder }) else { return }
        waitingForClaude.append(report)
        if waitingForClaude.count == 1 { recheckClaude() }
    }

    /// Checks again later whether the claude command is ready, and once it is, hands over the
    /// reports that waited for it and that no chat has taken meanwhile.
    private func recheckClaude() {
        queue.asyncAfter(deadline: .now() + Self.claudeRecheckInterval) { [weak self] in
            guard let self, !waitingForClaude.isEmpty else { return }
            guard ClaudeCLI.ready() else {
                recheckClaude()
                return
            }
            let reports = Self.stillWaiting(waitingForClaude, paths: hub.paths)
            waitingForClaude = []
            hub.log("The claude command is ready; handing over \(reports.count) waiting reports")
            reports.forEach(deliver)
        }
    }

    /// Those of `reports` still waiting in the inbox, as they are now: a chat may have taken one,
    /// or the report may have been removed, while it waited.
    static func stillWaiting(_ reports: [InboxReport], paths: HubPaths) -> [InboxReport] {
        let folders = Set(reports.map(\.folder))
        let apps = Array(Set(reports.map(\.source.bundleID)))
        return InboxQueue.waiting(for: apps, paths: paths).filter { folders.contains($0.folder) }
    }

    /// Starts a chat with the report. A new chat gets a worktree of its own made from `folder`,
    /// the worktree the app was built from; `resuming` continues a chat the hub started before,
    /// in its own worktree. `pick` is the phone's "New chat" pick, remembered with the new chat.
    private func startChat(_ agent: Agent, in folder: String, for report: InboxReport, pick: String? = nil, resuming: String? = nil) {
        let source = report.source
        guard let executable = AgentCommand.locate(agent) else {
            pickSettled(pick)
            hub.log("Couldn't find \(agent.name)'s command to start a chat for report \(source.reportID)")
            Self.leaveWaiting(report, agent: agent, chat: resuming, because: "Couldn't find the \(agent.name) command")
            Self.notify(title: "Report from \(source.deviceName)", message: "Couldn't find \(agent.name) to start a chat. The report waits in the inbox.")
            return
        }
        let chat = ChatRecord(id: "started-\(agent.rawValue)-\(report.folder.lastPathComponent)", agent: agent.rawValue, folder: folder,
                              bundleIDs: [source.bundleID], pid: getpid(), registeredAt: Date(), lastActiveAt: Date())
        guard InboxQueue.claim(report, for: chat) else {
            pickSettled(pick)
            return
        }
        // Off the handoff queue: making the worktree fetches the main branch first, which can
        // wait on a slow or unreachable remote, and other reports go on meanwhile.
        // `pickSettled` goes back to the queue.
        DispatchQueue.global(qos: .utility).async { [self] in
            // A new chat works in a worktree of its own; a continued one is already in its own.
            // Without its own worktree, a new chat would work in the user's checkout: it doesn't start.
            let workFolder: String
            let madeWorktree = resuming == nil
            if resuming == nil {
                guard let made = NewWorktree.create(from: folder, name: "report-\(source.reportID)", agent: agent) else {
                    pickSettled(pick)
                    Self.leaveWaiting(report, agent: agent, chat: nil, because: "Couldn't make a worktree")
                    InboxQueue.release(report)
                    hub.log("Couldn't make a worktree from the main branch of \(folder) for report \(source.reportID); it waits in the inbox")
                    Self.notify(title: "Report from \(source.deviceName)",
                                message: "Couldn't make a worktree for a new \(agent.name) chat from the main branch of \(Self.folderName(folder)). The report waits in the inbox.")
                    return
                }
                workFolder = made
                hub.log("Made worktree \(made) for report \(source.reportID)")
            } else {
                workFolder = folder
            }
            let pictures = ReportContent.pictures(in: report.folder)
            var reportPrompt = ReportContent.text(for: report)
            // A Claude Code chat reads the pictures from a copy in its worktree, without asking.
            if agent == .claude, madeWorktree, let copy = NewWorktree.copyReport(report.folder, into: workFolder) {
                reportPrompt = reportPrompt.replacingOccurrences(of: report.folder.path, with: copy)
            }
            // A Claude Code chat is only opened by the claude command, with a line that takes
            // seconds; it moves into the desktop app at once and gets the report there, where the
            // user watches it work. The app doesn't move a chat that's still running.
            let reportText = reportPrompt
            let prompt = agent == .claude ? "A UI report from the user's device comes in the next message. Reply with just: Ready." : reportPrompt
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
            process.terminationHandler = { [hub, self] finished in
                let text = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
                let started = AgentCommand.startedChat(agent, in: text)
                guard finished.terminationStatus == 0, let started, !started.failed else {
                    // Free the report for a chat that opens later, and take back the unused worktree.
                    let reason = AgentCommand.failure(in: text)
                    Handoff.leaveWaiting(report, agent: agent, chat: resuming, because: "Couldn't start the chat: \(reason)")
                    InboxQueue.release(report)
                    if madeWorktree { NewWorktree.remove(workFolder) }
                    self.pickSettled(pick)
                    hub.log("The \(agent.name) chat for report \(source.reportID) failed (\(finished.terminationStatus)): \(reason)")
                    Handoff.notify(title: "Couldn't start a \(agent.name) chat", message: "\(reason). The report waits in the inbox.")
                    return
                }
                // Later reports with the same pick go to this chat.
                if let pick { StartedChats.remember(StartedChat(chat: started.chat, folder: workFolder, at: Date()), for: pick, paths: paths) }
                if let answer = started.answer {
                    try? answer.write(to: report.folder.appending(path: "answer.md"), atomically: true, encoding: .utf8)
                }
                // A Claude Code chat has the report once it's sent into the open chat.
                if agent != .claude {
                    InboxQueue.handedOver(report)
                    self.pickSettled(pick)
                }
                if agent == .codex {
                    // Shown in the Codex app, or in a terminal without it.
                    if AgentCommand.hasCodexApp {
                        Handoff.open("codex://threads/\(started.chat)")
                    } else {
                        Handoff.openTerminal(in: workFolder, running: executable.path, arguments: ["resume"], with: started.chat)
                    }
                    hub.log("The Codex chat \(started.chat) in \(workFolder) looked into report \(source.reportID)")
                    ReportDelivery.save(.init(agent: .codex, chat: started.chat, title: "New chat in \(place)", kind: .newChat), in: report.folder)
                    Handoff.notify(title: "Codex looked into a report", message: "Opened in Codex, in worktree \(place).")
                } else if agent == .claude {
                    // Reports waiting for this pick follow once this one is in the open chat.
                    self.openClaude(started.chat, in: workFolder, thenSend: reportText, for: report, pick: pick)
                } else {
                    hub.log("The \(agent.name) chat \(started.chat) in \(workFolder) looked into report \(source.reportID)")
                    ReportDelivery.save(.init(agent: agent, chat: started.chat, title: "New chat in \(place)", kind: .newChat), in: report.folder)
                    Handoff.notify(title: "\(agent.name) looked into a report", message: "Its answer is in the report's folder, answer.md. Worktree \(place).")
                }
            }
            do {
                try process.run()
                hub.log("\(resuming == nil ? "Started" : "Continued") a \(agent.name) chat in \(workFolder) for report \(source.reportID)")
                Self.notify(title: "\(agent.name) is looking into a report", message: "From \(source.deviceName), in worktree \(place).")
            } catch {
                Self.leaveWaiting(report, agent: agent, chat: resuming, because: "Couldn't start the chat")
                InboxQueue.release(report)
                if madeWorktree { NewWorktree.remove(workFolder) }
                pickSettled(pick)
                hub.log("Couldn't start a \(agent.name) chat for report \(source.reportID): \(error.localizedDescription)")
            }
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
    /// Claude's desktop app, where new Claude Code chats open.
    static var hasClaudeApp: Bool { FileManager.default.fileExists(atPath: "/Applications/Claude.app") }

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
