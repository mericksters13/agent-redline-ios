#if REDLINE
import Foundation
import Synchronization

/// Writes explicitly requested local layout evidence independently of interactive capture.
enum LayoutInspectionDiagnostics {
    private static let encoder = JSONEncoder()
    private static let writer = DispatchQueue(label: "Redline.layout.diagnostics", qos: .utility)

    static func write(
        _ inspection: LayoutInspection,
        trees: [Data],
        elements: [ElementSnapshot],
        to folder: URL
    ) async throws {
        let cancelled = Mutex(false)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                writer.async {
                    continuation.resume(
                        with: Result {
                            try writeNow(inspection, trees: trees, elements: elements, to: folder) {
                                if cancelled.withLock({ $0 }) { throw CancellationError() }
                            }
                        }
                    )
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }

    /// Blocking formatting, directory scans, and writes run only on the owned serial queue.
    private static func writeNow(
        _ inspection: LayoutInspection,
        trees: [Data],
        elements: [ElementSnapshot],
        to folder: URL,
        checkCancellation: () throws -> Void
    ) throws {
        try checkCancellation()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (index, tree) in trees.enumerated() {
            try checkCancellation()
            try tree.write(to: folder.appendingPathComponent("layout-tree-\(index).json"), options: .atomic)
        }
        try checkCancellation()
        let lines = inspection.nodes.enumerated().map { index, node in
            "\(index) parent=\(String(describing: node.parent)) \(node.type) text=\(String(describing: node.text)) frame=\(String(describing: node.frame)) \(node.settings)"
        }
        try lines.joined(separator: "\n").write(
            to: folder.appendingPathComponent("layout-nodes.txt"),
            atomically: true,
            encoding: .utf8
        )
        try checkCancellation()
        try encoder.encode(elements).write(to: folder.appendingPathComponent("layout-elements.json"), options: .atomic)
        try checkCancellation()
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            try checkCancellation()
            let name = file.lastPathComponent
            guard name.range(of: "^layout-tree-[0-9]+\\.json$", options: .regularExpression) != nil,
                let index = Int(name.dropFirst("layout-tree-".count).dropLast(".json".count)),
                index >= trees.count
            else { continue }
            try FileManager.default.removeItem(at: file)
        }
    }
}
#endif
