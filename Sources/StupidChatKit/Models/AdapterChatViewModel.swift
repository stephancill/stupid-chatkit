import Foundation

/// What a chat shows about itself, above its messages.
public struct ChatInfo: Equatable, Sendable {
    public var title: String
    public var subtitle: String
    /// Names head each sender's group of bubbles; one-to-one chats turn them off.
    public var showsSenderNames: Bool
    /// The title is made of member names, such as an untitled group, so name redaction applies to it.
    public var titleIsMemberNames: Bool
    /// A one-to-one chat shows the other person beside its title: their picture, else their initials on their
    /// chat color, as their Chats row does.
    public var avatarUserId: String?
    public var avatarURL: URL?

    public init(title: String, subtitle: String, showsSenderNames: Bool = true, titleIsMemberNames: Bool = false) {
        self.title = title
        self.subtitle = subtitle
        self.showsSenderNames = showsSenderNames
        self.titleIsMemberNames = titleIsMemberNames
    }
}

/// A message the user is sending.
public struct ChatOutgoing {
    public let text: String
    public let attachment: ChatAttachment?
    public let replyToId: String?
    /// Parts of `text` to set in italics (UTF-16 ranges), such as a forwarded copy's "Forwarded". Networks with
    /// formatting apply them (Telegram's entities, Markdown with `markdownText`); plain-text networks leave them out.
    public var italics: [NSRange] = []
    /// Parts of `text` that link somewhere (UTF-16 ranges), such as a forwarded copy's "Forwarded" to the original.
    /// Networks with formatting apply them; plain-text networks leave them out.
    public var links: [ChatOutgoingLink] = []

    public init(text: String, attachment: ChatAttachment?, replyToId: String?, italics: [NSRange] = [], links: [ChatOutgoingLink] = []) {
        self.text = text
        self.attachment = attachment
        self.replyToId = replyToId
        self.italics = italics
        self.links = links
    }

    /// `text` with `italics` wrapped in `marker` and `links` as `[text](url)`, for networks whose messages are
    /// Markdown. A link and italics on the same text read `[*text*](url)`.
    public func markdownText(marker: String = "*") -> String {
        let length = (text as NSString).length
        var openings: [Int: String] = [:]
        var closings: [Int: String] = [:]
        for link in links where NSMaxRange(link.range) <= length {
            openings[link.range.location, default: ""] += "["
            closings[NSMaxRange(link.range), default: ""] = "](\(link.url.absoluteString))" + (closings[NSMaxRange(link.range)] ?? "")
        }
        for range in italics where NSMaxRange(range) <= length {
            openings[range.location, default: ""] += marker
            closings[NSMaxRange(range), default: ""] = marker + (closings[NSMaxRange(range)] ?? "")
        }
        let result = NSMutableString(string: text)
        for position in Set(openings.keys).union(closings.keys).sorted(by: >) {
            result.insert((closings[position] ?? "") + (openings[position] ?? ""), at: position)
        }
        return result as String
    }
}

/// A link on part of an outgoing message's text.
public struct ChatOutgoingLink: Equatable, Sendable {
    public let range: NSRange
    public let url: URL

    public init(range: NSRange, url: URL) {
        self.range = range
        self.url = url
    }
}

/// One conversation on one network, as the chat framework drives it. An adapter only translates: it loads and
/// sends through its network and maps what comes back to `ChatMessage`s. The framework (`AdapterChatViewModel`)
/// owns the screen's state and the behavior every chat shares: connecting, polling, paging, unread counting and
/// the divider, read-marker debouncing, snapshots, drafts and optimistic sending.
///
/// Optional abilities are separate protocols (editing, deleting, reactions, unseen reactions, read receipts, audio previews, live updates,
/// quoted messages, windows of older history, typing, mentions, custom emoji, stickers, voice messages, commands, links), so a chat offers an action exactly when its adapter
/// implements it.
@MainActor
public protocol ChatAdapter: AnyObject {
    var network: ChatNetwork { get }
    /// The network and its id for the conversation, such as `spotify:<chat id>`; the account id is added to it.
    var key: String { get }
    /// Whether messages can be sent as replies.
    var canReply: Bool { get }
    /// Whether messages can carry a photo or file. Read again once connected, since a server may not allow
    /// uploads; before that, whether it might.
    var acceptsAttachments: Bool { get }
    /// How often to fetch the newest messages while the chat is open; `nil` when the network pushes them and the
    /// adapter calls `onChange`.
    var pollInterval: Duration? { get }
    /// Set by the framework; the adapter calls it when what it shows changes on its own, such as a profile name or
    /// track details loading after the messages did.
    var onChange: (() -> Void)? { get set }

    var info: ChatInfo { get }
    /// Set by the framework before anything else: the chat's stored history. The adapter writes what arrives
    /// outside a page fetch here (live updates, sent messages, the result of an action such as a reaction).
    var history: ChatHistory? { get set }

    /// A page of history for the request. `.after` and `.around` come only for adapters that adopt
    /// `ChatWindowing`. Fetching never marks anything read on the network.
    func fetch(_ request: ChatPageRequest) async throws -> ChatPage
    /// The messages, oldest first, and their reaction totals keyed by message id, that stored records show as.
    /// `records` are a stretch of history oldest first, followed by the records related to them; records that
    /// aren't messages of their own (`ChatRecord.relatesTo`) render into the ones they relate to.
    func render(_ records: [ChatRecord]) -> ChatRendering
    /// The cursor for the history before a stored message, for a gap that live updates opened rather than a page;
    /// `nil` where the network's cursors can't be made from a message, and the framework refetches the newest page.
    func cursor(before record: ChatRecord) -> ChatCursor?

    /// Sends and returns the network's id for the message, or `nil` when the network doesn't say. The framework
    /// fetches the newest page afterwards unless the message's record is stored by then.
    func send(_ message: ChatOutgoing) async throws -> String?
    /// Whether the message is past the user's read position on the network.
    func isAfterReadPosition(_ message: ChatMessage) -> Bool
    /// Moves the read position up to the message, if that passes unread messages, and returns what tells the
    /// network, which the framework sends shortly after; `nil` when there is nothing to send.
    func markRead(upTo message: ChatMessage) -> (@MainActor () async throws -> Void)?
    func reactors(of emoji: String, on messageId: String) -> [ChatReactor]

