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
    }
}
