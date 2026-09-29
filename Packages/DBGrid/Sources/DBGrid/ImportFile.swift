import Foundation

/// Why a file cannot be imported as it is.
public struct ImportFileError: Error, Hashable, CustomStringConvertible, Sendable {
    public let description: String

    init(_ description: String) { self.description = description }

    static let legacyExcel = ImportFileError(
        "This is an Excel 97–2003 workbook (.xls), which Tinker cannot read. "
            + "Open it in Excel or Numbers and save it as an Excel Workbook (.xlsx), then import that file.")
    static let binary = ImportFileError(
        "This file is not text and not an Excel workbook (.xlsx), so it has no columns to read. "
            + "Import a CSV, TSV, .xlsx, JSON or JSON Lines file.")
}

/// The encodings a delimited text file is read in.
///
/// The readers walk UTF-8. A file in another encoding is turned into UTF-8 once, before
/// it is read, rather than decoded as UTF-8 and shown as `�` and stray accents.
public enum ImportTextEncoding: String, Sendable, Hashable, CaseIterable, Identifiable {
    case utf8
    case utf16LittleEndian
    case utf16BigEndian
    case windows1252
    case isoLatin1

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .utf8: "UTF-8"
        case .utf16LittleEndian: "UTF-16 LE"
        case .utf16BigEndian: "UTF-16 BE"
        case .windows1252: "Windows-1252"
        case .isoLatin1: "ISO-8859-1"
        }
    }
}

/// Looks at a file's bytes before anything is read from it: what it is, how its text is
/// encoded, and what separates its fields.
public enum ImportFileProbe {
    /// How much of a file is looked at to decide its encoding and delimiter.
    static let sampleSize = 1_024 * 1_024
    /// Files up to this size are transcoded in memory; larger ones go through a file.
    static let inMemoryLimit = 16 * 1_024 * 1_024

