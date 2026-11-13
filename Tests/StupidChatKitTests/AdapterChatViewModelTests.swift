import AVFoundation
import Foundation
@testable import StupidChatKit
import XCTest

@MainActor
final class AdapterChatViewModelTests: XCTestCase {
    private var directory: URL!
    private var store: ChatStore!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appending(path: "AdapterChatViewModelTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testConnectLoadsAndShowsTheAdaptersChat() async {
        let adapter = FakeAdapter()
        adapter.pages = [[message(1), message(2)]]
        let chat = makeChat(adapter)
        await chat.connect()
        XCTAssertEqual(chat.state, .connected)
        XCTAssertEqual(chat.messages.map(\.id), ["1", "2"])
        XCTAssertEqual(chat.title, "Loaded")
        XCTAssertFalse(chat.canReact, "the adapter can't react")
        chat.disconnect()
    }

    func testAFailedLoadDisconnectsWithTheReason() async {
        let adapter = FakeAdapter()
        adapter.error = URLError(.notConnectedToInternet)
        let chat = makeChat(adapter)
        await chat.connect()
        guard case .disconnected = chat.state else { return XCTFail("expected disconnected, got \(chat.state)") }
    }

    func testReactingAdaptersEnableReactions() async {
        let adapter = FakeReactingAdapter()
        adapter.pages = [[message(1)]]
        let chat = makeChat(adapter)
        await chat.connect()
        XCTAssertTrue(chat.canReact)
        await chat.toggleReaction("👍", on: "1")
        XCTAssertEqual(chat.reactions["1"]?.first?.emoji, "👍")
        chat.disconnect()
    }

    func testStoredMessagesShowWithTheirDividerInTheFirstRender() async {
        let adapter = FakeAdapter()
        adapter.readUpTo = 1
        adapter.pages = [[message(1), message(2), message(3)]]
        let first = makeChat(adapter)
        await first.connect()
        first.disconnect()

        let reopened = FakeAdapter()
        reopened.readUpTo = 1
        let chat = makeChat(reopened)
        XCTAssertEqual(chat.messages.map(\.id), ["1", "2", "3"], "opens with the stored messages")
        XCTAssertEqual(chat.firstUnreadMessageId, "2")
        XCTAssertEqual(chat.unreadCount, 2)
    }

    func testAChatWhoseStoredMessagesAreCurrentFetchesNothing() async {
        let adapter = FakeAdapter()
        adapter.pages = [[message(1), message(2), message(3)]]
        let first = makeChat(adapter)
        await first.connect()
        first.disconnect()

        let reopened = FakeAdapter()
        let chat = makeChat(reopened)
        chat.latestMessageId = "3"
        await chat.connect()
        XCTAssertEqual(reopened.fetches, [], "the store holds the chat's latest message")
        XCTAssertEqual(chat.messages.map(\.id), ["1", "2", "3"])
        chat.disconnect()

        let behind = FakeAdapter()
        behind.pages = [[message(3), message(4)]]
        let stale = makeChat(behind)
        stale.latestMessageId = "4"
        await stale.connect()
        XCTAssertEqual(behind.fetches, [.newest])
        XCTAssertEqual(stale.messages.map(\.id), ["1", "2", "3", "4"], "the newest page joins the stored ones")
        stale.disconnect()
    }

    func testReadingAStoredCurrentChatSendsTheReadPosition() async throws {
        let adapter = FakeAdapter()
        adapter.pages = [[message(1), message(2), message(3)]]
        let first = makeChat(adapter)
        try await first.prefetch()

        let reopened = FakeAdapter()
        try reopened.restore(state: XCTUnwrap(adapter.state()))
        let chat = makeChat(reopened)
        chat.latestMessageId = "3"
        await chat.connect()
        XCTAssertEqual(reopened.fetches, [], "opened from the store")
        XCTAssertEqual(chat.state, .connected)
        XCTAssertEqual(chat.unreadCount, 3)
        chat.markRead(upTo: message(3))
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(reopened.readMarks, [3])
        chat.disconnect()
    }

    func testLoadingAheadNeitherRendersNorFollowsTheStore() async throws {
        let adapter = FakeAdapter()
        adapter.pages = [[message(1), message(2)]]
        let chat = try AdapterChatViewModel(adapter: adapter, accountId: "test", store: makeStore(), draftStore: ChatDraftStore(defaults: XCTUnwrap(UserDefaults(suiteName: "prefetch-\(UUID().uuidString)"))))
        try await chat.prefetch()
        XCTAssertEqual(adapter.fetches, [.newest])
        XCTAssertEqual(adapter.renderCount, 0, "nothing is shown, so nothing renders")
        XCTAssertTrue(chat.messages.isEmpty)
        chat.prepareToShow()
        XCTAssertEqual(chat.messages.map(\.id), ["1", "2"], "showing it reads the store")
    }

    func testANewestPageAboveAGapShowsTheNewestMessages() async {
        let adapter = FakeAdapter()
        adapter.pages = [[message(1), message(2)]]
        let first = makeChat(adapter)
        await first.connect()
        first.disconnect()

        let reopened = FakeAdapter()
        reopened.pages = [[message(10), message(11)]]
        reopened.earlierPages = [[message(3), message(4), message(5), message(6), message(7), message(8), message(9)], [message(1), message(2)]]
        let chat = makeChat(reopened)
        chat.latestMessageId = "11"
        XCTAssertEqual(chat.messages.map(\.id), ["1", "2"], "stored messages show at once")
        await chat.connect()
        XCTAssertEqual(chat.messages.map(\.id), ["10", "11"], "the newest messages, not what's below the gap")
        XCTAssertTrue(chat.hasEarlierMessages)
        await chat.loadEarlier()
        XCTAssertEqual(reopened.fetches, [.newest, .before(ChatCursor("earlier"))])
        XCTAssertEqual(chat.messages.map(\.id), (3 ... 11).map(String.init))
        await chat.loadEarlier()
        XCTAssertEqual(chat.messages.map(\.id), (1 ... 11).map(String.init), "the gap closed, joining the stored messages")
        XCTAssertFalse(chat.hasEarlierMessages, "the stored chunk started the chat")
        chat.disconnect()
    }

    func testMessagesSentBeforeConnectingGoOnceConnected() async {
        let adapter = FakeAdapter()
        adapter.pages = [[message(1)]]
        let chat = makeChat(adapter)
        chat.draft = "Hello"
        await chat.send()
        XCTAssertEqual(chat.draft, "", "the composer is free at once")
        XCTAssertEqual(chat.messages.last?.text, "Hello")
        XCTAssertTrue(chat.messages.last?.isSending ?? false)
        XCTAssertTrue(adapter.sent.isEmpty)
        await chat.connect()
        XCTAssertEqual(adapter.sent.map(\.text), ["Hello"])
        XCTAssertEqual(chat.messages.map(\.id), ["1", "sent-1"])
        chat.disconnect()
    }

    func testAMessageStillSendingStaysOutOfTheComposerWhenTheChatOpensAgain() async {
        let adapter = FakeAdapter()
        adapter.pages = [[message(1)]]
        adapter.sendDelay = .milliseconds(300)
        let chat = makeChat(adapter)
        await chat.connect()
        chat.draft = "Hello"
        let sending = Task { await chat.send() }
        try? await Task.sleep(for: .milliseconds(50))
        chat.disconnect()

        let again = makeChat(FakeAdapter())
        XCTAssertEqual(again.draft, "", "the first visit is still sending it")
        await sending.value
        XCTAssertEqual(adapter.sent.map(\.text), ["Hello"])
    }

