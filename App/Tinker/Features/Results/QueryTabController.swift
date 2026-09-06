import AppKit
import DBCore
import DBGrid
import DBSQL
import DBStore
import Foundation
import Observation
import SwiftUI

/// Runs the statements in a query tab and collects one result per statement.
@MainActor
@Observable
public final class QueryTabController: SQLEditorDelegate, DataGridDelegate {
    public var sql: String = ""
    public var caretOffset = 0
    /// The editor's selection, when text is highlighted; what Run Selected runs.
    public var selectedRange: Range<Int>?
    public var results: [QueryResultTab] = []
    public var selectedResultID: UUID?
    public var isRunning = false
    public var elapsed: Duration = .zero
    public var statusText = ""
    public var errorBanner: QueryErrorBanner?
    public var selection = GridSelection()
    public private(set) var revision = 0
    public var autoCommit = true
    public var isInTransaction = false
    /// True when the connection is read-only and the user has not unlocked it.
    public var isReadOnly = false
    public var completionCandidates: [CompletionCandidate] = []

    /// The connection the tab runs on. Changing it points the tab at another server
    /// (SPEC §13.1a).
    public var connectionID: UUID
    public var dialect: SQLDialect

    /// The database (MySQL) or schema (PostgreSQL) statements resolve unqualified names
    /// against, so a query reads `SELECT * FROM t` rather than `SELECT * FROM db.t`.
    public private(set) var sessionDatabase: String?
    /// What the pickers offer.
    public private(set) var availableConnections: [ConnectionConfig] = []
    public private(set) var availableDatabases: [String] = []
    private let environment: AppEnvironment
    private var runTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    /// The connection held while a transaction is open, so `COMMIT` reaches the same one.
    private var heldLease: ConnectionSession.Lease?
    private var heldConnection: (any SQLConnection)?
    /// Tables of the schema or database the tab resolves names against, for autocomplete.
    private var completionTables: [CompletionCandidate] = []
    /// The other schemas (PostgreSQL) or databases (MySQL), offered as `name.` prefixes.
    private var completionSchemas: [CompletionCandidate] = []
    /// Tables of other schemas, read the first time `schema.` is typed.
    private var tablesBySchema: [String: [CompletionCandidate]] = [:]
    /// Columns per table, keyed by connection, schema and table so a switch leaves nothing stale.
    private var cachedColumns: [ColumnCacheKey: [ColumnInfo]] = [:]
    /// Bumped when the connection or schema changes, so a load for the old one is dropped.
    private var completionGeneration = 0
    private var warmTask: Task<Void, Never>?

    struct ColumnCacheKey: Hashable {
        let connection: UUID
        let schema: String
        let table: String
    }

    public init(connectionID: UUID, dialect: SQLDialect, environment: AppEnvironment) {
        self.connectionID = connectionID
        self.dialect = dialect
        self.environment = environment
    }

    var session: ConnectionSession? { environment.session(for: connectionID) }

    public var selectedResult: QueryResultTab? {
        results.first { $0.id == selectedResultID } ?? results.first
    }

    public func bumpRevision() { revision &+= 1 }

    /// The schema (PostgreSQL) or database (MySQL) unqualified names resolve against: the
    /// tab's choice in the toolbar, else the connection's own.
    private var completionSchema: String? {
        if let sessionDatabase, !sessionDatabase.isEmpty { return sessionDatabase }
        switch dialect {
        case .mysql: return session?.config.database
        case .postgresql: return "public"
        }
    }

    private func schemaRef(_ schema: String) -> SchemaRef {
        switch dialect {
        case .mysql: SchemaRef.mysql(schema)
        case .postgresql: SchemaRef(database: session?.config.database ?? "", schema: schema)
        }
    }

    /// Loads what autocomplete offers: the tables of the tab's schema or database, and the
    /// other schemas as prefixes. Called again whenever the tab points elsewhere.
    public func loadCompletionSources() async {
        guard let session else { return }
        completionGeneration &+= 1
        let generation = completionGeneration
        tablesBySchema = [:]
        let database = session.config.database ?? ""
        var schemas: [String] = []
        switch dialect {
        case .mysql:
            if let databases = try? await session.introspection(.databases, load: { try await $0.databases() }) {
                schemas = databases.map(\.name)
            }
        case .postgresql:
            if let found = try? await session.introspection(
                .schemas(database: database), load: { try await $0.schemas(in: database) })
            {
                schemas = found.filter { !$0.isSystem }.map(\.name)
            }
        }
        var tables: [CompletionCandidate] = []
        if let current = completionSchema {
            tables = await tableCandidates(inSchema: current)
        }
        // A later load for another schema or connection wins over this one.
        guard generation == completionGeneration else { return }
        completionSchemas = schemas.map { CompletionCandidate(text: $0, kind: .schema) }
        completionTables = tables
    }

