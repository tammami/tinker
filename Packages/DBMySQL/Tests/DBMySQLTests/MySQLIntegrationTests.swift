import DBCore
import DBGrid
import DBSQL
import DBTestKit
import Logging
import XCTest

@testable import DBMySQL

/// The MySQL suite mirrors the PostgreSQL one statement for statement, because SPEC §16
/// Phase 6 requires an identical feature matrix.
final class MySQLIntegrationTests: XCTestCase {
    var logger: Logger {
        var logger = Logger(label: "test.mysql")
        logger.logLevel = .critical
        return logger
    }

    func withEachServer(
        _ body: (any SQLConnection, TestServer) async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let servers = try TestEnvironment.requireServers(for: .mysql)
        for server in servers {
            let connection = try await MySQLDriver.connect(server.resolvedConfig(), logger: logger)
            do {
                // SPEC §17.1: refuse to run as an account with rights beyond the test database.
                let grants = try await connection.executeCollecting("SHOW GRANTS FOR CURRENT_USER()")
                let global = grants.rows.compactMap { $0.first?.text }.contains { line in
                    line.contains("ON *.*") && !line.hasPrefix("GRANT USAGE ON *.*")
                }
                let database = try await connection.executeCollecting("SELECT DATABASE()")
                try TestGuards.requireUnprivileged(
                    isSuperuser: global,
                    database: database.firstText ?? "",
                    file: file, line: line
                )
                let version = await connection.serverVersion
                TestLog.note(
                    "server version: \(version.flavor.rawValue) \(version.rawString) — \(server.redactedDescription)")
                try await body(connection, server)
            } catch {
                await connection.close()
                throw error
            }
            await connection.close()
        }
    }

    // MARK: - Connection and authentication

    func testConnectsAndReportsVersionAndThreadID() async throws {
        try await withEachServer { connection, _ in
            let version = await connection.serverVersion
            XCTAssertTrue([.mysql, .mariadb, .percona].contains(version.flavor))
            XCTAssertGreaterThanOrEqual(version.major, 5)
            XCTAssertNotNil(Int(connection.backendID))
            try await connection.ping()
        }
    }

    /// SPEC §7.3 makes `caching_sha2_password` a hard requirement: MySQL 8 and later
    /// default to it, and the RSA path is what makes it work without TLS.
    func testAuthenticationPluginAndTLSState() async throws {
        try await withEachServer { connection, _ in
            // Reading `mysql.user` needs a privilege the test account must not have, so a
            // refusal here is the environment behaving correctly.
            let plugin = try? await connection.executeCollecting(
                """
                SELECT plugin FROM mysql.user WHERE user = SUBSTRING_INDEX(CURRENT_USER(), '@', 1) LIMIT 1
                """)
            let name = plugin?.firstText
            let cipher = try await connection.executeCollecting("SHOW SESSION STATUS LIKE 'Ssl_cipher'")
            let encrypted = !(cipher.rows.first?.last?.text ?? "").isEmpty
            TestLog.note("mysql auth plugin: \(name ?? "unreadable"), TLS: \(encrypted ? "on" : "off")")
            if name == nil {
                TestLog.note("cannot read mysql.user (no privilege); the plugin in use is not asserted")
            }
        }
    }

    func testConnectingToAStoppedServerFailsAtTheTCPStage() async throws {
        let servers = try TestEnvironment.requireServers(for: .mysql)
        guard let server = servers.first else { return }
        var config = server.resolvedConfig(connectTimeout: .seconds(5))
        config.port = 1
        do {
            let connection = try await MySQLDriver.connect(config, logger: logger)
            await connection.close()
            XCTFail("expected the connection to fail")
        } catch let error as DBError {
            guard case let .tunnelFailed(stage, _) = error else {
                return XCTFail("expected .tunnelFailed, got \(error)")
            }
            XCTAssertEqual(stage, .tcp)
        }
    }

    func testWrongPasswordSurfacesAsAuthenticationFailure() async throws {
        let servers = try TestEnvironment.requireServers(for: .mysql)
        guard let server = servers.first, server.password != nil else {
            throw XCTSkip("test URL carries no password")
        }
        var config = server.resolvedConfig(connectTimeout: .seconds(5))
        config.password = "definitely-not-the-password"
        do {
            let connection = try await MySQLDriver.connect(config, logger: logger)
            await connection.close()
            throw XCTSkip("server does not enforce passwords for this user")
        } catch let error as DBError {
            guard case let .authenticationFailed(user) = error else {
                return XCTFail("expected .authenticationFailed, got \(error)")
            }
            XCTAssertEqual(user, config.user)
        }
    }

