import DBCore
import XCTest

@testable import DBSQL

/// Comparing two tables that came from different servers (SPEC §15b.4).
final class StructureSyncTests: XCTestCase {
    let sourceTable = TableRef(database: "prod", schema: "public", name: "customers")
    let targetTable = TableRef(database: "dev", schema: "public", name: "customers")

    func sync() -> StructureSync { StructureSync(dialect: .postgresql) }

    func definition(_ table: TableRef, columns: [ColumnDefinition]) -> TableDefinition {
        TableDefinition(ref: table, columns: columns, primaryKey: ["id"])
    }

    /// SPEC §15b.5: syncing a table against itself produces nothing.
    func testAnIdenticalTableProducesNoStatements() {
        let columns = [
            ColumnDefinition(name: "id", type: "integer", isNullable: false),
            ColumnDefinition(name: "name", type: "text"),
        ]
        // Deliberately different identities, as two servers would give.
        let source = definition(sourceTable, columns: columns)
        let target = definition(
            targetTable,
            columns: columns.map {
                ColumnDefinition(
                    name: $0.name, type: $0.type, isNullable: $0.isNullable
                )
            })

        let result = sync().compare(source: source, target: target)
        XCTAssertTrue(result.isIdentical, result.statements.map(\.sql).joined(separator: "\n"))
        XCTAssertEqual(result.script(), "-- The target already matches the source.\n")
    }

    /// Objects are matched by name, or every column would read as dropped and re-added.
    func testAColumnMissingFromTheTargetIsAdded() {
        let source = definition(
            sourceTable,
            columns: [
                ColumnDefinition(name: "id", type: "integer", isNullable: false),
                ColumnDefinition(name: "name", type: "text"),
                ColumnDefinition(name: "email", type: "text", isNullable: false),
            ])
        let target = definition(
            targetTable,
            columns: [
                ColumnDefinition(name: "id", type: "integer", isNullable: false),
                ColumnDefinition(name: "name", type: "text"),
            ])

        let result = sync().compare(source: source, target: target)
        XCTAssertEqual(result.statements.map(\.kind), [.addColumn])
        XCTAssertEqual(
            result.statements[0].sql,
            #"ALTER TABLE "public"."customers" ADD COLUMN "email" text NOT NULL"#
        )
        XCTAssertTrue(result.destructive.isEmpty)
    }

    func testAChangedTypeIsAltered() {
        let source = definition(
            sourceTable,
            columns: [
                ColumnDefinition(name: "id", type: "integer", isNullable: false),
                ColumnDefinition(name: "name", type: "varchar(200)"),
            ])
        let target = definition(
            targetTable,
            columns: [
                ColumnDefinition(name: "id", type: "integer", isNullable: false),
                ColumnDefinition(name: "name", type: "text"),
            ])

        let result = sync().compare(source: source, target: target)
        XCTAssertEqual(result.statements.map(\.kind), [.alterColumn])
        XCTAssertTrue(result.statements[0].sql.contains("TYPE varchar(200)"))
    }

