#if os(macOS)
import AppKit
import Darwin
import SwiftUI
import Synchronization
import UserNotifications

/// Sends each report where the user picked on the phone, or else to the chat working in the
/// worktree the app was built from.
///
/// A Claude Code chat gets it through its socket, which starts a turn even when the chat is idle. A
/// Codex chat gets it through the Codex app with its pictures attached. A new chat starts in the
/// worktree and looks into the report without changing code.
final class Handoff: Sendable {
    private unowned let hub: Hub
    private let queue = DispatchQueue(label: "Redline.hub.handoff", qos: .userInitiated)
    /// "New chat" picks whose first report is still starting the chat, with the reports that
    /// arrived for them meanwhile.
    ///
    /// They go to that chat once it's started.
    private let startingPicks = Mutex<[String: [InboxReport]]>([:])
    /// Set once the hub is stopping: no new hand-over starts.
    ///
    /// Set outside `queue`, so work already queued there sees it at once rather than after it has
    /// run.
    private let isFinishing = Mutex(false)

    init(hub: Hub) {
        self.hub = hub
    }

    /// Starts no new hand-overs, and waits for those under way to reach their chats or give their
    /// reports back.
    ///
    /// A hand-over cut off by the hub exiting looks interrupted, and the next hub would hand the
    /// report over again while the chat or command this one started still has it. The reports not
    /// handed over wait in the inbox for the next hub. Parks the stopping thread, checking every
    /// half second, until then; never called on `queue`.
    func finish() {
        isFinishing.withLock { $0 = true }
        // A hand-over that started before the flag was set has made its claim once this returns,
        // so the wait below sees it.
        queue.sync {}
        var hasLogged = false
        while true {
            let count = Inbox.reportsHandedOver(by: getpid(), paths: hub.paths)
            guard count > 0 else { return }
            if !hasLogged {
                hub.log(
                    "Stopping once \(count == 1 ? "the report being handed over reaches its chat" : "the \(count) reports being handed over reach their chats")"
                )
                hasLogged = true
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    // MARK: - Delivery

    /// Delivers a report the hub just filed, unless a chat took it already.
    func reportDidArrive(at folder: URL, source: ReportSource) {
        queue.async { [self] in
            // A chat may have taken it already, through MCP or a hook. One whose hand-over was
            // interrupted doesn't have it, so the report goes on; delivering replaces that claim.
            guard Inbox.activeClaim(of: folder) == nil else { return }
            deliver(InboxReport(folder: folder, source: source, claim: nil))
        }
    }

    /// Hands over the reports no chat took while the hub was down: those sent to a chat on the
    /// phone or cut off mid hand-over, however long ago, and the others that arrived shortly before
    /// the hub started.
    func handOverRecent(within interval: TimeInterval = 3600) {
        queue.async { [self] in
            // Every watched app, including those given on the command line.
            for report in Inbox.unclaimedReports(for: hub.apps, paths: hub.paths)
            where Self.isReplayed(report, within: interval) {
                deliver(report)
            }
        }
    }

    /// Whether a report waiting when the hub starts is handed over again.
    ///
    /// One already addressed to a chat waits for that chat's hooks. One the user sent to a chat, or
    /// whose hand-over was cut off, was promised to a chat. Any other goes only while recent: a chat
    /// started for it long after it was sent would surprise the user.
    static func isReplayed(_ report: InboxReport, within interval: TimeInterval, now: Date = .now) -> Bool {
        guard Inbox.recipient(of: report.folder) == nil else { return false }
        return report.claim != nil || Routing.pick(of: report.folder) != nil
            || now.timeIntervalSince(report.source.receivedAt) < interval
    }

    private func deliver(_ report: InboxReport) {
        guard !isFinishing.withLock({ $0 }) else {
            hub.log("Report \(report.source.reportID) waits in the inbox for the next hub: this one is stopping")
            return
        }
        // The menu bar app has no window, so App Nap would slow a delivery the user is waiting for.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Handing a report to a chat"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let source = report.source
        let paths = hub.paths
        let destination = Routing.destination(
            of: report.folder,
            bundleID: source.bundleID,
            lastAgent: ProjectHistory.all(paths)[source.bundleID]?.agent
        ) { bundleID, sourceFile in
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
            } else if let pick, startingPicks.withLock({ $0[pick] != nil }) {
                startingPicks.withLock { $0[pick, default: []].append(report) }
                hub.log("Report \(source.reportID) waits for the \(agent.name) chat its pick is starting")
                leaveWaiting(report, agent: agent, chat: nil, because: "Waiting for the new chat to start")
            } else if agent == .claude, !ClaudeCLI.isReady() {
                waitForClaudeSignIn(report)
            } else {
                if let pick { startingPicks.withLock { $0[pick] = [] } }
                startChat(agent, in: folder, for: report, pick: pick)
            }
        case .undecided(let reason):
            hub.log("Report \(source.reportID) waits in the inbox: \(reason)")
            leaveWaiting(report, agent: nil, chat: nil, because: reason)
            Self.notify(title: Self.reportTitle(source), message: "\(reason).")
        }
    }

    /// Takes the report for a chat.
    ///
    /// False, after logging why when it isn't another chat that took it first, when the report
    /// can't be taken.
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
            try Inbox.release(report)
        } catch {
            hub.log("Couldn't let report \(report.source.reportID) go for another chat: \(error.localizedDescription)")
        }
    }

