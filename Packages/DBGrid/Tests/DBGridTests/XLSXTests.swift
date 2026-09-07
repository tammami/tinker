import DBCore
import Foundation
import XCTest

@testable import DBGrid

final class XLSXTests: XCTestCase {
    private func unzip(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func column(_ name: String, _ kind: DBValueKind) -> ColumnMeta {
        ColumnMeta(id: name.hashValue, name: name, nativeTypeName: "x", kind: kind)
    }

    func testWorkbookIsAValidZipWithNumbersStringsAndABoldHeader() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tinker-\(UUID().uuidString).xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        var options = ExportOptions()
        options.format = .xlsx
        options.sheetTitle = "orders"
        let exporter = try RowExporter(url: url, options: options)
        try exporter.begin(columns: [column("id", .int), column("name", .string), column("total", .decimal)])
        exporter.write(rows: [
            [.int(1), .string("A & B <c>"), .decimal("10.50")],
            [.int(2), .null, .decimal("not a number")],
            [.int(3), .bool(true), .double(2.5)],
        ])
        try exporter.finish()

        let integrity = try unzip(["-t", url.path])
        XCTAssertEqual(integrity.status, 0, integrity.output)
        let sheet = try unzip(["-p", url.path, "xl/worksheets/sheet1.xml"]).output
        XCTAssertTrue(
            sheet.contains(#"<row r="1"><c r="A1" t="inlineStr" s="1"><is><t xml:space="preserve">id</t></is></c>"#),
            sheet)
        XCTAssertTrue(sheet.contains(#"<c r="A2"><v>1</v></c>"#), sheet)
        XCTAssertTrue(sheet.contains("A &amp; B &lt;c&gt;"), sheet)
        XCTAssertTrue(sheet.contains(#"<c r="C2"><v>10.50</v></c>"#), sheet)
        XCTAssertFalse(sheet.contains(#"r="B3""#), "a NULL leaves no cell")
        XCTAssertTrue(
            sheet.contains(#"<c r="C3" t="inlineStr"><is><t xml:space="preserve">not a number</t></is></c>"#), sheet)
        XCTAssertTrue(sheet.contains(#"<c r="B4" t="b"><v>1</v></c>"#), sheet)
        // Every part must be well-formed XML, or Excel repairs or refuses the file.
        for part in [
            "\\[Content_Types\\].xml", "_rels/.rels", "xl/workbook.xml", "xl/styles.xml", "xl/worksheets/sheet1.xml",
        ] {
            let xml = try unzip(["-p", url.path, part]).output
            let lint = Process()
            lint.executableURL = URL(fileURLWithPath: "/usr/bin/xmllint")
            lint.arguments = ["--noout", "-"]
            let input = Pipe()
            let errors = Pipe()
            lint.standardInput = input
            lint.standardError = errors
            try lint.run()
            input.fileHandleForWriting.write(Data(xml.utf8))
            try input.fileHandleForWriting.close()
            lint.waitUntilExit()
            XCTAssertEqual(
                lint.terminationStatus, 0,
                "\(part): " + String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        let workbook = try unzip(["-p", url.path, "xl/workbook.xml"]).output
        XCTAssertTrue(workbook.contains(#"<sheet name="orders""#), workbook)
        XCTAssertEqual(exporter.writtenRowCount, 3)
    }

    func testColumnLettersAndNumberDetection() {
        XCTAssertEqual(XLSXWorkbookWriter.columnLetters(0), "A")
        XCTAssertEqual(XLSXWorkbookWriter.columnLetters(25), "Z")
        XCTAssertEqual(XLSXWorkbookWriter.columnLetters(26), "AA")
        XCTAssertEqual(XLSXWorkbookWriter.columnLetters(701), "ZZ")
        XCTAssertEqual(XLSXWorkbookWriter.columnLetters(702), "AAA")
        XCTAssertTrue(XLSXWorkbookWriter.isPlainNumber("-12.5e3"))
        XCTAssertTrue(XLSXWorkbookWriter.isPlainNumber("0"))
        XCTAssertFalse(XLSXWorkbookWriter.isPlainNumber("1,000"))
        XCTAssertFalse(XLSXWorkbookWriter.isPlainNumber("NaN"))
        XCTAssertFalse(XLSXWorkbookWriter.isPlainNumber(""))
        XCTAssertEqual(XLSXWorkbookWriter.sheetName("a/b:c?"), "a_b_c_")
        XCTAssertEqual(XLSXWorkbookWriter.sheetName(""), "Sheet1")
    }

    func testRowsPastTheExcelLimitAreReportedNotWritten() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tinker-\(UUID().uuidString).xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try XLSXWorkbookWriter(url: url)
        try writer.begin(columns: [column("n", .int)], includeHeader: false, title: "big")
        // Only the last two rows around the limit are worth writing in a unit test.
        for _ in 0 ..< XLSXWorkbookWriter.rowLimit { try writer.write(row: [.int(1)]) }
        try writer.write(row: [.int(2)])
        XCTAssertThrowsError(try writer.finish()) { error in
            XCTAssertTrue(String(describing: error).contains("1048576"), String(describing: error))
        }
        XCTAssertEqual(writer.rowsWritten, XLSXWorkbookWriter.rowLimit)
    }
}
