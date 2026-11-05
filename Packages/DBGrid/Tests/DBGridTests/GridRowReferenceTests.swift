import DBCore
import XCTest

@testable import DBGrid

/// A row followed by its key rather than its position.
@MainActor
final class GridRowReferenceTests: XCTestCase {
    private func makeModel(rows: Int, pageSize: Int = 100) -> GridModel {
        GridModel(
            source: .table(TableRef(database: "app", schema: "public", name: "items")),
            dialect: .postgresql,
            loader: FixtureLoader(totalRows: rows, pageSize: pageSize),
            identityColumns: ["id"],
            identityKind: .int,
            buffer: RowBuffer(pageSize: pageSize)
        )
    }

    func testARowIsFoundWhereItIs() async throws {
        let model = makeModel(rows: 10)
        await model.load(page: 0)
        let reference = try XCTUnwrap(model.reference(toRow: 4))
        XCTAssertEqual(model.row(for: reference), 4)
    }

    /// Another page holds other rows at the same positions.
    func testARowOnAnotherPageIsNotFound() async throws {
        let model = makeModel(rows: 250)
        model.isPaged = true
        await model.load(page: 0)
        let reference = try XCTUnwrap(model.reference(toRow: 4))

        await model.goToPage(1)

        XCTAssertNotNil(model.reference(toRow: 4))
        XCTAssertNotEqual(model.reference(toRow: 4), reference)
        XCTAssertNil(model.row(for: reference))
    }

    func testANewRowIsFollowedUntilItGoes() async throws {
        let model = makeModel(rows: 10)
        await model.load(page: 0)
        XCTAssertNotNil(model.addRow())
        let reference = try XCTUnwrap(model.reference(toRow: 10))
        XCTAssertEqual(model.row(for: reference), 10)

        XCTAssertTrue(model.markDeleted(rows: [10]))

        XCTAssertNil(model.row(for: reference))
    }

    func testARowNotLoadedHasNoReference() async throws {
        let model = makeModel(rows: 10)
        await model.load(page: 0)
        XCTAssertNil(model.reference(toRow: 50))
    }
}