    func testAMessageTheAppClosedOnWhileSendingGoesBackToTheComposer() throws {
        let chatKey = makeChat(FakeAdapter()).chatKey
        let item = ChatOutboxItem(id: "queued-1", chatKey: chatKey, created: Date(), content: .message(text: "Hello", attachments: [], replyToId: nil), isInFlight: true)
        try store.enqueue(item)

        let again = makeChat(FakeAdapter())
        XCTAssertEqual(again.draft, "Hello")
        XCTAssertEqual(try store.outbox(chatKey: chatKey), [])
    }

    func testAQueuedMessageSurvivesTheChatClosing() async {
        let adapter = FakeAdapter()
        adapter.pages = [[message(1)]]
        let chat = makeChat(adapter)
        chat.draft = "Later"
        await chat.send()

        let reopened = FakeAdapter()
        reopened.pages = [[message(1)]]
        let again = makeChat(reopened)
        XCTAssertEqual(again.messages.last?.text, "Later", "still waiting to send")
        await again.connect()
        XCTAssertEqual(reopened.sent.map(\.text), ["Later"])
        again.disconnect()
        _ = chat
    }

    func testAdapterChangesOutsideCallsReachTheScreen() async {
        let adapter = FakeAdapter()
        adapter.pages = [[message(1)]]
        let chat = makeChat(adapter)
        await chat.connect()
        adapter.info.title = "Renamed"
        adapter.onChange?()
        XCTAssertEqual(chat.title, "Renamed")
        chat.disconnect()
    }

    func testSendingShowsAtOnceThenTheNetworksCopy() async {
        let adapter = FakeAdapter()
        adapter.pages = [[message(1)]]
        let chat = makeChat(adapter)
        await chat.connect()
        chat.draft = "Hello"
        await chat.send()
        XCTAssertEqual(adapter.sent.map(\.text), ["Hello"])
        XCTAssertEqual(chat.messages.last?.id, "sent-1")
        XCTAssertFalse(chat.messages.contains(where: \.isSending))
        XCTAssertEqual(chat.draft, "")
        chat.disconnect()
    }

    func testSeveralFilesSendInOrderWithTheTextAndReplyOnTheFirst() async {
        let adapter = FakeAdapter()
        adapter.acceptsAttachments = true
        adapter.pages = [[message(1)]]
        let chat = makeChat(adapter)
        await chat.connect()
        chat.draft = "Look"
        chat.startReply(to: chat.messages[0])
        chat.attachments = (1 ... 3).map(file)
        await chat.send()
        XCTAssertEqual(adapter.sent.map(\.attachment?.filename), ["1.txt", "2.txt", "3.txt"])
        XCTAssertEqual(adapter.sent.map(\.text), ["Look", "", ""])
        XCTAssertEqual(adapter.sent.map(\.replyToId), ["1", nil, nil])
        XCTAssertTrue(chat.attachments.isEmpty)
        XCTAssertFalse(chat.messages.contains(where: \.isSending))
        chat.disconnect()
    }

    func testAFailedFileStopsTheRestAndPutsThemBack() async {
        let adapter = FakeAdapter()
        adapter.acceptsAttachments = true
        adapter.failsSendAfter = 1
        adapter.pages = [[message(1)]]
        let chat = makeChat(adapter)
        await chat.connect()
        chat.draft = "Look"
        chat.attachments = (1 ... 3).map(file)
        await chat.send()
        XCTAssertEqual(adapter.sent.map(\.attachment?.filename), ["1.txt"])
        XCTAssertEqual(chat.attachments.map(\.filename), ["2.txt", "3.txt"])
        XCTAssertEqual(chat.draft, "", "the text went with the first")
        XCTAssertNotNil(chat.errorMessage)
        XCTAssertFalse(chat.messages.contains(where: \.isSending))
        chat.disconnect()
    }

    func testMarkingReadMovesTheCountAtOnceAndSendsOnce() async throws {
        let adapter = FakeAdapter()
        adapter.pages = [[message(1), message(2), message(3)]]
        let chat = makeChat(adapter)
        await chat.connect()
        XCTAssertEqual(chat.unreadCount, 3)
        chat.markRead(upTo: message(2))
        chat.markRead(upTo: message(3))
        XCTAssertEqual(chat.unreadCount, 0)
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(adapter.readMarks, [3])
        chat.disconnect()
    }

    func testAFailedReadMarkIsRetried() async throws {
        let adapter = FakeAdapter()
        adapter.pages = [[message(1), message(2), message(3)]]
        let chat = makeChat(adapter)
        chat.readMarkerRetryDelays = [.milliseconds(100)]
        await chat.connect()
        adapter.failedReadMarks = 1
        chat.markRead(upTo: message(3))
        XCTAssertEqual(chat.unreadCount, 0, "read at once, before the network confirms it")
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(adapter.readMarks, [3])
        chat.disconnect()
    }

    func testAReadMarkThatNeverWentThroughGoesWithTheNextRead() async throws {
        let adapter = FakeAdapter()
        adapter.pages = [[message(1), message(2), message(3)]]
        let chat = makeChat(adapter)
        chat.readMarkerRetryDelays = []
        await chat.connect()
        adapter.failedReadMarks = 1
        chat.markRead(upTo: message(3))
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(adapter.readMarks, [])
        chat.markRead(upTo: message(3))
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(adapter.readMarks, [3], "the same chat sends it again")
        chat.disconnect()
    }

    func testAChatReopenedAfterAFailedReadMarkIsStillUnreadAndSendsIt() async throws {
        let adapter = FakeAdapter()
        adapter.pages = [[message(1), message(2), message(3)]]
        let first = makeChat(adapter)
        first.readMarkerRetryDelays = []
        await first.connect()
        adapter.failedReadMarks = 1
        first.markRead(upTo: message(3))
        try await Task.sleep(for: .milliseconds(800))
        first.disconnect()

        let reopened = FakeAdapter()
        try reopened.restore(state: XCTUnwrap(adapter.state()))
        let chat = makeChat(reopened)
        chat.latestMessageId = "3"
        await chat.connect()
        XCTAssertEqual(chat.unreadCount, 3, "the network still counts them unread")
        chat.markRead(upTo: message(3))
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(reopened.readMarks, [3])
        chat.disconnect()
    }

    func testAMessageSeenBeforeTheChatConnectsIsReadOnceItHas() async throws {
        let adapter = FakeAdapter()
        adapter.pages = [[message(1), message(2), message(3)]]
        let first = makeChat(adapter)
        try await first.prefetch()

        let reopened = FakeAdapter()
        reopened.pages = [[message(1), message(2), message(3), message(4)]]
        let chat = makeChat(reopened)
        chat.latestMessageId = "4"
        chat.prepareToShow()
        chat.markRead(upTo: message(2))
        XCTAssertEqual(chat.unreadCount, 3, "stored messages shown early stay unread until the chat connects")
        await chat.connect()
        XCTAssertEqual(chat.firstUnreadMessageId, "1", "the divider is placed before the early read")
        XCTAssertEqual(chat.unreadCount, 2)
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(reopened.readMarks, [2])
        chat.disconnect()
    }

    func testLiveAdaptersFollowWhileOpenAndPushedMessagesShow() async {
        let adapter = FakeLiveAdapter()
        adapter.pages = [[message(1)], [message(1)]]
        let chat = makeChat(adapter)
        await chat.connect()
        await chat.connect()
        XCTAssertEqual(adapter.followCount, 1, "connecting again while open doesn't follow twice")
        adapter.push(message(2))
        XCTAssertEqual(chat.messages.map(\.id), ["1", "2"])
        chat.disconnect()
        XCTAssertFalse(adapter.isFollowing)
        await chat.connect()
        XCTAssertEqual(adapter.followCount, 2, "reconnects after leaving")
        chat.disconnect()
    }

