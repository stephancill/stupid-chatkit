import Foundation

/// Every chat's history on this device, which the chat screen reads and the network writes. A chat's history is a
/// list of chunks, runs of messages known to have nothing missing between them, with a gap between two chunks that
/// the earlier edge's cursor fills. Keys are `ChatViewModel.chatKey`s (`<account id>|<adapter key>`).
///
/// Freshness: each account has a sync epoch, raised whenever its live connection may have missed events (and new at
/// every launch). The newest chunk records the epoch it was last known to reach the newest message in, so a live
/// event in the same epoch continues it and one in a later epoch starts a new chunk with a gap below.
///
/// Thread-safe; writes notify observers on the main actor.
public final class ChatStore: @unchecked Sendable {
    public struct Chunk: Hashable, Sendable {
        public let id: Int64
        /// More history is before this chunk: on the network at `earlierCursor`, or, without one, wherever the
        /// adapter's `cursor(before:)` for the oldest message says.
        public let hasEarlier: Bool
        public let earlierCursor: ChatCursor?
        public let reachesNewest: Bool
        /// Where later history continues when the chunk doesn't reach the newest message.
        public let laterCursor: ChatCursor?
        let epoch: String?
    }

    /// The records of a stretch of one chunk, and what lies around it.
    public struct Window: Sendable {
        public let chunk: Chunk?
        /// Messages oldest first, then the records related to them.
        public let records: [ChatRecord]
        /// The chunk holds older messages than the window.
        public let hasStoredEarlier: Bool
        /// The chunk holds newer messages than the window.
        public let hasStoredLater: Bool

        static let empty = Window(chunk: nil, records: [], hasStoredEarlier: false, hasStoredLater: false)

        public var oldestMessage: ChatRecord? {
            records.first(where: \.isMessage)
        }

        public var newestMessage: ChatRecord? {
            records.last(where: \.isMessage)
        }

        /// Whether more history is before the window, stored or on the network.
        public var hasEarlier: Bool {
            hasStoredEarlier || (chunk?.hasEarlier ?? false)
        }

        /// Whether newer history than the window exists, stored or on the network.
        public var hasLater: Bool {
            hasStoredLater || !(chunk?.reachesNewest ?? true)
        }
    }

    /// Where an open chat's window sits; the store reads it again after every write.
    public struct WindowPosition: Hashable, Sendable {
        /// The oldest message shown; `nil` for the newest messages of the newest chunk.
        public var anchorId: String?
        /// The newest sort key shown; `nil` to follow the chunk's newest message.
        public var upperSortKey: Int64?
        /// For a window without an anchor, how many messages to show.
        public var count: Int

        public static func newest(count: Int) -> WindowPosition {
            WindowPosition(anchorId: nil, upperSortKey: nil, count: count)
        }
    }

    public let url: URL
    private let database: ChatDatabase
    private let lock = NSLock()
    private let launchId = UUID().uuidString
    private var epochs: [String: Int] = [:]
    @MainActor private var observers: [String: [UUID: @MainActor () -> Void]] = [:]
    @MainActor private var allObservers: [UUID: @MainActor (Set<String>?) -> Void] = [:]
    private let darwinName: String?

