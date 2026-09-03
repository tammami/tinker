import DBCore
import XCTest
@testable import DBSQL

final class QueryBuilderTests: XCTestCase {
    let customers = TableRef(database: "db", schema: "public", name: "customers")
    let orders = TableRef(database: "db", schema: "public", name: "orders")

    func testEmptyModelHasNoSQLAndOneTableSelectsStar() {
        var model = QueryBuilderModel()
        XCTAssertNil(model.sql(dialect: .postgresql))
        model.add(customers)
        XCTAssertEqual(model.sql(dialect: .postgresql), "SELECT\n    *\nFROM \"public\".\"customers\"")
    }

    func testJoinFieldsConditionsGroupingAndOrdering() {
        var model = QueryBuilderModel()
        let c = model.add(customers)
        let o = model.add(orders)
        model.joins.append(.init(kind: .left, leftTable: c, leftColumn: "id", rightTable: o, rightColumn: "customer_id"))
        model.fields = [
            .init(table: c, column: "name"),
            .init(table: o, column: "total", aggregate: .sum, alias: "revenue"),
            .init(table: o, column: "*", aggregate: .count, alias: "orders"),
        ]
        model.conditions = [
            .init(table: c, column: "name", op: .contains, values: [.string("a_b")]),
            .init(table: o, column: "total", op: .greaterThan, values: [.decimal("10")], conjunction: .or),
        ]
        model.groupBy = [.init(table: c, column: "name")]
        model.having = [.init(table: o, column: "total", op: .isNotNull)]
        model.orderBy = [.init(table: o, column: "total", ascending: false)]
        model.limit = 50
        model.offset = 10
        model.isDistinct = true

        XCTAssertEqual(model.sql(dialect: .postgresql), """
        SELECT DISTINCT
            "customers"."name",
            SUM("orders"."total") AS "revenue",
            COUNT(*) AS "orders"
        FROM "public"."customers"
        LEFT JOIN "public"."orders"
            ON "customers"."id" = "orders"."customer_id"
        WHERE "customers"."name"::text LIKE '%a!_b%' ESCAPE '!'
            OR "orders"."total" > 10
        GROUP BY "customers"."name"
        HAVING "orders"."total" IS NOT NULL
        ORDER BY "orders"."total" DESC
        LIMIT 50
        OFFSET 10
        """)
        let mysql = model.sql(dialect: .mysql) ?? ""
        XCTAssertTrue(mysql.contains("LEFT JOIN `db`.`orders`"), mysql)
        XCTAssertTrue(mysql.contains("CAST(`customers`.`name` AS CHAR) LIKE '%a!_b%' ESCAPE '!'"), mysql)
    }

    func testAliasesAreUniqueAndSelfJoinsQuoteThem() {
        var model = QueryBuilderModel()
        let a = model.add(customers)
        let b = model.add(customers)
        XCTAssertEqual(model.table(b)?.alias, "customers_2")
        model.joins.append(.init(leftTable: a, leftColumn: "id", rightTable: b, rightColumn: "id"))
        XCTAssertEqual(model.sql(dialect: .postgresql), """
        SELECT
            *
        FROM "public"."customers"
        INNER JOIN "public"."customers" AS "customers_2"
            ON "customers"."id" = "customers_2"."id"
        """)
    }

    func testUnjoinedTablesBecomeCrossJoinsAndRemovalCleansUp() {
        var model = QueryBuilderModel()
        let c = model.add(customers)
        let o = model.add(orders)
        XCTAssertTrue(model.sql(dialect: .mysql)?.contains("CROSS JOIN `db`.`orders`") ?? false)
        model.fields = [.init(table: o, column: "total")]
        model.orderBy = [.init(table: o, column: "total")]
        model.remove(table: o)
        XCTAssertTrue(model.fields.isEmpty)
        XCTAssertTrue(model.orderBy.isEmpty)
        XCTAssertEqual(model.tables.map(\.id), [c])
    }

    func testForeignKeysBecomeJoinsWhenARelatedTableIsDropped() {
        var model = QueryBuilderModel()
        let c = model.add(customers)
        let o = model.add(orders)
        let key = ForeignKeyInfo(name: "fk", columns: ["customer_id"], referencedTable: customers, referencedColumns: ["id"])
        model.addJoins(fromForeignKeys: [key], of: o)
        XCTAssertEqual(model.joins.count, 1)
        XCTAssertEqual(model.joins.first?.leftTable, c)
        XCTAssertEqual(model.joins.first?.rightColumn, "customer_id")
        // Dropping the same key again adds nothing.
        model.addJoins(fromForeignKeys: [key], of: o)
        XCTAssertEqual(model.joins.count, 1)
    }

    func testIncompleteConditionsAreLeftOutAndCreateViewWraps() {
        var model = QueryBuilderModel()
        let c = model.add(customers)
        model.conditions = [.init(table: c, column: "name", op: .equal, values: [.string("")])]
        XCTAssertFalse(model.sql(dialect: .postgresql)?.contains("WHERE") ?? true)
        let view = model.createViewSQL(name: TableRef(database: "db", schema: "public", name: "v"), dialect: .postgresql)
        XCTAssertEqual(view, "CREATE OR REPLACE VIEW \"public\".\"v\" AS\nSELECT\n    *\nFROM \"public\".\"customers\"")
    }
}
