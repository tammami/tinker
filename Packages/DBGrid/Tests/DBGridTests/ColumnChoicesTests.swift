import DBCore
import XCTest

@testable import DBGrid

/// The values an enum or SET column offers, and what the grid refuses to write to one.
final class ColumnChoicesTests: XCTestCase {
    private func column(_ nativeType: String, labels: [String]?, nullable: Bool = true) -> ColumnInfo {
        ColumnInfo(
            ordinal: 1, name: "c", nativeType: nativeType, kind: .string, isNullable: nullable, enumLabels: labels)
    }

    func testAColumnWithoutLabelsTakesFreeValues() {
        XCTAssertNil(ColumnChoices(column: column("varchar(20)", labels: nil)))
        XCTAssertNil(ColumnChoices(column: column("enum('')", labels: [])))
    }

    func testAnEnumTakesExactlyOneOfItsLabels() throws {
        let choices = try XCTUnwrap(
            ColumnChoices(column: column("enum('angkat meter','segel')", labels: ["angkat meter", "segel"])))
        XCTAssertFalse(choices.allowsMany)
        XCTAssertEqual(choices.labels, ["angkat meter", "segel"], "declaration order is kept")
        XCTAssertTrue(choices.accepts("segel"))
        XCTAssertFalse(choices.accepts("Segel"), "a label is matched as declared, so a typo is caught")
        XCTAssertFalse(choices.accepts("angkat meter,segel"), "an enum holds one value")
        XCTAssertTrue(choices.accepts(""), "empty is NULL, which a nullable column takes")
        XCTAssertEqual(choices.refusal(of: "segl"), "“segl” is not one of “angkat meter”, “segel”.")
    }

    func testANotNullEnumRefusesNull() throws {
        let choices = try XCTUnwrap(
            ColumnChoices(column: column("enum('a','b')", labels: ["a", "b"], nullable: false)))
        XCTAssertFalse(choices.accepts(""))
        XCTAssertTrue(choices.refusal(of: "").contains("NULL"))
    }

    func testASetTakesAnyCombinationWrittenInDeclarationOrder() throws {
        let choices = try XCTUnwrap(ColumnChoices(column: column("set('x','y','z')", labels: ["x", "y", "z"])))
        XCTAssertTrue(choices.allowsMany)
        XCTAssertTrue(choices.accepts("z,x"))
        XCTAssertFalse(choices.accepts("x,w"))
        XCTAssertEqual(choices.members(of: "z,x"), ["x", "z"])
        XCTAssertNil(choices.members(of: "x,,y"), "an empty part is not a label")
        XCTAssertEqual(choices.text(for: ["z", "x"]), "x,z")
        XCTAssertEqual(choices.text(for: []), "")
    }

    func testAPostgresEnumTypeIsNotASet() throws {
        let choices = try XCTUnwrap(ColumnChoices(column: column("mood", labels: ["sad", "ok"])))
        XCTAssertFalse(choices.allowsMany)
    }

    func testByNameKeepsOnlyColumnsWithChoices() {
        let map = ColumnChoices.byName([
            ColumnInfo(ordinal: 1, name: "id", nativeType: "int", kind: .int, isNullable: false),
            ColumnInfo(
                ordinal: 2, name: "jenis", nativeType: "enum('a')", kind: .string, isNullable: true,
                enumLabels: ["a"]),
        ])
        XCTAssertEqual(Array(map.keys), ["jenis"])
    }
}
