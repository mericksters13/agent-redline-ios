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

    @Test func aGroupWithNoNameIsNamedAfterWhatItHolds() {
        var group = element(role: "Group", label: nil, frame: .zero, isContainer: true)
        group.contents = ["Beyond the sky"]
        group.contentCount = 1
        #expect(group.fullName == #""Beyond the sky""#)
        group.contents = ["Beyond the sky", "Unlock the rest"]
        group.contentCount = 2
        #expect(group.fullName == #""Beyond the sky" and "Unlock the rest""#)
        group.contents = ["Time, 55 min", "Serves, 4", "Calories, 480"]
        group.contentCount = 6
        #expect(group.fullName == #""Time, 55 min" and 5 more"#)
        // Its own name wins over what it holds.
        group.identifier = "detail.stats"
        #expect(group.fullName == "detail.stats")
    }

    @Test func aGroupWithNoNameIsALevelAndIsFoundAgainByWhatItHolds() {
        var card = element(
            role: "Group",
            label: nil,
            frame: CGRect(x: 20, y: 100, width: 360, height: 200),
            isContainer: true
        )
        card.contents = ["Beyond the sky", "Tricks and bigger patterns"]
        card.contentCount = 2
        let text = element(
            role: "Text",
            label: "Tricks and bigger patterns",
            frame: CGRect(x: 30, y: 160, width: 340, height: 60),
            parent: 0
        )
        let levels = ElementSelection.levels(at: CGPoint(x: 100, y: 180), in: [card, text], screenSize: screen)
        #expect(
            levels.map(\.fullName) == [
                "Tricks and bigger patterns", #""Beyond the sky" and "Tricks and bigger patterns""#,
            ]
        )

        var moved = card
        moved.frame.origin.y += 40
        var other = card
        other.contents = ["Low orbit"]
        other.frame.origin.y = 400
        #expect(ElementSelection.match(card, in: [other, moved]) == moved)
        #expect(ElementSelection.match(card, in: [other]) == nil)
    }

    @Test func aLongNameIsCutShortForLists() {
        let long = String(repeating: "a", count: 40)
        #expect(element(role: "Text", label: long, frame: .zero).shortName == String(repeating: "a", count: 33) + "…")
        #expect(element(role: "Text", label: long, frame: .zero).fullName == long)
        #expect(element(role: "Text", label: "Short", frame: .zero).shortName == "Short")
    }

    // MARK: - Drawings

    /// A card with a title, a button, a chart and a link, then a row below it, each child
    /// pointing at the card, as `AccessibilityTree` reads them.
    private var card: [ElementSnapshot] {
        [
            element(
                role: "Group",
                label: nil,
                frame: CGRect(x: 20, y: 156, width: 362, height: 295),
                identifier: "growth.card",
                isContainer: true
            ),
            element(role: "Text", label: "Growth", frame: CGRect(x: 92, y: 186, width: 80, height: 24), parent: 0),
            element(role: "Button", label: "Add", frame: CGRect(x: 300, y: 176, width: 66, height: 44), parent: 0),
            element(
                role: "Group",
                label: "Weight in kg by age",
                frame: CGRect(x: 36, y: 330, width: 330, height: 90),
                identifier: "growth.card.chart",
                isContainer: true,
                parent: 0
            ),
            element(
                role: "Button",
                label: "All measurements",
                frame: CGRect(x: 36, y: 420, width: 330, height: 24),
                parent: 0
            ),
            element(role: "Button", label: "Sleep", frame: CGRect(x: 20, y: 520, width: 362, height: 60)),
        ]
    }

    /// A hand-drawn loop around `rect`, a little bigger than it, from `start` to `end` radians.
    private func loop(around rect: CGRect, from start: Double = 0, to end: Double = 2 * .pi) -> [CGPoint] {
        (0...24).map { step in
            let angle = start + (end - start) * Double(step) / 24
            return CGPoint(
                x: rect.midX + rect.width * 0.6 * cos(angle),
                y: rect.midY + rect.height * 0.6 * sin(angle)
            )
        }
    }

    private func names(_ elements: [ElementSnapshot]) -> [String?] {
        elements.map(\.fullName)
    }

    @Test func aCircleAroundAButtonEnclosesOnlyThatButton() {
        let add = CGRect(x: 300, y: 176, width: 66, height: 44)
        let enclosed = ElementSelection.enclosed(by: [loop(around: add)], in: card, screenSize: screen)
        #expect(names(enclosed) == ["Add"])
    }

    @Test func aCircleAroundACardEnclosesItAndWhatItHolds() {
        let box = CGRect(x: 20, y: 156, width: 362, height: 295)
        let enclosed = ElementSelection.enclosed(by: [loop(around: box)], in: card, screenSize: screen)
        #expect(names(enclosed) == ["growth.card", "Growth", "Add", "Weight in kg by age", "All measurements"])
    }

    @Test func aLineOrATapEnclosesNothing() {
        let line = [CGPoint(x: 290, y: 198), CGPoint(x: 330, y: 199), CGPoint(x: 376, y: 198)]
        #expect(ElementSelection.enclosed(by: [line], in: card, screenSize: screen).isEmpty)
        #expect(ElementSelection.enclosed(by: [], in: card, screenSize: screen).isEmpty)
    }

    @Test func aLoopTracedTwiceOrInTwoHalvesStillEncloses() {
        let add = CGRect(x: 300, y: 176, width: 66, height: 44)
        let twice = loop(around: add) + loop(around: add)
        #expect(names(ElementSelection.enclosed(by: [twice], in: card, screenSize: screen)) == ["Add"])
        // Two halves whose ends don't meet: the gap between them is closed all the same.
        let top = loop(around: add, from: .pi + 0.1, to: 2 * .pi - 0.1)
        let bottom = loop(around: add, from: 0.1, to: .pi - 0.1)
        #expect(names(ElementSelection.enclosed(by: [top, bottom], in: card, screenSize: screen)) == ["Add"])
    }

    @Test func aLoopAroundMostOfARowEnclosesIt() {
        // A list row merges its title and details into one element as wide as the screen.
        let title = CGRect(x: 20, y: 520, width: 230, height: 60)
        #expect(names(ElementSelection.enclosed(by: [loop(around: title)], in: card, screenSize: screen)) == ["Sleep"])
    }

    @Test func anElementReachingWellPastTheDrawingIsNotEnclosed() {
        // The Sleep row's center is inside, but the row is far wider than the loop.
        let middle = CGRect(x: 171, y: 520, width: 60, height: 60)
        #expect(ElementSelection.enclosed(by: [loop(around: middle)], in: card, screenSize: screen).isEmpty)
    }

    @Test func anElementCoveredByASheetIsNotEnclosed() {
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
        let around = CGRect(x: 0, y: 290, width: 400, height: 80)
        let enclosed = ElementSelection.enclosed(
            by: [loop(around: around)],
            in: [list, row, sheet, send],
            screenSize: screen
        )
        #expect(names(enclosed) == ["Send"])
    }

    @Test func aGroupNamedOnlyByWhatItHoldsAddsNothingOnceThoseAreListed() {
        var group = element(
            role: "Group",
            label: nil,
            frame: CGRect(x: 80, y: 170, width: 300, height: 60),
            isContainer: true
        )
        group.contents = ["Growth", "Add"]
        group.contentCount = 2
        let elements = [
            group,
            element(role: "Text", label: "Growth", frame: CGRect(x: 92, y: 186, width: 80, height: 24), parent: 0),
            element(role: "Button", label: "Add", frame: CGRect(x: 300, y: 176, width: 66, height: 44), parent: 0),
        ]
        let enclosed = ElementSelection.enclosed(by: [loop(around: group.frame)], in: elements, screenSize: screen)
        #expect(names(enclosed) == ["Growth", "Add"])
    }

    @Test func twoCirclesApartEncloseOnlyWhatEachHolds() {
        // The chart and the link between them are in neither circle.
        let add = loop(around: CGRect(x: 300, y: 176, width: 66, height: 44))
        let sleep = loop(around: CGRect(x: 20, y: 520, width: 230, height: 60))
        #expect(names(ElementSelection.enclosed(by: [add, sleep], in: card, screenSize: screen)) == ["Add", "Sleep"])
    }

    @Test func aLineApartFromALoopEnclosesNothingMore() {
        let add = loop(around: CGRect(x: 300, y: 176, width: 66, height: 44))
        let underline = [CGPoint(x: 40, y: 700), CGPoint(x: 200, y: 702), CGPoint(x: 360, y: 700)]
        #expect(names(ElementSelection.enclosed(by: [add, underline], in: card, screenSize: screen)) == ["Add"])
    }

    @Test func anElementInTheBoxButOutsideTheShapeIsNotEnclosed() {
        let triangle = [CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 0), CGPoint(x: 0, y: 200), CGPoint(x: 0, y: 0)]
        let elements = [
            element(role: "Button", label: "Inside", frame: CGRect(x: 20, y: 20, width: 40, height: 40)),
            // Its center is past the triangle's long side.
            element(role: "Button", label: "Corner", frame: CGRect(x: 150, y: 150, width: 40, height: 40)),
        ]
        #expect(names(ElementSelection.enclosed(by: [triangle], in: elements, screenSize: screen)) == ["Inside"])
    }

    @Test func aGroupHoldingSomethingNotListedStays() {
        var group = element(
            role: "Group",
            label: nil,
            frame: CGRect(x: 80, y: 170, width: 300, height: 60),
            isContainer: true
        )
        group.contents = ["Growth", "Add", "Chart"]
        group.contentCount = 3
        let elements = [
            group,
            element(role: "Text", label: "Growth", frame: CGRect(x: 92, y: 186, width: 80, height: 24), parent: 0),
            element(role: "Button", label: "Add", frame: CGRect(x: 300, y: 176, width: 66, height: 44), parent: 0),
        ]
        let enclosed = ElementSelection.enclosed(by: [loop(around: group.frame)], in: elements, screenSize: screen)
        #expect(enclosed == elements)
    }

    @Test func aDrawingIsHeldByTheElementsAroundIt() {
        let gap = CGRect(x: 60, y: 350, width: 40, height: 40)
        #expect(
            names(ElementSelection.holding(gap, excluding: [], in: card, screenSize: screen)) == [
                "Weight in kg by age", "growth.card",
            ]
        )
        // Partly outside the chart, so only the card holds it.
        let edge = CGRect(x: 60, y: 320, width: 40, height: 40)
        #expect(names(ElementSelection.holding(edge, excluding: [], in: card, screenSize: screen)) == ["growth.card"])
    }

    @Test func aLoopInsideAButtonEnclosesItAndIsHeldOnlyByWhatHoldsTheButton() throws {
        let strokes = [loop(around: CGRect(x: 310, y: 185, width: 46, height: 26))]
        let enclosed = ElementSelection.enclosed(by: strokes, in: card, screenSize: screen)
        #expect(names(enclosed) == ["Add"])
        let box = try #require(Annotation.bounds(of: strokes))
        let holders = ElementSelection.holding(box, excluding: [], in: card, screenSize: screen)
        #expect(names(holders) == ["Add", "growth.card"])
        let outside = ElementSelection.holding(box, excluding: enclosed, in: card, screenSize: screen)
        #expect(names(outside) == ["growth.card"])
    }

    @Test func aDrawingFollowsItsElementOnlyAtTheSameSize() {
        let add = element(
            role: "Button",
            label: "Add",
            frame: CGRect(x: 300, y: 176, width: 66, height: 44),
            identifier: "growth.add"
        )
        var scrolled = add
        scrolled.frame = add.frame.offsetBy(dx: 0, dy: -100)
        #expect(ElementSelection.offset(of: add, in: [scrolled]) == CGPoint(x: 0, y: -100))
        var grown = add
        grown.frame.size.height += 10
        #expect(ElementSelection.offset(of: add, in: [grown]) == nil)
        #expect(ElementSelection.offset(of: add, in: []) == nil)
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
