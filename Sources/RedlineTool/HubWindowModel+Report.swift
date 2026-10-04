#if os(macOS)
import Foundation

extension HubWindowModel {
    /// A picture as the agent gets it, with the numbered outlines already drawn in, and the
    /// notes it shows.
    struct Picture: Equatable, Sendable {
        var file: URL
        /// The screen's title, or the title of the note the picture is attached to.
        var title: String
        var notes: [Int]
        /// The notes whose outline this picture shows most of, when a screen is split into parts.
        var mainFor: [Int] = []
    }

    /// The report's pictures in the order the agent gets them: each screen's pictures, then each
    /// note's own pictures, including the picture of an element note from an older report.
    ///
    /// Only the files `ReportContent.pictures(in:)` reads, so a name that leads out of the report's
    /// folder, or a link to another file on the Mac, is left out.
    nonisolated static func pictures(in folder: URL) -> [Picture] {
        let listing = ReportListing.load(from: folder)
        guard let screens = listing?.screens,
            let images = screens.map({ screen in
                screen.images.map { image in image.notes.map { (screen.title, image.file, $0) } }.allPresent()
            }).allPresent(),
            let items = listing?.items?.map({ item in
                item.number.flatMap { number in
                    item.title.flatMap { title in
                        item.attachments.map {
                            (number: number, title: item.screenTitle ?? title, attachments: $0, picture: item.picture)
                        }
                    }
                }
            }).allPresent()
        else {
            return ReportContent.pictures(in: folder).map {
                Picture(file: $0, title: $0.deletingPathExtension().lastPathComponent, notes: [])
            }
        }
        func mainFor(_ file: String) -> [Int] { items.filter { $0.picture == file }.map(\.number).sorted() }
        let screenImages = images.flatMap { $0 }
        let shown = screenImages.map { title, file, notes in
            Picture(file: folder.appending(path: file), title: title ?? "Screen", notes: notes, mainFor: mainFor(file))
        }
        let screenFiles = screenImages.map { _, file, _ in file }
        let attached = items.flatMap { item in
            ReportContent.ownPictures(
                picture: item.picture,
                attachments: item.attachments,
                screenPictures: screenFiles
            ).map {
                Picture(
                    file: folder.appending(path: $0),
                    title: item.title,
                    notes: [item.number],
                    mainFor: item.picture == $0 ? [item.number] : []
                )
            }
        }
        let safe = Set(ReportContent.pictures(in: folder, listing: listing))
        return (shown + attached).filter { safe.contains($0.file) }
    }

    /// The picture that shows most of a note's outline, as the report names it, or else the first
    /// picture that shows the note.
    nonisolated static func picture(showing note: Int, in pictures: [Picture]) -> URL? {
        (pictures.first { $0.mainFor.contains(note) } ?? pictures.first { $0.notes.contains(note) })?.file
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
    /// has. A claim whose hand-over was interrupted doesn't count, since that chat never got the
    /// report.
    ///
    /// Nil when the report went to no chat.
    nonisolated static func chat(of report: URL) -> ChatLink? {
        let claim = Inbox.activeClaim(of: report)
        let folder = claim.flatMap { $0.folder.isEmpty ? nil : $0.folder }
        if let delivery = ChatDelivery.load(from: report),
            !(delivery.isPending && claim.map { $0.claimedAt > delivery.deliveredAt } == true)
        {
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
