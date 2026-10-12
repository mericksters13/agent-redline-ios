#if REDLINE && canImport(UIKit)
import SwiftUI

/// The layout lines a note can include: the component's own settings, then its parents'.
///
/// Nothing is included until its row is tapped.
struct LayoutInspectorView: View {
    let details: [LayoutInspection.Row]
    let selected: Set<Int>
    let toggle: (Int) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(details.enumerated()), id: \.offset) { index, row in
                let isSelected = selected.contains(index)
                Button {
                    toggle(index)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.body)
                            .foregroundStyle(isSelected ? Mono.text : Mono.secondary)
                            .accessibilityHidden(true)
                        if dynamicTypeSize.isAccessibilitySize {
                            VStack(alignment: .leading, spacing: 3) {
                                title(row.title)
                                value(row.value)
                            }
                        } else {
                            title(row.title)
                            value(row.value)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(row.title): \(row.value)")
                .accessibilityValue(isSelected ? "Included in note" : "Not included")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("RedlineLayoutRow\(index)")
            }
        }
    }

    private func title(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(Mono.secondary).fixedSize()
    }

    private func value(_ text: String) -> some View {
        Text(text).font(.footnote.weight(.medium)).monospacedDigit()
            .foregroundStyle(Mono.text).multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}
#endif
