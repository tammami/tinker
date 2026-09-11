import DBCore
import DBSQL
import XCTest

@testable import DBGrid

/// A statement runner that answers from a script and records what it was asked to do.
actor ScriptedRunner: GridStatementRunner {
    private(set) var journal: [String] = []
    private var affectedByIndex: [Int64?]
    private var failAtIndex: Int?
    private var runCount = 0
    private var returningRows: [[DBValue]]

    init(affected: [Int64?] = [], failAt: Int? = nil, returningRows: [[DBValue]] = []) {
        affectedByIndex = affected
        failAtIndex = failAt
        self.returningRows = returningRows
    }

    func beginTransaction() async throws { journal.append("BEGIN") }
    func commitTransaction() async throws { journal.append("COMMIT") }
    func rollbackTransaction() async throws { journal.append("ROLLBACK") }

    func run(_ statement: GeneratedStatement) async throws -> StatementOutcome {
        defer { runCount += 1 }
        journal.append(statement.kind.rawValue)
        if runCount == failAtIndex {
            throw DBError.server(ServerError(sqlState: "23505", message: "duplicate key value"))
        }
        let affected = runCount < affectedByIndex.count ? affectedByIndex[runCount] : 1
        return StatementOutcome(
            affectedRows: affected,
            returnedRows: statement.kind == .insert ? returningRows : [],
            returnedColumns: statement.kind == .insert && !returningRows.isEmpty
                ? [ColumnMeta(id: 0, name: "id", nativeTypeName: "int4", kind: .int)]
                : []
        )
    }
}

final class GridCommitterTests: XCTestCase {
    let table = TableRef(database: "app", schema: "public", name: "users")

    func makeGenerator() -> DMLGenerator {
        DMLGenerator(dialect: .postgresql, table: table, identityColumns: ["id"])
    }

    func testHappyPathRunsEverythingInOneTransaction() async throws {
        let generator = makeGenerator()
        let statements = [
            try generator.update(changes: ["a": .int(1)], originalIdentity: ["id": .int(1)]),
            try generator.delete(originalIdentity: ["id": .int(2)]),
        ]
        let runner = ScriptedRunner(affected: [1, 1])
        let result = try await GridCommitter().commit(statements, using: runner)

        XCTAssertEqual(result.statementCount, 2)
        XCTAssertEqual(result.totalAffectedRows, 2)
        let journal = await runner.journal
        XCTAssertEqual(journal, ["BEGIN", "update", "delete", "COMMIT"])
    }

    /// SPEC §12.3: an UPDATE that does not touch exactly one row rolls the whole
    /// transaction back and says the data changed.
    func testWrongAffectedRowCountRollsBackEverything() async throws {
        let generator = makeGenerator()
        let statements = [
            try generator.update(changes: ["a": .int(1)], originalIdentity: ["id": .int(1)]),
            try generator.update(changes: ["a": .int(2)], originalIdentity: ["id": .int(2)]),
        ]
        let runner = ScriptedRunner(affected: [1, 0])
        do {
            _ = try await GridCommitter().commit(statements, using: runner)
            XCTFail("expected the commit to fail")
        } catch let error as GridCommitError {
            guard case let .unexpectedAffectedRows(expected, actual, statement) = error else {
                return XCTFail("expected .unexpectedAffectedRows, got \(error)")
            }
            XCTAssertEqual(expected, 1)
            XCTAssertEqual(actual, 0)
            XCTAssertTrue(statement.contains("UPDATE"))
            XCTAssertTrue(error.description.contains("data may have changed"))
        }
        let journal = await runner.journal
        XCTAssertEqual(journal, ["BEGIN", "update", "update", "ROLLBACK"])
    }

    func testAffectingMoreThanOneRowAlsoRollsBack() async throws {
        let generator = makeGenerator()
        let statements = [try generator.delete(originalIdentity: ["id": .int(1)])]
        let runner = ScriptedRunner(affected: [2])
        do {
            _ = try await GridCommitter().commit(statements, using: runner)
            XCTFail("expected the commit to fail")
        } catch let error as GridCommitError {
            guard case let .unexpectedAffectedRows(_, actual, _) = error else {
                return XCTFail("expected .unexpectedAffectedRows")
            }
            XCTAssertEqual(actual, 2)
        }
        let journal = await runner.journal
        XCTAssertTrue(journal.contains("ROLLBACK"))
    }

