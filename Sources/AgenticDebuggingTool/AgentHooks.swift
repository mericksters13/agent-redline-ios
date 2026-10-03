#if os(macOS)
import Darwin
import Foundation

/// The agents whose chats get reports through their own hooks, with nothing for the user to
/// run or ask. Each runs `agentic-debugging hook <agent> <event>` with the event's JSON on
/// standard input.
enum Agent: String, CaseIterable, Sendable {
    case claude, codex, cursor

    var name: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        }
    }
}

/// The hook events this tool takes, as its hook settings name them.
enum HookEvent: String, Sendable {
    /// A chat opened: register it and tell the agent about reports.
    case start
    /// The user sent a message: the chat becomes the one used most recently, and gets any
    /// report already waiting.
    case prompt
    /// Claude Code, in the background: wait for a report, then wake the chat with it, even
    /// when it's idle.
    case wait
    /// Codex and Cursor, whose hooks can't wake an idle chat: when the agent finishes a reply,
    /// keep the chat open for a while and continue it with a report that arrives.
    case stop
    /// The chat closed.
    case end
}

/// Which chat a hook call is for, and its folder, from the agent's JSON.
struct HookInput: Equatable {
    var chat: String
    var folder: String

    init?(_ agent: Agent, json: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return nil }
        switch agent {
        case .claude, .codex:
            guard let id = object["session_id"] as? String, let cwd = object["cwd"] as? String else { return nil }
            chat = id
            folder = cwd
        case .cursor:
            guard let id = object["conversation_id"] as? String ?? object["session_id"] as? String,
                  let root = (object["workspace_roots"] as? [String])?.first ?? object["cwd"] as? String
            else { return nil }
            chat = id
            folder = root
        }
    }
}

enum AgentHooks {
    /// Set for chats the hub starts itself. Their hooks stay out of the way: such a chat runs
    /// once and ends, and must not be held open or take other reports.
    static let startedByHub = "AGENTIC_DEBUGGING_STARTED_CHAT"
    /// How long a Codex or Cursor chat stays open for reports after the agent replies.
    static let holdOpen: TimeInterval = 1800

    /// Runs one hook call and returns the exit code for the agent.
    static func run(_ agent: Agent, _ event: HookEvent, paths: HubPaths) -> Int32 {
        let input = HookInput(agent, json: FileHandle.standardInput.readDataToEndOfFile())
        let startedByHub = ProcessInfo.processInfo.environment[startedByHub] != nil
        guard let input else { return answer(agent, event, nil) }
        let session = ChatSession(paths: paths, folder: URL(fileURLWithPath: input.folder), extraApps: [], agent: agent.rawValue,
                                  id: "\(agent.rawValue)-\(input.chat)", pid: AgentProcess.find(agent, chat: input.chat))
        // Not an app project: nothing to do, in every project the agent opens.
        guard !session.chat.bundleIDs.isEmpty else { return answer(agent, event, nil) }

        switch event {
        case .start:
            if !startedByHub {
                session.register()
                ProjectHistory.note(session.chat, paths: paths)
            }
            return answer(agent, event, startContext(apps: session.chat.bundleIDs))

        case .prompt:
            guard !startedByHub else { return answer(agent, event, nil) }
            session.touch()
            ProjectHistory.note(session.chat, paths: paths)
            return answer(agent, event, session.takeText().map(reportPrompt))

        case .wait:
            guard !startedByHub, let lock = WaitLock(chat: session.chat.id, paths: paths) else { return 0 }
            session.registerWaiting()
            stopWhenChatCloses(session.chat.pid)
            let waiter = ChatSession.Waiter()
            while session.waitForRoutedReport(timeout: nil, waiter: waiter) {
                guard let text = session.takeText() else { continue }
                // Exit code 2 wakes the chat; Claude Code shows it standard error.
                FileHandle.standardError.write(Data(reportPrompt(text).utf8))
                withExtendedLifetime(lock) {}
                return 2
            }
            return 0

        case .stop:
            guard !startedByHub else { return answer(agent, event, nil) }
            if let text = session.takeText() { return answer(agent, event, reportPrompt(text)) }
            // Already held open by an earlier call for this chat.
            guard let lock = WaitLock(chat: session.chat.id, paths: paths) else { return answer(agent, event, nil) }
            session.registerWaiting()
            let waiter = ChatSession.Waiter()
            let deadline = Date().addingTimeInterval(holdOpen)
            while session.waitForRoutedReport(timeout: deadline.timeIntervalSinceNow, waiter: waiter) {
                guard let text = session.takeText() else { continue }
                withExtendedLifetime(lock) {}
                return answer(agent, event, reportPrompt(text))
            }
            return answer(agent, event, nil)

        case .end:
            session.unregister()
            return 0
        }
    }