    func testALostConnectionShowsAndReconnectsOnTheNextConnect() async {
        let adapter = FakeLiveAdapter()
        adapter.pages = [[message(1)], [message(1)]]
        let chat = makeChat(adapter)
        await chat.connect()
        adapter.onConnectionLost?(URLError(.networkConnectionLost))
        guard case .disconnected = chat.state else { return XCTFail("expected disconnected, got \(chat.state)") }
        adapter.onConnectionLost?(nil)
        XCTAssertEqual(chat.state, .connecting, "closed by the app itself: nothing to report")
        await chat.connect()
        XCTAssertEqual(chat.state, .connected)
        chat.disconnect()
    }

    func testCommandsRunWithoutASendingCopy() async {
        let adapter = FakeWindowingAdapter()
        adapter.pages = [[message(1)]]
        let chat = makeChat(adapter)
        await chat.connect()
        chat.draft = "/nick ada"
        await chat.send()
        XCTAssertEqual(adapter.commands, ["/nick ada"])
        XCTAssertTrue(adapter.sent.isEmpty)
        XCTAssertEqual(chat.draft, "")
        XCTAssertEqual(chat.messages.map(\.id), ["1"])
        chat.disconnect()
    }

    func testJumpingOutsideTheLoadedMessagesShowsAWindow() async {
        let adapter = FakeWindowingAdapter()
        adapter.pages = [[message(50)]]
        let chat = makeChat(adapter)
        await chat.connect()
        await chat.jump(to: "10")
        XCTAssertEqual(chat.jumpTarget, "10")
        XCTAssertTrue(chat.hasLaterMessages)
        await chat.jump(to: "404")
        XCTAssertEqual(chat.errorMessage, "That message is no longer available.")
        await chat.jumpToLatest()
        XCTAssertFalse(chat.hasLaterMessages)
        XCTAssertEqual(chat.messages.map(\.id), ["50"])
        chat.disconnect()
    }

    func testReferencedMessagesComeFromTheAdapter() async {
        let adapter = FakeLiveAdapter()
        adapter.pages = [[message(1)]]
        adapter.referencedMessages = ["0": message(0)]
        adapter.unavailableReferences = ["-1"]
        let chat = makeChat(adapter)
        await chat.connect()
        XCTAssertEqual(chat.message(withId: "0")?.text, "Message 0")
        XCTAssertTrue(chat.isUnavailableReference("-1"))
        chat.disconnect()
    }

    func testUnseenReactionsShowAndSeeingThemSendsOnce() async throws {
        let adapter = FakeUnseenReactionsAdapter()
        adapter.pages = [[message(1, own: true), message(2, own: true), message(3, own: true)]]
        adapter.unseen = ["1", "3"]
        let chat = makeChat(adapter)
        var rowCounts: [Int?] = []
        chat.summaryDidChange = { _, _, _, count in rowCounts.append(count) }
        await chat.connect()
        XCTAssertEqual(chat.unseenReactionMessageIds, ["1", "3"])
        chat.reactionsSeen(on: ["1", "2"])
        chat.reactionsSeen(on: ["3"])
        XCTAssertEqual(chat.unseenReactionMessageIds, [], "seen at once")
        XCTAssertEqual(rowCounts.last, 0, "the row follows")
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(adapter.seenSends, [["1", "3"]], "one send covers both")
        chat.disconnect()
    }

    func testReactionsAreOnlySeenOnceConnected() {
        let adapter = FakeUnseenReactionsAdapter()
        adapter.unseen = ["1"]
        let chat = makeChat(adapter)
        chat.reactionsSeen(on: ["1"])
        XCTAssertEqual(chat.unseenReactionMessageIds, ["1"], "cached messages shown before connecting don't count")
    }

    func testChatsWithoutUnseenReactionsLeaveTheRowsCount() async {
        let adapter = FakeAdapter()
        adapter.pages = [[message(1)]]
        let chat = makeChat(adapter)
        var rowCounts: [Int?] = []
        chat.summaryDidChange = { _, _, _, count in rowCounts.append(count) }
        await chat.connect()
        XCTAssertFalse(rowCounts.isEmpty)
        XCTAssertTrue(rowCounts.allSatisfy { $0 == nil })
        chat.disconnect()
    }

    func testReceiptsShowSentThenSeenOnTheUsersConfirmedMessages() async {
        let adapter = FakeReceiptsAdapter()
        adapter.pages = [[message(1, own: true), message(2), message(3, own: true)]]
        adapter.seenUpTo = 1
        let chat = makeChat(adapter)
        await chat.connect()
        XCTAssertEqual(chat.receipt(for: chat.messages[0]), .seen)
        XCTAssertNil(chat.receipt(for: chat.messages[1]), "others' messages have none")
        XCTAssertEqual(chat.receipt(for: chat.messages[2]), .sent)
        adapter.seenUpTo = 3
        adapter.onChange?()
        XCTAssertEqual(chat.receipt(for: chat.messages[2]), .seen, "follows the adapter")
        chat.disconnect()
    }

    func testChatsWithoutReceiptsShowNone() async {
        let adapter = FakeAdapter()
        adapter.pages = [[message(1, own: true)]]
        let chat = makeChat(adapter)
        await chat.connect()
        XCTAssertNil(chat.receipt(for: chat.messages[0]))
        chat.disconnect()
    }

    func testJumpingToAnUnloadedMessageWithoutWindowsPagesBack() async {
        let adapter = FakeUnseenReactionsAdapter()
        adapter.pages = [[message(3, own: true)]]
        adapter.earlierPages = [[message(2, own: true)], [message(1, own: true)]]
        adapter.unseen = ["1"]
        let chat = makeChat(adapter)
        await chat.connect()
        await chat.jumpToNextUnseenReaction()
        XCTAssertEqual(chat.jumpTarget, "1")
        XCTAssertEqual(chat.messages.map(\.id), ["1", "2", "3"])
        chat.disconnect()
    }

    func testSearchFindsLoadedMessagesAndStepsBetweenThem() async {
        let adapter = FakeAdapter()
        adapter.pages = [[said(1, "Lunch at noon?"), said(2, "sure"), said(3, "Café LUNCH was great")]]
        let chat = makeChat(adapter)
        await chat.connect()
        chat.beginSearch()
        chat.updateSearch("lunch ")
        XCTAssertEqual(chat.searchMatchIds, ["1", "3"], "ignores case, accents and surrounding spaces")
        await chat.submitSearch()
        XCTAssertEqual(chat.searchMatchIndex, 1, "starts at the newest match")
        XCTAssertEqual(chat.jumpTarget, "3")
        await chat.showOlderMatch()
        XCTAssertEqual(chat.jumpTarget, "1")
        XCTAssertFalse(chat.canShowOlderMatch)
        XCTAssertTrue(chat.canShowNewerMatch)
        chat.endSearch()
        XCTAssertNil(chat.searchQuery)
        XCTAssertTrue(chat.searchMatchIds.isEmpty)
        chat.disconnect()
    }

    func testSharedPostIsFoundByItsAuthorTextAndQuoteAndPreviewedByAuthor() async {
        let quoted = ChatPost(authorName: "Grace", authorHandle: "@grace", text: "Nanoseconds are short")
        let post = ChatPost(authorName: "Ada", authorHandle: "@ada", text: "Look at this", quoted: quoted)
        let shared = ChatMessage(id: "1", sender: ChatUser(id: "bo", name: "Bo", avatarURL: nil), timestamp: Date(timeIntervalSince1970: 1), text: nil, embeds: [.post(post)], isOwn: false)
        let adapter = FakeAdapter()
        adapter.pages = [[shared, said(2, "nice")]]
        let chat = makeChat(adapter)
        await chat.connect()
        for query in ["@ada", "look at", "nanoseconds", "grace"] {
            XCTAssertEqual(chat.searchableText(of: shared).localizedCaseInsensitiveContains(query), true, query)
        }
        XCTAssertEqual(shared.previewText, "Post by Ada")
        chat.disconnect()
    }

