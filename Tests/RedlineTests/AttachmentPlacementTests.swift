#if REDLINE
import Foundation
import Testing
@testable import Redline

/// An iPhone 17 Pro in portrait: 402 by 874 pt, the space inside the safe area from 62 to 840.
struct AttachmentPlacementTests {
    private let bounds = CGRect(x: 0, y: 62, width: 402, height: 778)
    /// The paperclip in the island, near the top right.
    private let islandButton = CGRect(x: 268, y: 72, width: 44, height: 44)

    @Test func aButtonNearTheTopRightGrowsFromItsTopTrailingCorner() {
        #expect(AttachmentPlacement.corner(for: islandButton, in: bounds) == .topTrailing)
    }

    @Test func aButtonNearTheBottomLeftGrowsUpward() {
        let button = CGRect(x: 20, y: 780, width: 44, height: 44)
        #expect(AttachmentPlacement.corner(for: button, in: bounds) == .bottomLeading)
        let grid = AttachmentPlacement.expanded(anchor: button, in: bounds)
        #expect(grid.maxY == button.maxY)
    }

    @Test func theGridStaysInsideTheSpace() {
        for x in stride(from: 0.0, through: 380, by: 20) {
            for y in stride(from: 62.0, through: 820, by: 40) {
                let grid = AttachmentPlacement.expanded(anchor: CGRect(x: x, y: y, width: 44, height: 44), in: bounds)
                #expect(bounds.insetBy(dx: AttachmentPlacement.margin - 0.001, dy: -0.001).contains(grid))
            }
        }
    }

    @Test func theGridOpensFullWidthFromTheButtonsEdge() {
        let grid = AttachmentPlacement.expanded(anchor: islandButton, in: bounds)
        #expect(grid.minX == 12)
        #expect(grid.width == 378)
        #expect(grid.minY == islandButton.minY)
        #expect(grid.height == 378 * AttachmentPlacement.maxHeightRatio)
    }

    @Test func aGridWithFewPhotosIsOnlyAsTallAsItsContent() {
        let short = AttachmentPlacement.expanded(anchor: islandButton, in: bounds, contentHeight: 400)
        #expect(short.minY == islandButton.minY)
        #expect(short.height == 400)
        let full = AttachmentPlacement.expanded(anchor: islandButton, in: bounds, contentHeight: 5000)
        #expect(full == AttachmentPlacement.expanded(anchor: islandButton, in: bounds))
    }

    @Test func aShortGridOpeningUpwardKeepsItsBottomAtTheButton() {
        let button = CGRect(x: 268, y: 760, width: 44, height: 44)
        let grid = AttachmentPlacement.expanded(anchor: button, in: bounds, contentHeight: 300)
        #expect(grid.maxY == button.maxY)
        #expect(grid.height == 300)
    }

    @Test func theGridIsShortenedWhenThereIsNoRoom() {
        let button = CGRect(x: 268, y: 380, width: 44, height: 44)
        let grid = AttachmentPlacement.expanded(anchor: button, in: bounds)
        #expect(grid.minY == 380)
        #expect(grid.maxY == bounds.maxY - AttachmentPlacement.margin)
    }
}
#endif
