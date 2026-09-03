import DBCore
import DBSQL
import Foundation

/// What a grid is showing.
public enum GridSource: Sendable, Hashable {
    /// A table or view, paged and sortable server-side, editable when it has a row identity.
    case table(TableRef)
    /// The result of a statement, streamed and read-only.
    case query(String)
}

/// A page the grid asked for.
public struct PageRequest: Sendable, Hashable {
    public let page: Int
    public let strategy: PagingStrategy
    /// Last key value already loaded, for a keyset page.
    public let keysetAnchor: DBValue?
    public let sort: [PagePlanner.SortTerm]
    public let filter: [FilterRule]

    public init(
        page: Int,
        strategy: PagingStrategy,
        keysetAnchor: DBValue? = nil,
        sort: [PagePlanner.SortTerm] = [],
        filter: [FilterRule] = []
    ) {
        self.page = page
        self.strategy = strategy
        self.keysetAnchor = keysetAnchor
        self.sort = sort
        self.filter = filter
    }
}

/// Rows and their description, as returned for one page.
public struct LoadedPage: Sendable {
    public let columns: [ColumnMeta]
    public let rows: [[DBValue]]

    public init(columns: [ColumnMeta], rows: [[DBValue]]) {
        self.columns = columns
        self.rows = rows
    }
}

/// Fetches pages for a grid. Implemented by the app over a connection session, and by
/// tests over fixed data.
public protocol GridDataLoader: Sendable {
    func loadPage(_ request: PageRequest) async throws -> LoadedPage
    /// Exact row count for the current filter, when the user asks for one.
    func exactCount(filter: [FilterRule]) async throws -> Int64
}

/// The grid's data model: what is loaded, what is pending, and what to fetch next.
///
/// It is `@MainActor` because the table view reads it directly during drawing; every
/// fetch it starts hops off the main actor and comes back (SPEC §12.1).
@MainActor
public final class GridModel {
    public private(set) var columns: [ColumnMeta] = []
    public private(set) var buffer: RowBuffer
    public var edits = EditBuffer()

    /// Rows known to exist. Grows as pages arrive and is exact once ``isExhausted``.
    public private(set) var rowCount = 0
    /// Exact total when it has been counted, else nil.
    public private(set) var totalCount: Int64?
    /// True once a short page proved there is nothing more.
    public private(set) var isExhausted = false
    /// The planner's estimate, used to size the scrollbar before an exact count exists.
    public var estimatedTotal: Int64?
    public private(set) var lastError: (any Error)?

    public let source: GridSource
    public let dialect: SQLDialect
    /// Columns that identify a row. Empty means the grid is read-only.
    public private(set) var identityColumns: [String] = []
    public private(set) var identityKind: DBValueKind?

    public var sort: [PagePlanner.SortTerm] = []
    public var filter: [FilterRule] = []

    private let loader: any GridDataLoader
    private let planner: PagePlanner?
    private var loadingPages: Set<Int> = []

    public init(
        source: GridSource,
        dialect: SQLDialect,
        loader: any GridDataLoader,
        columns: [ColumnMeta] = [],
        identityColumns: [String] = [],
        identityKind: DBValueKind? = nil,
        buffer: RowBuffer = RowBuffer()
    ) {
        self.source = source
        self.dialect = dialect
        self.loader = loader
        self.columns = columns
        self.identityColumns = identityColumns
        self.identityKind = identityKind
        self.buffer = buffer
        planner = if case let .table(table) = source {
            PagePlanner(dialect: dialect, table: table)
        } else {
            nil
        }
    }

    /// How many rows the table view should claim, including the pending new rows.
    ///
    /// Before an exact count exists the estimate sizes the scrollbar, so dragging it to
    /// the end works on a table nobody has counted (SPEC §12.6).
    public var displayRowCount: Int {
        let known = if let total = totalCount {
            Int(total)
        } else if let estimate = estimatedTotal, estimate > Int64(rowCount) {
            Int(estimate)
        } else {
            rowCount
        }
        return known + edits.pendingInserts.count
    }

    /// True when `row` is one of the rows the user is adding rather than a loaded row.
    public func isPendingInsertRow(_ row: Int) -> Bool {
        let base = displayRowCount - edits.pendingInserts.count
        return row >= base && row < displayRowCount
    }

    /// The pending insert shown at `row`, if that row is one.
    public func pendingInsert(at row: Int) -> PendingInsert? {
        let base = displayRowCount - edits.pendingInserts.count
        let offset = row - base
        guard offset >= 0, offset < edits.pendingInserts.count else { return nil }
        return edits.pendingInserts[offset]
    }

