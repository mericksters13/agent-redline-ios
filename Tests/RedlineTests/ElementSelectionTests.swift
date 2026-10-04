#if REDLINE
import Foundation
import Testing
@testable import Redline

struct ElementSelectionTests {
    private let screen = CGSize(width: 400, height: 800)

    private func element(_ role: String, _ label: String?, _ frame: CGRect, identifier: String? = nil, container: Bool = false) -> ElementSnapshot {
        ElementSnapshot(role: role, label: label, value: nil, identifier: identifier, className: nil, isContainer: container, frame: frame)
    }

    @Test func innermostElementComesFirstThenItsContainers() {
        let card = element("Group", "Account", CGRect(x: 20, y: 100, width: 360, height: 200), container: true)
        let row = element("Button", "Email", CGRect(x: 30, y: 120, width: 340, height: 44))
        let label = element("Text", "Email", CGRect(x: 40, y: 130, width: 100, height: 20))
        let levels = ElementSelection.levels(at: CGPoint(x: 60, y: 140), in: [card, label, row], screenSize: screen)
        #expect(levels == [label, row, card])
    }

    @Test func sameSizedWrappersCollapseIntoOneLevel() {
        let button = element("Button", "Save", CGRect(x: 20, y: 600, width: 360, height: 50))
        let wrapper = element("Group", "Save", CGRect(x: 21, y: 601, width: 358, height: 49), container: true)
        let levels = ElementSelection.levels(at: CGPoint(x: 200, y: 620), in: [button, wrapper], screenSize: screen)
        #expect(levels.count == 1)
    }

    @Test func elementsCoveringTheScreenAreLeftOut() {
        let background = element("Group", "Main", CGRect(x: 0, y: 0, width: 400, height: 800), container: true)
        let button = element("Button", "Save", CGRect(x: 20, y: 600, width: 360, height: 50))
        let levels = ElementSelection.levels(at: CGPoint(x: 200, y: 620), in: [background, button], screenSize: screen)
        #expect(levels == [button])
    }

    @Test func aNearMissPicksTheNearestElement() {
        let icon = element("Image", "Close", CGRect(x: 350, y: 60, width: 24, height: 24))
        let levels = ElementSelection.levels(at: CGPoint(x: 340, y: 50), in: [icon], screenSize: screen)
        #expect(levels == [icon])
    }

    @Test func aFarMissPicksNothing() {
        let icon = element("Image", "Close", CGRect(x: 350, y: 60, width: 24, height: 24))
        let levels = ElementSelection.levels(at: CGPoint(x: 100, y: 400), in: [icon], screenSize: screen)
        #expect(levels.isEmpty)
    }

    @Test func matchPrefersTheIdentifier() {
        let saved = element("Button", "Save", CGRect(x: 0, y: 0, width: 10, height: 10), identifier: "save")
        let moved = element("Button", "Save changes", CGRect(x: 0, y: 300, width: 10, height: 10), identifier: "save")
        let other = element("Button", "Save", CGRect(x: 0, y: 500, width: 10, height: 10))
        #expect(ElementSelection.match(saved, in: [other, moved]) == moved)
    }

    @Test func matchByLabelNeedsAUniqueHit() {
        let saved = element("Text", "Total", CGRect(x: 0, y: 0, width: 10, height: 10))
        let first = element("Text", "Total", CGRect(x: 0, y: 100, width: 10, height: 10))
        let second = element("Text", "Total", CGRect(x: 0, y: 200, width: 10, height: 10))
        #expect(ElementSelection.match(saved, in: [first]) == first)
        #expect(ElementSelection.match(saved, in: [first, second]) == nil)
    }

    @Test func displayNameUsesRoleAndLabel() {
        #expect(element("Button", "Save", .zero).displayName == "Button · Save")
        #expect(element("Image", nil, .zero, identifier: "logo").displayName == "Image · logo")
        #expect(element("Group", nil, .zero).displayName == "Group")
    }

    @Test func headerTitleIsTheTopmostHeader() {
        let section = element("Header", "Quick add", CGRect(x: 20, y: 600, width: 200, height: 30))
        let title = element("Header", "Today", CGRect(x: 20, y: 150, width: 200, height: 40))
        let text = element("Text", "Hello", CGRect(x: 20, y: 100, width: 200, height: 20))
        #expect(ElementSelection.headerTitle(in: [section, text, title]) == "Today")
        #expect(ElementSelection.headerTitle(in: [text]) == nil)
    }
}
#endif
