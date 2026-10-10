#if REDLINE
import Foundation
import Testing
@testable import Redline

struct LayoutInspectionTests {
    private func element(_ label: String, role: String = "Text") -> ElementSnapshot {
        ElementSnapshot(role: role, label: label, value: nil, identifier: nil, className: nil,
                        isContainer: false, frame: .zero)
    }

    @Test func duplicateTextDoesNotSelectTheFirstMatch() {
        let node = LayoutInspection.Node(type: "Text", text: "Same", settings: ["padding=4"], parent: nil, childCount: 0)
        let result = LayoutInspection(nodes: [node, node]).describe(element("Same"))
        #expect(result.contains("Ambiguous"))
        #expect(!result.contains("padding=4"))
    }

    @Test func wrappersAreSeparatedFromAncestorLayout() {
        let inspection = LayoutInspection(nodes: [
            .init(type: "HStack", settings: ["spacing=12"], parent: nil, childCount: 2),
            .init(type: "Padding", settings: ["insets=system default"], parent: 0, childCount: 1),
            .init(type: "Text", text: "Sample", settings: [], parent: 1, childCount: 0)
        ])
        let result = inspection.describe(element("Sample"))
        #expect(result.contains("Component wrappers:\ninsets=system default\nAncestor layouts:\nspacing=12"))
        #expect(result.contains("not verified"))
    }

    @Test func identicalNestedModifiersRemainSeparate() {
        let inspection = LayoutInspection(nodes: [
            .init(type: "Padding", settings: ["leading=5"], parent: nil, childCount: 1),
            .init(type: "Padding", settings: ["leading=5"], parent: 0, childCount: 1),
            .init(type: "Text", text: "Nested", settings: [], parent: 1, childCount: 0)
        ])
        let result = inspection.describe(element("Nested"))
        #expect(result.components(separatedBy: "leading=5").count - 1 == 2)
    }

    @Test func repeatedTextCanBeDistinguishedByRuntimeBounds() {
        let first = CGRect(x: 10, y: 20, width: 80, height: 20)
        let second = CGRect(x: 110, y: 20, width: 80, height: 20)
        let inspection = LayoutInspection(nodes: [
            .init(type: "Padding", settings: ["padding=4"], parent: nil, childCount: 1, frame: first),
            .init(type: "Text", text: "Same", settings: [], parent: 0, childCount: 0, frame: first),
            .init(type: "Padding", settings: ["padding=20"], parent: nil, childCount: 1, frame: second),
            .init(type: "Text", text: "Same", settings: [], parent: 2, childCount: 0, frame: second)
        ])
        var selected = element("Same")
        selected.frame = second
        let result = inspection.describe(selected)
        #expect(result.contains("text and bounds"))
        #expect(result.contains("padding=20"))
        #expect(!result.contains("padding=4"))
    }

    @Test func coincidentBoundsRemainAmbiguous() {
        let frame = CGRect(x: 10, y: 20, width: 80, height: 20)
        let node = LayoutInspection.Node(type: "Text", text: "Same", settings: [], parent: nil, childCount: 0, frame: frame)
        var selected = element("Same")
        selected.frame = frame
        #expect(LayoutInspection(nodes: [node, node]).describe(selected).contains("Ambiguous"))
    }

    @Test func syntheticLabelAndNonTextSelectionStayUnsupported() {
        let inspection = LayoutInspection(nodes: [
            .init(type: "Text", text: "Visible", settings: ["padding=9"], parent: nil, childCount: 0)
        ])
        #expect(inspection.describe(element("Synthetic")).contains("No runtime text match"))
        #expect(inspection.describe(element("Visible", role: "Button")).contains("Unsupported"))
        #expect(LayoutInspection().describe(element("Visible")).contains("unavailable"))
    }
}
#endif
