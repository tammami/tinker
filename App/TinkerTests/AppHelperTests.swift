import DBCore
import DBGrid
import DBSQL
import DBTunnel
import XCTest

@testable import Tinker

/// The app's own small helpers, run inside the app (ADR-0047): the pieces the package
/// suites cannot reach because they live in the app target.
@MainActor
final class AppHelperTests: XCTestCase {
    // MARK: Logging

    func testRecentRecordsKeepTheLastFewHundredInOrder() {
        let records = AppLogging.RecentRecords()
        for index in 0 ..< (AppLogging.RecentRecords.capacity + 25) { records.append("record \(index)") }
        let lines = records.lines()
        XCTAssertEqual(lines.count, AppLogging.RecentRecords.capacity, "the buffer is bounded")
        XCTAssertEqual(lines.first, "record 25", "the oldest records are the ones dropped")
        XCTAssertEqual(lines.last, "record \(AppLogging.RecentRecords.capacity + 24)")
    }

    func testBootstrapHappensOnce() {
        let records = AppLogging.RecentRecords()
        XCTAssertTrue(records.markBootstrapped())
        XCTAssertFalse(records.markBootstrapped(), "a second bootstrap is refused, not crashed on")
    }

    func testDiagnosticsSummaryNamesTheAppAndCarriesNoSecrets() {
        let environment = AppEnvironment(secrets: EphemeralSecretStore())
        AppLogging.RecentRecords.shared.append("12:00:00.000 info [tinker.test] a record for the summary")
        let summary = Diagnostics.summary(environment: environment)
        XCTAssertTrue(summary.hasPrefix(Product.name), "the first line names the product and version")
        XCTAssertTrue(summary.contains("Connections: none configured"))
        XCTAssertTrue(summary.contains(AppLogging.subsystem))
        XCTAssertTrue(summary.contains("a record for the summary"), "recent records are appended")
        XCTAssertFalse(summary.lowercased().contains("password"), "nothing secret goes into a bug report")
    }

    // MARK: Prompts

    func testDeletePromptCountsItsRows() {
        let one = GridEditPrompts.deleteRows(count: 1, from: "orders") {}
        XCTAssertEqual(one.title, "Delete 1 row from “orders”?")
        XCTAssertEqual(one.confirmTitle, "Delete Row")
        let many = GridEditPrompts.deleteRows(count: 3, from: "orders") {}
        XCTAssertEqual(many.title, "Delete 3 rows from “orders”?")
        XCTAssertEqual(many.confirmTitle, "Delete 3 Rows")
        XCTAssertTrue(many.message.contains("Auto-commit is on"))
    }

    // MARK: Paste structure review

    /// Waits, boundedly, for the controller to put its review up.
    private func waitForReview(on controller: TransferController) async {
        for _ in 0 ..< 1_000 where controller.pendingReview == nil { await Task.yield() }
    }

    func testStructureReviewWithNothingToRunDoesNotAsk() async {
        let controller = TransferController(environment: AppEnvironment(secrets: EphemeralSecretStore()))
        let approved = await controller.reviewStructure([], target: "MySQL", source: "Localhost")
        XCTAssertTrue(approved)
        XCTAssertNil(controller.pendingReview, "an empty structure is not a question")
    }

    func testStructureReviewWaitsOnTheControllerUntilConfirmed() async {
        let controller = TransferController(environment: AppEnvironment(secrets: EphemeralSecretStore()))
        let answer = Task {
            await controller.reviewStructure(["CREATE TABLE a (id int)"], target: "MySQL", source: "Localhost")
        }
        await waitForReview(on: controller)
        let review = controller.pendingReview
        XCTAssertEqual(review?.title, "Run this structure on “MySQL”?")
        XCTAssertEqual(review?.confirmTitle, "Run and Copy Rows")
        XCTAssertEqual(review?.detail, "CREATE TABLE a (id int);", "the statements are shown whole, not cut to fit")
        XCTAssertFalse(review?.message.contains("CREATE") ?? true, "the subtitle only says what will happen")
        // The question lives on the controller the paste sheet owns, not on the workspace,
        // so presenting it cannot replace the sheet and restart the paste.
        await review?.action()
        let approved = await answer.value
        XCTAssertTrue(approved)
        XCTAssertNil(controller.pendingReview)
        controller.declineReview()  // a late dismissal after the answer is ignored, not a second resume
    }

