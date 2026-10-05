#if os(macOS)
import AppKit
import SwiftUI

/// The hub as a menu bar app: the same process takes reports off phones and simulators, and
/// its menu bar panel shows the devices that are active and the reports sent, with where each
/// went. It refreshes only while the panel is open, so it costs nothing while closed.
struct HubMenuBarApp: App {
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

/// Hands the running hub to the app, which SwiftUI creates on its own.
enum HubAppContext {
    nonisolated(unsafe) static var hub: Hub?
}

/// What the panel shows, read from the hub and its inbox.
@MainActor
@Observable
final class HubWindowModel {
    struct DeviceRow: Identifiable, Equatable {
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
    struct Note: Equatable {
        var number: Int
        var text: String
    }

    struct ReportRow: Identifiable, Equatable {
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

    private(set) var devices: [DeviceRow] = []
    private(set) var reports: [ReportRow] = []
    /// Where apps reach the hub, as the panel's header says it.
    private(set) var address = HubWindowModel.reach(nil)
    private let hub: Hub?
    private var timer: Timer?
    /// True while a refresh is reading the inbox and simulators. A slow `simctl` makes the timer
    /// skip a turn rather than start another, so an older refresh never overwrites a newer one.
    @ObservationIgnored private var refreshing = false

    init(hub: Hub?) {
        self.hub = hub
    }

    /// Refreshes now and every two seconds while the panel is open.
    func panelOpened() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func panelClosed() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        let paths = hub?.paths ?? HubPaths.standard
        let status = hub?.statusSnapshot() ?? Self.savedStatus(paths)
        let watchedSimulators = hub?.watchedSimulators() ?? []
        Task.detached(priority: .userInitiated) {
            let (reports, last) = HubWindowModel.readReports(paths: paths)
            let booted = HubWindowModel.bootedSimulators().filter { watchedSimulators.contains($0.udid) }
            await MainActor.run {
                self.refreshing = false
                let phones = (status?.phones ?? []).map {
                    DeviceRow(id: $0.udid, name: $0.name, kind: $0.model ?? "iPhone", state: HubWindowModel.phoneState($0.state),
                              lastReport: last[$0.udid], active: $0.state.hasPrefix("Ready"))
                }
                let simulators = booted.map { DeviceRow(id: $0.udid, name: $0.name, kind: "Simulator", state: "Running", lastReport: last[$0.udid]) }
                // Ready phones and running simulators first, then paired phones that can't take reports now.
                self.devices = phones.filter(\.active) + simulators + phones.filter { !$0.active }
                self.reports = reports
                ThumbnailCache.keep(Set(reports.compactMap(\.thumbnail)))
                self.address = HubWindowModel.reach(status)
            }
        }
    }

    /// Where apps reach the hub, from its latest status: none while it starts, and none once
    /// the Mac leaves its networks, so the panel never shows an address apps can't use.
    nonisolated static func reach(_ status: HubStatus?) -> String {
        guard let status else { return "Starting" }
        guard let host = status.hosts.first else { return "Not on a network, so apps can't reach it" }
        return "Apps reach it at \(host) · port \(status.port)"
    }

    /// A phone's state as the panel shows it, short.
    nonisolated static func phoneState(_ state: String) -> String {
        if state.hasPrefix("Ready") { return "Ready" }
        if state.hasPrefix("Not reachable") { return "Not reachable" }
        if state.hasPrefix("None of the watched apps") { return "No watched app installed" }
        if state == PhoneLink.macOfflineState { return "Mac offline" }
        return state
    }

    /// The status the hub last saved, when this process isn't the hub.
    nonisolated static func savedStatus(_ paths: HubPaths) -> HubStatus? {
        (try? Data(contentsOf: paths.status)).flatMap { try? Chats.decoder.decode(HubStatus.self, from: $0) }
    }

