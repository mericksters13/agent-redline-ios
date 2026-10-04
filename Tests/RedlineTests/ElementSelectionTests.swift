#if REDLINE
import Foundation
import Testing
@testable import Redline

struct ElementSelectionTests {
    private let screen = CGSize(width: 400, height: 800)

    private func element(
        role: String,
        label: String?,
        frame: CGRect,
        identifier: String? = nil,
        isContainer: Bool = false
    ) -> ElementSnapshot {
        ElementSnapshot(
            role: role,
            label: label,
            value: nil,
            identifier: identifier,
            className: nil,
            isContainer: isContainer,
            frame: frame
        )
    }

    @Test func innermostElementComesFirstThenItsContainers() {
        let card = element(
            role: "Group",
            label: "Account",
            frame: CGRect(x: 20, y: 100, width: 360, height: 200),
            isContainer: true
        )
        let row = element(role: "Button", label: "Email", frame: CGRect(x: 30, y: 120, width: 340, height: 44))
        let label = element(role: "Text", label: "Email", frame: CGRect(x: 40, y: 130, width: 100, height: 20))
        let levels = ElementSelection.levels(at: CGPoint(x: 60, y: 140), in: [card, label, row], screenSize: screen)
        #expect(levels == [label, row, card])
    }

    @Test func sameSizedWrappersCollapseIntoOneLevel() {
        let button = element(role: "Button", label: "Save", frame: CGRect(x: 20, y: 600, width: 360, height: 50))
        let wrapper = element(
            role: "Group",
            label: "Save",
            frame: CGRect(x: 21, y: 601, width: 358, height: 49),
            isContainer: true
        )
        let levels = ElementSelection.levels(at: CGPoint(x: 200, y: 620), in: [button, wrapper], screenSize: screen)
        #expect(levels.count == 1)
    }

    @Test func elementsCoveringTheScreenAreLeftOut() {
        let background = element(
            role: "Group",
            label: "Main",
            frame: CGRect(x: 0, y: 0, width: 400, height: 800),
            isContainer: true
        )
        let button = element(role: "Button", label: "Save", frame: CGRect(x: 20, y: 600, width: 360, height: 50))
        let levels = ElementSelection.levels(at: CGPoint(x: 200, y: 620), in: [background, button], screenSize: screen)
        #expect(levels == [button])
    }

    @Test func aNearMissPicksTheNearestElement() {
        let icon = element(role: "Image", label: "Close", frame: CGRect(x: 350, y: 60, width: 24, height: 24))
        let levels = ElementSelection.levels(at: CGPoint(x: 340, y: 50), in: [icon], screenSize: screen)
        #expect(levels == [icon])
    }

    @Test func aFarMissPicksNothing() {
        let icon = element(role: "Image", label: "Close", frame: CGRect(x: 350, y: 60, width: 24, height: 24))
        let levels = ElementSelection.levels(at: CGPoint(x: 100, y: 400), in: [icon], screenSize: screen)
        #expect(levels.isEmpty)
    }

    @Test func matchPrefersTheIdentifier() {
        let saved = element(
            role: "Button",
            label: "Save",
            frame: CGRect(x: 0, y: 0, width: 10, height: 10),
            identifier: "save"
        )
        let moved = element(
            role: "Button",
            label: "Save changes",
            frame: CGRect(x: 0, y: 300, width: 10, height: 10),
            identifier: "save"
        )
        let other = element(role: "Button", label: "Save", frame: CGRect(x: 0, y: 500, width: 10, height: 10))
        #expect(ElementSelection.match(saved, in: [other, moved]) == moved)
    }

    @Test func matchByLabelNeedsAUniqueHit() {
        let saved = element(role: "Text", label: "Total", frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        let first = element(role: "Text", label: "Total", frame: CGRect(x: 0, y: 100, width: 10, height: 10))
        let second = element(role: "Text", label: "Total", frame: CGRect(x: 0, y: 200, width: 10, height: 10))
        #expect(ElementSelection.match(saved, in: [first]) == first)
        #expect(ElementSelection.match(saved, in: [first, second]) == nil)
    }

    @Test func theNameIsTheLabelThenTheIdentifierThenTheValue() {
        #expect(element(role: "Button", label: "Save", frame: .zero, identifier: "save").fullName == "Save")
        #expect(element(role: "Image", label: nil, frame: .zero, identifier: "logo").fullName == "logo")
        // An empty label is no name.
        #expect(element(role: "Image", label: "", frame: .zero, identifier: "logo").fullName == "logo")
        #expect(element(role: "Group", label: nil, frame: .zero).fullName == nil)
    }

    @Test func aLongNameIsCutShortForLists() {
        let long = String(repeating: "a", count: 40)
        #expect(element(role: "Text", label: long, frame: .zero).shortName == String(repeating: "a", count: 33) + "…")
        #expect(element(role: "Text", label: long, frame: .zero).fullName == long)
        #expect(element(role: "Text", label: "Short", frame: .zero).shortName == "Short")
    }

    @Test func headerTitleIsTheTopmostHeader() {
        let section = element(role: "Header", label: "Quick add", frame: CGRect(x: 20, y: 600, width: 200, height: 30))
        let title = element(role: "Header", label: "Today", frame: CGRect(x: 20, y: 150, width: 200, height: 40))
        let text = element(role: "Text", label: "Hello", frame: CGRect(x: 20, y: 100, width: 200, height: 20))
        #expect(ElementSelection.headerTitle(in: [section, text, title]) == "Today")
        #expect(ElementSelection.headerTitle(in: [text]) == nil)
    }
}
#endif
