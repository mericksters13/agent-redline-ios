#if REDLINE
import Foundation
import Testing
@testable import Redline

struct NoteCardPlacementTests {
    private let statusBar: CGFloat = 62
    private let keyboardTop: CGFloat = 538
    private let homeIndicatorTop: CGFloat = 840
    private let minimum: CGFloat = 134

    private func space(_ element: CGRect?, height: CGFloat = 200, bottom: CGFloat = 538)
        -> (bounds: ClosedRange<CGFloat>, anchorsBottom: Bool)
    {
        NoteCardPlacement.space(
            element: element,
            minimumHeight: minimum,
            height: height,
            top: statusBar,
            bottom: bottom
        )
    }

    private func element(y: CGFloat, height: CGFloat = 60) -> CGRect {
        CGRect(x: 20, y: y, width: 360, height: height)
    }

    @Test func theMeasurementTagStaysOnScreenAndAwayFromTheCard() {
        let marked = CGRect(x: 20, y: 182, width: 180, height: 44)
        let small = CGSize(width: 120, height: 28)
        // The card is below, so the tag sits above the marked area, by its leading edge.
        let above = NoteCardPlacement.tagOrigin(marked: marked, tag: small, cardMidY: 400, screenWidth: 402, top: 62)
        #expect(above == CGPoint(x: 17, y: 146))
        // The card is above, so the tag sits below.
        let below = NoteCardPlacement.tagOrigin(marked: marked, tag: small, cardMidY: 100, screenWidth: 402, top: 62)
        #expect(below == CGPoint(x: 17, y: 234))
        // A tag as wide as it may get, naming every edge and the frame, starts at the margin
        // instead of running off the leading edge.
        let widest = CGSize(width: NoteCardPlacement.tagMaxWidth(screenWidth: 402), height: 46)
        let wide = NoteCardPlacement.tagOrigin(
            marked: CGRect(x: 300, y: 182, width: 80, height: 44),
            tag: widest,
            cardMidY: 400,
            screenWidth: 402,
            top: 62
        )
        #expect(wide.x == 8)
        #expect(wide.x + widest.width <= 402 - 8)
        #expect(wide.y == 128)
        // Near the top, a tall tag stops under the status bar.
        let top = NoteCardPlacement.tagOrigin(
            marked: CGRect(x: 20, y: 80, width: 80, height: 20),
            tag: widest,
            cardMidY: 400,
            screenWidth: 402,
            top: 62
        )
        #expect(top.y == 66)
    }

    @Test func anElementNearTheTopGetsTheSpaceBelowIt() {
        let slot = space(element(y: 100))
        #expect(slot.bounds == 168...530)
        #expect(!slot.anchorsBottom)
    }

    @Test func anElementLowerDownGetsTheSpaceAboveIt() {
        let slot = space(element(y: 420))
        #expect(slot.bounds == 70...412)
        #expect(slot.anchorsBottom)
    }

    @Test func anElementUnderTheKeyboardGetsTheWholeVisibleSpace() {
        let slot = space(element(y: 780, height: 50))
        #expect(slot.bounds == 70...530)
        #expect(slot.anchorsBottom)
    }

    @Test func aFormThatCannotFitAtFullHeightStillUsesAClearSide() {
        // Neither side fits the old 266 pt reservation, but 222 pt above is usable.
        let slot = space(element(y: 300), height: 600)
        #expect(slot.bounds == 70...292)
        #expect(slot.anchorsBottom)
    }

    @Test func theLargerUsableSideWinsAndEqualSidesPreferBelow() {
        let picked = element(y: 230, height: 140)
        let slot = space(picked)
        #expect(slot.bounds == 378...530)
        #expect(!slot.anchorsBottom)
        let above = space(element(y: 260, height: 140))
        #expect(above.bounds == 70...252)
        #expect(above.anchorsBottom)
    }

    @Test func aGrowingNoteKeepsTheSameSideAndBoundary() {
        for picked in [element(y: 100), element(y: 420)] {
            let short = space(picked, height: 150)
            let tall = space(picked, height: 600)
            #expect(short.bounds == tall.bounds)
            #expect(short.anchorsBottom == tall.anchorsBottom)
        }
    }

    @Test func overlapIsAllowedOnlyWhenNeitherSideHoldsTheMinimumForm() {
        let picked = element(y: 120, height: 400)
        let slot = space(picked)
        #expect(slot.bounds == 70...530)
        #expect(!slot.anchorsBottom)
    }

    @Test func editingFromTheListRestsOnTheKeyboard() {
        let slot = space(nil)
        #expect(slot.bounds == 70...530)
        #expect(slot.anchorsBottom)
    }

    @Test func withoutAKeyboardTheFormUsesTheSpaceAboveTheHomeIndicator() {
        let slot = space(element(y: 300), bottom: homeIndicatorTop)
        #expect(slot.bounds == 368...832)
        #expect(!slot.anchorsBottom)
    }

    @Test func aTallerFooterRequiresEnoughSpaceForAUsableContentRow() {
        let slot = NoteCardPlacement.space(
            element: element(y: 230, height: 140),
            minimumHeight: 180,
            height: 200,
            top: statusBar,
            bottom: keyboardTop
        )
        #expect(slot.bounds == 70...530)
    }

    @Test func cappedFormsRemainClearWheneverEitherSideIsUsable() {
        for bottom in [193.0, 538.0, 600.0, 840.0] {
            let safeTop = bottom == 193 ? 0.0 : 62.0
            let start = safeTop + 8
            let end = bottom - 8
            for elementHeight in [20.0, 60.0, 200.0, 500.0] {
                for y in stride(from: 0.0, through: 874.0, by: 10) {
                    let picked = element(y: y, height: elementHeight)
                    for contentHeight in [150.0, 266.0, 600.0] {
                        let slot = NoteCardPlacement.space(
                            element: picked,
                            minimumHeight: minimum,
                            height: contentHeight,
                            top: safeTop,
                            bottom: bottom
                        )
                        let height = min(contentHeight, slot.bounds.upperBound - slot.bounds.lowerBound)
                        let top = slot.anchorsBottom ? slot.bounds.upperBound - height : slot.bounds.lowerBound
                        #expect(top >= start)
                        #expect(top + height <= end + 0.001)
                        if picked.minY - 8 - start >= minimum || end - picked.maxY - 8 >= minimum {
                            #expect(
                                top + height <= picked.minY - 8 + 0.001 || top >= picked.maxY + 8,
                                "Form \(top)...\(top + height) covers component \(picked)"
                            )
                        }
                    }
                }
            }
        }
    }

    @Test func unavailableViewportProducesAnEmptySpace() {
        let slot = NoteCardPlacement.space(element: nil, minimumHeight: minimum, height: 200, top: 100, bottom: 100)
        #expect(slot.bounds.lowerBound == slot.bounds.upperBound)
    }
}
#endif
