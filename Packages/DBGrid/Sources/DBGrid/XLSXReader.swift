import Foundation

/// Why a workbook could not be read.
public struct XLSXReadError: Error, Hashable, CustomStringConvertible, Sendable {
    public let description: String

    init(_ description: String) { self.description = description }
}

/// An `.xlsx` workbook opened for import: its first sheet, read a row at a time.
///
/// Excel's own files and Tinker's exports both work: shared or inline strings, numbers
/// kept exactly as the file writes them (never through `Double`), booleans, formulas by
/// their cached value, and dates — which Excel stores as day counts — turned back into
/// `YYYY-MM-DD`, `HH:MM:SS` or both, as the cell's number format says.
///
/// The archive is mapped, not read. A sheet over a few megabytes is inflated into a
/// temporary file that is mapped and unlinked at once, so memory holds one row at a
/// time however large the sheet; the shared-string table is the only part kept whole.
public final class XLSXWorkbook: Sendable {
    /// The sheet that is read: the workbook's first unless another was asked for.
    public let sheetName: String
    /// Every worksheet of the workbook, in the order of its tabs.
    public let sheets: [XLSXSheetInfo]
    /// Where the sheet that is read sits in `sheets`.
    public let sheetIndex: Int
    let sheet: Data
    let sharedStrings: [String]
    /// Index in `cellXfs` → what kind of date the cell's number stands for.
    let dateStyles: [Int: ExcelDateKind]
    let uses1904Dates: Bool
    /// True for a workbook a spreadsheet wrote, whose numbers are doubles saved with up
    /// to 17 digits. False for Tinker's own export, whose numbers are the server's exact
    /// text and must come back digit for digit.
    let numbersAreDoubles: Bool
    /// The archive, kept so another sheet can be opened without reading the rest again.
    private let archive: ZipArchive

    /// Sheets up to this size are inflated in memory; larger ones go through a file.
    static let inMemoryLimit: UInt64 = 16 * 1_024 * 1_024

    public convenience init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    /// Opens the workbook on its first sheet.
    public convenience init(data: Data) throws {
        try self.init(data: data, sheet: nil)
    }

    /// Opens the workbook on the sheet at `sheet` in `sheets`, or on the first when nil.
    public init(data: Data, sheet index: Int?) throws {
        let zip = try ZipArchive(data: data)
        let workbookXML = try Self.part("xl/workbook.xml", from: zip)
        var listed: [(name: String, relation: String?, isHidden: Bool)] = []
        var uses1904 = false
        XMLScanner.walk(workbookXML) { token in
            guard case let .open(name, attributes, _) = token else { return true }
            if name == "workbookPr" { uses1904 = ["1", "true"].contains(attributes["date1904"] ?? "") }
            if name == "sheet" {
                let relation = attributes.first { $0.key == "r:id" || $0.key.hasSuffix(":id") }?.value
                let state = attributes["state"] ?? "visible"
                listed.append((attributes["name"] ?? "Sheet\(listed.count + 1)", relation, state != "visible"))
            }
            return true
        }
        guard !listed.isEmpty else { throw XLSXReadError("The workbook has no sheets.") }

        // Each sheet's part, from the workbook's relationships.
        var targets: [String: (path: String, isWorksheet: Bool)] = [:]
        if zip.contains("xl/_rels/workbook.xml.rels"),
            let rels = try? Self.part("xl/_rels/workbook.xml.rels", from: zip)
        {
            XMLScanner.walk(rels) { token in
                guard case let .open("Relationship", attributes, _) = token, let id = attributes["Id"],
                    let target = attributes["Target"]
                else { return true }
                // A chart sheet or a macro sheet has a tab but no rows.
                let type = attributes["Type"] ?? ""
                let isOther = ["/chartsheet", "/dialogsheet", "/macrosheet"].contains { type.hasSuffix($0) }
                targets[id] = (Self.resolve(target), !isOther)
                return true
            }
        }
        var found: [XLSXSheetInfo] = []
        for (position, entry) in listed.enumerated() {
            let target = entry.relation.flatMap { targets[$0] }
            if let target, !target.isWorksheet { continue }
            // `sheetN.xml` when the relationships say nothing.
            let path = target?.path ?? "xl/worksheets/sheet\(position + 1).xml"
            found.append(XLSXSheetInfo(index: found.count, name: entry.name, isHidden: entry.isHidden, path: path))
        }
        guard !found.isEmpty else { throw XLSXReadError("The workbook has no worksheets, only charts.") }
        let chosen = index ?? 0
        guard found.indices.contains(chosen) else {
            throw XLSXReadError("The workbook has \(found.count) sheets; there is no sheet \(chosen + 1).")
        }
        guard zip.contains(found[chosen].path) else {
            throw XLSXReadError(
                chosen == 0
                    ? "The workbook's first sheet is missing." : "The sheet “\(found[chosen].name)” is missing.")
        }

        archive = zip
        sheets = found
        sheetIndex = chosen
        sheetName = found[chosen].name
        uses1904Dates = uses1904
        // Tinker's export writes neither part: its strings are inline and it has no
        // application to name.
        numbersAreDoubles = zip.contains("docProps/app.xml") || zip.contains("xl/sharedStrings.xml")
        sharedStrings =
            zip.contains("xl/sharedStrings.xml")
            ? try Self.sharedStrings(Self.part("xl/sharedStrings.xml", from: zip)) : []
        dateStyles = zip.contains("xl/styles.xml") ? try Self.dateStyles(Self.part("xl/styles.xml", from: zip)) : [:]
        sheet = try Self.inflate(found[chosen].path, from: zip)
    }

