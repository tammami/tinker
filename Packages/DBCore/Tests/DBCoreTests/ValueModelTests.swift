import XCTest

@testable import DBCore

final class DBValueTests: XCTestCase {
    func testKindMatchesTheCase() {
        let pairs: [(DBValue, DBValueKind)] = [
            (.null, .null), (.bool(true), .bool), (.int(1), .int), (.uint(1), .uint),
            (.double(1), .double), (.decimal("1"), .decimal), (.string("a"), .string),
            (.bytes(Data()), .bytes), (.date(DBDate(year: 2024, month: 1, day: 1)), .date),
            (.time(DBTime(hour: 0, minute: 0, second: 0)), .time),
            (
                .timestamp(
                    DBTimestamp(
                        date: DBDate(year: 2024, month: 1, day: 1),
                        time: DBTime(hour: 0, minute: 0, second: 0), hasTimeZone: false
                    )), .timestamp
            ),
            (.uuid(UUID()), .uuid), (.json("null"), .json), (.array([]), .array),
            (.raw(typeName: "t", text: nil, bytes: nil), .raw),
        ]
        for (value, kind) in pairs {
            XCTAssertEqual(value.kind, kind, "\(value)")
        }
        XCTAssertEqual(Set(pairs.map(\.1)).count, DBValueKind.allCases.count, "a kind is untested")
    }

    func testDecimalTextIsNeverReformatted() {
        // Trailing zeros and the exact digit count carry meaning in a NUMERIC(p,s).
        for text in ["1.2300", "0", "-0.000000000000000000000000000001", "NaN"] {
            XCTAssertEqual(DBValue.decimal(text).text, text)
        }
    }

    func testDoubleTextUsesPostgresSpellingForSpecialValues() {
        XCTAssertEqual(DBValue.double(.nan).text, "NaN")
        XCTAssertEqual(DBValue.double(.infinity).text, "Infinity")
        XCTAssertEqual(DBValue.double(-.infinity).text, "-Infinity")
        // Shortest round-tripping form.
        XCTAssertEqual(DBValue.double(0.1).text, "0.1")
        XCTAssertEqual(Double(DBValue.double(0.1 + 0.2).text ?? ""), 0.1 + 0.2)
    }

    func testTextIsNilWhereNoTextExists() {
        XCTAssertNil(DBValue.null.text)
        XCTAssertNil(DBValue.bytes(Data([1])).text)
        XCTAssertNil(DBValue.array([.int(1)]).text)
        XCTAssertNil(DBValue.raw(typeName: "geometry", text: nil, bytes: Data([1])).text)
    }

    func testDebugDescriptions() {
        XCTAssertEqual(DBValue.null.debugDescription, "NULL")
        XCTAssertEqual(DBValue.bytes(Data([1, 2, 3])).debugDescription, "<3 bytes>")
        XCTAssertEqual(DBValue.array([.int(1), .null]).debugDescription, "{1,NULL}")
    }

    func testCodingRoundTrip() throws {
        let values: [DBValue] = [
            .null, .bool(true), .int(-9_223_372_036_854_775_808), .uint(18_446_744_073_709_551_615),
            .double(1.5), .decimal("1.2300"), .string("çé日本"), .bytes(Data([0, 255])),
            .json("{\"a\":1}"), .uuid(UUID()), .array([.int(1), .null]),
        ]
        let data = try JSONEncoder().encode(values)
        XCTAssertEqual(try JSONDecoder().decode([DBValue].self, from: data), values)
    }

    func testUnsignedBigIntegerSurvives() {
        XCTAssertEqual(DBValue.uint(UInt64.max).text, "18446744073709551615")
    }
}

final class DateAndTimeRenderingTests: XCTestCase {
    func testDateRendering() {
        XCTAssertEqual(DBDate(year: 2024, month: 3, day: 7).description, "2024-03-07")
        XCTAssertEqual(DBDate(year: 1, month: 1, day: 1).description, "0001-01-01")
        XCTAssertEqual(DBDate(year: 9999, month: 12, day: 31).description, "9999-12-31")
        XCTAssertEqual(DBDate(year: 12345, month: 1, day: 1).description, "12345-01-01")
    }

    func testTimeRendering() {
        XCTAssertEqual(DBTime(hour: 1, minute: 2, second: 3).description, "01:02:03")
        XCTAssertEqual(DBTime(hour: 1, minute: 2, second: 3, microsecond: 500_000).description, "01:02:03.5")
        XCTAssertEqual(DBTime(hour: 1, minute: 2, second: 3, microsecond: 1).description, "01:02:03.000001")
    }

    func testOffsetRenderingUsesTheShortestExactForm() {
        XCTAssertEqual(DBTime.formatOffset(7 * 3_600), "+07")
        XCTAssertEqual(DBTime.formatOffset(-(5 * 3_600 + 30 * 60)), "-05:30")
        XCTAssertEqual(DBTime.formatOffset(5 * 3_600 + 30 * 60 + 15), "+05:30:15")
        XCTAssertEqual(DBTime.formatOffset(0), "+00")
    }

    func testTimestampKeepsServerText() {
        let stamp = DBTimestamp(
            date: DBDate(year: 2024, month: 3, day: 10),
            time: DBTime(hour: 2, minute: 30, second: 0),
            hasTimeZone: true,
            serverText: "2024-03-10 02:30:00+07"
        )
        XCTAssertEqual(stamp.description, "2024-03-10 02:30:00+07")
        XCTAssertEqual(DBValue.timestamp(stamp).text, "2024-03-10 02:30:00+07")
    }
}

