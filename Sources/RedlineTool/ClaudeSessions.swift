#if os(macOS)
import Darwin
import Foundation

/// Claude Code's open chats, from the file each keeps under `~/.claude/sessions`.
///
/// Every chat listens on a socket for messages from the user's other chats, and starts a turn with
/// one when it's idle. The hub uses it for a chat that isn't waiting for
/// reports, such as one opened before the hooks were added.
enum ClaudeSessions {
    /// An open Claude Code chat.
    struct Session: Equatable {
        var id: String
        var folder: String
        var socket: String
        var updatedAt: Date
        /// The chat's name in Claude Code, when it has one.
        var title: String? = nil
    }

    /// The interactive chats that are still running.
    static func openSessions() -> [Session] {
        var sessions: [Session] = []
        for folder in configFolders {
            let files =
                (try? FileManager.default.contentsOfDirectory(
                    at: URL(filePath: folder).appending(path: "sessions"),
                    includingPropertiesForKeys: nil
                )) ?? []
            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file), let session = session(from: data) else { continue }
                sessions.append(session)
            }
        }
        return sessions
    }

    /// Where Claude Code keeps its chats: the configured folder, and the default one.
    static var configFolders: Set<String> {
        Set(
            [
                ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"],
                AgentSettings.homeDirectory().appending(path: ".claude").path,
            ]
            .compactMap { $0 }
        )
    }

    /// One session file, as Claude Code writes it.
    ///
    /// Times are in milliseconds.
    private struct SessionFile: Decodable {
        var sessionId: String?
        var cwd: String?
        var messagingSocketPath: String?
        var pid: Int32?
        var kind: String?
        var name: String?
        var updatedAt: Double?
        var startedAt: Double?
    }

    private static let decoder = JSONDecoder()

    /// The session a file describes, when it's an interactive chat that's still running.
    static func session(from data: Data) -> Session? {
        guard let file = try? decoder.decode(SessionFile.self, from: data),
            let id = file.sessionId, let folder = file.cwd, let socket = file.messagingSocketPath, let pid = file.pid,
            file.kind == "interactive"
        else { return nil }
        // A process that started after the chat did only reuses the chat's PID.
        let started = file.startedAt.map { Date(timeIntervalSince1970: $0 / 1000) }
        guard started.map({ Chats.isRunning(pid, since: $0) }) ?? Chats.isRunning(pid) else { return nil }
        let updated = file.updatedAt ?? file.startedAt ?? 0
        return Session(
            id: id,
            folder: folder,
            socket: socket,
            updatedAt: Date(timeIntervalSince1970: updated / 1000),
            title: file.name
        )
    }

    /// The line a chat's socket takes: one message, as if typed by another of the user's chats.
    private static func line(_ text: String) -> Data {
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": text]]
        do {
            return try JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes])
                + Data("\n".utf8)
        } catch {
            // Strings in nested dictionaries always serialize.
            assertionFailure("Couldn't encode a chat message: \(error)")
            return Data("\n".utf8)
        }
    }

    /// Sends `text` to the chat.
    ///
    /// True once the chat's socket took it.
    static func send(_ text: String, to session: Session) -> Bool {
        guard let descriptor = UnixSocket.connect(path: session.socket) else { return false }
        defer { close(descriptor) }
        let data = line(text)
        var sent = 0
        while sent < data.count {
            let written = data.withUnsafeBytes { bytes in
                // The line always holds at least its newline, so the buffer has an address.
                guard let base = bytes.baseAddress else { return -1 }
                return write(descriptor, base + sent, data.count - sent)
            }
            guard written > 0 else { return false }
            sent += written
        }
        return true
    }
}
#endif
