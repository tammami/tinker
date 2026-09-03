import DBCore
import DBSQL
import DBTestKit
import Logging
import XCTest
@testable import DBPostgres

/// Integration tests against every server named in `DBSTUDIO_TEST_PG_URL(S)`.
///
/// They skip with a reason when no server is configured and **fail** when a configured
/// server is one the suite must not touch (SPEC §17.1). The server version is reported so
/// the CI log shows what actually ran.
final class PostgresIntegrationTests: XCTestCase {
    var logger: Logger {
        var logger = Logger(label: "test.postgres")
        logger.logLevel = .critical
        return logger
    }

    /// Runs `body` against each configured server, after proving the account is unprivileged.
    func withEachServer(
        _ body: (any SQLConnection, TestServer) async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let servers = try TestEnvironment.requireServers(for: .postgresql)
        for server in servers {
            let connection = try await PostgresDriver.connect(server.resolvedConfig(), logger: logger)
            do {
                let guardResult = try await connection.executeCollecting(
                    "SELECT rolsuper, current_database() FROM pg_roles WHERE rolname = current_user"
                )
                try TestGuards.requireUnprivileged(
                    isSuperuser: guardResult.rows.first?.first == .bool(true),
                    database: guardResult.rows.first?.last?.text ?? "",
                    file: file, line: line
                )
                let version = await connection.serverVersion
                TestLog.note("server version: \(version.rawString) — \(server.redactedDescription)")
                try await body(connection, server)
            } catch {
                // Always hand the socket back, or PostgresNIO asserts in its deinit.
                await connection.close()
                throw error
            }
            await connection.close()
        }
    }

    // MARK: - Connection

    func testConnectsAndReportsVersionAndBackendID() async throws {
        try await withEachServer { connection, _ in
            let version = await connection.serverVersion
            XCTAssertEqual(version.flavor, .postgresql)
            XCTAssertGreaterThanOrEqual(version.major, 10)
            XCTAssertFalse(version.rawString.isEmpty)
            XCTAssertNotNil(Int32(connection.backendID))
            try await connection.ping()
        }
    }

    func testConnectingToAStoppedServerFailsAtTheTCPStage() async throws {
        let servers = try TestEnvironment.requireServers(for: .postgresql)
        guard let server = servers.first else { return }
        var config = server.resolvedConfig(connectTimeout: .seconds(5))
        config.port = 1   // nothing listens here
        do {
            _ = try await PostgresDriver.connect(config, logger: logger)
            XCTFail("expected the connection to fail")
        } catch let error as DBError {
            guard case let .tunnelFailed(stage, _) = error else {
                return XCTFail("expected .tunnelFailed, got \(error)")
            }
            XCTAssertEqual(stage, .tcp)
        }
    }

    func testWrongPasswordSurfacesAsAuthenticationFailure() async throws {
        let servers = try TestEnvironment.requireServers(for: .postgresql)
        guard let server = servers.first, server.password != nil else {
            throw XCTSkip("test URL carries no password, so a wrong-password test would not be meaningful")
        }
        var config = server.resolvedConfig(connectTimeout: .seconds(5))
        config.password = "definitely-not-the-password"
        do {
            let connection = try await PostgresDriver.connect(config, logger: logger)
            await connection.close()
            // Some local servers authorise loopback with `trust`, so no password is checked.
            // That is a property of the server, not a defect, and it is reported as a gap.
            TestLog.note("pg_hba does not require a password for \(config.user) on \(config.host); "
                + "authentication-failure path NOT covered on this server")
            throw XCTSkip("server does not enforce passwords for this user")
        } catch let error as DBError {
            guard case let .authenticationFailed(user) = error else {
                return XCTFail("expected .authenticationFailed, got \(error)")
            }
            XCTAssertEqual(user, config.user)
        }
    }

    /// SCRAM-SHA-256 is PostgreSQL's default since version 14 and the fixture user is
    /// created with a password, so a successful connection exercises whichever
    /// mechanism the server is configured for. The mechanism is reported for the log.
    func testPasswordAuthenticationMechanism() async throws {
        try await withEachServer { connection, _ in
            let result = try await connection.executeCollecting(
                "SELECT current_setting('password_encryption')"
            )
            TestLog.note("password_encryption: \(result.firstText ?? "?")")
            XCTAssertNotNil(result.firstText)
        }
    }

