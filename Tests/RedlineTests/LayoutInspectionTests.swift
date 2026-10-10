#if REDLINE
import Foundation
import Testing
@testable import Redline

struct LayoutInspectionTests {
    private func element(_ label: String, role: String = "Text") -> ElementSnapshot {
        ElementSnapshot(
            role: role,
            label: label,
            value: nil,
            identifier: nil,
            className: nil,
            isContainer: false,
            frame: .zero
        )
    }

    @Test func duplicateTextDoesNotSelectTheFirstMatch() {
        let node = LayoutInspection.Node(
            type: "Text",
            text: "Same",
            settings: ["padding=4"],
            parent: nil,
            childCount: 0
        )
        let result = LayoutInspection(nodes: [node, node]).report(element("Same"))
        #expect(result.message.contains("Multiple views"))
        #expect(result.rows.isEmpty)
    }

    @Test func wrappersAreSeparatedFromAncestorLayout() {
        let inspection = LayoutInspection(nodes: [
            .init(
                type: "HStack",
                settings: [],
                parent: nil,
                childCount: 2,
                layout: [.stack(axis: "Horizontal", spacing: 12, alignment: "top")]
            ),
            .init(
                type: "Padding",
                settings: [],
                parent: 0,
                childCount: 1,
                layout: [.padding(.init(top: nil, leading: nil, bottom: nil, trailing: nil))]
            ),
            .init(type: "Text", text: "Sample", settings: [], parent: 1, childCount: 0),
        ])
        let result = inspection.report(element("Sample"))
        #expect(result.rows == [.init(title: "Padding", value: "System default")])
        #expect(result.ancestors.contains(.init(title: "Spacing", value: "12 pt")))
        #expect(result.message.contains("unverified"))
    }

    @Test func identicalNestedModifiersRemainSeparate() {
        let inspection = LayoutInspection(nodes: [
            .init(
                type: "Padding",
                settings: [],
                parent: nil,
                childCount: 1,
                layout: [.padding(.init(top: 0, leading: 5, bottom: 0, trailing: 0))]
            ),
            .init(
                type: "Padding",
                settings: [],
                parent: 0,
                childCount: 1,
                layout: [.padding(.init(top: 0, leading: 5, bottom: 0, trailing: 0))]
            ),
            .init(type: "Text", text: "Nested", settings: [], parent: 1, childCount: 0),
        ])
        let result = inspection.report(element("Nested"))
        #expect(result.rows.filter { $0 == .init(title: "Padding", value: "Leading 5 pt") }.count == 2)
    }

    @Test func repeatedTextCanBeDistinguishedByRuntimeBounds() {
        let first = CGRect(x: 10, y: 20, width: 80, height: 20)
        let second = CGRect(x: 110, y: 20, width: 80, height: 20)
        let inspection = LayoutInspection(nodes: [
            .init(
                type: "Padding",
                settings: ["padding=4"],
                parent: nil,
                childCount: 1,
                frame: first,
                layout: [.padding(.init(top: 4, leading: 4, bottom: 4, trailing: 4))]
            ),
            .init(type: "Text", text: "Same", settings: [], parent: 0, childCount: 0, frame: first),
            .init(
                type: "Padding",
                settings: ["padding=20"],
                parent: nil,
                childCount: 1,
                frame: second,
                layout: [.padding(.init(top: 20, leading: 20, bottom: 20, trailing: 20))]
            ),
            .init(type: "Text", text: "Same", settings: [], parent: 2, childCount: 0, frame: second),
        ])
        var selected = element("Same")
        selected.frame = second
        let result = inspection.report(selected)
        #expect(result.message.contains("text and bounds"))
        #expect(result.rows.contains(.init(title: "Padding", value: "All sides · 20 pt")))
        #expect(!result.rows.contains(.init(title: "Padding", value: "All sides · 4 pt")))
    }

