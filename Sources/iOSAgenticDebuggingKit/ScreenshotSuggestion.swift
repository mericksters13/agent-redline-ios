#if AGENTIC_DEBUGGING
import Foundation

/// Which screenshot from Photos to offer when the app becomes active. Only used
/// when the app already has Photos access; the kit never asks for it.
enum ScreenshotSuggestion {
    /// How recent a screenshot must be to be offered.
    static let window: TimeInterval = 10 * 60
    /// A screenshot taken this close to one the app captured itself is that same screenshot.
    static let sameMoment: TimeInterval = 5

    struct Candidate: Equatable, Sendable {
        var id: String
        var createdAt: Date
    }

    /// The newest screenshot, if it is worth offering: taken in the last 10 minutes,
    /// never offered before, and not one the app already offered from its own capture.
    /// Only the newest counts, so an older screenshot never turns up after a newer one.
    static func pick(newest: [Candidate], now: Date, offered: Set<String>, inAppCaptures: [Date]) -> Candidate? {
        guard let candidate = newest.max(by: { $0.createdAt < $1.createdAt }) else { return nil }
        guard now.timeIntervalSince(candidate.createdAt) <= window,
              candidate.createdAt <= now.addingTimeInterval(sameMoment),
              !offered.contains(candidate.id),
              !inAppCaptures.contains(where: { abs($0.timeIntervalSince(candidate.createdAt)) <= sameMoment })
        else { return nil }
        return candidate
    }
}
#endif
