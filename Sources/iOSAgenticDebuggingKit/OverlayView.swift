#if AGENTIC_DEBUGGING && canImport(UIKit)
import SwiftUI

/// The debugger's colors: black surfaces and white type, like the Dynamic Island
/// and other system overlays. The same on top of any app, light or dark.
enum Mono {
    static let surface = Color.black
    static let text = Color.white
    static let secondary = Color.white.opacity(0.6)
    /// Fields and secondary buttons on a black surface.
    static let fill = Color.white.opacity(0.12)
    static let hairline = Color.white.opacity(0.16)
}

/// Everything the debugger draws. The view fills the overlay window and ignores
/// safe areas, so its coordinates match the screen coordinates elements use.
struct OverlayView: View {
    @Bindable var session: DebugSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var noteFocused: Bool
    @State private var cardHeight: CGFloat = 0
    @State private var islandHeight: CGFloat = 52
    @State private var tagWidth: CGFloat = 140
    @State private var listContentHeight: CGFloat = 0
    /// The button's center when the current drag began.
    @State private var dragStart: CGPoint?

    private var width: CGFloat { session.screenSize.width }
    private var panelWidth: CGFloat { min(width - 24, 420) }
    private var panelLeading: CGFloat { (width - panelWidth) / 2 }
    private var islandWidth: CGFloat { min(width - 24, 380) }
    private var islandTop: CGFloat { session.safeAreaTop + 4 }
    private var islandBottom: CGFloat { islandTop + islandHeight }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if session.mode != .idle {
                touchSurface
                ForEach(session.markers) { marker in
                    savedNoteMarker(number: marker.number, frame: marker.frame)
                }
            }

            if session.mode == .picking || session.mode == .noting, let element = session.selected {
                outline(element.frame, weight: 2)
                if session.mode == .picking {
                    nameTag(element)
                }
            }

            if session.mode == .noting {
                noteCard
            }

            if session.mode == .tray {
                notesList
            }

