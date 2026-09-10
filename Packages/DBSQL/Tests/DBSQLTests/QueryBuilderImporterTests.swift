import DBCore
import XCTest

@testable import DBSQL

/// The importer against the text the servers actually hand back for views.
final class QueryBuilderImporterTests: XCTestCase {
    private let schema = SchemaRef(database: "tinker_test", schema: "public")

    private func resolve(_ name: String, _ qualifier: String?) -> TableRef? {
        ["customers", "orders", "audited"].contains(name) ? TableRef(schema: schema, name: name) : nil
    }

    private func imported(_ sql: String, dialect: SQLDialect = .postgresql) throws -> QueryBuilderModel {
        try QueryBuilderImporter.model(from: sql, dialect: dialect, resolveTable: resolve)
    }

    private func failure(_ sql: String, dialect: SQLDialect = .postgresql) -> QueryBuilderImporter.Failure? {
        do {
            _ = try imported(sql, dialect: dialect)
            return nil
        } catch let error as QueryBuilderImporter.Failure {
            return error
        } catch {
            return nil
        }
    }

    // MARK: - What PostgreSQL writes

    func testPostgreSQLViewWithJoinAggregateAndGroupBy() throws {
        let model = try imported(
            """
             SELECT c.id,
                c.name,
                sum(o.total) AS total
               FROM customers c
                 LEFT JOIN orders o ON o.customer_id = c.id
              GROUP BY c.id, c.name;
            """)
        XCTAssertEqual(model.tables.map(\.ref.name), ["customers", "orders"])
        XCTAssertEqual(model.tables.map(\.alias), ["c", "o"])
        XCTAssertEqual(model.joins.count, 1)
        XCTAssertEqual(model.joins.first?.kind, .left)
        XCTAssertEqual(model.joins.first?.leftColumn, "customer_id")
        XCTAssertEqual(model.joins.first?.rightColumn, "id")
        XCTAssertEqual(model.fields.map(\.column), ["id", "name", "total"])
        XCTAssertEqual(model.fields.map(\.aggregate), [.none, .none, .sum])
        XCTAssertEqual(model.fields.last?.alias, "total")
        XCTAssertEqual(model.groupBy.map(\.column), ["id", "name"])
        // Rendered again, the canvas produces the same shape of statement.
        let sql = try XCTUnwrap(model.sql(dialect: .postgresql))
        XCTAssertTrue(sql.contains(#"LEFT JOIN "public"."orders" AS "o""#), sql)
        XCTAssertTrue(sql.contains(#"SUM("o"."total") AS "total""#), sql)
        XCTAssertTrue(sql.contains(#"GROUP BY "c"."id", "c"."name""#), sql)
    }

    func testPostgreSQLCastsAndParenthesesInWhere() throws {
        let model = try imported(
            """
             SELECT customers.id, customers.name
               FROM customers
              WHERE ((customers.tier = 'ok'::mood) AND (customers.id > 5))
              ORDER BY customers.name DESC
              LIMIT 10;
            """)
        XCTAssertEqual(model.tables.first?.alias, "customers")
        XCTAssertEqual(model.conditions.count, 2)
        XCTAssertEqual(model.conditions[0].op, .equal)
        XCTAssertEqual(model.conditions[0].values, [.string("ok")])
        XCTAssertEqual(model.conditions[1].op, .greaterThan)
        XCTAssertEqual(model.conditions[1].values, [.int(5)])
        XCTAssertEqual(model.conditions[1].conjunction, .and)
        XCTAssertEqual(model.orderBy.first?.column, "name")
        XCTAssertEqual(model.orderBy.first?.ascending, false)
        XCTAssertEqual(model.limit, 10)
    }

    // MARK: - What MySQL writes

    func testMySQLShowCreateViewText() throws {
        let model = try imported(
            "CREATE ALGORITHM=UNDEFINED DEFINER=`tinker_test`@`%` SQL SECURITY DEFINER VIEW `customer_totals` AS "
                + "select `c`.`id` AS `id`,`c`.`name` AS `name`,sum(`o`.`total`) AS `total` "
                + "from (`customers` `c` left join `orders` `o` on((`o`.`customer_id` = `c`.`id`))) "
                + "group by `c`.`id`,`c`.`name`",
            dialect: .mysql)
        XCTAssertEqual(model.tables.map(\.alias), ["c", "o"])
        XCTAssertEqual(model.joins.first?.kind, .left)
        // An alias that only repeats the column name is not an alias.
        XCTAssertEqual(model.fields.map(\.alias), [nil, nil, "total"])
        XCTAssertEqual(model.fields.last?.aggregate, .sum)
        XCTAssertEqual(model.groupBy.count, 2)
    }

    func testMySQLDatabaseQualifiedTableAndLimitWithOffset() throws {
        let model = try imported(
            "select `orders`.`id` AS `id` from `tinker_test`.`orders` where (`orders`.`total` >= 10.5) limit 5,20",
            dialect: .mysql)
        XCTAssertEqual(model.tables.first?.ref.name, "orders")
        XCTAssertEqual(model.conditions.first?.op, .greaterOrEqual)
        XCTAssertEqual(model.conditions.first?.values, [.decimal("10.5")])
        XCTAssertEqual(model.offset, 5)
        XCTAssertEqual(model.limit, 20)
    }

    // MARK: - Operators the canvas has rows for

    func testLikePatternsBecomeTheBuildersTextOperators() throws {
        let model = try imported(
            "SELECT * FROM customers WHERE name LIKE '%adi%' OR name LIKE 'A%' OR name LIKE '%z' OR name LIKE '50!%' ESCAPE '!'"
        )
        XCTAssertEqual(model.fields.map(\.column), ["*"])
        XCTAssertEqual(model.conditions.map(\.op), [.contains, .startsWith, .endsWith, .equal])
        XCTAssertEqual(
            model.conditions.map(\.values), [[.string("adi")], [.string("A")], [.string("z")], [.string("50%")]])
        XCTAssertEqual(model.conditions.map(\.conjunction), [.and, .or, .or, .or])
    }

    func testNullInAndBetween() throws {
        let model = try imported(
            "SELECT id FROM orders WHERE placed_at IS NOT NULL AND id IN (1, 2, 3) AND total BETWEEN 1 AND 100")
        XCTAssertEqual(model.conditions.map(\.op), [.isNotNull, .inList, .between])
        XCTAssertEqual(model.conditions[1].values, [.int(1), .int(2), .int(3)])
        XCTAssertEqual(model.conditions[2].values, [.int(1), .int(100)])
    }

    func testDistinctStarAndCountStar() throws {
        let model = try imported("SELECT DISTINCT COUNT(*) AS n FROM customers")
        XCTAssertTrue(model.isDistinct)
        XCTAssertEqual(model.fields.first?.aggregate, .count)
        XCTAssertEqual(model.fields.first?.column, "*")
        XCTAssertEqual(model.fields.first?.alias, "n")
    }

    // MARK: - What it refuses, and says so

    func testRefusalsNameTheReason() {
        XCTAssertEqual(failure("CREATE VIEW v AS TABLE customers"), .noSelect)
        XCTAssertEqual(failure("SELECT * FROM nowhere"), .unknownTable("nowhere"))
        XCTAssertEqual(
            failure("SELECT id FROM customers c JOIN orders o ON o.customer_id = c.id"), .unknownColumnOwner("id"))
        XCTAssertEqual(
            failure("SELECT * FROM customers WHERE id IN (SELECT customer_id FROM orders)"),
            .unsupported("IN (SELECT …)"))
        XCTAssertEqual(
            failure("SELECT * FROM customers WHERE (tier = 'ok' OR tier = 'meh') AND id > 1"),
            .unsupported("grouped conditions (parentheses around AND/OR)"))
        XCTAssertEqual(failure("SELECT lower(name) FROM customers"), .unsupported("the function lower()"))
        XCTAssertEqual(failure("SELECT * FROM customers c JOIN orders o USING (id)"), .unsupported("JOIN … USING"))
        XCTAssertEqual(
            failure("SELECT * FROM customers c JOIN orders o ON o.customer_id = c.id AND o.id = c.id"),
            .unsupported("a join on more than one column"))
        XCTAssertEqual(failure("SELECT * FROM customers UNION SELECT * FROM audited"), .unsupported("UNION"))
        XCTAssertEqual(
            failure("SELECT * FROM customers WHERE name LIKE 'a%b'"),
            .unsupported("a LIKE pattern with a wildcard in the middle"))
    }

    /// The builder's own output reads back into the same canvas.
    func testRoundTripsTheBuildersOwnSQL() throws {
        var original = QueryBuilderModel()
        let customers = original.add(TableRef(schema: schema, name: "customers"))
        let orders = original.add(TableRef(schema: schema, name: "orders"), at: (300, 60))
        original.joins.append(
            .init(kind: .left, leftTable: orders, leftColumn: "customer_id", rightTable: customers, rightColumn: "id"))
        original.fields = [
            .init(table: customers, column: "name"),
            .init(table: orders, column: "total", aggregate: .sum, alias: "spent"),
        ]
        original.conditions = [.init(table: customers, column: "tier", op: .equal, values: [.string("ok")])]
        original.groupBy = [.init(table: customers, column: "name")]
        original.orderBy = [.init(table: customers, column: "name", ascending: false)]
        original.limit = 25

        for dialect in [SQLDialect.postgresql, .mysql, .sqlite] {
            let sql = try XCTUnwrap(original.sql(dialect: dialect))
            let back = try imported(sql, dialect: dialect)
            XCTAssertEqual(back.tables.map(\.ref.name), ["customers", "orders"], "\(dialect)")
            XCTAssertEqual(back.joins.map(\.kind), [.left], "\(dialect)")
            XCTAssertEqual(back.fields.map(\.column), ["name", "total"], "\(dialect)")
            XCTAssertEqual(back.fields.map(\.alias), [nil, "spent"], "\(dialect)")
            XCTAssertEqual(back.conditions.map(\.op), [.equal], "\(dialect)")
            XCTAssertEqual(back.groupBy.map(\.column), ["name"], "\(dialect)")
            XCTAssertEqual(back.orderBy.map(\.ascending), [false], "\(dialect)")
            XCTAssertEqual(back.limit, 25, "\(dialect)")
        }
    }
}
