import DBCore
import XCTest

@testable import DBSQL

/// What a table definition becomes on another engine.
final class SchemaTranslatorTests: XCTestCase {
    func testMySQLTypesBecomePostgresTypesInPostgresSpelling() {
        let cases: [(String, String)] = [
            ("tinyint(1)", "boolean"), ("tinyint", "smallint"), ("int", "integer"), ("int unsigned", "bigint"),
            ("bigint", "bigint"), ("bigint unsigned", "numeric(20,0)"), ("float", "real"), ("double", "double precision"),
            ("decimal(12,4)", "numeric(12,4)"), ("varchar(255)", "character varying(255)"), ("char(8)", "character(8)"),
            ("text", "text"), ("longtext", "text"), ("blob", "bytea"), ("varbinary(16)", "bytea"), ("date", "date"),
            ("datetime", "timestamp without time zone"), ("datetime(6)", "timestamp(6) without time zone"),
            ("timestamp", "timestamp with time zone"), ("time", "time without time zone"), ("year", "smallint"),
            ("json", "jsonb"), ("enum('a','b')", "text"), ("set('x','y')", "text"), ("bit(1)", "boolean"),
            ("bit(8)", "bit(8)"), ("geometry", "text"), ("mediumint", "integer"),
        ]
        for (mysql, postgres) in cases {
            XCTAssertEqual(SchemaTranslator.translateType(mysql, from: .mysql, to: .postgresql), postgres, mysql)
        }
    }

    func testPostgresTypesBecomeMySQLTypes() {
        let cases: [(String, String)] = [
            ("boolean", "tinyint(1)"), ("smallint", "smallint"), ("integer", "int"), ("bigint", "bigint"),
            ("real", "float"), ("double precision", "double"), ("numeric(10,2)", "decimal(10,2)"),
            ("numeric(80,40)", "decimal(65,30)"), ("character varying(100)", "varchar(100)"),
            ("character varying(20000)", "text"), ("character varying", "text"), ("character(3)", "char(3)"),
            ("text", "longtext"), ("bytea", "longblob"), ("timestamp without time zone", "datetime"),
            ("timestamp(3) with time zone", "datetime(3)"), ("time with time zone", "varchar(32)"), ("time(3) without time zone", "time(3)"), ("uuid", "char(36)"),
            ("jsonb", "json"), ("integer[]", "json"), ("interval", "varchar(64)"), ("inet", "varchar(45)"),
            ("money", "decimal(19,2)"), ("xml", "longtext"), ("citext", "longtext"),
        ]
        for (postgres, mysql) in cases {
            XCTAssertEqual(SchemaTranslator.translateType(postgres, from: .postgresql, to: .mysql), mysql, postgres)
        }
        XCTAssertEqual(
            SchemaTranslator.translateType("mood", enumLabels: ["sad", "ok"], from: .postgresql, to: .mysql),
            "enum('sad','ok')", "a PostgreSQL enum type becomes a MySQL ENUM")
        XCTAssertEqual(SchemaTranslator.translateType("mood", enumLabels: ["sad"], from: .postgresql, to: .sqlite), "TEXT")
    }

    func testEverythingBecomesSQLiteAffinityNamesAndBack() {
        XCTAssertEqual(SchemaTranslator.translateType("int unsigned", from: .mysql, to: .sqlite), "INTEGER")
        XCTAssertEqual(SchemaTranslator.translateType("double precision", from: .postgresql, to: .sqlite), "REAL")
        XCTAssertEqual(SchemaTranslator.translateType("numeric(12,2)", from: .postgresql, to: .sqlite), "NUMERIC(12,2)")
        XCTAssertEqual(SchemaTranslator.translateType("timestamptz", from: .postgresql, to: .sqlite), "DATETIME")
        XCTAssertEqual(SchemaTranslator.translateType("varchar(40)", from: .mysql, to: .sqlite), "VARCHAR(40)")
        XCTAssertEqual(SchemaTranslator.translateType("bytea", from: .postgresql, to: .sqlite), "BLOB")
        XCTAssertEqual(SchemaTranslator.translateType("INTEGER", from: .sqlite, to: .postgresql), "bigint")
        XCTAssertEqual(SchemaTranslator.translateType("INTEGER", from: .sqlite, to: .mysql), "bigint")
        XCTAssertEqual(SchemaTranslator.translateType("REAL", from: .sqlite, to: .mysql), "double")
        XCTAssertEqual(SchemaTranslator.translateType("TEXT", from: .sqlite, to: .postgresql), "text")
        XCTAssertEqual(SchemaTranslator.translateType("DATETIME", from: .sqlite, to: .postgresql), "timestamp without time zone")
        XCTAssertEqual(SchemaTranslator.translateType("", from: .sqlite, to: .mysql), "longtext", "an untyped column is text")
        XCTAssertEqual(SchemaTranslator.translateType("BOOLEAN", from: .sqlite, to: .mysql), "tinyint(1)")
        XCTAssertEqual(SchemaTranslator.translateType("int", from: .mysql, to: .mysql), "int", "same engine: untouched")
    }

