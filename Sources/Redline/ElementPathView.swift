#if REDLINE && canImport(UIKit)
import SwiftUI

/// Opens the nearest captured hierarchy for the selected element.
struct ElementPathView: View {
    @Bindable var session: DebugSession
    @Binding var isExpanded: Bool
    let availableWidth: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if isExpanded, let hierarchy = session.hierarchy {
            ElementHierarchyView(
                hierarchy: hierarchy,
                selectedIndex: session.hierarchySelectionIndex,
                availableWidth: availableWidth,
                select: session.selectHierarchyElement
            )
            .disabled(!session.screenReadIsCurrent)
            .transition(
                reduceMotion
                    ? .opacity.animation(.easeOut(duration: 0.15))
                    : .opacity.combined(with: .offset(y: -8))
            )
        } else if session.hierarchy != nil {
            Button {
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) {
                    isExpanded = true
                }
            } label: {
                HStack {
                    Text("View hierarchy")
                    Spacer()
                    Image(systemName: "chevron.down")
                        .accessibilityHidden(true)
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Mono.text)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .disabled(!session.screenReadIsCurrent)
            .transition(.opacity.animation(.easeOut(duration: 0.15)))
        }
    }
}
#endif
