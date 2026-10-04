#if REDLINE
import Foundation

/// A report already sent, read back to show on the phone.
struct SentReport: Identifiable, Sendable {
    var report: Report
    /// Where its snapshots are.
    var folder: URL
    /// The Mac has confirmed it has the report.
    var isDelivered = false
    var id: String { report.id }
}

/// The last attempt to hand reports to the Mac, kept so the phone can say why one isn't there.
struct Delivery: Codable, Equatable, Sendable {
    var attemptedAt: Date
    var outcome: HubLink.Outcome

    private enum CodingKeys: String, CodingKey {
        case attemptedAt = "at"
        case outcome
    }
}
#endif
