#if REDLINE && canImport(UIKit)
import SwiftUI
import UIKit

/// Owns the annotation form's focus, constrained layout, and the panel open under the note.
struct AnnotationFormView: View {
    /// What can open under the note field: one at a time, and never with the keyboard.
    private enum Panel {
        case padding, layout, hierarchy
    }

    @Bindable var session: DebugSession
    let panelWidth: CGFloat
    let panelLeading: CGFloat
    /// The card's frame on screen, which the overlay keeps its measurement tag clear of.
    @Binding var cardFrame: CGRect
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isNoteFocused: Bool
    @State private var panel: Panel?
    @State private var isHierarchyTraversing = false
    @State private var hierarchyDragTop: CGFloat?
    @State private var panelFrame: CGRect = .zero
    @ScaledMetric(relativeTo: .caption) private var noteBadgeSize: CGFloat = 26
    @State private var cardHeight: CGFloat = 0
    @State private var noteContentHeight: CGFloat = 0
    @State private var noteFooterHeight: CGFloat = 0
    @State private var noteTopHeight: CGFloat = 0
    @State private var panelContentHeight: CGFloat = 0
    private static let estimatedCardHeight: CGFloat = 190
    private static let minimumPanelHeight: CGFloat = 88

    var body: some View {
        let pending = session.pending
        let space = noteCardSpace
        let height = min(
            cardHeight == 0 ? Self.estimatedCardHeight : cardHeight,
            space.bounds.upperBound - space.bounds.lowerBound
        )
        let top = space.anchorsBottom ? space.bounds.upperBound - height : space.bounds.lowerBound
        return VStack(alignment: .leading, spacing: 14) {
            // Scrolls only when the name and note alone are taller than the space, such as in
            // landscape or at large text sizes, so the buttons below stay in reach.
            ScrollView {
                noteCardContent(pending: pending, isElementHidden: isElementHidden(cardTop: top, cardHeight: height))
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.height
                    } action: {
                        noteContentHeight = $0
                    }
            }
            .scrollBounceBehavior(.basedOnSize)
            .accessibilityIdentifier("RedlineNoteScroll")
            .animation(reduceMotion ? nil : .smooth(duration: 0.3)) { content in
                content.frame(height: noteScrollHeight)
            }
            // Clamp immediately when the keyboard reduces the slot, even during a height animation.
            .frame(maxHeight: noteScrollRoom)
            .fixedSize(horizontal: false, vertical: true)
            .clipped()

            noteCardFooter(pending: pending)
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                } action: {
                    noteFooterHeight = $0
                }
        }
        .buttonStyle(.plain)
        .padding(16)
        .frame(width: panelWidth)
        .background(Mono.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Mono.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("RedlineNoteCard")
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .global)
        } action: { frame in
            cardFrame = frame
            cardHeight = frame.height
        }
        // Align the actual card inside the free slot. This keeps its edge outside the target
        // throughout an animated resize, without depending on the previous measured height.
        .frame(
            height: space.bounds.upperBound - space.bounds.lowerBound,
            alignment: space.anchorsBottom ? .bottom : .top
        )
        .padding(.leading, panelLeading)
        .padding(.top, space.bounds.lowerBound)
        .onAppear { isNoteFocused = true }
        // A panel takes the keyboard's room, and closing it goes back to writing.
        .onChange(of: panel) { _, panel in
            isNoteFocused = panel == nil
            if panel != .hierarchy {
                isHierarchyTraversing = false
                hierarchyDragTop = nil
            }
        }
        .onChange(of: isNoteFocused) { _, focused in
            if focused { panel = nil }
        }
        .onDisappear {
            panel = nil
            isHierarchyTraversing = false
            hierarchyDragTop = nil
            cardFrame = .zero
            cardHeight = 0
            noteContentHeight = 0
            noteFooterHeight = 0
            noteTopHeight = 0
            panelContentHeight = 0
        }
    }

    private func noteCardTitle(pending: DebugSession.PendingAttachment?) -> String {
        if let pending {
            return Annotation.title(
                kind: pending.kind,
                element: nil,
                screen: pending.screen,
                snapshotCount: pending.count
            )
        }
        if session.isNotingDrawing {
            return Annotation.title(
                kind: .drawing,
                element: nil,
                screen: session.screen,
                snapshotCount: 1,
                encloses: session.encloses,
                enclosedCount: session.encloses.count
            )
        }
        return session.selected?.shortName ?? "Unnamed element"
    }

    private func noteCardSubtitle(pending: DebugSession.PendingAttachment?) -> String {
        if let pending { return Annotation.subtitle(kind: pending.kind, element: nil, screen: pending.screen) }
        if session.isNotingDrawing { return Annotation.subtitle(kind: .drawing, element: nil, screen: session.screen) }
        return session.selected?.role ?? "Element"
    }

    /// What the drawing encloses, where an element's card shows its path: the agent finds the code
    /// by these names.
    private var enclosedLine: some View {
        let shown = session.encloses.prefix(3).compactMap(\.shortName)
        let more = session.encloses.count - shown.count
        let names = shown.joined(separator: ", ") + (more > 0 ? " and \(more) more" : "")
        return Text(shown.isEmpty ? "Nothing named inside the drawing" : "Encloses \(names)")
            .font(.footnote)
            .foregroundStyle(Mono.secondary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Enough room for a scrollable content row plus the fixed footer, spacing and padding.
    ///
    /// With a panel open, the name, the note and a short panel must fit, so a side that would
    /// squeeze them out is not chosen, such as the strip left under a hierarchy's large owner.
    private var noteCardMinimumHeight: CGFloat {
        let content = panel == nil ? 44 : noteTopHeight + 14 + 1 + Self.minimumPanelHeight
        return content + (noteFooterHeight == 0 ? 44 : noteFooterHeight) + 14 + 32
    }

    private var noteCardSpace: (bounds: ClosedRange<CGFloat>, anchorsBottom: Bool) {
        let space = session.noteCardSpace(
            height: cardHeight == 0 ? Self.estimatedCardHeight : cardHeight,
            minimumHeight: noteCardMinimumHeight,
            showsHierarchy: panel == .hierarchy
        )
        if let top = hierarchyDragTop, space.bounds.contains(top),
            space.bounds.upperBound - top >= noteCardMinimumHeight
        {
            return (top...space.bounds.upperBound, false)
        }
        return space
    }

    /// Only the upper content scrolls; Cancel and Add note stay in reach.
    private var noteScrollHeight: CGFloat {
        let content = noteContentHeight == 0 ? 120 : noteContentHeight
        return min(content, noteScrollRoom)
    }

    private var noteScrollRoom: CGFloat {
        let footer = noteFooterHeight == 0 ? 44 : noteFooterHeight
        let bounds = noteCardSpace.bounds
        return max(bounds.upperBound - bounds.lowerBound - 32 - 14 - footer, 0)
    }

    /// What is left for the open panel once the name and the note have their room.
    private var panelRoom: CGFloat {
        max(noteScrollRoom - noteTopHeight - 14 - 1, Self.minimumPanelHeight)
    }

    private func noteCardContent(pending: DebugSession.PendingAttachment?, isElementHidden: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // The name and the note keep their place whatever opens below them.
            VStack(alignment: .leading, spacing: 14) {
                header(pending: pending, isElementHidden: isElementHidden)
                if pending == nil, session.isNotingDrawing {
                    enclosedLine
                }
                TextField("What's wrong?", text: $session.noteText, axis: .vertical)
                    .font(.body)
                    .foregroundStyle(Mono.text)
                    .tint(Color.white)
                    .lineLimit(2...5)
                    .focused($isNoteFocused)
                    .accessibilityIdentifier("RedlineNoteText")
                    .padding(12)
                    .background(Mono.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .onGeometryChange(for: CGFloat.self) {
                $0.size.height
            } action: {
                noteTopHeight = $0
            }

            if let panel, pending == nil {
                VStack(alignment: .leading, spacing: 0) {
                    Rectangle().fill(Mono.hairline).frame(height: 1)
                    // A long panel scrolls by itself, under the name and the note.
                    ScrollView {
                        panelContent(panel)
                            .padding(.top, 6)
                            .onGeometryChange(for: CGFloat.self) {
                                $0.size.height
                            } action: {
                                panelContentHeight = $0
                            }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(
                        height: min(
                            panelContentHeight == 0 ? Self.minimumPanelHeight : panelContentHeight,
                            panelRoom
                        )
                    )
                    .accessibilityIdentifier("RedlinePanelScroll")
                    .onGeometryChange(for: CGRect.self) {
                        $0.frame(in: .global)
                    } action: {
                        panelFrame = $0
                    }
                }
                .transition(.identity)
            }
        }
    }

    private func header(pending: DebugSession.PendingAttachment?, isElementHidden: Bool) -> some View {
        HStack(spacing: 12) {
            if let pending {
                attachmentPreview(pending)
            } else if panel == nil || panel == .layout, isElementHidden,
                let preview = session.selectedElementPreview()
            {
                // The element is behind the keyboard or this card, so show what was picked.
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(
                            Mono.hairline,
                            lineWidth: 1
                        )
                    )
                    .overlay(alignment: .topLeading) {
                        NumberBadge(number: session.nextNumber, size: 20).offset(x: -6, y: -6)
                    }
                    .accessibilityHidden(true)
            } else {
                NumberBadge(number: session.nextNumber, size: noteBadgeSize)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(noteCardTitle(pending: pending))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Mono.text)
                subtitle(pending: pending)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            if pending == nil, !session.isNotingDrawing {
                headerButtons
            }
        }
        .frame(minHeight: 44)
    }

    /// The role, with the measured size beside it when the element's layout was read.
    @ViewBuilder
    private func subtitle(pending: DebugSession.PendingAttachment?) -> some View {
        let role = noteCardSubtitle(pending: pending)
        if pending == nil, let geometry = session.measuredGeometry {
            // VoiceOver also reads the settings behind the size.
            Text("\(role) · \(geometry.size)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(Mono.secondary)
                .accessibilityLabel("\(role), \(geometry.size)\n\(session.selectedLayout.summary)")
                .accessibilityIdentifier("RedlineLayoutInspection")
        } else {
            Text(role)
                .font(.caption)
                .foregroundStyle(Mono.secondary)
        }
    }

    /// Padding and Layout show only for what was measured, so an element that wasn't looks as it
    /// did before layout inspection.
    private var headerButtons: some View {
        let layout = session.selectedLayout
        let geometry = session.measuredGeometry
        return HStack(spacing: 0) {
            if let geometry, !geometry.padding.isEmpty, session.selectedLayoutPreview() != nil {
                headerButton(
                    .padding,
                    symbol: "square.dashed.inset.filled",
                    label: "Padding",
                    included: LayoutInspection.phrase(
                        for: layout.included(edges: session.selectedPadding, details: [])
                    ),
                    identifier: "RedlineShowPadding"
                )
            }
            if geometry != nil, !layout.details.isEmpty {
                headerButton(
                    .layout,
                    symbol: "ruler",
                    label: "Layout",
                    included: LayoutInspection.phrase(
                        for: layout.included(edges: [], details: session.selectedDetails)
                    ),
                    identifier: "RedlineShowLayout"
                )
            }
            if session.hierarchy != nil {
                headerButton(
                    .hierarchy,
                    symbol: "square.3.layers.3d",
                    label: "Hierarchy",
                    included: nil,
                    identifier: "RedlineShowHierarchy"
                )
                .disabled(!session.screenReadIsCurrent)
            }
        }
        // The circles sit inside their touch areas; line the last one up with the card's edge.
        .padding(.trailing, -6)
    }

    /// A round control that opens its panel under the note, white while that panel is open.
    ///
    /// A red dot says something in a closed panel is included in the note.
    private func headerButton(
        _ kind: Panel,
        symbol: String,
        label: String,
        included: String?,
        identifier: String
    ) -> some View {
        let isOpen = panel == kind
        return Button {
            panel = isOpen ? nil : kind
        } label: {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isOpen ? Color.black : Mono.text)
                .frame(width: 32, height: 32)
                .background(isOpen ? Color.white : Mono.fill, in: Circle())
                .overlay(alignment: .topTrailing) {
                    if included != nil, !isOpen {
                        Circle()
                            .fill(Color(uiColor: .systemRed))
                            .frame(width: 9, height: 9)
                            .overlay(Circle().stroke(Mono.surface, lineWidth: 2))
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
        .accessibilityValue(included.map { "\($0) included" } ?? "")
        .accessibilityAddTraits(isOpen ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private func panelContent(_ panel: Panel) -> some View {
        switch panel {
        case .padding:
            if let geometry = session.measuredGeometry, let image = session.selectedLayoutPreview() {
                VStack(alignment: .leading, spacing: 8) {
                    LayoutSnapshotView(
                        geometry: geometry,
                        image: image,
                        selected: session.selectedPadding,
                        toggle: session.togglePadding
                    )
                    includedLine(hint: "Tap a side to include its padding in the note.")
                }
            }
        case .layout:
            VStack(alignment: .leading, spacing: 8) {
                LayoutInspectorView(
                    details: session.selectedLayout.details,
                    selected: session.selectedDetails,
                    toggle: session.toggleDetail
                )
                includedLine(hint: "Tap a row to include it in the note.")
            }
        case .hierarchy:
            if let hierarchy = session.hierarchy {
                ElementHierarchyView(
                    hierarchy: hierarchy,
                    selectedIndex: session.hierarchySelectionIndex,
                    availableWidth: panelWidth - 32,
                    visibleBounds: panelFrame,
                    owner: session.hierarchyOwner,
                    select: session.selectHierarchyElement,
                    widen: session.widenHierarchy,
                    traversingChanged: { traversing in
                        guard traversing != isHierarchyTraversing else { return }
                        // Keep the rows under the finger while the selected app frame changes.
                        hierarchyDragTop = traversing ? cardFrame.minY : nil
                        isHierarchyTraversing = traversing
                    }
                )
                .disabled(!session.screenReadIsCurrent)
            }
        }
    }

    /// What the note will include, in a few words, or how to include something.
    private func includedLine(hint: String) -> some View {
        let included = session.includedLayout
        return Text(LayoutInspection.phrase(for: included).map { "Included in the note: \($0)." } ?? hint)
            .font(.caption)
            .foregroundStyle(Mono.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(
                included.isEmpty
                    ? hint
                    : "Included in the note. " + included.map { "\($0.title): \($0.value)" }.joined(separator: ". ")
            )
            .accessibilityIdentifier("RedlineLayoutContext")
    }

    private func noteCardFooter(pending: DebugSession.PendingAttachment?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
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
                Button {
                    session.saveNote()
                } label: {
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
    ///
    /// Photos still loading show as placeholders until they arrive.
    private func attachmentPreview(_ pending: DebugSession.PendingAttachment) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return HStack(spacing: -14) {
            ForEach(0..<max(min(pending.count, 3), 1), id: \.self) { index in
                Group {
                    if pending.previews.indices.contains(index) {
                        Image(uiImage: pending.previews[index]).resizable().scaledToFill()
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
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .global)
                } action: { frame in
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

    /// True when the picked element sits under the keyboard or under the card itself, or the screen
    /// has rotated since it was picked and its frame no longer lines up.
    private func isElementHidden(cardTop: CGFloat, cardHeight height: CGFloat) -> Bool {
        guard let frame = session.noteFrame else { return false }
        guard session.screenReadIsCurrent else { return true }
        let visibleBottom = min(session.noteKeyboardTop, session.screenSize.height)
        let card = CGRect(x: panelLeading, y: cardTop, width: panelWidth, height: height)
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return center.y >= visibleBottom || card.contains(center)
    }

}
#endif