    func testDefaultsTravelWhenTheTargetCanReadThem() {
        XCTAssertEqual(SchemaTranslator.translateDefault("CURRENT_TIMESTAMP", from: .mysql, to: .postgresql), "CURRENT_TIMESTAMP")
        XCTAssertEqual(SchemaTranslator.translateDefault("now()", from: .postgresql, to: .mysql), "CURRENT_TIMESTAMP")
        XCTAssertEqual(SchemaTranslator.translateDefault("'plain'::text", from: .postgresql, to: .mysql), "'plain'")
        XCTAssertEqual(SchemaTranslator.translateDefault("'it''s'::character varying", from: .postgresql, to: .sqlite), "'it''s'")
        XCTAssertEqual(SchemaTranslator.translateDefault("0", from: .mysql, to: .postgresql), "0")
        XCTAssertEqual(SchemaTranslator.translateDefault("12.5", from: .mysql, to: .sqlite), "12.5")
        XCTAssertEqual(SchemaTranslator.translateDefault("true", from: .postgresql, to: .mysql), "1")
        XCTAssertEqual(SchemaTranslator.translateDefault("b'0'", from: .mysql, to: .postgresql), "false")
        XCTAssertNil(SchemaTranslator.translateDefault("nextval('t_id_seq'::regclass)", from: .postgresql, to: .mysql))
        XCTAssertNil(SchemaTranslator.translateDefault("'0000-00-00 00:00:00'", from: .mysql, to: .postgresql))
        XCTAssertEqual(SchemaTranslator.translateDefault("gen_random_uuid()", from: .postgresql, to: .mysql), "(uuid())")
        XCTAssertNil(SchemaTranslator.translateDefault("uuid()", from: .mysql, to: .sqlite))
        XCTAssertEqual(SchemaTranslator.translateDefault("(id * 2)", from: .mysql, to: .postgresql), "id * 2")
        XCTAssertEqual(SchemaTranslator.translateDefault("upper(name)", from: .postgresql, to: .mysql), "(upper(name))")
        XCTAssertNil(SchemaTranslator.translateDefault("upper(name)", from: .postgresql, to: .sqlite))
        XCTAssertEqual(SchemaTranslator.stripCasts("('{}'::jsonb)"), "'{}'")
        XCTAssertEqual(SchemaTranslator.stripCasts("'a'::character varying(10)[]"), "'a'")
    }

