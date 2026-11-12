import Foundation
import StupidChatKit

/// A made-up chat backend, kept in memory. A real app puts its own API client here: the kit only sees the
/// adapter and the list provider below.
let cairn = ChatNetwork(rawValue: "cairn")

enum DemoBackend {
    struct Chat {
        let id: String
        let title: String
        var avatarURL: URL?
        var unreadCount = 0
        var isGroup = false
        var isMuted = false
        var presence: ChatPresence?
        var typing: [String] = []
        let messages: @Sendable (Date) -> [ChatMessage]
        var reactions: [String: [ChatReaction]] = [:]
    }

    static let you = ChatUser(id: "you", name: "You", avatarURL: nil)
    static let maya = person("maya", "Maya Chen", women: 44)
    static let jules = person("jules", "Jules", women: 65)
    static let theo = person("theo", "Theo", men: 12)
    static let nova = person("nova", "Nova", women: 8)
    static let kade = person("kade", "Kade", men: 75)
    static let people = [maya, jules, theo, nova, kade]

    /// Plays for the voice messages; each adds a fragment, since the player follows clips by id.
    static let voiceSample = "https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3"

    static let customEmojis: [String: ChatCustomEmoji] = [
        emoji(":summit:", "Mountain/3D/mountain_3d.png", tags: ["mountain", "top"]),
        emoji(":send-it:", "Flexed%20biceps/Default/3D/flexed_biceps_3d_default.png", tags: ["strong", "climb"]),
        emoji(":crux:", "Rock/3D/rock_3d.png", tags: ["rock", "boulder"]),
        emoji(":camp:", "Camping/3D/camping_3d.png", tags: ["tent", "weekend"]),
        emoji(":party:", "Party%20popper/3D/party_popper_3d.png", tags: ["celebrate"]),
    ].reduce(into: [:]) { $0[$1.key] = $1 }

