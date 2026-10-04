#if os(macOS)
import Darwin
import Foundation
import Synchronization

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
        /// The chat's name in Claude Code, when it has one.
        var title: String? = nil
    }

    /// The interactive chats that are still running.
    static func open() -> [Session] {
        let folders = [ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], NSHomeDirectory() + "/.claude"].compactMap { $0 }
        var sessions: [Session] = []
        for folder in Set(folders) {
            let files = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder).appending(path: "sessions"), includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file), let session = session(from: data) else { continue }
                sessions.append(session)
            }
        }
        return sessions
    }

    static func session(from data: Data) -> Session? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["sessionId"] as? String, let folder = object["cwd"] as? String,
              let socket = object["messagingSocketPath"] as? String, let pid = object["pid"] as? Int,
              object["kind"] as? String == "interactive", Chats.isRunning(Int32(pid))
        else { return nil }
        let updated = (object["updatedAt"] as? Double) ?? (object["startedAt"] as? Double) ?? 0
        return Session(id: id, folder: folder, socket: socket, updatedAt: Date(timeIntervalSince1970: updated / 1000),
                       title: object["name"] as? String)
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
    /// The last check, so `ready()` runs the command at most every minute.
    private static let lastCheck = Mutex<ReadinessCheck?>(nil)

    private struct ReadinessCheck {
        var isReady: Bool
        var checkedAt: Date
    }

    /// Signed in with `claude auth login`, and, with the desktop app installed, new enough to open
    /// a chat in it. Checked at most every minute.
    static func ready() -> Bool {
        if let check = lastCheck.withLock({ $0 }), Date().timeIntervalSince(check.checkedAt) < 60 { return check.isReady }
        guard let claude = AgentCommand.locate(.claude) else { return false }
        let signedIn = output(claude, ["auth", "status"]) != nil
        let version = output(claude, ["--version"]).flatMap { version(in: $0) } ?? []
        let ready = signedIn && (!AgentCommand.hasClaudeApp || !version.lexicographicallyPrecedes(desktopVersion))
        lastCheck.withLock { $0 = ReadinessCheck(isReady: ready, checkedAt: Date()) }
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
        lastCheck.withLock { $0 = nil }
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

    /// The command's output when it succeeds.
    private static func output(_ executable: URL, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
#endif
