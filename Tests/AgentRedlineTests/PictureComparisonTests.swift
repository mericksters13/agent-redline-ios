#if AGENT_REDLINE
import CoreGraphics
import Testing
@testable import AgentRedline

struct PictureComparisonTests {
    /// A 400 by 800 picture: white, with dark bars at the given heights, measured from the
    /// bottom as Core Graphics draws. Pixel rows count from the top.
    private func picture(bars: [Int], barHeight: Int = 40, mark: CGRect? = nil, markGray: CGFloat = 0.1) -> CGImage {
        let context = CGContext(data: nil, width: 400, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 800))
        context.setFillColor(gray: 0.1, alpha: 1)
        for y in bars { context.fill(CGRect(x: 20, y: y, width: 360, height: barHeight)) }
        if let mark {
            context.setFillColor(gray: markGray, alpha: 1)
            context.fill(mark)
        }
        return context.makeImage()!
    }

    @Test func identicalPicturesMatch() {
        let a = picture(bars: [100, 300, 500])
        #expect(PictureComparison.difference(a, a) == 0)
    }

    @Test func aTinyChangeStillCountsAsTheSamePicture() {
        // A small mark, about the size of a clock's last digit changing.
        let a = picture(bars: [100, 300, 500])
        let b = picture(bars: [100, 300, 500], mark: CGRect(x: 340, y: 770, width: 16, height: 20))
        #expect(PictureComparison.difference(a, b) < PictureComparison.samePicture)
    }

    @Test func movedContentIsADifferentPicture() {
        let a = picture(bars: [100, 300, 500])
        let b = picture(bars: [160, 360, 560])
        #expect(PictureComparison.difference(a, b) > PictureComparison.samePicture)
    }

    @Test func anElementCoveredByAPopupNoLongerLooksTheSame() {
        let plain = picture(bars: [300, 500, 700])
        // A white popup card over the middle of the screen, covering the bar drawn at 500.
        let withPopup = picture(bars: [300, 500, 700], mark: CGRect(x: 0, y: 420, width: 400, height: 200), markGray: 1)
        // Pixel rows count from the top: the bar drawn at 500 sits in rows 260..<300, the one at 700 in 60..<100.
        let covered = CGRect(x: 20, y: 260, width: 360, height: 40)
        let clear = CGRect(x: 20, y: 60, width: 360, height: 40)
        #expect(PictureComparison.difference(plain, in: clear, withPopup, in: clear) < PictureComparison.sameElement)
        #expect(PictureComparison.difference(plain, in: covered, withPopup, in: covered) > PictureComparison.sameElement)
    }

    @Test func theSharedStretchOfTwoScrolledPicturesMatches() {
        // The second picture is the first with its content scrolled up by 200 pixels.
        let a = picture(bars: [300, 500, 700])
        let b = picture(bars: [500, 700])
        #expect(PictureComparison.difference(a, rows: 200..<800, b, rows: 0..<600) < PictureComparison.sameOverlap)
        #expect(PictureComparison.difference(a, rows: 0..<600, b, rows: 0..<600) > PictureComparison.sameOverlap)
    }
}
#endif
