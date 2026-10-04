#if os(macOS)
import Foundation

/// What the hub has taken from one app on one phone or simulator.
///
/// Every report an app offers is one the user sent and the Mac hasn't confirmed, however long ago:
/// one sent before any Mac set the app up is still waiting for one.
struct SourceState: Codable, Equatable {
    var delivered: [String] = []

    /// The finished reports still to copy.
    func reportIDsToCopy(from finished: [FinishedReport]) -> [String] {
        let done = Set(delivered)
        return finished.filter { !done.contains($0.id) }.map(\.id)
    }

    /// The offered reports the app can stop offering: the ones copied.
    func settledReportIDs(in finished: [FinishedReport]) -> [String] {
        let done = Set(delivered)
        return finished.filter { done.contains($0.id) }.map(\.id)
    }
}
#endif
