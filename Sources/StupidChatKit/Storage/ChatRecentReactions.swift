import Foundation

/// The emoji the user last reacted with on this device, most recent first, which the reaction grid offers first.
/// Kept as the network wrote them (custom emoji by key); the grid offers each only in chats that take it.
final class ChatRecentReactions {
    private let defaults: UserDefaults
    private let key = "chatRecentReactions"
    /// More than the grid shows, so a chat that takes only some emoji can still fill its row.
    static let limit = 32

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var keys: [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    /// Moves the reaction to the front; Telegram's ❤ and the catalog's ❤️ count as one.
    func use(_ reaction: String) {
        let bare = { (emoji: String) in emoji.replacingOccurrences(of: "\u{FE0F}", with: "") }
        var keys = keys
        keys.removeAll { bare($0) == bare(reaction) }
        keys.insert(reaction, at: 0)
        defaults.set(Array(keys.prefix(Self.limit)), forKey: key)
    }
}
