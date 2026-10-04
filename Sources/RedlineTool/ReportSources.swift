#if os(macOS)
import Foundation

/// The messages between the kit and the hub, one line of JSON each. Must match the kit's
/// `HubLink` exactly. On one connection: the app's `Offer`, the hub's `Answer`, an `Upload` for
/// each report the hub wants, and the hub's `Reply`.
enum HubMessage {
    /// What the hub leaves in each watched app's folder on a phone, over the device link.
    struct Address: Codable, Equatable, Sendable {
        /// The phone's UDID, which an app can't find out on its own.
        var device: String
        var hosts: [String]
        var port: UInt16
        /// Proves an offer comes from the phone and app the address was given to: only a Mac
        /// paired with the phone can leave it there.
        var token: String?
        /// False in a simulator app, whose reports the hub takes from its folder: the app only
        /// asks which chats a report can go to.
        var uploads: Bool? = nil
    }

    struct Offer: Codable, Equatable, Sendable {
        struct Report: Codable, Equatable, Sendable {
            var id: String
            var finishedAt: Date
        }

        var device: String
        var bundleID: String
        var token: String
        var reports: [Report]
    }

    struct Answer: Codable, Equatable, Sendable {
        /// Reports to send now.
        var want: [String]
        /// Reports the Mac already has, or doesn't take: the app can stop offering them.
        var delivered: [String]
        /// Why the offer was turned down, when it was.
        var refused: String?
    }

    struct Upload: Codable, Equatable, Sendable {
        var id: String
        /// File name to contents, base64 in the line.
        var files: [String: Data]
    }

    struct Reply: Codable, Equatable, Sendable {
        var delivered: [String]
    }

    /// Before the user sends, the app asks which chats a report can go to.
    struct ChatsRequest: Codable, Equatable, Sendable {
        /// Always "chats": tells this request from an offer, which has no kind.
        var kind: String
        var device: String
        var bundleID: String
        var token: String
        /// The project file that attached the kit, naming the worktree the app was built from.
        var sourceFile: String?
    }

    /// An open chat a report can go to.
    struct Chat: Codable, Equatable, Sendable {
        /// The agent's own ID for the chat: Claude Code's session ID, Codex's thread ID.
        var id: String
        /// `claude`, `codex` or `cursor`.
        var agent: String
        var title: String
        /// The last part of the chat's folder.
        var folder: String
        /// The chat works in the worktree the app was built from.
        var sameWorktree: Bool
        var lastActive: Date
    }

    struct ChatList: Codable, Equatable, Sendable {
        /// The agents on this Mac reports can go to, in the order to show them.
        var agents: [String]
        /// The open chats on the app, those in the app's worktree first, then by last use.
        var chats: [Chat]
        /// The last part of the worktree the app was built from.
        var worktree: String?
        /// The branch a new chat's worktree starts from, such as "main".
        var newChatBase: String? = nil
        /// Why the request was turned down, when it was.
        var refused: String?
    }

    /// Where the kit looks for the hub's address, inside an app's data container.
    static let addressPath = "Library/Application Support/AgentRedline/hub.json"

    static func encode<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return ((try? encoder.encode(value)) ?? Data()) + Data("\n".utf8)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }
}

/// A report the kit has finished drawing.
struct FinishedReport: Equatable {
    var id: String
    /// When its `report.json` was written.
    var finishedAt: Date?
}

/// Where the kit keeps sent reports, inside an app's data container.
enum ReportFolder {
    static let path = "Library/Application Support/AgentRedline/reports"

    /// The finished reports among paths relative to the reports folder. A report is finished
    /// once its `report.json` is written and the draft it was drawn from is gone.
    static func finished(in entries: [(path: String, modified: Date?)]) -> [FinishedReport] {
        var written: [String: FinishedReport] = [:]
        var drawing = Set<String>()
        for entry in entries {
            let parts = entry.path.split(separator: "/")
            guard parts.count >= 2 else { continue }
            let id = String(parts[0])
            if parts.count == 2, parts[1] == "report.json" { written[id] = FinishedReport(id: id, finishedAt: entry.modified) }
            if parts[1] == "draft" { drawing.insert(id) }
        }
        return written.values.filter { !drawing.contains($0.id) }.sorted { $0.id < $1.id }
    }
}

/// What the hub has taken from one app on one phone or simulator.
struct SourceState: Codable, Equatable {
    /// Reports finished before this were there before the hub first looked, and stay where they are.
    var since: Date
    var delivered: [String] = []

    /// The finished reports still to copy.
    func toCopy(from finished: [FinishedReport]) -> [String] {
        let done = Set(delivered)
        return finished.filter { report in
            !done.contains(report.id) && !isOld(report)
        }.map(\.id)
    }

    /// The offered reports the app can stop offering: copied, or there before the hub first looked.
    func settled(_ finished: [FinishedReport]) -> [String] {
        let done = Set(delivered)
        return finished.filter { done.contains($0.id) || isOld($0) }.map(\.id)
    }

    private func isOld(_ report: FinishedReport) -> Bool {
        report.finishedAt.map { $0 < since } ?? false
    }
}

/// A report folder inside a simulator app's data container, found from the path of a file in it.
struct SimulatorReportPath: Equatable {
    /// The app's data container.
    var container: String
    /// The simulator's UDID.
    var device: String
    var reportID: String

    static func parse(_ path: String) -> SimulatorReportPath? {
        guard let marker = path.range(of: "/" + ReportFolder.path + "/") else { return nil }
        let container = String(path[..<marker.lowerBound])
        guard let id = path[marker.upperBound...].split(separator: "/").first.map(String.init), !id.isEmpty else { return nil }
        let parts = container.split(separator: "/")
        guard let devices = parts.lastIndex(of: "Devices"), devices + 1 < parts.count else { return nil }
        return SimulatorReportPath(container: container, device: String(parts[devices + 1]), reportID: id)
    }
}

enum Inbox {
    /// One report's folder in the inbox: sorts by time, and two phones sending in the same
    /// second don't collide.
    static func folderName(reportID: String, device: String) -> String {
        "\(reportID)-\(device.replacingOccurrences(of: "-", with: "").suffix(8))"
    }
}
#endif
