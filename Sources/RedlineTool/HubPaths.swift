#if os(macOS)
import Foundation

/// Where the tool keeps things on the Mac.
///
/// - `inbox/<bundle ID>/<report>/`: reports taken off phones and simulators. Each holds the
///   report's own files (`report.json`, `report.md`, snapshots) and the hub's: `source.json`
///   (where it came from), `claim.json` (the chat that took it), `to.json` (the chat it's
///   addressed to), `delivery.json` (where the hub sent it), and for a chat the hub started,
///   `new-chat-output.jsonl` and `answer.md`. A report is filled under `.incoming-<name>` and
///   renamed into place whole.
/// - `hub/chats/<chat>.json`: the open chats, written by their MCP copies, hooks and waits
/// - `hub/state.json`: which reports each phone and simulator app has already given
/// - `hub/tokens.json`: the token each app on each phone was given; secret
/// - `hub/started-chats.json`: the chats the hub started for the phone's "New chat" picks
/// - `hub/status.json`, `hub/hub.pid`, `hub/hub.log` (and `hub/hub.log.1`): for `redline status`
///   and the panel; the hub holds a lock on `hub.pid` while it runs
struct HubPaths: Sendable {
    let root: URL

    static let standard = HubPaths(
        root: URL.applicationSupportDirectory.appending(path: "Redline", directoryHint: .isDirectory)
    )

    var inbox: URL { root.appending(path: "inbox", directoryHint: .isDirectory) }
    var hub: URL { root.appending(path: "hub", directoryHint: .isDirectory) }
    var state: URL { hub.appending(path: "state.json") }
    var status: URL { hub.appending(path: "status.json") }
    var pid: URL { hub.appending(path: "hub.pid") }
    var log: URL { hub.appending(path: "hub.log") }
    /// The token each app on each phone was given; secret, readable only by the user.
    var tokens: URL { hub.appending(path: "tokens.json") }

    /// How the hub and the chats write their JSON files: ISO 8601 dates, pretty-printed with
    /// sorted keys, so people can read them.
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
#endif
