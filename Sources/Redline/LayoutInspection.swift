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
    }

    var nodes: [Node] = []

    func describe(_ element: ElementSnapshot?) -> String {
        guard !nodes.isEmpty else {
            return "Layout data unavailable. Activate SwiftUI view debugging before the first view renders."
        }
        guard let element, element.role == "Text", let label = element.label else {
            return "Unsupported selection. This prototype matches plain text only."
        }
        let textMatches = nodes.indices.filter { nodes[$0].text == label }
        let geometryMatches = textMatches.filter { textIndex in
            var current: Int? = textIndex
            var visited = Set<Int>()
            while let index = current, nodes.indices.contains(index), visited.insert(index).inserted {
                let node = nodes[index]
                if node.childCount > 1 { break }
                if let frame = node.frame, abs(frame.minX - element.frame.minX) < 1,
                   abs(frame.minY - element.frame.minY) < 1,
                   abs(frame.width - element.frame.width) < 1,
                   abs(frame.height - element.frame.height) < 1 { return true }
                current = node.parent
            }
            return false
        }
        let matches = geometryMatches.isEmpty ? textMatches : geometryMatches
        guard matches.count == 1, var index = matches.first else {
            return matches.isEmpty
                ? "No runtime text match. No layout settings inferred."
                : "Ambiguous runtime text: \(matches.count) matches. No layout settings inferred."
        }
        let mapping = geometryMatches.count == 1
            ? "Runtime match by text and bounds (experimental)."
            : "Runtime candidate by unique text. View mapping is not verified."
        var lines = [mapping, "Component wrappers:"]
        var isAncestor = false
        var visited = Set<Int>()
        while nodes.indices.contains(index), visited.insert(index).inserted {
            let node = nodes[index]
            if node.childCount > 1, !isAncestor {
                isAncestor = true
                lines.append("Ancestor layouts:")
            }
            lines.append(contentsOf: node.settings)
            guard let parent = node.parent else { break }
            index = parent
        }
        return lines.joined(separator: "\n")
    }
}
#endif