    /// Links the app resolves are drawn as what it returns: in place of a card, after the embeds for a link only in
    /// the text, once per message, and again when the app says a link has loaded.
    func testResolvedLinksReplaceCardsAndFollowText() async throws {
        let post = ChatEmbed.post(ChatPost(authorName: "Ada", text: "Hello"))
        let postURL = try XCTUnwrap(URL(string: "https://posts.example/ada/1"))
        var loaded: Set<URL> = []
        ChatKit.resolveLink = { url in
            guard url.host() == "posts.example" else { return nil }
            return loaded.contains(url) ? post : nil
        }
        defer { ChatKit.resolveLink = nil }

        let sender = ChatUser(id: "bo", name: "Bo", avatarURL: nil)
        let card = ChatEmbed.card(title: "Post", subtitle: nil, systemImage: "link", imageURL: nil, link: postURL)
        let adapter = FakeAdapter()
        adapter.pages = [[
            ChatMessage(id: "1", sender: sender, timestamp: Date(timeIntervalSince1970: 1), text: "see \(postURL.absoluteString)", embeds: [card], isOwn: false),
            ChatMessage(id: "2", sender: sender, timestamp: Date(timeIntervalSince1970: 2), text: "and https://posts.example/ada/1 and https://example.com", isOwn: false),
        ]]
        let chat = makeChat(adapter)
        await chat.connect()
        XCTAssertEqual(chat.messages.map(\.embeds), [[card], []], "nothing until the link has loaded")

        loaded.insert(postURL)
        ChatKit.linksDidResolve()
        XCTAssertEqual(chat.messages.map(\.embeds), [[post], [post]], "the card replaced, the text link added once")
        chat.disconnect()
    }

    func testSearchPagesBackForOlderMatches() async {
        let adapter = FakeUnseenReactionsAdapter()
        adapter.pages = [[said(4, "lunch?"), said(5, "ok")]]
        adapter.earlierPages = [[said(3, "nothing")], [said(2, "lunch again")], [said(1, "lunch first")]]
        let chat = makeChat(adapter)
        await chat.connect()
        chat.beginSearch()
        chat.updateSearch("lunch")
        await chat.submitSearch()
        XCTAssertEqual(chat.jumpTarget, "4")
        XCTAssertTrue(chat.canShowOlderMatch, "earlier history may have more")
        await chat.showOlderMatch()
        XCTAssertEqual(chat.jumpTarget, "2", "loads pages until one brings an older match, and no further")
        XCTAssertEqual(chat.messages.map(\.id), ["2", "3", "4", "5"])
        XCTAssertEqual(chat.searchMatchIds, ["2", "4"])
        XCTAssertEqual(chat.searchMatchIndex, 0)
        chat.disconnect()
    }

    func testSearchWithNothingLoadedLooksFurtherBackOnReturn() async {
        let adapter = FakeUnseenReactionsAdapter()
        adapter.pages = [[said(3, "hi")]]
        adapter.earlierPages = [[said(2, "nope")], [said(1, "the plan")]]
        let chat = makeChat(adapter)
        await chat.connect()
        chat.beginSearch()
        chat.updateSearch("plan")
        XCTAssertTrue(chat.searchMatchIds.isEmpty)
        await chat.submitSearch()
        XCTAssertEqual(chat.searchMatchIds, ["1"])
        XCTAssertEqual(chat.jumpTarget, "1")
        chat.disconnect()
    }

    func testSearchMatchesFollowNewMessagesAndKeepTheShownOne() async {
        let adapter = FakeAdapter()
        adapter.pages = [[said(1, "lunch")]]
        let chat = makeChat(adapter)
        await chat.connect()
        chat.beginSearch()
        chat.updateSearch("lunch")
        await chat.submitSearch()
        adapter.append(said(2, "more lunch"))
        adapter.onChange?()
        XCTAssertEqual(chat.searchMatchIds, ["1", "2"])
        XCTAssertEqual(chat.searchMatchIndex, 0, "still shows the same message")
        chat.disconnect()
    }

    func testComposerMenuFollowsTheAdapter() {
        let adapter = FakeMenuAdapter()
        let chat = makeChat(adapter)
        XCTAssertEqual(chat.composerMenu?.title, "Small", "published before connecting, so the composer starts with it")
        chat.selectComposerMenuItem("large")
        XCTAssertEqual(adapter.selected, "large")
        XCTAssertEqual(chat.composerMenu?.title, "Large")
        XCTAssertEqual(chat.composerMenu?.sections.first?.first { $0.isSelected }?.id, "large")

        adapter.hidesMenu = true
        adapter.onChange?()
        XCTAssertNil(chat.composerMenu)
    }

    func testChatsWithoutAComposerMenuShowNone() {
        XCTAssertNil(makeChat(FakeAdapter()).composerMenu)
    }

    func testEditingSavesTheTextAndGivesBackWhatWasBeingWritten() async {
        let adapter = FakeEditingAdapter()
        adapter.pages = [[message(1), message(2, own: true)]]
        let chat = makeChat(adapter)
        await chat.connect()
        XCTAssertFalse(chat.canEdit(message(1)), "someone else's message")
        XCTAssertTrue(chat.canEdit(message(2, own: true)))
        chat.draft = "Half written"
        chat.startReply(to: message(1))
        chat.startEditing(message(2, own: true))
        XCTAssertEqual(chat.draft, "Message 2")
        XCTAssertNil(chat.replyingTo)
        chat.draft = "Changed "
        await chat.send()
        XCTAssertEqual(adapter.edits.map(\.text), ["Changed"])
        XCTAssertEqual(chat.messages.last?.text, "Changed")
        XCTAssertEqual(chat.messages.last?.isEdited, true)
        XCTAssertNil(chat.editingMessage)
        XCTAssertEqual(chat.draft, "Half written")
        XCTAssertEqual(chat.replyingTo?.id, "1")
        chat.disconnect()
    }

    func testStickersAreOfferedOnlyWhereTheAdapterSendsThem() async throws {
        XCTAssertFalse(makeChat(FakeAdapter()).offersStickers)
        let adapter = FakeStickerAdapter()
        let chat = makeChat(adapter)
        XCTAssertTrue(chat.offersStickers)
        let sets = try await chat.stickerSets()
        XCTAssertEqual(sets.map(\.id), ["recent", "set-1"])
        let stickers = try await chat.stickers(inSet: "set-1")
        XCTAssertEqual(stickers.map(\.id), ["7"])
    }

    func testASentStickerShowsAtOnceRepliesAndKeepsTheDraft() async {
        let adapter = FakeStickerAdapter()
        adapter.pages = [[message(1)]]
        let chat = makeChat(adapter)
        await chat.connect()
        chat.draft = "Half written"
        chat.startReply(to: message(1))
        await chat.send(sticker: adapter.sticker)
        XCTAssertEqual(adapter.sentStickers.map(\.id), ["7"])
        XCTAssertEqual(adapter.sentStickerReplies, ["1"])
        XCTAssertEqual(chat.messages.last?.id, "sticker-1")
        XCTAssertEqual(chat.messages.last?.embeds, [.sticker(adapter.sticker)])
        XCTAssertFalse(chat.messages.contains(where: \.isSending))
        XCTAssertEqual(chat.draft, "Half written", "a sticker leaves the draft")
        XCTAssertNil(chat.replyingTo)
        chat.disconnect()
    }

    func testAFailedStickerGoesAwayWithTheReason() async {
        let adapter = FakeStickerAdapter()
        adapter.pages = [[message(1)]]
        adapter.stickerError = URLError(.notConnectedToInternet)
        let chat = makeChat(adapter)
        await chat.connect()
        chat.draft = "Half written"
        await chat.send(sticker: adapter.sticker)
        XCTAssertEqual(chat.messages.map(\.id), ["1"])
        XCTAssertNotNil(chat.errorMessage)
        XCTAssertEqual(chat.draft, "Half written")
        chat.disconnect()
    }

