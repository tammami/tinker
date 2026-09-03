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

    public let connectionID: UUID
    public let dialect: SQLDialect
    private let environment: AppEnvironment
    private var runTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    /// The connection held while a transaction is open, so `COMMIT` reaches the same one.
    private var heldLease: ConnectionSession.Lease?
    private var heldConnection: (any SQLConnection)?
    private var schemaNames: [CompletionCandidate] = []

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

    /// Loads the schema names autocomplete offers.
    public func loadCompletionSources() async {
        guard let session else { return }
        var candidates: [CompletionCandidate] = []
        let database = session.config.database ?? ""
        if let schemas = try? await session.introspection(.schemas(database: database), load: {
            try await $0.schemas(in: database)
        }) {
            for schema in schemas where !schema.isSystem {
                candidates.append(CompletionCandidate(text: schema.name, kind: .schema))
                if let tables = try? await session.introspection(.tables(schema.ref), load: {
                    try await $0.tables(in: schema.ref)
                }) {
                    for table in tables {
                        candidates.append(CompletionCandidate(
                            text: table.name, detail: table.kind.rawValue, kind: .table
                        ))
                    }
                }
            }
        }
        schemaNames = candidates
    }

    // MARK: - Running

    /// Runs the statement under the cursor, the selection, or every statement.
    public func run(all: Bool, selectedRange: Range<Int>? = nil) {
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
                result.message = "\(completion?.serverTag ?? "OK") — \(affected) row\(affected == 1 ? "" : "s") in \(Self.format(duration))"
            } else {
                result.message = "\(rowTotal) row\(rowTotal == 1 ? "" : "s") in \(Self.format(duration))"
            }
            await environment.recordHistory(QueryHistoryEntry(
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
            await environment.recordHistory(QueryHistoryEntry(
                connectionID: connectionID, database: session.config.database,
                sql: statement.text, startedAt: startedAt,
                duration: clockStart.duration(to: .now),
                error: banner.message, succeeded: false
            ))
            bumpRevision()
            return true
        }
    }

    /// The connection a statement runs on: the held one when a transaction is open, else
    /// a fresh lease returned as soon as the statement finishes.
    private func connectionForRun(session: ConnectionSession) async throws -> any SQLConnection {
        if let heldConnection { return heldConnection }
        let (lease, connection) = try await session.lease()
        if autoCommit {
            // Returned once the statement's stream is drained; the lease is released by
            // `releaseHeldConnection` when the tab closes or auto-commit turns back on.
            heldLease = lease
            heldConnection = connection
        } else {
            heldLease = lease
            heldConnection = connection
            try await connection.beginTransaction()
            isInTransaction = true
        }
        return connection
    }

    public func setAutoCommit(_ enabled: Bool) async {
        autoCommit = enabled
        if enabled, isInTransaction { await commitTransaction() }
    }

    public func commitTransaction() async {
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
        let milliseconds = Double(duration.components.seconds) * 1_000
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
    }

    public func editorDidChangeSelection(offset: Int) {
        caretOffset = offset
    }

    public func editorDidRequestRun(all: Bool) {
        run(all: all)
    }

    /// Keywords, then tables, then the columns of tables the statement mentions.
    ///
    /// Alias-aware: `FROM users u` makes `u.` offer users' columns (SPEC §13.1).
    public func editorCompletionCandidates(prefix: String, statement: String) -> [CompletionCandidate] {
        let lowered = prefix.lowercased()
        var candidates: [CompletionCandidate] = []

        if let dotIndex = prefix.lastIndex(of: ".") {
            let qualifier = String(prefix[prefix.startIndex ..< dotIndex])
            let tail = String(prefix[prefix.index(after: dotIndex)...]).lowercased()
            let tableName = Self.resolveAlias(qualifier, in: statement, dialect: dialect) ?? qualifier
            return columnCandidates(forTable: tableName)
                .filter { tail.isEmpty || $0.text.lowercased().hasPrefix(tail) }
        }

        candidates += SQLTokenizer.keywords
            .filter { $0.lowercased().hasPrefix(lowered) }
            .sorted()
            .map { CompletionCandidate(text: $0, kind: .keyword) }
        candidates += schemaNames.filter { $0.text.lowercased().hasPrefix(lowered) }
        for table in Self.tablesMentioned(in: statement, dialect: dialect) {
            candidates += columnCandidates(forTable: table)
                .filter { lowered.isEmpty || $0.text.lowercased().hasPrefix(lowered) }
        }
        // Prefix matches first, then everything else, as the spec's ranking requires.
        return Array(candidates.prefix(60))
    }

    private func columnCandidates(forTable name: String) -> [CompletionCandidate] {
        cachedColumns[name]?.map {
            CompletionCandidate(text: $0.name, detail: $0.nativeType, kind: .column)
        } ?? []
    }

    /// Columns per table, filled in as statements name tables.
    private var cachedColumns: [String: [ColumnInfo]] = [:]

    /// Reads the columns of every table the statement mentions, for autocomplete.
    public func warmColumnCache(for statement: String) async {
        guard let session else { return }
        let database = session.config.database ?? ""
        for name in Self.tablesMentioned(in: statement, dialect: dialect) where cachedColumns[name] == nil {
            let ref = TableRef(database: database, schema: dialect == .mysql ? database : "public", name: name)
            if let columns = try? await session.introspection(.columns(ref), load: {
                try await $0.columns(of: ref)
            }) {
                cachedColumns[name] = columns
            }
        }
    }

    /// Table names appearing after FROM, JOIN, INTO or UPDATE.
    static func tablesMentioned(in statement: String, dialect: SQLDialect) -> [String] {
        let tokens = SQLTokenizer.tokenize(statement, dialect: dialect).filter { $0.kind != .whitespace }
        var names: [String] = []
        for (index, token) in tokens.enumerated() where token.kind == .keyword {
            let keyword = token.text.uppercased()
            guard ["FROM", "JOIN", "INTO", "UPDATE", "TABLE"].contains(keyword),
                  index + 1 < tokens.count
            else { continue }
            let next = tokens[index + 1]
            guard next.kind == .identifier || next.kind == .quotedIdentifier else { continue }
            names.append(Identifier.unquote(next.text, dialect: dialect))
        }
        return names
    }

    /// The table an alias refers to: `FROM users u` maps `u` to `users`.
    static func resolveAlias(_ alias: String, in statement: String, dialect: SQLDialect) -> String? {
        let tokens = SQLTokenizer.tokenize(statement, dialect: dialect).filter { $0.kind != .whitespace }
        for (index, token) in tokens.enumerated() where token.kind == .keyword {
            guard ["FROM", "JOIN", "UPDATE"].contains(token.text.uppercased()), index + 1 < tokens.count else {
                continue
            }
            let table = tokens[index + 1]
            guard table.kind == .identifier || table.kind == .quotedIdentifier else { continue }
            // `FROM users u` or `FROM users AS u`.
            var aliasIndex = index + 2
            if aliasIndex < tokens.count, tokens[aliasIndex].text.uppercased() == "AS" { aliasIndex += 1 }
            guard aliasIndex < tokens.count else { continue }
            let candidate = tokens[aliasIndex]
            if candidate.kind == .identifier, candidate.text.caseInsensitiveCompare(alias) == .orderedSame {
                return Identifier.unquote(table.text, dialect: dialect)
            }
            if table.text.caseInsensitiveCompare(alias) == .orderedSame {
                return Identifier.unquote(table.text, dialect: dialect)
            }
        }
        return nil
    }

    // MARK: - DataGridDelegate

    public func gridDidChangeSelection(_ selection: GridSelection) { self.selection = selection }
    public func gridDidRequestLoad(range: Range<Int>) {}
    public func gridDidCommitEdit(row: Int, column: Int, text: String) {}
    public func gridDidRequestInspector() {}
    public func gridDidChangeColumnWidths(_ widths: [String: Double]) {}

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
