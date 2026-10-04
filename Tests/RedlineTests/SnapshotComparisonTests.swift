#if REDLINE
import CoreGraphics
import Testing
@testable import Redline

struct SnapshotComparisonTests {
    /// A 400 by 800 snapshot: white, with dark bars at the given heights, measured from the bottom
    /// as Core Graphics draws.
    ///
    /// Pixel rows count from the top.
    private func snapshot(bars: [Int], barHeight: Int = 40, mark: CGRect? = nil, markGray: CGFloat = 0.1) throws
        -> CGImage
    {
        let context = try #require(
            CGContext(
                data: nil,
                width: 400,
                height: 800,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
        )
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 800))
        context.setFillColor(gray: 0.1, alpha: 1)
        for y in bars { context.fill(CGRect(x: 20, y: y, width: 360, height: barHeight)) }
        if let mark {
            context.setFillColor(gray: markGray, alpha: 1)
            context.fill(mark)
        }
        return try #require(context.makeImage())
    }

    @Test func identicalSnapshotsMatch() throws {
        let a = try snapshot(bars: [100, 300, 500])
        #expect(SnapshotComparison.difference(a, a) == 0)
    }

    @Test func aTinyChangeStillCountsAsTheSameSnapshot() throws {
        // A small mark, about the size of a clock's last digit changing.
        let a = try snapshot(bars: [100, 300, 500])
        let b = try snapshot(bars: [100, 300, 500], mark: CGRect(x: 340, y: 770, width: 16, height: 20))
        #expect(SnapshotComparison.difference(a, b) < SnapshotComparison.sameSnapshot)
    }

    @Test func movedContentIsADifferentSnapshot() throws {
        let a = try snapshot(bars: [100, 300, 500])
        let b = try snapshot(bars: [160, 360, 560])
        #expect(SnapshotComparison.difference(a, b) > SnapshotComparison.sameSnapshot)
    }

    @Test func anElementCoveredByAPopupNoLongerLooksTheSame() throws {
        let plain = try snapshot(bars: [300, 500, 700])
        // A white popup card over the middle of the screen, covering the bar drawn at 500.
        let withPopup = try snapshot(
            bars: [300, 500, 700],
            mark: CGRect(x: 0, y: 420, width: 400, height: 200),
            markGray: 1
        )
        // Pixel rows count from the top: the bar drawn at 500 sits in rows 260..<300, the one at 700 in 60..<100.
        let covered = CGRect(x: 20, y: 260, width: 360, height: 40)
        let clear = CGRect(x: 20, y: 60, width: 360, height: 40)
        #expect(SnapshotComparison.differingPixels(plain, in: clear, withPopup, in: clear) == 0)
        #expect(
            SnapshotComparison.differingPixels(plain, in: covered, withPopup, in: covered)
                > SnapshotComparison.sameElementPixels
        )
    }

    // MARK: - Elements

    /// The growth card's frame in a capture's pixels.
    private let card = CGRect(
        x: GrowthScreen.card.minX * GrowthScreen.scale,
        y: GrowthScreen.card.minY * GrowthScreen.scale,
        width: GrowthScreen.card.width * GrowthScreen.scale,
        height: GrowthScreen.card.height * GrowthScreen.scale
    )

    private let sleepCard = CGRect(
        x: GrowthScreen.sleepCard.minX * GrowthScreen.scale,
        y: GrowthScreen.sleepCard.minY * GrowthScreen.scale,
        width: GrowthScreen.sleepCard.width * GrowthScreen.scale,
        height: GrowthScreen.sleepCard.height * GrowthScreen.scale
    )

    @Test func aSegmentSwitchChangesTheCard() throws {
        // About 25,000 of the card's 427,000 pixels; the old small copy saw 5%.
        let length = try GrowthScreen(segment: .length).image()
        let head = try GrowthScreen(segment: .head).image()
        #expect(SnapshotComparison.differingPixels(length, in: card, head, in: card) > 20_000)
    }

    @Test func aChangedLabelOrChartChangesTheCard() throws {
        let weight = try GrowthScreen(segment: .weight).image()
        // A chart replaced by a message: about 31,000 pixels.
        let length = try GrowthScreen(segment: .length).image()
        #expect(SnapshotComparison.differingPixels(weight, in: card, length, in: card) > 20_000)
        // "4.1 kg" to "4.2 kg": about 700.
        let heavier = try GrowthScreen(segment: .weight, weightText: "4.2 kg").image()
        #expect(SnapshotComparison.differingPixels(weight, in: card, heavier, in: card) > 500)
        // One digit of a 17 pt count, 3 to 8, the smallest change tried: about 35.
        let count = try GrowthScreen(segment: .weight, countText: "8").image()
        #expect(
            SnapshotComparison.differingPixels(weight, in: card, count, in: card) > SnapshotComparison.sameElementPixels
        )
    }

    @Test func anUnchangedElementLooksIdentical() throws {
        let weight = try GrowthScreen(segment: .weight).image()
        #expect(
            SnapshotComparison.differingPixels(weight, in: card, try GrowthScreen(segment: .weight).image(), in: card)
                == 0
        )
        // The sleep card under the growth card doesn't change with its segment.
        let length = try GrowthScreen(segment: .length).image()
        #expect(SnapshotComparison.differingPixels(weight, in: sleepCard, length, in: sleepCard) == 0)
    }

    @Test func edgesSmoothedDifferentlyStillLookIdentical() throws {
        // Every label drawn half a pixel to the side: only the smoothing of its edges changes. A
        // plain comparison at this size counts about 3,500 pixels.
        let weight = try GrowthScreen(segment: .weight).image()
        let shifted = try GrowthScreen(segment: .weight, textOffset: 0.5).image()
        #expect(
            SnapshotComparison.differingPixels(weight, in: card, shifted, in: card)
                <= SnapshotComparison.sameElementPixels
        )
        #expect(
            SnapshotComparison.differingPixels(weight, in: sleepCard, shifted, in: sleepCard)
                <= SnapshotComparison.sameElementPixels
        )
    }

    @Test func anElementUnderADimmedPopupChanges() throws {
        let weight = try GrowthScreen(segment: .weight).image()
        let popup = try GrowthScreen(segment: .weight, showsPopup: true).image()
        // Nearly every pixel, under the popup or only under its dimmed backdrop.
        #expect(SnapshotComparison.differingPixels(weight, in: card, popup, in: card) > 400_000)
        #expect(SnapshotComparison.differingPixels(weight, in: sleepCard, popup, in: sleepCard) > 250_000)
    }

    @Test func anElementThatChangedSizeChanges() throws {
        let weight = try GrowthScreen(segment: .weight).image()
        let taller = card.insetBy(dx: 0, dy: -10)
        #expect(
            SnapshotComparison.differingPixels(weight, in: card, weight, in: taller)
                > SnapshotComparison.sameElementPixels
        )
    }

    @Test func theSharedStretchOfTwoScrolledSnapshotsMatches() throws {
        // The second snapshot is the first with its content scrolled up by 200 pixels.
        let a = try snapshot(bars: [300, 500, 700])
        let b = try snapshot(bars: [500, 700])
        #expect(SnapshotComparison.difference(a, rows: 200..<800, b, rows: 0..<600) < SnapshotComparison.sameOverlap)
        #expect(SnapshotComparison.difference(a, rows: 0..<600, b, rows: 0..<600) > SnapshotComparison.sameOverlap)
    }
}
#endif
