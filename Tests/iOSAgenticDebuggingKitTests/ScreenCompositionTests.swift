#if AGENTIC_DEBUGGING
import Foundation
import Testing
@testable import iOSAgenticDebuggingKit

/// An iPhone 17 Pro in portrait, 402 by 874 pt, with a full-screen list whose content
/// starts under the status bar (62 pt) and ends above the home indicator (34 pt).
struct ScreenCompositionTests {
    private let size = CGSize(width: 402, height: 874)

    private func scroll(_ offset: CGFloat, insetBottom: CGFloat = 34) -> ScrollState {
        ScrollState(frame: CGRect(origin: .zero, size: size), offsetY: offset, insetTop: 62, insetBottom: insetBottom, contentHeight: 3000)
    }

    private func element(_ label: String, y: CGFloat, height: CGFloat = 50, id: String? = nil) -> ElementSnapshot {
        ElementSnapshot(role: "Button", label: label, value: nil, identifier: id, className: nil, isContainer: false,
                        frame: CGRect(x: 20, y: y, width: 362, height: height))
    }

    private func capture(_ offset: CGFloat?, group: Int = 0, elements: [ElementSnapshot] = [], insetBottom: CGFloat = 34) -> Capture {
        Capture(id: UUID(), file: "c.png", size: size, scroll: offset.map { scroll($0, insetBottom: insetBottom) },
                elements: elements, group: group)
    }

    // MARK: - Reuse, stitch or replace

    @Test func anUnchangedScreenReusesItsPicture() {
        let first = capture(-62), second = capture(-62)
        #expect(CaptureMerge.decide(previous: first, new: second, picturesMatch: true, overlapMatches: nil) == .reuse(first.id))
    }

    @Test func aChangedScreenReplacesItsPicture() {
        #expect(CaptureMerge.decide(previous: capture(-62), new: capture(-62), picturesMatch: false, overlapMatches: nil) == .replace)
        #expect(CaptureMerge.decide(previous: capture(nil), new: capture(nil), picturesMatch: false, overlapMatches: nil) == .replace)
    }

    @Test func aScrolledScreenIsStitched() {
        #expect(CaptureMerge.decide(previous: capture(-62), new: capture(400), picturesMatch: false, overlapMatches: true) == .stitch)
        // Scrolled too far to overlap: nothing contradicts a scroll.
        #expect(CaptureMerge.decide(previous: capture(-62), new: capture(1500), picturesMatch: false, overlapMatches: nil) == .stitch)
    }

    @Test func aScrolledScreenWhoseContentAlsoChangedIsReplaced() {
        #expect(CaptureMerge.decide(previous: capture(-62), new: capture(400), picturesMatch: false, overlapMatches: false) == .replace)
    }

    @Test func aRotatedScreenIsReplaced() {
        var turned = capture(-62)
        turned.size = CGSize(width: 874, height: 402)
        #expect(CaptureMerge.decide(previous: capture(-62), new: turned, picturesMatch: true, overlapMatches: nil) == .replace)
    }

    // MARK: - Where content scrolls

    @Test func theScrollingBandLeavesOutTheBarsInsets() {
        #expect(ScreenComposition.band(for: [capture(-62), capture(400)]) == 62...840)
    }

    @Test func aTabBarFloatingOverTheContentIsLeftOut() {
        // No bottom inset: the tab bar sits over the list, and stays put while the list scrolls.
        let tabBar = element("Today", y: 780, id: "tab.today")
        let top = capture(-62, elements: [tabBar, element("Newborn", y: 200)], insetBottom: 0)
        let scrolled = capture(400, elements: [tabBar, element("Feed", y: 300)], insetBottom: 0)
        #expect(ScreenComposition.band(for: [top, scrolled]) == 62...780)
    }

    // MARK: - Stitching

    @Test func oneCaptureIsThePictureAsItIs() throws {
        let only = capture(-62)
        let plan = try #require(ScreenComposition.plan(for: [only]))
        #expect(plan.size == size)
        #expect(plan.stitchedFrom == 1)
        let note = CGRect(x: 20, y: 300, width: 100, height: 40)
        #expect(plan.place(note, from: only.id) == note)
    }

    @Test func overlappingCapturesStitchIntoOneTallPicture() throws {
        let top = capture(-62), lower = capture(400)
        let plan = try #require(ScreenComposition.plan(for: [top, lower]))
        // Status bar, the list from its top to the bottom of the lower capture, then the home indicator.
        #expect(plan.size.height == 1336)
        #expect(plan.stitchedFrom == 2)
        #expect(plan.gaps.isEmpty)
        // Top bars from the capture scrolled highest, bottom bars from the lowest; the older
        // capture fills only the content the newer one doesn't show.
        #expect(plan.segments.map(\.capture) == [top.id, top.id, lower.id, lower.id])
        #expect(plan.segments[1].height == 462)
        // Notes keep their place in the content.
        #expect(plan.place(CGRect(x: 20, y: 100, width: 100, height: 40), from: top.id)?.minY == 100)
        #expect(plan.place(CGRect(x: 20, y: 500, width: 100, height: 40), from: lower.id)?.minY == 962)
        // A note on the bottom bars sits at the bottom of the picture.
        #expect(plan.place(CGRect(x: 20, y: 850, width: 100, height: 20), from: top.id)?.minY == plan.footerY + 10)
    }

    @Test func capturesFarApartAreJoinedAcrossAMarkedGap() throws {
        let top = capture(-62), far = capture(1500)
        let plan = try #require(ScreenComposition.plan(for: [top, far]))
        #expect(plan.gaps.count == 1)
        #expect(plan.size.height == 62 + 778 + ScreenComposition.gapHeight + 778 + 34)
        #expect(plan.place(CGRect(x: 20, y: 100, width: 100, height: 40), from: far.id)?.minY == 62 + 778 + ScreenComposition.gapHeight + 38)
    }

    @Test func aNoteShowsOnAnotherCaptureOnlyWhenItWasInView() {
        let top = capture(-62), lower = capture(400)
        let band = ScreenComposition.band(for: [top, lower])
        let nearTop = CGRect(x: 20, y: 600, width: 100, height: 40)
        #expect(ScreenComposition.position(of: nearTop, from: top, on: lower, band: band)?.minY == 138)
        let farUp = CGRect(x: 20, y: 100, width: 100, height: 40)
        #expect(ScreenComposition.position(of: farUp, from: top, on: lower, band: band) == nil)
    }

    // MARK: - Parts

    @Test func aPictureAboutOneScreenTallStaysWhole() {
        #expect(ScreenComposition.parts(height: 900, maxHeight: 874, keepingWhole: []) == [0...900])
    }

    @Test func aTallPictureIsSplitWithoutCuttingThroughAnOutline() {
        let outline = CGRect(x: 20, y: 850, width: 100, height: 50)
        let parts = ScreenComposition.parts(height: 1336, maxHeight: 874, keepingWhole: [outline])
        #expect(parts == [0...842, 842...1336])
    }

    @Test func partsCoverThePictureWithoutGapsOrOverlap() {
        let parts = ScreenComposition.parts(height: 3000, maxHeight: 874, keepingWhole: [])
        #expect(parts.first?.lowerBound == 0)
        #expect(parts.last?.upperBound == 3000)
        for (a, b) in zip(parts, parts.dropFirst()) { #expect(a.upperBound == b.lowerBound) }
        #expect(parts.allSatisfy { $0.upperBound - $0.lowerBound <= 874 * 1.1 })
    }
}
#endif
