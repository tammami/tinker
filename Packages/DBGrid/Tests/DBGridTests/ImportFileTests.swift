import DBCore
import Foundation
import XCTest

@testable import DBGrid

/// What an import reads must be what the file holds: text in any script, in whatever
/// encoding the file was saved, from the sheet that was asked for — or a plain refusal,
/// never a column of noise.
final class ImportFileTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("tinker-import-\(UUID())")
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

    private func rows(csv data: Data, delimiter: Character = ",") -> [[String]] {
        var reader = CSVReader(data: data, delimiter: delimiter)
        var result: [[String]] = []
        while let row = reader.next() { result.append(row) }
        return result
    }

    private func zip(_ parts: [(String, String)], named name: String) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        let zip = try ZipStreamWriter(url: url)
        for (path, content) in parts {
            try zip.beginEntry(name: path)
            try zip.write(Data(content.utf8))
            try zip.endEntry()
        }
        try zip.finish()
        return url
    }

    private func export(
        _ columns: [ColumnMeta], _ rows: [[DBValue]], format: ExportFormat, named name: String
    ) throws
        -> URL
    {
        let url = scratch.appendingPathComponent(name)
        var options = ExportOptions()
        options.format = format
        let exporter = try RowExporter(url: url, options: options)
        try exporter.begin(columns: columns)
        exporter.write(rows: rows)
        try exporter.finish()
        return url
    }

    private let table = TableRef(database: "db", schema: "public", name: "barang")

    private func column(
        _ ordinal: Int, _ name: String, _ kind: DBValueKind = .string, nullable: Bool = true,
        defaultExpression: String? = nil, key: Bool = false, auto: Bool = false, generated: Bool = false
    ) -> ColumnInfo {
        ColumnInfo(
            ordinal: ordinal, name: name, nativeType: kind.rawValue, kind: kind, isNullable: nullable,
            defaultExpression: defaultExpression, isPrimaryKey: key, isAutoIncrement: auto, isGenerated: generated)
    }

    // MARK: - Round trip

    /// The report: what is exported to Excel comes back character for character.
    func testEveryKindOfTextSurvivesAnExcelRoundTrip() throws {
        let texts = [
            "Café Münster", "日本語のテキスト", "العربية", "Ωμέγα", "emoji 🎉👨‍👩‍👧 selesai", "Rp 1.500,00",
            "\"dikutip\" & <tag> 'apos'", "baris satu\nbaris dua", "baris\r\nwindows", "tab\tdi tengah",
            "=SUM(A1:A9)", "+62 812 3456", "-minus", "@handle", "  spasi di tepi  ", "_x0041_ bukan A",
            "_x000D_", "a\u{01}b", "0012345", "1e5", "ñandú — “kutip” …",
        ]
        let columns = [
            ColumnMeta(id: 0, name: "id", nativeTypeName: "int", kind: .int),
            ColumnMeta(id: 1, name: "teks", nativeTypeName: "text", kind: .string),
            ColumnMeta(id: 2, name: "harga", nativeTypeName: "numeric", kind: .decimal),
            ColumnMeta(id: 3, name: "tanggal", nativeTypeName: "date", kind: .date),
            ColumnMeta(id: 4, name: "waktu", nativeTypeName: "timestamp", kind: .timestamp),
            ColumnMeta(id: 5, name: "catatan", nativeTypeName: "text", kind: .string),
        ]
        let values: [[DBValue]] = texts.enumerated().map { index, text in
            [
                .int(Int64(index + 1)), .string(text), .decimal("12345678901234567890.123456789"),
                .raw(typeName: "date", text: "2026-09-30", bytes: nil),
                .raw(typeName: "timestamp", text: "2026-09-30 23:59:59.123456", bytes: nil), .null,
            ]
        }
        let url = try export(columns, values, format: .xlsx, named: "teks.xlsx")
        let data = try Data(contentsOf: url)
        XCTAssertEqual(try ImportFileProbe.format(url: url, data: data), .xlsx)

        let read = rows(try XLSXWorkbook(data: data))
        XCTAssertEqual(read.first, ["id", "teks", "harga", "tanggal", "waktu", "catatan"])
        XCTAssertEqual(read.count, texts.count + 1)
        for (index, text) in texts.enumerated() {
            let row = read[index + 1]
            XCTAssertEqual(row[0], String(index + 1))
            XCTAssertEqual(row[1], text, "row \(index + 1)")
            XCTAssertEqual(row[2], "12345678901234567890.123456789")
            XCTAssertEqual(row[3], "2026-09-30")
            XCTAssertEqual(row[4], "2026-09-30 23:59:59.123456")
            // A NULL is a cell left out: the row ends before it.
            XCTAssertEqual(row.count, 5)
        }
    }

    /// An exact decimal with as many digits as a double's dump stays exact in Tinker's
    /// own export, where a spreadsheet's number is read as it was typed.
    func testNumbersKeepTheirDigitsOrTheirTypedForm() throws {
        let columns = [ColumnMeta(id: 0, name: "n", nativeTypeName: "numeric", kind: .decimal)]
        let url = try export(
            columns, [[.decimal("-8.5994023899999995")], [.decimal("0.10")]], format: .xlsx, named: "exact.xlsx")
        XCTAssertEqual(rows(try XLSXWorkbook(url: url)), [["n"], ["-8.5994023899999995"], ["0.10"]])

        let sheet = """
            <worksheet><sheetData>
            <row r="1"><c r="A1" t="s"><v>0</v></c></row>
            <row r="2"><c r="A2"><v>-8.5994023899999995</v></c></row>
            <row r="3"><c r="A3"><v>0.30000000000000004</v></c></row>
            <row r="4"><c r="A4"><v>\(String(format: "%.17g", 116.1073847))</v></c></row>
            <row r="5"><c r="A5"><v>1234567.8899999999</v></c></row>
            <row r="6"><c r="A6"><v>0.1</v></c></row>
            <row r="7"><c r="A7"><v>12345678901234567890</v></c></row>
            <row r="8"><c r="A8"><v>1.0000000000000001E-5</v></c></row>
            </sheetData></worksheet>
            """
        let excel = try zip(
            [
                (
                    "xl/workbook.xml",
                    "<workbook><sheets><sheet name=\"Data\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>"
                ),
                ("xl/sharedStrings.xml", "<sst><si><t>n</t></si></sst>"),
                ("xl/worksheets/sheet1.xml", sheet),
            ], named: "excel.xlsx")
        XCTAssertEqual(
            rows(try XLSXWorkbook(url: excel)),
            [
                ["n"], ["-8.59940239"], ["0.30000000000000004"], ["116.1073847"], ["1234567.89"], ["0.1"],
                ["12345678901234567890"], ["1.0000000000000001E-5"],
            ])
        // A neighbouring double is another number, however close it looks.
        XCTAssertEqual(XLSXRowReader.typedNumber("116.10738470000001"), "116.10738470000001")
        XCTAssertEqual(XLSXRowReader.typedNumber("45292"), "45292")
        XCTAssertEqual(XLSXRowReader.typedNumber("1234567890123456"), "1234567890123456")
    }

    /// A CSV exported with formula protection imports as the table held it.
    func testFormulaGuardsComeOffOnRequest() throws {
        let columns = [
            ColumnMeta(id: 0, name: "id", nativeTypeName: "int", kind: .int),
            ColumnMeta(id: 1, name: "teks", nativeTypeName: "text", kind: .string),
        ]
        let url = try export(
            columns,
            [
                [.int(1), .string("=SUM(A1)")], [.int(2), .string("-5 derajat")], [.int(3), .string("'kutip")],
                [.int(-4), .string("biasa")],
            ], format: .csv, named: "guard.csv")
        let data = try Data(contentsOf: url)
        XCTAssertEqual(rows(csv: data)[1], ["1", "'=SUM(A1)"], "the export guards the formula")

        let target = [column(1, "id", .int), column(2, "teks")]
        var plan = CSVImportPlan(
            table: table, assignments: CSVImportPlan.assignmentsByName(header: ["id", "teks"], columns: target),
            sourceCount: 2, removesFormulaGuard: true)
        var importer = CSVImporter(plan: plan, columns: target, dialect: .postgresql)
        let read = rows(csv: data).dropFirst()
        XCTAssertEqual(
            try read.map { try importer.values(for: $0, number: 1) },
            [
                [.int(1), .string("=SUM(A1)")], [.int(2), .string("-5 derajat")], [.int(3), .string("'kutip")],
                [.int(-4), .string("biasa")],
            ])
        // Left alone unless asked: the apostrophe may be data.
        plan.removesFormulaGuard = false
        importer = CSVImporter(plan: plan, columns: target, dialect: .postgresql)
        XCTAssertEqual(try importer.values(for: ["1", "'=SUM(A1)"], number: 1), [.int(1), .string("'=SUM(A1)")])
        XCTAssertEqual(ValueCoercion.removingFormulaGuard("'"), "'")
        XCTAssertEqual(ValueCoercion.removingFormulaGuard("''=x"), "''=x")
    }

    /// A workbook's boolean cell fills a column that keeps flags as integers.
    func testBooleanTextFillsIntegerColumns() {
        XCTAssertEqual(ValueCoercion.coerce("true", to: .int), .int(1))
        XCTAssertEqual(ValueCoercion.coerce("false", to: .uint), .uint(0))
        XCTAssertNil(ValueCoercion.coerce("yes", to: .int))
        XCTAssertEqual(ValueCoercion.coerce("7", to: .int), .int(7))
    }

    // MARK: - What is refused

    func testAnOldExcelWorkbookIsRefusedByName() {
        let ole = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1] + [UInt8](repeating: 0, count: 504))
        for name in ["laporan.xls", "laporan.csv", "laporan.xlsx", "laporan"] {
            XCTAssertThrowsError(try ImportFileProbe.format(url: URL(fileURLWithPath: "/x/\(name)"), data: ole)) {
                XCTAssertTrue(String(describing: $0).contains("Excel 97–2003"), "\(name): \($0)")
                XCTAssertTrue(String(describing: $0).contains(".xlsx"), "\(name): \($0)")
            }
        }
        // Excel also saves tab-separated text under `.xls`; that is text and is read.
        XCTAssertEqual(
            try ImportFileProbe.format(url: URL(fileURLWithPath: "/x/teks.xls"), data: Data("a\tb\n1\t2\n".utf8)),
            .delimited(","))
    }

    func testABinaryFileIsRefused() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D, 0x49, 0x48, 0x44, 0x52, 0, 1])
        XCTAssertThrowsError(try ImportFileProbe.format(url: URL(fileURLWithPath: "/x/gambar.csv"), data: png)) {
            XCTAssertTrue(String(describing: $0).contains("not text"), "\($0)")
        }
        var noise = Data()
        for value in 0 ..< 4_096 { noise.append(UInt8((value * 7 + 3) % 32)) }
        XCTAssertThrowsError(try ImportFileProbe.format(url: URL(fileURLWithPath: "/x/data.csv"), data: noise))
        // Text passes, in every encoding read here, and so does an empty file.
        let url = URL(fileURLWithPath: "/x/data.csv")
        XCTAssertEqual(try ImportFileProbe.format(url: url, data: Data()), .delimited(","))
        XCTAssertEqual(try ImportFileProbe.format(url: url, data: Data("id;nama\n1;Café\n".utf8)), .delimited(","))
        XCTAssertEqual(
            try ImportFileProbe.format(url: url, data: Data([0x69, 0x64, 0x3B, 0xE9, 0x0A])), .delimited(","))
        XCTAssertEqual(
            try ImportFileProbe.format(url: url, data: XCTUnwrap("id\tnama\n".data(using: .utf16))), .delimited(","))
        XCTAssertEqual(
            try ImportFileProbe.format(url: URL(fileURLWithPath: "/x/a.json"), data: Data("[{}]".utf8)), .json)
    }

    func testAWorkbookPartInUTF16IsRefused() throws {
        let workbook = "<workbook><sheets><sheet name=\"Data\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>"
        let sheetText =
            "<?xml version=\"1.0\" encoding=\"UTF-16\"?><worksheet><sheetData><row><c t=\"inlineStr\"><is><t>é</t></is></c></row></sheetData></worksheet>"
        let url = scratch.appendingPathComponent("utf16.xlsx")
        let zip = try ZipStreamWriter(url: url)
        try zip.beginEntry(name: "xl/workbook.xml")
        try zip.write(Data(workbook.utf8))
        try zip.endEntry()
        try zip.beginEntry(name: "xl/worksheets/sheet1.xml")
        try zip.write(XCTUnwrap(sheetText.data(using: .utf16)))
        try zip.endEntry()
        try zip.finish()
        XCTAssertThrowsError(try XLSXWorkbook(url: url)) {
            XCTAssertTrue(String(describing: $0).contains("UTF-16"), "\($0)")
        }

        // Declared, without a byte-order mark to give it away.
        let declared = try self.zip(
            [
                ("xl/workbook.xml", "<?xml version=\"1.0\" encoding=\"ISO-8859-1\" standalone=\"yes\"?>" + workbook),
                ("xl/worksheets/sheet1.xml", "<worksheet><sheetData/></worksheet>"),
            ], named: "latin.xlsx")
        XCTAssertThrowsError(try XLSXWorkbook(url: declared)) {
            XCTAssertTrue(String(describing: $0).contains("ISO-8859-1"), "\($0)")
        }
        // UTF-8, declared in either case and with `standalone` after it, is read.
        XCTAssertNoThrow(
            try XLSXWorkbook.checkEncoding(
                Data("<?xml version='1.0' encoding='utf-8' standalone='yes'?><a/>".utf8), of: "a"))
        XCTAssertNoThrow(try XLSXWorkbook.checkEncoding(Data("<a encoding=\"UTF-16\"/>".utf8), of: "a"))
    }

    // MARK: - Sheets

    func testEverySheetIsListedAndAnyCanBeRead() throws {
        func sheet(_ text: String) -> String {
            "<worksheet><sheetData><row><c t=\"inlineStr\"><is><t>\(text)</t></is></c></row></sheetData></worksheet>"
        }
        let url = try zip(
            [
                (
                    "xl/workbook.xml",
                    """
                    <workbook xmlns:r="r"><sheets>
                    <sheet name="Ringkasan" sheetId="1" state="hidden" r:id="rId1"/>
                    <sheet name="Grafik" sheetId="2" r:id="rId2"/>
                    <sheet name="Pelanggan &amp; Toko" sheetId="3" r:id="rId3"/>
                    <sheet name="Arsip" sheetId="4" state="veryHidden" r:id="rId4"/>
                    </sheets></workbook>
                    """
                ),
                (
                    "xl/_rels/workbook.xml.rels",
                    """
                    <Relationships>
                    <Relationship Id="rId1" Type="http://x/relationships/worksheet" Target="worksheets/sheet1.xml"/>
                    <Relationship Id="rId2" Type="http://x/relationships/chartsheet" Target="chartsheets/sheet1.xml"/>
                    <Relationship Id="rId3" Type="http://x/relationships/worksheet" Target="worksheets/sheet7.xml"/>
                    <Relationship Id="rId4" Type="http://x/relationships/worksheet" Target="worksheets/sheet9.xml"/>
                    </Relationships>
                    """
                ),
                ("xl/worksheets/sheet1.xml", sheet("ringkasan")),
                ("xl/chartsheets/sheet1.xml", "<chartsheet/>"),
                ("xl/worksheets/sheet7.xml", sheet("pelanggan")),
                ("xl/worksheets/sheet9.xml", sheet("arsip")),
            ], named: "banyak.xlsx")
        let workbook = try XLSXWorkbook(url: url)
        XCTAssertEqual(workbook.sheets.map(\.name), ["Ringkasan", "Pelanggan & Toko", "Arsip"])
        XCTAssertEqual(workbook.sheets.map(\.isHidden), [true, false, true])
        XCTAssertEqual(workbook.sheets.map(\.index), [0, 1, 2])
        XCTAssertEqual(workbook.sheetName, "Ringkasan")
        XCTAssertEqual(workbook.sheetIndex, 0)
        XCTAssertEqual(rows(workbook), [["ringkasan"]])

        let second = try workbook.selecting(sheet: 1)
        XCTAssertEqual(second.sheetName, "Pelanggan & Toko")
        XCTAssertEqual(second.sheetIndex, 1)
        XCTAssertEqual(rows(second), [["pelanggan"]])
        XCTAssertEqual(rows(try second.selecting(sheet: 2)), [["arsip"]])
        XCTAssertEqual(rows(try XLSXWorkbook(data: Data(contentsOf: url), sheet: 2)), [["arsip"]])
        XCTAssertThrowsError(try workbook.selecting(sheet: 3)) {
            XCTAssertTrue(String(describing: $0).contains("no sheet 4"), "\($0)")
        }
    }

    // MARK: - Encodings

    /// Excel's "Unicode Text": UTF-16 little-endian with a mark, fields apart by tabs.
    func testExcelUnicodeTextReadsAsTyped() throws {
        let text = "id\tnama\tkota\r\n1\tCafé Münster\t日本\r\n2\t\"Toko\tTab\"\t🎉\r\n"
        var data = Data([0xFF, 0xFE])
        for unit in text.utf16 { data.append(contentsOf: [UInt8(unit & 0xFF), UInt8(unit >> 8)]) }
        let url = URL(fileURLWithPath: "/x/unicode.txt")
        XCTAssertEqual(try ImportFileProbe.format(url: url, data: data), .delimited(","))
        XCTAssertEqual(ImportFileProbe.detectEncoding(data), .utf16LittleEndian)
        let utf8 = try ImportFileProbe.utf8Data(from: data, encoding: .utf16LittleEndian)
        XCTAssertEqual(ImportFileProbe.detectDelimiter(utf8), "\t")
        XCTAssertEqual(
            rows(csv: utf8, delimiter: "\t"),
            [["id", "nama", "kota"], ["1", "Café Münster", "日本"], ["2", "Toko\tTab", "🎉"]])
        // Read as UTF-8 it is what the report showed: noise.
        XCTAssertNotEqual(rows(csv: data, delimiter: "\t").first, ["id", "nama", "kota"])
    }

    func testUTF16WithoutAMarkIsRecognisedEitherWay() throws {
        let text = "id,nama\n1,Münster\n2,Yogyakarta\n"
        var little = Data()
        var big = Data()
        for unit in text.utf16 {
            little.append(contentsOf: [UInt8(unit & 0xFF), UInt8(unit >> 8)])
            big.append(contentsOf: [UInt8(unit >> 8), UInt8(unit & 0xFF)])
        }
        XCTAssertEqual(ImportFileProbe.detectEncoding(little), .utf16LittleEndian)
        XCTAssertEqual(ImportFileProbe.detectEncoding(big), .utf16BigEndian)
        let expected = [["id", "nama"], ["1", "Münster"], ["2", "Yogyakarta"]]
        XCTAssertEqual(rows(csv: try ImportFileProbe.utf8Data(from: little, encoding: .utf16LittleEndian)), expected)
        XCTAssertEqual(rows(csv: try ImportFileProbe.utf8Data(from: big, encoding: .utf16BigEndian)), expected)
        // A lone surrogate and an odd last byte are damage, not a crash.
        let damaged = Data([0x41, 0x00, 0x00, 0xD8, 0x42, 0x00, 0x43])
        XCTAssertEqual(
            String(decoding: try ImportFileProbe.utf8Data(from: damaged, encoding: .utf16LittleEndian), as: UTF8.self),
            "A\u{FFFD}B")
    }

    /// What Excel on Windows saves as "CSV": one byte per character, semicolons.
    func testWindows1252ReadsAsTyped() throws {
        let data = Data(
            [0x69, 0x64, 0x3B, 0x6E, 0x61, 0x6D, 0x61, 0x3B, 0x68, 0x61, 0x72, 0x67, 0x61, 0x0D, 0x0A]  // id;nama;harga
                + [0x31, 0x3B, 0x43, 0x61, 0x66, 0xE9, 0x20, 0x93, 0x4D, 0xFC, 0x6E, 0x73, 0x74, 0x65, 0x72, 0x94]
                + [0x3B, 0x80, 0x20, 0x31, 0x2C, 0x35, 0x30, 0x0D, 0x0A])
        XCTAssertEqual(ImportFileProbe.detectEncoding(data), .windows1252)
        let utf8 = try ImportFileProbe.utf8Data(from: data, encoding: .windows1252)
        XCTAssertEqual(ImportFileProbe.detectDelimiter(utf8), ";")
        XCTAssertEqual(rows(csv: utf8, delimiter: ";"), [["id", "nama", "harga"], ["1", "Café “Münster”", "€ 1,50"]])
        // ISO-8859-1 has control characters where Windows-1252 has the quotes and the euro.
        let latin = try ImportFileProbe.utf8Data(from: Data([0xE9, 0x80]), encoding: .isoLatin1)
        XCTAssertEqual(String(decoding: latin, as: UTF8.self), "é\u{80}")
    }

    func testUTF8IsRecognisedAndHandedBackUntouched() throws {
        let plain = Data("id,nama\n1,Café 日本 🎉\n".utf8)
        XCTAssertEqual(ImportFileProbe.detectEncoding(plain), .utf8)
        XCTAssertEqual(ImportFileProbe.detectEncoding(Data([0xEF, 0xBB, 0xBF]) + plain), .utf8)
        XCTAssertEqual(ImportFileProbe.detectEncoding(Data("hanya ascii".utf8)), .utf8)
        XCTAssertEqual(try ImportFileProbe.utf8Data(from: plain, encoding: .utf8), plain)
        XCTAssertTrue(ImportFileProbe.isValidUTF8(plain))
        // Overlong forms, surrogates and stray continuation bytes are not UTF-8.
        for bytes: [UInt8] in [[0xC0, 0xAF], [0xED, 0xA0, 0x80], [0x80], [0xF5, 0x80, 0x80, 0x80], [0xE9, 0x20]] {
            XCTAssertFalse(ImportFileProbe.isValidUTF8(Data(bytes)), "\(bytes)")
        }
        // A sequence the sample cut short is not held against the file.
        XCTAssertTrue(ImportFileProbe.isValidUTF8(Data("日".utf8.prefix(2))))
    }

    /// Past the in-memory limit the text goes through a file that leaves nothing behind.
    func testALargeFileIsTranscodedThroughATemporaryFile() throws {
        let line = Array("1;Caf".utf8) + [0xE9] + Array(";Surabaya\n".utf8)
        let count = ImportFileProbe.inMemoryLimit / line.count + 10
        var data = Data(capacity: count * line.count)
        for _ in 0 ..< count { data.append(contentsOf: line) }
        XCTAssertGreaterThan(data.count, ImportFileProbe.inMemoryLimit)
        let before = try leftovers()
        let utf8 = try ImportFileProbe.utf8Data(from: data, encoding: .windows1252)
        XCTAssertEqual(utf8.count, data.count + count)
        var reader = CSVReader(data: utf8, delimiter: ";")
        var read = 0
        while let row = reader.next() {
            if read == 0 || read == count - 1 { XCTAssertEqual(row, ["1", "Café", "Surabaya"]) }
            read += 1
        }
        XCTAssertEqual(read, count)
        XCTAssertEqual(try leftovers(), before, "the temporary file is unlinked as soon as it is mapped")
    }

    private func leftovers() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("tinker-import-") && $0.hasSuffix(".txt") }.sorted()
    }

    // MARK: - Delimiters

    func testTheDelimiterIsReadFromTheFirstLines() {
        func detect(_ text: String, fallback: Character = ",") -> Character {
            ImportFileProbe.detectDelimiter(Data(text.utf8), fallback: fallback)
        }
        XCTAssertEqual(detect("id,nama,kota\n1,A,B\n"), ",")
        // Indonesia's Excel: semicolons between fields, commas in the numbers.
        XCTAssertEqual(detect("id;nama;harga\n1;Pena;1,50\n2;Buku;12,00\n"), ";")
        XCTAssertEqual(detect("id;alamat\n1;\"Jl. Sudirman, No. 1, Jakarta\"\n2;Mataram\n"), ";")
        XCTAssertEqual(detect("id\tnama\n1\tA, B\n"), "\t")
        XCTAssertEqual(detect("id|nama\n1|A\n"), "|")
        XCTAssertEqual(detect("\u{FEFF}id;nama\n1;A\n"), ";")
        XCTAssertEqual(detect("satu kolom\nnilai\n"), ",")
        XCTAssertEqual(detect("satu kolom\nnilai\n", fallback: "\t"), "\t")
        XCTAssertEqual(detect(""), ",")
        // A comma in every address does not beat the semicolon that splits every line alike.
        XCTAssertEqual(detect("nama;alamat\nA;Jl. X, Y, Z\nB;Jl. P, Q\n"), ";")
    }

    func testExcelsSeparatorLineIsHonouredAndSkipped() {
        let data = Data("sep=;\r\nid;nama\r\n1;A,B\r\n".utf8)
        XCTAssertEqual(ImportFileProbe.detectDelimiter(data), ";")
        XCTAssertEqual(rows(csv: data, delimiter: ";"), [["id", "nama"], ["1", "A,B"]])
        XCTAssertEqual(rows(csv: Data("SEP=|\nid|nama\n".utf8), delimiter: "|"), [["id", "nama"]])
        // A field that merely starts that way is a field.
        XCTAssertEqual(rows(csv: Data("sep=;x,b\n1,2\n".utf8)), [["sep=;x", "b"], ["1", "2"]])
        XCTAssertEqual(rows(csv: Data("sep=".utf8)), [["sep="]])
    }

    // MARK: - The plan

    func testTableColumnsChooseTheirFileColumn() throws {
        let columns = [
            column(1, "id", .int, nullable: false, key: true, auto: true),
            column(2, "nama", nullable: false),
            column(3, "nama_tampil"),
            column(4, "kota", nullable: false, defaultExpression: "'Mataram'"),
            column(5, "kode", nullable: false),
            column(6, "nama_besar", generated: true),
        ]
        let header = [" Nama ", "KOTA", "lain", "nama", "nama_besar"]
        let byName = CSVImportPlan.assignmentsByName(header: header, columns: columns)
        XCTAssertEqual(
            byName, [ImportAssignment(column: "nama", source: 0), ImportAssignment(column: "kota", source: 1)],
            "the first of two columns with one name; a generated column is never filled")
        XCTAssertEqual(CSVImportPlan.missingRequired(byName, columns: columns).map(\.name), ["kode"])

        XCTAssertEqual(
            CSVImportPlan.assignmentsByPosition(sourceCount: 3, columns: columns).map(\.column),
            ["id", "nama", "nama_tampil"])
        XCTAssertEqual(
            CSVImportPlan.assignmentsByPosition(sourceCount: 9, columns: columns).map(\.column),
            ["id", "nama", "nama_tampil", "kota", "kode"])

        // One file column fills two table columns; the statement names them in order.
        let plan = CSVImportPlan(
            table: table,
            assignments: [
                ImportAssignment(column: "nama", source: 0), ImportAssignment(column: "nama_tampil", source: 0),
                ImportAssignment(column: "kode", source: 2), ImportAssignment(column: "nama", source: 1),
            ], sourceCount: 3)
        XCTAssertEqual(plan.assignments.map(\.column), ["nama", "nama_tampil", "kode"], "a column is filled once")
        XCTAssertEqual(plan.mapping, ["nama", nil, "kode"])
        let importer = CSVImporter(plan: plan, columns: columns, dialect: .postgresql)
        XCTAssertEqual(importer.targetColumns.map(\.name), ["nama", "nama_tampil", "kode"])
        XCTAssertEqual(
            try importer.values(for: ["Toko Maju", "x", "TM"], number: 2),
            [.string("Toko Maju"), .string("Toko Maju"), .string("TM")])
        XCTAssertEqual(
            importer.insertStatement(rows: [[.string("a"), .string("a"), .string("b")]]).sql,
            "INSERT INTO \"public\".\"barang\" (\"nama\", \"nama_tampil\", \"kode\") VALUES ($1, $2, $3)")
        XCTAssertTrue(CSVImportPlan.missingRequired(plan.assignments, columns: columns).isEmpty)
    }

    /// The plan built from the file's side still says what it said.
    func testAMappingFromTheFileSideIsTheSamePlan() {
        var plan = CSVImportPlan(table: table, mapping: ["id", nil, "nama"])
        XCTAssertEqual(
            plan.assignments, [ImportAssignment(column: "id", source: 0), ImportAssignment(column: "nama", source: 2)])
        XCTAssertEqual(plan.sourceCount, 3)
        XCTAssertEqual(plan.mapping, ["id", nil, "nama"])
        plan.mapping = [nil, "kota"]
        XCTAssertEqual(plan.assignments, [ImportAssignment(column: "kota", source: 1)])
        XCTAssertEqual(plan.mapping, [nil, "kota"])
        XCTAssertFalse(plan.removesFormulaGuard)
    }
}