    /// TLS modes: `require` must either encrypt the connection or fail loudly, never
    /// fall back silently. Which of the two happens depends on the server's build and
    /// configuration, so both outcomes are accepted and the one that occurred is reported.
    func testTLSRequireEitherEncryptsOrFailsLoudly() async throws {
        let servers = try TestEnvironment.requireServers(for: .postgresql)
        for server in servers {
            var config = server.resolvedConfig(connectTimeout: .seconds(10))
            config.tls = TLSConfig(mode: .require)
            do {
                let connection = try await PostgresDriver.connect(config, logger: logger)
                let result = try await connection.executeCollecting(
                    "SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()"
                )
                await connection.close()
                XCTAssertEqual(result.rows.first?.first, .bool(true), "sslmode=require connected without TLS")
                TestLog.note("TLS require: encrypted on \(server.host)")
            } catch DBError.tlsRequiredButUnavailable {
                TestLog.note("TLS require: server has no TLS support; encrypted-connection path NOT covered on \(server.host)")
            }
        }
    }

    func testTLSDisableConnectsWithoutEncryption() async throws {
        let servers = try TestEnvironment.requireServers(for: .postgresql)
        for server in servers {
            var config = server.resolvedConfig(connectTimeout: .seconds(10))
            config.tls = TLSConfig(mode: .disable)
            let connection = try await PostgresDriver.connect(config, logger: logger)
            let result = try await connection.executeCollecting(
                "SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()"
            )
            await connection.close()
            XCTAssertEqual(result.rows.first?.first, .bool(false))
        }
    }

    // MARK: - Types

    func testEveryMappedTypeRoundTrips() async throws {
        try await withEachServer { connection, _ in
            let result = try await connection.executeCollecting("""
                SELECT c_bool, c_int2, c_int4, c_int8, c_float4, c_float8, c_numeric,
                       c_text, c_varchar, c_char, c_name, c_bytea,
                       c_date, c_time, c_timetz, c_timestamp, c_timestamptz,
                       c_uuid, c_json, c_jsonb, c_int_array, c_text_array, c_mood,
                       c_interval, c_inet, c_bit, c_generated
                FROM all_types WHERE id = 1
                """)
            let row = try XCTUnwrap(result.rows.first)
            func value(_ name: String) throws -> DBValue {
                try XCTUnwrap(result.value(0, name), "no column \(name)")
            }

            XCTAssertEqual(try value("c_bool"), .bool(true))
            XCTAssertEqual(try value("c_int2"), .int(32_767))
            XCTAssertEqual(try value("c_int4"), .int(2_147_483_647))
            XCTAssertEqual(try value("c_int8"), .int(9_223_372_036_854_775_807))
            XCTAssertEqual(try value("c_float4"), .double(1.5))
            XCTAssertEqual(try value("c_float8"), .double(2.5))
            XCTAssertEqual(
                try value("c_numeric"),
                .decimal("12345678901234567890123456789012345.123456789012345678901234567890")
            )
            XCTAssertEqual(try value("c_text"), .string("ascii text"))
            XCTAssertEqual(try value("c_varchar"), .string("varchar"))
            XCTAssertEqual(try value("c_char"), .string("char8   "))
            XCTAssertEqual(try value("c_name"), .string("a_name"))
            XCTAssertEqual(try value("c_bytea"), .bytes(Data([0x00, 0x01, 0x02, 0xFF])))
            XCTAssertEqual(try value("c_date"), .date(DBDate(year: 2024, month: 3, day: 10)))
            XCTAssertEqual(try value("c_time").text, "02:30:00.123456")
            XCTAssertEqual(try value("c_timetz").text, "02:30:00+07")
            XCTAssertEqual(try value("c_timestamp").text, "2024-03-10 02:30:00.123456")
            XCTAssertEqual(try value("c_uuid").text, "11111111-2222-3333-4444-555555555555")
            XCTAssertEqual(try value("c_json"), .json("{\"a\":1}"))
            XCTAssertEqual(try value("c_jsonb"), .json("{\"b\": [1, 2, 3]}"))
            XCTAssertEqual(try value("c_int_array"), .array([.int(1), .null, .int(3)]))
            XCTAssertEqual(try value("c_text_array"), .array([.string("a"), .null, .string("ç")]))
            XCTAssertEqual(try value("c_mood"), .string("happy"))
            XCTAssertEqual(try value("c_interval").text, "1 year 2 mons 3 days 04:05:06.5")
            XCTAssertEqual(try value("c_inet").text, "192.168.1.10/24")
            XCTAssertEqual(try value("c_bit").text, "10110001")
            XCTAssertEqual(try value("c_generated"), .int(4_294_967_294))

            // A timestamptz is an instant, so its rendering depends on the session zone;
            // what must hold is that it round-trips back to the same instant.
            let timestamptz = try value("c_timestamptz")
            guard case let .timestamp(stamp) = timestamptz else { return XCTFail("expected a timestamp") }
            XCTAssertTrue(stamp.hasTimeZone)
            let sameInstant = try await connection.executeCollecting(
                "SELECT c_timestamptz = $1::timestamptz FROM all_types WHERE id = 1",
                parameters: [.string(stamp.serverText)]
            )
            XCTAssertEqual(sameInstant.rows.first?.first, .bool(true), "serverText \(stamp.serverText) did not round-trip")
            XCTAssertEqual(row.count, 27)
        }
    }

