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
        func isUsable(_ element: ElementSnapshot) -> Bool { Self.isUsable(element, screenSize: screenSize) }

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
        return levels(from: hit, in: elements, screenSize: screenSize)
    }

    /// The compact path for an explicitly selected node, without another geometric hit test.
    static func levels(from index: Int, in elements: [ElementSnapshot], screenSize: CGSize) -> [ElementSnapshot] {
        guard elements.indices.contains(index) else { return [] }
        var levels = [elements[index]]
        var current = index
        // Parents come before their children, so each step moves to a lower index.
        while let index = elements[current].parent, index >= 0, index < current, levels.count < 8 {
            current = index
            let element = elements[index]
            // A label and the row wrapping it at the same size are one level, not two.
            guard isUsable(element, screenSize: screenSize), let innermost = levels.last,
                !isSameBox(innermost.frame, element.frame)
            else {
                continue
            }
            levels.append(element)
        }
        return levels
    }

    /// How many enclosed elements a drawing keeps; the rest are counted.
    static let enclosedLimit = 12
    /// How far past the box around a drawing still counts as inside it, in points: a quick circle
    /// cuts corners.
    static let enclosingSlack: CGFloat = 12
    /// How much of an element must be inside the drawing's box for it to be enclosed.
    ///
    /// A list row merges its title and details into one element as wide as the screen, and
    /// circling the title means the row.
    static let enclosedShare: CGFloat = 0.5
    /// The smallest area a shape must close around to enclose anything, in square points, so a
    /// straight line or a tap encloses nothing.
    static let minimumEnclosedArea: CGFloat = 200

    /// The named elements a drawing encloses, in screen order: back to front, each parent before its
    /// children, as `AccessibilityTree` reads them.
    ///
    /// Strokes whose boxes, each grown by `enclosingSlack`, overlap, directly or through other
    /// strokes, draw one shape, so a circle traced twice, two half circles or a box drawn as four
    /// lines all enclose what lies between them, while two circles apart each enclose only what they
    /// hold. A shape counts as the convex hull of its points. An element is enclosed when, for one
    /// shape, its center is inside the hull and at least `enclosedShare` of it is within
    /// `enclosingSlack` of the box around the shape, and it shows: it is the frontmost element at one
    /// of five points on it, or holds that element. An element covered by a sheet or by a view in
    /// front of it isn't what was circled. A group named only by what it holds adds nothing once what
    /// it holds shows inside the drawing, by name or by value.
    static func enclosed(by strokes: [[CGPoint]], in elements: [ElementSnapshot], screenSize: CGSize)
        -> [ElementSnapshot]
    {
        let areas = shapes(of: strokes).compactMap { shape -> (hull: [CGPoint], reach: CGRect)? in
            let hull = convexHull(Array(shape.joined()))
            guard hull.count >= 3, polygonArea(hull) >= minimumEnclosedArea, let box = Annotation.bounds(of: shape)
            else { return nil }
            return (hull, box.insetBy(dx: -enclosingSlack, dy: -enclosingSlack))
        }
        guard !areas.isEmpty else { return [] }
        let shown = elements.filter { element in
            let frame = element.frame
            let center = CGPoint(x: frame.midX, y: frame.midY)
            guard isUsable(element, screenSize: screenSize),
                areas.contains(where: { shape in
                    area(frame.intersection(shape.reach)) >= area(frame) * enclosedShare
                        && contains(center, inConvex: shape.hull)
                })
            else { return false }
            // The center and four points around it, so a small view in front of one spot, like a
            // badge, doesn't hide a whole card.
            let samples = [(0.5, 0.5), (0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)].map { x, y in
                CGPoint(x: frame.minX + frame.width * x, y: frame.minY + frame.height * y)
            }
            return samples.contains { chain(at: $0, in: elements, screenSize: screenSize).contains(element) }
        }
        // Everything inside, named or not: a group named by what it holds, values included, adds
        // nothing once that shows.
        let names = Set(shown.compactMap { $0.label?.nonEmpty ?? $0.identifier?.nonEmpty ?? $0.value?.nonEmpty })
        return shown.filter { element in
            guard hasName(element) else { return false }
            guard element.label?.nonEmpty == nil, element.identifier?.nonEmpty == nil, let contents = element.contents
            else { return true }
            return !contents.allSatisfy(names.contains)
        }
    }

    /// The named elements holding the whole box around a drawing, innermost first, like an element
    /// note's ancestors: for a circle around a gap, they say where it is.
    ///
    /// What the drawing encloses is left out, since the note already lists it.
    static func holding(
        _ box: CGRect,
        excluding enclosed: [ElementSnapshot],
        in elements: [ElementSnapshot],
        screenSize: CGSize
    ) -> [ElementSnapshot] {
        chain(at: CGPoint(x: box.midX, y: box.midY), in: elements, screenSize: screenSize).filter {
            hasName($0) && $0.frame.insetBy(dx: -2, dy: -2).contains(box) && !enclosed.contains($0)
        }
    }

    /// The frontmost element at `point` and every element holding it, innermost first.
    ///
    /// Unlike `levels(at:in:screenSize:)`, a holder the same size as what it holds stays, so a named
    /// wrapper around an unlabeled control counts as shown, and nothing is picked from nearby.
    private static func chain(at point: CGPoint, in elements: [ElementSnapshot], screenSize: CGSize)
        -> [ElementSnapshot]
    {
        guard
            var current = elements.indices.last(where: {
                isUsable(elements[$0], screenSize: screenSize) && elements[$0].frame.contains(point)
            })
        else { return [] }
        var chain = [elements[current]]
        // Parents come before their children, so each step moves to a lower index.
        while let index = elements[current].parent, index >= 0, index < current {
            current = index
            if isUsable(elements[index], screenSize: screenSize) { chain.append(elements[index]) }
        }
        return chain
    }

    /// Whether an element is local enough to pick, enclose or use as a hierarchy owner.
    ///
    /// Empty frames and elements covering almost the whole screen are excluded.
    static func isUsable(_ element: ElementSnapshot, screenSize: CGSize) -> Bool {
        !element.frame.isEmpty && area(element.frame) < screenSize.width * screenSize.height * 0.9
    }

    /// How far `element` has moved on a fresh read of the screen; nil when it isn't found there, or
    /// it changed size by more than 2 points.
    ///
    /// A saved drawing moves with the first element it encloses, so it stays on it through a scroll.
    static func offset(of element: ElementSnapshot, in elements: [ElementSnapshot]) -> CGPoint? {
        guard let match = match(element, in: elements), abs(match.frame.width - element.frame.width) <= 2,
            abs(match.frame.height - element.frame.height) <= 2
        else { return nil }
        return CGPoint(x: match.frame.minX - element.frame.minX, y: match.frame.minY - element.frame.minY)
    }

    /// Strokes grouped into the shapes they draw: two strokes are in one shape when their boxes,
    /// grown by `enclosingSlack`, overlap, directly or through other strokes.
    ///
    /// Compares every pair of shapes until none overlap, which is quick for the few strokes a finger
    /// draws.
    private static func shapes(of strokes: [[CGPoint]]) -> [[[CGPoint]]] {
        var shapes = strokes.compactMap { stroke in
            Annotation.bounds(of: [stroke]).map {
                (box: $0.insetBy(dx: -enclosingSlack, dy: -enclosingSlack), strokes: [stroke])
            }
        }
        var merged = true
        while merged {
            merged = false
            search: for first in shapes.indices {
                for second in shapes.indices where second > first && shapes[first].box.intersects(shapes[second].box) {
                    shapes[first] = (
                        shapes[first].box.union(shapes[second].box), shapes[first].strokes + shapes[second].strokes
                    )
                    shapes.remove(at: second)
                    merged = true
                    break search
                }
            }
        }
        return shapes.map(\.strokes)
    }

    /// Whether an element has a label, an identifier, or, for a group, named contents: something a
    /// report can call it.
    ///
    /// A value alone, such as a slider's "50%" or the text typed in a field, isn't, since it isn't in
    /// the code; such an element is left out of what a drawing encloses and of what holds it.
    private static func hasName(_ element: ElementSnapshot) -> Bool {
        element.label?.nonEmpty != nil || element.identifier?.nonEmpty != nil || element.contents?.isEmpty == false
    }

    /// The smallest convex polygon around `points`, by Andrew's monotone chain.
    private static func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        let sorted = points.sorted { ($0.x, $0.y) < ($1.x, $1.y) }
        guard sorted.count >= 3 else { return sorted }
        func turn(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        func half(_ points: [CGPoint]) -> [CGPoint] {
            var chain: [CGPoint] = []
            for point in points {
                while chain.count >= 2, turn(chain[chain.count - 2], chain[chain.count - 1], point) <= 0 {
                    chain.removeLast()
                }
                chain.append(point)
            }
            return chain
        }
        return Array(half(sorted).dropLast() + half(sorted.reversed()).dropLast())
    }

    private static func polygonArea(_ polygon: [CGPoint]) -> CGFloat {
        var sum: CGFloat = 0
        for index in polygon.indices {
            let a = polygon[index]
            let b = polygon[(index + 1) % polygon.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }

    /// Whether `point` is inside a convex polygon or on its edge: it is on the same side of every edge.
    private static func contains(_ point: CGPoint, inConvex polygon: [CGPoint]) -> Bool {
        var side: CGFloat = 0
        for index in polygon.indices {
            let a = polygon[index]
            let b = polygon[(index + 1) % polygon.count]
            let turn = (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
            guard turn != 0 else { continue }
            if side == 0 {
                side = turn
            } else if (turn > 0) != (side > 0) {
                return false
            }
        }
        return true
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
