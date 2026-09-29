import DBCore
import Foundation
import XCTest

@testable import DBGrid

/// Importing a workbook: what Tinker exports reads back as it went out, and what Excel
/// writes — shared strings, styles that make numbers dates, cells left out — reads as
/// the text a person sees in Excel.
final class XLSXReaderTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("tinker-xlsx-read-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func rows(_ workbook: XLSXWorkbook) -> [[String]] {
        var reader = workbook.rows()
        var result: [[String]] = []
        while let row = reader.next() { result.append(row) }
        return result
    }

    /// The report: export to Excel, import the same file. It used to be read as CSV, and
    /// the column mapping showed the zip's bytes.
    func testATinkerExportImportsBackRowForRow() throws {
        let url = scratch.appendingPathComponent("pelanggan.xlsx")
        var options = ExportOptions()
        options.format = .xlsx
        options.sheetTitle = "pelanggan"
        let exporter = try RowExporter(url: url, options: options)
        let columns = [
            ColumnMeta(id: 0, name: "id", nativeTypeName: "int", kind: .int),
            ColumnMeta(id: 1, name: "nama", nativeTypeName: "varchar", kind: .string),
            ColumnMeta(id: 2, name: "latitude", nativeTypeName: "varchar", kind: .string),
            ColumnMeta(id: 3, name: "saldo", nativeTypeName: "decimal", kind: .decimal),
            ColumnMeta(id: 4, name: "aktif", nativeTypeName: "bool", kind: .bool),
        ]
        try exporter.begin(columns: columns)
        exporter.write(rows: [
            [.int(1), .string("Toko \"Maju\" & <Jaya>"), .string("-8.59940239"), .decimal("1250000.50"), .bool(true)],
            [.int(2), .null, .string("-8.595696215758"), .decimal("0.10"), .bool(false)],
            [.int(3), .string("Baris\ndua"), .null, .decimal("12345678901234567890.123"), .null],
        ])
        try exporter.finish()

        let data = try Data(contentsOf: url)
        XCTAssertEqual(TabularFormat.detect(url: url, data: data), .xlsx)
        XCTAssertEqual(
            TabularFormat.detect(url: URL(fileURLWithPath: "/x/renamed.csv"), data: data), .xlsx,
            "a workbook is a workbook whatever it is called")

        let workbook = try XLSXWorkbook(data: data)
        XCTAssertEqual(workbook.sheetName, "pelanggan")
        XCTAssertEqual(
            rows(workbook),
            [
                ["id", "nama", "latitude", "saldo", "aktif"],
                ["1", "Toko \"Maju\" & <Jaya>", "-8.59940239", "1250000.50", "true"],
                // A NULL is a cell left out; it reads as an empty field, which imports as NULL.
                ["2", "", "-8.595696215758", "0.10", "false"],
                ["3", "Baris\ndua", "", "12345678901234567890.123"],
            ])
    }

    /// The header row is what the column mapping offers, so it must match by name.
    func testTheHeaderMatchesTableColumnsByName() throws {
        let url = scratch.appendingPathComponent("header.xlsx")
        var options = ExportOptions()
        options.format = .xlsx
        let exporter = try RowExporter(url: url, options: options)
        try exporter.begin(columns: [
            ColumnMeta(id: 0, name: "Latitude", nativeTypeName: "text", kind: .string),
            ColumnMeta(id: 1, name: "nama", nativeTypeName: "text", kind: .string),
        ])
        exporter.write(rows: [[.string("-8.6"), .string("A")]])
        try exporter.finish()
        var reader = try XLSXWorkbook(url: url).rows()
        let header = try XCTUnwrap(reader.next())
        let table = TableRef(schema: SchemaRef(database: "d", schema: "public"), name: "t")
        let plan = CSVImportPlan.matched(
            header: header,
            to: [
                ColumnInfo(ordinal: 1, name: "nama", nativeType: "text", kind: .string, isNullable: true),
                ColumnInfo(ordinal: 2, name: "latitude", nativeType: "text", kind: .string, isNullable: true),
            ],
            table: table)
        XCTAssertEqual(plan.mapping, ["latitude", "nama"])
    }

    // MARK: - Excel's own shape

    private let sheetXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <dimension ref="A1:F4"/><sheetData>
        <row r="1" spans="1:6"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c><c r="C1" t="s"><v>2</v></c><c r="D1" t="s"><v>3</v></c><c r="E1" t="s"><v>4</v></c><c r="F1" t="s"><v>5</v></c></row>
        <row r="2"><c r="A2"><v>1</v></c><c r="B2" t="s"><v>6</v></c><c r="C2" s="1"><v>45292</v></c><c r="D2" s="2"><v>45292.5</v></c><c r="E2" t="b"><v>1</v></c><c r="F2"><f>A2*2</f><v>2</v></c></row>
        <row r="3"/>
        <row r="4"><c r="A4"><v>0.1</v></c><c r="C4" s="3"><v>0.75</v></c><c r="F4" t="str"><v>x &amp; y</v></c></row>
        <row r="5"><c r="B5" t="inlineStr"><is><t xml:space="preserve"> sel_x000D_baru </t></is></c></row>
        </sheetData></worksheet>
        """
    private let sharedXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="7" uniqueCount="7">
        <si><t>id</t></si><si><t>nama</t></si><si><t>tanggal</t></si><si><t>waktu</t></si><si><t>aktif</t></si><si><t>hitung</t></si>
        <si><r><rPr><b/></rPr><t>Kantor </t></r><r><t>Pusat</t></r><rPh sb="0" eb="1"><t>カ</t></rPh></si>
        </sst>
        """
    private let stylesXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <numFmts count="1"><numFmt numFmtId="164" formatCode="yyyy\\-mm\\-dd\\ hh:mm:ss"/></numFmts>
        <cellStyleXfs count="1"><xf numFmtId="14"/></cellStyleXfs>
        <cellXfs count="4"><xf numFmtId="0"/><xf numFmtId="14" applyNumberFormat="1"/><xf numFmtId="164" applyNumberFormat="1"/><xf numFmtId="21"/></cellXfs>
        </styleSheet>
        """
    private let workbookXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <x:workbook xmlns:x="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <x:workbookPr/><x:sheets><x:sheet name="Data &amp; more" sheetId="3" r:id="rId7"/><x:sheet name="Other" sheetId="1" r:id="rId1"/></x:sheets></x:workbook>
        """
    private let relsXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="worksheet" Target="worksheets/sheet1.xml"/>
        <Relationship Id="rId7" Type="worksheet" Target="/xl/worksheets/data.xml"/>
        </Relationships>
        """

    private var excelParts: [(String, String)] {
        [
            ("xl/workbook.xml", workbookXML), ("xl/_rels/workbook.xml.rels", relsXML),
            ("xl/sharedStrings.xml", sharedXML), ("xl/styles.xml", stylesXML),
            ("xl/worksheets/data.xml", sheetXML),
            (
                "xl/worksheets/sheet1.xml",
                "<worksheet><sheetData><row><c t=\"inlineStr\"><is><t>wrong sheet</t></is></c></row></sheetData></worksheet>"
            ),
        ]
    }

    private let expectedExcelRows: [[String]] = [
        ["id", "nama", "tanggal", "waktu", "aktif", "hitung"],
        ["1", "Kantor Pusat", "2024-01-01", "2024-01-01 12:00:00", "true", "2"],
        ["0.1", "", "18:00:00", "", "", "x & y"],
        ["", " sel\rbaru "],
    ]

    func testAWorkbookInExcelsShapeReadsAsExcelShowsIt() throws {
        let url = scratch.appendingPathComponent("excel.xlsx")
        let zip = try ZipStreamWriter(url: url)
        for (name, content) in excelParts {
            try zip.beginEntry(name: name)
            try zip.write(Data(content.utf8))
            try zip.endEntry()
        }
        try zip.finish()
        let workbook = try XLSXWorkbook(url: url)
        XCTAssertEqual(workbook.sheetName, "Data & more", "the first sheet, found through its relationship")
        XCTAssertEqual(rows(workbook), expectedExcelRows)
    }

    /// The same parts zipped by Info-ZIP, stored and deflated: sizes in the local
    /// headers rather than in data descriptors, as most tools other than Tinker write.
    func testAnArchiveFromAnotherZipToolReadsTheSame() throws {
        let parts = scratch.appendingPathComponent("parts")
        for (name, content) in excelParts {
            let file = parts.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: file)
        }
        for (flag, name) in [("-0", "stored.xlsx"), ("-9", "deflated.xlsx")] {
            let output = scratch.appendingPathComponent(name)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.currentDirectoryURL = parts
            process.arguments = ["-q", "-X", "-r", flag, output.path, "xl"]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertEqual(rows(try XLSXWorkbook(url: output)), expectedExcelRows, name)
        }
    }

    func testAFileThatIsNotAWorkbookSaysSo() {
        XCTAssertThrowsError(try XLSXWorkbook(data: Data("id,nama\n1,A\n".utf8))) { error in
            XCTAssertTrue(String(describing: error).contains("not an Excel workbook"), String(describing: error))
        }
        // A zip that is not a workbook.
        let url = scratch.appendingPathComponent("other.zip")
        do {
            let zip = try ZipStreamWriter(url: url)
            try zip.beginEntry(name: "readme.txt")
            try zip.write(Data("hi".utf8))
            try zip.endEntry()
            try zip.finish()
            XCTAssertThrowsError(try XLSXWorkbook(url: url)) { error in
                XCTAssertTrue(String(describing: error).contains("xl/workbook.xml"), String(describing: error))
            }
        } catch {
            XCTFail("\(error)")
        }
    }

    /// A sheet large enough to go through a temporary file reads the same, and leaves
    /// no file behind.
    func testALargeSheetStreamsThroughATemporaryFile() throws {
        let url = scratch.appendingPathComponent("large.xlsx")
        var options = ExportOptions()
        options.format = .xlsx
        let exporter = try RowExporter(url: url, options: options)
        try exporter.begin(columns: [
            ColumnMeta(id: 0, name: "id", nativeTypeName: "int", kind: .int),
            ColumnMeta(id: 1, name: "note", nativeTypeName: "text", kind: .string),
        ])
        let note = String(repeating: "lorem ipsum dolor ", count: 12)
        for start in stride(from: 0, to: 120_000, by: 1_000) {
            exporter.write(rows: (start ..< start + 1_000).map { [.int(Int64($0)), .string("\(note)\($0)")] })
        }
        try exporter.finish()
        let before = try FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())
            .filter { $0.hasPrefix("tinker-xlsx-") && $0.hasSuffix(".xml") }
        let workbook = try XLSXWorkbook(url: url)
        let after = try FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())
            .filter { $0.hasPrefix("tinker-xlsx-") && $0.hasSuffix(".xml") }
        XCTAssertEqual(Set(after), Set(before), "the inflated sheet is unlinked once mapped")
        XCTAssertGreaterThan(workbook.sheet.count, Int(XLSXWorkbook.inMemoryLimit))
        var reader = workbook.rows()
        var count = 0
        var last: [String] = []
        while let row = reader.next() {
            count += 1
            last = row
        }
        XCTAssertEqual(count, 120_001)
        XCTAssertEqual(last, ["119999", "\(note)119999"])
        XCTAssertEqual(reader.recordNumber, 120_001)
    }

    // MARK: - Pieces

    func testDateFormatsAndSerials() {
        XCTAssertEqual(ExcelDateKind.of(formatID: 14, code: nil), .date)
        XCTAssertEqual(ExcelDateKind.of(formatID: 22, code: nil), .dateTime)
        XCTAssertEqual(ExcelDateKind.of(formatID: 20, code: nil), .time)
        XCTAssertNil(ExcelDateKind.of(formatID: 2, code: nil), "0.00 is a number")
        XCTAssertEqual(ExcelDateKind.of(formatID: 165, code: "dd/mm/yyyy"), .date)
        XCTAssertEqual(ExcelDateKind.of(formatID: 166, code: "[$-421]d mmmm yyyy;@"), .date)
        XCTAssertEqual(ExcelDateKind.of(formatID: 167, code: "[h]:mm:ss"), .duration)
        XCTAssertEqual(ExcelDateKind.of(formatID: 46, code: nil), .duration)
        XCTAssertEqual(ExcelDateKind.of(formatID: 171, code: "hh:mm"), .time)
        // Colours, currencies and locales in brackets say nothing about dates.
        XCTAssertNil(ExcelDateKind.of(formatID: 172, code: "[$USD]\\ #,##0.00"), "a price is not a time")
        XCTAssertNil(ExcelDateKind.of(formatID: 173, code: "[Magenta]0"), "a colour is not a month")
        XCTAssertNil(ExcelDateKind.of(formatID: 174, code: "[White]0.00"))
        XCTAssertEqual(ExcelDateKind.of(formatID: 175, code: "[$-en-US]d mmm yyyy"), .date)
        XCTAssertNil(ExcelDateKind.of(formatID: 168, code: "#,##0.00\" days\""), "quoted text is not a format")
        XCTAssertNil(ExcelDateKind.of(formatID: 169, code: "[Red]0.00;[Blue]-0.00"))
        XCTAssertNil(ExcelDateKind.of(formatID: 170, code: "General"))

        func text(_ serial: String, _ kind: ExcelDateKind, _ uses1904: Bool = false) -> String? {
            ExcelDateKind.text(serial: serial, kind: kind, uses1904: uses1904)
        }
        XCTAssertEqual(text("1", .date), "1900-01-01")
        XCTAssertEqual(text("59", .date), "1900-02-28")
        XCTAssertEqual(text("61", .date), "1900-03-01", "past Excel's phantom 29 February")
        XCTAssertEqual(text("45292", .date), "2024-01-01")
        XCTAssertEqual(text("45351.999999", .dateTime), "2024-03-01 00:00:00", "rounds to the second")
        XCTAssertEqual(text("0.5", .time), "12:00:00")
        XCTAssertEqual(text("45292.75", .time), "18:00:00", "a date-time under h:mm shows the clock, not the hours since 1900")
        XCTAssertEqual(text("1.25", .duration), "30:00:00", "a duration keeps counting hours")
        XCTAssertEqual(text("0", .date, true), "1904-01-01")
        XCTAssertNil(text("abc", .date))
        XCTAssertNil(text("-1", .date))
    }

    func testCellReferencesAndEscapes() {
        XCTAssertEqual(XLSXRowReader.columnIndex("A1"), 0)
        XCTAssertEqual(XLSXRowReader.columnIndex("Z9"), 25)
        XCTAssertEqual(XLSXRowReader.columnIndex("AA10"), 26)
        XCTAssertEqual(XLSXRowReader.columnIndex("XFD1048576"), 16_383)
        XCTAssertNil(XLSXRowReader.columnIndex("12"))
        XCTAssertNil(XLSXRowReader.columnIndex("XFE1"), "past Excel's last column")
        XCTAssertNil(XLSXRowReader.columnIndex("AAAAAAAAAAAAAAA1"), "no overflow, no trap")
        XCTAssertNil(XLSXRowReader.columnIndex("ZZZZZZZ1"))
        XCTAssertEqual(XMLScanner.unescape("a &amp; b &lt;c&gt; &#233; &#x1F600; &bogus;"), "a & b <c> é 😀 &bogus;")
        XCTAssertEqual(XMLScanner.unescapeOOXML("a_x000D__x000A_b _x005F_x000D_"), "a\r\nb _x000D_")
        XCTAssertEqual(XLSXWorkbook.resolve("worksheets/sheet2.xml"), "xl/worksheets/sheet2.xml")
        XCTAssertEqual(XLSXWorkbook.resolve("/xl/worksheets/a.xml"), "xl/worksheets/a.xml")
        XCTAssertEqual(XLSXWorkbook.resolve("../xl/worksheets/b.xml"), "xl/worksheets/b.xml")
    }

    // MARK: - Hostile files

    private func zipParts(_ parts: [(String, Data)], to url: URL) throws {
        let zip = try ZipStreamWriter(url: url)
        for (name, content) in parts {
            try zip.beginEntry(name: name)
            try zip.write(content)
            try zip.endEntry()
        }
        try zip.finish()
    }

    private func minimalWorkbook(sheet: String) -> [(String, Data)] {
        [
            ("xl/workbook.xml", Data(#"<workbook><sheets><sheet name="S" sheetId="1"/></sheets></workbook>"#.utf8)),
            ("xl/worksheets/sheet1.xml", Data(sheet.utf8)),
        ]
    }

    /// A reference far past XFD neither crashes nor allocates: the cell is skipped.
    func testAnAbsurdCellReferenceIsSkipped() throws {
        let url = scratch.appendingPathComponent("far.xlsx")
        try zipParts(
            minimalWorkbook(
                sheet: #"<worksheet><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>ok</t></is></c><c r="ZZZZZZZ1"><v>1</v></c><c r="AAAAAAAAAAAAAAAA1"><v>2</v></c></row></sheetData></worksheet>"#),
            to: url)
        XCTAssertEqual(rows(try XLSXWorkbook(url: url)), [["ok"]])
    }

    /// A sheet cut off inside its deflate stream is refused, not imported in part.
    func testATruncatedSheetIsRefused() throws {
        let url = scratch.appendingPathComponent("cut.xlsx")
        let body = (0 ..< 5_000).map { #"<row r="\#($0 + 1)"><c><v>\#($0)</v></c></row>"# }.joined()
        try zipParts(minimalWorkbook(sheet: "<worksheet><sheetData>\(body)</sheetData></worksheet>"), to: url)
        var bytes = try Data(contentsOf: url)
        // Find the sheet's deflated bytes and damage the middle of them; the directory stays.
        let marker = Data("xl/worksheets/sheet1.xml".utf8)
        let local = try XCTUnwrap(bytes.range(of: marker))
        let start = local.upperBound + 200
        for index in start ..< start + 64 { bytes[index] = 0 }
        XCTAssertThrowsError(try XLSXWorkbook(data: bytes)) { error in
            XCTAssertTrue(String(describing: error).contains("damaged"), String(describing: error))
        }
    }

    /// A part claiming to inflate a thousandfold is refused before anything is written.
    func testAZipBombIsRefused() throws {
        let url = scratch.appendingPathComponent("bomb.xlsx")
        let zeros = Data(count: 8 * 1_024 * 1_024)
        try zipParts(minimalWorkbook(sheet: "<worksheet><sheetData/></worksheet>") + [("xl/sharedStrings.xml", zeros)], to: url)
        XCTAssertThrowsError(try XLSXWorkbook(url: url)) { error in
            XCTAssertTrue(String(describing: error).contains("unsafe"), String(describing: error))
        }
    }

    /// Unescaping stays linear on text made to defeat it.
    func testEntityHeavyTextIsLinear() {
        let ampersands = Substring(String(repeating: "&", count: 400_000))
        let underscores = Substring(String(repeating: "_x", count: 200_000))
        let started = Date()
        XCTAssertEqual(XMLScanner.unescape(ampersands).count, 400_000)
        XCTAssertEqual(XMLScanner.unescapeOOXML(underscores).count, 400_000)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "quadratic unescaping would take minutes")
    }

    func testOpeningIsAsync() async throws {
        let url = scratch.appendingPathComponent("async.xlsx")
        try zipParts(
            minimalWorkbook(sheet: #"<worksheet><sheetData><row><c t="inlineStr"><is><t>a</t></is></c></row></sheetData></worksheet>"#),
            to: url)
        let workbook = try await XLSXWorkbook.open(data: try Data(contentsOf: url))
        XCTAssertEqual(rows(workbook), [["a"]])
    }
}
