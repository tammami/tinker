import DBCore
import XCTest

@testable import DBGrid

/// Which SELECTs read one table, so their rows can be edited in place.
final class QuerySourceTableTests: XCTestCase {
    func testSimpleSelectsNameTheirTable() {
        XCTAssertEqual(
            QuerySourceTable.detect("SELECT * FROM customers", dialect: .postgresql),
            QuerySourceTable.Match(schema: nil, name: "customers"))
        XCTAssertEqual(
            QuerySourceTable.detect(
                "select id, name from public.\"Orders\" o where o.id > 3 order by 1 limit 10;", dialect: .postgresql),
            QuerySourceTable.Match(schema: "public", name: "Orders"))
        XCTAssertEqual(
            QuerySourceTable.detect("SELECT c.*, upper(c.name) AS loud FROM `shop`.`customers` AS c", dialect: .mysql),
            QuerySourceTable.Match(schema: "shop", name: "customers"))
        XCTAssertEqual(
            QuerySourceTable.detect(
                "SELECT DISTINCT id, name FROM t WHERE x IN (SELECT y FROM z)", dialect: .postgresql),
            QuerySourceTable.Match(schema: nil, name: "t"), "a subquery in WHERE does not change what a row is")
    }

    func testAnythingThatChangesWhatARowIsIsRefused() {
        let refused = [
            "SELECT a.id FROM a JOIN b ON a.id = b.a_id",
            "SELECT a.id FROM a, b",
            "SELECT count(*) FROM t GROUP BY x",
            "SELECT * FROM (SELECT * FROM t) AS q",
            "SELECT * FROM t UNION SELECT * FROM u",
            "SELECT DISTINCT ON (x) * FROM t",
            "WITH q AS (SELECT 1) SELECT * FROM q",
            "SHOW TABLES",
            "SELECT 1",
        ]
        for sql in refused {
            XCTAssertNil(QuerySourceTable.detect(sql, dialect: .postgresql), sql)
        }
    }
}
