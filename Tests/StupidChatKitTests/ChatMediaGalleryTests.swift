@testable import StupidChatKit
import XCTest

final class ChatMediaGalleryTests: XCTestCase {
    private let ada = ChatUser(id: "ada", name: "Ada", avatarURL: nil)
    private let photo = URL(string: "https://example.com/a.jpg")!
    private let video = URL(string: "https://example.com/b.mp4")!
    private let poster = URL(string: "https://example.com/b.jpg")!

    /// Only media that fills a bubble is paged through, oldest first, keyed by message and embed.
    func testItemsAreTheBubblesPhotosAndVideosInOrder() {
        let messages = [
            ChatMessage(id: "1", sender: ada, timestamp: nil, text: " Look ", embeds: [
                .image(url: photo, aspectRatio: 1, alt: "A cat", link: nil, opensViewer: true),
                .card(title: "Card", subtitle: nil, systemImage: "link", imageURL: nil, link: nil),
                .video(url: video, posterURL: poster, aspectRatio: 16 / 9, duration: "0:05", isGIF: false),
            ], isOwn: false),
            ChatMessage(id: "2", sender: ada, timestamp: nil, text: nil, embeds: [
                .image(url: photo, aspectRatio: nil, alt: nil, link: nil, opensViewer: false),
                .linkPreview(title: "Preview", subtitle: nil, link: nil, media: [.image(url: photo, aspectRatio: nil, alt: nil, link: nil, opensViewer: true)]),
            ], isOwn: false),
            ChatMessage(id: "3", sender: ada, timestamp: nil, text: "", embeds: [
                .video(url: video, posterURL: nil, aspectRatio: nil, duration: nil, isGIF: true),
            ], isOwn: true),
        ]

        let items = ChatMediaItem.items(in: messages)

        XCTAssertEqual(items.map(\.key), ["1#0", "1#2", "3#0"])
        XCTAssertEqual(items.map(\.index), [0, 1, 0])
        XCTAssertEqual(items.map(\.count), [2, 2, 1])
        XCTAssertEqual(items.map(\.isVideo), [false, true, true])
        XCTAssertEqual(items[0].alt, "A cat")
        XCTAssertEqual(items[0].caption, "Look")
        XCTAssertEqual(items[1].posterURL, poster)
        XCTAssertNil(items[2].caption)
        XCTAssertTrue(items[2].isGIF)
    }
}
