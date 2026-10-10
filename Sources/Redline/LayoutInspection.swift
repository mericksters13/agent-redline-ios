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
            if top == bottom, top == leading, top == trailing, let top { return "All sides · \(LayoutInspection.points(top))" }
            if top == 0 && bottom == 0 && leading == trailing { return "Horizontal · \(leading.map(LayoutInspection.points) ?? "System default")" }
            if leading == 0 && trailing == 0 && top == bottom { return "Vertical · \(top.map(LayoutInspection.points) ?? "System default")" }
            return [("Top", top), ("Leading", leading), ("Bottom", bottom), ("Trailing", trailing)]
                .filter { $0.1 != 0 }.map { "\($0.0) \($0.1.map(LayoutInspection.points) ?? "System default")" }.joined(separator: " · ")
        }
    }

    enum Setting: Equatable, Sendable {
        case padding(Insets)
        case frame(width: CGFloat?, height: CGFloat?, alignment: String)
        case flexibleFrame(minWidth: CGFloat?, idealWidth: CGFloat?, maxWidth: CGFloat?,
                           minHeight: CGFloat?, idealHeight: CGFloat?, maxHeight: CGFloat?, alignment: String)
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
                    size = "\(width.map { "Width " + LayoutInspection.points($0) } ?? "Natural width") · \(height.map { "Height " + LayoutInspection.points($0) } ?? "Natural height")"
                }
                return [Row(title: "Frame", value: size), Row(title: "Alignment", value: LayoutInspection.readableAlignment(alignment))]
            case .flexibleFrame(let minWidth, let idealWidth, let maxWidth, let minHeight, let idealHeight, let maxHeight, let alignment):
                func bounds(_ minimum: CGFloat?, _ ideal: CGFloat?, _ maximum: CGFloat?) -> String {
                    [("Min", minimum), ("Ideal", ideal), ("Max", maximum)].compactMap { label, value in
                        value.map { $0.isInfinite ? "Fill available space" : "\(label) \(LayoutInspection.points($0))" }
                    }.joined(separator: " · ")
                }
                return [Row(title: "Width", value: bounds(minWidth, idealWidth, maxWidth)),
                        Row(title: "Height", value: bounds(minHeight, idealHeight, maxHeight)),
                        Row(title: "Alignment", value: LayoutInspection.readableAlignment(alignment))].filter { !$0.value.isEmpty }
            case .stack(let axis, let spacing, let alignment):
                return [Row(title: "Parent stack", value: axis),
                        Row(title: "Spacing", value: spacing.map(LayoutInspection.points) ?? "System default"),
                        Row(title: "Alignment", value: LayoutInspection.readableAlignment(alignment))]
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
            let provenance = geometry.padding.contains(where: \.isSystemDefault) ? "measured; system default" : "measured"
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
        guard !nodes.isEmpty else { return Report(message: "Layout unavailable. Enable layout inspection before the app opens.") }
        guard let element, element.role == "Text", let label = element.label else {
            return Report(message: "Layout inspection supports text selections in this prototype.")
        }
        let textMatches = nodes.indices.filter { nodes[$0].text == label }
        let geometryMatches = textMatches.filter { index in
            path(from: index, componentOnly: true).contains { index in
                guard let frame = nodes[index].frame else { return false }
                return abs(frame.minX - element.frame.minX) < 1 && abs(frame.minY - element.frame.minY) < 1
                    && abs(frame.width - element.frame.width) < 1 && abs(frame.height - element.frame.height) < 1
            }
        }
        let matches = geometryMatches.isEmpty ? textMatches : geometryMatches
        guard matches.count == 1, let matched = matches.first else {
            return Report(message: matches.isEmpty ? "No matching rendered view. Measurements unavailable."
                          : "Multiple views match this selection. Measurements unavailable.")
        }
        let verified = geometryMatches.count == 1
        var report = Report(message: verified ? "Matched by text and bounds · Experimental" : "Text match only · Position unverified")
        var inner = nodes[matched].frame
        var padding: [PaddingRegion] = []
        var frame: CGRect?
        var ancestor = false
        for index in path(from: matched) {
            let node = nodes[index]
            if node.childCount > 1 { ancestor = true }
            for setting in node.layout {
                if ancestor { report.ancestors.append(contentsOf: setting.rows); continue }
                report.rows.append(contentsOf: setting.rows)
                let bounds = renderedBounds(at: index)
                switch setting {
                case .padding(let insets):
                    if let inner, let bounds, bounds.contains(inner), bounds != inner {
                        let isDefault = [insets.top, insets.leading, insets.bottom, insets.trailing].contains(nil)
                        padding.append(PaddingRegion(inner: inner, outer: bounds, isSystemDefault: isDefault))
                        if isDefault {
                            report.rows.append(Row(title: "Measured padding", value: Insets(
                                top: inner.minY - bounds.minY, leading: inner.minX - bounds.minX,
                                bottom: bounds.maxY - inner.maxY, trailing: bounds.maxX - inner.maxX
                            ).summary))
                        }
                    }
                case .frame, .flexibleFrame:
                    if let bounds { frame = bounds }
                default: break
                }
                if let bounds { inner = bounds }
            }
        }
        if verified, let content = nodes[matched].frame {
            report.geometry = Geometry(content: content, frame: frame, padding: padding)
            if !report.rows.contains(where: { $0.title == "Frame" }) {
                let bounds = frame ?? padding.last?.outer ?? content
                report.rows.insert(Row(title: frame == nil ? "Rendered size" : "Measured frame",
                                       value: "\(Self.number(bounds.width)) × \(Self.number(bounds.height)) pt"), at: 0)
            }
        }
        return report
    }

    private func path(from start: Int, componentOnly: Bool = false) -> [Int] {
        var current: Int? = start
        var visited = Set<Int>()
        var result: [Int] = []
        while let index = current, nodes.indices.contains(index), visited.insert(index).inserted {
            if componentOnly && nodes[index].childCount > 1 { break }
            result.append(index)
            current = nodes[index].parent
        }
        return result
    }

    /// Some debug layout nodes omit bounds; their immediate background records the same rendered box.
    private func renderedBounds(at index: Int) -> CGRect? {
        if let frame = nodes[index].frame { return frame }
        guard let parent = nodes[index].parent, nodes.indices.contains(parent),
              nodes[parent].type.hasPrefix("_BackgroundStyleModifier<") else { return nil }
        return nodes[parent].frame
    }

    var nodes: [Node] = []

}
#endif
