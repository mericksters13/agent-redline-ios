#if AGENT_REDLINE
import Foundation

/// Where the app was built, so the Mac can send a report to the chat working there.
enum BuildIdentity {
    /// The project file that attached the kit, filled in by the compiler at the call site. It
    /// names the worktree the app was built from, and keys the destination the user picked.
    nonisolated(unsafe) static var sourceFile: String?
}
#endif
