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
