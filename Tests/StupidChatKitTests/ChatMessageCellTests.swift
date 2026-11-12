@testable import StupidChatKit
import UIKit
import XCTest

@MainActor
final class ChatMessageCellTests: XCTestCase {
    private func fittedHeight(of cell: UICollectionViewCell, width: CGFloat) -> CGFloat {
        cell.contentView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel,
        ).height
    }

    /// A system caption sizes its cell: a long one used to overflow into the messages after it.
    func testSystemCaptionSizesTheCell() {
        let width: CGFloat = 390
        let text = String(repeating: "Could not connect to the server. ", count: 30)
        let body = NSAttributedString(string: text, attributes: [.font: UIFont.preferredFont(forTextStyle: .footnote)])
        let message = ChatMessage(
            id: "notice",
            sender: ChatUser(id: "system", name: nil, avatarURL: nil, isSystem: true),
            timestamp: Date(),
            text: text,
            isOwn: false,
            isNotice: true,
        )
        let cell = ChatMessageCell(frame: CGRect(x: 0, y: 0, width: width, height: 44))
        cell.configure(
            message: message,
            layout: ChatBubbleLayout(isOwn: false, isSystem: true, showsName: false, showsAvatar: false, startsGroup: true),
            reply: nil,
            avatarURL: nil,
            body: body,
            embeds: [],
            reactions: [],
            actions: .init(),
            availableWidth: width,
        )
        let textHeight = body.boundingRect(with: CGSize(width: width * 0.85, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height
        XCTAssertGreaterThanOrEqual(fittedHeight(of: cell, width: width), ceil(textHeight))
    }

    /// A reused cell sizes to the bubble again after showing a system caption.
    func testBubbleSizesTheCellAfterACaption() {
        let width: CGFloat = 390
        let cell = ChatMessageCell(frame: CGRect(x: 0, y: 0, width: width, height: 44))
        let caption = NSAttributedString(string: "Today", attributes: [.font: UIFont.preferredFont(forTextStyle: .footnote)])
        cell.configure(
            message: ChatMessage(id: "c", sender: ChatUser(id: "system", name: nil, avatarURL: nil, isSystem: true), timestamp: nil, text: "Today", isOwn: false, isNotice: true),
            layout: ChatBubbleLayout(isOwn: false, isSystem: true, showsName: false, showsAvatar: false, startsGroup: true),
            reply: nil, avatarURL: nil, body: caption, embeds: [], reactions: [], actions: .init(), availableWidth: width,
        )
        let text = String(repeating: "A long message in a bubble. ", count: 20)
        let body = NSAttributedString(string: text, attributes: [.font: UIFont.preferredFont(forTextStyle: .body)])
        cell.configure(
            message: ChatMessage(id: "m", sender: ChatUser(id: "ada", name: "Ada", avatarURL: nil), timestamp: Date(), text: text, isOwn: false),
            layout: ChatBubbleLayout(isOwn: false, isSystem: false, showsName: false, showsAvatar: true, startsGroup: true),
            reply: nil, avatarURL: nil, body: body, embeds: [], reactions: [], actions: .init(), availableWidth: width,
        )
        let textHeight = body.boundingRect(with: CGSize(width: width * 0.8, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height
        XCTAssertGreaterThanOrEqual(fittedHeight(of: cell, width: width), ceil(textHeight))
    }

    /// A post sizes its cell, shows twelve lines of a long text until opened, and its quote adds to it.
    func testPostSizesTheCellAndOpensToItsWholeText() {
        let width: CGFloat = 390
        let long = String(repeating: "A long post that runs on for a while. ", count: 30)
        func height(_ post: ChatPost, expanded: Bool) -> CGFloat {
            let cell = ChatMessageCell(frame: CGRect(x: 0, y: 0, width: width, height: 44))
            var actions = ChatMessageCell.Actions()
            actions.isEmbedExpanded = { _ in expanded }
            cell.configure(
                message: ChatMessage(id: "p", sender: ChatUser(id: "ada", name: "Ada", avatarURL: nil), timestamp: Date(), text: nil, embeds: [.post(post)], isOwn: false),
                layout: ChatBubbleLayout(isOwn: false, isSystem: false, showsName: false, showsAvatar: true, startsGroup: true),
                reply: nil, avatarURL: nil, body: nil, embeds: [.post(post)], reactions: [], actions: actions, availableWidth: width,
            )
            return fittedHeight(of: cell, width: width)
        }
        let short = ChatPost(authorName: "Ada", authorHandle: "@ada", isVerified: true, date: Date(), text: "Hello")
        let collapsed = height(ChatPost(authorName: "Ada", text: long), expanded: false)
        let expanded = height(ChatPost(authorName: "Ada", text: long), expanded: true)
        let quoting = height(ChatPost(authorName: "Ada", text: "Hello", quoted: ChatPost(authorName: "Grace", text: "Quoted")), expanded: false)
        let lineHeight = UIFont.preferredFont(forTextStyle: .subheadline).lineHeight
        XCTAssertGreaterThan(height(short, expanded: false), 36 + 20, "the header and the frame's margins")
        XCTAssertGreaterThanOrEqual(collapsed, 12 * lineHeight)
        XCTAssertGreaterThan(expanded, collapsed + lineHeight)
        XCTAssertGreaterThan(quoting, height(short, expanded: false) + lineHeight)
    }

    func testPostDateReadsLikeANetworks() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        XCTAssertEqual(ChatMessageCell.postDate(now.addingTimeInterval(-30), now: now, calendar: calendar), "now")
        XCTAssertEqual(ChatMessageCell.postDate(now.addingTimeInterval(-5 * 60), now: now, calendar: calendar), "5m")
        XCTAssertEqual(ChatMessageCell.postDate(now.addingTimeInterval(-3 * 3600), now: now, calendar: calendar), "3h")
        XCTAssertFalse(ChatMessageCell.postDate(now.addingTimeInterval(-3 * 86400), now: now, calendar: calendar).contains("20"), "no year within this year")
        XCTAssertTrue(ChatMessageCell.postDate(now.addingTimeInterval(-400 * 86400), now: now, calendar: calendar).contains("2025"))
    }

    func testPostCountsReadLikeXs() {
        let counts = [0, 999, 1000, 1250, 1299, 12345, 123_456, 999_999, 3_450_000, 2_100_000_000]
        XCTAssertEqual(counts.map { ChatMessageCell.compactCount($0, locale: Locale(identifier: "en_US")) }, ["0", "999", "1K", "1.2K", "1.2K", "12K", "123K", "999K", "3.4M", "2.1B"])
    }

    /// Counts add a row under the post; with none to show, there is no row.
    func testPostCountsAddARow() {
        let width: CGFloat = 390
        func height(_ counts: ChatPost.Counts?) -> CGFloat {
            let post = ChatPost(authorName: "Ada", text: "Hello", counts: counts)
            let cell = ChatMessageCell(frame: CGRect(x: 0, y: 0, width: width, height: 44))
            cell.configure(
                message: ChatMessage(id: "p", sender: ChatUser(id: "ada", name: "Ada", avatarURL: nil), timestamp: Date(), text: nil, embeds: [.post(post)], isOwn: false),
                layout: ChatBubbleLayout(isOwn: false, isSystem: false, showsName: false, showsAvatar: true, startsGroup: true),
                reply: nil, avatarURL: nil, body: nil, embeds: [.post(post)], reactions: [], actions: .init(), availableWidth: width,
            )
            return fittedHeight(of: cell, width: width)
        }
        XCTAssertGreaterThan(height(ChatPost.Counts(replies: 3, reposts: 10, likes: 1250)), height(nil) + 10)
        XCTAssertEqual(height(ChatPost.Counts(replies: nil, reposts: nil, likes: nil)), height(nil))
    }
}