    private func tableCandidates(inSchema schema: String) async -> [CompletionCandidate] {
        guard let session else { return [] }
        let ref = schemaRef(schema)
        guard let tables = try? await session.introspection(.tables(ref), load: { try await $0.tables(in: ref) })
        else { return [] }
        return tables.map { CompletionCandidate(text: $0.name, detail: $0.kind.rawValue, kind: .table) }
    }

    // MARK: - Running

    /// Runs the statement under the cursor, the selection, or every statement.
    public func run(all: Bool, selectedRange: Range<Int>? = nil) {
        // Running is the end of typing, so the suggestion list goes with it.
        NotificationCenter.default.post(name: .tinkerDismissCompletion, object: nil)
        guard !isRunning else { return }
        let statements: [SQLStatement]
        if let selectedRange, !selectedRange.isEmpty {
            let units = Array(sql.utf16)
            let clamped = selectedRange.clamped(to: 0 ..< units.count)
            let text = String(decoding: units[clamped], as: UTF16.self)
            statements = StatementSplitter.split(text, dialect: dialect)
        } else if all {
            statements = StatementSplitter.split(sql, dialect: dialect)
        } else if let statement = StatementSplitter.statement(at: caretOffset, in: sql, dialect: dialect) {
            statements = [statement]
        } else {
            statements = []
        }
        guard !statements.isEmpty else {
            statusText = "Nothing to run"
            return
        }
        runTask = Task { await execute(statements) }
    }

    /// Runs `EXPLAIN` for the statement under the cursor and shows the plan as a result.
    ///
    /// `analyze` executes the statement to time it, so it is only offered explicitly and
    /// never on a read-only connection.
    public func explain(analyze: Bool) {
        NotificationCenter.default.post(name: .tinkerDismissCompletion, object: nil)
        guard !isRunning,
            let statement = StatementSplitter.statement(at: caretOffset, in: sql, dialect: dialect)
        else {
            statusText = "Put the cursor in a statement to explain it"
            return
        }
        let text = TableOperations.explain(statement.text, analyze: analyze, dialect: dialect)
        let explained = SQLStatement(
            text: text, utf16Range: statement.utf16Range,
            startLine: statement.startLine, terminator: statement.terminator
        )
        runTask = Task { await execute([explained]) }
    }

    /// Puts text at the caret, replacing the selection if there is one.
    public func insertAtCaret(_ text: String) {
        let units = Array(sql.utf16)
        let offset = min(max(0, caretOffset), units.count)
        let before = String(decoding: units[..<offset], as: UTF16.self)
        let after = String(decoding: units[offset...], as: UTF16.self)
        let separator = before.isEmpty || before.hasSuffix("\n") ? "" : "\n"
        sql = before + separator + text + after
        caretOffset = offset + separator.utf16.count + text.utf16.count
        NotificationCenter.default.post(name: .tinkerMoveCaret, object: nil, userInfo: ["offset": caretOffset])
    }

    private func execute(_ statements: [SQLStatement]) async {
        guard let session else {
            statusText = "This connection is no longer configured"
            return
        }
        isRunning = true
        errorBanner = nil
        results.removeAll()
        elapsed = .zero
        startTimer()
        defer {
            isRunning = false
            timerTask?.cancel()
        }

        isReadOnly = await session.isReadOnly
        for statement in statements {
            if isReadOnly, !statement.isProbablyReadOnly {
                let result = QueryResultTab(label: statement.shortLabel, statement: statement.text)
                result.message = "Blocked: this connection is read-only. Unlock it with ⌘⇧L to run writes."
                results.append(result)
                selectedResultID = result.id
                break
            }
            let failed = await runOne(statement, session: session)
            if failed { break }
        }
        statusText = summary()
        // Several statements: show the first result, so the page reads top to bottom and
        // it is plain that every statement ran; the strip switches between the rest.
        if results.count > 1 { selectedResultID = results.first?.id }
        bumpRevision()
    }

