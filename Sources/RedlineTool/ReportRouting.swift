#if os(macOS)
import Foundation

/// Where a report goes.
enum ReportDestination: Equatable {
    /// An open chat: the one the user picked on the phone, or the only chat working in the
    /// worktree the app was built from.
    case chat(Agent, id: String)
    /// A new chat, in a worktree of its own made from the one the app was built from: picked on
    /// the phone, or because no chat works there. `pick` names the phone's "New chat" pick: the
    /// first report with it starts the chat, later ones go to that chat.
    case newChat(Agent, folder: String, pick: String?)
    /// Nothing says where: several chats work in the worktree and none was picked, or the
    /// report doesn't say where the app was built. It waits in the inbox.
    case undecided(reason: String)
}

/// Decides where a report goes, from what the phone saved with it and the open chats.
enum Routing {
    static func worktree(of report: URL) -> String? {
        ReportListing.load(from: report)?.app?.sourceFile.map(Worktree.root(of:))
    }

    static func destination(of report: URL, bundleID: String, list: (_ bundleID: String, _ sourceFile: String?) -> HubMessage.ChatList) -> ReportDestination {
        // A listing without its app reads as if there were none, as it always has.
        let listing = ReportListing.load(from: report).flatMap { $0.app == nil ? nil : $0 }
        let worktree = listing?.app?.sourceFile.map(Worktree.root(of:))
        if let pick = listing?.destination, let agent = Agent(rawValue: pick.agent) {
            if let chat = pick.chat { return .chat(agent, id: chat) }
            guard let worktree else { return .undecided(reason: "The report doesn't say which worktree the app was built from") }
            return .newChat(agent, folder: worktree, pick: pick.newChat)
        }
        guard let worktree else { return .undecided(reason: "The report doesn't say which worktree the app was built from") }
        let directory = list(bundleID, listing?.app?.sourceFile)
        let here = directory.chats.filter(\.isSameWorktree)
        if here.count == 1, let chat = here.first, let agent = Agent(rawValue: chat.agent) { return .chat(agent, id: chat.id) }
        if here.isEmpty, let agent = directory.agents.first.flatMap(Agent.init(rawValue:)) { return .newChat(agent, folder: worktree, pick: nil) }
        return .undecided(reason: "\(here.count) chats work in \(URL(filePath: worktree).lastPathComponent); pick one on the phone")
    }
}
#endif
