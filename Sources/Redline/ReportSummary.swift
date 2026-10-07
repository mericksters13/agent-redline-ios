#if REDLINE
import Foundation

/// The report as text the agent reads first: what was reported, on which screen, and
/// which snapshot shows each note.
enum ReportSummary {
    static func markdown(_ report: Report) -> String {
        var lines: [String] = []
        let app = [
            report.app.name ?? report.app.bundleID ?? "App", report.app.version.map { "\($0)" },
            report.app.build.map { "(\($0))" },
        ]
        .compactMap { $0 }.joined(separator: " ")
        lines.append("# UI report: \(app)")
        lines.append("")
        let notes = countPhrase(report.items.count, singular: "note", plural: "notes")
        let screens =
            report.screens.isEmpty
            ? "" : " on " + countPhrase(report.screens.count, singular: "screen", plural: "screens")
        lines.append(
            "\(report.device.model), \(report.device.systemName) \(report.device.systemVersion). "
                + "\(notes)\(screens). Numbers match the red numbered outlines in the snapshots."
        )
        let items = Dictionary(uniqueKeysWithValues: report.items.map { ($0.number, $0) })

        for screen in report.screens {
            lines.append("")
            lines.append("## Screen: \(screen.title ?? screen.viewController ?? "Untitled")")
            lines.append("")
            let current = screen.snapshots.filter { !$0.isEarlierState }
            if let first = current.first {
                var description = "One snapshot of this screen"
                if first.stitchedFrom > 1 { description += ", stitched from \(first.stitchedFrom) scroll positions" }
                if current.count > 1 {
                    description += ", in \(current.count) parts: " + current.map(\.file).joined(separator: ", ")
                } else {
                    description += ": \(first.file)"
                }
                let numbers = Array(Set(current.flatMap(\.notes))).sorted()
                let outlined = numbers.count == 1 ? "Note \(list(numbers)) is" : "Notes \(list(numbers)) are"
                lines.append("\(description). \(outlined) outlined and numbered on it.")
                let skipped = current.compactMap(\.scrolledPast).reduce(0, +)
                if skipped > 0 {
                    lines.append(
                        "The notes are far apart: about \(skipped) pt of the screen between them wasn't captured and is marked \"Scrolled past\". Those parts aren't next to each other in the layout."
                    )
                }
            }
            for earlier in screen.snapshots where earlier.isEarlierState {
                lines.append(
                    "An earlier state of the same screen, before its content changed: \(earlier.file), with \(earlier.notes.count == 1 ? "note" : "notes") \(list(earlier.notes))."
                )
            }
            lines.append("")
            for number in screen.notes {
                guard let item = items[number] else { continue }
                lines.append(line(for: item))
            }
        }

        let attachments = report.items.filter { $0.screen == nil }
        if !attachments.isEmpty {
            lines.append("")
            lines.append("## Attachments")
            lines.append("")
            for item in attachments { lines.append(line(for: item)) }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func line(for item: Report.Item) -> String {
        var text = "\(item.number). **\(item.title)**"
        if let element = item.element {
            var details = [element.role]
            if let identifier = element.identifier { details.append("identifier `\(identifier)`") }
            if let label = element.label, label != item.title {
                details.append("label \"\(label)\"")
            }
            // A group with no name of its own: what it holds is what to search the source for.
            if element.label == nil, element.identifier == nil, let contents = element.contents {
                details.append("holding " + contents.map { "\"\($0)\"" }.joined(separator: ", "))
            }
            text += " (\(details.joined(separator: ", ")))"
        }
        // The elements holding it, such as the row or card with the identifier, tell apart
        // elements that share a label.
        let inside = item.ancestors.compactMap { ancestor -> String? in
            if ancestor.label == nil, ancestor.identifier == nil {
                return ancestor.contentsName.map { "\(ancestor.role) \($0)" }
            }
            return [ancestor.role, ancestor.label.map { "\"\($0)\"" }, ancestor.identifier.map { "`\($0)`" }]
                .compactMap { $0 }.joined(separator: " ")
        }
        if !inside.isEmpty { text += ", in " + inside.joined(separator: " in ") }
        if item.note.isEmpty {
            text += ". No note."
        } else {
            let ended = item.note.last.map { ".!?".contains($0) } ?? false
            text += ": \(item.note)\(ended ? "" : ".")"
        }
        if let snapshot = item.snapshot { text += " See \(snapshot)." }
        if !item.attachments.isEmpty { text += " Snapshots: \(item.attachments.joined(separator: ", "))." }
        return text
    }

    private static func list(_ numbers: [Int]) -> String {
        let words = numbers.map(String.init)
        guard words.count > 1, let last = words.last else { return words.first ?? "" }
        return words.dropLast().joined(separator: ", ") + " and " + last
    }
}
#endif
