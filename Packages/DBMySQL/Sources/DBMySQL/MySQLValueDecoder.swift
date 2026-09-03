import DBCore
import Foundation
import MySQLNIO
import NIOCore

/// Per-connection settings that change how values are read.
public struct MySQLSessionSettings: Sendable {
    /// When true, a column declared `tinyint(1)` is a boolean rather than a small integer
    /// (SPEC §7.3). Configurable because some schemas use `tinyint(1)` as a number.
    public var tinyint1IsBool: Bool
    /// `@@session.time_zone` as the server reports it, for display and diagnostics.
    public var timeZoneName: String

    public init(tinyint1IsBool: Bool = true, timeZoneName: String = "SYSTEM") {
        self.tinyint1IsBool = tinyint1IsBool
        self.timeZoneName = timeZoneName
    }

    public static let `default` = MySQLSessionSettings()
}

/// Turns MySQL result values into ``DBValue``.
///
/// It handles both wire formats, because a prepared statement returns binary rows while
/// the text protocol returns everything as digits. Values that carry precision —
/// `DECIMAL` above all — are read as the exact characters MySQL sent, never through
/// `Double` or `Foundation.Decimal` (SPEC §5).
public struct MySQLValueDecoder: Sendable {
    public let settings: MySQLSessionSettings

    public init(settings: MySQLSessionSettings = .default) {
        self.settings = settings
    }

    /// Decodes one cell, using its column definition for the details the value alone does
    /// not carry: unsigned-ness, `tinyint(1)`, and whether a string column is really binary.
    public func decode(_ data: MySQLData, column: MySQLProtocol.ColumnDefinition41) -> DBValue {
        guard var buffer = data.buffer else { return .null }
        let isUnsigned = column.flags.contains(.COLUMN_UNSIGNED)
        let isBinaryColumn = column.characterSet == .binary

        switch column.columnType {
        case .tiny:
            // `tinyint(1)` is MySQL's boolean, but only when the column was declared that way.
            if settings.tinyint1IsBool, column.columnLength <= 1, !isUnsigned {
                return .bool((integer(data, buffer: &buffer, unsigned: false) ?? 0) != 0)
            }
            return integerValue(data, buffer: &buffer, unsigned: isUnsigned)
        case .short, .long, .int24:
            return integerValue(data, buffer: &buffer, unsigned: isUnsigned)
        case .year:
            // mysql-nio's integer accessors do not cover YEAR, which the binary protocol
            // sends as two little-endian bytes.
            if data.format == .text {
                return Int64(readString(&buffer)).map { .int($0) } ?? .null
            }
            return buffer.readInteger(endianness: .little, as: UInt16.self)
                .map { .int(Int64($0)) } ?? .null
        case .longlong:
            // Only `BIGINT UNSIGNED` can exceed Int64, which is the one case `uint` exists for.
            if isUnsigned {
                if let text = data.format == .text ? readString(&buffer) : nil,
                   let value = UInt64(text) {
                    return .uint(value)
                }
                if let value = buffer.getInteger(at: buffer.readerIndex, endianness: .little, as: UInt64.self) {
                    return .uint(value)
                }
            }
            return integerValue(data, buffer: &buffer, unsigned: isUnsigned)

        case .float, .double:
            return data.double.map { .double($0) } ?? .null

        case .decimal, .newdecimal:
            // In both formats the payload is the exact decimal text.
            return .decimal(readString(&buffer))

        case .date, .newdate:
            guard let time = data.time, let year = time.year else { return .null }
            return .date(DBDate(
                year: Int(year), month: Int(time.month ?? 1), day: Int(time.day ?? 1)
            ))

        case .time, .time2:
            guard let time = data.time else { return .null }
            return .time(DBTime(
                hour: Int(time.hour ?? 0), minute: Int(time.minute ?? 0),
                second: Int(time.second ?? 0), microsecond: Int(time.microsecond ?? 0)
            ))

        case .datetime, .datetime2, .timestamp, .timestamp2:
            guard let time = data.time, let year = time.year else { return .null }
            let date = DBDate(year: Int(year), month: Int(time.month ?? 1), day: Int(time.day ?? 1))
            let clock = DBTime(
                hour: Int(time.hour ?? 0), minute: Int(time.minute ?? 0),
                second: Int(time.second ?? 0), microsecond: Int(time.microsecond ?? 0)
            )
            // MySQL's DATETIME and TIMESTAMP both arrive without an offset: TIMESTAMP is
            // converted to the session zone by the server before it is sent (SPEC §7.3).
            return .timestamp(DBTimestamp(date: date, time: clock, hasTimeZone: false))

        case .json:
            return .json(readString(&buffer))

        case .bit:
            let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
            return .raw(typeName: "bit", text: Self.bitText(bytes, length: Int(column.columnLength)), bytes: Data(bytes))

        case .geometry:
            return .raw(typeName: "geometry", text: nil, bytes: Data(buffer.readBytes(length: buffer.readableBytes) ?? []))

        case .enum, .set:
            return .string(readString(&buffer))

        case .blob, .tinyBlob, .mediumBlob, .longBlob, .varchar, .varString, .string:
            // The character set is what separates TEXT from BLOB and VARCHAR from BINARY.
            if isBinaryColumn {
                return .bytes(Data(buffer.readBytes(length: buffer.readableBytes) ?? []))
            }
            return .string(readString(&buffer))

        case .null:
            return .null

        default:
            let bytes = Data(buffer.readBytes(length: buffer.readableBytes) ?? [])
            return .raw(typeName: Self.typeName(column), text: nil, bytes: bytes)
        }
    }

