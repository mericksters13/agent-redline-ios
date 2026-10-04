#if REDLINE
import CoreGraphics
import CoreText
import Foundation
@testable import Redline

/// Shared test data.
enum Fixtures {
    /// The image files of `report(id:)`, named as the kit names them: the screen's two parts, then
    /// the two photos.
    static let snapshotFiles = [
        "3F2B8C1A-6D4E-4A57-9B0C-1E2D3F4A5B6C.jpg",
        "A7C1D2E3-4F50-4617-8293-A4B5C6D7E8F9.jpg",
        "0E9D8C7B-6A59-4837-A261-5F4E3D2C1B0A.jpg",
        "C4B3A291-8070-4F6E-9D5C-4B3A29180706.jpg",
    ]

    /// A sent report: two notes on a stitched screen sent in two parts, and two photos.
    static func report(id: String) -> Report {
        let element = ElementSnapshot(
            role: "Button",
            label: "Save",
            value: nil,
            identifier: "save",
            className: nil,
            isContainer: false,
            frame: CGRect(x: 1, y: 2, width: 3, height: 4)
        )
        func item(_ number: Int, _ note: String, snapshot: String) -> Report.Item {
            Report.Item(
                number: number,
                kind: .element,
                note: note,
                createdAt: Date(timeIntervalSince1970: 1_790_000_000),
                title: "Save",
                element: element,
                ancestors: [],
                screen: "screen-1",
                screenTitle: "Today",
                snapshot: snapshot,
                outline: Report.Box(x: 10, y: 20, width: 30, height: 40),
                attachments: []
            )
        }
        return Report(
            id: id,
            createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            app: Report.App(bundleID: "com.example.app", name: "Example", version: "1.0", build: "1"),
            device: Report.Device(model: "iPhone18,1", systemName: "iOS", systemVersion: "27.0"),
            screens: [
                Report.Screen(
                    id: "screen-1",
                    title: "Today",
                    viewController: "Home",
                    notes: [1, 2],
                    snapshots: [
                        Report.Snapshot(
                            file: snapshotFiles[0],
                            part: 1,
                            parts: 2,
                            stitchedFrom: 2,
                            isEarlierState: false,
                            notes: [1, 2],
                            width: 563,
                            height: 1224
                        ),
                        Report.Snapshot(
                            file: snapshotFiles[1],
                            part: 2,
                            parts: 2,
                            stitchedFrom: 2,
                            isEarlierState: false,
                            notes: [2],
                            width: 563,
                            height: 700
                        ),
                    ]
                )
            ],
            items: [
                item(1, "Cut off", snapshot: snapshotFiles[0]),
                item(2, "Too faint", snapshot: snapshotFiles[1]),
                Report.Item(
                    number: 3,
                    kind: .photo,
                    note: "Same bug",
                    createdAt: Date(timeIntervalSince1970: 1_790_000_000),
                    title: "2 snapshots from Photos",
                    element: nil,
                    ancestors: [],
                    screen: nil,
                    screenTitle: nil,
                    snapshot: nil,
                    outline: nil,
                    attachments: [snapshotFiles[2], snapshotFiles[3]]
                ),
            ]
        )
    }
}

/// A synthetic capture of Tiny Tally's Patterns screen, drawn the way the kit captures screens (at
/// 2x, in color, dark mode): a growth card with a Weight, Length and Head segment control, a sleep
/// card under it, and a tab bar.
///
/// Drawn with Core Graphics and Core Text, so the tests run on the Mac.
struct GrowthScreen {
    enum Segment: Int, CaseIterable {
        case weight, length, head

        var title: String { ["Weight", "Length", "Head"][rawValue] }
    }

    var segment = Segment.weight
    /// A dimmed backdrop over the whole screen with a popup card in its middle, like a sheet or an
    /// alert.
    var showsPopup = false
    /// A banner across the top of the screen, which changes the screen around the card.
    var showsBanner = false
    /// Moves every label by a fraction of a pixel, which changes only how its edges are smoothed.
    var textOffset: CGFloat = 0
    var weightText = "4.1 kg"
    var countText = "3"

