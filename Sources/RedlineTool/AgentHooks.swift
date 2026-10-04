#if os(macOS)
import Darwin
import Foundation

/// The agents reports go to: Claude Code and Codex.
enum Agent: String, CaseIterable, Sendable {
    case claude, codex

    var name: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }
}

/// The hook events this tool takes, as its hook settings name them.
enum HookEvent: String, Sendable {
    /// The user sent a message (Codex): hand over reports sent to this chat.
    case prompt
}

/// Which chat a hook call is for, and its folder, from the agent's JSON.
struct HookInput: Equatable {
    var chat: String
    var folder: String

    init?(json: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let id = object["session_id"] as? String, let cwd = object["cwd"] as? String
        else { return nil }
        chat = id
        folder = cwd
    }
}

enum AgentHooks {
    /// Set for chats the hub starts itself. Their hooks stay out of the way: such a chat runs
    /// once and ends, and must not take other reports.
    static let startedByHub = "REDLINE_STARTED_CHAT"

    /// Runs one hook call and returns the exit code for the agent.
    static func run(_ agent: Agent, _ event: HookEvent, paths: HubPaths) -> Int32 {
        let input = HookInput(json: FileHandle.standardInput.readDataToEndOfFile())
        guard let input, ProcessInfo.processInfo.environment[startedByHub] == nil else { return answer(event, nil) }
        let id = ChatID.make(agent, input.chat)
        let folder = URL(fileURLWithPath: input.folder)

        let session = ChatSession(paths: paths, folder: folder, extraApps: [], agent: agent.rawValue, id: id, pid: AgentProcess.find())
        // Not an app project: nothing to do, in every project the agent opens.
        guard !session.chat.bundleIDs.isEmpty else { return answer(event, nil) }

        switch event {
        case .prompt:
            session.touch()
            return answer(event, session.takeAddressed())
        }
    }

    /// Prints what the agent expects from this event, carrying `text` when there is any.
    static func answer(_ event: HookEvent, _ text: String?) -> Int32 {
        if let output = output(event, text),
           let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .withoutEscapingSlashes]) {
            FileHandle.standardOutput.write(data + Data("\n".utf8))
        }
        return 0
    }

    /// The output for each event; Claude Code and Codex share one shape.
    static func output(_ event: HookEvent, _ text: String?) -> [String: Any]? {
        switch event {
        case .prompt:
            text.map { ["hookSpecificOutput": ["hookEventName": "UserPromptSubmit", "additionalContext": $0]] }
        }
    }
}

/// Finds the process a chat lives in, from a hook that runs as its child.
enum AgentProcess {
    /// The nearest ancestor that isn't a shell started to run the hook.
    static func find() -> Int32 {
        var pid = getppid()
        while let (parent, name) = info(pid), shells.contains(name), parent > 1 {
            pid = parent
        }
        return pid
    }

    private static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "env"]

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
