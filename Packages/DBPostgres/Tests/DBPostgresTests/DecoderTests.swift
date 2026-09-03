import DBCore
import NIOCore
import XCTest
@testable import DBPostgres

/// Decoder tests that need no server: hand-built wire payloads in, `DBValue` out.
final class PostgresBinaryDecoderTests: XCTestCase {
    let decoder = PostgresBinaryDecoder(catalog: PostgresTypeCatalog())

    func buffer(_ bytes: [UInt8]) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        return buffer
    }

    func buffer(_ text: String) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: text.utf8.count)
        buffer.writeString(text)
        return buffer
    }

    func testNullIsNullRegardlessOfType() {
        for oid in [PGOID.int4, PGOID.text, PGOID.numeric, PGOID.timestamptz] {
            XCTAssertEqual(decoder.decode(oid: oid, bytes: nil), .null)
        }
    }

    func testIntegers() {
        XCTAssertEqual(decoder.decode(oid: PGOID.int2, bytes: buffer([0x80, 0x00])), .int(-32_768))
        XCTAssertEqual(decoder.decode(oid: PGOID.int4, bytes: buffer([0x7F, 0xFF, 0xFF, 0xFF])), .int(2_147_483_647))
        XCTAssertEqual(
            decoder.decode(oid: PGOID.int8, bytes: buffer([0x80, 0, 0, 0, 0, 0, 0, 0])),
            .int(Int64.min)
        )
    }

    func testFloats() {
        // 1.5 as IEEE-754 binary32 and binary64.
        XCTAssertEqual(decoder.decode(oid: PGOID.float4, bytes: buffer([0x3F, 0xC0, 0x00, 0x00])), .double(1.5))
        XCTAssertEqual(
            decoder.decode(oid: PGOID.float8, bytes: buffer([0x3F, 0xF8, 0, 0, 0, 0, 0, 0])),
            .double(1.5)
        )
    }

    /// `numeric` carries base-10000 groups; reassembly must not lose a digit.
    func testNumericKeepsEveryDigit() {
        // 12345.6789 → digits [1, 2345, 6789], weight 1, scale 4.
        let payload: [UInt8] = [
            0x00, 0x03,             // 3 digit groups
            0x00, 0x01,             // weight 1
            0x00, 0x00,             // positive
            0x00, 0x04,             // display scale 4
            0x00, 0x01,             // 1
            0x09, 0x29,             // 2345
            0x1A, 0x85,             // 6789
        ]
        XCTAssertEqual(decoder.decode(oid: PGOID.numeric, bytes: buffer(payload)), .decimal("12345.6789"))
    }

    func testNegativeNumericAndSpecialValues() {
        let negative: [UInt8] = [0, 1, 0, 0, 0x40, 0x00, 0, 2, 0, 7]
        XCTAssertEqual(decoder.decode(oid: PGOID.numeric, bytes: buffer(negative)), .decimal("-7.00"))
        let nan: [UInt8] = [0, 0, 0, 0, 0xC0, 0x00, 0, 0]
        XCTAssertEqual(decoder.decode(oid: PGOID.numeric, bytes: buffer(nan)), .decimal("NaN"))
        let zero: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0]
        XCTAssertEqual(decoder.decode(oid: PGOID.numeric, bytes: buffer(zero)), .decimal("0"))
    }

    func testTextLikeTypesAreTheirBytes() {
        for oid in [PGOID.text, PGOID.varchar, PGOID.bpchar, PGOID.name, PGOID.xml] {
            XCTAssertEqual(decoder.decode(oid: oid, bytes: buffer("日本 🇮🇩")), .string("日本 🇮🇩"))
        }
    }

    func testJSONBSkipsItsVersionByte() {
        var payload = ByteBufferAllocator().buffer(capacity: 8)
        payload.writeInteger(UInt8(1))
        payload.writeString("{\"a\": 1}")
        XCTAssertEqual(decoder.decode(oid: PGOID.jsonb, bytes: payload), .json("{\"a\": 1}"))
        XCTAssertEqual(decoder.decode(oid: PGOID.json, bytes: buffer("{\"a\": 1}")), .json("{\"a\": 1}"))
    }

    func testDateUsesThePostgresEpoch() {
        // 0 days after 2000-01-01.
        XCTAssertEqual(
            decoder.decode(oid: PGOID.date, bytes: buffer([0, 0, 0, 0])),
            .date(DBDate(year: 2000, month: 1, day: 1))
        )
        // 8766 days later is 2024-01-01.
        var forward = ByteBufferAllocator().buffer(capacity: 4)
        forward.writeInteger(Int32(8_766))
        XCTAssertEqual(decoder.decode(oid: PGOID.date, bytes: forward), .date(DBDate(year: 2024, month: 1, day: 1)))
    }

    func testDateInfinities() {
        var positive = ByteBufferAllocator().buffer(capacity: 4)
        positive.writeInteger(Int32.max)
        XCTAssertEqual(decoder.decode(oid: PGOID.date, bytes: positive).text, "infinity")
        var negative = ByteBufferAllocator().buffer(capacity: 4)
        negative.writeInteger(Int32.min)
        XCTAssertEqual(decoder.decode(oid: PGOID.date, bytes: negative).text, "-infinity")
    }

    func testTimeAndTimetz() {
        var time = ByteBufferAllocator().buffer(capacity: 8)
        time.writeInteger(Int64(2 * 3_600 + 30 * 60) * 1_000_000 + 123_456)
        XCTAssertEqual(decoder.decode(oid: PGOID.time, bytes: time).text, "02:30:00.123456")

        var timetz = ByteBufferAllocator().buffer(capacity: 12)
        timetz.writeInteger(Int64(2 * 3_600) * 1_000_000)
        timetz.writeInteger(Int32(-7 * 3_600))   // stored west of UTC, so this prints as +07
        XCTAssertEqual(decoder.decode(oid: PGOID.timetz, bytes: timetz).text, "02:00:00+07")
    }

    func testTimestampWithoutTimeZoneIsRenderedVerbatim() {
        var buffer = ByteBufferAllocator().buffer(capacity: 8)
        // 2024-03-10 02:30:00.123456 as microseconds since 2000-01-01.
        let days = Int64(8_835)
        buffer.writeInteger(days * 86_400_000_000 + (2 * 3_600 + 30 * 60) * 1_000_000 + 123_456)
        guard case let .timestamp(value) = decoder.decode(oid: PGOID.timestamp, bytes: buffer) else {
            return XCTFail("expected a timestamp")
        }
        XCTAssertEqual(value.serverText, "2024-03-10 02:30:00.123456")
        XCTAssertFalse(value.hasTimeZone)
        XCTAssertEqual(value.date, DBDate(year: 2024, month: 3, day: 10))
    }

    func testTimestamptzIsRenderedInTheSessionZone() {
        let jakarta = PostgresBinaryDecoder(
            catalog: PostgresTypeCatalog(),
            settings: PostgresSessionSettings(timeZone: TimeZone(identifier: "Asia/Jakarta"), timeZoneName: "Asia/Jakarta")
        )
        var buffer = ByteBufferAllocator().buffer(capacity: 8)
        buffer.writeInteger(Int64(0))   // exactly 2000-01-01 00:00:00 UTC
        guard case let .timestamp(value) = jakarta.decode(oid: PGOID.timestamptz, bytes: buffer) else {
            return XCTFail("expected a timestamp")
        }
        XCTAssertEqual(value.serverText, "2000-01-01 07:00:00+07")
        XCTAssertTrue(value.hasTimeZone)
    }

    func testTimestampBeforeTheEpochCarriesDaysBackwards() {
        var buffer = ByteBufferAllocator().buffer(capacity: 8)
        buffer.writeInteger(Int64(-1))   // one microsecond before 2000-01-01
        guard case let .timestamp(value) = decoder.decode(oid: PGOID.timestamp, bytes: buffer) else {
            return XCTFail("expected a timestamp")
        }
        XCTAssertEqual(value.serverText, "1999-12-31 23:59:59.999999")
    }

    func testUUID() {
        let bytes: [UInt8] = [
            0x11, 0x11, 0x11, 0x11, 0x22, 0x22, 0x33, 0x33,
            0x44, 0x44, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55,
        ]
        XCTAssertEqual(
            decoder.decode(oid: PGOID.uuid, bytes: buffer(bytes)).text,
            "11111111-2222-3333-4444-555555555555"
        )
    }

    func testByteaKeepsEveryByte() {
        let all = (0 ... 255).map { UInt8($0) }
        guard case let .bytes(data) = decoder.decode(oid: PGOID.bytea, bytes: buffer(all)) else {
            return XCTFail("expected bytes")
        }
        XCTAssertEqual(Array(data), all)
    }

    func testIntervalRendersLikePostgres() {
        var buffer = ByteBufferAllocator().buffer(capacity: 16)
        buffer.writeInteger(Int64(4 * 3_600 + 5 * 60 + 6) * 1_000_000 + 500_000)
        buffer.writeInteger(Int32(3))    // days
        buffer.writeInteger(Int32(14))   // months = 1 year 2 mons
        XCTAssertEqual(
            decoder.decode(oid: PGOID.interval, bytes: buffer).text,
            "1 year 2 mons 3 days 04:05:06.5"
        )
    }

    func testZeroIntervalStillRenders() {
        var buffer = ByteBufferAllocator().buffer(capacity: 16)
        buffer.writeInteger(Int64(0))
        buffer.writeInteger(Int32(0))
        buffer.writeInteger(Int32(0))
        XCTAssertEqual(decoder.decode(oid: PGOID.interval, bytes: buffer).text, "00:00:00")
    }

    func testBitString() {
        var buffer = ByteBufferAllocator().buffer(capacity: 8)
        buffer.writeInteger(Int32(4))
        buffer.writeInteger(UInt8(0b1011_0000))
        XCTAssertEqual(decoder.decode(oid: PGOID.bit, bytes: buffer).text, "1011")
    }

    func testInet() {
        var ipv4 = ByteBufferAllocator().buffer(capacity: 8)
        ipv4.writeBytes([2, 24, 0, 4, 192, 168, 1, 10])
        XCTAssertEqual(decoder.decode(oid: PGOID.inet, bytes: ipv4).text, "192.168.1.10/24")
        var host = ByteBufferAllocator().buffer(capacity: 8)
        host.writeBytes([2, 32, 0, 4, 10, 0, 0, 1])
        XCTAssertEqual(decoder.decode(oid: PGOID.inet, bytes: host).text, "10.0.0.1")
    }

    func testArrayWithNulls() {
        var buffer = ByteBufferAllocator().buffer(capacity: 64)
        buffer.writeInteger(Int32(1))            // one dimension
        buffer.writeInteger(Int32(1))            // has nulls
        buffer.writeInteger(PGOID.int4)          // element type
        buffer.writeInteger(Int32(3))            // length
        buffer.writeInteger(Int32(1))            // lower bound
        buffer.writeInteger(Int32(4)); buffer.writeInteger(Int32(1))
        buffer.writeInteger(Int32(-1))           // NULL element
        buffer.writeInteger(Int32(4)); buffer.writeInteger(Int32(3))
        XCTAssertEqual(
            decoder.decode(oid: 1_007, bytes: buffer),
            .array([.int(1), .null, .int(3)])
        )
    }

    func testEmptyArray() {
        var buffer = ByteBufferAllocator().buffer(capacity: 12)
        buffer.writeInteger(Int32(0))
        buffer.writeInteger(Int32(0))
        buffer.writeInteger(PGOID.text)
        XCTAssertEqual(decoder.decode(oid: 1_009, bytes: buffer), .array([]))
    }

    func testUnknownTypeBecomesRawWithItsCatalogName() {
        let catalog = PostgresTypeCatalog(types: [
            90_001: PostgresTypeInfo(name: "geometry", type: "b", category: "U", elementOID: 0, baseOID: 0),
        ])
        let decoder = PostgresBinaryDecoder(catalog: catalog)
        guard case let .raw(typeName, text, bytes) = decoder.decode(oid: 90_001, bytes: buffer([1, 2, 3])) else {
            return XCTFail("expected raw")
        }
        XCTAssertEqual(typeName, "geometry")
        XCTAssertNil(text)
        XCTAssertEqual(bytes.map(Array.init), [1, 2, 3])
    }

    func testEnumAndStringCategoryTypesDecodeAsText() {
        let catalog = PostgresTypeCatalog(types: [
            90_002: PostgresTypeInfo(name: "mood", type: "e", category: "E", elementOID: 0, baseOID: 0),
            90_003: PostgresTypeInfo(name: "citext", type: "b", category: "S", elementOID: 0, baseOID: 0),
        ])
        let decoder = PostgresBinaryDecoder(catalog: catalog)
        XCTAssertEqual(decoder.decode(oid: 90_002, bytes: buffer("happy")), .string("happy"))
        XCTAssertEqual(decoder.decode(oid: 90_003, bytes: buffer("Mixed")), .string("Mixed"))
    }

    func testDomainsDecodeAsTheirBaseType() {
        let catalog = PostgresTypeCatalog(types: [
            90_004: PostgresTypeInfo(name: "positive_int", type: "d", category: "N", elementOID: 0, baseOID: PGOID.int4),
        ])
        let decoder = PostgresBinaryDecoder(catalog: catalog)
        XCTAssertEqual(decoder.decode(oid: 90_004, bytes: buffer([0, 0, 0, 7])), .int(7))
        XCTAssertEqual(PGOID.kind(for: 90_004, catalog: catalog), .int)
    }
}

