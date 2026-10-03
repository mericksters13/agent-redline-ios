#if AGENTIC_DEBUGGING && canImport(UIKit)
import ImageIO
import SwiftUI
import UIKit

/// The reports already sent from this phone, opened with a long press on the floating
/// button: a list, newest first, and each report the way the agent gets it, with every
/// screen's pictures and their numbered outlines, then the notes. Tap a note to jump to
/// its outline.
struct SentReportsView: View {
    @Bindable var session: DebugSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Nil while the list loads.
    @State private var reports: [SentReport]?
    @State private var open: SentReport?

    private var size: CGSize { session.screenSize }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black
            if let open {
                ReportDetail(sent: open, session: session) { show(nil) }
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing))
            } else {
                list
                    .transition(reduceMotion ? .opacity : .move(edge: .leading))
            }
        }
        .frame(width: size.width, height: size.height)
        .ignoresSafeArea()
        .task { reports = await session.sentReports() }
    }

    private func show(_ report: SentReport?) {
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.3)) { open = report }
    }

    // MARK: - List

    private var list: some View {
        VStack(spacing: 0) {
            ViewerBar(title: "Sent reports", icon: "xmark", label: "Close", top: session.safeAreaTop) {
                session.closeSentReports()
            }
            if let reports {
                if reports.isEmpty {
                    empty
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(reports.enumerated()), id: \.element.id) { index, sent in
                                if index > 0 {
                                    Rectangle().fill(Mono.hairline).frame(height: 1).padding(.leading, 80)
                                }
                                row(sent)
                            }
                        }
                        .padding(.vertical, 6)
                        .background(Mono.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Mono.hairline, lineWidth: 1))
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .padding(.bottom, session.safeAreaInsets.bottom + 16)
                    }
                }
            }
        }
    }

    private func row(_ sent: SentReport) -> some View {
        Button { show(sent) } label: {
            HStack(spacing: 12) {
                ReportPicture(url: sent.cover, pointWidth: 52, alignment: .top)
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Mono.hairline, lineWidth: 1))
                VStack(alignment: .leading, spacing: 2) {
                    Text(sent.report.screenNames)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Mono.text)
                    Text(sent.report.contents)
                        .font(.caption)
                        .foregroundStyle(Mono.secondary)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
                Text(Self.time(sent.report.createdAt))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Mono.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Mono.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the pictures and notes as sent")
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 34))
                .foregroundStyle(Mono.secondary)
                .padding(.bottom, 4)
            Text("No reports yet")
                .font(.headline)
                .foregroundStyle(Mono.text)
            Text("Reports sent from this iPhone show up here.")
                .font(.subheadline)
                .foregroundStyle(Mono.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
        .frame(maxHeight: .infinity)
    }

    /// The time alone for today's reports, the date as well for older ones.
    static func time(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }
}

