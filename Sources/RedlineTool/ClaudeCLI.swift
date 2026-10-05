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

    /// For setup, before anything else: the claude command installed, new enough for the desktop
    /// app, and signed in, running `claude update` and `claude auth login` in this terminal when
    /// needed.
    ///
    /// False when it still isn't ready, with what to do printed.
    static func prepare() -> Bool {
        guard let claude = AgentCommand.locate(.claude) else {
            print(
                "The claude command isn't installed. It starts new Claude Code chats for reports. Install it, then run setup again:"
            )
            print("  curl -fsSL https://claude.ai/install.sh | bash")
            return false
        }
        let version = runForOutput(claude, ["--version"]).flatMap { version(in: $0) } ?? []
        if AgentCommand.isClaudeAppInstalled(), version.lexicographicallyPrecedes(desktopVersion) {
            print(
                "Updating the claude command: opening new chats in the Claude app needs \(desktopVersion.map(String.init).joined(separator: ".")) or later."
            )
            _ = runInteractively(claude, ["update"])
        }
        if runForOutput(claude, ["auth", "status"]) == nil {
            print(
                "Sign in the claude command first: it starts new Claude Code chats for reports, and keeps its own sign-in, separate from the Claude app's."
            )
            guard runInteractively(claude, ["auth", "login"]), runForOutput(claude, ["auth", "status"]) != nil else {
                print("The claude command still isn't signed in. Run setup again after claude auth login.")
                return false
            }
        }
        lastCheck.withLock { $0 = nil }
        return isReady()
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
    ///
    /// One still running after `timeout` is stopped and counts as failed: the hub asks from its
    /// hand-off queue, which a stalled command would hold up.
    private static func runForOutput(
        _ executable: URL,
        _ arguments: [String],
        timeout: TimeInterval = 10
    ) -> String? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            printError("Couldn't run \(executable.path): \(error.localizedDescription)")
            return nil
        }
        // Read while it runs, so a long output can't fill the pipe and hold it up.
        let read = DispatchSemaphore(value: 0)
        let output = Mutex(Data())
        DispatchQueue.global(qos: .utility).async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            output.withLock { $0 = data }
            read.signal()
        }
        // Parks the caller's thread, the hand-off queue or setup's main thread and never a Task,
        // for at most `timeout`.
        let deadline = DispatchTime.now() + timeout
        guard exited.wait(timeout: deadline) == .success, read.wait(timeout: deadline) == .success else {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return output.withLock { String(decoding: $0, as: UTF8.self) }
    }
}
#endif
