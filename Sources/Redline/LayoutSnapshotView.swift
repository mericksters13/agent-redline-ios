#if REDLINE && canImport(UIKit)
import SwiftUI
import UIKit

/// A captured component with one control per padding edge, independent of its display scale.
///
/// The crop is scaled up so each edge gets a full touch target, which the edges of the element on
/// screen are too small and too close together for.
struct LayoutSnapshotView: View {
    let geometry: LayoutInspection.Geometry
    let image: UIImage
    let selected: Set<LayoutInspection.Edge>
    let toggle: (LayoutInspection.Edge) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 8) {
                preview.frame(height: 100)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(LayoutInspection.Edge.allCases, id: \.self) { edgeControl($0) }
                }
            }
        } else {
            VStack(spacing: 2) {
                edgeControl(.top)
                HStack(spacing: 8) {
                    edgeControl(.left)
                    // The crop keeps a useful width however long the values beside it are.
                    preview.frame(minWidth: 96).frame(height: 72)
                    edgeControl(.right)
                }
                edgeControl(.bottom)
            }
        }
    }

    /// White when the edge is included, like the card's other chosen controls; an edge with no
    /// padding stays selectable, since "there is none here" can be the note.
    private func edgeControl(_ edge: LayoutInspection.Edge) -> some View {
        let value = geometry.paddingLabel(on: edge)
        let isSelected = selected.contains(edge)
        let isZero = geometry.paddingValues(on: edge).isEmpty
        // One text, so a long nested value such as "5 + 5 + 5 pt" wraps inside the control's
        // column instead of running out of the card.
        let name = Text(edge.title).foregroundStyle(isSelected ? Color.black : Mono.secondary)
        let amount = Text(value ?? "")
            .fontWeight(.semibold)
            .foregroundStyle(isSelected ? Color.black : isZero ? Mono.secondary : Mono.text)
        let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)
        return Button {
            toggle(edge)
        } label: {
            Text("\(name) \(amount)")
                .font(.caption)
                .monospacedDigit()
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(minHeight: 30)
                .background(isSelected ? Color.white : Mono.fill, in: shape)
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

    private var preview: some View {
        GeometryReader { proxy in
            let box = geometry.bounds
            let scale = min((proxy.size.width - 6) / max(box.width, 1), (proxy.size.height - 6) / max(box.height, 1), 3)
            let size = CGSize(width: box.width * scale, height: box.height * scale)
            ZStack {
                Image(uiImage: image).resizable().frame(width: size.width, height: size.height)
                Canvas { context, _ in
                    func local(_ rect: CGRect) -> CGRect {
                        CGRect(
                            x: (rect.minX - box.minX) * scale,
                            y: (rect.minY - box.minY) * scale,
                            width: rect.width * scale,
                            height: rect.height * scale
                        )
                    }
                    for region in geometry.padding {
                        var band = Path(local(region.outer))
                        band.addRect(local(region.inner))
                        context.fill(band, with: .color(.gray.opacity(0.3)), style: FillStyle(eoFill: true))
                    }
                    for edge in selected {
                        for region in geometry.padding {
                            context.fill(Path(local(region.band(on: edge))), with: .color(.red.opacity(0.4)))
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
