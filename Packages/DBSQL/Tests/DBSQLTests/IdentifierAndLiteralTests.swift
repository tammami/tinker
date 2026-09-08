import DBCore
import XCTest

@testable import DBSQL

final class IdentifierTests: XCTestCase {
    func testQuotingEscapesTheQuoteCharacter() {
        XCTAssertEqual(Identifier.quote("users", dialect: .postgresql), "\"users\"")
        XCTAssertEqual(Identifier.quote("we\"ird", dialect: .postgresql), "\"we\"\"ird\"")
        XCTAssertEqual(Identifier.quote("users", dialect: .mysql), "`users`")
        XCTAssertEqual(Identifier.quote("we`ird", dialect: .mysql), "`we``ird`")
    }

    func testQualifiedNameUsesSchemaForPostgresAndDatabaseForMySQL() {
        let table = TableRef(database: "app", schema: "public", name: "users")
        XCTAssertEqual(Identifier.qualified(table, dialect: .postgresql), "\"public\".\"users\"")
        XCTAssertEqual(Identifier.qualified(table, dialect: .mysql), "`app`.`users`")
    }

    func testDisplayQuotesOnlyWhenNeeded() {
        XCTAssertEqual(Identifier.display("users", dialect: .postgresql), "users")
        XCTAssertEqual(Identifier.display("Users", dialect: .postgresql), "\"Users\"")
        XCTAssertEqual(Identifier.display("select", dialect: .postgresql), "\"select\"")
        XCTAssertEqual(Identifier.display("my table", dialect: .postgresql), "\"my table\"")
        XCTAssertEqual(Identifier.display("Users", dialect: .mysql), "Users")
        XCTAssertEqual(Identifier.display("123", dialect: .mysql), "`123`")
        XCTAssertEqual(Identifier.display("select", dialect: .mysql), "`select`")
    }

    func testUnquoteRoundTrips() {
        for name in ["users", "we\"ird", "Mixed Case"] {
            let quoted = Identifier.quote(name, dialect: .postgresql)
            XCTAssertEqual(Identifier.unquote(quoted, dialect: .postgresql), name)
        }
        for name in ["users", "we`ird"] {
            let quoted = Identifier.quote(name, dialect: .mysql)
            XCTAssertEqual(Identifier.unquote(quoted, dialect: .mysql), name)
        }
    }
}

final class SQLLiteralTests: XCTestCase {
    func testStringEscapingDiffersByDialect() {
        XCTAssertEqual(SQLLiteral.quoteString("it's", dialect: .postgresql), "'it''s'")
        XCTAssertEqual(SQLLiteral.quoteString("back\\slash", dialect: .postgresql), "'back\\slash'")
        XCTAssertEqual(SQLLiteral.quoteString("it's", dialect: .mysql), "'it''s'")
        XCTAssertEqual(SQLLiteral.quoteString("back\\slash", dialect: .mysql), "'back\\\\slash'")
    }

    func testDecimalIsNeverQuotedSoItStaysExact() {
        let value = DBValue.decimal("12345678901234567890.123456789012345")
        XCTAssertEqual(value.sqlLiteral(dialect: .postgresql), "12345678901234567890.123456789012345")
        XCTAssertEqual(value.sqlLiteral(dialect: .mysql), "12345678901234567890.123456789012345")
    }

    func testTimestampLiteralUsesServerText() {
        let timestamp = DBTimestamp(
            date: DBDate(year: 2024, month: 3, day: 10),
            time: DBTime(hour: 2, minute: 30, second: 0, microsecond: 123_456),
            hasTimeZone: true,
            serverText: "2024-03-10 02:30:00.123456+07"
        )
        XCTAssertEqual(
            DBValue.timestamp(timestamp).sqlLiteral(dialect: .postgresql),
            "'2024-03-10 02:30:00.123456+07'::timestamptz"
        )
    }

    func testByteLiteral() {
        let data = Data([0x00, 0xFF, 0x41])
        XCTAssertEqual(DBValue.bytes(data).sqlLiteral(dialect: .postgresql), "'\\x00ff41'::bytea")
        XCTAssertEqual(DBValue.bytes(data).sqlLiteral(dialect: .mysql), "X'00ff41'")
        XCTAssertEqual(DBValue.bytes(Data()).sqlLiteral(dialect: .mysql), "X''")
    }

    func testBooleanAndSpecialDoubles() {
        XCTAssertEqual(DBValue.bool(true).sqlLiteral(dialect: .postgresql), "TRUE")
        XCTAssertEqual(DBValue.bool(true).sqlLiteral(dialect: .mysql), "1")
        XCTAssertEqual(DBValue.double(.nan).sqlLiteral(dialect: .postgresql), "'NaN'::float8")
        XCTAssertEqual(DBValue.double(.infinity).sqlLiteral(dialect: .postgresql), "'Infinity'::float8")
    }

    func testArrayLiteral() {
        let value = DBValue.array([.int(1), .null, .string("a'b")])
        XCTAssertEqual(value.sqlLiteral(dialect: .postgresql), "ARRAY[1, NULL, 'a''b']")
    }

    /// The cast's type name comes from the server's catalogue; one that is not type
    /// spelling is quoted rather than pasted into the statement.
    func testRawCastQuotesATypeNameThatIsNotAType() {
        XCTAssertEqual(
            DBValue.raw(typeName: "mood", text: "happy", bytes: nil).sqlLiteral(dialect: .postgresql),
            "'happy'::mood")
        XCTAssertEqual(
            DBValue.raw(typeName: "my schema.Mood", text: "x", bytes: nil).sqlLiteral(dialect: .postgresql),
            "'x'::my schema.Mood")
        XCTAssertEqual(
            DBValue.raw(typeName: "text; DROP TABLE t; --", text: "x", bytes: nil).sqlLiteral(dialect: .postgresql),
            #"'x'::"text; DROP TABLE t; --""#)
        XCTAssertEqual(
            DBValue.raw(typeName: "mood", text: "x", bytes: nil).sqlLiteral(dialect: .mysql), "'x'")
    }

    func testRenderForDisplaySubstitutesPlaceholders() {
        let sql = "UPDATE t SET a = $1, b = $2 WHERE id = $3"
        let rendered = SQLLiteral.renderForDisplay(
            sql, parameters: [.string("x"), .null, .int(7)], dialect: .postgresql
        )
        XCTAssertEqual(rendered, "UPDATE t SET a = 'x', b = NULL WHERE id = 7")
    }

    func testRenderForDisplayLeavesPlaceholdersInsideLiteralsAlone() {
        let sql = "SELECT '$1', \"$1\", -- $1\n $1"
        let rendered = SQLLiteral.renderForDisplay(sql, parameters: [.int(9)], dialect: .postgresql)
        XCTAssertEqual(rendered, "SELECT '$1', \"$1\", -- $1\n 9")
    }

    func testRenderForDisplayMySQLQuestionMarks() {
        let rendered = SQLLiteral.renderForDisplay(
            "INSERT INTO t VALUES (?, ?)", parameters: [.int(1), .string("a?b")], dialect: .mysql
        )
        XCTAssertEqual(rendered, "INSERT INTO t VALUES (1, 'a?b')")
    }
}
