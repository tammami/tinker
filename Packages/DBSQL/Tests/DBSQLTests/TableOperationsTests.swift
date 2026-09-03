import DBCore
import XCTest
@testable import DBSQL

final class TableOperationsTests: XCTestCase {
    let pg = TableRef(database: "db", schema: "public", name: "orders")
    let my = TableRef(database: "shop", schema: "shop", name: "orders")

    func testRenameQuotesPerDialect() {
        XCTAssertEqual(
            TableOperations.rename(pg, to: "Orders Old", dialect: .postgresql),
            #"ALTER TABLE "public"."orders" RENAME TO "Orders Old""#
        )
        XCTAssertEqual(
            TableOperations.rename(my, to: "orders_old", dialect: .mysql),
            "RENAME TABLE `shop`.`orders` TO `shop`.`orders_old`"
        )
    }

    func testDuplicateWithAndWithoutData() {
        XCTAssertEqual(
            TableOperations.duplicate(pg, to: "orders_copy", includeData: false, dialect: .postgresql),
            [#"CREATE TABLE "public"."orders_copy" (LIKE "public"."orders" INCLUDING ALL)"#]
        )
        XCTAssertEqual(
            TableOperations.duplicate(my, to: "orders_copy", includeData: true, dialect: .mysql),
            [
                "CREATE TABLE `shop`.`orders_copy` LIKE `shop`.`orders`",
                "INSERT INTO `shop`.`orders_copy` SELECT * FROM `shop`.`orders`",
            ]
        )
    }

    func testMaintenanceOnlyOffersWhatTheEngineHas() {
        XCTAssertEqual(MaintenanceAction.available(for: .postgresql), [.analyze, .vacuum, .reindex])
        XCTAssertEqual(MaintenanceAction.available(for: .mysql), [.analyze, .optimize, .check])
        XCTAssertNil(TableOperations.maintenance(.optimize, on: pg, dialect: .postgresql))
        XCTAssertNil(TableOperations.maintenance(.vacuum, on: my, dialect: .mysql))
        XCTAssertEqual(
            TableOperations.maintenance(.vacuum, on: pg, dialect: .postgresql),
            #"VACUUM (ANALYZE) "public"."orders""#
        )
        XCTAssertEqual(
            TableOperations.maintenance(.check, on: my, dialect: .mysql),
            "CHECK TABLE `shop`.`orders`"
        )
    }

    func testExplainStripsTrailingSemicolonAndSpellsPerDialect() {
        XCTAssertEqual(
            TableOperations.explain("SELECT 1;\n", analyze: false, dialect: .postgresql),
            "EXPLAIN (FORMAT TEXT) SELECT 1"
        )
        XCTAssertEqual(
            TableOperations.explain("SELECT 1", analyze: true, dialect: .postgresql),
            "EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT) SELECT 1"
        )
        XCTAssertEqual(TableOperations.explain("SELECT 1;", analyze: false, dialect: .mysql), "EXPLAIN SELECT 1")
        XCTAssertEqual(TableOperations.explain("SELECT 1", analyze: true, dialect: .mysql), "EXPLAIN ANALYZE SELECT 1")
    }
}
