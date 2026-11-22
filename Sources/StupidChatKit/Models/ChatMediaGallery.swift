import Combine
import Foundation

/// A photo or video sent in a chat, as the app's full-screen viewer pages through them (`ChatKit.openChatMedia`).
public struct ChatMediaItem: Hashable, Sendable {
    /// `<message id>#<embed index>`: unique in the chat, and the same as more messages load.
    public let key: String
    public let messageId: String
    /// The photo, or the video.
    public let url: URL
    /// A video's poster, when the network gives one.
    public let posterURL: URL?
    public let isVideo: Bool
    public let isGIF: Bool
    /// Width over height.
    public let aspectRatio: Double?
    public let alt: String?
    /// The message's text.
    public let caption: String?
    /// Which of the message's photos and videos this is, from 0, and how many it has.
    public let index: Int
    public let count: Int

    /// Every photo and video that fills a bubble (`ChatMessageCell`'s media: viewer images and videos), oldest
    /// first. Link previews' and posts' media and stickers are left out: they open on their own.
    public static func items(in messages: [ChatMessage]) -> [ChatMediaItem] {
        messages.flatMap { message -> [ChatMediaItem] in
            guard !message.isDeleted else { return [] }
            let media: [(offset: Int, url: URL, poster: URL?, isVideo: Bool, isGIF: Bool, ratio: Double?, alt: String?)] =
                message.embeds.enumerated().compactMap { offset, embed in
                    switch embed {
                    case let .image(url, aspectRatio, alt, _, true): (offset, url, nil, false, false, aspectRatio, alt)
                    case let .video(url, posterURL, aspectRatio, _, isGIF): (offset, url, posterURL, true, isGIF, aspectRatio, nil)
                    default: nil
                    }
                }
            let caption = message.text?.trimmingCharacters(in: .whitespacesAndNewlines)
            return media.enumerated().map { index, item in
                ChatMediaItem(
                    key: "\(message.id)#\(item.offset)",
                    messageId: message.id,
                    url: item.url,
                    posterURL: item.poster,
                    isVideo: item.isVideo,
                    isGIF: item.isGIF,
                    aspectRatio: item.ratio,
                    alt: item.alt,
                    caption: caption?.isEmpty == false ? caption : nil,
                    index: index,
                    count: media.count,
                )
            }
        }
    }
}

/// A chat's photos and videos for the app's viewer, opened at the one tapped. `updates` brings the media again as
/// messages load or change; `loadEarlier` asks for older messages, for paging back past the first.
@MainActor
public struct ChatMediaGallery {
    public let network: ChatNetwork
    public let items: [ChatMediaItem]
    public let startKey: String
    public let updates: AnyPublisher<[ChatMediaItem], Never>
    public let loadEarlier: () -> Void

    init(viewModel: ChatViewModel, startKey: String) {
        network = viewModel.network
        items = ChatMediaItem.items(in: viewModel.messages)
        self.startKey = startKey
        updates = viewModel.$messages.map(ChatMediaItem.items(in:)).removeDuplicates().eraseToAnyPublisher()
        loadEarlier = { [weak viewModel] in
            guard let viewModel, viewModel.hasEarlierMessages, !viewModel.isLoadingEarlier else { return }
            Task { await viewModel.loadEarlier() }
        }
    }
}
