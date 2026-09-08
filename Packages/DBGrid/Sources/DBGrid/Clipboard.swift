import DBCore
import DBSQL
import Foundation

/// How a copied selection is rendered (SPEC §12.4).
public enum ClipboardFormat: String, Sendable, Hashable, CaseIterable {
    case tsv
    case csv
    case json
    case markdown
    case sqlInsert
    case whereIn
    /// Monospaced columns padded to the same width, the way `psql` prints them.
    case text

    public var displayName: String {
        switch self {
        case .text: "Aligned text"
        case .tsv: "Tab-separated"
        case .csv: "CSV"
        case .json: "JSON"
        case .markdown: "Markdown table"
        case .sqlInsert: "INSERT statements"
        case .whereIn: "WHERE-IN list"
        }
    }
}

/// Renders grid selections for the pasteboard.
public enum ClipboardFormatter {
    /// How NULL appears in text formats. The default is an empty field, which is what
    /// spreadsheets expect; the setting can make it the literal word.
    public struct Options: Sendable, Hashable {
        public var nullText: String
        public var includeHeader: Bool
        public var dialect: SQLDialect
        public var table: TableRef?
        /// Prefix a field a spreadsheet would run as a formula with an apostrophe
        /// (DECISIONS.md ADR-0031). On by default; off reproduces the value exactly.
        public var guardFormulas: Bool

        public init(
            nullText: String = "",
            includeHeader: Bool = false,
            dialect: SQLDialect = .postgresql,
            table: TableRef? = nil,
            guardFormulas: Bool = true
        ) {
            self.nullText = nullText
            self.includeHeader = includeHeader
            self.dialect = dialect
            self.table = table
            self.guardFormulas = guardFormulas
        }
    }

    /// A field that Excel, Numbers or Sheets would evaluate rather than show — one that
    /// starts with `=`, `+`, `-`, `@`, a tab or a carriage return — gets a leading
    /// apostrophe, which spreadsheets read as "text follows". Everything else is untouched.
    public static func guardingFormula(_ text: String) -> String {
        guard let first = text.unicodeScalars.first else { return text }
        switch first {
        case "=", "+", "-", "@", "\t", "\r": return "'" + text
        default: return text
        }
    }

    /// Only text can carry a formula; a number, date or boolean is rendered by Tinker and
    /// is never guarded, so `-5` in a numeric column stays `-5`.
    public static func mayCarryFormula(_ value: DBValue) -> Bool {
        switch value {
        case .string, .json, .raw, .array: true
        default: false
        }
    }

    public static func render(
        columns: [ColumnMeta],
        rows: [[DBValue]],
        format: ClipboardFormat,
        options: Options = Options()
    ) -> String {
        switch format {
        case .tsv: tsv(columns: columns, rows: rows, options: options)
        case .csv: csv(columns: columns, rows: rows, options: options)
        case .json: json(columns: columns, rows: rows)
        case .markdown: markdown(columns: columns, rows: rows, options: options)
        case .sqlInsert: sqlInserts(columns: columns, rows: rows, options: options)
        case .whereIn: whereInList(columns: columns, rows: rows, options: options)
        case .text: alignedText(columns: columns, rows: rows, options: options)
        }
    }

    /// Pads every column to its widest value. Two passes over the rows, one string
    /// built with its capacity reserved, and no per-cell allocation beyond the cell text.
    static func alignedText(columns: [ColumnMeta], rows: [[DBValue]], options: Options) -> String {
        guard !columns.isEmpty else { return "" }
        let nullText = options.nullText.isEmpty ? "NULL" : options.nullText
        var widths = columns.map { $0.name.count }
        var cells: [[String]] = []
        cells.reserveCapacity(rows.count)
        for row in rows {
            var line: [String] = []
            line.reserveCapacity(columns.count)
            for (index, value) in row.prefix(columns.count).enumerated() {
                let text = cellText(value, nullText: nullText)
                    .replacingOccurrences(of: "\n", with: "⏎")
                widths[index] = max(widths[index], text.count)
                line.append(text)
            }
            cells.append(line)
        }
        let lineWidth = widths.reduce(0, +) + columns.count * 3
        var output = ""
        output.reserveCapacity(lineWidth * (rows.count + 2))
        func append(_ fields: [String]) {
            for (index, field) in fields.enumerated() {
                if index > 0 { output += " | " }
                let numeric = index < columns.count && columns[index].kind.isNumeric
                let padding = String(repeating: " ", count: max(0, widths[index] - field.count))
                output += numeric ? padding + field : field + padding
            }
            output += "\n"
        }
        if options.includeHeader {
            append(columns.map(\.name))
            output += widths.map { String(repeating: "-", count: $0) }.joined(separator: "-+-") + "\n"
        }
        for line in cells { append(line) }
        return output
    }

    /// The plain text of one cell, for copying a single value.
    public static func cellText(_ value: DBValue, nullText: String = "") -> String {
        switch value {
        case .null: nullText
        case let .bytes(data): "\\x" + data.map { String(format: "%02x", $0) }.joined()
        case let .array(items): "{" + items.map { $0.text ?? "NULL" }.joined(separator: ",") + "}"
        default: value.text ?? nullText
        }
    }