    /// What the adapter keeps about the chat besides its history (names, read positions, …), for the next visit;
    /// `nil` when there is nothing to keep.
    func state() -> Data?
    func restore(state: Data)
}

public extension ChatAdapter {
    func cursor(before _: ChatRecord) -> ChatCursor? {
        nil
    }
}

/// What a stretch of stored history shows as.
public struct ChatRendering: Sendable {
    public var messages: [ChatMessage]
    public var reactions: [String: [ChatReaction]]

    public init(messages: [ChatMessage], reactions: [String: [ChatReaction]] = [:]) {
        self.messages = messages
        self.reactions = reactions
    }
}

/// One chat's stored history, as its adapter sees it.
@MainActor
public final class ChatHistory {
    public let store: ChatStore
    public let chatKey: String

    public init(store: ChatStore, chatKey: String) {
        self.store = store
        self.chatKey = chatKey
    }

    /// Stores a newest page the adapter fetched itself, such as a refresh after a pushed update that names no
    /// message (`ChatStore.apply`).
    public func apply(newest page: ChatPage) throws {
        try store.apply(page, for: .newest, chatKey: chatKey)
    }

    /// Stores records that arrived outside a page (`ChatStore.write`).
    public func write(_ records: [ChatRecord]) throws {
        try store.write(records, chatKey: chatKey)
    }

    public func delete(ids: [String]) throws {
        try store.delete(ids: ids, chatKey: chatKey)
    }

    /// Changes a stored record, such as an optimistic reaction; `transform` returning `nil` leaves it.
    public func update(id: String, _ transform: (ChatRecord) throws -> ChatRecord?) throws {
        try store.update(id: id, chatKey: chatKey, transform)
    }

    public func record(id: String) throws -> ChatRecord? {
        try store.record(id: id, chatKey: chatKey)
    }

    /// The records related to these, wherever they are stored.
    public func related(to ids: [String]) throws -> [ChatRecord] {
        try store.related(to: ids, chatKey: chatKey)
    }
}

/// Changing the text of the user's sent messages.
@MainActor
public protocol ChatEditing: ChatAdapter {
    /// The text to edit the message from, such as a photo's caption, or `nil` when the network doesn't let this
    /// one be edited (someone else's, too old, or with formatting an edit would lose).
    func editableText(of message: ChatMessage) -> String?
    /// Saves the new text. When it returns, `messages` shows the edit or the network's copy of it.
    func edit(_ messageId: String, text: String) async throws
}

/// Deleting the user's sent messages for everyone in the chat.
@MainActor
public protocol ChatDeleting: ChatAdapter {
    /// Whether the network lets the user delete this message.
    func canDelete(_ message: ChatMessage) -> Bool
    /// When it returns, `messages` no longer shows the message, or shows it as deleted.
    func delete(_ messageId: String) async throws
}

/// Buttons under messages that ask the network to act (`ChatMessageButton.Action.press`), such as a bot's inline
/// keyboard. Without it they show dimmed.
@MainActor
public protocol ChatButtonPressing: ChatAdapter {
    /// What the network answers, if anything. A change the press makes to the message arrives as usual.
    func press(_ button: ChatMessageButton, on messageId: String) async throws -> ChatButtonAnswer?
}

/// A choice the chat offers in its composer, such as the model an assistant answers with: an icon button at the end of
/// the text row, which opens a menu of items headed by the current value.
@MainActor
public protocol ChatComposerMenus: ChatAdapter {
    /// `nil` hides the button.
    var composerMenu: ChatComposerMenu? { get }
    /// The user chose an item. The adapter applies it and calls `onChange` when `composerMenu` changes.
    func selectComposerMenuItem(_ itemId: String)
}

/// The composer's menu: its button's icon and the items it opens, in sections separated by lines.
public struct ChatComposerMenu: Equatable, Sendable {
    /// The current value, such as the selected model's name: the menu's heading and VoiceOver's value for the button.
    public var title: String
    /// What the button chooses, for VoiceOver, such as "Model".
    public var accessibilityLabel: String
    /// The button's SF Symbol; a filter icon by default.
    public var systemImage: String
    public var sections: [[ChatComposerMenuItem]]

    public init(title: String, accessibilityLabel: String, systemImage: String = "line.3.horizontal.decrease", sections: [[ChatComposerMenuItem]]) {
        self.title = title
        self.accessibilityLabel = accessibilityLabel
        self.systemImage = systemImage
        self.sections = sections
    }
}

public struct ChatComposerMenuItem: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var systemImage: String?
    /// Shown with a checkmark.
    public var isSelected: Bool

    public init(id: String, title: String, subtitle: String? = nil, systemImage: String? = nil, isSelected: Bool = false) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.isSelected = isSelected
    }
}

/// Chats the user may only be allowed to read, such as a guest on a server that lets guests only read.
@MainActor
public protocol ChatReadOnlyAccess: ChatAdapter {
    /// Read once connected; while true the composer is disabled.
    var isReadOnly: Bool { get }
}

/// An adapter whose in-flight work the user can stop, such as an assistant still answering. While `isBusy`, the
/// composer's send button becomes a stop button in place of send; tapping it calls `stop()`. The adapter calls
/// `onChange` when `isBusy` changes.
@MainActor
public protocol ChatStoppable: ChatAdapter {
    /// Read whenever the composer updates. While true the send button is a stop button.
    var isBusy: Bool { get }
    /// The user tapped stop.
    func stop()
}

/// Reacting to messages.
@MainActor
public protocol ChatReactionSending: ChatAdapter {
    /// Read once connected, since a server may not allow reactions.
    var acceptsReactions: Bool { get }
    func yourEmojis(on messageId: String) -> [String]
    /// Adds the emoji, or removes it when you already reacted with it. The adapter shows the change at once
    /// and puts it back if the network refuses it.
    func toggleReaction(_ emoji: String, on messageId: String) async throws
}

/// A network that takes only some emoji as reactions, such as Telegram's fixed set: the picker offers just these,
/// rather than every emoji.
@MainActor
public protocol ChatReactionChoices: ChatReactionSending {
    /// In the network's order; nil until known.
    var reactionChoices: [String]? { get }
}

