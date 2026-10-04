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
    }

    /// The report's pictures in the order the agent gets them: each screen's pictures, then the
    /// pictures attached to notes.
    nonisolated static func pictures(in folder: URL) -> [Picture] {
        let listing = ReportListing.load(from: folder)
        guard let screens = listing?.screens,
              let images = screens.map({ screen in screen.images.map { image in image.notes.map { (screen.title, image.file, $0) } }.allPresent() }).allPresent(),
              let items = listing?.items?.map({ item in
                  item.number.flatMap { number in item.title.flatMap { title in item.attachments.map { (number, item.screenTitle ?? title, $0) } } }
              }).allPresent()
        else {
            return ReportContent.pictures(in: folder).map { Picture(file: $0, title: $0.deletingPathExtension().lastPathComponent, notes: []) }
        }
        let shown = images.flatMap { $0 }.map { title, file, notes in Picture(file: folder.appending(path: file), title: title ?? "Screen", notes: notes) }
        let attached = items.flatMap { number, title, attachments in
            attachments.map { Picture(file: folder.appending(path: $0), title: title, notes: [number]) }
        }
        return (shown + attached).filter { FileManager.default.fileExists(atPath: $0.file.path) }
    }

    /// The first picture that shows a note.
    nonisolated static func picture(showing note: Int, in pictures: [Picture]) -> URL? {
        pictures.first { $0.notes.contains(note) }?.file
    }

    /// A chat a report went to, to open it again. `folder` is where that chat works, when known.
    struct ChatLink: Equatable, Sendable {
        var agent: Agent
        var id: String
        var folder: String?
    }

    /// The chat a report went to: from what the hub saved when it delivered the report, or else
    /// the chat that took it. Nil when the report went to no chat.
    nonisolated static func chat(of report: URL) -> ChatLink? {
        let claim = (try? Data(contentsOf: report.appending(path: Inbox.claimFile))).flatMap { try? HubPaths.decoder.decode(Claim.self, from: $0) }
        let folder = claim.flatMap { $0.folder.isEmpty ? nil : $0.folder }
        if let delivery = ReportDelivery.load(from: report) {
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
           let started = AgentCommand.startedChat(agent, in: output), !started.didFail {
            return ChatLink(agent: agent, id: started.chat, folder: folder)
        }
        return nil
    }
}
#endif
