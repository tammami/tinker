import DBCore
import DBSQL
import Foundation
import Logging
import NIOConcurrencyHelpers
import NIOCore
import PostgresNIO

/// One physical PostgreSQL connection.
///
/// Mutable state lives on the actor; the immutable pieces the streaming path needs
/// (decoder, backend pid, logger) are `nonisolated` so ``execute(_:parameters:)`` can hand
/// back a stream without an `await`.
public actor PostgresSQLConnection: SQLConnection {
    nonisolated let underlying: PostgresConnection
    nonisolated let config: ResolvedConnectionConfig
    nonisolated let logger: Logger
    nonisolated let decoder: PostgresBinaryDecoder

    public nonisolated let backendID: String
    public nonisolated let serverVersion: ServerVersion
    public nonisolated let introspector: any SchemaIntrospector

    /// Tracked rather than read from the server, because the wire protocol's transaction
    /// status is not exposed by PostgresNIO. Updated both by the transaction methods and
    /// by observing transaction keywords in statements the user runs (ADR-0009).
    private var transactionOpen = false
    private var closed = false

    init(underlying: PostgresConnection, config: ResolvedConnectionConfig, logger: Logger) async throws {
        self.underlying = underlying
        self.config = config
        self.logger = logger

        // One round trip for everything the connection needs to know about itself.
        let probe = try await Self.rawQuery(
            """
            SELECT version(), pg_backend_pid()::int8, current_setting('TimeZone'), \
            current_setting('server_version')
            """,
            on: underlying, logger: logger, decoder: PostgresBinaryDecoder(catalog: PostgresTypeCatalog())
        )
        guard let row = probe.rows.first, row.count >= 4 else {
            throw DBError.protocolError("The server did not answer the connection probe")
        }
        let versionText = row[0].text ?? ""
        let numericVersion = row[3].text ?? ""
        backendID = row[1].text ?? "0"
        let timeZoneName = row[2].text ?? "UTC"

        let numbers = ServerVersion.parseNumbers(numericVersion)
        serverVersion = ServerVersion(
            major: numbers.major, minor: numbers.minor, patch: numbers.patch,
            flavor: Self.flavor(from: versionText), rawString: versionText
        )

        let catalogRows = try await Self.rawQuery(
            PostgresTypeCatalog.loadQuery,
            on: underlying, logger: logger, decoder: PostgresBinaryDecoder(catalog: PostgresTypeCatalog())
        )
        let catalog = PostgresTypeCatalog.make(from: catalogRows.rows)
        decoder = PostgresBinaryDecoder(
            catalog: catalog,
            settings: PostgresSessionSettings(
                timeZone: TimeZone(identifier: timeZoneName), timeZoneName: timeZoneName
            )
        )
        introspector = PostgresIntrospector(
            connection: underlying, logger: logger, decoder: decoder,
            version: serverVersion, currentDatabase: config.database ?? ""
        )

        if let timeout = config.statementTimeout {
            let milliseconds =
                timeout.components.seconds * 1_000
                + Int64(timeout.components.attoseconds / 1_000_000_000_000_000)
            _ = try? await Self.rawQuery(
                "SET statement_timeout = \(milliseconds)",
                on: underlying, logger: logger, decoder: decoder
            )
        }
    }

    /// Runs a statement with no parameters and collects it, used during connection setup
    /// and by the introspector, where result sets are small and known.
    static func rawQuery(
        _ sql: String,
        on connection: PostgresConnection,
        logger: Logger,
        decoder: PostgresBinaryDecoder
    ) async throws -> QueryResult {
        let collected = NIOLockedValueBox<(columns: [ColumnMeta], rows: [[DBValue]])>(([], []))
        let started = ContinuousClock.now
        let metadata = try await connection.query(PostgresQuery(unsafeSQL: sql), logger: logger) { row in
            collected.withLockedValue { state in
                if state.columns.isEmpty { state.columns = Self.columns(of: row, decoder: decoder) }
                state.rows.append(Self.values(of: row, decoder: decoder))
            }
        }.get()
        let state = collected.withLockedValue { $0 }
        return QueryResult(
            columns: state.columns,
            rows: state.rows,
            completion: QueryCompletion(
                affectedRows: metadata.rows.map(Int64.init),
                serverTag: Self.tag(from: metadata),
                durationTotal: started.duration(to: .now)
            )
        )
    }

    static func flavor(from versionText: String) -> ServerFlavor {
        let lowered = versionText.lowercased()
        if lowered.contains("aurora") { return .aurora }
        return .postgresql
    }

    static func tag(from metadata: PostgresQueryMetadata) -> String {
        if let oid = metadata.oid, let rows = metadata.rows { return "\(metadata.command) \(oid) \(rows)" }
        if let rows = metadata.rows { return "\(metadata.command) \(rows)" }
        return metadata.command
    }

    static func columns(of row: PostgresRow, decoder: PostgresBinaryDecoder) -> [ColumnMeta] {
        row.enumerated().map { index, cell in
            let oid = cell.dataType.rawValue
            return ColumnMeta(
                id: index,
                name: cell.columnName,
                tableOID: nil,
                nativeTypeName: decoder.typeName(decoder.catalog.resolvingDomain(oid)),
                kind: PGOID.kind(for: oid, catalog: decoder.catalog)
            )
        }
    }

    static func values(of row: PostgresRow, decoder: PostgresBinaryDecoder) -> [DBValue] {
        row.map { decoder.decode(oid: $0.dataType.rawValue, bytes: $0.bytes) }
    }

    // MARK: - SQLConnection

    /// `COPY table (columns) FROM STDIN` in text format, fed by `body`.
    ///
    /// PostgresNIO quotes the table as a single identifier, so the schema is reached
    /// through `search_path` for the duration of the copy and the previous value put back.
    public func copyIn(
        into table: TableRef, columns: [String], body: @Sendable (any BulkLoadWriter) async throws -> Void
    ) async throws {
        for name in [table.schema, table.name] + columns where name.contains("\"") {
            throw DBError.protocolError("COPY cannot target a name containing a double quote: \(name)")
        }
        var previousPath =
            try await Self.rawQuery("SHOW search_path", on: underlying, logger: logger, decoder: decoder)
            .rows.first?.first?.text ?? "\"$user\", public"
        // pg_dump scripts empty the path; an empty list has to be spelled as ''.
        if previousPath.trimmingCharacters(in: .whitespaces).isEmpty { previousPath = "''" }
        _ = try await Self.rawQuery(
            "SET search_path TO \(Identifier.quote(table.schema, dialect: .postgresql))",
            on: underlying, logger: logger, decoder: decoder)
        var failure: (any Error)?
        do {
            try await underlying.copyFrom(table: table.name, columns: columns, logger: logger) { writer in
                try await body(CopyWriter(writer: writer))
            }
        } catch {
            failure = error
        }
        // Put back before anything else can run on this connection, whichever way it went.
        _ = try? await Self.rawQuery(
            "SET search_path TO \(previousPath)", on: underlying, logger: logger, decoder: decoder)
        if let failure { throw PostgresErrorMapper.map(failure, user: config.user) }
    }

    private struct CopyWriter: BulkLoadWriter {
        let writer: PostgresCopyFromWriter
        func write(_ data: Data) async throws {
            try await writer.write(ByteBuffer(bytes: data))
        }
    }

    public nonisolated func execute(
        _ sql: String,
        parameters: [DBValue]
    ) -> AsyncThrowingStream<QueryEvent, any Error> {
        AsyncThrowingStream { continuation in
            // Unstructured on purpose: cancelling the consumer must reach the *server*
            // through `pg_cancel_backend`, not tear down the NIO channel, so that the
            // connection stays usable afterwards (SPEC §13.3).
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
        let query = PostgresQuery(
            unsafeSQL: sql, binds: PostgresParameterEncoder.bindings(for: parameters)
        )
        do {
            if Self.streamsManyRows(sql) {
                try await runStreaming(query, sql: sql, into: continuation, started: started)
            } else {
                try await runCollecting(query, into: continuation, started: started)
            }
            noteTransactionKeyword(in: sql)
            continuation.finish()
        } catch {
            let mapped = PostgresErrorMapper.map(error, user: config.user)
            if case .server(let serverError) = mapped,
                serverError.sqlState == PostgresErrorMapper.adminShutdownSQLState
            {
                closed = true
            }
            continuation.finish(throwing: mapped)
        }
    }

    /// Statements that can return an unbounded number of rows take the back-pressured
    /// path; everything else takes the callback path, which reports the server's own
    /// command tag and therefore the real affected-row count (ADR-0008).
    static func streamsManyRows(_ sql: String) -> Bool {
        let statement = SQLStatement(text: sql, utf16Range: 0 ..< 0, startLine: 1, terminator: nil)
        let keyword = statement.leadingKeyword
        if ["SELECT", "WITH", "VALUES", "TABLE", "SHOW", "EXPLAIN"].contains(keyword) { return true }
        // `… RETURNING` streams rows, and its row count equals its affected-row count.
        return SQLTokenizer.tokenize(sql, dialect: .postgresql)
            .contains { $0.kind == .keyword && $0.text.uppercased() == "RETURNING" }
    }

    private func runStreaming(
        _ query: PostgresQuery,
        sql: String,
        into continuation: AsyncThrowingStream<QueryEvent, any Error>.Continuation,
        started: ContinuousClock.Instant
    ) async throws {
        let rows = try await underlying.query(query, logger: logger)
        var emittedColumns = false
        var batch: [[DBValue]] = []
        var batchBytes = 0
        var delivered = 0

        func flush() {
            guard !batch.isEmpty else { return }
            continuation.yield(.rows(RowBatch(rows: batch, startIndex: delivered - batch.count)))
            batch.removeAll(keepingCapacity: true)
            batchBytes = 0
        }

        for try await row in rows {
            if !emittedColumns {
                continuation.yield(.columns(Self.columns(of: row, decoder: decoder)))
                emittedColumns = true
            }
            var rowBytes = 0
            let values = row.map { cell -> DBValue in
                rowBytes += cell.bytes?.readableBytes ?? 0
                return decoder.decode(oid: cell.dataType.rawValue, bytes: cell.bytes)
            }
            batch.append(values)
            batchBytes += rowBytes
            delivered += 1
            if batch.count >= RowBatching.maxRows || batchBytes >= RowBatching.maxBytes { flush() }
        }
        flush()
        if !emittedColumns { continuation.yield(.columns([])) }

        let keyword = SQLStatement(text: sql, utf16Range: 0 ..< 0, startLine: 1, terminator: nil).leadingKeyword
        continuation.yield(
            .complete(
                QueryCompletion(
                    affectedRows: Int64(delivered),
                    serverTag: "\(keyword.isEmpty ? "SELECT" : keyword) \(delivered)",
                    durationTotal: started.duration(to: .now)
                )))
    }

    private func runCollecting(
        _ query: PostgresQuery,
        into continuation: AsyncThrowingStream<QueryEvent, any Error>.Continuation,
        started: ContinuousClock.Instant
    ) async throws {
        let decoder = decoder
        let collected = NIOLockedValueBox<(columns: [ColumnMeta], rows: [[DBValue]])>(([], []))
        let metadata = try await underlying.query(query, logger: logger) { row in
            collected.withLockedValue { state in
                if state.columns.isEmpty { state.columns = Self.columns(of: row, decoder: decoder) }
                state.rows.append(Self.values(of: row, decoder: decoder))
            }
        }.get()

        let state = collected.withLockedValue { $0 }
        continuation.yield(.columns(state.columns))
        if !state.rows.isEmpty {
            continuation.yield(.rows(RowBatch(rows: state.rows, startIndex: 0)))
        }
        continuation.yield(
            .complete(
                QueryCompletion(
                    affectedRows: metadata.rows.map(Int64.init) ?? Int64(state.rows.count),
                    serverTag: Self.tag(from: metadata),
                    durationTotal: started.duration(to: .now)
                )))
    }

    /// Keeps ``isInTransaction`` honest when the user types `BEGIN` or `COMMIT`
    /// into the editor instead of using the toolbar.
    private func noteTransactionKeyword(in sql: String) {
        let keyword = SQLStatement(text: sql, utf16Range: 0 ..< 0, startLine: 1, terminator: nil).leadingKeyword
        switch keyword {
        case "BEGIN", "START": transactionOpen = true
        case "COMMIT", "ROLLBACK", "END": transactionOpen = false
        default: break
        }
    }

    /// Cancels whatever this connection is running, from a second connection, using
    /// PostgreSQL's own `pg_cancel_backend` (ADR-0007).
    ///
    /// Best effort by design: a connection that has already finished, or a server that
    /// refuses the cancel, must not turn into an error the user sees.
    public func cancelCurrent() async {
        guard !closed, let pid = Int32(backendID) else { return }
        var cancelConfig = config
        cancelConfig.connectTimeout = .seconds(5)
        cancelConfig.statementTimeout = .seconds(5)
        do {
            let tls = try PostgresDriver.makeTLS(cancelConfig)
            var configuration = PostgresConnection.Configuration(
                host: cancelConfig.host, port: cancelConfig.port,
                username: cancelConfig.user, password: cancelConfig.password,
                database: cancelConfig.database, tls: tls
            )
            configuration.options.connectTimeout = .seconds(5)
            let helper = try await PostgresConnection.connect(
                on: PostgresDriver.eventLoopGroup.next(),
                configuration: configuration,
                id: -abs(Int(pid)),
                logger: logger
            )
            do {
                _ = try await Self.rawQuery(
                    "SELECT pg_cancel_backend(\(pid))", on: helper, logger: logger, decoder: decoder
                )
            } catch {
                logger.debug("cancel query failed", metadata: ["error": "\(error)"])
            }
            try? await helper.close()
        } catch {
            logger.debug("cancel request failed", metadata: ["error": "\(error)"])
        }
    }

    public func beginTransaction() async throws {
        try await runSimple("BEGIN")
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
        try? await underlying.close()
    }

    private func runSimple(_ sql: String) async throws {
        do {
            _ = try await Self.rawQuery(sql, on: underlying, logger: logger, decoder: decoder)
        } catch {
            throw PostgresErrorMapper.map(error, user: config.user)
        }
    }
}
