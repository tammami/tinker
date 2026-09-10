import DBCore
import XCTest

@testable import DBGrid

final class ResultColumnOriginsTests: XCTestCase {
    private let orders = TableRef(database: "tinker_test", schema: "public", name: "orders")
    private let customers = TableRef(database: "tinker_test", schema: "public", name: "customers")

    private var sources: [ResultColumnOrigins.Source] {
        [
            .init(table: orders, columns: ["id", "customer_id", "total", "placed_at"]),
            .init(table: customers, columns: ["id", "name", "email"]),
        ]
    }

    private func column(_ index: Int, _ name: String, table: String? = nil, source: String? = nil) -> ColumnMeta {
        ColumnMeta(id: index, name: name, tableOID: table, sourceColumn: source, nativeTypeName: "text", kind: .string)
    }

    /// PostgreSQL: names are matched against the tables the statement reads; `id` is in
    /// both and stays unresolved, `customer_id` and `name` are in one each.
    func testNamesUniqueToOneTableResolveByName() {
        let origins = ResultColumnOrigins.resolve(
            columns: [column(0, "id"), column(1, "customer_id"), column(2, "name"), column(3, "orders")],
            sources: sources)
        XCTAssertNil(origins[0])
        XCTAssertEqual(origins[1], ColumnOrigin(table: orders, column: "customer_id"))
        XCTAssertEqual(origins[2], ColumnOrigin(table: customers, column: "name"))
        XCTAssertNil(origins[3], "a computed column belongs to no table")
    }

    /// MySQL: the server names the table and the original column, so an alias and even
    /// a shared name like `id` resolve.
    func testServerReportedTableAndColumnWin() {
        let origins = ResultColumnOrigins.resolve(
            columns: [
                column(0, "id", table: "public.orders", source: "id"),
                column(1, "customer", table: "public.customers", source: "name"),
                column(2, "cid", table: "public.orders", source: "customer_id"),
                column(3, "elsewhere", table: "public.unknown", source: "x"),
            ],
            sources: sources)
        XCTAssertEqual(origins[0], ColumnOrigin(table: orders, column: "id"))
        XCTAssertEqual(origins[1], ColumnOrigin(table: customers, column: "name"))
        XCTAssertEqual(origins[2], ColumnOrigin(table: orders, column: "customer_id"))
        XCTAssertNil(origins[3], "a table the statement does not read is not guessed at")
    }

    func testTableWithoutSourceColumnFallsBackToTheName() {
        let origins = ResultColumnOrigins.resolve(
            columns: [column(0, "Customer_ID", table: "public.orders")], sources: sources)
        XCTAssertEqual(origins[0], ColumnOrigin(table: orders, column: "customer_id"))
    }

    func testNoSourcesMeansNoOrigins() {
        XCTAssertTrue(ResultColumnOrigins.resolve(columns: [column(0, "id")], sources: []).isEmpty)
    }
}