    static let size = CGSize(width: 393, height: 852)
    static let scale: CGFloat = 2

    static let card = CGRect(x: 20, y: 156, width: 362, height: 295)
    static let chart = CGRect(x: 36, y: 330, width: 330, height: 90)
    static let sleepCard = CGRect(x: 20, y: 520, width: 362, height: 200)
    static let popupButton = CGRect(x: 80, y: 420, width: 233, height: 50)
    static let banner = CGRect(x: 0, y: 50, width: 393, height: 96)

    /// What the accessibility tree reads in this state.
    var elements: [ElementSnapshot] {
        func element(_ role: String, _ label: String?, _ identifier: String?, _ frame: CGRect, container: Bool = false)
            -> ElementSnapshot
        {
            ElementSnapshot(
                role: role,
                label: label,
                value: nil,
                identifier: identifier,
                className: "AccessibilityNode",
                isContainer: container,
                frame: frame
            )
        }
        var list = [
            element("Group", nil, "growth.card", Self.card, container: true),
            element("Text", "Growth", nil, CGRect(x: 92, y: 186, width: 80, height: 24)),
            element("Button", "Add", nil, CGRect(x: 300, y: 176, width: 66, height: 44)),
            element("Button", "Weight", nil, segmentFrame(.weight)),
            element("Button", "Length", nil, segmentFrame(.length)),
            element("Button", "Head", nil, segmentFrame(.head)),
            element("Button", "All measurements", nil, CGRect(x: 36, y: 420, width: 330, height: 24)),
            element("Header", "Patterns", nil, CGRect(x: 20, y: 476, width: 120, height: 30)),
            element("Group", nil, "sleep.card", Self.sleepCard, container: true),
            element("Button", "Insights", nil, CGRect(x: 160, y: 780, width: 80, height: 50)),
        ]
        switch segment {
        case .weight:
            list.append(element("Group", "Weight in kg by age", "growth.card.chart", Self.chart, container: true))
        case .length, .head: list.append(element("Text", emptyText, nil, CGRect(x: 36, y: 340, width: 300, height: 20)))
        }
        if showsPopup { list.append(element("Button", "Keep editing", nil, Self.popupButton)) }
        if showsBanner { list.append(element("Button", "Back up your data", nil, Self.banner)) }
        return list
    }

    private var emptyText: String { "No \(segment.title.lowercased()) measured yet." }

    private func segmentFrame(_ segment: Segment) -> CGRect {
        CGRect(x: 38 + CGFloat(segment.rawValue) * 110, y: 238, width: 106, height: 32)
    }

