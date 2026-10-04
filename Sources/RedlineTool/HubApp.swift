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
        var kind: String
        var state: String
        var lastReport: Date?
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
        var notes: [String]
    }

    private(set) var devices: [DeviceRow] = []
    private(set) var reports: [ReportRow] = []
    private(set) var address = ""
    private let hub: Hub?
    private var timer: Timer?

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
        let paths = hub?.paths ?? HubPaths.standard
        let status = hub?.statusSnapshot() ?? Self.savedStatus(paths)
        let watchedSimulators = hub?.watchedSimulators() ?? []
        Task.detached(priority: .userInitiated) {
            let reports = HubWindowModel.readReports(paths: paths)
            let booted = HubWindowModel.bootedSimulators().filter { watchedSimulators.contains($0.udid) }
            await MainActor.run {
                let last = Dictionary(reports.map { ($0.deviceID, $0.row.receivedAt) }, uniquingKeysWith: max)
                var devices: [DeviceRow] = (status?.phones ?? []).filter { $0.state.hasPrefix("Ready") }.map {
                    DeviceRow(id: $0.udid, name: $0.name, kind: "iPhone", state: "Ready", lastReport: last[$0.udid])
                }
                devices += booted.map { DeviceRow(id: $0.udid, name: $0.name, kind: "Simulator", state: "Running", lastReport: last[$0.udid]) }
                self.devices = devices
                self.reports = reports.map(\.row)
                if let status { self.address = "\(status.hosts.first ?? "") · port \(status.port)" }
            }
        }
    }

    /// The status the hub last saved, when this process isn't the hub.
    nonisolated static func savedStatus(_ paths: HubPaths) -> HubStatus? {
        (try? Data(contentsOf: paths.status)).flatMap { try? Chats.decoder.decode(HubStatus.self, from: $0) }
    }

    /// The newest reports in the inbox, with where each went.
    nonisolated static func readReports(paths: HubPaths, limit: Int = 30) -> [(deviceID: String, row: ReportRow)] {
        let files = FileManager.default
        var found: [(String, ReportRow)] = []
        for app in (try? files.contentsOfDirectory(atPath: paths.inbox.path)) ?? [] where !app.hasPrefix(".") {
            let appFolder = paths.inbox.appending(path: app, directoryHint: .isDirectory)
            for name in (try? files.contentsOfDirectory(atPath: appFolder.path)) ?? [] where !name.hasPrefix(".") {
                let folder = appFolder.appending(path: name, directoryHint: .isDirectory)
                guard let data = try? Data(contentsOf: folder.appending(path: "source.json")),
                      let source = try? Chats.decoder.decode(ReportSource.self, from: data)
                else { continue }
                let (agent, chat, waiting) = destination(of: folder)
                found.append((source.device, ReportRow(id: folder.path, folder: folder, device: source.deviceName, receivedAt: source.receivedAt,
                                                       agent: agent, chat: chat, waiting: waiting,
                                                       thumbnail: ReportContent.pictures(in: folder).first, notes: notes(in: folder))))
            }
        }
        return Array(found.sorted { $0.1.receivedAt > $1.1.receivedAt }.prefix(limit))
    }

    /// The agent and chat a report went to: what the hub saved when it delivered it, or the
    /// chat that took it through MCP or a hook.
    nonisolated static func destination(of folder: URL) -> (agent: String, chat: String, waiting: Bool) {
        if let delivery = ReportDelivery.load(from: folder) {
            let agent = delivery.agent.flatMap(Agent.init(rawValue:))?.name ?? "Not sent"
            return (agent, delivery.title, delivery.kind == .waiting)
        }
        if let data = try? Data(contentsOf: folder.appending(path: InboxQueue.claimFile)),
           let claim = try? Chats.decoder.decode(Claim.self, from: data) {
            let agent = Agent(rawValue: claim.agent)?.name ?? claim.agent
            return (agent, chatTitle(claim), false)
        }
        return ("Not sent", "Waiting in the inbox", true)
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

    /// "1. Log milestone: This is ugly", one per note, numbered as on the phone.
    nonisolated static func notes(in folder: URL) -> [String] {
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
            return "\(item.number). \(name): \(item.note.isEmpty ? "No note" : item.note)"
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
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runtimes = object["devices"] as? [String: [[String: Any]]]
        else { return [] }
        return runtimes.values.flatMap { $0 }.compactMap { device in
            guard let udid = device["udid"] as? String, let name = device["name"] as? String else { return nil }
            return (udid, name)
        }
    }
}

/// The panel: active devices, then the reports sent.
struct HubPanel: View {
    let model: HubWindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.12))
            section("Devices")
            if model.devices.isEmpty {
                Text("No phone or simulator is active.")
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
                ScrollView { reportList }.frame(maxHeight: 520)
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
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(model.reports) { report in
                ReportRowView(report: report)
                Divider().overlay(Color.white.opacity(0.08)).padding(.leading, 84)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle().fill(Color.white).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text("Redline").font(.headline)
                Text(model.address.isEmpty ? "Starting" : "Apps reach it at \(model.address)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
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
            Button("Open inbox") { NSWorkspace.shared.open(HubPaths.standard.inbox) }
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
            Image(systemName: device.kind == "iPhone" ? "iphone.gen3" : "iphone.gen3.badge.play")
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
                ForEach(Array(report.notes.prefix(3).enumerated()), id: \.offset) { _, note in
                    Text(note)
                        .font(.caption)
                        .lineLimit(2)
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
        .onTapGesture { NSWorkspace.shared.open(report.folder) }
        .help("Opens the report's folder")
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

@MainActor
enum ThumbnailCache {
    private static var images: [URL: NSImage] = [:]

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