final class CivilDateTests: XCTestCase {
    func testRoundTripAcrossFourCenturies() {
        for days in stride(from: -800_000, through: 800_000, by: 997) {
            let civil = CivilDate.civilFromDays(days)
            XCTAssertEqual(
                CivilDate.daysFromCivil(year: civil.year, month: civil.month, day: civil.day),
                days
            )
        }
    }

    func testKnownDates() {
        XCTAssertEqual(CivilDate.civilFromDays(0).year, 1970)
        XCTAssertEqual(CivilDate.civilFromDays(0).month, 1)
        XCTAssertEqual(CivilDate.civilFromDays(0).day, 1)
        // 2000-01-01 is PostgreSQL's epoch.
        let epoch = CivilDate.civilFromDays(CivilDate.postgresEpochDaysFromUnix)
        XCTAssertEqual([epoch.year, epoch.month, epoch.day], [2000, 1, 1])
        // Leap day.
        let leap = CivilDate.daysFromCivil(year: 2024, month: 2, day: 29)
        let back = CivilDate.civilFromDays(leap)
        XCTAssertEqual([back.year, back.month, back.day], [2024, 2, 29])
    }

    func testNegativeMicrosecondsCarryDaysBackwards() {
        let split = CivilDate.timeFromMicroseconds(-1)
        XCTAssertEqual(split.dayCarry, -1)
        XCTAssertEqual(split.time.description, "23:59:59.999999")
    }

