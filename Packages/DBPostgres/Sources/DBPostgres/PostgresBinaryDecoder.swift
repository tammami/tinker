import DBCore
import Foundation
import NIOCore

/// Session settings that change how values are rendered as text.
public struct PostgresSessionSettings: Sendable {
    /// The session's `TimeZone`, used to render `timestamptz` the way the server would print it.
    /// `nil` means UTC.
    public var timeZone: TimeZone?
    /// `SHOW TimeZone` as the server reported it, kept for display and diagnostics.
    public var timeZoneName: String

    public init(timeZone: TimeZone? = nil, timeZoneName: String = "UTC") {
        self.timeZone = timeZone
        self.timeZoneName = timeZoneName
    }

    public static let utc = PostgresSessionSettings()
}

/// Turns PostgreSQL's binary wire format into ``DBValue``.
///
/// PostgresNIO always requests binary results, so this is the only decoding path.
/// Precision is never lost: `numeric` is decoded to its exact digits and timestamps are
/// carried as integer microseconds, so nothing passes through `Double` or `Date`
/// (SPEC §5). Types the driver does not model become `.raw` carrying `pg_type.typname`.
public struct PostgresBinaryDecoder: Sendable {
    public let catalog: PostgresTypeCatalog
    public let settings: PostgresSessionSettings

    public init(catalog: PostgresTypeCatalog, settings: PostgresSessionSettings = .utc) {
        self.catalog = catalog
        self.settings = settings
    }

    /// Decodes one cell. `bytes` is nil for SQL NULL.
    public func decode(oid rawOID: UInt32, bytes: ByteBuffer?) -> DBValue {
        guard var buffer = bytes else { return .null }
        let oid = catalog.resolvingDomain(rawOID)
        return decodeResolved(oid: oid, buffer: &buffer)
    }

    func typeName(_ oid: UInt32) -> String {
        catalog[oid]?.name ?? "oid:\(oid)"
    }

    private func decodeResolved(oid: UInt32, buffer: inout ByteBuffer) -> DBValue {
        switch oid {
        case PGOID.bool:
            return .bool((buffer.readInteger(as: UInt8.self) ?? 0) != 0)
        case PGOID.int2:
            return .int(Int64(buffer.readInteger(as: Int16.self) ?? 0))
        case PGOID.int4:
            return .int(Int64(buffer.readInteger(as: Int32.self) ?? 0))
        case PGOID.int8:
            return .int(buffer.readInteger(as: Int64.self) ?? 0)
        case PGOID.oid, PGOID.xid, PGOID.cid:
            return .int(Int64(buffer.readInteger(as: UInt32.self) ?? 0))
        case PGOID.float4:
            let bits = buffer.readInteger(as: UInt32.self) ?? 0
            return .double(Double(Float(bitPattern: bits)))
        case PGOID.float8:
            let bits = buffer.readInteger(as: UInt64.self) ?? 0
            return .double(Double(bitPattern: bits))
        case PGOID.numeric:
            return decodeNumeric(&buffer)
        case PGOID.bytea:
            return .bytes(Data(buffer.readBytes(length: buffer.readableBytes) ?? []))
        case PGOID.uuid:
            return decodeUUID(&buffer)
        case PGOID.json:
            return .json(readString(&buffer))
        case PGOID.jsonb:
            // jsonb's binary form is a one-byte version marker followed by the JSON text.
            if buffer.readableBytes > 0, buffer.getInteger(at: buffer.readerIndex, as: UInt8.self) == 1 {
                buffer.moveReaderIndex(forwardBy: 1)
            }
            return .json(readString(&buffer))
        case PGOID.date:
            return decodeDate(&buffer)
        case PGOID.time:
            let microseconds = buffer.readInteger(as: Int64.self) ?? 0
            return .time(CivilDate.timeFromMicroseconds(microseconds).time)
        case PGOID.timetz:
            let microseconds = buffer.readInteger(as: Int64.self) ?? 0
            // PostgreSQL stores the zone as seconds *west* of UTC; the printed offset is its negation.
            let west = Int(buffer.readInteger(as: Int32.self) ?? 0)
            let base = CivilDate.timeFromMicroseconds(microseconds).time
            return .time(
                DBTime(
                    hour: base.hour, minute: base.minute, second: base.second,
                    microsecond: base.microsecond, tzOffsetSeconds: -west
                ))
        case PGOID.timestamp:
            return decodeTimestamp(&buffer, hasTimeZone: false)
        case PGOID.timestamptz:
            return decodeTimestamp(&buffer, hasTimeZone: true)
        case PGOID.interval:
            return decodeInterval(&buffer)
        case PGOID.inet, PGOID.cidr:
            return decodeInet(&buffer, oid: oid)
        case PGOID.macaddr, PGOID.macaddr8:
            let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
            let text = bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
            return .raw(typeName: typeName(oid), text: text, bytes: Data(bytes))
        case PGOID.bit, PGOID.varbit:
            return decodeBitString(&buffer, oid: oid)
        case PGOID.money:
            // Scale and symbol depend on lc_monetary, which the driver does not read;
            // the exact integer amount in the server's minor unit is the honest value.
            let amount = buffer.readInteger(as: Int64.self) ?? 0
            return .raw(typeName: "money", text: String(amount), bytes: nil)
        default:
            break
        }

        if PGOID.textLike.contains(oid) { return .string(readString(&buffer)) }
        if let elementOID = PGOID.arrayElement[oid] { return decodeArray(&buffer, fallbackElement: elementOID) }

        guard let info = catalog[oid] else {
            return .raw(
                typeName: typeName(oid), text: nil, bytes: Data(buffer.readBytes(length: buffer.readableBytes) ?? []))
        }
        // An enum's binary form is its label; a string-category type's is its text.
        if info.type == "e" || info.category == "S" { return .string(readString(&buffer)) }
        if info.category == "A" || info.elementOID != 0 {
            return decodeArray(&buffer, fallbackElement: info.elementOID)
        }
        return .raw(typeName: info.name, text: nil, bytes: Data(buffer.readBytes(length: buffer.readableBytes) ?? []))
    }

