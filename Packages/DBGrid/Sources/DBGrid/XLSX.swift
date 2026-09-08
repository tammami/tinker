import DBCore
import Foundation
import zlib

/// Writes a zip archive entry by entry, streaming each entry's bytes through deflate.
///
/// Nothing is held: an entry's compressed bytes go to the file as they are produced,
/// and its size and checksum follow in a data descriptor, the way every streaming zip
/// writer does it. The central directory is written at the end from what was recorded.
final class ZipStreamWriter {
    private struct Entry {
        let name: String
        let offset: UInt64
        var crc: UInt32 = 0
        var compressedSize: UInt64 = 0
        var uncompressedSize: UInt64 = 0
    }

    private let handle: FileHandle
    private var position: UInt64 = 0
    private var entries: [Entry] = []
    private var current: Entry?
    private var deflater: GzipDeflater?

    /// Zip without ZIP64 records addresses at most 4 GiB; past that the file would be silently wrong.
    static let sizeLimit = UInt64(UInt32.max)

    init(url: URL) throws {
        try FileManager.default.createPrivateFile(at: url)
        handle = try FileHandle(forWritingTo: url)
    }

    /// Opens an entry; bytes written until `endEntry` belong to it.
    func beginEntry(name: String) throws {
        precondition(current == nil, "an entry is already open")
        var header = Data()
        header.append(le32(0x0403_4B50))
        header.append(le16(20))  // version needed: deflate
        header.append(le16(0x0808))  // bit 3: sizes follow in a descriptor; bit 11: UTF-8 names
        header.append(le16(8))  // deflate
        header.append(le16(0))  // time
        header.append(le16(0x21))  // date: 1980-01-01
        header.append(le32(0))  // crc, in the descriptor
        header.append(le32(0))  // compressed size, in the descriptor
        header.append(le32(0))  // uncompressed size, in the descriptor
        let nameBytes = Data(name.utf8)
        header.append(le16(UInt16(nameBytes.count)))
        header.append(le16(0))
        header.append(nameBytes)
        current = Entry(name: name, offset: position)
        deflater = try GzipDeflater(level: 6, raw: true)
        try emit(header)
    }

    func write(_ data: Data) throws {
        guard var entry = current, let deflater else { preconditionFailure("no entry is open") }
        guard !data.isEmpty else { return }
        entry.crc = data.withUnsafeBytes { raw in
            UInt32(crc32(uLong(entry.crc), raw.baseAddress?.assumingMemoryBound(to: Bytef.self), uInt(raw.count)))
        }
        entry.uncompressedSize += UInt64(data.count)
        let compressed = try deflater.compress(data)
        entry.compressedSize += UInt64(compressed.count)
        current = entry
        guard entry.uncompressedSize <= Self.sizeLimit, entry.compressedSize <= Self.sizeLimit,
            position + UInt64(compressed.count) <= Self.sizeLimit
        else { throw XLSXError.tooLarge }
        try emit(compressed)
    }

    func endEntry() throws {
        guard var entry = current, let deflater else { preconditionFailure("no entry is open") }
        let tail = try deflater.compress(Data(), finish: true)
        entry.compressedSize += UInt64(tail.count)
        guard entry.compressedSize <= Self.sizeLimit, position + UInt64(tail.count) + 16 <= Self.sizeLimit else {
            throw XLSXError.tooLarge
        }
        try emit(tail)
        var descriptor = Data()
        descriptor.append(le32(0x0807_4B50))
        descriptor.append(le32(entry.crc))
        descriptor.append(le32(UInt32(clamping: entry.compressedSize)))
        descriptor.append(le32(UInt32(clamping: entry.uncompressedSize)))
        try emit(descriptor)
        entries.append(entry)
        current = nil
        self.deflater = nil
    }

    /// Writes the central directory and closes the file.
    func finish() throws {
        precondition(current == nil, "an entry is still open")
        let directoryStart = position
        guard directoryStart <= Self.sizeLimit else { throw XLSXError.tooLarge }
        for entry in entries {
            var record = Data()
            record.append(le32(0x0201_4B50))
            record.append(le16(20))  // made by
            record.append(le16(20))  // needed
            record.append(le16(0x0808))
            record.append(le16(8))
            record.append(le16(0))
            record.append(le16(0x21))
            record.append(le32(entry.crc))
            record.append(le32(UInt32(clamping: entry.compressedSize)))
            record.append(le32(UInt32(clamping: entry.uncompressedSize)))
            let nameBytes = Data(entry.name.utf8)
            record.append(le16(UInt16(nameBytes.count)))
            record.append(le16(0))  // extra
            record.append(le16(0))  // comment
            record.append(le16(0))  // disk
            record.append(le16(0))  // internal attributes
            record.append(le32(0))  // external attributes
            record.append(le32(UInt32(clamping: entry.offset)))
            record.append(nameBytes)
            try emit(record)
        }
        let directorySize = position - directoryStart
        var end = Data()
        end.append(le32(0x0605_4B50))
        end.append(le16(0))
        end.append(le16(0))
        end.append(le16(UInt16(clamping: entries.count)))
        end.append(le16(UInt16(clamping: entries.count)))
        end.append(le32(UInt32(clamping: directorySize)))
        end.append(le32(UInt32(clamping: directoryStart)))
        end.append(le16(0))
        try emit(end)
        try handle.close()
    }

