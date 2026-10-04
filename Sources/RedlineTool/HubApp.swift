#if os(macOS)
import AppKit
import SwiftUI

/// The hub as a menu bar app: the same process takes reports off phones and simulators, and
/// its menu bar panel shows the devices that are active and the reports sent, with where each
/// went. It refreshes only while the panel is open, so it costs nothing while closed.
struct HubMenuBarApp: App {
    @NSApplicationDelegateAdaptor(HubAppDelegate.self) private var delegate
    @State private var model = HubWindowModel(hub: HubAppContext.hub)

    var body: some Scene {
        MenuBarExtra {
            HubPanel(model: model)
        } label: {
            Image(nsImage: MenuBarIcon.image)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu bar icon: the app icon's phone with a marked element and its note number, as a
/// template image the menu bar tints for light and dark.
enum MenuBarIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let badge = CGRect(x: 10.5, y: 1.2, width: 6, height: 6)
            context.setFillColor(NSColor.black.cgColor)
            context.setStrokeColor(NSColor.black.cgColor)
            // The phone and its marked element, cut back around the badge so the two stay apart.
            context.saveGState()
            context.addRect(CGRect(x: 0, y: 0, width: 18, height: 18))
            context.addEllipse(in: badge.insetBy(dx: -1.3, dy: -1.3))
            context.clip(using: .evenOdd)
            context.setLineWidth(1.5)
            context.addPath(CGPath(roundedRect: CGRect(x: 4.5, y: 1.25, width: 9, height: 15.5), cornerWidth: 2.8, cornerHeight: 2.8, transform: nil))
            context.strokePath()
            context.addPath(CGPath(roundedRect: CGRect(x: 6.3, y: 7, width: 5.4, height: 3.4), cornerWidth: 1, cornerHeight: 1, transform: nil))
            context.fillPath()
            context.restoreGState()
            context.fillEllipse(in: badge)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Redline"
        return image
    }()
}

/// Stops the hub when the app quits, from the panel's Quit button, the Dock or logging out, so
/// it releases `hub.pid` and logs that it stopped. Termination signals stop it on their own.
final class HubAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        HubAppContext.hub?.stop()
    }
}

/// Hands the running hub to the app, which SwiftUI creates on its own. Set by `redline app`
/// before the app starts, on the main actor.
@MainActor
enum HubAppContext {
    static var hub: Hub!
}

/// What the panel shows, read from the hub and its inbox.
@MainActor
@Observable
final class HubWindowModel {
    struct DeviceRow: Identifiable, Equatable, Sendable {
        var id: String
        var name: String
        /// "iPhone 17 Pro", or "Simulator".
        var kind: String
        var state: String
        var lastReport: Date?
        /// Ready to send reports. A paired phone that isn't still shows, dimmed, with why.
        var active = true
        var isSimulator: Bool { kind == "Simulator" }
    }

    /// A note, numbered as on the phone.
    struct Note: Equatable, Sendable {
        var number: Int
        var text: String
    }

    struct ReportRow: Identifiable, Equatable, Sendable {
        var id: String
        var folder: URL
        var device: String
        var receivedAt: Date
        var agent: String
        var chat: String
        var waiting: Bool
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
    private(set) var address = ""
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
    func panelOpened() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            // Scheduled on the main run loop, so it fires on the main thread.
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer?.tolerance = 0.5
    }

