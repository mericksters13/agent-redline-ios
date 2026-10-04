#if os(macOS)
import Foundation

/// What the panel shows, read from the hub and its inbox.
@MainActor
@Observable
final class HubWindowModel {
    /// A device row in the panel: a paired phone or a running simulator.
    struct DeviceRow: Identifiable, Equatable, Sendable {
        var id: String
        var name: String
        /// "iPhone 17 Pro", or "Simulator".
        var kind: String
        var state: String
        var lastReport: Date?
        /// Ready to send reports. A paired phone that isn't still shows, dimmed, with why.
        var isActive = true
        var isSimulator: Bool { kind == "Simulator" }
    }

    /// A note, numbered as on the phone.
    struct Note: Equatable, Sendable {
        var number: Int
        var text: String
    }

    /// A report row in the panel.
    struct ReportRow: Identifiable, Equatable, Sendable {
        var id: String
        var folder: URL
        var device: String
        var receivedAt: Date
        var agent: String
        var chat: String
        var isWaiting: Bool
        var thumbnail: URL?
        var notes: [Note]
    }

    /// Everything one refresh reads, off the main actor.
    struct Snapshot: Sendable {
        var status: HubStatus
        var reports: [(deviceID: String, row: ReportRow)]
        var simulators: [(udid: String, name: String)]
    }

    private(set) var devices: [DeviceRow] = []
    private(set) var reports: [ReportRow] = []
    /// Where apps reach the hub, as the header says it.
    private(set) var reach = "Starting"
    private let hub: Hub
    private var timer: Timer?
    /// The refresh under way; one at a time, cancelled when the panel closes.
    private var refreshing: Task<Void, Never>?

    init(hub: Hub) {
        self.hub = hub
    }

    /// The hub's inbox, for the panel's Open inbox button.
    var inbox: URL { hub.paths.inbox }

