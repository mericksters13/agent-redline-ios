#if REDLINE
import CoreGraphics
import Foundation
import XCTest
@testable import Redline

/// Measures the kit's hot paths with realistic sizes: picking runs on every drag frame, the
/// comparisons and the plan on every saved note, and the store scan on every activation.
///
/// XCTest only for `measure`, which Swift Testing doesn't have.
final class KitPerformanceTests: XCTestCase {
    private let screen = CGSize(width: 402, height: 874)

    /// Rows of buttons with labels inside, grouped in cards: about `count` elements.
    private func elements(count: Int, offsetY: CGFloat = 0) -> [ElementSnapshot] {
        (0..<count).map { index in
            let row = CGFloat(index / 4)
            let inRow = index % 4
            let frame =
                inRow == 0
                ? CGRect(x: 16, y: row * 60 - offsetY, width: 370, height: 56)
                : CGRect(x: 24 + CGFloat(inRow - 1) * 120, y: row * 60 + 8 - offsetY, width: 110, height: 40)
            return ElementSnapshot(
                role: inRow == 0 ? "Group" : "Button",
                label: "Item \(index)",
                value: nil,
                identifier: "item.\(index)",
                className: nil,
                isContainer: inRow == 0,
                frame: frame
            )
        }
    }

    /// Styled controls retain many runtime wrappers; matching must not rescan every label per control.
    func testLayoutMatchingWith4000Nodes() {
        var inspection = LayoutInspection()
        for button in 0..<200 {
            let bounds = CGRect(x: 20, y: button * 50, width: 100, height: 44)
            var parent = inspection.nodes.count
            inspection.nodes.append(
                .init(
                    type: "Button<Label<Text,Image>>",
                    settings: [],
                    parent: nil,
                    childCount: 1,
                    frame: bounds
                )
            )
            for _ in 0..<16 {
                let index = inspection.nodes.count
                inspection.nodes.append(.init(type: "StyleWrapper", settings: [], parent: parent, childCount: 1))
                parent = index
            }
            let branch = inspection.nodes.count
            inspection.nodes.append(.init(type: "HStack<Text,Image>", settings: [], parent: parent, childCount: 2))
            inspection.nodes.append(
                .init(
                    type: "Text",
                    text: "Action \(button)",
                    settings: [],
                    parent: branch,
                    childCount: 0,
                    frame: CGRect(x: 40, y: button * 50 + 12, width: 60, height: 20)
                )
            )
            inspection.nodes.append(
                .init(
                    type: "Image",
                    settings: [],
                    parent: branch,
                    childCount: 0,
                    frame: CGRect(x: 24, y: button * 50 + 12, width: 12, height: 20)
                )
            )
        }
        let selected = ElementSnapshot(
            role: "Button",
            label: "Action 199",
            value: nil,
            identifier: nil,
            className: nil,
            isContainer: false,
            frame: CGRect(x: 20, y: 9950, width: 100, height: 44)
        )
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            XCTAssertNotNil(inspection.report(selected).geometry)
        }
    }

    func testLevelsWith400Elements() {
        let all = elements(count: 400)
        let points = (0..<50).map { CGPoint(x: CGFloat($0 * 7 % 400), y: CGFloat($0 * 17 % 874)) }
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            for point in points { _ = ElementSelection.levels(at: point, in: all, screenSize: screen) }
        }
    }

    func testSnapshotComparisonOnFullCaptures() throws {
        func capture(shift: Int) throws -> CGImage {
            let context = try XCTUnwrap(
                CGContext(
                    data: nil,
                    width: 786,
                    height: 1704,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                )
            )
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 786, height: 1704))
            context.setFillColor(gray: 0.2, alpha: 1)
            for row in stride(from: 0, to: 1704, by: 120) {
                context.fill(CGRect(x: 32, y: row + shift, width: 720, height: 80))
            }
            return try XCTUnwrap(context.makeImage())
        }
        let before = try capture(shift: 0)
        let after = try capture(shift: 40)
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            _ = SnapshotComparison.difference(before, after)
            _ = SnapshotComparison.difference(before, rows: 400..<1400, after, rows: 360..<1360)
        }
    }

    /// The element check each earlier note gets when its screen's snapshot is replaced, on a
    /// full-width card: labels smoothed differently, the slowest case that still matches, and a
    /// segment switch, which stops at the first few differences.
    func testElementComparisonOnACard() throws {
        let before = try GrowthScreen(segment: .weight).image()
        let smoothed = try GrowthScreen(segment: .weight, textOffset: 0.5).image()
        let switched = try GrowthScreen(segment: .length).image()
        let card = GrowthScreen.card.applying(CGAffineTransform(scaleX: GrowthScreen.scale, y: GrowthScreen.scale))
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            _ = SnapshotComparison.differingPixels(before, in: card, smoothed, in: card, upTo: 8)
            _ = SnapshotComparison.differingPixels(before, in: card, switched, in: card, upTo: 8)
        }
    }

    /// The slowest element check that still matches, which runs when a note is saved: a
    /// full-screen element, such as a list's container, with every label smoothed differently.
    func testElementComparisonOnAFullScreenElement() throws {
        let before = try GrowthScreen(segment: .weight).image()
        let smoothed = try GrowthScreen(segment: .weight, textOffset: 0.5).image()
        let screen = CGRect(x: 0, y: 0, width: before.width, height: before.height)
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            _ = SnapshotComparison.differingPixels(before, in: screen, smoothed, in: screen, upTo: 8)
        }
    }

    func testPlanForAStitchedScreen() {
        let captures = (0..<4).map { index -> Capture in
            let offset = CGFloat(index) * 500 - 62
            let scroll = ScrollState(
                frame: CGRect(origin: .zero, size: screen),
                offsetY: offset,
                insetTop: 62,
                insetBottom: 34,
                contentHeight: 6000
            )
            return Capture(
                id: UUID(),
                file: "c\(index).png",
                size: screen,
                scroll: scroll,
                elements: elements(count: 300, offsetY: offset),
                group: 0
            )
        }
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            _ = ScreenComposition.plan(for: captures)
            _ = CaptureMerge.isScroll(from: captures[0], to: captures[1])
        }
    }

    func testUndeliveredWith200Reports() throws {
        let store = ReportStore(
            root: FileManager.default.temporaryDirectory.appending(path: "KitPerformanceTests-\(UUID().uuidString)")
        )
        defer { try? FileManager.default.removeItem(at: store.root) }
        var ids: [String] = []
        for index in 0..<200 {
            try store.saveDraft([])
            let started = try store.beginReport(date: Date(timeIntervalSince1970: 1_790_000_000 + Double(index)))
            try store.finishReport(Fixtures.report(id: started.id), in: started.folder)
            ids.append(started.id)
        }
        store.markDelivered(Array(ids.prefix(100)))
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric(), XCTStorageMetric()]) {
            XCTAssertEqual(store.undeliveredReports().count, 100)
        }
    }
}
#endif