    static func tsv(columns: [ColumnMeta], rows: [[DBValue]], options: Options) -> String {
        var lines: [String] = []
        if options.includeHeader { lines.append(columns.map(\.name).joined(separator: "\t")) }
        for row in rows {
            lines.append(
                row.map { field in
                    // Tabs and newlines would break the row structure a spreadsheet expects.
                    let text =
                        cellText(field, nullText: options.nullText)
                        .replacingOccurrences(of: "\t", with: " ")
                        .replacingOccurrences(of: "\n", with: " ")
                        .replacingOccurrences(of: "\r", with: " ")
                    return options.guardFormulas && mayCarryFormula(field) ? guardingFormula(text) : text
                }.joined(separator: "\t"))
        }
        return lines.joined(separator: "\n")
    }

    static func csv(columns: [ColumnMeta], rows: [[DBValue]], options: Options) -> String {
        var lines: [String] = []
        if options.includeHeader { lines.append(columns.map { csvField($0.name) }.joined(separator: ",")) }
        for row in rows {
            lines.append(
                row.map { value in
                    let text = cellText(value, nullText: options.nullText)
                    return csvField(options.guardFormulas && mayCarryFormula(value) ? guardingFormula(text) : text)
                }.joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    /// Quotes a CSV field when it holds a delimiter, a quote or a line break.
    public static func csvField(_ text: String, delimiter: Character = ",", quote: Character = "\"") -> String {
        let needsQuoting =
            text.contains(delimiter) || text.contains(quote)
            || text.contains("\n") || text.contains("\r")
        guard needsQuoting else { return text }
        let escaped = text.replacingOccurrences(of: String(quote), with: String(repeating: String(quote), count: 2))
        return "\(quote)\(escaped)\(quote)"
    }

    static func json(columns: [ColumnMeta], rows: [[DBValue]]) -> String {
        let objects = rows.map { row in
            "{"
                + zip(columns, row).map { column, value in
                    "\(jsonString(column.name)): \(jsonValue(value))"
                }.joined(separator: ", ") + "}"
        }
        return "[\n  " + objects.joined(separator: ",\n  ") + "\n]"
    }

    /// One JSON object per line, the shape most tools stream.
    public static func ndjson(columns: [ColumnMeta], rows: [[DBValue]]) -> String {
        rows.map { row in
            "{"
                + zip(columns, row).map { column, value in
                    "\(jsonString(column.name)):\(jsonValue(value))"
                }.joined(separator: ",") + "}"
        }.joined(separator: "\n")
    }

    /// A JSON value that keeps numeric precision: exact decimals stay unquoted only when
    /// JSON can represent them, and JSON columns are inlined rather than double-encoded.
    public static func jsonValue(_ value: DBValue) -> String {
        switch value {
        case .null: "null"
        case let .bool(flag): flag ? "true" : "false"
        case let .int(number): String(number)
        case let .uint(number): String(number)
        case let .double(number):
            // JSON has no NaN or infinity; null is the only honest spelling.
            number.isFinite ? String(number) : "null"
        case let .decimal(text):
            // A decimal wider than a double must not silently lose digits, so it is
            // written as a string rather than a JSON number.
            text.count <= 15 && Double(text) != nil ? text : jsonString(text)
        case let .json(text): text
        case let .array(items): "[" + items.map(jsonValue).joined(separator: ",") + "]"
        default: jsonString(cellText(value, nullText: ""))
        }
    }

    public static func jsonString(_ text: String) -> String {
        var output = "\""
        for character in text.unicodeScalars {
            switch character {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            default:
                if character.value < 0x20 {
                    output += String(format: "\\u%04x", character.value)
                } else {
                    output.unicodeScalars.append(character)
                }
            }
        }
        return output + "\""
    }

    static func markdown(columns: [ColumnMeta], rows: [[DBValue]], options: Options) -> String {
        guard !columns.isEmpty else { return "" }
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "|", with: "\\|")
                .replacingOccurrences(of: "\n", with: " ")
        }
        var lines = ["| " + columns.map { escape($0.name) }.joined(separator: " | ") + " |"]
        lines.append("| " + columns.map { _ in "---" }.joined(separator: " | ") + " |")
        for row in rows {
            lines.append(
                "| "
                    + row.map { escape(cellText($0, nullText: options.nullText)) }
                    .joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }

    static func sqlInserts(columns: [ColumnMeta], rows: [[DBValue]], options: Options) -> String {
        let dialect = options.dialect
        let name =
            options.table.map { Identifier.qualified($0, dialect: dialect) }
            ?? Identifier.quote("table", dialect: dialect)
        let columnList = columns.map { Identifier.quote($0.name, dialect: dialect) }.joined(separator: ", ")
        return rows.map { row in
            let values = row.map { $0.sqlLiteral(dialect: dialect) }.joined(separator: ", ")
            return "INSERT INTO \(name) (\(columnList)) VALUES (\(values));"
        }.joined(separator: "\n")
    }

    /// `"id" IN (1, 2, 3)` for the first selected column, which is how a user carries a
    /// selection into another query.
    static func whereInList(columns: [ColumnMeta], rows: [[DBValue]], options: Options) -> String {
        guard let column = columns.first else { return "" }
        let values = rows.compactMap(\.first).map { $0.sqlLiteral(dialect: options.dialect) }
        let name = Identifier.quote(column.name, dialect: options.dialect)
        return "\(name) IN (\(values.joined(separator: ", ")))"
    }

    // MARK: - Paste

    /// Splits pasted TSV into a rectangle of text cells, respecting quoted fields.
    public static func parseTSV(_ text: String) -> [[String]] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                line.hasSuffix("\r") ? String(line.dropLast()) : String(line)
            }
            .filter { !$0.isEmpty }
            .map { $0.components(separatedBy: "\t") }
    }
}
