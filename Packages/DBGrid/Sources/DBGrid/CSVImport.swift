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
            default:
                // MySQL's boolean is a tinyint(1) that takes any small integer; typing 2
                // into such a column stores 2.
                return Int64(text).map { .int($0) }
            }
        case .int:
            return (Int64(text) ?? booleanNumber(text)).map { .int($0) }
        case .uint:
            return (UInt64(text) ?? booleanNumber(text).map(UInt64.init)).map { .uint($0) }
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

    /// A workbook's boolean cell reads as `true`/`false`; a column that keeps its flags
    /// as integers — SQLite's, or a MySQL `tinyint` wider than one digit — takes 1 and 0.
    private static func booleanNumber(_ text: String) -> Int64? {
        switch text {
        case "true", "TRUE", "True": 1
        case "false", "FALSE", "False": 0
        default: nil
        }
    }

    /// Takes off the apostrophe Tinker's CSV export puts before text a spreadsheet would
    /// run as a formula (`'=SUM(A1)`), so a file exported and imported again holds what
    /// the table held. Only that exact shape is touched: an apostrophe followed by `=`,
    /// `+`, `-`, `@`, a tab or a carriage return.
    public static func removingFormulaGuard(_ text: String) -> String {
        var scalars = text.unicodeScalars.makeIterator()
        guard scalars.next() == "'", let second = scalars.next() else { return text }
        switch second {
        case "=", "+", "-", "@", "\t", "\r": return String(text.unicodeScalars.dropFirst())
        default: return text
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
            bytes[bytes.startIndex + 1] == 0xBB, bytes[bytes.startIndex + 2] == 0xBF
        {
            position = bytes.startIndex + 3
        }
        // Excel's `sep=;` first line names the delimiter; it is not a record.
        if Self.declaredSeparator(in: data) != nil {
            while position < bytes.endIndex, bytes[position] != 10, bytes[position] != 13 { position += 1 }
            if position < bytes.endIndex, bytes[position] == 13 { position += 1 }
            if position < bytes.endIndex, bytes[position] == 10 { position += 1 }
        }
    }

    /// The delimiter a leading `sep=` line declares, the way Excel reads and writes it.
    static func declaredSeparator(in data: Data) -> UInt8? {
        var start = data.startIndex
        if data.count >= 3, data[start] == 0xEF, data[start + 1] == 0xBB, data[start + 2] == 0xBF { start += 3 }
        let prefix = Array("sep=".utf8)
        guard data.endIndex - start > prefix.count else { return nil }
        for (offset, byte) in prefix.enumerated() where data[start + offset] | 0x20 != byte {
            return nil
        }
        let separator = data[start + prefix.count]
        guard separator < 0x80, separator != 10, separator != 13 else { return nil }
        let after = start + prefix.count + 1
        guard after >= data.endIndex || data[after] == 10 || data[after] == 13 else { return nil }
        return separator
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

/// One table column and the file column that fills it.
public struct ImportAssignment: Sendable, Hashable {
    /// The table column's name.
    public var column: String
    /// The zero-based position of the file's column.
    public var source: Int

    public init(column: String, source: Int) {
        self.column = column
        self.source = source
    }
}

/// How the file's columns map onto the table's.
public struct CSVImportPlan: Sendable, Hashable {
    public let table: TableRef
    /// The table columns the import fills, each with the file column it takes its value
    /// from, in the order the `INSERT` names them. One file column may fill several
    /// table columns; a table column appears at most once.
    public var assignments: [ImportAssignment]
    /// How many columns the file has, which is how long `mapping` is.
    public var sourceCount: Int
    public var hasHeader: Bool
    /// A field equal to this is inserted as NULL. Empty fields are always NULL.
    public var nullText: String
    /// Rows per `INSERT`. Bounded so a statement never grows past what a server accepts.
    public var batchSize: Int
    /// Commit after this many rows; 0 keeps the whole import in one transaction. A file
    /// of hundreds of millions of rows is better committed along the way than held in
    /// one transaction the server may not be able to keep.
    public var commitEveryRows: Int
    /// Take the apostrophe of a formula guard off text fields (see
    /// `ValueCoercion.removingFormulaGuard`). Off unless asked for: it changes data.
    public var removesFormulaGuard: Bool

    /// A plan from the file's side: for each file column, the table column it fills, or
    /// nil to skip it.
    public init(
        table: TableRef, mapping: [String?], hasHeader: Bool = true, nullText: String = "", batchSize: Int = 200,
        commitEveryRows: Int = 0
    ) {
        self.init(
            table: table, assignments: Self.assignments(from: mapping), sourceCount: mapping.count,
            hasHeader: hasHeader, nullText: nullText, batchSize: batchSize, commitEveryRows: commitEveryRows)
    }

    /// A plan from the table's side: each table column names the file column it takes.
    public init(
        table: TableRef, assignments: [ImportAssignment], sourceCount: Int, hasHeader: Bool = true,
        nullText: String = "", batchSize: Int = 200, commitEveryRows: Int = 0, removesFormulaGuard: Bool = false
    ) {
        self.table = table
        var seen = Set<String>()
        let kept = assignments.filter { $0.source >= 0 && seen.insert($0.column).inserted }
        self.assignments = kept
        self.sourceCount = max(sourceCount, (kept.map(\.source).max() ?? -1) + 1)
        self.hasHeader = hasHeader
        self.nullText = nullText
        self.batchSize = min(max(1, batchSize), 1_000)
        self.commitEveryRows = max(0, commitEveryRows)
        self.removesFormulaGuard = removesFormulaGuard
    }

    /// The plan seen from the file: for each file column, the first table column it
    /// fills, or nil when it fills none. Setting it replaces the assignments.
    public var mapping: [String?] {
        get {
            var result = [String?](repeating: nil, count: sourceCount)
            for assignment in assignments where result.indices.contains(assignment.source) {
                if result[assignment.source] == nil { result[assignment.source] = assignment.column }
            }
            return result
        }
        set {
            assignments = Self.assignments(from: newValue)
            sourceCount = newValue.count
        }
    }

    private static func assignments(from mapping: [String?]) -> [ImportAssignment] {
        var seen = Set<String>()
        return mapping.enumerated().compactMap { index, name in
            guard let name, seen.insert(name).inserted else { return nil }
            return ImportAssignment(column: name, source: index)
        }
    }

    /// For each table column, the file column of the same name — compared without case
    /// or surrounding spaces, the first of two that share a name — in the table's order.
    /// A generated column is never filled: the server computes it and refuses a value.
    public static func assignmentsByName(header: [String], columns: [ColumnInfo]) -> [ImportAssignment] {
        var byName: [String: Int] = [:]
        for (index, name) in header.enumerated() {
            let key = name.trimmingCharacters(in: .whitespaces).lowercased()
            if !key.isEmpty, byName[key] == nil { byName[key] = index }
        }
        return columns.compactMap { column in
            guard !column.isGenerated, let source = byName[column.name.lowercased()] else { return nil }
            return ImportAssignment(column: column.name, source: source)
        }
    }

    /// The first file column fills the first table column, and so on, for as many as
    /// both have. A generated column keeps its place but is not filled.
    public static func assignmentsByPosition(sourceCount: Int, columns: [ColumnInfo]) -> [ImportAssignment] {
        columns.enumerated().compactMap { index, column in
            guard index < sourceCount, !column.isGenerated else { return nil }
            return ImportAssignment(column: column.name, source: index)
        }
    }

    /// The table columns an insert must supply and these assignments do not: `NOT NULL`,
    /// with no default, not numbered by the server and not generated.
    public static func missingRequired(_ assignments: [ImportAssignment], columns: [ColumnInfo]) -> [ColumnInfo] {
        let filled = Set(assignments.map(\.column))
        return columns.filter { column in
            !column.isNullable && column.defaultExpression == nil && !column.isAutoIncrement && !column.isGenerated
                && !filled.contains(column.name)
        }
    }

    /// Matches CSV header names to table columns by name, case-insensitively.
    public static func matched(header: [String], to columns: [ColumnInfo], table: TableRef) -> CSVImportPlan {
        let byName = Dictionary(
            columns.map { ($0.name.lowercased(), $0.name) }, uniquingKeysWith: { first, _ in first })
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

    /// The table columns the plan fills, in the order the `INSERT` names them.
    public var targetColumns: [ColumnInfo] {
        plan.assignments.compactMap { assignment in columns.first { $0.name == assignment.column } }
    }

    /// Coerces one CSV record into the values of the target columns.
    public func values(for record: [String], number: Int) throws -> [DBValue] {
        var result: [DBValue] = []
        result.reserveCapacity(targetColumns.count)
        for assignment in plan.assignments {
            guard let column = columns.first(where: { $0.name == assignment.column }) else { continue }
            var text = assignment.source < record.count ? record[assignment.source] : ""
            if text == plan.nullText {
                result.append(.null)
                continue
            }
            if plan.removesFormulaGuard, [.string, .json, .raw, .array].contains(column.kind) {
                text = ValueCoercion.removingFormulaGuard(text)
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
    /// By default the whole import is one transaction: either every record is in, or
    /// none is. With `commitEveryRows` set, work is committed along the way and a failure
    /// loses only the rows since the last commit. The reader is consumed a batch at a
    /// time, so memory stays at one batch whatever the file's size.
    public func run<Source: RecordSource>(
        reader: inout Source,
        on connection: any SQLConnection,
        progress: (@Sendable (Int64) -> Void)? = nil
    ) async throws -> Int64 {
        if plan.hasHeader { _ = reader.next() }
        var inserted: Int64 = 0
        var sinceCommit: Int64 = 0
        var batch: [[DBValue]] = []
        batch.reserveCapacity(plan.batchSize)

        func flush() async throws {
            guard !batch.isEmpty else { return }
            let statement = insertStatement(rows: batch)
            let result = try await connection.executeCollecting(statement.sql, parameters: statement.parameters)
            let count = result.completion.affectedRows ?? Int64(batch.count)
            inserted += count
            sinceCommit += count
            progress?(inserted)
            batch.removeAll(keepingCapacity: true)
            if plan.commitEveryRows > 0, sinceCommit >= Int64(plan.commitEveryRows) {
                try await connection.commit()
                try await connection.beginTransaction()
                sinceCommit = 0
            }
        }

        try await connection.beginTransaction()
        do {
            while let record = reader.next() {
                try Task.checkCancellation()
                batch.append(try values(for: record, number: reader.recordNumber))
                if batch.count >= plan.batchSize { try await flush() }
            }
            try await flush()
            try await connection.commit()
        } catch {
            try? await connection.rollback()
            throw error
        }
        return inserted
    }
}
