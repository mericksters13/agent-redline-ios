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
        struct Listing: Decodable {
            struct Screen: Decodable {
                struct Image: Decodable {
                    var file: String
                    var notes: [Int]
                }
                var title: String?
                var images: [Image]
            }
            struct Item: Decodable {
                var number: Int
                var title: String
                var screenTitle: String?
                var attachments: [String]
            }
            var screens: [Screen]
            var items: [Item]
        }
        guard let data = try? Data(contentsOf: folder.appending(path: "report.json")),
              let listing = try? JSONDecoder().decode(Listing.self, from: data)
        else {
            return ReportContent.pictures(in: folder).map { Picture(file: $0, title: $0.deletingPathExtension().lastPathComponent, notes: []) }
        }
        let screens = listing.screens.flatMap { screen in
            screen.images.map { Picture(file: folder.appending(path: $0.file), title: screen.title ?? "Screen", notes: $0.notes) }
        }
        let attached = listing.items.flatMap { item in
            item.attachments.map { Picture(file: folder.appending(path: $0), title: item.screenTitle ?? item.title, notes: [item.number]) }
        }
        return (screens + attached).filter { FileManager.default.fileExists(atPath: $0.file.path) }
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
        let claim = (try? Data(contentsOf: report.appending(path: InboxQueue.claimFile))).flatMap { try? Chats.decoder.decode(Claim.self, from: $0) }
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
           let output = try? String(contentsOf: report.appending(path: "new-chat-output.jsonl"), encoding: .utf8),
           let started = AgentCommand.startedChat(agent, in: output), !started.failed {
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

    private static var open: [URL: OpenWindow] = [:]
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
        if let window = open[report.folder]?.window {
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
        window.center()
        let folder = report.folder
        // queue: .main delivers on the main thread.
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated {
                if let observer = open[folder]?.observer { NotificationCenter.default.removeObserver(observer) }
                open[folder] = nil
            }
        }
        open[folder] = OpenWindow(window: window, observer: observer)
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
        HStack(spacing: 0) {
            pictureStrip
            Divider().overlay(Color.white.opacity(0.12))
            sidebar.frame(width: 340)
        }
        .frame(minWidth: 820, idealWidth: 1040, minHeight: 600, idealHeight: 720)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
    }

    /// The pictures side by side, each as tall as the window allows.
    private var pictureStrip: some View {
        GeometryReader { size in
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 20) {
                        ForEach(pictures, id: \.file) { picture in
                            // Room for the padding and the caption below.
                            pictureView(picture, height: max(size.size.height - 48 - 28, 120))
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
                .onChange(of: selected) { _, note in
                    guard let note, let file = HubWindowModel.picture(showing: note, in: pictures) else { return }
                    withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(file, anchor: .center) }
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
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(report.device) · \(report.receivedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                (Text(report.agent).foregroundStyle(report.waiting ? .secondary : .primary)
                    + Text(" · ").foregroundStyle(.secondary)
                    + Text(report.chat))
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
            }
            .padding(16)
            HStack(spacing: 8) {
                if let chat {
                    Button("Open in \(chat.agent.name)") {
                        let folder = chat.folder ?? NSHomeDirectory()
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
                    .buttonStyle(ViewerButtonStyle(prominent: true))
                    .help("Opens the chat this report went to")
                }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([report.folder]) }
                    .buttonStyle(ViewerButtonStyle(prominent: false))
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
                        Button { selected = note.number } label: {
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
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(prominent ? Color.black : Color.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(prominent ? Color.white : Color.white.opacity(0.12)))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
#endif
