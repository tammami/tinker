import DBCore
import XCTest

@testable import DBGrid

/// A query result pages on the server: which statements qualify and how they are wrapped.
final class QueryPagingTests: XCTestCase {
    func testOnlySubqueryableStatementsPage() {
        XCTAssertTrue(QueryGridLoader.isPageable("SELECT * FROM t", dialect: .postgresql))
        XCTAssertTrue(QueryGridLoader.isPageable("  with x as (select 1) select * from x", dialect: .mysql))
        XCTAssertTrue(QueryGridLoader.isPageable("VALUES (1), (2)", dialect: .postgresql))
        XCTAssertTrue(QueryGridLoader.isPageable("TABLE t", dialect: .postgresql))
        XCTAssertFalse(QueryGridLoader.isPageable("TABLE t", dialect: .mysql))
        XCTAssertFalse(QueryGridLoader.isPageable("SHOW TABLES", dialect: .mysql))
        XCTAssertFalse(QueryGridLoader.isPageable("EXPLAIN SELECT 1", dialect: .postgresql))
        XCTAssertFalse(QueryGridLoader.isPageable("UPDATE t SET a = 1 RETURNING *", dialect: .postgresql))
        XCTAssertFalse(QueryGridLoader.isPageable("SELECT * FROM t FOR UPDATE", dialect: .postgresql))
    }

    func testWrappingKeepsTheStatementAndAddsTheWindow() {
        XCTAssertEqual(
            QueryGridLoader.pageSQL("SELECT * FROM t ORDER BY id;", page: 2, pageSize: 1_000),
            "SELECT * FROM (SELECT * FROM t ORDER BY id) AS tinker_page LIMIT 1000 OFFSET 2000")
        XCTAssertEqual(
            QueryGridLoader.countSQL("SELECT a, b FROM t"), "SELECT count(*) FROM (SELECT a, b FROM t) AS tinker_page")
    }
}
