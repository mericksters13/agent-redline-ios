#if AGENTIC_DEBUGGING && canImport(UIKit)
import SwiftUI

/// Everything the debugger draws. The view fills the overlay window and ignores
/// safe areas, so its coordinates match the screen coordinates elements use.
struct OverlayView: View {
    @Bindable var session: DebugSession
    @FocusState private var noteFocused: Bool
    @State private var noteBoxHeight: CGFloat = 180
    @State private var trayContentHeight: CGFloat = 0
    /// The button's center when the current drag began.
    @State private var dragStart: CGPoint?

    private var panelWidth: CGFloat { min(session.screenSize.width - 24, 420) }
    private var panelLeading: CGFloat { (session.screenSize.width - panelWidth) / 2 }
    private var islandBottom: CGFloat { session.safeAreaTop + 6 + 44 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            switch session.mode {
            case .picking:
                pickingSurface
            case .tray:
                Color.black.opacity(0.06)
                    .contentShape(Rectangle())
                    .onTapGesture { session.toggleTray() }
            case .noting:
                Color.black.opacity(0.06)
            case .idle:
                Color.clear.allowsHitTesting(false)
            }

            if session.mode != .idle {
                ForEach(session.markers) { marker in
                    numberBadge(marker.number)
                        .offset(x: marker.frame.minX - 10, y: marker.frame.minY - 10)
                        .allowsHitTesting(false)
                }
            }

            if session.mode == .picking || session.mode == .noting, let element = session.selected {
                highlight(element)
            }

            if session.mode == .noting {
                noteBox
            }

            if session.mode == .tray {
                tray
            }

            topBar

            if session.mode == .idle, let center = session.buttonCenter {
                floatingButton(at: center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .animation(.snappy(duration: 0.2), value: session.mode)
    }

    // MARK: - Picking

    private var pickingSurface: some View {
        Color.black.opacity(0.06)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { session.hover(at: $0.location) }
                    .onEnded { session.finishHover(at: $0.location) }
            )
    }

    private func highlight(_ element: ElementSnapshot) -> some View {
        let frame = element.frame.insetBy(dx: -3, dy: -3)
        let chipAbove = frame.minY - 30 > islandBottom
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.blue.opacity(0.12))
                .strokeBorder(Color.blue, lineWidth: 2)
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)

            Text(element.displayName)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.blue, in: Capsule())
                .fixedSize()
                .offset(
                    x: max(8, min(frame.minX, session.screenSize.width - 240)),
                    y: chipAbove ? frame.minY - 28 : frame.maxY + 6
                )
        }
        .allowsHitTesting(false)
    }

    private func numberBadge(_ number: Int) -> some View {
        Text("\(number)")
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(Color.blue, in: Circle())
    }

    // MARK: - Top bar

    @ViewBuilder
    private var topBar: some View {
        Group {
            switch session.mode {
            case .picking, .tray:
                island
            case .noting:
                EmptyView()
            case .idle:
                if let toast = session.toast {
                    Text(toast)
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(width: session.screenSize.width)
        .offset(y: session.safeAreaTop + 6)
    }

    private var island: some View {
        HStack(spacing: 10) {
            Button { session.exitPicking() } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("Stop picking")

            if session.annotations.isEmpty {
                Text("Tap an element")
                    .foregroundStyle(.secondary)
            } else {
                Button { session.toggleTray() } label: {
                    HStack(spacing: 4) {
                        Text(session.annotations.count == 1 ? "1 note" : "\(session.annotations.count) notes")
                        Image(systemName: session.mode == .tray ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                    }
                }
            }

            Spacer(minLength: 0)

            if !session.annotations.isEmpty {
                Button("Send") { session.send() }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
            }
        }
        .font(.subheadline.weight(.medium))
        .tint(.blue)
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .frame(width: min(session.screenSize.width - 32, 360), height: 44)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
    }

    // MARK: - Floating button

    private func floatingButton(at center: CGPoint) -> some View {
        let count = session.annotations.count
        return Image(systemName: "ladybug.fill")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: FloatingButtonPlacement.size, height: FloatingButtonPlacement.size)
            .background(Color.black.opacity(0.75), in: Circle())
            .overlay(Circle().strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                if count > 0 {
                    numberBadge(count).offset(x: 4, y: -4)
                }
            }
            .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
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
            .accessibilityLabel(count == 0 ? "Report a UI issue" : "Report a UI issue, \(count) notes waiting")
            .accessibilityAddTraits(.isButton)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { session.setButtonFrame($0) }
            .onDisappear { session.setButtonFrame(nil) }
            .position(center)
    }

    // MARK: - Note box

    private var noteBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(session.noteTitle)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.15), in: Capsule())
                Spacer(minLength: 0)
                if session.canStepDown {
                    Button { session.stepDown() } label: { Image(systemName: "arrow.down") }
                        .accessibilityLabel("Smaller element")
                }
                if session.canStepUp {
                    Button { session.stepUp() } label: { Label("Parent", systemImage: "arrow.up") }
                }
            }
            .font(.subheadline)

            TextField("What's wrong?", text: $session.noteText, axis: .vertical)
                .lineLimit(2...5)
                .focused($noteFocused)
                .padding(10)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))

            HStack {
                Button("Cancel") { session.cancelNote() }
                Spacer()
                Button(session.editingID == nil ? "Add note" : "Save") { session.saveNote() }
                    .buttonStyle(.borderedProminent)
            }
            .font(.subheadline.weight(.medium))
        }
        .tint(.blue)
        .padding(12)
        .frame(width: panelWidth)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { noteBoxHeight = $0 }
        .offset(x: panelLeading, y: session.noteBoxTop(height: noteBoxHeight))
        .onAppear { noteFocused = true }
    }

    // MARK: - Tray

    private var tray: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(session.annotations.enumerated()), id: \.element.id) { index, annotation in
                    if index > 0 { Divider() }
                    trayRow(number: index + 1, annotation: annotation)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { trayContentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: panelWidth, height: min(trayContentHeight, session.screenSize.height * 0.5))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .offset(x: panelLeading, y: islandBottom + 8)
    }

    private func trayRow(number: Int, annotation: Annotation) -> some View {
        HStack(alignment: .top, spacing: 10) {
            numberBadge(number)
            VStack(alignment: .leading, spacing: 2) {
                Text(annotation.element.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(annotation.note.isEmpty ? "No note" : annotation.note)
                    .font(.subheadline)
                    .foregroundStyle(annotation.note.isEmpty ? .secondary : .primary)
                    .lineLimit(2)
                if let title = annotation.screen.title {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Button(role: .destructive) { session.delete(annotation) } label: {
                Image(systemName: "trash")
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("Delete note \(number)")
        }
        .padding(12)
        .contentShape(Rectangle())
        .onTapGesture { session.edit(annotation) }
    }
}
#endif