    /// The newest reports in the inbox, with where each went, and when each device last sent
    /// one, from every report in the inbox rather than only those shown.
    nonisolated static func readReports(paths: HubPaths, limit: Int = 30) -> (rows: [ReportRow], lastReport: [String: Date]) {
        let files = FileManager.default
        // Only source.json for every report; the rest only for the newest, which are shown.
        var found: [(folder: URL, source: ReportSource)] = []
        for app in (try? files.contentsOfDirectory(atPath: paths.inbox.path)) ?? [] where !app.hasPrefix(".") {
            let appFolder = paths.inbox.appending(path: app, directoryHint: .isDirectory)
            for name in (try? files.contentsOfDirectory(atPath: appFolder.path)) ?? [] where !name.hasPrefix(".") {
                let folder = appFolder.appending(path: name, directoryHint: .isDirectory)
                guard let data = try? Data(contentsOf: folder.appending(path: "source.json")),
                      let source = try? Chats.decoder.decode(ReportSource.self, from: data)
                else { continue }
                found.append((folder, source))
            }
        }
        let lastReport = Dictionary(found.map { ($0.source.device, $0.source.receivedAt) }, uniquingKeysWith: max)
        let rows = found.sorted {
            ($0.source.receivedAt, $0.folder.lastPathComponent) > ($1.source.receivedAt, $1.folder.lastPathComponent)
        }.prefix(limit).map { folder, source in
            let (agent, chat, waiting) = destination(of: folder)
            return ReportRow(id: folder.path, folder: folder, device: source.deviceName, receivedAt: source.receivedAt,
                             agent: agent, chat: chat, waiting: waiting,
                             thumbnail: ReportContent.pictures(in: folder).first, notes: notes(in: folder))
        }
        return (rows, lastReport)
    }

    /// The agent and chat a report went to: what the hub saved when it delivered it, or the
    /// chat that took it through MCP or a hook. A report the hub left waiting, or set to go with
    /// a chat's next message, shows as waiting until a chat takes it, and then shows that chat.
    /// No dates are compared: a wait is saved only while no other chat holds the report, so a
    /// claim next to one always came after it. A claim whose hand-over was interrupted doesn't
    /// count: the report is free again, as `InboxQueue.waiting` has it.
    nonisolated static func destination(of folder: URL) -> (agent: String, chat: String, waiting: Bool) {
        destination(delivery: ReportDelivery.load(from: folder), claim: claim(of: folder))
    }

    /// `destination(of:)` from a delivery and claim already read, so the report viewer can
    /// derive this and the chat to open from the same reads.
    nonisolated static func destination(delivery: ReportDelivery?, claim: Claim?) -> (agent: String, chat: String, waiting: Bool) {
        if let delivery, !(delivery.pending && claim != nil) {
            let agent = delivery.agent.flatMap(Agent.init(rawValue:))?.name ?? "Not sent"
            // A report set to go with a chat's next message isn't in that chat yet.
            let chat = delivery.kind == .nextMessage ? "\(delivery.title) (next message)" : delivery.title
            return (agent, chat, delivery.pending)
        }
        if let claim {
            let agent = Agent(rawValue: claim.agent)?.name ?? claim.agent
            return (agent, chatTitle(claim), false)
        }
        return ("Not sent", "Waiting in the inbox", true)
    }

    /// The chat that took a report, unless its hand-over was interrupted.
    nonisolated static func claim(of folder: URL) -> Claim? {
        (try? Data(contentsOf: folder.appending(path: InboxQueue.claimFile)))
            .flatMap { try? Chats.decoder.decode(Claim.self, from: $0) }
            .flatMap { $0.isInterrupted ? nil : $0 }
    }

    /// A chat's title for a report taken before the hub saved where reports went: the Codex
    /// chat's title, "New chat in …" for one the hub started, else the chat's folder.
    nonisolated static func chatTitle(_ claim: Claim) -> String {
        let folder = claim.folder.isEmpty ? nil : URL(fileURLWithPath: claim.folder).lastPathComponent
        if claim.chat.hasPrefix("codex-") {
            return CodexThreads.title(of: String(claim.chat.dropFirst("codex-".count))) ?? folder ?? "Codex chat"
        }
        if claim.chat.hasPrefix("started-") { return "New chat" + (folder.map { " in \($0)" } ?? "") }
        return folder ?? "Chat"
    }