    static let chats: [Chat] = [
        Chat(
            id: "climbing", title: "Climbing Crew 🧗", avatarURL: photo(1018, 200, 200), unreadCount: 3, isGroup: true, typing: ["Theo"],
            messages: { now in
                [
                    message("c1", nova, now, minutes: 52, "ok the new overhang wall is SO good :summit:"),
                    message("c2", theo, now, minutes: 49, "I fell off the purple one 11 times 😭"),
                    message("c3", you, now, minutes: 40, "going tomorrow after work if anyone wants to join"),
                    message("c4", nova, now, minutes: 14, "@theo what was your beta for the purple one?"),
                    message("c5", theo, now, minutes: 11, "start low, left heel hook, then just trust the sloper", replyTo: "c4"),
                    message("c6", maya, now, minutes: 6, "\"just trust the sloper\" is my new life motto", replyTo: "c5"),
                    message("c7", jules, now, minutes: 2, "save me a spot, I'll bring snacks 🍪"),
                ]
            },
            reactions: [
                "c1": [ChatReaction(emoji: ":summit:", count: 4, includesYou: true), ChatReaction(emoji: "🔥", count: 2, includesYou: false)],
                "c3": [ChatReaction(emoji: "🙋", count: 3, includesYou: false), ChatReaction(emoji: ":send-it:", count: 2, includesYou: false)],
                "c5": [ChatReaction(emoji: "💯", count: 2, includesYou: true)],
                "c6": [ChatReaction(emoji: "😂", count: 3, includesYou: false)],
            ],
        ),
        Chat(
            id: "coast", title: "Coast Weekend 🌊", avatarURL: photo(1050, 200, 200), isGroup: true,
            messages: { now in
                [
                    message("w1", maya, now, minutes: 240, "made it!! first batch from the coast", embeds: [
                        picture(1050, 1200, 900), picture(1052, 900, 900), picture(211, 900, 900),
                    ]),
                    message("w2", theo, now, minutes: 230, "the cliff path is covered in these", embeds: [
                        .video(url: URL(string: "https://interactive-examples.mdn.mozilla.net/media/cc0-videos/flower.mp4")!, posterURL: photo(152, 1280, 720), aspectRatio: 16 / 9, duration: "0:05", isGIF: false),
                    ]),
                    message("w3", maya, now, minutes: 120, nil, embeds: [.voice(previewId: voiceSample + "#maya", duration: 14, waveform: waveform(seed: 1))]),
                    message("w4", you, now, minutes: 110, nil, embeds: [.voice(previewId: voiceSample + "#you", duration: 6, waveform: waveform(seed: 4))]),
                    message("w5", theo, now, minutes: 90, "booked the cabin for saturday night https://seacliffcabins.com/the-loft", embeds: [
                        .card(title: "The Loft · Seacliff Cabins", subtitle: "Sleeps 4 · wood stove · deck over the water", systemImage: "link", imageURL: photo(424, 400, 400), link: URL(string: "https://seacliffcabins.com/the-loft")),
                    ]),
                    message("w6", nova, now, minutes: 72, "the lake on the drive up, from last year https://pinboard.social/nova/posts/1182", embeds: [
                        .linkPreview(title: "Nova (@nova)", subtitle: "still water, no signal, best morning of the summer", link: URL(string: "https://pinboard.social/nova/posts/1182"), media: [
                            picture(1011, 960, 1280), picture(1043, 960, 1280), picture(1036, 960, 1280), picture(1039, 960, 1280),
                        ]),
                    ]),
                    message("w6b", theo, now, minutes: 66, nil, embeds: [
                        .post(ChatPost(
                            authorName: "Seacliff Cabins",
                            authorHandle: "@seacliffcabins",
                            authorAvatarURL: photo(424, 200, 200),
                            isVerified: true,
                            date: now.addingTimeInterval(-3 * 3600),
                            text: "Storm watch this weekend 🌧️ Check-in moves to the lodge, and the cliff path closes at dusk. Boots strongly advised.",
                            media: [picture(1015, 1280, 853)],
                            link: URL(string: "https://pinboard.social/seacliffcabins/posts/88"),
                            quoted: ChatPost(
                                authorName: "Nova",
                                authorHandle: "@nova",
                                authorAvatarURL: nova.avatarURL,
                                text: "still water, no signal, best morning of the summer",
                                media: [picture(1011, 960, 1280)],
                                link: URL(string: "https://pinboard.social/nova/posts/1182"),
                            ),
                        )),
                    ]),
                    message("w7", theo, now, minutes: 60, nil, embeds: [
                        .file(url: URL(string: "https://seacliffcabins.com/files/packing-list.pdf")!, filename: "packing list.pdf", subtitle: "13 KB", thumbnailURL: nil),
                    ]),
                    message("w8", maya, now, minutes: 20, "same time next year? 🏕️"),
                ]
            },
            reactions: [
                "w1": [ChatReaction(emoji: "😍", count: 3, includesYou: true)],
                "w4": [ChatReaction(emoji: "😂", count: 2, includesYou: false)],
                "w8": [ChatReaction(emoji: "🙋", count: 4, includesYou: true), ChatReaction(emoji: ":party:", count: 2, includesYou: false)],
            ],
        ),
        Chat(
            id: "maya", title: "Maya Chen", avatarURL: maya.avatarURL, unreadCount: 3, presence: .online,
            messages: { now in
                [
                    message("m1", maya, now, minutes: 64, "are you still coming saturday?"),
                    message("m2", you, now, minutes: 61, "yes!! what time"),
                    message("m3", you, now, minutes: 60, "I can drive if we leave early"),
                    message("m4", maya, now, minutes: 6, "10ish. Jules is in too"),
                    message("m5", maya, now, minutes: 5, "this is where we're going 😍"),
                    message("m6", maya, now, minutes: 4, nil, embeds: [picture(1015, 1200, 900)]),
                ]
            },
            reactions: ["m3": [ChatReaction(emoji: "🙏", count: 1, includesYou: false)]],
        ),
        Chat(
            id: "jules", title: "Jules", avatarURL: jules.avatarURL, unreadCount: 1, presence: .recently,
            messages: { now in
                [
                    message("j1", you, now, minutes: 30, "did you end up getting the film camera?"),
                    message("j2", jules, now, minutes: 18, "I did 👀 first roll gets developed this week"),
                ]
            },
        ),
        Chat(
            id: "kade", title: "Kade", avatarURL: kade.avatarURL, presence: .lastSeen(Date().addingTimeInterval(-3600)),
            messages: { now in
                [
                    message("k1", kade, now, minutes: 300, "pushed the fix for the map tiles, can you try it on your phone?"),
                    message("k2", you, now, minutes: 290, "works now, and so fast 😄"),
                ]
            },
            reactions: ["k2": [ChatReaction(emoji: "❤️", count: 1, includesYou: false)]],
        ),
        Chat(
            id: "bookclub", title: "Book Club 📚", unreadCount: 14, isGroup: true, isMuted: true,
            messages: { now in
                [
                    message("b1", nova, now, minutes: 420, "who's finished it?"),
                    message("b2", kade, now, minutes: 400, "two chapters left, no spoilers"),
                ]
            },
        ),
    ]