    func testAServerErrorRollsBackAndKeepsTheMessage() async throws {
        let generator = makeGenerator()
        let statements = [
            try generator.update(changes: ["a": .int(1)], originalIdentity: ["id": .int(1)]),
            try generator.insert(values: ["name": .string("dup")]),
        ]
        let runner = ScriptedRunner(affected: [1, 1], failAt: 1)
        do {
            _ = try await GridCommitter().commit(statements, using: runner)
            XCTFail("expected the commit to fail")
        } catch let error as GridCommitError {
            guard case let .statementFailed(statement, underlying) = error else {
                return XCTFail("expected .statementFailed, got \(error)")
            }
            XCTAssertTrue(statement.contains("INSERT"))
            XCTAssertEqual(underlying, "duplicate key value", "the server's words must survive")
        }
        let journal = await runner.journal
        XCTAssertEqual(journal.last, "ROLLBACK")
    }

    func testInsertReturningCountsAsOneRowAndItsRowIsKept() async throws {
        let generator = makeGenerator()
        let statements = [try generator.insert(values: ["name": .string("new")])]
        let runner = ScriptedRunner(affected: [nil], returningRows: [[.int(42)]])
        let result = try await GridCommitter().commit(statements, using: runner)
        XCTAssertEqual(result.totalAffectedRows, 1)
        XCTAssertEqual(result.insertedRows, [[.int(42)]])
        XCTAssertEqual(result.insertedColumns.first?.name, "id")
    }

    func testAnEmptyCommitDoesNotOpenATransaction() async throws {
        let runner = ScriptedRunner()
        let result = try await GridCommitter().commit([], using: runner)
        XCTAssertEqual(result.statementCount, 0)
        let journal = await runner.journal
        XCTAssertTrue(journal.isEmpty)
    }
}

/// A loader that serves a fixed table and records the requests it received.
actor FixtureLoader: GridDataLoader {
    let totalRows: Int
    let pageSize: Int
    private(set) var requests: [PageRequest] = []
    private var failure: (any Error)?

    init(totalRows: Int, pageSize: Int = 1_000) {
        self.totalRows = totalRows
        self.pageSize = pageSize
    }

    func setFailure(_ error: (any Error)?) { failure = error }
    func requestLog() -> [PageRequest] { requests }

    /// A sort on this column answers late, with rows that say so, so a test can prove a
    /// late answer never lands over a newer one.
    private var slowSort: (column: String, delay: Duration)?
    func setSlowSort(column: String, delay: Duration) { slowSort = (column, delay) }

    static let columns = [
        ColumnMeta(id: 0, name: "id", nativeTypeName: "int4", kind: .int, isPrimaryKey: true),
        ColumnMeta(id: 1, name: "name", nativeTypeName: "text", kind: .string),
    ]

    func loadPage(_ request: PageRequest) async throws -> LoadedPage {
        requests.append(request)
        if let failure { throw failure }
        var label = "row"
        if let slowSort, request.sort.first?.column == slowSort.column {
            try await Task.sleep(for: slowSort.delay)
            label = "slow"
        }
        let start = request.page * pageSize
        guard start < totalRows else { return LoadedPage(columns: Self.columns, rows: []) }
        let end = min(start + pageSize, totalRows)
        let rows = (start ..< end).map { index in
            [DBValue.int(Int64(index)), .string("\(label) \(index)")]
        }
        return LoadedPage(columns: Self.columns, rows: rows)
    }

    func exactCount(filter: [FilterRule]) async throws -> Int64 {
        Int64(totalRows)
    }
}

@MainActor
final class GridModelTests: XCTestCase {
    let table = TableRef(database: "app", schema: "public", name: "big_table")

