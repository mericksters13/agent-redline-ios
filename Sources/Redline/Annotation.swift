#if REDLINE
import Foundation

/// The screen an annotation was made on.
struct ScreenInfo: Codable, Equatable, Sendable {
    var title: String?
    var viewController: String?
}

/// One item in a report: a note on a picked element or a drawing, or an attachment.
struct Annotation: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// An element picked on the live screen.
        case element
        /// Strokes drawn on the live screen, around what the note is about.
        case drawing
        /// The whole screen, captured by Redline or when a screenshot was taken in the app.
        case screen
        /// Photos picked from the photo library.
        case photo
    }

    var id: UUID
    var createdAt: Date
    var note: String
    var kind: Kind
    /// The picked element.
    ///
    /// Nil for attachments.
    var element: ElementSnapshot?
    /// Bigger elements holding the chosen one, innermost first.
    var ancestors: [ElementSnapshot]
    /// The screen it was made on.
    ///
    /// Nil for photos, which can come from anywhere.
    var screen: ScreenInfo?
    /// The draft's files attached to the item, in order: the captured screen or the photos picked.
    ///
    /// Element notes made before screens shared one snapshot keep theirs here, outlined.
    var attachments: [String]
    /// For an element note or a drawing, the capture of its screen it was made on.
    ///
    /// Every note on a screen shares the screen's snapshot; outlines and drawings are drawn when it's
    /// shown or sent.
    var captureID: UUID? = nil
    /// For a drawing, its strokes, in the points of the screen its capture was taken of.
    var strokes: [[CGPoint]] = []
    /// For a drawing, the named elements it encloses, in screen order, up to
    /// `ElementSelection.enclosedLimit`.
    var encloses: [ElementSnapshot] = []
    /// For a drawing, how many named elements it encloses, of which `encloses` lists the first.
    var enclosedCount = 0

    /// How many snapshots the note shows in the viewer.
    var snapshotCount: Int { captureID != nil ? 1 : attachments.count }

    /// The area the note marks on its capture: its element's frame, or the box around its drawing.
    ///
    /// For a drawing, this goes through every point of its strokes, so read it once per use.
    var frame: CGRect? { element?.frame ?? Self.bounds(of: strokes) }

    /// A note on a drawing, keeping the first `ElementSelection.enclosedLimit` of the named elements
    /// it encloses and how many there are.
    static func drawing(
        id: UUID,
        note: String,
        strokes: [[CGPoint]],
        enclosing enclosed: [ElementSnapshot],
        heldBy ancestors: [ElementSnapshot],
        screen: ScreenInfo?,
        captureID: UUID?
    ) -> Annotation {
        Annotation(
            id: id,
            createdAt: .now,
            note: note,
            kind: .drawing,
            element: nil,
            ancestors: ancestors,
            screen: screen,
            attachments: [],
            captureID: captureID,
            strokes: strokes,
            encloses: Array(enclosed.prefix(ElementSelection.enclosedLimit)),
            enclosedCount: enclosed.count
        )
    }

    /// A drawing's strokes moved from where `box`, the box around them, was to `rect`.
    ///
    /// Snapshots move a note's area only up or down, and a saved drawing moves with an element it
    /// encloses, never resizing, so the strokes move by the same amount.
    static func strokes(_ strokes: [[CGPoint]], from box: CGRect, to rect: CGRect) -> [[CGPoint]] {
        let dx = rect.minX - box.minX
        let dy = rect.minY - box.minY
        return strokes.map { $0.map { CGPoint(x: $0.x + dx, y: $0.y + dy) } }
    }

    /// A drawing's strokes, each moved whole as `place` moves the box around it; a stroke `place`
    /// leaves out is left out.
    ///
    /// A stitched snapshot keeps a bar where it was and moves the content under it, so a stroke on
    /// a bar and one on the content move apart, like an element on each. A stroke that only grazes
    /// the edge between them goes with the side its middle is on.
    static func strokes(_ strokes: [[CGPoint]], placedBy place: (CGRect) -> CGRect?) -> [[CGPoint]] {
        strokes.compactMap { stroke in
            guard let box = bounds(of: [stroke]), let placed = place(box) else { return nil }
            return Self.strokes([stroke], from: box, to: placed).first
        }
    }

    /// The areas a note marks, as a stitched snapshot places them: the element's frame, or the box
    /// around a drawing's strokes over the top bars, over the content in `band`, and over the bottom
    /// bars, so the content between strokes on the same side counts too.
    static func areas(element: ElementSnapshot?, strokes: [[CGPoint]], band: ClosedRange<CGFloat>) -> [CGRect] {
        if let element { return [element.frame] }
        let sides = Dictionary(grouping: strokes) { stroke -> Int in
            guard let box = bounds(of: [stroke]) else { return 0 }
            return box.midY < band.lowerBound ? -1 : box.midY > band.upperBound ? 1 : 0
        }
        return [-1, 0, 1].compactMap { sides[$0].flatMap(bounds(of:)) }
    }

    /// The square of the screen a note's thumbnail shows, in the points of `screen`.
    ///
    /// An element's keeps its leading end when it is wide and its top when it is tall, where the
    /// icon and title usually are; the middle of a row is often empty. A drawing's holds all of it,
    /// centered and moved inside the screen. A drawing taller or wider than the screen's shorter
    /// side gets a square that reaches past the screen's edges, centered on the screen there.
    static func thumbnailArea(around frame: CGRect, isDrawing: Bool, on screen: CGSize) -> CGRect {
        let area = frame.insetBy(dx: -12, dy: -12)
        guard isDrawing else {
            let side = min(area.width, area.height)
            return CGRect(origin: area.origin, size: CGSize(width: side, height: side))
        }
        let side = max(area.width, area.height)
        func start(centeredOn center: CGFloat, within length: CGFloat) -> CGFloat {
            guard side <= length else { return (length - side) / 2 }
            return min(max(center - side / 2, 0), length - side)
        }
        return CGRect(
            x: start(centeredOn: area.midX, within: screen.width),
            y: start(centeredOn: area.midY, within: screen.height),
            width: side,
            height: side
        )
    }

    /// The box around every point of a drawing, grown by 2 points on each side so a straight line
    /// still has an area; nil without points.
    static func bounds(of strokes: [[CGPoint]]) -> CGRect? {
        let points = strokes.joined()
        guard let first = points.first else { return nil }
        var box = CGRect(origin: first, size: .zero)
        for point in points.dropFirst() { box = box.union(CGRect(origin: point, size: .zero)) }
        return box.insetBy(dx: -2, dy: -2)
    }
}

