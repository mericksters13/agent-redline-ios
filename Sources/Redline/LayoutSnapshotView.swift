#if REDLINE && canImport(UIKit)
import SwiftUI
import UIKit

/// A captured component with physical-edge padding controls, independent of its display scale.
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
                    ForEach(LayoutInspection.Edge.allCases, id: \.self) { paddingButton($0) }
                }
            } else {
                paddingButton(.top)
                HStack(spacing: 8) {
                    paddingButton(.left)
                    preview.frame(height: 92)
                    paddingButton(.right)
                }
                paddingButton(.bottom)
            }
            let box = geometry.frame ?? geometry.bounds
            Text("\(geometry.frame == nil ? "Captured size" : "Frame") · \(LayoutInspection.number(box.width)) × \(LayoutInspection.number(box.height)) pt")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(Mono.secondary)
        }
    }

    private func paddingButton(_ edge: LayoutInspection.Edge) -> some View {
        let value = geometry.paddingLabel(on: edge)
        let isSelected = selected.contains(edge)
        return Button { toggle(edge) } label: {
            VStack(spacing: 2) {
                Text(edge.title).font(.caption)
                Text(value ?? "—").font(.caption.weight(.semibold)).monospacedDigit()
            }
            .foregroundStyle(isSelected ? Color.black : Mono.text)
            .frame(minWidth: 56, minHeight: 44)
            .padding(.horizontal, 6)
            .background(isSelected ? Mono.text : Mono.fill, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? Mono.text : Mono.hairline, lineWidth: 1))
        }
        .disabled(value == nil)
        .accessibilityLabel("\(edge.title) padding, \(value ?? "measurement unavailable")")
        .accessibilityValue(isSelected ? "Included in note" : "Not included")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("RedlinePadding\(edge.title)")
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
                    if let frame = geometry.frame {
                        context.stroke(Path(local(frame)), with: .color(.black), style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                        context.stroke(Path(local(frame)), with: .color(.white), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
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
