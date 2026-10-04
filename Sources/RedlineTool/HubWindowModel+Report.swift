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
    }

    /// The report's snapshots in the order the agent gets them: each screen's snapshots, then the
    /// snapshots attached to notes.
    ///
    /// Without a complete report.json, the folder's snapshots in name order, which for UUID names
    /// says nothing about the report's order.
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
                    item.title.flatMap { title in item.attachments.map { (number, item.screenTitle ?? title, $0) } }
                }
            }).allPresent()
        else {
            return ReportContent.snapshots(in: folder).map {
                ReportSnapshot(file: $0, title: "Snapshot", notes: [])
            }
        }
        let shown = shownSnapshots.flatMap { $0 }.map { title, file, notes in
            ReportSnapshot(file: folder.appending(path: file), title: title, notes: notes)
        }
        let attached = items.flatMap { number, title, attachments in
            attachments.map { ReportSnapshot(file: folder.appending(path: $0), title: title, notes: [number]) }
        }
        return (shown + attached).filter { FileManager.default.fileExists(atPath: $0.file.path) }
    }

    /// The first snapshot that shows a note.
    nonisolated static func snapshot(showing note: Int, in snapshots: [ReportSnapshot]) -> URL? {
        snapshots.first { $0.notes.contains(note) }?.file
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
    /// Nil when the report went to no chat.
    nonisolated static func chat(of report: URL) -> ChatLink? {
        let claim = (try? Data(contentsOf: report.appending(path: Inbox.claimFile))).flatMap {
            try? HubPaths.decoder.decode(Claim.self, from: $0)
        }
        let folder = claim.flatMap { $0.folder.isEmpty ? nil : $0.folder }
        if let delivery = ChatDelivery.load(from: report) {
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
