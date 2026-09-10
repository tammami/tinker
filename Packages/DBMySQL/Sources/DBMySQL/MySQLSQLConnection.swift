import DBCore
import DBSQL
import Foundation
import Logging
import MySQLNIO
import NIOConcurrencyHelpers
import NIOCore

/// One physical MySQL connection.
public actor MySQLSQLConnection: SQLConnection {
    nonisolated let underlying: MySQLConnection
    nonisolated let config: ResolvedConnectionConfig
    nonisolated let logger: Logger
    nonisolated let decoder: MySQLValueDecoder

    public nonisolated let backendID: String
    public nonisolated let serverVersion: ServerVersion
    public nonisolated let introspector: any SchemaIntrospector
    public nonisolated let transport: TransportInfo

    private var transactionOpen = false
    private var closed = false
    /// Set when a statement changed session state (`USE`, `SET`), so the reset on release
    /// only pays its round trip when there is something to put back.
    private var sessionMutated = false
    /// Kept open so a cancel does not have to wait for a fresh handshake (SPEC §7.3).
    private var killConnection: MySQLConnection?

    init(underlying: MySQLConnection, config: ResolvedConnectionConfig, logger: Logger) async throws {
        self.underlying = underlying
        self.config = config
        self.logger = logger

        // One round trip for identity and session settings.
        let probe = try await Self.rawQuery(
            "SELECT VERSION(), CONNECTION_ID(), @@session.time_zone, @@session.sql_mode",
            on: underlying, logger: logger, decoder: MySQLValueDecoder()
        )
        guard let row = probe.rows.first, row.count >= 3 else {
            throw DBError.protocolError("The server did not answer the connection probe")
        }
        let versionText = row[0].text ?? ""
        backendID = row[1].text ?? "0"
        let timeZone = row[2].text ?? "SYSTEM"

        let numbers = ServerVersion.parseNumbers(versionText)
        serverVersion = ServerVersion(
            major: numbers.major, minor: numbers.minor, patch: numbers.patch,
            flavor: Self.flavor(from: versionText), rawString: versionText
        )
        // What the wire actually is. mysql-nio negotiates TLS only when the server greeting
        // offers it, and otherwise carries on in the clear; a mode that requires TLS must
        // not be satisfied by that (an on-path attacker can strip the capability bit).
        let transport = try await Self.readTransport(on: underlying, logger: logger)
        if config.tls.mode.requiresTLS, !transport.isEncrypted {
            throw DBError.connectionFailed(
                underlying:
                    "TLS mode '\(config.tls.mode.rawValue)' requires an encrypted connection, but the server "
                    + "connection to \(config.host):\(config.port) is not encrypted",
                hint:
                    "The server did not offer TLS. Enable it on the server, or lower the mode only if plaintext is acceptable"
            )
        }
        self.transport = transport

        let tinyint1IsBool = config.options[ConnectionConfig.OptionKey.tinyint1IsBool] != "false"
        decoder = MySQLValueDecoder(
            settings: MySQLSessionSettings(
                tinyint1IsBool: tinyint1IsBool, timeZoneName: timeZone
            ))
        introspector = MySQLIntrospector(
            connection: underlying, logger: logger, decoder: decoder,
            version: serverVersion, currentDatabase: config.database ?? ""
        )

        // Results always arrive as utf8mb4, whatever the server's default is (SPEC §7.3).
        _ = try? await Self.rawQuery(
            "SET character_set_results = utf8mb4", on: underlying, logger: logger, decoder: decoder
        )
        if let timeout = config.statementTimeout {
            let milliseconds =
                timeout.components.seconds * 1_000
                + Int64(timeout.components.attoseconds / 1_000_000_000_000_000)
            // MariaDB spells it differently, and neither server minds an unknown variable
            // being set in its own dialect's statement failing.
            _ = try? await Self.rawQuery(
                "SET SESSION max_execution_time = \(milliseconds)",
                on: underlying, logger: logger, decoder: decoder
            )
        }
    }

    /// The negotiated cipher and protocol, from the session's own status variables. An
    /// empty `Ssl_cipher` is what an unencrypted session reports.
    static func readTransport(on connection: MySQLConnection, logger: Logger) async throws -> TransportInfo {
        let status = try await rawQuery(
            "SHOW SESSION STATUS WHERE Variable_name IN ('Ssl_cipher', 'Ssl_version')",
            on: connection, logger: logger, decoder: MySQLValueDecoder()
        )
        var cipher: String?
        var version: String?
        for row in status.rows where row.count >= 2 {
            let value = row[1].text?.trimmingCharacters(in: .whitespaces) ?? ""
            switch row[0].text?.lowercased() {
            case "ssl_cipher": cipher = value.isEmpty ? nil : value
            case "ssl_version": version = value.isEmpty ? nil : value
            default: break
            }
        }
        return TransportInfo(isEncrypted: cipher != nil, protocolVersion: version, cipher: cipher)
    }

    /// Puts the session back the way the connection started: the configured database,
    /// the server's default SQL mode and checks, no profiling. Skipped when nothing ran
    /// that could have changed them.
    public func resetSessionState() async throws {
        guard sessionMutated, !closed else { return }
        sessionMutated = false
        if let database = config.database, !database.isEmpty {
            _ = try await Self.rawQuery(
                "USE \(Identifier.quote(database, dialect: .mysql))", on: underlying, logger: logger, decoder: decoder)
        }
        for statement in [
            "SET SESSION sql_mode = DEFAULT", "SET SESSION foreign_key_checks = 1", "SET SESSION autocommit = 1",
            "SET SESSION time_zone = DEFAULT", "SET SESSION profiling = 0",
        ] {
            // Not every server has every variable; the ones it has are what matter.
            _ = try? await Self.rawQuery(statement, on: underlying, logger: logger, decoder: decoder)
        }
    }

    static func flavor(from versionText: String) -> ServerFlavor {
        let lowered = versionText.lowercased()
        if lowered.contains("mariadb") { return .mariadb }
        if lowered.contains("percona") { return .percona }
        return .mysql
    }

    /// Runs a statement and collects it. For introspection and short probes.
    static func rawQuery(
        _ sql: String,
        parameters: [DBValue] = [],
        on connection: MySQLConnection,
        logger: Logger,
        decoder: MySQLValueDecoder
    ) async throws -> QueryResult {
        let collected = NIOLockedValueBox<(columns: [ColumnMeta], rows: [[DBValue]])>(([], []))
        let metadataBox = NIOLockedValueBox<MySQLQueryMetadata?>(nil)
        let started = ContinuousClock.now

        let collect: @Sendable (MySQLRow) -> Void = { row in
            collected.withLockedValue { state in
                if state.columns.isEmpty { state.columns = Self.columns(of: row, decoder: decoder) }
                state.rows.append(Self.values(of: row, decoder: decoder))
            }
        }
        do {
            try await connection.query(
                sql,
                MySQLParameterEncoder.bindings(for: parameters),
                onRow: collect,
                onMetadata: { metadata in metadataBox.withLockedValue { $0 = metadata } }
            ).get()
        } catch let error where isUnsupportedByPreparedProtocol(error) && parameters.isEmpty {
            // Some statements — SHOW GRANTS, ANALYZE, several administrative commands —
            // can only run over the text protocol. It reports no affected-row count, which
            // none of those statements has anyway. A statement with parameters cannot take
            // this path: the text protocol would run it with the placeholders unbound.
            collected.withLockedValue { $0 = ([], []) }
            try await connection.simpleQuery(sql, onRow: collect).get()
        }

        let state = collected.withLockedValue { $0 }
        let metadata = metadataBox.withLockedValue { $0 }
        return QueryResult(
            columns: state.columns,
            rows: state.rows,
            completion: QueryCompletion(
                affectedRows: metadata.flatMap { Int64(exactly: $0.affectedRows) } ?? Int64(state.rows.count),
                lastInsertID: metadata?.lastInsertID.flatMap { Int64(exactly: $0) },
                serverTag: Self.tag(sql: sql, metadata: metadata, rowCount: state.rows.count),
                durationTotal: started.duration(to: .now)
            )
        )
    }

    /// True for MySQL's "not supported in the prepared statement protocol yet" (1295),
    /// which several `SHOW` and administrative statements still raise.
    static func isUnsupportedByPreparedProtocol(_ error: any Error) -> Bool {
        guard let mysql = error as? MySQLError, case let .server(packet) = mysql else { return false }
        return packet.errorCode.rawValue == 1_295
    }

    /// A PostgreSQL-style command tag, so the UI can report both engines the same way.
    static func tag(sql: String, metadata: MySQLQueryMetadata?, rowCount: Int) -> String {
        let keyword = SQLStatement(
            text: sql, utf16Range: 0 ..< 0, startLine: 1, terminator: nil
        ).leadingKeyword
        guard let metadata else { return keyword.isEmpty ? "OK" : keyword }
        if keyword == "SELECT" || keyword == "SHOW" || keyword == "WITH" {
            return "\(keyword) \(rowCount)"
        }
        return "\(keyword.isEmpty ? "OK" : keyword) \(metadata.affectedRows)"
    }

    static func columns(of row: MySQLRow, decoder: MySQLValueDecoder) -> [ColumnMeta] {
        row.columnDefinitions.enumerated().map { index, column in
            ColumnMeta(
                id: index,
                name: column.name,
                tableOID: column.orgTable.isEmpty ? nil : "\(column.schema).\(column.orgTable)",
                sourceColumn: column.orgName.isEmpty ? nil : column.orgName,
                nativeTypeName: MySQLValueDecoder.typeName(column),
                kind: decoder.kind(for: column),
                isNullable: !column.flags.contains(.COLUMN_NOT_NULL),
                isPrimaryKey: column.flags.contains(.PRIMARY_KEY)
            )
        }
    }

    static func values(of row: MySQLRow, decoder: MySQLValueDecoder) -> [DBValue] {
        zip(row.columnDefinitions, row.values).map { column, buffer in
            guard let buffer else { return .null }
            let data = MySQLData(
                type: column.columnType,
                format: row.format,
                buffer: buffer,
                isUnsigned: column.flags.contains(.COLUMN_UNSIGNED)
            )
            return decoder.decode(data, column: column)
        }
    }

    // MARK: - SQLConnection

    /// MySQL has no server-side bulk-load stream a client can drive statement by
    /// statement; its dumps carry `INSERT`s, which is what the importer falls back to.
    public func copyIn(
        into table: TableRef, columns: [String], body: @Sendable (any BulkLoadWriter) async throws -> Void
    ) async throws {
        throw DBError.protocolError("MySQL has no COPY FROM STDIN; rows are loaded with INSERT statements")
    }

    public nonisolated func execute(
        _ sql: String,
        parameters: [DBValue]
    ) -> AsyncThrowingStream<QueryEvent, any Error> {
        AsyncThrowingStream { continuation in
            // Unstructured on purpose: cancelling the consumer reaches the server through
            // `KILL QUERY`, which leaves this connection usable (SPEC §13.3).
            let task = Task { await self.run(sql: sql, parameters: parameters, into: continuation) }
            continuation.onTermination = { termination in
                guard case .cancelled = termination else { return }
                Task {
                    await self.cancelCurrent()
                    task.cancel()
                }
            }
        }
    }

    private func run(
        sql: String,
        parameters: [DBValue],
        into continuation: AsyncThrowingStream<QueryEvent, any Error>.Continuation
    ) async {
        let started = ContinuousClock.now
        let decoder = decoder
        let batcher = RowBatcher(continuation: continuation, decoder: decoder)
        do {
            let metadataBox = NIOLockedValueBox<MySQLQueryMetadata?>(nil)
            do {
                try await underlying.query(
                    sql,
                    MySQLParameterEncoder.bindings(for: parameters),
                    onRow: { row in batcher.append(row) },
                    onMetadata: { metadata in metadataBox.withLockedValue { $0 = metadata } }
                ).get()
            } catch let error where Self.isUnsupportedByPreparedProtocol(error) && parameters.isEmpty {
                try await underlying.simpleQuery(sql, onRow: { row in batcher.append(row) }).get()
            }

            let rowCount = batcher.finish()
            let metadata = metadataBox.withLockedValue { $0 }
            continuation.yield(
                .complete(
                    QueryCompletion(
                        affectedRows: rowCount > 0
                            ? Int64(rowCount)
                            : metadata.flatMap { Int64(exactly: $0.affectedRows) },
                        lastInsertID: metadata?.lastInsertID.flatMap { Int64(exactly: $0) },
                        serverTag: Self.tag(sql: sql, metadata: metadata, rowCount: rowCount),
                        durationTotal: started.duration(to: .now)
                    )))
            noteTransactionKeyword(in: sql)
            continuation.finish()
        } catch {
            continuation.finish(throwing: MySQLErrorMapper.map(error, user: config.user))
        }
    }

    /// Keeps ``isInTransaction`` honest when the user types the keywords themselves, and
    /// notes a statement that changed session state for the reset on release.
    private func noteTransactionKeyword(in sql: String) {
        let keyword = SQLStatement(
            text: sql, utf16Range: 0 ..< 0, startLine: 1, terminator: nil
        ).leadingKeyword
        switch keyword {
        case "BEGIN", "START": transactionOpen = true
        case "COMMIT", "ROLLBACK": transactionOpen = false
        case "USE", "SET": sessionMutated = true
        default: break
        }
    }

    /// Stops the running statement with `KILL QUERY` from a second connection (SPEC §7.3).
    public func cancelCurrent() async {
        guard !closed, let threadID = Int(backendID) else { return }
        do {
            let connection = try await killChannel()
            _ = try await Self.rawQuery(
                "KILL QUERY \(threadID)", on: connection, logger: logger, decoder: decoder
            )
        } catch {
            logger.debug("cancel request failed", metadata: ["error": "\(error)"])
        }
    }

    /// The spare connection cancels run on, opened once and kept.
    private func killChannel() async throws -> MySQLConnection {
        if let killConnection, !killConnection.isClosed { return killConnection }
        var spare = config
        spare.connectTimeout = .seconds(5)
        spare.statementTimeout = nil
        let connection = try await MySQLDriver.openConnection(spare, logger: logger)
        killConnection = connection
        return connection
    }

    public func beginTransaction() async throws {
        try await runSimple("START TRANSACTION")
        transactionOpen = true
    }

    public func commit() async throws {
        try await runSimple("COMMIT")
        transactionOpen = false
    }

    public func rollback() async throws {
        try await runSimple("ROLLBACK")
        transactionOpen = false
    }

    public var isInTransaction: Bool { transactionOpen }

    public func ping() async throws {
        try await runSimple("SELECT 1")
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        if let killConnection { try? await killConnection.close().get() }
        killConnection = nil
        try? await underlying.close().get()
    }

    private func runSimple(_ sql: String) async throws {
        do {
            _ = try await Self.rawQuery(sql, on: underlying, logger: logger, decoder: decoder)
        } catch {
            throw MySQLErrorMapper.map(error, user: config.user)
        }
    }
}