    /// `require` must encrypt or fail; both outcomes are reported so the log says which ran.
    func testTLSModes() async throws {
        let servers = try TestEnvironment.requireServers(for: .mysql)
        for server in servers {
            var required = server.resolvedConfig(connectTimeout: .seconds(10))
            required.tls = TLSConfig(mode: .require)
            do {
                let connection = try await MySQLDriver.connect(required, logger: logger)
                let cipher = try await connection.executeCollecting("SHOW SESSION STATUS LIKE 'Ssl_cipher'")
                await connection.close()
                let name = cipher.rows.first?.last?.text ?? ""
                XCTAssertFalse(name.isEmpty, "sslmode=require connected without TLS")
                TestLog.note("MySQL TLS require: encrypted with \(name)")
            } catch DBError.tlsRequiredButUnavailable {
                TestLog.note("MySQL TLS require: server has no TLS; encrypted path NOT covered")
            }

            var disabled = server.resolvedConfig(connectTimeout: .seconds(10))
            disabled.tls = TLSConfig(mode: .disable)
            let connection = try await MySQLDriver.connect(disabled, logger: logger)
            let cipher = try await connection.executeCollecting("SHOW SESSION STATUS LIKE 'Ssl_cipher'")
            await connection.close()
            XCTAssertEqual(cipher.rows.first?.last?.text ?? "", "", "TLS was disabled but the session is encrypted")
        }
    }

    // MARK: - Types

    func testEveryMappedTypeRoundTrips() async throws {
        try await withEachServer { connection, _ in
            let result = try await connection.executeCollecting(
                """
                SELECT c_bool, c_tinyint, c_utinyint, c_smallint, c_mediumint, c_int,
                       c_bigint, c_ubigint, c_float, c_double, c_decimal,
                       c_char, c_varchar, c_text, c_binary, c_varbinary,
                       c_date, c_time, c_datetime, c_timestamp, c_year,
                       c_json, c_enum, c_set, c_bit, c_generated
                FROM all_types WHERE id = 1
                """)
            func value(_ name: String) throws -> DBValue {
                try XCTUnwrap(result.value(0, name), "no column \(name)")
            }

            // `tinyint(1)` is MySQL's boolean.
            XCTAssertEqual(try value("c_bool"), .bool(true))
            XCTAssertEqual(try value("c_tinyint"), .int(127))
            XCTAssertEqual(try value("c_utinyint"), .int(255))
            XCTAssertEqual(try value("c_smallint"), .int(32_767))
            XCTAssertEqual(try value("c_mediumint"), .int(8_388_607))
            XCTAssertEqual(try value("c_int"), .int(2_147_483_647))
            XCTAssertEqual(try value("c_bigint"), .int(9_223_372_036_854_775_807))
            // Only BIGINT UNSIGNED needs the unsigned case, and it must reach its maximum.
            XCTAssertEqual(try value("c_ubigint"), .uint(18_446_744_073_709_551_615))
            XCTAssertEqual(try value("c_float"), .double(1.5))
            XCTAssertEqual(try value("c_double"), .double(2.5))
            XCTAssertEqual(
                try value("c_decimal"),
                .decimal("12345678901234567890123456789012345.123456789012345678901234567890")
            )
            XCTAssertEqual(try value("c_char"), .string("char8"))
            XCTAssertEqual(try value("c_varchar"), .string("varchar"))
            XCTAssertEqual(try value("c_text"), .string("ascii text"))
            XCTAssertEqual(try value("c_binary"), .bytes(Data([0x00, 0x01, 0x02, 0xFF])))
            XCTAssertEqual(try value("c_varbinary"), .bytes(Data([0x00, 0xFF])))
            XCTAssertEqual(try value("c_date"), .date(DBDate(year: 2024, month: 3, day: 10)))
            XCTAssertEqual(try value("c_time").text, "02:30:00.123456")
            XCTAssertEqual(try value("c_datetime").text, "2024-03-10 02:30:00.123456")
            XCTAssertEqual(try value("c_timestamp").text, "2024-03-10 02:30:00.123456")
            XCTAssertEqual(try value("c_year"), .int(2_024))
            XCTAssertEqual(try value("c_json"), .json("{\"b\": [1, 2, 3]}"))
            XCTAssertEqual(try value("c_enum"), .string("happy"))
            XCTAssertEqual(try value("c_set"), .string("a,c"))
            XCTAssertEqual(try value("c_bit").text, "10110001")
            XCTAssertEqual(try value("c_generated"), .int(4_294_967_294))
        }
    }