    func testStructureReviewDeclinedByCancelOrDismissal() async {
        let controller = TransferController(environment: AppEnvironment(secrets: EphemeralSecretStore()))
        let cancelled = Task { await controller.reviewStructure(["CREATE TABLE a (id int)"], target: "t", source: "s") }
        await waitForReview(on: controller)
        controller.pendingReview?.onCancel?()
        let first = await cancelled.value
        XCTAssertFalse(first, "the review's own Cancel declines")

        let stopped = Task { await controller.reviewStructure(["CREATE TABLE a (id int)"], target: "t", source: "s") }
        await waitForReview(on: controller)
        controller.cancel()
        let second = await stopped.value
        XCTAssertFalse(second, "the sheet's Cancel declines a review still waiting instead of leaving the paste hung")
        XCTAssertNil(controller.pendingReview)
    }

    func testHostKeyTrustReadsBothFilesAndWritesOnlyTinkersOwn() {
        let trust = HostKeyPrompt.trust
        XCTAssertEqual(trust.readPaths, [KnownHostsFile.defaultPath, HostKeyPrompt.recordPath])
        XCTAssertEqual(trust.recordPath, HostKeyPrompt.recordPath)
        XCTAssertNotEqual(trust.recordPath, KnownHostsFile.defaultPath, "the user's own file is never written")
        XCTAssertTrue(trust.recordPath.hasSuffix("/\(Product.name)/known_hosts"))
        XCTAssertNotNil(trust.confirmation, "a new host is asked about, not accepted")
    }

    // MARK: Result tabs

    func testAResultTabShowsOneOfItsGrids() {
        let tab = QueryResultTab(label: "1", statement: "SELECT 1; SELECT 2")
        XCTAssertNil(tab.grid)
        let first = makeGrid()
        let second = makeGrid()
        tab.grids = [first, second]
        XCTAssertTrue(tab.grid === first)
        tab.shownGridIndex = 1
        XCTAssertTrue(tab.grid === second)
        tab.shownGridIndex = 7
        XCTAssertTrue(tab.grid === first, "an index past the end falls back to the first grid")

        let replacement = makeGrid()
        tab.shownGridIndex = 1
        tab.grid = replacement
        XCTAssertTrue(tab.grids[1] === replacement, "setting replaces the shown grid")
        tab.grid = nil
        XCTAssertTrue(tab.grids.isEmpty)
        XCTAssertEqual(tab.shownGridIndex, 0)
        tab.grid = replacement
        XCTAssertEqual(tab.grids.count, 1, "setting on an empty tab adds the grid")
    }

    // MARK: Cell inspector

    func testAnUntouchedFormFieldIsNotReportedAsChanged() {
        // The row form fills each field with the same text the clipboard would carry.
        // Anything it fills in and nobody touches must read back as unchanged, or leaving
        // the field writes an UPDATE for a row that was never edited.
        let untouched: [(String, DBValue)] = [
            ("7", .int(7)),
            ("01.01", .string("01.01")),
            ("1.7500", .decimal("1.7500")),
            ("{1,2}", .array([.int(1), .int(2)])),
            ("", .null),
        ]
        for (draft, value) in untouched {
            XCTAssertFalse(
                CellInspectorView.isChanged(draft: draft, from: value),
                "\(value) filled the field with \(draft) and was not edited")
        }
    }

    func testATypedFormFieldIsReportedAsChanged() {
        XCTAssertTrue(CellInspectorView.isChanged(draft: "8", from: .int(7)))
        XCTAssertTrue(CellInspectorView.isChanged(draft: "{1,3}", from: .array([.int(1), .int(2)])))
        XCTAssertTrue(
            CellInspectorView.isChanged(draft: "", from: .string("01.01")),
            "a field cleared by hand is a change, not a no-op")
        XCTAssertTrue(
            CellInspectorView.isChanged(draft: "text", from: .null),
            "typing into a NULL field is a change")
    }