    private func emit(_ data: Data) throws {
        try handle.write(contentsOf: data)
        position += UInt64(data.count)
    }

    private func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    private func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
}

/// Why an Excel export stopped.
public enum XLSXError: Error, CustomStringConvertible, Sendable {
    /// A worksheet holds at most 1,048,576 rows, the header included.
    case tooManyRows(limit: Int)
    /// A worksheet holds at most 16,384 columns.
    case tooManyColumns(limit: Int)
    /// The archive would pass 4 GiB, which this writer does not address.
    case tooLarge

    public var description: String {
        switch self {
        case let .tooManyRows(limit):
            "An Excel worksheet holds at most \(limit) rows; export the rest as CSV or split the query."
        case let .tooManyColumns(limit):
            "An Excel worksheet holds at most \(limit) columns."
        case .tooLarge:
            "The workbook would exceed 4 GB, more than an .xlsx file can hold; export as CSV instead."
        }
    }
}

/// Writes rows into an `.xlsx` workbook with one sheet, streaming.
///
/// The workbook is the plain Office Open XML shape Excel writes itself, minus what a
/// data export never needs: strings are inline, numbers are numbers, the header row is
/// bold. Rows go straight into the zip as they are written, so memory stays flat
/// however many there are.
public final class XLSXWorkbookWriter {
    /// Excel's hard limit on rows per worksheet.
    public static let rowLimit = 1_048_576
    /// Excel's hard limit on columns per worksheet (`XFD`).
    public static let columnLimit = 16_384
    /// Excel's limit on UTF-16 units in one cell; longer text is cut to fit.
    static let cellTextLimit = 32_767
    private static let chunk = 256 * 1_024

    private let zip: ZipStreamWriter
    private var pending = Data()
    private var rowNumber = 0
    private var columnCount = 0
    private var overflowed = false

    public init(url: URL) throws {
        zip = try ZipStreamWriter(url: url)
    }

    /// Writes the fixed parts and opens the sheet. `title` names the sheet tab.
    public func begin(columns: [ColumnMeta], includeHeader: Bool, title: String) throws {
        guard columns.count <= Self.columnLimit else { throw XLSXError.tooManyColumns(limit: Self.columnLimit) }
        columnCount = columns.count
        try put(
            "[Content_Types].xml",
            """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>
            """)
        try put(
            "_rels/.rels",
            """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
            """)
        try put(
            "xl/workbook.xml",
            """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="\(Self.escape(Self.sheetName(title)))" sheetId="1" r:id="rId1"/></sheets></workbook>
            """)
        try put(
            "xl/_rels/workbook.xml.rels",
            """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>
            """)
        // Style 0 is the default; style 1 is bold, for the header row.
        try put(
            "xl/styles.xml",
            """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs></styleSheet>
            """)
        try zip.beginEntry(name: "xl/worksheets/sheet1.xml")
        pending.append(
            contentsOf: """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
                """.utf8)
        if includeHeader {
            try writeRow(columns.map { .string($0.name) }, style: 1)
        }
    }

    /// Writes one row and returns true. Past Excel's limit rows are dropped, false is
    /// returned, and `finish` reports it.
    @discardableResult
    public func write(row: [DBValue]) throws -> Bool {
        guard !overflowed else { return false }
        guard rowNumber < Self.rowLimit else {
            overflowed = true
            return false
        }
        try writeRow(row, style: 0)
        return true
    }