/// Reactions others put on the user's messages since the user last saw them, which the chat badges and jumps
/// between.
@MainActor
public protocol ChatUnseenReactions: ChatAdapter {
    /// Ids of the user's messages with unseen reactions, oldest first; they may include messages that aren't
    /// loaded.
    var unseenReactionMessageIds: [String] { get }
    /// The user saw these messages on screen. Drops their reactions from the unseen ones at once and returns what
    /// tells the network, which the framework sends shortly after; `nil` when there is nothing to send. The send
    /// covers every message seen since the last send that went through.
    func markReactionsSeen(on messageIds: Set<String>) -> (@MainActor () async throws -> Void)?
}

/// Whether others have read the user's messages, which show as sent or seen.
@MainActor
public protocol ChatReadReceipts: ChatAdapter {
    /// `.seen` once someone else in the chat has read the user's message (in a group, anyone), else `.sent`;
    /// `nil` where the network shows none, such as a chat with yourself.
    func receipt(for message: ChatMessage) -> ChatReceipt?
}

/// Inline previews for `.audio` embeds.
@MainActor
public protocol ChatAudioPreviewing: ChatAdapter {
    func audioPreviewURL(for previewId: String) async -> URL?
}

/// Updates the network pushes while the chat is open. The adapter applies them and calls `onChange`; a network
/// can also name a `pollInterval` as a fallback.
@MainActor
public protocol ChatLiveUpdating: ChatAdapter {
    /// Set by the framework: the connection closed, with an error unless the app closed it itself.
    var onConnectionLost: ((Error?) -> Void)? { get set }
    /// Set by the framework: something failed outside a call it made, such as an upload after its message posted.
    var onError: ((Error) -> Void)? { get set }
    /// Set by the framework: the adapter calls it when pushed updates may have been missed, such as after its
    /// connection reconnected (`LiveUpdate.catchUp`), and the framework loads the newest messages.
    var onCatchUp: (() -> Void)? { get set }
    /// Called once the newest messages have loaded.
    func startFollowing() async
    func stopFollowing()
}

/// Messages that replies quote but that aren't among the loaded ones.
@MainActor
public protocol ChatReferenceResolving: ChatAdapter {
    var referencedMessages: [String: ChatMessage] { get }
    /// Quoted messages the network couldn't return, such as deleted ones.
    var unavailableReferences: Set<String> { get }
}

/// Fetching history around a message and after a cursor (`ChatPageRequest.around`, `.after`), so the chat can jump
/// to an old message without loading everything in between. Without it, a jump pages back from the newest.
@MainActor
public protocol ChatWindowing: ChatAdapter {}

/// Typing indications, both ways.
@MainActor
public protocol ChatTyping: ChatAdapter {
    /// Names of the other users typing, in the order they started.
    var typingNames: [String] { get }
    /// Called as the user edits the draft.
    func draftDidChange(_ draft: String)
}

/// `@` mentions in message text.
@MainActor
public protocol ChatMentioning: ChatAdapter {
    /// Matches a mention written in the text, such as `@user_id`, which shows by name and is tappable; `nil`
    /// for a network that marks mentions by position (`ChatMessage.mentions`).
    var mentionPattern: NSRegularExpression? { get }
    /// User id → name.
    var mentionNames: [String: String] { get }
    func mentionSuggestions(for query: String) -> [ChatUser]
}

/// Custom emoji the network defines, written as `:name:` keys in reactions and text.
@MainActor
public protocol ChatCustomEmojis: ChatAdapter {
    /// Key → emoji; empty until the network's catalog loads, then the adapter calls `onChange`.
    var customEmojis: [String: ChatCustomEmoji] { get }
}

/// Stickers the user can send: their recent stickers and installed sets.
@MainActor
public protocol ChatStickerSending: ChatAdapter {
    /// Recently used first, with its stickers; the other sets may leave theirs to `stickers(inSet:)`.
    func stickerSets() async throws -> [ChatStickerSet]
    func stickers(inSet id: String) async throws -> [ChatSticker]
    /// Stickers for an emoji, from the user's sets first, then ones the network suggests.
    func stickers(forEmoji emoji: String) async throws -> [ChatSticker]
    /// Returns the sent message's id, as `send(_:)` does.
    func send(sticker: ChatSticker, replyToId: String?) async throws -> String?
}

/// Voice messages the user records in the composer.
@MainActor
public protocol ChatVoiceSending: ChatAdapter {
    /// Returns the sent message's id, as `send(_:)` does.
    func send(voice: ChatVoiceNote, replyToId: String?) async throws -> String?
}

/// Text that runs a command rather than posting a message, which may post nothing.
@MainActor
public protocol ChatCommanding: ChatAdapter {
    func isCommand(_ text: String) -> Bool
    func sendCommand(_ text: String, replyToId: String?) async throws
}

/// Links to messages: Copy Link, and the link a forwarded copy's "Forwarded" goes to.
@MainActor
public protocol ChatMessageLinking: ChatAdapter {
    /// `nil` for a message the network has no link to.
    func link(toMessage messageId: String) -> URL?
}

/// Links in messages that point into the chat itself.
@MainActor
public protocol ChatLinking: ChatMessageLinking {
    func linkTarget(for url: URL) -> ChatLinkTarget?
    var linkBaseURL: URL? { get }
    /// How a link written as its URL reads, such as "Message in #general"; `nil` keeps the URL.
    func placeLabel(forLink url: URL) -> ChatPlaceLabel?
    /// Finds references to places written in text, such as `#room_id`; the first capture group is the reference.
    var referencePattern: NSRegularExpression? { get }
    /// How a reference reads; `nil` keeps it as written.
    func placeLabel(forReference reference: String) -> ChatPlaceLabel?
    /// What starts a reference the composer completes, such as `#`.
    var referencePrefix: String? { get }
    /// Places to offer for a typed reference; an empty query lists them to browse.
    func referenceSuggestions(for query: String) -> [ChatReferenceSuggestion]
}