    func makeModel(
        rows: Int = 2_500,
        pageSize: Int = 1_000,
        identity: [String] = ["id"],
        kind: DBValueKind? = .int
    ) -> (GridModel, FixtureLoader) {
        let loader = FixtureLoader(totalRows: rows, pageSize: pageSize)
        let model = GridModel(
            source: .table(table),
            dialect: .postgresql,
            loader: loader,
            identityColumns: identity,
            identityKind: kind,
            buffer: RowBuffer(pageSize: pageSize)
        )
        return (model, loader)
    }

    // MARK: - Pages (SPEC §12.7)

    func testAPagedGridShowsOnePageAtATime() async {
        let (model, _) = makeModel(rows: 2_500)
        model.isPaged = true
        model.estimatedTotal = 2_500
        await model.load(page: 0)

        XCTAssertEqual(model.displayRowCount, 1_000, "one page, not the whole table")
        XCTAssertEqual(model.pageRange, 1 ... 1_000)
        XCTAssertTrue(model.hasNextPage)
        XCTAssertFalse(model.hasPreviousPage)
        XCTAssertEqual(model.value(row: 0, column: 0), .int(0))
    }

    /// The rows are numbered from zero within the page, so the grid, the edits and the
    /// selection all keep meaning the same thing on every page.
    func testMovingToTheNextPageRereadsFromTheServer() async {
        let (model, loader) = makeModel(rows: 2_500)
        model.isPaged = true
        await model.load(page: 0)

        await model.goToPage(1)
        XCTAssertEqual(model.pageOffset, 1)
        XCTAssertEqual(model.displayRowCount, 1_000)
        XCTAssertEqual(model.pageRange, 1_001 ... 2_000)
        XCTAssertEqual(model.value(row: 0, column: 0), .int(1_000), "the page's first row")

        let pages = await loader.requestLog().map(\.page)
        XCTAssertEqual(pages, [0, 1], "one request per page, and only for the page shown")
    }

    func testTheLastPageIsShortAndHasNoNext() async {
        let (model, _) = makeModel(rows: 2_500)
        model.isPaged = true
        await model.goToPage(2)
        XCTAssertEqual(model.displayRowCount, 500)
        XCTAssertEqual(model.pageRange, 2_001 ... 2_500)
        XCTAssertFalse(model.hasNextPage)
        XCTAssertTrue(model.hasPreviousPage)
    }

    /// Both change what page two would mean, so both go back to page one.
    func testFilterAndSortReturnToTheFirstPage() async {
        let (model, _) = makeModel(rows: 2_500)
        model.isPaged = true
        await model.goToPage(2)
        XCTAssertEqual(model.pageOffset, 2)

        await model.setFilter([FilterRule(column: "name", op: .contains, values: [.string("row")])])
        XCTAssertEqual(model.pageOffset, 0)

        await model.goToPage(1)
        await model.setSort([PagePlanner.SortTerm(column: "name", ascending: true)])
        XCTAssertEqual(model.pageOffset, 0)
    }

    /// A paged grid never reports the whole table's estimate as its row count.
    func testAPagedGridIgnoresTheTableEstimate() async {
        let (model, _) = makeModel(rows: 2_500)
        model.isPaged = true
        model.estimatedTotal = 1_000_000
        await model.load(page: 0)
        XCTAssertEqual(model.displayRowCount, 1_000)
    }

    /// The planner estimate describes the whole table. Once a filter is on it is not the
    /// number of matching rows, and a grid that keeps using it draws rows that hold
    /// nothing — which is what a filtered table looked like when its page failed to load.
    func testAFilteredGridDoesNotCountTheWholeTable() async {
        let (model, loader) = makeModel(rows: 2_500)
        model.estimatedTotal = 1_000_000
        await model.load(page: 0)
        XCTAssertEqual(model.displayRowCount, 1_000_000, "unfiltered, the estimate stands")

        // A filter whose first page cannot be read.
        await loader.setFailure(DBError.notConnected)
        await model.setFilter([FilterRule(column: "name", op: .contains, values: [.string("x")])])

        XCTAssertNotNil(model.lastError, "the failure is kept so the tab can show it")
        XCTAssertEqual(
            model.displayRowCount, 0,
            "no rows were read, so none are drawn — not a million empty ones"
        )
    }

