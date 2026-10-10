#if REDLINE
import Foundation

/// A deliberately conservative prototype: text identity alone is not proof of a view mapping.
struct LayoutInspection: Equatable, Sendable {
    struct Node: Equatable, Sendable {
        var type: String
        var text: String?
        var settings: [String]
        var parent: Int?
        var childCount: Int
        var frame: CGRect? = nil
        var layout: [Setting] = []
    }

    struct Insets: Equatable, Sendable {
        var top: CGFloat?
        var leading: CGFloat?
        var bottom: CGFloat?
        var trailing: CGFloat?

        var summary: String {
            if top == nil && leading == nil && bottom == nil && trailing == nil { return "System default" }
            if top == bottom, top == leading, top == trailing, let top {
                return "All sides · \(LayoutInspection.points(top))"
            }
            if top == 0 && bottom == 0 && leading == trailing {
                return "Horizontal · \(leading.map(LayoutInspection.points) ?? "System default")"
            }
            if leading == 0 && trailing == 0 && top == bottom {
                return "Vertical · \(top.map(LayoutInspection.points) ?? "System default")"
            }
            return [("Top", top), ("Leading", leading), ("Bottom", bottom), ("Trailing", trailing)]
                .filter { $0.1 != 0 }.map { "\($0.0) \($0.1.map(LayoutInspection.points) ?? "System default")" }.joined(
                    separator: " · "
                )
        }
    }

    enum Setting: Equatable, Sendable {
        case padding(Insets)
        case frame(width: CGFloat?, height: CGFloat?, alignment: String)
        case flexibleFrame(
            minWidth: CGFloat?,
            idealWidth: CGFloat?,
            maxWidth: CGFloat?,
            minHeight: CGFloat?,
            idealHeight: CGFloat?,
            maxHeight: CGFloat?,
            alignment: String
        )
        case stack(axis: String, spacing: CGFloat?, alignment: String)
        case priority(Double)

        var rows: [Row] {
            switch self {
            case .padding(let insets):
                return [Row(title: "Padding", value: insets.summary)]
            case .frame(let width, let height, let alignment):
                let size: String
                if let width, let height {
                    size = "\(LayoutInspection.number(width)) × \(LayoutInspection.number(height)) pt"
                } else {
                    size =
                        "\(width.map { "Width " + LayoutInspection.points($0) } ?? "Natural width") · \(height.map { "Height " + LayoutInspection.points($0) } ?? "Natural height")"
                }
                return [
                    Row(title: "Frame", value: size),
                    Row(title: "Alignment", value: LayoutInspection.readableAlignment(alignment)),
                ]
            case .flexibleFrame(
                let minWidth,
                let idealWidth,
                let maxWidth,
                let minHeight,
                let idealHeight,
                let maxHeight,
                let alignment
            ):
                func bounds(_ minimum: CGFloat?, _ ideal: CGFloat?, _ maximum: CGFloat?) -> String {
                    [("Min", minimum), ("Ideal", ideal), ("Max", maximum)].compactMap { label, value in
                        value.map { $0.isInfinite ? "Fill available space" : "\(label) \(LayoutInspection.points($0))" }
                    }.joined(separator: " · ")
                }
                return [
                    Row(title: "Width", value: bounds(minWidth, idealWidth, maxWidth)),
                    Row(title: "Height", value: bounds(minHeight, idealHeight, maxHeight)),
                    Row(title: "Alignment", value: LayoutInspection.readableAlignment(alignment)),
                ].filter { !$0.value.isEmpty }
            case .stack(let axis, let spacing, let alignment):
                return [
                    Row(title: "Parent stack", value: axis),
                    Row(title: "Spacing", value: spacing.map(LayoutInspection.points) ?? "System default"),
                    Row(title: "Alignment", value: LayoutInspection.readableAlignment(alignment)),
                ]
            case .priority(let value):
                return [Row(title: "Layout priority", value: LayoutInspection.number(CGFloat(value)))]
            }
        }
    }

    struct Row: Equatable, Sendable {
        var title: String
        var value: String
    }

    struct PaddingRegion: Equatable, Sendable {
        var inner: CGRect
        var outer: CGRect
        var isSystemDefault: Bool
    }

    enum Edge: String, CaseIterable, Sendable {
        case top, right, bottom, left
        var title: String { rawValue.capitalized }
    }

    struct Geometry: Equatable, Sendable {
        var content: CGRect
        var frame: CGRect?
        var padding: [PaddingRegion]

        func paddingValues(on edge: Edge) -> [CGFloat] {
            padding.map { region in
                switch edge {
                case .top: region.inner.minY - region.outer.minY
                case .right: region.outer.maxX - region.inner.maxX
                case .bottom: region.outer.maxY - region.inner.maxY
                case .left: region.inner.minX - region.outer.minX
                }
            }.filter { $0 > 0.05 }
        }

