import Foundation
import StupidChatKit

/// Networks the tests name, as an app would declare its own.
extension ChatNetwork {
    static let apron = ChatNetwork(rawValue: "apron")
    static let telegram = ChatNetwork(rawValue: "telegram")
    static let spotify = ChatNetwork(rawValue: "spotify")
    static let x = ChatNetwork(rawValue: "x")
    static let discord = ChatNetwork(rawValue: "discord")
}

/// An app's archive in memory, as `ChatLocalArchive`.
@MainActor
final class FakeLocalArchive: ChatLocalArchive {
    let didChange = Notification.Name("FakeLocalArchive.didChange-\(UUID().uuidString)")
    var archived: Set<String> = []

    func isArchived(_ chatId: String) -> Bool {
        archived.contains(chatId)
    }

    func setArchived(_ archived: Bool, chatId: String) {
        if archived {
            self.archived.insert(chatId)
        } else {
            self.archived.remove(chatId)
        }
    }

    /// As when another device changes it: the change, then the notification.
    func changeRemotely(archived: Bool, chatId: String) {
        setArchived(archived, chatId: chatId)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