    /// And a filter that does match reports what it matched.
    func testAFilteredGridCountsWhatItLoaded() async {
        let (model, _) = makeModel(rows: 12)
        model.estimatedTotal = 1_000_000
        await model.setFilter([FilterRule(column: "name", op: .contains, values: [.string("row")])])
        XCTAssertEqual(model.displayRowCount, 12)
        XCTAssertNil(model.lastError)
    }

    func testLoadingAPageFillsColumnsAndRows() async {
        let (model, _) = makeModel()
        await model.load(page: 0)
        XCTAssertEqual(model.columns.map(\.name), ["id", "name"])
        XCTAssertEqual(model.rowCount, 1_000)
        XCTAssertEqual(model.value(row: 0, column: 0), .int(0))
        XCTAssertEqual(model.value(row: 999, column: 1), .string("row 999"))
        XCTAssertFalse(model.isExhausted)
    }

    func testAShortPageMarksTheResultExhausted() async {
        let (model, _) = makeModel(rows: 1_500)
        await model.load(page: 0)
        await model.load(page: 1)
        XCTAssertTrue(model.isExhausted)
        XCTAssertEqual(model.totalCount, 1_500)
        XCTAssertEqual(model.rowCount, 1_500)
    }

    func testEnsureLoadedFetchesOnlyMissingPagesAndNotTwice() async {
        let (model, loader) = makeModel()
        await model.ensureLoaded(range: 0 ..< 10)
        await model.ensureLoaded(range: 0 ..< 10)
        await model.ensureLoaded(range: 1_000 ..< 1_010)
        let requested = await loader.requestLog().map(\.page)
        XCTAssertEqual(requested, [0, 1])
    }

    /// A keyset cursor resumes from a row already loaded, so it applies when the user
    /// scrolls on past page 50 and not when they jump into unloaded territory.
    func testSequentialScrollingPastPageFiftyUsesAKeysetCursor() async {
        let (model, loader) = makeModel(rows: 200_000)
        XCTAssertEqual(model.strategy(forPage: 10), .offset)

        for page in 0 ... 51 { await model.load(page: page) }
        let requests = await loader.requestLog()
        let deepest = try? XCTUnwrap(requests.last)
        XCTAssertEqual(deepest?.page, 51)
        XCTAssertEqual(deepest?.strategy, .keyset(column: "id"))
        // The anchor is the last row of page 50.
        XCTAssertEqual(deepest?.keysetAnchor, .int(50_999))
    }

    func testJumpingIntoUnloadedTerritoryFallsBackToOffset() async {
        let (model, loader) = makeModel(rows: 200_000)
        await model.load(page: 0)
        // Nothing precedes page 120, so a keyset cursor has nowhere to resume from.
        XCTAssertEqual(model.strategy(forPage: 120), .offset)
        await model.load(page: 120)
        let requests = await loader.requestLog()
        XCTAssertEqual(requests.last?.strategy, .offset)
        XCTAssertNil(requests.last?.keysetAnchor)
    }

    func testAUserSortForcesOffsetPaging() async {
        let (model, _) = makeModel(rows: 200_000)
        await model.setSort([PagePlanner.SortTerm(column: "name", ascending: true)])
        XCTAssertEqual(model.strategy(forPage: 60), .offset)
    }

    func testSortAndFilterReloadFromTheFirstPage() async {
        let (model, loader) = makeModel()
        await model.load(page: 1)
        XCTAssertEqual(model.rowCount, 2_000)

        await model.setFilter([FilterRule(column: "name", op: .contains, values: [.string("x")])])
        XCTAssertEqual(model.rowCount, 1_000, "a filter change should have reloaded from page 0")
        let requests = await loader.requestLog()
        XCTAssertEqual(requests.last?.page, 0)
        XCTAssertEqual(requests.last?.filter.first?.column, "name")
    }

