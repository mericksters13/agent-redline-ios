#if os(macOS)
import AppKit

extension HubWindowModel {
    /// An agent installed on this Mac, and whether reports reach its chats now.
    struct AgentRow: Identifiable, Equatable, Sendable {
        /// How delivery to the agent stands.
        enum Health: Equatable, Sendable {
            /// Not known yet: the first check is under way.
            case checking
            case working
            /// Nothing is broken, but reports arrive later: with each chat's next message.
            case limited
            /// Something needs fixing; until then, reports arrive later or wait in the inbox, as
            /// `advice` says.
            case broken
        }

        var id: String
        var name: String
        /// "Ready", or what is wrong, short.
        var state: String
        var health: Health
        /// What happens to reports meanwhile and what to do, in one line; nil while delivery works.
        var advice: String?
        /// The command to run in Terminal for it, shown on a line of its own to copy; nil when there
        /// is none.
        var command: String?

        init(_ agent: Agent, state: String, health: Health, advice: String? = nil, command: String? = nil) {
            id = agent.rawValue
            name = agent.name
            self.state = state
            self.health = health
            self.advice = advice
            self.command = command
        }
    }

    /// Where the panel checks the agents: the checks run commands and wait on sockets, which must
    /// hold up neither the main actor nor the panel's refreshes.
    private nonisolated static let checker = DispatchQueue(label: "Redline.panel.checker", qos: .utility)

    /// The agents installed on this Mac, the ones the phone offers, read off the main actor.
    ///
    /// Add @concurrent when the tools version reaches 6.2.
    nonisolated static func loadInstalledAgents() async -> [Agent] {
        await withCheckedContinuation { continuation in
            checker.async { continuation.resume(returning: ChatDirectory.agents()) }
        }
    }

    /// A row for each of `agents`, from checking the path delivery takes to its chats, the same way
    /// delivery takes it.
    ///
    /// Runs off the main actor. Add @concurrent when the tools version reaches 6.2.
    nonisolated static func loadAgentRows(_ agents: [Agent]) async -> [AgentRow] {
        await withCheckedContinuation { continuation in
            checker.async {
                let rows = agents.map { agent in
                    switch agent {
                    case .claude:
                        return claudeRow(ClaudeCLI.checkReadiness(recheckingFailure: true))
                    case .codex:
                        let app = AgentCommand.codexApp()
                        return codexRow(
                            CodexApp.checkHandshake(),
                            appName: app?.deletingPathExtension().lastPathComponent,
                            isAppRunning: app.map(isRunning) ?? false
                        )
                    }
                }
                continuation.resume(returning: rows)
            }
        }
    }

    /// An app runs from `app`, which tells a Codex app that is closed from one whose socket is gone,
    /// as after an update that moved it.
    private nonisolated static func isRunning(_ app: URL) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.path == app.path }
    }

    /// Claude Code's row, from the claude command that starts new chats and reopens closed ones.
    ///
    /// An open chat takes reports through its own socket, which needs no command.
    nonisolated static func claudeRow(_ readiness: ClaudeCLI.Readiness) -> AgentRow {
        /// A failed check's row: reports wait until the user runs the command for `need`.
        func broken(_ state: String, need: ClaudeCLI.Need) -> AgentRow {
            AgentRow(
                .claude,
                state: state,
                health: .broken,
                advice: "Reports for new or closed chats wait in the inbox. To fix, run:",
                command: ClaudeCLI.command(for: need)
            )
        }
        return switch readiness {
        case .ready: AgentRow(.claude, state: "Ready", health: .working)
        case .doesNotRun: broken("Command doesn't run", need: .install)
        case .needs(.install): broken("Command not found", need: .install)
        case .needs(.update): broken("Command too old", need: .update)
        case .needs(.signIn): broken("Not signed in", need: .signIn)
        }
    }

    /// Codex's row, from the handshake with the Codex app, which starts every report's turn in an
    /// open chat. `appName` is the app as the Dock shows it, such as ChatGPT; nil when it isn't
    /// installed.
    ///
    /// Without the app, a report goes in with the chat's next message, through the hook setup adds.
    nonisolated static func codexRow(
        _ handshake: CodexApp.Handshake,
        appName: String?,
        isAppRunning: Bool
    ) -> AgentRow {
        let meanwhile = "Reports go in with each chat's next message"
        let app = appName ?? "Codex"
        return switch handshake {
        case .answered:
            AgentRow(.codex, state: "Ready", health: .working)
        // A running app that nothing answers for is broken, whether its socket is gone or silent.
        case .notListening where isAppRunning, .notAnswering:
            AgentRow(.codex, state: "App not answering", health: .broken, advice: "\(meanwhile). Reopen \(app).")
        case .notListening where appName == nil:
            AgentRow(.codex, state: "App not installed", health: .limited, advice: "\(meanwhile).")
        case .notListening:
            AgentRow(.codex, state: "App not running", health: .limited, advice: "\(meanwhile) until \(app) is open.")
        }
    }
}
#endif
