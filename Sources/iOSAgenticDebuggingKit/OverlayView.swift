#if AGENTIC_DEBUGGING && canImport(UIKit)
import SwiftUI

/// The debugger's palette, taken from engineering drawings: graphite ink, drafting
/// white, one revision orange. Fixed colors, so the debugger looks the same on top
/// of any app and is never mistaken for part of it.
enum Drafting {
    static let ink = Color(red: 17 / 255, green: 20 / 255, blue: 24 / 255)
    static let paper = Color(red: 247 / 255, green: 248 / 255, blue: 246 / 255)
    static let orange = Color(red: 1, green: 90 / 255, blue: 31 / 255)
    /// Labels and rules on ink.
    static let gray = Color(red: 138 / 255, green: 144 / 255, blue: 153 / 255)
    /// Secondary text on paper; darker than `gray` so it stays readable there.
    static let graphite = Color(red: 92 / 255, green: 99 / 255, blue: 109 / 255)
}

/// Everything the debugger draws. The view fills the overlay window and ignores
/// safe areas, so its coordinates match the screen coordinates elements use.
struct OverlayView: View {
    @Bindable var session: DebugSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var noteFocused: Bool
    @State private var slipFrame = CGRect.zero
    @State private var titleBlockHeight: CGFloat = 52
    @State private var tagWidth: CGFloat = 160
    @State private var listContentHeight: CGFloat = 0
    @State private var leaderProgress: CGFloat = 0
    /// The button's center when the current drag began.
    @State private var dragStart: CGPoint?

    private var width: CGFloat { session.screenSize.width }
    private var panelWidth: CGFloat { min(width - 24, 420) }
    private var panelLeading: CGFloat { (width - panelWidth) / 2 }
    private var titleBlockTop: CGFloat { session.safeAreaTop + 4 }
    private var titleBlockBottom: CGFloat { titleBlockTop + titleBlockHeight }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if session.mode != .idle {
                surface
                sheetBorder
                ForEach(session.markers) { marker in
                    callout(number: marker.number, frame: marker.frame)
                }
            }

            if session.mode == .picking, let element = session.selected {
                cornerTicks(around: element.frame)
                elementTag(element)
            }

            if session.mode == .noting {
                if let element = session.selected, session.editingID == nil {
                    cornerTicks(around: element.frame)
                    slipLeader(to: element.frame)
                }
                noteSlip
            }

            if session.mode == .tray {
                notesList
            }

            if session.mode == .picking || session.mode == .tray {
                titleBlock
                    .offset(x: (width - min(width - 24, 400)) / 2, y: titleBlockTop)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if session.mode == .idle {
                if let toast = session.toast {
                    toastView(toast)
                }
                if let center = session.buttonCenter {
                    floatingButton(at: center)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: 0.22), value: session.mode)
    }

    // MARK: - Sheet