    private static let zipSignature: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
    private static let oleSignature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]

    /// The file's format, from its bytes first and its name second.
    ///
    /// Throws for what no reader here can make rows of — an old binary `.xls`, or any
    /// other binary file. Read as CSV, those fill the column mapping with noise.
    public static func format(url: URL, data: Data) throws -> TabularFormat {
        if starts(data, with: zipSignature) { return .xlsx }
        if starts(data, with: oleSignature) { throw ImportFileError.legacyExcel }
        let named = TabularFormat.detect(url: url)
        // A workbook by name that is not a zip is left to the workbook reader to refuse.
        if named == .xlsx { return .xlsx }
        if url.pathExtension.lowercased() == "xls" {
            // Excel also saves HTML and tab-separated text under `.xls`; only text passes.
            guard isText(data) else { throw ImportFileError.legacyExcel }
            return named
        }
        guard isText(data) else { throw ImportFileError.binary }
        return named
    }

    private static func starts(_ data: Data, with signature: [UInt8]) -> Bool {
        data.count >= signature.count && Array(data.prefix(signature.count)) == signature
    }

    /// True when the file's first bytes are text in one of the encodings read here.
    static func isText(_ data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        if utf16ByteOrder(data) != nil { return true }
        let sample = data.prefix(64 * 1_024)
        var controls = 0
        for byte in sample {
            // NUL never appears in 8-bit text; UTF-16 was recognised above.
            if byte == 0 { return false }
            if byte < 0x20, byte != 9, byte != 10, byte != 13, byte != 12, byte != 27 { controls += 1 }
        }
        return controls * 20 <= sample.count
    }

    // MARK: - Encoding

    /// The encoding a text file is most likely in.
    ///
    /// A byte-order mark decides; without one, zero bytes in every other position are
    /// UTF-16, bytes that are valid UTF-8 are UTF-8, and anything else is Windows-1252 —
    /// what Excel on Windows writes for "CSV", and a superset of ISO-8859-1's text.
    public static func detectEncoding(_ data: Data) -> ImportTextEncoding {
        if let order = utf16ByteOrder(data) { return order }
        if starts(data, with: [0xEF, 0xBB, 0xBF]) { return .utf8 }
        return isValidUTF8(data.prefix(sampleSize)) ? .utf8 : .windows1252
    }

    /// UTF-16 by its byte-order mark, or by the zero bytes ASCII leaves in every other
    /// position when there is no mark.
    static func utf16ByteOrder(_ data: Data) -> ImportTextEncoding? {
        if starts(data, with: [0xFF, 0xFE]) { return .utf16LittleEndian }
        if starts(data, with: [0xFE, 0xFF]) { return .utf16BigEndian }
        let sample = data.prefix(4_096)
        guard sample.count >= 4 else { return nil }
        var evenZeros = 0
        var oddZeros = 0
        for (offset, byte) in sample.enumerated() where byte == 0 {
            if offset.isMultiple(of: 2) { evenZeros += 1 } else { oddZeros += 1 }
        }
        let half = sample.count / 2
        // Mostly-ASCII text leaves nearly every high byte zero and no low byte zero.
        if oddZeros * 10 >= half * 4, evenZeros * 10 <= half { return .utf16LittleEndian }
        if evenZeros * 10 >= half * 4, oddZeros * 10 <= half { return .utf16BigEndian }
        return nil
    }

    /// True when the bytes are well-formed UTF-8. A sequence cut short by the end of
    /// the sample is not held against it.
    static func isValidUTF8(_ bytes: Data) -> Bool {
        var remaining = 0
        var lower: UInt8 = 0x80
        var upper: UInt8 = 0xBF
        for byte in bytes {
            if remaining > 0 {
                guard byte >= lower, byte <= upper else { return false }
                lower = 0x80
                upper = 0xBF
                remaining -= 1
                continue
            }
            switch byte {
            case 0x00 ... 0x7F:
                continue
            case 0xC2 ... 0xDF:
                remaining = 1
            case 0xE0:
                remaining = 2
                lower = 0xA0
            case 0xED:
                remaining = 2
                upper = 0x9F
            case 0xE1 ... 0xEC, 0xEE, 0xEF:
                remaining = 2
            case 0xF0:
                remaining = 3
                lower = 0x90
            case 0xF4:
                remaining = 3
                upper = 0x8F
            case 0xF1 ... 0xF3:
                remaining = 3
            default:
                return false
            }
        }
        return true
    }

    /// The file's text as UTF-8, which is what the readers walk.
    ///
    /// UTF-8 is handed back as it came — the same mapped bytes, nothing copied. Any
    /// other encoding is transcoded once, a piece at a time: in memory for a small file,
    /// and through a temporary file that is mapped and unlinked for a large one, so
    /// memory holds one piece however large the file.
    public static func utf8Data(from data: Data, encoding: ImportTextEncoding) throws -> Data {
        if encoding == .utf8 { return data }
        if data.count <= inMemoryLimit {
            var result = Data(capacity: data.count + data.count / 8)
            try transcode(data, encoding: encoding) { result.append($0) }
            return result
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tinker-import-\(UUID().uuidString).txt")
        try FileManager.default.createPrivateFile(at: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        do {
            try transcode(data, encoding: encoding) { try handle.write(contentsOf: $0) }
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        // Mapped before the name is removed; the pages stay reachable through the mapping.
        return try Data(contentsOf: url, options: .alwaysMapped)
    }

    /// Windows-1252's 0x80…0x9F, where it differs from ISO-8859-1. The five bytes it
    /// leaves undefined read as the control characters ISO-8859-1 has there.
    private static let windows1252High: [UInt32] = [
        0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152,
        0x008D, 0x017D, 0x008F, 0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122,
        0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
    ]

    private static func transcode(
        _ data: Data, encoding: ImportTextEncoding, _ body: (Data) throws -> Void
    ) throws {
        let piece = 1_024 * 1_024
        var output = [UInt8]()
        output.reserveCapacity(piece + piece / 2)
        func emit() throws {
            guard !output.isEmpty else { return }
            try body(Data(output))
            output.removeAll(keepingCapacity: true)
        }

        switch encoding {
        case .utf8:
            try body(data)

        case .windows1252, .isoLatin1:
            for byte in data {
                let value: UInt32
                if encoding == .windows1252, byte >= 0x80, byte <= 0x9F {
                    value = windows1252High[Int(byte - 0x80)]
                } else {
                    value = UInt32(byte)
                }
                appendUTF8(value, to: &output)
                if output.count >= piece { try emit() }
            }
            try emit()

        case .utf16LittleEndian, .utf16BigEndian:
            let isLittle = encoding == .utf16LittleEndian
            var index = data.startIndex
            let end = data.endIndex
            var pendingHigh: UInt32?
            var isFirst = true
            while index + 1 < end {
                let first = UInt32(data[index])
                let second = UInt32(data[index + 1])
                index += 2
                let unit = isLittle ? first | second << 8 : first << 8 | second
                if isFirst {
                    isFirst = false
                    // The byte-order mark is not part of the first field.
                    if unit == 0xFEFF { continue }
                }
                if let high = pendingHigh {
                    pendingHigh = nil
                    if (0xDC00 ... 0xDFFF).contains(unit) {
                        appendUTF8(0x10000 + ((high - 0xD800) << 10) + (unit - 0xDC00), to: &output)
                        continue
                    }
                    appendUTF8(0xFFFD, to: &output)
                }
                if (0xD800 ... 0xDBFF).contains(unit) {
                    pendingHigh = unit
                } else if (0xDC00 ... 0xDFFF).contains(unit) {
                    appendUTF8(0xFFFD, to: &output)
                } else {
                    appendUTF8(unit, to: &output)
                }
                if output.count >= piece { try emit() }
            }
            if pendingHigh != nil { appendUTF8(0xFFFD, to: &output) }
            try emit()
        }
    }

    private static func appendUTF8(_ value: UInt32, to output: inout [UInt8]) {
        switch value {
        case 0 ..< 0x80:
            output.append(UInt8(value))
        case 0x80 ..< 0x800:
            output.append(UInt8(0xC0 | value >> 6))
            output.append(UInt8(0x80 | value & 0x3F))
        case 0x800 ..< 0x10000:
            output.append(UInt8(0xE0 | value >> 12))
            output.append(UInt8(0x80 | value >> 6 & 0x3F))
            output.append(UInt8(0x80 | value & 0x3F))
        default:
            output.append(UInt8(0xF0 | value >> 18))
            output.append(UInt8(0x80 | value >> 12 & 0x3F))
            output.append(UInt8(0x80 | value >> 6 & 0x3F))
            output.append(UInt8(0x80 | value & 0x3F))
        }
    }

    // MARK: - Delimiter

    /// The character that separates the fields of UTF-8 text, from its first lines.
    ///
    /// Excel writes commas, semicolons where the comma is the decimal mark (Indonesia,
    /// most of Europe), and tabs for "Unicode Text"; a `sep=` line says so outright.
    /// The candidate that splits every sampled line into the same number of fields —
    /// more than one — wins; with nothing to go on, `fallback` is returned.
    public static func detectDelimiter(_ data: Data, fallback: Character = ",") -> Character {
        if let declared = CSVReader.declaredSeparator(in: data) { return Character(UnicodeScalar(declared)) }
        let candidates: [UInt8] = [UInt8(ascii: ","), UInt8(ascii: ";"), 9, UInt8(ascii: "|")]
        var start = data.startIndex
        if starts(data, with: [0xEF, 0xBB, 0xBF]) { start += 3 }
        let sample = data[start ..< min(data.endIndex, start + 64 * 1_024)]
        let quote = UInt8(ascii: "\"")

        // Per line, how many of each candidate sit outside quotes.
        var lines: [[Int]] = []
        var counts = [Int](repeating: 0, count: candidates.count)
        var inQuotes = false
        var lineHasBytes = false
        var reachedEnd = true
        for byte in sample {
            if byte == quote {
                inQuotes.toggle()
                lineHasBytes = true
                continue
            }
            if inQuotes { continue }
            if byte == 10 || byte == 13 {
                if lineHasBytes { lines.append(counts) }
                counts = [Int](repeating: 0, count: candidates.count)
                lineHasBytes = false
                if lines.count >= 8 {
                    reachedEnd = false
                    break
                }
                continue
            }
            lineHasBytes = true
            if let index = candidates.firstIndex(of: byte) { counts[index] += 1 }
        }
        // The last line counts only when it is whole: the sample may have cut it short.
        if reachedEnd, lineHasBytes, sample.endIndex == data.endIndex { lines.append(counts) }
        guard let first = lines.first else { return fallback }

        var best: (index: Int, score: Int)?
        for index in candidates.indices where first[index] > 0 {
            let isConsistent = lines.allSatisfy { $0[index] == first[index] }
            // Consistency outweighs count: a comma inside every address does not beat
            // the semicolon that splits each line the same way.
            let score = (isConsistent ? 1_000_000 : 0) + first[index]
            if score > (best?.score ?? 0) { best = (index, score) }
        }
        guard let best else { return fallback }
        return Character(UnicodeScalar(candidates[best.index]))
    }
}