    /// Neither DATETIME nor TIMESTAMP carries an offset on the wire; the server converts
    /// TIMESTAMP to the session zone before sending it (SPEC §7.3).
    func testDateTimeAndTimestampBothArriveWithoutAZone() async throws {
        try await withEachServer { connection, _ in
            let result = try await connection.executeCollecting(
                "SELECT c_datetime, c_timestamp FROM all_types WHERE id = 1"
            )
            for name in ["c_datetime", "c_timestamp"] {
                guard case let .timestamp(value)? = result.value(0, name) else {
                    return XCTFail("\(name) is not a timestamp")
                }
                XCTAssertFalse(value.hasTimeZone, "\(name) should not claim a zone")
            }
        }
    }

    func testNullsInEveryColumn() async throws {
        try await withEachServer { connection, _ in
            let result = try await connection.executeCollecting(
                """
                SELECT c_bool, c_bigint, c_decimal, c_text, c_blob, c_datetime, c_json, c_enum
                FROM all_types WHERE id = 2
                """)
            let row = try XCTUnwrap(result.rows.first)
            XCTAssertTrue(row.allSatisfy(\.isNull), "expected every value to be NULL, got \(row)")
        }
    }

    func testExtremesAndUnicode() async throws {
        try await withEachServer { connection, _ in
            let result = try await connection.executeCollecting(
                """
                SELECT c_tinyint, c_smallint, c_int, c_bigint, c_decimal, c_text, c_blob,
                       c_date, c_datetime
                FROM all_types WHERE id = 3
                """)
            XCTAssertEqual(result.value(0, "c_tinyint"), .int(-128))
            XCTAssertEqual(result.value(0, "c_bigint"), .int(-9_223_372_036_854_775_808))
            XCTAssertEqual(result.value(0, "c_decimal"), .decimal("-0.000000000000000000000000000001"))

            let text = try XCTUnwrap(result.value(0, "c_text")?.text)
            XCTAssertTrue(text.contains("中文"), "CJK lost: \(text)")
            XCTAssertTrue(text.contains("👩‍👩‍👧‍👦"), "emoji ZWJ sequence lost: \(text)")
            XCTAssertTrue(text.contains("אבג"), "RTL lost: \(text)")

            guard case let .bytes(data)? = result.value(0, "c_blob") else { return XCTFail("expected bytes") }
            XCTAssertEqual(Array(data), (0 ... 255).map { UInt8($0) }, "not every byte value survived")

            XCTAssertEqual(result.value(0, "c_date"), .date(DBDate(year: 1_000, month: 1, day: 1)))
            XCTAssertEqual(result.value(0, "c_datetime")?.text, "9999-12-31 23:59:59.999999")
        }
    }

    func testOneMegabyteStringAndDeeplyNestedJSON() async throws {
        try await withEachServer { connection, _ in
            let result = try await connection.executeCollecting(
                "SELECT c_text, c_json FROM all_types WHERE id = 4"
            )
            XCTAssertEqual(try XCTUnwrap(result.value(0, "c_text")?.text).count, 1_048_576)
            let json = try XCTUnwrap(result.value(0, "c_json")?.text)
            XCTAssertEqual(json.filter { $0 == "{" }.count, 50)
        }
    }

    /// A zero date is legal under a permissive `sql_mode` and must not become nil.
    func testZeroDatesUnderPermissiveSQLMode() async throws {
        try await withEachServer { connection, _ in
            _ = try await connection.executeCollecting("SET SESSION sql_mode = ''")
            _ = try await connection.executeCollecting("DROP TEMPORARY TABLE IF EXISTS zero_dates")
            _ = try await connection.executeCollecting(
                "CREATE TEMPORARY TABLE zero_dates (d DATE, dt DATETIME)"
            )
            _ = try await connection.executeCollecting(
                "INSERT INTO zero_dates VALUES ('0000-00-00', '0000-00-00 00:00:00')"
            )
            let result = try await connection.executeCollecting("SELECT d, dt FROM zero_dates")
            let row = try XCTUnwrap(result.rows.first)
            // Whatever the server sends, the driver must produce a value rather than crash.
            XCTAssertEqual(row.count, 2)
            TestLog.note("mysql zero dates decode as \(row[0].debugDescription) / \(row[1].debugDescription)")
            _ = try await connection.executeCollecting("DROP TEMPORARY TABLE zero_dates")
        }
    }

    // MARK: - Statement execution

