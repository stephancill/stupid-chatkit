import StupidChatKit
import SwiftUI

/// A Chats list on `ChatListViewModel` with one backend's provider, opening each row in the kit's chat screen.
struct ContentView: View {
    @StateObject private var list = ChatListViewModel<String>(sources: {
        [ChatListSource(provider: DemoChatListProvider(), accountId: "demo", label: "Cairn")]
    })

    var body: some View {
        NavigationStack {
            List(list.chats) { chat in
                NavigationLink(value: chat) {
                    ChatRow(chat: chat)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Chats")
            .navigationDestination(for: ChatSummary<String>.self) { chat in
                NetworkChatView(viewModel: list.follow(AdapterChatViewModel(adapter: DemoChatAdapter(chatId: chat.destination), accountId: chat.accountId), chatId: chat.id))
            }
            .task { await list.load() }
            .refreshable { await list.load() }
        }
    }
}

private struct ChatRow: View {
    let chat: ChatSummary<String>

    var body: some View {
        HStack(spacing: 10) {
            ChatAvatarImage(url: chat.avatarURL, title: chat.title, size: 48, colorKey: chat.avatarColorKey)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline) {
                    Text(chat.title).font(.headline).lineLimit(1)
                    if chat.isMuted {
                        Image(systemName: "speaker.slash.fill").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if let timestamp = chat.timestamp {
                        Text(timestamp, format: .dateTime.hour().minute())
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(alignment: .top) {
                    Text(chat.preview ?? chat.subtitle ?? "No messages yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    if chat.unreadCount > 0 {
                        Text("\(chat.unreadCount)")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(chat.isMuted ? Color.gray : Color.blue, in: Capsule())
                    }
                }
            }
        }
    }
}
