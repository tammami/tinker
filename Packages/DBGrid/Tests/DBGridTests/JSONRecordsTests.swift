import Foundation
import XCTest

@testable import DBGrid

/// The JSON record reader: arrays and JSON Lines, precision kept, nulls as NULL.
final class JSONRecordsTests: XCTestCase {
    func testArrayOfObjectsBecomesRecordsInHeaderOrder() {
        let json = """
            [
              {"id": 1, "name": "Ada", "amount": 12.50, "active": true, "note": null},
              {"id": 2, "name": "Grace \\"the\\" Hopper", "extra": {"a": [1, 2]}, "amount": 99999999999999999999.001}
            ]
            """
        var reader = JSONRecordReader(data: Data(json.utf8))
        XCTAssertEqual(reader.header, ["id", "name", "amount", "active", "note", "extra"])
        XCTAssertEqual(reader.next(), ["1", "Ada", "12.50", "true", "", ""])
        XCTAssertEqual(
            reader.next(), ["2", "Grace \"the\" Hopper", "99999999999999999999.001", "", "", "{\"a\": [1, 2]}"])
        XCTAssertNil(reader.next())
        XCTAssertEqual(reader.recordNumber, 2)
    }

    func testJSONLinesReadTheSameWay() {
        let lines = """
            {"id": 1, "city": "Jakarta"}
            {"id": 2, "city": "Bandung", "pop": 2500000}

            {"id": 3}
            """
        var reader = JSONRecordReader(data: Data(lines.utf8))
        XCTAssertEqual(reader.header, ["id", "city", "pop"])
        var records: [[String]] = []
        while let record = reader.next() { records.append(record) }
        XCTAssertEqual(records, [["1", "Jakarta", ""], ["2", "Bandung", "2500000"], ["3", "", ""]])
    }

    func testUnicodeEscapesAndEmptyFile() {
        var reader = JSONRecordReader(data: Data("[{\"t\": \"caf\\u00e9\\n\"}]".utf8))
        XCTAssertEqual(reader.next(), ["café\n"])
        var empty = JSONRecordReader(data: Data("[]".utf8))
        XCTAssertEqual(empty.header, [])
        XCTAssertNil(empty.next())
    }

    func testFormatDetectionByExtension() {
        XCTAssertEqual(TabularFormat.detect(url: URL(fileURLWithPath: "/x/a.json")), .json)
        XCTAssertEqual(TabularFormat.detect(url: URL(fileURLWithPath: "/x/a.ndjson")), .json)
        XCTAssertEqual(TabularFormat.detect(url: URL(fileURLWithPath: "/x/a.tsv")), .delimited("\t"))
        XCTAssertEqual(TabularFormat.detect(url: URL(fileURLWithPath: "/x/a.csv")), .delimited(","))
    }
}
