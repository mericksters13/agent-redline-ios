#if os(macOS)
import AppKit
import SwiftUI

extension HubWindowModel {
    /// A picture as the agent gets it, with the numbered outlines already drawn in, and the
    /// notes it shows.
    struct Picture: Equatable {
        var file: URL
        /// The screen's title, or the title of the note the picture is attached to.
        var title: String
        var notes: [Int]
        /// The notes whose outline this picture shows most of, when a screen is split into parts.
        var mainFor: [Int] = []
    }

    /// The report's pictures in the order the agent gets them: each screen's pictures, then each
    /// note's own pictures, including the picture of an element note from an older report. Only the files `ReportContent.pictures(in:)` reads, so a name
    /// that leads out of the report's folder, or a link to another file on the Mac, is left out.
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
                /// The picture that shows most of the note's outline.
                var picture: String?
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
        func mainFor(_ file: String) -> [Int] { listing.items.filter { $0.picture == file }.map(\.number).sorted() }
        let screens = listing.screens.flatMap { screen in
            screen.images.map {
                Picture(file: folder.appending(path: $0.file), title: screen.title ?? "Screen", notes: $0.notes, mainFor: mainFor($0.file))
            }
        }
        let screenFiles = listing.screens.flatMap { $0.images.map(\.file) }
        let attached = listing.items.flatMap { item in
            ReportContent.ownPictures(picture: item.picture, attachments: item.attachments, screenPictures: screenFiles).map {
                Picture(file: folder.appending(path: $0), title: item.screenTitle ?? item.title, notes: [item.number],
                        mainFor: item.picture == $0 ? [item.number] : [])
            }
        }
        let safe = Set(ReportContent.pictures(in: folder))
        return (screens + attached).filter { safe.contains($0.file) }
    }

    /// The picture that shows most of a note's outline, as the report names it, or else the first
    /// picture that shows the note.
    nonisolated static func picture(showing note: Int, in pictures: [Picture]) -> URL? {
        (pictures.first { $0.mainFor.contains(note) } ?? pictures.first { $0.notes.contains(note) })?.file
    }

    /// The chat a report went to, to open it again: the same chat `destination(of:)` names in the
    /// report's row. That is what the hub saved when it delivered the report, or else the chat
    /// that took it, including one that took a report the hub left waiting or set to go with a
    /// chat's next message. As there, no dates are compared: any claim next to a waiting
    /// delivery came after it. A claim whose hand-over was interrupted doesn't count, since that
    /// chat never got the report. `folder` is where the chat works, when known. Nil when the
    /// report went to no chat, or to an agent other than Claude Code and Codex.
    nonisolated static func chat(of report: URL) -> (agent: Agent, id: String, folder: String?)? {
        chat(of: report, delivery: ReportDelivery.load(from: report), claim: claim(of: report))
    }

    /// `chat(of:)` from a delivery and claim already read, the same ones `destination` gets.
    nonisolated static func chat(of report: URL, delivery: ReportDelivery?, claim: Claim?) -> (agent: Agent, id: String, folder: String?)? {
        let folder = claim.flatMap { $0.folder.isEmpty ? nil : $0.folder }
        if let delivery, !(delivery.pending && claim != nil) {
            guard delivery.kind != .waiting, let agent = delivery.agent.flatMap(Agent.init(rawValue:)), agent != .cursor,
                  let id = delivery.chat
            else { return nil }
            return (agent, id, folder)
        }
        guard let claim, let agent = Agent(rawValue: claim.agent), agent != .cursor else { return nil }
        if claim.chat.hasPrefix("\(agent.rawValue)-") {
            return (agent, String(claim.chat.dropFirst(agent.rawValue.count + 1)), folder)
        }
        // A chat the hub started: its ID is in what the agent's command printed.
        if claim.chat.hasPrefix("started-"),
           let output = try? String(contentsOf: report.appending(path: "new-chat-output.jsonl"), encoding: .utf8),
           let started = AgentCommand.startedChat(agent, in: output), !started.failed {
            return (agent, started.chat, folder)
        }
        return nil
    }
}

/// One window per report, opened from the panel.
@MainActor
enum ReportWindows {
    private static var open: [URL: (window: NSWindow, observer: any NSObjectProtocol)] = [:]

    /// Opens the report's window, or brings it forward, in front of the other apps: Redline is
    /// a menu bar app, so it isn't active when the panel is clicked. An open window reads the
    /// report again, since it may have gone to a chat since it opened.
    static func show(_ report: HubWindowModel.ReportRow) {
        defer { NSApp.activate() }
        if let window = open[report.folder]?.window {
            window.title = ReportViewer.title(of: report)
            (window.contentViewController as? NSHostingController<ReportViewer>)?.rootView = ReportViewer(report: report)
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = ReportViewer.title(of: report)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.contentViewController = NSHostingController(rootView: ReportViewer(report: report))
        window.center()
        let folder = report.folder
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated {
                if let observer = open[folder]?.observer { NotificationCenter.default.removeObserver(observer) }
                open[folder] = nil
            }
        }
        open[folder] = (window, observer)
        window.makeKeyAndOrderFront(nil)
    }
}

