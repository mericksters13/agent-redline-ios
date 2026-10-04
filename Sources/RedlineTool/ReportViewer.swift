#if os(macOS)
import AppKit
import SwiftUI

extension HubWindowModel {
    /// A picture as the agent gets it, with the numbered outlines already drawn in, and the
    /// notes it shows.
    struct Picture: Equatable, Sendable {
        var file: URL
        /// The screen's title, or the title of the note the picture is attached to.
        var title: String
        var notes: [Int]
    }

    /// The report's pictures in the order the agent gets them: each screen's pictures, then the
    /// pictures attached to notes.
    nonisolated static func pictures(in folder: URL) -> [Picture] {
        let listing = ReportListing.load(from: folder)
        guard let screens = listing?.screens,
              let images = screens.map({ screen in screen.images.map { image in image.notes.map { (screen.title, image.file, $0) } }.allPresent() }).allPresent(),
              let items = listing?.items?.map({ item in
                  item.number.flatMap { number in item.title.flatMap { title in item.attachments.map { (number, item.screenTitle ?? title, $0) } } }
              }).allPresent()
        else {
            return ReportContent.pictures(in: folder).map { Picture(file: $0, title: $0.deletingPathExtension().lastPathComponent, notes: []) }
        }
        let shown = images.flatMap { $0 }.map { title, file, notes in Picture(file: folder.appending(path: file), title: title ?? "Screen", notes: notes) }
        let attached = items.flatMap { number, title, attachments in
            attachments.map { Picture(file: folder.appending(path: $0), title: title, notes: [number]) }
        }
        return (shown + attached).filter { FileManager.default.fileExists(atPath: $0.file.path) }
    }

    /// The first picture that shows a note.
    nonisolated static func picture(showing note: Int, in pictures: [Picture]) -> URL? {
        pictures.first { $0.notes.contains(note) }?.file
    }

    /// A chat a report went to, to open it again. `folder` is where that chat works, when known.
    struct ChatLink: Equatable, Sendable {
        var agent: Agent
        var id: String
        var folder: String?
    }

    /// The chat a report went to: from what the hub saved when it delivered the report, or else
    /// the chat that took it. Nil when the report went to no chat.
    nonisolated static func chat(of report: URL) -> ChatLink? {
        let claim = (try? Data(contentsOf: report.appending(path: Inbox.claimFile))).flatMap { try? HubPaths.decoder.decode(Claim.self, from: $0) }
        let folder = claim.flatMap { $0.folder.isEmpty ? nil : $0.folder }
        if let delivery = ReportDelivery.load(from: report) {
            guard delivery.kind != .waiting, let agent = delivery.agent.flatMap(Agent.init(rawValue:)),
                  let id = delivery.chat
            else { return nil }
            return ChatLink(agent: agent, id: id, folder: folder)
        }
        guard let claim, let agent = Agent(rawValue: claim.agent) else { return nil }
        if let id = ChatID.agentID(of: claim.chat, agent: agent) {
            return ChatLink(agent: agent, id: id, folder: folder)
        }
        // A chat the hub started: its ID is in what the agent's command printed.
        if ChatID.isStarted(claim.chat),
           let output = try? String(contentsOf: report.appending(path: Inbox.newChatOutputFile), encoding: .utf8),
           let started = AgentCommand.startedChat(agent, in: output), !started.didFail {
            return ChatLink(agent: agent, id: started.chat, folder: folder)
        }
        return nil
    }
}

/// One window per report, opened from the panel.
@MainActor
enum ReportWindows {
    private struct OpenWindow {
        var window: NSWindow
        var observer: any NSObjectProtocol
    }

    private static var windows: [URL: OpenWindow] = [:]
    /// Where the next new window goes, so each opens below and right of the last, not on top of it.
    private static var cascadePoint = NSPoint.zero
    /// Reports whose files are being read before their window shows; a second click waits for it.
    private static var loading: [URL: Task<Void, Never>] = [:]

    /// Opens the report's window, or brings it forward, in front of the other apps: Redline is
    /// a menu bar app, so it isn't active when the panel is clicked. An open window reads the
    /// report again, since it may have gone to a chat since it opened. The report's files are
    /// read off the main actor first.
    static func show(_ report: HubWindowModel.ReportRow) {
        let folder = report.folder
        guard loading[folder] == nil else { return }
        loading[folder] = Task {
            let contents = await ReportViewer.load(folder)
            loading[folder] = nil
            present(report, contents)
        }
    }

    private static func present(_ report: HubWindowModel.ReportRow, _ contents: ReportViewer.Contents) {
        defer { NSApp.activate() }
        if let window = windows[report.folder]?.window {
            window.title = ReportViewer.title(of: report)
            (window.contentViewController as? NSHostingController<ReportViewer>)?.rootView = ReportViewer(report: report, contents: contents)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = ReportViewer.title(of: report)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.contentViewController = NSHostingController(rootView: ReportViewer(report: report, contents: contents))
        if windows.isEmpty { window.center() }
        cascadePoint = window.cascadeTopLeft(from: cascadePoint)
        let folder = report.folder
        // queue: .main delivers on the main thread.
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated {
                if let observer = windows[folder]?.observer { NotificationCenter.default.removeObserver(observer) }
                windows[folder] = nil
            }
        }
        windows[folder] = OpenWindow(window: window, observer: observer)
        window.makeKeyAndOrderFront(nil)
    }
}

