#if os(macOS)
import Foundation
import Synchronization

/// The `claude` command, which starts a new chat by itself and moves it into the desktop app with
/// `--desktop --resume`.
///
/// It has its own sign-in, separate from the desktop app's.
enum ClaudeCLI {
    /// The first version with `--desktop`.
    static let desktopVersion = [2, 1, 285]
    /// The last check, so `ready()` runs the command at most every minute.
    private static let lastCheck = Mutex<ReadinessCheck?>(nil)

    private struct ReadinessCheck {
        var isReady: Bool
        var checkedAt: Date
    }

    /// Signed in with `claude auth login`, and, with the desktop app installed, new enough to open
    /// a chat in it.
    ///
    /// Checked at most every minute.
    static func isReady() -> Bool {
        if let check = lastCheck.withLock({ $0 }), Date.now.timeIntervalSince(check.checkedAt) < 60 {
            return check.isReady
        }
        guard let claude = AgentCommand.locate(.claude) else { return false }
        let signedIn = runForOutput(claude, ["auth", "status"]) != nil
        let version = runForOutput(claude, ["--version"]).flatMap { version(in: $0) } ?? []
        let ready =
            signedIn && (!AgentCommand.isClaudeAppInstalled() || !version.lexicographicallyPrecedes(desktopVersion))
        lastCheck.withLock { $0 = ReadinessCheck(isReady: ready, checkedAt: .now) }
        return ready
    }

    /// What the claude command still needs before it can start new chats.
    enum Need: Equatable {
        case install, update, signIn
    }

    /// What the claude command still needs, in the order to do it; empty when it is ready.
    static func needs(isInstalled: Bool, version: [Int], isSignedIn: Bool, isClaudeAppInstalled: Bool) -> [Need] {
        guard isInstalled else { return [.install] }
        var needs: [Need] = []
        if isClaudeAppInstalled, version.lexicographicallyPrecedes(desktopVersion) { needs.append(.update) }
        if !isSignedIn { needs.append(.signIn) }
        return needs
    }

    /// For setup: the claude command installed, new enough for the desktop app, and signed in.
    ///
    /// When `isAsking`, runs `claude update` and `claude auth login` in this terminal as needed.
    /// Prints what the user must still do, and never stops setup. False when something is still
    /// missing.
    static func prepare(isAsking: Bool) -> Bool {
        let claude = AgentCommand.locate(.claude)
        let isClaudeAppInstalled = AgentCommand.isClaudeAppInstalled()
        func missing() -> [Need] {
            guard let claude else {
                return needs(
                    isInstalled: false,
                    version: [],
                    isSignedIn: false,
                    isClaudeAppInstalled: isClaudeAppInstalled
                )
            }
            return needs(
                isInstalled: true,
                version: runForOutput(claude, ["--version"]).flatMap { version(in: $0) } ?? [],
                isSignedIn: runForOutput(claude, ["auth", "status"]) != nil,
                isClaudeAppInstalled: isClaudeAppInstalled
            )
        }
        var left = missing()
        if isAsking, let claude, !left.isEmpty {
            if left.contains(.update) {
                print(
                    "Updating the claude command: opening new chats in the Claude app needs \(desktopVersionText) or later."
                )
                _ = runInteractively(claude, ["update"])
            }
            if left.contains(.signIn) {
                print(
                    "Sign in the claude command: it starts new Claude Code chats for reports, and keeps its own sign-in, separate from the Claude app's."
                )
                _ = runInteractively(claude, ["auth", "login"])
            }
            left = missing()
        }
        for need in left { print(instruction(for: need)) }
        lastCheck.withLock { $0 = nil }
        return left.isEmpty
    }

    /// What the user runs for a need, with why.
    static func instruction(for need: Need) -> String {
        switch need {
        case .install:
            """
            Claude Code: the claude command isn't installed. It starts new Claude Code chats for reports. Install it, then run setup again:
              curl -fsSL https://claude.ai/install.sh | bash
            """
        case .update:
            """
            Claude Code: the claude command is too old to open new chats in the Claude app (\(desktopVersionText) or later). Update it:
              claude update
            """
        case .signIn:
            """
            Claude Code: the claude command isn't signed in. It starts new Claude Code chats for reports, and keeps its own sign-in, separate from the Claude app's. Sign it in:
              claude auth login
            """
        }
    }

    /// `desktopVersion` as text, such as "2.1.285".
    private static var desktopVersionText: String {
        desktopVersion.map(String.init).joined(separator: ".")
    }

    /// Runs the command in this terminal, so the user can answer it.
    ///
    /// True when it succeeds.
    private static func runInteractively(_ executable: URL, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        do {
            try process.run()
        } catch {
            printError("Couldn't run \(executable.path): \(error.localizedDescription)")
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// "2.1.289 (Claude Code)" as [2, 1, 289].
    static func version(in text: String) -> [Int]? {
        let numbers = text.split(separator: " ").first?.split(separator: ".").compactMap { Int($0) } ?? []
        return numbers.count == 3 ? numbers : nil
    }

    /// The command's output when it succeeds.
    private static func runForOutput(_ executable: URL, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            printError("Couldn't run \(executable.path): \(error.localizedDescription)")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
#endif
