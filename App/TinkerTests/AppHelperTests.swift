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

struct EmptyLoader: GridDataLoader {
    func loadPage(_ request: PageRequest) async throws -> LoadedPage { LoadedPage(columns: [], rows: []) }
    func exactCount(filter: [FilterRule]) async throws -> Int64 { 0 }
}