    /// The report's notes in their numbers' order, each as "Log milestone: This is ugly".
    nonisolated static func notes(in folder: URL) -> [Note] {
        struct Listing: Decodable {
            struct Item: Decodable {
                struct Element: Decodable {
                    var identifier: String?
                    var label: String?
                }
                var number: Int
                var title: String
                var note: String
                var element: Element?
            }
            var items: [Item]
        }
        guard let data = try? Data(contentsOf: folder.appending(path: "report.json")),
              let listing = try? JSONDecoder().decode(Listing.self, from: data)
        else { return [] }
        return listing.items.sorted { $0.number < $1.number }.map { item in
            let name = item.element?.label ?? item.element?.identifier ?? item.title
            return Note(number: item.number, text: "\(name): \(item.note.isEmpty ? "No note" : item.note)")
        }
    }

    /// Simulators that are booted, from `simctl`. None when `simctl` fails or takes longer than
    /// 10 seconds, so a stalled CoreSimulator can't hold up every later refresh of the panel.
    nonisolated static func bootedSimulators() -> [(udid: String, name: String)] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "list", "devices", "booted", "-j"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { if process.isRunning { process.terminate() } }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runtimes = object["devices"] as? [String: [[String: Any]]]
        else { return [] }
        return runtimes.values.flatMap { $0 }.compactMap { device in
            guard let udid = device["udid"] as? String, let name = device["name"] as? String else { return nil }
            return (udid, name)
        }
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
    /// The height of the devices and reports. A scroll view in the menu bar panel has no height
    /// of its own, so they set it, up to what fits on the screen.
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.12))
            // Devices and reports scroll together, so with many of both the header and the
            // footer's Open inbox and Quit stay on the screen.
            ScrollView {
                content.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: min(max(contentHeight, 1), Self.largestContentHeight(screen: NSScreen.main?.visibleFrame.height)))
            Divider().overlay(Color.white.opacity(0.12))
            footer
        }
        .frame(width: 400)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
        .onAppear { model.panelOpened() }
        .onDisappear { model.panelClosed() }
    }

    /// The tallest the devices and reports get: 720 points, less on a screen too short for that
    /// with the header, the footer and some room below.
    nonisolated static func largestContentHeight(screen: CGFloat?) -> CGFloat {
        guard let screen else { return 520 }
        return max(min(720, screen - 160), 120)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                ForEach(model.reports) { report in
                    ReportRowView(report: report)
                    Divider().overlay(Color.white.opacity(0.08)).padding(.leading, 84)
                }
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
            Text(model.address)
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
            Button("Open inbox") {
                // Before the first report arrives the inbox doesn't exist yet.
                let inbox = HubPaths.standard.inbox
                try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
                NSWorkspace.shared.open(inbox)
            }
            Spacer()
            Button("Quit") {
                // The hub stops first, off the main thread: it waits for the reports being
                // handed over to reach their chats, and the panel shouldn't freeze meanwhile.
                Task.detached {
                    HubAppContext.hub?.stop()
                    await MainActor.run { NSApplication.shared.terminate(nil) }
                }
            }
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

/// A report's first screenshot, small, read off the disk once.
struct Thumbnail: View {
    let url: URL?

    var body: some View {
        Group {
            if let url, let image = ThumbnailCache.image(for: url) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Color.white.opacity(0.08)
            }
        }
        .frame(width: 56, height: 100)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
    }
}

/// Thumbnails of the reports the panel lists, and no others: the hub runs for days, and
/// reports that leave the list let go of theirs.
@MainActor
enum ThumbnailCache {
    private static var images: [URL: NSImage] = [:]

    /// Drops the thumbnails of reports no longer listed.
    static func keep(_ urls: Set<URL>) {
        images = images.filter { urls.contains($0.key) }
    }

    static func image(for url: URL) -> NSImage? {
        if let image = images[url] { return image }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 240,
              ] as CFDictionary)
        else { return nil }
        let image = NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
        images[url] = image
        return image
    }
}
#endif