    private func writeRow(_ values: [DBValue], style: Int) throws {
        rowNumber += 1
        var xml = "<row r=\"\(rowNumber)\">"
        for (index, value) in values.enumerated() {
            let ref = Self.columnLetters(index) + String(rowNumber)
            let styleAttribute = style == 0 ? "" : " s=\"\(style)\""
            switch value {
            case .null:
                continue
            case let .bool(flag):
                xml += "<c r=\"\(ref)\" t=\"b\"\(styleAttribute)><v>\(flag ? 1 : 0)</v></c>"
            case let .int(number):
                xml += "<c r=\"\(ref)\"\(styleAttribute)><v>\(number)</v></c>"
            case let .uint(number):
                xml += "<c r=\"\(ref)\"\(styleAttribute)><v>\(number)</v></c>"
            case let .double(number) where number.isFinite:
                xml += "<c r=\"\(ref)\"\(styleAttribute)><v>\(number)</v></c>"
            case let .decimal(text) where Self.isPlainNumber(text):
                xml += "<c r=\"\(ref)\"\(styleAttribute)><v>\(text)</v></c>"
            default:
                let text = Self.clip(ClipboardFormatter.cellText(value))
                xml += "<c r=\"\(ref)\" t=\"inlineStr\"\(styleAttribute)><is><t xml:space=\"preserve\">"
                xml += Self.escape(text) + "</t></is></c>"
            }
        }
        xml += "</row>\n"
        pending.append(contentsOf: xml.utf8)
        if pending.count >= Self.chunk { try flushPending() }
    }

    /// The number of rows written, the header included.
    public var rowsWritten: Int { rowNumber }

    /// Closes the sheet and the archive. Throws when rows were dropped at Excel's limit;
    /// the file written so far is still a valid workbook.
    public func finish() throws {
        pending.append(contentsOf: "</sheetData></worksheet>".utf8)
        try flushPending()
        try zip.endEntry()
        try zip.finish()
        if overflowed { throw XLSXError.tooManyRows(limit: Self.rowLimit) }
    }

    private func put(_ name: String, _ content: String) throws {
        try zip.beginEntry(name: name)
        try zip.write(Data(content.utf8))
        try zip.endEntry()
    }

    private func flushPending() throws {
        guard !pending.isEmpty else { return }
        try zip.write(pending)
        pending.removeAll(keepingCapacity: true)
    }

    /// `A`, `B`, … `Z`, `AA`, `AB`, … for a zero-based column index.
    static func columnLetters(_ index: Int) -> String {
        var number = index + 1
        var letters = ""
        while number > 0 {
            let remainder = (number - 1) % 26
            letters = String(UnicodeScalar(UInt8(65 + remainder))) + letters
            number = (number - 1) / 26
        }
        return letters
    }

    /// Digits, one sign, one point, one exponent with digits after it: what Excel reads
    /// as a number.
    static func isPlainNumber(_ text: String) -> Bool {
        guard !text.isEmpty, text.count < 40 else { return false }
        var sawDigit = false
        var sawPoint = false
        var sawExponent = false
        var exponentDigits = 0
        for (offset, character) in text.enumerated() {
            switch character {
            case "0" ... "9":
                sawDigit = true
                if sawExponent { exponentDigits += 1 }
            case "-", "+":
                guard offset == 0 || text[text.index(text.startIndex, offsetBy: offset - 1)].lowercased() == "e"
                else { return false }
            case ".":
                guard !sawPoint, !sawExponent else { return false }
                sawPoint = true
            case "e", "E":
                guard sawDigit, !sawExponent else { return false }
                sawExponent = true
            default: return false
            }
        }
        return sawDigit && (!sawExponent || exponentDigits > 0)
    }

    /// Escapes the five XML characters and drops control characters XML 1.0 forbids.
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\t", "\n", "\r": out.unicodeScalars.append(scalar)
            case _ where scalar.value < 0x20 || scalar.value == 0xFFFE || scalar.value == 0xFFFF: continue
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// Cuts text to Excel's cell limit, counted in UTF-16 units as Excel counts, without
    /// splitting a surrogate pair.
    static func clip(_ text: String) -> String {
        guard text.utf16.count > cellTextLimit else { return text }
        var end = text.utf16.index(text.utf16.startIndex, offsetBy: cellTextLimit)
        if let cut = String(text.utf16[..<end]) { return cut }
        end = text.utf16.index(before: end)
        return String(text.utf16[..<end]) ?? ""
    }

    /// A sheet name Excel accepts: 31 characters at most, none of `[]:*?/\`, no
    /// apostrophe at either end, and not the reserved `History`.
    static func sheetName(_ title: String) -> String {
        let cleaned = title.map { "[]:*?/\\".contains($0) ? "_" : $0 }
        let trimmed = String(cleaned.prefix(31))
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "'"))
        guard !trimmed.isEmpty, trimmed.lowercased() != "history" else { return "Sheet1" }
        return trimmed
    }
}
