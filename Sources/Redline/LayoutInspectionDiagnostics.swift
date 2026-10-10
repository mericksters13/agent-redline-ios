#if REDLINE
import Foundation

/// Writes explicitly requested local layout evidence independently of interactive capture.
enum LayoutInspectionDiagnostics {
    private static let encoder = JSONEncoder()

    @concurrent
    static func write(
        _ inspection: LayoutInspection,
        trees: [Data],
        elements: [ElementSnapshot],
        to folder: URL
    ) async throws {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (index, tree) in trees.enumerated() {
            try Task.checkCancellation()
            try tree.write(to: folder.appendingPathComponent("layout-tree-\(index).json"), options: .atomic)
        }
        try Task.checkCancellation()
        let lines = inspection.nodes.enumerated().map { index, node in
            "\(index) parent=\(String(describing: node.parent)) \(node.type) text=\(String(describing: node.text)) frame=\(String(describing: node.frame)) \(node.settings)"
        }
        try lines.joined(separator: "\n").write(
            to: folder.appendingPathComponent("layout-nodes.txt"),
            atomically: true,
            encoding: .utf8
        )
        try Task.checkCancellation()
        try encoder.encode(elements).write(to: folder.appendingPathComponent("layout-elements.json"), options: .atomic)
    }
}
#endif