    @Test func coincidentBoundsRemainAmbiguous() {
        let frame = CGRect(x: 10, y: 20, width: 80, height: 20)
        let node = LayoutInspection.Node(
            type: "Text",
            text: "Same",
            settings: [],
            parent: nil,
            childCount: 0,
            frame: frame
        )
        var selected = element("Same")
        selected.frame = frame
        #expect(LayoutInspection(nodes: [node, node]).report(selected).message.contains("Multiple views"))
    }

    @Test func syntheticLabelsAndUnverifiedButtonsStayUnsupported() {
        let inspection = LayoutInspection(nodes: [
            .init(type: "Text", text: "Visible", settings: ["padding=9"], parent: nil, childCount: 0)
        ])
        #expect(inspection.report(element("Synthetic")).message.contains("No matching rendered view"))
        #expect(inspection.report(element("Visible", role: "Button")).message.contains("No matching rendered view"))
        #expect(LayoutInspection().report(element("Visible")).message.contains("unavailable"))
    }

    @Test func capturedPaddingAndFrameProduceMeasuredRegions() {
        let text = CGRect(x: 36, y: 194, width: 41, height: 20)
        let padded = CGRect(x: 20, y: 194, width: 73, height: 20)
        let box = CGRect(x: 20, y: 182, width: 180, height: 44)
        let inspection = LayoutInspection(nodes: [
            .init(type: "_BackgroundStyleModifier<Color>", settings: [], parent: nil, childCount: 1, frame: box),
            .init(
                type: "_FrameLayout",
                settings: [],
                parent: 0,
                childCount: 1,
                layout: [.frame(width: 180, height: 44, alignment: "leading")]
            ),
            .init(
                type: "_PaddingLayout",
                settings: [],
                parent: 1,
                childCount: 1,
                frame: padded,
                layout: [.padding(.init(top: 0, leading: 16, bottom: 0, trailing: 16))]
            ),
            .init(type: "Text", text: "Fixed", settings: [], parent: 2, childCount: 0, frame: text),
        ])
        var selected = element("Fixed")
        selected.frame = padded
        let result = inspection.report(selected)
        #expect(result.geometry?.content == text)
        #expect(result.geometry?.frame == box)
        #expect(result.geometry?.bounds == padded)
        #expect(result.geometry?.padding == [.init(inner: text, outer: padded, isSystemDefault: false)])
        #expect(result.summary.contains("Padding: Horizontal · 16 pt"))
        #expect(result.summary.contains("Frame: 180 × 44 pt"))
        #expect(!result.summary.contains("_FrameLayout"))
    }

    @Test func defaultPaddingKeepsDeclarationSeparateFromMeasurement() {
        let text = CGRect(x: 36, y: 372, width: 121, height: 20)
        let padded = text.insetBy(dx: -16, dy: -16)
        let inspection = LayoutInspection(nodes: [
            .init(type: "_BackgroundStyleModifier<Color>", settings: [], parent: nil, childCount: 1, frame: padded),
            .init(
                type: "_PaddingLayout",
                settings: [],
                parent: 0,
                childCount: 1,
                layout: [.padding(.init(top: nil, leading: nil, bottom: nil, trailing: nil))]
            ),
            .init(type: "Text", text: "Default", settings: [], parent: 1, childCount: 0, frame: text),
        ])
        var selected = element("Default")
        selected.frame = text
        let result = inspection.report(selected)
        #expect(result.summary.contains("Padding: System default"))
        #expect(result.summary.contains("Measured padding: All sides · 16 pt"))
        #expect(result.geometry?.padding.first?.isSystemDefault == true)
        #expect(result.geometry?.frame == nil)
    }