    /// Runs one statement and appends its result. Returns true when it failed.
    private func runOne(_ statement: SQLStatement, session: ConnectionSession) async -> Bool {
        let result = QueryResultTab(label: statement.shortLabel, statement: statement.text)
        results.append(result)
        selectedResultID = result.id

        let startedAt = Date()
        let clockStart = ContinuousClock.now
        do {
            let connection = try await connectionForRun(session: session)
            // A SELECT pages on the server like a table tab: one page of rows now, the
            // rest on demand, whatever the table's size.
            if QueryGridLoader.isPageable(statement.text, dialect: dialect) {
                let loader = QueryGridLoader(statement: statement.text, dialect: dialect) { [weak self] in
                    guard let self else { throw DBError.notConnected }
                    return try await self.connectionForRun(session: session)
                }
                // A SELECT over one table with its key edits like a table tab.
                let editing = await editTarget(for: statement.text, session: session)
                let grid = GridModel(
                    source: .query(statement.text), dialect: dialect, loader: loader,
                    identityColumns: editing?.key ?? [], identityKind: editing?.keyKind)
                grid.isPaged = true
                await grid.load(page: 0)
                if let failure = grid.lastError { throw failure }
                if let editing {
                    let names = Set(grid.columns.map(\.name))
                    let sameTable = grid.columns.allSatisfy { $0.tableOID == nil || $0.tableOID == editing.tableOID }
                    if editing.key.allSatisfy(names.contains), sameTable {
                        grid.editTarget = editing.table
                        grid.editableColumns = editing.columns.intersection(names)
                    } else {
                        grid.setIdentity(columns: [], kind: nil)
                    }
                }
                let duration = clockStart.duration(to: .now)
                result.grid = grid
                result.completion = QueryCompletion(
                    affectedRows: nil, lastInsertID: nil, serverTag: nil, durationServer: nil, durationTotal: duration,
                    notices: [])
                result.message = Self.pageMessage(grid, exactTotal: nil, duration: duration)
                await environment.recordHistory(
                    QueryHistoryEntry(
                        connectionID: connectionID, database: session.config.database,
                        sql: statement.text, startedAt: startedAt, duration: duration,
                        rowCount: Int64(grid.rowCount), succeeded: true
                    ))
                isInTransaction = await connection.isInTransaction
                bumpRevision()
                return false
            }
            var columns: [ColumnMeta] = []
            var model: GridModel?
            var rowTotal = 0
            var completion: QueryCompletion?

            for try await event in connection.execute(statement.text, parameters: []) {
                switch event {
                case let .columns(value):
                    columns = value
                    if !value.isEmpty {
                        let grid = GridModel(
                            source: .query(statement.text), dialect: dialect, loader: StreamedGridLoader()
                        )
                        grid.appendStreamed(columns: value, batch: RowBatch(rows: [], startIndex: 0))
                        model = grid
                        result.grid = grid
                    }
                case let .rows(batch):
                    model?.appendStreamed(columns: columns, batch: batch)
                    rowTotal += batch.count
                    // Redraw as rows arrive so a long query shows progress.
                    if rowTotal % 5_000 < batch.count { bumpRevision() }
                    if let model, model.hasReachedMemoryCap { break }
                case let .complete(value):
                    completion = value
                }
            }
            model?.markStreamComplete()
            result.completion = completion
            let duration = clockStart.duration(to: .now)

            if columns.isEmpty {
                let affected = completion?.affectedRows ?? 0
                result.message =
                    "\(completion?.serverTag ?? "OK") — \(affected) row\(affected == 1 ? "" : "s") in \(Self.format(duration))"
            } else {
                result.message = "\(rowTotal) row\(rowTotal == 1 ? "" : "s") in \(Self.format(duration))"
            }
            await environment.recordHistory(
                QueryHistoryEntry(
                    connectionID: connectionID, database: session.config.database,
                    sql: statement.text, startedAt: startedAt, duration: duration,
                    rowCount: Int64(rowTotal), succeeded: true
                ))
            isInTransaction = await connection.isInTransaction
            bumpRevision()
            return false
        } catch {
            let banner = QueryErrorBanner(error: error, statement: statement.text)
            result.error = banner
            errorBanner = banner
            await environment.recordHistory(
                QueryHistoryEntry(
                    connectionID: connectionID, database: session.config.database,
                    sql: statement.text, startedAt: startedAt,
                    duration: clockStart.duration(to: .now),
                    error: banner.message, succeeded: false
                ))
            bumpRevision()
            return true
        }
    }

    /// What editing a result of `sql` would write to, when it reads one table whose key
    /// can be looked up; nil means the rows stay read-only.
    private func editTarget(
        for sql: String, session: ConnectionSession
    ) async -> (
        table: TableRef, key: [String], keyKind: DBValueKind?, columns: Set<String>, tableOID: String
    )? {
        guard let match = QuerySourceTable.detect(sql, dialect: dialect) else { return nil }
        let database = session.config.database ?? ""
        let table: TableRef
        switch dialect {
        case .mysql:
            let schema = match.schema ?? sessionDatabase ?? database
            table = TableRef(schema: SchemaRef.mysql(schema), name: match.name)
        case .postgresql:
            table = TableRef(database: database, schema: match.schema ?? sessionDatabase ?? "public", name: match.name)
        }
        guard
            let columns = try? await session.introspection(.columns(table), load: { try await $0.columns(of: table) }),
            !columns.isEmpty
        else { return nil }
        var key =
            (try? await session.introspection(.primaryKey(table), load: { try await $0.primaryKey(of: table) })) ?? nil
        if key == nil || key?.isEmpty == true {
            let (lease, connection) = (try? await session.lease()) ?? (nil, nil)
            if let lease, let connection {
                key = try? await connection.introspector.rowIdentity(of: table)
                await session.release(lease)
            }
        }
        guard let key, !key.isEmpty else { return nil }
        let keyKind = key.count == 1 ? columns.first { $0.name == key[0] }?.kind : nil
        let editable = Set(columns.filter { !$0.isGenerated }.map(\.name))
        return (table, key, keyKind, editable, "\(table.schema).\(table.name)")
    }

    // MARK: - Editing a result

    /// Pending edits on the selected result, for the status bar and the menu.
    public var pendingEditCount: Int { selectedResult?.grid?.edits.pendingStatementCount ?? 0 }