extension Annotation {
    private enum CodingKeys: String, CodingKey {
        case id, createdAt, note, kind, element, ancestors, screen, captureID, strokes, encloses, enclosedCount
        /// The draft's name for `attachments`, kept so drafts stay readable.
        case attachments = "screenshots"
        /// The single snapshot of drafts saved before attachments existed.
        case screenshot
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        note = try container.decode(String.self, forKey: .note)
        element = try container.decodeIfPresent(ElementSnapshot.self, forKey: .element)
        // A kind this kit doesn't know, written by a newer one, falls back the way drafts saved
        // before kinds existed do: a whole-screen item, or an element note when it has an element.
        let kindName = try container.decodeIfPresent(String.self, forKey: .kind)
        kind = kindName.flatMap(Kind.init(rawValue:)) ?? (element == nil ? .screen : .element)
        ancestors = try container.decodeIfPresent([ElementSnapshot].self, forKey: .ancestors) ?? []
        screen = try container.decodeIfPresent(ScreenInfo.self, forKey: .screen)
        if let files = try container.decodeIfPresent([String].self, forKey: .attachments) {
            attachments = files
        } else {
            attachments = [try container.decode(String.self, forKey: .screenshot)]
        }
        captureID = try container.decodeIfPresent(UUID.self, forKey: .captureID)
        strokes = try container.decodeIfPresent([[CGPoint]].self, forKey: .strokes) ?? []
        encloses = try container.decodeIfPresent([ElementSnapshot].self, forKey: .encloses) ?? []
        enclosedCount = try container.decodeIfPresent(Int.self, forKey: .enclosedCount) ?? encloses.count
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(note, forKey: .note)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(element, forKey: .element)
        try container.encode(ancestors, forKey: .ancestors)
        try container.encodeIfPresent(screen, forKey: .screen)
        try container.encode(attachments, forKey: .attachments)
        try container.encodeIfPresent(captureID, forKey: .captureID)
        // Only drawings have these, so element notes and attachments are written as before.
        if !strokes.isEmpty { try container.encode(strokes, forKey: .strokes) }
        if !encloses.isEmpty { try container.encode(encloses, forKey: .encloses) }
        if enclosedCount != encloses.count { try container.encode(enclosedCount, forKey: .enclosedCount) }
    }

    /// What the item shows as its name in Redline.
    ///
    /// A drawing is named after the first element it encloses that has a label or an identifier, such
    /// as "Drawing around Save and 2 more".
    static func title(
        kind: Kind,
        element: ElementSnapshot?,
        screen: ScreenInfo?,
        snapshotCount: Int,
        encloses: [ElementSnapshot] = [],
        enclosedCount: Int = 0
    ) -> String {
        switch kind {
        case .element: element?.shortName ?? element?.role ?? "Unnamed element"
        case .drawing: drawingTitle(encloses: encloses, count: max(enclosedCount, encloses.count))
        case .screen: screen?.title ?? "This screen"
        case .photo: snapshotCount == 1 ? "Photo" : "\(snapshotCount) photos"
        }
    }

    private static func drawingTitle(encloses: [ElementSnapshot], count: Int) -> String {
        guard count > 0 else { return "Drawing" }
        // A group named only by what it holds already reads "… and 2 more".
        // The whole name, as an element note's report title has: lists shorten it as they lay it out.
        guard let named = encloses.first(where: { $0.label?.nonEmpty != nil || $0.identifier?.nonEmpty != nil }),
            let name = named.fullName
        else { return "Drawing around \(countPhrase(count, singular: "element", plural: "elements"))" }
        return count == 1 ? "Drawing around \(name)" : "Drawing around \(name) and \(count - 1) more"
    }

    /// The line under the name: what kind of item it is and where it was made.
    static func subtitle(kind: Kind, element: ElementSnapshot?, screen: ScreenInfo?) -> String {
        switch kind {
        case .element: [element?.role, screen?.title].compactMap { $0 }.joined(separator: " · ")
        case .drawing: ["Drawing", screen?.title].compactMap { $0 }.joined(separator: " · ")
        case .screen: "Whole screen"
        case .photo: "Attachment"
        }
    }

    var title: String {
        Self.title(
            kind: kind,
            element: element,
            screen: screen,
            snapshotCount: snapshotCount,
            encloses: encloses,
            enclosedCount: enclosedCount
        )
    }
    var subtitle: String { Self.subtitle(kind: kind, element: element, screen: screen) }
}
#endif
