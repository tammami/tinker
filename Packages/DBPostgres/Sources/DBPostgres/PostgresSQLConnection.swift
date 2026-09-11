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
    public nonisolated let transport: TransportInfo
    /// Set when a statement changed session state (`SET`, `RESET`, `DISCARD`), so the
    /// reset on release only pays its round trip when there is something to put back.
    private var sessionMutated = false

    /// Tracked rather than read from the server, because the wire protocol's transaction
    /// status is not exposed by PostgresNIO. Updated both by the transaction methods and
    /// by observing transaction keywords in statements the user runs (ADR-0009).
    private var transactionOpen = false
    private var closed = false
    /// Set when this client asked the server to cancel, so that the 57014 that follows is
    /// reported as `.cancelled` and a `statement_timeout`'s 57014 is not.
    private var cancelRequested = false
    /// Counts statements started on this connection. A cancel opens a helper connection
    /// first, which takes long enough for the statement it was meant for to finish and
    /// the next one to start; the cancel is dropped when that has happened, so it never
    /// lands on a statement nobody asked to stop.
    private var statementGeneration = 0
    private var statementInFlight = false

    init(underlying: PostgresConnection, config: ResolvedConnectionConfig, logger: Logger) async throws {
        self.underlying = underlying
        self.config = config
        self.logger = logger

        // One round trip for everything the connection needs to know about itself,
        // including whether the wire it came over is encrypted.
        let probe = try await Self.rawQuery(
            """
            SELECT version(), pg_backend_pid()::int8, current_setting('TimeZone'), \
            current_setting('server_version'), s.ssl, s.version, s.cipher
            FROM (SELECT 1) AS one
            LEFT JOIN pg_catalog.pg_stat_ssl s ON s.pid = pg_backend_pid()
            """,
            on: underlying, logger: logger, decoder: PostgresBinaryDecoder(catalog: PostgresTypeCatalog())
        )
        guard let row = probe.rows.first, row.count >= 7 else {
            throw DBError.protocolError("The server did not answer the connection probe")
        }
        let encrypted = row[4] == .bool(true)
        transport = TransportInfo(
            isEncrypted: encrypted,
            protocolVersion: encrypted ? row[5].text : nil,
            cipher: encrypted ? row[6].text : nil
        )
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

    /// Puts the session back the way the connection started: every `SET` undone, the
    /// role dropped, and the statement timeout the configuration asked for restored.
    /// Skipped when nothing ran that could have changed them.
    public func resetSessionState() async throws {
        guard sessionMutated, !closed else { return }
        sessionMutated = false
        try await runSimple("RESET ALL")
        try await runSimple("RESET ROLE")
        if let timeout = config.statementTimeout {
            let milliseconds =
                timeout.components.seconds * 1_000
                + Int64(timeout.components.attoseconds / 1_000_000_000_000_000)
            _ = try? await Self.rawQuery(
                "SET statement_timeout = \(milliseconds)", on: underlying, logger: logger, decoder: decoder)
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
        let previousPath =
            try await Self.rawQuery("SHOW search_path", on: underlying, logger: logger, decoder: decoder)
            .rows.first?.first?.text ?? "\"$user\", public"
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
        // The previous value is bound, not interpolated: it is text the server gave us,
        // and `set_config` takes it as a value rather than as SQL.
        _ = try? await underlying.query(
            "SELECT set_config('search_path', \(previousPath), false)", logger: logger
        ).get()
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
        // A bounded channel, not a continuation: `send` waits when the consumer is behind,
        // and that wait reaches the socket through the row sequence, so a million-row
        // result is never more than a few batches in memory (SPEC §4, §12.6).
        let channel = QueryEventChannel()
        // Unstructured on purpose: cancelling the consumer must reach the *server*
        // through `pg_cancel_backend`, not tear down the NIO channel, so that the
        // connection stays usable afterwards (SPEC §13.3).
        let task = Task { await self.run(sql: sql, parameters: parameters, into: channel) }
        return channel.stream { [pendingCancels] in
            // Counted before the hop onto the actor, so a statement started in between
            // still waits for this cancel to land (see `waitForCancelsToLand`).
            pendingCancels.increment()
            Task {
                await self.cancelCurrent()
                await self.notePendingCancelDone()
                task.cancel()
            }
        }
    }

    /// Cancels asked for by a dropped stream that have not yet reached the actor. Read
    /// by `waitForCancelsToLand`; counted off the actor, where the asking happens.
    private nonisolated let pendingCancels = AtomicCounter()

    private func run(
        sql: String,
        parameters: [DBValue],
        into channel: QueryEventChannel
    ) async {
        let started = ContinuousClock.now
        let query = PostgresQuery(
            unsafeSQL: sql, binds: PostgresParameterEncoder.bindings(for: parameters)
        )
        // A cancel that is still on its way lands before this statement begins, so it
        // cannot land on it. Then a new generation, unless the previous statement's
        // consumer went away while the server was still running it: this one is queued
        // behind it on the wire, and a cancel meant for the abandoned one must still be
        // sent, or this one waits until the server has streamed every row nobody wanted.
        await waitForCancelsToLand()
        if !statementInFlight { statementGeneration += 1 }
        statementInFlight = true
        do {
            if Self.streamsManyRows(sql) {
                try await runStreaming(query, sql: sql, into: channel, started: started)
            } else {
                try await runCollecting(query, into: channel, started: started)
            }
            noteTransactionKeyword(in: sql)
            cancelRequested = false
            statementInFlight = false
            channel.finish()
        } catch {
            // A consumer that went away ends this task, not the statement: the server is
            // still running it until the cancel lands, so it stays "in flight" and the
            // cancel that the dropped stream triggered is not skipped as stale.
            if !(error is CancellationError) { statementInFlight = false }
            let mapped = PostgresErrorMapper.map(error, user: config.user, cancelRequested: cancelRequested)
            cancelRequested = false
            if case .server(let serverError) = mapped,
                serverError.sqlState == PostgresErrorMapper.adminShutdownSQLState
            {
                closed = true
            }
            channel.finish(throwing: mapped)
        }
    }

    /// Statements that can return an unbounded number of rows take the back-pressured
    /// path; everything else takes the callback path, which reports the server's own
    /// command tag and therefore the real affected-row count (ADR-0008).
    static func streamsManyRows(_ sql: String) -> Bool {
        let statement = SQLStatement(text: sql, utf16Range: 0 ..< 0, startLine: 1, terminator: nil)
        let keyword = statement.leadingKeyword
        // `… RETURNING` streams rows, and its row count equals its affected-row count.
        let returning = SQLTokenizer.tokenize(sql, dialect: .postgresql)
            .contains { $0.kind == .keyword && $0.text.uppercased() == "RETURNING" }
        if returning { return true }
        // `WITH … INSERT/UPDATE/DELETE` with no RETURNING streams nothing; on the streaming
        // path its command tag was discarded and it reported "WITH 0" rows affected. The
        // splitter's read-only classification already tells the two apart.
        if keyword == "WITH" { return statement.isProbablyReadOnly }
        return ["SELECT", "VALUES", "TABLE", "SHOW", "EXPLAIN"].contains(keyword)
    }

    private func runStreaming(
        _ query: PostgresQuery,
        sql: String,
        into channel: QueryEventChannel,
        started: ContinuousClock.Instant
    ) async throws {
        let rows = try await underlying.query(query, logger: logger)
        var emittedColumns = false
        var batch: [[DBValue]] = []
        var batchBytes = 0
        var delivered = 0

        // Waits while the consumer is behind; the row sequence then stops asking NIO for
        // more, which is the back-pressure the spec asks for. The batch is handed over by
        // value so nothing mutable is shared across the suspension.
        func send(_ rows: [[DBValue]], startingAt start: Int) async throws {
            guard !rows.isEmpty else { return }
            try await channel.send(.rows(RowBatch(rows: rows, startIndex: start)))
        }

        for try await row in rows {
            if !emittedColumns {
                try await channel.send(.columns(Self.columns(of: row, decoder: decoder)))
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
            if batch.count >= RowBatching.maxRows || batchBytes >= RowBatching.maxBytes {
                let full = batch
                batch.removeAll(keepingCapacity: true)
                batchBytes = 0
                try await send(full, startingAt: delivered - full.count)
            }
        }
        // Every row has been read: the server is done with this statement, whatever the
        // consumer does with the rest of the events. A cancel asked for now would have
        // nothing to stop, and the next statement may take a new generation.
        statementInFlight = false
        let rest = batch
        batch.removeAll()
        try await send(rest, startingAt: delivered - rest.count)
        if !emittedColumns { try await channel.send(.columns([])) }

        let keyword = SQLStatement(text: sql, utf16Range: 0 ..< 0, startLine: 1, terminator: nil).leadingKeyword
        try await channel.send(
            .complete(
                QueryCompletion(
                    affectedRows: Int64(delivered),
                    serverTag: "\(keyword.isEmpty ? "SELECT" : keyword) \(delivered)",
                    durationTotal: started.duration(to: .now)
                )))
    }

    private func runCollecting(
        _ query: PostgresQuery,
        into channel: QueryEventChannel,
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

        // The server has answered; only the hand-off to the consumer is left.
        statementInFlight = false
        let state = collected.withLockedValue { $0 }
        try await channel.send(.columns(state.columns))
        if !state.rows.isEmpty {
            try await channel.send(.rows(RowBatch(rows: state.rows, startIndex: 0)))
        }
        try await channel.send(
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
        case "SET", "RESET", "DISCARD": sessionMutated = true
        // `SELECT set_config(…)` changes session state as `SET` does.
        case "SELECT" where sql.uppercased().contains("SET_CONFIG("): sessionMutated = true
        default: break
        }
    }

    /// Cancels whatever this connection is running, from a second connection, using
    /// PostgreSQL's own `pg_cancel_backend` (ADR-0007).
    ///
    /// Best effort by design: a connection that has already finished, or a server that
    /// refuses the cancel, must not turn into an error the user sees.
    /// Added to the time the cancel's helper connection takes, so a test can widen the
    /// window in which the statement it was for ends and another starts.
    var cancelDelayForTesting: Duration = .zero
    func setCancelDelayForTesting(_ delay: Duration) { cancelDelayForTesting = delay }

    /// Cancels in flight, and the statements waiting for them to land. A cancel opens a
    /// helper connection first; a statement that started meanwhile could be the one the
    /// `SIGINT` reaches. So no statement starts on this connection while a cancel is on
    /// its way: it waits, the cancel lands on the statement it was for (or on an idle
    /// backend, which ignores it), and only then does the next one begin.
    private var cancelsInFlight = 0
    private var runsWaitingForCancels: [CheckedContinuation<Void, Never>] = []

    private func waitForCancelsToLand() async {
        while cancelsInFlight > 0 || pendingCancels.value > 0 {
            await withCheckedContinuation { runsWaitingForCancels.append($0) }
        }
    }

    private func noteCancelLanded() {
        cancelsInFlight -= 1
        resumeRunsIfNoCancelIsPending()
    }

    private func notePendingCancelDone() {
        pendingCancels.decrement()
        resumeRunsIfNoCancelIsPending()
    }

    private func resumeRunsIfNoCancelIsPending() {
        guard cancelsInFlight == 0, pendingCancels.value == 0 else { return }
        let waiting = runsWaitingForCancels
        runsWaitingForCancels.removeAll()
        for continuation in waiting { continuation.resume() }
    }

    public func cancelCurrent() async {
        guard !closed, statementInFlight, let pid = Int32(backendID) else { return }
        let generation = statementGeneration
        cancelRequested = true
        cancelsInFlight += 1
        defer { noteCancelLanded() }
        if cancelDelayForTesting > .zero { try? await Task.sleep(for: cancelDelayForTesting) }
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
            // Opening the helper took time; the statement this cancel was for may have
            // finished and another started. That one is left alone.
            if generation == statementGeneration, statementInFlight {
                do {
                    _ = try await Self.rawQuery(
                        "SELECT pg_cancel_backend(\(pid))", on: helper, logger: logger, decoder: decoder
                    )
                } catch {
                    logger.debug("cancel query failed", metadata: ["error": "\(error)"])
                }
            } else {
                cancelRequested = false
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
        // `BEGIN`, `COMMIT` and `ROLLBACK` wait for a cancel on its way like any statement.
        await waitForCancelsToLand()
        do {
            _ = try await Self.rawQuery(sql, on: underlying, logger: logger, decoder: decoder)
        } catch {
            throw PostgresErrorMapper.map(error, user: config.user)
        }
    }
}
