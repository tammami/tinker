import DBCore
import DBSQL
import Foundation

/// Turns typed text into a value of a column's kind, or nil when it does not fit.
///
/// An empty string is NULL; everything the server parses itself — dates, JSON, arrays —
/// passes through as text so the server does the coercion and reports its own error.
public enum ValueCoercion {
    public static func coerce(_ text: String, to kind: DBValueKind) -> DBValue? {
        if text.isEmpty { return .null }
        switch kind {
        case .bool:
            switch text.lowercased() {
            case "t", "true", "1", "yes", "y": return .bool(true)
            case "f", "false", "0", "no", "n": return .bool(false)
            default: return nil
            }
        case .int:
            return Int64(text).map { .int($0) }
        case .uint:
            return UInt64(text).map { .uint($0) }
        case .double:
            return Double(text).map { .double($0) }
        case .decimal:
            // Validated but never parsed, so every digit survives.
            let allowed = text.allSatisfy {
                $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" || $0 == "e" || $0 == "E"
            }
            return allowed ? .decimal(text) : nil
        case .uuid:
            return UUID(uuidString: text).map { .uuid($0) }
        case .bytes:
            let hex = text.hasPrefix("\\x") ? String(text.dropFirst(2)) : text
            guard hex.count % 2 == 0, hex.allSatisfy(\.isHexDigit) else { return nil }
            var data = Data(capacity: hex.count / 2)
            var index = hex.startIndex
            while index < hex.endIndex {
                let next = hex.index(index, offsetBy: 2)
                guard let byte = UInt8(hex[index ..< next], radix: 16) else { return nil }
                data.append(byte)
                index = next
            }
            return .bytes(data)
        case .json:
            return .json(text)
        case .string:
            return .string(text)
        case .null:
            return .null
        case .date, .time, .timestamp, .array, .raw:
            return .raw(typeName: kind.rawValue, text: text, bytes: nil)
        }
    }
}

/// Reads CSV one record at a time from bytes, so a file is never held twice.
///
/// RFC 4180: fields are separated by the delimiter, quoted fields may hold delimiters,
/// line breaks and doubled quotes, and either `\n` or `\r\n` ends a record. A byte-order
/// mark at the start is skipped. The input is UTF-8; the parser walks bytes and decodes
/// each field once, which is the cheapest way to stay within a bounded memory footprint
/// on a file of any size when it is memory-mapped by the caller.
public struct CSVReader {
    public let delimiter: UInt8
    public let quote: UInt8
    private let bytes: Data
    private var position: Data.Index
    /// Records read so far, one-based after the first `next()`.
    public private(set) var recordNumber = 0

    public init(data: Data, delimiter: Character = ",", quote: Character = "\"") {
        self.delimiter = delimiter.asciiValue ?? UInt8(ascii: ",")
        self.quote = quote.asciiValue ?? UInt8(ascii: "\"")
        bytes = data
        position = data.startIndex
        // A UTF-8 byte-order mark is not part of the first field.
        if bytes.count >= 3, bytes[bytes.startIndex] == 0xEF,
           bytes[bytes.startIndex + 1] == 0xBB, bytes[bytes.startIndex + 2] == 0xBF {
            position = bytes.startIndex + 3
        }
    }

    public var isAtEnd: Bool { position >= bytes.endIndex }

    /// The next record, or nil at the end. A blank line is skipped rather than returned
    /// as a one-field record.
    public mutating func next() -> [String]? {
        while position < bytes.endIndex {
            let record = readRecord()
            if record.count == 1, record[0].isEmpty { continue }
            recordNumber += 1
            return record
        }
        return nil
    }

    private mutating func readRecord() -> [String] {
        var fields: [String] = []
        var field = [UInt8]()
        field.reserveCapacity(32)
        var inQuotes = false
        let newline = UInt8(ascii: "\n")
        let carriage = UInt8(ascii: "\r")

        while position < bytes.endIndex {
            let byte = bytes[position]
            position += 1
            if inQuotes {
                if byte == quote {
                    if position < bytes.endIndex, bytes[position] == quote {
                        field.append(quote)
                        position += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(byte)
                }
                continue
            }
            switch byte {
            case quote where field.isEmpty:
                inQuotes = true
            case delimiter:
                fields.append(String(decoding: field, as: UTF8.self))
                field.removeAll(keepingCapacity: true)
            case newline:
                fields.append(String(decoding: field, as: UTF8.self))
                return fields
            case carriage:
                if position < bytes.endIndex, bytes[position] == newline { position += 1 }
                fields.append(String(decoding: field, as: UTF8.self))
                return fields
            default:
                field.append(byte)
            }
        }
        fields.append(String(decoding: field, as: UTF8.self))
        return fields
    }

    /// Parses a whole string, for small inputs and tests.
    public static func parse(_ text: String, delimiter: Character = ",") -> [[String]] {
        var reader = CSVReader(data: Data(text.utf8), delimiter: delimiter)
        var rows: [[String]] = []
        while let row = reader.next() { rows.append(row) }
        return rows
    }
}

/// How the CSV's columns map onto the table's.
public struct CSVImportPlan: Sendable, Hashable {
    public let table: TableRef
    /// For each CSV column, the table column it fills, or nil to skip it.
    public var mapping: [String?]
    public var hasHeader: Bool
    /// A field equal to this is inserted as NULL. Empty fields are always NULL.
    public var nullText: String
    /// Rows per `INSERT`. Bounded so a statement never grows past what a server accepts.
    public var batchSize: Int

