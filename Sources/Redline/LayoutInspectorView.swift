#if REDLINE && canImport(UIKit)
import SwiftUI
import UIKit

struct LayoutInspectorView: View {
    let report: LayoutInspection.Report
    let image: UIImage?
    let selected: Set<LayoutInspection.Edge>
    let toggle: (LayoutInspection.Edge) -> Void
    @State private var showsDetails = false
    @State private var showsParent = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let geometry = report.geometry, let image {
                LayoutSnapshotView(geometry: geometry, image: image, selected: selected, toggle: toggle)
                Text(geometry.padding.isEmpty ? "Padding measurements unavailable."
                     : geometry.padding.contains(where: \.isSystemDefault)
                        ? "System default padding · Showing measured spacing"
                        : "Tap padding to include it in the note.")
                    .font(.caption)
                    .foregroundStyle(Mono.secondary)
                let context = report.context(for: selected)
                if !context.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Included in note").font(.caption).foregroundStyle(Mono.secondary)
                        Text(context).font(.caption).foregroundStyle(Mono.text)
                            .accessibilityIdentifier("RedlineLayoutContext")
                    }
                }
            } else if report.geometry != nil {
                Text("Component snapshot unavailable.").font(.subheadline).foregroundStyle(Mono.secondary)
            }
            if !report.rows.isEmpty {
                DisclosureGroup(isExpanded: $showsDetails) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(report.rows.enumerated()), id: \.offset) { _, row in setting(row) }
                        if !report.ancestors.isEmpty {
                            DisclosureGroup(isExpanded: $showsParent) {
                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(Array(report.ancestors.enumerated()), id: \.offset) { _, row in setting(row) }
                                }
                                .padding(.top, 8)
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel(report.ancestors.map { "\($0.title): \($0.value)" }.joined(separator: "\n"))
                                .accessibilityIdentifier("RedlineParentLayout")
                            } label: { disclosureTitle("Parent layout") }
                        }
                    }
                    .padding(.top, 8)
                } label: { disclosureTitle("Layout details") }
                .tint(Mono.secondary)
            }
            Text(report.message)
                .font(.caption)
                .foregroundStyle(Mono.secondary)
                .accessibilityLabel(report.summary)
                .accessibilityIdentifier("RedlineLayoutInspection")
        }
    }

    private func disclosureTitle(_ text: String) -> some View {
        Text(text).font(.subheadline).foregroundStyle(Mono.text).frame(minHeight: 44)
    }

    @ViewBuilder
    private func setting(_ row: LayoutInspection.Row) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 3) { title(row.title); value(row.value) }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                title(row.title).frame(width: 108, alignment: .leading)
                value(row.value).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func title(_ text: String) -> some View {
        Text(text).font(.subheadline).foregroundStyle(Mono.secondary)
    }

    private func value(_ text: String) -> some View {
        Text(text).font(.subheadline.weight(.medium)).monospacedDigit()
            .foregroundStyle(Mono.text).fixedSize(horizontal: false, vertical: true)
    }
}
#endif