    /// Notes that the chat has the report, so the claim stands for good.
    private func handedOver(_ report: InboxReport) {
        do {
            try Inbox.handedOver(report)
        } catch {
            hub.log(
                "Couldn't note that report \(report.source.reportID) was handed over: \(error.localizedDescription)"
            )
        }
    }

    /// Saves where the report went, for the panel and the viewer.
    private func record(_ delivery: ChatDelivery, for report: InboxReport) {
        do {
            try ChatDelivery.save(delivery, in: report.folder)
        } catch {
            hub.log("Couldn't save where report \(report.source.reportID) went: \(error.localizedDescription)")
        }
    }

    /// The report stays in the inbox for a chat to take later; the panel shows why.
    ///
    /// Saved before a claim is released, so a chat that takes the report next is always newer than
    /// this, and not saved when a chat already took it, such as one whose wait woke when it was
    /// filed.
    private func leaveWaiting(_ report: InboxReport, agent: Agent?, chat: String?, because reason: String) {
        record(.init(agent: agent, chat: chat, title: reason, kind: .waiting), for: report)
    }

    /// The chat a "New chat" pick was starting has started or failed: the reports that waited for
    /// it go on, to that chat once it's remembered, or else to start one again.
    private func pickSettled(_ pick: String?) {
        guard let pick else { return }
        queue.async { [self] in
            let waiting = startingPicks.withLock { $0.removeValue(forKey: pick) } ?? []
            waiting.forEach(deliver)
        }
    }

    /// A chat record for a chat the hub hands a report to, as the claim names it.
    private static func claimant(id: String, agent: Agent, folder: String, bundleID: String) -> ChatRecord {
        ChatRecord(
            id: id,
            agent: agent.rawValue,
            folder: folder,
            bundleIDs: [bundleID],
            pid: getpid(),
            registeredAt: .now,
            lastActiveAt: .now
        )
    }

    /// The title of every notification about a report.
    private static func reportTitle(_ source: ReportSource) -> String {
        "Report from \(source.deviceName)"
    }

    // MARK: - Claude Code

