import DBCore
import DBSQL
import XCTest

@testable import DBGrid

/// The reference picker's query and its choice of label column, without a server.
final class ReferenceLookupTests: XCTestCase {
    private let key = ForeignKeyInfo(
        name: "orders_customer_fk",
        columns: ["customer_id"],
        referencedTable: TableRef(database: "tinker_test", schema: "public", name: "customers"),
        referencedColumns: ["id"]
    )

    private func column(_ name: String, kind: DBValueKind, isPrimaryKey: Bool = false) -> ColumnInfo {
        ColumnInfo(
            ordinal: 1, name: name, nativeType: kind.rawValue, kind: kind, isNullable: true,
            defaultExpression: nil, isPrimaryKey: isPrimaryKey, isAutoIncrement: false, isGenerated: false,
            comment: nil
        )
    }

    func testLabelColumnPrefersANameOverAnyOtherText() {
        let columns = [
            column("id", kind: .int, isPrimaryKey: true), column("notes", kind: .string), column("name", kind: .string),
        ]
        XCTAssertEqual(ReferenceLookup.labelColumn(among: columns, keyColumns: ["id"]), "name")
    }

    func testLabelColumnFallsBackToTheFirstTextColumnThatIsNotTheKey() {
        let columns = [
            column("code", kind: .string, isPrimaryKey: true), column("qty", kind: .int), column("memo", kind: .string),
        ]
        // `code` is a preferred name, but it is the key itself.
        XCTAssertEqual(ReferenceLookup.labelColumn(among: columns, keyColumns: ["code"]), "memo")
        XCTAssertNil(
            ReferenceLookup.labelColumn(among: [column("id", kind: .int), column("n", kind: .int)], keyColumns: ["id"]))
    }

    func testLabelChoicesListTextColumnsFirstAndNeverTheKey() {
        let columns = [column("id", kind: .int), column("total", kind: .decimal), column("name", kind: .string)]
        XCTAssertEqual(ReferenceLookup.labelChoices(among: columns, keyColumns: ["id"]), ["name", "total"])
    }

    func testQuerySelectsOnlyKeyAndLabelAndSearchesBoth() {
        let query = ReferenceLookup.query(key: key, label: "name", text: "hadi", page: 0, dialect: .postgresql)
        XCTAssertEqual(
            query.sql,
            #"SELECT "id", "name" FROM "public"."customers" WHERE ("id"::text ILIKE $1 ESCAPE '!' OR "name"::text ILIKE $2 ESCAPE '!') ORDER BY "name" ASC LIMIT 51"#
        )
        XCTAssertEqual(query.parameters, [.string("%hadi%"), .string("%hadi%")])
    }

    func testAnEmptySearchListsTheTableFromTheStartAndPagesByFifty() {
        let first = ReferenceLookup.query(key: key, label: nil, text: "  ", page: 0, dialect: .mysql)
        XCTAssertEqual(first.sql, "SELECT `id` FROM `tinker_test`.`customers` ORDER BY `id` ASC LIMIT 51")
        XCTAssertTrue(first.parameters.isEmpty)
        let third = ReferenceLookup.query(key: key, label: nil, text: "", page: 2, dialect: .mysql)
        XCTAssertTrue(third.sql.hasSuffix("LIMIT 51 OFFSET 100"), third.sql)
    }

    func testSQLiteSearchFoldsCaseThroughLower() {
        let query = ReferenceLookup.query(key: key, label: "name", text: "Ö", page: 0, dialect: .sqlite)
        XCTAssertTrue(query.sql.contains(#"lower(CAST("name" AS TEXT)) LIKE lower(?) ESCAPE '!'"#), query.sql)
        XCTAssertTrue(query.sql.hasSuffix(#"ORDER BY "name" ASC LIMIT 51"#), query.sql)
    }
}

extension ReferenceLookupTests {
    func testLabelsQueryAsksForKeyAndLabelOfTheGivenKeysOnly() {
        let key = ForeignKeyInfo(
            name: "fk", columns: ["customer_id"],
            referencedTable: TableRef(database: "tinker_test", schema: "public", name: "customers"),
            referencedColumns: ["id"])
        let query = ReferenceLookup.labelsQuery(
            key: key, label: "name", keys: [.int(1), .int(2)], dialect: .postgresql)
        XCTAssertEqual(query?.sql, #"SELECT "id", "name" FROM "public"."customers" WHERE "id" IN ($1, $2)"#)
        XCTAssertEqual(query?.parameters, [.int(1), .int(2)])
        XCTAssertNil(ReferenceLookup.labelsQuery(key: key, label: "name", keys: [], dialect: .mysql))

        let composite = ForeignKeyInfo(
            name: "fk2", columns: ["a", "b"], referencedTable: key.referencedTable, referencedColumns: ["a", "b"])
        XCTAssertNil(ReferenceLookup.labelsQuery(key: composite, label: "name", keys: [.int(1)], dialect: .mysql))
    }
}
