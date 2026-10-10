#if REDLINE && canImport(UIKit)
import SwiftUI

/// Opens the nearest captured hierarchy for the selected element.
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
            .transition(.identity)
        } else if session.hierarchy != nil {
            Button {
                isExpanded = true
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
            .transition(.identity)
        }
    }
}
#endif