    func testNullsInEveryColumn() async throws {
        try await withEachServer { connection, _ in
            let result = try await connection.executeCollecting(
                "SELECT c_int2, c_numeric, c_text, c_bytea, c_timestamptz, c_int_array, c_mood FROM all_types WHERE id = 2"
            )
            let row = try XCTUnwrap(result.rows.first)
            XCTAssertTrue(row.allSatisfy(\.isNull), "expected every value to be NULL, got \(row)")
        }
    }

    func testExtremesAndUnicode() async throws {
        try await withEachServer { connection, _ in
            let result = try await connection.executeCollecting("""
                SELECT c_int2, c_int4, c_int8, c_float4, c_float8, c_numeric,
                       c_text, c_bytea, c_date, c_timestamp, c_int_array, c_text_array
                FROM all_types WHERE id = 3
                """)
            XCTAssertEqual(result.value(0, "c_int2"), .int(-32_768))
            XCTAssertEqual(result.value(0, "c_int8"), .int(-9_223_372_036_854_775_808))
            XCTAssertEqual(result.value(0, "c_float4"), .double(.infinity))
            guard case let .double(nan)? = result.value(0, "c_float8") else { return XCTFail("expected a double") }
            XCTAssertTrue(nan.isNaN)
            XCTAssertEqual(result.value(0, "c_numeric"), .decimal("-0.000000000000000000000000000001"))

            let text = try XCTUnwrap(result.value(0, "c_text")?.text)
            XCTAssertTrue(text.contains("中文"), "CJK lost: \(text)")
            XCTAssertTrue(text.contains("👩‍👩‍👧‍👦"), "emoji ZWJ sequence lost: \(text)")
            XCTAssertTrue(text.contains("אבג"), "RTL lost: \(text)")

            guard case let .bytes(data)? = result.value(0, "c_bytea") else { return XCTFail("expected bytes") }
            XCTAssertEqual(Array(data), (0 ... 255).map { UInt8($0) }, "not every byte value survived")

            XCTAssertEqual(result.value(0, "c_date"), .date(DBDate(year: 1, month: 1, day: 1)))
            XCTAssertEqual(result.value(0, "c_timestamp")?.text, "9999-12-31 23:59:59.999999")
            XCTAssertEqual(result.value(0, "c_int_array"), .array([.null, .null]))
            XCTAssertEqual(result.value(0, "c_text_array"), .array([]))
        }
    }

    func testOneMegabyteStringAndDeeplyNestedJSON() async throws {
        try await withEachServer { connection, _ in
            let result = try await connection.executeCollecting(
                "SELECT c_text, c_jsonb FROM all_types WHERE id = 4"
            )
            let text = try XCTUnwrap(result.value(0, "c_text")?.text)
            XCTAssertEqual(text.count, 1_048_576)
            let json = try XCTUnwrap(result.value(0, "c_jsonb")?.text)
            XCTAssertEqual(json.filter { $0 == "{" }.count, 50)
        }
    }

