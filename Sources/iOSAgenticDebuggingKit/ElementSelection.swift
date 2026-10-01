#if AGENTIC_DEBUGGING
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

    /// Short name for chips and lists, such as "Button · Save".
    var displayName: String {
        guard let name = label?.nonEmpty ?? identifier?.nonEmpty ?? value?.nonEmpty else { return role }
        let short = name.count > 40 ? name.prefix(39) + "…" : Substring(name)
        return "\(role) · \(short)"
    }
}

enum ElementSelection {
    /// How far from an element a touch can land and still pick it, in points.
    static let nearbyDistance: CGFloat = 44

    /// The elements under a point, innermost first, then each bigger element
    /// holding it. A touch that misses every element picks the nearest one within
    /// `nearbyDistance`. Elements covering almost the whole screen are left out,
    /// since "the whole screen" says nothing useful.
    static func levels(at point: CGPoint, in elements: [ElementSnapshot], screenSize: CGSize) -> [ElementSnapshot] {
        let screenArea = screenSize.width * screenSize.height
        let usable = elements.filter { !$0.frame.isEmpty && area($0.frame) < screenArea * 0.9 }

        var containing = usable.filter { $0.frame.contains(point) }
        if containing.isEmpty,
           let nearest = usable.filter({ !$0.isContainer }).min(by: { distance(from: point, to: $0.frame) < distance(from: point, to: $1.frame) }),
           distance(from: point, to: nearest.frame) <= nearbyDistance {
            containing = usable.filter { $0.frame.contains(nearest.frame) }
        }

        var levels: [ElementSnapshot] = []
        for element in containing.sorted(by: { area($0.frame) < area($1.frame) }) {
            // A label and the row wrapping it at the same size are one level, not two.
            if let innermost = levels.last, isSameBox(innermost.frame, element.frame) { continue }
            levels.append(element)
        }
        return Array(levels.prefix(8))
    }

    /// Finds the element a saved annotation points at on a fresh read of the
    /// screen: by identifier first, then by role and label when that is unique.
    static func match(_ target: ElementSnapshot, in elements: [ElementSnapshot]) -> ElementSnapshot? {
        if let identifier = target.identifier?.nonEmpty {
            let hits = elements.filter { $0.identifier == identifier }
            if hits.count == 1 { return hits[0] }
            if let exact = hits.first(where: { $0.role == target.role && $0.label == target.label }) { return exact }
        }
        guard let label = target.label?.nonEmpty else { return nil }
        let hits = elements.filter { $0.role == target.role && $0.label == label }
        return hits.count == 1 ? hits[0] : nil
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

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
#endif