    func testAQueryResultOffersOnlyItsWritableColumnsForEditing() async {
        // A query may return columns that belong to no writable table. The inspector asks
        // the grid the same question the grid asks itself before a write, so a column the
        // grid would refuse is not offered as a field to type into.
        let grid = GridModel(source: .query("SELECT id, name, id * 2 FROM invoices"), dialect: .sqlite,
                             loader: ThreeColumnLoader())
        await grid.load(page: 0)
        grid.editTarget = TableRef(database: "main", schema: "main", name: "invoices")
        grid.setIdentity(columns: ["id"], kind: .int)
        XCTAssertTrue(grid.isEditable, "the query reads one table and its key is in the result")
        grid.editableColumns = ["id", "name"]
        XCTAssertTrue(grid.isColumnEditable(0))
        XCTAssertTrue(grid.isColumnEditable(1))
        XCTAssertFalse(grid.isColumnEditable(2), "a computed column belongs to no table and is read only")
        XCTAssertFalse(grid.isColumnEditable(9), "a column past the end is never editable")
    }

    private func makeGrid() -> GridModel {
        GridModel(source: .query("SELECT 1"), dialect: .sqlite, loader: EmptyLoader())
    }
}

/// Three columns, the last of them computed, so per-column editing can be tested.
struct ThreeColumnLoader: GridDataLoader {
    func loadPage(_ request: PageRequest) async throws -> LoadedPage {
        LoadedPage(
            columns: [
                ColumnMeta(id: 0, name: "id", nativeTypeName: "integer", kind: .int, isPrimaryKey: true),
                ColumnMeta(id: 1, name: "name", nativeTypeName: "text", kind: .string),
                ColumnMeta(id: 2, name: "double_id", nativeTypeName: "integer", kind: .int),
            ],
            rows: [[.int(1), .string("one"), .int(2)]])
    }

    func exactCount(filter: [FilterRule]) async throws -> Int64 { 1 }
}

/// When the grid opens a cell for typing on its own.
@MainActor
final class GridInsertTypingTests: XCTestCase {
    private func rule(
        _ selection: GridSelection, editable: Bool = true, editor: Bool = false, insert: Bool = true
    ) -> Bool {
        GridCoordinator.opensForTyping(
            selection: selection, isEditable: editable, hasEditor: editor, isPendingInsertRow: insert)
    }

    /// A row being added has nothing in it, so landing on a cell means typing in it.
    func testACellOfARowBeingAddedOpensForTyping() {
        XCTAssertTrue(rule(GridSelection(row: 3, column: 0)))
        XCTAssertTrue(rule(GridSelection(row: 3, column: 2)))
    }

    func testAnExistingRowStillWaitsToBeAsked() {
        XCTAssertFalse(rule(GridSelection(row: 1, column: 0), insert: false))
    }

    func testNothingOpensOverAnEditorOrOnAReadOnlyGrid() {
        XCTAssertFalse(rule(GridSelection(row: 3, column: 0), editor: true))
        XCTAssertFalse(rule(GridSelection(row: 3, column: 0), editable: false))
    }

    /// Shift-extending a span, or selecting whole rows or columns, is not typing.
    func testASpanOrAWholeRowIsNotTyping() {
        var acrossColumns = GridSelection(row: 3, column: 0)
        acrossColumns.focusColumn = 2
        XCTAssertFalse(rule(acrossColumns))

        var acrossRows = GridSelection(row: 3, column: 0)
        acrossRows.focusRow = 5
        XCTAssertFalse(rule(acrossRows), "a span down the rows is not typing either")

        var rows = GridSelection(row: 3, column: 0)
        rows.mode = .rows
        XCTAssertFalse(rule(rows))

        var columns = GridSelection(row: 3, column: 0)
        columns.mode = .columns
        XCTAssertFalse(rule(columns))
    }
}

/// The event editor's own state machine, without a server.
@MainActor
final class EventEditorControllerTests: XCTestCase {
    private func controller(_ mode: EventEditorRequest.Mode = .create) -> EventEditorController {
        EventEditorController(
            request: EventEditorRequest(
                mode: mode, connectionID: UUID(), schema: SchemaRef.mysql("shop")),
            environment: AppEnvironment(secrets: EphemeralSecretStore()))
    }

    func testTheFormBuildsTheStatementItPreviews() {
        let editor = controller()
        editor.name = "nightly_clear"
        editor.intervalValue = "1"
        editor.intervalField = .day
        editor.starts = "2099-01-01 00:00:00"
        editor.body = "TRUNCATE TABLE staging"
        let sql = try? XCTUnwrap(editor.statement)
        XCTAssertEqual(
            sql,
            """
            CREATE EVENT `shop`.`nightly_clear`
            ON SCHEDULE EVERY 1 DAY
            STARTS '2099-01-01 00:00:00'
            ON COMPLETION PRESERVE
            ENABLE
            DO TRUNCATE TABLE staging
            """)
        XCTAssertNil(editor.problem)
    }