    /// Catches touches while the debugger is active. Nothing is drawn: the app stays fully visible.
    @ViewBuilder
    private var surface: some View {
        switch session.mode {
        case .picking:
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .onChanged { session.hover(at: $0.location) }
                        .onEnded { session.finishHover(at: $0.location) }
                )
        case .tray:
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { session.toggleTray() }
        case .noting, .idle:
            Color.clear.contentShape(Rectangle())
        }
    }

    /// A thin orange border just inside the display's edge, with a tick at the
    /// middle of each side: the app has become a drawing sheet.
    private var sheetBorder: some View {
        let inset: CGFloat = 3
        let radius = max(session.displayCornerRadius - inset, 0)
        return ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Drafting.orange, lineWidth: 2)
                .padding(inset)
            SheetTicks(inset: inset)
                .stroke(Drafting.orange, lineWidth: 2)
        }
        .frame(width: session.screenSize.width, height: session.screenSize.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Callouts

    private func cornerTicks(around frame: CGRect) -> some View {
        let box = frame.insetBy(dx: -4, dy: -4)
        return CornerTicks()
            .stroke(Drafting.orange, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            .frame(width: box.width, height: box.height)
            .offset(x: box.minX, y: box.minY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// The name tag for the element under the finger: its role in small caps, then its label.
    private func elementTag(_ element: ElementSnapshot) -> some View {
        let above = element.frame.minY - 38 > titleBlockBottom + 4
        let x = min(max(element.frame.minX - 4, 8), width - tagWidth - 8)
        return HStack(spacing: 6) {
            Text(element.role.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(0.6)
                .foregroundStyle(Drafting.gray)
            if let name = shortName(of: element) {
                Text(name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Drafting.paper)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Drafting.ink, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tagWidth = $0 }
        .offset(x: x, y: above ? element.frame.minY - 34 : element.frame.maxY + 8)
        .allowsHitTesting(false)
    }

    /// A saved note on this screen: a numbered balloon on a leader line, ending in a dot on the element.
    private func callout(number: Int, frame: CGRect) -> some View {
        let center = balloonCenter(for: frame)
        let end = nearestPoint(on: frame, to: center)
        return ZStack(alignment: .topLeading) {
            LeaderLine(from: end, to: center)
                .stroke(Drafting.orange, lineWidth: 1.5)
            Circle()
                .fill(Drafting.orange)
                .frame(width: 6, height: 6)
                .offset(x: end.x - 3, y: end.y - 3)
            Balloon(number: number)
                .offset(x: center.x - Balloon.size / 2, y: center.y - Balloon.size / 2)
        }
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel("Note \(number)")
    }

    /// The leader that draws itself from the picked element to the note slip's balloon.
    private func slipLeader(to frame: CGRect) -> some View {
        let balloon = CGPoint(x: slipFrame.minX + 14 + Balloon.size / 2, y: slipFrame.minY + 14 + Balloon.size / 2)
        let end = nearestPoint(on: frame, to: balloon)
        return ZStack(alignment: .topLeading) {
            LeaderLine(from: end, to: balloon)
                .trim(from: 0, to: leaderProgress)
                .stroke(Drafting.orange, lineWidth: 1.5)
            Circle()
                .fill(Drafting.orange)
                .frame(width: 6, height: 6)
                .offset(x: end.x - 3, y: end.y - 3)
        }
        .opacity(slipFrame == .zero ? 0 : 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            leaderProgress = 0
            if reduceMotion {
                leaderProgress = 1
            } else {
                withAnimation(.easeOut(duration: 0.32).delay(0.05)) { leaderProgress = 1 }
            }
        }
    }

    /// Where a saved note's balloon sits: just off a corner of its element, the
    /// first corner that keeps the balloon on screen and clear of the title block.
    private func balloonCenter(for frame: CGRect) -> CGPoint {
        let offset: CGFloat = 22
        let half = Balloon.size / 2
        let candidates = [
            CGPoint(x: frame.maxX + offset, y: frame.minY - offset),
            CGPoint(x: frame.minX - offset, y: frame.minY - offset),
            CGPoint(x: frame.maxX + offset, y: frame.maxY + offset),
            CGPoint(x: frame.minX - offset, y: frame.maxY + offset),
        ]
        let fits: (CGPoint) -> Bool = { point in
            point.x - half >= 6 && point.x + half <= width - 6
                && point.y - half >= titleBlockBottom + 6 && point.y + half <= session.screenSize.height - 6
        }
        if let point = candidates.first(where: fits) { return point }
        return CGPoint(
            x: min(max(frame.maxX - half, half + 6), width - half - 6),
            y: min(max(frame.minY + half, titleBlockBottom + half + 6), session.screenSize.height - half - 6)
        )
    }

    private func nearestPoint(on frame: CGRect, to point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, frame.minX), frame.maxX), y: min(max(point.y, frame.minY), frame.maxY))
    }

    private func shortName(of element: ElementSnapshot) -> String? {
        guard let name = element.label?.nonEmpty ?? element.identifier?.nonEmpty ?? element.value?.nonEmpty else { return nil }
        return name.count > 32 ? String(name.prefix(31)) + "…" : name
    }

    // MARK: - Title block

    /// The pick-mode controls, laid out like a drawing's title block: ruled cells
    /// with small labels, the orange Send cell at the end.
    private var titleBlock: some View {
        let count = session.annotations.count
        return HStack(spacing: 0) {
            Button { session.exitPicking() } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Drafting.paper)
                    .frame(width: 48)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Stop picking")

            rule
            titleCell(label: "Screen", value: session.screenTitle)
                .frame(maxWidth: .infinity, alignment: .leading)

            if count == 0 {
                rule
                Text("Tap an element")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Drafting.gray)
                    .padding(.horizontal, 14)
            } else {
                rule
                Button { session.toggleTray() } label: {
                    HStack(alignment: .lastTextBaseline, spacing: 6) {
                        titleCell(label: "Notes", value: "\(count)")
                        Image(systemName: session.mode == .tray ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Drafting.gray)
                            .padding(.trailing, 12)
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel(session.mode == .tray ? "Hide notes" : "Show \(count) notes")

                Button { session.send() } label: {
                    Text("Send")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Drafting.ink)
                        .padding(.horizontal, 18)
                        .frame(maxHeight: .infinity)
                        .background(Drafting.orange)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(count == 1 ? "Send 1 note" : "Send \(count) notes")
            }
        }
        .buttonStyle(.plain)
        .frame(minHeight: 52)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: min(width - 24, 400))
        .background(Drafting.ink)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Drafting.gray.opacity(0.35), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { titleBlockHeight = $0 }
    }

    private func titleCell(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(0.8)
                .foregroundStyle(Drafting.gray)
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(Drafting.paper)
                .lineLimit(1)
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
    }

    private var rule: some View {
        Rectangle()
            .fill(Drafting.gray.opacity(0.35))
            .frame(width: 1)
    }

    // MARK: - Note slip

    private var noteSlip: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Balloon(number: session.slipNumber)
                VStack(alignment: .leading, spacing: 1) {
                    Text((session.noteElement?.role ?? "Element").uppercased())
                        .font(.caption2.weight(.bold))
                        .tracking(0.6)
                        .foregroundStyle(Drafting.graphite)
                    Text(session.noteElement.flatMap(shortName(of:)) ?? "Unnamed element")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Drafting.ink)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if session.canStepDown {
                    sizeButton("Smaller", systemImage: "arrow.down.right.and.arrow.up.left") { session.stepDown() }
                }
                if session.canStepUp {
                    sizeButton("Larger", systemImage: "arrow.up.left.and.arrow.down.right") { session.stepUp() }
                }
            }

            TextField("What's wrong?", text: $session.noteText, axis: .vertical)
                .font(.body)
                .foregroundStyle(Drafting.ink)
                .tint(Drafting.orange)
                .lineLimit(2...5)
                .focused($noteFocused)
                .padding(.vertical, 6)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Drafting.ink.opacity(0.22)).frame(height: 1)
                }

            HStack {
                Button("Cancel") { session.cancelNote() }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Drafting.graphite)
                    .frame(minHeight: 44)
                Spacer()
                Button { session.saveNote() } label: {
                    Text(session.editingID == nil ? "Add note" : "Save")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Drafting.ink)
                        .padding(.horizontal, 18)
                        .frame(minHeight: 44)
                        .background(Drafting.orange, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
        .buttonStyle(.plain)
        .padding(14)
        .frame(width: panelWidth)
        .background(Drafting.paper, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Drafting.ink.opacity(0.16), lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
        .environment(\.colorScheme, .light)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { slipFrame = $0 }
        .offset(x: panelLeading, y: session.noteBoxTop(height: slipFrame.height == 0 ? 180 : slipFrame.height))
        .onAppear { noteFocused = true }
        .onDisappear { slipFrame = .zero }
    }

    private func sizeButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Drafting.ink)
                .padding(.horizontal, 10)
                .frame(minHeight: 32)
                .overlay(Capsule().strokeBorder(Drafting.ink.opacity(0.25), lineWidth: 1))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(title == "Larger" ? "Pick the larger area around it" : "Pick a smaller part")
    }

    // MARK: - Notes list

    /// The notes waiting to be sent, laid out like a drawing's parts list.
    private var notesList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("No.").frame(width: Balloon.size, alignment: .leading)
                Text("Element and note")
                Spacer()
            }
            .font(.caption2.weight(.bold))
            .textCase(.uppercase)
            .tracking(0.8)
            .foregroundStyle(Drafting.graphite)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            Rectangle().fill(Drafting.ink.opacity(0.14)).frame(height: 1)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(session.annotations.enumerated()), id: \.element.id) { index, annotation in
                        if index > 0 {
                            Rectangle().fill(Drafting.ink.opacity(0.1)).frame(height: 1).padding(.leading, 14)
                        }
                        noteRow(number: index + 1, annotation: annotation)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listContentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(listContentHeight, session.screenSize.height * 0.5))
        }
        .frame(width: panelWidth)
        .background(Drafting.paper, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Drafting.ink.opacity(0.16), lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
        .environment(\.colorScheme, .light)
        .offset(x: panelLeading, y: titleBlockBottom + 8)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func noteRow(number: Int, annotation: Annotation) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Balloon(number: number)
            thumbnail(for: annotation)
            VStack(alignment: .leading, spacing: 2) {
                Text(annotation.element.role.uppercased())
                    .font(.caption2.weight(.bold))
                    .tracking(0.6)
                    .foregroundStyle(Drafting.graphite)
                Text(shortName(of: annotation.element) ?? "Unnamed element")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Drafting.ink)
                    .lineLimit(1)
                Text(annotation.note.isEmpty ? "No note" : annotation.note)
                    .font(.subheadline)
                    .foregroundStyle(annotation.note.isEmpty ? Drafting.graphite : Drafting.ink)
                    .lineLimit(2)
                if let title = annotation.screen.title {
                    Text("On \(title)")
                        .font(.caption)
                        .foregroundStyle(Drafting.graphite)
                }
            }
            Spacer(minLength: 0)
            Button(role: .destructive) { session.delete(annotation) } label: {
                Image(systemName: "trash")
                    .font(.subheadline)
                    .foregroundStyle(Drafting.graphite)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete note \(number)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { session.edit(annotation) }
        .accessibilityAction(named: "Edit note") { session.edit(annotation) }
    }

    @ViewBuilder
    private func thumbnail(for annotation: Annotation) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        if let image = session.thumbnail(for: annotation) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 52, height: 52)
                .clipShape(shape)
                .overlay(shape.strokeBorder(Drafting.ink.opacity(0.16), lineWidth: 1))
                .accessibilityHidden(true)
        } else {
            shape.fill(Drafting.ink.opacity(0.06)).frame(width: 52, height: 52)
        }
    }

    // MARK: - Idle

    private func toastView(_ message: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(Drafting.orange).frame(width: 7, height: 7)
            Text(message)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Drafting.paper)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Drafting.ink, in: Capsule())
        .overlay(Capsule().strokeBorder(Drafting.gray.opacity(0.35), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .frame(width: width)
        .offset(y: titleBlockTop)
        .allowsHitTesting(false)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func floatingButton(at center: CGPoint) -> some View {
        let count = session.annotations.count
        return CalloutGlyph()
            .frame(width: 26, height: 26)
            .frame(width: FloatingButtonPlacement.size, height: FloatingButtonPlacement.size)
            .background(Drafting.ink, in: Circle())
            .overlay(Circle().strokeBorder(Drafting.gray.opacity(0.45), lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(Drafting.ink)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(Drafting.orange, in: Circle())
                        .overlay(Circle().strokeBorder(Drafting.ink, lineWidth: 1.5))
                        .offset(x: 4, y: -4)
                }
            }
            .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
            .contentShape(Circle())
            .onTapGesture { session.enterPicking() }
            .gesture(
                DragGesture(minimumDistance: 6, coordinateSpace: .global)
                    .onChanged { value in
                        // The button follows the finger itself, so the snap starts from where it's let go.
                        let start = dragStart ?? center
                        if dragStart == nil { dragStart = center }
                        session.dragButton(to: CGPoint(
                            x: start.x + value.translation.width,
                            y: start.y + value.translation.height
                        ))
                    }
                    .onEnded { value in
                        let start = dragStart ?? center
                        dragStart = nil
                        // Snap toward where a flick was heading.
                        withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                            session.moveButton(to: CGPoint(
                                x: start.x + value.predictedEndTranslation.width,
                                y: start.y + value.predictedEndTranslation.height
                            ))
                        }
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(count == 0 ? "Report a UI issue" : "Report a UI issue, \(count) notes waiting")
            .accessibilityAddTraits(.isButton)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { session.setButtonFrame($0) }
            .onDisappear { session.setButtonFrame(nil) }
            .position(center)
    }
}

// MARK: - Drawing parts

/// A numbered balloon, the circle engineers use to call out a part.
struct Balloon: View {
    static let size: CGFloat = 26
    let number: Int

    var body: some View {
        Text("\(number)")
            .font(.system(size: 13, weight: .bold).monospacedDigit())
            .foregroundStyle(Drafting.ink)
            .frame(width: Self.size, height: Self.size)
            .background(Drafting.paper, in: Circle())
            .overlay(Circle().strokeBorder(Drafting.orange, lineWidth: 2))
    }
}

/// L-shaped ticks at the four corners of a rectangle, like crop marks.
struct CornerTicks: Shape {
    func path(in rect: CGRect) -> Path {
        let arm = min(14, rect.width / 3, rect.height / 3)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + arm))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + arm, y: rect.minY))
        path.move(to: CGPoint(x: rect.maxX - arm, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + arm))
        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - arm))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - arm, y: rect.maxY))
        path.move(to: CGPoint(x: rect.minX + arm, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - arm))
        return path
    }
}