    /// True when the grid may be edited: it shows a table that has a row identity.
    public var isEditable: Bool {
        if case .table = source { return !identityColumns.isEmpty }
        return false
    }

    /// Why editing is unavailable, for the status bar.
    public var readOnlyReason: String? {
        switch source {
        case .query: "Query results are read-only"
        case .table: identityColumns.isEmpty ? "No primary key — read only" : nil
        }
    }

    // MARK: - Reading

    /// The value to draw, reading the edit overlay first.
    public func value(row: Int, column: Int) -> DBValue? {
        guard column < columns.count else { return nil }
        if let insert = pendingInsert(at: row) {
            return insert.values[columns[column].name] ?? .null
        }
        guard let loaded = buffer.row(at: row), column < loaded.count else { return nil }
        return edits.value(row: row, column: columns[column].name, loaded: loaded[column])
    }

    /// The row as loaded, ignoring pending edits.
    public func loadedRow(_ row: Int) -> [DBValue]? { buffer.row(at: row) }

    public func changeState(row: Int, column: Int) -> CellChangeState {
        guard column < columns.count else { return .unchanged }
        if isPendingInsertRow(row) { return .inserted }
        return edits.state(row: row, column: columns[column].name)
    }

    public func rowChangeState(_ row: Int) -> CellChangeState {
        if isPendingInsertRow(row) { return .inserted }
        return edits.rowState(row)
    }

    /// The identity values of a loaded row, as loaded.
    public func identity(ofRow row: Int) -> [String: DBValue]? {
        guard let loaded = buffer.row(at: row) else { return nil }
        var identity: [String: DBValue] = [:]
        for name in identityColumns {
            guard let index = columns.firstIndex(where: { $0.name == name }), index < loaded.count else {
                return nil
            }
            identity[name] = loaded[index]
        }
        return identity.isEmpty ? nil : identity
    }

    // MARK: - Loading

    /// The order pages are actually fetched in.
    ///
    /// Without an `ORDER BY`, `LIMIT`/`OFFSET` reads rows in whatever order the server
    /// finds them, so paging would repeat and skip rows. When the user has not chosen a
    /// sort, the row identity supplies a stable one.
    public var effectiveSort: [PagePlanner.SortTerm] {
        if !sort.isEmpty { return sort }
        return identityColumns.map { PagePlanner.SortTerm(column: $0, ascending: true) }
    }

    /// The paging strategy for a given page, so the status bar can explain it.
    ///
    /// A keyset cursor can only continue from a row already in hand, so it is used when
    /// the planner allows it *and* the preceding page is loaded. Dragging the scrollbar
    /// into unloaded territory falls back to `OFFSET`, which can position anywhere.
    public func strategy(forPage page: Int) -> PagingStrategy {
        let preferred = planner?.strategy(
            page: page, userSort: sort,
            identityColumns: identityColumns, identityKind: identityKind
        ) ?? .offset
        guard case let .keyset(column) = preferred else { return .offset }
        return keysetAnchor(forPage: page, column: column) == nil ? .offset : preferred
    }

    /// The key value of the last row before `page`, which is where a keyset page resumes.
    func keysetAnchor(forPage page: Int, column: String) -> DBValue? {
        guard page > 0,
              let index = columns.firstIndex(where: { $0.name == column }),
              let previous = buffer.row(at: page * buffer.pageSize - 1),
              index < previous.count
        else { return nil }
        return previous[index]
    }

    /// Loads whatever `range` needs and returns once it is resident.
    ///
    /// Pages already in flight are not requested twice, so scrolling quickly through a
    /// large table does not pile up duplicate queries.
    public func ensureLoaded(range: Range<Int>) async {
        guard !range.isEmpty else { return }
        buffer.noteViewport(page: buffer.page(containing: range.lowerBound))
        let missing = buffer.missingPages(for: range).filter { !loadingPages.contains($0) }
        guard !missing.isEmpty else { return }
        for page in missing {
            await load(page: page)
        }
    }

