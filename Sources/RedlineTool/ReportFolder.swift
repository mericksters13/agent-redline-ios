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
    /// Where a build from before the rename keeps them.
    ///
    /// A simulator app still running such a build after the Mac tool is updated writes its reports
    /// here, until a new build moves them.
    static let earlierPath = HubMessage.earlierKitFolder + "/reports"
    static let paths = [path, earlierPath]
    /// The empty file in a report's folder that says the Mac has it, as the kit's `ReportStore`
    /// names it.
    static let deliveredMark = "delivered"

    /// The finished reports among paths relative to the reports folder that a Mac doesn't have yet.
    ///
    /// A report is finished once its `report.json` is written and the draft it was drawn from is
    /// gone; one with the delivered mark is already on a Mac.
    static func finishedReports(in entries: [(path: String, modified: Date?)]) -> [FinishedReport] {
        var written: [String: FinishedReport] = [:]
        var skipped = Set<String>()
        for entry in entries {
            let parts = entry.path.split(separator: "/")
            guard parts.count >= 2 else { continue }
            let id = String(parts[0])
            if parts.count == 2, parts[1] == "report.json" {
                written[id] = FinishedReport(id: id, finishedAt: entry.modified)
            }
            if parts[1] == "draft" || (parts.count == 2 && parts[1] == deliveredMark) { skipped.insert(id) }
        }
        return written.values.filter { !skipped.contains($0.id) }.sorted { $0.id < $1.id }
    }
}

/// A report folder inside a simulator app's data container, found from the path of a file in it.
struct SimulatorReportPath: Hashable {
    /// The app's data container.
    var container: String
    /// The simulator's UDID.
    var device: String
    var reportID: String
    /// The reports folder in the container, one of `ReportFolder.paths`.
    var folder = ReportFolder.path

    static func parse(_ path: String) -> SimulatorReportPath? {
        for folder in ReportFolder.paths {
            guard let marker = path.range(of: "/" + folder + "/") else { continue }
            let container = String(path[..<marker.lowerBound])
            guard let id = path[marker.upperBound...].split(separator: "/").first.map(String.init), !id.isEmpty else {
                return nil
            }
            guard let device = device(ofContainer: container) else { return nil }
            return SimulatorReportPath(container: container, device: device, reportID: id, folder: folder)
        }
        return nil
    }

    /// The simulator an app's data container belongs to, from the container's path.
    static func device(ofContainer container: String) -> String? {
        let parts = container.split(separator: "/")
        guard let devices = parts.lastIndex(of: "Devices"), devices + 1 < parts.count else { return nil }
        return String(parts[devices + 1])
    }
}
#endif
