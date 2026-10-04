#if REDLINE && canImport(UIKit)
import SwiftUI

/// Where reports go: an agent on the Mac, then one of its chats that work on this app, or a
/// new chat. The chat in the worktree the app was built from is marked and picked at first.
struct DestinationPicker: View {
    @Bindable var session: DebugSession

    private var width: CGFloat { min(session.screenSize.width - 24, 420) }

    var body: some View {
        ZStack(alignment: .top) {
            // Keeps the app underneath out of reach while picking.
            Color.black.opacity(0.45)
                .contentShape(Rectangle())
                .onTapGesture {}
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 14) {
                Text("Send to")
                    .font(.headline)
                    .foregroundStyle(Mono.text)
                    .accessibilityAddTraits(.isHeader)
                content
                buttons
            }
            .buttonStyle(.plain)
            .padding(16)
            .frame(width: width)
            .background(Mono.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Mono.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
            .padding(.top, session.safeAreaTop + 12)
        }
        .frame(width: session.screenSize.width, height: session.screenSize.height, alignment: .top)
    }

    @ViewBuilder
    private var content: some View {
        switch session.chatList {
        case .loading:
            HStack(spacing: 10) {
                ProgressView().tint(Mono.text)
                Text("Asking the Mac for its chats")
                    .font(.subheadline)
                    .foregroundStyle(Mono.secondary)
            }
            .frame(minHeight: 44)
        case .unavailable:
            Text("Couldn't reach the Mac. It will send the report to the chat working in the folder this app was built from.")
                .font(.subheadline)
                .foregroundStyle(Mono.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .loaded(let list):
            if list.agents.isEmpty {
                Text("No agents found on the Mac.")
                    .font(.subheadline)
                    .foregroundStyle(Mono.secondary)
            } else {
                agents(list.agents)
                chats(in: list)
            }
        }
    }

    private func agents(_ agents: [String]) -> some View {
        HStack(spacing: 8) {
            ForEach(agents, id: \.self) { agent in
                let selected = session.pickerAgent == agent
                Button { session.choose(agent: agent) } label: {
                    Text(HubLink.agentName(agent))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(selected ? Color.black : Mono.text)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background(selected ? Color.white : Mono.fill, in: Capsule(style: .continuous))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private func chats(in list: HubLink.ChatList) -> some View {
        let agent = session.pickerAgent ?? ""
        let chats = list.chats.filter { $0.agent == agent }
        return ScrollView {
            VStack(spacing: 0) {
                row(title: "New chat", detail: "In a new worktree from \(list.newChatBase ?? "main")", tag: nil, icon: "plus",
                    choice: Report.Destination(agent: agent, chat: nil, title: "a new \(HubLink.agentName(agent)) chat"))
                ForEach(chats) { chat in
                    Rectangle().fill(Mono.hairline).frame(height: 1)
                    row(title: chat.title, detail: detail(chat), tag: chat.sameWorktree ? "This build" : nil, icon: nil,
                        choice: Report.Destination(agent: agent, chat: chat.id, title: chat.title))
                }
                if chats.isEmpty {
                    Text("No open \(HubLink.agentName(agent)) chats work on this app.")
                        .font(.caption)
                        .foregroundStyle(Mono.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: session.screenSize.height * 0.45)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func detail(_ chat: HubLink.Chat) -> String {
        let ago = RelativeDateTimeFormatter().localizedString(for: chat.lastActive, relativeTo: .now)
        return "\(chat.folder) · \(ago)"
    }

    private func row(title: String, detail: String, tag: String?, icon: String?, choice: Report.Destination) -> some View {
        let selected = choice.sameChoice(as: session.pickerChoice)
        return Button { session.choose(choice) } label: {
            HStack(spacing: 12) {
                if let icon {
                    Image(systemName: icon)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Mono.text)
                        .frame(width: 28, height: 28)
                        .background(Mono.fill, in: Circle())
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Mono.text)
                            .lineLimit(1)
                        if let tag {
                            Text(tag)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Mono.text)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Mono.fill, in: Capsule(style: .continuous))
                        }
                    }
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Mono.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "checkmark")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Mono.text)
                    .opacity(selected ? 1 : 0)
            }
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var buttons: some View {
        let unavailable = session.chatList == .unavailable
        let loading = session.chatList == .loading
        let ready = unavailable || session.pickerChoice?.agent == session.pickerAgent
        let primary = session.sendsAfterPicking ? (unavailable ? "Send anyway" : "Send") : "Done"
        return HStack {
            Button("Cancel") { session.cancelDestinations() }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Mono.secondary)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            Spacer()
            Button { session.confirmDestination() } label: {
                Text(primary)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 18)
                    .frame(height: 38)
                    .background(Color.white.opacity(ready && !loading ? 1 : 0.4), in: Capsule(style: .continuous))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .allowsHitTesting(ready && !loading)
            .accessibilityAddTraits(ready && !loading ? [] : .isStaticText)
        }
    }
}
#endif
