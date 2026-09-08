import DBCore
import Foundation
import XCTest

@testable import DBGrid

final class ExportGuardTests: XCTestCase {
    private func column(_ name: String, _ kind: DBValueKind) -> ColumnMeta {
        ColumnMeta(id: name.hashValue, name: name, nativeTypeName: "x", kind: kind)
    }

    func testTextThatLooksLikeAFormulaIsGuardedButNumbersAreNot() {
        XCTAssertEqual(ClipboardFormatter.guardingFormula("=SUM(A1)"), "'=SUM(A1)")
        XCTAssertEqual(ClipboardFormatter.guardingFormula("+62 812"), "'+62 812")
        XCTAssertEqual(ClipboardFormatter.guardingFormula("@user"), "'@user")
        XCTAssertEqual(ClipboardFormatter.guardingFormula("plain"), "plain")
        XCTAssertTrue(ClipboardFormatter.mayCarryFormula(.string("=x")))
        XCTAssertFalse(ClipboardFormatter.mayCarryFormula(.int(-5)))
        XCTAssertFalse(ClipboardFormatter.mayCarryFormula(.decimal("-5.5")))

        let columns = [column("n", .int), column("s", .string)]
        let rows: [[DBValue]] = [[.int(-5), .string("=cmd|' /C calc'!A0")]]
        let csv = ClipboardFormatter.render(columns: columns, rows: rows, format: .csv)
        XCTAssertEqual(csv, "-5,'=cmd|' /C calc'!A0")
        let tsv = ClipboardFormatter.render(columns: columns, rows: rows, format: .tsv)
        XCTAssertEqual(tsv, "-5\t'=cmd|' /C calc'!A0")
        let raw = ClipboardFormatter.render(
            columns: columns, rows: rows, format: .csv, options: .init(guardFormulas: false))
        XCTAssertEqual(raw, "-5,=cmd|' /C calc'!A0")
    }

    func testJSONWritesNullForNonFiniteDoubles() {
        XCTAssertEqual(ClipboardFormatter.jsonValue(.double(.nan)), "null")
        XCTAssertEqual(ClipboardFormatter.jsonValue(.double(.infinity)), "null")
        XCTAssertEqual(ClipboardFormatter.jsonValue(.double(2.5)), "2.5")
    }

    func testCSVExportGuardsAndTheFileIsPrivate() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tinker-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        var options = ExportOptions()
        options.format = .csv
        let exporter = try RowExporter(url: url, options: options)
        try exporter.begin(columns: [column("n", .int), column("s", .string)])
        exporter.write(rows: [[.int(-1), .string("=1+1")]])
        try exporter.finish()
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text, "n,s\n-1,'=1+1\n")
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testExcelNumberDetectionSheetNamesAndClipping() {
        XCTAssertFalse(XLSXWorkbookWriter.isPlainNumber("1e"))
        XCTAssertFalse(XLSXWorkbookWriter.isPlainNumber("1e+"))
        XCTAssertTrue(XLSXWorkbookWriter.isPlainNumber("1e+3"))
        XCTAssertEqual(XLSXWorkbookWriter.sheetName("'quoted'"), "quoted")
        XCTAssertEqual(XLSXWorkbookWriter.sheetName("History"), "Sheet1")
        XCTAssertEqual(XLSXWorkbookWriter.sheetName("history"), "Sheet1")
        // Clipping counts UTF-16 units and never splits a surrogate pair.
        let long = String(repeating: "a", count: 32_766) + "😀"
        let clipped = XLSXWorkbookWriter.clip(long)
        XCTAssertEqual(clipped.utf16.count, 32_766)
        XCTAssertTrue(clipped.allSatisfy { $0 == "a" })
        XCTAssertEqual(XLSXWorkbookWriter.clip("short"), "short")
    }

    func testTooManyColumnsIsRefusedBeforeAnythingIsWritten() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tinker-\(UUID().uuidString).xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try XLSXWorkbookWriter(url: url)
        let columns = (0 ..< XLSXWorkbookWriter.columnLimit + 1).map { column("c\($0)", .int) }
        XCTAssertThrowsError(try writer.begin(columns: columns, includeHeader: true, title: "wide")) { error in
            XCTAssertTrue(String(describing: error).contains("16384"), String(describing: error))
        }
    }

    func testDroppedExcelRowsAreNotCounted() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tinker-\(UUID().uuidString).xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        var options = ExportOptions()
        options.format = .xlsx
        options.includeHeader = false
        let exporter = try RowExporter(url: url, options: options)
        try exporter.begin(columns: [column("n", .int)])
        for _ in 0 ..< XLSXWorkbookWriter.rowLimit + 3 { exporter.write(row: [.int(1)]) }
        XCTAssertThrowsError(try exporter.finish())
        XCTAssertEqual(exporter.writtenRowCount, Int64(XLSXWorkbookWriter.rowLimit))
    }

    func testInflateRefusesAPieceThatExpandsPastTheLimit() throws {
        // Eighty MiB of zeros deflate to under a megabyte; inflating that one piece
        // would need it all in memory, so the inflater stops at its limit instead.
        let deflater = try GzipDeflater(level: 9)
        var compressed = Data()
        let zeros = Data(count: 8 * 1_024 * 1_024)
        for _ in 0 ..< 10 { compressed.append(try deflater.compress(zeros)) }
        compressed.append(try deflater.compress(Data(), finish: true))
        XCTAssertLessThan(compressed.count, 1_024 * 1_024)
        let inflater = try GzipInflater()
        XCTAssertThrowsError(try inflater.decompress(compressed)) { error in
            XCTAssertTrue(String(describing: error).contains("output over"), String(describing: error))
        }
    }
}
