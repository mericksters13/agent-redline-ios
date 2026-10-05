#if os(macOS)
import Darwin
import Foundation

/// Claude Code's open chats, from the file each keeps under `~/.claude/sessions`. Every chat
/// listens on a socket for messages from the user's other chats, and starts a turn with one
/// when it's idle. The hub uses it for a chat that isn't waiting for reports, such as one
/// opened before the hooks were added.
enum ClaudeSessions {
    struct Session: Equatable {
        var id: String
        var folder: String
        var socket: String
        var updatedAt: Date
        /// Not in the middle of a turn.
        var isIdle: Bool
        /// The chat's name in Claude Code, when it has one.
        var title: String? = nil
    }

    /// The interactive chats that are still running.
    static func open() -> [Session] {
        var sessions: [Session] = []
        for folder in configFolders {
            let files = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder).appending(path: "sessions"), includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file), let session = session(from: data) else { continue }
                sessions.append(session)
            }
        }
        return sessions
    }

    /// Where Claude Code keeps its chats: the configured folder, and the default one.
    static var configFolders: Set<String> {
        Set([ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], NSHomeDirectory() + "/.claude"].compactMap { $0 })
    }

    static func session(from data: Data) -> Session? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["sessionId"] as? String, let folder = object["cwd"] as? String,
              let socket = object["messagingSocketPath"] as? String, let pid = object["pid"] as? Int,
              object["kind"] as? String == "interactive"
        else { return nil }
        // A process that started after the chat did only reuses the chat's PID.
        let started = (object["startedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        guard started.map({ Chats.isRunning(Int32(pid), since: $0) }) ?? Chats.isRunning(Int32(pid)) else { return nil }
        let updated = (object["updatedAt"] as? Double) ?? (object["startedAt"] as? Double) ?? 0
        return Session(id: id, folder: folder, socket: socket, updatedAt: Date(timeIntervalSince1970: updated / 1000),
                       isIdle: object["status"] as? String == "idle", title: object["name"] as? String)
    }

    /// The line a chat's socket takes: one message, as if typed by another of the user's chats.
    static func line(_ text: String) -> Data {
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": text]]
        return ((try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes])) ?? Data()) + Data("\n".utf8)
    }

    /// Sends `text` to the chat. True once the chat's socket took it.
    static func send(_ text: String, to session: Session) -> Bool {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        // A chat closing mid-write fails the write instead of ending the hub with SIGPIPE.
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(session.socket.utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            path.withUnsafeBytes { bytes.copyMemory(from: $0) }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return false }
        let data = line(text)
        var sent = 0
        while sent < data.count {
            let written = data.withUnsafeBytes { write(descriptor, $0.baseAddress! + sent, data.count - sent) }
            guard written > 0 else { return false }
            sent += written
        }
        return true
    }
}
/// The `claude` command, which starts a new chat by itself and moves it into the desktop app
/// with `--desktop --resume`. It has its own sign-in, separate from the desktop app's.
enum ClaudeCLI {
    /// The first version with `--desktop`.
    static let desktopVersion = [2, 1, 285]
    private static let lock = NSLock()
    nonisolated(unsafe) private static var checked: (ready: Bool, at: Date)?

    /// Signed in with `claude auth login`, and, with the desktop app installed, new enough to open
    /// a chat in it. Checked at most every minute.
    static func ready() -> Bool {
        if let checked = lock.withLock({ checked }), Date().timeIntervalSince(checked.at) < 60 { return checked.ready }
        guard let claude = AgentCommand.locate(.claude) else { return false }
        let signedIn = output(claude, ["auth", "status"]) != nil
        let version = output(claude, ["--version"]).flatMap { version(in: $0) } ?? []
        let ready = signedIn && (!AgentCommand.hasClaudeApp || !version.lexicographicallyPrecedes(desktopVersion))
        lock.withLock { checked = (ready, Date()) }
        return ready
    }

    /// For setup, before anything else: the claude command installed, new enough for the desktop
    /// app, and signed in, running `claude update` and `claude auth login` in this terminal when
    /// needed. False when it still isn't ready, with what to do printed.
    static func prepare() -> Bool {
        guard let claude = AgentCommand.locate(.claude) else {
            print("The claude command isn't installed. It starts new Claude Code chats for reports. Install it, then run setup again:")
            print("  curl -fsSL https://claude.ai/install.sh | bash")
            return false
        }
        let version = output(claude, ["--version"]).flatMap { version(in: $0) } ?? []
        if AgentCommand.hasClaudeApp, version.lexicographicallyPrecedes(desktopVersion) {
            print("Updating the claude command: opening new chats in the Claude app needs \(desktopVersion.map(String.init).joined(separator: ".")) or later.")
            _ = interactive(claude, ["update"])
        }
        if output(claude, ["auth", "status"]) == nil {
            print("Sign in the claude command first: it starts new Claude Code chats for reports, and keeps its own sign-in, separate from the Claude app's.")
            guard interactive(claude, ["auth", "login"]), output(claude, ["auth", "status"]) != nil else {
                print("The claude command still isn't signed in. Setup stopped; run it again after claude auth login.")
                return false
            }
        }
        lock.withLock { checked = nil }
        return ready()
    }

    /// Runs the command in this terminal, so the user can answer it. True when it succeeds.
    private static func interactive(_ executable: URL, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// "2.1.289 (Claude Code)" as [2, 1, 289].
    static func version(in text: String) -> [Int]? {
        let numbers = text.split(separator: " ").first?.split(separator: ".").compactMap { Int($0) } ?? []
        return numbers.count == 3 ? numbers : nil
    }

    /// The command's output when it succeeds. One still running after `timeout` is stopped and
    /// counts as failed: the hub asks from its hand-off queue, which a stalled command would hold up.
    private static func output(_ executable: URL, _ arguments: [String], timeout: TimeInterval = 10) -> String? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        guard (try? process.run()) != nil else { return nil }
        // Read while it runs, so a long output can't fill the pipe and hold it up.
        let read = DispatchSemaphore(value: 0)
        let output = OutputBox()
        DispatchQueue.global(qos: .utility).async {
            output.data = pipe.fileHandleForReading.readDataToEndOfFile()
            read.signal()
        }
        let deadline = DispatchTime.now() + timeout
        guard exited.wait(timeout: deadline) == .success, read.wait(timeout: deadline) == .success else {
            process.terminate()
            return nil
        }
        return process.terminationStatus == 0 ? String(decoding: output.data, as: UTF8.self) : nil
    }

    /// The output read on another queue; the semaphore orders the write before the read.
    private final class OutputBox: @unchecked Sendable {
        var data = Data()
    }
}
#endif