    /// A column the target has and the source does not is a drop, and a drop is never in
    /// the script unless it is asked for.
    func testADroppedColumnIsHeldBackFromTheScript() {
        let source = definition(
            sourceTable,
            columns: [
                ColumnDefinition(name: "id", type: "integer", isNullable: false)
            ])
        let target = definition(
            targetTable,
            columns: [
                ColumnDefinition(name: "id", type: "integer", isNullable: false),
                ColumnDefinition(name: "legacy", type: "text"),
            ])

        let result = sync().compare(source: source, target: target)
        XCTAssertEqual(result.destructive.count, 1)
        XCTAssertEqual(result.safe.count, 0)

        let script = result.script()
        XCTAssertTrue(script.contains("left out"), script)
        XCTAssertTrue(script.contains(#"-- ALTER TABLE "public"."customers" DROP COLUMN "legacy";"#), script)
        XCTAssertFalse(
            script.contains("\nALTER TABLE \"public\".\"customers\" DROP COLUMN \"legacy\";"),
            "a drop must not be runnable unless it was asked for"
        )

        let full = result.script(includingDestructive: true)
        XCTAssertTrue(full.contains(#"ALTER TABLE "public"."customers" DROP COLUMN "legacy";"#), full)
        XCTAssertFalse(full.contains("left out"), full)
    }

    func testIndexesAndChecksAreMatchedByName() {
        var source = definition(
            sourceTable,
            columns: [
                ColumnDefinition(name: "id", type: "integer", isNullable: false),
                ColumnDefinition(name: "email", type: "text"),
            ])
        source.indexes = [
            IndexDefinition(
                name: "customers_email_idx", columns: [IndexColumn(name: "email")], isUnique: true
            )
        ]
        source.checks = [CheckDefinition(name: "positive", expression: "id > 0")]

        var target = definition(
            targetTable,
            columns: source.columns.map {
                ColumnDefinition(name: $0.name, type: $0.type, isNullable: $0.isNullable)
            })
        // Same name, not unique: the sync should rebuild it rather than create a second.
        target.indexes = [
            IndexDefinition(
                name: "customers_email_idx", columns: [IndexColumn(name: "email")], isUnique: false
            )
        ]

        let result = sync().compare(source: source, target: target)
        XCTAssertEqual(result.statements.map(\.kind), [.dropIndex, .createIndex, .addCheck])
    }

    /// A foreign key points into the target's own schema, not back at the source's.
    func testAForeignKeyIsRepointedAtTheTarget() {
        var source = definition(
            sourceTable,
            columns: [
                ColumnDefinition(name: "id", type: "integer", isNullable: false)
            ])
        source.foreignKeys = [
            ForeignKeyDefinition(
                name: "customers_org_fk",
                columns: ["org_id"],
                referencedTable: TableRef(database: "prod", schema: "public", name: "orgs"),
                referencedColumns: ["id"],
                onDelete: .cascade
            )
        ]
        let target = definition(
            targetTable,
            columns: source.columns.map {
                ColumnDefinition(name: $0.name, type: $0.type, isNullable: $0.isNullable)
            })

        let result = sync().compare(source: source, target: target)
        XCTAssertEqual(result.statements.map(\.kind), [.addForeignKey])
        XCTAssertTrue(
            result.statements[0].sql.contains(#"REFERENCES "public"."orgs""#),
            result.statements[0].sql
        )
    }

    /// The sync changes the target in place; it never renames it to the source's name.
    func testTheTargetKeepsItsOwnName() {
        let source = definition(
            TableRef(database: "prod", schema: "public", name: "customers"),
            columns: [ColumnDefinition(name: "id", type: "integer", isNullable: false)]
        )
        let target = definition(
            TableRef(database: "dev", schema: "public", name: "clients"),
            columns: [ColumnDefinition(name: "id", type: "integer", isNullable: false)]
        )
        let result = sync().compare(source: source, target: target)
        XCTAssertFalse(
            result.statements.contains { $0.kind == .renameTable },
            result.statements.map(\.sql).joined(separator: "\n")
        )
    }

    /// A table the target does not have at all is created rather than diffed.
    func testCreatingATableTheTargetLacks() {
        var source = definition(
            sourceTable,
            columns: [
                ColumnDefinition(name: "id", type: "integer", isNullable: false)
            ])
        source.indexes = [IndexDefinition(name: "i", columns: [IndexColumn(name: "id")])]

        let schema = SchemaRef(database: "dev", schema: "public")
        let result = sync().create(source: source, in: schema)
        XCTAssertEqual(result.statements.map(\.kind), [.createTable, .createIndex])
        XCTAssertEqual(result.target, TableRef(database: "dev", schema: "public", name: "customers"))
        XCTAssertTrue(result.script().contains("CREATE TABLE"))
    }
}
