import DBCore
import DBSQL
import Foundation
import Logging
import SQLite3

/// The `sqlite3*` handle and the little state that has to be reachable from any thread:
/// the interrupt, and the deadline the progress handler checks.
final class SQLiteHandle: @unchecked Sendable {
    let pointer: OpaquePointer
    private let lock = NSLock()
    private var deadline: ContinuousClock.Instant?
    private var timeout: Duration?
    private(set) var timedOut = false
    private var isClosed = false

    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    /// Asks SQLite to stop whatever this handle is running. Safe from any thread, and a
    /// no-op once the handle is closed or when nothing is running.
    func interrupt() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        sqlite3_interrupt(pointer)
    }

    func beginStatement(timeout: Duration?) {
        lock.lock()
        self.timeout = timeout
        deadline = timeout.map { ContinuousClock.now + $0 }
        timedOut = false
        lock.unlock()
    }

    func endStatement() {
        lock.lock()
        deadline = nil
        lock.unlock()
    }

    /// The timeout that stopped the last statement, if one did.
    var expiredTimeout: Duration? {
        lock.lock()
        defer { lock.unlock() }
        return timedOut ? timeout : nil
    }

    /// Called by SQLite every few hundred virtual-machine steps while a statement runs.
    /// Returning true aborts the statement with `SQLITE_INTERRUPT`.
    fileprivate func shouldAbort() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let deadline, ContinuousClock.now >= deadline else { return false }
        timedOut = true
        return true
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        sqlite3_progress_handler(pointer, 0, nil, nil)
        sqlite3_close_v2(pointer)
    }

    var closed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isClosed
    }
}