    public func pendingStatements() -> [GeneratedStatement] {
        (try? selectedResult?.grid?.pendingStatements()) ?? []
    }

    public func discardEdits() {
        selectedResult?.grid?.edits.discardAll()
        bumpRevision()
    }

    public func setSelectionNull() {
        guard let grid = selectedResult?.grid, grid.isEditable else { return }
        for row in selection.rows(totalRows: grid.displayRowCount) {
            for column in selection.columns(totalColumns: grid.columns.count) {
                grid.setValue(.null, row: row, column: column)
            }
        }
        bumpRevision()
    }

    public func deleteSelectedRows() {
        guard let grid = selectedResult?.grid, grid.isEditable else { return }
        grid.markDeleted(rows: selection.rows(totalRows: grid.displayRowCount))
        bumpRevision()
    }

    public func addRow() {
        guard let grid = selectedResult?.grid, grid.isEditable else { return }
        grid.addRow()
        bumpRevision()
    }

    public func rowValues(_ row: Int) -> [DBValue]? {
        guard let grid = selectedResult?.grid, row >= 0, row < grid.displayRowCount else { return nil }
        return (0 ..< grid.columns.count).map { grid.value(row: row, column: $0) ?? .null }
    }

    /// Writes the pending edits through the tab's own connection.
    ///
    /// With auto-commit on, the edits are one transaction of their own. With it off they
    /// join the tab's open transaction under a savepoint, so a refused statement takes
    /// only the edits back, not the statements the user ran before them; the transaction
    /// then commits when the user commits it. Either way the page is re-read afterwards,
    /// so a timestamp the server set is what the grid shows.
    public func commitEdits() async -> String? {
        guard let result = selectedResult, let grid = result.grid, grid.isEditable, let session else { return nil }
        if await session.isReadOnly { return "This connection is read-only" }
        do {
            let connection = try await connectionForRun(session: session)
            let runner = HeldConnectionRunner(connection: connection, usesSavepoint: !autoCommit)
            let committed = try await grid.commit(using: runner)
            isInTransaction = await connection.isInTransaction
            await grid.reload()
            result.message = Self.pageMessage(grid, exactTotal: result.exactTotal, duration: .zero)
            bumpRevision()
            return committed.statementCount == 0
                ? nil
                : "Committed \(committed.statementCount) statement\(committed.statementCount == 1 ? "" : "s")"
                    + (autoCommit ? "" : " into the open transaction")
        } catch let error as GridCommitError {
            errorBanner = QueryErrorBanner(error: error, statement: error.statement ?? result.statement)
            bumpRevision()
            return error.description
        } catch {
            errorBanner = QueryErrorBanner(error: error, statement: result.statement)
            bumpRevision()
            return (error as? DBError)?.errorDescription ?? String(describing: error)
        }
    }

    /// Re-reads every paged result, so rows show what the server holds now.
    private func reloadPagedResults() async {
        for result in results {
            guard let grid = result.grid, grid.isPaged else { continue }
            await grid.reload()
        }
        bumpRevision()
    }

    static func pageMessage(_ grid: GridModel, exactTotal: Int64?, duration: Duration) -> String {
        guard let range = grid.pageRange else { return "0 rows in \(format(duration))" }
        var text = "Rows \(range.lowerBound)–\(range.upperBound)"
        if let exactTotal {
            text += " of \(exactTotal)"
        } else if grid.isExhausted, let total = grid.totalCount {
            text += " of \(total)"
        }
        return text + " in \(format(duration))"
    }

    // MARK: - Result pages

    public var currentPage: Int { (selectedResult?.grid?.pageOffset ?? 0) + 1 }
    public var canGoBack: Bool { selectedResult?.grid?.hasPreviousPage ?? false }
    public var canGoForward: Bool {
        guard let result = selectedResult, let grid = result.grid, grid.hasNextPage else { return false }
        if let total = result.exactTotal { return Int64(currentPage) * Int64(grid.pageSize) < total }
        return true
    }

    public func goToPage(_ page: Int) async {
        guard let result = selectedResult, let grid = result.grid, grid.isPaged else { return }
        let started = ContinuousClock.now
        await grid.goToPage(page)
        if let failure = grid.lastError {
            errorBanner = QueryErrorBanner(error: failure, statement: result.statement)
        } else {
            result.message = Self.pageMessage(grid, exactTotal: result.exactTotal, duration: started.duration(to: .now))
        }
        bumpRevision()
    }

    public func goToFirstPage() async { await goToPage(0) }
    public func goToPreviousPage() async { await goToPage(max(0, (selectedResult?.grid?.pageOffset ?? 0) - 1)) }
    public func goToNextPage() async { await goToPage((selectedResult?.grid?.pageOffset ?? 0) + 1) }

    /// Jumping to the end counts the rows, the one place a `COUNT` over the query is worth it.
    public func goToLastPage() async {
        guard let result = selectedResult, let grid = result.grid, grid.isPaged else { return }
        let total = await grid.exactRowCount()
        result.exactTotal = total
        guard let total, total > 0 else { return }
        await goToPage(Int((total - 1) / Int64(grid.pageSize)))
    }

