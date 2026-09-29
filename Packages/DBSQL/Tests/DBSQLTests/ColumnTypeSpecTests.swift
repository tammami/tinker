import DBCore
import XCTest

@testable import DBSQL

/// The designer takes a type apart into base/length/decimals/members and must put it back
/// together exactly, or an untouched column would generate a `MODIFY COLUMN`.
final class ColumnTypeSpecTests: XCTestCase {
    func testLengthAndDecimalsRoundTrip() {
        for text in ["varchar(255)", "decimal(10,2)", "int(11) unsigned zerofill", "timestamp(6)", "numeric(12,2)"] {
            let spec = ColumnTypeSpec.parse(text)
            XCTAssertEqual(spec.render(dialect: .mysql), text, text)
        }
        let decimal = ColumnTypeSpec.parse("decimal(10,2)")
        XCTAssertEqual(decimal.base, "decimal")
        XCTAssertEqual(decimal.length, 10)
        XCTAssertEqual(decimal.decimals, 2)
        let unsigned = ColumnTypeSpec.parse("int(11) unsigned zerofill")
        XCTAssertEqual(unsigned.length, 11)
        XCTAssertEqual(unsigned.suffix, "unsigned zerofill")
    }

    func testPlainTypesStayWhole() {
        for text in ["text", "double precision", "timestamp without time zone", "bigint unsigned"] {
            let spec = ColumnTypeSpec.parse(text)
            XCTAssertEqual(spec.render(dialect: .postgresql), text, text)
            XCTAssertNil(spec.length, text)
        }
    }

    func testEnumMembersRoundTripWithQuoting() {
        let spec = ColumnTypeSpec.parse("enum('User','Administrator','it''s')")
        XCTAssertEqual(spec.base, "enum")
        XCTAssertEqual(spec.values, ["User", "Administrator", "it's"])
        XCTAssertTrue(spec.isEnumeration)
        XCTAssertEqual(spec.render(dialect: .mysql), "enum('User','Administrator','it''s')")
        XCTAssertEqual(spec.membersText(dialect: .mysql), "'User','Administrator','it''s'")

        let set = ColumnTypeSpec.parse("set('a','b')")
        XCTAssertEqual(set.values, ["a", "b"])
        XCTAssertEqual(set.render(dialect: .mysql), "set('a','b')")
    }

    func testMembersTypedBareOrQuoted() {
        XCTAssertEqual(ColumnTypeSpec.parseMembers("a, b ,c"), ["a", "b", "c"])
        XCTAssertEqual(ColumnTypeSpec.parseMembers("'x, y','z'"), ["x, y", "z"])
        XCTAssertEqual(ColumnTypeSpec.parseMembers(""), [])
        XCTAssertEqual(ColumnTypeSpec.parseMembers("'', 'a'"), ["", "a"])
    }

    func testChangingLengthRendersTheNewType() {
        var spec = ColumnTypeSpec.parse("varchar(255)")
        spec.length = 100
        XCTAssertEqual(spec.render(dialect: .mysql), "varchar(100)")
        spec = ColumnTypeSpec(base: "decimal", length: 8, decimals: 3)
        XCTAssertEqual(spec.render(dialect: .postgresql), "decimal(8,3)")
        spec = ColumnTypeSpec(base: "enum", values: ["on", "off"])
        XCTAssertEqual(spec.render(dialect: .mysql), "enum('on','off')")
    }

    func testCatalogKnowsWhichTypesTakeLengths() {
        XCTAssertEqual(ColumnTypeCatalog.choice(named: "VARCHAR", dialect: .mysql)?.takesLength, true)
        XCTAssertEqual(ColumnTypeCatalog.choice(named: "decimal", dialect: .mysql)?.takesDecimals, true)
        XCTAssertEqual(ColumnTypeCatalog.choice(named: "text", dialect: .postgresql)?.takesLength, false)
        XCTAssertNil(ColumnTypeCatalog.choice(named: "mood", dialect: .postgresql))
        XCTAssertEqual(ColumnTypeCatalog.choice(named: "timestamp", dialect: .postgresql)?.takesLength, true)
        XCTAssertEqual(
            ColumnTypeCatalog.choice(named: "timestamp", dialect: .postgresql)?.suffixes,
            ["without time zone", "with time zone"])
        XCTAssertEqual(
            ColumnTypeCatalog.choice(named: "int", dialect: .mysql)?.suffixes, ["", "unsigned", "unsigned zerofill"])
        XCTAssertNil(ColumnTypeCatalog.choice(named: "timestamp without time zone", dialect: .postgresql))
    }