    func testTimestampsAcrossADSTBoundary() async throws {
        try await withEachServer { connection, _ in
            let result = try await connection.executeCollecting(
                "SELECT label, at, at AT TIME ZONE 'UTC' AS utc FROM dst_samples ORDER BY id"
            )
            XCTAssertEqual(result.rows.count, 4)
            // The two 01:30 samples in November are different instants an hour apart.
            let firstUTC = try XCTUnwrap(result.value(2, "utc")?.text)
            let secondUTC = try XCTUnwrap(result.value(3, "utc")?.text)
            XCTAssertEqual(firstUTC, "2024-11-03 05:30:00")
            XCTAssertEqual(secondUTC, "2024-11-03 06:30:00")
        }
    }

    // MARK: - Statement execution

    func testEventOrderIsColumnsThenRowsThenComplete() async throws {
        try await withEachServer { connection, _ in
            var kinds: [String] = []
            var rowTotal = 0
            for try await event in connection.execute("SELECT * FROM big_table ORDER BY id LIMIT 1200", parameters: []) {
                switch event {
                case .columns: kinds.append("columns")
                case let .rows(batch):
                    kinds.append("rows")
                    XCTAssertEqual(batch.startIndex, rowTotal)
                    rowTotal += batch.count
                    XCTAssertLessThanOrEqual(batch.count, RowBatching.maxRows)
                case .complete: kinds.append("complete")
                }
            }
            XCTAssertEqual(kinds.first, "columns")
            XCTAssertEqual(kinds.last, "complete")
            XCTAssertEqual(kinds.filter { $0 == "columns" }.count, 1)
            XCTAssertEqual(kinds.filter { $0 == "complete" }.count, 1)
            XCTAssertEqual(rowTotal, 1_200)
        }
    }

    func testAffectedRowsForDML() async throws {
        try await withEachServer { connection, _ in
            _ = try await connection.executeCollecting("CREATE TEMP TABLE dml_probe (a int)")
            let inserted = try await connection.executeCollecting("INSERT INTO dml_probe VALUES (1), (2), (3)")
            XCTAssertEqual(inserted.completion.affectedRows, 3)
            XCTAssertEqual(inserted.completion.serverTag, "INSERT 0 3")

            let updated = try await connection.executeCollecting("UPDATE dml_probe SET a = a + 1")
            XCTAssertEqual(updated.completion.affectedRows, 3)
            XCTAssertEqual(updated.completion.serverTag, "UPDATE 3")

            let deleted = try await connection.executeCollecting("DELETE FROM dml_probe WHERE a = 2")
            XCTAssertEqual(deleted.completion.affectedRows, 1)

            let returning = try await connection.executeCollecting(
                "INSERT INTO dml_probe VALUES (10), (11) RETURNING a"
            )
            XCTAssertEqual(returning.rows.count, 2)
            XCTAssertEqual(returning.completion.affectedRows, 2)
            _ = try await connection.executeCollecting("DROP TABLE dml_probe")
        }
    }

    func testParametersAreBoundServerSide() async throws {
        try await withEachServer { connection, _ in
            // A value that would end the statement if it were interpolated rather than bound.
            let hostile = "'; DROP TABLE smoke; --"
            let result = try await connection.executeCollecting(
                "SELECT $1::text AS echoed, $2::int AS number", parameters: [.string(hostile), .int(42)]
            )
            XCTAssertEqual(result.value(0, "echoed"), .string(hostile))
            XCTAssertEqual(result.value(0, "number"), .int(42))
            // The table the injection targeted is still there.
            let survived = try await connection.executeCollecting("SELECT count(*) FROM smoke")
            XCTAssertEqual(survived.firstText, "3")
        }
    }

