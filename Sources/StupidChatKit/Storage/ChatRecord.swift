import Foundation

/// One item of a chat's history as its network describes it, stored as the adapter encodes it. The kit orders,
/// stores and gaps records; only the adapter reads `data` (`ChatAdapter.render`).
public struct ChatRecord: Hashable, Sendable {
    /// The network's id, unique within the chat. A message's record id is the `ChatMessage.id` it renders as.
    public let id: String
    /// Orders records within the chat: the network's increasing id or sequence, or a timestamp. Ties order by `id`.
    public let sortKey: Int64
    /// Set for an event about another record rather than a message of its own, such as a reaction or an edit kept as
    /// a separate event: it is read whenever its target is, wherever either is stored, and never bounds history.
    public let relatesTo: String?
    /// A stored record is replaced only by one with the same or a greater version, such as an edit's timestamp or
    /// a snapshot's log id; 0 when every copy replaces the last.
    public let version: Int64
    public let data: Data

    public init(id: String, sortKey: Int64, relatesTo: String? = nil, version: Int64 = 0, data: Data) {
        self.id = id
        self.sortKey = sortKey
        self.relatesTo = relatesTo
        self.version = version
        self.data = data
    }

    public init(id: String, sortKey: Int64, relatesTo: String? = nil, version: Int64 = 0, encoding value: some Encodable) throws {
        try self.init(id: id, sortKey: sortKey, relatesTo: relatesTo, version: version, data: ChatRecord.encoder.encode(value))
    }

    public func decode<T: Decodable>(_: T.Type) throws -> T {
        try ChatRecord.decoder.decode(T.self, from: data)
    }

    var isMessage: Bool {
        relatesTo == nil
    }

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()
}

/// Where a network's paging continues, as the adapter writes it (a message id, a timestamp, an opaque token).
public struct ChatCursor: Hashable, Codable, Sendable {
    public let value: String

    public init(_ value: String) {
        self.value = value
    }
}

/// What a page fetch asks for.
public enum ChatPageRequest: Hashable, Sendable {
    /// The newest messages.
    case newest
    /// The messages just before the cursor, which came from an earlier page or `ChatAdapter.cursor(before:)`.
    case before(ChatCursor)
    /// The messages just after the cursor (`ChatWindowing`).
    case after(ChatCursor)
    /// Messages on both sides of one (`ChatWindowing`).
    case around(messageId: String)
}

/// A contiguous run of history from the network.
public struct ChatPage: Sendable {
    public var records: [ChatRecord]
    /// Where earlier history continues; `nil` at the start of the chat.
    public var earlier: ChatCursor?
    /// Where later history continues; `nil` when the page reaches the newest message. Ignored for `.newest` and
    /// `.before`.
    public var later: ChatCursor?
    /// The sort keys the page holds everything of, so a stored message in it that the page lacks was deleted. By
    /// default the span of its message records. A network whose pages can carry records from outside it (such as
    /// an old message edited within the page's time) names it, and those records only update stored copies.
    public var covers: ClosedRange<Int64>?
    /// Whether the page holds every message in `covers`, so a stored one it lacks was deleted. A network that
    /// reports deletions as records of their own (tombstones) says false.
    public var isComplete: Bool

    public init(records: [ChatRecord], earlier: ChatCursor?, later: ChatCursor? = nil, covers: ClosedRange<Int64>? = nil, isComplete: Bool = true) {
        self.records = records
        self.earlier = earlier
        self.later = later
        self.covers = covers
        self.isComplete = isComplete
    }

    var coveredRange: ClosedRange<Int64>? {
        if let covers {
            return covers
        }
        let keys = records.filter(\.isMessage).map(\.sortKey)
        guard let low = keys.min(), let high = keys.max() else { return nil }
        return low ... high
    }
}
