import Foundation

/// Anything that yields records of text fields one at a time: a CSV, a TSV, a JSON file.
public protocol RecordSource {
    /// Records read so far, one-based after the first `next()`.
    var recordNumber: Int { get }
    mutating func next() -> [String]?
}

extension CSVReader: RecordSource {}

/// The shape of a data file, from its name.
public enum TabularFormat: Sendable, Hashable {
    case delimited(Character)
    case json

    public static func detect(url: URL) -> TabularFormat {
        switch url.pathExtension.lowercased() {
        case "json", "ndjson", "jsonl": .json
        case "tsv", "tab": .delimited("\t")
        default: .delimited(",")
        }
    }
}

/// Reads a JSON file of flat objects — an array of them, or one per line — a record at
/// a time, without ever parsing the whole document.
///
/// Numbers keep their text so `12.50` stays `12.50`; `null` becomes an empty field (NULL
/// on import); a nested object or array is passed through as its JSON text. The header
/// is the union of keys of the first objects, in order of first appearance, so every
/// record lines up with it whatever keys it leaves out.
public struct JSONRecordReader: RecordSource {
    public let header: [String]
    public private(set) var recordNumber = 0
    private let bytes: Data
    private var position: Data.Index
    private var isFinished = false

    private static let headerSample = 64

    public init(data: Data) {
        bytes = data
        position = data.startIndex
        var keys: [String] = []
        var seen: Set<String> = []
        var probe = JSONRecordReader(bytes: data)
        for _ in 0 ..< Self.headerSample {
            guard let object = probe.nextObject() else { break }
            for (key, _) in object where seen.insert(key).inserted { keys.append(key) }
        }
        header = keys
    }

    private init(bytes: Data) {
        self.bytes = bytes
        position = bytes.startIndex
        header = []
    }

    public var isAtEnd: Bool { isFinished || position >= bytes.endIndex }

    /// The next object's values in header order; a missing key is an empty field.
    public mutating func next() -> [String]? {
        guard let object = nextObject() else { return nil }
        recordNumber += 1
        let lookup = Dictionary(object, uniquingKeysWith: { first, _ in first })
        return header.map { lookup[$0] ?? "" }
    }

    // MARK: - Scanning

    /// The next `{…}` at the top level, as key–text pairs, skipping the array
    /// brackets, commas and line breaks between objects.
    private mutating func nextObject() -> [(String, String)]? {
        while position < bytes.endIndex {
            let byte = bytes[position]
            if byte == UInt8(ascii: "{") { return parseObject() }
            if byte == UInt8(ascii: "]") {
                isFinished = true
                return nil
            }
            // Whitespace, `[`, `,` and a stray byte-order mark are all between objects.
            position += 1
        }
        return nil
    }

    private mutating func parseObject() -> [(String, String)]? {
        position += 1  // `{`
        var pairs: [(String, String)] = []
        while true {
            skipWhitespace()
            guard position < bytes.endIndex else { return nil }
            if bytes[position] == UInt8(ascii: "}") {
                position += 1
                return pairs
            }
            if bytes[position] == UInt8(ascii: ",") {
                position += 1
                continue
            }
            guard bytes[position] == UInt8(ascii: "\""), let key = parseString() else { return nil }
            skipWhitespace()
            guard position < bytes.endIndex, bytes[position] == UInt8(ascii: ":") else { return nil }
            position += 1
            skipWhitespace()
            guard let value = parseValueText() else { return nil }
            pairs.append((key, value))
        }
    }

    private mutating func skipWhitespace() {
        while position < bytes.endIndex {
            let byte = bytes[position]
            guard
                byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r")
                    || byte == UInt8(ascii: "\t")
            else { return }
            position += 1
        }
    }

    /// A JSON string starting at the opening quote, decoded.
    private mutating func parseString() -> String? {
        let start = position
        position += 1
        var escaped = false
        var needsDecoding = false
        while position < bytes.endIndex {
            let byte = bytes[position]
            if escaped {
                escaped = false
                needsDecoding = true
            } else if byte == UInt8(ascii: "\\") {
                escaped = true
            } else if byte == UInt8(ascii: "\"") {
                position += 1
                let raw = bytes[(start + 1) ..< (position - 1)]
                if !needsDecoding { return String(decoding: raw, as: UTF8.self) }
                // Escapes are rare enough that the system parser can take those strings.
                let quoted = bytes[start ..< position]
                return (try? JSONSerialization.jsonObject(with: quoted, options: [.fragmentsAllowed])) as? String
            }
            position += 1
        }
        return nil
    }

    /// The text of a value: a decoded string, the literal text of a number or
    /// `true`/`false`, an empty field for `null`, the JSON text of anything nested.
    private mutating func parseValueText() -> String? {
        guard position < bytes.endIndex else { return nil }
        let byte = bytes[position]
        if byte == UInt8(ascii: "\"") { return parseString() }
        if byte == UInt8(ascii: "{") || byte == UInt8(ascii: "[") {
            let start = position
            var depth = 0
            var inString = false
            var escaped = false
            while position < bytes.endIndex {
                let current = bytes[position]
                if inString {
                    if escaped {
                        escaped = false
                    } else if current == UInt8(ascii: "\\") {
                        escaped = true
                    } else if current == UInt8(ascii: "\"") {
                        inString = false
                    }
                } else if current == UInt8(ascii: "\"") {
                    inString = true
                } else if current == UInt8(ascii: "{") || current == UInt8(ascii: "[") {
                    depth += 1
                } else if current == UInt8(ascii: "}") || current == UInt8(ascii: "]") {
                    depth -= 1
                    if depth == 0 {
                        position += 1
                        return String(decoding: bytes[start ..< position], as: UTF8.self)
                    }
                }
                position += 1
            }
            return nil
        }
        // A number, true, false or null: everything up to the next separator.
        let start = position
        while position < bytes.endIndex {
            let current = bytes[position]
            if current == UInt8(ascii: ",") || current == UInt8(ascii: "}") || current == UInt8(ascii: "]")
                || current == UInt8(ascii: " ") || current == UInt8(ascii: "\n") || current == UInt8(ascii: "\r")
                || current == UInt8(ascii: "\t")
            {
                break
            }
            position += 1
        }
        let literal = String(decoding: bytes[start ..< position], as: UTF8.self)
        return literal == "null" ? "" : literal
    }
}
