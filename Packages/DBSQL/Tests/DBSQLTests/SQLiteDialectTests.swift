import DBCore
import XCTest

@testable import DBSQL

/// What DBSQL generates for the SQLite dialect, where it differs from the other two.
final class SQLiteDialectTests: XCTestCase {
    func testIdentifiersUseDoubleQuotesAndATableInMainIsBare() {
        XCTAssertEqual(Identifier.quote("a\"b", dialect: .sqlite), "\"a\"\"b\"")
        XCTAssertEqual(Identifier.qualified(TableRef(schema: .sqlite, name: "orders"), dialect: .sqlite), "\"orders\"")
        XCTAssertEqual(
            Identifier.qualified(TableRef(database: "aux", schema: "aux", name: "orders"), dialect: .sqlite),
            "\"aux\".\"orders\"")
        XCTAssertEqual(Identifier.unquote("`x`", dialect: .sqlite), "x")
        XCTAssertEqual(Identifier.unquote("\"x\"\"y\"", dialect: .sqlite), "x\"y")
        XCTAssertFalse(Identifier.needsQuoting("Orders", dialect: .sqlite), "SQLite keeps case")
        XCTAssertTrue(Identifier.needsQuoting("sqlite_master", dialect: .sqlite))
        XCTAssertTrue(Identifier.needsQuoting("order", dialect: .sqlite))
        XCTAssertTrue(Identifier.needsQuoting("1abc", dialect: .sqlite))
    }

    func testLiteralsHaveNoBackslashEscapesAndNoTypeKeywords() {
        XCTAssertEqual(SQLLiteral.quoteString("a\\b'c", dialect: .sqlite), "'a\\b''c'")
        XCTAssertEqual(DBValue.bool(true).sqlLiteral(dialect: .sqlite), "1")
        XCTAssertEqual(DBValue.date(DBDate(year: 2024, month: 1, day: 2)).sqlLiteral(dialect: .sqlite), "'2024-01-02'")
        XCTAssertEqual(DBValue.time(DBTime(hour: 1, minute: 2, second: 3)).sqlLiteral(dialect: .sqlite), "'01:02:03'")
        XCTAssertEqual(
            DBValue.timestamp(DBTimestamp(date: DBDate(year: 2024, month: 1, day: 2), time: DBTime(hour: 1, minute: 2, second: 3), hasTimeZone: false))
                .sqlLiteral(dialect: .sqlite), "'2024-01-02 01:02:03'")
        XCTAssertEqual(DBValue.json("{\"a\":1}").sqlLiteral(dialect: .sqlite), "'{\"a\":1}'")
        XCTAssertEqual(DBValue.bytes(Data([0xDE, 0xAD])).sqlLiteral(dialect: .sqlite), "X'dead'")
        XCTAssertEqual(DBValue.double(.infinity).sqlLiteral(dialect: .sqlite), "9e999")
        XCTAssertEqual(DBValue.double(.nan).sqlLiteral(dialect: .sqlite), "NULL")
        XCTAssertEqual(SQLLiteral.placeholder(3, dialect: .sqlite), "?")
        XCTAssertEqual(
            SQLLiteral.renderForDisplay("SELECT ? WHERE x = ?", parameters: [.int(1), .string("a")], dialect: .sqlite),
            "SELECT 1 WHERE x = 'a'")
        XCTAssertEqual(SQLLiteral.textCast("c", dialect: .sqlite), "CAST(c AS TEXT)")
    }

    func testTokenizerKnowsBackticksPlaceholdersAndPragma() {
        let tokens = SQLTokenizer.tokenize("PRAGMA `x`; SELECT ? FROM \"t\"", dialect: .sqlite).filter { $0.kind != .whitespace }
        XCTAssertEqual(tokens[0].kind, .keyword)
        XCTAssertEqual(tokens[1].kind, .quotedIdentifier)
        XCTAssertEqual(tokens.first { $0.text == "?" }?.kind, .parameter)
        XCTAssertEqual(tokens.last?.kind, .quotedIdentifier, "double quotes are identifiers, not strings")
    }

    func testATriggerBodySplitsAsOneStatement() {
        let script = """
            CREATE TABLE t (id INTEGER PRIMARY KEY, n INTEGER);
            CREATE TRIGGER t_after AFTER INSERT ON t
            BEGIN
                UPDATE t SET n = CASE WHEN NEW.n IS NULL THEN 0 ELSE NEW.n END WHERE id = NEW.id;
                INSERT INTO log VALUES ('x; not a terminator');
            END;
            BEGIN;
            INSERT INTO t VALUES (1, 2);
            COMMIT;
            -- create trigger in a comment; BEGIN
            select 'END;';
            """
        let statements = StatementSplitter.split(script, dialect: .sqlite)
        XCTAssertEqual(statements.count, 6, statements.map(\.text).joined(separator: "\n---\n"))
        XCTAssertTrue(statements[1].text.hasPrefix("CREATE TRIGGER"))
        XCTAssertTrue(statements[1].text.hasSuffix("END"), statements[1].text)
        XCTAssertEqual(statements[2].text, "BEGIN", "a bare BEGIN is a transaction, not a block")
        XCTAssertEqual(statements[3].text, "INSERT INTO t VALUES (1, 2)")
        XCTAssertTrue(statements[5].text.hasSuffix("select 'END;'"), statements[5].text)
        // Temporary triggers and mixed case too.
        let temp = StatementSplitter.split("create temp trigger x before delete on t begin select 1; end; select 2;", dialect: .sqlite)
        XCTAssertEqual(temp.count, 2)
        XCTAssertTrue(StatementSplitter.isSQLiteTriggerStatement("/* c */ CREATE TEMPORARY TRIGGER"))
        XCTAssertFalse(StatementSplitter.isSQLiteTriggerStatement("CREATE TABLE trigger_log"))
    }

