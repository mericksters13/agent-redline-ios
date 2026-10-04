#if REDLINE
import Foundation
import Testing
@testable import Redline

/// An iPhone 17 Pro in portrait, 402 by 874 pt, with a full-screen list whose content
/// starts under the status bar (62 pt) and ends above the home indicator (34 pt).
struct ScreenCompositionTests {
    private let size = CGSize(width: 402, height: 874)

    private func scroll(_ offset: CGFloat, insetBottom: CGFloat = 34, contentHeight: CGFloat = 3000) -> ScrollState {
        ScrollState(
            frame: CGRect(origin: .zero, size: size),
            offsetY: offset,
            insetTop: 62,
            insetBottom: insetBottom,
            contentHeight: contentHeight
        )
    }

    private func element(_ label: String, y: CGFloat, height: CGFloat = 50, identifier: String? = nil)
        -> ElementSnapshot
    {
        ElementSnapshot(
            role: "Button",
            label: label,
            value: nil,
            identifier: identifier,
            className: nil,
            isContainer: false,
            frame: CGRect(x: 20, y: y, width: 362, height: height)
        )
    }

    private func capture(
        _ offset: CGFloat?,
        group: Int = 0,
        elements: [ElementSnapshot] = [],
        insetBottom: CGFloat = 34,
        contentHeight: CGFloat = 3000
    ) -> Capture {
        Capture(
            id: UUID(),
            file: "c.png",
            size: size,
            scroll: offset.map { scroll($0, insetBottom: insetBottom, contentHeight: contentHeight) },
            elements: elements,
            group: group
        )
    }

    // MARK: - Reuse, stitch or replace

