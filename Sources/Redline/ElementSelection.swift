#if REDLINE
import Foundation

/// One element from the app's accessibility tree, as it looked when it was read.
struct ElementSnapshot: Codable, Equatable, Sendable {
    /// Plain role such as "Button", "Text" or "Image".
    var role: String
    var label: String?
    var value: String?
    var identifier: String?
    var className: String?
    /// True for groups that carry an identifier or label but aren't elements themselves.
    var isContainer: Bool
    /// Position on screen, in points.
    var frame: CGRect
    /// True for content that changes on its own, such as a spinner or a running timer.
    ///
    /// A new frame of it isn't a new state of the screen. Nil otherwise, which keeps it out of
    /// `report.json`.
    var updatesFrequently: Bool? = nil
    /// Index of the nearest enclosing element in the same read of the screen, so a pick can step
    /// up through real ancestors only.
    ///
    /// Not saved: it means nothing outside that read.
    var parent: Int? = nil
    /// The names of the first elements inside a group with no identifier or label of its own.
    ///
    /// Such a group, such as a SwiftUI container with `.accessibilityElement(children: .contain)`, is
    /// named after them. Nil otherwise.
    var contents: [String]? = nil
    /// How many named elements the group holds, of which `contents` lists the first.
    var contentCount: Int? = nil

    private enum CodingKeys: String, CodingKey {
        case role, label, value, identifier, className, isContainer, frame, updatesFrequently, contents,
            contentCount
    }

    /// The role headers have, which marks a screen's title.
    static let headerRole = "Header"

    /// The longest a name runs in chips and lists, in characters, before it's cut short.
    static let shortNameLength = 34

    /// The element's whole name: its label, else its identifier, else its value, else, for a group
    /// with none of those, what it holds, such as `"Beyond the sky" and 2 more`.
    ///
    /// Nil when it has none.
    var fullName: String? {
        label?.nonEmpty ?? identifier?.nonEmpty ?? value?.nonEmpty ?? contentsName
    }

    /// `"Beyond the sky"`, `"Beyond the sky" and "Unlock"`, or `"Beyond the sky" and 2 more`, from
    /// `contents`; nil when the group holds nothing named.
    var contentsName: String? {
        guard let first = contents?.first else { return nil }
        let count = max(contentCount ?? 0, contents?.count ?? 0)
        switch count {
        case ...1: return "\"\(first)\""
        case 2: return "\"\(first)\" and \"\(contents?.dropFirst().first ?? "")\""
        default: return "\"\(first)\" and \(count - 1) more"
        }
    }

    /// How many names a group keeps in `contents`.
    static let contentsLength = 3

    /// The element's own name, shortened for chips and lists, or nil when it has none.
    var shortName: String? {
        guard let name = fullName else { return nil }
        return name.count > Self.shortNameLength ? String(name.prefix(Self.shortNameLength - 1)) + "…" : name
    }
}

/// Finds the elements under a finger, and a saved note's element on a fresh read of the screen.
enum ElementSelection {
    /// How far from an element a touch can land and still pick it, in points.
    static let nearbyDistance: CGFloat = 44

    /// The element under a point, then each bigger element holding it, innermost first.
    ///
    /// `elements` come back to front, each parent before its children, as `AccessibilityTree`
    /// reads them, so the last one containing the point is the one the user sees there. A touch
    /// that misses every element picks the nearest one within `nearbyDistance`, the frontmost of any
    /// at the same distance. Elements covering almost the whole screen are left out, since "the
    /// whole screen" says nothing useful.
    static func levels(at point: CGPoint, in elements: [ElementSnapshot], screenSize: CGSize) -> [ElementSnapshot] {
        let screenArea = screenSize.width * screenSize.height
        func isUsable(_ element: ElementSnapshot) -> Bool {
            !element.frame.isEmpty && area(element.frame) < screenArea * 0.9
        }

        var hit = elements.indices.last { isUsable(elements[$0]) && elements[$0].frame.contains(point) }
        if hit == nil,
            let nearest = elements.indices
                .filter({ isUsable(elements[$0]) && !elements[$0].isContainer })
                .reversed()
                .min(by: {
                    distance(from: point, to: elements[$0].frame) < distance(from: point, to: elements[$1].frame)
                }),
            distance(from: point, to: elements[nearest].frame) <= nearbyDistance
        {
            hit = nearest
        }
        guard let hit else { return [] }

        var levels = [elements[hit]]
        var current = hit
        // Parents come before their children, so each step moves to a lower index.
        while let index = elements[current].parent, index >= 0, index < current, levels.count < 8 {
            current = index
            let element = elements[index]
            // A label and the row wrapping it at the same size are one level, not two.
            guard isUsable(element), let innermost = levels.last, !isSameBox(innermost.frame, element.frame) else {
                continue
            }
            levels.append(element)
        }
        return levels
    }

    /// Finds the element a saved annotation points at on a fresh read of the screen: by identifier
    /// first, then by role and label only when the identifier is gone from the screen.
    ///
    /// Look-alikes, such as repeated list rows, only match when exactly one is still where the saved
    /// one was.
    static func match(_ target: ElementSnapshot, in elements: [ElementSnapshot]) -> ElementSnapshot? {
        if let identifier = target.identifier?.nonEmpty {
            let hits = elements.filter { $0.identifier == identifier }
            if hits.count == 1 { return hits[0] }
            // Elements still carrying the identifier rule out a look-alike elsewhere.
            if !hits.isEmpty {
                return unique(hits.filter { $0.role == target.role && $0.label == target.label }, for: target)
            }
        }
        if let label = target.label?.nonEmpty {
            return unique(elements.filter { $0.role == target.role && $0.label == label }, for: target)
        }
        // A group with no name of its own is known by what it holds.
        guard let contents = target.contents, !contents.isEmpty else { return nil }
        return unique(elements.filter { $0.role == target.role && $0.contents == contents }, for: target)
    }

    /// The only hit, or the only one in the saved element's place.
    ///
    /// Nil when that is still ambiguous.
    private static func unique(_ hits: [ElementSnapshot], for target: ElementSnapshot) -> ElementSnapshot? {
        if hits.count == 1 { return hits[0] }
        let inPlace = hits.filter { isSameBox($0.frame, target.frame) }
        return inPlace.count == 1 ? inPlace[0] : nil
    }

    /// The label of the topmost header on screen, which is usually the screen's title.
    static func headerTitle(in elements: [ElementSnapshot]) -> String? {
        elements
            .filter { $0.role == ElementSnapshot.headerRole && $0.label?.nonEmpty != nil }
            .min { $0.frame.minY < $1.frame.minY }?
            .label
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.width * rect.height
    }

    private static func isSameBox(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 3 && abs(a.minY - b.minY) < 3
            && abs(a.width - b.width) < 6 && abs(a.height - b.height) < 6
    }

    private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}
#endif