    func panelClosed() {
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
                      lastReport: last[$0.udid], active: $0.phoneState?.isReady ?? $0.state.hasPrefix("Ready"))
        }
        let simulators = snapshot.simulators.map { DeviceRow(id: $0.udid, name: $0.name, kind: "Simulator", state: "Running", lastReport: last[$0.udid]) }
        // Ready phones and running simulators first, then paired phones that can't take reports now.
        devices = phones.filter(\.active) + simulators + phones.filter { !$0.active }
        reports = snapshot.reports.map(\.row)
        address = "\(snapshot.status.hosts.first ?? "") · port \(snapshot.status.port)"
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
                let simulators = bootedSimulators().filter { watched.contains($0.udid) }
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
            let (agent, chat, waiting) = destination(of: folder, codexDatabase: database)
            return (report.source.device, ReportRow(id: folder.path, folder: folder, device: report.source.deviceName, receivedAt: report.source.receivedAt,
                                                    agent: agent, chat: chat, waiting: waiting,
                                                    thumbnail: ReportContent.pictures(in: folder, listing: listing).first, notes: notes(of: listing)))
        }
    }

    /// The agent and chat a report went to: what the hub saved when it delivered it, or the
    /// chat that took it through MCP or a hook.
    nonisolated static func destination(of folder: URL, codexDatabase: URL?) -> (agent: String, chat: String, waiting: Bool) {
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
        let folder = claim.folder.isEmpty ? nil : URL(fileURLWithPath: claim.folder).lastPathComponent
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
    nonisolated static func bootedSimulators() -> [(udid: String, name: String)] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
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

/// Redline's red: the color it marks elements and numbers notes with on the phone, and the
/// only color in the panel besides the screenshots.
enum Mark {
    static let red = Color(red: 1, green: 0.271, blue: 0.227)
}

/// The panel: the devices, then the reports sent.
struct HubPanel: View {
    let model: HubWindowModel
    /// The report list's own height. A scroll view in the menu bar panel has no height of its
    /// own, so the list sets it, up to a limit.
    @State private var listHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.12))
            section("Devices")
            if model.devices.isEmpty {
                Text("No paired iPhone or running simulator.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            } else {
                ForEach(model.devices) { DeviceRowView(device: $0) }
            }
            Divider().overlay(Color.white.opacity(0.12)).padding(.top, 4)
            section("Reports")
            if model.reports.isEmpty {
                Text("Reports sent from the phone show here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            } else {
                ScrollView {
                    reportList.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                .frame(height: min(max(listHeight, 1), 520))
            }
            Divider().overlay(Color.white.opacity(0.12))
            footer
        }
        .frame(width: 400)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
        .onAppear { model.panelOpened() }
        .onDisappear { model.panelClosed() }
    }

    private var reportList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.reports) { report in
                ReportRowView(report: report)
                Divider().overlay(Color.white.opacity(0.08)).padding(.leading, 84)
            }
        }
    }

    /// The name marked up the way Redline marks an element on the phone, as in the app icon:
    /// outlined in red, with a red dot on the corner.
    private var header: some View {
        HStack(spacing: 12) {
            Text("Redline")
                .font(.headline)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Mark.red, lineWidth: 1.5))
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .fill(Mark.red)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().stroke(Color.black, lineWidth: 2))
                        .offset(x: 4, y: -4)
                }
            Text(model.address.isEmpty ? "Starting" : "Apps reach it at \(model.address)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 6)
    }

    private var footer: some View {
        HStack {
            Button("Open inbox") { NSWorkspace.shared.open(model.inbox) }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .buttonStyle(.plain)
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

struct DeviceRowView: View {
    let device: HubWindowModel.DeviceRow

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.isSimulator ? "iphone.gen3.badge.play" : "iphone.gen3")
                .font(.body)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name).font(.callout.weight(.semibold))
                Text([device.kind, device.state, device.lastReport.map { "last report \($0.formatted(.relative(presentation: .named)))" }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .opacity(device.active ? 1 : 0.5)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}

struct ReportRowView: View {
    let report: HubWindowModel.ReportRow

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Thumbnail(url: report.thumbnail)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(report.device) · \(report.receivedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                (Text(report.agent).foregroundStyle(report.waiting ? .secondary : .primary)
                    + Text(" · ").foregroundStyle(.secondary)
                    + Text(report.chat))
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                ForEach(report.notes.prefix(3), id: \.number) { note in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        NoteNumber(number: note.number)
                        Text(note.text)
                            .font(.caption)
                            .lineLimit(2)
                    }
                }
                if report.notes.count > 3 {
                    Text("\(report.notes.count - 3) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { ReportWindows.show(report) }
        .help("Opens the report")
    }
}

/// A note's number as the phone draws it: white on a red dot.
struct NoteNumber: View {
    let number: Int

    var body: some View {
        Text("\(number)")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, number < 10 ? 0 : 4)
            .frame(minWidth: 15, minHeight: 15)
            .background(Capsule().fill(Mark.red))
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 3.5 }
    }
}

/// A report's first screenshot, small, decoded off the main actor.
struct Thumbnail: View {
    let url: URL?
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Color.white.opacity(0.08)
            }
        }
        .frame(width: 56, height: 100)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
        .task(id: url) {
            image = nil
            guard let url else { return }
            image = await Thumbnails.load(url, maxPixels: 240)
        }
    }
}

/// Pictures decoded at the size they're shown, off the main actor, kept in a bounded cache.
enum Thumbnails {
    private static let queue = DispatchQueue(label: "Redline.panel.thumbnails", qos: .userInitiated)
    /// Keeps the panel's rows and a few more, evicting on its own. NSCache is thread-safe, but the
    /// SDK doesn't mark it Sendable.
    nonisolated(unsafe) private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 60
        return cache
    }()

    /// The picture at `url`, no more than `maxPixels` on its longer side. Runs off the main
    /// actor. Add @concurrent when the tools version reaches 6.2.
    static func load(_ url: URL, maxPixels: Int) async -> NSImage? {
        let key = "\(maxPixels):\(url.path)" as NSString
        if let image = cache.object(forKey: key) { return image }
        return await withCheckedContinuation { continuation in
            queue.async {
                let image = thumbnail(url, maxPixels: maxPixels).map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
                if let image { cache.setObject(image, forKey: key) }
                continuation.resume(returning: image)
            }
        }
    }

    /// Decodes the picture at `url` straight to `maxPixels`, upright, without keeping the full-size
    /// image around.
    static func thumbnail(_ url: URL, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ] as CFDictionary)
    }
}
#endif