/// One sent report: each screen's pictures as the agent got them, then the notes made on
/// it. A note scrolls to its outline when tapped.
private struct ReportDetail: View {
    let sent: SentReport
    let session: DebugSession
    let back: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var report: Report { sent.report }
    private var width: CGFloat { session.screenSize.width - 32 }
    private var items: [Int: Report.Item] { Dictionary(report.items.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first }) }
    private var attachments: [Report.Item] { report.items.filter { $0.screen == nil } }

    var body: some View {
        VStack(spacing: 0) {
            ViewerBar(title: SentReportsView.time(report.createdAt), icon: "chevron.left", label: "Back", top: session.safeAreaTop, action: back)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 32) {
                        Text(about)
                            .font(.caption)
                            .foregroundStyle(Mono.secondary)
                        ForEach(report.screens, id: \.id) { screen in
                            section(screen, proxy: proxy)
                        }
                        if !attachments.isEmpty { attachmentSection }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, session.safeAreaInsets.bottom + 24)
                }
            }
        }
    }

    /// What was reported from where: "3 notes, 1 screen · Tiny Tally 1.0.9 (41)".
    private var about: String {
        let app = [report.app.name ?? report.app.bundleIdentifier, report.app.version, report.app.build.map { "(\($0))" }]
            .compactMap { $0 }.joined(separator: " ")
        return app.isEmpty ? report.contents : "\(report.contents) · \(app)"
    }

    // MARK: - Screens

    private func section(_ screen: Report.Screen, proxy: ScrollViewProxy) -> some View {
        // The screen as it was last, then any earlier state kept for notes it no longer showed.
        let pictures = screen.images.filter { !$0.earlierState } + screen.images.filter(\.earlierState)
        return VStack(alignment: .leading, spacing: 12) {
            Text(screen.title ?? screen.viewController ?? "Untitled")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Mono.text)
            ForEach(pictures, id: \.file) { picture in
                VStack(alignment: .leading, spacing: 6) {
                    if let caption = caption(for: picture) {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(Mono.secondary)
                    }
                    pictureView(picture)
                }
            }
            notes(screen.notes.compactMap { items[$0] }) { number in
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.4)) { proxy.scrollTo(number, anchor: .center) }
            }
        }
    }

    private func caption(for picture: Report.Picture) -> String? {
        var parts: [String] = []
        if picture.earlierState { parts.append("Earlier state, before the screen changed") }
        if picture.stitchedFrom > 1, picture.part == 1 { parts.append("Stitched from \(picture.stitchedFrom) scroll positions") }
        if picture.parts > 1 { parts.append("Part \(picture.part) of \(picture.parts)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A picture at full width, with an invisible mark over each outline so a note can scroll to it.
    private func pictureView(_ picture: Report.Picture) -> some View {
        let scale = width / CGFloat(max(picture.width, 1))
        let outlined = report.items.filter { $0.picture == picture.file && $0.outline != nil }
        return ReportPicture(url: sent.folder.appending(path: picture.file), pointWidth: width, alignment: .top)
            .frame(width: width, height: CGFloat(picture.height) * scale)
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    ForEach(outlined, id: \.number) { item in
                        let box = item.outline!
                        Color.clear
                            .frame(width: CGFloat(box.width) * scale, height: CGFloat(box.height) * scale)
                            .id(item.number)
                            .padding(.leading, CGFloat(box.x) * scale)
                            .padding(.top, CGFloat(box.y) * scale)
                    }
                }
                .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Mono.hairline, lineWidth: 1))
            .accessibilityElement()
            .accessibilityLabel(picture.notes.isEmpty ? "Screenshot" : "Screenshot with notes \(picture.notes.map(String.init).joined(separator: ", ")) outlined")
            .accessibilityAddTraits(.isImage)
    }

    // MARK: - Notes

    private func notes(_ list: [Report.Item], jump: ((Int) -> Void)?) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(list.enumerated()), id: \.element.number) { index, item in
                if index > 0 {
                    Rectangle().fill(Mono.hairline).frame(height: 1).padding(.leading, 52)
                }
                if let jump, item.outline != nil {
                    Button { jump(item.number) } label: { noteRow(item) }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityHint("Scrolls to its outline")
                } else {
                    // Nothing to scroll to, such as images attached from Photos.
                    noteRow(item)
                        .accessibilityElement(children: .combine)
                }
            }
        }
        .background(Mono.fill.opacity(0.5), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Mono.hairline, lineWidth: 1))
    }

    private func noteRow(_ item: Report.Item) -> some View {
        HStack(alignment: .top, spacing: 12) {
            NumberBadge(number: item.number, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Mono.text)
                    .lineLimit(2)
                Text(item.note.isEmpty ? "No note" : item.note)
                    .font(.subheadline)
                    .foregroundStyle(item.note.isEmpty ? Mono.secondary : Mono.text)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    // MARK: - Attachments

    private var attachmentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Attachments")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Mono.text)
            ForEach(attachments, id: \.number) { item in
                VStack(alignment: .leading, spacing: 10) {
                    notes([item], jump: nil)
                    ForEach(item.attachments, id: \.self) { file in
                        ReportPicture(url: sent.folder.appending(path: file), pointWidth: width, alignment: .top, fits: true)
                            .frame(width: width)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Mono.hairline, lineWidth: 1))
                            .accessibilityLabel("Image for note \(item.number)")
                            .accessibilityAddTraits(.isImage)
                    }
                }
            }
        }
    }
}

/// The top bar of the full-screen views: a round button on the left and a centered title.
private struct ViewerBar: View {
    let title: String
    let icon: String
    let label: String
    let top: CGFloat
    let action: () -> Void

    var body: some View {
        HStack {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Mono.text)
                    .frame(width: 36, height: 36)
                    .background(Mono.surface, in: Circle())
                    .overlay(Circle().strokeBorder(Mono.hairline, lineWidth: 1))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            Spacer()
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Mono.text)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            // Balances the button so the title stays centered.
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 12)
        .padding(.top, top + 2)
        .padding(.bottom, 4)
    }
}

/// A picture from a sent report, decoded off the main thread at the size it's shown. It
/// fills the frame it's given, or, with `fits`, takes its own aspect ratio, for attachments
/// whose size the report doesn't record.
private struct ReportPicture: View {
    let url: URL?
    let pointWidth: CGFloat
    let alignment: Alignment
    var fits = false
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image, fits {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: alignment)
                    .clipped()
            } else if fits {
                Mono.fill.frame(height: pointWidth)
            } else {
                Mono.fill
            }
        }
        .task(id: url) {
            guard let url else { return }
            image = await Self.load(url, pixelWidth: pointWidth * displayScale)
        }
    }

    private static func load(_ url: URL, pixelWidth: CGFloat) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
                  width > 0
            else { return nil }
            // The longest side, at no more than the width it's shown at.
            let longest = max(width, height) * min(pixelWidth / width, 1)
            let options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: longest.rounded(.up),
            ] as CFDictionary
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options).map { UIImage(cgImage: $0) }
        }.value
    }
}

private extension SentReport {
    /// The picture shown in the list: the first screen as it was last, or the first attachment.
    var cover: URL? {
        let picture = report.screens.first.flatMap { screen in screen.images.first { !$0.earlierState } ?? screen.images.first }
        let file = picture?.file ?? report.items.lazy.flatMap(\.attachments).first
        return file.map { folder.appending(path: $0) }
    }
}
#endif
