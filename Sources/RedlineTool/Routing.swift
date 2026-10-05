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
    /// report doesn't say where the app was built, or names a folder that doesn't build the app.
    /// It waits in the inbox.
    case undecided(reason: String)
}

/// Decides where a report goes, from what the phone saved with it and the open chats.
enum Routing {
    /// The worktree the app was built from, as the report says, when that folder builds the
    /// report's app.
    ///
    /// The phone writes the report, so a path to any other project isn't used: the hub makes
    /// worktrees and starts chats in this folder.
    static func worktree(of report: URL, bundleID: String) -> String? {
        worktree(of: ReportListing.load(from: report), bundleID: bundleID)
    }

    private static func worktree(of listing: ReportListing?, bundleID: String) -> String? {
        guard let worktree = listing?.app?.sourceFile.map(Worktree.root(of:)),
            ChatDirectory.apps.bundleIDs(in: worktree).contains(bundleID)
        else { return nil }
        return worktree
    }

    /// The user's pick, saved with the report on the phone; nil when there's none, or when it names
    /// an agent the hub doesn't send reports to.
    static func pick(of report: URL) -> ReportListing.Pick? {
        ReportListing.load(from: report)?.destination.flatMap { Agent(rawValue: $0.agent) == nil ? nil : $0 }
    }

    /// Where a report goes. `lastAgent` is the agent last used on the app: a new chat starts with
    /// it while it can start one, else with the first agent that can.
    static func destination(
        of report: URL,
        bundleID: String,
        lastAgent: String? = nil,
        list: (_ bundleID: String, _ sourceFile: String?) -> HubMessage.ChatList
    ) -> ReportDestination {
        // A listing without its app reads as if there were none, as it always has.
        let listing = ReportListing.load(from: report).flatMap { $0.app == nil ? nil : $0 }
        let worktree = worktree(of: listing, bundleID: bundleID)
        let unknown =
            listing?.app?.sourceFile == nil
            ? "The report doesn't say which worktree the app was built from"
            : "The worktree the report names doesn't build \(bundleID)"
        if let pick = listing?.destination, let agent = Agent(rawValue: pick.agent) {
            if let chat = pick.chat { return .chat(agent, id: chat) }
            guard let worktree else { return .undecided(reason: unknown) }
            return .newChat(agent, folder: worktree, pick: pick.newChat)
        }
        guard let worktree else { return .undecided(reason: unknown) }
        let directory = list(bundleID, listing?.app?.sourceFile)
        let here = directory.chats.filter(\.isSameWorktree)
        if here.count == 1, let chat = here.first, let agent = Agent(rawValue: chat.agent) {
            return .chat(agent, id: chat.id)
        }
        let startable = directory.newChats ?? directory.agents
        if here.isEmpty,
            let agent = (startable.first { $0 == lastAgent } ?? startable.first).flatMap(Agent.init(rawValue:))
        {
            return .newChat(agent, folder: worktree, pick: nil)
        }
        return .undecided(
            reason: "\(here.count) chats work in \(URL(filePath: worktree).lastPathComponent); pick one on the phone"
        )
    }
}
#endif