    /// Refreshes now and every two seconds while the panel is open.
    func panelDidOpen() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            // Scheduled on the main run loop, so it fires on the main thread.
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer?.tolerance = 0.5
    }

    func panelDidClose() {
        timer?.invalidate()
        timer = nil
        refreshing?.cancel()
        refreshing = nil
    }

    /// Reads the hub and the inbox off the main actor, then shows the result in one step. A
    /// refresh still running when the next is due is left to finish, so results never land out
    /// of order.
    func refresh() {
        guard refreshing == nil else { return }
        let hub = hub
        refreshing = Task {
            let snapshot = await Self.loadSnapshot(hub: hub)
            refreshing = nil
            guard !Task.isCancelled else { return }
            apply(snapshot)
        }
    }

    private func apply(_ snapshot: Snapshot) {
        let last = Dictionary(snapshot.reports.map { ($0.deviceID, $0.row.receivedAt) }, uniquingKeysWith: max)
        let phones = snapshot.status.phones.map {
            DeviceRow(id: $0.udid, name: $0.name, kind: $0.model ?? "iPhone", state: Self.phoneState($0),
                      lastReport: last[$0.udid], isActive: $0.phoneState?.isReady ?? $0.state.hasPrefix("Ready"))
        }
        let simulators = snapshot.simulators.map { DeviceRow(id: $0.udid, name: $0.name, kind: "Simulator", state: "Running", lastReport: last[$0.udid]) }
        // Ready phones and running simulators first, then paired phones that can't take reports now.
        // Only what changed is set, so the panel redraws only when something did.
        let newDevices = phones.filter(\.isActive) + simulators + phones.filter { !$0.isActive }
        if newDevices != devices { devices = newDevices }
        let newReports = snapshot.reports.map(\.row)
        if newReports != reports { reports = newReports }
        let newReach = snapshot.status.hosts.first.map { "Apps reach it at \($0) · port \(snapshot.status.port)" } ?? "No local network"
        if newReach != reach { reach = newReach }
    }

    /// Where refreshes read the inbox and run simctl, which block.
    private nonisolated static let loader = DispatchQueue(label: "Redline.panel.loader", qos: .userInitiated)

    /// Runs off the main actor. Add @concurrent when the tools version reaches 6.2.
    nonisolated static func loadSnapshot(hub: Hub) async -> Snapshot {
        await withCheckedContinuation { continuation in
            loader.async {
                let status = hub.statusSnapshot()
                let watched = hub.watchedSimulators()
                let reports = readReports(paths: hub.paths)
                let simulators = fetchBootedSimulators().filter { watched.contains($0.udid) }
                continuation.resume(returning: Snapshot(status: status, reports: reports, simulators: simulators))
            }
        }
    }

    /// A phone's state as the panel shows it, short.
    nonisolated static func phoneState(_ phone: HubStatus.Phone) -> String {
        if let state = phone.phoneState { return state.shortDescription }
        // Saved by an earlier hub, as text only.
        let state = phone.state
        if state.hasPrefix("Ready") { return "Ready" }
        if state.hasPrefix("Not reachable") { return "Not reachable" }
        if state.hasPrefix("None of the watched apps") { return "No watched app installed" }
        return state
    }

    /// The newest reports in the inbox, with where each went. Only the newest `limit` are read
    /// beyond their source.json.
    nonisolated static func readReports(paths: HubPaths, limit: Int = 30) -> [(deviceID: String, row: ReportRow)] {
        let newest = Inbox.reports(for: nil, paths: paths).sorted { $0.source.receivedAt > $1.source.receivedAt }.prefix(limit)
        let database = CodexThreads.newestDatabase()
        return newest.map { report in
            let folder = report.folder
            let listing = ReportListing.load(from: folder)
            let (agent, chat, isWaiting) = destination(of: folder, codexDatabase: database)
            return (report.source.device, ReportRow(id: folder.path, folder: folder, device: report.source.deviceName, receivedAt: report.source.receivedAt,
                                                    agent: agent, chat: chat, isWaiting: isWaiting,
                                                    thumbnail: ReportContent.pictures(in: folder, listing: listing).first, notes: notes(of: listing)))
        }
    }

    /// The agent and chat a report went to: what the hub saved when it delivered it, or the
    /// chat that took it through MCP or a hook.
    nonisolated static func destination(of folder: URL, codexDatabase: URL?) -> (agent: String, chat: String, isWaiting: Bool) {
        if let delivery = ReportDelivery.load(from: folder) {
            let agent = delivery.agent.flatMap(Agent.init(rawValue:))?.name ?? "Not sent"
            return (agent, delivery.title, delivery.kind == .waiting)
        }
        if let claim = Inbox.claim(of: folder) {
            let agent = Agent(rawValue: claim.agent)?.name ?? claim.agent
            return (agent, chatTitle(claim, codexDatabase: codexDatabase), false)
        }
        return ("Not sent", "Waiting in the inbox", true)
    }

    /// A chat's title for a report taken before the hub saved where reports went: the Codex
    /// chat's title, "New chat in …" for one the hub started, else the chat's folder.
    nonisolated static func chatTitle(_ claim: Claim, codexDatabase: URL?) -> String {
        let folder = claim.folder.isEmpty ? nil : URL(filePath: claim.folder).lastPathComponent
        if let thread = ChatID.agentID(of: claim.chat, agent: .codex) {
            return CodexThreads.title(of: thread, in: codexDatabase) ?? folder ?? "Codex chat"
        }
        if ChatID.isStarted(claim.chat) { return "New chat" + (folder.map { " in \($0)" } ?? "") }
        return folder ?? "Chat"
    }

    /// The report's notes in their numbers' order, each as "Log milestone: This is ugly". None
    /// when an item lacks its number, title or note.
    nonisolated static func notes(in folder: URL) -> [Note] {
        notes(of: ReportListing.load(from: folder))
    }

    nonisolated static func notes(of listing: ReportListing?) -> [Note] {
        guard let items = listing?.items?.map({ item in
            item.number.flatMap { number in item.title.flatMap { title in item.note.map { (number, title, $0, item.element) } } }
        }).allPresent() else { return [] }
        return items.sorted { $0.0 < $1.0 }.map { number, title, note, element in
            let name = element?.label ?? element?.identifier ?? title
            return Note(number: number, text: "\(name): \(note.isEmpty ? "No note" : note)")
        }
    }

    /// Simulators that are booted, from `simctl`.
    nonisolated static func fetchBootedSimulators() -> [(udid: String, name: String)] {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "list", "devices", "booted", "-j"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        // Without Xcode's simctl there are no simulators to show.
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        struct List: Decodable {
            struct Device: Decodable {
                var udid: String
                var name: String
            }
            var devices: [String: [Device]]
        }
        guard let list = try? HubPaths.decoder.decode(List.self, from: data) else { return [] }
        return list.devices.values.flatMap { $0 }.map { ($0.udid, $0.name) }
    }
}
#endif
