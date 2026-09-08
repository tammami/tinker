import XCTest

@testable import DBSQL

final class RedactionTests: XCTestCase {
    func testPostgresPasswordsAreMasked() {
        XCTAssertEqual(
            SQLRedactor.redactSecrets("CREATE ROLE app WITH LOGIN PASSWORD 'hunter2'"),
            "CREATE ROLE app WITH LOGIN PASSWORD '•••'")
        XCTAssertEqual(
            SQLRedactor.redactSecrets("alter user app encrypted password 'it''s secret' valid until 'infinity'"),
            "alter user app encrypted password '•••' valid until 'infinity'")
    }

    func testMySQLIdentifiedByIsMasked() {
        XCTAssertEqual(
            SQLRedactor.redactSecrets("CREATE USER 'app'@'%' IDENTIFIED BY 'p@ss;word'"),
            "CREATE USER 'app'@'%' IDENTIFIED BY '•••'")
        XCTAssertEqual(
            SQLRedactor.redactSecrets("ALTER USER app IDENTIFIED WITH caching_sha2_password BY 'x'"),
            "ALTER USER app IDENTIFIED WITH caching_sha2_password BY '•••'")
        XCTAssertEqual(
            SQLRedactor.redactSecrets("CREATE USER app IDENTIFIED WITH mysql_native_password AS '*HASH'"),
            "CREATE USER app IDENTIFIED WITH mysql_native_password AS '•••'")
    }

    func testSecretOptionsAndSeveralInOneStatement() {
        XCTAssertEqual(
            SQLRedactor.redactSecrets("CREATE USER MAPPING FOR app SERVER s OPTIONS (password 'a', secret = 'b')"),
            "CREATE USER MAPPING FOR app SERVER s OPTIONS (password '•••', secret = '•••')")
    }

    func testOrdinaryStatementsAreUntouched() {
        let sql = "SELECT * FROM users WHERE password_hint = 'birthday' AND name = 'password'"
        XCTAssertEqual(SQLRedactor.redactSecrets(sql), sql)
        XCTAssertEqual(SQLRedactor.redactSecrets("UPDATE t SET secret_level = 3"), "UPDATE t SET secret_level = 3")
    }

    func testServerMessagesEchoingTheStatementAreMaskedToo() {
        let message = "syntax error at or near \"PASSWORD 'hunter2'\""
        XCTAssertEqual(SQLRedactor.redactSecrets(message), "syntax error at or near \"PASSWORD '•••'\"")
    }
}