/// One open SQLite database file.
///
/// The actor runs on its own thread (``SQLiteExecutor``), so SQLite's blocking calls
/// never hold a cooperative-pool thread, and every call on the handle happens on one
/// thread, which is what SQLite asks of a connection. `sqlite3_interrupt` is the one
/// call SQLite allows from elsewhere, and ``cancelCurrent()`` is how it is used.
public actor SQLiteConnection: SQLConnection {
    private nonisolated let executor: SQLiteExecutor
    public nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }

    nonisolated let handle: SQLiteHandle
    nonisolated let config: ResolvedConnectionConfig
    nonisolated let logger: Logger
    /// The database file, as opened.
    public nonisolated let path: String

    public nonisolated let backendID: String
    public nonisolated let serverVersion: ServerVersion
    /// A file opened in-process has no wire at all.
    public nonisolated let transport: TransportInfo = .localFile

    /// True when a `PRAGMA` ran on this connection, so the next reset puts the settings
    /// the connection was opened with back.
    private var sessionMutated = false
    private var closed = false

    private static let ordinal = OrdinalCounter()

    /// Opens `path`, creating it when asked to, and applies the connection's settings.
    static func open(
        path: String, config: ResolvedConnectionConfig, createIfMissing: Bool, logger: Logger
    ) async throws -> SQLiteConnection {
        var pointer: OpaquePointer?
        var flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        if createIfMissing { flags |= SQLITE_OPEN_CREATE }
        let code = sqlite3_open_v2(path, &pointer, flags, nil)
        guard code == SQLITE_OK, let pointer else {
            let message = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite error \(code)"
            sqlite3_close_v2(pointer)
            throw Self.openError(code: code, message: message, path: path)
        }
        sqlite3_extended_result_codes(pointer, 1)
        // Another process may hold the file; wait a little rather than failing at once.
        sqlite3_busy_timeout(pointer, 5_000)
        let connection = SQLiteConnection(pointer: pointer, path: path, config: config, logger: logger)
        do {
            try await connection.applyInitialSettings()
        } catch {
            await connection.close()
            throw error
        }
        return connection
    }

    private init(pointer: OpaquePointer, path: String, config: ResolvedConnectionConfig, logger: Logger) {
        self.handle = SQLiteHandle(pointer: pointer)
        self.path = path
        self.config = config
        self.logger = logger
        self.executor = SQLiteExecutor(name: "Tinker SQLite \(URL(fileURLWithPath: path).lastPathComponent)")
        self.backendID = String(Self.ordinal.next())
        let version = String(cString: sqlite3_libversion())
        let numbers = ServerVersion.parseNumbers(version)
        self.serverVersion = ServerVersion(
            major: numbers.major, minor: numbers.minor, patch: numbers.patch,
            flavor: .sqlite, rawString: "SQLite \(version)"
        )
        // The progress handler is what enforces the statement timeout; it reads the
        // deadline from the handle, which outlives every statement.
        sqlite3_progress_handler(
            pointer, 500,
            { context in
                guard let context else { return 0 }
                return Unmanaged<SQLiteHandle>.fromOpaque(context).takeUnretainedValue().shouldAbort() ? 1 : 0
            },
            Unmanaged.passUnretained(handle).toOpaque()
        )
    }

    deinit {
        handle.close()
    }

    static func openError(code: Int32, message: String, path: String) -> DBError {
        switch code & 0xFF {
        case SQLITE_NOTADB:
            return .connectionFailed(underlying: message, hint: "\(path) is not a SQLite database")
        case SQLITE_CANTOPEN:
            return .connectionFailed(underlying: message, hint: "Check that \(path) exists and is readable")
        case SQLITE_PERM, SQLITE_READONLY:
            return .connectionFailed(underlying: message, hint: "Check the file's permissions")
        default:
            return .connectionFailed(underlying: message, hint: nil)
        }
    }

    /// Settings every connection starts with: foreign-key enforcement as configured, and
    /// `lower()`/`upper()` that know more than ASCII.
    private func applyInitialSettings() throws {
        try runIsolated(Self.foreignKeysPragma(config))
        try registerCaseFunctions()
    }

    /// SQLite's own `lower()` and `upper()` fold ASCII only unless it was built with ICU,
    /// and Apple's is not: `lower('Ö')` is `Ö`. Overriding the two built-ins on this
    /// connection is what the ICU extension itself does, and it is what lets the grid's
    /// quick search find `wörld` when asked for `ÖRL`.
    private func registerCaseFunctions() throws {
        let flags = SQLITE_UTF8 | SQLITE_DETERMINISTIC
        let lower = sqlite3_create_function_v2(
            handle.pointer, "lower", 1, flags, nil,
            { context, count, values in
                SQLiteConnection.foldCase(context: context, count: count, values: values, upper: false)
            }, nil, nil, nil)
        let upper = sqlite3_create_function_v2(
            handle.pointer, "upper", 1, flags, nil,
            { context, count, values in
                SQLiteConnection.foldCase(context: context, count: count, values: values, upper: true)
            }, nil, nil, nil)
        guard lower == SQLITE_OK, upper == SQLITE_OK else { throw currentError(sql: nil) }
    }

    private static func foldCase(
        context: OpaquePointer?, count: Int32, values: UnsafeMutablePointer<OpaquePointer?>?, upper: Bool
    ) {
        guard count == 1, let value = values?[0] else {
            sqlite3_result_null(context)
            return
        }
        guard sqlite3_value_type(value) != SQLITE_NULL, let text = sqlite3_value_text(value) else {
            sqlite3_result_null(context)
            return
        }
        let folded = upper ? String(cString: text).uppercased() : String(cString: text).lowercased()
        var copy = folded
        copy.withUTF8 { buffer in
            sqlite3_result_text64(
                context, buffer.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) },
                sqlite3_uint64(buffer.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self), UInt8(SQLITE_UTF8))
        }
    }

    private static func foreignKeysPragma(_ config: ResolvedConnectionConfig) -> String {
        let enabled = config.options[SQLiteDriver.OptionKey.foreignKeys] != "false"
        return "PRAGMA foreign_keys = \(enabled ? "ON" : "OFF")"
    }

    // MARK: - SQLConnection

    public nonisolated var introspector: any SchemaIntrospector { SQLiteIntrospector(connection: self) }

    public nonisolated func execute(
        _ sql: String,
        parameters: [DBValue]
    ) -> AsyncThrowingStream<QueryEvent, any Error> {
        AsyncThrowingStream { continuation in
            // Unstructured on purpose: cancelling the consumer interrupts the statement
            // through the handle, which leaves the connection usable (SPEC §13.3).
            let task = Task { await self.run(sql: sql, parameters: parameters, into: continuation) }
            continuation.onTermination = { [handle] termination in
                guard case .cancelled = termination else { return }
                handle.interrupt()
                task.cancel()
            }
        }
    }

    private func run(
        sql: String,
        parameters: [DBValue],
        into continuation: AsyncThrowingStream<QueryEvent, any Error>.Continuation
    ) {
        let started = ContinuousClock.now
        guard !closed else {
            continuation.finish(throwing: DBError.notConnected)
            return
        }
        handle.beginStatement(timeout: config.statementTimeout)
        defer { handle.endStatement() }

        do {
            let outcome = try runStatements(sql, parameters: parameters, continuation: continuation)
            let keyword = SQLStatement(text: sql, utf16Range: 0 ..< 0, startLine: 1, terminator: nil).leadingKeyword
            if keyword == "PRAGMA" || keyword == "ATTACH" || keyword == "DETACH" { sessionMutated = true }
            continuation.yield(
                .complete(
                    QueryCompletion(
                        affectedRows: outcome.rowCount > 0 ? Int64(outcome.rowCount) : outcome.changes,
                        lastInsertID: keyword == "INSERT" || keyword == "REPLACE" ? outcome.lastInsertID : nil,
                        serverTag: Self.tag(keyword: keyword, rowCount: outcome.rowCount, changes: outcome.changes),
                        durationTotal: started.duration(to: .now)
                    )))
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    private struct Outcome {
        var rowCount = 0
        var changes: Int64?
        var lastInsertID: Int64?
        var emittedColumns = false
    }

    /// Prepares and steps every statement in `sql`. Drivers are handed one statement at a
    /// time, but a `CREATE TRIGGER` body or a pasted pair still has to run whole; rows
    /// come from the first statement that produces any, later ones only count changes.
    private func runStatements(
        _ sql: String, parameters: [DBValue],
        continuation: AsyncThrowingStream<QueryEvent, any Error>.Continuation
    ) throws -> Outcome {
        var outcome = Outcome()
        var remaining = Substring(sql)
        var isFirst = true
        while !remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let text = String(remaining)
            let pointer = handle.pointer
            let (code, statement, tailOffset) = text.withCString { base -> (Int32, OpaquePointer?, Int) in
                var prepared: OpaquePointer?
                var tail: UnsafePointer<CChar>?
                let result = sqlite3_prepare_v3(pointer, base, -1, 0, &prepared, &tail)
                return (result, prepared, tail.map { Int($0 - base) } ?? text.utf8.count)
            }
            guard code == SQLITE_OK else {
                throw currentError(sql: text)
            }
            remaining = Substring(String(decoding: Array(text.utf8)[tailOffset...], as: UTF8.self))
            guard let statement else { continue }  // Only whitespace or a comment.
            defer { sqlite3_finalize(statement) }

            if isFirst {
                try bind(parameters, to: statement, sql: text)
            } else if sqlite3_bind_parameter_count(statement) > 0 {
                throw DBError.protocolError("Only the first statement of a batch can take parameters")
            }
            isFirst = false

            let columnCount = sqlite3_column_count(statement)
            if columnCount > 0, !outcome.emittedColumns {
                outcome.rowCount = try stream(statement, columnCount: columnCount, continuation: continuation, sql: text)
                outcome.emittedColumns = true
            } else {
                try stepToEnd(statement, sql: text)
            }
            // `sqlite3_changes` counts the rows this statement changed directly — not the
            // rows its triggers or `ON DELETE CASCADE` touched, which `sqlite3_total_changes`
            // would add and which made the grid refuse a correct one-row edit as "touched
            // 4 rows". It is only read after a row write, so a CREATE cannot inherit the
            // previous INSERT's count (DECISIONS.md ADR-0040).
            if !sqlite3_stmt_readonly(statement).isTruthy, Self.isRowWrite(text) {
                outcome.changes = (outcome.changes ?? 0) + sqlite3_changes64(handle.pointer)
                outcome.lastInsertID = sqlite3_last_insert_rowid(handle.pointer)
            }
        }
        if !outcome.emittedColumns { continuation.yield(.columns([])) }
        return outcome
    }

    /// Steps a statement that returns rows, yielding its columns and then batches of rows.
    private func stream(
        _ statement: OpaquePointer, columnCount: Int32,
        continuation: AsyncThrowingStream<QueryEvent, any Error>.Continuation, sql: String
    ) throws -> Int {
        // The first row is read before the columns are described: a column without a
        // declared type — an expression — is typed by what its first value is.
        var step = sqlite3_step(statement)
        let (columns, declared) = describeColumns(statement, count: columnCount, firstRowAvailable: step == SQLITE_ROW)
        continuation.yield(.columns(columns))

        var rows: [[DBValue]] = []
        var bytes = 0
        var delivered = 0
        func flush() {
            guard !rows.isEmpty else { return }
            continuation.yield(.rows(RowBatch(rows: rows, startIndex: delivered)))
            delivered += rows.count
            rows.removeAll(keepingCapacity: true)
            bytes = 0
        }
        while step == SQLITE_ROW {
            var row: [DBValue] = []
            row.reserveCapacity(Int(columnCount))
            for index in 0 ..< columnCount {
                let value = SQLiteValueCodec.value(of: statement, column: index, declared: declared[Int(index)])
                switch value {
                case let .string(text), let .json(text), let .decimal(text): bytes += text.utf8.count
                case let .bytes(data): bytes += data.count
                default: bytes += 8
                }
                row.append(value)
            }
            rows.append(row)
            if rows.count >= RowBatching.maxRows || bytes >= RowBatching.maxBytes { flush() }
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw currentError(sql: sql) }
        flush()
        return delivered
    }

    private func stepToEnd(_ statement: OpaquePointer, sql: String) throws {
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW { step = sqlite3_step(statement) }
        guard step == SQLITE_DONE else { throw currentError(sql: sql) }
    }

    private func bind(_ parameters: [DBValue], to statement: OpaquePointer, sql: String) throws {
        let expected = Int(sqlite3_bind_parameter_count(statement))
        guard expected == parameters.count else {
            throw DBError.protocolError("The statement has \(expected) parameters but \(parameters.count) were given")
        }
        for (offset, value) in parameters.enumerated() {
            let code = SQLiteValueCodec.bind(value, to: statement, at: Int32(offset + 1))
            guard code == SQLITE_OK else { throw currentError(sql: sql) }
        }
    }

    /// The result set's columns, with the declared type of each for the codec.
    private func describeColumns(
        _ statement: OpaquePointer, count: Int32, firstRowAvailable: Bool
    ) -> ([ColumnMeta], [SQLiteValueCodec.DeclaredType]) {
        var columns: [ColumnMeta] = []
        var declaredTypes: [SQLiteValueCodec.DeclaredType] = []
        for index in 0 ..< count {
            let name = sqlite3_column_name(statement, index).map { String(cString: $0) } ?? "column\(index)"
            let declaredText = sqlite3_column_decltype(statement, index).map { String(cString: $0) }
            let declared = SQLiteValueCodec.DeclaredType(declaredText)
            declaredTypes.append(declared)

            var nativeTypeName = declaredText ?? ""
            var kind = declared.kind
            if declaredText == nil, firstRowAvailable,
                let storage = SQLiteValueCodec.storageClassName(of: statement, column: index)
            {
                nativeTypeName = storage
                kind = SQLiteValueCodec.value(of: statement, column: index, declared: .other).kind
            }

            let table = sqlite3_column_table_name(statement, index).map { String(cString: $0) }
            let origin = sqlite3_column_origin_name(statement, index).map { String(cString: $0) }
            let database = sqlite3_column_database_name(statement, index).map { String(cString: $0) }
            var isNullable: Bool?
            var isPrimaryKey: Bool?
            if let table, let origin {
                var notNull: Int32 = 0
                var primaryKey: Int32 = 0
                var autoIncrement: Int32 = 0
                if sqlite3_table_column_metadata(
                    handle.pointer, database, table, origin, nil, nil, &notNull, &primaryKey, &autoIncrement
                ) == SQLITE_OK {
                    isNullable = notNull == 0
                    isPrimaryKey = primaryKey != 0
                }
            }
            columns.append(
                ColumnMeta(
                    id: Int(index),
                    name: name,
                    tableOID: table.map { "\(database ?? SchemaRef.sqliteMainSchema).\($0)" },
                    nativeTypeName: nativeTypeName,
                    kind: kind,
                    isNullable: isNullable,
                    isPrimaryKey: isPrimaryKey
                ))
        }
        return (columns, declaredTypes)
    }

    /// The error SQLite has for the last failed call, in its own words.
    private func currentError(sql: String?) -> DBError {
        let code = sqlite3_extended_errcode(handle.pointer)
        let message = String(cString: sqlite3_errmsg(handle.pointer))
        let offset = sqlite3_error_offset(handle.pointer)
        return SQLiteErrorMapper.map(
            code: code, message: message, offset: offset, sql: sql, timedOut: handle.expiredTimeout)
    }

    /// True for a statement whose changed-row count means something: INSERT, UPDATE,
    /// DELETE, REPLACE, or a WITH that leads to one of them.
    static func isRowWrite(_ sql: String) -> Bool {
        let statement = SQLStatement(text: sql, utf16Range: 0 ..< 0, startLine: 1, terminator: nil)
        switch statement.leadingKeyword {
        case "INSERT", "UPDATE", "DELETE", "REPLACE": return true
        case "WITH": return !statement.isProbablyReadOnly
        default: return false
        }
    }

    /// A PostgreSQL-style command tag, so the UI reports every engine the same way.
    static func tag(keyword: String, rowCount: Int, changes: Int64?) -> String {
        let verb = keyword.isEmpty ? "OK" : keyword
        if rowCount > 0 || ["SELECT", "WITH", "VALUES", "PRAGMA", "EXPLAIN"].contains(verb) {
            return "\(verb) \(rowCount)"
        }
        if let changes { return "\(verb) \(changes)" }
        return verb
    }

    /// Runs a statement on the actor's thread and discards its rows.
    private func runIsolated(_ sql: String) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v3(handle.pointer, sql, -1, 0, &statement, nil) == SQLITE_OK else {
            throw currentError(sql: sql)
        }
        defer { sqlite3_finalize(statement) }
        guard let statement else { return }
        try stepToEnd(statement, sql: sql)
    }

    /// `sqlite3_interrupt`, which makes the running `sqlite3_step` return
    /// `SQLITE_INTERRUPT`. Nonisolated: waiting for the actor would mean waiting for the
    /// very statement being cancelled.
    public nonisolated func cancelCurrent() async {
        handle.interrupt()
    }

    public func beginTransaction() async throws {
        try runIsolated("BEGIN")
    }

    public func commit() async throws {
        try runIsolated("COMMIT")
    }

    public func rollback() async throws {
        try runIsolated("ROLLBACK")
    }

    /// Read from SQLite itself, so a `BEGIN` the user typed counts too.
    public var isInTransaction: Bool {
        !closed && sqlite3_get_autocommit(handle.pointer) == 0
    }

    public func ping() async throws {
        try runIsolated("SELECT 1")
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        handle.close()
    }

    /// Puts the pragmas the connection was opened with back, when a statement may have
    /// changed them. `query_only` belongs to the session's read-only guard, which
    /// re-applies it on every lease.
    public func resetSessionState() async throws {
        guard sessionMutated, !closed else { return }
        sessionMutated = false
        try runIsolated(Self.foreignKeysPragma(config))
    }

    /// SQLite has no bulk-load stream; dumps carry `INSERT`s, which is what the importer
    /// falls back to.
    public func copyIn(
        into table: TableRef, columns: [String], body: @Sendable (any BulkLoadWriter) async throws -> Void
    ) async throws {
        throw DBError.protocolError("SQLite has no COPY FROM STDIN; rows are loaded with INSERT statements")
    }

    /// Runs a statement and collects it, for the introspector.
    func query(_ sql: String, _ parameters: [DBValue] = []) async throws -> QueryResult {
        try await executeCollecting(sql, parameters: parameters)
    }
}

/// Numbers connections within the process, for ``SQLConnection/backendID``.
final class OrdinalCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

extension Int32 {
    fileprivate var isTruthy: Bool { self != 0 }
}
