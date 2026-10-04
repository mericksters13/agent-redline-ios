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

/// The colors of marking the app itself, the only color the debugger draws over the app.
/// Red is the usual color for markup and matches the outlines in sent screenshots.
enum Markup {
    /// What is marked: the element under the finger and notes already made.
    static let red = Color(uiColor: .systemRed)
    /// The steady frame around the screen in annotate mode: lighter, since it's ambient.
    /// A blinking red is kept for recording.
    static let frame = Color(red: 1, green: 0.42, blue: 0.42)
}

/// Everything the debugger draws. The view fills the overlay window and ignores
/// safe areas, so its coordinates match the screen coordinates elements use.
struct OverlayView: View {
    @Bindable var session: DebugSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var noteFocused: Bool
    @State private var cardHeight: CGFloat = 0
    /// The note card's element row and text field, which scroll when the card is capped.
    @State private var noteContentHeight: CGFloat = 0
    /// The note card's error line and buttons, which never scroll.
    @State private var noteFooterHeight: CGFloat = 0
    /// The card's height when it opened, before any typing.
    @State private var openingCardHeight: CGFloat = 0
    @State private var islandHeight: CGFloat = 52
    @State private var tagWidth: CGFloat = 140
    @State private var listContentHeight: CGFloat = 0
    /// The finger on the floating button, from touch down to lift.
    @State private var press: ButtonPress?

    private var width: CGFloat { session.screenSize.width }
    private var panelWidth: CGFloat { min(width - 24, 420) }
    private var panelLeading: CGFloat { (width - panelWidth) / 2 }
    private var islandWidth: CGFloat { min(width - 24, 380) }
    private var islandTop: CGFloat { session.safeAreaTop + 4 }
    private var islandBottom: CGFloat { islandTop + islandHeight }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if session.mode != .idle && session.mode != .viewer && session.mode != .reports && session.mode != .destination {
                touchSurface
                // Frames from before a rotation would land on the wrong spots.
                if session.screenReadIsCurrent {
                    ForEach(session.markers) { marker in
                        savedNoteMarker(number: marker.number, frame: marker.frame)
                    }
                }
            }

            if session.mode == .picking || session.mode == .tray || session.mode == .attaching || session.mode == .noting {
                annotateFrame
                    .transition(.opacity)
            }