    func testExplainQueryPlanIsReadOnlyAndTheExplainedStatementIsFound() {
        let statement = StatementSplitter.split("EXPLAIN QUERY PLAN SELECT * FROM t", dialect: .sqlite)[0]
        XCTAssertTrue(statement.isProbablyReadOnly)
        XCTAssertEqual(statement.explainedStatement?.statement.text, "SELECT * FROM t")
        XCTAssertEqual(TableOperations.explain("SELECT 1;", analyze: true, dialect: .sqlite), "EXPLAIN QUERY PLAN SELECT 1")
    }

    func testTableOperationsSpeakSQLite() {
        let table = TableRef(schema: .sqlite, name: "t")
        XCTAssertEqual(TableOperations.rename(table, to: "u", dialect: .sqlite), "ALTER TABLE \"t\" RENAME TO \"u\"")
        XCTAssertEqual(MaintenanceAction.available(for: .sqlite), [.analyze, .vacuum, .reindex])
        XCTAssertEqual(TableOperations.maintenance(.vacuum, on: table, dialect: .sqlite), "VACUUM")
        XCTAssertEqual(TableOperations.maintenance(.reindex, on: table, dialect: .sqlite), "REINDEX \"t\"")
        XCTAssertEqual(TableOperations.maintenance(.optimize, on: table, dialect: .sqlite), nil)
        let duplicate = TableOperations.duplicate(table, to: "t2", includeData: false, dialect: .sqlite)
        XCTAssertTrue(duplicate[0].contains("CREATE TABLE \"t2\" AS SELECT * FROM \"t\" WHERE 0"), duplicate[0])
        XCTAssertThrowsError(try UserOperations.create(UserRequest(name: "x", password: "y"), dialect: .sqlite))
    }

    func testDMLUsesReturningAndDefaultValues() throws {
        let generator = DMLGenerator(dialect: .sqlite, table: TableRef(schema: .sqlite, name: "t"), identityColumns: ["id"])
        XCTAssertEqual(try generator.insert(values: [:]).sql, "INSERT INTO \"t\" DEFAULT VALUES RETURNING *")
        XCTAssertEqual(try generator.insert(values: ["a": .int(1)]).sql, "INSERT INTO \"t\" (\"a\") VALUES (?) RETURNING *")
        XCTAssertEqual(try generator.insert(values: ["a": .int(1)], returnRow: false).sql, "INSERT INTO \"t\" (\"a\") VALUES (?)")
    }

    func testFilterQuickSearchFoldsCaseThroughLower() {
        let compiled = FilterCompiler.compile([FilterRule.search("ÖRL", in: ["name"])], dialect: .sqlite)
        XCTAssertEqual(compiled.whereClause, "(lower(CAST(\"name\" AS TEXT)) LIKE lower(?) ESCAPE '!')")
        XCTAssertEqual(compiled.parameters, [.string("%ÖRL%")])
    }

    func testCreateViewDropsBeforeCreating() {
        var model = QueryBuilderModel()
        let t = model.add(TableRef(schema: .sqlite, name: "t"))
        model.fields = [.init(table: t, column: "a")]
        let sql = model.createViewSQL(name: TableRef(schema: .sqlite, name: "v"), dialect: .sqlite)
        XCTAssertTrue(sql?.hasPrefix("DROP VIEW IF EXISTS \"v\";\nCREATE VIEW \"v\" AS") ?? false, sql ?? "nil")
    }

    func testDDLGeneratorCreatesAnInlineRowidKeyAndSchemaScopedObjects() {
        let table = TableRef(schema: .sqlite, name: "t")
        var definition = TableDefinition(ref: table)
        definition.columns = [
            ColumnDefinition(name: "id", type: "INTEGER", isNullable: false, isAutoIncrement: true),
            ColumnDefinition(name: "name", type: "TEXT", collation: "NOCASE"),
        ]
        definition.primaryKey = ["id"]
        definition.indexes = [IndexDefinition(name: "t_name", columns: [IndexColumn(name: "name")], isUnique: true, predicate: "name <> ''")]
        definition.triggers = [
            TriggerInfo(name: "t_touch", timing: .after, events: [.insert, .update], body: "BEGIN SELECT 1; END")
        ]
        let statements = DDLGenerator(dialect: .sqlite).create(definition)
        XCTAssertEqual(
            statements[0].sql,
            "CREATE TABLE \"t\" (\n    \"id\" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,\n    \"name\" TEXT COLLATE NOCASE\n)")
        XCTAssertEqual(statements[1].sql, "CREATE UNIQUE INDEX \"t_name\" ON \"t\" (\"name\") WHERE name <> ''")
        XCTAssertEqual(statements[2].sql, "CREATE TRIGGER \"t_touch\" AFTER INSERT ON \"t\" FOR EACH ROW\nBEGIN SELECT 1; END")
        XCTAssertEqual(statements.map(\.kind), [.createTable, .createIndex, .createTrigger], "no comments, no partitions")
    }
}
