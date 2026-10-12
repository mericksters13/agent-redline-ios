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

        /// Attribute logical horizontal defaults only when the measured sides establish their mapping.
        func systemDefaultEdges(inner: CGRect, outer: CGRect) -> Set<Edge> {
            var result: Set<Edge> = []
            if top == nil { result.insert(.top) }
            if bottom == nil { result.insert(.bottom) }
            let left = inner.minX - outer.minX
            let right = outer.maxX - inner.maxX
            if leading == nil && trailing == nil {
                result.formUnion([.left, .right])
            } else if leading == nil, let trailing {
                if abs(right - trailing) < 0.05 && abs(left - trailing) >= 0.05 { result.insert(.left) }
                if abs(left - trailing) < 0.05 && abs(right - trailing) >= 0.05 { result.insert(.right) }
            } else if trailing == nil, let leading {
                if abs(left - leading) < 0.05 && abs(right - leading) >= 0.05 { result.insert(.right) }
                if abs(right - leading) < 0.05 && abs(left - leading) >= 0.05 { result.insert(.left) }
            }
            return result
        }

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

        /// The setting as one line a note can include: the component's own, or its parent's.
        ///
        /// A component's own padding is chosen edge by edge in the snapshot, so it has no line here.
        func detail(inParent: Bool) -> Row? {
            let own: Row
            switch self {
            case .padding(let insets):
                guard inParent else { return nil }
                own = Row(title: "Padding", value: insets.summary)
            case .frame, .flexibleFrame:
                let parts = rows.map {
                    ["Frame", "Alignment"].contains($0.title) ? $0.value : "\($0.title) \($0.value)"
                }
                own = Row(title: "Frame", value: parts.joined(separator: " · "))
            case .stack(let axis, let spacing, let alignment):
                // Overlapping children have no spacing to report.
                let parts = [
                    inParent ? "\(axis) stack" : axis,
                    axis == "Overlapping" ? nil : "Spacing \(spacing.map(LayoutInspection.points) ?? "System default")",
                    LayoutInspection.readableAlignment(alignment),
                ]
                let value = parts.compactMap { $0 }.joined(separator: " · ")
                return Row(title: inParent ? "Parent" : "Stack", value: value)
            case .priority:
                own = rows[0]
            }
            return inParent ? Row(title: "Parent", value: "\(own.title) · \(own.value)") : own
        }
    }

    struct Row: Codable, Equatable, Sendable {
        var title: String
        var value: String
    }

    struct PaddingRegion: Equatable, Sendable {
        var inner: CGRect
        var outer: CGRect
        var systemDefaultEdges: Set<Edge> = []
        var isSystemDefault: Bool { !systemDefaultEdges.isEmpty }

        /// The strip this padding adds on `edge`.
        ///
        /// Top and bottom span the outer width, so the corners belong to them.
        func band(on edge: Edge) -> CGRect {
            switch edge {
            case .top:
                CGRect(x: outer.minX, y: outer.minY, width: outer.width, height: max(inner.minY - outer.minY, 0))
            case .right:
                CGRect(x: inner.maxX, y: inner.minY, width: max(outer.maxX - inner.maxX, 0), height: inner.height)
            case .bottom:
                CGRect(x: outer.minX, y: inner.maxY, width: outer.width, height: max(outer.maxY - inner.maxY, 0))
            case .left:
                CGRect(x: outer.minX, y: inner.minY, width: max(inner.minX - outer.minX, 0), height: inner.height)
            }
        }
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

        /// The measured frame, or the component with its padding when no frame was read.
        var box: CGRect { frame ?? bounds }

        var size: String { LayoutInspection.size(box) }
    }

    struct Report: Equatable, Sendable {
        /// Why the selection has measurements or not.
        ///
        /// Logged, never shown.
        var message: String
        var rows: [Row] = []
        /// The lines a note can include besides padding: the component's own settings, then its
        /// parents', innermost first.
        var details: [Row] = []
        var geometry: Geometry?

        /// What the person chose to send with the note: padding edges, then layout lines.
        ///
        /// Nothing without verified geometry, since nothing was offered.
        func included(edges: Set<Edge>, details chosen: Set<Int>) -> [Row] {
            guard let geometry else { return [] }
            let padding: [Row] =
                geometry.padding.isEmpty
                ? []
                : Edge.allCases.filter(edges.contains).compactMap { edge in
                    let provenance =
                        geometry.padding.contains { $0.systemDefaultEdges.contains(edge) }
                        ? "measured; system default" : "measured"
                    return geometry.paddingLabel(on: edge).map {
                        Row(title: "\(edge.title) padding", value: "\($0) (\(provenance))")
                    }
                }
            return padding + details.indices.filter(chosen.contains).map { details[$0] }
        }

        /// The measured box behind a chosen line for the component's own frame or size, which the
        /// overlay outlines.
        ///
        /// Nil when no such line is chosen, or when the frame was declared but its bounds were not
        /// measured: the note still carries the declared line, and nothing unmeasured is drawn.
        func markedFrame(_ chosen: Set<Int>) -> CGRect? {
            guard let geometry else { return nil }
            for index in details.indices where chosen.contains(index) {
                switch details[index].title {
                case "Frame", "Measured frame":
                    if let frame = geometry.frame { return frame }
                case "Rendered size":
                    return geometry.bounds
                default:
                    continue
                }
            }
            return nil
        }

        /// The component's own settings, one per line, as VoiceOver reads the measured header.
        var summary: String {
            rows.map { "\($0.title): \($0.value)" }.joined(separator: "\n")
        }
    }

    /// The note as it is sent: the person's words, then the layout they chose to include.
    static func note(_ text: String, layout: [Row]) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !layout.isEmpty else { return text }
        let context = layout.map { "\($0.title): \($0.value)" }.joined(separator: "\n")
        return [text, "Layout context:\n" + context].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// What a note includes, in a few words: "left padding and frame".
    static func phrase(for layout: [Row]) -> String? {
        var names: [String] = []
        for row in layout {
            let name = row.title == "Parent" ? "parent layout" : row.title.lowercased()
            if !names.contains(name) { names.append(name) }
        }
        let edges = names.filter { $0.hasSuffix(" padding") }
        if edges.count == Edge.allCases.count {
            names = ["padding"] + names.filter { !edges.contains($0) }
        }
        guard let last = names.last else { return nil }
        return names.count == 1 ? last : names.dropLast().joined(separator: ", ") + " and " + last
    }

    static func number(_ value: CGFloat) -> String {
        String(format: "%.1f", Double(value)).replacingOccurrences(of: ".0", with: "")
    }

    static func points(_ value: CGFloat) -> String { number(value) + " pt" }

    static func size(_ box: CGRect) -> String { "\(number(box.width)) × \(number(box.height)) pt" }

    private static func readableAlignment(_ value: String) -> String {
        value.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).capitalized
    }

    func report(_ element: ElementSnapshot?) -> Report {
        guard !nodes.isEmpty else {
            return Report(message: "Layout unavailable. Enable layout inspection before the app opens.")
        }
        guard let element else { return Report(message: "Select a component to inspect its layout.") }
        let candidates: [Int]
        if element.role == "Button" {
            candidates = buttonCandidates(label: element.label)
        } else {
            candidates = nodes.indices.filter { index in
                let node = nodes[index]
                switch element.role {
                case "Text", "Header":
                    return node.type == "Text" && node.text != nil && node.text == element.label
                case "Image": return node.type == "Image"
                case "Group":
                    return element.isContainer
                        && ["HStack<", "VStack<", "ZStack<", "Grid<"].contains { node.type.hasPrefix($0) }
                default: return false
                }
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
        let matchingNodes = Set(geometryMatches)
        let componentMatches =
            element.role == "Button"
            ? Set(geometryMatches.map { buttonOwner(at: $0, among: matchingNodes) }) : matchingNodes
        let matches = geometryMatches.isEmpty ? textMatches : Array(componentMatches)
        guard matches.count == 1, let matched = matches.first else {
            return Report(
                message: matches.isEmpty
                    ? "No matching rendered view. Measurements unavailable."
                    : "Multiple views match this selection. Measurements unavailable."
            )
        }
        let verified = componentMatches.count == 1
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
            if index != matched && Self.isComponentBoundary(node) {
                ancestor = true
            }
            for setting in node.layout {
                if let detail = setting.detail(inParent: ancestor) { report.details.append(detail) }
                if ancestor { continue }
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
                        padding.append(
                            PaddingRegion(
                                inner: inner,
                                outer: bounds,
                                systemDefaultEdges: insets.systemDefaultEdges(inner: inner, outer: bounds)
                            )
                        )
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
                let measured = Row(
                    title: frame == nil ? "Rendered size" : "Measured frame",
                    value: "\(Self.number(bounds.width)) × \(Self.number(bounds.height)) pt"
                )
                report.rows.insert(measured, at: 0)
                report.details.insert(measured, at: 0)
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
                && Self.isComponentBoundary(nodes[index])
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

    /// A plain button can render its text without a separate text box.
    ///
    /// Keep that label's identity only under a sized control, without borrowing its bounds for the text.
    func canCaptureButtonLabel(below parent: Int?) -> Bool {
        guard let parent else { return false }
        return path(from: parent).prefix {
            nodes[$0].childCount == 1 && nodes[$0].type != "AccessibilityContainerModifier"
        }.contains { index in
            Self.isButton(nodes[index].type)
                && nodes[index].frame.map { $0.width > 0 && $0.height > 0 } == true
        }
    }

    /// Walk only the labels that match this selection, instead of scanning every label for every button.
    private func buttonCandidates(label: String?) -> [Int] {
        guard let label else { return [] }
        let labels = nodes.indices.filter { nodes[$0].type == "Text" && nodes[$0].text == label }
        var result = Set(labels)
        for index in labels {
            for ancestor in path(from: index).dropFirst() where Self.isButton(nodes[ancestor].type) {
                result.insert(ancestor)
            }
        }
        return result.sorted()
    }

    /// A control and its rendered label or single-child control wrappers describe one component.
    ///
    /// Unowned labels and separate controls remain separate matches, including coincident bounds.
    private func buttonOwner(at index: Int, among matches: Set<Int>) -> Int {
        var owner = index
        if nodes[index].type == "Text",
            let control = path(from: index).dropFirst().first(where: { Self.isButton(nodes[$0].type) }),
            matches.contains(control)
        {
            owner = control
        }
        return path(from: owner).prefix {
            $0 == owner || (nodes[$0].childCount == 1 && nodes[$0].type != "AccessibilityContainerModifier")
        }.last {
            matches.contains($0) && Self.isButton(nodes[$0].type)
        } ?? owner
    }

    /// Semantic containers own their layout even when their current contents have one child.
    private static func isComponentBoundary(_ node: Node) -> Bool {
        node.childCount > 1 || node.type == "AccessibilityContainerModifier"
            || [
                "HStack<", "VStack<", "ZStack<", "Grid<", "GridRow<", "LazyHStack<", "LazyVStack<", "LazyHGrid<",
                "LazyVGrid<",
            ]
            .contains { node.type.hasPrefix($0) }
    }

    private static func isButton(_ type: String) -> Bool {
        type.hasPrefix("Button<") || type.hasPrefix("KeyboardShortcutBindingBehavior<")
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