    /// Another sheet of the same workbook: the strings and styles read once are shared.
    private init(_ other: XLSXWorkbook, sheet index: Int) throws {
        guard other.sheets.indices.contains(index) else {
            throw XLSXReadError("The workbook has \(other.sheets.count) sheets; there is no sheet \(index + 1).")
        }
        let info = other.sheets[index]
        guard other.archive.contains(info.path) else { throw XLSXReadError("The sheet “\(info.name)” is missing.") }
        archive = other.archive
        sheets = other.sheets
        sheetIndex = index
        sheetName = info.name
        uses1904Dates = other.uses1904Dates
        numbersAreDoubles = other.numbersAreDoubles
        sharedStrings = other.sharedStrings
        dateStyles = other.dateStyles
        sheet = try Self.inflate(info.path, from: other.archive)
    }

    /// The same workbook read from another of its sheets.
    public func selecting(sheet index: Int) throws -> XLSXWorkbook {
        index == sheetIndex ? self : try XLSXWorkbook(self, sheet: index)
    }

    /// Opens a workbook away from the caller's actor: inflating a large sheet takes a
    /// moment, and the import sheet must not freeze while it does.
    public static func open(data: Data, sheet: Int? = nil) async throws -> XLSXWorkbook {
        try XLSXWorkbook(data: data, sheet: sheet)
    }

    /// A small part read whole, refused when it is not in an encoding the scanner reads.
    private static func part(_ name: String, from zip: ZipArchive) throws -> Data {
        let data = try zip.readAll(name)
        try checkEncoding(data, of: name)
        return data
    }

    /// The scanner walks UTF-8, which is what every spreadsheet writes. XML allows
    /// UTF-16 too; read as UTF-8 it would come out as noise, so it is refused by name.
    static func checkEncoding(_ data: Data, of name: String) throws {
        let head = Array(data.prefix(200))
        let refusal = XLSXReadError(
            "\(name) is encoded as UTF-16, which Tinker cannot read. Open the workbook in Excel or Numbers and "
                + "save it again as .xlsx.")
        if head.starts(with: [0xFF, 0xFE]) || head.starts(with: [0xFE, 0xFF]) { throw refusal }
        if head.count >= 4, (head[0] == 0x3C && head[1] == 0) || (head[0] == 0 && head[1] == 0x3C) { throw refusal }
        let declaration = String(decoding: head, as: UTF8.self).lowercased()
        guard declaration.hasPrefix("<?xml") || declaration.hasPrefix("\u{FEFF}<?xml"),
            let end = declaration.range(of: "?>"),
            let encoding = declaration[..<end.lowerBound].range(of: "encoding")
        else { return }
        let rest = declaration[encoding.upperBound ..< end.lowerBound]
        guard let open = rest.firstIndex(where: { $0 == "\"" || $0 == "'" }),
            let close = rest[rest.index(after: open)...].firstIndex(of: rest[open])
        else { return }
        let value = String(rest[rest.index(after: open) ..< close])
        guard ["utf-8", "utf8", "us-ascii", "ascii"].contains(value) else {
            throw XLSXReadError(
                "\(name) is encoded as \(value.uppercased()), which Tinker cannot read. Open the workbook in Excel "
                    + "or Numbers and save it again as .xlsx.")
        }
    }

    /// A reader over the sheet's rows, from the first. Cheap: nothing is re-read.
    public func rows() -> XLSXRowReader { XLSXRowReader(workbook: self) }

    // MARK: - Parts