    func testBCYearsRenderWithSuffix() {
        XCTAssertEqual(CivilDate.render(date: DBDate(year: 0, month: 1, day: 1)), "0001-01-01 BC")
        XCTAssertEqual(CivilDate.render(date: DBDate(year: -1, month: 12, day: 31)), "0002-12-31 BC")
        XCTAssertEqual(CivilDate.render(date: DBDate(year: 1, month: 1, day: 1)), "0001-01-01")
    }
}

final class PostgresParameterEncoderTests: XCTestCase {
    func testTextForms() {
        XCTAssertEqual(PostgresParameterEncoder.text(for: .bool(true)), "t")
        XCTAssertEqual(PostgresParameterEncoder.text(for: .bool(false)), "f")
        XCTAssertEqual(PostgresParameterEncoder.text(for: .int(-5)), "-5")
        XCTAssertEqual(PostgresParameterEncoder.text(for: .decimal("1.2300")), "1.2300")
        XCTAssertEqual(PostgresParameterEncoder.text(for: .bytes(Data([0, 255]))), "\\x00ff")
        XCTAssertEqual(PostgresParameterEncoder.text(for: .json("{\"a\":1}")), "{\"a\":1}")
    }

    func testArrayLiteralQuotesWhereItMustAndNowhereElse() {
        XCTAssertEqual(PostgresParameterEncoder.arrayLiteral([.int(1), .null, .int(3)]), "{1,NULL,3}")
        XCTAssertEqual(
            PostgresParameterEncoder.arrayLiteral([.string("a,b"), .string("plain"), .string("")]),
            "{\"a,b\",plain,\"\"}"
        )
        XCTAssertEqual(
            PostgresParameterEncoder.arrayLiteral([.string("say \"hi\""), .string("back\\slash")]),
            "{\"say \\\"hi\\\"\",\"back\\\\slash\"}"
        )
        // The four-character text NULL must be quoted so it is not read as a SQL NULL.
        XCTAssertEqual(PostgresParameterEncoder.arrayLiteral([.string("NULL")]), "{\"NULL\"}")
    }