            if session.mode == .picking || session.mode == .noting, session.screenReadIsCurrent, let element = session.selected {
                outline(element.frame, weight: 2.5)
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

            if session.mode == .picking || session.mode == .tray || session.mode == .attaching {
                island
                    .modifier(Shake(phase: reduceMotion ? 0 : CGFloat(session.nudges)))
                    // Placed by layout, not offset: views moved with offset can keep taking
                    // touches at their original position when they contain UIKit-backed views.
                    .padding(.leading, (width - islandWidth) / 2)
                    .padding(.top, islandTop)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if session.mode == .picking, let hint = session.hint {
                hintChip(hint)
                    .frame(width: width)
                    .padding(.top, islandBottom + 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if session.mode == .attaching {
                AttachmentPicker(session: session)
            }

            if session.mode == .viewer {
                NoteViewer(session: session)
                    .transition(.opacity)
            }

            if session.mode == .reports {
                SentReportsView(session: session)
                    .transition(.opacity)
            }

            if session.mode == .destination {
                DestinationPicker(session: session)
                    .transition(.opacity)
            }

            if session.mode == .idle, let center = session.buttonCenter {
                floatingButton(at: center)
            }

            // Shown in every mode but noting, which has its own error line on the card,
            // so a failed Send or delete is seen where it happened.
            if session.mode != .noting, let toast = session.toast {
                toastView(toast)
            }

            if let suggestion = session.suggestion, session.mode == .idle || session.mode == .picking {
                suggestionCard(suggestion)
            }

            if let capture = session.captureFlight {
                CaptureFlight(image: capture, screenSize: session.screenSize, slot: session.attachmentSlot) {
                    session.finishCaptureFlight()
                }
                // Shown at once: fading in with the mode change would swallow the flash.
                .transition(.identity)
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
        case .noting, .idle, .viewer, .attaching, .reports, .destination:
            Color.clear.contentShape(Rectangle())
        }
    }

    /// A steady light red line around the whole screen, along its rounded corners, while the
    /// debugger has the screen, so the app is never mistaken for being live.
    private var annotateFrame: some View {
        RoundedRectangle(cornerRadius: session.displayCornerRadius, style: .continuous)
            .strokeBorder(Markup.frame, lineWidth: 4)
        .frame(width: session.screenSize.width, height: session.screenSize.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Under the island after a tap that found nothing: which mode this is and the way out.
    private func hintChip(_ title: String) -> some View {
        (Text(title).foregroundStyle(Mono.text)
            + Text("  Tap ").foregroundStyle(Mono.secondary)
            + Text(Image(systemName: "xmark.circle.fill")).foregroundStyle(Mono.text)
            + Text(" to use the app").foregroundStyle(Mono.secondary))
            .font(.footnote.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Mono.surface, in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous).strokeBorder(Mono.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 12, y: 5)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// A red line with a thin white halo, so it reads on dark and red content too.
    private func outline(_ frame: CGRect, weight: CGFloat) -> some View {
        let box = frame.insetBy(dx: -3, dy: -3)
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return ZStack {
            shape.stroke(Color.white.opacity(0.9), lineWidth: weight + 2)
            shape.stroke(Markup.red, lineWidth: weight)
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
            Text(element.shortName ?? element.role)
                .foregroundStyle(Mono.text)
            if element.shortName != nil {
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
            outline(frame, weight: 1.5)
            // Red with a white number, like the notes in sent screenshots.
            Text("\(number)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(Color.white)
                .frame(minWidth: badge, minHeight: badge)
                .background(Markup.red, in: Circle())
                .overlay(Circle().strokeBorder(Color.white, lineWidth: 1.5))
                .offset(x: x, y: y)
        }
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel("Note \(number)")
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
            .accessibilityLabel("Close annotate mode")

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
            // Not disabled: a disabled button fades its text, and this one also shows the screen name.
            .allowsHitTesting(count > 0)
            .accessibilityLabel(count == 0 ? "\(session.screenTitle). Tap an element to add a note." : session.mode == .tray ? "Hide notes" : "Show \(count) notes")

            Button { session.captureThisScreen() } label: {
                Image(systemName: "camera.viewfinder")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Mono.text)
                    .frame(width: 32, height: 32)
                    .background(Mono.fill, in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Capture this screen")

            Button { session.openAttachments() } label: {
                Image(systemName: "paperclip")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Mono.text)
                    .frame(width: 32, height: 32)
                    .background(Mono.fill, in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Attach photos")
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { session.attachAnchor = $0 }

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
        .padding(.trailing, count > 0 ? 9 : 4)
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
            // Scrolls only when the card is taller than the space above the keyboard, such
            // as in landscape or at large text sizes, so the buttons below stay in reach.
            ScrollView {
                noteCardContent
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { noteContentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: noteScrollHeight)

            noteCardFooter
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { noteFooterHeight = $0 }
        }
        .buttonStyle(.plain)
        .padding(16)
        .frame(width: panelWidth)
        .background(Mono.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Mono.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            cardHeight = height
            // Wait for the real content height; the first pass uses an estimate.
            if openingCardHeight == 0, noteContentHeight > 0 { openingCardHeight = height }
        }
        .padding(.leading, panelLeading)
        .padding(.top, session.noteCardTop(height: cardHeight == 0 ? 190 : cardHeight, reservedHeight: reservedCardHeight))
        .onAppear { noteFocused = true }
        .onDisappear {
            cardHeight = 0
            openingCardHeight = 0
            noteContentHeight = 0
            noteFooterHeight = 0
        }
    }

    /// The scrolling part's height: all of it when the card fits, otherwise what is left
    /// once the card's padding, spacing and buttons are in.
    private var noteScrollHeight: CGFloat {
        let content = noteContentHeight == 0 ? 120 : noteContentHeight
        let footer = noteFooterHeight == 0 ? 44 : noteFooterHeight
        let room = session.noteCardMaxHeight - 32 - 14 - footer
        return max(min(content, room), 44)
    }

    private var noteCardContent: some View {
        let pending = session.pending
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                if let pending {
                    attachmentPreview(pending)
                } else if elementIsHidden, let preview = session.selectedElementPreview() {
                    // The element is behind the keyboard or this card, so show what was picked.
                    Image(uiImage: preview)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Mono.hairline, lineWidth: 1))
                        .overlay(alignment: .topLeading) {
                            NumberBadge(number: session.nextNumber, size: 20).offset(x: -6, y: -6)
                        }
                        .accessibilityHidden(true)
                } else {
                    NumberBadge(number: session.nextNumber, size: 26)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(pending.map { Annotation.title(kind: $0.kind, element: nil, screen: $0.screen, imageCount: $0.count) }
                        ?? session.selected?.shortName ?? "Unnamed element")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Mono.text)
                    Text(pending.map { Annotation.subtitle(kind: $0.kind, element: nil, screen: $0.screen) } ?? session.selected?.role ?? "Element")
                        .font(.caption)
                        .foregroundStyle(Mono.secondary)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
                if pending == nil {
                    if session.canStepDown {
                        sizeButton("Smaller") { session.stepDown() }
                    }
                    if session.canStepUp {
                        sizeButton("Larger") { session.stepUp() }
                    }
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
        }
    }

    private var noteCardFooter: some View {
        let pending = session.pending
        return VStack(alignment: .leading, spacing: 14) {
            if let error = session.noteError {
                Text(error)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Mono.text)
            }

            HStack {
                Button("Cancel") { session.cancelNote() }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Mono.secondary)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                Spacer()
                Button { session.saveNote() } label: {
                    Text(primaryNoteAction(sendsReport: pending?.sendsReport == true))
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
    }

    /// A suggested screenshot's note box sends the report, with the rest of the draft.
    private func primaryNoteAction(sendsReport: Bool) -> String {
        guard sendsReport else { return "Add note" }
        let count = session.annotations.count + 1
        return count == 1 ? "Send" : "Send \(count) notes"
    }

    /// The images a note is being written for: up to three, fanned like a small stack.
    /// Photos still loading show as placeholders until they arrive.
    private func attachmentPreview(_ pending: DebugSession.PendingAttachment) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return HStack(spacing: -14) {
            ForEach(0..<max(min(pending.count, 3), 1), id: \.self) { index in
                Group {
                    if pending.images.indices.contains(index) {
                        Image(uiImage: pending.images[index]).resizable().scaledToFill()
                    } else {
                        Color(white: 0.16).overlay {
                            if index == 0 { ProgressView().controlSize(.small).tint(Mono.text) }
                        }
                    }
                }
                .frame(width: 34, height: 56, alignment: .top)
                .clipShape(shape)
                .overlay(shape.strokeBorder(Color.white.opacity(0.4), lineWidth: 1))
                // A screen just captured is still flying in; it lands here.
                .opacity(index == 0 && session.captureFlight != nil ? 0 : 1)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                    if index == 0 { session.attachmentSlot = frame }
                }
                .zIndex(Double(3 - index))
            }
        }
        .overlay(alignment: .topLeading) {
            NumberBadge(number: session.nextNumber, size: 20).offset(x: -6, y: -6)
        }
        .accessibilityHidden(true)
    }

    /// True when the picked element sits under the keyboard or under the card itself, or
    /// the screen has rotated since it was picked and its frame no longer lines up.
    private var elementIsHidden: Bool {
        guard let frame = session.selected?.frame else { return false }
        guard session.screenReadIsCurrent else { return true }
        let visibleBottom = min(session.noteKeyboardTop, session.screenSize.height)
        let height = cardHeight == 0 ? 190 : cardHeight
        let card = CGRect(x: panelLeading, y: session.noteCardTop(height: height, reservedHeight: reservedCardHeight), width: panelWidth, height: height)
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return center.y >= visibleBottom || card.contains(center)
    }

    /// The height the card can reach while typing: three more lines than it opened with,
    /// the text field's limit.
    private var reservedCardHeight: CGFloat {
        let opening = openingCardHeight == 0 ? 190 : openingCardHeight
        return opening + 3 * UIFont.preferredFont(forTextStyle: .body).lineHeight
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
                if session.canPickDestination {
                    Rectangle().fill(Mono.hairline).frame(height: 1)
                    destinationRow
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
        .padding(.leading, panelLeading)
        .padding(.top, islandBottom + 8)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// Where Send goes, and the way to change it.
    private var destinationRow: some View {
        Button { session.openDestinations() } label: {
            HStack(spacing: 12) {
                Image(systemName: "paperplane")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Mono.text)
                    .frame(width: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Send to")
                        .font(.caption)
                        .foregroundStyle(Mono.secondary)
                    Text(session.destination.map { "\($0.title) · \(HubLink.agentName($0.agent))" } ?? "Choose a chat")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Mono.text)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Mono.secondary)
                    .frame(width: 44, height: 44)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(session.destination.map { "Send to \($0.title), \(HubLink.agentName($0.agent))" } ?? "Choose where to send")
        .accessibilityHint("Changes where reports go")
    }

    private func noteRow(number: Int, annotation: Annotation) -> some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail(for: annotation)
                .overlay(alignment: .topLeading) {
                    NumberBadge(number: number, size: 20).offset(x: -6, y: -6)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(annotation.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Mono.text)
                    .lineLimit(1)
                Text(annotation.note.isEmpty ? "No note" : annotation.note)
                    .font(.subheadline)
                    .foregroundStyle(annotation.note.isEmpty ? Mono.secondary : Mono.text)
                    .lineLimit(2)
                Text(annotation.subtitle)
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
        .onTapGesture { session.openViewer(annotation) }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(annotation.imageCount > 1 ? "Opens the \(annotation.imageCount) images and the note" : "Opens the screenshot and note")
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
                .overlay(alignment: .bottomTrailing) {
                    if annotation.imageCount > 1 {
                        // More images travel with this note.
                        Text("\(annotation.imageCount)")
                            .font(.caption2.weight(.bold).monospacedDigit())
                            .foregroundStyle(Mono.text)
                            .padding(.horizontal, 5)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(Mono.surface, in: Capsule(style: .continuous))
                            .padding(3)
                    }
                }
                .accessibilityHidden(true)
        } else {
            shape.fill(Mono.fill).frame(width: 52, height: 52)
        }
    }

    // MARK: - Toast

    /// At the top of the screen when idle, under the island while picking, listing notes
    /// or attaching, and under the top bar of the viewer, sent reports and the chat picker.
    private var toastTop: CGFloat {
        switch session.mode {
        case .idle, .noting: islandTop
        case .picking, .tray, .attaching: islandBottom + 8
        case .viewer, .reports, .destination: session.safeAreaTop + 56
        }
    }

    private func toastView(_ toast: DebugSession.Toast) -> some View {
        HStack(spacing: 8) {
            Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(Mono.text)
            Text(toast.message)
                .foregroundStyle(Mono.text)
                .multilineTextAlignment(.leading)
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(Mono.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Mono.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
        .padding(.horizontal, 16)
        .frame(width: width)
        .offset(y: toastTop)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - Idle

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
                    NumberBadge(number: count, size: 20).offset(x: 4, y: -4)
                }
            }
            .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
            .contentShape(Circle())
            // One gesture tells a tap, a press held still and a drag apart. Separate tap,
            // long press and drag gestures left the tap winning over a held press.
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        if press == nil {
                            press = ButtonPress(center: center, hold: Task {
                                try? await Task.sleep(for: .seconds(ButtonPress.holdDuration))
                                guard !Task.isCancelled, press?.isDragging == false else { return }
                                press?.held = true
                                session.openSentReports()
                            })
                        }
                        guard let current = press, !current.held else { return }
                        if !current.isDragging {
                            guard hypot(value.translation.width, value.translation.height) >= ButtonPress.dragDistance else { return }
                            current.hold.cancel()
                            press?.isDragging = true
                        }
                        // The button follows the finger itself, so the snap starts from where it's let go.
                        session.dragButton(to: CGPoint(
                            x: current.center.x + value.translation.width,
                            y: current.center.y + value.translation.height
                        ))
                    }
                    .onEnded { value in
                        guard let current = press else { return }
                        press = nil
                        current.hold.cancel()
                        if current.held { return }
                        guard current.isDragging else {
                            session.enterPicking()
                            return
                        }
                        // Snap toward where a flick was heading.
                        withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                            session.moveButton(to: CGPoint(
                                x: current.center.x + value.predictedEndTranslation.width,
                                y: current.center.y + value.predictedEndTranslation.height
                            ))
                        }
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(count == 0 ? "Report a UI issue" : "Report a UI issue, \(count) notes waiting")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { session.enterPicking() }
            .accessibilityAction(named: "Sent reports") { session.openSentReports() }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { session.setButtonFrame($0) }
            .onDisappear {
                // A press that opened the sent reports never sees the finger lift here.
                press?.hold.cancel()
                press = nil
                session.setButtonFrame(nil)
            }
            .position(center)
    }

    // MARK: - Suggested screenshot

    /// A screenshot just taken, docked at the side the floating button rests on, with a
    /// close button on its inner corner and a send button below it.
    private func suggestionCard(_ suggestion: DebugSession.Suggestion) -> some View {
        let cardWidth: CGFloat = 96
        let aspect = suggestion.image.size.height / max(suggestion.image.size.width, 1)
        let cardHeight = min(cardWidth * aspect, 220)
        let center = session.buttonCenter ?? CGPoint(x: width - 34, y: session.screenSize.height / 2)
        let onRight = center.x > width / 2
        let groupHeight = cardHeight + 12 + 44
        let buttonRadius = FloatingButtonPlacement.size / 2
        // Above the button when there is room, otherwise below it.
        let above = center.y - buttonRadius - 14 - groupHeight
        let top = above >= session.safeAreaTop + 8 ? above : center.y + buttonRadius + 14
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return VStack(spacing: 12) {
            Button { session.sendSuggestion() } label: {
                Image(uiImage: suggestion.image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: cardWidth, height: cardHeight, alignment: .top)
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(Color.white, lineWidth: 3))
                    .overlay(shape.strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5))
            }
            .accessibilityLabel("Screenshot just taken")
            .accessibilityHint("Write a note and send it")
            .overlay(alignment: onRight ? .topLeading : .topTrailing) {
                Button { session.dismissSuggestion() } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Mono.text)
                        .frame(width: 26, height: 26)
                        .background(Mono.surface, in: Circle())
                        .overlay(Circle().strokeBorder(Mono.hairline, lineWidth: 1))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Dismiss screenshot")
                .offset(x: onRight ? -18 : 18, y: -18)
            }

            Button { session.sendSuggestion() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.black)
                    .frame(width: 44, height: 44)
                    .background(Color.white, in: Circle())
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.15), lineWidth: 0.5))
            }
            .accessibilityLabel("Send screenshot")
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.3), radius: 12, y: 5)
        // The close button reaches past the card's corner, so take touches a little around it.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { session.setTouchableFrame($0.insetBy(dx: -24, dy: -24), for: "suggestion") }
        .onDisappear { session.setTouchableFrame(nil, for: "suggestion") }
        .padding(.leading, onRight ? width - 12 - cardWidth : 12)
        .padding(.top, top)
        .transition(.move(edge: onRight ? .trailing : .leading).combined(with: .opacity))
    }
}

