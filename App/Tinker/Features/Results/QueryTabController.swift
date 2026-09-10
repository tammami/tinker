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
    /// The tables the pending warm is about to read, so asking for them again while it
    /// waits does not restart its pause: a list polled every few milliseconds would
    /// otherwise never see the columns arrive.
    private var warmingKeys: Set<ColumnCacheKey> = []
    private var warmGeneration = 0

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

    /// The foreign keys of each result that reads one table, by result id, so a cell
    /// can be followed to the row it points at, as on a table tab.
    @ObservationIgnored private var references: [UUID: ReferenceSupport] = [:]
    private var selectedReferences: ReferenceSupport? { selectedResultID.flatMap { references[$0] } }

    var session: ConnectionSession? { environment.session(for: connectionID) }

    /// The connection's configuration as stored now; nil once it has been deleted.
    private var config: ConnectionConfig? { environment.connections.first { $0.id == connectionID } }

    /// True when the connection is marked as production.
    public var isProduction: Bool { config?.isProduction ?? false }

    /// Whether result edits write as they are made. Never on a production connection:
    /// there every write goes through the commit sheet, whatever the checkbox says.
    public var autoCommitsEdits: Bool { autoCommit && !isProduction }

    /// Whether statements commit as they run. Never on a production connection: there a
    /// write is held in a transaction until Commit, so a mistake can still be rolled back.
    public var commitsAutomatically: Bool { autoCommit && !isProduction }

    /// Set by the tab view: shows a confirmation sheet before statements run on production.
    @ObservationIgnored public var onConfirmProduction: ((DestructiveConfirmation) -> Void)?

    /// Starts the statements, after asking on a production connection when any of them
    /// writes. Reads run without a question; nothing else does. With no way to ask (the
    /// tab's view has not attached one), a production write does not run at all.
    private func start(_ statements: [SQLStatement]) {
        let writes = statements.filter { !$0.isProbablyReadOnly }
        guard isProduction, !writes.isEmpty, let config else {
            runTask = Task { await execute(statements) }
            return
        }
        guard let onConfirmProduction else {
            statusText = "Not run: production writes need the tab's confirmation sheet"
            errorBanner = QueryErrorBanner(
                error: DBError.protocolError(
                    "“\(config.name)” is a production connection and this tab cannot ask for confirmation; open the statement in a query tab"
                ),
                statement: writes[0].text)
            return
        }
        let destructive = writes.contains(where: \.isProbablyDestructive)
        let listed = writes.prefix(5).map { "• " + $0.text.split(whereSeparator: \.isNewline).joined(separator: " ") }
        var message =
            "\(writes.count) of \(statements.count) statement\(statements.count == 1 ? "" : "s") "
            + "will change data on the production connection “\(config.name)”:\n\n" + listed.joined(separator: "\n")
        if writes.count > listed.count { message += "\n• … and \(writes.count - listed.count) more" }
        if destructive { message += "\n\nType the connection's name to run them." }
        onConfirmProduction(
            DestructiveConfirmation(
                title: "Run on “\(config.name)”?",
                message: message,
                requiredTypedName: destructive ? config.name : nil,
                confirmTitle: "Run on \(config.name)",
                action: { [weak self] in
                    guard let self else { return }
                    // Through `runTask`, so ⌘. cancels a confirmed run like any other.
                    let task = Task { await self.execute(statements) }
                    runTask = task
                    await task.value
                }
            ))
    }

    public var selectedResult: QueryResultTab? {
        results.first { $0.id == selectedResultID } ?? results.first
    }

    public func bumpRevision() {
        revision &+= 1
        scheduleReferenceLabels()
    }

    /// Looks up, shortly after the grid changed, the labels beside foreign-key values
    /// that are loaded and not known yet; a redraw follows without another round.
    private func scheduleReferenceLabels() {
        guard let grid = selectedResult?.grid, let session, let references = selectedReferences else { return }
        references.scheduleLabels(model: grid, session: session) { [weak self] in self?.revision &+= 1 }
    }

    /// Shows one of the run's results. The cell selection belongs to the result it was
    /// made in, so it starts over rather than pointing into another result's columns.
    public func showResult(_ id: UUID) {
        guard selectedResultID != id else { return }
        selectedResultID = id
        selection = GridSelection()
    }

    /// The schema (PostgreSQL) or database (MySQL) unqualified names resolve against: the
    /// tab's choice in the toolbar, else the connection's own.
    private var completionSchema: String? {
        if let sessionDatabase, !sessionDatabase.isEmpty { return sessionDatabase }
        switch dialect {
        case .mysql: return session?.config.database
        case .postgresql: return "public"
        case .sqlite: return SchemaRef.sqliteMainSchema
        }
    }

    private func schemaRef(_ schema: String) -> SchemaRef {
        SchemaRef.pseudoSchema(dialect, database: schema)
            ?? SchemaRef(database: session?.config.database ?? "", schema: schema)
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
        case .mysql, .sqlite:
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
        guard !isWritingEdits else {
            statusText = "Waiting for the edit to save before running"
            return
        }
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
        start(statements)
    }

    /// Runs `EXPLAIN` for the statement under the cursor and shows the plan as a result.
    ///
    /// `analyze` executes the statement to time it, so it is only offered explicitly and
    /// never on a read-only connection.
    public func explain(analyze: Bool) {
        NotificationCenter.default.post(name: .tinkerDismissCompletion, object: nil)
        guard !isRunning else { return }
        guard !isWritingEdits else {
            statusText = "Waiting for the edit to save before running"
            return
        }
        guard let statement = StatementSplitter.statement(at: caretOffset, in: sql, dialect: dialect) else {
            statusText = "Put the cursor in a statement to explain it"
            return
        }
        let text = TableOperations.explain(statement.text, analyze: analyze, dialect: dialect)
        let explained = SQLStatement(
            text: text, utf16Range: statement.utf16Range,
            startLine: statement.startLine, terminator: statement.terminator
        )
        start([explained])
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
        references.removeAll()
        elapsed = .zero
        startTimer()
        defer {
            isRunning = false
            timerTask?.cancel()
            // An edit that arrived while the statements ran waited; it goes now.
            if let scope = writeAfterRun {
                writeAfterRun = nil
                enqueueWrite(scope, on: writeTarget ?? selectedResult)
            }
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
                let source = sourceTable(for: statement.text, session: session)
                let editing = await editTarget(for: source, session: session)
                let grid = GridModel(
                    source: .query(statement.text), dialect: dialect, loader: loader,
                    identityColumns: editing?.key ?? [], identityKind: editing?.keyKind)
                grid.isPaged = true
                await grid.load(page: 0)
                if let failure = grid.lastError { throw failure }
                // The foreign keys of the tables the statement reads, joined or not, so a
                // cell can be followed to the row it points at as on a table tab.
                let read = readTables(in: statement.text, session: session)
                if !read.isEmpty {
                    let support = ReferenceSupport(
                        environment: environment, connectionID: connectionID, dialect: dialect)
                    await support.load(tables: read, columns: grid.columns, session: session)
                    if !support.foreignKeys.isEmpty { references[result.id] = support }
                }
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
                        sql: SQLRedactor.redactSecrets(statement.text), startedAt: startedAt, duration: duration,
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
            // History is written to disk: a password inside `CREATE USER` must not go with it.
            await environment.recordHistory(
                QueryHistoryEntry(
                    connectionID: connectionID, database: session.config.database,
                    sql: SQLRedactor.redactSecrets(statement.text), startedAt: startedAt, duration: duration,
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
                    sql: SQLRedactor.redactSecrets(statement.text), startedAt: startedAt,
                    duration: clockStart.duration(to: .now),
                    error: SQLRedactor.redactSecrets(banner.message), succeeded: false
                ))
            bumpRevision()
            return true
        }
    }

    /// The one table a SELECT reads, resolved against the tab's database, or nil when the
    /// statement joins, aggregates or is not a SELECT.
    private func sourceTable(for sql: String, session: ConnectionSession) -> TableRef? {
        guard let match = QuerySourceTable.detect(sql, dialect: dialect) else { return nil }
        return tableRef(schema: match.schema, name: match.name, session: session)
    }

    /// Every table the statement reads (FROM, JOIN, a comma list), each once, resolved
    /// against the tab's database; what a result's foreign keys can come from.
    private func readTables(in sql: String, session: ConnectionSession) -> [TableRef] {
        var seen: Set<String> = []
        var tables: [TableRef] = []
        for mention in SQLCompletionContext.tableMentions(in: sql, dialect: dialect) {
            let table = tableRef(schema: mention.schema, name: mention.name, session: session)
            if seen.insert(table.id).inserted { tables.append(table) }
        }
        return tables
    }

    /// A table named in a statement, with the schema or database the statement left out
    /// filled in from the tab's session.
    private func tableRef(schema: String?, name: String, session: ConnectionSession) -> TableRef {
        let database = session.config.database ?? ""
        switch dialect {
        case .mysql:
            return TableRef(schema: SchemaRef.mysql(schema ?? sessionDatabase ?? database), name: name)
        case .sqlite:
            // One schema, `main`, unless the statement names an attached database.
            let schema = schema ?? SchemaRef.sqliteMainSchema
            return TableRef(database: schema, schema: schema, name: name)
        case .postgresql:
            return TableRef(database: database, schema: schema ?? sessionDatabase ?? "public", name: name)
        }
    }

    /// What editing a result over `table` would write to, when the table's key can be
    /// looked up; nil means the rows stay read-only.
    private func editTarget(
        for table: TableRef?, session: ConnectionSession
    ) async -> (
        table: TableRef, key: [String], keyKind: DBValueKind?, columns: Set<String>, tableOID: String
    )? {
        guard let table else { return nil }
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

    /// Drops every pending edit on the selected result. Refused while a write is on the
    /// server: what is on the wire will land whatever the grid shows.
    public func discardEdits() {
        guard !isWritingEdits else { return }
        selectedResult?.grid?.edits.discardAll()
        bumpRevision()
    }

    /// Pending edits on any result, not just the selected one; what closing the tab asks about.
    public var hasPendingEdits: Bool {
        results.contains { ($0.grid?.edits.pendingStatementCount ?? 0) > 0 }
    }

    public func setSelectionNull() {
        guard let grid = selectedResult?.grid, grid.isEditable else { return }
        for row in selection.rows(totalRows: grid.displayRowCount) {
            for column in selection.columns(totalColumns: grid.columns.count) {
                grid.setValue(.null, row: row, column: column)
            }
        }
        bumpRevision()
        writeIfAutoCommit(.loadedRowsOnly)
    }

    public func deleteSelectedRows() {
        guard let grid = selectedResult?.grid, grid.isEditable else { return }
        grid.markDeleted(rows: selection.rows(totalRows: grid.displayRowCount))
        bumpRevision()
        writeIfAutoCommit(.loadedRowsOnly)
    }

    // MARK: - Auto-commit of result edits

    /// True while a write of result edits is on the server.
    public private(set) var isWritingEdits = false
    @ObservationIgnored private var writeTask: Task<Void, Never>?
    @ObservationIgnored private var queuedWrite: CommitScope?
    /// The result whose edits the write task is committing.
    @ObservationIgnored private var writeTarget: QueryResultTab?
    /// A write asked for while statements were running; it goes when they finish, since
    /// both would use the tab's one held connection.
    @ObservationIgnored private var writeAfterRun: CommitScope?
    @ObservationIgnored private var lastCommitMessage: String?

    /// With auto-commit on, an edit to a result is written as it is made, one write at a
    /// time; an edit made during a write follows it. Off, edits wait for Commit.
    private func writeIfAutoCommit(_ scope: CommitScope) {
        guard autoCommitsEdits, let result = selectedResult, let grid = result.grid,
            grid.edits.pendingStatementCount(scope) > 0
        else { return }
        enqueueWrite(scope, on: result)
    }

    /// The one gate every commit of result edits goes through — auto-commit, Retry, the
    /// ⌘⇧S sheet — so two never run at once and never beside a running statement, which
    /// would share the held connection. The page is re-read once the queue drains.
    @discardableResult
    private func enqueueWrite(_ scope: CommitScope, on result: QueryResultTab?) -> Task<Void, Never> {
        if let writeTask {
            queuedWrite = (queuedWrite == .everything || scope == .everything) ? .everything : .loadedRowsOnly
            return writeTask
        }
        if isRunning {
            writeAfterRun = (writeAfterRun == .everything || scope == .everything) ? .everything : .loadedRowsOnly
            return runTask.map { task in Task { await task.value } } ?? Task {}
        }
        guard let result, let grid = result.grid else { return Task {} }
        isWritingEdits = true
        writeTarget = result
        let task = Task { [weak self] in
            guard let self else { return }
            var initial: CommitScope? = scope
            repeat {
                var current = initial
                initial = nil
                var failed = false
                while let scope = current {
                    current = nil
                    if grid.edits.pendingStatementCount(scope) > 0, !(await performCommitEdits(scope, on: result)) {
                        failed = true
                        break
                    }
                    current = queuedWrite
                    queuedWrite = nil
                }
                if failed {
                    queuedWrite = nil
                    break
                }
                await grid.reload(keepingNewRows: !grid.edits.pendingInserts.isEmpty)
                result.message = Self.pageMessage(grid, exactTotal: result.exactTotal, duration: .zero)
                bumpRevision()
                initial = queuedWrite
                queuedWrite = nil
            } while initial != nil
            isWritingEdits = false
            writeTarget = nil
            writeTask = nil
        }
        writeTask = task
        return task
    }

    /// A new row goes when the user leaves it; one left untouched holds nothing and is
    /// dropped. Not while a write is on the server, whose reload briefly empties the grid.
    private func flushNewRowsIfLeft(focusRow: Int) {
        guard autoCommitsEdits, !isWritingEdits, let grid = selectedResult?.grid,
            !grid.edits.pendingInserts.isEmpty, !grid.isPendingInsertRow(focusRow)
        else { return }
        for insert in grid.edits.pendingInserts where insert.values.isEmpty {
            grid.edits.removeInsert(id: insert.id)
        }
        bumpRevision()
        writeIfAutoCommit(.everything)
    }

    public func addRow() {
        guard let grid = selectedResult?.grid, grid.isEditable, grid.addRow() != nil else { return }
        // Focus moves into the new row, so it is not flushed as untouched on the next click.
        selection = GridSelection(row: grid.displayRowCount - 1, column: 0)
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
    public func commitEdits(_ scope: CommitScope = .everything) async -> String? {
        guard let result = selectedResult, let grid = result.grid, grid.isEditable else { return nil }
        lastCommitMessage = nil
        await enqueueWrite(scope, on: result).value
        return lastCommitMessage ?? errorBanner?.message
    }

    /// Runs one commit of `result`'s edits. Returns false when the server refused it; the
    /// edits stay put and the banner says why.
    private func performCommitEdits(_ scope: CommitScope, on result: QueryResultTab) async -> Bool {
        guard let grid = result.grid, let session else { return false }
        if await session.isReadOnly {
            errorBanner = QueryErrorBanner(
                error: DBError.protocolError("This connection is read-only. Unlock it with ⌘⇧L to write."),
                statement: result.statement)
            bumpRevision()
            return false
        }
        do {
            let connection = try await connectionForRun(session: session)
            // A transaction the user opened by hand (BEGIN as a statement) is theirs to
            // commit: the edit joins it under a savepoint rather than committing it.
            let runner = HeldConnectionRunner(connection: connection, usesSavepoint: !autoCommit || isInTransaction)
            let committed = try await grid.commit(using: runner, scope: scope)
            isInTransaction = await connection.isInTransaction
            if committed.statementCount > 0 {
                lastCommitMessage =
                    "Committed \(committed.statementCount) statement\(committed.statementCount == 1 ? "" : "s")"
                    + (isInTransaction ? " into the open transaction" : "")
            }
            bumpRevision()
            return true
        } catch let error as GridCommitError {
            errorBanner = QueryErrorBanner(error: error, statement: error.statement ?? result.statement)
            bumpRevision()
            return false
        } catch {
            errorBanner = QueryErrorBanner(error: error, statement: result.statement)
            bumpRevision()
            return false
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
            await session.applyReadOnlyGuard(to: heldConnection)
            // Auto-commit was turned off after this connection was taken: the next statement
            // is the first of a transaction, so one is opened here rather than never.
            if !commitsAutomatically, !isInTransaction {
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
        if !commitsAutomatically {
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
        let sql: String
        switch dialect {
        case .mysql: sql = "USE \(quoted)"
        // PostgreSQL cannot change database on an open connection; unqualified names
        // resolve against the search path, which it can change.
        case .postgresql: sql = "SET search_path TO \(quoted)"
        // A SQLite connection is one file; unqualified names already resolve in `main`.
        case .sqlite: return
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
        case .sqlite:
            result.profileNote = "SQLite has no profiler. Use Explain for the query plan."
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
            case .sqlite:
                // No session counters in a file; the pragmas that describe it stand in.
                """
                SELECT 'page_size' AS name, page_size AS value FROM pragma_page_size
                UNION ALL SELECT 'page_count', page_count FROM pragma_page_count
                UNION ALL SELECT 'freelist_count', freelist_count FROM pragma_freelist_count
                UNION ALL SELECT 'journal_mode', journal_mode FROM pragma_journal_mode
                UNION ALL SELECT 'foreign_keys', foreign_keys FROM pragma_foreign_keys
                UNION ALL SELECT 'encoding', encoding FROM pragma_encoding
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
            case .mysql, .sqlite:
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
                    switch dialect {
                    case .mysql: environment.connections.first { $0.id == connectionID }?.database
                    case .sqlite: SchemaRef.sqliteMainSchema
                    case .postgresql: availableDatabases.first { $0 == "public" } ?? availableDatabases.first
                    }
            }
        } catch {
            statusText = (error as? DBError)?.errorDescription ?? String(describing: error)
        }
    }

    /// Switches the tab to another database or schema, reporting what the server said if
    /// it refuses. The picker keeps the previous choice on failure.
    public func selectDatabase(_ name: String) async {
        // Columns being read for the old schema must not land under the new one.
        warmTask?.cancel()
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
        warmTask?.cancel()
        await releaseHeldConnection()
        connectionID = id
        dialect = config.dialect
        sessionDatabase = nil
        availableDatabases = []
        results.removeAll()
        references.removeAll()
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
        // Matching is fuzzy: `kel` finds `aset_kelompok`, `ak` too. The ranking at the
        // end puts the best fit first; here the buckets only drop what cannot match.
        func matches(_ candidate: CompletionCandidate) -> Bool {
            lowered.isEmpty || FuzzyMatch.matches(lowered, in: candidate.text)
        }
        let keywords =
            lowered.isEmpty
            ? []
            : SQLTokenizer.keywords
                .filter { FuzzyMatch.matches(lowered, in: $0) }
                .sorted()
                .map { CompletionCandidate(text: $0, kind: .keyword) }
        // The engine's functions, once a letter is typed: `DA` offers DATE, DATE_FORMAT,
        // DAY, DAYNAME… with their signatures, the way a person looks for them.
        let functions =
            lowered.isEmpty
            ? []
            : SQLFunctionCatalog.functions(for: dialect)
                .filter { FuzzyMatch.matches(lowered, in: $0.name) }
                .sorted { $0.name.lowercased() < $1.name.lowercased() }
                .map { CompletionCandidate(function: $0) }

        var ranked: [CompletionCandidate]
        switch context.expecting {
        case .tables:
            ranked = completionTables.filter(matches) + completionSchemas.filter(matches)
            if ranked.isEmpty { ranked = keywords }
        case .columns:
            ranked = columnCandidates(for: context.tables, matching: lowered) + functions + keywords
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
            ranked = lowered.isEmpty ? [] : keywords + completionTables.filter(matches) + functions
        }
        // What was typed in full, then the everyday keywords (`fro` is FROM before
        // FROM_BASE64), then the rest by fit, each bucket keeping its order; the cap then
        // never hides what the context asked for.
        ranked = SQLCompletionRanking.order(ranked, prefix: lowered, text: \.text, isKeyword: { $0.kind == .keyword })
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
            for column in columns where lowered.isEmpty || FuzzyMatch.matches(lowered, in: column.name) {
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
        if let mentions, !mentions.isEmpty, mentions.allSatisfy({ warmingKeys.contains(cacheKey(for: $0)) }) {
            return  // Already on its way.
        }
        warmTask?.cancel()
        warmingKeys = Set((mentions ?? []).map(cacheKey(for:)))
        warmGeneration &+= 1
        let generation = warmGeneration
        warmTask = Task { [weak self] in
            defer {
                if let self, self.warmGeneration == generation { self.warmingKeys.removeAll() }
            }
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
    ///
    /// The connection, schema and session are fixed at entry: a switch while a read is in
    /// flight bumps `completionGeneration`, and what arrives after that is dropped rather
    /// than filed under the new connection's key. A table that cannot be read is cached
    /// as empty for this generation, so typing does not re-ask the server every pause.
    private func warmColumns(of mentions: [SQLTableMention]) async -> Bool {
        guard let session else { return false }
        let generation = completionGeneration
        let keys = mentions.map { (mention: $0, key: cacheKey(for: $0)) }
        var loaded = false
        for (mention, key) in keys {
            guard cachedColumns[key] == nil else { continue }
            let ref = TableRef(schema: schemaRef(key.schema), name: mention.name)
            let columns = try? await session.introspection(.columns(ref), load: { try await $0.columns(of: ref) })
            guard generation == completionGeneration, !Task.isCancelled else { return loaded }
            cachedColumns[key] = columns ?? []
            if columns != nil { loaded = true }
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

    /// The row the grid asked to see on the map; the view switches to the map for it.
    public var mapRequest: MapRequest?

    public func gridDidRequestShowOnMap(row: Int, column: Int) {
        mapRequest = MapRequest(row: row, column: column)
    }

    public func gridDidChangeSelection(_ selection: GridSelection) {
        self.selection = selection
        flushNewRowsIfLeft(focusRow: selection.focusRow)
    }
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
        if !grid.isPendingInsertRow(row) { writeIfAutoCommit(.loadedRowsOnly) }
    }
    public func gridDidRequestInspector() { onRequestInspector?() }
    /// Set by the tab view; the grid asks for the inspector with the space bar.
    @ObservationIgnored public var onRequestInspector: (() -> Void)?
    /// Set by the tab view; the grid's context menu asks to follow a foreign key.
    @ObservationIgnored public var onFollowReference: ((TableRef, [FilterRule]) -> Void)?

    // MARK: Foreign keys of a single-table result

    /// The foreign key a cell takes part in and the filter that finds the referenced row.
    public func referenceTarget(row: Int, column: Int) -> (table: TableRef, filter: [FilterRule])? {
        guard let grid = selectedResult?.grid, let references = selectedReferences else { return nil }
        return references.target(row: row, column: column, in: grid)
    }

    public func gridHasReference(row: Int, column: Int) -> Bool {
        referenceTarget(row: row, column: column) != nil
    }

    public func gridDidRequestFollowReference(row: Int, column: Int) {
        guard let target = referenceTarget(row: row, column: column) else { return }
        onFollowReference?(target.table, target.filter)
    }

    public func gridColumnReferences(_ column: Int) -> Bool {
        guard let grid = selectedResult?.grid, let references = selectedReferences else { return false }
        return references.columnReferences(column, in: grid)
    }

    public func gridReferencePicker(row: Int, column: Int) -> ReferencePickerModel? {
        guard let grid = selectedResult?.grid, let session, let references = selectedReferences else { return nil }
        return references.picker(row: row, column: column, in: grid, session: session) { [weak self] in
            self?.bumpRevision()
        }
    }

    public func gridDidPickReference(row: Int, column: Int, key: [String: DBValue]) {
        guard let grid = selectedResult?.grid, let references = selectedReferences,
            references.apply(key: key, row: row, column: column, in: grid)
        else { return }
        bumpRevision()
        if !grid.isPendingInsertRow(row) { writeIfAutoCommit(.loadedRowsOnly) }
    }

    public func gridReferenceLabel(row: Int, column: Int) -> String? {
        guard let grid = selectedResult?.grid, let references = selectedReferences else { return nil }
        return references.label(row: row, column: column, in: grid)
    }

    /// Asks the grid to open the foreign-key picker over a cell, for the inspector's
    /// Choose button. The grid owns the popover so it can anchor to the real cell.
    public func requestReferencePicker(column: Int) {
        NotificationCenter.default.post(
            name: .tinkerPresentReferencePicker, object: self,
            userInfo: ["row": selection.focusRow, "column": column]
        )
    }
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
