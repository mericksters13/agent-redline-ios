#if os(macOS)
import Foundation

/// Where a paired phone stands, as the hub and the panel show it.
enum PhoneState: Codable, Equatable, Sendable, CustomStringConvertible {
    /// The watched apps on it have the hub's address.
    case ready(apps: [String])
    /// The phone couldn't be reached; it's tried again after the delay or when a phone wakes.
    case unreachable(retryInSeconds: Int)
    case noWatchedApps

    /// For `redline status` and the log.
    var description: String {
        switch self {
        case .ready(let apps): "Ready for \(apps.joined(separator: ", "))"
        case .unreachable(let seconds): "Not reachable, trying again in \(seconds) s or when a phone wakes"
        case .noWatchedApps: "None of the watched apps installed"
        }
    }

    /// For the panel.
    var shortDescription: String {
        switch self {
        case .ready: "Ready"
        case .unreachable: "Not reachable"
        case .noWatchedApps: "No watched app installed"
        }
    }

    var isReady: Bool {
        switch self {
        case .ready: true
        case .unreachable, .noWatchedApps: false
        }
    }
}

/// What the hub tells `redline status`.
struct HubStatus: Codable, Sendable {
    /// A paired phone and where it stands.
    struct Phone: Codable, Equatable, Sendable {
        var name: String
        var udid: String
        var state: String
        /// "iPhone 17 Pro": tells apart phones with the same name.
        var model: String? = nil
        /// The state as a value, for the panel. `state` stays the text, which a `redline status`
        /// of an earlier version reads; nil in a status.json an earlier hub wrote.
        var phoneState: PhoneState? = nil
    }

    var pid: Int32
    var startedAt: Date
    var apps: [String]
    /// The apps given on the command line, which a hub taking over keeps watching.
    ///
    /// Nil in a status.json an earlier hub wrote.
    var fixedApps: [String]? = nil
    /// Where apps reach the hub.
    var hosts: [String]
    var port: UInt16
    var phones: [Phone]
    var simulatorContainers: Int
}
#endif