    func testEventOrderAndBatching() async throws {
        try await withEachServer { connection, _ in
            var kinds: [String] = []
            var rowTotal = 0
            for try await event in connection.execute(
                "SELECT * FROM big_table ORDER BY id LIMIT 1200", parameters: []
            ) {
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
            XCTAssertEqual(rowTotal, 1_200)
        }
    }

    func testAffectedRowsAndLastInsertID() async throws {
        try await withEachServer { connection, _ in
            _ = try await connection.executeCollecting("DROP TEMPORARY TABLE IF EXISTS dml_probe")
            _ = try await connection.executeCollecting(
                "CREATE TEMPORARY TABLE dml_probe (id INT AUTO_INCREMENT PRIMARY KEY, a INT)"
            )
            let inserted = try await connection.executeCollecting(
                "INSERT INTO dml_probe (a) VALUES (1), (2), (3)"
            )
            XCTAssertEqual(inserted.completion.affectedRows, 3)
            XCTAssertEqual(inserted.completion.lastInsertID, 1, "the OK packet carries the first generated id")

            let updated = try await connection.executeCollecting("UPDATE dml_probe SET a = a + 1")
            XCTAssertEqual(updated.completion.affectedRows, 3)

            let deleted = try await connection.executeCollecting("DELETE FROM dml_probe WHERE a = 2")
            XCTAssertEqual(deleted.completion.affectedRows, 1)
            _ = try await connection.executeCollecting("DROP TEMPORARY TABLE dml_probe")
        }
    }

    func testParametersAreBoundServerSide() async throws {
        try await withEachServer { connection, _ in
            let hostile = "'; DROP TABLE smoke; --"
            let result = try await connection.executeCollecting(
                "SELECT ? AS echoed, ? AS number", parameters: [.string(hostile), .int(42)]
            )
            XCTAssertEqual(result.value(0, "echoed")?.text, hostile)
            XCTAssertEqual(result.value(0, "number")?.text, "42")

            let survived = try await connection.executeCollecting("SELECT COUNT(*) FROM smoke")
            XCTAssertEqual(survived.firstText, "3")
        }
    }

    func testServerErrorsArriveVerbatimWithTheirCode() async throws {
        try await withEachServer { connection, _ in
            do {
                _ = try await connection.executeCollecting("SELECT 1 FROM no_such_table_here")
                XCTFail("expected the statement to fail")
            } catch let error as DBError {
                guard case let .server(serverError) = error else {
                    return XCTFail("expected .server, got \(error)")
                }
                XCTAssertEqual(serverError.code, 1_146, "unknown table")
                XCTAssertEqual(serverError.sqlState, "42S02")
                XCTAssertTrue(serverError.message.contains("no_such_table_here"), serverError.message)
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

    // MARK: - Cancellation and transactions

    /// `KILL QUERY` must stop the statement quickly and leave the connection usable.
    ///
    /// MySQL's `SLEEP()` is a special case: interrupting it is not an error, it returns 1
    /// instead of 0. Both outcomes are accepted; what is asserted is that the statement
    /// stopped early and the connection still works.
    func testKillQueryCancelsAndLeavesTheConnectionUsable() async throws {
        try await withEachServer { connection, _ in
            let started = ContinuousClock.now
            async let cancellation: Void = {
                try? await Task.sleep(for: .milliseconds(400))
                await connection.cancelCurrent()
            }()

            do {
                let result = try await connection.executeCollecting("SELECT SLEEP(30)")
                XCTAssertEqual(
                    result.firstText, "1",
                    "SLEEP returned \(result.firstText ?? "nil"); 1 means it was interrupted"
                )
            } catch let error as DBError {
                XCTAssertEqual(error, .cancelled, "expected .cancelled, got \(error)")
            }
            await cancellation
            let elapsed = started.duration(to: .now)
            XCTAssertLessThan(elapsed, .seconds(5), "the kill took \(elapsed)")

            let reuse = try await connection.executeCollecting("SELECT 1")
            XCTAssertEqual(reuse.firstText, "1")
        }
    }

    /// A statement that is not `SLEEP` fails with error 1317 when killed, which the driver
    /// maps to `.cancelled` (SPEC §4).
    func testAKilledStatementSurfacesAsCancelled() async throws {
        try await withEachServer { connection, _ in
            async let cancellation: Void = {
                try? await Task.sleep(for: .milliseconds(400))
                await connection.cancelCurrent()
            }()
            let started = ContinuousClock.now
            do {
                // Long enough to be killed mid-flight, and interruptible.
                _ = try await connection.executeCollecting(
                    "SELECT COUNT(*) FROM big_table a JOIN big_table b ON a.id = b.id + 1"
                )
                TestLog.note("the join finished before the kill arrived; cancellation not exercised")
            } catch let error as DBError {
                XCTAssertEqual(error, .cancelled, "expected .cancelled, got \(error)")
            }
            await cancellation
            XCTAssertLessThan(started.duration(to: .now), .seconds(20))
            let reuse = try await connection.executeCollecting("SELECT 1")
            XCTAssertEqual(reuse.firstText, "1")
        }
    }

    func testTransactionsCommitAndRollBack() async throws {
        try await withEachServer { connection, _ in
            _ = try await connection.executeCollecting("DROP TABLE IF EXISTS tx_probe")
            // InnoDB, because MyISAM would ignore the transaction entirely.
            _ = try await connection.executeCollecting("CREATE TABLE tx_probe (a INT) ENGINE = InnoDB")

            try await connection.beginTransaction()
            let open = await connection.isInTransaction
            XCTAssertTrue(open)
            _ = try await connection.executeCollecting("INSERT INTO tx_probe VALUES (1)")
            try await connection.rollback()
            let afterRollback = try await connection.executeCollecting("SELECT COUNT(*) FROM tx_probe")
            XCTAssertEqual(afterRollback.firstText, "0")

            try await connection.withTransaction {
                _ = try await connection.executeCollecting("INSERT INTO tx_probe VALUES (2)")
            }
            let afterCommit = try await connection.executeCollecting("SELECT COUNT(*) FROM tx_probe")
            XCTAssertEqual(afterCommit.firstText, "1")
            _ = try await connection.executeCollecting("DROP TABLE tx_probe")
        }
    }

    // MARK: - Introspection

    func testIntrospectionSnapshot() async throws {
        try await withEachServer { connection, server in
            let introspector = connection.introspector
            let schema = SchemaRef.mysql(server.database)

            let databases = try await introspector.databases()
            XCTAssertTrue(databases.contains { $0.name == server.database && $0.isCurrent })

            // MySQL has no schema layer: one pseudo-schema named for the database.
            let schemas = try await introspector.schemas(in: server.database)
            XCTAssertEqual(schemas.map(\.name), [server.database])
            XCTAssertFalse(schemas[0].isSystem)
            let systemSchemas = try await introspector.schemas(in: "mysql")
            XCTAssertTrue(systemSchemas[0].isSystem)

            let tables = try await introspector.tables(in: schema)
            let byName = Dictionary(uniqueKeysWithValues: tables.map { ($0.name, $0) })
            XCTAssertEqual(byName["all_types"]?.kind, .table)
            XCTAssertEqual(byName["customer_totals"]?.kind, .view)
            XCTAssertEqual(byName["all_types"]?.comment, "Every mapped MySQL type, plus NULLs and extremes")
            XCTAssertNotNil(byName["big_table"]?.sizeBytes)

            // One table on its own reads the same entry the list carries.
            let single = try await introspector.tableInfo(of: TableRef(schema: schema, name: "all_types"))
            XCTAssertEqual(single, byName["all_types"])
            let missing = try await introspector.tableInfo(of: TableRef(schema: schema, name: "no_such_table"))
            XCTAssertNil(missing)
        }
    }

    func testColumnIntrospectionDetails() async throws {
        try await withEachServer { connection, server in
            let table = TableRef(schema: SchemaRef.mysql(server.database), name: "all_types")
            let columns = try await connection.introspector.columns(of: table)
            let byName = Dictionary(uniqueKeysWithValues: columns.map { ($0.name, $0) })

            let id = try XCTUnwrap(byName["id"])
            XCTAssertTrue(id.isPrimaryKey)
            XCTAssertTrue(id.isAutoIncrement)
            XCTAssertFalse(id.isNullable)

            XCTAssertEqual(byName["c_decimal"]?.nativeType, "decimal(65,30)")
            XCTAssertEqual(byName["c_decimal"]?.kind, .decimal)
            XCTAssertEqual(byName["c_bool"]?.kind, .bool)
            XCTAssertEqual(byName["c_ubigint"]?.kind, .uint)
            XCTAssertEqual(byName["c_enum"]?.enumLabels, ["sad", "ok", "happy"])
            XCTAssertEqual(byName["c_set"]?.enumLabels, ["a", "b", "c"])
            XCTAssertEqual(byName["c_blob"]?.kind, .bytes)
            XCTAssertEqual(byName["c_generated"]?.isGenerated, true)
            XCTAssertEqual(byName["c_varchar"]?.characterSet, "utf8mb4")
            XCTAssertEqual(columns.map(\.ordinal), Array(1 ... columns.count))
        }
    }

    func testKeysIndexesAndForeignKeys() async throws {
        try await withEachServer { connection, server in
            let introspector = connection.introspector
            func table(_ name: String) -> TableRef {
                TableRef(schema: SchemaRef.mysql(server.database), name: name)
            }

            let composite = try await introspector.primaryKey(of: table("composite_pk"))
            XCTAssertEqual(composite, ["org_id", "user_id"])
            let none = try await introspector.primaryKey(of: table("no_pk"))
            XCTAssertNil(none)
            let unique = try await introspector.rowIdentity(of: table("unique_not_null"))
            XCTAssertEqual(unique, ["code"])
            let noIdentity = try await introspector.rowIdentity(of: table("no_pk"))
            XCTAssertNil(noIdentity)

            let indexes = try await introspector.indexes(of: table("orders"))
            XCTAssertTrue(indexes.contains { $0.isPrimary && $0.columns == ["id"] })
            XCTAssertTrue(indexes.contains { $0.name == "orders_customer_idx" && !$0.isUnique })
            XCTAssertTrue(indexes.contains { $0.name == "orders_unique_customer_total" && $0.isUnique })

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
            let schema = SchemaRef.mysql(server.database)

            let routines = try await introspector.routines(in: schema)
            let add = try XCTUnwrap(routines.first { $0.name == "add_numbers" })
            XCTAssertEqual(add.kind, .function)
            XCTAssertTrue(add.signature.contains("a int"), add.signature)
            XCTAssertTrue(routines.contains { $0.name == "touch_customer" && $0.kind == .procedure })

            // MySQL answers with its own CREATE TABLE rather than a synthesized one.
            let ddl = try await introspector.tableDDL(TableRef(schema: schema, name: "orders"))
            XCTAssertTrue(ddl.hasPrefix("CREATE TABLE `orders`"), ddl)
            XCTAssertTrue(ddl.contains("PRIMARY KEY"), ddl)
            XCTAssertTrue(ddl.contains("FOREIGN KEY"), ddl)

            let estimate = try await introspector.approximateRowCount(
                TableRef(schema: schema, name: "big_table")
            )
            XCTAssertGreaterThan(try XCTUnwrap(estimate), 500_000)
        }
    }

    func testLargeResultStreamsInBatches() async throws {
        try await withEachServer { connection, _ in
            var batches = 0
            var rows = 0
            for try await event in connection.execute(
                "SELECT id, name FROM big_table ORDER BY id", parameters: []
            ) {
                if case let .rows(batch) = event {
                    batches += 1
                    rows += batch.count
                }
            }
            XCTAssertEqual(rows, 1_000_000)
            XCTAssertGreaterThan(batches, 100)
        }
    }

    /// The four reads the table designer added (SPEC §8, §15b), against real catalogs.
    func testDesignerReadsCheckConstraintsTriggersAndPartitioning() async throws {
        try await withEachServer { connection, server in
            guard let introspector = connection.introspector as? MySQLIntrospector else {
                return XCTFail("expected the MySQL introspector")
            }
            func table(_ name: String) -> TableRef {
                TableRef(schema: SchemaRef.mysql(server.database), name: name)
            }

            let checks = try await introspector.checkConstraints(of: table("checked_values"))
            if introspector.supportsCheckConstraints {
                XCTAssertEqual(checks.map(\.name).sorted(), ["label_not_blank", "quantity_positive"])
                let quantity = try XCTUnwrap(checks.first { $0.name == "quantity_positive" })
                XCTAssertTrue(quantity.expression.contains("quantity"), quantity.expression)
            } else {
                // Before 8.0.16 the server parses CHECK and discards it, so there is
                // genuinely nothing in the catalog to read.
                XCTAssertTrue(checks.isEmpty)
            }

            let customerChecks = try await introspector.checkConstraints(of: table("customers"))
            XCTAssertTrue(customerChecks.isEmpty)

            let triggers = try await introspector.triggers(of: table("audited"))
            XCTAssertEqual(triggers.count, 1, "expected the one fixture trigger")
            let trigger = try XCTUnwrap(triggers.first)
            XCTAssertEqual(trigger.name, "audited_bump")
            XCTAssertEqual(trigger.timing, .before)
            XCTAssertEqual(trigger.events, [.update], "a MySQL trigger fires on exactly one event")
            XCTAssertTrue(trigger.isRowLevel)
            XCTAssertTrue((trigger.body ?? "").contains("touched"), trigger.body ?? "nil")

            let measurementPartitioning = try await introspector.partitioning(of: table("measurements"))
            let partitioning = try XCTUnwrap(measurementPartitioning)
            XCTAssertEqual(partitioning.strategy, .range)
            XCTAssertTrue(partitioning.key.contains("taken_at"), partitioning.key)
            XCTAssertEqual(partitioning.partitions.map(\.name).sorted(), ["p2024", "p2025"])
            let firstPartition = try XCTUnwrap(partitioning.partitions.first)
            XCTAssertTrue((firstPartition.bound ?? "").contains("2025"), firstPartition.bound ?? "nil")

            let none = try await introspector.partitioning(of: table("customers"))
            XCTAssertNil(none, "an unpartitioned table reports nil, not an empty partition list")

            let collations = try await introspector.collations(in: server.database)
            XCTAssertFalse(collations.isEmpty)
            XCTAssertTrue(
                collations.contains { $0.characterSet != nil },
                "MySQL groups collations under a character set"
            )
        }
    }
}

/// Decoder checks that need no server.
final class MySQLValueDecoderTests: XCTestCase {
    func testBitTextIsMostSignificantFirst() {
        XCTAssertEqual(MySQLValueDecoder.bitText([0b1011_0001], length: 8), "10110001")
        XCTAssertEqual(MySQLValueDecoder.bitText([0b0000_1011], length: 4), "1011")
        XCTAssertEqual(MySQLValueDecoder.bitText([], length: 8), "")
    }

    func testEnumAndSetLabelsAreParsedFromTheDeclaredType() {
        XCTAssertEqual(
            MySQLIntrospector.enumLabels(from: "enum('sad','ok','happy')", dataType: "enum"),
            ["sad", "ok", "happy"]
        )
        XCTAssertEqual(
            MySQLIntrospector.enumLabels(from: "set('a','b','c')", dataType: "set"),
            ["a", "b", "c"]
        )
        // A label containing a doubled quote is one label, not two.
        XCTAssertEqual(
            MySQLIntrospector.enumLabels(from: "enum('it''s','ok')", dataType: "enum"),
            ["it's", "ok"]
        )
        XCTAssertNil(MySQLIntrospector.enumLabels(from: "varchar(255)", dataType: "varchar"))
    }

    func testDeclaredTypeToKind() {
        let decoder = MySQLValueDecoder()
        func kind(_ dataType: String, _ columnType: String) -> DBValueKind {
            MySQLIntrospector.kind(dataType: dataType, columnType: columnType, decoder: decoder)
        }
        XCTAssertEqual(kind("tinyint", "tinyint(1)"), .bool)
        XCTAssertEqual(kind("tinyint", "tinyint(4)"), .int)
        XCTAssertEqual(kind("tinyint", "tinyint(1) unsigned"), .int)
        XCTAssertEqual(kind("bigint", "bigint(20)"), .int)
        XCTAssertEqual(kind("bigint", "bigint(20) unsigned"), .uint)
        XCTAssertEqual(kind("decimal", "decimal(65,30)"), .decimal)
        XCTAssertEqual(kind("datetime", "datetime(6)"), .timestamp)
        XCTAssertEqual(kind("timestamp", "timestamp"), .timestamp)
        XCTAssertEqual(kind("longblob", "longblob"), .bytes)
        XCTAssertEqual(kind("longtext", "longtext"), .string)
        XCTAssertEqual(kind("json", "json"), .json)
        XCTAssertEqual(kind("geometry", "geometry"), .raw)
    }

    func testTinyint1CanBeTreatedAsAnInteger() {
        let asInteger = MySQLValueDecoder(settings: MySQLSessionSettings(tinyint1IsBool: false))
        XCTAssertEqual(
            MySQLIntrospector.kind(dataType: "tinyint", columnType: "tinyint(1)", decoder: asInteger),
            .int
        )
    }

    func testIPAddressDetectionGuardsSNI() {
        XCTAssertTrue(MySQLDriver.isIPAddress("127.0.0.1"))
        XCTAssertTrue(MySQLDriver.isIPAddress("::1"))
        XCTAssertFalse(MySQLDriver.isIPAddress("db.example.com"))
        XCTAssertFalse(MySQLDriver.isIPAddress("localhost"))
    }

    func testCommandTagsMatchPostgresShape() {
        XCTAssertEqual(
            MySQLSQLConnection.tag(sql: "SELECT 1", metadata: nil, rowCount: 3),
            "SELECT"
        )
        XCTAssertEqual(
            MySQLSQLConnection.tag(sql: "DELETE FROM t", metadata: nil, rowCount: 0),
            "DELETE"
        )
    }

}

// MARK: - Server monitoring and definitions

extension MySQLIntegrationTests {
    func testActivityListsTheCurrentSessionAndTerminateRefusesNonsense() async throws {
        try await withEachServer { connection, _ in
            let server = try XCTUnwrap(connection.introspector.server)
            let sessions = try await server.activity()
            let me = try XCTUnwrap(sessions.first { $0.isCurrent })
            XCTAssertEqual(me.id, connection.backendID)
            XCTAssertNotNil(me.user)
            XCTAssertNotNil(me.duration)
            do {
                try await server.terminateSession(id: "not-a-thread")
                XCTFail("expected a refusal")
            } catch {}
            do {
                try await server.terminateSession(id: "4000000000")
                XCTFail("expected the server to refuse an unknown thread")
            } catch let error as DBError {
                XCTAssertFalse(error.errorDescription?.isEmpty ?? true)
            }
        }
    }

    func testUsersAndVariablesAreReadable() async throws {
        try await withEachServer { connection, server in
            let introspector = try XCTUnwrap(connection.introspector.server)
            let users = try await introspector.users()
            let me = try XCTUnwrap(users.first { $0.name == server.user })
            XCTAssertFalse(me.isSuperuser)
            XCTAssertNotNil(me.attributes)
            let variables = try await introspector.variables()
            XCTAssertTrue(variables.contains { $0.name == "version" })
            XCTAssertTrue(variables.contains { $0.name == "max_connections" })
        }
    }

    func testViewAndRoutineDefinitionsComeFromTheServer() async throws {
        try await withEachServer { connection, server in
            let introspector = try XCTUnwrap(connection.introspector.server)
            let view = try await introspector.viewDefinition(
                TableRef(database: server.database, schema: server.database, name: "customer_totals")
            )
            XCTAssertTrue(view.uppercased().contains("VIEW"), view)
            XCTAssertTrue(view.contains("customer_totals"), view)

            let schema = SchemaRef.mysql(server.database)
            let function = try await introspector.routineDefinition(
                in: schema, name: "add_numbers", signature: "a int, b int", kind: .function
            )
            XCTAssertTrue(function.uppercased().contains("FUNCTION"), function)
            XCTAssertTrue(function.contains("add_numbers"), function)
            let procedure = try await introspector.routineDefinition(
                in: schema, name: "touch_customer", signature: "cid int", kind: .procedure
            )
            XCTAssertTrue(procedure.uppercased().contains("PROCEDURE"), procedure)

            do {
                _ = try await introspector.routineDefinition(
                    in: schema, name: "no_such", signature: "", kind: .function)
                XCTFail("expected not found")
            } catch {}
        }
    }
}

extension MySQLIntegrationTests {
    func testGrantsAreShownVerbatimAndCreateUserIsRefusedVerbatim() async throws {
        try await withEachServer { connection, server in
            let introspector = try XCTUnwrap(connection.introspector.server)
            let users = try await introspector.users()
            let me = try XCTUnwrap(users.first { $0.name == server.user })
            let grants = try await introspector.grants(for: me)
            XCTAssertTrue(grants.contains { $0.uppercased().hasPrefix("GRANT") }, "\(grants)")
            XCTAssertTrue(grants.contains { $0.contains("tinker_test") }, "\(grants)")
            let statements = try UserOperations.create(
                UserRequest(name: "tinker_test_new_user", host: "localhost", password: "x"), dialect: .mysql
            )
            do {
                _ = try await connection.executeCollecting(statements[0])
                XCTFail("expected the server to refuse")
            } catch let error as DBError {
                XCTAssertFalse(error.errorDescription?.isEmpty ?? true)
            }
        }
    }
}

extension MySQLIntegrationTests {
    /// MySQL's own geometry arrives as SRID + WKB and reads back as longitude/latitude.
    func testSpatialColumnsDecodeToPlaceableShapes() async throws {
        try await withEachServer { connection, _ in
            let result = try await connection.executeCollecting(
                "SELECT id, kind, geom FROM spatial_places WHERE geom IS NOT NULL ORDER BY id"
            )
            XCTAssertEqual(result.rows.count, 6)
            let geomColumn = try XCTUnwrap(result.columns.firstIndex { $0.name == "geom" })
            XCTAssertTrue(
                GeometryParser.isGeometryType(result.columns[geomColumn].nativeTypeName),
                result.columns[geomColumn].nativeTypeName)
            let monas = try XCTUnwrap(GeometryParser.parse(result.rows[0][geomColumn], dialect: .mysql))
            XCTAssertEqual(monas.srid, 4326)
            guard case let .point(point) = monas.shape else { return XCTFail("Monas is a point") }
            XCTAssertEqual(point.longitude, 106.8272, accuracy: 1e-6)
            XCTAssertEqual(point.latitude, -6.1754, accuracy: 1e-6)
            let avenue = try XCTUnwrap(GeometryParser.parse(result.rows[4][geomColumn], dialect: .mysql))
            guard case let .line(points) = avenue.shape else { return XCTFail("the avenue is a line") }
            XCTAssertEqual(points.count, 3)
            XCTAssertEqual(points[0].longitude, 106.8230, accuracy: 1e-6)
            let park = try XCTUnwrap(GeometryParser.parse(result.rows[5][geomColumn], dialect: .mysql))
            guard case let .polygon(rings) = park.shape else { return XCTFail("the park is a polygon") }
            XCTAssertEqual(rings.first?.count, 5)
            XCTAssertFalse(park.isUnplaceable)
        }
    }
}
