import DBCore
import DBSQL
import Foundation
import SQLite3

/// Moves values across the SQLite boundary in both directions.
///
/// SQLite stores whatever it is given: a column declared `INTEGER` can hold text, and a
/// column declared `DATE` holds text, a number or nothing, because SQLite has no date
/// type. So a cell's ``DBValue`` starts from the storage class SQLite reports for that
/// cell, and the declared type only refines it — an integer in a `BOOLEAN` column is a
/// bool, text in a `DATETIME` column is a timestamp when it reads as one. What does not
/// fit the declared type keeps its storage class, which is the truth about the file.
///
/// There is no exact decimal: a `DECIMAL(65, 30)` column has numeric affinity, and SQLite
/// turns any number written into it into a 64-bit integer or a REAL, keeping fifteen
/// significant digits. The driver reports the REAL it finds rather than pretending.
enum SQLiteValueCodec {
    /// The declared type of a column reduced to what the codec branches on.
    enum DeclaredType: Sendable, Hashable {
        case bool, date, time, timestamp, json, uuid, numeric, integer, real, text, blob, other

        init(_ declared: String?) {
            guard let declared, !declared.isEmpty else {
                self = .other
                return
            }
            let upper = declared.uppercased()
            // Order matters: DATETIME contains both DATE and TIME.
            if upper.contains("BOOL") {
                self = .bool
            } else if upper.contains("DATETIME") || upper.contains("TIMESTAMP") {
                self = .timestamp
            } else if upper.contains("DATE") {
                self = .date
            } else if upper.contains("TIME") {
                self = .time
            } else if upper.contains("JSON") {
                self = .json
            } else if upper.contains("UUID") || upper.contains("GUID") {
                self = .uuid
            } else if upper.contains("DECIMAL") || upper.contains("NUMERIC") || upper.contains("MONEY") {
                self = .numeric
            } else if upper.contains("INT") {
                self = .integer
            } else if upper.contains("REAL") || upper.contains("FLOA") || upper.contains("DOUB") {
                self = .real
            } else if upper.contains("CHAR") || upper.contains("CLOB") || upper.contains("TEXT")
                || upper.contains("STRING")
            {
                self = .text
            } else if upper.contains("BLOB") || upper.contains("BINARY") {
                self = .blob
            } else {
                self = .other
            }
        }

        /// The kind a column of this declared type most likely produces, for `ColumnMeta`
        /// before any row has arrived. SQLite's own affinity rules, with the app's
        /// refinements on top.
        var kind: DBValueKind {
            switch self {
            case .bool: .bool
            case .date: .date
            case .time: .time
            case .timestamp: .timestamp
            case .json: .json
            case .uuid: .uuid
            // Numeric affinity stores a REAL (or an integer); see the type's doc comment.
            case .numeric: .double
            case .integer: .int
            case .real: .double
            case .text: .string
            case .blob: .bytes
            case .other: .string
            }
        }
    }

    // MARK: - Reading

    /// The value in column `index` of the statement's current row.
    static func value(of statement: OpaquePointer, column index: Int32, declared: DeclaredType) -> DBValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_NULL:
            return .null
        case SQLITE_INTEGER:
            let number = sqlite3_column_int64(statement, index)
            if declared == .bool, number == 0 || number == 1 { return .bool(number == 1) }
            return .int(number)
        case SQLITE_FLOAT:
            return .double(sqlite3_column_double(statement, index))
        case SQLITE_BLOB:
            guard let bytes = sqlite3_column_blob(statement, index) else { return .bytes(Data()) }
            let count = Int(sqlite3_column_bytes(statement, index))
            return .bytes(Data(bytes: bytes, count: count))
        default:
            guard let text = sqlite3_column_text(statement, index) else { return .null }
            return refine(String(cString: text), declared: declared)
        }
    }

    /// Text refined by the column's declared type, when the text reads as that type.
    static func refine(_ text: String, declared: DeclaredType) -> DBValue {
        switch declared {
        case .date:
            if let date = TemporalParser.date(text) { return .date(date) }
        case .time:
            if let time = TemporalParser.time(text) { return .time(time) }
        case .timestamp:
            if let timestamp = TemporalParser.timestamp(text) { return .timestamp(timestamp) }
            if let date = TemporalParser.date(text) {
                return .timestamp(
                    DBTimestamp(date: date, time: DBTime(hour: 0, minute: 0, second: 0), hasTimeZone: false, serverText: text))
            }
        case .json:
            return .json(text)
        case .uuid:
            if let uuid = UUID(uuidString: text) { return .uuid(uuid) }
        case .bool:
            switch text.lowercased() {
            case "true", "t", "yes", "1": return .bool(true)
            case "false", "f", "no", "0": return .bool(false)
            default: break
            }
        case .numeric, .integer, .real, .text, .blob, .other:
            break
        }
        return .string(text)
    }

    /// The storage class of column `index` in the current row, as SQLite names it.
    static func storageClassName(of statement: OpaquePointer, column index: Int32) -> String? {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER: "INTEGER"
        case SQLITE_FLOAT: "REAL"
        case SQLITE_TEXT: "TEXT"
        case SQLITE_BLOB: "BLOB"
        default: nil
        }
    }

    // MARK: - Binding

    /// The `SQLITE_TRANSIENT` destructor: SQLite copies the bytes before returning.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Binds `value` at one-based `index`. Text stays text — a decimal, a timestamp, a
    /// UUID — and SQLite's own affinity rules decide how the column stores it.
    static func bind(_ value: DBValue, to statement: OpaquePointer, at index: Int32) -> Int32 {
        switch value {
        case .null:
            return sqlite3_bind_null(statement, index)
        case let .bool(flag):
            return sqlite3_bind_int64(statement, index, flag ? 1 : 0)
        case let .int(number):
            return sqlite3_bind_int64(statement, index, number)
        case let .uint(number):
            if let fits = Int64(exactly: number) { return sqlite3_bind_int64(statement, index, fits) }
            return bindText(String(number), to: statement, at: index)
        case let .double(number):
            return sqlite3_bind_double(statement, index, number)
        case let .decimal(text), let .string(text), let .json(text):
            return bindText(text, to: statement, at: index)
        case let .bytes(data):
            return bindBlob(data, to: statement, at: index)
        case let .date(date):
            return bindText(date.description, to: statement, at: index)
        case let .time(time):
            return bindText(time.description, to: statement, at: index)
        case let .timestamp(timestamp):
            return bindText(timestamp.serverText, to: statement, at: index)
        case let .uuid(uuid):
            return bindText(uuid.uuidString.lowercased(), to: statement, at: index)
        case let .array(items):
            // SQLite has no arrays; a JSON array is the closest thing it will store.
            return bindText(SQLLiteral.jsonArray(items), to: statement, at: index)
        case let .raw(_, text, bytes):
            if let text { return bindText(text, to: statement, at: index) }
            if let bytes { return bindBlob(bytes, to: statement, at: index) }
            return sqlite3_bind_null(statement, index)
        }
    }

    private static func bindText(_ text: String, to statement: OpaquePointer, at index: Int32) -> Int32 {
        var copy = text
        return copy.withUTF8 { buffer in
            sqlite3_bind_text64(
                statement, index, buffer.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) },
                sqlite3_uint64(buffer.count), transient, UInt8(SQLITE_UTF8))
        }
    }

    private static func bindBlob(_ data: Data, to statement: OpaquePointer, at index: Int32) -> Int32 {
        guard !data.isEmpty else { return sqlite3_bind_zeroblob(statement, index, 0) }
        return data.withUnsafeBytes { buffer in
            sqlite3_bind_blob64(statement, index, buffer.baseAddress, sqlite3_uint64(buffer.count), transient)
        }
    }
}