    func testCatalogAnswersToTheNamesTheDocumentationGives() {
        // PostgreSQL's documented names, and the catalog names other clients show.
        XCTAssertEqual(ColumnTypeCatalog.choice(named: "int8", dialect: .postgresql)?.name, "bigint")
        XCTAssertEqual(ColumnTypeCatalog.choice(named: "int4", dialect: .postgresql)?.name, "integer")
        XCTAssertEqual(ColumnTypeCatalog.choice(named: "int2", dialect: .postgresql)?.name, "smallint")
        XCTAssertEqual(ColumnTypeCatalog.choice(named: "float8", dialect: .postgresql)?.name, "double precision")
        XCTAssertEqual(ColumnTypeCatalog.choice(named: "varchar", dialect: .postgresql)?.name, "character varying")
        XCTAssertEqual(ColumnTypeCatalog.choice(named: "bool", dialect: .postgresql)?.name, "boolean")
        XCTAssertEqual(ColumnTypeCatalog.choice(named: "bigint", dialect: .postgresql)?.title, "bigint · int8")
        // A name wins over an alias.
        XCTAssertEqual(ColumnTypeCatalog.choice(named: "serial", dialect: .postgresql)?.name, "serial")
        XCTAssertEqual(ColumnTypeCatalog.choice(named: "real", dialect: .mysql)?.name, "double")
        XCTAssertEqual(ColumnTypeCatalog.choice(named: "INTEGER", dialect: .mysql)?.name, "int")
        XCTAssertEqual(ColumnTypeCatalog.choice(named: "integer", dialect: .sqlite)?.name, "INTEGER")
        XCTAssertEqual(ColumnTypeCatalog.choice(named: "int", dialect: .sqlite)?.name, "INTEGER")
    }

    func testCatalogCarriesEveryDocumentedType() {
        let postgres = Set(ColumnTypeCatalog.choices(for: .postgresql).map(\.name))
        for name in [
            "bigint", "bigserial", "bit", "bit varying", "boolean", "box", "bytea", "character", "character varying",
            "cidr", "circle", "date", "double precision", "inet", "integer", "interval", "json", "jsonb", "line",
            "lseg", "macaddr", "macaddr8", "money", "numeric", "path", "pg_lsn", "pg_snapshot", "point", "polygon",
            "real", "smallint", "smallserial", "serial", "text", "time", "timestamp", "tsquery", "tsvector",
            "txid_snapshot", "uuid", "xml", "int4range", "int8range", "numrange", "tsrange", "tstzrange",
            "daterange", "int4multirange", "oid",
        ] {
            XCTAssertTrue(postgres.contains(name), "PostgreSQL: \(name)")
        }
        let mysql = Set(ColumnTypeCatalog.choices(for: .mysql).map(\.name))
        for name in [
            "tinyint", "smallint", "mediumint", "int", "bigint", "decimal", "float", "double", "bit", "boolean",
            "serial", "date", "time", "datetime", "timestamp", "year", "char", "varchar", "binary", "varbinary",
            "tinyblob", "blob", "mediumblob", "longblob", "tinytext", "text", "mediumtext", "longtext", "enum",
            "set", "json", "geometry", "point", "linestring", "polygon", "multipoint", "multilinestring",
            "multipolygon", "geometrycollection", "vector",
        ] {
            XCTAssertTrue(mysql.contains(name), "MySQL: \(name)")
        }
        let sqlite = Set(ColumnTypeCatalog.choices(for: .sqlite).map(\.name))
        for name in [
            "INTEGER", "TINYINT", "SMALLINT", "MEDIUMINT", "BIGINT", "UNSIGNED BIG INT", "INT2", "INT8", "CHARACTER",
            "VARCHAR", "VARYING CHARACTER", "NCHAR", "NATIVE CHARACTER", "NVARCHAR", "TEXT", "CLOB", "BLOB", "REAL",
            "DOUBLE", "DOUBLE PRECISION", "FLOAT", "NUMERIC", "DECIMAL", "BOOLEAN", "DATE", "DATETIME", "ANY",
        ] {
            XCTAssertTrue(sqlite.contains(name), "SQLite: \(name)")
        }
        for dialect in SQLDialect.allCases {
            let choices = ColumnTypeCatalog.choices(for: dialect)
            XCTAssertEqual(Set(choices.map(\.name)).count, choices.count, "\(dialect): a name is listed twice")
            XCTAssertTrue(choices.allSatisfy { !$0.group.isEmpty && !$0.summary.isEmpty }, "\(dialect)")
            XCTAssertTrue(choices.allSatisfy { ColumnTypeSpec.isSafeTypeText($0.name) }, "\(dialect)")
        }
    }