/// A report as the agent got it: its pictures, with the numbered outlines drawn in, and its
/// notes. Clicking a note brings the picture that shows it into view.
struct ReportViewer: View {
    /// What the viewer reads from the report's folder, before its window shows.
    struct Contents: Sendable {
        var pictures: [HubWindowModel.Picture]
        var chat: HubWindowModel.ChatLink?
    }

    let report: HubWindowModel.ReportRow
    private let pictures: [HubWindowModel.Picture]
    private let chat: HubWindowModel.ChatLink?
    @State private var selected: Int?

    init(report: HubWindowModel.ReportRow, contents: Contents) {
        self.report = report
        pictures = contents.pictures
        chat = contents.chat
    }

    private static let loader = DispatchQueue(label: "Redline.viewer.loader", qos: .userInitiated)

    /// Reads the report's pictures and chat. Runs off the main actor. Add @concurrent when the
    /// tools version reaches 6.2.
    nonisolated static func load(_ folder: URL) async -> Contents {
        await withCheckedContinuation { continuation in
            loader.async {
                continuation.resume(returning: Contents(pictures: HubWindowModel.pictures(in: folder), chat: HubWindowModel.chat(of: folder)))
            }
        }
    }

    static func title(of report: HubWindowModel.ReportRow) -> String {
        "Redline · \(report.device) · \(report.receivedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    var body: some View {
        ScrollViewReader { proxy in
            HStack(spacing: 0) {
                pictureStrip
                Divider().overlay(Color.white.opacity(0.12))
                sidebar(proxy).frame(width: 340)
            }
        }
        .frame(minWidth: 820, idealWidth: 1040, minHeight: 600, idealHeight: 720)
        .background(Color.black)
    }

    /// Room in the strip's height for its padding (48) and each picture's caption (28).
    private static let pictureMargin: CGFloat = 76

    /// The pictures side by side, each as tall as the window allows. The strip measures its own
    /// height: inside a horizontal scroll view, containerRelativeFrame doesn't get it (a render
    /// showed the pictures shrunk to their minimum), and a picture's width follows its height.
    private var pictureStrip: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 20) {
                    ForEach(pictures, id: \.file) { picture in
                        pictureView(picture, height: max(geometry.size.height - Self.pictureMargin, 120))
                            .id(picture.file)
                    }
                }
                .padding(24)
            }
            .overlay {
                if pictures.isEmpty {
                    Text("This report has no pictures.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pictureView(_ picture: HubWindowModel.Picture, height: CGFloat) -> some View {
        let showsSelected = selected.map(picture.notes.contains) ?? false
        return VStack(alignment: .leading, spacing: 8) {
            PictureImage(file: picture.file, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(showsSelected ? 0.9 : 0.16), lineWidth: showsSelected ? 2 : 1))
            HStack(spacing: 6) {
                Text(picture.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                ForEach(picture.notes, id: \.self) { NoteNumber(number: $0) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(picture.notes.isEmpty ? picture.title : "\(picture.title), notes \(picture.notes.map(String.init).joined(separator: ", "))")
    }

    /// Brings the picture that shows a note into view, every time the note is clicked.
    private func scroll(to note: Int, _ proxy: ScrollViewProxy) {
        guard let file = HubWindowModel.picture(showing: note, in: pictures) else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { proxy.scrollTo(file, anchor: .center) }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func sidebar(_ proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(report.device) · \(report.receivedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                DestinationText(report: report)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
            }
            .padding(16)
            HStack(spacing: 8) {
                if let chat {
                    Button("Open in \(chat.agent.name)") {
                        let folder = chat.folder ?? URL.homeDirectory.path
                        let hub = HubAppContext.hub
                        // Opening runs /usr/bin/open and waits for it, so not on the main thread.
                        DispatchQueue.global(qos: .userInitiated).async {
                            do {
                                try Handoff.openChat(chat.agent, id: chat.id, in: folder)
                            } catch {
                                hub?.log("Couldn't open the \(chat.agent.name) chat \(chat.id): \(error.localizedDescription)")
                            }
                        }
                    }
                    .buttonStyle(ViewerButtonStyle(isProminent: true))
                    .help("Opens the chat this report went to")
                }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([report.folder]) }
                    .buttonStyle(ViewerButtonStyle(isProminent: false))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            Divider().overlay(Color.white.opacity(0.12))
            Text("NOTES")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(report.notes, id: \.number) { note in
                        Button {
                            selected = note.number
                            scroll(to: note.number, proxy)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                NoteNumber(number: note.number)
                                Text(note.text)
                                    .font(.callout)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.white.opacity(selected == note.number ? 0.12 : 0)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
        }
    }
}

/// One of the viewer's pictures, as tall as `height`, decoded off the main actor. A placeholder
/// of a phone screen's shape shows until it's ready.
struct PictureImage: View {
    let file: URL
    let height: CGFloat
    @State private var image: NSImage?

    /// Big enough for the picture to stay sharp in a full-screen window on a Retina display.
    private static let maxPixels = 3000

    var body: some View {
        Group {
            if let image, image.size.height > 0 {
                Image(nsImage: image).resizable().frame(width: height * image.size.width / image.size.height, height: height)
            } else {
                Color.white.opacity(0.08).frame(width: height * 9 / 19.5, height: height)
            }
        }
        .task(id: file) { image = await Thumbnails.load(file, maxPixels: Self.maxPixels) }
    }
}

/// The viewer's buttons: white on black for the main one, gray for the other.
struct ViewerButtonStyle: ButtonStyle {
    let isProminent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(isProminent ? Color.black : Color.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isProminent ? Color.white : Color.white.opacity(0.12)))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
#endif