/// Short ticks at the middle of each side of the sheet border, like a drawing's zone marks.
struct SheetTicks: Shape {
    let inset: CGFloat

    func path(in rect: CGRect) -> Path {
        let length: CGFloat = 10
        let box = rect.insetBy(dx: inset, dy: inset)
        var path = Path()
        path.move(to: CGPoint(x: box.midX, y: box.maxY))
        path.addLine(to: CGPoint(x: box.midX, y: box.maxY - length))
        path.move(to: CGPoint(x: box.minX, y: box.midY))
        path.addLine(to: CGPoint(x: box.minX + length, y: box.midY))
        path.move(to: CGPoint(x: box.maxX, y: box.midY))
        path.addLine(to: CGPoint(x: box.maxX - length, y: box.midY))
        return path
    }
}

/// A straight leader line between two points in screen coordinates.
struct LeaderLine: Shape {
    var from: CGPoint
    var to: CGPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)
        return path
    }
}

/// The floating button's mark: a small balloon on an orange leader line.
struct CalloutGlyph: View {
    var body: some View {
        Canvas { context, size in
            let unit = size.width / 24
            context.stroke(
                Path(ellipseIn: CGRect(x: 10 * unit, y: 3 * unit, width: 11 * unit, height: 11 * unit)),
                with: .color(Drafting.paper),
                lineWidth: 2 * unit
            )
            var leader = Path()
            leader.move(to: CGPoint(x: 11.6 * unit, y: 12.4 * unit))
            leader.addLine(to: CGPoint(x: 5.6 * unit, y: 18.4 * unit))
            context.stroke(leader, with: .color(Drafting.orange), style: StrokeStyle(lineWidth: 2 * unit, lineCap: .round))
            context.fill(
                Path(ellipseIn: CGRect(x: 2.8 * unit, y: 15.6 * unit, width: 5 * unit, height: 5 * unit)),
                with: .color(Drafting.orange)
            )
        }
        .accessibilityHidden(true)
    }
}
#endif