    /// `worksheets/sheet1.xml` or `/xl/worksheets/sheet1.xml` → `xl/worksheets/sheet1.xml`.
    static func resolve(_ target: String) -> String {
        if target.hasPrefix("/") { return String(target.dropFirst()) }
        var parts = ["xl"]
        for piece in target.split(separator: "/") {
            if piece == ".." { _ = parts.popLast() } else if piece != "." { parts.append(String(piece)) }
        }
        return parts.joined(separator: "/")
    }

    private static func inflate(_ path: String, from zip: ZipArchive) throws -> Data {
        let data = try inflateUnchecked(path, from: zip)
        try checkEncoding(data, of: path)
        return data
    }

    private static func inflateUnchecked(_ path: String, from zip: ZipArchive) throws -> Data {
        guard let size = zip.uncompressedSize(of: path), size > inMemoryLimit else { return try zip.readAll(path) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tinker-xlsx-\(UUID().uuidString).xml")
        try FileManager.default.createPrivateFile(at: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        do {
            try zip.read(path) { try handle.write(contentsOf: $0) }
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        // Mapped before the name is removed; the pages stay reachable through the mapping.
        return try Data(contentsOf: url, options: .alwaysMapped)
    }

    /// Every `<si>`: plain text or rich-text runs joined; phonetic hints are left out.
    static func sharedStrings(_ xml: Data) -> [String] {
        var strings: [String] = []
        var current: String?
        var inText = false
        var phoneticDepth = 0
        XMLScanner.walk(xml) { token in
            switch token {
            case let .open(name, _, selfClosing):
                if name == "si" { current = selfClosing ? nil : ""; if selfClosing { strings.append("") } }
                if name == "rPh", !selfClosing { phoneticDepth += 1 }
                if name == "t", !selfClosing { inText = phoneticDepth == 0 }
            case let .close(name):
                if name == "t" { inText = false }
                if name == "rPh" { phoneticDepth -= 1 }
                if name == "si" {
                    strings.append(current ?? "")
                    current = nil
                }
            case let .text(text):
                if inText { current?.append(XMLScanner.unescapeOOXML(text)) }
            }
            return true
        }
        return strings
    }

    /// Which `cellXfs` entries format a number as a date, a time or both.
    static func dateStyles(_ xml: Data) -> [Int: ExcelDateKind] {
        var custom: [Int: String] = [:]
        var formats: [Int] = []
        var inCellXfs = false
        XMLScanner.walk(xml) { token in
            switch token {
            case let .open(name, attributes, selfClosing):
                if name == "numFmt", let id = attributes["numFmtId"].flatMap(Int.init) {
                    custom[id] = attributes["formatCode"] ?? ""
                }
                if name == "cellXfs", !selfClosing { inCellXfs = true }
                if name == "xf", inCellXfs { formats.append(attributes["numFmtId"].flatMap(Int.init) ?? 0) }
            case let .close(name):
                if name == "cellXfs" { inCellXfs = false }
            case .text:
                break
            }
            return true
        }
        var result: [Int: ExcelDateKind] = [:]
        for (index, id) in formats.enumerated() {
            if let kind = ExcelDateKind.of(formatID: id, code: custom[id]) { result[index] = kind }
        }
        return result
    }
}

/// One worksheet of a workbook, as its tab shows it.
public struct XLSXSheetInfo: Sendable, Hashable, Identifiable {
    /// Where the sheet sits among the workbook's worksheets, from zero.
    public let index: Int
    public let name: String
    /// Hidden in Excel (`hidden` or `veryHidden`). It still holds rows and can be read.
    public let isHidden: Bool
    /// The sheet's part in the archive.
    let path: String

    public var id: Int { index }
}

/// The rows of a workbook's sheet, one `[String]` per row, as `CSVReader` gives
/// them — so the import's header, mapping and coercion work the same.
///
/// Empty rows are skipped, as blank lines are in CSV. A cell the file leaves out is an
/// empty field, so every value stays under its own column.
public struct XLSXRowReader: RecordSource {
    public private(set) var recordNumber = 0
    private let workbook: XLSXWorkbook
    private var scanner: XMLScanner

    init(workbook: XLSXWorkbook) {
        self.workbook = workbook
        scanner = XMLScanner(workbook.sheet)
    }

    public mutating func next() -> [String]? {
        while let token = scanner.next() {
            switch token {
            case let .open("row", _, selfClosing):
                if selfClosing { continue }
                let row = readRow()
                if row.allSatisfy(\.isEmpty) { continue }
                recordNumber += 1
                return row
            case .close("sheetData"):
                return nil
            default:
                continue
            }
        }
        return nil
    }

    private mutating func readRow() -> [String] {
        var cells: [String] = []
        while let token = scanner.next() {
            switch token {
            case let .open("c", attributes, selfClosing):
                let value = selfClosing ? "" : readCell(type: attributes["t"], style: attributes["s"].flatMap(Int.init))
                // Excel stops at XFD; a reference past it (or one that is not a reference)
                // is damage, not data, and padding up to it would allocate without limit.
                let column: Int
                if let reference = attributes["r"] {
                    guard let index = Self.columnIndex(reference) else { continue }
                    column = index
                } else {
                    column = cells.count
                }
                guard column < Self.columnLimit else { continue }
                if column >= cells.count {
                    cells.append(contentsOf: repeatElement("", count: column - cells.count))
                    cells.append(value)
                } else {
                    cells[column] = value
                }
            case .close("row"):
                return cells
            default:
                continue
            }
        }
        return cells
    }

    private mutating func readCell(type: String?, style: Int?) -> String {
        var raw = ""
        var inline = ""
        var element = ""
        var phoneticDepth = 0
        loop: while let token = scanner.next() {
            switch token {
            case let .open(name, _, selfClosing):
                if selfClosing { continue }
                if name == "rPh" { phoneticDepth += 1 }
                element = name
            case let .close(name):
                if name == "c" { break loop }
                if name == "rPh" { phoneticDepth -= 1 }
                element = ""
            case let .text(text):
                if element == "v" { raw += XMLScanner.unescape(text) }
                if element == "t", phoneticDepth == 0 { inline += XMLScanner.unescapeOOXML(text) }
            }
        }
        switch type {
        case "s":
            guard let index = Int(raw), workbook.sharedStrings.indices.contains(index) else { return raw }
            return workbook.sharedStrings[index]
        case "inlineStr":
            return inline
        case "b":
            return raw == "1" ? "true" : raw == "0" ? "false" : raw
        case "str", "e", "d":
            return raw
        default:
            if let style, let kind = workbook.dateStyles[style],
                let text = ExcelDateKind.text(serial: raw, kind: kind, uses1904: workbook.uses1904Dates)
            {
                return text
            }
            return workbook.numbersAreDoubles ? Self.typedNumber(raw) : raw
        }
    }

    /// A number as it was typed, where Excel wrote out the binary fraction behind it.
    ///
    /// Excel keeps numbers as doubles and saves them with up to 17 digits, so a cell
    /// showing `-8.59940239` is stored as `-8.5994023899999995`. When the text is such a
    /// dump — 16 or 17 significant digits — and a number of at most 15 digits is the very
    /// same double, that shorter number is what the cell shows and what was entered.
    /// Anything else is returned untouched: an exact decimal Tinker exported keeps every
    /// digit, and a number with more digits than a double holds was never one.
    static func typedNumber(_ raw: String) -> String {
        guard raw.utf8.count >= 16, raw.utf8.count <= 26 else { return raw }
        let mantissa = raw.split(whereSeparator: { $0 == "e" || $0 == "E" }).first ?? Substring(raw)
        let significant = mantissa.filter(\.isNumber).drop { $0 == "0" }.count
        guard significant == 16 || significant == 17, let value = Double(raw), value.isFinite else { return raw }
        var short = "\(value)"
        guard !short.contains("e"), !short.contains("E") else { return raw }
        if short.hasSuffix(".0") { short.removeLast(2) }
        let shortDigits = short.filter(\.isNumber).drop { $0 == "0" }.count
        guard shortDigits <= 15, Double(short) == value else { return raw }
        return short
    }

    /// Excel's last column, `XFD`, is index 16 383.
    static let columnLimit = 16_384

    /// `C7` → 2. Nil for anything that is not one to three letters followed by digits.
    static func columnIndex(_ reference: String) -> Int? {
        var index = 0
        var letters = 0
        for scalar in reference.unicodeScalars {
            if letters > 3 { return nil }
            switch scalar.value {
            case 65 ... 90:
                index = index * 26 + Int(scalar.value - 64)
                letters += 1
            case 97 ... 122:
                index = index * 26 + Int(scalar.value - 96)
                letters += 1
            case 48 ... 57:
                return letters == 0 || letters > 3 || index > columnLimit ? nil : index - 1
            default:
                return nil
            }
        }
        return letters == 0 || letters > 3 || index > columnLimit ? nil : index - 1
    }
}

/// What an Excel number format makes of a day count.
enum ExcelDateKind: Sendable, Hashable {
    /// `time` is a time of day; `duration` is elapsed time (`[h]:mm:ss`), where hours
    /// keep counting past a day.
    case date, time, dateTime, duration

    /// Built-in formats by id, then a custom format by what its code asks for.
    static func of(formatID id: Int, code: String?) -> ExcelDateKind? {
        switch id {
        case 14 ... 17, 27 ... 31, 34 ... 36, 50 ... 58: return .date
        case 18 ... 21, 32, 33, 45, 47: return .time
        case 46: return .duration
        case 22: return .dateTime
        default: break
        }
        guard let code, id >= 164 else { return nil }
        // Quoted text, escaped characters and [colour]/[$-locale] sections say nothing
        // about the value; `[h]` (elapsed hours) does.
        var cleaned = ""
        var inQuote = false
        var bracket: String?
        var escape = false
        var isElapsed = false
        for character in code.lowercased() {
            if escape { escape = false; continue }
            if var inside = bracket {
                if character == "]" {
                    // Only `[h]`, `[mm]`, `[ss]` and the like are about the value; a colour
                    // (`[Magenta]`), a currency (`[$USD]`) or a locale (`[$-421]`) is not.
                    if let first = inside.first, "hms".contains(first), inside.allSatisfy({ $0 == first }) {
                        cleaned += inside
                        isElapsed = true
                    }
                    bracket = nil
                } else {
                    inside.append(character)
                    bracket = inside
                }
                continue
            }
            if character == "\\" { escape = true; continue }
            if character == "\"" { inQuote.toggle(); continue }
            if inQuote { continue }
            if character == "[" { bracket = ""; continue }
            cleaned.append(character)
        }
        // A format for positive numbers is the first section.
        let section = cleaned.split(separator: ";", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        if section.contains("general") { return nil }
        let hasDate = section.contains("y") || section.contains("d")
        let hasTime = section.contains("h") || section.contains("s")
        switch (hasDate, hasTime) {
        case (true, true): return .dateTime
        case (true, false): return .date
        case (false, true): return isElapsed ? .duration : .time
        default:
            // `mm` alone, or `mmm yy` without the y already caught: months.
            return section.contains("m") ? .date : nil
        }
    }

    /// A day count as ISO text, with no time zone and no `Date` in between: Excel's
    /// values are wall-clock readings. Nil for text that is not a non-negative number.
    static func text(serial: String, kind: ExcelDateKind, uses1904: Bool) -> String? {
        guard let value = Double(serial), value.isFinite, value >= 0, value < 3_000_000 else { return nil }
        var days = Int(value.rounded(.down))
        var seconds = Int(((value - Double(days)) * 86_400).rounded())
        if seconds >= 86_400 {
            days += 1
            seconds -= 86_400
        }
        let time = String(format: "%02d:%02d:%02d", seconds / 3_600, seconds / 60 % 60, seconds % 60)
        // A time of day shows the clock whatever the date; a duration keeps counting
        // hours past a day, as `[h]:mm:ss` does.
        if kind == .time { return time }
        if kind == .duration {
            let hours = days * 24 + seconds / 3_600
            return String(format: "%02d:%02d:%02d", hours, seconds / 60 % 60, seconds % 60)
        }
        let dayNumber: Int
        if uses1904 {
            dayNumber = daysFromCivil(1904, 1, 1) + days
        } else if days >= 61 {
            // Excel counts a 29 February 1900 that never was (Lotus's bug), so serials
            // from 61 on are one ahead of the calendar.
            dayNumber = daysFromCivil(1899, 12, 30) + days
        } else {
            dayNumber = daysFromCivil(1899, 12, 31) + days
        }
        let (year, month, day) = civilFromDays(dayNumber)
        let date = String(format: "%04d-%02d-%02d", year, month, day)
        return kind == .date ? date : "\(date) \(time)"
    }

    /// Days since 1970-01-01 in the proleptic Gregorian calendar (H. Hinnant).
    static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func civilFromDays(_ days: Int) -> (Int, Int, Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }
}

// MARK: - Zip

/// The entries of a zip archive, found through its central directory — the only place
/// a streaming writer (Tinker's own, among others) records the sizes.
struct ZipArchive {
    struct Entry {
        let method: UInt16
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localHeaderOffset: UInt64
    }

    private let data: Data
    private let entries: [String: Entry]
    /// Parts other than the sheet are read whole; none is anywhere near this.
    static let wholePartLimit: UInt64 = 256 * 1_024 * 1_024
    /// No part inflates past this: a million rows of a wide sheet is well under it.
    static let partLimit: UInt64 = 4 * 1_024 * 1_024 * 1_024

    init(data: Data) throws {
        self.data = data
        let bytes = ByteView(data)
        let notAWorkbook = XLSXReadError("This is not an Excel workbook (.xlsx); the zip directory is missing.")
        // The end record sits in the last 22 bytes plus at most a 64 KiB comment.
        var end: Int?
        var probe = data.count - 22
        while probe >= max(0, data.count - 65_557) {
            if bytes.u32(probe) == 0x0605_4B50 {
                end = probe
                break
            }
            probe -= 1
        }
        guard let end, var count = bytes.u16(end + 10).map(UInt64.init),
            var directory = bytes.u32(end + 16).map(UInt64.init)
        else { throw notAWorkbook }
        // ZIP64: a locator just before the end record points at the larger one.
        if end >= 20, bytes.u32(end - 20) == 0x0706_4B50, let record = bytes.u64(end - 12).flatMap(Int.init(exactly:)),
            bytes.u32(record) == 0x0606_4B50, let bigCount = bytes.u64(record + 32),
            let bigDirectory = bytes.u64(record + 48)
        {
            count = bigCount
            directory = bigDirectory
        }
        var entries: [String: Entry] = [:]
        guard let start = Int(exactly: directory), start < data.count, count <= UInt64(data.count / 46) else {
            throw notAWorkbook
        }
        var position = start
        for _ in 0 ..< count {
            guard bytes.u32(position) == 0x0201_4B50, let method = bytes.u16(position + 10),
                var compressed = bytes.u32(position + 20).map(UInt64.init),
                var uncompressed = bytes.u32(position + 24).map(UInt64.init),
                let nameLength = bytes.u16(position + 28).map(Int.init),
                let extraLength = bytes.u16(position + 30).map(Int.init),
                let commentLength = bytes.u16(position + 32).map(Int.init),
                var offset = bytes.u32(position + 42).map(UInt64.init),
                let name = bytes.string(position + 46, nameLength)
            else { throw notAWorkbook }
            // ZIP64 extra field: only the values that overflowed are in it, in this order.
            var extra = position + 46 + nameLength
            let extraEnd = extra + extraLength
            while extra + 4 <= extraEnd, let id = bytes.u16(extra), let size = bytes.u16(extra + 2).map(Int.init) {
                if id == 0x0001 {
                    var field = extra + 4
                    if uncompressed == 0xFFFF_FFFF, let value = bytes.u64(field) { uncompressed = value; field += 8 }
                    if compressed == 0xFFFF_FFFF, let value = bytes.u64(field) { compressed = value; field += 8 }
                    if offset == 0xFFFF_FFFF, let value = bytes.u64(field) { offset = value }
                }
                extra += 4 + size
            }
            entries[name] = Entry(
                method: method, compressedSize: compressed, uncompressedSize: uncompressed, localHeaderOffset: offset)
            position = extraEnd + commentLength
        }
        self.entries = entries
    }

    func contains(_ name: String) -> Bool { entries[name] != nil }

    func uncompressedSize(of name: String) -> UInt64? { entries[name]?.uncompressedSize }

    /// An entry whole, for the small parts: workbook, relationships, strings, styles.
    func readAll(_ name: String) throws -> Data {
        guard let entry = entries[name] else { throw XLSXReadError("The workbook has no \(name).") }
        guard entry.uncompressedSize <= Self.wholePartLimit else {
            throw XLSXReadError("\(name) is too large to read (\(entry.uncompressedSize >> 20) MiB).")
        }
        var result = Data(capacity: Int(entry.uncompressedSize))
        try read(name) { result.append($0) }
        return result
    }

    /// Streams an entry's bytes to `body`, a piece at a time. Stops with an error past
    /// the size the directory declared, so a crafted archive cannot fill the disk.
    func read(_ name: String, _ body: (Data) throws -> Void) throws {
        guard let entry = entries[name] else { throw XLSXReadError("The workbook has no \(name).") }
        let bytes = ByteView(data)
        let damaged = XLSXReadError("\(name) is damaged in the archive.")
        guard let header = Int(exactly: entry.localHeaderOffset), header < data.count,
            bytes.u32(header) == 0x0403_4B50, let nameLength = bytes.u16(header + 26).map(Int.init),
            let extraLength = bytes.u16(header + 28).map(Int.init)
        else { throw damaged }
        let start = header + 30 + nameLength + extraLength
        guard let compressed = Int(exactly: entry.compressedSize), compressed <= data.count - min(start, data.count),
            start + compressed <= data.count
        else { throw XLSXReadError("\(name) is cut short; the file is incomplete.") }
        let end = start + compressed
        // A part that claims to inflate a thousand times over, or past the absolute cap,
        // is a zip bomb or damage; real spreadsheets compress XML ten to fifty times.
        guard entry.uncompressedSize <= Self.partLimit,
            entry.uncompressedSize <= max(UInt64(compressed), 1_024) * 1_000
        else {
            throw XLSXReadError("\(name) claims \(entry.uncompressedSize >> 20) MiB; the file is refused as unsafe.")
        }
        let base = data.startIndex
        let piece = 64 * 1_024
        switch entry.method {
        case 0:
            guard UInt64(compressed) == entry.uncompressedSize else { throw damaged }
            var offset = start
            while offset < end {
                let next = min(offset + 1_024 * 1_024, end)
                try body(data.subdata(in: base + offset ..< base + next))
                offset = next
            }
        case 8:
            let inflater = try GzipInflater(raw: true)
            var produced: UInt64 = 0
            var offset = start
            while offset < end, !inflater.isFinished {
                let next = min(offset + piece, end)
                let output: Data
                do {
                    output = try inflater.decompress(data.subdata(in: base + offset ..< base + next))
                } catch {
                    throw damaged
                }
                produced += UInt64(output.count)
                guard produced <= entry.uncompressedSize else {
                    throw XLSXReadError("\(name) inflates past the size the archive declares.")
                }
                if !output.isEmpty { try body(output) }
                offset = next
            }
            // A stream that stops early, or inflates to other than it said, is damage:
            // importing the rows before it would pass off part of a sheet as all of it.
            guard inflater.isFinished, produced == entry.uncompressedSize else { throw damaged }
        default:
            throw XLSXReadError("\(name) uses a compression method (\(entry.method)) Tinker cannot read.")
        }
    }
}

/// Little-endian reads that answer nil instead of trapping past the end.
private struct ByteView {
    let data: Data

    init(_ data: Data) { self.data = data }

    func u16(_ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        let base = data.startIndex + offset
        return UInt16(data[base]) | UInt16(data[base + 1]) << 8
    }

    func u32(_ offset: Int) -> UInt32? {
        guard let low = u16(offset), let high = u16(offset + 2) else { return nil }
        return UInt32(low) | UInt32(high) << 16
    }

    func u64(_ offset: Int) -> UInt64? {
        guard let low = u32(offset), let high = u32(offset + 4) else { return nil }
        return UInt64(low) | UInt64(high) << 32
    }

    func string(_ offset: Int, _ length: Int) -> String? {
        guard offset >= 0, offset + length <= data.count else { return nil }
        let base = data.startIndex + offset
        return String(decoding: data[base ..< base + length], as: UTF8.self)
    }
}

// MARK: - XML

/// A forward-only scanner over the XML Office writes: tags with their attributes, and
/// the text between them. It skips declarations, comments and doctype; CDATA is text.
/// Namespace prefixes are dropped from element names (`x:row` is `row`) but kept on
/// attributes, where `r:id` needs its prefix to be told from `id`.
///
/// It is not a validating parser, and does not need to be: it reads what spreadsheet
/// writers produce, and a malformed file ends the scan instead of trapping.
struct XMLScanner {
    enum Token {
        case open(String, [String: String], Bool)
        case close(String)
        /// Raw text, entities still escaped; `unescape` when it is wanted.
        case text(Substring)
    }

    private let bytes: Data
    private var position: Data.Index

    init(_ data: Data) {
        bytes = data
        position = data.startIndex
    }

    /// Runs `body` over every token until it returns false or the document ends.
    static func walk(_ data: Data, _ body: (Token) -> Bool) {
        var scanner = XMLScanner(data)
        while let token = scanner.next(), body(token) {}
    }

    mutating func next() -> Token? {
        while position < bytes.endIndex {
            if bytes[position] != UInt8(ascii: "<") {
                let start = position
                while position < bytes.endIndex, bytes[position] != UInt8(ascii: "<") { position += 1 }
                return .text(Self.decode(bytes[start ..< position]))
            }
            if starts(with: "<![CDATA[") {
                let start = position + 9
                guard let end = find("]]>", from: start) else { return nil }
                position = end + 3
                // Returned escaped so `unescape` leaves the literal text as it was.
                return .text(Self.escape(Self.decode(bytes[start ..< end])))
            }
            if starts(with: "<?") || starts(with: "<!") {
                let terminator = starts(with: "<!--") ? "-->" : ">"
                guard let end = find(terminator, from: position + 2) else { return nil }
                position = end + terminator.utf8.count
                continue
            }
            return readTag()
        }
        return nil
    }

    private mutating func readTag() -> Token? {
        position += 1
        let isClose = position < bytes.endIndex && bytes[position] == UInt8(ascii: "/")
        if isClose { position += 1 }
        let name = Self.localName(readName())
        if isClose {
            guard let end = find(">", from: position) else { return nil }
            position = end + 1
            return .close(name)
        }
        var attributes: [String: String] = [:]
        while position < bytes.endIndex {
            skipSpaces()
            guard position < bytes.endIndex else { return nil }
            let byte = bytes[position]
            if byte == UInt8(ascii: ">") {
                position += 1
                return .open(name, attributes, false)
            }
            if byte == UInt8(ascii: "/") {
                guard let end = find(">", from: position) else { return nil }
                position = end + 1
                return .open(name, attributes, true)
            }
            let key = readName()
            guard !key.isEmpty else { return nil }
            skipSpaces()
            guard position < bytes.endIndex, bytes[position] == UInt8(ascii: "=") else { continue }
            position += 1
            skipSpaces()
            guard position < bytes.endIndex else { return nil }
            let quote = bytes[position]
            guard quote == UInt8(ascii: "\"") || quote == UInt8(ascii: "'") else { return nil }
            position += 1
            let start = position
            while position < bytes.endIndex, bytes[position] != quote { position += 1 }
            guard position < bytes.endIndex else { return nil }
            attributes[key] = Self.unescape(Self.decode(bytes[start ..< position]))
            position += 1
        }
        return nil
    }

    private mutating func readName() -> String {
        let start = position
        while position < bytes.endIndex {
            let byte = bytes[position]
            if byte == UInt8(ascii: " ") || byte == UInt8(ascii: ">") || byte == UInt8(ascii: "/")
                || byte == UInt8(ascii: "=") || byte == 9 || byte == 10 || byte == 13
            {
                break
            }
            position += 1
        }
        return String(decoding: bytes[start ..< position], as: UTF8.self)
    }

    private mutating func skipSpaces() {
        while position < bytes.endIndex, [32, 9, 10, 13].contains(bytes[position]) { position += 1 }
    }

    private func starts(with literal: String) -> Bool {
        var index = position
        for byte in literal.utf8 {
            guard index < bytes.endIndex, bytes[index] == byte else { return false }
            index += 1
        }
        return true
    }

    private func find(_ literal: String, from start: Data.Index) -> Data.Index? {
        let pattern = Array(literal.utf8)
        guard let first = pattern.first else { return nil }
        var index = start
        while index + pattern.count <= bytes.endIndex {
            if bytes[index] == first {
                var matched = true
                for offset in 1 ..< pattern.count where bytes[index + offset] != pattern[offset] {
                    matched = false
                    break
                }
                if matched { return index }
            }
            index += 1
        }
        return nil
    }

    private static func decode(_ slice: Data.SubSequence) -> Substring {
        Substring(String(decoding: slice, as: UTF8.self))
    }

    private static func localName(_ name: String) -> String {
        guard let colon = name.lastIndex(of: ":") else { return name }
        return String(name[name.index(after: colon)...])
    }

    private static func escape(_ text: Substring) -> Substring {
        Substring(text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;"))
    }

    /// The five named entities and numeric references.
    static func unescape(_ text: Substring) -> String {
        guard text.contains("&") else { return String(text) }
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            // Entities are short: look for the `;` in the next few characters only, so a
            // text full of `&` stays linear.
            guard character == "&", let semicolon = text[index...].prefix(12).firstIndex(of: ";") else {
                result.append(character)
                index = text.index(after: index)
                continue
            }
            let entity = text[text.index(after: index) ..< semicolon]
            var replacement: String?
            switch entity {
            case "amp": replacement = "&"
            case "lt": replacement = "<"
            case "gt": replacement = ">"
            case "quot": replacement = "\""
            case "apos": replacement = "'"
            default:
                if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                    replacement = UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map(String.init)
                } else if entity.hasPrefix("#") {
                    replacement = UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map(String.init)
                }
            }
            if let replacement {
                result += replacement
                index = text.index(after: semicolon)
            } else {
                result.append(character)
                index = text.index(after: index)
            }
        }
        return result
    }

    /// `unescape`, then Office's own escape for characters XML cannot hold:
    /// `_x000D_` is a carriage return, `_x005F_` an underscore.
    static func unescapeOOXML(_ text: Substring) -> String {
        let plain = unescape(text)
        guard plain.contains("_x") else { return plain }
        var result = ""
        var index = plain.startIndex
        while index < plain.endIndex {
            let rest = plain[index...]
            if rest.hasPrefix("_x"), let hexEnd = plain.index(index, offsetBy: 6, limitedBy: plain.endIndex),
                hexEnd < plain.endIndex
            {
                let hexStart = plain.index(index, offsetBy: 2)
                if plain[hexEnd] == "_", let value = UInt32(plain[hexStart ..< hexEnd], radix: 16),
                    let scalar = Unicode.Scalar(value)
                {
                    result.unicodeScalars.append(scalar)
                    index = plain.index(after: hexEnd)
                    continue
                }
            }
            result.append(plain[index])
            index = plain.index(after: index)
        }
        return result
    }
}
