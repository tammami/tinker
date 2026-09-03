import DBCore
import DBSQL
import Foundation

/// The file formats v0.1 exports (SPEC §14).
public enum ExportFormat: String, Sendable, Hashable, CaseIterable, Identifiable {
    case csv
    case json
    case ndjson
    case sqlInsert

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .csv: "CSV"
        case .json: "JSON"
        case .ndjson: "JSON Lines"
        case .sqlInsert: "SQL INSERT"
        }
    }

    public var fileExtension: String {
        switch self {
        case .csv: "csv"
        case .json: "json"
        case .ndjson: "ndjson"
        case .sqlInsert: "sql"
        }
    }
}

/// Everything the export sheet can configure.
public struct ExportOptions: Sendable, Hashable {
    public var format: ExportFormat = .csv
    public var delimiter: Character = ","
    public var quote: Character = "\""
    public var includeHeader = true
    public var nullText = ""
    /// A byte-order mark helps Excel open UTF-8 correctly.
    public var writeByteOrderMark = false
    /// Rows per `INSERT` statement.
    public var batchSize = 100
    public var includeCreateTable = false
    public var dialect: SQLDialect = .postgresql
    public var table: TableRef?

    public init() {}
}

/// Writes rows to a file as they arrive.
///
/// The whole point is that nothing accumulates: rows are formatted and handed to a
/// buffered file handle, so exporting a million rows costs a constant amount of memory
/// (SPEC §14).
public final class RowExporter {
    private let handle: FileHandle
    private let options: ExportOptions
    private var buffer = Data()
    private var wroteHeader = false
    private var rowsWritten: Int64 = 0
    private var batchOpen = false
    private var columns: [ColumnMeta] = []

    /// Flush threshold. Large enough that a write per row never reaches the file system.
    private static let flushThreshold = 256 * 1_024

    public init(url: URL, options: ExportOptions) throws {
        self.options = options
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        if options.writeByteOrderMark, options.format != .sqlInsert {
            buffer.append(contentsOf: [0xEF, 0xBB, 0xBF])
        }
    }

    public var writtenRowCount: Int64 { rowsWritten }

    public func begin(columns: [ColumnMeta]) {
        self.columns = columns
        switch options.format {
        case .csv:
            if options.includeHeader {
                append(
                    columns.map {
                        ClipboardFormatter.csvField($0.name, delimiter: options.delimiter, quote: options.quote)
                    }.joined(separator: String(options.delimiter)) + "\n")
            }
        case .json:
            append("[\n")
        case .ndjson:
            break
        case .sqlInsert:
            if options.includeCreateTable, let table = options.table {
                append(Self.createTableStatement(table: table, columns: columns, dialect: options.dialect))
            }
        }
        wroteHeader = true
    }

    public func write(rows: [[DBValue]]) {
        for row in rows { write(row: row) }
        flushIfNeeded()
    }

    public func write(row: [DBValue]) {
        switch options.format {
        case .csv:
            append(
                row.map { value in
                    ClipboardFormatter.csvField(
                        ClipboardFormatter.cellText(value, nullText: options.nullText),
                        delimiter: options.delimiter, quote: options.quote
                    )
                }.joined(separator: String(options.delimiter)) + "\n")

        case .json:
            let object =
                "{"
                + zip(columns, row).map { column, value in
                    "\(ClipboardFormatter.jsonString(column.name)): \(ClipboardFormatter.jsonValue(value))"
                }.joined(separator: ", ") + "}"
            append(rowsWritten == 0 ? "  \(object)" : ",\n  \(object)")

        case .ndjson:
            let object =
                "{"
                + zip(columns, row).map { column, value in
                    "\(ClipboardFormatter.jsonString(column.name)):\(ClipboardFormatter.jsonValue(value))"
                }.joined(separator: ",") + "}"
            append(object + "\n")

        case .sqlInsert:
            let values = "(" + row.map { $0.sqlLiteral(dialect: options.dialect) }.joined(separator: ", ") + ")"
            if !batchOpen {
                append(insertPrefix())
                append(values)
                batchOpen = true
            } else {
                append(",\n" + values)
            }
            if (rowsWritten + 1) % Int64(max(1, options.batchSize)) == 0 {
                append(";\n")
                batchOpen = false
            }
        }
        rowsWritten += 1
    }

    private func insertPrefix() -> String {
        let name =
            options.table.map { Identifier.qualified($0, dialect: options.dialect) }
            ?? Identifier.quote("exported", dialect: options.dialect)
        let columnList = columns.map { Identifier.quote($0.name, dialect: options.dialect) }
            .joined(separator: ", ")
        return "INSERT INTO \(name) (\(columnList)) VALUES\n"
    }

    static func createTableStatement(
        table: TableRef,
        columns: [ColumnMeta],
        dialect: SQLDialect
    ) -> String {
        let name = Identifier.qualified(table, dialect: dialect)
        let lines = columns.map { column in
            "    \(Identifier.quote(column.name, dialect: dialect)) \(column.nativeTypeName)"
        }
        return "CREATE TABLE \(name) (\n\(lines.joined(separator: ",\n"))\n);\n\n"
    }

    /// Finishes the file and closes it. Safe to call twice.
    public func finish() throws {
        switch options.format {
        case .json:
            append(rowsWritten == 0 ? "]\n" : "\n]\n")
        case .sqlInsert:
            if batchOpen { append(";\n") }
        case .csv, .ndjson:
            break
        }
        try flush()
        try handle.close()
    }

    private func append(_ text: String) {
        buffer.append(contentsOf: text.utf8)
    }

    private func flushIfNeeded() {
        guard buffer.count >= Self.flushThreshold else { return }
        try? flush()
    }

    private func flush() throws {
        guard !buffer.isEmpty else { return }
        try handle.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }
}