    /// Two header clicks start two loads. The first answers last here, and its rows must
    /// not land over the second's: the grid showed one column's order under another
    /// column's arrow.
    func testAStaleLoadDoesNotOverwriteANewerOne() async throws {
        let (model, loader) = makeModel(rows: 100, pageSize: 100)
        await loader.setSlowSort(column: "name", delay: .milliseconds(200))

        let slow = Task { await model.setSort([PagePlanner.SortTerm(column: "name", ascending: true)]) }
        try await Task.sleep(for: .milliseconds(30))
        await model.setSort([PagePlanner.SortTerm(column: "id", ascending: true)])
        XCTAssertEqual(model.value(row: 0, column: 1), .string("row 0"))

        await slow.value
        XCTAssertEqual(model.sort.first?.column, "id")
        XCTAssertEqual(
            model.value(row: 0, column: 1), .string("row 0"),
            "the late answer for the earlier sort must have been dropped")
        XCTAssertEqual(model.rowCount, 100)
        XCTAssertNil(model.lastError)
    }

    /// ⌘Z takes back one change at a time — a cell, a delete, a new row — whoever made
    /// it; a commit and a reload forget the history, since what they leave is not undoable.
    func testUndoAndRedoWalkTheEditsOneChangeAtATime() async throws {
        let (model, _) = makeModel(rows: 10, pageSize: 10)
        await model.load(page: 0)
        XCTAssertFalse(model.canUndo)

        model.setValue(.string("one"), row: 0, column: 1)
        model.setValue(.string("two"), row: 1, column: 1)
        model.markDeleted(rows: [2])
        let insert = try XCTUnwrap(model.addRow())
        model.edits.setInsertValue(.string("new"), id: insert.id, column: "name")
        XCTAssertEqual(model.edits.pendingStatementCount, 4)

        model.undo()
        XCTAssertEqual(model.edits.pendingInserts.first?.values.count, 0, "the typed value went, the row stayed")
        model.undo()
        XCTAssertTrue(model.edits.pendingInserts.isEmpty)
        model.undo()
        XCTAssertEqual(model.changeState(row: 2, column: 1), .unchanged)
        XCTAssertEqual(model.value(row: 1, column: 1), .string("two"))
        model.undo()
        model.undo()
        XCTAssertEqual(model.value(row: 0, column: 1), .string("row 0"))
        XCTAssertFalse(model.canUndo)
        XCTAssertTrue(model.canRedo)

        model.redo()
        XCTAssertEqual(model.value(row: 0, column: 1), .string("one"))
        // A new change after an undo drops what could have been redone.
        model.setValue(.string("three"), row: 3, column: 1)
        XCTAssertFalse(model.canRedo)

        await model.reload()
        XCTAssertFalse(model.canUndo, "a reload forgets the history: the indices mean nothing now")
    }

    func testCycleSortGoesAscendingDescendingNone() async {
        let (model, _) = makeModel()
        await model.cycleSort(column: "name", additive: false)
        XCTAssertEqual(model.sort.map(\.ascending), [true])
        await model.cycleSort(column: "name", additive: false)
        XCTAssertEqual(model.sort.map(\.ascending), [false])
        await model.cycleSort(column: "name", additive: false)
        XCTAssertTrue(model.sort.isEmpty)
    }

    func testAdditiveSortKeepsEarlierColumns() async {
        let (model, _) = makeModel()
        await model.cycleSort(column: "id", additive: false)
        await model.cycleSort(column: "name", additive: true)
        XCTAssertEqual(model.sort.map(\.column), ["id", "name"])
    }

    func testEditingRequiresARowIdentity() async {
        let (withKey, _) = makeModel()
        await withKey.load(page: 0)
        XCTAssertTrue(withKey.isEditable)
        XCTAssertNil(withKey.readOnlyReason)
        XCTAssertTrue(withKey.setValue(.string("edited"), row: 0, column: 1))
        XCTAssertEqual(withKey.value(row: 0, column: 1), .string("edited"))
        XCTAssertEqual(withKey.changeState(row: 0, column: 1), .edited)

        let (withoutKey, _) = makeModel(identity: [], kind: nil)
        await withoutKey.load(page: 0)
        XCTAssertFalse(withoutKey.isEditable)
        XCTAssertEqual(withoutKey.readOnlyReason, "No primary key — read only")
        XCTAssertFalse(withoutKey.setValue(.string("edited"), row: 0, column: 1))
    }