    /// The connection a statement runs on: the held one when a transaction is open, else
    /// a fresh lease returned as soon as the statement finishes.
    private func connectionForRun(session: ConnectionSession) async throws -> any SQLConnection {
        if let heldConnection {
            try await applySessionDatabase(on: heldConnection)
            // Auto-commit was turned off after this connection was taken: the next statement
            // is the first of a transaction, so one is opened here rather than never.
            if !autoCommit, !isInTransaction {
                try await heldConnection.beginTransaction()
                isInTransaction = true
            }
            return heldConnection
        }
        let (lease, connection) = try await session.lease()
        try await applySessionDatabase(on: connection)
        // The lease is kept either way — released by `releaseHeldConnection` when the tab
        // closes — so that COMMIT reaches the same connection the statements ran on.
        heldLease = lease
        heldConnection = connection
        if !autoCommit {
            try await connection.beginTransaction()
            isInTransaction = true
        }
        return connection
    }

    /// Points the connection at the chosen database or schema.
    ///
    /// Applied on every acquisition rather than once: the pool can hand back a different
    /// connection, and a `USE` on one says nothing about another.
    private func applySessionDatabase(on connection: any SQLConnection) async throws {
        guard let name = sessionDatabase, !name.isEmpty else { return }
        let quoted = Identifier.quote(name, dialect: dialect)
        let sql =
            switch dialect {
            case .mysql: "USE \(quoted)"
            // PostgreSQL cannot change database on an open connection; unqualified names
            // resolve against the search path, which it can change.
            case .postgresql: "SET search_path TO \(quoted)"
            }
        _ = try await connection.executeCollecting(sql)
    }

    // MARK: - Profile and Status panes (SPEC §13.2a)

    /// Reads the per-stage timings for a result, if the engine has any to give.
    public func loadProfile(for result: QueryResultTab) async {
        guard result.profile == nil, result.profileNote == nil else { return }
        guard let session = environment.session(for: connectionID) else { return }
        switch dialect {
        case .mysql:
            do {
                let (lease, connection) = try await session.lease()
                defer { Task { await session.release(lease) } }
                // Profiling is off by default and is per session, so it has to be asked
                // for; the numbers then describe the statements run after this point.
                _ = try? await connection.executeCollecting("SET profiling = 1")
                let profiles = try await connection.executeCollecting(
                    "SHOW PROFILE CPU, BLOCK IO"
                )
                guard !profiles.rows.isEmpty else {
                    result.profileNote =
                        "No profile yet. MySQL records one for the "
                        + "statements run after profiling is turned on, so run this again."
                    return
                }
                result.profileColumns = profiles.columns.map(\.name)
                result.profile = profiles.rows.map { row in row.map { $0.text ?? "" } }
            } catch {
                result.profileNote =
                    (error as? DBError)?.errorDescription
                    ?? String(describing: error)
            }
        case .postgresql:
            // Timing a statement here means running it again, and running a write again to
            // measure it is not something a client may do on its own.
            result.profileNote =
                "PostgreSQL has no profile that does not re-run the "
                + "statement. Use EXPLAIN (ANALYZE) on a SELECT when you want its timings."
        }
    }

    /// Reads the session counters for a result.
    public func loadStatus(for result: QueryResultTab) async {
        guard result.status == nil, result.statusNote == nil else { return }
        guard let session = environment.session(for: connectionID) else { return }
        let sql =
            switch dialect {
            case .mysql: "SHOW SESSION STATUS"
            case .postgresql:
                """
                SELECT * FROM pg_stat_database WHERE datname = current_database()
                """
            }
        do {
            let (lease, connection) = try await session.lease()
            defer { Task { await session.release(lease) } }
            let read = try await connection.executeCollecting(sql)
            result.statusColumns = read.columns.map(\.name)
            if dialect == .postgresql {
                // One wide row reads better turned on its side.
                result.statusColumns = ["Name", "Value"]
                result.status = zip(read.columns, read.rows.first ?? []).map { column, value in
                    [column.name, value.text ?? ""]
                }
            } else {
                result.status = read.rows.map { row in row.map { $0.text ?? "" } }
            }
        } catch {
            result.statusNote = (error as? DBError)?.errorDescription ?? String(describing: error)
        }
    }

    // MARK: - The tab's session (SPEC §13.1a)

    /// Reads what the pickers should offer for the current connection.
    public func loadSessionChoices() async {
        availableConnections = environment.connections
        guard let session = environment.session(for: connectionID) else { return }
        do {
            _ = try await session.connect()
            switch dialect {
            case .mysql:
                availableDatabases = try await session.introspection(.databases) {
                    try await $0.databases()
                }.map(\.name)
            case .postgresql:
                // The picker offers schemas, which is what an unqualified name resolves
                // against on PostgreSQL.
                let database =
                    environment.connections
                    .first { $0.id == connectionID }?.database ?? ""
                availableDatabases = try await session.introspection(.schemas(database: database)) {
                    try await $0.schemas(in: database)
                }.filter { !$0.isSystem }.map(\.name)
            }
            if sessionDatabase == nil {
                sessionDatabase =
                    dialect == .mysql
                    ? environment.connections.first { $0.id == connectionID }?.database
                    : availableDatabases.first { $0 == "public" } ?? availableDatabases.first
            }
        } catch {
            statusText = (error as? DBError)?.errorDescription ?? String(describing: error)
        }
    }