final class ServerVersionTests: XCTestCase {
    func testParsesLeadingNumbers() {
        XCTAssertEqual(ServerVersion.parseNumbers("16.15").major, 16)
        XCTAssertEqual(ServerVersion.parseNumbers("16.15").minor, 15)
        XCTAssertEqual(ServerVersion.parseNumbers("8.0.36-log").patch, 36)
        XCTAssertEqual(ServerVersion.parseNumbers("10.11.6-MariaDB").major, 10)
        XCTAssertEqual(ServerVersion.parseNumbers("").major, 0)
    }

    func testComparison() {
        let version = ServerVersion(major: 16, minor: 2, patch: 1, flavor: .postgresql, rawString: "16.2.1")
        XCTAssertTrue(version.isAtLeast(16))
        XCTAssertTrue(version.isAtLeast(16, 2))
        XCTAssertTrue(version.isAtLeast(15, 99))
        XCTAssertFalse(version.isAtLeast(16, 3))
        XCTAssertFalse(version.isAtLeast(17))
    }
}

final class ConnectionConfigTests: XCTestCase {
    func testSecretRefNaming() {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555") ?? UUID()
        let ref = SecretRef.forConnection(id, field: "password")
        XCTAssertEqual(ref.service, "com.tinker.connection")
        XCTAssertEqual(ref.account, "\(id.uuidString).password")
    }

    func testConfigCodingCarriesNoSecret() throws {
        var config = ConnectionConfig(
            name: "prod", dialect: .postgresql, host: "db.example", port: 5432, user: "app"
        )
        config.passwordRef = SecretRef.forConnection(config.id, field: "password")
        config.ssh = SSHConfig(
            host: "bastion", user: "me",
            auth: .privateKey(path: "/keys/id_ed25519", passphrase: SecretRef(account: "x.passphrase")),
            jumpHost: SSHConfig(host: "jump", user: "me", auth: .agent)
        )
        let data = try JSONEncoder().encode(config)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.lowercased().contains("password\":\"s"), text)
        XCTAssertFalse(text.contains("hunter2"))

        let decoded = try JSONDecoder().decode(ConnectionConfig.self, from: data)
        XCTAssertEqual(decoded, config)
        XCTAssertEqual(decoded.ssh?.jumpHost?.value.host, "jump")
    }

    func testTLSModeSemantics() {
        XCTAssertFalse(TLSMode.disable.requiresTLS)
        XCTAssertFalse(TLSMode.prefer.requiresTLS)
        XCTAssertTrue(TLSMode.require.requiresTLS)
        XCTAssertFalse(TLSMode.require.verifiesCertificate)
        XCTAssertTrue(TLSMode.verifyCA.verifiesCertificate)
        XCTAssertFalse(TLSMode.verifyCA.verifiesHostname)
        XCTAssertTrue(TLSMode.verifyFull.verifiesHostname)
        XCTAssertEqual(TLSMode.verifyFull.rawValue, "verify-full")
    }

    func testResolvedConfigDescriptionOmitsThePassword() {
        let config = ResolvedConnectionConfig(
            configID: UUID(), dialect: .postgresql, host: "h", port: 5432,
            user: "u", password: "hunter2", database: "d"
        )
        XCTAssertFalse(config.description.contains("hunter2"))
        XCTAssertEqual(config.description, "postgresql://u@h:5432/d")
    }
}

final class QueryResultTests: XCTestCase {
    func testValueLookupByName() {
        let result = QueryResult(
            columns: [
                ColumnMeta(id: 0, name: "a", nativeTypeName: "int4", kind: .int),
                ColumnMeta(id: 1, name: "b", nativeTypeName: "text", kind: .string),
            ],
            rows: [[.int(1), .string("x")]],
            completion: QueryCompletion(durationTotal: .zero)
        )
        XCTAssertEqual(result.value(0, "a"), .int(1))
        XCTAssertEqual(result.value(0, "b"), .string("x"))
        XCTAssertNil(result.value(0, "missing"))
        XCTAssertNil(result.value(5, "a"))
        XCTAssertEqual(result.firstText, "1")
    }

    func testRowBatchIndexing() {
        let batch = RowBatch(rows: [[.int(1)], [.int(2)]], startIndex: 500)
        XCTAssertEqual(batch.count, 2)
        XCTAssertFalse(batch.isEmpty)
        XCTAssertEqual(batch.startIndex, 500)
    }

    func testBatchingLimitsMatchTheSpec() {
        XCTAssertEqual(RowBatching.maxRows, 500)
        XCTAssertEqual(RowBatching.maxBytes, 1_048_576)
    }
}

final class ErrorTests: XCTestCase {
    func testServerMessagesAreNotRewritten() {
        let serverError = ServerError(
            sqlState: "42P01", message: "relation \"x\" does not exist",
            detail: "d", hint: "h", position: 15
        )
        XCTAssertEqual(DBError.server(serverError).errorDescription, "relation \"x\" does not exist")
    }

    func testEveryCaseHasADescription() {
        let errors: [DBError] = [
            .connectionFailed(underlying: "u", hint: "h"),
            .authenticationFailed(user: "bob"),
            .tlsRequiredButUnavailable,
            .tunnelFailed(stage: .sshAuth, underlying: "denied"),
            .cancelled,
            .timeout(after: .seconds(1)),
            .server(ServerError(message: "boom")),
            .unsupportedType(nativeName: "geometry"),
            .protocolError("bad"),
            .notConnected,
        ]
        for error in errors {
            XCTAssertNotNil(error.errorDescription)
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true, "\(error)")
        }
    }
}