    /// The default store, in Application Support. An app whose extensions write to the store too sets
    /// `ChatKit.store` to one in its App Group container at launch.
    public static func defaultURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "chat-store.sqlite")
    }

    /// `darwinNotificationName`, when set, tells other processes sharing the file (an app and its notification
    /// extension) that it changed, and makes this store pick up their writes.
    public init(url: URL = ChatStore.defaultURL(), darwinNotificationName: String? = nil) throws {
        self.url = url
        darwinName = darwinNotificationName
        database = try ChatDatabase(url: url)
        try database.execute("PRAGMA journal_mode=WAL")
        try database.execute("PRAGMA synchronous=NORMAL")
        try database.execute(Self.schema)
        try? (url as NSURL).setResourceValue(URLFileProtection.completeUntilFirstUserAuthentication, forKey: .fileProtectionKey)
        if let darwinNotificationName {
            listenForOtherProcesses(name: darwinNotificationName)
        }
    }

    private static let schema = """
    CREATE TABLE IF NOT EXISTS chat (
        key TEXT PRIMARY KEY,
        account TEXT NOT NULL,
        state BLOB,
        opened_at REAL
    );
    CREATE INDEX IF NOT EXISTS chat_account ON chat(account);
    CREATE TABLE IF NOT EXISTS chunk (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        chat TEXT NOT NULL,
        has_earlier INTEGER NOT NULL,
        earlier TEXT,
        reaches_newest INTEGER NOT NULL,
        later TEXT,
        epoch TEXT
    );
    CREATE INDEX IF NOT EXISTS chunk_chat ON chunk(chat);
    CREATE TABLE IF NOT EXISTS record (
        chat TEXT NOT NULL,
        id TEXT NOT NULL,
        chunk INTEGER,
        sort INTEGER NOT NULL,
        relates TEXT,
        version INTEGER NOT NULL,
        data BLOB NOT NULL,
        PRIMARY KEY (chat, id)
    );
    CREATE INDEX IF NOT EXISTS record_order ON record(chat, chunk, sort, id);
    CREATE INDEX IF NOT EXISTS record_relates ON record(chat, relates) WHERE relates IS NOT NULL;
    CREATE TABLE IF NOT EXISTS outbox (
        id TEXT PRIMARY KEY,
        chat TEXT NOT NULL,
        account TEXT NOT NULL,
        created REAL NOT NULL,
        payload BLOB NOT NULL,
        failure TEXT
    );
    CREATE INDEX IF NOT EXISTS outbox_chat ON outbox(chat, created);
    """

    static func accountId(of chatKey: String) -> String {
        chatKey.split(separator: "|", maxSplits: 1).first.map(String.init) ?? chatKey
    }

    // MARK: Epochs

    /// The account's current sync epoch.
    public func epoch(accountId: String) -> String {
        locked { "\(launchId):\(epochs[accountId, default: 0])" }
    }

    /// The account's live connection may have missed events: newest chunks stop counting as current until a fetch
    /// or a newer list row shows they are.
    public func raiseEpoch(accountId: String) {
        locked { epochs[accountId, default: 0] += 1 }
    }

    // MARK: Writing

    /// Stores a page fetched for `request`. `adjacentTo` is the chunk the request continues (the newer chunk for
    /// `.before`, the older one for `.after`), which the page joins even where no message overlaps.
    @discardableResult
    public func apply(_ page: ChatPage, for request: ChatPageRequest, chatKey: String, adjacentTo adjacent: Int64? = nil) throws -> Chunk {
        let chunk = try locked {
            try database.transaction {
                try ensureChat(chatKey)
                return try applyPage(page, request: request, chat: chatKey, adjacent: adjacent)
            }
        }
        didChange([chatKey])
        return chunk
    }

    /// Stores records that arrived outside a page (live events, a sent message, the network's answer to an
    /// action). A stored record is updated where it is. A new message continues the newest chunk while that is
    /// current; newer than everything stored, it starts a new newest chunk; anything else is left to the page that
    /// will bring it. Related records are always kept.
    public func write(_ records: [ChatRecord], chatKey: String) throws {
        guard !records.isEmpty else { return }
        try locked {
            try database.transaction {
                try ensureChat(chatKey)
                try writeLive(records, chat: chatKey)
            }
        }
        didChange([chatKey])
    }

    /// Removes records the network deleted.
    public func delete(ids: [String], chatKey: String) throws {
        guard !ids.isEmpty else { return }
        try locked {
            try database.transaction {
                for id in ids {
                    try database.run("DELETE FROM record WHERE chat = ? AND id = ?", [.text(chatKey), .text(id)])
                }
            }
        }
        didChange([chatKey])
    }

    /// Changes a stored record, such as an optimistic reaction; `transform` returning `nil` leaves it.
    public func update(id: String, chatKey: String, _ transform: (ChatRecord) throws -> ChatRecord?) throws {
        let changed = try locked {
            try database.transaction { () -> Bool in
                guard let record = try storedRecord(id: id, chat: chatKey), let updated = try transform(record) else { return false }
                try database.run(
                    "UPDATE record SET sort = ?, relates = ?, version = ?, data = ? WHERE chat = ? AND id = ?",
                    [.int(updated.sortKey), .optional(updated.relatesTo), .int(updated.version), .blob(updated.data), .text(chatKey), .text(id)],
                )
                return true
            }
        }
        if changed {
            didChange([chatKey])
        }
    }

    // MARK: Reading

    public func record(id: String, chatKey: String) throws -> ChatRecord? {
        try locked { try storedRecord(id: id, chat: chatKey) }
    }

    /// The records related to these, wherever they are stored.
    public func related(to ids: [String], chatKey: String) throws -> [ChatRecord] {
        try locked { try relatedRecords(to: ids, chat: chatKey) }
    }

    public func newestChunk(chatKey: String) throws -> Chunk? {
        try locked { try newest(chat: chatKey) }
    }

    /// Whether the newest stored messages are the chat's newest: the newest chunk holds the network's latest message
    /// (which makes it current for this epoch), or, without one, was current in this epoch.
    public func isCurrent(chatKey: String, latestMessageId: String?) throws -> Bool {
        try locked {
            guard let chunk = try newest(chat: chatKey), chunk.reachesNewest else { return false }
            let epoch = "\(launchId):\(epochs[Self.accountId(of: chatKey), default: 0])"
            if let latestMessageId {
                guard let stored = try database.first(
                    "SELECT chunk FROM record WHERE chat = ? AND id = ?", [.text(chatKey), .text(latestMessageId)], map: { $0.int(0) },
                ), stored == chunk.id else { return false }
                if chunk.epoch != epoch {
                    try database.run("UPDATE chunk SET epoch = ? WHERE id = ?", [.text(epoch), .int(chunk.id)])
                }
                return true
            }
            return chunk.epoch == epoch
        }
    }

    /// The window at a position: from its anchor (or the newest `count` messages) up to its upper bound.
    public func window(chatKey: String, at position: WindowPosition) throws -> Window {
        try locked {
            if let anchorId = position.anchorId,
               let anchor = try database.first(
                   "SELECT chunk, sort FROM record WHERE chat = ? AND id = ? AND relates IS NULL",
                   [.text(chatKey), .text(anchorId)], map: { ($0.int(0), $0.int(1)) },
               ),
               let chunk = try chunk(id: anchor.0)
            {
                return try readWindow(chat: chatKey, chunk: chunk, lower: anchor.1, upper: position.upperSortKey)
            }
            guard let chunk = try newest(chat: chatKey) else { return .empty }
            let lower = try database.first(
                "SELECT sort FROM record WHERE chat = ? AND chunk = ? AND relates IS NULL ORDER BY sort DESC, id DESC LIMIT 1 OFFSET ?",
                [.text(chatKey), .int(chunk.id), .int(Int64(max(position.count, 1) - 1))], map: { $0.int(0) },
            )
            return try readWindow(chat: chatKey, chunk: chunk, lower: lower, upper: nil)
        }
    }

    /// A window of about `count` messages around a stored one; `nil` when it isn't stored.
    public func position(around messageId: String, count: Int, chatKey: String) throws -> WindowPosition? {
        try locked {
            guard let anchor = try database.first(
                "SELECT chunk, sort FROM record WHERE chat = ? AND id = ? AND relates IS NULL",
                [.text(chatKey), .text(messageId)], map: { ($0.int(0), $0.int(1)) },
            ), let chunk = try chunk(id: anchor.0) else { return nil }
            let half = Int64(max(count / 2, 1))
            let below = try database.first(
                "SELECT id FROM (SELECT id, sort FROM record WHERE chat = ? AND chunk = ? AND relates IS NULL AND sort <= ? ORDER BY sort DESC, id DESC LIMIT ?) ORDER BY sort ASC, id ASC LIMIT 1",
                [.text(chatKey), .int(chunk.id), .int(anchor.1), .int(half)], map: { $0.text(0) },
            ) ?? messageId
            let above = try database.first(
                "SELECT sort FROM record WHERE chat = ? AND chunk = ? AND relates IS NULL AND sort > ? ORDER BY sort ASC, id ASC LIMIT 1 OFFSET ?",
                [.text(chatKey), .int(chunk.id), .int(anchor.1), .int(half - 1)], map: { $0.int(0) },
            )
            return WindowPosition(anchorId: below, upperSortKey: above, count: count)
        }
    }

    /// The position `count` stored messages earlier than the window's oldest, in the same chunk.
    public func position(extending position: WindowPosition, earlierBy count: Int, chatKey: String) throws -> WindowPosition {
        let window = try window(chatKey: chatKey, at: position)
        guard let chunk = window.chunk, let oldest = window.oldestMessage else { return position }
        let anchorId = try locked {
            try database.first(
                "SELECT id FROM (SELECT id, sort FROM record WHERE chat = ? AND chunk = ? AND relates IS NULL AND (sort < ? OR (sort = ? AND id < ?)) ORDER BY sort DESC, id DESC LIMIT ?) ORDER BY sort ASC, id ASC LIMIT 1",
                [.text(chatKey), .int(chunk.id), .int(oldest.sortKey), .int(oldest.sortKey), .text(oldest.id), .int(Int64(count))], map: { $0.text(0) },
            )
        }
        var extended = position
        extended.anchorId = anchorId ?? oldest.id
        return extended
    }

    /// The position `count` stored messages later than the window's newest, following the chunk's newest message
    /// once it gets there.
    public func position(extending position: WindowPosition, laterBy count: Int, chatKey: String) throws -> WindowPosition {
        let window = try window(chatKey: chatKey, at: position)
        guard let chunk = window.chunk, let newest = window.newestMessage, let oldest = window.oldestMessage else { return position }
        let upper = try locked {
            try database.first(
                "SELECT sort FROM record WHERE chat = ? AND chunk = ? AND relates IS NULL AND sort > ? ORDER BY sort ASC, id ASC LIMIT 1 OFFSET ?",
                [.text(chatKey), .int(chunk.id), .int(newest.sortKey), .int(Int64(max(count, 1) - 1))], map: { $0.int(0) },
            )
        }
        return WindowPosition(anchorId: position.anchorId ?? oldest.id, upperSortKey: upper, count: position.count)
    }

    // MARK: Chat state

    /// What the chat's adapter keeps between visits (names, read positions, …).
    public func state(chatKey: String) throws -> Data? {
        try locked {
            try database.first("SELECT state FROM chat WHERE key = ?", [.text(chatKey)], map: { $0.blob(0) }) ?? nil
        }
    }

    public func setState(_ state: Data?, chatKey: String) throws {
        try locked {
            try ensureChat(chatKey)
            try database.run("UPDATE chat SET state = ? WHERE key = ?", [state.map { .blob($0) } ?? .null, .text(chatKey)])
        }
    }

    func markOpened(chatKey: String) throws {
        try locked {
            try ensureChat(chatKey)
            try database.run("UPDATE chat SET opened_at = ? WHERE key = ?", [.double(Date().timeIntervalSince1970), .text(chatKey)])
        }
    }

    // MARK: Outbox

    /// Adds a message to send, or updates one already waiting.
    func enqueue(_ item: ChatOutboxItem) throws {
        let payload = try PropertyListEncoder().encode(item)
        try locked {
            try database.run(
                "INSERT OR REPLACE INTO outbox (id, chat, account, created, payload) VALUES (?, ?, ?, ?, ?)",
                [.text(item.id), .text(item.chatKey), .text(Self.accountId(of: item.chatKey)), .double(item.created.timeIntervalSince1970), .blob(payload)],
            )
        }
    }

    /// The chat's messages waiting to send, oldest first.
    func outbox(chatKey: String) throws -> [ChatOutboxItem] {
        try locked {
            try database.rows("SELECT payload FROM outbox WHERE chat = ? ORDER BY created ASC", [.text(chatKey)]) { row in
                try PropertyListDecoder().decode(ChatOutboxItem.self, from: row.blob(0) ?? Data())
            }
        }
    }

    func dequeue(id: String) throws {
        try locked { try database.run("DELETE FROM outbox WHERE id = ?", [.text(id)]) }
    }

    /// Chats with messages waiting to send.
    public func chatKeysWithQueuedMessages() throws -> [String] {
        try locked { try database.rows("SELECT DISTINCT chat FROM outbox", map: { $0.text(0) ?? "" }) }
    }

    // MARK: Maintenance

    /// Bytes on disk, the write-ahead log included.
    public var size: Int64 {
        [url, URL(filePath: url.path + "-wal"), URL(filePath: url.path + "-shm")].reduce(0) { total, file in
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + Int64(size)
        }
    }

    /// Removes every chat's history and state; messages waiting to send stay.
    public func removeHistory() throws {
        let keys = try locked {
            try database.transaction { () -> Set<String> in
                let keys = try Set(database.rows("SELECT key FROM chat", map: { $0.text(0) ?? "" }))
                try database.execute("DELETE FROM record; DELETE FROM chunk; DELETE FROM chat;")
                return keys
            }
        }
        try? locked { try database.execute("VACUUM") }
        didChange(keys)
    }

    /// Removes an account's chats, such as a removed account's.
    public func removeAll(accountId: String) throws {
        let keys = try locked {
            try database.transaction { () -> Set<String> in
                let keys = try Set(database.rows("SELECT key FROM chat WHERE account = ?", [.text(accountId)], map: { $0.text(0) ?? "" }))
                for key in keys {
                    try database.run("DELETE FROM record WHERE chat = ?", [.text(key)])
                    try database.run("DELETE FROM chunk WHERE chat = ?", [.text(key)])
                }
                try database.run("DELETE FROM chat WHERE account = ?", [.text(accountId)])
                try database.run("DELETE FROM outbox WHERE account = ?", [.text(accountId)])
                return keys
            }
        }
        didChange(keys)
    }

    // MARK: Observing

    /// Calls `handler` after every write to the chat, from this process or another sharing the file.
    @MainActor
    public func observe(chatKey: String, _ handler: @escaping @MainActor () -> Void) -> ChatStoreObservation {
        let id = UUID()
        observers[chatKey, default: [:]][id] = handler
        return ChatStoreObservation { [weak self] in
            self?.observers[chatKey]?[id] = nil
        }
    }

    /// Calls `handler` after every write, with the chats written (`nil` when another process wrote).
    @MainActor
    public func observeAll(_ handler: @escaping @MainActor (Set<String>?) -> Void) -> ChatStoreObservation {
        let id = UUID()
        allObservers[id] = handler
        return ChatStoreObservation { [weak self] in
            self?.allObservers[id] = nil
        }
    }

    private func didChange(_ keys: Set<String>) {
        guard !keys.isEmpty else { return }
        if let darwinName {
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(darwinName as CFString), nil, nil, true)
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated { notify(keys) }
        } else {
            Task { @MainActor in notify(keys) }
        }
    }

    @MainActor
    private func notify(_ keys: Set<String>?) {
        if let keys {
            for key in keys {
                for handler in observers[key]?.values.map(\.self) ?? [] {
                    handler()
                }
            }
        } else {
            for handler in observers.values.flatMap(\.values) {
                handler()
            }
        }
        for handler in allObservers.values {
            handler(keys)
        }
    }

    private func listenForOtherProcesses(name: String) {
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), observer, { _, observer, _, _, _ in
            guard let observer else { return }
            let store = Unmanaged<ChatStore>.fromOpaque(observer).takeUnretainedValue()
            Task { @MainActor in store.notify(nil) }
        }, name as CFString, nil, .deliverImmediately)
    }

    // MARK: Internals (called with the lock held)

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func ensureChat(_ chat: String) throws {
        try database.run("INSERT OR IGNORE INTO chat (key, account) VALUES (?, ?)", [.text(chat), .text(Self.accountId(of: chat))])
    }

    private func currentEpoch(chat: String) -> String {
        "\(launchId):\(epochs[Self.accountId(of: chat), default: 0])"
    }

    private static let chunkColumns = "id, has_earlier, earlier, reaches_newest, later, epoch"

    private static func chunk(from row: ChatDatabase.Row) -> Chunk {
        Chunk(
            id: row.int(0),
            hasEarlier: row.int(1) != 0,
            earlierCursor: row.text(2).map(ChatCursor.init),
            reachesNewest: row.int(3) != 0,
            laterCursor: row.text(4).map(ChatCursor.init),
            epoch: row.text(5),
        )
    }

    private func chunk(id: Int64) throws -> Chunk? {
        try database.first("SELECT \(Self.chunkColumns) FROM chunk WHERE id = ?", [.int(id)], map: Self.chunk(from:))
    }

    /// The chunk that reaches the newest message, else the one with the newest messages.
    private func newest(chat: String) throws -> Chunk? {
        if let chunk = try database.first(
            "SELECT \(Self.chunkColumns) FROM chunk WHERE chat = ? AND reaches_newest = 1 ORDER BY id DESC LIMIT 1", [.text(chat)], map: Self.chunk(from:),
        ) {
            return chunk
        }
        guard let id = try database.first(
            "SELECT chunk FROM record WHERE chat = ? AND relates IS NULL ORDER BY sort DESC LIMIT 1", [.text(chat)], map: { $0.int(0) },
        ) else { return nil }
        return try chunk(id: id)
    }

    private static let recordColumns = "id, sort, relates, version, data"

    private static func record(from row: ChatDatabase.Row) -> ChatRecord {
        ChatRecord(id: row.text(0) ?? "", sortKey: row.int(1), relatesTo: row.text(2), version: row.int(3), data: row.blob(4) ?? Data())
    }

    private func storedRecord(id: String, chat: String) throws -> ChatRecord? {
        try database.first("SELECT \(Self.recordColumns) FROM record WHERE chat = ? AND id = ?", [.text(chat), .text(id)], map: Self.record(from:))
    }

    private func relatedRecords(to ids: [String], chat: String) throws -> [ChatRecord] {
        guard !ids.isEmpty else { return [] }
        var result: [ChatRecord] = []
        for batch in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0 ..< min($0 + 500, ids.count)]) }) {
            let marks = Array(repeating: "?", count: batch.count).joined(separator: ",")
            result += try database.rows(
                "SELECT \(Self.recordColumns) FROM record WHERE chat = ? AND relates IN (\(marks)) ORDER BY sort ASC, id ASC",
                [.text(chat)] + batch.map { .text($0) }, map: Self.record(from:),
            )
        }
        return result
    }

    private func span(chunk: Int64) throws -> ClosedRange<Int64>? {
        try database.first("SELECT MIN(sort), MAX(sort), COUNT(*) FROM record WHERE chunk = ? AND relates IS NULL", [.int(chunk)]) { row in
            row.int(2) == 0 ? nil : row.int(0) ... row.int(1)
        } ?? nil
    }

    private func readWindow(chat: String, chunk: Chunk, lower: Int64?, upper: Int64?) throws -> Window {
        var sql = "SELECT \(Self.recordColumns) FROM record WHERE chat = ? AND chunk = ? AND relates IS NULL"
        var values: [ChatDatabase.Value] = [.text(chat), .int(chunk.id)]
        if let lower {
            sql += " AND sort >= ?"
            values.append(.int(lower))
        }
        if let upper {
            sql += " AND sort <= ?"
            values.append(.int(upper))
        }
        let messages = try database.rows(sql + " ORDER BY sort ASC, id ASC", values, map: Self.record(from:))
        let related = try relatedRecords(to: messages.map(\.id), chat: chat)
        let earlier = try lower.map { lower in
            try database.first(
                "SELECT 1 FROM record WHERE chunk = ? AND relates IS NULL AND sort < ? LIMIT 1", [.int(chunk.id), .int(lower)], map: { _ in true },
            ) ?? false
        } ?? false
        let later = try upper.map { upper in
            try database.first(
                "SELECT 1 FROM record WHERE chunk = ? AND relates IS NULL AND sort > ? LIMIT 1", [.int(chunk.id), .int(upper)], map: { _ in true },
            ) ?? false
        } ?? false
        return Window(chunk: chunk, records: messages + related, hasStoredEarlier: earlier, hasStoredLater: later)
    }

    private func insert(_ record: ChatRecord, chat: String, chunk: Int64?) throws {
        try database.run(
            "INSERT INTO record (chat, id, chunk, sort, relates, version, data) VALUES (?, ?, ?, ?, ?, ?, ?)",
            [.text(chat), .text(record.id), chunk.map { .int($0) } ?? .null, .int(record.sortKey), .optional(record.relatesTo), .int(record.version), .blob(record.data)],
        )
    }

    /// Replaces a stored record with a copy of the same or a greater version, keeping its chunk; false when none is
    /// stored.
    private func replaceStored(_ record: ChatRecord, chat: String) throws -> Bool {
        guard let version = try database.first(
            "SELECT version FROM record WHERE chat = ? AND id = ?", [.text(chat), .text(record.id)], map: { $0.int(0) },
        ) else { return false }
        if record.version >= version {
            try database.run(
                "UPDATE record SET sort = ?, relates = ?, version = ?, data = ? WHERE chat = ? AND id = ?",
                [.int(record.sortKey), .optional(record.relatesTo), .int(record.version), .blob(record.data), .text(chat), .text(record.id)],
            )
        }
        return true
    }

    private func writeLive(_ records: [ChatRecord], chat: String) throws {
        let epoch = currentEpoch(chat: chat)
        for record in records.sorted(by: { ($0.sortKey, $0.id) < ($1.sortKey, $1.id) }) {
            if try replaceStored(record, chat: chat) {
                continue
            }
            let newest = try newest(chat: chat)
            if !record.isMessage {
                try insert(record, chat: chat, chunk: nil)
                continue
            }
            let span = try newest.flatMap { try span(chunk: $0.id) }
            if let newest, newest.reachesNewest, newest.epoch == epoch, span.map({ record.sortKey >= $0.lowerBound }) ?? true {
                try insert(record, chat: chat, chunk: newest.id)
                continue
            }
            let storedMax = try database.first(
                "SELECT MAX(sort) FROM record WHERE chat = ? AND relates IS NULL", [.text(chat)], map: { $0.isNull(0) ? nil : $0.int(0) },
            ) ?? nil
            guard storedMax.map({ record.sortKey > $0 }) ?? true else { continue }
            try database.run("UPDATE chunk SET reaches_newest = 0, later = NULL WHERE chat = ? AND reaches_newest = 1", [.text(chat)])
            try database.run(
                "INSERT INTO chunk (chat, has_earlier, earlier, reaches_newest, later, epoch) VALUES (?, ?, NULL, 1, NULL, ?)",
                [.text(chat), .bool(storedMax != nil || newest != nil), .text(epoch)],
            )
            try insert(record, chat: chat, chunk: database.lastInsertId)
        }
    }

    private struct Part {
        var span: ClosedRange<Int64>?
        var hasEarlier: Bool
        var earlier: String?
        var reachesNewest: Bool
        var later: String?
        var epoch: String?
    }

    private func applyPage(_ page: ChatPage, request: ChatPageRequest, chat: String, adjacent: Int64?) throws -> Chunk {
        let epoch = currentEpoch(chat: chat)
        let covered = page.coveredRange
        let pageReachesNewest: Bool = switch request {
        case .newest: true
        case .before: false
        case .after, .around: page.later == nil
        }
        var pagePart = Part(
            span: covered, hasEarlier: page.earlier != nil, earlier: page.earlier?.value,
            reachesNewest: pageReachesNewest, later: pageReachesNewest ? nil : page.later?.value, epoch: pageReachesNewest ? epoch : nil,
        )
        if case .before = request {
            pagePart.later = nil
        }

        // The chunks the page joins: those its covered range overlaps, the one it continues, and, for a page that
        // reaches the newest message, the chunk that did.
        var joined: [Chunk] = []
        let chunks = try database.rows("SELECT \(Self.chunkColumns) FROM chunk WHERE chat = ?", [.text(chat)], map: Self.chunk(from:))
        for chunk in chunks {
            let span = try span(chunk: chunk.id)
            let overlaps = if let covered, let span { covered.overlaps(span) } else { false }
            let continues = chunk.id == adjacent
            let emptyNewest = span == nil && chunk.reachesNewest && pageReachesNewest
            let newerAfterPage = if case .after = request, pageReachesNewest, chunk.reachesNewest { true } else { false }
            if overlaps || continues || emptyNewest || newerAfterPage {
                joined.append(chunk)
            } else if span == nil, !chunk.reachesNewest {
                try database.run("DELETE FROM chunk WHERE id = ?", [.int(chunk.id)])
            }
        }
        if pageReachesNewest {
            let joinedIds = Set(joined.map(\.id))
            for chunk in chunks where chunk.reachesNewest && !joinedIds.contains(chunk.id) {
                try database.run("UPDATE chunk SET reaches_newest = 0, later = NULL WHERE id = ?", [.int(chunk.id)])
            }
        }

        var parts = [pagePart]
        for chunk in joined {
            try parts.append(Part(
                span: span(chunk: chunk.id), hasEarlier: chunk.hasEarlier, earlier: chunk.earlierCursor?.value,
                reachesNewest: chunk.reachesNewest, later: chunk.laterCursor?.value, epoch: chunk.epoch,
            ))
        }
        // The earlier edge is the oldest part's; a `.before` page with nothing in it means the chunk it continues
        // starts the chat.
        let oldest: Part = if case .before = request, covered == nil { pagePart } else {
            parts.filter { $0.span != nil }.min { $0.span!.lowerBound < $1.span!.lowerBound } ?? pagePart
        }
        let reachesNewest = parts.contains(where: \.reachesNewest)
        let newestPart = parts.filter { $0.span != nil }.max { $0.span!.upperBound < $1.span!.upperBound } ?? pagePart
        let resultEpoch = pageReachesNewest ? epoch : parts.first(where: \.reachesNewest)?.epoch

        let target: Int64
        if let first = joined.first {
            target = first.id
            try database.run(
                "UPDATE chunk SET has_earlier = ?, earlier = ?, reaches_newest = ?, later = ?, epoch = ? WHERE id = ?",
                [.bool(oldest.hasEarlier), .optional(oldest.earlier), .bool(reachesNewest), .optional(reachesNewest ? nil : newestPart.later), .optional(resultEpoch), .int(target)],
            )
            for other in joined.dropFirst() {
                try database.run("UPDATE record SET chunk = ? WHERE chunk = ?", [.int(target), .int(other.id)])
                try database.run("DELETE FROM chunk WHERE id = ?", [.int(other.id)])
            }
        } else {
            try database.run(
                "INSERT INTO chunk (chat, has_earlier, earlier, reaches_newest, later, epoch) VALUES (?, ?, ?, ?, ?, ?)",
                [.text(chat), .bool(oldest.hasEarlier), .optional(oldest.earlier), .bool(reachesNewest), .optional(reachesNewest ? nil : newestPart.later), .optional(resultEpoch)],
            )
            target = database.lastInsertId
        }

        // Messages the page covers but doesn't hold were deleted.
        if let covered {
            let ids = Set(page.records.map(\.id))
            let stale = try database.rows(
                "SELECT id FROM record WHERE chunk = ? AND relates IS NULL AND sort >= ? AND sort <= ?",
                [.int(target), .int(covered.lowerBound), .int(covered.upperBound)], map: { $0.text(0) ?? "" },
            ).filter { !ids.contains($0) }
            for id in stale {
                try database.run("DELETE FROM record WHERE chat = ? AND id = ?", [.text(chat), .text(id)])
            }
        }

        for record in page.records {
            let inside = covered.map { $0.contains(record.sortKey) } ?? false
            if try replaceStored(record, chat: chat) {
                if inside, record.isMessage {
                    try database.run("UPDATE record SET chunk = ? WHERE chat = ? AND id = ?", [.int(target), .text(chat), .text(record.id)])
                }
                continue
            }
            if !record.isMessage {
                try insert(record, chat: chat, chunk: nil)
            } else if inside {
                try insert(record, chat: chat, chunk: target)
            }
        }
        return try chunk(id: target)!
    }
}

/// Stops an observation when cancelled or released.
public final class ChatStoreObservation: @unchecked Sendable {
    private var onCancel: (@MainActor () -> Void)?

    init(_ onCancel: @escaping @MainActor () -> Void) {
        self.onCancel = onCancel
    }

    @MainActor
    public func cancel() {
        onCancel?()
        onCancel = nil
    }

    deinit {
        guard let onCancel else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated { onCancel() }
        } else {
            Task { @MainActor in onCancel() }
        }
    }
}
