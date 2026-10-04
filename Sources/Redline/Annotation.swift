#if REDLINE
import Foundation

/// The screen an annotation was made on.
struct ScreenInfo: Codable, Equatable, Sendable {
    var title: String?
    var viewController: String?
}

/// One item in a report: a note on a picked element, or an attachment.
struct Annotation: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// An element picked on the live screen.
        case element
        /// The whole screen, captured by Redline or when a screenshot was taken in the app.
        case screen
        /// Images picked from Photos.
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
    /// Nil for images from Photos, which can come from anywhere.
    var screen: ScreenInfo?
    /// Attached images, in order: the captured screen or the images picked from Photos.
    ///
    /// Element notes made before screens shared one screenshot keep theirs here, outlined.
    var screenshots: [String]
    /// For an element note, the capture of its screen it was made on.
    ///
    /// Every note on a screen shares the screen's picture; outlines are drawn when it's shown or
    /// sent.
    var captureID: UUID? = nil

    /// How many pictures the note shows in the viewer.
    var imageCount: Int { captureID != nil ? 1 : screenshots.count }
}

extension Annotation {
    private enum CodingKeys: String, CodingKey {
        case id, createdAt, note, kind, element, ancestors, screen, screenshots, captureID
        /// The single screenshot of drafts saved before attachments existed.
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
        if let files = try container.decodeIfPresent([String].self, forKey: .screenshots) {
            screenshots = files
        } else {
            screenshots = [try container.decode(String.self, forKey: .screenshot)]
        }
        captureID = try container.decodeIfPresent(UUID.self, forKey: .captureID)
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
        try container.encode(screenshots, forKey: .screenshots)
        try container.encodeIfPresent(captureID, forKey: .captureID)
    }

    /// What the item shows as its name in Redline.
    static func title(kind: Kind, element: ElementSnapshot?, screen: ScreenInfo?, imageCount: Int) -> String {
        switch kind {
        case .element: element?.shortName ?? element?.role ?? "Unnamed element"
        case .screen: screen?.title ?? "This screen"
        case .photo: imageCount == 1 ? "Image from Photos" : "\(imageCount) images from Photos"
        }
    }

    /// The line under the name: what kind of item it is and where it was made.
    static func subtitle(kind: Kind, element: ElementSnapshot?, screen: ScreenInfo?) -> String {
        switch kind {
        case .element: [element?.role, screen?.title].compactMap { $0 }.joined(separator: " · ")
        case .screen: "Whole screen"
        case .photo: "Attachment"
        }
    }

    var title: String { Self.title(kind: kind, element: element, screen: screen, imageCount: imageCount) }
    var subtitle: String { Self.subtitle(kind: kind, element: element, screen: screen) }
}
#endif
