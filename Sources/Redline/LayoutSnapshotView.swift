#if REDLINE && canImport(UIKit)
import SwiftUI
import UIKit

/// A captured component with tappable padding measurements, independent of its display scale.
struct LayoutSnapshotView: View {
    let geometry: LayoutInspection.Geometry
    let image: UIImage
    let selected: Set<LayoutInspection.Edge>
    let toggle: (LayoutInspection.Edge) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 8) {
            if dynamicTypeSize.isAccessibilitySize {
                preview.frame(height: 100)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(LayoutInspection.Edge.allCases, id: \.self) { paddingConstraint($0) }
                }
            } else {
                paddingConstraint(.top)
                GeometryReader { proxy in
                    let box = geometry.bounds
                    let scale = min(max(proxy.size.width - 138, 1) / max(box.width, 1),
                                    86 / max(box.height, 1), 3)
                    HStack(spacing: 4) {
                        paddingConstraint(.left).frame(width: 62)
                        preview.frame(width: box.width * scale + 6, height: box.height * scale + 6)
                        paddingConstraint(.right).frame(width: 62)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(height: 92)
                paddingConstraint(.bottom)
            }
            let box = geometry.frame ?? geometry.bounds
            Text("\(geometry.frame == nil ? "Captured size" : "Frame") · \(LayoutInspection.number(box.width)) × \(LayoutInspection.number(box.height)) pt")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(Mono.secondary)
        }
    }

    private func paddingConstraint(_ edge: LayoutInspection.Edge) -> some View {
        let value = geometry.paddingLabel(on: edge)
        let isSelected = selected.contains(edge)
        let isVertical = edge == .top || edge == .bottom
        let color = value == nil ? Mono.secondary : Color(uiColor: .systemRed)
        return Button { toggle(edge) } label: {
            Group {
                if isVertical {
                    HStack(spacing: 8) {
                        measurementLine(vertical: true, selected: isSelected, color: color)
                            .frame(width: 16, height: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(edge.title).font(.caption)
                            measurement(value, selected: isSelected)
                        }
                    }
                } else {
                    VStack(spacing: 2) {
                        Text(edge.title).font(.caption)
                        ZStack {
                            measurementLine(vertical: false, selected: isSelected, color: color)
                            measurement(value, selected: isSelected)
                                .padding(.horizontal, 4)
                                .background(Mono.surface)
                        }
                        .frame(height: 24)
                    }
                }
            }
            .foregroundStyle(color)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(value == nil)
        .accessibilityLabel("\(edge.title) padding, \(value ?? "measurement unavailable")")
        .accessibilityValue(isSelected ? "Included in note" : "Not included")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("RedlinePadding\(edge.title)")
    }

    private func measurement(_ value: String?, selected: Bool) -> some View {
        Text(value ?? "—")
            .font(.caption.weight(selected ? .bold : .semibold))
            .monospacedDigit()
            .foregroundStyle(selected ? Mono.text : Color(uiColor: .systemRed))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func measurementLine(vertical: Bool, selected: Bool, color: Color) -> some View {
        Canvas { context, size in
            let start = vertical ? CGPoint(x: size.width / 2, y: 2) : CGPoint(x: 2, y: size.height / 2)
            let end = vertical ? CGPoint(x: size.width / 2, y: size.height - 2) : CGPoint(x: size.width - 2, y: size.height / 2)
            context.stroke(dimension(from: start, to: end, vertical: vertical, tick: 6),
                           with: .color(color), lineWidth: selected ? 3 : 1.5)
        }
        .accessibilityHidden(true)
    }

    /// End ticks distinguish the measured span from the component and frame outlines.
    private func dimension(from start: CGPoint, to end: CGPoint, vertical: Bool, tick: CGFloat) -> Path {
        Path { path in
            path.move(to: start)
            path.addLine(to: end)
            for point in [start, end] {
                path.move(to: CGPoint(x: point.x - (vertical ? tick : 0), y: point.y - (vertical ? 0 : tick)))
                path.addLine(to: CGPoint(x: point.x + (vertical ? tick : 0), y: point.y + (vertical ? 0 : tick)))
            }
        }
    }

    private var preview: some View {
        GeometryReader { proxy in
            let box = geometry.bounds
            let scale = min((proxy.size.width - 6) / max(box.width, 1), (proxy.size.height - 6) / max(box.height, 1), 3)
            let size = CGSize(width: box.width * scale, height: box.height * scale)
            ZStack {
                Image(uiImage: image).resizable().frame(width: size.width, height: size.height)
                Canvas { context, _ in
                    func local(_ rect: CGRect) -> CGRect {
                        CGRect(x: (rect.minX - box.minX) * scale, y: (rect.minY - box.minY) * scale,
                               width: rect.width * scale, height: rect.height * scale)
                    }
                    for region in geometry.padding {
                        var band = Path(local(region.outer))
                        band.addRect(local(region.inner))
                        context.fill(band, with: .color(.gray.opacity(0.3)), style: FillStyle(eoFill: true))
                    }
                    for edge in selected {
                        for region in geometry.padding {
                            let inner = region.inner
                            let outer = region.outer
                            let band: CGRect
                            switch edge {
                            case .top: band = CGRect(x: outer.minX, y: outer.minY, width: outer.width, height: max(inner.minY - outer.minY, 0))
                            case .right: band = CGRect(x: inner.maxX, y: inner.minY, width: max(outer.maxX - inner.maxX, 0), height: inner.height)
                            case .bottom: band = CGRect(x: outer.minX, y: inner.maxY, width: outer.width, height: max(outer.maxY - inner.maxY, 0))
                            case .left: band = CGRect(x: outer.minX, y: inner.minY, width: max(inner.minX - outer.minX, 0), height: inner.height)
                            }
                            context.fill(Path(local(band)), with: .color(.red.opacity(0.4)))
                        }
                    }
                    context.stroke(Path(local(geometry.content)), with: .color(.red), lineWidth: 1.5)
                }
                .frame(width: size.width, height: size.height)
            }
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .background(Mono.fill, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("Captured component")
        .accessibilityIdentifier("RedlineComponentPreview")
    }
}
#endif