    func testADefinitionCrossesWithItsKeysAndNotesWhatStayedBehind() {
        let source = SchemaRef.mysql("shop")
        var definition = TableDefinition(ref: TableRef(schema: source, name: "orders"))
        definition.columns = [
            ColumnDefinition(name: "id", type: "int unsigned", isNullable: false, isAutoIncrement: true),
            ColumnDefinition(name: "customer_id", type: "int", isNullable: false),
            ColumnDefinition(name: "total", type: "decimal(12,2)", isNullable: false, defaultExpression: "0.00"),
            ColumnDefinition(name: "note", type: "varchar(255)", characterSet: "utf8mb4", collation: "utf8mb4_bin"),
            ColumnDefinition(name: "placed_at", type: "datetime", defaultExpression: "CURRENT_TIMESTAMP"),
            ColumnDefinition(name: "total_twice", type: "decimal(12,2)", generatedExpression: "total * 2"),
        ]
        definition.primaryKey = ["id"]
        definition.indexes = [
            IndexDefinition(name: "orders_customer", columns: [IndexColumn(name: "customer_id")], isUnique: false, method: "BTREE"),
            IndexDefinition(name: "orders_note_ft", columns: [IndexColumn(name: "note")], isUnique: false, method: "FULLTEXT"),
            IndexDefinition(name: "orders_prefix", columns: [IndexColumn(name: "note", prefixLength: 20)], isUnique: false),
        ]
        definition.foreignKeys = [
            ForeignKeyDefinition(
                name: "orders_customer_fk", columns: ["customer_id"],
                referencedTable: TableRef(schema: source, name: "customers"), referencedColumns: ["id"],
                onUpdate: .restrict, onDelete: .cascade)
        ]
        definition.checks = [CheckDefinition(name: "total_positive", expression: "`total` >= 0")]
        definition.triggers = [TriggerInfo(name: "orders_touch", timing: .after, events: [.insert], body: "BEGIN END")]
        definition.options = TableOptions(engine: "InnoDB", characterSet: "utf8mb4", collation: "utf8mb4_0900_ai_ci")

        let target = SchemaRef(database: "estia", schema: "public")
        let translation = SchemaTranslator.translate(definition, from: .mysql, to: .postgresql, into: target)
        let result = translation.definition
        XCTAssertEqual(result.ref, TableRef(schema: target, name: "orders"))
        XCTAssertEqual(result.columns.map(\.type), [
            "bigint", "integer", "numeric(12,2)", "character varying(255)", "timestamp without time zone", "numeric(12,2)",
        ])
        XCTAssertEqual(result.columns[0].isAutoIncrement, true)
        XCTAssertEqual(result.columns[2].defaultExpression, "0.00")
        XCTAssertEqual(result.columns[4].defaultExpression, "CURRENT_TIMESTAMP")
        XCTAssertNil(result.columns[3].collation)
        XCTAssertNil(result.columns[5].generatedExpression)
        XCTAssertEqual(result.indexes.map(\.name), ["orders_customer", "orders_prefix"], "the full-text index stays behind")
        XCTAssertNil(result.indexes[0].method)
        XCTAssertNil(result.indexes[1].columns[0].prefixLength)
        XCTAssertEqual(result.foreignKeys.first?.referencedTable, TableRef(schema: target, name: "customers"))
        XCTAssertEqual(result.foreignKeys.first?.onDelete, .cascade)
        XCTAssertTrue(result.checks.isEmpty)
        XCTAssertTrue(result.triggers.isEmpty)
        XCTAssertEqual(result.options, TableOptions())
        XCTAssertEqual(translation.notes.count, 4, translation.notes.joined(separator: "\n"))

        // What DDLGenerator makes of it must be PostgreSQL that creates the table.
        let sql = DDLGenerator(dialect: .postgresql).create(result).map(\.sql).joined(separator: ";\n")
        XCTAssertTrue(sql.contains("\"id\" bigint NOT NULL GENERATED BY DEFAULT AS IDENTITY"), sql)
        XCTAssertTrue(sql.contains("REFERENCES \"public\".\"customers\" (\"id\")"), sql)
        XCTAssertTrue(sql.contains("CREATE INDEX \"orders_customer\" ON \"public\".\"orders\" (\"customer_id\")"), sql)
        XCTAssertFalse(sql.contains("FULLTEXT"))
        XCTAssertFalse(sql.contains("CHECK"))

        let same = SchemaTranslator.translate(definition, from: .mysql, to: .mysql)
        XCTAssertEqual(same.definition, definition, "the same engine changes nothing")
        XCTAssertTrue(same.notes.isEmpty)
    }
}

/// Literals that cross engines: arrays as JSON, zone offsets MySQL can read.
final class CrossEngineLiteralTests: XCTestCase {
    func testArraysBecomeJSONOnEnginesWithoutArrays() {
        let array = DBValue.array([.string("a\"b"), .int(2), .null, .bool(true), .string("line\nbreak")])
        XCTAssertEqual(array.sqlLiteral(dialect: .mysql), "'[\"a\\\\\"b\",2,null,true,\"line\\\\nbreak\"]'")
        XCTAssertEqual(array.sqlLiteral(dialect: .sqlite), "'[\"a\\\"b\",2,null,true,\"line\\n\\break\"]'".replacingOccurrences(of: "\\break", with: "break"))
        XCTAssertEqual(SQLLiteral.jsonArray([.array([.int(1)]), .json("{\"k\":1}")]), "[[1],{\"k\":1}]")
        XCTAssertTrue(array.sqlLiteral(dialect: .postgresql).hasPrefix("ARRAY["))
    }

    func testAZonedTimestampIsWrittenForMySQLWithAFullOffset() {
        let value = DBValue.timestamp(
            DBTimestamp(
                date: DBDate(year: 2026, month: 9, day: 9),
                time: DBTime(hour: 13, minute: 0, second: 5, microsecond: 250_000, tzOffsetSeconds: 7 * 3_600),
                hasTimeZone: true, serverText: "2026-09-09 13:00:05.25+07"))
        XCTAssertEqual(value.sqlLiteral(dialect: .mysql), "TIMESTAMP '2026-09-09 13:00:05.25+07:00'")
        XCTAssertEqual(value.sqlLiteral(dialect: .postgresql), "'2026-09-09 13:00:05.25+07'::timestamptz")
        let plain = DBValue.timestamp(
            DBTimestamp(date: DBDate(year: 2026, month: 1, day: 2), time: DBTime(hour: 3, minute: 4, second: 5), hasTimeZone: false))
        XCTAssertEqual(plain.sqlLiteral(dialect: .mysql), "TIMESTAMP '2026-01-02 03:04:05'")
    }
}