    func testCatalogOffersOnlyWhatTheServerHas() {
        func version(_ major: Int, _ minor: Int, _ flavor: ServerFlavor) -> ServerVersion {
            ServerVersion(major: major, minor: minor, patch: 0, flavor: flavor, rawString: "\(major).\(minor)")
        }
        XCTAssertNil(ColumnTypeCatalog.choice(named: "vector", dialect: .mysql, version: version(8, 4, .mysql)))
        XCTAssertNotNil(ColumnTypeCatalog.choice(named: "vector", dialect: .mysql, version: version(9, 4, .mysql)))
        XCTAssertNil(ColumnTypeCatalog.choice(named: "uuid", dialect: .mysql, version: version(9, 4, .mysql)))
        XCTAssertNotNil(ColumnTypeCatalog.choice(named: "uuid", dialect: .mysql, version: version(11, 8, .mariadb)))
        XCTAssertNil(ColumnTypeCatalog.choice(named: "inet4", dialect: .mysql, version: version(10, 6, .mariadb)))
        XCTAssertNil(
            ColumnTypeCatalog.choice(named: "int4multirange", dialect: .postgresql, version: version(13, 0, .postgresql)))
        XCTAssertNotNil(
            ColumnTypeCatalog.choice(named: "int4multirange", dialect: .postgresql, version: version(16, 0, .postgresql)))
        XCTAssertEqual(ColumnTypeCatalog.choice(named: "serial", dialect: .postgresql)?.isCreationOnly, true)
    }

    /// Every spelling a server writes must come back character for character, or the
    /// generator would emit a type change nobody asked for.
    func testServerSpellingsRoundTripExactly() {
        let spellings = [
            "numeric(10,2)[]", "character varying(20)[]", "integer[][]", "timestamp(6) without time zone",
            "timestamp with time zone", "time(3) with time zone", "int unsigned", "bigint unsigned zerofill",
            "int(11) unsigned zerofill", "decimal(10,2) unsigned", "double precision", "interval day(2)",
            "geometry(Point,4326)", "\"Mood\"", "public.mood", "enum('a','b')", "set('x','y')",
        ]
        for text in spellings {
            XCTAssertEqual(ColumnTypeSpec.parse(text).render(dialect: .postgresql), text, text)
        }
    }

    func testArraysAndBareModifiersComeApart() {
        let array = ColumnTypeSpec.parse("numeric(10,2)[]")
        XCTAssertEqual(array.base, "numeric")
        XCTAssertEqual(array.length, 10)
        XCTAssertEqual(array.decimals, 2)
        XCTAssertEqual(array.array, "[]")
        let zoned = ColumnTypeSpec.parse("timestamp(6) without time zone")
        XCTAssertEqual(zoned.base, "timestamp")
        XCTAssertEqual(zoned.length, 6)
        XCTAssertEqual(zoned.suffix, "without time zone")
        let bareZone = ColumnTypeSpec.parse("time with time zone")
        XCTAssertEqual(bareZone.base, "time")
        XCTAssertEqual(bareZone.suffix, "with time zone")
        let unsigned = ColumnTypeSpec.parse("bigint unsigned zerofill")
        XCTAssertEqual(unsigned.base, "bigint")
        XCTAssertEqual(unsigned.suffix, "unsigned zerofill")
        XCTAssertEqual(ColumnTypeSpec.parse("int unsigned").base, "int")
        // Given a length through the designer, the precision lands before the zone words.
        var edited = bareZone
        edited.length = 3
        XCTAssertEqual(edited.render(dialect: .postgresql), "time(3) with time zone")
        var wide = unsigned
        wide.length = 20
        XCTAssertEqual(wide.render(dialect: .mysql), "bigint(20) unsigned zerofill")
    }

    func testRenderDropsWhatCannotBeATypeButKeepsMembersQuoted() {
        XCTAssertFalse(ColumnTypeSpec.isSafeTypeText("text; DROP TABLE x"))
        XCTAssertTrue(ColumnTypeSpec.isSafeTypeText("character varying(20)[]"))
        let hostile = ColumnTypeSpec.parse("text; DROP TABLE x -- ")
        XCTAssertEqual(hostile.render(dialect: .postgresql), "text DROP TABLE x ")
        var spec = ColumnTypeSpec(base: "varchar", length: 10, suffix: "'; DROP TABLE t; --")
        XCTAssertEqual(spec.render(dialect: .mysql), "varchar(10)  DROP TABLE t ")
        spec = ColumnTypeSpec(base: "enum", values: ["a'); DROP TABLE t; --", "b"])
        XCTAssertEqual(spec.render(dialect: .mysql), "enum('a''); DROP TABLE t; --','b')")
        XCTAssertEqual(
            ColumnTypeSpec.normalized("varchar(255); DROP TABLE t", dialect: .mysql), "varchar(255)  DROP TABLE t")
    }
}