    static func chat(id: String) -> Chat {
        chats.first { $0.id == id } ?? chats[0]
    }

    static func photo(_ id: Int, _ width: Int, _ height: Int) -> URL {
        URL(string: "https://picsum.photos/id/\(id)/\(width)/\(height)")!
    }

    static func picture(_ id: Int, _ width: Int, _ height: Int) -> ChatEmbed {
        .image(url: photo(id, width, height), aspectRatio: Double(width) / Double(height), alt: nil, link: nil, opensViewer: true)
    }

    /// A voice message's levels: a few phrases with pauses between them, the same every time.
    static func waveform(seed: Int) -> [Double] {
        (0 ..< 100).map { index in
            let phrase = sin(Double(index + seed) / 6.5)
            let syllable = abs(sin(Double(index * (seed + 3)) / 2.3))
            return phrase > -0.3 ? 0.25 + 0.75 * syllable * (phrase + 0.3) / 1.3 : 0.05
        }
    }

    private static func emoji(_ key: String, _ path: String, tags: [String]) -> ChatCustomEmoji {
        ChatCustomEmoji(key: key, url: URL(string: "https://cdn.jsdelivr.net/gh/microsoft/fluentui-emoji@main/assets/\(path)")!, category: "Cairn", tags: tags)
    }

    private static func person(_ id: String, _ name: String, women: Int? = nil, men: Int? = nil) -> ChatUser {
        let url = if let women {
            URL(string: "https://randomuser.me/api/portraits/women/\(women).jpg")
        } else {
            URL(string: "https://randomuser.me/api/portraits/men/\(men ?? 1).jpg")
        }
        return ChatUser(id: id, name: name, avatarURL: url)
    }

    private static func message(_ id: String, _ sender: ChatUser, _ now: Date, minutes: Double, _ text: String?, embeds: [ChatEmbed] = [], replyTo: String? = nil) -> ChatMessage {
        ChatMessage(id: id, sender: sender, timestamp: now.addingTimeInterval(-60 * minutes), text: text, embeds: embeds, replyToId: replyTo, isOwn: sender.id == you.id)
    }
}

/// The backend's rows for the Chats list.
struct DemoChatListProvider: ChatListProvider {
    let chatNetwork = cairn

    func chatList() async throws -> ChatListPage<String> {
        let now = Date()
        let chats = DemoBackend.chats.map { chat in
            let latest = chat.messages(now).last
            let body = latest?.previewText ?? ""
            let preview = if latest?.isOwn == true {
                "You: \(body)"
            } else if chat.isGroup, let latest {
                "\(latest.sender.name): \(body)"
            } else {
                body
            }
            return ChatSummary(
                id: chat.id,
                network: cairn,
                title: chat.title,
                avatarURL: chat.avatarURL,
                avatarColorKey: chat.id,
                preview: preview,
                timestamp: latest?.timestamp,
                unreadCount: chat.unreadCount,
                destination: chat.id,
                namesSenderInPreview: chat.isGroup,
                isMuted: chat.isMuted,
                presence: chat.presence,
            )
        }
        return ChatListPage(chats: chats, archived: [])
    }
}

/// One conversation on the backend. The kit offers each ability this conforms to: reactions, custom emoji,
/// voice playback, read receipts, typing, mentions and editing.
@MainActor
final class DemoChatAdapter: ChatReactionSending, ChatCustomEmojis, ChatAudioPreviewing, ChatReadReceipts, ChatTyping, ChatMentioning, ChatEditing {
    let network = cairn
    let key: String
    let canReply = true
    let acceptsAttachments = false
    let pollInterval: Duration? = nil
    var onChange: (() -> Void)?
    let info: ChatInfo
    var history: ChatHistory?
    private(set) var reactions: [String: [ChatReaction]]
    let acceptsReactions = true
    let customEmojis = DemoBackend.customEmojis
    let typingNames: [String]
    let mentionPattern = try? NSRegularExpression(pattern: "@([a-z]+)")
    let mentionNames = Dictionary(uniqueKeysWithValues: DemoBackend.people.map { ($0.id, $0.name) })
    private let chat: DemoBackend.Chat
    private var readCount: Int
    private var sentIds: Set<String> = []
    /// The backend's messages by id, and their order; a real adapter decodes its records instead.
    private var catalog: [String: ChatMessage] = [:]
    private var order: [String: Int64] = [:]
    private var version: Int64 = 0