enum AdapterChatViewModelLimits {
    /// Messages a chat opens with.
    static let windowCount = 60
    /// Messages a scroll past either end shows more of.
    static let pageCount = 50
    /// How many times opening goes further back while every message shown is unread.
    static let unreadExtensions = 4
}

/// The shared chat screen's model for a network that has a `ChatAdapter`.
@MainActor
public final class AdapterChatViewModel<Adapter: ChatAdapter>: ChatViewModel {
    public let adapter: Adapter
    /// The account the chat belongs to (`Account.id`).
    public let accountId: String
    public let store: ChatStore
    /// From a successful `connect()` until `disconnect()` or a lost connection; `connect()` runs again when the
    /// app becomes active.
    private var isOpen = false
    private var isConnecting = false
    /// Where the shown stretch of history sits in the store.
    private var position = ChatStore.WindowPosition.newest(count: AdapterChatViewModelLimits.windowCount)
    /// The shown stretch as last read, rendered again whenever the adapter changes.
    private var window = ChatStore.Window.empty
    /// Whether the window shows the newest messages, so it moves to a newer chunk when one starts.
    private var followsNewest = true
    private var storeObservation: ChatStoreObservation?
    private var stateSaveTask: Task<Void, Never>?
    /// Voice messages being sent this visit → the recording the composer made, played while it sends.
    private var recordings: [String: ChatVoiceNote] = [:]
    /// A computed property, since generic classes can't have static stored ones.
    private static var jumpPageLimit: Int {
        20
    }

    public init(adapter: Adapter, accountId: String, store: ChatStore = ChatKit.store, draftStore: ChatDraftStore = ChatDraftStore()) {
        self.adapter = adapter
        self.accountId = accountId
        self.store = store
        let chatKey = "\(accountId)|\(adapter.key)"
        if let state = try? store.state(chatKey: chatKey) {
            adapter.restore(state: state)
        }
        adapter.history = ChatHistory(store: store, chatKey: chatKey)
        super.init(
            network: adapter.network,
            chatKey: chatKey,
            title: adapter.info.title,
            subtitle: adapter.info.subtitle,
            canReply: adapter.canReply,
            offersAttachments: adapter.acceptsAttachments,
            mentionPattern: (adapter as? any ChatMentioning)?.mentionPattern ?? nil,
            draftStore: draftStore,
        )
        tracksUnseenReactions = adapter is any ChatUnseenReactions
        showsReadReceipts = adapter is any ChatReadReceipts
        adapter.onChange = { [weak self] in self?.adapterDidChange() }
        if let live = adapter as? any ChatLiveUpdating {
            live.onConnectionLost = { [weak self] error in self?.connectionLost(error) }
            live.onError = { [weak self] error in self?.errorMessage = error.localizedDescription }
            live.onCatchUp = { [weak self] in
                guard let self, isOpen else { return }
                // Updates may have been missed, so stored messages stop counting as current until a fetch.
                store.raiseEpoch(accountId: accountId)
                Task { await self.poll() }
            }
        }
        storeObservation = store.observe(chatKey: chatKey) { [weak self] in self?.reloadWindow() }
        openAtFirstUnread()
        restoreOutbox()
        // In the first render, rather than appearing once history arrives.
        placeUnreadDivider()
    }

    /// Reads the newest stored messages, going back further (up to a limit) while all of them are unread, so the
    /// chat opens at the "New Messages" divider.
    private func openAtFirstUnread() {
        reloadWindow()
        var extensions = 0
        while extensions < AdapterChatViewModelLimits.unreadExtensions, window.hasStoredEarlier,
              let oldest = history.first(where: { !$0.isNotice }), isUnread(oldest)
        {
            extend(earlierBy: AdapterChatViewModelLimits.windowCount)
            extensions += 1
        }
    }

