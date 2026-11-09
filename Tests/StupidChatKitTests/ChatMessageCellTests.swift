@testable import StupidChatKit
import UIKit
import XCTest

@MainActor
final class ChatMessageCellTests: XCTestCase {
    private func fittedHeight(of cell: UICollectionViewCell, width: CGFloat) -> CGFloat {
        cell.contentView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
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
}
