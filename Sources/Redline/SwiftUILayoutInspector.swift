#if REDLINE && canImport(UIKit)
import SwiftUI
import UIKit

@MainActor
private protocol HostingLayoutDebugSource: AnyObject {
    func _viewDebugData() -> [_ViewDebug.Data]
}

extension _UIHostingView: HostingLayoutDebugSource {}

/// Uses an underscored debug API and reflected storage.
///
/// Both may change between OS versions.
@MainActor
enum SwiftUILayoutInspector {
    static var isEnabled: Bool {
        let defaults = UserDefaults.standard
        return defaults.bool(forKey: "RedlineLayoutInspection") || defaults.bool(forKey: "RedlineLayoutPrototype")
    }

    private static var diagnosticsTask: Task<Void, Never>?

    static func capture(in windows: [UIWindow], elements: [ElementSnapshot]) -> LayoutInspection {
        guard isEnabled else {
            diagnosticsTask?.cancel()
            return LayoutInspection()
        }
        let exportsDiagnostics = UserDefaults.standard.bool(forKey: "RedlineLayoutDiagnostics")
        if !exportsDiagnostics { diagnosticsTask?.cancel() }
        var result = LayoutInspection()
        var renderedTextIndices: Set<Int> = []
        var serialized: [Data] = []
        func append(
            _ data: _ViewDebug.Data,
            description: [String: Any]?,
            parent: Int?,
            host: UIView,
            depth: Int,
            inheritedOffset: CGPoint? = nil,
            geometryIsValid: Bool = true
        ) {
            // Retain deeply nested styled labels while bounding recursion.
            guard depth < 256 else { return }
            let mirror = Mirror(reflecting: data)
            let properties =
                mirror.children.first { $0.label == "data" }?.value
                as? [_ViewDebug.Property: Any] ?? [:]
            let children =
                mirror.children.first { $0.label == "childData" }?.value
                as? [_ViewDebug.Data] ?? []
            let descriptions = description?["children"] as? [[String: Any]] ?? []
            let transform = (description?["properties"] as? [[String: Any]])?.first {
                $0["id"] as? Int == Int(_ViewDebug.Property.transform.rawValue)
            }
            let translation = ((transform?["attribute"] as? [String: Any])?["value"] as? [String: Any])
                .flatMap(LayoutInspection.debugTranslation)
            let offset = translation ?? inheritedOffset
            let validGeometry = transform == nil ? geometryIsValid : translation != nil
            let value = properties[.value]
            let type = properties[.type].map { String(describing: $0) } ?? "unknown"
            let index = result.nodes.count
            let capturesText =
                type == "Text"
                && ((properties[.size] as? CGSize).map { $0.width > 0 && $0.height > 0 } == true
                    || (properties[.size] == nil
                        && parent.map {
                            result.nodes[$0].type == "AccessibilityAttachmentModifier"
                                && result.nodes[$0].frame.map { $0.width > 0 && $0.height > 0 } == true
                        } == true)
                    || (properties[.size] == nil && result.canCaptureButtonLabel(below: parent)))
            if capturesText { renderedTextIndices.insert(index) }
            result.nodes.append(
                LayoutInspection.Node(
                    type: type,
                    text: capturesText ? value.flatMap { text(in: $0) } : nil,
                    settings: exportsDiagnostics && isLayoutNode(type) ? value.map { settings(in: $0) } ?? [] : [],
                    parent: parent,
                    childCount: children.count,
                    frame: validGeometry
                        ? (properties[.position] as? CGPoint).flatMap { position in
                            (properties[.size] as? CGSize).map { size in
                                let box = CGRect(origin: position, size: size)
                                // Serialized translations include the host and navigation/scroll coordinate spaces.
                                return offset.map { box.offsetBy(dx: $0.x, dy: $0.y) } ?? host.convert(box, to: nil)
                            }
                        } : nil,
                    layout: isLayoutNode(type) ? value.map { layout(in: $0) } ?? [] : []
                )
            )
            for (childIndex, child) in children.enumerated() {
                append(
                    child,
                    description: descriptions.indices.contains(childIndex) ? descriptions[childIndex] : nil,
                    parent: index,
                    host: host,
                    depth: depth + 1,
                    inheritedOffset: offset,
                    geometryIsValid: validGeometry
                )
            }
            // The renderer's attributed string has already resolved localization and interpolation.
            // Replace only the nearest rendered Text's identity; accessibility-only text stays excluded.
            if type == "StyledTextContentView", let label = value.flatMap({ resolvedText(in: $0) }) {
                var ancestor = parent
                while let current = ancestor {
                    if result.nodes[current].type == "Text" {
                        if renderedTextIndices.contains(current) { result.nodes[current].text = label }
                        break
                    }
                    ancestor = result.nodes[current].parent
                }
            }
        }
        @discardableResult
        func visit(_ view: UIView) -> Bool {
            guard !view.isHidden, view.alpha > 0.01 else { return false }
            var hasNestedHost = false
            for child in view.subviews {
                if visit(child) { hasNestedHost = true }
            }
            // Read the visible content hosts; a tab container's transition graph can trap.
            if hasNestedHost { return true }
            guard let host = view as? any HostingLayoutDebugSource else { return false }
            let roots = host._viewDebugData()
            let data = _ViewDebug.serializedData(roots)
            if let data, exportsDiagnostics { serialized.append(data) }
            let descriptions = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [[String: Any]] ?? []
            for (index, root) in roots.enumerated() {
                append(
                    root,
                    description: descriptions.indices.contains(index) ? descriptions[index] : nil,
                    parent: nil,
                    host: view,
                    depth: 0
                )
            }
            return true
        }
        for window in windows { visit(window) }
        // Export is separately opt-in and does not run file I/O on the main actor.
        if exportsDiagnostics,
            let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        {
            let previous = diagnosticsTask
            previous?.cancel()
            let inspection = result
            let trees = serialized
            diagnosticsTask = Task(priority: .utility) {
                // Let an in-flight write finish before replacing it, so older captures cannot win.
                await previous?.value
                guard !Task.isCancelled else { return }
                do {
                    try await LayoutInspectionDiagnostics.write(
                        inspection,
                        trees: trees,
                        elements: elements,
                        to: folder
                    )
                } catch is CancellationError {
                    // A newer capture replaces this export.
                } catch {
                    Log.accessibility.error(
                        "Couldn't export layout diagnostics: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }
        return result
    }

    private static func isLayoutNode(_ type: String) -> Bool {
        [
            "_PaddingLayout", "_FrameLayout", "_FlexFrameLayout", "_HStackLayout", "_VStackLayout", "_ZStackLayout",
            "LayoutPriorityLayout", "_TraitWritingModifier<LayoutPriorityTraitKey>",
        ].contains(type)
            || ["HStack<", "VStack<", "ZStack<"].contains { type.hasPrefix($0) }
    }

    private static func resolvedText(in value: Any, depth: Int = 0) -> String? {
        if let attributed = value as? NSAttributedString { return attributed.string }
        if let attributed = value as? AttributedString { return String(attributed.characters) }
        guard depth < 12 else { return nil }
        for child in Mirror(reflecting: value).children {
            if let label = resolvedText(in: child.value, depth: depth + 1) { return label }
        }
        return nil
    }

    private static func text(in value: Any, depth: Int = 0) -> String? {
        guard depth < 12 else { return nil }
        let mirror = Mirror(reflecting: value)
        for child in mirror.children {
            if ["verbatim", "key"].contains(child.label ?? ""), let string = child.value as? String {
                return string
            }
        }
        for child in mirror.children {
            if let string = text(in: child.value, depth: depth + 1) { return string }
        }
        return nil
    }

    private static func layout(in value: Any, depth: Int = 0) -> [LayoutInspection.Setting] {
        guard depth < 8 else { return [] }
        let type = String(describing: Swift.type(of: value))
        let children = Array(Mirror(reflecting: value).children)
        func field(_ name: String) -> Any? {
            guard let value = children.first(where: { $0.label == name })?.value else { return nil }
            let mirror = Mirror(reflecting: value)
            return mirror.displayStyle == .optional ? mirror.children.first?.value : value
        }
        func scalar(_ name: String) -> CGFloat? {
            if let value = field(name) as? CGFloat { return value }
            if let value = field(name) as? Double { return CGFloat(value) }
            return nil
        }
        let alignment = field("alignment").map(format) ?? "unspecified"
        switch type {
        case "_PaddingLayout":
            guard let edges = field("edges") as? Edge.Set else { return [] }
            let insets = field("insets") as? EdgeInsets
            return [
                .padding(
                    .init(
                        top: edges.contains(.top) ? insets?.top : 0,
                        leading: edges.contains(.leading) ? insets?.leading : 0,
                        bottom: edges.contains(.bottom) ? insets?.bottom : 0,
                        trailing: edges.contains(.trailing) ? insets?.trailing : 0
                    )
                )
            ]
        case "_FrameLayout":
            return [.frame(width: scalar("width"), height: scalar("height"), alignment: alignment)]
        case "_FlexFrameLayout":
            return [
                .flexibleFrame(
                    minWidth: scalar("minWidth"),
                    idealWidth: scalar("idealWidth"),
                    maxWidth: scalar("maxWidth"),
                    minHeight: scalar("minHeight"),
                    idealHeight: scalar("idealHeight"),
                    maxHeight: scalar("maxHeight"),
                    alignment: alignment
                )
            ]
        case "_HStackLayout", "_VStackLayout", "_ZStackLayout":
            return [
                .stack(
                    axis: type == "_HStackLayout" ? "Horizontal" : type == "_VStackLayout" ? "Vertical" : "Overlapping",
                    spacing: scalar("spacing"),
                    alignment: alignment
                )
            ]
        case "LayoutPriorityLayout":
            return scalar("priority").map { [.priority(Double($0))] } ?? []
        case "_TraitWritingModifier<LayoutPriorityTraitKey>":
            return scalar("value").map { [.priority(Double($0))] } ?? []
        default:
            return children.filter { ["_tree", "root", "modifier", "layout"].contains($0.label ?? "") }
                .flatMap { layout(in: $0.value, depth: depth + 1) }
        }
    }

    private static func settings(in value: Any, depth: Int = 0) -> [String] {
        guard depth < 8 else { return [] }
        let type = String(describing: Swift.type(of: value))
        let mirror = Mirror(reflecting: value)
        if [
            "_PaddingLayout", "_FrameLayout", "_FlexFrameLayout", "_HStackLayout", "_VStackLayout", "_ZStackLayout",
            "LayoutPriorityLayout",
        ].contains(type)
            || type == "_TraitWritingModifier<LayoutPriorityTraitKey>"
        {
            let fields = mirror.children.map { child in
                let name = child.label ?? "value"
                var formatted = format(child.value)
                if formatted == "unspecified",
                    (type == "_PaddingLayout" && name == "insets")
                        || (type.hasSuffix("StackLayout") && name == "spacing")
                {
                    formatted += " (system default)"
                }
                return "\(name)=\(formatted)"
            }
            return ["\(type): \(fields.joined(separator: ", "))"]
        }
        return mirror.children.filter { ["_tree", "root", "modifier", "layout"].contains($0.label ?? "") }
            .flatMap { settings(in: $0.value, depth: depth + 1) }
    }

    private static func format(_ value: Any) -> String {
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            return mirror.children.first.map { format($0.value) } ?? "unspecified"
        }
        if let alignment = value as? Alignment {
            for (name, candidate) in [
                ("center", Alignment.center), ("leading", .leading), ("trailing", .trailing),
                ("top", .top), ("bottom", .bottom), ("topLeading", .topLeading),
                ("topTrailing", .topTrailing), ("bottomLeading", .bottomLeading),
                ("bottomTrailing", .bottomTrailing),
            ] where alignment == candidate { return name }
            return "custom alignment"
        }
        if let alignment = value as? HorizontalAlignment {
            if alignment == .leading { return "leading" }
            if alignment == .trailing { return "trailing" }
            if alignment == .center { return "center" }
            return "custom horizontal alignment"
        }
        if let alignment = value as? VerticalAlignment {
            if alignment == .top { return "top" }
            if alignment == .bottom { return "bottom" }
            if alignment == .center { return "center" }
            if alignment == .firstTextBaseline { return "firstTextBaseline" }
            if alignment == .lastTextBaseline { return "lastTextBaseline" }
            return "custom vertical alignment"
        }
        if let edges = value as? Edge.Set {
            return [("top", Edge.Set.top), ("leading", .leading), ("bottom", .bottom), ("trailing", .trailing)]
                .filter { edges.contains($0.1) }.map(\.0).joined(separator: "+")
        }
        return String(describing: value)
    }
}
#endif