/// A report as the agent got it: its pictures, with the numbered outlines drawn in, and its
/// notes. Clicking a note brings the picture that shows it into view.
struct ReportViewer: View {
    let report: HubWindowModel.ReportRow
    private let pictures: [HubWindowModel.Picture]
    private let images: [URL: NSImage]
    private let chat: (agent: Agent, id: String, folder: String?)?
    /// Where the report went, read again with `chat` and from the same reads, so the two agree:
    /// the panel's row may be older than a delivery that happened while the panel was closed.
    private let destination: (agent: String, chat: String, waiting: Bool)
    @State private var selected: Int?
    /// Why the chat didn't open, shown until the user dismisses it.
    @State private var openFailure: String?

    init(report: HubWindowModel.ReportRow) {
        self.report = report
        pictures = HubWindowModel.pictures(in: report.folder)
        images = Dictionary(pictures.compactMap { picture in NSImage(contentsOf: picture.file).map { (picture.file, $0) } }) { first, _ in first }
        let delivery = ReportDelivery.load(from: report.folder)
        let claim = HubWindowModel.claim(of: report.folder)
        chat = HubWindowModel.chat(of: report.folder, delivery: delivery, claim: claim)
        destination = HubWindowModel.destination(delivery: delivery, claim: claim)
    }

    static func title(of report: HubWindowModel.ReportRow) -> String {
        "Redline · \(report.device) · \(report.receivedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    var body: some View {
        ScrollViewReader { proxy in
            HStack(spacing: 0) {
                pictureStrip
                Divider().overlay(Color.white.opacity(0.12))
                sidebar(scrolling: proxy).frame(width: 340)
            }
        }
        .frame(minWidth: 820, idealWidth: 1040, minHeight: 600, idealHeight: 720)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
        .alert("The chat didn't open", isPresented: Binding(get: { openFailure != nil }, set: { if !$0 { openFailure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(openFailure ?? "")
        }
    }

    /// Opens the chat a report went to, and says why when it can't. A report sent to an existing
    /// Codex chat records no folder; Codex keeps the chat's own, and `codex resume` reopens it
    /// there. A folder that is gone, such as a removed worktree, is skipped: opening a terminal
    /// there would make it again, empty, and opening one anywhere else would resume the chat
    /// away from its project.
    nonisolated private static func open(_ chat: (agent: Agent, id: String, folder: String?)) -> String? {
        let known = [chat.folder, chat.agent == .codex ? CodexThreads.folder(of: chat.id) : nil]
        let folder = known.compactMap { $0 }.first { path in
            var isFolder: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) && isFolder.boolValue
        }
        if Handoff.openChat(chat.agent, id: chat.id, in: folder) { return nil }
        if AgentCommand.locate(chat.agent) == nil {
            return "Redline found neither the \(chat.agent.name) app nor its command on this Mac."
        }
        guard let folder else {
            return "The folder this chat worked in is gone or unknown, so Redline can't resume it in a terminal."
        }
        return "Redline couldn't open a terminal in \(folder)."
    }

    /// The pictures side by side, each as tall as the window allows.
    private var pictureStrip: some View {
        GeometryReader { size in
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pictureView(_ picture: HubWindowModel.Picture, height: CGFloat) -> some View {
        let showsSelected = selected.map(picture.notes.contains) ?? false
        return VStack(alignment: .leading, spacing: 8) {
            Group {
                if let image = images[picture.file], image.size.height > 0 {
                    Image(nsImage: image).resizable().frame(width: height * image.size.width / image.size.height, height: height)
                } else {
                    Color.white.opacity(0.08).frame(width: height * 9 / 19.5, height: height)
                }
            }
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

    /// Selects a note and brings the picture that shows it into view, on every click: the
    /// picture may have been scrolled away since the note was last selected.
    private func show(_ note: Int, scrolling proxy: ScrollViewProxy) {
        selected = note
        guard let file = HubWindowModel.picture(showing: note, in: pictures) else { return }
        withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(file, anchor: .center) }
    }

    private func sidebar(scrolling proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(report.device) · \(report.receivedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                (Text(destination.agent).foregroundStyle(destination.waiting ? .secondary : .primary)
                    + Text(" · ").foregroundStyle(.secondary)
                    + Text(destination.chat))
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
            }
            .padding(16)
            HStack(spacing: 8) {
                if let chat {
                    Button("Open in \(chat.agent.name)") {
                        Task {
                            openFailure = await Task.detached { Self.open(chat) }.value
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
                        Button { show(note.number, scrolling: proxy) } label: {
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
