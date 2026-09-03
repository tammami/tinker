import Foundation

/// A calendar date with no time component, exactly as the server stores it.
public struct DBDate: Sendable, Hashable, Codable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// ISO-8601 calendar date. Years outside 0001–9999 keep their full digit count,
    /// and negative (BC) years are written with a leading `-`.
    public var description: String {
        let sign = year < 0 ? "-" : ""
        let y = abs(year)
        let yearText = y < 10000 ? String(format: "%04d", y) : String(y)
        return "\(sign)\(yearText)-\(Self.pad2(month))-\(Self.pad2(day))"
    }

    /// Two-digit zero padding, the building block of every date and time rendering.
    public static func pad2(_ value: Int) -> String {
        value < 10 && value >= 0 ? "0\(value)" : String(value)
    }
}

/// A time of day with microsecond resolution and an optional UTC offset
/// (PostgreSQL `timetz`, and the time half of a timestamp).
public struct DBTime: Sendable, Hashable, Codable, CustomStringConvertible {
    public let hour: Int
    public let minute: Int
    public let second: Int
    public let microsecond: Int
    /// Offset from UTC in seconds, or nil when the value carries no zone.
    public let tzOffsetSeconds: Int?

    public init(hour: Int, minute: Int, second: Int, microsecond: Int = 0, tzOffsetSeconds: Int? = nil) {
        self.hour = hour
        self.minute = minute
        self.second = second
        self.microsecond = microsecond
        self.tzOffsetSeconds = tzOffsetSeconds
    }

    /// `hh:mm:ss[.ffffff][±hh[:mm]]`. Fractional seconds are omitted when zero and
    /// otherwise printed without trailing zeros, matching PostgreSQL's own output.
    public var description: String {
        var text = "\(DBDate.pad2(hour)):\(DBDate.pad2(minute)):\(DBDate.pad2(second))"
        if microsecond != 0 {
            var fraction = String(format: "%06d", microsecond)
            while fraction.hasSuffix("0") { fraction.removeLast() }
            text += ".\(fraction)"
        }
        if let offset = tzOffsetSeconds {
            text += Self.formatOffset(offset)
        }
        return text
    }

    /// `±hh`, `±hh:mm` or `±hh:mm:ss` — the shortest form that is exact, as PostgreSQL prints it.
    public static func formatOffset(_ seconds: Int) -> String {
        let sign = seconds < 0 ? "-" : "+"
        let total = abs(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if s != 0 { return "\(sign)\(DBDate.pad2(h)):\(DBDate.pad2(m)):\(DBDate.pad2(s))" }
        if m != 0 { return "\(sign)\(DBDate.pad2(h)):\(DBDate.pad2(m))" }
        return "\(sign)\(DBDate.pad2(h))"
    }
}

/// A timestamp, with or without a time zone.
///
/// `serverText` is the authoritative representation: it round-trips back to the server
/// verbatim as a typed literal. `date` and `time` are a decoded convenience for the UI
/// and are never used to reconstruct the value.
public struct DBTimestamp: Sendable, Hashable, Codable, CustomStringConvertible {
    public let date: DBDate
    public let time: DBTime
    public let hasTimeZone: Bool
    /// Text form of the value, exact and lossless. Never derived from `Foundation.Date`.
    public let serverText: String

    public init(date: DBDate, time: DBTime, hasTimeZone: Bool, serverText: String) {
        self.date = date
        self.time = time
        self.hasTimeZone = hasTimeZone
        self.serverText = serverText
    }

    /// Builds a timestamp whose `serverText` is the canonical `date time` rendering.
    public init(date: DBDate, time: DBTime, hasTimeZone: Bool) {
        self.init(date: date, time: time, hasTimeZone: hasTimeZone, serverText: "\(date) \(time)")
    }

    public var description: String { serverText }
}

/// Which `DBValue` case a column produces. Mirrors `DBValue` one-for-one so the UI can
/// pick a cell editor from `ColumnMeta` before a single row has arrived.
public enum DBValueKind: String, Sendable, Hashable, Codable, CaseIterable {
    case null, bool, int, uint, double, decimal, string, bytes
    case date, time, timestamp, uuid, json, array, raw