    func testParameterTypesTheServerInfers() async throws {
        try await withEachServer { connection, _ in
            let result = try await connection.executeCollecting("""
                SELECT $1::numeric AS exact, $2::timestamptz AS moment, $3::bytea AS blob,
                       $4::uuid AS identifier, $5::jsonb AS document, $6::int[] AS numbers
                """, parameters: [
                    .decimal("0.10000000000000000001"),
                    .string("2024-03-10 02:30:00+00"),
                    .bytes(Data([0, 1, 255])),
                    .uuid(UUID(uuidString: "11111111-2222-3333-4444-555555555555") ?? UUID()),
                    .json("{\"k\": [1, 2]}"),
                    .array([.int(1), .null, .int(3)]),
                ])
            XCTAssertEqual(result.value(0, "exact"), .decimal("0.10000000000000000001"))
            XCTAssertEqual(result.value(0, "blob"), .bytes(Data([0, 1, 255])))
            XCTAssertEqual(result.value(0, "identifier")?.text, "11111111-2222-3333-4444-555555555555")
            XCTAssertEqual(result.value(0, "numbers"), .array([.int(1), .null, .int(3)]))
        }
    }

    func testServerErrorsArriveVerbatimWithPosition() async throws {
        try await withEachServer { connection, _ in
            do {
                _ = try await connection.executeCollecting("SELECT 1 FROM no_such_relation_here")
                XCTFail("expected the statement to fail")
            } catch let error as DBError {
                guard case let .server(serverError) = error else {
                    return XCTFail("expected .server, got \(error)")
                }
                XCTAssertEqual(serverError.sqlState, "42P01")
                XCTAssertTrue(serverError.message.contains("no_such_relation_here"), serverError.message)
                XCTAssertNotNil(serverError.position)
            }
        }
    }

    /// SPEC §13.3: a syntax error's reported position addresses the offending token.
    func testSyntaxErrorPositionAddressesTheToken() async throws {
        try await withEachServer { connection, _ in
            let sql = "SELECT id, name, FROM smoke"
            do {
                _ = try await connection.executeCollecting(sql)
                XCTFail("expected a syntax error")
            } catch let error as DBError {
                guard case let .server(serverError) = error, let position = serverError.position else {
                    return XCTFail("expected a server error carrying a position, got \(error)")
                }
                let index = sql.index(sql.startIndex, offsetBy: position - 1)
                XCTAssertTrue(sql[index...].hasPrefix("FROM"), "position \(position) points at '\(sql[index...])'")
            }
        }
    }

    func testConnectionIsUsableAfterAnError() async throws {
        try await withEachServer { connection, _ in
            _ = try? await connection.executeCollecting("SELECT * FROM definitely_missing")
            let result = try await connection.executeCollecting("SELECT 1")
            XCTAssertEqual(result.firstText, "1")
        }
    }

    // MARK: - Cancellation

    /// SPEC §13.3: cancelling `pg_sleep(60)` returns quickly with `.cancelled`, and the
    /// same connection still works afterwards.
    func testServerSideCancelReturnsQuicklyAndLeavesTheConnectionUsable() async throws {
        try await withEachServer { connection, _ in
            let started = ContinuousClock.now
            async let cancellation: Void = {
                try? await Task.sleep(for: .milliseconds(300))
                await connection.cancelCurrent()
            }()

            do {
                _ = try await connection.executeCollecting("SELECT pg_sleep(60)")
                XCTFail("expected the statement to be cancelled")
            } catch let error as DBError {
                XCTAssertEqual(error, .cancelled, "expected .cancelled, got \(error)")
            }
            await cancellation
            let elapsed = started.duration(to: .now)
            XCTAssertLessThan(elapsed, .seconds(5), "cancel took \(elapsed)")

            let reuse = try await connection.executeCollecting("SELECT 1")
            XCTAssertEqual(reuse.firstText, "1")
        }
    }

    func testCancellingTheConsumingTaskStopsTheServerToo() async throws {
        try await withEachServer { connection, _ in
            let task = Task {
                for try await _ in connection.execute("SELECT pg_sleep(60)", parameters: []) {}
                return Task.isCancelled
            }
            try await Task.sleep(for: .milliseconds(300))
            task.cancel()
            _ = try? await task.value

            // The backend is free again well before the sleep would have ended.
            try await Task.sleep(for: .milliseconds(700))
            // The probe must not match itself: pg_stat_activity.query holds the text of
            // the statement doing the asking, which mentions the sleep it is looking for.
            let active = try await connection.executeCollecting("""
                SELECT count(*) FROM pg_stat_activity
                WHERE pid = \(connection.backendID) AND state = 'active'
                  AND query LIKE ('%pg' || '_sleep%') AND query NOT LIKE '%pg_stat_activity%'
                """)
            XCTAssertEqual(active.firstText, "0", "the sleeping statement was still running")
        }
    }