/// Parses the ISO-8601 shapes SQLite's own date functions read and write:
/// `YYYY-MM-DD`, `HH:MM[:SS[.SSS]]`, and the two joined by a space or a `T`, with an
/// optional `Z` or `±HH:MM` zone. Nothing here goes through `Foundation.Date`.
enum TemporalParser {
    static func date(_ text: String) -> DBDate? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
            let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
            (1 ... 12).contains(month), (1 ... 31).contains(day)
        else { return nil }
        return DBDate(year: year, month: month, day: day)
    }

    static func time(_ text: String) -> DBTime? {
        var body = Substring(text)
        var offset: Int? = nil
        if body.hasSuffix("Z") {
            body = body.dropLast()
            offset = 0
        } else if let sign = body.lastIndex(where: { $0 == "+" || $0 == "-" }), body.distance(from: body.startIndex, to: sign) >= 5 {
            let zone = body[sign...]
            body = body[..<sign]
            guard let parsed = zoneOffset(zone) else { return nil }
            offset = parsed
        }
        let parts = body.split(separator: ":", omittingEmptySubsequences: false)
        guard (2 ... 3).contains(parts.count), parts[0].count == 2, parts[1].count == 2,
            let hour = Int(parts[0]), let minute = Int(parts[1]), (0 ... 23).contains(hour), (0 ... 59).contains(minute)
        else { return nil }
        var second = 0
        var microsecond = 0
        if parts.count == 3 {
            let secondParts = parts[2].split(separator: ".", omittingEmptySubsequences: false)
            guard (1 ... 2).contains(secondParts.count), secondParts[0].count == 2, let whole = Int(secondParts[0]),
                (0 ... 59).contains(whole)
            else { return nil }
            second = whole
            if secondParts.count == 2 {
                let fraction = secondParts[1]
                guard !fraction.isEmpty, fraction.count <= 6, fraction.allSatisfy(\.isNumber),
                    let digits = Int(fraction)
                else { return nil }
                microsecond = digits * Int(pow(10.0, Double(6 - fraction.count)))
            }
        }
        return DBTime(hour: hour, minute: minute, second: second, microsecond: microsecond, tzOffsetSeconds: offset)
    }

    static func timestamp(_ text: String) -> DBTimestamp? {
        guard text.count >= 16, let separator = text.dropFirst(10).first, separator == " " || separator == "T" else {
            return nil
        }
        let datePart = String(text.prefix(10))
        let timePart = String(text.dropFirst(11))
        guard let date = date(datePart), let time = time(timePart) else { return nil }
        return DBTimestamp(date: date, time: time, hasTimeZone: time.tzOffsetSeconds != nil, serverText: text)
    }

    /// `±HH:MM` or `±HHMM` or `±HH`, in seconds.
    static func zoneOffset(_ zone: Substring) -> Int? {
        guard let sign = zone.first, sign == "+" || sign == "-" else { return nil }
        let digits = zone.dropFirst().replacingOccurrences(of: ":", with: "")
        guard digits.count == 2 || digits.count == 4, digits.allSatisfy(\.isNumber),
            let hours = Int(digits.prefix(2))
        else { return nil }
        let minutes = digits.count == 4 ? Int(digits.suffix(2)) ?? 0 : 0
        let total = hours * 3_600 + minutes * 60
        return sign == "-" ? -total : total
    }
}