    func testVoiceMessagesAreOfferedOnlyWhereTheAdapterSendsThem() {
        XCTAssertFalse(makeChat(FakeAdapter()).offersVoiceNotes)
        XCTAssertTrue(makeChat(FakeVoiceAdapter()).offersVoiceNotes)
    }

    func testASentVoiceMessagePlaysItsRecordingWhileSendingAndKeepsTheDraft() async {
        let adapter = FakeVoiceAdapter()
        adapter.pages = [[message(1)]]
        let chat = makeChat(adapter)
        await chat.connect()
        chat.draft = "Half written"
        chat.startReply(to: message(1))
        let note = ChatVoiceNote(fileURL: URL(fileURLWithPath: "/tmp/voice.caf"), duration: 2.5, waveform: [0, 1])
        var whileSending: (embeds: [ChatEmbed]?, preview: URL?)?
        adapter.onSend = {
            let sending = chat.messages.last
            let previewId = sending?.embeds.first.flatMap { embed -> String? in
                if case let .voice(id, _, _) = embed { return id }
                return nil
            }
            whileSending = await (sending?.embeds, chat.audioPreviewURL(for: previewId ?? ""))
        }
        await chat.send(voice: note)
        guard case .voice(_, 2.5, [0, 1])? = whileSending?.embeds?.first else { return XCTFail("\(String(describing: whileSending))") }
        XCTAssertEqual(whileSending?.preview, note.fileURL)
        XCTAssertEqual(adapter.sentVoices, [note])
        XCTAssertEqual(adapter.sentVoiceReplies, ["1"])
        XCTAssertEqual(chat.messages.last?.id, "voice-1")
        XCTAssertFalse(chat.messages.contains(where: \.isSending))
        XCTAssertEqual(chat.draft, "Half written", "a voice message leaves the draft")
        XCTAssertNil(chat.replyingTo)
        chat.disconnect()
    }

    func testVoiceMessagesGoAsAFileWhereTheNetworkTakesFilesButNotVoice() async throws {
        let adapter = FakeAdapter()
        adapter.acceptsAttachments = true
        adapter.pages = [[message(1)]]
        let chat = makeChat(adapter)
        await chat.connect()
        XCTAssertTrue(chat.offersVoiceNotes)
        let recording = try makeRecording()
        try await chat.send(voice: ChatVoiceNote(recordingAt: recording))
        XCTAssertNil(chat.errorMessage)
        XCTAssertEqual(adapter.sent.first?.attachment?.mimeType, "audio/mp4")
        XCTAssertEqual(adapter.sent.first?.attachment?.filename, "Voice Message.m4a")
        XCTAssertFalse(adapter.sent.first?.attachment?.data.isEmpty ?? true)
        chat.disconnect()
    }

    func testForwardIsOfferedOnceTheOpeningScreenTakesIt() async {
        let adapter = FakeForwardingAdapter()
        adapter.pages = [[message(1)]]
        let chat = makeChat(adapter)
        await chat.connect()
        XCTAssertFalse(chat.canForward(message(1)))
        var picked: ChatForward?
        chat.forwardHandler = { picked = $0 }
        XCTAssertTrue(chat.canForward(message(1)))
        await chat.startForward(message(1))
        XCTAssertEqual(picked?.reference, "ref-1")
        XCTAssertEqual(picked?.accountId, "test")
        XCTAssertEqual(picked?.originName, "Ada")
        chat.disconnect()
    }

    func testAForwardInTheSameAccountGoesNativelyAfterTheTypedText() async {
        let adapter = FakeForwardingAdapter()
        adapter.pages = [[message(1)]]
        let chat = makeChat(adapter)
        await chat.connect()
        chat.stage(ChatForward(message: message(1), network: .telegram, accountId: "test", reference: "ref-1", media: []))
        chat.draft = "Look"
        await chat.send()
        XCTAssertEqual(adapter.sent.map(\.text), ["Look"])
        XCTAssertEqual(adapter.forwarded, ["ref-1"])
        XCTAssertNil(chat.forwarding)
        XCTAssertEqual(chat.messages.last?.id, "forward-1")
        XCTAssertFalse(chat.messages.contains(where: \.isSending))
        chat.disconnect()
    }

    func testAForwardFromAnotherNetworkOrAccountSendsACopyUnderAnItalicForwarded() async throws {
        let adapter = FakeForwardingAdapter()
        adapter.pages = [[]]
        let chat = makeChat(adapter)
        await chat.connect()
        chat.stage(ChatForward(message: message(1), network: .discord, accountId: "other", reference: "discord-ref", media: []))
        await chat.send()
        XCTAssertEqual(adapter.forwarded, [])
        XCTAssertEqual(adapter.sent.map(\.text), ["Forwarded\n\nMessage 1"], "no sender or network")
        XCTAssertEqual(adapter.sent.last?.italics, [NSRange(location: 0, length: 9)])
        XCTAssertEqual(adapter.sent.last?.markdownText(), "*Forwarded*\n\nMessage 1")
        chat.stage(ChatForward(message: message(2), network: .telegram, accountId: "other", reference: "ref-2", media: []))
        await chat.send()
        XCTAssertEqual(adapter.sent.last?.text, "Forwarded\n\nMessage 2", "another account's message goes as a copy too")
        XCTAssertEqual(adapter.sent.last?.links, [], "no link without one to the original")
        let original = try XCTUnwrap(URL(string: "https://discord.com/channels/@me/1/3"))
        chat.stage(ChatForward(message: message(3), network: .discord, accountId: "other", reference: nil, link: original, media: []))
        await chat.send()
        XCTAssertEqual(adapter.sent.last?.links, [ChatOutgoingLink(range: NSRange(location: 0, length: 9), url: original)])
        XCTAssertEqual(adapter.sent.last?.markdownText(), "[*Forwarded*](https://discord.com/channels/@me/1/3)\n\nMessage 3")
        chat.disconnect()
    }

    func testAForwardWithFilesToAChatWithoutFilesFailsAndStays() async {
        let adapter = FakeAdapter()
        adapter.pages = [[]]
        let chat = makeChat(adapter)
        await chat.connect()
        let forward = ChatForward(message: message(1), network: .discord, accountId: "other", reference: nil, media: [.image(url: URL(fileURLWithPath: "/tmp/photo.jpg"))])
        chat.stage(forward)
        await chat.send()
        XCTAssertEqual(adapter.sent.count, 0)
        XCTAssertNotNil(chat.errorMessage)
        XCTAssertEqual(chat.forwarding, forward)
        XCTAssertFalse(chat.messages.contains(where: \.isSending))
        chat.disconnect()
    }

