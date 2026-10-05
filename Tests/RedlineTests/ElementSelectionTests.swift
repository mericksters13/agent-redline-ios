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
        isContainer: Bool = false,
        parent: Int? = nil
    ) -> ElementSnapshot {
        ElementSnapshot(
            role: role,
            label: label,
            value: nil,
            identifier: identifier,
            className: nil,
            isContainer: isContainer,
            frame: frame,
            parent: parent
        )
    }

    @Test func innermostElementComesFirstThenItsContainers() {
        let card = element(
            role: "Group",
            label: "Account",
            frame: CGRect(x: 20, y: 100, width: 360, height: 200),
            isContainer: true
        )
        let row = element(
            role: "Button",
            label: "Email",
            frame: CGRect(x: 30, y: 120, width: 340, height: 44),
            parent: 0
        )
        let label = element(
            role: "Text",
            label: "Email",
            frame: CGRect(x: 40, y: 130, width: 100, height: 20),
            parent: 1
        )
        let levels = ElementSelection.levels(at: CGPoint(x: 60, y: 140), in: [card, row, label], screenSize: screen)
        #expect(levels == [label, row, card])
    }

    @Test func sameSizedWrappersCollapseIntoOneLevel() {
        let wrapper = element(
            role: "Group",
            label: "Save",
            frame: CGRect(x: 21, y: 601, width: 358, height: 49),
            isContainer: true
        )
        let button = element(
            role: "Button",
            label: "Save",
            frame: CGRect(x: 20, y: 600, width: 360, height: 50),
            parent: 0
        )
        let levels = ElementSelection.levels(at: CGPoint(x: 200, y: 620), in: [wrapper, button], screenSize: screen)
        #expect(levels == [button])
    }

    @Test func elementsCoveringTheScreenAreLeftOut() {
        let background = element(
            role: "Group",
            label: "Main",
            frame: CGRect(x: 0, y: 0, width: 400, height: 800),
            isContainer: true
        )
        let card = element(
            role: "Group",
            label: "Actions",
            frame: CGRect(x: 10, y: 500, width: 380, height: 200),
            isContainer: true,
            parent: 0
        )
        let button = element(
            role: "Button",
            label: "Save",
            frame: CGRect(x: 20, y: 600, width: 360, height: 50),
            parent: 1
        )
        let levels = ElementSelection.levels(
            at: CGPoint(x: 200, y: 620),
            in: [background, card, button],
            screenSize: screen
        )
        #expect(levels == [button, card])
    }

    @Test func theFrontElementWinsOverASmallerOneBehindIt() {
        let row = element(role: "Button", label: "Delete", frame: CGRect(x: 20, y: 600, width: 100, height: 44))
        let banner = element(role: "Text", label: "Saved", frame: CGRect(x: 0, y: 560, width: 400, height: 120))
        let levels = ElementSelection.levels(at: CGPoint(x: 60, y: 620), in: [row, banner], screenSize: screen)
        #expect(levels == [banner])
    }

    @Test func coveredElementsAreNotAncestors() {
        let list = element(
            role: "Group",
            label: "Inbox",
            frame: CGRect(x: 0, y: 100, width: 400, height: 600),
            isContainer: true
        )
        let row = element(
            role: "Button",
            label: "Message",
            frame: CGRect(x: 0, y: 300, width: 400, height: 60),
            parent: 0
        )
        let sheet = element(
            role: "Group",
            label: "Compose",
            frame: CGRect(x: 0, y: 250, width: 400, height: 400),
            isContainer: true
        )
        let send = element(
            role: "Button",
            label: "Send",
            frame: CGRect(x: 300, y: 270, width: 80, height: 44),
            parent: 2
        )
        let levels = ElementSelection.levels(
            at: CGPoint(x: 320, y: 310),
            in: [list, row, sheet, send],
            screenSize: screen
        )
        #expect(levels == [send, sheet])
    }

    @Test func theParentIsNotSaved() throws {
        let saved = element(role: "Button", label: "Save", frame: CGRect(x: 1, y: 2, width: 3, height: 4), parent: 7)
        let decoded = try JSONDecoder().decode(ElementSnapshot.self, from: JSONEncoder().encode(saved))
        #expect(decoded.parent == nil)
        #expect(decoded.label == "Save")
    }

    @Test func aNearMissPicksTheNearestElement() {
        let icon = element(role: "Image", label: "Close", frame: CGRect(x: 350, y: 60, width: 24, height: 24))
        let levels = ElementSelection.levels(at: CGPoint(x: 340, y: 50), in: [icon], screenSize: screen)
        #expect(levels == [icon])
    }

    @Test func aNearMissBetweenTiedElementsPicksTheFrontOne() {
        let back = element(role: "Button", label: "Behind", frame: CGRect(x: 100, y: 100, width: 100, height: 40))
        let front = element(role: "Button", label: "In front", frame: CGRect(x: 100, y: 100, width: 100, height: 40))
        let levels = ElementSelection.levels(at: CGPoint(x: 150, y: 160), in: [back, front], screenSize: screen)
        #expect(levels == [front])
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

    @Test func repeatedRowsMatchOnlyTheOneInTheSavedPlace() {
        let rows = (0..<3).map {
            element(
                role: "Button",
                label: "Delete",
                frame: CGRect(x: 0, y: 100 + CGFloat($0) * 60, width: 300, height: 44),
                identifier: "row.delete"
            )
        }
        let others = [
            element(
                role: "Button",
                label: "Edit",
                frame: CGRect(x: 0, y: 400, width: 300, height: 44),
                identifier: "row.delete"
            )
        ]
        #expect(ElementSelection.match(rows[2], in: rows + others) == rows[2])
        #expect(ElementSelection.match(rows[1], in: rows) == rows[1])
        // After a scroll none is where the saved one was, so no row gets its marker.
        var scrolled = rows[1]
        scrolled.frame.origin.y += 30
        #expect(ElementSelection.match(scrolled, in: rows) == nil)
    }

    @Test func survivingIdentifierHitsStopTheLabelFallback() {
        let saved = element(
            role: "Button",
            label: "Delete",
            frame: CGRect(x: 0, y: 100, width: 300, height: 44),
            identifier: "row.delete"
        )
        let rows = (0..<2).map {
            element(
                role: "Button",
                label: "Remove",
                frame: CGRect(x: 0, y: 100 + CGFloat($0) * 60, width: 300, height: 44),
                identifier: "row.delete"
            )
        }
        let lookAlike = element(
            role: "Button",
            label: "Delete",
            frame: CGRect(x: 0, y: 600, width: 300, height: 44),
            identifier: "footer.delete"
        )
        #expect(ElementSelection.match(saved, in: rows + [lookAlike]) == nil)
        // With the identifier gone from the screen, the label still finds it.
        #expect(ElementSelection.match(saved, in: [lookAlike]) == lookAlike)
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
