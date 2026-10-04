#if REDLINE
import Foundation
import Testing
@testable import Redline

/// An iPhone 17 Pro in portrait: 874 pt tall, status bar to 62, keyboard top at 538.
struct NoteCardPlacementTests {
    private let statusBar: CGFloat = 62
    private let keyboardTop: CGFloat = 538
    private let homeIndicatorTop: CGFloat = 840
    private let height: CGFloat = 200
    private let reserved: CGFloat = 266

    private func place(_ element: CGRect?, height: CGFloat? = nil, bottom: CGFloat? = nil) -> CGFloat {
        NoteCardPlacement.top(
            element: element,
            height: height ?? self.height,
            reservedHeight: reserved,
            top: statusBar,
            bottom: bottom ?? keyboardTop
        )
    }

    private func element(y: CGFloat, height: CGFloat = 60) -> CGRect {
        CGRect(x: 20, y: y, width: 360, height: height)
    }

    @Test func anElementNearTheTopGetsTheCardBelowIt() {
        #expect(place(element(y: 100)) == 168)
    }

    @Test func anElementLowerDownGetsTheCardAboveIt() {
        #expect(place(element(y: 420)) == 212)
    }

    @Test func anElementUnderTheKeyboardGetsTheCardRestingOnTheKeyboard() {
        let tabBar = element(y: 780, height: 50)
        #expect(place(tabBar) == keyboardTop - 8 - height)
    }

    @Test func whenNeitherSideFitsTheCardHidesTheLeastOfTheElement() {
        // In the middle: resting on the keyboard would hide 60 pt of it, the top 36 pt.
        #expect(place(element(y: 300)) == statusBar + 8)
        // A tall element: the top position hides less of it than resting on the keyboard.
        #expect(place(element(y: 120, height: 400)) == statusBar + 8)
        // Lower in the middle band: resting on the keyboard hides less.
        #expect(place(element(y: 215, height: 60)) == keyboardTop - 8 - height)
    }

    @Test func editingFromTheListRestsOnTheKeyboard() {
        #expect(place(nil) == keyboardTop - 8 - height)
    }

    @Test func withoutAKeyboardTheCardUsesTheSpaceAboveTheHomeIndicator() {
        #expect(place(element(y: 300), bottom: homeIndicatorTop) == 368)
    }

    @Test func aGrowingNoteBelowTheElementStaysBelowIt() {
        let picked = element(y: 100)
        #expect(place(picked, height: 200) == 168)
        #expect(place(picked, height: 266) == 168)
    }

    @Test func aGrowingNoteAboveTheElementGrowsUpwardKeepingItsBottom() {
        let picked = element(y: 420)
        let short = place(picked, height: 200)
        let tall = place(picked, height: 266)
        #expect(short + 200 == tall + 266)
        #expect(short + 200 == 412)
    }

    @Test func theCardNeverGoesUnderTheKeyboardOrTheStatusBar() {
        for keyboard in [keyboardTop, 600, homeIndicatorTop] {
            for elementHeight in [20.0, 60.0, 200.0, 500.0] {
                for y in stride(from: 0.0, through: 874.0, by: 10) {
                    for cardHeight in [150.0, 200.0, 266.0] {
                        let top = place(element(y: y, height: elementHeight), height: cardHeight, bottom: keyboard)
                        #expect(top >= statusBar + 8, "top \(top) for element at \(y)")
                        #expect(
                            top + cardHeight <= keyboard - 8 + 0.001,
                            "bottom \(top + cardHeight) for element at \(y)"
                        )
                    }
                }
            }
        }
    }

    @Test func aCardTallerThanTheSpaceKeepsItsTopVisible() {
        #expect(place(element(y: 300), height: 600) == statusBar + 8)
    }
}
#endif
