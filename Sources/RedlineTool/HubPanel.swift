#if os(macOS)
import AppKit
import SwiftUI

/// Redline's red: the color it marks elements and numbers notes with on the phone, and the
/// only color in the panel besides the snapshots.
///
/// It also marks an agent whose delivery needs fixing.
private enum Mark {
    static let red = Color(red: 1, green: 0.271, blue: 0.227)
}

/// The panel: the devices, the agents reports go to, then the reports sent.
struct HubPanel: View {
    let model: HubWindowModel
    /// The height of the devices, agents and reports.
    ///
    /// A scroll view in the menu bar panel has no height of its own, so they set it, up to what
    /// fits on the screen.
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.12))
            // Devices, agents and reports scroll together, so with many of them the header and the
            // footer's Open inbox and Quit stay on the screen.
            ScrollView {
                content.onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    contentHeight = height
                }
            }
            .frame(
                height: min(
                    max(contentHeight, 1),
                    Self.largestContentHeight(screen: NSScreen.main?.visibleFrame.height)
                )
            )
            Divider().overlay(Color.white.opacity(0.12))
            footer
        }
        .frame(width: 400)
        .background(Color.black)
        .preferredColorScheme(.dark)
        .onAppear { model.panelDidOpen() }
        .onDisappear { model.panelDidClose() }
    }

    /// The tallest the devices, agents and reports get: 720 points, less on a screen too short for
    /// that with the header, the footer and some room below.
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
            // Shown once the agents installed are known, which never holds the panel up.
            if !model.agents.isEmpty {
                section("Agents")
                ForEach(model.agents) { AgentRowView(agent: $0) }
                Divider().overlay(Color.white.opacity(0.12)).padding(.top, 4)
            }
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
            Text(model.reach)
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
            Button {
                // Before the first report arrives the inbox doesn't exist yet.
                do {
                    try FileManager.default.createDirectory(at: model.inbox, withIntermediateDirectories: true)
                } catch {
                    printError("Couldn't create the inbox: \(error.localizedDescription)")
                }
                NSWorkspace.shared.open(model.inbox)
            } label: {
                footerLabel("Open inbox")
            }
            Spacer()
            Button {
                // The hub stops first, on a thread of its own: it waits for the reports being
                // handed over to reach their chats, which can take minutes, and the panel shouldn't
                // freeze meanwhile. Stopping again as the app ends returns at once.
                let hub = HubAppContext.hub
                Thread {
                    hub?.stop()
                    Task { @MainActor in NSApplication.shared.terminate(nil) }
                }.start()
            } label: {
                footerLabel("Quit")
            }
        }
        .buttonStyle(.plain)
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    /// A footer button's label, with a click target at least 28 points tall.
    private func footerLabel(_ title: String) -> some View {
        Text(title)
            .frame(minHeight: 28)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
    }
}

/// A device: its name, kind and state, and when it last sent a report.
private struct DeviceRowView: View {
    let device: HubWindowModel.DeviceRow

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.isSimulator ? "iphone.gen3.badge.play" : "iphone.gen3")
                .font(.body)
                .frame(width: 24)
                .opacity(device.isActive ? 1 : 0.5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                    .font(.callout.weight(.semibold))
                    .opacity(device.isActive ? 1 : 0.5)
                // Not dimmed: for a phone that can't take reports, this says why.
                details
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    /// "iPhone 17 Pro · Ready · last report 5 minutes ago", the time kept current by the system.
    private var details: Text {
        let base = Text(verbatim: "\(device.kind) · \(device.state)")
        guard let lastReport = device.lastReport else { return base }
        return Text("\(base) · last report \(Text(.currentDate, format: .reference(to: lastReport)))")
    }
}

/// An agent: whether reports reach its chats now, and when they don't all, what happens to them
/// meanwhile and what to do.
private struct AgentRowView: View {
    let agent: HubWindowModel.AgentRow
    /// The command was copied; reset when it changes.
    @State private var isCopied = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(agent.health == .broken ? Mark.red : Color.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(agent.name)
                        .font(.callout.weight(.semibold))
                    Spacer(minLength: 0)
                    Text(agent.state)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let advice = agent.advice {
                    Text(advice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let command = agent.command {
                    HStack(spacing: 4) {
                        Text(verbatim: command)
                            .font(.caption.monospaced())
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command, forType: .string)
                            isCopied = true
                        } label: {
                            Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                                .font(.caption)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Copy the command")
                        .accessibilityLabel("Copy command")
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .onChange(of: agent.command) { isCopied = false }
    }

    /// Shaped apart from the round note numbers, so a failure doesn't read as one more note.
    private var symbol: String {
        switch agent.health {
        case .checking: "circle.dotted"
        case .working: "checkmark.circle"
        case .limited: "pause.circle"
        case .broken: "exclamationmark.triangle"
        }
    }
}

/// A report: its first snapshot, where it went and its first notes.
///
/// Clicking opens it.
private struct ReportRowView: View {
    let report: HubWindowModel.ReportRow

    var body: some View {
        Button {
            ReportWindows.show(report)
        } label: {
            row
        }
        .buttonStyle(.plain)
        .help("Opens the report")
    }

    private var row: some View {
        HStack(alignment: .top, spacing: 12) {
            Thumbnail(url: report.thumbnail)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(report.device) · \(Text(.currentDate, format: .reference(to: report.receivedAt)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                DestinationText(report: report)
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
    }
}

/// Where a report went, "Claude Code · Fix the paywall", with the agent dimmed while it waits.
struct DestinationText: View {
    let report: HubWindowModel.ReportRow

    var body: some View {
        Text(
            "\(Text(report.agent).foregroundStyle(report.isWaiting ? .secondary : .primary))\(Text(" · ").foregroundStyle(.secondary))\(report.chat)"
        )
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

/// A report's first snapshot, small, decoded off the main actor.
private struct Thumbnail: View {
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
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
        )
        .task(id: url) {
            image = nil
            guard let url else { return }
            image = await Thumbnails.load(url, maxPixels: 240)
        }
    }
}
#endif
