import DBCore
import XCTest
@testable import DBSQL

final class StatementSplitterTests: XCTestCase {
    func testSplitsOnSemicolons() {
        let statements = StatementSplitter.split("SELECT 1; SELECT 2;\nSELECT 3", dialect: .postgresql)
        XCTAssertEqual(statements.map(\.text), ["SELECT 1", "SELECT 2", "SELECT 3"])
        XCTAssertEqual(statements.map(\.terminator), [";", ";", nil])
        XCTAssertEqual(statements.map(\.startLine), [1, 1, 2])
    }

    func testIgnoresSemicolonsInsideStrings() {
        let sql = "SELECT ';' AS a; SELECT 'it''s; fine'"
        let statements = StatementSplitter.split(sql, dialect: .postgresql)
        XCTAssertEqual(statements.map(\.text), ["SELECT ';' AS a", "SELECT 'it''s; fine'"])
    }

    func testIgnoresSemicolonsInsideQuotedIdentifiers() {
        let statements = StatementSplitter.split("SELECT \"a;b\" FROM t; SELECT 1", dialect: .postgresql)
        XCTAssertEqual(statements.map(\.text), ["SELECT \"a;b\" FROM t", "SELECT 1"])
    }

    func testIgnoresSemicolonsInsideBackticks() {
        let statements = StatementSplitter.split("SELECT `a;b` FROM t; SELECT 1", dialect: .mysql)
        XCTAssertEqual(statements.map(\.text), ["SELECT `a;b` FROM t", "SELECT 1"])
    }

    func testIgnoresSemicolonsInsideComments() {
        let shared = """
        SELECT 1; -- trailing; comment
        /* block ; comment */ SELECT 2;
        SELECT 3
        """
        let pg = StatementSplitter.split(shared, dialect: .postgresql)
        XCTAssertEqual(pg.map { $0.text.hasSuffix("3") }, [false, false, true])
        XCTAssertEqual(pg.count, 3)

        // `#` starts a line comment in MySQL only; PostgreSQL would see an operator there.
        let mysql = StatementSplitter.split("SELECT 1; # a ; b\nSELECT 2", dialect: .mysql)
        XCTAssertEqual(mysql.count, 2)
        XCTAssertEqual(StatementSplitter.split("SELECT 1; # a ; b\nSELECT 2", dialect: .postgresql).count, 3)
    }

    func testNestedBlockCommentsArePostgresOnly() {
        let sql = "SELECT /* outer /* inner */ still comment */ 1; SELECT 2"
        XCTAssertEqual(StatementSplitter.split(sql, dialect: .postgresql).count, 2)
    }

    func testDollarQuotedBodyKeepsItsSemicolons() {
        let sql = """
        CREATE FUNCTION f() RETURNS int AS $$
        BEGIN
            RETURN 1;
        END;
        $$ LANGUAGE plpgsql;
        SELECT f()
        """
        let statements = StatementSplitter.split(sql, dialect: .postgresql)
        XCTAssertEqual(statements.count, 2)
        XCTAssertTrue(statements[0].text.contains("RETURN 1;"))
        XCTAssertEqual(statements[1].text, "SELECT f()")
    }

    func testTaggedDollarQuoting() {
        let sql = "SELECT $tag$ a ; $$ b $tag$; SELECT 2"
        let statements = StatementSplitter.split(sql, dialect: .postgresql)
        XCTAssertEqual(statements.count, 2)
        XCTAssertEqual(statements[1].text, "SELECT 2")
    }

    func testDollarParameterIsNotADollarQuote() {
        let statements = StatementSplitter.split("SELECT $1; SELECT $2", dialect: .postgresql)
        XCTAssertEqual(statements.map(\.text), ["SELECT $1", "SELECT $2"])
    }

    func testMySQLDelimiterDirective() {
        let sql = """
        DELIMITER $$
        CREATE PROCEDURE p()
        BEGIN
            SELECT 1;
            SELECT 2;
        END$$
        DELIMITER ;
        SELECT 3;
        """
        let statements = StatementSplitter.split(sql, dialect: .mysql)
        XCTAssertEqual(statements.count, 2)
        XCTAssertTrue(statements[0].text.hasPrefix("CREATE PROCEDURE p()"))
        XCTAssertTrue(statements[0].text.contains("SELECT 1;"))
        XCTAssertEqual(statements[1].text, "SELECT 3")
    }