        func paddingLabel(on edge: Edge) -> String? {
            guard !padding.isEmpty else { return nil }
            let values = paddingValues(on: edge)
            return values.isEmpty ? "0 pt" : values.map(LayoutInspection.number).joined(separator: " + ") + " pt"
        }

        /// The component and its padding; frame space is reported separately.
        var bounds: CGRect {
            padding.reduce(content) { $0.union($1.outer) }
        }
    }

    struct Report: Equatable, Sendable {
        var message: String
        var rows: [Row] = []
        var ancestors: [Row] = []
        var geometry: Geometry?

        func context(for edges: Set<Edge>) -> String {
            guard let geometry, !geometry.padding.isEmpty else { return "" }
            let provenance =
                geometry.padding.contains(where: \.isSystemDefault) ? "measured; system default" : "measured"
            return Edge.allCases.filter(edges.contains).compactMap { edge in
                geometry.paddingLabel(on: edge).map { "\(edge.title) padding: \($0) (\(provenance))" }
            }.joined(separator: "\n")
        }

        func note(_ text: String, including edges: Set<Edge>) -> String {
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let context = context(for: edges)
            guard !context.isEmpty else { return text }
            return [text, "Layout context:\n" + context].filter { !$0.isEmpty }.joined(separator: "\n\n")
        }

        var summary: String {
            ([message] + rows.map { "\($0.title): \($0.value)" })
                .joined(separator: "\n")
        }
    }

    static func number(_ value: CGFloat) -> String {
        String(format: "%.1f", Double(value)).replacingOccurrences(of: ".0", with: "")
    }

    static func points(_ value: CGFloat) -> String { number(value) + " pt" }

