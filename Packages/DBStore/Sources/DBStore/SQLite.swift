import Foundation
import SQLite3

/// Errors from the local store. These are Tinker's own storage failing, never a user's
/// database, so they are kept separate from `DBError`.
public enum StoreError: Error, CustomStringConvertible {
    case openFailed(path: String, message: String)
    case sqlite(code: Int32, message: String, sql: String?)
    case migrationFailed(version: Int, message: String)
    case decodingFailed(String)

    public var description: String {
        switch self {
        case let .openFailed(path, message): "Cannot open \(path): \(message)"
        case let .sqlite(code, message, sql):
            sql.map { "SQLite error \(code): \(message) — while running: \($0)" } ?? "SQLite error \(code): \(message)"
        case let .migrationFailed(version, message): "Migration \(version) failed: \(message)"
        case let .decodingFailed(message): "Cannot decode stored value: \(message)"
        }
    }
}

/// A value bound into, or read out of, a local-store statement.
public enum SQLiteValue: Sendable, Hashable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    public var intValue: Int64? { if case let .integer(value) = self { value } else { nil } }
    public var textValue: String? { if case let .text(value) = self { value } else { nil } }
    public var dataValue: Data? { if case let .blob(value) = self { value } else { nil } }
    public var doubleValue: Double? {
        switch self {
        case let .real(value): value
        case let .integer(value): Double(value)
        default: nil
        }
    }
}

/// A row from the local store, addressable by column name.
public struct SQLiteRow: Sendable {
    public let columns: [String]
    public let values: [SQLiteValue]

    public subscript(name: String) -> SQLiteValue {
        guard let index = columns.firstIndex(of: name) else { return .null }
        return values[index]
    }

    public subscript(index: Int) -> SQLiteValue {
        index < values.count ? values[index] : .null
    }
}

/// A minimal typed layer over the SQLite3 C API.
///
/// No ORM, as SPEC §15 requires. All access is serialised on this actor, and every
/// statement is prepared with bound parameters.
public actor SQLiteDatabase {
    private var handle: OpaquePointer?
    public nonisolated let path: String

    /// SQLite copies bound text and blobs when told the destructor is `SQLITE_TRANSIENT`.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Opens, or creates, the database at `path` in WAL mode.
    public init(path: String) throws {
        self.path = path
        if path != ":memory:" {
            let directory = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(path, &handle, flags, nil)
        guard result == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close_v2(handle)
            throw StoreError.openFailed(path: path, message: message)
        }
        self.handle = handle
        // WAL keeps readers from blocking the writer, and a busy timeout stops a second
        // window's write from failing outright.
        sqlite3_busy_timeout(handle, 5_000)
        _ = try? Self.executeRaw("PRAGMA journal_mode = WAL", on: handle)
        _ = try? Self.executeRaw("PRAGMA foreign_keys = ON", on: handle)
        _ = try? Self.executeRaw("PRAGMA synchronous = NORMAL", on: handle)
    }

    /// The handle is closed by ``close()``. There is no `deinit` cleanup because a
    /// nonisolated `deinit` cannot touch actor state under strict concurrency; callers
    /// close the store when they are done with it, and the process exiting closes it too.
    public func close() {
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    private func requireHandle() throws -> OpaquePointer {
        guard let handle else {
            throw StoreError.sqlite(code: SQLITE_MISUSE, message: "The store is closed", sql: nil)
        }
        return handle
    }

    /// Runs a statement that returns no rows.
    @discardableResult
    public func execute(_ sql: String, _ parameters: [SQLiteValue] = []) throws -> Int {
        _ = try query(sql, parameters)
        return Int(sqlite3_changes(try requireHandle()))
    }

    /// Runs a statement and collects its rows.
    @discardableResult
    public func query(_ sql: String, _ parameters: [SQLiteValue] = []) throws -> [SQLiteRow] {
        let handle = try requireHandle()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError.sqlite(
                code: sqlite3_errcode(handle), message: String(cString: sqlite3_errmsg(handle)), sql: sql
            )
        }
        defer { sqlite3_finalize(statement) }

        for (offset, value) in parameters.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32 =
                switch value {
                case .null:
                    sqlite3_bind_null(statement, index)
                case let .integer(number):
                    sqlite3_bind_int64(statement, index, number)
                case let .real(number):
                    sqlite3_bind_double(statement, index, number)
                case let .text(text):
                    sqlite3_bind_text(statement, index, text, -1, Self.transient)
                case let .blob(data):
                    data.withUnsafeBytes { buffer in
                        sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), Self.transient)
                    }
                }
            guard code == SQLITE_OK else {
                throw StoreError.sqlite(
                    code: code, message: String(cString: sqlite3_errmsg(handle)), sql: sql
                )
            }
        }

        let columnCount = Int(sqlite3_column_count(statement))
        let columns = (0 ..< columnCount).map { index in
            sqlite3_column_name(statement, Int32(index)).map { String(cString: $0) } ?? "\(index)"
        }

        var rows: [SQLiteRow] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw StoreError.sqlite(
                    code: step, message: String(cString: sqlite3_errmsg(handle)), sql: sql
                )
            }
            var values: [SQLiteValue] = []
            values.reserveCapacity(columnCount)
            for index in 0 ..< Int32(columnCount) {
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER:
                    values.append(.integer(sqlite3_column_int64(statement, index)))
                case SQLITE_FLOAT:
                    values.append(.real(sqlite3_column_double(statement, index)))
                case SQLITE_TEXT:
                    values.append(.text(String(cString: sqlite3_column_text(statement, index))))
                case SQLITE_BLOB:
                    let bytes = sqlite3_column_bytes(statement, index)
                    if let pointer = sqlite3_column_blob(statement, index), bytes > 0 {
                        values.append(.blob(Data(bytes: pointer, count: Int(bytes))))
                    } else {
                        values.append(.blob(Data()))
                    }
                default:
                    values.append(.null)
                }
            }
            rows.append(SQLiteRow(columns: columns, values: values))
        }
        return rows
    }

    /// Runs `body` inside a transaction, rolling back on any error.
    public func withTransaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            _ = try? execute("ROLLBACK")
            throw error
        }
    }

    /// Runs several statements in one transaction. Used by migrations, where the whole
    /// step must apply or none of it.
    public func executeBatch(_ statements: [String]) throws {
        try withTransaction {
            for statement in statements {
                try self.executeIsolated(statement)
            }
        }
    }

    /// The actor-isolated form of ``execute(_:_:)``, callable from inside a transaction body.
    private func executeIsolated(_ sql: String) throws {
        _ = try query(sql, [])
    }

    public var userVersion: Int {
        get throws {
            let rows = try query("PRAGMA user_version")
            return Int(rows.first?[0].intValue ?? 0)
        }
    }

    public func setUserVersion(_ version: Int) throws {
        // PRAGMA does not accept a bound parameter, and `version` is an Int the store
        // itself supplies, never user input.
        try execute("PRAGMA user_version = \(version)")
    }

    public var lastInsertRowID: Int64 {
        (try? requireHandle()).map(sqlite3_last_insert_rowid) ?? 0
    }

    private static func executeRaw(_ sql: String, on handle: OpaquePointer) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(error)
            throw StoreError.sqlite(code: sqlite3_errcode(handle), message: message, sql: sql)
        }
    }
}