    func testCommentOnlyInputProducesNoStatements() {
        XCTAssertTrue(StatementSplitter.split("-- nothing here\n/* nor here */", dialect: .postgresql).isEmpty)
        XCTAssertTrue(StatementSplitter.split("   \n\t ", dialect: .postgresql).isEmpty)
        XCTAssertTrue(StatementSplitter.split(";;;", dialect: .postgresql).isEmpty)
    }

    func testRangesPointAtTheOriginalText() {
        let sql = "  SELECT 1;\n  SELECT 'πé';"
        let statements = StatementSplitter.split(sql, dialect: .postgresql)
        let utf16 = Array(sql.utf16)
        for statement in statements {
            let slice = String(decoding: utf16[statement.utf16Range], as: UTF16.self)
            XCTAssertEqual(slice, statement.text)
        }
    }

    func testStatementAtCursor() {
        let sql = "SELECT 1;\nSELECT 2;\nSELECT 3"
        XCTAssertEqual(StatementSplitter.statement(at: 0, in: sql, dialect: .postgresql)?.text, "SELECT 1")
        XCTAssertEqual(StatementSplitter.statement(at: 12, in: sql, dialect: .postgresql)?.text, "SELECT 2")
        XCTAssertEqual(StatementSplitter.statement(at: 25, in: sql, dialect: .postgresql)?.text, "SELECT 3")
        // Cursor sitting right after a terminator belongs to the statement that just ended.
        XCTAssertEqual(StatementSplitter.statement(at: 9, in: sql, dialect: .postgresql)?.text, "SELECT 1")
    }

    func testLeadingKeywordAndReadOnlyDetection() {
        func statement(_ sql: String) -> SQLStatement {
            StatementSplitter.split(sql, dialect: .postgresql)[0]
        }
        XCTAssertEqual(statement("  -- c\n select 1").leadingKeyword, "SELECT")
        XCTAssertEqual(statement("(SELECT 1) UNION (SELECT 2)").leadingKeyword, "SELECT")
        XCTAssertTrue(statement("SELECT 1").isProbablyReadOnly)
        XCTAssertTrue(statement("WITH x AS (SELECT 1) SELECT * FROM x").isProbablyReadOnly)
        XCTAssertFalse(statement("WITH x AS (SELECT 1) INSERT INTO t SELECT * FROM x").isProbablyReadOnly)
        XCTAssertFalse(statement("UPDATE t SET a = 1").isProbablyReadOnly)
        XCTAssertFalse(statement("DROP TABLE t").isProbablyReadOnly)
    }

    func testShortLabelCollapsesWhitespace() {
        let statement = StatementSplitter.split("SELECT\n   a,\n   b\nFROM t", dialect: .postgresql)[0]
        XCTAssertEqual(statement.shortLabel, "SELECT a, b FROM t")
    }

    func testLargeScriptSplitsCorrectly() {
        // The acceptance criterion in SPEC §13.3 is a 2,000-statement dump with routines.
        var script = ""
        for index in 0 ..< 1_000 {
            script += "INSERT INTO t (a) VALUES ('v;\(index)');\n"
        }
        script += "DELIMITER $$\n"
        for index in 0 ..< 1_000 {
            script += "CREATE PROCEDURE p\(index)() BEGIN SELECT 1; SELECT 2; END$$\n"
        }
        let statements = StatementSplitter.split(script, dialect: .mysql)
        XCTAssertEqual(statements.count, 2_000)
        XCTAssertTrue(statements[0].text.hasPrefix("INSERT INTO t"))
        XCTAssertTrue(statements[1_999].text.contains("SELECT 2;"))
    }

    func testUnterminatedConstructsDoNotHang() {
        XCTAssertEqual(StatementSplitter.split("SELECT 'unterminated", dialect: .postgresql).count, 1)
        XCTAssertEqual(StatementSplitter.split("SELECT $$unterminated", dialect: .postgresql).count, 1)
        XCTAssertEqual(StatementSplitter.split("SELECT /* unterminated", dialect: .postgresql).count, 1)
    }
}