    @Test func nestedPaddingUsesEachCapturedBoundary() {
        let text = CGRect(x: 57, y: 252, width: 55, height: 20)
        let inner = CGRect(x: 52, y: 252, width: 60, height: 20)
        let outer = CGRect(x: 47, y: 252, width: 65, height: 20)
        let setting = LayoutInspection.Setting.padding(.init(top: 0, leading: 5, bottom: 0, trailing: 0))
        let inspection = LayoutInspection(nodes: [
            .init(type: "_PaddingLayout", settings: [], parent: nil, childCount: 1, frame: outer, layout: [setting]),
            .init(type: "_PaddingLayout", settings: [], parent: 0, childCount: 1, frame: inner, layout: [setting]),
            .init(type: "Text", text: "Nested", settings: [], parent: 1, childCount: 0, frame: text),
        ])
        var selected = element("Nested")
        selected.frame = text
        let result = inspection.report(selected)
        #expect(result.geometry?.padding.map(\.outer) == [inner, outer])
        #expect(result.geometry?.bounds == outer)
        #expect(result.rows.filter { $0.title == "Padding" }.count == 2)
    }

    @Test func uncertainMappingsNeverDrawMeasurements() {
        let text = CGRect(x: 10, y: 20, width: 80, height: 20)
        let node = LayoutInspection.Node(
            type: "Text",
            text: "Same",
            settings: [],
            parent: nil,
            childCount: 0,
            frame: text
        )
        var selected = element("Same")
        selected.frame = text
        let ambiguous = LayoutInspection(nodes: [node, node]).report(selected)
        #expect(ambiguous.geometry == nil)
        #expect(ambiguous.rows.isEmpty)
        #expect(ambiguous.message.contains("Multiple views"))
        selected.frame.origin.x += 100
        let unverified = LayoutInspection(nodes: [node]).report(selected)
        #expect(unverified.geometry == nil)
        #expect(unverified.message.contains("unverified"))
    }

    @Test func missingLayoutBoundsDoNotBorrowAnAncestorStackBox() {
        let text = CGRect(x: 20, y: 30, width: 80, height: 20)
        let inspection = LayoutInspection(nodes: [
            .init(
                type: "VStack<Text>",
                settings: [],
                parent: nil,
                childCount: 2,
                frame: CGRect(x: 0, y: 0, width: 400, height: 800),
                layout: [.stack(axis: "Vertical", spacing: 18, alignment: "leading")]
            ),
            .init(
                type: "_FrameLayout",
                settings: [],
                parent: 0,
                childCount: 1,
                layout: [.frame(width: 180, height: 44, alignment: "topLeading")]
            ),
            .init(type: "Text", text: "Sample", settings: [], parent: 1, childCount: 0, frame: text),
        ])
        var selected = element("Sample")
        selected.frame = text
        let result = inspection.report(selected)
        #expect(result.geometry?.frame == nil)
        #expect(result.geometry?.bounds == text)
        #expect(result.ancestors.contains(.init(title: "Spacing", value: "18 pt")))
        #expect(result.rows.contains(.init(title: "Alignment", value: "Top Leading")))
    }

    @Test func flexibleBoundsUsePlainLanguageAndDistinguishMeasuredSize() {
        let rows = LayoutInspection.Setting.flexibleFrame(
            minWidth: 100,
            idealWidth: 160,
            maxWidth: .infinity,
            minHeight: 40,
            idealHeight: nil,
            maxHeight: nil,
            alignment: "trailing"
        ).rows
        #expect(rows.contains(.init(title: "Width", value: "Min 100 pt · Ideal 160 pt · Fill available space")))
        #expect(rows.contains(.init(title: "Height", value: "Min 40 pt")))
        #expect(rows.contains(.init(title: "Alignment", value: "Trailing")))
    }

