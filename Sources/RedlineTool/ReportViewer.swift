#if os(macOS)
import AppKit
import SwiftUI

/// A report as the agent got it: its pictures, with the numbered outlines drawn in, and its notes.
///
/// Clicking a note brings the picture that shows it into view.
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

    private nonisolated static let loader = DispatchQueue(label: "Redline.viewer.loader", qos: .userInitiated)

    /// Reads the report's pictures and chat.
    ///
    /// Runs off the main actor. Add @concurrent when the tools version reaches 6.2.
    nonisolated static func load(_ folder: URL) async -> Contents {
        await withCheckedContinuation { continuation in
            loader.async {
                continuation.resume(
                    returning: Contents(
                        pictures: HubWindowModel.pictures(in: folder),
                        chat: HubWindowModel.chat(of: folder)
                    )
                )
            }
        }
    }

    /// The report window's title.
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

    /// The pictures side by side, each as tall as the window allows.
    ///
    /// The strip measures its own height: inside a horizontal scroll view, containerRelativeFrame
    /// doesn't get it (a render showed the pictures shrunk to their minimum), and a picture's width
    /// follows its height.
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
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(showsSelected ? 0.9 : 0.16), lineWidth: showsSelected ? 2 : 1)
                )
            HStack(spacing: 6) {
                Text(picture.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                ForEach(picture.notes, id: \.self) { NoteNumber(number: $0) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            picture.notes.isEmpty
                ? picture.title : "\(picture.title), notes \(picture.notes.map(String.init).joined(separator: ", "))"
        )
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
                        let hub = HubAppContext.hub
                        // Opening runs /usr/bin/open and waits for it, so not on the main thread.
                        DispatchQueue.global(qos: .userInitiated).async {
                            // A report sent to an existing Codex chat records no folder; Codex keeps
                            // the chat's own, and `codex resume` reopens it there.
                            let codexFolder =
                                chat.agent == .codex
                                ? CodexThreads.folder(of: chat.id, in: CodexThreads.newestDatabase()) : nil
                            let folder = chat.folder ?? codexFolder ?? URL.homeDirectory.path
                            do {
                                try Handoff.openChat(chat.agent, id: chat.id, in: folder)
                            } catch {
                                hub?.log(
                                    "Couldn't open the \(chat.agent.name) chat \(chat.id): \(error.localizedDescription)"
                                )
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
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.white.opacity(selected == note.number ? 0.12 : 0))
                            )
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

/// One of the viewer's pictures, as tall as `height`, decoded off the main actor.
///
/// A placeholder of a phone screen's shape shows until it's ready.
private struct PictureImage: View {
    let file: URL
    let height: CGFloat
    @State private var image: NSImage?

    /// Big enough for the picture to stay sharp in a full-screen window on a Retina display.
    private static let maxPixels = 3000

    var body: some View {
        Group {
            if let image, image.size.height > 0 {
                Image(nsImage: image).resizable().frame(
                    width: height * image.size.width / image.size.height,
                    height: height
                )
            } else {
                Color.white.opacity(0.08).frame(width: height * 9 / 19.5, height: height)
            }
        }
        .task(id: file) { image = await Thumbnails.load(file, maxPixels: Self.maxPixels) }
    }
}

/// The viewer's buttons: white on black for the main one, gray for the other.
private struct ViewerButtonStyle: ButtonStyle {
    let isProminent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(isProminent ? Color.black : Color.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isProminent ? Color.white : Color.white.opacity(0.12))
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
#endif