    private static func readableAlignment(_ value: String) -> String {
        value.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).capitalized
    }

    func report(_ element: ElementSnapshot?) -> Report {
        guard !nodes.isEmpty else {
            return Report(message: "Layout unavailable. Enable layout inspection before the app opens.")
        }
        guard let element else { return Report(message: "Select a component to inspect its layout.") }
        let candidates = nodes.indices.filter { index in
            let node = nodes[index]
            switch element.role {
            case "Text", "Header":
                return node.type == "Text" && node.text != nil && node.text == element.label
            case "Button":
                return (node.type == "Text" && node.text != nil && node.text == element.label)
                    || ((node.type.hasPrefix("Button<") || node.type.hasPrefix("KeyboardShortcutBindingBehavior<"))
                        && descendantText(at: index).contains(element.label ?? ""))
            case "Image": return node.type == "Image"
            case "Group":
                return element.isContainer
                    && ["HStack<", "VStack<", "ZStack<", "Grid<"].contains { node.type.hasPrefix($0) }
            default: return false
            }
        }
        let geometryMatches = candidates.filter { index in
            path(from: index, componentOnly: true).contains { index in
                guard let frame = renderedBounds(at: index) else { return false }
                return abs(frame.minX - element.frame.minX) < 1 && abs(frame.minY - element.frame.minY) < 1
                    && abs(frame.width - element.frame.width) < 1 && abs(frame.height - element.frame.height) < 1
            }
        }
        // Labels support an unverified text candidate. Other roles require a unique bounds match.
        let textMatches =
            ["Text", "Header"].contains(element.role)
            ? candidates.filter { nodes[$0].type == "Text" && nodes[$0].text == element.label } : []
        let matches = geometryMatches.isEmpty ? textMatches : geometryMatches
        guard matches.count == 1, let matched = matches.first else {
            return Report(
                message: matches.isEmpty
                    ? "No matching rendered view. Measurements unavailable."
                    : "Multiple views match this selection. Measurements unavailable."
            )
        }
        let verified = geometryMatches.count == 1
        let identity = nodes[matched].type == "Text" ? "text and bounds" : "component bounds"
        var report = Report(
            message: verified ? "Matched by \(identity) · Experimental" : "Text match only · Position unverified"
        )
        var inner = renderedBounds(at: matched)
        var padding: [PaddingRegion] = []
        var frame: CGRect?
        var ancestor = false
        for index in path(from: matched) {
            let node = nodes[index]
            if index != matched && (node.childCount > 1 || node.type == "AccessibilityContainerModifier") {
                ancestor = true
            }
            for setting in node.layout {
                if ancestor {
                    report.ancestors.append(contentsOf: setting.rows)
                    continue
                }
                report.rows.append(
                    contentsOf: setting.rows.map { row in
                        Row(title: row.title == "Parent stack" ? "Stack" : row.title, value: row.value)
                    }
                )
                let bounds = renderedBounds(at: index)
                switch setting {
                case .padding(let insets):
                    if let inner, let bounds, bounds.contains(inner), bounds != inner {
                        let isDefault = [insets.top, insets.leading, insets.bottom, insets.trailing].contains(nil)
                        padding.append(PaddingRegion(inner: inner, outer: bounds, isSystemDefault: isDefault))
                        if isDefault {
                            report.rows.append(
                                Row(
                                    title: "Measured padding",
                                    value: Insets(
                                        top: inner.minY - bounds.minY,
                                        leading: inner.minX - bounds.minX,
                                        bottom: bounds.maxY - inner.maxY,
                                        trailing: bounds.maxX - inner.maxX
                                    ).summary
                                )
                            )
                        }
                    }
                case .frame, .flexibleFrame:
                    if let bounds { frame = bounds }
                default: break
                }
                if let bounds { inner = bounds }
            }
        }
        if verified, let content = renderedBounds(at: matched) {
            report.geometry = Geometry(content: content, frame: frame, padding: padding)
            if !report.rows.contains(where: { $0.title == "Frame" }) {
                let bounds = frame ?? padding.last?.outer ?? content
                report.rows.insert(
                    Row(
                        title: frame == nil ? "Rendered size" : "Measured frame",
                        value: "\(Self.number(bounds.width)) × \(Self.number(bounds.height)) pt"
                    ),
                    at: 0
                )
            }
        }
        return report
    }

    private func path(from start: Int, componentOnly: Bool = false) -> [Int] {
        var current: Int? = start
        var visited = Set<Int>()
        var result: [Int] = []
        while let index = current, nodes.indices.contains(index), visited.insert(index).inserted {
            if componentOnly && index != start
                && (nodes[index].childCount > 1 || nodes[index].type == "AccessibilityContainerModifier")
            {
                break
            }
            result.append(index)
            current = nodes[index].parent
        }
        return result
    }

    /// The runtime can attach a component's box to its accessibility or background wrapper.
    ///
    /// Stop before a layout owner so a child never borrows an ancestor stack's bounds.
    private func renderedBounds(at index: Int) -> CGRect? {
        guard nodes.indices.contains(index) else { return nil }
        if let frame = nodes[index].frame, frame.width > 0, frame.height > 0 { return frame }
        var parent = nodes[index].parent
        var visited: Set<Int> = [index]
        while let current = parent, nodes.indices.contains(current), visited.insert(current).inserted {
            let node = nodes[current]
            guard node.childCount == 1,
                node.type == "AccessibilityAttachmentModifier"
                    || node.type.hasPrefix("_BackgroundStyleModifier<")
                    || node.type.hasPrefix("_InsettableBackgroundShapeModifier<")
            else { break }
            if let frame = node.frame, frame.width > 0, frame.height > 0 { return frame }
            parent = node.parent
        }
        // Explicit runtime insets establish the outer box even when that modifier omits it.
        if case .padding(let insets) = nodes[index].layout.first,
            let top = insets.top, let leading = insets.leading,
            let bottom = insets.bottom, let trailing = insets.trailing,
            [top, leading, bottom, trailing].allSatisfy({ $0.isFinite && $0 >= 0 })
        {
            var child = nodes.indices.first { nodes[$0].parent == index }
            while let current = child, nodes.indices.contains(current), visited.insert(current).inserted {
                let node = nodes[current]
                if let inner = node.frame, inner.width > 0, inner.height > 0 {
                    return CGRect(
                        x: inner.minX - leading,
                        y: inner.minY - top,
                        width: inner.width + leading + trailing,
                        height: inner.height + top + bottom
                    )
                }
                guard node.childCount == 1, node.layout.isEmpty else { break }
                child = nodes.indices.first { nodes[$0].parent == current }
            }
        }
        return nil
    }

    private func descendantText(at index: Int) -> Set<String> {
        var result = Set<String>()
        for candidate in nodes.indices where nodes[candidate].text != nil {
            if path(from: candidate).contains(index), let text = nodes[candidate].text { result.insert(text) }
        }
        return result
    }

    /// Only translations have a verified mapping in this prototype.
    ///
    /// Other transforms stay unavailable.
    static func debugTranslation(_ value: [String: Any]) -> CGPoint? {
        guard let adjustment = value["positionAdjustment"] as? [Double], adjustment.count == 2,
            let items = value["items"] as? [[String: Any]]
        else { return nil }
        var offset = CGPoint(x: -adjustment[0], y: -adjustment[1])
        for item in items {
            if item.isEmpty { continue }
            guard item.count == 1, let translation = item["translation"] as? [Double], translation.count == 2 else {
                return nil
            }
            offset.x += translation[0]
            offset.y += translation[1]
        }
        return offset.x.isFinite && offset.y.isFinite ? offset : nil
    }

    var nodes: [Node] = []

}
#endif