    @Test func selectedPaddingBecomesNoteContextWithoutChangingTheUserText() throws {
        let content = CGRect(x: 36, y: 194, width: 41, height: 20)
        let outer = content.insetBy(dx: -16, dy: 0)
        let report = LayoutInspection.Report(
            message: "Matched",
            geometry: .init(
                content: content,
                frame: nil,
                padding: [.init(inner: content, outer: outer, isSystemDefault: false)]
            )
        )
        #expect(report.geometry?.paddingLabel(on: .top) == "0 pt")
        #expect(
            report.note("  Too wide  ", including: [.left])
                == "Too wide\n\nLayout context:\nLeft padding: 16 pt (measured)"
        )
        #expect(!report.context(for: [.left]).contains("Right"))
        #expect(report.note("  Too wide  ", including: []) == "Too wide")
        let fractional = LayoutInspection.Geometry(
            content: content,
            frame: nil,
            padding: [.init(inner: content, outer: content.insetBy(dx: -0.5, dy: 0), isSystemDefault: false)]
        )
        #expect(fractional.paddingLabel(on: .left) == "0.5 pt")
        let annotation = Annotation(
            id: UUID(),
            createdAt: .now,
            note: report.note("Too wide", including: [.left]),
            kind: .element,
            element: element("Fixed"),
            ancestors: [],
            screen: nil,
            attachments: []
        )
        let saved = try JSONDecoder().decode(Annotation.self, from: JSONEncoder().encode(annotation))
        #expect(saved.note == annotation.note)
    }

    @Test func nestedPaddingAndSystemDefaultsStayHonestInContext() {
        let content = CGRect(x: 57, y: 252, width: 55, height: 20)
        let inner = CGRect(x: 52, y: 252, width: 60, height: 20)
        let outer = CGRect(x: 47, y: 252, width: 65, height: 20)
        let nested = LayoutInspection.Report(
            message: "Matched",
            geometry: .init(
                content: content,
                frame: nil,
                padding: [
                    .init(inner: content, outer: inner, isSystemDefault: false),
                    .init(inner: inner, outer: outer, isSystemDefault: false),
                ]
            )
        )
        #expect(nested.geometry?.paddingLabel(on: .left) == "5 + 5 pt")
        #expect(nested.context(for: [.left]) == "Left padding: 5 + 5 pt (measured)")
        let system = LayoutInspection.Report(
            message: "Matched",
            geometry: .init(
                content: content,
                frame: nil,
                padding: [.init(inner: content, outer: content.insetBy(dx: -16, dy: -16), isSystemDefault: true)]
            )
        )
        #expect(system.context(for: [.top]) == "Top padding: 16 pt (measured; system default)")
        #expect(LayoutInspection.Report(message: "Unavailable").note("Keep this", including: [.left]) == "Keep this")
    }

    @Test func accessibilityWrappersSupplyDeclaredFrameBounds() {
        let text = CGRect(x: 84, y: 253, width: 149.3, height: 18)
        let frame = CGRect(x: 84, y: 253, width: 150, height: 18)
        let inspection = LayoutInspection(nodes: [
            .init(
                type: "VStack<Text>",
                settings: [],
                parent: nil,
                childCount: 2,
                layout: [.stack(axis: "Vertical", spacing: 2, alignment: "leading")]
            ),
            .init(type: "AccessibilityAttachmentModifier", settings: [], parent: 0, childCount: 1, frame: frame),
            .init(
                type: "_FrameLayout",
                settings: [],
                parent: 1,
                childCount: 1,
                layout: [.frame(width: 150, height: nil, alignment: "leading")]
            ),
            .init(type: "Text", text: "Summary", settings: [], parent: 2, childCount: 0, frame: text),
        ])
        var selected = element("Summary")
        selected.frame = text
        let result = inspection.report(selected)
        #expect(result.geometry?.frame == frame)
        #expect(result.geometry?.bounds == text)
        #expect(result.geometry?.padding.isEmpty == true)
        #expect(result.summary.contains("Frame: Width 150 pt"))
    }

    @Test func textBackedButtonsAndHeadersUseTheirAccessibilityWrapper() {
        let bounds = CGRect(x: 84, y: 187, width: 46, height: 64)
        let inspection = LayoutInspection(nodes: [
            .init(type: "AccessibilityAttachmentModifier", settings: [], parent: nil, childCount: 1, frame: bounds),
            .init(type: "Text", text: "Recipe", settings: [], parent: 0, childCount: 0),
        ])
        for role in ["Button", "Header"] {
            var selected = element("Recipe", role: role)
            selected.frame = bounds
            let result = inspection.report(selected)
            #expect(result.geometry?.content == bounds)
            #expect(result.geometry?.padding.isEmpty == true)
            #expect(result.message.contains("text and bounds"))
        }
    }

    @Test func selectedRowPaddingDoesNotIncludeListInsets() {
        let row = CGRect(x: 32, y: 187, width: 338, height: 84)
        let padded = row.insetBy(dx: 0, dy: -4)
        let inspection = LayoutInspection(nodes: [
            .init(
                type: "_PaddingLayout",
                settings: [],
                parent: nil,
                childCount: 1,
                frame: padded.insetBy(dx: -16, dy: -15),
                layout: [.padding(.init(top: 15, leading: 16, bottom: 15, trailing: 16))]
            ),
            .init(type: "AccessibilityContainerModifier", settings: [], parent: 0, childCount: 1),
            .init(
                type: "_PaddingLayout",
                settings: [],
                parent: 1,
                childCount: 1,
                layout: [.padding(.init(top: 4, leading: 0, bottom: 4, trailing: 0))]
            ),
            .init(
                type: "HStack<Text>",
                settings: [],
                parent: 2,
                childCount: 2,
                frame: row,
                layout: [.stack(axis: "Horizontal", spacing: 12, alignment: "center")]
            ),
            .init(
                type: "Text",
                text: "Recipe",
                settings: [],
                parent: 3,
                childCount: 0,
                frame: CGRect(x: 84, y: 187, width: 80, height: 20)
            ),
        ])
        var selected = element("", role: "Group")
        selected.isContainer = true
        selected.frame = padded
        let result = inspection.report(selected)
        #expect(result.geometry?.content == row)
        #expect(result.geometry?.bounds == padded)
        #expect(result.context(for: [.top]) == "Top padding: 4 pt (measured)")
        #expect(result.rows.contains(.init(title: "Stack", value: "Horizontal")))
        #expect(result.rows.contains(.init(title: "Padding", value: "Vertical · 4 pt")))
        #expect(
            !result.rows.contains(
                .init(title: "Padding", value: "Top 15 pt · Leading 16 pt · Bottom 15 pt · Trailing 16 pt")
            )
        )
        #expect(
            result.ancestors.contains(
                .init(title: "Padding", value: "Top 15 pt · Leading 16 pt · Bottom 15 pt · Trailing 16 pt")
            )
        )
        selected = element("Recipe")
        selected.frame = inspection.nodes[4].frame!
        #expect(inspection.report(selected).geometry?.padding.isEmpty == true)
    }

    @Test func styledButtonOwnsItsOuterPadding() {
        let button = CGRect(x: 60, y: 708, width: 326, height: 50)
        let inspection = LayoutInspection(nodes: [
            .init(type: "VStack<Text>", settings: [], parent: nil, childCount: 2),
            .init(
                type: "_PaddingLayout",
                settings: [],
                parent: 0,
                childCount: 1,
                layout: [.padding(.init(top: 0, leading: 44, bottom: 0, trailing: 0))]
            ),
            .init(
                type: "KeyboardShortcutBindingBehavior<Label>",
                settings: [],
                parent: 1,
                childCount: 1,
                frame: button
            ),
            .init(type: "HStack<Text>", settings: [], parent: 2, childCount: 2),
            .init(
                type: "Text",
                text: "Start cooking",
                settings: [],
                parent: 3,
                childCount: 0,
                frame: CGRect(x: 160, y: 722, width: 102, height: 20)
            ),
        ])
        var selected = element("Start cooking", role: "Button")
        selected.frame = button
        let result = inspection.report(selected)
        #expect(result.geometry?.content == button)
        #expect(result.geometry?.bounds == CGRect(x: 16, y: 708, width: 370, height: 50))
        #expect(result.context(for: [.left]) == "Left padding: 44 pt (measured)")
        selected.label = "Different action"
        #expect(inspection.report(selected).geometry == nil)
    }

    @Test func imageFrameUsesOnlyItsOwnBackgroundAndAccessibilityWrappers() {
        let box = CGRect(x: 32, y: 209, width: 40, height: 40)
        let inspection = LayoutInspection(nodes: [
            .init(type: "AccessibilityAttachmentModifier", settings: [], parent: nil, childCount: 1, frame: box),
            .init(type: "_InsettableBackgroundShapeModifier<Color, Rectangle>", settings: [], parent: 0, childCount: 1),
            .init(
                type: "_FrameLayout",
                settings: [],
                parent: 1,
                childCount: 1,
                layout: [.frame(width: 40, height: 40, alignment: "center")]
            ),
            .init(
                type: "Image",
                settings: [],
                parent: 2,
                childCount: 0,
                frame: CGRect(x: 37, y: 215, width: 30, height: 28)
            ),
        ])
        var selected = element("Lunch", role: "Image")
        selected.frame = box
        let result = inspection.report(selected)
        #expect(result.geometry?.frame == box)
        #expect(result.geometry?.padding.isEmpty == true)
        #expect(result.summary.contains("Frame: 40 × 40 pt"))
        var ambiguous = inspection
        ambiguous.nodes.append(inspection.nodes[3])
        #expect(ambiguous.report(selected).geometry == nil)
        #expect(ambiguous.report(selected).message.contains("Multiple views"))
    }

    @Test func missingDefaultPaddingBoundsDoNotTurnParentSpaceIntoPadding() {
        let text = CGRect(x: 20, y: 20, width: 80, height: 20)
        let inspection = LayoutInspection(nodes: [
            .init(
                type: "VStack<Text>",
                settings: [],
                parent: nil,
                childCount: 2,
                frame: CGRect(x: 0, y: 0, width: 400, height: 800)
            ),
            .init(
                type: "_PaddingLayout",
                settings: [],
                parent: 0,
                childCount: 1,
                layout: [.padding(.init(top: nil, leading: nil, bottom: nil, trailing: nil))]
            ),
            .init(type: "Text", text: "Sample", settings: [], parent: 1, childCount: 0, frame: text),
        ])
        var selected = element("Sample")
        selected.frame = text
        let result = inspection.report(selected)
        #expect(result.geometry?.padding.isEmpty == true)
        #expect(result.geometry?.bounds == text)
        #expect(result.rows.contains(.init(title: "Padding", value: "System default")))
    }

    @Test func capturedTranslationsIncludeNavigationAndScrollOffsets() {
        #expect(
            LayoutInspection.debugTranslation([
                "positionAdjustment": [0.0, 0.0],
                "items": [[:], ["translation": [0.0, 116.0]], [:]],
            ]) == CGPoint(x: 0, y: 116)
        )
        #expect(
            LayoutInspection.debugTranslation([
                "positionAdjustment": [16.0, 41.0],
                "items": [
                    ["translation": [16.0, 41.0]], ["translation": [16.0, 168.0]], ["translation": [0.0, -90.0]],
                ],
            ])
                == CGPoint(x: 16, y: 78)
        )
        #expect(
            LayoutInspection.debugTranslation([
                "positionAdjustment": [0.0, 0.0],
                "items": [["affineTransform": [1.0, 0.0, 0.0, 1.0, 0.0, 0.0]]],
            ]) == nil
        )
        #expect(LayoutInspection.debugTranslation(["items": []]) == nil)
    }

}
#endif