    // MARK: - Transactions

    func testTransactionsCommitAndRollBack() async throws {
        try await withEachServer { connection, _ in
            _ = try await connection.executeCollecting("CREATE TEMP TABLE tx_probe (a int)")

            try await connection.beginTransaction()
            let inTransaction = await connection.isInTransaction
            XCTAssertTrue(inTransaction)
            _ = try await connection.executeCollecting("INSERT INTO tx_probe VALUES (1)")
            try await connection.rollback()
            let afterRollback = try await connection.executeCollecting("SELECT count(*) FROM tx_probe")
            XCTAssertEqual(afterRollback.firstText, "0")

            try await connection.withTransaction {
                _ = try await connection.executeCollecting("INSERT INTO tx_probe VALUES (2)")
            }
            let afterCommit = try await connection.executeCollecting("SELECT count(*) FROM tx_probe")
            XCTAssertEqual(afterCommit.firstText, "1")

            let idle = await connection.isInTransaction
            XCTAssertFalse(idle)
            _ = try await connection.executeCollecting("DROP TABLE tx_probe")
        }
    }

    func testTransactionKeywordsTypedByTheUserAreTracked() async throws {
        try await withEachServer { connection, _ in
            _ = try await connection.executeCollecting("BEGIN")
            let opened = await connection.isInTransaction
            XCTAssertTrue(opened)
            _ = try await connection.executeCollecting("ROLLBACK")
            let closed = await connection.isInTransaction
            XCTAssertFalse(closed)
        }
    }

    // MARK: - Introspection

    func testIntrospectionSnapshot() async throws {
        try await withEachServer { connection, server in
            let introspector = connection.introspector
            let schema = SchemaRef(database: server.database, schema: "public")

            let databases = try await introspector.databases()
            XCTAssertTrue(databases.contains { $0.name == server.database && $0.isCurrent })

            let schemas = try await introspector.schemas(in: server.database)
            XCTAssertTrue(schemas.contains { $0.name == "public" && !$0.isSystem })
            XCTAssertTrue(schemas.contains { $0.name == "pg_catalog" && $0.isSystem })

            let tables = try await introspector.tables(in: schema)
            let byName = Dictionary(uniqueKeysWithValues: tables.map { ($0.name, $0) })
            XCTAssertEqual(byName["all_types"]?.kind, .table)
            XCTAssertEqual(byName["customer_totals"]?.kind, .view)
            XCTAssertEqual(byName["customer_totals_mv"]?.kind, .materializedView)
            XCTAssertEqual(byName["all_types"]?.comment, "Every mapped PostgreSQL type, plus NULLs and extremes")
            XCTAssertNotNil(byName["big_table"]?.sizeBytes)
        }
    }

    func testColumnIntrospectionDetails() async throws {
        try await withEachServer { connection, server in
            let table = TableRef(database: server.database, schema: "public", name: "all_types")
            let columns = try await connection.introspector.columns(of: table)
            let byName = Dictionary(uniqueKeysWithValues: columns.map { ($0.name, $0) })

            let id = try XCTUnwrap(byName["id"])
            XCTAssertTrue(id.isPrimaryKey)
            XCTAssertTrue(id.isAutoIncrement)
            XCTAssertFalse(id.isNullable)

            XCTAssertEqual(byName["c_numeric"]?.nativeType, "numeric(65,30)")
            XCTAssertEqual(byName["c_numeric"]?.kind, .decimal)
            XCTAssertEqual(byName["c_numeric"]?.comment, "Exact decimal, never a Double")
            XCTAssertEqual(byName["c_varchar"]?.nativeType, "character varying(255)")
            XCTAssertEqual(byName["c_mood"]?.enumLabels, ["sad", "ok", "happy"])
            XCTAssertEqual(byName["c_mood"]?.kind, .string)
            XCTAssertEqual(byName["c_int_array"]?.kind, .array)
            XCTAssertEqual(byName["c_generated"]?.isGenerated, true)
            XCTAssertEqual(columns.map(\.ordinal), Array(1 ... columns.count))
        }
    }