    /// A short tone as PCM in a CAF file, as the composer records.
    private func makeRecording() throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "voice.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24000)!
        buffer.frameLength = 24000
        for index in 0 ..< 24000 {
            buffer.floatChannelData![0][index] = Float(sin(Double(index) * 2 * .pi * 440 / 48000) * 0.5)
        }
        try file.write(from: buffer)
        return url
    }

    func testCancellingOrKeepingTheTextSavesNothing() async {
        let adapter = FakeEditingAdapter()
        adapter.pages = [[message(2, own: true)]]
        let chat = makeChat(adapter)
        await chat.connect()
        chat.draft = "Half written"
        chat.startEditing(message(2, own: true))
        chat.cancelEditing()
        XCTAssertEqual(chat.draft, "Half written")
        chat.startEditing(message(2, own: true))
        await chat.send()
        XCTAssertTrue(adapter.edits.isEmpty)
        XCTAssertNil(chat.editingMessage)
        XCTAssertEqual(chat.draft, "Half written")
        chat.disconnect()
    }

    func testAFailedEditShowsTheMessageAsItWasAndReturnsTheEdit() async {
        let adapter = FakeEditingAdapter()
        adapter.pages = [[message(2, own: true)]]
        adapter.editError = URLError(.notConnectedToInternet)
        let chat = makeChat(adapter)
        await chat.connect()
        chat.startEditing(message(2, own: true))
        chat.draft = "Changed"
        await chat.send()
        XCTAssertEqual(chat.messages.last?.text, "Message 2")
        XCTAssertEqual(chat.editingMessage?.id, "2")
        XCTAssertEqual(chat.draft, "Changed")
        XCTAssertNotNil(chat.errorMessage)
        chat.disconnect()
    }

    func testASavedEditShowsUntilTheNetworksCopyArrives() async {
        let adapter = FakeEditingAdapter()
        adapter.pages = [[message(2, own: true)]]
        adapter.appliesEdits = false
        let chat = makeChat(adapter)
        await chat.connect()
        chat.startEditing(message(2, own: true))
        chat.draft = "Changed"
        await chat.send()
        XCTAssertEqual(chat.messages.last?.text, "Changed")
        XCTAssertFalse(chat.canEdit(message(2, own: true)), "not while the edit is still showing")
        adapter.replace(with: [ChatMessage(id: "2", sender: ChatUser(id: "you", name: "You", avatarURL: nil), timestamp: nil, text: "Changed, as the network wrote it", isOwn: true, isEdited: true)])
        adapter.onChange?()
        XCTAssertEqual(chat.messages.last?.text, "Changed, as the network wrote it")
        XCTAssertTrue(chat.canEdit(message(2, own: true)))
        chat.disconnect()
    }

    func testChatsWithoutEditingOfferNone() async {
        let adapter = FakeAdapter()
        adapter.pages = [[message(2, own: true)]]
        let chat = makeChat(adapter)
        await chat.connect()
        XCTAssertFalse(chat.canEdit(message(2, own: true)))
        chat.startEditing(message(2, own: true))
        XCTAssertNil(chat.editingMessage)
        chat.disconnect()
    }

    func testDeletingRemovesTheUsersMessage() async {
        let adapter = FakeDeletingAdapter()
        adapter.pages = [[message(1), message(2, own: true)]]
        let chat = makeChat(adapter)
        await chat.connect()
        XCTAssertFalse(chat.canDelete(message(1)), "someone else's message")
        XCTAssertTrue(chat.canDelete(message(2, own: true)))
        await chat.delete(message(2, own: true))
        XCTAssertEqual(adapter.deleted, ["2"])
        XCTAssertEqual(chat.messages.map(\.id), ["1"])
        chat.disconnect()
    }

    func testAFailedDeleteKeepsTheMessage() async {
        let adapter = FakeDeletingAdapter()
        adapter.pages = [[message(2, own: true)]]
        adapter.deleteError = URLError(.notConnectedToInternet)
        let chat = makeChat(adapter)
        await chat.connect()
        await chat.delete(message(2, own: true))
        XCTAssertEqual(chat.messages.map(\.id), ["2"])
        XCTAssertNotNil(chat.errorMessage)
        chat.disconnect()
    }

    func testChatsWithoutDeletingOfferNone() async {
        let adapter = FakeAdapter()
        adapter.pages = [[message(2, own: true)]]
        let chat = makeChat(adapter)
        await chat.connect()
        XCTAssertFalse(chat.canDelete(message(2, own: true)))
        chat.disconnect()
    }

    func testMutingAndArchivingChangeTheNetworkThenTheRow() async throws {
        let row = ChatSummary<String>(id: "fake:1", network: .telegram, title: "Fake", avatarURL: nil, preview: nil, timestamp: Date(), unreadCount: 0, destination: "fake")
        let list = ChatListViewModel<String>(sources: { [ChatListSource(provider: RowsProvider(chats: [row]), accountId: "test", label: "Test")] }, caches: directory)
        await list.load()
        let adapter = FakeSettingsAdapter()
        let chat = makeChat(adapter)
        XCTAssertFalse(chat.canMute, "a chat without a row doesn't know whether it is muted")
        XCTAssertFalse(chat.canArchive)

        _ = list.follow(chat, chatId: "test|fake:1")
        XCTAssertEqual(chat.isMuted, false)
        XCTAssertEqual(chat.isArchived, false)
        XCTAssertTrue(chat.canMute)
        XCTAssertTrue(chat.canArchive)

        try await chat.setMuted(true)
        XCTAssertEqual(adapter.mutes, [true])
        XCTAssertEqual(chat.isMuted, true)
        XCTAssertEqual(list.chats.first?.isMuted, true)

        try await chat.setArchived(true)
        XCTAssertEqual(adapter.archives, [true])
        XCTAssertEqual(chat.isArchived, true)
        XCTAssertEqual(list.chats.map(\.id), [])
        XCTAssertEqual(list.archivedChats.map(\.id), ["test|fake:1"])
        XCTAssertEqual(list.archivedChats.first?.isMuted, true)

        adapter.settingsError = URLError(.notConnectedToInternet)
        do {
            try await chat.setArchived(false)
            XCTFail("the network's refusal is thrown")
        } catch {}
        XCTAssertEqual(chat.isArchived, true, "a refused change leaves the chat as it was")
        XCTAssertEqual(list.archivedChats.map(\.id), ["test|fake:1"])

        adapter.settingsError = nil
        try await chat.setArchived(false)
        XCTAssertEqual(list.chats.map(\.id), ["test|fake:1"])
        XCTAssertEqual(list.archivedChats.map(\.id), [])
    }

    func testChatsWithoutMutingOrArchivingOfferNeither() async {
        let row = ChatSummary<String>(id: "fake:1", network: .telegram, title: "Fake", avatarURL: nil, preview: nil, timestamp: Date(), unreadCount: 0, destination: "fake")
        let list = ChatListViewModel<String>(sources: { [ChatListSource(provider: RowsProvider(chats: [row]), accountId: "test", label: "Test")] }, caches: directory)
        await list.load()
        let chat = makeChat(FakeAdapter())
        _ = list.follow(chat, chatId: "test|fake:1")
        XCTAssertEqual(chat.isMuted, false)
        XCTAssertFalse(chat.canMute)
        XCTAssertFalse(chat.canArchive)
    }

    private func makeStore() throws -> ChatStore {
        if let store {
            return store
        }
        store = try ChatStore(url: directory.appending(path: "store.sqlite"))
        return store
    }

    func testReactorsComeFromTheWindowWhenAReplyQuotesAStoredMessageOutsideIt() async {
        let adapter = FakeAdapter()
        adapter.pages = [[message(1), message(2)]]
        let first = makeChat(adapter)
        await first.connect()
        first.disconnect()

        let reopened = FakeRenderStateAdapter()
        let reply = ChatMessage(id: "11", sender: ChatUser(id: "ada", name: "Ada", avatarURL: nil), timestamp: nil, text: "Reply", replyToId: "1", isOwn: false)
        reopened.pages = [[message(10), reply]]
        reopened.earlierPages = [[message(3)], [message(1), message(2)]]
        reopened.reactions = ["10": [ChatReaction(emoji: "👍", count: 1, includesYou: false)]]
        let chat = makeChat(reopened)
        await chat.connect()
        XCTAssertEqual(chat.messages.map(\.id), ["10", "11"])
        XCTAssertEqual(chat.message(withId: "1")?.text, "Message 1", "the quoted message comes from the store")
        XCTAssertEqual(chat.reactors(of: "👍", on: "10").map(\.user.id), ["ada"], "the adapter's state is the window's, not the quoted message's")
        chat.disconnect()
    }

    private func makeChat(_ adapter: FakeAdapter) -> AdapterChatViewModel<FakeAdapter> {
        let suite = "AdapterChatViewModelTests-\(UUID().uuidString)"
        if store == nil {
            store = try! makeStore()
        }
        let chat = AdapterChatViewModel(
            adapter: adapter,
            accountId: "test",
            store: store,
            draftStore: ChatDraftStore(defaults: UserDefaults(suiteName: suite)!),
        )
        // As the chat screen does before its first render.
        chat.prepareToShow()
        return chat
    }
}