    func testAnIncompleteFormReportsWhyRatherThanOfferingAStatement() {
        let editor = controller()
        XCTAssertNil(editor.statement)
        XCTAssertEqual(editor.problem, EventOperationsError.emptyName.description)
        editor.name = "nightly"
        XCTAssertEqual(editor.problem, EventOperationsError.emptyBody.description)
        editor.body = "SELECT 1"
        XCTAssertNil(editor.problem)
        editor.intervalValue = "0"
        XCTAssertNotNil(editor.problem, "a zero interval is refused before it is sent")
    }

    func testEditingAltersInPlaceAndCanRename() {
        let editor = controller(.edit(name: "old_name"))
        editor.name = "new_name"
        editor.body = "SELECT 1"
        let sql = editor.statement ?? ""
        XCTAssertTrue(sql.hasPrefix("ALTER EVENT `shop`.`old_name`"), sql)
        XCTAssertTrue(sql.contains("RENAME TO `shop`.`new_name`"), sql)
        XCTAssertTrue(editor.isEditing)
    }

    /// Each server state gets its own words.
    func testEachSchedulerStateGetsItsOwnWarning() {
        XCTAssertNil(EventEditorController.schedulerWarning(for: .on, persists: true))
        XCTAssertNil(EventEditorController.schedulerWarning(for: .unsupported, persists: true))

        let off = EventEditorController.schedulerWarning(for: .off, persists: true)
        XCTAssertTrue(off?.message.contains("is off") == true)
        XCTAssertTrue(off?.hint.contains("stays on after a restart") == true)

        let notPersisted = EventEditorController.schedulerWarning(for: .off, persists: false)
        XCTAssertTrue(
            notPersisted?.hint.contains("my.cnf") == true,
            "a server without SET PERSIST is told so")

        let disabled = EventEditorController.schedulerWarning(for: .disabled, persists: true)
        XCTAssertTrue(disabled?.hint.contains("restarted") == true)
        XCTAssertFalse(
            disabled?.hint.contains("privilege") == true,
            "no privilege moves a disabled scheduler")
    }

    func testATimeAlreadyPastIsPointedOut() {
        // Two days either side, not decades: far enough that no time zone flips the answer,
        // near enough that the comparison is actually being exercised.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let past = formatter.string(from: now.addingTimeInterval(-48 * 3600))
        let future = formatter.string(from: now.addingTimeInterval(48 * 3600))
        XCTAssertNotNil(EventEditorController.pastScheduleHint(past, repeats: false, now: now))
        XCTAssertNil(EventEditorController.pastScheduleHint(future, repeats: false, now: now))
        XCTAssertNil(EventEditorController.pastScheduleHint("", repeats: true, now: now))
        XCTAssertNil(
            EventEditorController.pastScheduleHint("not a time", repeats: true, now: now),
            "unparseable text is left to the server")
    }

    /// Only MySQL gets the folder, the segment and the menu item.
    func testOnlyMySQLOffersEvents() {
        XCTAssertTrue(SQLDialect.mysql.hasScheduledEvents)
        XCTAssertFalse(SQLDialect.postgresql.hasScheduledEvents)
        XCTAssertFalse(SQLDialect.sqlite.hasScheduledEvents)
        XCTAssertTrue(SidebarRow.newObjectOrder(for: .mysql).contains(.event))
        XCTAssertFalse(SidebarRow.newObjectOrder(for: .postgresql).contains(.event))
        XCTAssertFalse(SidebarRow.newObjectOrder(for: .sqlite).contains(.event))
    }

    func testTheEventsFolderSaysWhenTheSchedulerIsNotRunning() {
        XCTAssertNil(SidebarModel.schedulerNote(.on))
        XCTAssertNil(SidebarModel.schedulerNote(.unsupported))
        XCTAssertEqual(SidebarModel.schedulerNote(.off), "scheduler off")
        XCTAssertEqual(SidebarModel.schedulerNote(.disabled), "scheduler disabled")
    }
}

struct EmptyLoader: GridDataLoader {
    func loadPage(_ request: PageRequest) async throws -> LoadedPage { LoadedPage(columns: [], rows: []) }
    func exactCount(filter: [FilterRule]) async throws -> Int64 { 0 }
}
