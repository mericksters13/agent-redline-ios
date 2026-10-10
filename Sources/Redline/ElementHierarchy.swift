#if REDLINE
import Foundation

/// The captured subtree of the nearest local owner of a touch.
///
/// Choosing another node does not change its root.
struct ElementHierarchy {
    struct Row: Identifiable, Equatable {
        let id: Int
        let element: ElementSnapshot
        /// Each branch says whether the line continues to a following sibling.
        let branches: [Bool]
        let hasChildren: Bool
    }

    let elements: [ElementSnapshot]
    let root: Int
    private let children: [[Int]]

    init?(touched: ElementSnapshot, in elements: [ElementSnapshot], screenSize: CGSize) {
        guard let index = elements.lastIndex(of: touched) else { return nil }
        self.elements = elements
        if let parent = touched.parent, parent >= 0, parent < index,
            ElementSelection.isUsable(elements[parent], screenSize: screenSize)
        {
            root = parent
        } else {
            root = index
        }
        var children = Array(repeating: [Int](), count: elements.count)
        for index in elements.indices {
            if let parent = elements[index].parent, parent >= 0, parent < index {
                children[parent].append(index)
            }
        }
        self.children = children
    }

    func rows(collapsing collapsed: Set<Int> = []) -> [Row] {
        var result: [Row] = []
        func append(_ index: Int, branches: [Bool]) {
            result.append(
                Row(id: index, element: elements[index], branches: branches, hasChildren: !children[index].isEmpty)
            )
            guard !collapsed.contains(index) else { return }
            for (offset, child) in children[index].enumerated() {
                append(child, branches: branches + [offset < children[index].count - 1])
            }
        }
        append(root, branches: [])
        return result
    }

    /// Only nodes owned by this root can become the note's target.
    func element(at index: Int) -> ElementSnapshot? {
        guard elements.indices.contains(index) else { return nil }
        var current = index
        while current != root {
            guard let parent = elements[current].parent, parent >= 0, parent < current else { return nil }
            current = parent
        }
        return elements[index]
    }
}
#endif
