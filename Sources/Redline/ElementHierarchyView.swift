#if REDLINE && canImport(UIKit)
import SwiftUI

/// One line per captured node, with branch lines following ownership rather than geometry.
struct ElementHierarchyView: View {
    let hierarchy: ElementHierarchy
    let selectedIndex: Int?
    let availableWidth: CGFloat
    let visibleBounds: CGRect
    /// The element one step out from the root, which the up row widens to; nil at the outermost.
    let owner: ElementSnapshot?
    let select: (Int) -> Void
    let widen: () -> Void
    let traversingChanged: (Bool) -> Void
    @State private var collapsed: Set<Int> = []
    @State private var rowFrames: [Int: CGRect] = [:]
    @State private var viewport: CGRect = .zero
    @ScaledMetric(relativeTo: .footnote) private var indentation: CGFloat = 18

    var body: some View {
        let rows = hierarchy.rows(collapsing: collapsed)
        let depth = rows.map { $0.branches.count }.max() ?? 0
        VStack(alignment: .leading, spacing: 0) {
            if let owner {
                Button(action: widen) {
                    HStack(spacing: 0) {
                        Image(systemName: "arrow.up")
                            .font(.caption.weight(.semibold))
                            .frame(width: 44, height: 44)
                        Text(owner.fullName ?? owner.role)
                            .font(.footnote)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                    }
                    .foregroundStyle(Mono.secondary)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("Show \(owner.fullName ?? owner.role)")
                .accessibilityHint("Widens the hierarchy by one enclosing element.")
                .accessibilityIdentifier("RedlineHierarchyUp")
            }
            tree(rows: rows, depth: depth)
        }
        .onDisappear { traversingChanged(false) }
    }

    private func tree(rows: [ElementHierarchy.Row], depth: Int) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    HStack(spacing: 0) {
                        Color.clear.frame(width: CGFloat(row.branches.count) * indentation)
                        if row.hasChildren {
                            Button {
                                if !collapsed.insert(row.id).inserted { collapsed.remove(row.id) }
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
                            .accessibilityIdentifier("RedlineHierarchyBranch\(row.id)")
                        } else {
                            Color.clear.frame(width: 44)
                        }
                        Button {
                            select(row.id)
                        } label: {
                            HStack(spacing: 8) {
                                Text(row.element.fullName ?? row.element.role)
                                    .font(.footnote.weight(row.id == selectedIndex ? .semibold : .regular))
                                    .foregroundStyle(row.id == selectedIndex ? Color.black : Mono.text)
                                // The role tells apart elements that share a name.
                                if row.element.fullName != nil {
                                    Text(row.element.role)
                                        .font(.caption)
                                        .foregroundStyle(
                                            row.id == selectedIndex ? Color.black.opacity(0.6) : Mono.secondary
                                        )
                                }
                            }
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                            .padding(.horizontal, 10)
                            .background(
                                row.id == selectedIndex ? Color.white : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .accessibilityLabel(
                            "\(row.element.fullName ?? row.element.role), \(row.element.role), level \(row.branches.count + 1)"
                        )
                        .accessibilityAddTraits(row.id == selectedIndex ? .isSelected : [])
                        .accessibilityValue(row.id == selectedIndex ? "Selected" : "")
                        .accessibilityHint("Press and drag across rows to select a component.")
                        .accessibilityIdentifier("RedlineHierarchyRow\(row.id)")
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
                                                // Up to the branch arrow, or to a leaf's name.
                                                x: x + (row.hasChildren ? indentation - 8 : indentation * 2),
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
                    .onGeometryChange(for: CGRect.self) {
                        $0.frame(in: .global)
                    } action: {
                        rowFrames[row.id] = $0
                    }
                    .transition(.identity)
                }
            }
            .frame(minWidth: max(availableWidth, CGFloat(depth) * indentation + 180), alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                HierarchyTraversalGesture { point in
                    traversingChanged(point != nil)
                    if let point,
                        let index = hierarchy.row(
                            at: point,
                            frames: rowFrames,
                            visibleBounds: visibleBounds.intersection(viewport),
                            collapsing: collapsed
                        )
                    {
                        select(index)
                    }
                }
            )
        }
        .accessibilityIdentifier("RedlineHierarchy")
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .global)
        } action: {
            viewport = $0
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Hierarchy of \(hierarchy.elements[hierarchy.root].fullName ?? "the selected element")")
    }
}
#endif