    public init(table: TableRef, mapping: [String?], hasHeader: Bool = true, nullText: String = "", batchSize: Int = 200) {
        self.table = table
        self.mapping = mapping
        self.hasHeader = hasHeader
        self.nullText = nullText
        self.batchSize = min(max(1, batchSize), 1_000)
    }

    /// Matches CSV header names to table columns by name, case-insensitively.
    public static func matched(header: [String], to columns: [ColumnInfo], table: TableRef) -> CSVImportPlan {
        let byName = Dictionary(columns.map { ($0.name.lowercased(), $0.name) }, uniquingKeysWith: { first, _ in first })
        let mapping = header.map { byName[$0.trimmingCharacters(in: .whitespaces).lowercased()] }
        return CSVImportPlan(table: table, mapping: mapping)
    }
}

/// What went wrong with one CSV field.
public struct CSVImportError: Error, Hashable, CustomStringConvertible, Sendable {
    public let record: Int
    public let column: String
    public let text: String
    public let expected: String

    public var description: String {
        "Record \(record): “\(text)” is not a valid \(expected) for column \(column)"
    }
}

/// Builds the batched `INSERT` statements for an import and runs them in one transaction.
///
/// Values travel as bound parameters, never as literals, and every row is coerced against
/// the column's kind before anything is sent: a bad field stops the import with the record
/// number, and the transaction rolls back so the table is exactly as it was.
public struct CSVImporter: Sendable {
    public let plan: CSVImportPlan
    public let columns: [ColumnInfo]
    public let dialect: SQLDialect

    public init(plan: CSVImportPlan, columns: [ColumnInfo], dialect: SQLDialect) {
        self.plan = plan
        self.columns = columns
        self.dialect = dialect
    }

    /// The table columns the plan fills, in CSV order.
    public var targetColumns: [ColumnInfo] {
        plan.mapping.compactMap { name in name.flatMap { n in columns.first { $0.name == n } } }
    }

    /// Coerces one CSV record into the values of the target columns.
    public func values(for record: [String], number: Int) throws -> [DBValue] {
        var result: [DBValue] = []
        result.reserveCapacity(targetColumns.count)
        for (index, target) in plan.mapping.enumerated() {
            guard let target, let column = columns.first(where: { $0.name == target }) else { continue }
            let text = index < record.count ? record[index] : ""
            if text == plan.nullText {
                result.append(.null)
                continue
            }
            guard let value = ValueCoercion.coerce(text, to: column.kind) else {
                throw CSVImportError(record: number, column: column.name, text: text, expected: column.nativeType)
            }
            result.append(value)
        }
        return result
    }

    /// One multi-row `INSERT` for a batch of coerced rows.
    public func insertStatement(rows: [[DBValue]]) -> GeneratedStatement {
        let targets = targetColumns
        let table = Identifier.qualified(plan.table, dialect: dialect)
        let names = targets.map { Identifier.quote($0.name, dialect: dialect) }.joined(separator: ", ")
        var parameters: [DBValue] = []
        parameters.reserveCapacity(rows.count * targets.count)
        var tuples: [String] = []
        tuples.reserveCapacity(rows.count)
        var index = 1
        for row in rows {
            var placeholders: [String] = []
            placeholders.reserveCapacity(targets.count)
            for value in row {
                placeholders.append(SQLLiteral.placeholder(index, dialect: dialect))
                parameters.append(value)
                index += 1
            }
            tuples.append("(" + placeholders.joined(separator: ", ") + ")")
        }
        return GeneratedStatement(
            kind: .insert,
            sql: "INSERT INTO \(table) (\(names)) VALUES \(tuples.joined(separator: ", "))",
            parameters: parameters,
            table: plan.table,
            expectsSingleRow: false
        )
    }

    /// Runs the import. Returns the number of rows inserted.
    ///
    /// The whole import is one transaction: either every record is in, or none is. The
    /// reader is consumed a batch at a time, so memory stays at one batch.
    public func run(
        reader: inout CSVReader,
        on connection: any SQLConnection,
        progress: (@Sendable (Int64) -> Void)? = nil
    ) async throws -> Int64 {
        if plan.hasHeader { _ = reader.next() }
        var inserted: Int64 = 0
        try await connection.withTransaction {
            var batch: [[DBValue]] = []
            batch.reserveCapacity(plan.batchSize)
            func flush() async throws {
                guard !batch.isEmpty else { return }
                let statement = insertStatement(rows: batch)
                let result = try await connection.executeCollecting(statement.sql, parameters: statement.parameters)
                inserted += result.completion.affectedRows ?? Int64(batch.count)
                progress?(inserted)
                batch.removeAll(keepingCapacity: true)
            }
            while let record = reader.next() {
                batch.append(try values(for: record, number: reader.recordNumber))
                if batch.count >= plan.batchSize { try await flush() }
            }
            try await flush()
        }
        return inserted
    }
}
