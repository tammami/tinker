import DBCore
import XCTest

@testable import DBSQL

/// Enum and set members survive the trip from the catalog through the designer into DDL.
final class EnumColumnTests: XCTestCase {
    let myTable = TableRef(database: "d", schema: "d", name: "users")
    let pgTable = TableRef(database: "d", schema: "public", name: "users")

    func testMySQLEnumMembersAreWrittenQuoted() {
        let column = ColumnDefinition(
            name: "akses",
            type: ColumnTypeSpec(base: "enum", values: ["User", "Administrator", "it's"]).render(dialect: .mysql),
            isNullable: true,
            defaultExpression: "NULL",
            characterSet: "utf8mb4",
            collation: "utf8mb4_unicode_ci"
        )
        let clause = DDLGenerator(dialect: .mysql).columnClause(column)
        XCTAssertEqual(
            clause,
            "`akses` enum('User','Administrator','it''s') CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL"
        )
    }

    func testChangingMembersIsAModifyColumn() {
        let before = ColumnDefinition(name: "akses", type: "enum('User','Administrator')")
        var after = before
        var spec = ColumnTypeSpec.parse(after.type)
        spec.values.append("Guest")
        after.type = spec.render(dialect: .mysql)
        let statements = DDLGenerator(dialect: .mysql).alter(
            from: TableDefinition(ref: myTable, columns: [before]),
            to: TableDefinition(ref: myTable, columns: [after])
        )
        XCTAssertEqual(statements.count, 1)
        XCTAssertEqual(
            statements[0].sql,
            "ALTER TABLE `d`.`users` MODIFY COLUMN `akses` enum('User','Administrator','Guest')")
    }

    func testAnUntouchedEnumColumnGeneratesNothing() {
        let info = ColumnInfo(
            ordinal: 1, name: "akses", nativeType: "enum('User','Administrator')", kind: .string,
            isNullable: true, enumLabels: ["User", "Administrator"])
        let definition = TableDefinition(
            table: myTable, info: nil, columns: [info], primaryKey: [], indexes: [], foreignKeys: [])
        var edited = definition
        // Re-rendering through the spec is what the designer does on every keystroke.
        let spec = ColumnTypeSpec.parse(edited.columns[0].type)
        edited.columns[0].type = spec.render(dialect: .mysql)
        XCTAssertTrue(DDLGenerator(dialect: .mysql).alter(from: definition, to: edited).isEmpty)
    }

    func testPostgresEnumLabelsRideAlongForDisplayOnly() {
        let info = ColumnInfo(
            ordinal: 1, name: "mood", nativeType: "mood", kind: .string, isNullable: true,
            enumLabels: ["sad", "ok", "happy"])
        let definition = TableDefinition(
            table: pgTable, info: nil, columns: [info], primaryKey: [], indexes: [], foreignKeys: [])
        XCTAssertEqual(definition.columns[0].enumLabels, ["sad", "ok", "happy"])
        XCTAssertEqual(definition.columns[0].type, "mood")
        var edited = definition
        edited.columns[0].enumLabels = nil
        XCTAssertTrue(
            DDLGenerator(dialect: .postgresql).alter(from: definition, to: edited).isEmpty,
            "labels are not part of the column's definition")
    }
}
