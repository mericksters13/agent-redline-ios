#if REDLINE
import CoreGraphics
import Foundation
import Testing
@testable import Redline

/// Notes made on Tiny Tally's growth card in different states, filed the way the phone files them.
struct CaptureMergeTests {
    /// The draft as the phone keeps it: screens with their captures, notes, and each capture's
    /// pixels.
    private struct Draft {
        var screens: [ScreenRecord] = []
        var annotations: [Annotation] = []
        var images: [UUID: CGImage] = [:]

        /// Adds a note on the element with `identifier` or `label`, as it is on `state`.
        @discardableResult
        mutating func addNote(on state: GrowthScreen, identifier: String? = nil, label: String? = nil) throws -> UUID {
            let elements = state.elements
            let element = try #require(
                elements.first { identifier != nil ? $0.identifier == identifier : $0.label == label }
            )
            let image = try state.image()
            let capture = Capture(
                id: UUID(),
                file: "capture.png",
                size: GrowthScreen.size,
                scroll: state.scroll,
                elements: elements,
                group: 0
            )
            let images = self.images
            let filing = CaptureMerge.place(
                capture,
                image: image,
                element: element,
                screen: ScreenInfo(title: "Patterns", viewController: "NavigationStackHostingController"),
                screens: &screens,
                annotations: &annotations
            ) { images[$0.id] }
            if filing.isNewCapture { self.images[capture.id] = image }
            let id = UUID()
            annotations.append(
                Annotation(
                    id: id,
                    createdAt: .now,
                    note: "Note \(annotations.count + 1)",
                    kind: .element,
                    element: element,
                    ancestors: [],
                    screen: ScreenInfo(title: "Patterns", viewController: "NavigationStackHostingController"),
                    attachments: [],
                    captureID: filing.captureID
                )
            )
            return id
        }

        /// The snapshots a report gets: one per state of a screen that still has notes on it.
        var snapshots: [[Int]] {
            screens.flatMap(\.groups).compactMap { group in
                let ids = Set(group.map(\.id))
                let notes = annotations.indices.filter { annotations[$0].captureID.map(ids.contains) ?? false }
                return notes.isEmpty ? nil : notes.map { $0 + 1 }
            }
        }

