import XCTest

@testable import DBCore

final class SQLDialectTests: XCTestCase {
    func testRawValuesAreStable() {
        // Raw values are persisted in ConnectionConfig (SPEC §15); they must not drift.
        XCTAssertEqual(SQLDialect.postgresql.rawValue, "postgresql")
        XCTAssertEqual(SQLDialect.mysql.rawValue, "mysql")
        XCTAssertEqual(SQLDialect.sqlite.rawValue, "sqlite")
        XCTAssertEqual(SQLDialect.allCases.count, 3)
    }

    func testOnlyPostgresHasASchemaLayerAndOnlySQLiteIsAFile() {
        XCTAssertTrue(SQLDialect.postgresql.hasSchemaLayer)
        XCTAssertFalse(SQLDialect.mysql.hasSchemaLayer)
        XCTAssertFalse(SQLDialect.sqlite.hasSchemaLayer)
        XCTAssertTrue(SQLDialect.sqlite.isFileBased)
        XCTAssertFalse(SQLDialect.sqlite.hasMultipleDatabases)
        XCTAssertFalse(SQLDialect.sqlite.hasUserAccounts)
        XCTAssertEqual(SchemaRef.pseudoSchema(.sqlite, database: "anything"), SchemaRef.sqlite)
        XCTAssertEqual(SchemaRef.pseudoSchema(.mysql, database: "shop"), SchemaRef.mysql("shop"))
        XCTAssertNil(SchemaRef.pseudoSchema(.postgresql, database: "shop"))
    }
}