private func message(_ id: Int, own: Bool = false) -> ChatMessage {
    ChatMessage(id: "\(id)", sender: ChatUser(id: own ? "you" : "ada", name: own ? "You" : "Ada", avatarURL: nil), timestamp: Date(timeIntervalSince1970: Double(id)), text: "Message \(id)", isOwn: own)
}

private func said(_ id: Int, _ text: String) -> ChatMessage {
    ChatMessage(id: "\(id)", sender: ChatUser(id: "ada", name: "Ada", avatarURL: nil), timestamp: Date(timeIntervalSince1970: Double(id)), text: text, isOwn: false)
}

/// Read position is a message id, like Telegram's. The fake's network holds `catalog`: each newest fetch returns
/// the next of `pages` (or the last one again), and earlier fetches return `earlierPages` in turn.
@MainActor
private class FakeAdapter: ChatAdapter {
    let network = ChatNetwork.telegram
    let key = "fake:1"
    let canReply = true
    var acceptsAttachments = false
    let pollInterval: Duration? = .seconds(60)
    var onChange: (() -> Void)?
    var info = ChatInfo(title: "Fake", subtitle: "Test")
    var history: ChatHistory?
    var reactions: [String: [ChatReaction]] = [:]

    var pages: [[ChatMessage]] = []
    var earlierPages: [[ChatMessage]] = []
    var error: Error?
    var readUpTo = 0
    /// How many of the next read marks fail.
    var failedReadMarks = 0
    private(set) var sent: [ChatOutgoing] = []
    private(set) var readMarks: [Int] = []
    private(set) var fetches: [ChatPageRequest] = []
    /// The network's copy of each message.
    private(set) var catalog: [String: ChatMessage] = [:]
    private var newest: [ChatMessage]?
    private var sortKeys: [String: Int64] = [:]
    private var nextSortKey: Int64 = 1_000_000
    private var version: Int64 = 0

    /// The network's messages, oldest first.
    var messages: [ChatMessage] {
        catalog.values.sorted { sortKey($0.id) < sortKey($1.id) }
    }

    func sortKey(_ id: String) -> Int64 {
        if let key = sortKeys[id] {
            return key
        }
        let key: Int64
        if let numeric = Int64(id) {
            key = numeric
        } else {
            nextSortKey += 1
            key = nextSortKey
        }
        sortKeys[id] = key
        return key
    }

    func record(_ message: ChatMessage) -> ChatRecord {
        catalog[message.id] = message
        version += 1
        return ChatRecord(id: message.id, sortKey: sortKey(message.id), version: version, data: Data(message.id.utf8))
    }

    func fetch(_ request: ChatPageRequest) async throws -> ChatPage {
        fetches.append(request)
        if let error {
            throw error
        }
        info.title = "Loaded"
        switch request {
        case .newest:
            if !pages.isEmpty {
                newest = pages.removeFirst()
            }
            let page = newest ?? []
            return ChatPage(records: page.map(record), earlier: earlierPages.isEmpty ? nil : ChatCursor("earlier"))
        case .before:
            guard !earlierPages.isEmpty else { return ChatPage(records: [], earlier: nil) }
            let page = earlierPages.removeFirst()
            return ChatPage(records: page.map(record), earlier: earlierPages.isEmpty ? nil : ChatCursor("earlier"))
        case .after, .around:
            return ChatPage(records: [], earlier: nil)
        }
    }

    private(set) var renderCount = 0

    func render(_ records: [ChatRecord]) -> ChatRendering {
        renderCount += 1
        let messages = records.filter { $0.relatesTo == nil }.map { catalog[$0.id] ?? message(Int($0.id) ?? 0) }
        let ids = Set(messages.map(\.id))
        return ChatRendering(messages: messages, reactions: reactions.filter { ids.contains($0.key) })
    }

    /// A message arriving outside a page, as a pushed update or the network's copy of a sent one.
    func append(_ message: ChatMessage) {
        try? history?.write([record(message)])
    }

    /// The network's messages change to these: missing ones were deleted, the rest written again.
    func replace(with messages: [ChatMessage]) {
        let ids = Set(messages.map(\.id))
        let deleted = catalog.keys.filter { !ids.contains($0) }
        for id in deleted {
            catalog[id] = nil
        }
        try? history?.delete(ids: deleted)
        try? history?.write(messages.map(record))
    }

    /// Sends after this many succeed fail.
    var failsSendAfter: Int?

    /// How long the network takes to answer a send.
    var sendDelay: Duration?

    func send(_ message: ChatOutgoing) async throws -> String? {
        if let sendDelay {
            try await Task.sleep(for: sendDelay)
        }
        if let failsSendAfter, sent.count >= failsSendAfter {
            throw URLError(.notConnectedToInternet)
        }
        sent.append(message)
        let id = "sent-\(sent.count)"
        append(ChatMessage(id: id, sender: ChatUser(id: "you", name: "You", avatarURL: nil), timestamp: Date(), text: message.text, isOwn: true))
        return id
    }

    func isAfterReadPosition(_ message: ChatMessage) -> Bool {
        (Int(message.id) ?? 0) > readUpTo
    }

    func markRead(upTo message: ChatMessage) -> (@MainActor () async throws -> Void)? {
        guard let id = Int(message.id), id > readUpTo else { return nil }
        return { [weak self] in
            guard let self else { return }
            if failedReadMarks > 0 {
                failedReadMarks -= 1
                throw URLError(.networkConnectionLost)
            }
            readMarks.append(id)
            readUpTo = max(readUpTo, id)
        }
    }

    func reactors(of _: String, on _: String) -> [ChatReactor] {
        []
    }

    private struct State: Codable {
        let readUpTo: Int
    }

    func state() -> Data? {
        try? JSONEncoder().encode(State(readUpTo: readUpTo))
    }

    func restore(state data: Data) {
        guard let state = try? JSONDecoder().decode(State.self, from: data) else { return }
        readUpTo = state.readUpTo
    }
}

/// Keeps what it last rendered, as network adapters do, and answers reactors from it.
@MainActor
private final class FakeRenderStateAdapter: FakeAdapter {
    private var rendered: Set<String> = []

    override func render(_ records: [ChatRecord]) -> ChatRendering {
        let rendering = super.render(records)
        rendered = Set(rendering.messages.map(\.id))
        return rendering
    }

    override func reactors(of emoji: String, on messageId: String) -> [ChatReactor] {
        guard rendered.contains(messageId), reactions[messageId]?.contains(where: { $0.emoji == emoji }) == true else { return [] }
        return [ChatReactor(user: ChatUser(id: "ada", name: "Ada", avatarURL: nil), date: nil, isYou: false)]
    }
}

@MainActor
private final class FakeLiveAdapter: FakeAdapter, ChatLiveUpdating, ChatReferenceResolving {
    var onConnectionLost: ((Error?) -> Void)?
    var onError: ((Error) -> Void)?
    var onCatchUp: (() -> Void)?
    private(set) var followCount = 0
    private(set) var isFollowing = false
    var referencedMessages: [String: ChatMessage] = [:]
    var unavailableReferences: Set<String> = []

    func startFollowing() async {
        followCount += 1
        isFollowing = true
    }

    func stopFollowing() {
        isFollowing = false
    }

    func push(_ pushed: ChatMessage) {
        append(pushed)
    }
}

/// Messages 1–100 exist on the "network"; a window holds the message and the five after it.
@MainActor
private final class FakeWindowingAdapter: FakeAdapter, ChatWindowing, ChatCommanding {
    private(set) var commands: [String] = []