        func captureID(of note: UUID) -> UUID? {
            annotations.first { $0.id == note }?.captureID
        }
    }

    @Test func aSegmentSwitchInsideACardGivesEachNoteItsOwnSnapshot() throws {
        var draft = Draft()
        let card = try draft.addNote(on: GrowthScreen(segment: .length), identifier: "growth.card")
        let segment = try draft.addNote(on: GrowthScreen(segment: .head), label: "Head")
        #expect(draft.captureID(of: card) != draft.captureID(of: segment))
        #expect(draft.snapshots == [[1], [2]])
    }

    @Test func aNoteDoesNotMoveOntoANewerSnapshotOfAnotherState() throws {
        // The banner changes the screen, so the new capture replaces the screen's snapshot; the
        // card changed only by its segment, about 5% of a small copy.
        var draft = Draft()
        let card = try draft.addNote(on: GrowthScreen(segment: .length), identifier: "growth.card")
        let banner = try draft.addNote(on: GrowthScreen(segment: .head, showsBanner: true), label: "Back up your data")
        #expect(draft.captureID(of: card) != draft.captureID(of: banner))
        #expect(draft.snapshots == [[1], [2]])
    }

    @Test func aNoteOnAnUnchangedElementSharesTheNewerSnapshot() throws {
        var draft = Draft()
        let sleep = try draft.addNote(on: GrowthScreen(segment: .weight), identifier: "sleep.card")
        let growth = try draft.addNote(on: GrowthScreen(segment: .length), identifier: "growth.card")
        #expect(draft.captureID(of: sleep) == draft.captureID(of: growth))
        #expect(draft.snapshots == [[1, 2]])
    }

    @Test func aNoteUnderADimmedPopupKeepsItsSnapshot() throws {
        var draft = Draft()
        let card = try draft.addNote(on: GrowthScreen(segment: .weight), identifier: "growth.card")
        let popup = try draft.addNote(on: GrowthScreen(segment: .weight, showsPopup: true), label: "Keep editing")
        #expect(draft.captureID(of: card) != draft.captureID(of: popup))
        #expect(draft.snapshots == [[1], [2]])
    }

    /// The report this came from: three notes on the growth card, one per segment, gave two
    /// snapshots.
    @Test func threeNotesInThreeSegmentStatesGetThreeSnapshots() throws {
        // Length and Head look alike on the whole screen and have the same layout, so the old rule
        // put the Head note on the Length capture.
        let length = try GrowthScreen(segment: .length).image()
        let head = try GrowthScreen(segment: .head).image()
        #expect(SnapshotComparison.difference(length, head) < SnapshotComparison.sameSnapshot)
        #expect(
            CaptureMerge.isSameLayout(
                capture(GrowthScreen(segment: .length)),
                as: capture(GrowthScreen(segment: .head))
            )
        )

        var draft = Draft()
        try draft.addNote(on: GrowthScreen(segment: .weight), identifier: "growth.card.chart")
        try draft.addNote(on: GrowthScreen(segment: .length), identifier: "growth.card")
        try draft.addNote(on: GrowthScreen(segment: .head), identifier: "growth.card")
        #expect(draft.snapshots == [[1], [2], [3]])
    }

    @Test func anUnchangedScreenReusesItsSnapshot() throws {
        var draft = Draft()
        let first = try draft.addNote(on: GrowthScreen(segment: .weight), identifier: "growth.card")
        let second = try draft.addNote(on: GrowthScreen(segment: .weight), label: "Add")
        #expect(draft.captureID(of: first) == draft.captureID(of: second))
        #expect(draft.screens.first?.captures.count == 1)
    }

    // MARK: - Scrolling

    /// The case stitching used to get wrong: a segment switch, then a scroll, then a note on another
    /// card.
    ///
    /// The scrolled capture would draw the card behind note 1 in the Head state.
    @Test func aSegmentSwitchThenAScrollStartsANewSnapshot() throws {
        var draft = Draft()
        try draft.addNote(on: GrowthScreen(segment: .length), identifier: "growth.card")
        try draft.addNote(on: GrowthScreen(segment: .head, scrollOffset: 100), identifier: "sleep.card")
        #expect(draft.snapshots == [[1], [2]])
    }

    @Test func aScrollWithoutAChangeIsStitched() throws {
        var draft = Draft()
        try draft.addNote(on: GrowthScreen(segment: .length), identifier: "growth.card")
        try draft.addNote(on: GrowthScreen(segment: .length, scrollOffset: 100), identifier: "sleep.card")
        #expect(draft.snapshots == [[1, 2]])
        #expect(draft.screens.first?.captures.count == 2)
    }

    /// A stitched snapshot takes the bottom bars from the capture scrolled lowest, so a scroll
    /// further down would draw the changed tab bar under note 1.
    @Test func aScrollThatChangesATabBarWithANoteStartsANewSnapshot() throws {
        var draft = Draft()
        try draft.addNote(on: GrowthScreen(segment: .length), label: "Insights")
        try draft.addNote(
            on: GrowthScreen(segment: .length, scrollOffset: 100, selectsInsights: true),
            identifier: "sleep.card"
        )
        #expect(draft.snapshots == [[1], [2]])
    }

    @Test func aScrollThatKeepsATabBarWithANoteIsStitched() throws {
        var draft = Draft()
        try draft.addNote(on: GrowthScreen(segment: .length), label: "Insights")
        try draft.addNote(on: GrowthScreen(segment: .length, scrollOffset: 100), identifier: "sleep.card")
        #expect(draft.snapshots == [[1, 2]])
    }

    /// Scrolled back up, the new capture draws only the top bars; the tab bar under note 1 still
    /// comes from note 1's capture.
    @Test func aScrollUpThatChangesOnlyTheTabBarIsStitched() throws {
        var draft = Draft()
        try draft.addNote(on: GrowthScreen(segment: .length, scrollOffset: 100), label: "Insights")
        try draft.addNote(on: GrowthScreen(segment: .length, selectsInsights: true), identifier: "sleep.card")
        #expect(draft.snapshots == [[1, 2]])
    }

    /// A note on a changed tab bar, scrolled back up, starts a new snapshot.
    ///
    /// Stitched, the snapshot would take the tab bar from the earlier capture scrolled lower and
    /// draw note 2 over the bar's old state. Note 1, whose card looks identical in the new capture,
    /// moves onto it.
    @Test func aScrollUpWithANoteOnAChangedTabBarStartsANewSnapshot() throws {
        var draft = Draft()
        try draft.addNote(on: GrowthScreen(segment: .length, scrollOffset: 100), identifier: "sleep.card")
        let note = try draft.addNote(on: GrowthScreen(segment: .length, selectsInsights: true), label: "Insights")
        let captures = try #require(draft.screens.first?.captures)
        #expect(captures.map(\.group) == [0, 1])
        #expect(draft.captureID(of: note) == captures.last?.id)
        #expect(draft.snapshots == [[1, 2]])
    }

    @Test func aScrollUpWithANoteOnAnUnchangedTabBarIsStitched() throws {
        var draft = Draft()
        try draft.addNote(on: GrowthScreen(segment: .length, scrollOffset: 100), identifier: "sleep.card")
        try draft.addNote(on: GrowthScreen(segment: .length), label: "Insights")
        #expect(draft.screens.first?.captures.map(\.group) == [0, 0])
        #expect(draft.snapshots == [[1, 2]])
    }

    /// On a 3x phone, layout moves by thirds of a point, which a 2x capture shows as two thirds of
    /// a pixel.
    @Test(arguments: [1.0 / 3, 2.0 / 3, 1.5])
    func anElementThatMovedALittleStillSharesItsSnapshot(by distance: Double) throws {
        var draft = Draft()
        try draft.addNote(on: GrowthScreen(segment: .weight), identifier: "growth.card")
        try draft.addNote(on: GrowthScreen(segment: .weight, scrollOffset: distance), identifier: "growth.card")
        #expect(draft.snapshots == [[1, 2]])
        // The screen's snapshot is reused, not replaced.
        #expect(draft.screens.first?.captures.count == 1)
    }

    @Test func anEarlierNoteMovedByAThirdOfAPointMovesOntoTheNewSnapshot() throws {
        // The banner replaces the screen's snapshot; the card under it only moved.
        var draft = Draft()
        try draft.addNote(on: GrowthScreen(segment: .weight), identifier: "growth.card")
        try draft.addNote(
            on: GrowthScreen(segment: .weight, showsBanner: true, scrollOffset: 1.0 / 3),
            label: "Back up your data"
        )
        #expect(draft.snapshots == [[1, 2]])
        #expect(draft.screens.first?.captures.count == 2)
    }

    // MARK: - What counts as a new state

    @Test func aColorChangeAtTheSameBrightnessIsANewState() throws {
        var draft = Draft()
        try draft.addNote(on: GrowthScreen(segment: .weight), identifier: "growth.card")
        try draft.addNote(
            on: GrowthScreen(segment: .weight, iconColor: (red: 0.1, green: 0.56, blue: 0.6)),
            identifier: "growth.card"
        )
        #expect(draft.snapshots == [[1], [2]])
    }

    @Test func aTurningSpinnerInsideTheElementIsNotANewState() throws {
        var draft = Draft()
        try draft.addNote(on: GrowthScreen(segment: .length, spinnerPhase: 0), identifier: "growth.card")
        try draft.addNote(on: GrowthScreen(segment: .length, spinnerPhase: 3), identifier: "growth.card")
        #expect(draft.snapshots == [[1, 2]])
    }

    @Test func aLiveElementThatChangesSizeIsNotANewState() throws {
        // A note on the spinner itself, which widens between captures, like a timer going from
        // 9:59 to 10:00.
        let first = GrowthScreen(segment: .length, spinnerPhase: 0)
        let later = GrowthScreen(segment: .length, spinnerPhase: 3)
        var widened = capture(later)
        let index = try #require(widened.elements.firstIndex { $0.updatesFrequently == true })
        widened.elements[index].frame.size.width += 4
        #expect(
            CaptureMerge.looksIdentical(
                GrowthScreen.spinner,
                in: try first.image(),
                of: capture(first),
                as: widened.elements[index].frame,
                in: try later.image(),
                of: widened
            )
        )
    }

    /// A caret isn't an element, so it can't be told from a changed character.
    ///
    /// The note keeps the snapshot it was made on: an extra snapshot costs less than a note shown on
    /// the wrong state.
    @Test func aBlinkingCaretInsideTheElementKeepsEachNoteOnItsOwnSnapshot() throws {
        var draft = Draft()
        try draft.addNote(on: GrowthScreen(segment: .length), identifier: "growth.card")
        try draft.addNote(on: GrowthScreen(segment: .length, showsCaret: true), identifier: "growth.card")
        try draft.addNote(on: GrowthScreen(segment: .length, showsCaret: true), label: "Add")
        #expect(draft.snapshots == [[1], [2, 3]])
    }

    private func capture(_ state: GrowthScreen) -> Capture {
        Capture(
            id: UUID(),
            file: "capture.png",
            size: GrowthScreen.size,
            scroll: nil,
            elements: state.elements,
            group: 0
        )
    }
}
#endif
