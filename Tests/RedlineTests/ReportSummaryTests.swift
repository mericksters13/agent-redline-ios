#if REDLINE
import Foundation
import Testing
@testable import Redline

struct ReportSummaryTests {
    @Test func aSentReportIsSummedUpForTheList() {
        let report = Fixtures.report(id: "r")
        #expect(report.screenNames == "Today")
        #expect(report.contents == "3 notes, 1 screen")
        var attachmentsOnly = report
        attachmentsOnly.screens = []
        attachmentsOnly.items = [report.items[2]]
        #expect(attachmentsOnly.screenNames == "Attachment")
        #expect(attachmentsOnly.contents == "1 note")
    }

    @Test func theSummaryTellsTheAgentWhichPictureShowsEachNote() {
        let text = ReportSummary.markdown(Fixtures.report(id: "r"))
        #expect(text.contains("## Screen: Today"))
        #expect(
            text.contains(
                "One screenshot of this screen, stitched from 2 scroll positions, in 2 parts: screen-1.jpg, screen-1-part-2.jpg."
            )
        )
        #expect(text.contains("Notes 1 and 2 are outlined and numbered on it."))
        #expect(text.contains("1. **Save** (Button, identifier `save`): Cut off. See screen-1.jpg."))
        #expect(text.contains("## Attachments"))
        #expect(text.contains("3. **2 images from Photos**: Same bug. Images: note-3-1.jpg, note-3-2.jpg."))
    }

    @Test func anEarlierStateAndContentScrolledPastAreExplained() {
        var report = Fixtures.report(id: "r")
        report.screens[0].images[0].scrolledPast = 786
        report.screens[0].images.append(
            Report.Picture(
                file: "screen-1-earlier-1.jpg",
                part: 1,
                parts: 1,
                stitchedFrom: 1,
                isEarlierState: true,
                notes: [3],
                width: 563,
                height: 1224
            )
        )
        let text = ReportSummary.markdown(report)
        #expect(
            text.contains("about 786 pt of the screen between them wasn't captured and is marked \"Scrolled past\"")
        )
        #expect(
            text.contains(
                "An earlier state of the same screen, before its content changed: screen-1-earlier-1.jpg, with note 3."
            )
        )
    }

    @Test func threeOrMoreNotesAreListedWithAnd() {
        var report = Fixtures.report(id: "r")
        report.screens[0].images[0].notes = [1, 2, 3]
        report.screens[0].images.removeLast()
        #expect(ReportSummary.markdown(report).contains("Notes 1, 2 and 3 are outlined and numbered on it."))
    }

    @Test func aLabelThatIsntTheTitleIsGivenToo() {
        var report = Fixtures.report(id: "r")
        report.items[0].title = "Save changes"
        #expect(
            ReportSummary.markdown(report).contains(
                #"1. **Save changes** (Button, identifier `save`, label "Save"): Cut off."#
            )
        )
    }

    @Test func theElementsHoldingANoteAreNamed() {
        func container(_ role: String, label: String?, identifier: String?) -> ElementSnapshot {
            ElementSnapshot(
                role: role,
                label: label,
                value: nil,
                identifier: identifier,
                className: nil,
                isContainer: true,
                frame: .zero
            )
        }
        var report = Fixtures.report(id: "r")
        // Unnamed holders don't help find the code, so they're left out.
        report.items[0].ancestors = [
            container("Cell", label: "Milestones", identifier: "today.row"),
            container("Group", label: nil, identifier: nil),
            container("List", label: nil, identifier: "today.list"),
        ]
        #expect(
            ReportSummary.markdown(report).contains(
                #"1. **Save** (Button, identifier `save`), in Cell "Milestones" `today.row` in List `today.list`: Cut off. See screen-1.jpg."#
            )
        )
    }
}
#endif