    /// Puts the report into a Claude Code chat through its socket.
    ///
    /// If the chat closed, a new one starts in the worktree.
    private func sendToClaude(_ report: InboxReport, session id: String, worktree: String?) {
        let source = report.source
        guard let session = ClaudeSessions.openSessions().first(where: { $0.id == id }) else {
            hub.log("The Claude Code chat for report \(source.reportID) is closed")
            // Continued where it left off, then reopened in the desktop app.
            if let worktree, ClaudeCLI.isReady() {
                let chat = Self.claimant(
                    id: ChatID.make(.claude, id),
                    agent: .claude,
                    folder: worktree,
                    bundleID: source.bundleID
                )
                guard claim(report, for: chat) else { return }
                openClaude(id, in: worktree, thenSend: ReportContent.text(for: report), for: report, isReopening: true)
            } else if worktree != nil {
                waitForClaudeSignIn(report)
            } else {
                hub.log(
                    "Report \(source.reportID) waits in the inbox: it doesn't say where the app was built, to reopen the chat there"
                )
                leaveWaiting(report, agent: .claude, chat: id, because: "The chat is closed")
            }
            return
        }
        let chat = Self.claimant(
            id: ChatID.make(.claude, id),
            agent: .claude,
            folder: session.folder,
            bundleID: source.bundleID
        )
        guard claim(report, for: chat) else { return }
        let name = session.title ?? Self.folderName(session.folder)
        if ClaudeSessions.send(ReportContent.text(for: report), to: session) {
            handedOver(report)
            hub.log("Sent report \(source.reportID) to the Claude Code chat \(name), in \(session.folder)")
            record(.init(agent: .claude, chat: id, title: name, kind: .sent), for: report)
            Self.notify(title: Self.reportTitle(source), message: "Sent to the Claude Code chat \(name).")
        } else {
            leaveWaiting(report, agent: .claude, chat: id, because: "\(name) didn't take it")
            release(report)
            hub.log("The Claude Code chat \(name) didn't take report \(source.reportID); it waits in the inbox")
            Self.notify(
                title: Self.reportTitle(source),
                message: "The Claude Code chat \(name) didn't take it. It waits in the inbox."
            )
        }
    }

    // MARK: - Codex