/// Collects rows arriving on the event loop and yields them in batches.
///
/// `onRow` is called from NIO, so the buffer is lock-protected; batches leave at the
/// thresholds SPEC §4 sets.
final class RowBatcher: @unchecked Sendable {
    private let continuation: AsyncThrowingStream<QueryEvent, any Error>.Continuation
    private let decoder: MySQLValueDecoder
    private let lock = NIOLock()
    private var rows: [[DBValue]] = []
    private var delivered = 0
    private var bytes = 0
    private var emittedColumns = false

    init(
        continuation: AsyncThrowingStream<QueryEvent, any Error>.Continuation,
        decoder: MySQLValueDecoder
    ) {
        self.continuation = continuation
        self.decoder = decoder
    }

    func append(_ row: MySQLRow) {
        lock.lock()
        if !emittedColumns {
            emittedColumns = true
            let columns = MySQLSQLConnection.columns(of: row, decoder: decoder)
            lock.unlock()
            continuation.yield(.columns(columns))
            lock.lock()
        }
        rows.append(MySQLSQLConnection.values(of: row, decoder: decoder))
        bytes += row.values.reduce(0) { $0 + ($1?.readableBytes ?? 0) }
        let shouldFlush = rows.count >= RowBatching.maxRows || bytes >= RowBatching.maxBytes
        lock.unlock()
        if shouldFlush { flush() }
    }

    private func flush() {
        lock.lock()
        guard !rows.isEmpty else { return lock.unlock() }
        let batch = RowBatch(rows: rows, startIndex: delivered)
        delivered += rows.count
        rows.removeAll(keepingCapacity: true)
        bytes = 0
        lock.unlock()
        continuation.yield(.rows(batch))
    }

    /// Emits the last partial batch and returns how many rows were delivered.
    func finish() -> Int {
        flush()
        lock.lock()
        let total = delivered
        let sawColumns = emittedColumns
        lock.unlock()
        if !sawColumns { continuation.yield(.columns([])) }
        return total
    }
}
