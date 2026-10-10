#if REDLINE && canImport(UIKit)
import SwiftUI
import UIKit

@MainActor
private protocol HostingLayoutDebugSource: AnyObject {
    func _viewDebugData() -> [_ViewDebug.Data]
}

extension _UIHostingView: HostingLayoutDebugSource {}

/// Uses an underscored debug API and reflected storage. Both may change between OS versions.
@MainActor
enum SwiftUILayoutInspector {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "RedlineLayoutPrototype") }

    static func capture(in windows: [UIWindow]) -> LayoutInspection {
        guard isEnabled else { return LayoutInspection() }
        var result = LayoutInspection()
        var serialized: [Data] = []
        func append(_ data: _ViewDebug.Data, parent: Int?, host: UIView, depth: Int) {
            guard depth < 100 else { return }
            let mirror = Mirror(reflecting: data)
            let properties = mirror.children.first { $0.label == "data" }?.value
                as? [_ViewDebug.Property: Any] ?? [:]
            let children = mirror.children.first { $0.label == "childData" }?.value
                as? [_ViewDebug.Data] ?? []
            let value = properties[.value]
            let type = properties[.type].map { String(describing: $0) } ?? "unknown"
            let index = result.nodes.count
            result.nodes.append(LayoutInspection.Node(
                type: type,
                text: type == "Text" && (properties[.size] as? CGSize).map { $0.width > 0 && $0.height > 0 } == true
                    ? value.flatMap { text(in: $0) } : nil,
                settings: isLayoutNode(type) ? value.map { settings(in: $0) } ?? [] : [],
                parent: parent,
                childCount: children.count,
                frame: (properties[.position] as? CGPoint).flatMap { position in
                    (properties[.size] as? CGSize).map { host.convert(CGRect(origin: position, size: $0), to: nil) }
                }
            ))
            for child in children { append(child, parent: index, host: host, depth: depth + 1) }
        }
        func visit(_ view: UIView) {
            if let host = view as? any HostingLayoutDebugSource {
                let roots = host._viewDebugData()
                if let data = _ViewDebug.serializedData(roots) { serialized.append(data) }
                for root in roots { append(root, parent: nil, host: view, depth: 0) }
                return
            }
            for child in view.subviews { visit(child) }
        }
        for window in windows { visit(window) }
        // Opt-in local evidence only; this data never enters a Redline report.
        if let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            for (index, data) in serialized.enumerated() {
                try? data.write(to: folder.appendingPathComponent("layout-tree-\(index).json"))
            }
            let debugLines = result.nodes.enumerated().map { index, node in
                "\(index) parent=\(String(describing: node.parent)) \(node.type) text=\(String(describing: node.text)) \(node.settings)"
            }
            try? debugLines.joined(separator: "\n").write(
                to: folder.appendingPathComponent("layout-nodes.txt"), atomically: true, encoding: .utf8
            )
        }
        return result
    }

    private static func isLayoutNode(_ type: String) -> Bool {
        ["_PaddingLayout", "_FrameLayout", "_FlexFrameLayout", "_HStackLayout", "_VStackLayout", "_ZStackLayout",
         "LayoutPriorityLayout", "_TraitWritingModifier<LayoutPriorityTraitKey>"].contains(type)
            || ["HStack<", "VStack<", "ZStack<"].contains { type.hasPrefix($0) }
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

    private static func settings(in value: Any, depth: Int = 0) -> [String] {
        guard depth < 8 else { return [] }
        let type = String(describing: Swift.type(of: value))
        let mirror = Mirror(reflecting: value)
        if ["_PaddingLayout", "_FrameLayout", "_FlexFrameLayout", "_HStackLayout", "_VStackLayout", "_ZStackLayout", "LayoutPriorityLayout"].contains(type)
            || type == "_TraitWritingModifier<LayoutPriorityTraitKey>" {
            let fields = mirror.children.map { child in
                let name = child.label ?? "value"
                var formatted = format(child.value)
                if formatted == "unspecified", (type == "_PaddingLayout" && name == "insets")
                    || (type.hasSuffix("StackLayout") && name == "spacing") {
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
            for (name, candidate) in [("center", Alignment.center), ("leading", .leading), ("trailing", .trailing),
                                      ("top", .top), ("bottom", .bottom), ("topLeading", .topLeading),
                                      ("topTrailing", .topTrailing), ("bottomLeading", .bottomLeading),
                                      ("bottomTrailing", .bottomTrailing)] where alignment == candidate { return name }
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