    /// Starts a turn with the report, pictures attached, in a Codex chat.
    ///
    /// A chat no Codex window has open is opened first. If the app can't take it, the chat's own
    /// hook hands it over with the next message.
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
                try Self.openURL(
                    Self.appLink(.codex, id: thread, isClaudeAppInstalled: false, isCodexAppInstalled: true)
                        ?? "codex://threads/\(thread)"
                )
            } catch {
                hub.log("Couldn't open the Codex chat \(thread): \(error.localizedDescription)")
            }
            Thread.sleep(forTimeInterval: 5)
            outcome = CodexApp.startTurn(thread: thread, text: text, pictures: pictures)
        }
        if outcome == .started {
            handedOver(report)
            hub.log("Sent report \(source.reportID) with \(pictures.count) pictures to the Codex chat \(thread)")
            record(
                .init(
                    agent: .codex,
                    chat: thread,
                    title: CodexThreads.title(of: thread, in: CodexThreads.newestDatabase()) ?? "Codex chat",
                    kind: .sent
                ),
                for: report
            )
            Self.notify(title: Self.reportTitle(source), message: "Sent to the Codex chat, with its pictures.")
            return
        }
        // Saved before the report is free, so a claim the chat's hook makes is always newer than this.
        record(
            .init(
                agent: .codex,
                chat: thread,
                title: CodexThreads.title(of: thread, in: CodexThreads.newestDatabase()) ?? "Codex chat",
                kind: .nextMessage
            ),
            for: report
        )
        do {
            // Addressed before it's let go, so no other chat takes it in between.
            try Inbox.setRecipient(ReportRecipient(chat: chat.id, agent: chat.agent, folder: ""), of: report.folder)
        } catch {
            hub.log(
                "Couldn't address report \(source.reportID) to the Codex chat \(thread): \(error.localizedDescription)"
            )
        }
        release(report)
        hub.log(
            "The Codex app didn't take report \(source.reportID) (\(outcome)); it goes in with the chat's next message"
        )
        Self.notify(title: Self.reportTitle(source), message: "Goes to the Codex chat with your next message there.")
    }

    /// Opens a Claude Code chat the claude command made: in the desktop app with
    /// `claude --desktop --resume`, or in a terminal without the app.
    ///
    /// Once the chat is open, sends it the report through its socket, so the user sees it start. If
    /// the chat doesn't open in time, the report goes in with the claude command instead.
    /// `isReopening` is a chat that closed, rather than one the hub just started.
    private func openClaude(
        _ id: String,
        in folder: String,
        thenSend text: String,
        for report: InboxReport,
        pick: String? = nil,
        isReopening: Bool = false
    ) {
        let source = report.source
        guard let claude = AgentCommand.locate(.claude) else {
            pickSettled(pick)
            leaveWaiting(report, agent: .claude, chat: id, because: "Couldn't find the claude command")
            release(report)
            hub.log(
                "Couldn't find the claude command to open the chat for report \(source.reportID); it waits in the inbox"
            )
            return
        }
        let hasApp = AgentCommand.isClaudeAppInstalled()
        do {
            if hasApp {
                // claude --desktop refuses to run without a terminal; script gives it one.
                try Self.run(
                    "/usr/bin/script",
                    arguments: ["-q", "/dev/null", claude.path, "--desktop", "--resume", id],
                    in: folder
                )
            } else {
                try Self.openTerminal(in: folder, running: claude.path, arguments: ["--resume"], with: id)
            }
            hub.log("Opened the Claude Code chat \(id) in \(hasApp ? "the Claude app" : "a terminal"), in \(folder)")
        } catch {
            // The report still goes in below: through the socket if the chat opens anyway, else
            // with the claude command.
            hub.log(
                "Couldn't open the Claude Code chat \(id) in \(hasApp ? "the Claude app" : "a terminal"): \(error.localizedDescription)"
            )
        }
        let place = Self.folderName(folder)
        let kind: ChatDelivery.Kind = isReopening ? .sent : .newChat
        let title = isReopening ? place : "New chat in \(place)"
        queue.async { [self] in
            defer { pickSettled(pick) }
            for _ in 0..<60 {
                if let session = ClaudeSessions.openSessions().first(where: { $0.id == id }),
                    ClaudeSessions.send(text, to: session)
                {
                    handedOver(report)
                    hub.log("Sent report \(source.reportID) to the Claude Code chat \(id), now open")
                    record(.init(agent: .claude, chat: id, title: session.title ?? title, kind: kind), for: report)
                    Self.notify(
                        title: Self.reportTitle(source),
                        message:
                            "Claude Code is looking into it in \(hasApp ? "the Claude app" : "Terminal"), in worktree \(place)."
                    )
                    return
                }
                Thread.sleep(forTimeInterval: 1)
            }
            // Not open after a minute: the report goes in anyway, and shows when the chat is opened.
            hub.log(
                "The Claude Code chat \(id) didn't open in time; giving it report \(source.reportID) with the claude command"
            )
            let isTaken: Bool
            do {
                isTaken = try Self.run(
                    claude.path,
                    arguments: ["-p", text, "--resume", id, "--permission-mode", "plan"],
                    in: folder
                )
            } catch {
                hub.log("Couldn't run the claude command for report \(source.reportID): \(error.localizedDescription)")
                isTaken = false
            }
            guard isTaken else {
                // Such as when the claude command's sign-in expired: the chat doesn't have it.
                leaveWaiting(report, agent: .claude, chat: id, because: "Claude Code didn't take it")
                release(report)
                hub.log(
                    "The claude command didn't give report \(source.reportID) to the Claude Code chat \(id); it waits in the inbox"
                )
                Self.notify(
                    title: Self.reportTitle(source),
                    message: "Claude Code didn't take it. It waits in the inbox."
                )
                return
            }
            handedOver(report)
            // The claim names the folder the chat was started from, not its worktree: this says
            // where it ran.
            record(.init(agent: .claude, chat: id, title: title, kind: kind), for: report)
            Self.notify(
                title: Self.reportTitle(source),
                message: "Claude Code looked into it. Open the chat in worktree \(place) to see it."
            )
        }
    }

    /// The claude command, which starts new Claude Code chats, isn't signed in: the report waits
    /// in the inbox, and the Mac says what to run once.
    private func waitForClaudeSignIn(_ report: InboxReport) {
        let source = report.source
        hub.log(
            "Report \(source.reportID) waits: the claude command that starts new chats isn't signed in or is older than \(ClaudeCLI.desktopVersion.map(String.init).joined(separator: "."))"
        )
        leaveWaiting(report, agent: .claude, chat: nil, because: "Waiting for claude auth login")
        Self.notify(
            title: Self.reportTitle(source),
            message:
                "To start new Claude Code chats, run claude auth login once in Terminal. The report waits until then."
        )
    }

    // MARK: - New chats

    /// Starts a chat with the report, in a worktree of its own made from `folder`, the worktree
    /// the app was built from. `pick` is the phone's "New chat" pick, remembered with the new chat.
    private func startChat(_ agent: Agent, in folder: String, for report: InboxReport, pick: String? = nil) {
        let source = report.source
        guard let executable = AgentCommand.locate(agent) else {
            pickSettled(pick)
            hub.log("Couldn't find \(agent.name)'s command to start a chat for report \(source.reportID)")
            leaveWaiting(report, agent: agent, chat: nil, because: "Couldn't find the \(agent.name) command")
            Self.notify(
                title: Self.reportTitle(source),
                message: "Couldn't find \(agent.name) to start a chat. The report waits in the inbox."
            )
            return
        }
        let chat = Self.claimant(
            id: ChatID.started(agent, report: report.folder),
            agent: agent,
            folder: folder,
            bundleID: source.bundleID
        )
        guard claim(report, for: chat) else {
            pickSettled(pick)
            return
        }

        // A new chat works in a worktree of its own. Without one it would work in the user's
        // checkout, so it doesn't start and the report waits in the inbox.
        let workFolder: String
        do {
            workFolder = try NewWorktree.create(from: folder, name: "report-\(source.reportID)", agent: agent)
            hub.log("Made worktree \(workFolder) for report \(source.reportID)")
            do {
                try Inbox.moveClaim(of: report.folder, to: workFolder)
            } catch {
                hub.log(
                    "Couldn't record worktree \(workFolder) in report \(source.reportID)'s claim: \(error.localizedDescription)"
                )
            }
        } catch {
            pickSettled(pick)
            leaveWaiting(report, agent: agent, chat: nil, because: "Couldn't make a worktree")
            release(report)
            hub.log(
                "Couldn't make a worktree for report \(source.reportID): \(error.localizedDescription); it waits in the inbox"
            )
            Self.notify(
                title: Self.reportTitle(source),
                message:
                    "Couldn't make a worktree for a new \(agent.name) chat from the main branch of \(Self.folderName(folder)). The report waits in the inbox."
            )
            return
        }
        let pictures = ReportContent.pictures(in: report.folder)
        var reportPrompt = ReportContent.text(for: report)
        // A Claude Code chat reads the pictures from a copy in its worktree, without asking.
        if agent == .claude {
            do {
                let copy = try NewWorktree.copyReport(report.folder, into: workFolder)
                reportPrompt = reportPrompt.replacing(report.folder.path, with: copy)
            } catch {
                hub.log(
                    "Couldn't copy report \(source.reportID) into \(workFolder): \(error.localizedDescription); the chat reads it from the inbox"
                )
            }
        }
        // A Claude Code chat is only opened by the claude command, with a line that takes
        // seconds; it moves into the desktop app at once and gets the report there, where the
        // user watches it work. The app doesn't move a chat that's still running.
        let reportText = reportPrompt
        let prompt =
            switch agent {
            case .claude: "A UI report from the user's device comes in the next message. Reply with just: Ready."
            case .codex: reportPrompt
            }
        let output = report.folder.appending(path: Inbox.newChatOutputFile)
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let process = Process()
        process.executableURL = executable
        process.arguments = AgentCommand.arguments(agent, folder: workFolder, prompt: prompt, pictures: pictures)
        process.currentDirectoryURL = URL(filePath: workFolder)
        process.environment = ProcessInfo.processInfo.environment.merging([AgentHooks.startedByHub: "1"]) { $1 }
        process.standardInput = FileHandle.nullDevice
        do {
            let handle = try FileHandle(forWritingTo: output)
            process.standardOutput = handle
            process.standardError = handle
        } catch {
            hub.log(
                "Couldn't keep what the \(agent.name) command prints for report \(source.reportID): \(error.localizedDescription)"
            )
        }
        let paths = hub.paths
        let place = Self.folderName(workFolder)
        process.terminationHandler = { [hub, self] finished in
            let text = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
            let started = AgentCommand.startedChat(agent, in: text)
            guard finished.terminationStatus == 0, let started, !started.didFail else {
                // Free the report for a chat that opens later, and take back the unused worktree.
                let reason = AgentCommand.failure(in: text)
                leaveWaiting(report, agent: agent, chat: nil, because: "Couldn't start the chat: \(reason)")
                release(report)
                NewWorktree.remove(workFolder)
                pickSettled(pick)
                hub.log(
                    "The \(agent.name) chat for report \(source.reportID) failed (\(finished.terminationStatus)): \(reason)"
                )
                Self.notify(
                    title: "Couldn't start a \(agent.name) chat",
                    message: "\(reason). The report waits in the inbox."
                )
                return
            }
            // Later reports with the same pick go to this chat.
            if let pick {
                do {
                    try StartedChats.remember(
                        StartedChat(chat: started.chat, folder: workFolder, startedAt: .now),
                        for: pick,
                        paths: paths
                    )
                } catch {
                    hub.log(
                        "Couldn't remember the chat for the phone's pick \(pick); its next report starts another: \(error.localizedDescription)"
                    )
                }
            }
            if let answer = started.answer {
                do {
                    try answer.write(
                        to: report.folder.appending(path: Inbox.answerFile),
                        atomically: true,
                        encoding: .utf8
                    )
                } catch {
                    hub.log("Couldn't save the answer to report \(source.reportID): \(error.localizedDescription)")
                }
            }
            switch agent {
            case .codex:
                // The chat has the report: it was its first message. A Claude Code chat has it only once
                // it is sent into the open chat.
                handedOver(report)
                pickSettled(pick)
                do {
                    try Self.openChat(.codex, id: started.chat, in: workFolder)
                } catch {
                    hub.log("Couldn't open the Codex chat \(started.chat): \(error.localizedDescription)")
                }
                hub.log("The Codex chat \(started.chat) in \(workFolder) looked into report \(source.reportID)")
                record(
                    .init(agent: .codex, chat: started.chat, title: "New chat in \(place)", kind: .newChat),
                    for: report
                )
                Self.notify(title: "Codex looked into a report", message: "Opened in Codex, in worktree \(place).")
            case .claude:
                // Reports waiting for this pick follow once this one is in the open chat.
                openClaude(started.chat, in: workFolder, thenSend: reportText, for: report, pick: pick)
            }
        }
        do {
            try process.run()
            hub.log("Started a \(agent.name) chat in \(workFolder) for report \(source.reportID)")
            Self.notify(
                title: "\(agent.name) is looking into a report",
                message: "From \(source.deviceName), in worktree \(place)."
            )
        } catch {
            leaveWaiting(report, agent: agent, chat: nil, because: "Couldn't start the chat")
            release(report)
            NewWorktree.remove(workFolder)
            pickSettled(pick)
            hub.log("Couldn't start a \(agent.name) chat for report \(source.reportID): \(error.localizedDescription)")
        }
    }

    private static func folderName(_ path: String) -> String {
        URL(filePath: path).lastPathComponent
    }

    // MARK: - Notifications

    /// Shows a notification.
    ///
    /// Inside Redline.app it comes from Redline; the bare command has no app of its own, so it goes
    /// through osascript.
    static func notify(title: String, message: String) {
        if Bundle.main.bundleURL.pathExtension == "app" {
            // The app asks for permission when it starts, but a report can arrive before the
            // user answers. Asking again waits for that answer (macOS shows the prompt only
            // once), so the notification is added only once it's allowed and isn't lost.
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { isGranted, _ in
                guard isGranted else { return }
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = message
                UNUserNotificationCenter.current().add(
                    UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                )
            }
            return
        }
        func quoted(_ text: String) -> String {
            "\"" + text.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"") + "\""
        }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/osascript")
        process.arguments = ["-e", "display notification \(quoted(message)) with title \(quoted(title))"]
        // A notification that can't be shown is left out; the log says what happened.
        try? process.run()
    }
}
#endif
