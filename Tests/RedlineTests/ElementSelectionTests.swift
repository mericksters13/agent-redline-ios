#if REDLINE
import Foundation
import Testing
@testable import Redline

struct ElementSelectionTests {
    private let screen = CGSize(width: 400, height: 800)

    private func element(_ role: String, _ label: String?, _ frame: CGRect, identifier: String? = nil, container: Bool = false, parent: Int? = nil) -> ElementSnapshot {
        ElementSnapshot(role: role, label: label, value: nil, identifier: identifier, className: nil, isContainer: container, frame: frame, parent: parent)
    }

    @Test func innermostElementComesFirstThenItsContainers() {
        let card = element("Group", "Account", CGRect(x: 20, y: 100, width: 360, height: 200), container: true)
        let row = element("Button", "Email", CGRect(x: 30, y: 120, width: 340, height: 44), parent: 0)
        let label = element("Text", "Email", CGRect(x: 40, y: 130, width: 100, height: 20), parent: 1)
        let levels = ElementSelection.levels(at: CGPoint(x: 60, y: 140), in: [card, row, label], screenSize: screen)
        #expect(levels == [label, row, card])
    }

    @Test func sameSizedWrappersCollapseIntoOneLevel() {
        let wrapper = element("Group", "Save", CGRect(x: 21, y: 601, width: 358, height: 49), container: true)
        let button = element("Button", "Save", CGRect(x: 20, y: 600, width: 360, height: 50), parent: 0)
        let levels = ElementSelection.levels(at: CGPoint(x: 200, y: 620), in: [wrapper, button], screenSize: screen)
        #expect(levels == [button])
    }

    @Test func elementsCoveringTheScreenAreLeftOut() {
        let background = element("Group", "Main", CGRect(x: 0, y: 0, width: 400, height: 800), container: true)
        let card = element("Group", "Actions", CGRect(x: 10, y: 500, width: 380, height: 200), container: true, parent: 0)
        let button = element("Button", "Save", CGRect(x: 20, y: 600, width: 360, height: 50), parent: 1)
        let levels = ElementSelection.levels(at: CGPoint(x: 200, y: 620), in: [background, card, button], screenSize: screen)
        #expect(levels == [button, card])
    }

    @Test func theFrontElementWinsOverASmallerOneBehindIt() {
        let row = element("Button", "Delete", CGRect(x: 20, y: 600, width: 100, height: 44))
        let banner = element("Text", "Saved", CGRect(x: 0, y: 560, width: 400, height: 120))
        let levels = ElementSelection.levels(at: CGPoint(x: 60, y: 620), in: [row, banner], screenSize: screen)
        #expect(levels == [banner])
    }

    @Test func coveredElementsAreNotAncestors() {
        let list = element("Group", "Inbox", CGRect(x: 0, y: 100, width: 400, height: 600), container: true)
        let row = element("Button", "Message", CGRect(x: 0, y: 300, width: 400, height: 60), parent: 0)
        let sheet = element("Group", "Compose", CGRect(x: 0, y: 250, width: 400, height: 400), container: true)
        let send = element("Button", "Send", CGRect(x: 300, y: 270, width: 80, height: 44), parent: 2)
        let levels = ElementSelection.levels(at: CGPoint(x: 320, y: 310), in: [list, row, sheet, send], screenSize: screen)
        #expect(levels == [send, sheet])
    }

    @Test func theParentIsNotSaved() throws {
        let saved = element("Button", "Save", CGRect(x: 1, y: 2, width: 3, height: 4), parent: 7)
        let decoded = try JSONDecoder().decode(ElementSnapshot.self, from: JSONEncoder().encode(saved))
        #expect(decoded.parent == nil)
        #expect(decoded.label == "Save")
    }

    @Test func aNearMissPicksTheNearestElement() {
        let icon = element("Image", "Close", CGRect(x: 350, y: 60, width: 24, height: 24))
        let levels = ElementSelection.levels(at: CGPoint(x: 340, y: 50), in: [icon], screenSize: screen)
        #expect(levels == [icon])
    }

    @Test func aNearMissBetweenTiedElementsPicksTheFrontOne() {
        let back = element("Button", "Behind", CGRect(x: 100, y: 100, width: 100, height: 40))
        let front = element("Button", "In front", CGRect(x: 100, y: 100, width: 100, height: 40))
        let levels = ElementSelection.levels(at: CGPoint(x: 150, y: 160), in: [back, front], screenSize: screen)
        #expect(levels == [front])
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

    @Test func repeatedRowsMatchOnlyTheOneInTheSavedPlace() {
        let rows = (0..<3).map { element("Button", "Delete", CGRect(x: 0, y: 100 + CGFloat($0) * 60, width: 300, height: 44), identifier: "row.delete") }
        let others = [element("Button", "Edit", CGRect(x: 0, y: 400, width: 300, height: 44), identifier: "row.delete")]
        #expect(ElementSelection.match(rows[2], in: rows + others) == rows[2])
        #expect(ElementSelection.match(rows[1], in: rows) == rows[1])
        // After a scroll none is where the saved one was, so no row gets its marker.
        var scrolled = rows[1]
        scrolled.frame.origin.y += 30
        #expect(ElementSelection.match(scrolled, in: rows) == nil)
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
