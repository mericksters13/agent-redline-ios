#if REDLINE
import Foundation

/// Hands sent reports to the Mac's hub, and says how that went.
///
/// Free of UIKit, so it is tested on the Mac.
enum ReportDelivery {
    /// Set once a report has reached the Mac's hub, and so iOS has allowed local network access.
    static let hubReachedKey = "RedlineHubReached"

    /// How long to wait for the hub.
    ///
    /// The first time, iOS asks about local network access before the hub can answer, so the wait
    /// is longer until a report has reached it once.
    static var patience: TimeInterval {
        UserDefaults.standard.bool(forKey: hubReachedKey) ? 8 : 60
    }

    /// Sends every report the Mac hasn't confirmed to its hub, notes the ones it now has, and
    /// records how it went.
    ///
    /// One attempt at a time: each holds its reports' files in memory, up to 50 MB, so a send while
    /// the app's return is still delivering waits for it, then sends whatever is left. Nil when
    /// there's nothing to send, or no bundle ID to send it as. Runs off the main actor. Add
    /// @concurrent when the tools version reaches 6.2.
    static func deliver(from store: ReportStore, bundleID: String?, patience: TimeInterval) async -> HubLink.Outcome? {
        await deliveries.run { await deliverNow(from: store, bundleID: bundleID, patience: patience) }
    }

    private static let deliveries = DeliveryLine()

    /// Runs deliveries one after another, in the order they were asked for.
    private actor DeliveryLine {
        private var last: Task<HubLink.Outcome?, Never>?

        func run(_ work: @escaping @Sendable () async -> HubLink.Outcome?) async -> HubLink.Outcome? {
            let previous = last
            let next = Task {
                _ = await previous?.value
                return await work()
            }
            last = next
            return await next.value
        }
    }

    private static func deliverNow(
        from store: ReportStore,
        bundleID: String?,
        patience: TimeInterval
    ) async -> HubLink.Outcome? {
        guard let bundleID else { return nil }
        let reports = store.undeliveredReports()
        guard !reports.isEmpty else { return nil }
        guard let address = store.hubAddress() else {
            store.recordDelivery(.noHub)
            return .noHub
        }
        // In a simulator the hub takes reports from the app's folder as they're saved, and marks
        // each one delivered once it's copied. No mark soon means no hub is watching.
        if !address.acceptsUploads {
            let outcome = await waitForSimulatorHub(toTake: Set(reports.map(\.id)), in: store, patience: patience)
            if outcome == .delivered { store.pruneDeliveredReports() }
            store.recordDelivery(outcome)
            return outcome
        }
        let result = await HubLink.deliver(
            reports,
            bundleID: bundleID,
            address: address,
            files: { store.reportFiles($0) },
            patience: patience
        )
        store.markDelivered(result.delivered)
        store.pruneDeliveredReports()
        store.recordDelivery(result.outcome)
        // The hub answered, so iOS has allowed local network access.
        if result.outcome != .unreachable { UserDefaults.standard.set(true, forKey: hubReachedKey) }
        return result.outcome
    }

    /// Waits up to `patience`, and no more than 5 seconds, for a simulator's hub to mark every
    /// one of `ids` delivered.
    private static func waitForSimulatorHub(
        toTake ids: Set<String>,
        in store: ReportStore,
        patience: TimeInterval
    ) async -> HubLink.Outcome {
        let deadline = Date.now.addingTimeInterval(min(patience, 5))
        while Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { break }
            if !store.undeliveredReports().contains(where: { ids.contains($0.id) }) { return .delivered }
        }
        return .unreachable
    }

    /// What the toast after Send says, so a report that didn't reach the Mac says why.
    static func toast(for outcome: HubLink.Outcome?, notes: String, to destination: String? = nil) -> String {
        switch outcome {
        case .delivered: "Sent \(notes) to \(destination ?? "the Mac")"
        case .noHub, nil: "Saved \(notes) on this iPhone"
        case .unreachable: "Saved on this iPhone. Couldn't reach the Mac"
        case .refused: "Saved on this iPhone. The Mac didn't accept it"
        case .interrupted: "Saved on this iPhone. Sending to the Mac stopped"
        }
    }
}
#endif
