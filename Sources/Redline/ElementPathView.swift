#if REDLINE && canImport(UIKit)
import SwiftUI

/// The compact enclosing path expands into the subtree captured at the original touch.
struct ElementPathView: View {
    @Bindable var session: DebugSession
    @Binding var isExpanded: Bool
    let availableWidth: CGFloat

    var body: some View {
        if isExpanded, let hierarchy = session.hierarchy {
            ElementHierarchyView(
                hierarchy: hierarchy,
                selectedIndex: session.hierarchySelectionIndex,
                availableWidth: availableWidth,
                select: session.selectHierarchyElement
            )
            .disabled(!session.screenReadIsCurrent)
        } else {
            HStack(spacing: 4) {
                compactPath
                if session.hierarchy != nil {
                    Button("Expand hierarchy", systemImage: "chevron.down") { isExpanded = true }
                        .labelStyle(.iconOnly)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Mono.text)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .disabled(!session.screenReadIsCurrent)
                }
            }
        }
    }

    @ViewBuilder private var compactPath: some View {
        let levels = session.levels
        if levels.count > 1 {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(levels.indices.reversed(), id: \.self) { index in
                            HStack(spacing: 2) {
                                if index != levels.count - 1 {
                                    Image(systemName: "chevron.compact.right")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(Mono.secondary)
                                        .accessibilityHidden(true)
                                }
                                levelButton(levels[index], index: index)
                            }
                            .id(index)
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .onAppear { proxy.scrollTo(session.levelIndex, anchor: pathAnchor(session.levelIndex, of: levels)) }
                .onChange(of: session.levelIndex) { _, index in
                    proxy.scrollTo(index, anchor: pathAnchor(index, of: levels))
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Enclosing elements")
        } else {
            Text("Nothing larger to select")
                .font(.footnote)
                .foregroundStyle(Mono.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func pathAnchor(_ index: Int, of levels: [ElementSnapshot]) -> UnitPoint {
        if index == 0 { return .trailing }
        if index == levels.count - 1 { return .leading }
        return .center
    }

    private func levelButton(_ level: ElementSnapshot, index: Int) -> some View {
        let isSelected = index == session.levelIndex
        return Button {
            session.selectLevel(index)
        } label: {
            Text(level.shortName ?? level.role)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(isSelected ? Color.black : Mono.text)
                .lineLimit(1)
                .frame(maxWidth: 170)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(minHeight: 30)
                .background(isSelected ? Color.white : Mono.fill, in: Capsule(style: .continuous))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("\(level.fullName ?? level.role), \(level.role)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
#endif
