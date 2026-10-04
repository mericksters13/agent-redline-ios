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
        /// Where it runs: `claude-desktop` for the desktop app, `cli` in a terminal.
        var entrypoint: String? = nil
    }

    /// Where the user uses Claude Code: wherever their most recent chat runs, or the desktop app
    /// when it's installed and there's no chat to go by.
    static func usesDesktopApp() -> Bool {
        if let latest = open().max(by: { $0.updatedAt < $1.updatedAt }), let entrypoint = latest.entrypoint {
            return entrypoint == "claude-desktop"
        }
        return FileManager.default.fileExists(atPath: "/Applications/Claude.app")
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
                       isIdle: object["status"] as? String == "idle", title: object["name"] as? String,
                       entrypoint: object["entrypoint"] as? String)
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
#endif