    /// Switches the tab to another database or schema, reporting what the server said if
    /// it refuses. The picker keeps the previous choice on failure.
    public func selectDatabase(_ name: String) async {
        let previous = sessionDatabase
        sessionDatabase = name
        guard let session = environment.session(for: connectionID) else { return }
        do {
            let connection: any SQLConnection
            if let heldConnection {
                connection = heldConnection
            } else {
                let (lease, fresh) = try await session.lease()
                defer { Task { await session.release(lease) } }
                connection = fresh
            }
            try await applySessionDatabase(on: connection)
            statusText = "Using \(name)"
        } catch {
            sessionDatabase = previous
            statusText = (error as? DBError)?.errorDescription ?? String(describing: error)
        }
        // Names now resolve elsewhere, so the list offers that schema's tables.
        await loadCompletionSources()
    }

    /// Points the tab at another connection, which is a different server and therefore a
    /// different set of databases and a different completion cache.
    public func selectConnection(_ id: UUID) async {
        guard id != connectionID,
            let config = environment.connections.first(where: { $0.id == id })
        else { return }
        await releaseHeldConnection()
        connectionID = id
        dialect = config.dialect
        sessionDatabase = nil
        availableDatabases = []
        results.removeAll()
        selectedResultID = nil
        statusText = "Connected to \(config.name)"
        cachedColumns = [:]
        await loadSessionChoices()
        await loadCompletionSources()
    }

    /// Turns auto-commit on or off. Turning it on while a transaction is open commits that
    /// transaction, so nothing is left waiting for a commit that would never come.
    public func setAutoCommit(_ enabled: Bool) async {
        autoCommit = enabled
        if enabled, isInTransaction { await commitTransaction() }
    }

    public func commitTransaction() async {
        defer { Task { await reloadPagedResults() } }
        guard let connection = heldConnection else { return }
        do {
            try await connection.commit()
            isInTransaction = false
            statusText = "Committed"
        } catch {
            errorBanner = QueryErrorBanner(error: error, statement: "COMMIT")
        }
    }

    public func rollbackTransaction() async {
        guard let connection = heldConnection else { return }
        do {
            try await connection.rollback()
            isInTransaction = false
            statusText = "Rolled back"
        } catch {
            errorBanner = QueryErrorBanner(error: error, statement: "ROLLBACK")
        }
    }

    /// Cancels the running statement on the server.
    public func cancel() {
        Task {
            await heldConnection?.cancelCurrent()
            runTask?.cancel()
            statusText = "Cancelling…"
        }
    }

    public func releaseHeldConnection() async {
        guard let session, let heldLease else { return }
        if isInTransaction { await rollbackTransaction() }
        await session.release(heldLease)
        self.heldLease = nil
        heldConnection = nil
    }

