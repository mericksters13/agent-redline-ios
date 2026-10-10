#if REDLINE
import Foundation
import Testing
@testable import Redline

struct ElementHierarchyTests {
    private let screenSize = CGSize(width: 400, height: 800)

    private func node(_ name: String, parent: Int? = nil, group: Bool = false) -> ElementSnapshot {
        ElementSnapshot(
            role: group ? "Group" : "Text",
            label: name,
            value: nil,
            identifier: nil,
            className: nil,
            isContainer: group,
            frame: CGRect(x: 20, y: 100, width: 100, height: 40),
            parent: parent
        )
    }

    @Test func nearestParentExcludesAncestorsAndUnrelatedOverlappingTrees() throws {
        let elements = [
            node("Screen", group: true), node("Titles", parent: 0, group: true),
            node("Title", parent: 1), node("Summary", parent: 1),
            node("Stats", parent: 0, group: true), node("Time", parent: 4),
        ]
        let tree = try #require(ElementHierarchy(touched: elements[3], in: elements, screenSize: screenSize))
        #expect(tree.rows().map(\.id) == [1, 2, 3])
        #expect(tree.rows().map(\.branches) == [[], [true], [false]])
        #expect(tree.element(at: 2) == elements[2])
        #expect(tree.element(at: 4) == nil)
        #expect(tree.element(at: 0) == nil)
        #expect(tree.root == 1)
    }

    @Test func touchingAGroupIncludesItsImmediateOwnerAndKeepsTheSelectedGroupNested() throws {
        let elements = [
            node("List", group: true), node("Row", parent: 0, group: true),
            node("Icon", parent: 1), node("Titles", parent: 1, group: true),
            node("Title", parent: 3), node("Summary", parent: 3), node("Time", parent: 1),
            node("Other row", parent: 0, group: true), node("Other title", parent: 7),
        ]
        let tree = try #require(ElementHierarchy(touched: elements[3], in: elements, screenSize: screenSize))
        #expect(tree.root == 1)
        #expect(tree.rows().map(\.id) == [1, 2, 3, 4, 5, 6])
        #expect(tree.rows().map(\.branches) == [[], [true], [true], [true, true], [true, false], [false]])
        #expect(tree.element(at: 3) == elements[3])
        #expect(tree.element(at: 0) == nil)
        #expect(tree.element(at: 7) == nil)
    }

    @Test func collapsePreservesSiblingsAndTheirOwnershipLines() throws {
        let elements = [
            node("Root", group: true), node("Branch", parent: 0, group: true),
            node("Child", parent: 1), node("Sibling", parent: 0),
        ]
        let tree = try #require(ElementHierarchy(touched: elements[0], in: elements, screenSize: screenSize))
        #expect(tree.rows().map(\.branches) == [[], [true], [true, false], [false]])
        #expect(tree.rows(collapsing: [1]).map(\.id) == [0, 1, 3])
        #expect(tree.rows(collapsing: [0]).map(\.id) == [0])
        #expect(tree.rows()[1].hasChildren)
    }

    @Test func leafWithoutAValidParentRemainsItsOwnRoot() throws {
        for parent in [nil, -1, 0, 7] as [Int?] {
            let leaf = node("Leaf", parent: parent)
            let tree = try #require(ElementHierarchy(touched: leaf, in: [leaf], screenSize: screenSize))
            #expect(tree.rows().map(\.id) == [0])
            #expect(!tree.rows()[0].hasChildren)
            #expect(tree.element(at: -1) == nil)
            #expect(tree.element(at: 1) == nil)
        }
    }

    @Test func wholeScreenOwnerDoesNotPullOtherBranchesIntoHierarchy() throws {
        var screen = node("Screen", group: true)
        screen.frame = CGRect(origin: .zero, size: screenSize)
        let elements = [
            screen, node("Row", parent: 0, group: true), node("Title", parent: 1),
            node("Other row", parent: 0, group: true), node("Other title", parent: 3),
        ]
        let tree = try #require(ElementHierarchy(touched: elements[1], in: elements, screenSize: screenSize))
        #expect(tree.root == 1)
        #expect(tree.rows().map(\.id) == [1, 2])
        #expect(tree.element(at: 0) == nil)
        #expect(tree.element(at: 3) == nil)
    }

    @Test func hierarchyKeepsSameSizedOwnersAndMoreThanEightLevels() throws {
        let elements = (0..<12).map { node("Node \($0)", parent: $0 == 0 ? nil : $0 - 1, group: $0 < 11) }
        let tree = try #require(ElementHierarchy(touched: elements[0], in: elements, screenSize: screenSize))
        #expect(tree.rows().count == 12)
        #expect(tree.rows().last?.branches.count == 11)
        #expect(tree.element(at: 11) == elements[11])
    }

    @Test func dragSelectionUsesVisibleRowBoundsWithoutSelectingClippedOrUnownedRows() throws {
        let elements = [node("Root", group: true), node("First", parent: 0),
                        node("Second", parent: 0), node("Other root", group: true)]
        let tree = try #require(ElementHierarchy(touched: elements[0], in: elements, screenSize: screenSize))
        let viewport = CGRect(x: 20, y: 100, width: 200, height: 110)
        let frames = [0: CGRect(x: 20, y: 100, width: 200, height: 44),
                      1: CGRect(x: 20, y: 144, width: 200, height: 44),
                      2: CGRect(x: 20, y: 188, width: 200, height: 44),
                      3: CGRect(x: 20, y: 100, width: 200, height: 44)]
        #expect(tree.row(at: CGPoint(x: 100, y: 120), frames: frames, visibleBounds: viewport) == 0)
        #expect(tree.row(at: CGPoint(x: 100, y: 170), frames: frames, visibleBounds: viewport) == 1)
        #expect(tree.row(at: CGPoint(x: 100, y: 200), frames: frames, visibleBounds: viewport) == 2)
        #expect(tree.row(at: CGPoint(x: 100, y: 220), frames: frames, visibleBounds: viewport) == nil)
        #expect(tree.row(at: CGPoint(x: 10, y: 170), frames: frames, visibleBounds: viewport) == nil)
        #expect(tree.row(at: CGPoint(x: 100, y: 120), frames: [3: frames[3]!], visibleBounds: viewport) == nil)
    }

    @Test func collapsedRowsCannotBeSelectedFromStaleDragFrames() throws {
        let elements = [node("Root", group: true), node("Branch", parent: 0, group: true),
                        node("Child", parent: 1), node("Sibling", parent: 0)]
        let tree = try #require(ElementHierarchy(touched: elements[0], in: elements, screenSize: screenSize))
        let viewport = CGRect(x: 20, y: 100, width: 200, height: 200)
        let child = CGRect(x: 20, y: 188, width: 200, height: 44)
        #expect(tree.row(at: CGPoint(x: 100, y: 200), frames: [2: child], visibleBounds: viewport) == 2)
        #expect(tree.row(at: CGPoint(x: 100, y: 200), frames: [2: child], visibleBounds: viewport, collapsing: [1]) == nil)
    }

    @Test func explicitSelectionUsesNodeIdentityWhenFramesOverlap() {
        let elements = [node("Root", group: true), node("First", parent: 0), node("Second", parent: 0)]
        let levels = ElementSelection.levels(from: 1, in: elements, screenSize: CGSize(width: 400, height: 800))
        #expect(levels.first == elements[1])
        #expect(ElementSelection.levels(from: 99, in: elements, screenSize: CGSize(width: 400, height: 800)).isEmpty)
    }
}
#endif