    /// Whether values of this kind read as numbers, which is what decides alignment.
    public var isNumeric: Bool {
        switch self {
        case .int, .uint, .double, .decimal: true
        default: false
        }
    }
}

/// A database value in a driver-neutral representation.
///
/// Drivers map every native type to exactly one case; types they do not model map to
/// ``DBValue/raw(typeName:text:bytes:)`` carrying the server's own type name.
///
/// Values that carry precision keep their exact textual form: ``DBValue/decimal(_:)``
/// is a string and ``DBTimestamp/serverText`` is preserved verbatim. Neither is ever
/// routed through `Double` or `Foundation.Date`.
public enum DBValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    /// MySQL unsigned `BIGINT` only; every other integer fits ``DBValue/int(_:)``.
    case uint(UInt64)
    case double(Double)
    /// Exact decimal digits as text. Never converted to `Double`.
    case decimal(String)
    case string(String)
    case bytes(Data)
    case date(DBDate)
    case time(DBTime)
    case timestamp(DBTimestamp)
    case uuid(UUID)
    /// Canonical JSON text, unparsed.
    case json(String)
    /// PostgreSQL arrays. Elements may themselves be `.null`.
    case array([DBValue])
    /// A type the driver does not model. At least one of `text` or `bytes` is non-nil.
    case raw(typeName: String, text: String?, bytes: Data?)

    /// The kind of this value, for editor selection and diagnostics.
    public var kind: DBValueKind {
        switch self {
        case .null: .null
        case .bool: .bool
        case .int: .int
        case .uint: .uint
        case .double: .double
        case .decimal: .decimal
        case .string: .string
        case .bytes: .bytes
        case .date: .date
        case .time: .time
        case .timestamp: .timestamp
        case .uuid: .uuid
        case .json: .json
        case .array: .array
        case .raw: .raw
        }
    }

    public var isNull: Bool { if case .null = self { true } else { false } }

    /// The value's text form where one exists, without any display formatting.
    ///
    /// This is the text the grid edits and the text a driver sends back as a typed
    /// literal. `nil` for `.null`, for binary payloads, and for `.raw` values the
    /// driver could only capture as bytes.
    public var text: String? {
        switch self {
        case .null: nil
        case let .bool(value): value ? "true" : "false"
        case let .int(value): String(value)
        case let .uint(value): String(value)
        case let .double(value): Self.canonicalDouble(value)
        case let .decimal(value): value
        case let .string(value): value
        case .bytes: nil
        case let .date(value): value.description
        case let .time(value): value.description
        case let .timestamp(value): value.serverText
        case let .uuid(value): value.uuidString.lowercased()
        case let .json(value): value
        case .array: nil
        case let .raw(_, text, _): text
        }
    }

    /// Shortest text that round-trips to the same `Double`, with PostgreSQL's spelling
    /// of the three special values.
    public static func canonicalDouble(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value == .infinity { return "Infinity" }
        if value == -.infinity { return "-Infinity" }
        return String(value)
    }
}

extension DBValue: CustomDebugStringConvertible {
    public var debugDescription: String {
        switch self {
        case .null: "NULL"
        case let .bytes(data): "<\(data.count) bytes>"
        case let .array(items): "{\(items.map(\.debugDescription).joined(separator: ","))}"
        case let .raw(typeName, text, bytes):
            if let text { "\(typeName):\(text)" } else { "\(typeName):<\(bytes?.count ?? 0) bytes>" }
        default: text ?? "NULL"
        }
    }
}

extension DBValue: Codable {
    private enum CodingKeys: String, CodingKey { case kind, text, bytes, items, hasTimeZone }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(DBValueKind.self, forKey: .kind)
        let text = try container.decodeIfPresent(String.self, forKey: .text)
        switch kind {
        case .null: self = .null
        case .bool: self = .bool(text == "true")
        case .int: self = .int(Int64(text ?? "0") ?? 0)
        case .uint: self = .uint(UInt64(text ?? "0") ?? 0)
        case .double: self = .double(Double(text ?? "0") ?? 0)
        case .decimal: self = .decimal(text ?? "0")
        case .string: self = .string(text ?? "")
        case .bytes: self = .bytes(try container.decodeIfPresent(Data.self, forKey: .bytes) ?? Data())
        case .json: self = .json(text ?? "null")
        case .uuid: self = .uuid(UUID(uuidString: text ?? "") ?? UUID())
        case .array: self = .array(try container.decodeIfPresent([DBValue].self, forKey: .items) ?? [])
        case .date, .time, .timestamp, .raw:
            // Filter values of these kinds are edited and stored as text; the driver
            // casts them on the way to the server.
            self = .raw(typeName: kind.rawValue, text: text, bytes: nil)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(text, forKey: .text)
        if case let .bytes(data) = self { try container.encode(data, forKey: .bytes) }
        if case let .array(items) = self { try container.encode(items, forKey: .items) }
    }
}
