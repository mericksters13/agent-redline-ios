#if REDLINE
import Foundation
import Testing
@testable import Redline

struct LayoutInspectionDiagnosticsTests {
    @Test func anExplicitExportWritesTheCapturedEvidence() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "LayoutDiagnostics-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let tree = Data("[{\"type\":\"Text\"}]".utf8)
        let inspection = LayoutInspection(nodes: [
            .init(type: "Text", text: "Example", settings: [], parent: nil, childCount: 0)
        ])
        let element = ElementSnapshot(
            role: "Text",
            label: "Example",
            value: nil,
            identifier: nil,
            className: nil,
            isContainer: false,
            frame: .zero
        )
        try await LayoutInspectionDiagnostics.write(inspection, trees: [tree], elements: [element], to: folder)
        #expect(try Data(contentsOf: folder.appending(path: "layout-tree-0.json")) == tree)
        #expect(try String(contentsOf: folder.appending(path: "layout-nodes.txt"), encoding: .utf8).contains("Example"))
        let saved = try JSONDecoder().decode(
            [ElementSnapshot].self,
            from: Data(contentsOf: folder.appending(path: "layout-elements.json"))
        )
        #expect(saved == [element])
    }

    @Test func aFailedExportReportsItsError() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "LayoutDiagnostics-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("Occupied".utf8).write(to: file)
        await #expect(throws: (any Error).self) {
            try await LayoutInspectionDiagnostics.write(LayoutInspection(), trees: [], elements: [], to: file)
        }
        #expect(try Data(contentsOf: file) == Data("Occupied".utf8))
    }
}
#endif
