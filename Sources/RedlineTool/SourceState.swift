#if os(macOS)
import Foundation

/// What the hub has taken from one app on one phone or simulator.
struct SourceState: Codable, Equatable {
    /// Reports finished before this were there before the hub first looked, and stay where they are.
    var since: Date
    var delivered: [String] = []

    /// The finished reports still to copy.
    func reportIDsToCopy(from finished: [FinishedReport]) -> [String] {
        let done = Set(delivered)
        return finished.filter { report in
            !done.contains(report.id) && !isOld(report)
        }.map(\.id)
    }

    /// The offered reports the app can stop offering: copied, or there before the hub first looked.
    func settledReportIDs(in finished: [FinishedReport]) -> [String] {
        let done = Set(delivered)
        return finished.filter { done.contains($0.id) || isOld($0) }.map(\.id)
    }

    private func isOld(_ report: FinishedReport) -> Bool {
        report.finishedAt.map { $0 < since } ?? false
    }
}
#endif
