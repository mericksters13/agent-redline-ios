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
        #expect(Annotation.title(kind: .photo, element: nil, screen: nil, snapshotCount: 1) == "Snapshot from Photos")
        #expect(
            Annotation.title(kind: .photo, element: nil, screen: nil, snapshotCount: 3) == "3 snapshots from Photos"
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
        #expect(loaded.map(\.screenshots) == [["a.png"], ["b.png"]])
        #expect(loaded.allSatisfy { $0.ancestors.isEmpty })
    }
}
#endif
