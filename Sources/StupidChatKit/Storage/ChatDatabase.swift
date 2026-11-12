import Foundation
import SQLite3

/// A thin wrapper over one SQLite connection. Not thread-safe: `ChatStore` serializes every use.
final class ChatDatabase {
    enum Value {
        case int(Int64)
        case double(Double)
        case text(String)
        case blob(Data)
        case null
    }

    struct Failure: Error, CustomStringConvertible {
        let code: Int32
        let message: String
        var description: String {
            "SQLite \(code): \(message)"
        }
    }

    private var handle: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let code = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard code == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw Failure(code: code, message: message)
        }
        sqlite3_busy_timeout(handle, 5000)
    }

    deinit {
        for statement in statements.values {
            sqlite3_finalize(statement)
        }
        sqlite3_close(handle)
    }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(handle, sql, nil, nil, &error)
        if code != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(error)
            throw Failure(code: code, message: message)
        }
    }

    func run(_ sql: String, _ values: [Value] = []) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_reset(statement) }
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE || code == SQLITE_ROW else { throw failure(code) }
    }

    func query(_ sql: String, _ values: [Value] = [], row: (Row) throws -> Void) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_reset(statement) }
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return }
            guard code == SQLITE_ROW else { throw failure(code) }
            try row(Row(statement: statement))
        }
    }

    func rows<T>(_ sql: String, _ values: [Value] = [], map: (Row) throws -> T) throws -> [T] {
        var result: [T] = []
        try query(sql, values) { try result.append(map($0)) }
        return result
    }

    func first<T>(_ sql: String, _ values: [Value] = [], map: (Row) throws -> T) throws -> T? {
        var result: T?
        try query(sql, values) { row in
            if result == nil {
                result = try map(row)
            }
        }
        return result
    }

    var lastInsertId: Int64 {
        sqlite3_last_insert_rowid(handle)
    }

    var changes: Int {
        Int(sqlite3_changes(handle))
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String, _ values: [Value]) throws -> OpaquePointer {
        let statement: OpaquePointer
        if let cached = statements[sql] {
            statement = cached
        } else {
            var prepared: OpaquePointer?
            let code = sqlite3_prepare_v2(handle, sql, -1, &prepared, nil)
            guard code == SQLITE_OK, let prepared else { throw failure(code) }
            statements[sql] = prepared
            statement = prepared
        }
        sqlite3_clear_bindings(statement)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case let .int(int): sqlite3_bind_int64(statement, index, int)
            case let .double(double): sqlite3_bind_double(statement, index, double)
            case let .text(text): sqlite3_bind_text(statement, index, text, -1, Self.transient)
            case let .blob(data):
                _ = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), Self.transient)
                }
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }

    private func failure(_ code: Int32) -> Failure {
        Failure(code: code, message: String(cString: sqlite3_errmsg(handle)))
    }

    struct Row {
        let statement: OpaquePointer

        func int(_ column: Int32) -> Int64 {
            sqlite3_column_int64(statement, column)
        }

        func double(_ column: Int32) -> Double {
            sqlite3_column_double(statement, column)
        }

        func isNull(_ column: Int32) -> Bool {
            sqlite3_column_type(statement, column) == SQLITE_NULL
        }

        func text(_ column: Int32) -> String? {
            guard let pointer = sqlite3_column_text(statement, column) else { return nil }
            return String(cString: pointer)
        }

        func blob(_ column: Int32) -> Data? {
            guard !isNull(column) else { return nil }
            let count = Int(sqlite3_column_bytes(statement, column))
            guard count > 0, let pointer = sqlite3_column_blob(statement, column) else { return Data() }
            return Data(bytes: pointer, count: count)
        }
    }
}

extension ChatDatabase.Value {
    static func optional(_ text: String?) -> Self {
        text.map { .text($0) } ?? .null
    }

    static func bool(_ value: Bool) -> Self {
        .int(value ? 1 : 0)
    }
}