    func testKeysIndexesAndForeignKeys() async throws {
        try await withEachServer { connection, server in
            let introspector = connection.introspector
            func table(_ name: String) -> TableRef {
                TableRef(database: server.database, schema: "public", name: name)
            }

            let compositeKey = try await introspector.primaryKey(of: table("composite_pk"))
            XCTAssertEqual(compositeKey, ["org_id", "user_id"])
            let uuidKey = try await introspector.primaryKey(of: table("uuid_pk"))
            XCTAssertEqual(uuidKey, ["id"])
            let noKey = try await introspector.primaryKey(of: table("no_pk"))
            XCTAssertNil(noKey)

            // A table without a primary key can still be edited through a unique NOT NULL index.
            let uniqueIdentity = try await introspector.rowIdentity(of: table("unique_not_null"))
            XCTAssertEqual(uniqueIdentity, ["code"])
            let noIdentity = try await introspector.rowIdentity(of: table("no_pk"))
            XCTAssertNil(noIdentity)

            let indexes = try await introspector.indexes(of: table("orders"))
            XCTAssertTrue(indexes.contains { $0.isPrimary && $0.columns == ["id"] })
            XCTAssertTrue(indexes.contains { $0.name == "orders_customer_idx" && !$0.isUnique })
            XCTAssertTrue(indexes.contains { $0.name == "orders_unique_customer_total" && $0.isUnique })
            XCTAssertTrue(indexes.allSatisfy { $0.method != nil })

            let foreignKeys = try await introspector.foreignKeys(of: table("orders"))
            let foreignKey = try XCTUnwrap(foreignKeys.first)
            XCTAssertEqual(foreignKey.columns, ["customer_id"])
            XCTAssertEqual(foreignKey.referencedTable.name, "customers")
            XCTAssertEqual(foreignKey.referencedColumns, ["id"])
            XCTAssertEqual(foreignKey.onDelete, .cascade)
            XCTAssertEqual(foreignKey.onUpdate, .restrict)
        }
    }

    func testRoutinesAndDDLAndRowCount() async throws {
        try await withEachServer { connection, server in
            let introspector = connection.introspector
            let schema = SchemaRef(database: server.database, schema: "public")

            let routines = try await introspector.routines(in: schema)
            let add = try XCTUnwrap(routines.first { $0.name == "add_numbers" })
            XCTAssertEqual(add.kind, .function)
            XCTAssertEqual(add.signature, "a integer, b integer")
            XCTAssertEqual(add.returnType, "integer")
            XCTAssertTrue(routines.contains { $0.name == "touch_customer" && $0.kind == .procedure })

            let ddl = try await introspector.tableDDL(TableRef(schema: schema, name: "orders"))
            XCTAssertTrue(ddl.hasPrefix("CREATE TABLE \"public\".\"orders\""), ddl)
            XCTAssertTrue(ddl.contains("\"customer_id\" integer"), ddl)
            XCTAssertTrue(ddl.contains("PRIMARY KEY"), ddl)
            XCTAssertTrue(ddl.contains("FOREIGN KEY"), ddl)
            XCTAssertTrue(ddl.contains("CREATE INDEX orders_customer_idx"), ddl)

            let estimate = try await introspector.approximateRowCount(TableRef(schema: schema, name: "big_table"))
            XCTAssertGreaterThan(try XCTUnwrap(estimate), 900_000)
        }
    }

    // MARK: - Streaming

    func testLargeResultStreamsInBatchesWithoutLoadingEverything() async throws {
        try await withEachServer { connection, _ in
            var batches = 0
            var rows = 0
            var largestBatch = 0
            for try await event in connection.execute("SELECT id, name FROM big_table ORDER BY id", parameters: []) {
                if case let .rows(batch) = event {
                    batches += 1
                    rows += batch.count
                    largestBatch = max(largestBatch, batch.count)
                }
            }
            XCTAssertEqual(rows, 1_000_000)
            XCTAssertGreaterThan(batches, 100, "a million rows should arrive in many batches")
            XCTAssertLessThanOrEqual(largestBatch, RowBatching.maxRows)
        }
    }
}
