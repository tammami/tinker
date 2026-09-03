import DBCore
import DBSQL
import Foundation
import XCTest

@testable import DBGrid

final class CSVImportTests: XCTestCase {
    func testReaderHandlesQuotesNewlinesAndBOM() {
        let text = "\u{FEFF}id,name,note\r\n1,\"Smith, John\",\"line one\nline two\"\n2,\"say \"\"hi\"\"\",\n\n3,x,y"
        let rows = CSVReader.parse(text)
        XCTAssertEqual(
            rows,
            [
                ["id", "name", "note"],
                ["1", "Smith, John", "line one\nline two"],
                ["2", "say \"hi\"", ""],
                ["3", "x", "y"],
            ])
    }

    func testReaderAcceptsOtherDelimitersAndCountsRecords() {
        var reader = CSVReader(data: Data("a;b\n1;2\n3;4\n".utf8), delimiter: ";")
        XCTAssertEqual(reader.next(), ["a", "b"])
        XCTAssertEqual(reader.recordNumber, 1)
        XCTAssertEqual(reader.next(), ["1", "2"])
        XCTAssertEqual(reader.next(), ["3", "4"])
        XCTAssertNil(reader.next())
        XCTAssertTrue(reader.isAtEnd)
    }

    func testReaderDecodesUTF8Fields() {
        let rows = CSVReader.parse("name\nwörld\n日本語\n")
        XCTAssertEqual(rows, [["name"], ["wörld"], ["日本語"]])
    }

    let columns = [
        ColumnInfo(ordinal: 1, name: "id", nativeType: "integer", kind: .int, isNullable: false, isPrimaryKey: true),
        ColumnInfo(ordinal: 2, name: "name", nativeType: "text", kind: .string, isNullable: true),
        ColumnInfo(ordinal: 3, name: "price", nativeType: "numeric", kind: .decimal, isNullable: true),
    ]
    let table = TableRef(database: "db", schema: "public", name: "items")

    func testPlanMatchesHeaderNamesCaseInsensitively() {
        let plan = CSVImportPlan.matched(header: ["ID", " Name", "colour"], to: columns, table: table)
        XCTAssertEqual(plan.mapping, ["id", "name", nil])
    }

    func testCoercionRejectsWhatDoesNotFitAndNamesTheRecord() throws {
        let plan = CSVImportPlan(table: table, mapping: ["id", "name", "price"])
        let importer = CSVImporter(plan: plan, columns: columns, dialect: .postgresql)
        XCTAssertEqual(
            try importer.values(for: ["7", "pen", "1.50"], number: 2),
            [.int(7), .string("pen"), .decimal("1.50")]
        )
        XCTAssertThrowsError(try importer.values(for: ["seven", "pen", "1"], number: 3)) { error in
            let described = String(describing: error)
            XCTAssertTrue(described.contains("Record 3"), described)
            XCTAssertTrue(described.contains("integer"), described)
        }
    }

    func testNullTextAndMissingFieldsBecomeNull() throws {
        let plan = CSVImportPlan(table: table, mapping: ["id", "name", "price"], nullText: "\\N")
        let importer = CSVImporter(plan: plan, columns: columns, dialect: .postgresql)
        XCTAssertEqual(try importer.values(for: ["1", "\\N"], number: 1), [.int(1), .null, .null])
    }

    func testInsertStatementBatchesRowsWithBoundParameters() {
        let plan = CSVImportPlan(table: table, mapping: ["id", nil, "price"])
        let importer = CSVImporter(plan: plan, columns: columns, dialect: .postgresql)
        let statement = importer.insertStatement(rows: [[.int(1), .decimal("2")], [.int(3), .null]])
        XCTAssertEqual(
            statement.sql,
            #"INSERT INTO "public"."items" ("id", "price") VALUES ($1, $2), ($3, $4)"#
        )
        XCTAssertEqual(statement.parameters, [.int(1), .decimal("2"), .int(3), .null])
        XCTAssertFalse(statement.expectsSingleRow)

        let mysql = CSVImporter(plan: plan, columns: columns, dialect: .mysql)
            .insertStatement(rows: [[.int(1), .decimal("2")]])
        XCTAssertEqual(mysql.sql, "INSERT INTO `db`.`items` (`id`, `price`) VALUES (?, ?)")
    }

    func testBatchSizeIsBounded() {
        XCTAssertEqual(CSVImportPlan(table: table, mapping: [], batchSize: 0).batchSize, 1)
        XCTAssertEqual(CSVImportPlan(table: table, mapping: [], batchSize: 50_000).batchSize, 1_000)
    }

    func testAlignedTextPadsColumnsAndRightAlignsNumbers() {
        let columns = [
            ColumnMeta(id: 0, name: "id", nativeTypeName: "int4", kind: .int),
            ColumnMeta(id: 1, name: "name", nativeTypeName: "text", kind: .string),
        ]
        let text = ClipboardFormatter.render(
            columns: columns,
            rows: [[.int(1), .string("a")], [.int(100), .null]],
            format: .text,
            options: .init(includeHeader: true)
        )
        XCTAssertEqual(
            text,
            """
             id | name
            ----+-----
              1 | a   
            100 | NULL

            """)
    }
}