    func testQueryResultsEditOnlyWithATableAndItsKey() {
        let loader = FixtureLoader(totalRows: 0)
        let model = GridModel(source: .query("SELECT 1"), dialect: .postgresql, loader: loader)
        XCTAssertFalse(model.isEditable)
        XCTAssertEqual(model.readOnlyReason, "Read only — select from one table with its primary key to edit")

        // A result that reads one table edits like that table, but only its own columns.
        let keyed = GridModel(
            source: .query("SELECT id, name, upper(name) AS loud FROM t"), dialect: .postgresql, loader: loader,
            identityColumns: ["id"], identityKind: .int)
        keyed.editTarget = TableRef(database: "db", schema: "public", name: "t")
        keyed.editableColumns = ["id", "name"]
        XCTAssertTrue(keyed.isEditable)
        XCTAssertNil(keyed.readOnlyReason)
        XCTAssertEqual(keyed.writableTable?.name, "t")
        keyed.setIdentity(columns: [], kind: nil)
        XCTAssertFalse(keyed.isEditable)
        XCTAssertEqual(keyed.readOnlyReason, "Read only — the key is not in the result")
    }

    func testPendingStatementsUseOriginalIdentityValues() async throws {
        let (model, _) = makeModel()
        await model.load(page: 0)
        model.setValue(.string("edited"), row: 3, column: 1)
        // Changing the key column too must not change how the row is found.
        model.setValue(.int(999), row: 3, column: 0)

        let statements = try model.pendingStatements()
        XCTAssertEqual(statements.count, 1)
        XCTAssertTrue(statements[0].sql.hasSuffix("WHERE \"id\" = $3"))
        XCTAssertEqual(statements[0].parameters.last, .int(3), "the WHERE clause must use the loaded id")
    }

    func testDeleteAndCommitClearTheBuffer() async throws {
        let (model, _) = makeModel()
        await model.load(page: 0)
        model.markDeleted(rows: [1, 2])
        XCTAssertEqual(model.edits.pendingStatementCount, 2)

        let runner = ScriptedRunner(affected: [1, 1])
        let result = try await model.commit(using: runner)
        XCTAssertEqual(result.statementCount, 2)
        XCTAssertTrue(model.edits.isEmpty)
    }

    func testAFailedCommitKeepsTheEdits() async throws {
        let (model, _) = makeModel()
        await model.load(page: 0)
        model.setValue(.string("edited"), row: 0, column: 1)

        let runner = ScriptedRunner(affected: [0])
        do {
            _ = try await model.commit(using: runner)
            XCTFail("expected the commit to fail")
        } catch {
            XCTAssertFalse(model.edits.isEmpty, "the user's work must survive a failed commit")
            XCTAssertEqual(model.value(row: 0, column: 1), .string("edited"))
        }
    }

    func testStreamedResultsAppendAndComplete() {
        let loader = FixtureLoader(totalRows: 0)
        let model = GridModel(source: .query("SELECT 1"), dialect: .postgresql, loader: loader)
        model.appendStreamed(
            columns: FixtureLoader.columns,
            batch: RowBatch(rows: [[.int(0), .string("a")]], startIndex: 0)
        )
        model.appendStreamed(
            columns: FixtureLoader.columns,
            batch: RowBatch(rows: [[.int(1), .string("b")]], startIndex: 1)
        )
        XCTAssertEqual(model.rowCount, 2)
        XCTAssertEqual(model.value(row: 1, column: 1), .string("b"))
        model.markStreamComplete()
        XCTAssertTrue(model.isExhausted)
        XCTAssertEqual(model.totalCount, 2)
    }

    func testALoadFailureIsRecordedRatherThanThrown() async {
        let (model, loader) = makeModel()
        await loader.setFailure(DBError.server(ServerError(message: "permission denied")))
        await model.load(page: 0)
        XCTAssertNotNil(model.lastError)
        XCTAssertEqual(model.rowCount, 0)
    }

