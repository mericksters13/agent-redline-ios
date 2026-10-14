#if REDLINE
import Foundation

/// Which screenshot from Photos to offer when the app becomes active.
///
/// Only used when the app already has Photos access; the kit never asks for it.
enum ScreenshotSuggestion {
    /// How recent a screenshot must be to be offered.
    static let maxAge: TimeInterval = 10 * 60
    /// A screenshot in Photos dated this close to the app's own capture is the system's copy of
    /// that same screenshot.
    static let sameMoment: TimeInterval = 5

    /// A screenshot in Photos: its identifier and when it was taken.
    struct Candidate: Equatable, Sendable {
        var id: String
        var createdAt: Date
    }

    /// The newest screenshot, if it is worth offering: taken in the last 10 minutes, never offered
    /// before, and not the copy of a screenshot whose capture by the app was already sent or closed.
    ///
    /// Only the newest counts, so an older screenshot never turns up after a newer one.
    static func candidateToOffer(among newest: [Candidate], now: Date, offered: Set<String>, handledCaptures: [Date])
        -> Candidate?
    {
        guard let candidate = newest.max(by: { $0.createdAt < $1.createdAt }) else { return nil }
        guard now.timeIntervalSince(candidate.createdAt) <= maxAge,
            candidate.createdAt <= now.addingTimeInterval(sameMoment),
            !offered.contains(candidate.id),
            !handledCaptures.contains(where: { abs($0.timeIntervalSince(candidate.createdAt)) <= sameMoment })
        else { return nil }
        return candidate
    }

    /// True when the screenshot in Photos takes the place of the app's own capture made at
    /// `capturedAt`: it is the system's copy of that screenshot, with any crop or markup from the
    /// system's editor, or a newer one.
    static func replaces(captureAt capturedAt: Date, _ candidate: Candidate) -> Bool {
        candidate.createdAt >= capturedAt.addingTimeInterval(-sameMoment)
    }
}
#endif