    private func readString(_ buffer: inout ByteBuffer) -> String {
        buffer.readString(length: buffer.readableBytes) ?? ""
    }

    private func integerValue(_ data: MySQLData, buffer: inout ByteBuffer, unsigned: Bool) -> DBValue {
        integer(data, buffer: &buffer, unsigned: unsigned).map { .int($0) } ?? .null
    }

    private func integer(_ data: MySQLData, buffer: inout ByteBuffer, unsigned: Bool) -> Int64? {
        if data.format == .text {
            return Int64(buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) ?? "")
        }
        return data.int64
    }

    /// `BIT(n)` printed as its bits, most significant first.
    static func bitText(_ bytes: [UInt8], length: Int) -> String {
        guard !bytes.isEmpty else { return "" }
        let bitCount = length > 0 ? min(length, bytes.count * 8) : bytes.count * 8
        var text = ""
        text.reserveCapacity(bitCount)
        let offset = bytes.count * 8 - bitCount
        for position in 0 ..< bitCount {
            let absolute = offset + position
            let byte = bytes[absolute / 8]
            text.append((byte >> (7 - UInt8(absolute % 8))) & 1 == 1 ? "1" : "0")
        }
        return text
    }

    /// The value kind a column produces, for `ColumnMeta` before any row arrives.
    public func kind(for column: MySQLProtocol.ColumnDefinition41) -> DBValueKind {
        let isUnsigned = column.flags.contains(.COLUMN_UNSIGNED)
        switch column.columnType {
        case .tiny:
            return settings.tinyint1IsBool && column.columnLength <= 1 && !isUnsigned ? .bool : .int
        case .short, .long, .int24, .year:
            return .int
        case .longlong:
            return isUnsigned ? .uint : .int
        case .float, .double: return .double
        case .decimal, .newdecimal: return .decimal
        case .date, .newdate: return .date
        case .time, .time2: return .time
        case .datetime, .datetime2, .timestamp, .timestamp2: return .timestamp
        case .json: return .json
        case .enum, .set: return .string
        case .bit, .geometry: return .raw
        case .blob, .tinyBlob, .mediumBlob, .longBlob, .varchar, .varString, .string:
            return column.characterSet == .binary ? .bytes : .string
        case .null: return .null
        default: return .raw
        }
    }

    /// The type name shown in the grid header, as MySQL spells it.
    public static func typeName(_ column: MySQLProtocol.ColumnDefinition41) -> String {
        let base: String
        switch column.columnType {
        case .tiny: base = column.columnLength <= 1 ? "tinyint(1)" : "tinyint"
        case .short: base = "smallint"
        case .int24: base = "mediumint"
        case .long: base = "int"
        case .longlong: base = "bigint"
        case .float: base = "float"
        case .double: base = "double"
        case .decimal, .newdecimal: base = "decimal"
        case .date, .newdate: base = "date"
        case .time, .time2: base = "time"
        case .datetime, .datetime2: base = "datetime"
        case .timestamp, .timestamp2: base = "timestamp"
        case .year: base = "year"
        case .json: base = "json"
        case .enum: base = "enum"
        case .set: base = "set"
        case .bit: base = "bit"
        case .geometry: base = "geometry"
        case .varchar, .varString: base = column.characterSet == .binary ? "varbinary" : "varchar"
        case .string: base = column.characterSet == .binary ? "binary" : "char"
        case .blob: base = column.characterSet == .binary ? "blob" : "text"
        case .tinyBlob: base = column.characterSet == .binary ? "tinyblob" : "tinytext"
        case .mediumBlob: base = column.characterSet == .binary ? "mediumblob" : "mediumtext"
        case .longBlob: base = column.characterSet == .binary ? "longblob" : "longtext"
        case .null: base = "null"
        default: base = "unknown"
        }
        return column.flags.contains(.COLUMN_UNSIGNED) ? "\(base) unsigned" : base
    }
}
