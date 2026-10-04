#if os(macOS)
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
#endif
