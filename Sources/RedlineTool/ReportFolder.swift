#if os(macOS)
import Foundation

/// A report the kit has finished drawing.
struct FinishedReport: Equatable {
    var id: String
    /// When its `report.json` was written.
    var finishedAt: Date?
}

/// Where the kit keeps sent reports, inside an app's data container.
enum ReportFolder {
    static let path = HubMessage.kitFolder + "/reports"

    /// The finished reports among paths relative to the reports folder. A report is finished
    /// once its `report.json` is written and the draft it was drawn from is gone.
    static func finishedReports(in entries: [(path: String, modified: Date?)]) -> [FinishedReport] {
        var written: [String: FinishedReport] = [:]
        var drawing = Set<String>()
        for entry in entries {
            let parts = entry.path.split(separator: "/")
            guard parts.count >= 2 else { continue }
            let id = String(parts[0])
            if parts.count == 2, parts[1] == "report.json" { written[id] = FinishedReport(id: id, finishedAt: entry.modified) }
            if parts[1] == "draft" { drawing.insert(id) }
        }
        return written.values.filter { !drawing.contains($0.id) }.sorted { $0.id < $1.id }
    }
}

/// A report folder inside a simulator app's data container, found from the path of a file in it.
struct SimulatorReportPath: Hashable {
    /// The app's data container.
    var container: String
    /// The simulator's UDID.
    var device: String
    var reportID: String

    static func parse(_ path: String) -> SimulatorReportPath? {
        guard let marker = path.range(of: "/" + ReportFolder.path + "/") else { return nil }
        let container = String(path[..<marker.lowerBound])
        guard let id = path[marker.upperBound...].split(separator: "/").first.map(String.init), !id.isEmpty else { return nil }
        guard let device = device(ofContainer: container) else { return nil }
        return SimulatorReportPath(container: container, device: device, reportID: id)
    }

    /// The simulator an app's data container belongs to, from the container's path.
    static func device(ofContainer container: String) -> String? {
        let parts = container.split(separator: "/")
        guard let devices = parts.lastIndex(of: "Devices"), devices + 1 < parts.count else { return nil }
        return String(parts[devices + 1])
    }
}
#endif
