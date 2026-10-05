#if os(macOS)
import Foundation

extension HubWindowModel {
    /// A snapshot as the agent gets it, with the numbered outlines already drawn in, and the
    /// notes it shows.
    struct ReportSnapshot: Equatable, Sendable {
        var file: URL
        /// The screen's title, with what the snapshot shows when it is an earlier state or a part,
        /// or the title of the note the snapshot is attached to.
        var title: String
        var notes: [Int]
        /// The notes whose outline this snapshot shows most of, when a screen is split into parts.
        var mainFor: [Int] = []
    }

    /// The report's snapshots in the order the agent gets them: each screen's snapshots, then each
    /// note's own snapshots, including the picture of an element note from an older report.
    ///
    /// Only the files `ReportContent.snapshots(in:)` reads, so a name that leads out of the report's
    /// folder, or a link to another file on the Mac, is left out. Without a complete report.json,
    /// the folder's snapshots in name order, which for UUID names says nothing about the report's
    /// order.
    nonisolated static func snapshots(in folder: URL) -> [ReportSnapshot] {
        let listing = ReportListing.load(from: folder)
        guard let screens = listing?.screens,
            let shownSnapshots = screens.map({ screen in
                screen.snapshots.map { snapshot in
                    snapshot.notes.map { notes in
                        (
                            [screen.title ?? "Screen", snapshot.detail].compactMap { $0 }.joined(separator: ", "),
                            snapshot.file, notes
                        )
                    }
                }
                .allPresent()
            }).allPresent(),
            let items = listing?.items?.map({ item in
                item.number.flatMap { number in
                    item.title.flatMap { title in
                        item.attachments.map {
                            (number: number, title: item.screenTitle ?? title, attachments: $0, snapshot: item.snapshot)
                        }
                    }
                }
            }).allPresent()
        else {
            return ReportContent.snapshots(in: folder).map {
                ReportSnapshot(file: $0, title: "Snapshot", notes: [])
            }
        }
        func mainFor(_ file: String) -> [Int] { items.filter { $0.snapshot == file }.map(\.number).sorted() }
        let screenSnapshots = shownSnapshots.flatMap { $0 }
        let shown = screenSnapshots.map { title, file, notes in
            ReportSnapshot(file: folder.appending(path: file), title: title, notes: notes, mainFor: mainFor(file))
        }
        let screenFiles = screenSnapshots.map { _, file, _ in file }
        let attached = items.flatMap { item in
            ReportContent.ownSnapshots(
                snapshot: item.snapshot,
                attachments: item.attachments,
                screenSnapshots: screenFiles
            ).map {
                ReportSnapshot(
                    file: folder.appending(path: $0),
                    title: item.title,
                    notes: [item.number],
                    mainFor: item.snapshot == $0 ? [item.number] : []
                )
            }
        }
        let safe = Set(ReportContent.snapshots(in: folder, listing: listing))
        return (shown + attached).filter { safe.contains($0.file) }
    }

    /// The snapshot that shows most of a note's outline, as the report names it, or else the first
    /// snapshot that shows the note.
    nonisolated static func snapshot(showing note: Int, in snapshots: [ReportSnapshot]) -> URL? {
        (snapshots.first { $0.mainFor.contains(note) } ?? snapshots.first { $0.notes.contains(note) })?.file
    }

    /// A chat a report went to, to open it again. `folder` is where that chat works, when known.
    struct ChatLink: Equatable, Sendable {
        var agent: Agent
        var id: String
        var folder: String?
    }

    /// The chat a report went to: from what the hub saved when it delivered the report, or else the
    /// chat that took it.
    ///
    /// The same chat `destination(of:codexDatabase:)` names in the report's row: a report the hub
    /// left waiting, or set to go with a chat's next message, opens the chat that took it once one
    /// has. As there, no dates are compared: any claim next to a waiting delivery came after it. A
    /// claim whose hand-over was interrupted doesn't count, since that chat never got the report.
    ///
    /// Nil when the report went to no chat.
    nonisolated static func chat(of report: URL) -> ChatLink? {
        let claim = Inbox.activeClaim(of: report)
        let folder = claim.flatMap { $0.folder.isEmpty ? nil : $0.folder }
        if let delivery = ChatDelivery.load(from: report), !(delivery.isPending && claim != nil) {
            guard delivery.kind != .waiting, let agent = delivery.agent.flatMap(Agent.init(rawValue:)),
                let id = delivery.chat
            else { return nil }
            return ChatLink(agent: agent, id: id, folder: folder)
        }
        guard let claim, let agent = Agent(rawValue: claim.agent) else { return nil }
        if let id = ChatID.agentID(of: claim.chat, agent: agent) {
            return ChatLink(agent: agent, id: id, folder: folder)
        }
        // A chat the hub started: its ID is in what the agent's command printed.
        if ChatID.isStarted(claim.chat),
            let output = try? String(contentsOf: report.appending(path: Inbox.newChatOutputFile), encoding: .utf8),
            let started = AgentCommand.startedChat(agent, in: output), !started.didFail
        {
            return ChatLink(agent: agent, id: started.chat, folder: folder)
        }
        return nil
    }
}
#endif