    /// Prints what the agent expects from this event, carrying `text` when there is any.
    static func answer(_ agent: Agent, _ event: HookEvent, _ text: String?) -> Int32 {
        if let output = output(agent, event, text),
           let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .withoutEscapingSlashes]) {
            FileHandle.standardOutput.write(data + Data("\n".utf8))
        }
        return 0
    }

    /// Each agent's output for each event. Claude Code and Codex share one shape; Cursor has its own.
    static func output(_ agent: Agent, _ event: HookEvent, _ text: String?) -> [String: Any]? {
        switch (agent, event) {
        case (.cursor, .prompt):
            // Cursor's prompt hook can't add text; a waiting report goes in at the next stop.
            return ["continue": true]
        case (.cursor, .start):
            return text.map { ["additional_context": $0] }
        case (.cursor, .stop):
            return text.map { ["followup_message": $0] }
        case (_, .start):
            return text.map { ["hookSpecificOutput": ["hookEventName": "SessionStart", "additionalContext": $0]] }
        case (_, .prompt):
            return text.map { ["hookSpecificOutput": ["hookEventName": "UserPromptSubmit", "additionalContext": $0]] }
        case (_, .stop):
            return text.map { ["decision": "block", "reason": $0] }
        default:
            return nil
        }
    }

    static func startContext(apps: [String]) -> String {
        """
        This project builds \(apps.joined(separator: ", ")). The user sends UI reports about it from an iPhone or a simulator \
        with iOSAgenticDebuggingKit, and they arrive in this chat by themselves. In a report, each note is about one element \
        on screen, outlined and numbered the same way in the report's pictures, which are image files you can open.
        """
    }

    /// What the agent reads when a report arrives.
    static func reportPrompt(_ report: String) -> String {
        """
        A UI report arrived from the user's device through iOSAgenticDebuggingKit. Open its pictures, find the code for each \
        noted element by its identifier or label, then tell the user what you found and propose a fix before changing code.

        \(report)
        """
    }

    /// Ends this process when the chat's process ends, so no wait outlives its chat.
    private static func stopWhenChatCloses(_ pid: Int32) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        source.setEventHandler { exit(0) }
        source.resume()
        ChatProcessWatch.source = source
    }

    private enum ChatProcessWatch {
        nonisolated(unsafe) static var source: DispatchSourceProcess?
    }
}

/// Finds the process a chat lives in, from a hook that runs as its child.
enum AgentProcess {
    static func find(_ agent: Agent, chat: String) -> Int32 {
        if agent == .claude, let pid = claudeSession(chat) { return pid }
        // The nearest ancestor that isn't a shell started to run the hook.
        var pid = getppid()
        while let (parent, name) = info(pid), shells.contains(name), parent > 1 {
            pid = parent
        }
        return pid
    }

    private static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "env"]

    /// Claude Code keeps a file per open session with its process.
    private static func claudeSession(_ id: String) -> Int32? {
        let folders = [ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], NSHomeDirectory() + "/.claude"].compactMap { $0 }
        for folder in folders {
            let sessions = URL(fileURLWithPath: folder).appending(path: "sessions", directoryHint: .isDirectory)
            for file in (try? FileManager.default.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["sessionId"] as? String == id, let pid = object["pid"] as? Int
                else { continue }
                return Int32(pid)
            }
        }
        return nil
    }

    private static func info(_ pid: Int32) -> (parent: Int32, name: String)? {
        var process = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &process, &size, nil, 0) == 0, size > 0 else { return nil }
        let name = withUnsafeBytes(of: process.kp_proc.p_comm) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return (process.kp_eproc.e_ppid, name)
    }
}
#endif