    /// Loads one page, ignoring a request for a page already in flight.
    public func load(page: Int) async {
        guard !loadingPages.contains(page) else { return }
        loadingPages.insert(page)
        defer { loadingPages.remove(page) }

        let strategy = strategy(forPage: page)
        var anchor: DBValue?
        if case let .keyset(column) = strategy { anchor = keysetAnchor(forPage: page, column: column) }
        let request = PageRequest(
            page: page, strategy: strategy, keysetAnchor: anchor,
            sort: effectiveSort, filter: filter
        )
        do {
            let loaded = try await loader.loadPage(request)
            if columns.isEmpty { columns = loaded.columns }
            buffer.store(page: page, rows: loaded.rows)
            let end = page * buffer.pageSize + loaded.rows.count
            rowCount = max(rowCount, end)
            if loaded.rows.count < buffer.pageSize {
                isExhausted = true
                totalCount = Int64(rowCount)
            }
            lastError = nil
        } catch {
            lastError = error
        }
    }

    /// Appends streamed rows, for a query result rather than a paged table.
    public func appendStreamed(columns newColumns: [ColumnMeta], batch: RowBatch) {
        if columns.isEmpty { columns = newColumns }
        buffer.append(batch.rows, startingAt: batch.startIndex)
        rowCount = max(rowCount, batch.startIndex + batch.rows.count)
    }

    public func markStreamComplete() {
        isExhausted = true
        totalCount = Int64(rowCount)
    }

    /// True when the stream has produced as many rows as the buffer will hold, which is
    /// where the app offers "Load more", "Export to file" or "Cancel" (SPEC §12.1).
    public var hasReachedMemoryCap: Bool {
        rowCount >= buffer.rowCapacity
    }

    /// Counts rows for the current filter.
    public func loadExactCount() async {
        do {
            totalCount = try await loader.exactCount(filter: filter)
        } catch {
            lastError = error
        }
    }

    /// Throws away every loaded row and starts again from page 0. Pending edits are
    /// discarded too, because their row indices no longer mean anything.
    public func reload() async {
        buffer.removeAll()
        edits.discardAll()
        rowCount = 0
        totalCount = nil
        isExhausted = false
        loadingPages.removeAll()
        await load(page: 0)
    }

    /// Applies a new sort and reloads from the first page, as server-side sorting requires.
    public func setSort(_ terms: [PagePlanner.SortTerm]) async {
        sort = terms
        await reload()
    }

    public func setFilter(_ rules: [FilterRule]) async {
        filter = rules
        await reload()
    }

    /// Cycles one column's sort: none → ascending → descending → none.
    public func cycleSort(column: String, additive: Bool) async {
        var terms = additive ? sort : sort.filter { $0.column == column }
        if let index = terms.firstIndex(where: { $0.column == column }) {
            if terms[index].ascending {
                terms[index] = PagePlanner.SortTerm(column: column, ascending: false)
            } else {
                terms.remove(at: index)
            }
        } else {
            terms.append(PagePlanner.SortTerm(column: column, ascending: true))
        }
        await setSort(terms)
    }

    // MARK: - Editing

    /// Records a cell edit, if the grid is editable.
    @discardableResult
    public func setValue(_ value: DBValue, row: Int, column: Int) -> Bool {
        guard isEditable, column < columns.count else { return false }
        if let insert = pendingInsert(at: row) {
            edits.setInsertValue(value, id: insert.id, column: columns[column].name)
            return true
        }
        guard
            let loaded = buffer.row(at: row), column < loaded.count,
            let identity = identity(ofRow: row)
        else { return false }
        edits.setValue(
            value, row: row, column: columns[column].name,
            loaded: loaded[column], identity: identity
        )
        return true
    }

    @discardableResult
    public func markDeleted(rows: [Int]) -> Bool {
        guard isEditable else { return false }
        for row in rows {
            if let insert = pendingInsert(at: row) {
                edits.removeInsert(id: insert.id)
                continue
            }
            guard let identity = identity(ofRow: row) else { continue }
            edits.markDeleted(row: row, identity: identity)
        }
        return true
    }

    /// Adds an empty row at the end for the user to fill in.
    @discardableResult
    public func addRow() -> PendingInsert? {
        guard isEditable else { return nil }
        return edits.addInsert()
    }

    /// The statements a commit would run, for the preview sheet.
    public func pendingStatements() throws -> [GeneratedStatement] {
        guard case let .table(table) = source else { return [] }
        let generator = DMLGenerator(dialect: dialect, table: table, identityColumns: identityColumns)
        return try edits.statements(using: generator)
    }

    /// Runs the pending statements and, on success, clears the buffer and refreshes the
    /// rows that changed. On any failure nothing is written and the edits stay put.
    @discardableResult
    public func commit(using runner: any GridStatementRunner) async throws -> CommitResult {
        let statements = try pendingStatements()
        let result = try await GridCommitter().commit(statements, using: runner)
        edits.discardAll()
        return result
    }
}