    @Test func anUnchangedScreenReusesItsSnapshot() {
        let first = capture(-62)
        let second = capture(-62)
        #expect(
            CaptureMerge.decision(
                previous: first,
                new: second,
                snapshotsMatch: true,
                overlap: .tooSmallToTell,
                isElementUnchanged: { true }
            )
                == .reuse(first.id)
        )
    }

    @Test func aMenuOverALookalikeSnapshotIsNotReused() {
        // A light menu over a light screen: the small copies match, the elements don't.
        let row = element("Milk", y: 252, identifier: "glance.milk")
        let first = capture(-62, elements: [row])
        let withMenu = capture(-62, elements: [row, element("PDF report", y: 100), element("CSV file", y: 178)])
        #expect(
            CaptureMerge.decision(
                previous: first,
                new: withMenu,
                snapshotsMatch: true,
                overlap: .tooSmallToTell,
                isElementUnchanged: { true }
            )
                == .replace
        )
    }

    @Test func changedTextStillReusesTheSnapshot() {
        // "Last feed 2:08 PM" becomes "2:09 PM" between two notes: same element, same place.
        let first = capture(-62, elements: [element("Last feed 2:08 PM", y: 252)])
        var later = element("Last feed 2:09 PM", y: 252)
        later.frame.size.width -= 3
        let second = capture(-62, elements: [later])
        #expect(
            CaptureMerge.decision(
                previous: first,
                new: second,
                snapshotsMatch: true,
                overlap: .tooSmallToTell,
                isElementUnchanged: { true }
            )
                == .reuse(first.id)
        )
    }

    @Test func aChangedScreenReplacesItsSnapshot() {
        #expect(
            CaptureMerge.decision(
                previous: capture(-62),
                new: capture(-62),
                snapshotsMatch: false,
                overlap: .tooSmallToTell,
                isElementUnchanged: { true }
            ) == .replace
        )
        #expect(
            CaptureMerge.decision(
                previous: capture(nil),
                new: capture(nil),
                snapshotsMatch: false,
                overlap: .tooSmallToTell,
                isElementUnchanged: { true }
            ) == .replace
        )
    }

    @Test func aScrolledScreenIsStitched() {
        #expect(
            CaptureMerge.decision(
                previous: capture(-62),
                new: capture(400),
                snapshotsMatch: false,
                overlap: .matches,
                isElementUnchanged: { true }
            )
                == .stitch
        )
        // Scrolled too far to overlap: nothing contradicts a scroll.
        #expect(
            CaptureMerge.decision(
                previous: capture(-62),
                new: capture(1500),
                snapshotsMatch: false,
                overlap: .tooSmallToTell,
                isElementUnchanged: { true }
            ) == .stitch
        )
    }

    @Test func aScrolledScreenWhoseContentAlsoChangedIsReplaced() {
        #expect(
            CaptureMerge.decision(
                previous: capture(-62),
                new: capture(400),
                snapshotsMatch: false,
                overlap: .differs,
                isElementUnchanged: { true }
            )
                == .replace
        )
    }

    @Test func aRotatedScreenIsReplaced() {
        var turned = capture(-62)
        turned.size = CGSize(width: 874, height: 402)
        #expect(
            CaptureMerge.decision(
                previous: capture(-62),
                new: turned,
                snapshotsMatch: true,
                overlap: .tooSmallToTell,
                isElementUnchanged: { true }
            )
                == .replace
        )
    }

    // MARK: - A scroll, or different content under the same title

    @Test func elementsThatMovedByTheScrollDistanceProveAScroll() {
        // Scrolled 262 pt: the row seen at 600 is now at 338.
        let before = capture(
            -62,
            elements: [element("Feed", y: 600, identifier: "row.feed"), element("Pee", y: 700, identifier: "row.pee")]
        )
        let after = capture(
            200,
            elements: [element("Feed", y: 338, identifier: "row.feed"), element("Pee", y: 438, identifier: "row.pee")]
        )
        #expect(CaptureMerge.isScroll(from: before, to: after))
        #expect(
            CaptureMerge.decision(
                previous: before,
                new: after,
                snapshotsMatch: false,
                overlap: .matches,
                isElementUnchanged: { true }
            ) == .stitch
        )
    }

    @Test func aPinnedSectionHeaderDoesNotSpoilAScroll() {
        let header = element("Today", y: 100, height: 30, identifier: "section.today")
        let before = capture(
            -62,
            elements: [
                header, element("Feed", y: 600, identifier: "row.feed"), element("Pee", y: 700, identifier: "row.pee"),
            ]
        )
        let after = capture(
            200,
            elements: [
                header, element("Feed", y: 338, identifier: "row.feed"), element("Pee", y: 438, identifier: "row.pee"),
            ]
        )
        #expect(CaptureMerge.isScroll(from: before, to: after))
    }

    @Test func anotherItemUnderTheSameTitleIsNotAScroll() {
        // Two detail pages called "Feed": their shared header sits at unrelated places.
        let before = capture(-62, elements: [element("Notes", y: 400, height: 30, identifier: "detail.notes")])
        let after = capture(200, elements: [element("Notes", y: 500, height: 30, identifier: "detail.notes")])
        #expect(!CaptureMerge.isScroll(from: before, to: after))
        #expect(
            CaptureMerge.decision(
                previous: before,
                new: after,
                snapshotsMatch: false,
                overlap: .tooSmallToTell,
                isElementUnchanged: { true }
            )
                == .replace
        )
    }

    @Test func farApartWithNothingSharedTheContentMustBeAsLong() {
        #expect(CaptureMerge.isScroll(from: capture(-62), to: capture(1500)))
        let other = capture(1500, contentHeight: 2400)
        #expect(!CaptureMerge.isScroll(from: capture(-62), to: other))
        #expect(
            CaptureMerge.decision(
                previous: capture(-62),
                new: other,
                snapshotsMatch: false,
                overlap: .tooSmallToTell,
                isElementUnchanged: { true }
            )
                == .replace
        )
    }

    // MARK: - Where content scrolls

    @Test func theScrollingBandLeavesOutTheBarsInsets() {
        // And a point more at each end, for the bars' borders.
        #expect(ScreenComposition.band(for: [capture(-62), capture(400)]) == 63...839)
    }

    @Test func aTabBarFloatingOverTheContentIsLeftOut() {
        // No bottom inset: the tab bar sits over the list, and stays put while the list scrolls.
        let tabBar = element("Today", y: 780, identifier: "tab.today")
        let top = capture(-62, elements: [tabBar, element("Newborn", y: 200)], insetBottom: 0)
        let scrolled = capture(400, elements: [tabBar, element("Feed", y: 300)], insetBottom: 0)
        #expect(ScreenComposition.band(for: [top, scrolled]) == 63...779)
    }

    // MARK: - Stitching

    @Test func oneCaptureIsTheSnapshotAsItIs() throws {
        let only = capture(-62)
        let plan = try #require(ScreenComposition.plan(for: [only]))
        #expect(plan.size == size)
        #expect(plan.stitchedFrom == 1)
        let note = CGRect(x: 20, y: 300, width: 100, height: 40)
        #expect(plan.position(of: note, from: only.id) == note)
    }

    @Test func overlappingCapturesStitchIntoOneTallSnapshot() throws {
        let top = capture(-62)
        let lower = capture(400)
        let plan = try #require(ScreenComposition.plan(for: [top, lower]))
        // Status bar, the list from its top to the bottom of the lower capture, then the home indicator.
        #expect(plan.size.height == 1336)
        #expect(plan.stitchedFrom == 2)
        #expect(plan.gaps.isEmpty)
        // Top bars from the capture scrolled highest, bottom bars from the lowest; the older
        // capture fills only the content the newer one doesn't show.
        #expect(plan.segments.map(\.captureID) == [top.id, top.id, lower.id, lower.id])
        #expect(plan.segments[1].height == 462)
        // Notes keep their place in the content.
        #expect(plan.position(of: CGRect(x: 20, y: 100, width: 100, height: 40), from: top.id)?.minY == 100)
        #expect(plan.position(of: CGRect(x: 20, y: 500, width: 100, height: 40), from: lower.id)?.minY == 962)
        // A note on the bottom bars sits at the bottom of the snapshot.
        #expect(
            plan.position(of: CGRect(x: 20, y: 850, width: 100, height: 20), from: top.id)?.minY == plan.footerY + 11
        )
    }

    @Test func capturesFarApartAreJoinedAcrossAMarkedGap() throws {
        let top = capture(-62)
        let far = capture(1500)
        let plan = try #require(ScreenComposition.plan(for: [top, far]))
        #expect(plan.gaps.count == 1)
        // The top capture ends at 777 in the content; the far one starts at 1563.
        #expect(plan.gaps.map(\.skippedHeight) == [786])
        #expect(plan.size.height == 63 + 776 + ScreenComposition.gapHeight + 776 + 35)
        #expect(
            plan.position(of: CGRect(x: 20, y: 100, width: 100, height: 40), from: far.id)?.minY == 63 + 776
                + ScreenComposition.gapHeight + 37
        )
    }

    @Test func aNoteShowsOnAnotherCaptureOnlyWhenItWasInView() {
        let top = capture(-62)
        let lower = capture(400)
        let band = ScreenComposition.band(for: [top, lower])
        let nearTop = CGRect(x: 20, y: 600, width: 100, height: 40)
        #expect(ScreenComposition.position(of: nearTop, from: top, on: lower, band: band)?.minY == 138)
        let farUp = CGRect(x: 20, y: 100, width: 100, height: 40)
        #expect(ScreenComposition.position(of: farUp, from: top, on: lower, band: band) == nil)
    }

    // MARK: - Parts

    /// Two phone screens: the most a snapshot can be before it's split.
    private let twoScreens: CGFloat = 874 * ScreenComposition.screensPerSnapshot

    @Test func aScreenScrolledOnceIsSentAsOneSnapshot() {
        // The stitched Today screen from the simulator: about one and a half screens.
        #expect(ScreenComposition.parts(height: 1307, maxHeight: twoScreens, keepingWhole: []) == [0...1307])
        #expect(
            ScreenComposition.parts(height: twoScreens, maxHeight: twoScreens, keepingWhole: []) == [0...twoScreens]
        )
    }

    @Test func aLongerScreenIsCutInAGapBetweenSections() {
        // Cards 300 pt tall with 20 pt between them; the limit falls inside a card.
        let cards = stride(from: 0.0, to: 3000, by: 320).map { CGRect(x: 16, y: $0, width: 370, height: 300) }
        let parts = ScreenComposition.parts(height: 3000, maxHeight: twoScreens, keepingWhole: [], avoiding: cards)
        #expect(parts.count == 2)
        let cut = parts[0].upperBound
        #expect(cut <= twoScreens)
        #expect(!cards.contains { $0.minY < cut && $0.maxY > cut })
    }

    @Test func aCutNeverRunsThroughAnOutline() {
        let outline = CGRect(x: 20, y: 1700, width: 100, height: 80)
        let parts = ScreenComposition.parts(height: 3000, maxHeight: twoScreens, keepingWhole: [outline])
        #expect(parts.first?.upperBound == 1696)
    }

    @Test func aSectionTallerThanTheRangeIsCutBetweenItsRows() {
        // One long card holding rows 60 pt tall with 8 pt between them.
        let card = CGRect(x: 16, y: 0, width: 370, height: 3000)
        let rows = stride(from: 0.0, to: 3000, by: 68).map { CGRect(x: 24, y: $0, width: 354, height: 60) }
        let parts = ScreenComposition.parts(
            height: 3000,
            maxHeight: twoScreens,
            keepingWhole: [],
            avoiding: [card] + rows
        )
        let cut = parts[0].upperBound
        #expect(!rows.contains { $0.minY < cut && $0.maxY > cut })
    }

    @Test func aCutPrefersTheScrolledPastBand() {
        let parts = ScreenComposition.parts(height: 3000, maxHeight: twoScreens, keepingWhole: [], preferring: [1200])
        #expect(parts.first?.upperBound == 1200)
    }

    @Test func partsCoverTheSnapshotWithoutGapsOrOverlap() {
        let parts = ScreenComposition.parts(height: 6000, maxHeight: twoScreens, keepingWhole: [])
        #expect(parts.first?.lowerBound == 0)
        #expect(parts.last?.upperBound == 6000)
        for (a, b) in zip(parts, parts.dropFirst()) { #expect(a.upperBound == b.lowerBound) }
        #expect(parts.allSatisfy { $0.upperBound - $0.lowerBound <= twoScreens })
    }
}
#endif