    func testExactCount() async {
        let (model, _) = makeModel(rows: 2_500)
        await model.loadExactCount()
        XCTAssertEqual(model.totalCount, 2_500)
    }
}

final class CommitScopeTests: XCTestCase {
    let table = TableRef(database: "app", schema: "public", name: "users")

    func makeBuffer() -> EditBuffer {
        var buffer = EditBuffer()
        buffer.setValue(.int(2), row: 0, column: "a", loaded: .int(1), identity: ["id": .int(1)])
        buffer.markDeleted(row: 1, identity: ["id": .int(2)])
        let insert = buffer.addInsert()
        buffer.setInsertValue(.string("new"), id: insert.id, column: "name")
        return buffer
    }

    func testLoadedRowsOnlyLeavesNewRowsOut() throws {
        let buffer = makeBuffer()
        let generator = DMLGenerator(dialect: .postgresql, table: table, identityColumns: ["id"])
        let all = try buffer.statements(using: generator)
        let loaded = try buffer.statements(using: generator, scope: .loadedRowsOnly)
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(loaded.count, 2)
        XCTAssertFalse(loaded.contains { $0.sql.hasPrefix("INSERT") })
        XCTAssertEqual(buffer.pendingStatementCount(.loadedRowsOnly), 2)
        XCTAssertEqual(buffer.pendingStatementCount(.everything), 3)
    }

    func testDiscardingLoadedRowsKeepsTheNewRow() {
        var buffer = makeBuffer()
        buffer.discard(.loadedRowsOnly)
        XCTAssertEqual(buffer.pendingInserts.count, 1)
        XCTAssertEqual(buffer.pendingInserts.first?.values["name"], .string("new"))
        XCTAssertTrue(buffer.editedRowIndices.isEmpty)
        XCTAssertTrue(buffer.deletedRowIndices.isEmpty)
        buffer.discard(.everything)
        XCTAssertTrue(buffer.isEmpty)
    }

    /// An edit made while a commit is on the server must not vanish when that commit
    /// clears the buffer: only what the snapshot wrote goes.
    func testRemovingACommittedSnapshotKeepsChangesMadeSince() throws {
        var buffer = makeBuffer()
        let snapshot = buffer.snapshot(.loadedRowsOnly)
        // While the write is on the wire: row 0's cell changes again, a new cell on row 5
        // is edited, and a second new row is added.
        buffer.setValue(.int(3), row: 0, column: "a", loaded: .int(1), identity: ["id": .int(1)])
        buffer.setValue(.string("x"), row: 5, column: "name", loaded: .string("y"), identity: ["id": .int(6)])
        let second = buffer.addInsert()
        buffer.setInsertValue(.string("second"), id: second.id, column: "name")

        buffer.remove(committed: snapshot)

        XCTAssertEqual(buffer.editedRowIndices, [0, 5], "row 0 was changed again; row 5 was never written")
        XCTAssertTrue(buffer.deletedRowIndices.isEmpty, "the delete was written")
        XCTAssertEqual(buffer.pendingInserts.count, 2, "loadedRowsOnly wrote no insert")
        XCTAssertEqual(buffer.value(row: 0, column: "a", loaded: .int(1)), .int(3))

        // A full commit of what is left clears exactly that; nothing added later is touched.
        let everything = buffer.snapshot(.everything)
        let generator = DMLGenerator(dialect: .postgresql, table: table, identityColumns: ["id"])
        XCTAssertEqual(try buffer.statements(using: generator, snapshot: everything).count, 4)
        let third = buffer.addInsert()
        buffer.setInsertValue(.string("third"), id: third.id, column: "name")
        buffer.remove(committed: everything)
        XCTAssertTrue(buffer.editedRowIndices.isEmpty)
        XCTAssertEqual(buffer.pendingInserts.map(\.id), [third.id])
    }

    func testRemovingASnapshotLeavesAnUnchangedCellUnedited() {
        var buffer = makeBuffer()
        let snapshot = buffer.snapshot(.everything)
        buffer.remove(committed: snapshot)
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.pendingStatementCount, 0)
    }
}
