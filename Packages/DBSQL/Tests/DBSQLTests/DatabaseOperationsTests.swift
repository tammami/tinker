import DBCore
import XCTest

@testable import DBSQL

final class DatabaseOperationsTests: XCTestCase {
    func testCreateOnEachEngine() {
        XCTAssertEqual(DatabaseOperations.create("sales", dialect: .postgresql), "CREATE DATABASE \"sales\"")
        XCTAssertEqual(
            DatabaseOperations.create(
                " sales 2 ", dialect: .postgresql, options: .init(encoding: "UTF8", owner: "app")),
            "CREATE DATABASE \"sales 2\" OWNER \"app\" TEMPLATE \"template0\" ENCODING 'UTF8'",
            "an explicit encoding needs template0")
        XCTAssertEqual(
            DatabaseOperations.create("sales", dialect: .postgresql, options: .init(template: "template1")),
            "CREATE DATABASE \"sales\" TEMPLATE \"template1\"")
        XCTAssertEqual(DatabaseOperations.create("sales", dialect: .mysql), "CREATE DATABASE `sales`")
        XCTAssertEqual(
            DatabaseOperations.create(
                "sales", dialect: .mysql, options: .init(characterSet: "utf8mb4", collation: "utf8mb4_0900_ai_ci")),
            "CREATE DATABASE `sales` CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci")
        XCTAssertNil(DatabaseOperations.create("x", dialect: .sqlite))
    }

    func testNamesAndOptionsCannotBreakOutOfTheStatement() {
        XCTAssertEqual(DatabaseOperations.create("a\"b", dialect: .postgresql), "CREATE DATABASE \"a\"\"b\"")
        XCTAssertEqual(DatabaseOperations.create("a`b", dialect: .mysql), "CREATE DATABASE `a``b`")
        XCTAssertEqual(
            DatabaseOperations.create("x", dialect: .postgresql, options: .init(encoding: "UTF8'; DROP")),
            "CREATE DATABASE \"x\" TEMPLATE \"template0\" ENCODING 'UTF8''; DROP'")
        XCTAssertNil(
            DatabaseOperations.create("x", dialect: .mysql, options: .init(characterSet: "utf8; DROP")),
            "a character set that is not a word is refused, not dropped silently")
        XCTAssertNil(DatabaseOperations.create("x", dialect: .mysql, options: .init(collation: "a b")))
    }

    func testDropAndSystemDatabases() {
        XCTAssertEqual(DatabaseOperations.drop("sales", dialect: .postgresql), "DROP DATABASE \"sales\"")
        XCTAssertEqual(
            DatabaseOperations.drop("sales", dialect: .postgresql, force: true), "DROP DATABASE \"sales\" WITH (FORCE)")
        XCTAssertEqual(DatabaseOperations.drop("sales", dialect: .mysql), "DROP DATABASE `sales`")
        XCTAssertNil(DatabaseOperations.drop("x", dialect: .sqlite))
        XCTAssertTrue(DatabaseOperations.isSystemDatabase("template1", dialect: .postgresql))
        XCTAssertTrue(DatabaseOperations.isSystemDatabase("MySQL", dialect: .mysql))
        XCTAssertFalse(DatabaseOperations.isSystemDatabase("tinker_test", dialect: .mysql))
    }
}