    private func readString(_ buffer: inout ByteBuffer) -> String {
        buffer.readString(length: buffer.readableBytes) ?? ""
    }

    private func decodeUUID(_ buffer: inout ByteBuffer) -> DBValue {
        guard let bytes = buffer.readBytes(length: 16), bytes.count == 16 else { return .null }
        let uuid = UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            ))
        return .uuid(uuid)
    }

    /// `numeric` arrives as base-10000 digits with a weight and a display scale.
    /// Reassembling them as text keeps every digit the server had.
    private func decodeNumeric(_ buffer: inout ByteBuffer) -> DBValue {
        guard let digitCount = buffer.readInteger(as: Int16.self),
            let weight = buffer.readInteger(as: Int16.self),
            let sign = buffer.readInteger(as: UInt16.self),
            let displayScale = buffer.readInteger(as: Int16.self)
        else { return .decimal("0") }

        switch sign {
        case 0xC000: return .decimal("NaN")
        case 0xD000: return .decimal("Infinity")
        case 0xF000: return .decimal("-Infinity")
        default: break
        }

        // A count the payload cannot hold is a hostile or corrupt server; the bytes are
        // shown raw rather than trusted.
        guard digitCount >= 0, Int(digitCount) * 2 <= buffer.readableBytes else {
            return .raw(typeName: "numeric", text: nil, bytes: nil)
        }
        var digits: [Int] = []
        digits.reserveCapacity(Int(digitCount))
        for _ in 0 ..< Int(digitCount) {
            digits.append(Int(buffer.readInteger(as: Int16.self) ?? 0))
        }

        // Integer part: groups from the most significant digit down to weight 0.
        var integerText = ""
        if weight >= 0 {
            for position in 0 ... Int(weight) {
                let group = position < digits.count ? digits[position] : 0
                integerText += integerText.isEmpty ? String(group) : String(format: "%04d", group)
            }
        }
        if integerText.isEmpty { integerText = "0" }

        // Fractional part: groups after weight 0, truncated or padded to the display scale.
        var fractionText = ""
        if displayScale > 0 {
            var position = Int(weight) + 1
            while fractionText.count < Int(displayScale) {
                let group = (position >= 0 && position < digits.count) ? digits[position] : 0
                fractionText += String(format: "%04d", group)
                position += 1
            }
            fractionText = String(fractionText.prefix(Int(displayScale)))
        }

        let signText = sign == 0x4000 ? "-" : ""
        let text = fractionText.isEmpty ? "\(signText)\(integerText)" : "\(signText)\(integerText).\(fractionText)"
        return .decimal(text)
    }

    private func decodeDate(_ buffer: inout ByteBuffer) -> DBValue {
        guard let days = buffer.readInteger(as: Int32.self) else { return .null }
        if days == Int32.max { return .raw(typeName: "date", text: "infinity", bytes: nil) }
        if days == Int32.min { return .raw(typeName: "date", text: "-infinity", bytes: nil) }
        let civil = CivilDate.civilFromDays(Int(days) + CivilDate.postgresEpochDaysFromUnix)
        return .date(DBDate(year: civil.year, month: civil.month, day: civil.day))
    }

    private func decodeTimestamp(_ buffer: inout ByteBuffer, hasTimeZone: Bool) -> DBValue {
        guard let microseconds = buffer.readInteger(as: Int64.self) else { return .null }
        let name = hasTimeZone ? "timestamptz" : "timestamp"
        if microseconds == Int64.max { return .raw(typeName: name, text: "infinity", bytes: nil) }
        if microseconds == Int64.min { return .raw(typeName: name, text: "-infinity", bytes: nil) }

        var localMicroseconds = microseconds
        var offsetSeconds: Int?
        if hasTimeZone {
            // The value is an instant in UTC; render it in the session's zone, exactly as
            // the server would print it, by shifting whole seconds only.
            let seconds = Int((microseconds >= 0 ? microseconds : microseconds - 999_999) / 1_000_000)
            let instant = Date(timeIntervalSinceReferenceDate: Double(seconds - CivilDate.postgresToReferenceSeconds))
            let offset = settings.timeZone?.secondsFromGMT(for: instant) ?? 0
            offsetSeconds = offset
            localMicroseconds = microseconds + Int64(offset) * 1_000_000
        }

        let split = CivilDate.timeFromMicroseconds(localMicroseconds)
        let civil = CivilDate.civilFromDays(split.dayCarry + CivilDate.postgresEpochDaysFromUnix)
        let date = DBDate(year: civil.year, month: civil.month, day: civil.day)
        let time = DBTime(
            hour: split.time.hour, minute: split.time.minute, second: split.time.second,
            microsecond: split.time.microsecond, tzOffsetSeconds: offsetSeconds
        )
        let text = "\(CivilDate.render(date: date)) \(time)"
        return .timestamp(DBTimestamp(date: date, time: time, hasTimeZone: hasTimeZone, serverText: text))
    }

    /// `interval` has no lossless numeric representation, so it stays `.raw` with the text
    /// PostgreSQL itself would print under `IntervalStyle = postgres` (SPEC §7.3).
    private func decodeInterval(_ buffer: inout ByteBuffer) -> DBValue {
        guard let microseconds = buffer.readInteger(as: Int64.self),
            let days = buffer.readInteger(as: Int32.self),
            let months = buffer.readInteger(as: Int32.self)
        else { return .raw(typeName: "interval", text: nil, bytes: nil) }

        var parts: [String] = []
        let years = Int(months) / 12
        let remainingMonths = Int(months) % 12
        if years != 0 { parts.append("\(years) year\(abs(years) == 1 ? "" : "s")") }
        if remainingMonths != 0 { parts.append("\(remainingMonths) mon\(abs(remainingMonths) == 1 ? "" : "s")") }
        if days != 0 { parts.append("\(days) day\(abs(days) == 1 ? "" : "s")") }
        if microseconds != 0 || parts.isEmpty {
            let negative = microseconds < 0
            let total = abs(microseconds)
            let split = CivilDate.timeFromMicroseconds(total % 86_400_000_000)
            let hours = Int(total / 3_600_000_000)
            var clock = "\(DBDate.pad2(hours)):\(DBDate.pad2(split.time.minute)):\(DBDate.pad2(split.time.second))"
            if split.time.microsecond != 0 {
                var fraction = String(format: "%06d", split.time.microsecond)
                while fraction.hasSuffix("0") { fraction.removeLast() }
                clock += ".\(fraction)"
            }
            parts.append("\(negative ? "-" : "")\(clock)")
        }
        return .raw(typeName: "interval", text: parts.joined(separator: " "), bytes: nil)
    }

    /// `inet`/`cidr`: address family, prefix bits, a cidr flag, length, then the address.
    private func decodeInet(_ buffer: inout ByteBuffer, oid: UInt32) -> DBValue {
        guard let family = buffer.readInteger(as: UInt8.self),
            let bits = buffer.readInteger(as: UInt8.self),
            buffer.readInteger(as: UInt8.self) != nil,
            let length = buffer.readInteger(as: UInt8.self),
            let address = buffer.readBytes(length: Int(length))
        else { return .raw(typeName: typeName(oid), text: nil, bytes: nil) }

        let isIPv4 = family == 2 && address.count == 4
        guard isIPv4 || address.count == 16 else {
            return .raw(typeName: typeName(oid), text: nil, bytes: Data(address))
        }
        let host: String =
            if isIPv4 {
                address.map(String.init).joined(separator: ".")
            } else {
                stride(from: 0, to: address.count, by: 2)
                    .map { String(format: "%x", Int(address[$0]) << 8 | Int(address[$0 + 1])) }
                    .joined(separator: ":")
            }
        let fullWidth = isIPv4 ? 32 : 128
        let text = (oid == PGOID.cidr || Int(bits) != fullWidth) ? "\(host)/\(bits)" : host
        return .raw(typeName: typeName(oid), text: text, bytes: Data(address))
    }

    /// `bit`/`varbit`: a bit length followed by the packed bits.
    private func decodeBitString(_ buffer: inout ByteBuffer, oid: UInt32) -> DBValue {
        guard let bitCount = buffer.readInteger(as: Int32.self),
            let bytes = buffer.readBytes(length: buffer.readableBytes)
        else { return .raw(typeName: typeName(oid), text: nil, bytes: nil) }
        guard bitCount >= 0, Int(bitCount) <= bytes.count * 8 else {
            return .raw(typeName: typeName(oid), text: nil, bytes: Data(bytes))
        }
        var text = ""
        text.reserveCapacity(Int(bitCount))
        for position in 0 ..< Int(bitCount) {
            let byte = bytes[position / 8]
            text.append((byte >> (7 - UInt8(position % 8))) & 1 == 1 ? "1" : "0")
        }
        return .raw(typeName: typeName(oid), text: text, bytes: Data(bytes))
    }

    /// Array header: dimension count, a null flag, the element OID, then per dimension a
    /// length and lower bound, then each element as a length-prefixed payload.
    ///
    /// Multi-dimensional arrays are flattened in row-major order, which is the order the
    /// server sends them and the order the grid displays.
    private func decodeArray(_ buffer: inout ByteBuffer, fallbackElement: UInt32) -> DBValue {
        guard let dimensionCount = buffer.readInteger(as: Int32.self),
            buffer.readInteger(as: Int32.self) != nil,
            let elementOIDRaw = buffer.readInteger(as: UInt32.self)
        else { return .array([]) }
        if dimensionCount == 0 { return .array([]) }
        // PostgreSQL allows six dimensions; more is not a real array.
        guard dimensionCount > 0, dimensionCount <= 6 else { return .raw(typeName: "array", text: nil, bytes: nil) }

        var total = 1
        for _ in 0 ..< Int(dimensionCount) {
            guard let length = buffer.readInteger(as: Int32.self), length >= 0 else {
                return .raw(typeName: "array", text: nil, bytes: nil)
            }
            _ = buffer.readInteger(as: Int32.self)  // lower bound, not modelled
            let (product, overflow) = total.multipliedReportingOverflow(by: Int(length))
            guard !overflow else { return .raw(typeName: "array", text: nil, bytes: nil) }
            total = product
        }
        // Every element carries at least its 4-byte length, so a total the payload cannot
        // hold is not one to allocate for.
        guard total <= buffer.readableBytes / 4 else { return .raw(typeName: "array", text: nil, bytes: nil) }

        let elementOID = elementOIDRaw != 0 ? elementOIDRaw : fallbackElement
        let resolved = catalog.resolvingDomain(elementOID)
        var items: [DBValue] = []
        items.reserveCapacity(total)
        for _ in 0 ..< total {
            guard let length = buffer.readInteger(as: Int32.self) else { break }
            if length < 0 {
                items.append(.null)
                continue
            }
            guard var slice = buffer.readSlice(length: Int(length)) else { break }
            items.append(decodeResolved(oid: resolved, buffer: &slice))
        }
        return .array(items)
    }
}
