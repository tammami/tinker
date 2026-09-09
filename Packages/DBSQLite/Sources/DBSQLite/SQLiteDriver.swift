import DBCore
import Foundation
import Logging
import SQLite3

/// The SQLite driver, over the `libsqlite3` macOS ships.
///
/// A SQLite database is a file, so a connection has no host, port, user or password:
/// ``ConnectionConfig/database`` carries the file's path and everything else is empty.
/// There is no server process either, which shapes the rest of the driver: no TLS, no
/// SSH, no sessions to list, no users to manage, and "cancel" is `sqlite3_interrupt`
/// on the same handle rather than a message to another backend.
public enum SQLiteDriver: SQLDriver {
    public static var dialect: SQLDialect { .sqlite }
    public static var displayName: String { "SQLite" }
    /// There is no port. The value exists because the protocol asks for one.
    public static var defaultPort: Int { 0 }

    /// File extensions a SQLite database is usually found under. The header check in
    /// ``isDatabaseFile(at:)`` is what actually decides; the list is for open panels and
    /// drop targets.
    public static let fileExtensions: [String] = ["sqlite", "sqlite3", "db", "db3", "s3db", "sl3"]

    /// The 16 bytes every non-empty SQLite 3 database file starts with.
    static let magicHeader = Data("SQLite format 3\0".utf8)

    /// Keys for ``ConnectionConfig/options`` that only this driver reads.
    public enum OptionKey {
        /// Create the file when it does not exist, instead of failing. Default off, so a
        /// mistyped path is reported rather than silently becoming an empty database.
        public static let createIfMissing = "sqliteCreateIfMissing"
        /// `PRAGMA foreign_keys`. Default on: SQLite ships with enforcement off for
        /// backwards compatibility, and a client that lets a delete orphan rows by default
        /// is not the client this app wants to be.
        public static let foreignKeys = "sqliteForeignKeys"
    }

    public static func connect(
        _ config: ResolvedConnectionConfig,
        logger: Logger
    ) async throws -> any SQLConnection {
        let path = expandedPath(config.database)
        guard !path.isEmpty else {
            throw DBError.connectionFailed(
                underlying: "No database file was given",
                hint: "Choose the .sqlite or .db file to open")
        }
        let createIfMissing = config.options[OptionKey.createIfMissing] == "true"
        let exists = FileManager.default.fileExists(atPath: path)
        if !exists, !createIfMissing {
            throw DBError.connectionFailed(
                underlying: "No such file: \(path)",
                hint: "Choose an existing SQLite database, or turn on “Create the file if it does not exist”")
        }
        if exists, !isDatabaseFile(at: path) {
            throw DBError.connectionFailed(
                underlying: "\(path) is not a SQLite database",
                hint: "The file does not start with the SQLite 3 header")
        }
        return try await SQLiteConnection.open(path: path, config: config, createIfMissing: createIfMissing, logger: logger)
    }

    /// Resolves `~` and relative segments; SQLite itself takes the path verbatim.
    static func expandedPath(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return "" }
        return (path as NSString).expandingTildeInPath
    }

    /// True when the file at `path` is a SQLite 3 database: it starts with the SQLite
    /// header, or it is empty, which SQLite treats as a database with no tables yet.
    public static func isDatabaseFile(at path: String) -> Bool {
        let expanded = expandedPath(path)
        guard let handle = FileHandle(forReadingAtPath: expanded) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: magicHeader.count) else { return false }
        return head.isEmpty || head == magicHeader
    }

    /// Creates an empty database at `path`, failing if a file is already there. The file
    /// is written through SQLite so it carries the proper header from the start.
    public static func createDatabase(at path: String) throws {
        let expanded = expandedPath(path)
        guard !FileManager.default.fileExists(atPath: expanded) else {
            throw DBError.connectionFailed(
                underlying: "\(expanded) already exists", hint: "Choose a name that is not in use")
        }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let code = sqlite3_open_v2(expanded, &handle, flags, nil)
        defer { sqlite3_close_v2(handle) }
        guard code == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite error \(code)"
            throw DBError.connectionFailed(underlying: message, hint: nil)
        }
        // An open with no statement writes nothing; a `user_version` write forces the
        // header onto disk so the file is recognisably a database from now on.
        guard sqlite3_exec(handle, "PRAGMA user_version = 0", nil, nil, nil) == SQLITE_OK else {
            throw DBError.connectionFailed(
                underlying: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot write \(expanded)", hint: nil)
        }
    }

    /// The connection a database file opens as: named after the file, with the path as
    /// its database and every server-only field empty. Used by the connection editor,
    /// by files dropped on the app, and by `dbcli`.
    public static func connectionConfig(forFileAt path: String, id: UUID = UUID()) -> ConnectionConfig {
        let expanded = expandedPath(path)
        let url = URL(fileURLWithPath: expanded)
        var config = ConnectionConfig(
            id: id,
            name: url.deletingPathExtension().lastPathComponent,
            dialect: .sqlite,
            host: "",
            port: 0,
            user: "",
            database: expanded,
            tls: TLSConfig(mode: .disable)
        )
        config.options[OptionKey.foreignKeys] = "true"
        return config
    }
}

/// Translates SQLite result codes into ``DBError`` without rewriting SQLite's words.
enum SQLiteErrorMapper {
    /// `timedOut` is the statement timeout when it, rather than a cancel, interrupted
    /// the statement. `sql` turns SQLite's byte offset into the character position the
    /// editor highlights.
    static func map(code: Int32, message: String, offset: Int32, sql: String?, timedOut: Duration?) -> DBError {
        let primary = code & 0xFF
        if primary == SQLITE_INTERRUPT {
            if let timedOut { return .timeout(after: timedOut) }
            return .cancelled
        }
        if primary == SQLITE_MISUSE {
            return .protocolError(message)
        }
        return .server(
            ServerError(sqlState: nil, code: Int(code), message: message, position: position(ofByte: offset, in: sql)))
    }

    /// SQLite reports where a syntax error is as a UTF-8 byte offset, or -1 when it has
    /// none; the editor wants a one-based character position.
    static func position(ofByte offset: Int32, in sql: String?) -> Int? {
        guard offset >= 0, let sql else { return nil }
        let bytes = sql.utf8
        guard let index = bytes.index(bytes.startIndex, offsetBy: Int(offset), limitedBy: bytes.endIndex) else {
            return nil
        }
        return sql.distance(from: sql.startIndex, to: index) + 1
    }
}
