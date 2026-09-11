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

    private func makeGrid() -> GridModel {
        GridModel(source: .query("SELECT 1"), dialect: .sqlite, loader: EmptyLoader())
    }
}

struct EmptyLoader: GridDataLoader {
    func loadPage(_ request: PageRequest) async throws -> LoadedPage { LoadedPage(columns: [], rows: []) }
    func exactCount(filter: [FilterRule]) async throws -> Int64 { 0 }
}