    /// The capture, 786 by 1704 pixels.
    func image() throws -> CGImage {
        let width = Int(Self.size.width * Self.scale)
        let height = Int(Self.size.height * Self.scale)
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { throw DrawingError() }
        // Points from the top left, as UIKit lays out.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: Self.scale, y: -Self.scale)

        fill(context, CGRect(origin: .zero, size: Self.size), gray: 0.07)
        text(context, "Athena", at: CGPoint(x: 90, y: 110), size: 22, gray: 1)
        text(context, "1 month, 14 days", at: CGPoint(x: 90, y: 134), size: 15, gray: 0.6)

        fill(context, Self.card, gray: 0.17, radius: 24)
        fill(context, CGRect(x: 36, y: 176, width: 44, height: 44), red: 0.8, green: 0.45, blue: 0.2, radius: 10)
        text(context, "Growth", at: CGPoint(x: 92, y: 206), size: 20, gray: 1)
        fill(context, CGRect(x: 300, y: 176, width: 66, height: 44), gray: 0.25, radius: 22)
        text(context, "+ Add", at: CGPoint(x: 312, y: 204), size: 16, red: 0.7, green: 0.65, blue: 1)
        fill(context, CGRect(x: 36, y: 236, width: 330, height: 36), gray: 0.24, radius: 18)
        fill(context, segmentFrame(segment), gray: 0.36, radius: 16)
        for each in Segment.allCases {
            text(context, each.title, at: CGPoint(x: segmentFrame(each).minX + 26, y: 260), size: 16, gray: 1)
        }
        switch segment {
        case .weight:
            text(context, weightText, at: CGPoint(x: 36, y: 316), size: 30, red: 0.7, green: 0.65, blue: 1)
            context.setStrokeColor(red: 0.7, green: 0.65, blue: 1, alpha: 1)
            context.setLineWidth(2)
            context.move(to: CGPoint(x: 50, y: 410))
            context.addCurve(
                to: CGPoint(x: 340, y: 345),
                control1: CGPoint(x: 120, y: 360),
                control2: CGPoint(x: 220, y: 345)
            )
            context.strokePath()
        case .length, .head:
            text(context, emptyText, at: CGPoint(x: 36, y: 355), size: 15, gray: 0.75)
        }
        text(context, "All measurements", at: CGPoint(x: 36, y: 438), size: 17, red: 0.7, green: 0.65, blue: 1)
        text(context, countText, at: CGPoint(x: 340, y: 438), size: 17, gray: 0.6)

        text(context, "Patterns", at: CGPoint(x: 20, y: 500), size: 22, gray: 1)
        fill(context, Self.sleepCard, gray: 0.17, radius: 24)
        text(context, "Sleep", at: CGPoint(x: 92, y: 560), size: 20, gray: 1)
        text(context, "0m      0m      0", at: CGPoint(x: 36, y: 620), size: 20, gray: 1)
        text(context, "Total   Longest   Sessions", at: CGPoint(x: 36, y: 646), size: 15, gray: 0.6)

        fill(context, CGRect(x: 30, y: 770, width: 333, height: 64), gray: 0.2, radius: 32)
        text(context, "Today   History   Insights   Settings", at: CGPoint(x: 52, y: 810), size: 13, gray: 1)

        if showsBanner {
            fill(context, Self.banner, red: 0.95, green: 0.85, blue: 0.4)
            text(context, "Back up your data", at: CGPoint(x: 24, y: 106), size: 22, gray: 0)
        }
        if showsPopup {
            fill(context, CGRect(origin: .zero, size: Self.size), gray: 0, alpha: 0.4)
            fill(context, CGRect(x: 40, y: 300, width: 313, height: 200), gray: 0.22, radius: 20)
            text(context, "Discard this measurement?", at: CGPoint(x: 70, y: 360), size: 17, gray: 1)
            fill(context, Self.popupButton, gray: 0.35, radius: 25)
            text(context, "Keep editing", at: CGPoint(x: 150, y: 450), size: 16, gray: 1)
        }
        guard let image = context.makeImage() else { throw DrawingError() }
        return image
    }

    struct DrawingError: Error {}

    private func fill(_ context: CGContext, _ rect: CGRect, gray: CGFloat, alpha: CGFloat = 1, radius: CGFloat = 0) {
        fill(context, rect, red: gray, green: gray, blue: gray, alpha: alpha, radius: radius)
    }

    private func fill(
        _ context: CGContext,
        _ rect: CGRect,
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat,
        alpha: CGFloat = 1,
        radius: CGFloat = 0
    ) {
        context.setFillColor(red: red, green: green, blue: blue, alpha: alpha)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
    }

    private func text(_ context: CGContext, _ string: String, at baseline: CGPoint, size: CGFloat, gray: CGFloat) {
        text(context, string, at: baseline, size: size, red: gray, green: gray, blue: gray)
    }

    private func text(
        _ context: CGContext,
        _ string: String,
        at baseline: CGPoint,
        size: CGFloat,
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat
    ) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let color = CGColor(red: red, green: green, blue: blue, alpha: 1)
        let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color] as CFDictionary
        guard let attributed = CFAttributedStringCreate(nil, string as CFString, attributes) else { return }
        let line = CTLineCreateWithAttributedString(attributed)
        context.saveGState()
        // Core Text draws upward; flip back around the baseline.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: baseline.x + textOffset / Self.scale, y: baseline.y)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
#endif
