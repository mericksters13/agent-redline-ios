#if REDLINE && canImport(UIKit)
import SwiftUI
import UIKit

/// Owns the annotation form's focus, constrained layout, and hierarchy interaction.
struct AnnotationFormView: View {
    @Bindable var session: DebugSession
    let panelWidth: CGFloat
    let panelLeading: CGFloat
    @Binding var isLayoutPreviewExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isNoteFocused: Bool
    @State private var isHierarchyExpanded = false
    @State private var isHierarchyTraversing = false
    @State private var hierarchyDragTop: CGFloat?
    @State private var noteCardFrame: CGRect = .zero
    @State private var noteScrollFrame: CGRect = .zero
    @ScaledMetric(relativeTo: .caption) private var noteBadgeSize: CGFloat = 26
    @State private var cardHeight: CGFloat = 0
    @State private var noteContentHeight: CGFloat = 0
    @State private var noteFooterHeight: CGFloat = 0
    private static let estimatedCardHeight: CGFloat = 190

    var body: some View {
        let pending = session.pending
        let space = noteCardSpace
        let height = min(
            cardHeight == 0 ? Self.estimatedCardHeight : cardHeight,
            space.bounds.upperBound - space.bounds.lowerBound
        )
        let top = space.anchorsBottom ? space.bounds.upperBound - height : space.bounds.lowerBound
        return VStack(alignment: .leading, spacing: 14) {
            // Keep the selected component visible while long content scrolls above the footer.
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
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .global)
            } action: {
                noteScrollFrame = $0
            }

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
            noteCardFrame = frame
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
        .onAppear { isNoteFocused = !session.showsLayoutPrototype }
        .onChange(of: isHierarchyExpanded) { _, expanded in
            isNoteFocused = !expanded && !session.showsLayoutPrototype
            if !expanded {
                isHierarchyTraversing = false
                hierarchyDragTop = nil
            }
        }
        .onDisappear {
            isHierarchyExpanded = false
            isHierarchyTraversing = false
            hierarchyDragTop = nil
            cardHeight = 0
            noteContentHeight = 0
            noteFooterHeight = 0
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
    private var noteCardMinimumHeight: CGFloat { 44 + (noteFooterHeight == 0 ? 44 : noteFooterHeight) + 14 + 32 }

    private var noteCardSpace: (bounds: ClosedRange<CGFloat>, anchorsBottom: Bool) {
        let space = session.noteCardSpace(
            height: cardHeight == 0 ? Self.estimatedCardHeight : cardHeight,
            minimumHeight: noteCardMinimumHeight,
            showsHierarchy: isHierarchyExpanded
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

    private func noteCardContent(pending: DebugSession.PendingAttachment?, isElementHidden: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                if let pending {
                    attachmentPreview(pending)
                } else if !session.showsLayoutPrototype, !isHierarchyExpanded, isElementHidden,
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
                if pending == nil, !session.isNotingDrawing, session.hierarchy != nil, !isHierarchyExpanded {
                    Button {
                        isHierarchyExpanded = true
                    } label: {
                        noteCardName(pending: pending, showsHierarchyIcon: true)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .disabled(!session.screenReadIsCurrent)
                    .accessibilityLabel("View hierarchy for \(noteCardTitle(pending: pending))")
                    .accessibilityIdentifier("RedlineShowHierarchy")
                } else {
                    noteCardName(pending: pending, showsHierarchyIcon: false)
                }
            }

            if pending == nil {
                if session.isNotingDrawing {
                    enclosedLine
                } else if isHierarchyExpanded, let hierarchy = session.hierarchy {
                    ElementHierarchyView(
                        hierarchy: hierarchy,
                        selectedIndex: session.hierarchySelectionIndex,
                        availableWidth: panelWidth - 32,
                        visibleBounds: noteScrollFrame,
                        select: session.selectHierarchyElement,
                        traversingChanged: { traversing in
                            guard traversing != isHierarchyTraversing else { return }
                            // Keep the rows under the finger while the selected app frame changes.
                            hierarchyDragTop = traversing ? noteCardFrame.minY : nil
                            isHierarchyTraversing = traversing
                        }
                    )
                    .disabled(!session.screenReadIsCurrent)
                    .transition(.identity)
                }
            }

            if session.showsLayoutPrototype, pending == nil, !session.isNotingDrawing {
                LayoutInspectorView(
                    report: session.selectedLayout,
                    image: session.selectedLayoutPreview(),
                    selected: session.selectedPadding,
                    toggle: session.togglePadding,
                    isPreviewExpanded: $isLayoutPreviewExpanded
                )
            }

            if !isHierarchyExpanded {
                TextField("What's wrong?", text: $session.noteText, axis: .vertical)
                    .font(.body)
                    .foregroundStyle(Mono.text)
                    .tint(Color.white)
                    .lineLimit(2...5)
                    .focused($isNoteFocused)
                    .accessibilityIdentifier("RedlineNoteText")
                    .padding(12)
                    .background(Mono.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .transition(.identity)
            }
        }
    }

    private func noteCardName(pending: DebugSession.PendingAttachment?, showsHierarchyIcon: Bool) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(isHierarchyExpanded ? "Hierarchy" : noteCardTitle(pending: pending))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Mono.text)
                if !isHierarchyExpanded {
                    Text(noteCardSubtitle(pending: pending))
                        .font(.caption)
                        .foregroundStyle(Mono.secondary)
                }
            }
            .lineLimit(1)
            if showsHierarchyIcon {
                Image(systemName: "square.3.layers.3d")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Mono.secondary)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 0)
        }
    }

    private func noteCardFooter(pending: DebugSession.PendingAttachment?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if isHierarchyExpanded {
                HStack {
                    Spacer()
                    Button("Done") { isHierarchyExpanded = false }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .frame(minHeight: 38)
                        .background(Color.white, in: Capsule(style: .continuous))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
            } else {
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
