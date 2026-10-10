#if REDLINE && canImport(UIKit)
import SwiftUI

/// One line per captured node, with branch lines following ownership rather than geometry.
struct ElementHierarchyView: View {
    let hierarchy: ElementHierarchy
    let selectedIndex: Int?
    let availableWidth: CGFloat
    let select: (Int) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var collapsed: Set<Int> = []
    @ScaledMetric(relativeTo: .footnote) private var indentation: CGFloat = 18

    var body: some View {
        let rows = hierarchy.rows(collapsing: collapsed)
        let depth = rows.map { $0.branches.count }.max() ?? 0
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    HStack(spacing: 0) {
                        Color.clear.frame(width: CGFloat(row.branches.count) * indentation)
                        if row.hasChildren {
                            Button {
                                withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) {
                                    if !collapsed.insert(row.id).inserted { collapsed.remove(row.id) }
                                }
                            } label: {
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Mono.secondary)
                                    .rotationEffect(.degrees(collapsed.contains(row.id) ? 0 : 90))
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel(
                                "\(collapsed.contains(row.id) ? "Expand" : "Collapse") \(row.element.fullName ?? row.element.role)"
                            )
                        } else {
                            Color.clear.frame(width: 44)
                        }
                        Button {
                            select(row.id)
                        } label: {
                            Text(row.element.fullName ?? row.element.role)
                                .font(.footnote.weight(row.id == selectedIndex ? .semibold : .regular))
                                .foregroundStyle(row.id == selectedIndex ? Color.black : Mono.text)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .padding(.horizontal, 10)
                                .background(
                                    row.id == selectedIndex ? Color.white : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                )
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel(
                            "\(row.element.fullName ?? row.element.role), \(row.element.role), level \(row.branches.count + 1)"
                        )
                        .accessibilityAddTraits(row.id == selectedIndex ? .isSelected : [])
                    }
                    .overlay(alignment: .leading) {
                        GeometryReader { geometry in
                            Path { path in
                                for (column, continues) in row.branches.enumerated() {
                                    let x = 22 + CGFloat(column) * indentation
                                    let last = column == row.branches.count - 1
                                    guard last || continues else { continue }
                                    path.move(to: CGPoint(x: x, y: 0))
                                    path.addLine(
                                        to: CGPoint(
                                            x: x,
                                            y: last && !continues ? geometry.size.height / 2 : geometry.size.height
                                        )
                                    )
                                    if last {
                                        path.move(to: CGPoint(x: x, y: geometry.size.height / 2))
                                        path.addLine(
                                            to: CGPoint(
                                                x: x + indentation - (row.hasChildren ? 8 : 0),
                                                y: geometry.size.height / 2
                                            )
                                        )
                                    }
                                }
                            }
                            .stroke(Mono.secondary, lineWidth: 1)
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                    .transition(
                        reduceMotion
                            ? .opacity.animation(.easeOut(duration: 0.15))
                            : .opacity.combined(with: .offset(y: -8))
                    )
                }
            }
            .frame(minWidth: max(availableWidth, CGFloat(depth) * indentation + 180), alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Hierarchy of \(hierarchy.elements[hierarchy.root].fullName ?? "the selected element")")
    }
}
#endif
