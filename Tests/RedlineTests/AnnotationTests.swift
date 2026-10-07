#if REDLINE
import Foundation
import Testing
@testable import Redline

struct AnnotationTests {
    private let button = ElementSnapshot(
        role: "Button",
        label: "Save",
        value: nil,
        identifier: nil,
        className: nil,
        isContainer: false,
        frame: .zero
    )
    private let today = ScreenInfo(title: "Today", viewController: "Home")

    @Test func eachKindHasItsOwnTitle() {
        #expect(Annotation.title(kind: .element, element: button, screen: today, snapshotCount: 0) == "Save")
        let unnamed = ElementSnapshot(
            role: "Image",
            label: nil,
            value: nil,
            identifier: nil,
            className: nil,
            isContainer: false,
            frame: .zero
        )
        #expect(Annotation.title(kind: .element, element: unnamed, screen: today, snapshotCount: 0) == "Image")
        #expect(Annotation.title(kind: .screen, element: nil, screen: today, snapshotCount: 1) == "Today")
        #expect(Annotation.title(kind: .screen, element: nil, screen: nil, snapshotCount: 1) == "This screen")
        #expect(Annotation.title(kind: .photo, element: nil, screen: nil, snapshotCount: 1) == "Photo")
        #expect(
            Annotation.title(kind: .photo, element: nil, screen: nil, snapshotCount: 3) == "3 photos"
        )
    }

    @Test func theSubtitleSaysWhatKindOfItemItIs() {
        #expect(Annotation.subtitle(kind: .element, element: button, screen: today) == "Button · Today")
        #expect(Annotation.subtitle(kind: .screen, element: nil, screen: today) == "Whole screen")
        #expect(Annotation.subtitle(kind: .photo, element: nil, screen: nil) == "Attachment")
    }

    @Test func aDraftWithoutKindsTakesThemFromItsElements() throws {
        let legacy = """
            [{"id":"8FAD57B3-BD1A-4853-B238-DB8A7A6ED1AC","createdAt":"2026-10-02T23:59:39Z","note":"",
              "element":{"role":"Button","label":"Save","isContainer":false,"frame":[[1,2],[3,4]]},"screenshot":"a.png"},
             {"id":"9FAD57B3-BD1A-4853-B238-DB8A7A6ED1AC","createdAt":"2026-10-02T23:59:40Z","note":"","screenshot":"b.png"}]
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = try decoder.decode([Annotation].self, from: Data(legacy.utf8))
        #expect(loaded.map(\.kind) == [.element, .screen])
        #expect(loaded.map(\.attachments) == [["a.png"], ["b.png"]])
        #expect(loaded.allSatisfy { $0.ancestors.isEmpty })
    }

    private func named(_ role: String, label: String? = nil, identifier: String? = nil) -> ElementSnapshot {
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

    @Test func aDrawingIsNamedAfterWhatItEncloses() {
        func title(_ encloses: [ElementSnapshot], count: Int? = nil) -> String {
            Annotation.title(
                kind: .drawing,
                element: nil,
                screen: today,
                snapshotCount: 1,
                encloses: encloses,
                enclosedCount: count ?? encloses.count
            )
        }
        #expect(title([]) == "Drawing")
        #expect(title([button]) == "Drawing around Save")
        let card = named("Group", identifier: "growth.card")
        #expect(title([card, button, named("Text", label: "Growth")]) == "Drawing around growth.card and 2 more")
        #expect(title([card], count: 14) == "Drawing around growth.card and 13 more")
        // A group named only by what it holds reads "… and 2 more" already, so the count says it.
        var unnamed = named("Group")
        unnamed.contents = ["Growth", "Add", "Weight"]
        unnamed.contentCount = 3
        #expect(title([unnamed]) == "Drawing around 1 element")
        #expect(Annotation.subtitle(kind: .drawing, element: nil, screen: today) == "Drawing · Today")
    }

    @Test func aDrawingKeepsItsStrokesAndWhatItEncloses() throws {
        let drawing = Annotation(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_791_000_000),
            note: "Too cramped",
            kind: .drawing,
            element: nil,
            ancestors: [],
            screen: today,
            attachments: [],
            captureID: UUID(),
            strokes: [[CGPoint(x: 10, y: 20), CGPoint(x: 30, y: 40)], [CGPoint(x: 5, y: 5), CGPoint(x: 6, y: 50)]],
            encloses: [button],
            enclosedCount: 15
        )
        let decoded = try JSONDecoder().decode(Annotation.self, from: JSONEncoder().encode(drawing))
        #expect(decoded == drawing)
        #expect(drawing.frame == CGRect(x: 3, y: 3, width: 29, height: 49))
    }

    @Test func otherItemsAreSavedAsBefore() throws {
        let note = Annotation(
            id: UUID(),
            createdAt: .now,
            note: "",
            kind: .element,
            element: button,
            ancestors: [],
            screen: today,
            attachments: [],
            captureID: UUID()
        )
        let json = try #require(String(data: JSONEncoder().encode(note), encoding: .utf8))
        #expect(!json.contains("strokes") && !json.contains("encloses") && !json.contains("enclosedCount"))
        #expect(note.frame == button.frame)
        #expect(Annotation.bounds(of: []) == nil)
        // A straight line still has an area.
        #expect(Annotation.bounds(of: [[CGPoint(x: 0, y: 10), CGPoint(x: 100, y: 10)]])?.height == 4)
    }

    @Test func aDrawingKeepsTheFirstTwelveOfWhatItEnclosesAndHowManyThereAre() {
        let enclosed = (1...15).map { named("Button", label: "Item \($0)") }
        func drawing(enclosing: [ElementSnapshot]) -> Annotation {
            .drawing(
                id: UUID(),
                note: "Too cramped",
                strokes: [[CGPoint(x: 0, y: 0), CGPoint(x: 9, y: 9)]],
                enclosing: enclosing,
                heldBy: [named("Group", identifier: "growth.card")],
                screen: today,
                captureID: UUID()
            )
        }
        let many = drawing(enclosing: enclosed)
        #expect(many.kind == .drawing)
        #expect(many.encloses == Array(enclosed.prefix(ElementSelection.enclosedLimit)))
        #expect(many.enclosedCount == 15)
        let item = Report.Item(many, number: 4)
        #expect(item.number == 4)
        #expect(item.title == "Drawing around Item 1 and 14 more")
        #expect(item.encloses == many.encloses)
        #expect(item.enclosedCount == 15)
        #expect(item.ancestors == [named("Group", identifier: "growth.card")])
        // Everything it encloses is listed, so the report leaves the count out.
        let few = Report.Item(drawing(enclosing: Array(enclosed.prefix(3))), number: 1)
        #expect(few.encloses?.count == 3)
        #expect(few.enclosedCount == nil)
        // Nothing named inside is an empty list, not a missing one: the Mac says so.
        #expect(Report.Item(drawing(enclosing: []), number: 1).encloses == [])
    }

    @Test func anElementNoteEnclosesNothingInTheReport() {
        let note = Annotation(
            id: UUID(),
            createdAt: .now,
            note: "",
            kind: .element,
            element: button,
            ancestors: [],
            screen: today,
            attachments: [],
            captureID: UUID()
        )
        let item = Report.Item(note, number: 2)
        #expect(item.title == "Save")
        #expect(item.encloses == nil)
        #expect(item.enclosedCount == nil)
    }

    @Test func eachStrokeMovesWholeByItsOwnBox() {
        // Strokes whose box is low move down 50; one far right is left out.
        let high = [CGPoint(x: 10, y: 10), CGPoint(x: 40, y: 30)]
        let low = [CGPoint(x: 10, y: 90), CGPoint(x: 40, y: 140)]
        let right = [CGPoint(x: 310, y: 10), CGPoint(x: 340, y: 30)]
        let placed = Annotation.strokes([high, low, right]) { box in
            box.midX > 300 ? nil : box.offsetBy(dx: 0, dy: box.midY > 100 ? 50 : 0)
        }
        #expect(placed == [high, [CGPoint(x: 10, y: 140), CGPoint(x: 40, y: 190)]])
    }

    @Test func aNotesAreasAreItsElementOrEachStroke() {
        #expect(Annotation.areas(element: button, strokes: []) == [button.frame])
        let strokes = [
            [CGPoint(x: 10, y: 10), CGPoint(x: 40, y: 30)], [CGPoint(x: 10, y: 90), CGPoint(x: 40, y: 140)],
        ]
        #expect(
            Annotation.areas(element: nil, strokes: strokes) == [
                CGRect(x: 8, y: 8, width: 34, height: 24), CGRect(x: 8, y: 88, width: 34, height: 54),
            ]
        )
    }

    @Test func aThumbnailShowsAnElementsLeadingEndAndAllOfADrawing() {
        let screen = CGSize(width: 402, height: 874)
        func area(_ frame: CGRect, drawing: Bool) -> CGRect {
            Annotation.thumbnailArea(around: frame, isDrawing: drawing, on: screen)
        }
        // A wide row: the square at its leading end.
        let row = CGRect(x: 20, y: 100, width: 362, height: 60)
        #expect(area(row, drawing: false) == CGRect(x: 8, y: 88, width: 84, height: 84))
        // An underline: a square around all of it.
        let underline = CGRect(x: 40, y: 500, width: 300, height: 10)
        #expect(area(underline, drawing: true) == CGRect(x: 28, y: 343, width: 324, height: 324))
        // Near a corner: moved inside the screen, still holding the drawing.
        let corner = CGRect(x: 300, y: 20, width: 100, height: 40)
        #expect(area(corner, drawing: true) == CGRect(x: 278, y: 0, width: 124, height: 124))
        #expect(area(corner, drawing: true).contains(corner))
        // Taller than the screen is wide: past both sides, centered on the screen.
        let tall = CGRect(x: 60, y: 100, width: 200, height: 600)
        #expect(area(tall, drawing: true) == CGRect(x: -111, y: 88, width: 624, height: 624))
    }

    @Test func strokesMoveWithTheirBox() {
        let strokes = [[CGPoint(x: 10, y: 20), CGPoint(x: 30, y: 40)], [CGPoint(x: 12, y: 22)]]
        let box = CGRect(x: 8, y: 18, width: 24, height: 24)
        #expect(
            Annotation.strokes(strokes, from: box, to: box.offsetBy(dx: 0, dy: 100)) == [
                [CGPoint(x: 10, y: 120), CGPoint(x: 30, y: 140)], [CGPoint(x: 12, y: 122)],
            ]
        )
    }

    /// A kit from before drawings reads one as a whole-screen item rather than failing on the draft.
    @Test func aDrawingStillReadsWithoutItsKind() throws {
        let drawing = Annotation(
            id: UUID(),
            createdAt: .now,
            note: "",
            kind: .drawing,
            element: nil,
            ancestors: [],
            screen: today,
            attachments: [],
            captureID: UUID(),
            strokes: [[CGPoint(x: 1, y: 1), CGPoint(x: 9, y: 9)]]
        )
        let json = try #require(String(data: JSONEncoder().encode(drawing), encoding: .utf8))
        let unknown = json.replacingOccurrences(of: "\"drawing\"", with: "\"somethingNewer\"")
        let decoded = try JSONDecoder().decode(Annotation.self, from: Data(unknown.utf8))
        #expect(decoded.kind == .screen)
        #expect(decoded.captureID == drawing.captureID)
    }
}
#endif
