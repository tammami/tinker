import DBCore
import XCTest

@testable import DBGrid

/// Where typing starts on a new row: the first column the user would fill in.
@MainActor
final class NewRowColumnTests: XCTestCase {
    private func model(_ names: [String]) -> GridModel {
        GridModel(
            source: .table(TableRef(database: "app", schema: "public", name: "items")),
            dialect: .postgresql,
            loader: FixtureLoader(totalRows: 0),
            columns: names.enumerated().map { ColumnMeta(id: $0, name: $1, nativeTypeName: "text", kind: .string) },
            identityColumns: ["id"],
            identityKind: .int
        )
    }

    func testAnAutoIncrementKeyIsPassedOver() {
        let grid = model(["id", "name"])
        grid.autoIncrementColumns = ["id"]
        XCTAssertEqual(grid.firstColumnToFill(), 1)
    }

    /// A key the user assigns is the first thing a new row needs.
    func testAKeyTheUserAssignsIsWhereTypingStarts() {
        let grid = model(["id", "name"])
        grid.autoIncrementColumns = []
        XCTAssertEqual(grid.firstColumnToFill(), 0)
    }

    func testNotKnowingTheColumnsYetStartsAtTheFirst() {
        XCTAssertEqual(model(["id", "name"]).firstColumnToFill(), 0)
    }

    /// The server refuses a generated column a value; `tableColumns` leaves them out.
    func testAGeneratedColumnIsPassedOver() {
        let grid = model(["total", "name"])
        grid.tableColumns = ["id", "name"]
        XCTAssertEqual(grid.firstColumnToFill(), 1)
    }

    /// In a query result, an expression or alias has nothing to write back to.
    func testAColumnWithNothingToWriteBackToIsPassedOver() {
        let grid = model(["upper_name", "name"])
        grid.editableColumns = ["name"]
        XCTAssertEqual(grid.firstColumnToFill(), 1)
    }

    /// A hidden column has no cell to open.
    func testAHiddenColumnIsPassedOver() {
        let grid = model(["id", "name", "note"])
        grid.autoIncrementColumns = ["id"]
        XCTAssertEqual(grid.firstColumnToFill(hidden: ["name"]), 2)
    }

    /// Nothing to fill in still opens a cell the user can see.
    func testWithNothingToFillItIsTheFirstColumnShown() {
        let grid = model(["id", "seq"])
        grid.autoIncrementColumns = ["id", "seq"]
        XCTAssertEqual(grid.firstColumnToFill(), 0)
        XCTAssertEqual(grid.firstColumnToFill(hidden: ["id"]), 1)
        XCTAssertEqual(grid.firstColumnToFill(hidden: ["id", "seq"]), 0, "nothing shown")
    }
}
