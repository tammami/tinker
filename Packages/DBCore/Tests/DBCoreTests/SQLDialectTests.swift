import XCTest

@testable import DBCore

final class SQLDialectTests: XCTestCase {
    func testRawValuesAreStable() {
        // Raw values are persisted in ConnectionConfig (SPEC §15); they must not drift.
        XCTAssertEqual(SQLDialect.postgresql.rawValue, "postgresql")
        XCTAssertEqual(SQLDialect.mysql.rawValue, "mysql")
        XCTAssertEqual(SQLDialect.allCases.count, 2)
    }
}