    override func fetch(_ request: ChatPageRequest) async throws -> ChatPage {
        switch request {
        case let .around(messageId):
            guard let id = Int(messageId), (1 ... 100).contains(id) else { return ChatPage(records: [], earlier: nil) }
            return ChatPage(records: (id ... id + 5).map { record(message($0)) }, earlier: ChatCursor(String(id)), later: ChatCursor(String(id + 5)))
        case let .after(cursor):
            let id = (Int(cursor.value) ?? 0) + 1
            return ChatPage(records: (id ... id + 5).map { record(message($0)) }, earlier: ChatCursor(String(id)), later: ChatCursor(String(id + 5)))
        default:
            return try await super.fetch(request)
        }
    }

    func isCommand(_ text: String) -> Bool {
        text.hasPrefix("/")
    }

    func sendCommand(_ text: String, replyToId _: String?) async throws {
        commands.append(text)
    }
}

@MainActor
private final class FakeEditingAdapter: FakeAdapter, ChatEditing {
    var editError: Error?
    /// Off for a network whose copy of the edit arrives later.
    var appliesEdits = true
    private(set) var edits: [(id: String, text: String)] = []

    func editableText(of message: ChatMessage) -> String? {
        messages.first { $0.id == message.id && $0.isOwn }?.text
    }

    func edit(_ messageId: String, text: String) async throws {
        if let editError {
            throw editError
        }
        edits.append((messageId, text))
        guard appliesEdits else { return }
        replace(with: messages.map { $0.id == messageId ? ChatMessage(id: $0.id, sender: $0.sender, timestamp: $0.timestamp, text: text, isOwn: true, isEdited: true) : $0 })
    }
}

@MainActor
private final class FakeMenuAdapter: FakeAdapter, ChatComposerMenus {
    private(set) var selected = "small"
    var hidesMenu = false

    var composerMenu: ChatComposerMenu? {
        guard !hidesMenu else { return nil }
        let items = [("small", "Small"), ("large", "Large")].map { ChatComposerMenuItem(id: $0.0, title: $0.1, isSelected: $0.0 == selected) }
        return ChatComposerMenu(title: items.first { $0.isSelected }?.title ?? "", accessibilityLabel: "Size", sections: [items])
    }

    func selectComposerMenuItem(_ itemId: String) {
        selected = itemId
        onChange?()
    }
}

private struct RowsProvider: ChatListProvider {
    let chats: [ChatSummary<String>]
    let chatNetwork = ChatNetwork.telegram

    func chatList() async throws -> ChatListPage<String> {
        ChatListPage(chats: chats, archived: [])
    }
}

@MainActor
private final class FakeSettingsAdapter: FakeAdapter, ChatMuting, ChatArchiving {
    var settingsError: Error?
    private(set) var mutes: [Bool] = []
    private(set) var archives: [Bool] = []

    func setMuted(_ muted: Bool) async throws {
        if let settingsError { throw settingsError }
        mutes.append(muted)
    }

    func setArchived(_ archived: Bool) async throws {
        if let settingsError { throw settingsError }
        archives.append(archived)
    }
}

@MainActor
private final class FakeDeletingAdapter: FakeAdapter, ChatDeleting {
    var deleteError: Error?
    private(set) var deleted: [String] = []

    func canDelete(_ message: ChatMessage) -> Bool {
        message.isOwn
    }

    func delete(_ messageId: String) async throws {
        if let deleteError {
            throw deleteError
        }
        deleted.append(messageId)
        replace(with: messages.filter { $0.id != messageId })
    }
}

@MainActor
private final class FakeReactingAdapter: FakeAdapter, ChatReactionSending {
    let acceptsReactions = true

    func yourEmojis(on messageId: String) -> [String] {
        reactions[messageId]?.filter(\.includesYou).map(\.emoji) ?? []
    }

    func toggleReaction(_ emoji: String, on messageId: String) async throws {
        reactions[messageId] = [ChatReaction(emoji: emoji, count: 1, includesYou: true)]
    }
}

@MainActor
private final class FakeStickerAdapter: FakeAdapter, ChatStickerSending {
    let sticker = ChatSticker(id: "7", url: URL(string: "tgfile://file/document-7-full")!, format: .lottie, posterURL: nil, aspectRatio: 1, alt: "👋")
    var stickerError: Error?
    private(set) var sentStickers: [ChatSticker] = []
    private(set) var sentStickerReplies: [String?] = []

    func stickerSets() async throws -> [ChatStickerSet] {
        [ChatStickerSet(id: "recent", title: "Recent", cover: nil, count: 1, stickers: [sticker]), ChatStickerSet(id: "set-1", title: "Hands", cover: nil, count: 1, stickers: nil)]
    }

    func stickers(forEmoji emoji: String) async throws -> [ChatSticker] {
        emoji == "👋" ? [sticker] : []
    }

    func stickers(inSet id: String) async throws -> [ChatSticker] {
        id == "set-1" ? [sticker] : []
    }

    func send(sticker: ChatSticker, replyToId: String?) async throws -> String? {
        if let stickerError {
            throw stickerError
        }
        sentStickers.append(sticker)
        sentStickerReplies.append(replyToId)
        let id = "sticker-\(sentStickers.count)"
        append(ChatMessage(id: id, sender: ChatUser(id: "you", name: "You", avatarURL: nil), timestamp: Date(), text: nil, embeds: [.sticker(sticker)], isOwn: true))
        return id
    }
}

@MainActor
private final class FakeForwardingAdapter: FakeAdapter, ChatForwarding {
    private(set) var forwarded: [String] = []

    func forwardReference(for message: ChatMessage) -> String? {
        "ref-\(message.id)"
    }

    func forward(reference: String) async throws -> String? {
        forwarded.append(reference)
        let id = "forward-\(forwarded.count)"
        append(ChatMessage(id: id, sender: ChatUser(id: "you", name: "You", avatarURL: nil), timestamp: Date(), text: "Message 1", isOwn: true, forwardedFrom: ChatForwardOrigin(name: "Ada")))
        return id
    }
}

@MainActor
private final class FakeVoiceAdapter: FakeAdapter, ChatVoiceSending {
    var onSend: (() async -> Void)?
    private(set) var sentVoices: [ChatVoiceNote] = []
    private(set) var sentVoiceReplies: [String?] = []

    func send(voice: ChatVoiceNote, replyToId: String?) async throws -> String? {
        await onSend?()
        sentVoices.append(voice)
        sentVoiceReplies.append(replyToId)
        let id = "voice-\(sentVoices.count)"
        append(ChatMessage(id: id, sender: ChatUser(id: "you", name: "You", avatarURL: nil), timestamp: Date(), text: nil, embeds: [.voice(previewId: id, duration: voice.duration, waveform: voice.waveform)], isOwn: true))
        return id
    }
}

@MainActor
private final class FakeReceiptsAdapter: FakeAdapter, ChatReadReceipts {
    var seenUpTo = 0

    func receipt(for message: ChatMessage) -> ChatReceipt? {
        (Int(message.id) ?? 0) <= seenUpTo ? .seen : .sent
    }
}

@MainActor
private final class FakeUnseenReactionsAdapter: FakeAdapter, ChatUnseenReactions {
    var unseen: [String] = []
    private var pending: Set<String> = []
    private(set) var seenSends: [[String]] = []

    var unseenReactionMessageIds: [String] {
        unseen
    }

    func markReactionsSeen(on messageIds: Set<String>) -> (@MainActor () async throws -> Void)? {
        unseen.removeAll { messageIds.contains($0) }
        pending.formUnion(messageIds)
        return { [weak self] in
            guard let self, !pending.isEmpty else { return }
            seenSends.append(pending.sorted())
            pending = []
        }
    }
}

private func file(_ n: Int) -> ChatAttachment {
    ChatAttachment(data: Data("\(n)".utf8), mimeType: "text/plain", filename: "\(n).txt", isImage: false)
}