    private func startTimer() {
        timerTask?.cancel()
        let start = ContinuousClock.now
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, isRunning else { return }
                elapsed = start.duration(to: .now)
            }
        }
    }

    func summary() -> String {
        guard !results.isEmpty else { return "" }
        let failures = results.count { $0.error != nil }
        if failures > 0 {
            return "\(results.count - failures) of \(results.count) statements succeeded"
        }
        return results.count == 1
            ? (results[0].message ?? "Done")
            : "\(results.count) statements in \(Self.format(elapsed))"
    }

    public static func format(_ duration: Duration) -> String {
        let milliseconds =
            Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1e15
        if milliseconds < 1_000 { return String(format: "%.0f ms", milliseconds) }
        return String(format: "%.2f s", milliseconds / 1_000)
    }

    // MARK: - Editor support

    public func formatSQL() {
        sql = SQLFormatter.format(sql, dialect: dialect)
    }

    /// The range of the statement under the cursor, for the gutter marker.
    public var currentStatementRange: Range<Int>? {
        StatementSplitter.statement(at: caretOffset, in: sql, dialect: dialect)?.utf16Range
    }

    // MARK: - SQLEditorDelegate

    public func editorDidChangeText(_ text: String) {
        sql = text
        errorBanner = nil
        scheduleColumnWarm()
    }

    public func editorDidChangeSelection(offset: Int, length: Int) {
        caretOffset = offset
        selectedRange = length > 0 ? offset ..< offset + length : nil
    }

    public func editorDidRequestRun(_ scope: SQLRunScope, selection: Range<Int>?) {
        selectedRange = selection
        switch scope {
        case .all:
            statusText = "Running every statement…"
            run(all: true)
        case .selection:
            runSelection()
        case .current:
            // Run: the highlighted block when there is one, otherwise the statement at the
            // caret. Run All is its own button for the whole page.
            if let selection, !selection.isEmpty {
                statusText = "Running the selection…"
                run(all: false, selectedRange: selection)
            } else {
                statusText = "Running the statement under the cursor…"
                run(all: false)
            }
        }
    }

    /// Runs only the highlighted text, split into statements.
    public func runSelection() {
        guard let selectedRange, !selectedRange.isEmpty else {
            statusText = "Select the statements to run first"
            return
        }
        statusText = "Running the selection…"
        run(all: false, selectedRange: selectedRange)
    }

    public var hasSelection: Bool { !(selectedRange?.isEmpty ?? true) }

    /// What the list offers for the word at `caretOffset` (UTF-16, within `statement`).
    ///
    /// After `FROM` the tables of the tab's schema; in a select list or a condition the
    /// columns of the tables the statement names; after `u.` only that alias's columns;
    /// elsewhere keywords and tables (SPEC §13.1). With nothing typed yet the list still
    /// shows where the context makes it unambiguous, so `FROM ` alone offers the tables.
    public func editorCompletionCandidates(
        prefix: String, statement: String, caretOffset: Int
    )
        -> [CompletionCandidate]
    {
        let context = SQLCompletionContext.detect(statement: statement, caretOffset: caretOffset, dialect: dialect)
        let lowered = context.prefix.lowercased()
        func matches(_ candidate: CompletionCandidate) -> Bool {
            lowered.isEmpty || candidate.text.lowercased().hasPrefix(lowered)
        }
        let keywords =
            lowered.isEmpty
            ? []
            : SQLTokenizer.keywords
                .filter { $0.lowercased().hasPrefix(lowered) }
                .sorted()
                .map { CompletionCandidate(text: $0, kind: .keyword) }

        var ranked: [CompletionCandidate]
        switch context.expecting {
        case .tables:
            ranked = completionTables.filter(matches) + completionSchemas.filter(matches)
            if ranked.isEmpty { ranked = keywords }
        case .columns:
            ranked = columnCandidates(for: context.tables, matching: lowered) + keywords
        case let .qualified(qualifier):
            if let mention = context.table(for: qualifier) {
                ranked = columnCandidates(for: [mention], matching: lowered)
            } else if let tables = tablesBySchema[qualifier] {
                ranked = tables.filter(matches)
            } else if completionSchemas.contains(where: { $0.text.caseInsensitiveCompare(qualifier) == .orderedSame }) {
                loadTables(inSchema: qualifier)
                ranked = []
            } else {
                // A table named without a FROM: its columns, once they are read.
                ranked = columnCandidates(for: [SQLTableMention(name: qualifier)], matching: lowered)
            }
        case .any:
            ranked = lowered.isEmpty ? [] : keywords + completionTables.filter(matches)
        }
        // Tables and columns come before keywords, so the cap never hides what the context asked for.
        return Array(ranked.prefix(60))
    }

    /// Columns of `mentions` that are already read; the rest are read now and the list
    /// refreshed when they arrive.
    private func columnCandidates(for mentions: [SQLTableMention], matching lowered: String) -> [CompletionCandidate] {
        var candidates: [CompletionCandidate] = []
        var missing: [SQLTableMention] = []
        for mention in mentions {
            guard let columns = cachedColumns[cacheKey(for: mention)] else {
                missing.append(mention)
                continue
            }
            for column in columns where lowered.isEmpty || column.name.lowercased().hasPrefix(lowered) {
                let detail = mentions.count > 1 ? "\(mention.name) · \(column.nativeType)" : column.nativeType
                candidates.append(CompletionCandidate(text: column.name, detail: detail, kind: .column))
            }
        }
        if !missing.isEmpty { scheduleColumnWarm(missing) }
        return candidates
    }

    private func cacheKey(for mention: SQLTableMention) -> ColumnCacheKey {
        ColumnCacheKey(
            connection: connectionID, schema: mention.schema ?? completionSchema ?? "", table: mention.name)
    }

    /// Reads the columns of every table the statement mentions, for autocomplete.
    public func warmColumnCache(for statement: String) async {
        let mentions = SQLCompletionContext.detect(
            statement: statement, caretOffset: statement.utf16.count, dialect: dialect
        ).tables
        _ = await warmColumns(of: mentions)
    }

    /// Reads the columns of the tables the statement under the caret names, a moment after
    /// typing pauses, so the list has them by the time a column is wanted.
    private func scheduleColumnWarm(_ mentions: [SQLTableMention]? = nil) {
        warmTask?.cancel()
        warmTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            let wanted =
                mentions
                ?? {
                    let statement = StatementSplitter.statement(at: caretOffset, in: sql, dialect: dialect)?.text ?? sql
                    return SQLCompletionContext.detect(
                        statement: statement, caretOffset: statement.utf16.count, dialect: dialect
                    ).tables
                }()
            if await warmColumns(of: wanted) {
                NotificationCenter.default.post(name: .tinkerRefreshCompletion, object: nil)
            }
        }
    }

    /// Returns true when a table's columns were not cached before.
    private func warmColumns(of mentions: [SQLTableMention]) async -> Bool {
        guard let session else { return false }
        var loaded = false
        for mention in mentions {
            let key = cacheKey(for: mention)
            guard cachedColumns[key] == nil else { continue }
            let ref = TableRef(schema: schemaRef(key.schema), name: mention.name)
            if let columns = try? await session.introspection(.columns(ref), load: { try await $0.columns(of: ref) }) {
                cachedColumns[key] = columns
                loaded = true
            }
        }
        return loaded
    }

    /// Reads another schema's tables for `schema.` and refreshes the list when they arrive.
    private func loadTables(inSchema schema: String) {
        tablesBySchema[schema] = []
        let generation = completionGeneration
        Task { [weak self] in
            guard let self else { return }
            let tables = await tableCandidates(inSchema: schema)
            guard generation == completionGeneration else { return }
            tablesBySchema[schema] = tables
            NotificationCenter.default.post(name: .tinkerRefreshCompletion, object: nil)
        }
    }

    // MARK: - DataGridDelegate

    public func gridDidChangeSelection(_ selection: GridSelection) { self.selection = selection }
    public func gridDidRequestLoad(range: Range<Int>) {}
    public func gridDidCommitEdit(row: Int, column: Int, text: String) {
        guard let grid = selectedResult?.grid, grid.columns.indices.contains(column) else { return }
        guard grid.isColumnEditable(column) else {
            if let reason = grid.readOnlyReason {
                errorBanner = QueryErrorBanner(
                    error: DBError.protocolError(reason), statement: selectedResult?.statement ?? "")
            } else {
                errorBanner = QueryErrorBanner(
                    error: DBError.protocolError(
                        "\(grid.columns[column].name) is not a column of the table; it cannot be written back"),
                    statement: selectedResult?.statement ?? "")
            }
            bumpRevision()
            return
        }
        guard let value = ValueCoercion.coerce(text, to: grid.columns[column].kind) else {
            errorBanner = QueryErrorBanner(
                error: DBError.protocolError("\"\(text)\" is not a valid \(grid.columns[column].nativeTypeName)"),
                statement: selectedResult?.statement ?? "")
            bumpRevision()
            return
        }
        grid.setValue(value, row: row, column: column)
        bumpRevision()
    }
    public func gridDidRequestInspector() { onRequestInspector?() }
    /// Set by the tab view; the grid asks for the inspector with the space bar.
    @ObservationIgnored public var onRequestInspector: (() -> Void)?
    public func gridDidRequestSetNull() { setSelectionNull() }
    public func gridDidRequestDeleteRows() { deleteSelectedRows() }
    public func gridDidRequestAddRow() { addRow() }
    public func gridDidChangeColumnWidths(_ widths: [String: Double]) {}
    public func gridDidRequestCopy(format: ClipboardFormat) { copySelection(format: format) }

    /// Copies the current result selection as tab-separated text.
    public func copySelection(format: ClipboardFormat) {
        guard let grid = selectedResult?.grid else { return }
        let columnIndices = selection.columns(totalColumns: grid.columns.count)
        let rowIndices = selection.rows(totalRows: grid.displayRowCount)
        let columns = columnIndices.compactMap { grid.columns.indices.contains($0) ? grid.columns[$0] : nil }
        let rows = rowIndices.map { row in
            columnIndices.map { grid.value(row: row, column: $0) ?? .null }
        }
        guard !rows.isEmpty else { return }
        let text = ClipboardFormatter.render(
            columns: columns, rows: rows, format: format,
            options: .init(includeHeader: format != .tsv, dialect: dialect)
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Runs a grid commit on the query tab's own connection.
///
/// With `usesSavepoint` the edits sit inside the transaction already open on that
/// connection, fenced by a savepoint so a failure undoes only them.
private struct HeldConnectionRunner: GridStatementRunner {
    let connection: any SQLConnection
    let usesSavepoint: Bool

    func beginTransaction() async throws {
        if usesSavepoint {
            _ = try await connection.executeCollecting("SAVEPOINT tinker_edit")
        } else {
            try await connection.beginTransaction()
        }
    }

    func commitTransaction() async throws {
        if usesSavepoint {
            _ = try await connection.executeCollecting("RELEASE SAVEPOINT tinker_edit")
        } else {
            try await connection.commit()
        }
    }

    func rollbackTransaction() async throws {
        if usesSavepoint {
            _ = try await connection.executeCollecting("ROLLBACK TO SAVEPOINT tinker_edit")
        } else {
            try await connection.rollback()
        }
    }

    func run(_ statement: GeneratedStatement) async throws -> StatementOutcome {
        let result = try await connection.executeCollecting(statement.sql, parameters: statement.parameters)
        return StatementOutcome(
            affectedRows: result.completion.affectedRows, returnedRows: result.rows, returnedColumns: result.columns,
            lastInsertID: result.completion.lastInsertID)
    }
}