    func testNestedArrays() {
        XCTAssertEqual(
            PostgresParameterEncoder.arrayLiteral([.array([.int(1), .int(2)]), .array([.int(3)])]),
            "{{1,2},{3}}"
        )
    }
}

final class PGOIDKindTests: XCTestCase {
    let catalog = PostgresTypeCatalog(types: [
        90_010: PostgresTypeInfo(name: "mood", type: "e", category: "E", elementOID: 0, baseOID: 0),
        90_011: PostgresTypeInfo(name: "geometry", type: "b", category: "U", elementOID: 0, baseOID: 0),
        90_012: PostgresTypeInfo(name: "_mood", type: "b", category: "A", elementOID: 90_010, baseOID: 0),
    ])

    /// Every built-in OID must land on its own kind. A regression here silently gives the
    /// grid the wrong cell editor for every column.
    func testBuiltInOIDsMapToTheirOwnKind() {
        let expected: [(UInt32, DBValueKind)] = [
            (PGOID.bool, .bool),
            (PGOID.int2, .int), (PGOID.int4, .int), (PGOID.int8, .int), (PGOID.oid, .int),
            (PGOID.float4, .double), (PGOID.float8, .double),
            (PGOID.numeric, .decimal),
            (PGOID.text, .string), (PGOID.varchar, .string), (PGOID.bpchar, .string), (PGOID.name, .string),
            (PGOID.bytea, .bytes),
            (PGOID.date, .date),
            (PGOID.time, .time), (PGOID.timetz, .time),
            (PGOID.timestamp, .timestamp), (PGOID.timestamptz, .timestamp),
            (PGOID.uuid, .uuid),
            (PGOID.json, .json), (PGOID.jsonb, .json),
            (PGOID.interval, .raw), (PGOID.inet, .raw), (PGOID.bit, .raw), (PGOID.money, .raw),
        ]
        for (oid, kind) in expected {
            XCTAssertEqual(PGOID.kind(for: oid, catalog: catalog), kind, "OID \(oid)")
        }
    }

    func testArrayOIDsMapToArray() {
        for arrayOID in [1_007, 1_009, 1_016, 1_231, 2_951] {
            XCTAssertEqual(PGOID.kind(for: UInt32(arrayOID), catalog: catalog), .array, "array OID \(arrayOID)")
        }
        XCTAssertEqual(PGOID.kind(for: 90_012, catalog: catalog), .array)
    }

    func testUserDefinedTypes() {
        XCTAssertEqual(PGOID.kind(for: 90_010, catalog: catalog), .string)
        XCTAssertEqual(PGOID.kind(for: 90_011, catalog: catalog), .raw)
        XCTAssertEqual(PGOID.kind(for: 999_999, catalog: catalog), .raw)
    }
}
