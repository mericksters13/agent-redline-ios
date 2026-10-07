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

    @Test func theSummaryTellsTheAgentWhichSnapshotShowsEachNote() {
        let text = ReportSummary.markdown(Fixtures.report(id: "r"))
        let files = Fixtures.snapshotFiles
        #expect(text.contains("## Screen: Today"))
        #expect(
            text.contains(
                "One snapshot of this screen, stitched from 2 scroll positions, in 2 parts: \(files[0]), \(files[1])."
            )
        )
        #expect(text.contains("Notes 1 and 2 are outlined and numbered on it."))
        #expect(text.contains("1. **Save** (Button, identifier `save`): Cut off. See \(files[0])."))
        #expect(text.contains("## Attachments"))
        #expect(text.contains("3. **2 photos**: Same bug. Snapshots: \(files[2]), \(files[3])."))
    }

    @Test func anEarlierStateAndContentScrolledPastAreExplained() {
        var report = Fixtures.report(id: "r")
        let earlier = Report.makeSnapshotFileName()
        report.screens[0].snapshots[0].scrolledPast = 786
        report.screens[0].snapshots.append(
            Report.Snapshot(
                file: earlier,
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
                "An earlier state of the same screen, before its content changed: \(earlier), with note 3."
            )
        )
    }

    @Test func newSnapshotFilesAreNamedByUUID() throws {
        let name = Report.makeSnapshotFileName()
        #expect(name.hasSuffix(".jpg"))
        #expect(UUID(uuidString: String(name.dropLast(4))) != nil)
        #expect(Report.makeSnapshotFileName() != name)
    }

    @Test func threeOrMoreNotesAreListedWithAnd() {
        var report = Fixtures.report(id: "r")
        report.screens[0].snapshots[0].notes = [1, 2, 3]
        report.screens[0].snapshots.removeLast()
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
                #"1. **Save** (Button, identifier `save`), in Cell "Milestones" `today.row` in List `today.list`: Cut off. See "#
                    + "\(Fixtures.snapshotFiles[0])."
            )
        )
    }

    @Test func aGroupWithNoNameIsDescribedByWhatItHolds() {
        var card = ElementSnapshot(
            role: "Group",
            label: nil,
            value: nil,
            identifier: nil,
            className: nil,
            isContainer: true,
            frame: .zero
        )
        card.contents = ["Beyond the sky", "Tricks and bigger patterns", "Unlock the rest"]
        card.contentCount = 3
        var report = Fixtures.report(id: "r")
        report.items[0].ancestors = [card]
        #expect(
            ReportSummary.markdown(report).contains(
                #"(Button, identifier `save`), in Group "Beyond the sky" and 2 more: "#
            )
        )

        report.items[0].title = card.fullName ?? ""
        report.items[0].element = card
        report.items[0].ancestors = []
        #expect(
            ReportSummary.markdown(report).contains(
                #"1. **"Beyond the sky" and 2 more** (Group, holding "Beyond the sky", "Tricks and bigger patterns", "Unlock the rest"): Cut off."#
            )
        )
    }

    @Test func aDrawingListsWhatItEnclosesAndWhatHoldsIt() {
        func named(_ role: String, label: String? = nil, identifier: String? = nil) -> ElementSnapshot {
            ElementSnapshot(
                role: role,
                label: label,
                value: nil,
                identifier: identifier,
                className: nil,
                isContainer: role == "Group",
                frame: .zero
            )
        }
        var report = Fixtures.report(id: "r")
        report.items[0].kind = .drawing
        report.items[0].element = nil
        report.items[0].title = "Drawing around growth.card and 2 more"
        report.items[0].encloses = [
            named("Group", identifier: "growth.card"), named("Text", label: "Growth"),
            named("Button", label: "Add"),
        ]
        report.items[0].ancestors = [named("List", identifier: "patterns.list")]
        #expect(
            ReportSummary.markdown(report).contains(
                #"1. **Drawing around growth.card and 2 more**, enclosing Group `growth.card`, Text "Growth", Button "Add", in List `patterns.list`: Cut off."#
            )
        )

        report.items[0].enclosedCount = 15
        #expect(ReportSummary.markdown(report).contains(#"Button "Add" and 12 more, in List"#))

        report.items[0].encloses = []
        report.items[0].enclosedCount = nil
        report.items[0].title = "Drawing"
        #expect(ReportSummary.markdown(report).contains(#"1. **Drawing**, enclosing nothing named, in List"#))
    }

    @Test func aReportWithAKindThisKitDoesNotKnowStillReads() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = try #require(String(data: encoder.encode(Fixtures.report(id: "r")), encoding: .utf8))
        let newer = json.replacingOccurrences(of: #""kind":"element""#, with: #""kind":"somethingNewer""#)
        #expect(newer != json)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(Report.self, from: Data(newer.utf8))
        // It has an element, so it reads as an element note.
        #expect(report.items.first?.kind == .element)
    }
}
#endif