    override public func connect() async {
        guard !isOpen, !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }
        if messages.isEmpty {
            state = .connecting
        }
        errorMessage = nil
        try? store.markOpened(chatKey: chatKey)
        do {
            if try !store.isCurrent(chatKey: chatKey, latestMessageId: latestMessageId) {
                try await fetchNewest()
            }
            if followsNewest {
                moveToNewest()
            }
            // A divider placed from stored messages goes when history replaced the messages it sat on.
            if let divider = firstUnreadMessageId, message(withId: divider) == nil {
                firstUnreadMessageId = nil
            }
            placeUnreadDivider()
            saveState()
            canReact = (adapter as? any ChatReactionSending)?.acceptsReactions ?? false
            canAttach = adapter.acceptsAttachments
            isReadOnly = (adapter as? any ChatReadOnlyAccess)?.isReadOnly ?? false
            isOpen = true
            state = .connected
            if let live = adapter as? any ChatLiveUpdating {
                await live.startFollowing()
            }
            if let interval = adapter.pollInterval {
                startPolling(every: interval)
            }
            if let focusMessageId {
                self.focusMessageId = nil
                await jump(to: focusMessageId)
            }
            await deliverQueued()
        } catch {
            (adapter as? any ChatLiveUpdating)?.stopFollowing()
            state = .disconnected(error.localizedDescription)
        }
    }

    override public func disconnect() {
        isOpen = false
        stopPolling()
        (adapter as? any ChatLiveUpdating)?.stopFollowing()
        // Nothing follows or polls the chat from here, so its stored messages count as current only once a fetch or
        // its Chats row's latest message says so.
        store.raiseEpoch(accountId: accountId)
        stateSaveTask?.cancel()
        saveState()
    }

    override public func prefetch() async throws {
        if try store.isCurrent(chatKey: chatKey, latestMessageId: latestMessageId) {
            return
        }
        try await fetchNewest()
        saveState()
    }

    override public var isCurrent: Bool {
        (try? store.isCurrent(chatKey: chatKey, latestMessageId: latestMessageId)) ?? false
    }

    private func fetchNewest() async throws {
        let page = try await adapter.fetch(.newest)
        try store.apply(page, for: .newest, chatKey: chatKey)
    }

    /// Without an error the app closed the connection itself (it went to the background) and reconnects when
    /// active again, so there is nothing to report.
    private func connectionLost(_ error: Error?) {
        isOpen = false
        stopPolling()
        store.raiseEpoch(accountId: accountId)
        state = error.map { .disconnected($0.localizedDescription) } ?? .connecting
    }

    override func poll() async {
        do {
            try await fetchNewest()
            saveState()
        } catch {
            // A failed poll keeps what is shown; the next one tries again.
        }
    }

    // MARK: Windows

    private func reloadWindow() {
        do {
            window = try store.window(chatKey: chatKey, at: position)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        if followsNewest, let chunk = window.chunk, !chunk.reachesNewest, position.upperSortKey == nil {
            // A newer chunk started above a gap: show it, as the newest messages are what was showing.
            moveToNewest()
            return
        }
        if position.anchorId == nil, let oldest = window.oldestMessage {
            // From here the window grows with new messages rather than sliding.
            position.anchorId = oldest.id
        }
        adapterDidChange()
    }

    private func moveToNewest() {
        position = .newest(count: max(AdapterChatViewModelLimits.windowCount, min(history.count, AdapterChatViewModelLimits.windowCount * 4)))
        followsNewest = true
        do {
            window = try store.window(chatKey: chatKey, at: position)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        position.anchorId = window.oldestMessage?.id
        adapterDidChange()
    }

    private func extend(earlierBy count: Int) {
        guard let extended = try? store.position(extending: position, earlierBy: count, chatKey: chatKey) else { return }
        position = extended
        reloadWindow()
    }

    override public func loadEarlier() async {
        guard hasEarlierMessages, !isLoadingEarlier else { return }
        if window.hasStoredEarlier {
            extend(earlierBy: AdapterChatViewModelLimits.pageCount)
            return
        }
        guard let chunk = window.chunk, chunk.hasEarlier else { return }
        isLoadingEarlier = true
        defer { isLoadingEarlier = false }
        do {
            if let cursor = chunk.earlierCursor ?? window.oldestMessage.flatMap(adapter.cursor(before:)) {
                let page = try await adapter.fetch(.before(cursor))
                try store.apply(page, for: .before(cursor), chatKey: chatKey, adjacentTo: chunk.id)
                extend(earlierBy: max(page.records.count, 1))
            } else {
                // A gap live updates opened, on a network whose cursors can't be made from a message: the newest
                // page may close it.
                try await fetchNewest()
                extend(earlierBy: AdapterChatViewModelLimits.pageCount)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    override public func loadLater() async {
        guard hasLaterMessages, !isLoadingLater else { return }
        if window.hasStoredLater {
            extendLater()
            return
        }
        guard let chunk = window.chunk, !chunk.reachesNewest else { return }
        guard adapter is any ChatWindowing, let cursor = chunk.laterCursor else {
            await jumpToLatest()
            return
        }
        isLoadingLater = true
        defer { isLoadingLater = false }
        do {
            let page = try await adapter.fetch(.after(cursor))
            guard !page.records.isEmpty else {
                await jumpToLatest()
                return
            }
            try store.apply(page, for: .after(cursor), chatKey: chatKey, adjacentTo: chunk.id)
            extendLater()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func extendLater() {
        guard let extended = try? store.position(extending: position, laterBy: AdapterChatViewModelLimits.pageCount, chatKey: chatKey) else { return }
        position = extended
        reloadWindow()
        followsNewest = position.upperSortKey == nil && (window.chunk?.reachesNewest ?? false)
    }

    /// Shows a stored message in a window around it, fetching one where the network can (`ChatWindowing`), else
    /// paging back from the newest up to `jumpPageLimit` pages.
    override public func jump(to messageId: String) async {
        if message(withId: messageId) != nil, referencedMessages[messageId] == nil {
            jumpTarget = messageId
            return
        }
        if showStored(around: messageId) {
            return
        }
        if adapter is any ChatWindowing {
            do {
                let page = try await adapter.fetch(.around(messageId: messageId))
                if !page.records.isEmpty {
                    try store.apply(page, for: .around(messageId: messageId), chatKey: chatKey)
                }
            } catch {
                errorMessage = error.localizedDescription
                return
            }
            if !showStored(around: messageId) {
                errorMessage = "That message is no longer available."
            }
            return
        }
        for _ in 0 ..< Self.jumpPageLimit where hasEarlierMessages && message(withId: messageId) == nil {
            await loadEarlier()
        }
        if message(withId: messageId) != nil {
            jumpTarget = messageId
        } else {
            errorMessage = "That message is too far back to show."
        }
    }

    private func showStored(around messageId: String) -> Bool {
        guard let around = try? store.position(around: messageId, count: AdapterChatViewModelLimits.windowCount, chatKey: chatKey) else { return false }
        position = around
        followsNewest = false
        reloadWindow()
        followsNewest = position.upperSortKey == nil && (window.chunk?.reachesNewest ?? false)
        jumpTarget = messageId
        return true
    }

    override public func jumpToLatest() async {
        if !followsNewest || hasLaterMessages {
            moveToNewest()
        }
        scrollToLatestRequest += 1
        if isOpen, (try? store.isCurrent(chatKey: chatKey, latestMessageId: latestMessageId)) != true {
            await poll()
        }
    }

    // MARK: Composing

    /// The network's copy of a sent message shows once stored; a network that didn't push it gets asked.
    private func afterSend(_ id: String?) async {
        if let id, (try? store.record(id: id, chatKey: chatKey)) != nil {
            return
        }
        await poll()
    }

    /// Stops the adapter's in-flight work, from the composer's stop button. No-op when the adapter isn't stoppable.
    override public func stopBusyWork() {
        (adapter as? any ChatStoppable)?.stop()
    }

    /// Sends optimistically (see `sendOptimistically`), or saves the edit being made (`editOptimistically`); a
    /// command waits for the network instead, since it may post nothing.
    override public func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if editingMessage != nil {
            guard !text.isEmpty, let editing = adapter as? any ChatEditing else { return }
            await editOptimistically(text: text) { [weak self] id, text in
                try await editing.edit(id, text: text)
                self?.adapterDidChange()
            }
            return
        }
        let attachments = adapter.acceptsAttachments ? attachments : []
        if let forward = forwarding {
            guard !isReadOnly else { return }
            if !text.isEmpty || !attachments.isEmpty {
                await sendOptimistically(text: text, attachments: attachments, replyToId: nil) { [weak self, adapter] message in
                    let id = try await adapter.send(message)
                    await self?.afterSend(id)
                    return id
                }
                guard errorMessage == nil else { return }
            }
            await send(forward)
            return
        }
        guard !text.isEmpty || !attachments.isEmpty, !isReadOnly else { return }
        let replyToId = canReply ? replyingTo?.id : nil
        if let commanding = adapter as? any ChatCommanding, commanding.isCommand(text) {
            isSending = true
            errorMessage = nil
            defer { isSending = false }
            do {
                try await commanding.sendCommand(text, replyToId: replyToId)
                draft = ""
                self.attachments = []
                replyingTo = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }
        await submit(.message(text: text, attachments: attachments.map(ChatOutboxItem.Attachment.init), replyToId: replyToId))
    }

    override public var offersStickers: Bool {
        adapter is any ChatStickerSending
    }

    override public func stickerSets() async throws -> [ChatStickerSet] {
        try await (adapter as? any ChatStickerSending)?.stickerSets() ?? []
    }

    override public func stickers(inSet id: String) async throws -> [ChatSticker] {
        try await (adapter as? any ChatStickerSending)?.stickers(inSet: id) ?? []
    }

    override public func stickers(forEmoji emoji: String) async throws -> [ChatSticker] {
        try await (adapter as? any ChatStickerSending)?.stickers(forEmoji: emoji) ?? []
    }

    override public func send(sticker: ChatSticker) async {
        guard adapter is any ChatStickerSending, !isReadOnly else { return }
        await submit(.sticker(sticker, replyToId: canReply ? replyingTo?.id : nil))
    }

    /// Networks without voice messages take the recording as an audio file.
    override public var offersVoiceNotes: Bool {
        adapter is any ChatVoiceSending || canAttach
    }

    override public func send(voice: ChatVoiceNote) async {
        guard offersVoiceNotes, !isReadOnly else { return }
        // Kept in the outbox in case the chat closes before it goes; sent from the recording itself meanwhile.
        await submit(.voice(
            audio: (try? Data(contentsOf: voice.fileURL)) ?? Data(), fileExtension: voice.fileURL.pathExtension, duration: voice.duration, waveform: voice.waveform,
            replyToId: canReply ? replyingTo?.id : nil,
        ), recording: voice)
    }

    // MARK: Outbox

    /// Sends now while the chat is connected; before then, keeps the message in the outbox and shows it as sending
    /// until `connect()` delivers it. Either way it is in the outbox while it goes, so it outlives the app closing.
    private func submit(_ content: ChatOutboxItem.Content, recording: ChatVoiceNote? = nil) async {
        var item = ChatOutboxItem(id: "queued-\(UUID().uuidString)", chatKey: chatKey, created: Date(), content: content, isInFlight: isOpen)
        recordings[item.id] = recording
        do {
            try store.enqueue(item)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        guard isOpen else {
            show(queued: item)
            if case .message = content {
                draft = ""
                attachments = []
            }
            replyingTo = nil
            return
        }
        item.isInFlight = true
        await deliver(item, clearsComposer: true)
    }

    private func show(queued item: ChatOutboxItem) {
        switch item.content {
        case let .message(text, attachments, replyToId):
            showQueued(id: item.id, text: text, attachment: attachments.first?.attachment, sticker: nil, voice: nil, replyToId: replyToId)
        case let .sticker(sticker, replyToId):
            showQueued(id: item.id, text: "", attachment: nil, sticker: sticker, voice: nil, replyToId: replyToId)
        case let .voice(audio, fileExtension, duration, waveform, replyToId):
            let note = Self.voiceNote(id: item.id, audio: audio, fileExtension: fileExtension, duration: duration, waveform: waveform)
            showQueued(id: item.id, text: "", attachment: nil, sticker: nil, voice: note, replyToId: replyToId)
        }
    }

    /// Messages left from an earlier visit: waiting ones show as sending; ones the app closed on while sending go back
    /// to the composer, since the network may have taken them.
    private func restoreOutbox() {
        for item in (try? store.outbox(chatKey: chatKey)) ?? [] {
            guard item.isInFlight else {
                show(queued: item)
                continue
            }
            try? store.dequeue(id: item.id)
            if case let .message(text, files, _) = item.content, draft.isEmpty, attachments.isEmpty {
                draft = text
                attachments = files.map(\.attachment)
            }
        }
    }

    private func deliverQueued() async {
        for var item in (try? store.outbox(chatKey: chatKey)) ?? [] where !item.isInFlight {
            guard isOpen else { return }
            removeQueued(id: item.id)
            item.isInFlight = true
            await deliver(item, clearsComposer: false)
        }
    }

    private func deliver(_ item: ChatOutboxItem, clearsComposer: Bool) async {
        try? store.enqueue(item)
        defer {
            try? store.dequeue(id: item.id)
            recordings[item.id] = nil
        }
        switch item.content {
        case let .message(text, files, replyToId):
            await sendOptimistically(text: text, attachments: files.map(\.attachment), replyToId: replyToId, clearsComposer: clearsComposer) { [weak self, adapter] message in
                let id = try await adapter.send(message)
                await self?.afterSend(id)
                return id
            }
        case let .sticker(sticker, replyToId):
            guard let sending = adapter as? any ChatStickerSending else { return }
            await sendOptimistically(text: "", attachment: nil, sticker: sticker, replyToId: replyToId) { [weak self] in
                let id = try await sending.send(sticker: sticker, replyToId: replyToId)
                await self?.afterSend(id)
                return id
            }
        case let .voice(audio, fileExtension, duration, waveform, replyToId):
            guard let voice = recordings[item.id] ?? Self.voiceNote(id: item.id, audio: audio, fileExtension: fileExtension, duration: duration, waveform: waveform) else { return }
            await sendOptimistically(text: "", attachment: nil, voice: voice, replyToId: replyToId) { [weak self, adapter] in
                let id: String? = if let sending = adapter as? any ChatVoiceSending {
                    try await sending.send(voice: voice, replyToId: replyToId)
                } else {
                    try await adapter.send(ChatOutgoing(text: "", attachment: ChatVoiceFile.attachment(for: voice), replyToId: replyToId))
                }
                await self?.afterSend(id)
                return id
            }
        }
    }

    /// The recording, written back to a file for the adapter (and the bubble's player) to read.
    private static func voiceNote(id: String, audio: Data, fileExtension: String, duration: Double, waveform: [Double]) -> ChatVoiceNote? {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(id).\(fileExtension.isEmpty ? "m4a" : fileExtension)")
        if !FileManager.default.fileExists(atPath: url.path) {
            guard (try? audio.write(to: url, options: .atomic)) != nil else { return nil }
        }
        return ChatVoiceNote(fileURL: url, duration: duration, waveform: waveform)
    }

    // MARK: Forwarding

    override func forward(of message: ChatMessage) async -> ChatForward? {
        let media = await ChatForwardMedia.from(message.embeds) { [weak self] previewId in
            await self?.audioPreviewURL(for: previewId)
        }
        let reference = (adapter as? any ChatForwarding)?.forwardReference(for: message)
        return ChatForward(message: message, network: network, accountId: accountId, reference: reference, link: link(toMessage: message.id), media: media)
    }

    /// Whether the forward goes natively: from a chat of this account on this network that gave a reference.
    func forwardsNatively(_ forward: ChatForward) -> Bool {
        forward.reference != nil && forward.network == network && forward.accountId == accountId && adapter is any ChatForwarding
    }

    /// Forwards natively where the network can (`ChatForwarding`), else sends a copy: the header and text with the
    /// first file, then each other file, voice messages as voice where the network takes them.
    private func send(_ forward: ChatForward) async {
        let isNative = forwardsNatively(forward)
        await sendOptimistically(text: "", attachment: nil, forward: forward, replyToId: nil) { [weak self] in
            guard let self else { return nil }
            do {
                let id: String? = if isNative, let reference = forward.reference, let forwarding = adapter as? any ChatForwarding {
                    try await forwarding.forward(reference: reference)
                } else {
                    try await sendCopy(of: forward)
                }
                ChatKit.onEvent(.messageForwarded(network: network, from: forward.network, isNative: isNative, error: nil))
                await afterSend(id)
                return id
            } catch {
                ChatKit.onEvent(.messageForwarded(network: network, from: forward.network, isNative: isNative, error: error))
                throw error
            }
        }
        if errorMessage == nil {
            forwarding = nil
        }
    }

    private func sendCopy(of forward: ChatForward) async throws -> String? {
        let voiceOnly = forward.media.allSatisfy { if case .voice = $0 { true } else { false } }
        guard forward.media.isEmpty || adapter.acceptsAttachments || (voiceOnly && adapter is any ChatVoiceSending) else {
            throw ChatForwardError.noAttachments
        }
        var lastId: String?
        for part in ChatForwardCopy.parts(of: forward) {
            guard let media = part.media else {
                lastId = try await adapter.send(ChatOutgoing(text: part.text, attachment: nil, replyToId: nil, italics: part.italics, links: part.links))
                continue
            }
            if case .voice = media, let sending = adapter as? any ChatVoiceSending, let note = try await ChatForwardCopy.voiceNote(for: media) {
                if !part.text.isEmpty {
                    lastId = try await adapter.send(ChatOutgoing(text: part.text, attachment: nil, replyToId: nil, italics: part.italics, links: part.links))
                }
                lastId = try await sending.send(voice: note, replyToId: nil)
                continue
            }
            guard adapter.acceptsAttachments else { throw ChatForwardError.noAttachments }
            let attachment = try await ChatForwardCopy.attachment(for: media)
            lastId = try await adapter.send(ChatOutgoing(text: part.text, attachment: attachment, replyToId: nil, italics: part.italics, links: part.links))
        }
        return lastId
    }

    /// Editing a message isn't typing a new one.
    override public func draftDidChange() {
        guard editingMessage == nil else { return }
        (adapter as? any ChatTyping)?.draftDidChange(draft)
    }

    override public func editableText(of message: ChatMessage) -> String? {
        (adapter as? any ChatEditing)?.editableText(of: message)
    }

    override public func networkAllowsDeleting(_ message: ChatMessage) -> Bool {
        (adapter as? any ChatDeleting)?.canDelete(message) ?? false
    }

    override public func delete(_ message: ChatMessage) async {
        guard canDelete(message), let deleting = adapter as? any ChatDeleting else { return }
        errorMessage = nil
        do {
            try await deleting.delete(message.id)
            ChatKit.onEvent(.messageDeleted(network: network, error: nil))
        } catch {
            ChatKit.onEvent(.messageDeleted(network: network, error: error))
            errorMessage = error.localizedDescription
        }
        adapterDidChange()
    }

    override public var networkPressesButtons: Bool {
        adapter is any ChatButtonPressing
    }

    override public func selectComposerMenuItem(_ itemId: String) {
        (adapter as? any ChatComposerMenus)?.selectComposerMenuItem(itemId)
    }

    override public func press(_ button: ChatMessageButton, on message: ChatMessage) async -> ChatButtonAnswer? {
        guard canUse(button, on: message), let pressing = adapter as? any ChatButtonPressing else { return nil }
        errorMessage = nil
        do {
            let answer = try await pressing.press(button, on: message.id)
            ChatKit.onEvent(.messageButtonPressed(network: network, error: nil))
            adapterDidChange()
            return answer
        } catch {
            ChatKit.onEvent(.messageButtonPressed(network: network, error: error))
            errorMessage = error.localizedDescription
            return nil
        }
    }

    override public func mentionSuggestions(for query: String) -> [ChatUser] {
        (adapter as? any ChatMentioning)?.mentionSuggestions(for: query) ?? []
    }

    // MARK: Read position

    /// The read position moves at once (the count follows it); the network hears shortly after.
    override public func markRead(upTo message: ChatMessage) {
        guard !isQuickLook else { return }
        let send = adapter.markRead(upTo: message)
        updateUnreadCount()
        if let send {
            scheduleReadMarker(send)
        }
    }

    override func isAfterReadPosition(_ message: ChatMessage) -> Bool {
        adapter.isAfterReadPosition(message)
    }

    // MARK: Reactions

    override public func yourEmojis(on messageId: String) -> [String] {
        (adapter as? any ChatReactionSending)?.yourEmojis(on: messageId) ?? []
    }

    override public func toggleReaction(_ emoji: String, on messageId: String) async {
        guard canReact, let reacting = adapter as? any ChatReactionSending else { return }
        do {
            try await reacting.toggleReaction(emoji, on: messageId)
        } catch {
            errorMessage = error.localizedDescription
        }
        adapterDidChange()
    }

    /// Only once connected, like the read position: cached messages shown before then may be out of date.
    override public func reactionsSeen(on messageIds: Set<String>) {
        guard isOpen, !isQuickLook, let unseen = adapter as? any ChatUnseenReactions else { return }
        let ids = messageIds.intersection(unseenReactionMessageIds)
        guard !ids.isEmpty else { return }
        let send = unseen.markReactionsSeen(on: ids)
        adapterDidChange()
        if let send {
            scheduleReactionsSeen(send)
        }
    }

    override public func reactors(of emoji: String, on messageId: String) -> [ChatReactor] {
        adapter.reactors(of: emoji, on: messageId)
    }

    override public func audioPreviewURL(for previewId: String) async -> URL? {
        if let recording = sendingVoiceFiles[previewId] {
            return recording
        }
        return await (adapter as? any ChatAudioPreviewing)?.audioPreviewURL(for: previewId)
    }

    // MARK: Links

    override public func link(toMessage messageId: String) -> URL? {
        (adapter as? any ChatMessageLinking)?.link(toMessage: messageId)
    }

    override public func linkTarget(for url: URL) -> ChatLinkTarget? {
        (adapter as? any ChatLinking)?.linkTarget(for: url)
    }

    override public var linkBaseURL: URL? {
        (adapter as? any ChatLinking)?.linkBaseURL
    }

    override public func placeLabel(forLink url: URL) -> ChatPlaceLabel? {
        (adapter as? any ChatLinking)?.placeLabel(forLink: url)
    }

    override public var referencePattern: NSRegularExpression? {
        (adapter as? any ChatLinking)?.referencePattern ?? nil
    }

    override public func placeLabel(forReference reference: String) -> ChatPlaceLabel? {
        (adapter as? any ChatLinking)?.placeLabel(forReference: reference)
    }

    override public var referencePrefix: String? {
        (adapter as? any ChatLinking)?.referencePrefix ?? nil
    }

    override public func referenceSuggestions(for query: String) -> [ChatReferenceSuggestion] {
        (adapter as? any ChatLinking)?.referenceSuggestions(for: query) ?? []
    }

    // MARK: Publishing

    private func adapterDidChange() {
        let info = adapter.info
        if title != info.title {
            title = info.title
        }
        if subtitle != info.subtitle {
            subtitle = info.subtitle
        }
        showsSenderNames = info.showsSenderNames
        titleIsMemberNames = info.titleIsMemberNames
        if avatarUserId != info.avatarUserId {
            avatarUserId = info.avatarUserId
        }
        if avatarURL != info.avatarURL {
            avatarURL = info.avatarURL
        }
        if hasEarlierMessages != window.hasEarlier {
            hasEarlierMessages = window.hasEarlier
        }
        if hasLaterMessages != window.hasLater {
            hasLaterMessages = window.hasLater
        }
        if let typing = adapter as? any ChatTyping, typingNames != typing.typingNames {
            typingNames = typing.typingNames
        }
        if let menus = adapter as? any ChatComposerMenus, composerMenu != menus.composerMenu {
            composerMenu = menus.composerMenu
        }
        let busy = (adapter as? any ChatStoppable)?.isBusy ?? false
        if isBusy != busy {
            isBusy = busy
        }
        if let unseen = adapter as? any ChatUnseenReactions, unseenReactionMessageIds != unseen.unseenReactionMessageIds {
            unseenReactionMessageIds = unseen.unseenReactionMessageIds
        }
        if let mentioning = adapter as? any ChatMentioning, mentionNames != mentioning.mentionNames {
            mentionNames = mentioning.mentionNames
        }
        if let choices = adapter as? any ChatReactionChoices, reactionChoices != choices.reactionChoices {
            reactionChoices = choices.reactionChoices
        }
        if let emojis = adapter as? any ChatCustomEmojis, customEmojis != emojis.customEmojis {
            customEmojis = emojis.customEmojis
        }
        if let resolving = adapter as? any ChatReferenceResolving {
            if unavailableReferences != resolving.unavailableReferences {
                unavailableReferences = resolving.unavailableReferences
            }
        }
        let rendering = adapter.render(window.records)
        resolveStoredReferences(of: rendering.messages)
        if let reporting = adapter as? any ChatReadReceipts {
            var latest: [String: ChatReceipt] = [:]
            for message in rendering.messages where message.isOwn {
                latest[message.id] = reporting.receipt(for: message)
            }
            if receipts != latest {
                receipts = latest
            }
        }
        publish(history: rendering.messages, reactions: rendering.reactions)
        updateUnreadCount()
        scheduleStateSave()
    }

    /// Quoted messages outside the window that the store has, ahead of what the adapter resolves on the network.
    private func resolveStoredReferences(of messages: [ChatMessage]) {
        let shown = Set(messages.map(\.id))
        let adapterResolved = (adapter as? any ChatReferenceResolving)?.referencedMessages ?? [:]
        var resolved = adapterResolved
        for id in Set(messages.compactMap(\.replyToId)) where !shown.contains(id) && resolved[id] == nil {
            guard let record = try? store.record(id: id, chatKey: chatKey), record.relatesTo == nil else { continue }
            let related = (try? store.related(to: [id], chatKey: chatKey)) ?? []
            if let message = adapter.render([record] + related).messages.first(where: { $0.id == id }) {
                resolved[id] = message
            }
        }
        if referencedMessages != resolved {
            referencedMessages = resolved
        }
    }

    /// Saves shortly after changes while open, so the adapter's state survives the app being killed in a chat.
    private func scheduleStateSave() {
        guard isOpen else { return }
        stateSaveTask?.cancel()
        stateSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveState()
        }
    }

    private func saveState() {
        try? store.setState(adapter.state(), chatKey: chatKey)
    }
}
