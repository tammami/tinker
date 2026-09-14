import DBCore
import XCTest

@testable import DBGrid

/// Where pasted rows from a spreadsheet, a CSV or another grid go.
final class GridPastePlanTests: XCTestCase {
    private let columns = [
        ColumnInfo(
            ordinal: 1, name: "id", nativeType: "int", kind: .int, isNullable: false, isPrimaryKey: true,
            isAutoIncrement: true),
        ColumnInfo(ordinal: 2, name: "name", nativeType: "varchar(50)", kind: .string, isNullable: false),
        ColumnInfo(ordinal: 3, name: "note", nativeType: "text", kind: .string, isNullable: true),
    ]

    func testSpreadsheetRowsWithEveryColumnBecomeNewRows() throws {
        // Excel: CRLF line ends, a cell with a line break quoted, a trailing line end.
        let text = "1\tAda\tfirst\r\n2\tGrace\t\"two\nlines\"\r\n"
        let plan = try XCTUnwrap(GridPastePlan.make(text: text, columns: columns, focusColumn: 2))
        XCTAssertTrue(plan.appendsRows, "whole records are added, whatever cell has the focus")
        XCTAssertEqual(plan.columns, [0, 1, 2])
        XCTAssertEqual(plan.rows, [["1", "Ada", "first"], ["2", "Grace", "two\nlines"]])
    }

    func testRowsWithoutTheKeyComeInUnderAHeader() throws {
        // Without a header, two fields in a three-column table are cells, not a record.
        let bare = try XCTUnwrap(
            GridPastePlan.make(text: "Ada\tfirst\nGrace\tsecond", columns: columns, focusColumn: 1))
        XCTAssertFalse(bare.appendsRows)
        XCTAssertEqual(bare.columns, [1, 2])
        // With one naming the columns, they are new rows and the id is left to the server.
        let named = try XCTUnwrap(
            GridPastePlan.make(text: "name\tnote\nAda\tfirst\nGrace\tsecond", columns: columns, focusColumn: 0))
        XCTAssertTrue(named.appendsRows)
        XCTAssertEqual(named.columns, [1, 2])
        XCTAssertEqual(named.rows.count, 2)
    }

    func testAHeaderNamesTheColumnsInAnyOrderAndIsNotPasted() throws {
        let plan = try XCTUnwrap(
            GridPastePlan.make(text: "Note\tNAME\nfirst\tAda\nsecond\tGrace", columns: columns, focusColumn: 0))
        XCTAssertTrue(plan.hadHeader)
        XCTAssertTrue(plan.appendsRows)
        XCTAssertEqual(plan.columns, [2, 1])
        XCTAssertEqual(plan.rows, [["first", "Ada"], ["second", "Grace"]])
    }

    func testACSVWithEveryColumnIsSplitOnItsCommas() throws {
        let plan = try XCTUnwrap(
            GridPastePlan.make(text: "1,Ada,\"a, b\"\n2,Grace,x", columns: columns, focusColumn: 1))
        XCTAssertTrue(plan.appendsRows)
        XCTAssertEqual(plan.rows, [["1", "Ada", "a, b"], ["2", "Grace", "x"]])
    }

    func testASemicolonCSVWithAHeaderMapsByName() throws {
        let plan = try XCTUnwrap(GridPastePlan.make(text: "name;note\nAda;first", columns: columns, focusColumn: 0))
        XCTAssertTrue(plan.hadHeader)
        XCTAssertEqual(plan.columns, [1, 2])
        XCTAssertEqual(plan.rows, [["Ada", "first"]])
    }

    func testACommaInsideOneValueIsNotASplit() throws {
        for text in ["Jl. Merdeka, No 5", "a,c", "Jl. A, No 5\nJl. B, No 6"] {
            let plan = try XCTUnwrap(GridPastePlan.make(text: text, columns: columns, focusColumn: 2))
            XCTAssertFalse(plan.appendsRows, text)
            XCTAssertEqual(plan.columns, [2], text)
            XCTAssertEqual(plan.rows.first?.first, text.split(separator: "\n").first.map(String.init), text)
        }
    }

    func testNarrowerCellsFillAcrossFromTheFocus() throws {
        let plan = try XCTUnwrap(GridPastePlan.make(text: "x\ty", columns: columns, focusColumn: 2))
        XCTAssertFalse(plan.appendsRows)
        XCTAssertEqual(plan.columns, [2, nil], "a field past the last column has nowhere to go")
    }

    func testAOneColumnHeaderIsData() {
        XCTAssertNil(GridPastePlan.headerMapping(["name"], names: ["id", "name", "note"]))
        XCTAssertNil(GridPastePlan.headerMapping(["name", "Ada"], names: ["id", "name", "note"]))
    }

    func testNothingToPaste() {
        XCTAssertNil(GridPastePlan.make(text: "", columns: columns, focusColumn: 0))
        XCTAssertNil(GridPastePlan.make(text: "\r\n\n", columns: columns, focusColumn: 0))
        XCTAssertNil(GridPastePlan.make(text: "x", columns: [], focusColumn: 0))
    }
}
