#if REDLINE
import Foundation
@testable import Redline

/// Shared test data.
enum Fixtures {
    /// A sent report: two notes on a stitched screen sent in two parts, and two photos.
    static func report(id: String) -> Report {
        let element = ElementSnapshot(role: "Button", label: "Save", value: nil, identifier: "save", className: nil, isContainer: false, frame: CGRect(x: 1, y: 2, width: 3, height: 4))
        func item(_ number: Int, _ note: String, picture: String) -> Report.Item {
            Report.Item(number: number, kind: .element, note: note, createdAt: Date(timeIntervalSince1970: 1_790_000_000), title: "Save",
                        element: element, ancestors: [], screen: "screen-1", screenTitle: "Today", picture: picture,
                        outline: Report.Box(x: 10, y: 20, width: 30, height: 40), attachments: [])
        }
        return Report(
            id: id,
            createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            app: Report.App(bundleID: "com.example.app", name: "Example", version: "1.0", build: "1"),
            device: Report.Device(model: "iPhone18,1", systemName: "iOS", systemVersion: "27.0"),
            screens: [Report.Screen(id: "screen-1", title: "Today", viewController: "Home", notes: [1, 2], images: [
                Report.Picture(file: "screen-1.jpg", part: 1, parts: 2, stitchedFrom: 2, isEarlierState: false, notes: [1, 2], width: 563, height: 1224),
                Report.Picture(file: "screen-1-part-2.jpg", part: 2, parts: 2, stitchedFrom: 2, isEarlierState: false, notes: [2], width: 563, height: 700),
            ])],
            items: [
                item(1, "Cut off", picture: "screen-1.jpg"),
                item(2, "Too faint", picture: "screen-1-part-2.jpg"),
                Report.Item(number: 3, kind: .photo, note: "Same bug", createdAt: Date(timeIntervalSince1970: 1_790_000_000), title: "2 images from Photos",
                            element: nil, ancestors: [], screen: nil, screenTitle: nil, picture: nil, outline: nil,
                            attachments: ["note-3-1.jpg", "note-3-2.jpg"]),
            ]
        )
    }
}
#endif