    init(chatId: String) {
        chat = DemoBackend.chat(id: chatId)
        key = "cairn:\(chat.id)"
        reactions = chat.reactions
        typingNames = chat.typing
        readCount = chat.messages(Date()).count - chat.unreadCount
        var info = ChatInfo(title: chat.title, subtitle: chat.isGroup ? "5 members" : (chat.presence?.text ?? ""), showsSenderNames: chat.isGroup)
        info.avatarUserId = chat.id
        info.avatarURL = chat.avatarURL
        self.info = info
        for (index, message) in chat.messages(Date()).enumerated() {
            catalog[message.id] = message
            order[message.id] = Int64(index)
        }
    }

    private func record(_ message: ChatMessage) -> ChatRecord {
        catalog[message.id] = message
        version += 1
        return ChatRecord(id: message.id, sortKey: order[message.id] ?? 0, version: version, data: Data(message.id.utf8))
    }

    func fetch(_: ChatPageRequest) async throws -> ChatPage {
        let messages = catalog.values.sorted { order[$0.id, default: 0] < order[$1.id, default: 0] }
        return ChatPage(records: messages.map(record), earlier: nil)
    }

    func render(_ records: [ChatRecord]) -> ChatRendering {
        ChatRendering(messages: records.compactMap { catalog[$0.id] }, reactions: reactions)
    }

    func send(_ message: ChatOutgoing) async throws -> String? {
        try await Task.sleep(for: .milliseconds(600))
        let id = UUID().uuidString
        order[id] = (order.values.max() ?? 0) + 1
        sentIds.insert(id)
        try history?.write([record(ChatMessage(id: id, sender: DemoBackend.you, timestamp: Date(), text: message.text, replyToId: message.replyToId, isOwn: true))])
        return id
    }

    func receipt(for message: ChatMessage) -> ChatReceipt? {
        sentIds.contains(message.id) ? .sent : .seen
    }

    func isAfterReadPosition(_ message: ChatMessage) -> Bool {
        guard let index = order[message.id] else { return false }
        return index >= readCount
    }

    func markRead(upTo message: ChatMessage) -> (@MainActor () async throws -> Void)? {
        guard let index = order[message.id].map(Int.init), index >= readCount else { return nil }
        readCount = index + 1
        // A real backend sends the read position here.
        return {}
    }

    func reactors(of _: String, on _: String) -> [ChatReactor] {
        []
    }

    func yourEmojis(on messageId: String) -> [String] {
        reactions[messageId, default: []].filter(\.includesYou).map(\.emoji)
    }

    func toggleReaction(_ emoji: String, on messageId: String) async throws {
        var list = reactions[messageId, default: []]
        if let index = list.firstIndex(where: { $0.emoji == emoji }) {
            let reaction = list[index]
            let count = reaction.count + (reaction.includesYou ? -1 : 1)
            if count == 0 {
                list.remove(at: index)
            } else {
                list[index] = ChatReaction(emoji: emoji, count: count, includesYou: !reaction.includesYou)
            }
        } else {
            list.append(ChatReaction(emoji: emoji, count: 1, includesYou: true))
        }
        reactions[messageId] = list
        onChange?()
    }

    func draftDidChange(_: String) {}

    func mentionSuggestions(for query: String) -> [ChatUser] {
        DemoBackend.people.filter { query.isEmpty || $0.id.hasPrefix(query.lowercased()) || $0.name.lowercased().hasPrefix(query.lowercased()) }
    }

    func editableText(of message: ChatMessage) -> String? {
        message.isOwn ? message.text : nil
    }

    func edit(_ messageId: String, text: String) async throws {
        guard let old = catalog[messageId] else { return }
        try history?.write([record(ChatMessage(id: old.id, sender: old.sender, timestamp: old.timestamp, text: text, embeds: old.embeds, replyToId: old.replyToId, isOwn: true, isEdited: true))])
    }

    /// Voice messages play a sample from the web.
    func audioPreviewURL(for previewId: String) async -> URL? {
        URL(string: previewId)
    }

    func state() -> Data? {
        nil
    }

    func restore(state _: Data) {}
}
