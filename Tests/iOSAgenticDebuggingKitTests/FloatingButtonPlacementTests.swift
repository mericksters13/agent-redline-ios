#if AGENTIC_DEBUGGING
import Foundation
import Testing
@testable import iOSAgenticDebuggingKit

struct FloatingButtonPlacementTests {
    private let area = CGRect(x: 34, y: 96, width: 334, height: 700)

    @Test func restingAreaKeepsTheWholeButtonInsideTheSafeArea() {
        let rect = FloatingButtonPlacement.restingArea(screen: CGSize(width: 402, height: 874), top: 62, left: 0, bottom: 34, right: 0)
        #expect(rect == CGRect(x: 34, y: 96, width: 334, height: 710))
    }

    @Test func onlyTheRoundButtonTakesTouchesNotTheCornersOfItsFrame() {
        let frame = CGRect(x: 100, y: 200, width: 52, height: 52)
        #expect(FloatingButtonPlacement.buttonContains(CGPoint(x: 126, y: 226), frame: frame))
        #expect(FloatingButtonPlacement.buttonContains(CGPoint(x: 101, y: 226), frame: frame))
        #expect(!FloatingButtonPlacement.buttonContains(CGPoint(x: 102, y: 202), frame: frame))
        #expect(!FloatingButtonPlacement.buttonContains(CGPoint(x: 150, y: 250), frame: frame))
        #expect(!FloatingButtonPlacement.buttonContains(CGPoint(x: 126, y: 226), frame: .zero))
    }

    @Test func snapsToTheNearestSideEdge() {
        #expect(FloatingButtonPlacement.snapped(CGPoint(x: 300, y: 400), within: area) == CGPoint(x: 368, y: 400))
        #expect(FloatingButtonPlacement.snapped(CGPoint(x: 60, y: 400), within: area) == CGPoint(x: 34, y: 400))
    }

    @Test func restsOnTopOrBottomOnlyWhenDroppedRightByThem() {
        #expect(FloatingButtonPlacement.snapped(CGPoint(x: 200, y: 110), within: area) == CGPoint(x: 200, y: 96))
        #expect(FloatingButtonPlacement.snapped(CGPoint(x: 200, y: 780), within: area) == CGPoint(x: 200, y: 796))
    }

    @Test func aDropInTheUpperMiddleGoesToASideNotTheTop() {
        #expect(FloatingButtonPlacement.snapped(CGPoint(x: 190, y: 200), within: area) == CGPoint(x: 34, y: 200))
        #expect(FloatingButtonPlacement.snapped(CGPoint(x: 220, y: 200), within: area) == CGPoint(x: 368, y: 200))
    }

    @Test func aDropOutsideTheAreaComesBackOnScreen() {
        #expect(FloatingButtonPlacement.snapped(CGPoint(x: 500, y: 2000), within: area) == CGPoint(x: 368, y: 796))
        #expect(FloatingButtonPlacement.snapped(CGPoint(x: -40, y: 300), within: area) == CGPoint(x: 34, y: 300))
    }

    @Test func savedPositionSurvivesADifferentScreenSize() {
        let center = CGPoint(x: 368, y: 446)
        let fraction = FloatingButtonPlacement.fraction(of: center, within: area)
        let bigger = CGRect(x: 34, y: 96, width: 400, height: 900)
        #expect(FloatingButtonPlacement.center(fromFraction: fraction, within: bigger) == CGPoint(x: 434, y: 546))
    }

    @Test func startsOnTheRightEdge() {
        #expect(FloatingButtonPlacement.defaultCenter(within: area) == CGPoint(x: 368, y: 516))
    }
}
#endif
