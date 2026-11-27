import Foundation
@testable import StupidChatKit
import XCTest

final class ChatReactionGridTests: XCTestCase {
    private let cooking = ChatCustomEmoji(key: ":cooking:", url: URL(string: "https://example.com/cooking.png")!, category: "Food")
    private let hidden = ChatCustomEmoji(key: ":secret:", url: URL(string: "https://example.com/secret.png")!, isHidden: true)

    func testCatalogHasTheKeyboardsCategoriesInOrder() {
        let titles = EmojiCatalog.categories.map(\.title)
        XCTAssertEqual(titles.first, "Smileys & Emotion")
        XCTAssertEqual(titles.last, "Flags")
        XCTAssertEqual(EmojiCatalog.categories.first?.entries.first?.emoji, "😀")
    }

    func testSearchPutsTheEmojiNamedExactlyFirst() {
        let found = EmojiCatalog.search("fire").map(\.emoji)
        XCTAssertEqual(found.first, "🔥")
        XCTAssertTrue(found.contains("🚒"), "a word starting with the query matches too")
        XCTAssertEqual(EmojiCatalog.search("  ").count, 0)
    }

    func testCustomEmojiComeFirstThenEveryCategory() {
        let sections = ChatReactionGrid.sections(customEmojis: [cooking.key: cooking, hidden.key: hidden], choices: nil, query: "")
        XCTAssertEqual(sections.first?.title, "Food")
        XCTAssertEqual(sections.first?.items, [.custom(cooking)], "hidden custom emoji aren't offered")
        XCTAssertEqual(sections.dropFirst().map(\.title), EmojiCatalog.categories.map(\.title))
    }

    func testChoicesReplaceTheCatalog() {
        let sections = ChatReactionGrid.sections(customEmojis: [:], choices: ["❤", "👍"], query: "")
        XCTAssertEqual(sections.map(\.title), ["Reactions"])
        XCTAssertEqual(sections.first?.items, [.emoji("❤"), .emoji("👍")])
    }

    func testSearchKeepsToTheChoicesAsTheNetworkWritesThem() {
        let sections = ChatReactionGrid.sections(customEmojis: [:], choices: ["❤", "🔥"], query: "heart")
        XCTAssertEqual(sections.first?.items.map(\.key), ["❤"], "Telegram's ❤ matches the catalog's ❤️")
    }

    func testSearchFindsCustomEmojiBeforeUnicode() {
        let sections = ChatReactionGrid.sections(customEmojis: [cooking.key: cooking], choices: nil, query: "cook")
        XCTAssertEqual(sections.map(\.title), ["Results"])
        XCTAssertEqual(sections.first?.items.first, .custom(cooking))
        XCTAssertTrue(sections.first?.items.contains(.emoji("🧑‍🍳")) == true)
    }

    func testRecentReactionsLeadTheGridAsOneRow() {
        let recent = ["🔥", ":cooking:", "👍", "😂", "❤️", "🙏", "😮", "🎉", "👀", "💯"]
        let sections = ChatReactionGrid.sections(customEmojis: [cooking.key: cooking], choices: nil, recent: recent, query: "")
        XCTAssertEqual(sections.map(\.title).prefix(2), ["Recently Used", "Food"])
        XCTAssertEqual(sections.first?.items.count, ChatReactionGrid.recentCount)
        XCTAssertEqual(sections.first?.items.prefix(2), [.emoji("🔥"), .custom(cooking)])
        XCTAssertTrue(sections.contains { $0.title == "Smileys & Emotion" && $0.items.contains(.emoji("😂")) }, "a recent emoji stays in its category")
    }

    func testRecentReactionsKeepToWhatTheChatTakes() {
        let recent = [":cooking:", ":secret:", "❤️", "🔥", "🦄"]
        let sections = ChatReactionGrid.sections(customEmojis: [hidden.key: hidden], choices: ["❤", "👍"], recent: recent, query: "")
        XCTAssertEqual(sections.first?.title, "Recently Used")
        XCTAssertEqual(sections.first?.items, [.emoji("❤")], "custom emoji from elsewhere, hidden ones and emoji the network doesn't take are left out, and a choice is written as the network writes it")
        let anyEmoji = ChatReactionGrid.sections(customEmojis: [:], choices: nil, recent: ["❤"], query: "")
        XCTAssertEqual(anyEmoji.first?.items, [.emoji("❤️")], "the catalog's spelling where any emoji goes")
    }

    func testNoRecentRowWithoutRecentsOrWhileSearching() {
        XCTAssertNotEqual(ChatReactionGrid.sections(customEmojis: [:], choices: nil, recent: [], query: "").first?.title, "Recently Used")
        XCTAssertEqual(ChatReactionGrid.sections(customEmojis: [:], choices: nil, recent: ["🔥"], query: "fire").map(\.title), ["Results"])
    }

    func testRecentReactionsMoveToTheFrontOnce() throws {
        let suite = "ChatRecentReactionsTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let recents = ChatRecentReactions(defaults: defaults)
        recents.use("🔥")
        recents.use("❤️")
        recents.use("👍")
        recents.use("❤")
        XCTAssertEqual(recents.keys, ["❤", "👍", "🔥"])
        for index in 0 ..< ChatRecentReactions.limit + 5 {
            recents.use(":e\(index):")
        }
        XCTAssertEqual(recents.keys.count, ChatRecentReactions.limit)
    }
}