/// A capture shown the way iOS shows a screenshot: a white flash, then the picture of the
/// screen shrinks from full size and lands in the note box's first image slot.
struct CaptureFlight: View {
    let image: UIImage
    let screenSize: CGSize
    /// Where it lands. It follows the slot as the note box rises with the keyboard.
    let slot: CGRect
    let landed: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flash = 0.9
    @State private var isLanding = false

    /// Close to the curve of an iPhone's screen corners.
    private let screenCornerRadius: CGFloat = 55

    var body: some View {
        let full = CGRect(origin: .zero, size: screenSize)
        let target = slot.isEmpty ? CGRect(x: 28, y: screenSize.height * 0.5, width: 34, height: 56) : slot
        let frame = isLanding ? target : full
        let radius = isLanding ? 8 : screenCornerRadius
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack(alignment: .topLeading) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: frame.width, height: frame.height, alignment: .top)
                .clipShape(shape)
                .overlay(shape.strokeBorder(Color.white.opacity(isLanding ? 0.4 : 0.9), lineWidth: isLanding ? 1 : 4))
                .shadow(color: .black.opacity(0.35), radius: isLanding ? 4 : 24, y: isLanding ? 2 : 10)
                .position(x: frame.midX, y: frame.midY)
                .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.5, bounce: 0.12), value: slot)

            Color.white
                .opacity(flash)
                .frame(width: screenSize.width, height: screenSize.height)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            withAnimation(.easeOut(duration: reduceMotion ? 0.1 : 0.3)) { flash = 0 }
            // Hold the full-size picture for a beat, as a screenshot does, then send it to the note box.
            withAnimation(
                reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.55, bounce: 0.12).delay(0.2),
                completionCriteria: .logicallyComplete
            ) {
                isLanding = true
            } completion: {
                landed()
            }
        }
    }
}

/// A touch on the floating button: a tap opens pick mode, a press held still opens the
/// sent reports, and moving it drags the button.
struct ButtonPress {
    static let holdDuration = 0.45
    static let dragDistance: CGFloat = 6

    /// The button's center when the finger came down.
    var center: CGPoint
    /// Opens the sent reports once the press has been held long enough.
    var hold: Task<Void, Never>
    var isDragging = false
    var held = false
}

/// A quick side-to-side shake, played each time `phase` steps up by one.
struct Shake: GeometryEffect {
    var phase: CGFloat
    var animatableData: CGFloat {
        get { phase }
        set { phase = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 7 * sin(phase * .pi * 6), y: 0))
    }
}

/// A white number in a circle: a note's place in the list.
struct NumberBadge: View {
    let number: Int
    let size: CGFloat

    var body: some View {
        Text("\(number)")
            .font(.caption.weight(.bold).monospacedDigit())
            .foregroundStyle(Color.black)
            .frame(minWidth: size, minHeight: size)
            .background(Color.white, in: Circle())
            .overlay(Circle().strokeBorder(Color.black, lineWidth: 1.5))
    }
}
#endif