            if session.mode == .picking || session.mode == .tray {
                island
                    .offset(x: (width - islandWidth) / 2, y: islandTop)
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
        .environment(\.colorScheme, .dark)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.25), value: session.mode)
    }

    // MARK: - Picking

    /// Catches touches while the debugger is active. It draws nothing, so the app stays fully visible.
    @ViewBuilder
    private var touchSurface: some View {
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

    /// A white line with a black edge, readable over any app.
    private func outline(_ frame: CGRect, weight: CGFloat) -> some View {
        let box = frame.insetBy(dx: -3, dy: -3)
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return ZStack {
            shape.stroke(Color.black.opacity(0.75), lineWidth: weight + 2)
            shape.stroke(Color.white, lineWidth: weight)
        }
        .frame(width: box.width, height: box.height)
        .offset(x: box.minX, y: box.minY)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The element under the finger: its name, then what kind of element it is.
    private func nameTag(_ element: ElementSnapshot) -> some View {
        let above = element.frame.minY - 40 > islandBottom + 4
        let x = min(max(element.frame.minX - 3, 8), width - tagWidth - 8)
        return HStack(spacing: 6) {
            Text(shortName(of: element) ?? element.role)
                .foregroundStyle(Mono.text)
            if shortName(of: element) != nil {
                Text(element.role)
                    .foregroundStyle(Mono.secondary)
            }
        }
        .font(.footnote.weight(.semibold))
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Mono.surface, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(Mono.hairline, lineWidth: 1))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tagWidth = $0 }
        .offset(x: x, y: above ? element.frame.minY - 36 : element.frame.maxY + 8)
        .allowsHitTesting(false)
    }

    /// A note already made on this screen: its outline and number.
    private func savedNoteMarker(number: Int, frame: CGRect) -> some View {
        let badge: CGFloat = 22
        let x = min(max(frame.minX - badge / 2, 4), width - badge - 4)
        let y = max(frame.minY - badge / 2, islandBottom + 4)
        return ZStack(alignment: .topLeading) {
            outline(frame, weight: 1)
            numberBadge(number, size: badge)
                .offset(x: x, y: y)
        }
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel("Note \(number)")
    }

    private func numberBadge(_ number: Int, size: CGFloat) -> some View {
        Text("\(number)")
            .font(.caption.weight(.bold).monospacedDigit())
            .foregroundStyle(Color.black)
            .frame(minWidth: size, minHeight: size)
            .background(Color.white, in: Circle())
            .overlay(Circle().strokeBorder(Color.black, lineWidth: 1.5))
    }

    private func shortName(of element: ElementSnapshot) -> String? {
        guard let name = element.label?.nonEmpty ?? element.identifier?.nonEmpty ?? element.value?.nonEmpty else { return nil }
        return name.count > 34 ? String(name.prefix(33)) + "…" : name
    }

    // MARK: - Island

    /// The pick-mode controls: a black capsule under the status bar.
    private var island: some View {
        let count = session.annotations.count
        return HStack(spacing: 10) {
            Button { session.exitPicking() } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Mono.text)
                    .frame(width: 32, height: 32)
                    .background(Mono.fill, in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Stop picking")

            Button { session.toggleTray() } label: {
                HStack(spacing: 4) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(session.screenTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Mono.text)
                        Text(count == 0 ? "Tap an element" : count == 1 ? "1 note" : "\(count) notes")
                            .font(.caption)
                            .foregroundStyle(Mono.secondary)
                    }
                    .lineLimit(1)
                    if count > 0 {
                        Image(systemName: session.mode == .tray ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Mono.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .disabled(count == 0)
            .accessibilityLabel(count == 0 ? "\(session.screenTitle). Tap an element to add a note." : session.mode == .tray ? "Hide notes" : "Show \(count) notes")

            if count > 0 {
                Button { session.send() } label: {
                    Text("Send")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 16)
                        .frame(height: 34)
                        .background(Color.white, in: Capsule(style: .continuous))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(count == 1 ? "Send 1 note" : "Send \(count) notes")
            }
        }
        .buttonStyle(.plain)
        .padding(.leading, 4)
        .padding(.trailing, count > 0 ? 9 : 16)
        .padding(.vertical, 4)
        .frame(width: islandWidth)
        .background(Mono.surface, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(Mono.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { islandHeight = $0 }
    }

    // MARK: - Note card

    private var noteCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                numberBadge(session.slipNumber, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.noteElement.flatMap(shortName(of:)) ?? "Unnamed element")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Mono.text)
                    Text(session.noteElement?.role ?? "Element")
                        .font(.caption)
                        .foregroundStyle(Mono.secondary)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
                if session.canStepDown {
                    sizeButton("Smaller") { session.stepDown() }
                }
                if session.canStepUp {
                    sizeButton("Larger") { session.stepUp() }
                }
            }

            TextField("What's wrong?", text: $session.noteText, axis: .vertical)
                .font(.body)
                .foregroundStyle(Mono.text)
                .tint(Color.white)
                .lineLimit(2...5)
                .focused($noteFocused)
                .padding(12)
                .background(Mono.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack {
                Button("Cancel") { session.cancelNote() }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Mono.secondary)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                Spacer()
                Button { session.saveNote() } label: {
                    Text(session.editingID == nil ? "Add note" : "Save")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 18)
                        .frame(height: 38)
                        .background(Color.white, in: Capsule(style: .continuous))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
            }
        }
        .buttonStyle(.plain)
        .padding(16)
        .frame(width: panelWidth)
        .background(Mono.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Mono.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardHeight = $0 }
        .offset(x: panelLeading, y: session.noteBoxTop(height: cardHeight == 0 ? 190 : cardHeight))
        .onAppear { noteFocused = true }
    }

    /// Moves the selection to a larger or smaller element around the same spot.
    private func sizeButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Mono.text)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Mono.fill, in: Capsule(style: .continuous))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(title == "Larger" ? "Select the larger area around it" : "Select a smaller part")
    }

    // MARK: - Notes list

    /// The notes waiting to be sent, under the island.
    private var notesList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(session.annotations.enumerated()), id: \.element.id) { index, annotation in
                    if index > 0 {
                        Rectangle().fill(Mono.hairline).frame(height: 1).padding(.leading, 16)
                    }
                    noteRow(number: index + 1, annotation: annotation)
                }
            }
            .padding(.vertical, 6)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listContentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: panelWidth, height: min(listContentHeight, session.screenSize.height * 0.5))
        .background(Mono.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Mono.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
        .offset(x: panelLeading, y: islandBottom + 8)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func noteRow(number: Int, annotation: Annotation) -> some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail(for: annotation)
                .overlay(alignment: .topLeading) {
                    numberBadge(number, size: 20).offset(x: -6, y: -6)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(shortName(of: annotation.element) ?? annotation.element.role)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Mono.text)
                    .lineLimit(1)
                Text(annotation.note.isEmpty ? "No note" : annotation.note)
                    .font(.subheadline)
                    .foregroundStyle(annotation.note.isEmpty ? Mono.secondary : Mono.text)
                    .lineLimit(2)
                Text([annotation.element.role, annotation.screen.title].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(Mono.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button(role: .destructive) { session.delete(annotation) } label: {
                Image(systemName: "trash")
                    .font(.subheadline)
                    .foregroundStyle(Color.red)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete note \(number)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { session.edit(annotation) }
        .accessibilityAction(named: "Edit note") { session.edit(annotation) }
    }

    @ViewBuilder
    private func thumbnail(for annotation: Annotation) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        if let image = session.thumbnail(for: annotation) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 52, height: 52)
                .clipShape(shape)
                .overlay(shape.strokeBorder(Mono.hairline, lineWidth: 1))
                .accessibilityHidden(true)
        } else {
            shape.fill(Mono.fill).frame(width: 52, height: 52)
        }
    }

    // MARK: - Idle

    private func toastView(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Mono.text)
            Text(message)
                .foregroundStyle(Mono.text)
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(Mono.surface, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(Mono.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
        .frame(width: width)
        .offset(y: islandTop)
        .allowsHitTesting(false)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func floatingButton(at center: CGPoint) -> some View {
        let count = session.annotations.count
        return Image(systemName: "viewfinder")
            .font(.system(size: 21, weight: .semibold))
            .foregroundStyle(Mono.text)
            .frame(width: FloatingButtonPlacement.size, height: FloatingButtonPlacement.size)
            .background(Mono.surface, in: Circle())
            .overlay(Circle().strokeBorder(Mono.hairline, lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                if count > 0 {
                    numberBadge(count, size: 20).offset(x: 4, y: -4)
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
#endif
