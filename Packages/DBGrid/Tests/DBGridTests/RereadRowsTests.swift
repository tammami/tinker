import DBCore
import XCTest

@testable import DBGrid

/// A re-read after a write leaves the rows in place until new ones arrive. A reload lets go of
/// them first, since what comes next is different rows.
@MainActor
final class RereadRowsTests: XCTestCase {
    private func makeModel(rows: Int = 10, pageSize: Int = 100) -> (GridModel, FixtureLoader) {
        let loader = FixtureLoader(totalRows: rows, pageSize: pageSize)
        let model = GridModel(
            source: .table(TableRef(database: "app", schema: "public", name: "items")),
            dialect: .postgresql,
            loader: loader,
            identityColumns: ["id"],
            identityKind: .int,
            buffer: RowBuffer(pageSize: pageSize)
        )
        return (model, loader)
    }

    func testTheRowsAreReplacedWhenTheAnswerIsIn() async throws {
        let (model, loader) = makeModel(rows: 10)
        await model.load(page: 0)
        XCTAssertEqual(model.displayRowCount, 10)

        await loader.setTotalRows(11)
        await model.rereadRows()

        XCTAssertEqual(model.displayRowCount, 11, "a row the write added")
        XCTAssertEqual(model.totalCount, 11)
        XCTAssertTrue(model.isExhausted)
        XCTAssertNotNil(model.loadedRow(10))
    }

    func testFewerRowsLeaveNothingBehind() async throws {
        let (model, loader) = makeModel(rows: 10)
        await model.load(page: 0)

        await loader.setTotalRows(9)
        await model.rereadRows()

        XCTAssertEqual(model.displayRowCount, 9, "a row the write deleted")
        XCTAssertNil(model.loadedRow(9))
    }

    /// Rows that could not be read again are not shown as if they had been.
    func testAFailedReadLeavesNoRowsAndSaysWhy() async throws {
        let (model, loader) = makeModel(rows: 10)
        await model.load(page: 0)

        await loader.setFailure(DBError.protocolError("gone"))
        await model.rereadRows()

        XCTAssertEqual(model.displayRowCount, 0)
        XCTAssertNotNil(model.lastError)
    }

    /// Stays on the page the user paged to.
    func testItStaysOnThePageItIsOn() async throws {
        let (model, loader) = makeModel(rows: 250, pageSize: 100)
        model.isPaged = true
        await model.goToPage(2)
        await model.rereadRows()

        XCTAssertEqual(model.pageOffset, 2)
        let lastRequest = await loader.requestLog().last
        XCTAssertEqual(lastRequest?.page, 2)
    }

    /// An edit to another row is still pending afterwards, keyed by its identity (ADR-0047).
    func testAPendingEditSurvives() async throws {
        let (model, _) = makeModel(rows: 10)
        await model.load(page: 0)
        model.setValue(.string("kept"), row: 3, column: 1)

        await model.rereadRows()

        XCTAssertEqual(model.value(row: 3, column: 1), .string("kept"))
        XCTAssertEqual(model.edits.pendingStatementCount, 1)
    }
}
