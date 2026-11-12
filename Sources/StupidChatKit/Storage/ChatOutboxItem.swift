import Foundation

/// A message the user sent that the network hasn't taken yet, kept in the store so it survives the app closing.
struct ChatOutboxItem: Codable, Equatable {
    enum Content: Codable, Equatable {
        case message(text: String, attachments: [Attachment], replyToId: String?)
        case sticker(ChatSticker, replyToId: String?)
        case voice(audio: Data, fileExtension: String, duration: Double, waveform: [Double], replyToId: String?)
    }

    struct Attachment: Codable, Equatable {
        let data: Data
        let mimeType: String
        let filename: String
        let isImage: Bool

        init(_ attachment: ChatAttachment) {
            data = attachment.data
            mimeType = attachment.mimeType
            filename = attachment.filename
            isImage = attachment.isImage
        }

        var attachment: ChatAttachment {
            ChatAttachment(data: data, mimeType: mimeType, filename: filename, isImage: isImage)
        }
    }

    let id: String
    let chatKey: String
    let created: Date
    let content: Content
    /// Handed to the network: if the app closed before it answered, the message may or may not have gone, so it
    /// goes back to the composer rather than being sent again.
    var isInFlight: Bool
}
