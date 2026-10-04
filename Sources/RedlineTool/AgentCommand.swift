#if os(macOS)
import Foundation

/// Starting a chat with each agent from the command line.
///
/// Each runs without permission to change files, so the chat can only look and propose.
enum AgentCommand {
    /// Claude's desktop app, where new Claude Code chats open, is installed.
    ///
    /// Checks the disk.
    static func isClaudeAppInstalled() -> Bool {
        FileManager.default.fileExists(atPath: "/Applications/Claude.app")
    }

    /// Codex's desktop app, inside the ChatGPT app or on its own, is installed.
    ///
    /// Checks the disk.
    static func isCodexAppInstalled() -> Bool {
        ["/Applications/ChatGPT.app/Contents/Resources/codex-cli", "/Applications/Codex.app"].contains {
            FileManager.default.fileExists(atPath: $0)
        }
    }

    /// The agent's command, from the places its installers put it; nil when it isn't installed.
    static func locate(_ agent: Agent) -> URL? {
        let home = URL.homeDirectory.path
        let candidates: [String]
        switch agent {
        case .claude:
            candidates = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        case .codex:
            // The copy inside the ChatGPT app comes first: it updates with the app.
            candidates = [
                "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                "/Applications/Codex.app/Contents/Resources/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                "\(home)/.local/bin/codex",
            ]
        }
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:))
    }

    /// The arguments that start a chat in `folder` with `prompt`, read-only, printing JSON.
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

    /// What a command line run printed about the chat it started.
    struct StartedChatOutput: Equatable {
        var chat: String
        /// The chat's answer, when the run gives one.
        var answer: String?
        /// The run reported an error.
        var didFail: Bool
    }

    /// The chat a command line run started.
    ///
    /// Codex reports it in the first event of `codex exec --json`, and Claude Code in the result
    /// that `claude -p --output-format json` prints.
    static func startedChat(_ agent: Agent, in output: String) -> StartedChatOutput? {
        for line in output.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                continue
            }
            switch agent {
            case .codex:
                if object["type"] as? String == "thread.started", let thread = object["thread_id"] as? String {
                    return StartedChatOutput(chat: thread, answer: nil, didFail: false)
                }
            case .claude:
                if let session = object["session_id"] as? String ?? object["chatId"] as? String {
                    return StartedChatOutput(
                        chat: session,
                        answer: object["result"] as? String,
                        didFail: object["is_error"] as? Bool ?? false
                    )
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
                if let error = (object["error"] as? [String: Any])?["message"] as? String ?? object["message"]
                    as? String
                {
                    return error
                }
                continue
            }
            let text = line.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { return String(text.prefix(200)) }
        }
        return "It stopped without saying why"
    }

}
#endif
