import Foundation
@testable import StupidChatKit
import XCTest

final class ChatStoreTests: XCTestCase {
    private var directory: URL!
    private var store: ChatStore!
    private let chat = "account|test:chat"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "ChatStoreTests-\(UUID().uuidString)")
        store = try ChatStore(url: directory.appending(path: "store.sqlite"))
    }

    override func tearDown() {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func record(_ id: Int, version: Int64 = 0, text: String? = nil) -> ChatRecord {
        ChatRecord(id: String(id), sortKey: Int64(id), version: version, data: Data((text ?? String(id)).utf8))
    }

    private func page(_ ids: ClosedRange<Int>, earlier: Bool = true) -> ChatPage {
        ChatPage(records: ids.map { record($0) }, earlier: earlier ? ChatCursor(String(ids.lowerBound)) : nil)
    }

    private func newestIds(_ count: Int = 100) throws -> [String] {
        try store.window(chatKey: chat, at: .newest(count: count)).records.map(\.id)
    }

    func testANewestPageIsTheNewestWindowAndCurrentForTheEpoch() throws {
        try store.apply(page(5 ... 9), for: .newest, chatKey: chat)
        XCTAssertEqual(try newestIds(), ["5", "6", "7", "8", "9"])
        XCTAssertEqual(try store.window(chatKey: chat, at: .newest(count: 2)).records.map(\.id), ["8", "9"])
        let window = try store.window(chatKey: chat, at: .newest(count: 2))
        XCTAssertTrue(window.hasStoredEarlier)
        XCTAssertTrue(window.hasEarlier)
        XCTAssertFalse(window.hasLater)
        XCTAssertTrue(try store.isCurrent(chatKey: chat, latestMessageId: nil))
        store.raiseEpoch(accountId: "account")
        XCTAssertFalse(try store.isCurrent(chatKey: chat, latestMessageId: nil), "a raised epoch may have missed messages")
        XCTAssertFalse(try store.isCurrent(chatKey: chat, latestMessageId: "10"))
        XCTAssertTrue(try store.isCurrent(chatKey: chat, latestMessageId: "9"), "the newest chunk holds the latest message")
        XCTAssertTrue(try store.isCurrent(chatKey: chat, latestMessageId: nil), "and is stamped with the epoch")
    }

    func testANewestPageThatDoesntOverlapStartsANewChunkAboveAGap() throws {
        try store.apply(page(1 ... 5), for: .newest, chatKey: chat)
        let newer = try store.apply(page(20 ... 24), for: .newest, chatKey: chat)
        XCTAssertEqual(try newestIds(), ["20", "21", "22", "23", "24"])
        XCTAssertEqual(newer.earlierCursor, ChatCursor("20"))
        XCTAssertEqual(try store.window(chatKey: chat, at: ChatStore.WindowPosition(anchorId: "1", upperSortKey: nil, count: 10)).records.map(\.id), ["1", "2", "3", "4", "5"])
        let older = try store.window(chatKey: chat, at: ChatStore.WindowPosition(anchorId: "1", upperSortKey: nil, count: 10))
        XCTAssertTrue(older.hasLater, "the old chunk no longer reaches the newest message")
    }

    func testFillingAGapMergesTheChunks() throws {
        try store.apply(page(1 ... 5, earlier: false), for: .newest, chatKey: chat)
        let newer = try store.apply(page(20 ... 24), for: .newest, chatKey: chat)
        let filled = try store.apply(page(10 ... 19), for: .before(ChatCursor("20")), chatKey: chat, adjacentTo: newer.id)
        XCTAssertEqual(filled.earlierCursor, ChatCursor("10"), "still a gap between 5 and 10")
        let merged = try store.apply(page(4 ... 9), for: .before(ChatCursor("10")), chatKey: chat, adjacentTo: filled.id)
        XCTAssertFalse(merged.hasEarlier, "joined the chunk that starts the chat")
        XCTAssertEqual(try newestIds().count, 24)
        XCTAssertTrue(merged.reachesNewest)
    }

    func testAnEmptyEarlierPageMeansTheChatStartsThere() throws {
        let chunk = try store.apply(page(1 ... 5), for: .newest, chatKey: chat)
        let start = try store.apply(ChatPage(records: [], earlier: nil), for: .before(ChatCursor("1")), chatKey: chat, adjacentTo: chunk.id)
        XCTAssertFalse(start.hasEarlier)
        XCTAssertFalse(try store.window(chatKey: chat, at: .newest(count: 50)).hasEarlier)
    }

    func testAPageDeletesTheMessagesItCoversButLacks() throws {
        try store.apply(page(1 ... 5), for: .newest, chatKey: chat)
        try store.apply(ChatPage(records: [record(1), record(2), record(4), record(5), record(6)], earlier: ChatCursor("1")), for: .newest, chatKey: chat)
        XCTAssertEqual(try newestIds(), ["1", "2", "4", "5", "6"])
    }

    func testRecordsOutsideAPagesCoveredRangeOnlyUpdate() throws {
        try store.apply(page(10 ... 12), for: .newest, chatKey: chat)
        let edit = ChatPage(records: [record(3), record(11, text: "edited"), record(12), record(13)], earlier: ChatCursor("11"), covers: 11 ... 13)
        try store.apply(edit, for: .newest, chatKey: chat)
        XCTAssertEqual(try newestIds(), ["10", "11", "12", "13"], "3 is outside what the page covers")
        XCTAssertEqual(try store.record(id: "11", chatKey: chat)?.data, Data("edited".utf8))
    }

    func testLiveRecordsContinueACurrentChunkAndStartANewOneAfterAMissedStretch() throws {
        try store.apply(page(1 ... 3), for: .newest, chatKey: chat)
        try store.write([record(4)], chatKey: chat)
        XCTAssertEqual(try newestIds(), ["1", "2", "3", "4"])
        store.raiseEpoch(accountId: "account")
        try store.write([record(8)], chatKey: chat)
        XCTAssertEqual(try newestIds(), ["8"], "messages may be missing between 4 and 8")
        let window = try store.window(chatKey: chat, at: .newest(count: 10))
        XCTAssertTrue(window.hasEarlier)
        XCTAssertNil(window.chunk?.earlierCursor, "the adapter derives the cursor from the oldest message")
        try store.write([record(9)], chatKey: chat)
        XCTAssertEqual(try newestIds(), ["8", "9"], "the new chunk is current")
        try store.write([record(2, text: "edited"), record(6)], chatKey: chat)
        XCTAssertEqual(try store.record(id: "2", chatKey: chat)?.data, Data("edited".utf8), "a stored record updates in place")
        XCTAssertNil(try store.record(id: "6", chatKey: chat), "an unstored old message waits for its page")
    }

    func testOnlyAnEqualOrNewerVersionReplacesARecord() throws {
        try store.apply(ChatPage(records: [record(1, version: 5, text: "five")], earlier: nil), for: .newest, chatKey: chat)
        try store.write([record(1, version: 4, text: "four")], chatKey: chat)
        XCTAssertEqual(try store.record(id: "1", chatKey: chat)?.data, Data("five".utf8))
        try store.write([record(1, version: 6, text: "six")], chatKey: chat)
        XCTAssertEqual(try store.record(id: "1", chatKey: chat)?.data, Data("six".utf8))
    }

    func testRelatedRecordsComeWithTheirTargets() throws {
        try store.apply(page(1 ... 3), for: .newest, chatKey: chat)
        let reaction = ChatRecord(id: "r1", sortKey: 50, relatesTo: "2", data: Data())
        try store.write([reaction], chatKey: chat)
        let window = try store.window(chatKey: chat, at: .newest(count: 10))
        XCTAssertEqual(window.records.map(\.id), ["1", "2", "3", "r1"])
        XCTAssertEqual(window.newestMessage?.id, "3", "related records don't bound history")
        XCTAssertEqual(try store.window(chatKey: chat, at: .newest(count: 1)).records.map(\.id), ["3"])
    }

    func testWindowsExtendAndCenter() throws {
        try store.apply(page(1 ... 30), for: .newest, chatKey: chat)
        var position = ChatStore.WindowPosition.newest(count: 5)
        position = try store.position(extending: position, earlierBy: 5, chatKey: chat)
        XCTAssertEqual(try store.window(chatKey: chat, at: position).records.map(\.id), (21 ... 30).map(String.init))
        let around = try XCTUnwrap(store.position(around: "10", count: 6, chatKey: chat))
        let window = try store.window(chatKey: chat, at: around)
        XCTAssertEqual(window.records.map(\.id), (8 ... 13).map(String.init))
        XCTAssertTrue(window.hasLater)
        let later = try store.position(extending: around, laterBy: 3, chatKey: chat)
        XCTAssertEqual(try store.window(chatKey: chat, at: later).records.map(\.id), (8 ... 16).map(String.init))
    }

    func testRemovingAnAccountRemovesItsChats() throws {
        try store.apply(page(1 ... 3), for: .newest, chatKey: chat)
        try store.apply(page(1 ... 3), for: .newest, chatKey: "other|test:chat")
        try store.setState(Data("state".utf8), chatKey: chat)
        try store.removeAll(accountId: "account")
        XCTAssertEqual(try newestIds(), [])
        XCTAssertNil(try store.state(chatKey: chat))
        XCTAssertEqual(try store.window(chatKey: "other|test:chat", at: .newest(count: 10)).records.count, 3)
    }

    func testProvisionalRecordsShowUntilTheNetworksCopyAndNeverMakeAChatCurrent() throws {
        try store.apply(page(1 ... 3), for: .newest, chatKey: chat)
        try store.writeProvisional([record(9, text: "pushed")], chatKey: chat)
        try store.writeProvisional([record(9)], chatKey: "account|test:unstored")
        XCTAssertEqual(try newestIds(), ["1", "2", "3", "9"], "shown after the stored messages")
        XCTAssertTrue(try store.window(chatKey: "account|test:unstored", at: .newest(count: 10)).records.isEmpty, "only stored chats take them")
        store.raiseEpoch(accountId: "account")
        XCTAssertFalse(try store.isCurrent(chatKey: chat, latestMessageId: "9"), "the chat still fetches")
        try store.writeProvisional([record(2, text: "pushed")], chatKey: chat)
        XCTAssertEqual(try store.record(id: "2", chatKey: chat)?.data, Data("2".utf8), "stored records are left")

        try store.apply(page(3 ... 9), for: .newest, chatKey: chat)
        XCTAssertEqual(try store.record(id: "9", chatKey: chat)?.data, Data("9".utf8), "the network's copy replaces it")
        XCTAssertTrue(try store.isCurrent(chatKey: chat, latestMessageId: "9"))

        try store.writeProvisional([record(12)], chatKey: chat)
        try store.apply(page(10 ... 14).withoutRecord(12), for: .newest, chatKey: chat)
        XCTAssertNil(try store.record(id: "12", chatKey: chat), "a page that covers it without it removes it")
        try store.writeProvisional([record(99)], chatKey: chat)
        try store.apply(page(13 ... 15), for: .newest, chatKey: chat)
        XCTAssertNil(try store.record(id: "99", chatKey: chat), "nothing is newer than a newest page")
    }

    func testChatKeysMatchBySuffix() throws {
        try store.apply(page(1 ... 1), for: .newest, chatKey: "a|telegram:user:1")
        try store.apply(page(1 ... 1), for: .newest, chatKey: "b|telegram:user:1")
        try store.apply(page(1 ... 1), for: .newest, chatKey: "a|telegram:user:12")
        XCTAssertEqual(try Set(store.chatKeys(endingWith: "|telegram:user:1")), ["a|telegram:user:1", "b|telegram:user:1"])
    }

    @MainActor
    func testWritesNotifyTheChatsObservers() throws {
        var count = 0
        let observation = store.observe(chatKey: chat) { count += 1 }
        try store.apply(page(1 ... 3), for: .newest, chatKey: chat)
        try store.write([record(4)], chatKey: chat)
        try store.write([record(4)], chatKey: "other|chat")
        XCTAssertEqual(count, 2)
        observation.cancel()
        try store.write([record(5)], chatKey: chat)
        XCTAssertEqual(count, 2)
    }
}

private extension ChatPage {
    func withoutRecord(_ id: Int) -> ChatPage {
        ChatPage(records: records.filter { $0.id != String(id) }, earlier: earlier, later: later, covers: coveredRange)
    }
}
