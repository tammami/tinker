import DBCore
import DBGrid
import DBSQL
import DBTestKit
import Logging
import SQLite3
import XCTest

@testable import DBSQLite

/// The SQLite suite mirrors the PostgreSQL and MySQL ones statement for statement where a
/// file can do what a server does, and says so where it cannot. Everything here runs
/// against a real database file the suite makes for itself.
final class SQLiteIntegrationTests: XCTestCase {
    func withConnection(
        options: [String: String] = [:], statementTimeout: Duration? = nil,
        _ body: (any SQLConnection) async throws -> Void
    ) async throws {
        let connection = try await SQLiteFixture.connect(options: options, statementTimeout: statementTimeout)
        do {
            try await body(connection)
        } catch {
            await connection.close()
            throw error
        }
        await connection.close()
    }

    func table(_ name: String) -> TableRef { TableRef(schema: .sqlite, name: name) }

    // MARK: - Opening the file

    func testConnectsAndReportsVersionAndALocalTransport() async throws {
        try await withConnection { connection in
            let version = await connection.serverVersion
            XCTAssertEqual(version.flavor, .sqlite)
            XCTAssertEqual(version.major, 3)
            XCTAssertTrue(version.rawString.hasPrefix("SQLite 3."), version.rawString)
            XCTAssertNotNil(Int(connection.backendID))
            XCTAssertTrue(connection.transport.isLocalFile)
            XCTAssertEqual(connection.transport.summary, "Local file, no network connection")
            try await connection.ping()
            TestLog.note("server version: \(version.rawString) — \(SQLiteFixture.path)")
        }
    }

    func testAMissingFileIsRefusedUnlessCreationIsAskedFor() async throws {
        let path = SQLiteFixture.scratchPath()
        var config = SQLiteFixture.config()
        config.database = path
        do {
            _ = try await SQLiteDriver.connect(config, logger: SQLiteFixture.logger)
            XCTFail("a missing file must not be created silently")
        } catch let DBError.connectionFailed(underlying, hint) {
            XCTAssertTrue(underlying.contains("No such file"), underlying)
            XCTAssertNotNil(hint)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))

        config.options[SQLiteDriver.OptionKey.createIfMissing] = "true"
        let connection = try await SQLiteDriver.connect(config, logger: SQLiteFixture.logger)
        _ = try await connection.executeCollecting("CREATE TABLE t (x)")
        await connection.close()
        XCTAssertTrue(SQLiteDriver.isDatabaseFile(at: path))
    }

    func testAFileThatIsNotADatabaseIsRefusedByItsHeader() async throws {
        let path = SQLiteFixture.scratchPath()
        try Data("not a database at all, just text\n".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertFalse(SQLiteDriver.isDatabaseFile(at: path))
        var config = SQLiteFixture.config()
        config.database = path
        do {
            _ = try await SQLiteDriver.connect(config, logger: SQLiteFixture.logger)
            XCTFail("a text file is not a database")
        } catch let DBError.connectionFailed(underlying, _) {
            XCTAssertTrue(underlying.contains("is not a SQLite database"), underlying)
        }
    }

    func testCreateDatabaseWritesAProperHeaderAndRefusesToOverwrite() throws {
        let path = SQLiteFixture.scratchPath()
        try SQLiteDriver.createDatabase(at: path)
        let head = try Data(contentsOf: URL(fileURLWithPath: path)).prefix(16)
        XCTAssertEqual(head, Data("SQLite format 3\0".utf8))
        XCTAssertThrowsError(try SQLiteDriver.createDatabase(at: path))
    }

    func testConnectionConfigForAFileNamesItAfterTheFile() {
        let config = SQLiteDriver.connectionConfig(forFileAt: "~/Databases/Shop Orders.sqlite3")
        XCTAssertEqual(config.dialect, .sqlite)
        XCTAssertEqual(config.name, "Shop Orders")
        XCTAssertTrue(config.database?.hasSuffix("/Databases/Shop Orders.sqlite3") ?? false)
        XCTAssertFalse(config.database?.hasPrefix("~") ?? true, "the tilde is expanded")
        XCTAssertEqual(config.host, "")
        XCTAssertEqual(config.port, 0)
        XCTAssertEqual(config.tls.mode, .disable)
        XCTAssertEqual(config.options[SQLiteDriver.OptionKey.foreignKeys], "true")
    }

    // MARK: - Values

    func testEveryDeclaredTypeArrivesAsItsKind() async throws {
        try await withConnection { connection in
            let result = try await connection.executeCollecting("SELECT * FROM all_types WHERE id = 1")
            XCTAssertEqual(result.rows.count, 1)
            let row = result.rows[0]
            func value(_ name: String) -> DBValue { result.value(0, name) ?? .raw(typeName: "missing", text: nil, bytes: nil) }
            XCTAssertEqual(value("c_bool"), .bool(true))
            XCTAssertEqual(value("c_int"), .int(2_147_483_647))
            XCTAssertEqual(value("c_bigint"), .int(9_223_372_036_854_775_807))
            XCTAssertEqual(value("c_real"), .double(1.5))
            XCTAssertEqual(value("c_double"), .double(2.5))
            // NUMERIC(12,4) takes numeric affinity: 12.5 is stored as a REAL and read as one.
            XCTAssertEqual(value("c_numeric"), .double(12.5))
            // DECIMAL(65, 30) is numeric affinity: SQLite kept fifteen digits of the number as a
            // REAL, and the driver says so rather than inventing a decimal.
            XCTAssertEqual(value("c_decimal"), .double(1.234567890123457e34))
            XCTAssertEqual(value("c_text"), .string("ascii text"))
            XCTAssertEqual(value("c_varchar"), .string("varchar"))
            XCTAssertEqual(value("c_blob"), .bytes(Data([0x00, 0x01, 0x02, 0xFF])))
            XCTAssertEqual(value("c_date"), .date(DBDate(year: 2024, month: 3, day: 10)))
            XCTAssertEqual(value("c_time"), .time(DBTime(hour: 2, minute: 30, second: 0, microsecond: 123_000)))
            guard case let .timestamp(local) = value("c_datetime") else { return XCTFail("datetime: \(value("c_datetime"))") }
            XCTAssertEqual(local.serverText, "2024-03-10 02:30:00.123")
            XCTAssertFalse(local.hasTimeZone)
            guard case let .timestamp(zoned) = value("c_timestamp") else { return XCTFail("timestamp: \(value("c_timestamp"))") }
            XCTAssertEqual(zoned.serverText, "2024-03-10T02:30:00Z")
            XCTAssertTrue(zoned.hasTimeZone)
            XCTAssertEqual(zoned.time.tzOffsetSeconds, 0)
            XCTAssertEqual(value("c_uuid"), .uuid(UUID(uuidString: "11111111-2222-3333-4444-555555555555")!))
            XCTAssertEqual(value("c_json"), .json("{\"a\":1}"))
            // An undeclared column takes its storage class.
            XCTAssertEqual(value("c_any"), .string("anything"))
            XCTAssertEqual(value("c_generated"), .int(4_294_967_294))
            XCTAssertEqual(row.count, result.columns.count)

            let kinds = Dictionary(uniqueKeysWithValues: result.columns.map { ($0.name, $0.kind) })
            XCTAssertEqual(kinds["c_bool"], .bool)
            XCTAssertEqual(kinds["c_datetime"], .timestamp)
            XCTAssertEqual(kinds["c_json"], .json)
            XCTAssertEqual(kinds["c_uuid"], .uuid)
            XCTAssertEqual(kinds["c_blob"], .bytes)
            XCTAssertEqual(kinds["c_any"], .string, "an undeclared column is typed by its first value")
            let primaryKeys = result.columns.filter { $0.isPrimaryKey == true }.map(\.name)
            XCTAssertEqual(primaryKeys, ["id"])
            XCTAssertEqual(result.columns.first { $0.name == "c_int" }?.tableOID, "main.all_types")
        }
    }

    func testNullsInEveryColumn() async throws {
        try await withConnection { connection in
            let result = try await connection.executeCollecting("SELECT * FROM all_types WHERE id = 2")
            let nulls = result.rows[0].enumerated().filter { $0.element.isNull }.map { result.columns[$0.offset].name }
            XCTAssertEqual(nulls.count, result.columns.count - 1, "everything but the key")
            XCTAssertFalse(nulls.contains("id"))
        }
    }

    func testExtremesAndUnicode() async throws {
        try await withConnection { connection in
            let result = try await connection.executeCollecting("SELECT * FROM all_types WHERE id = 3")
            XCTAssertEqual(result.value(0, "c_int"), .int(-2_147_483_648))
            XCTAssertEqual(result.value(0, "c_bigint"), .int(-9_223_372_036_854_775_808))
            XCTAssertEqual(result.value(0, "c_real"), .double(.infinity))
            XCTAssertEqual(result.value(0, "c_double"), .double(-.infinity))
            XCTAssertEqual(result.value(0, "c_text"), .string("中文 👩‍👩‍👧‍👦 אבג é"))
            XCTAssertEqual(result.value(0, "c_blob"), .bytes(Data(count: 256)))
            XCTAssertEqual(result.value(0, "c_date"), .date(DBDate(year: 1, month: 1, day: 1)))
            XCTAssertEqual(result.value(0, "c_any"), .int(42), "an ANY column holds whatever it was given")
        }
    }

    func testOneMegabyteStringAndDeeplyNestedJSON() async throws {
        try await withConnection { connection in
            let result = try await connection.executeCollecting("SELECT c_text, c_json FROM all_types WHERE id = 4")
            XCTAssertEqual(result.rows[0][0].text?.utf8.count, 1_048_576)
            XCTAssertEqual(result.rows[0][1].text?.prefix(10), "{\"n\":{\"n\":")
        }
    }

    func testTextInATypedColumnKeepsItsStorageClassWhenItDoesNotFit() async throws {
        try await withConnection { connection in
            _ = try await connection.executeCollecting("CREATE TEMP TABLE loose (d DATE, b BOOLEAN, n INTEGER)")
            _ = try await connection.executeCollecting(
                "INSERT INTO loose VALUES ('not a date', 'maybe', 'twelve')")
            let result = try await connection.executeCollecting("SELECT d, b, n FROM loose")
            XCTAssertEqual(result.rows[0][0], .string("not a date"))
            XCTAssertEqual(result.rows[0][1], .string("maybe"))
            XCTAssertEqual(result.rows[0][2], .string("twelve"), "SQLite kept the text; so does the driver")
            _ = try await connection.executeCollecting("DROP TABLE loose")
        }
    }

    // MARK: - Streams and completions

    func testEventOrderAndBatching() async throws {
        try await withConnection { connection in
            var sawColumns = false
            var batches: [Int] = []
            var completions = 0
            var startIndexes: [Int] = []
            for try await event in connection.execute("SELECT id, name FROM big_table WHERE id <= 1200 ORDER BY id", parameters: []) {
                switch event {
                case .columns:
                    XCTAssertFalse(sawColumns, "columns arrive once")
                    XCTAssertTrue(batches.isEmpty, "columns arrive before rows")
                    sawColumns = true
                case let .rows(batch):
                    XCTAssertTrue(sawColumns)
                    XCTAssertLessThanOrEqual(batch.count, RowBatching.maxRows)
                    startIndexes.append(batch.startIndex)
                    batches.append(batch.count)
                case let .complete(completion):
                    completions += 1
                    XCTAssertEqual(completion.affectedRows, 1_200)
                    XCTAssertEqual(completion.serverTag, "SELECT 1200")
                }
            }
            XCTAssertEqual(completions, 1)
            XCTAssertEqual(batches.reduce(0, +), 1_200)
            XCTAssertEqual(batches, [500, 500, 200])
            XCTAssertEqual(startIndexes, [0, 500, 1_000])
        }
    }

    func testAffectedRowsLastInsertIDAndSilentDDL() async throws {
        try await withConnection { connection in
            _ = try await connection.executeCollecting("DROP TABLE IF EXISTS probe_rows")
            let create = try await connection.executeCollecting(
                "CREATE TABLE probe_rows (id INTEGER PRIMARY KEY AUTOINCREMENT, v TEXT)")
            XCTAssertNil(create.completion.affectedRows, "DDL changes no rows and must not borrow the last count")
            XCTAssertEqual(create.completion.serverTag, "CREATE")
            let insert = try await connection.executeCollecting("INSERT INTO probe_rows (v) VALUES ('a'), ('b'), ('c')")
            XCTAssertEqual(insert.completion.affectedRows, 3)
            XCTAssertEqual(insert.completion.lastInsertID, 3)
            XCTAssertEqual(insert.completion.serverTag, "INSERT 3")
            let update = try await connection.executeCollecting("UPDATE probe_rows SET v = upper(v) WHERE id > 1")
            XCTAssertEqual(update.completion.affectedRows, 2)
            XCTAssertNil(update.completion.lastInsertID)
            let pragma = try await connection.executeCollecting("PRAGMA foreign_keys = ON")
            XCTAssertNil(pragma.completion.affectedRows)
            let returning = try await connection.executeCollecting("INSERT INTO probe_rows (v) VALUES ('d') RETURNING id, v")
            XCTAssertEqual(returning.rows, [[.int(4), .string("d")]])
            let delete = try await connection.executeCollecting("DELETE FROM probe_rows")
            XCTAssertEqual(delete.completion.affectedRows, 4)
            _ = try await connection.executeCollecting("DROP TABLE probe_rows")
        }
    }

    /// `affectedRows` counts the rows the statement changed itself, not the rows a
    /// trigger or `ON DELETE CASCADE` changed with it: the grid checks for exactly one,
    /// and a parent with three children was reported as four and rolled back.
    func testAffectedRowsCountsDirectRowsNotCascadesOrTriggers() async throws {
        try await withConnection { connection in
            _ = try await connection.executeCollecting("DROP TABLE IF EXISTS probe_child")
            _ = try await connection.executeCollecting("DROP TABLE IF EXISTS probe_parent")
            _ = try await connection.executeCollecting("DROP TABLE IF EXISTS probe_audit")
            _ = try await connection.executeCollecting("CREATE TABLE probe_parent (id INTEGER PRIMARY KEY, v TEXT)")
            _ = try await connection.executeCollecting(
                "CREATE TABLE probe_child (id INTEGER PRIMARY KEY, parent INTEGER REFERENCES probe_parent(id) ON DELETE CASCADE)"
            )
            _ = try await connection.executeCollecting("CREATE TABLE probe_audit (note TEXT)")
            _ = try await connection.executeCollecting(
                "CREATE TRIGGER probe_after_update AFTER UPDATE ON probe_parent BEGIN INSERT INTO probe_audit VALUES ('u'); END"
            )
            _ = try await connection.executeCollecting("INSERT INTO probe_parent VALUES (1, 'a'), (2, 'b')")
            _ = try await connection.executeCollecting("INSERT INTO probe_child VALUES (10, 1), (11, 1), (12, 1)")

            let update = try await connection.executeCollecting("UPDATE probe_parent SET v = 'z' WHERE id = 1")
            XCTAssertEqual(update.completion.affectedRows, 1, "the trigger's insert is not the statement's own row")
            let delete = try await connection.executeCollecting("DELETE FROM probe_parent WHERE id = 1")
            XCTAssertEqual(delete.completion.affectedRows, 1, "three cascaded children are not the statement's own rows")
            let children = try await connection.executeCollecting("SELECT count(*) FROM probe_child")
            XCTAssertEqual(children.firstText, "0", "the cascade itself still happened")

            _ = try await connection.executeCollecting("DROP TABLE probe_child")
            _ = try await connection.executeCollecting("DROP TABLE probe_parent")
            _ = try await connection.executeCollecting("DROP TABLE probe_audit")
        }
    }

    func testParametersAreBoundNotInterpolated() async throws {
        try await withConnection { connection in
            let hostile = "x'; DROP TABLE smoke; --"
            let result = try await connection.executeCollecting(
                "SELECT ? AS s, ? AS i, ? AS d, ? AS b, ? AS n, ? AS blob",
                parameters: [.string(hostile), .int(-7), .double(2.5), .bool(true), .null, .bytes(Data([1, 2, 3]))])
            XCTAssertEqual(result.rows[0], [.string(hostile), .int(-7), .double(2.5), .int(1), .null, .bytes(Data([1, 2, 3]))])
            let smoke = try await connection.executeCollecting("SELECT count(*) FROM smoke")
            XCTAssertEqual(smoke.firstText, "3")

            do {
                _ = try await connection.executeCollecting("SELECT ?, ?", parameters: [.int(1)])
                XCTFail("a parameter count mismatch must be reported")
            } catch let DBError.protocolError(message) {
                XCTAssertTrue(message.contains("2 parameters"), message)
            }
        }
    }

    func testServerErrorsArriveVerbatimWithCodeAndPosition() async throws {
        try await withConnection { connection in
            do {
                _ = try await connection.executeCollecting("SELECT id FROM smoke WHERE id = 1 ORDR BY id")
                XCTFail("expected a syntax error")
            } catch let DBError.server(error) {
                XCTAssertEqual(error.message, "near \"ORDR\": syntax error")
                XCTAssertEqual(error.code, Int(SQLITE_ERROR))
                XCTAssertEqual(error.position, 35, "one-based character offset of the offending token")
            }
            do {
                _ = try await connection.executeCollecting("INSERT INTO smoke (id, name) VALUES (1, 'again')")
                XCTFail("expected a constraint error")
            } catch let DBError.server(error) {
                XCTAssertEqual(error.message, "UNIQUE constraint failed: smoke.id")
                // Extended code: SQLITE_CONSTRAINT (19) | (6 << 8) = SQLITE_CONSTRAINT_PRIMARYKEY.
                XCTAssertEqual(error.code, 1_555)
            }
        }
    }

    func testAMultibyteStatementReportsItsErrorPositionInCharacters() async throws {
        try await withConnection { connection in
            do {
                _ = try await connection.executeCollecting("SELECT 'ünïcödé — 日本語' FROM smoke WHERE bogus_column = 1 ORDR")
                XCTFail("expected a syntax error")
            } catch let DBError.server(error) {
                // The offset SQLite reports is in bytes; the position is in characters.
                let sql = "SELECT 'ünïcödé — 日本語' FROM smoke WHERE bogus_column = 1 ORDR"
                XCTAssertEqual(error.position, sql.distance(from: sql.startIndex, to: sql.range(of: "ORDR")!.lowerBound) + 1)
            }
        }
    }

    func testConnectionIsUsableAfterAnError() async throws {
        try await withConnection { connection in
            _ = try? await connection.executeCollecting("SELECT * FROM no_such_table")
            let result = try await connection.executeCollecting("SELECT 1")
            XCTAssertEqual(result.firstText, "1")
        }
    }

    // MARK: - Cancel and timeout

    /// SPEC §13.3: cancel returns within a second and the connection is reusable.
    func testInterruptCancelsAndLeavesTheConnectionUsable() async throws {
        try await withConnection { connection in
            let slow = "WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM r WHERE n < 300000000) SELECT count(*) FROM r"
            let started = ContinuousClock.now
            let task = Task { () -> DBError? in
                do {
                    _ = try await connection.executeCollecting(slow)
                    return nil
                } catch let error as DBError {
                    return error
                } catch {
                    return .protocolError("\(error)")
                }
            }
            try await Task.sleep(for: .milliseconds(150))
            await connection.cancelCurrent()
            let outcome = await task.value
            XCTAssertEqual(outcome, .cancelled)
            XCTAssertLessThan(started.duration(to: .now), .seconds(3))
            let probe = try await connection.executeCollecting("SELECT 1")
            XCTAssertEqual(probe.firstText, "1")
        }
    }

    func testCancellingTheConsumingTaskStopsTheStatement() async throws {
        try await withConnection { connection in
            let slow = "WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM r WHERE n < 300000000) SELECT count(*) FROM r"
            let task = Task {
                for try await _ in connection.execute(slow, parameters: []) {}
            }
            try await Task.sleep(for: .milliseconds(150))
            task.cancel()
            _ = try? await task.value
            let probe = try await connection.executeCollecting("SELECT 1")
            XCTAssertEqual(probe.firstText, "1")
        }
    }

    func testStatementTimeoutSurfacesAsTimeout() async throws {
        try await withConnection(statementTimeout: .milliseconds(200)) { connection in
            let slow = "WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM r WHERE n < 300000000) SELECT count(*) FROM r"
            do {
                _ = try await connection.executeCollecting(slow)
                XCTFail("expected a timeout")
            } catch let DBError.timeout(after) {
                XCTAssertEqual(after, .milliseconds(200))
            }
            let probe = try await connection.executeCollecting("SELECT 1")
            XCTAssertEqual(probe.firstText, "1")
        }
    }

    // MARK: - Transactions

    func testTransactionsCommitAndRollBack() async throws {
        try await withConnection { connection in
            _ = try await connection.executeCollecting("DROP TABLE IF EXISTS tx_probe")
            _ = try await connection.executeCollecting("CREATE TABLE tx_probe (id INTEGER PRIMARY KEY)")
            let inTransaction = await connection.isInTransaction
            XCTAssertFalse(inTransaction)
            try await connection.beginTransaction()
            let open = await connection.isInTransaction
            XCTAssertTrue(open)
            _ = try await connection.executeCollecting("INSERT INTO tx_probe VALUES (1)")
            try await connection.rollback()
            let afterRollback = try await connection.executeCollecting("SELECT count(*) FROM tx_probe").firstText
            XCTAssertEqual(afterRollback, "0")

            // A BEGIN the user typed counts too.
            _ = try await connection.executeCollecting("BEGIN")
            let typed = await connection.isInTransaction
            XCTAssertTrue(typed)
            _ = try await connection.executeCollecting("INSERT INTO tx_probe VALUES (2)")
            try await connection.commit()
            let closed = await connection.isInTransaction
            XCTAssertFalse(closed)
            let afterCommit = try await connection.executeCollecting("SELECT count(*) FROM tx_probe").firstText
            XCTAssertEqual(afterCommit, "1")
            _ = try await connection.executeCollecting("DROP TABLE tx_probe")
        }
    }

    // MARK: - Introspection

    func testIntrospectionSnapshot() async throws {
        try await withConnection { connection in
            let introspector = connection.introspector
            let databases = try await introspector.databases()
            XCTAssertEqual(databases.map(\.name), ["main"])
            XCTAssertTrue(databases[0].isCurrent)
            let schemas = try await introspector.schemas(in: "main")
            XCTAssertEqual(schemas.map(\.ref), [SchemaRef.sqlite])

            let tables = try await introspector.tables(in: .sqlite)
            let byName = Dictionary(uniqueKeysWithValues: tables.map { ($0.name, $0) })
            for name in ["smoke", "all_types", "big_table", "customers", "orders", "composite_pk", "uuid_pk", "no_pk", "checked_values", "audited"] {
                XCTAssertEqual(byName[name]?.kind, .table, name)
            }
            XCTAssertEqual(byName["customer_totals"]?.kind, .view)
            XCTAssertNil(byName["sqlite_sequence"], "SQLite's own tables stay out of the list")
            XCTAssertEqual(byName["big_table"]?.approximateRowCount, 1_000_000, "from sqlite_stat1 after ANALYZE")
            XCTAssertNotNil(byName["big_table"]?.sizeBytes, "dbstat is compiled into Apple's SQLite")
            let bigEstimate = try await introspector.approximateRowCount(table("big_table"))
            XCTAssertEqual(bigEstimate, 1_000_000)
            let smokeEstimate = try await introspector.approximateRowCount(table("smoke"))
            XCTAssertNil(smokeEstimate, "never analysed, so no estimate")
            let nowhere = try await introspector.tables(in: SchemaRef(database: "nowhere", schema: "nowhere"))
            XCTAssertEqual(nowhere, [])
            let routines = try await introspector.routines(in: .sqlite)
            XCTAssertEqual(routines, [])
        }
    }

    func testColumnIntrospectionDetails() async throws {
        try await withConnection { connection in
            let columns = try await connection.introspector.columns(of: table("all_types"))
            let byName = Dictionary(uniqueKeysWithValues: columns.map { ($0.name, $0) })
            XCTAssertEqual(columns.first?.name, "id")
            XCTAssertEqual(byName["id"]?.isPrimaryKey, true)
            XCTAssertEqual(byName["id"]?.isAutoIncrement, true)
            XCTAssertEqual(byName["id"]?.isNullable, false)
            XCTAssertEqual(byName["c_bool"]?.kind, .bool)
            XCTAssertEqual(byName["c_bool"]?.nativeType, "BOOLEAN")
            XCTAssertEqual(byName["c_decimal"]?.nativeType, "DECIMAL(65, 30)")
            XCTAssertEqual(byName["c_decimal"]?.kind, .double, "numeric affinity stores a REAL")
            XCTAssertEqual(byName["c_datetime"]?.kind, .timestamp)
            XCTAssertEqual(byName["c_any"]?.nativeType, "ANY")
            XCTAssertEqual(byName["c_generated"]?.isGenerated, true)
            XCTAssertEqual(byName["c_generated"]?.kind, .int)
            XCTAssertEqual(byName["c_text"]?.isNullable, true)

            let customers = try await connection.introspector.columns(of: table("customers"))
            XCTAssertEqual(customers.first { $0.name == "tier" }?.defaultExpression, "'ok'")
        }
    }

    func testKeysIndexesAndForeignKeys() async throws {
        try await withConnection { connection in
            let introspector = connection.introspector
            let compositeKey = try await introspector.primaryKey(of: table("composite_pk"))
            XCTAssertEqual(compositeKey, ["org_id", "user_id"])
            let ordersKey = try await introspector.primaryKey(of: table("orders"))
            XCTAssertEqual(ordersKey, ["id"])
            let noKey = try await introspector.primaryKey(of: table("no_pk"))
            XCTAssertNil(noKey)
            let uniqueIdentity = try await introspector.rowIdentity(of: table("unique_not_null"))
            XCTAssertEqual(uniqueIdentity, ["code"])
            let noIdentity = try await introspector.rowIdentity(of: table("no_pk"))
            XCTAssertNil(noIdentity)

            let indexes = try await introspector.indexes(of: table("orders"))
            let byName = Dictionary(uniqueKeysWithValues: indexes.map { ($0.name, $0) })
            XCTAssertEqual(byName["orders_customer_idx"]?.columns, ["customer_id"])
            XCTAssertEqual(byName["orders_customer_idx"]?.isUnique, false)
            XCTAssertEqual(byName["orders_unique_customer_total"]?.columns, ["customer_id", "total"])
            XCTAssertEqual(byName["orders_unique_customer_total"]?.isUnique, true)
            XCTAssertEqual(byName["orders_unique_customer_total"]?.isNullableFree, true)

            let keys = try await introspector.foreignKeys(of: table("orders"))
            XCTAssertEqual(keys.count, 1)
            XCTAssertEqual(keys.first?.name, "orders_customer_fk")
            XCTAssertEqual(keys.first?.columns, ["customer_id"])
            XCTAssertEqual(keys.first?.referencedTable, table("customers"))
            XCTAssertEqual(keys.first?.referencedColumns, ["id"])
            XCTAssertEqual(keys.first?.onDelete, .cascade)
            XCTAssertEqual(keys.first?.onUpdate, .restrict)
        }
    }

    func testDDLComesFromSQLiteItselfAndCarriesTheIndexes() async throws {
        try await withConnection { connection in
            let ddl = try await connection.introspector.tableDDL(table("orders"))
            XCTAssertTrue(ddl.hasPrefix("CREATE TABLE orders ("), ddl)
            XCTAssertTrue(ddl.contains("CREATE INDEX orders_customer_idx ON orders (customer_id);"), ddl)
            XCTAssertTrue(ddl.contains("CREATE UNIQUE INDEX orders_unique_customer_total"), ddl)
            XCTAssertFalse(ddl.contains("CREATE TRIGGER"), "triggers are read on their own")
            do {
                _ = try await connection.introspector.tableDDL(table("no_such"))
                XCTFail("expected a missing-table error")
            } catch let DBError.server(error) {
                XCTAssertEqual(error.message, "no such table: no_such")
            }
        }
    }

    func testDesignerReadsCheckConstraintsAndTriggers() async throws {
        try await withConnection { connection in
            let introspector = connection.introspector
            let checks = try await introspector.checkConstraints(of: table("checked_values"))
            XCTAssertEqual(checks.map(\.name), ["quantity_positive", "label_not_blank"])
            XCTAssertEqual(checks.map(\.expression), ["quantity > 0", "label IS NULL OR length(label) > 0"])
            let inline = try await introspector.checkConstraints(of: table("customers"))
            XCTAssertEqual(inline.map(\.name), ["check_1"])
            XCTAssertEqual(inline.first?.expression, "tier IN ('sad', 'ok', 'happy')")

            let triggers = try await introspector.triggers(of: table("audited"))
            XCTAssertEqual(triggers.count, 1)
            let trigger = try XCTUnwrap(triggers.first)
            XCTAssertEqual(trigger.name, "audited_bump")
            XCTAssertEqual(trigger.timing, .before)
            XCTAssertEqual(trigger.events, [.update])
            XCTAssertEqual(trigger.condition, "OLD.id IS NOT NULL")
            XCTAssertTrue(trigger.body?.hasPrefix("BEGIN") ?? false, trigger.body ?? "nil")
            XCTAssertTrue(trigger.body?.hasSuffix("END") ?? false, trigger.body ?? "nil")
            let partitioning = try await introspector.partitioning(of: table("audited"))
            XCTAssertNil(partitioning)
            let collations = try await introspector.collations(in: "main")
            XCTAssertTrue(collations.map(\.name).contains("NOCASE"))
            XCTAssertTrue(collations.contains { $0.name == "BINARY" && $0.isDefault })
        }
    }

    func testServerReadsSayWhatAFileHasAndWhatItDoesNot() async throws {
        try await withConnection { connection in
            let server = try XCTUnwrap(connection.introspector.server)
            let activity = try await server.activity()
            XCTAssertEqual(activity.count, 1)
            XCTAssertTrue(activity[0].isCurrent)
            XCTAssertEqual(activity[0].id, connection.backendID)
            let variables = try await server.variables()
            XCTAssertTrue(variables.contains { $0.name == "sqlite_version" })
            XCTAssertTrue(variables.contains { $0.name == "page_size" && Int($0.value) != nil })
            XCTAssertTrue(variables.contains { $0.name == "foreign_keys" && $0.value == "1" })
            XCTAssertTrue(variables.contains { $0.category == "Compile option" })
            do {
                _ = try await server.users()
                XCTFail("SQLite has no accounts")
            } catch let DBError.protocolError(message) {
                XCTAssertTrue(message.contains("no user accounts"), message)
            }
            let view = try await server.viewDefinition(table("customer_totals"))
            XCTAssertTrue(view.hasPrefix("CREATE VIEW customer_totals AS"), view)
        }
    }

    func testForeignKeysAreEnforcedByDefaultAndOptional() async throws {
        try await withConnection { connection in
            do {
                _ = try await connection.executeCollecting("INSERT INTO orders (customer_id, total) VALUES (999, 1)")
                XCTFail("the foreign key must hold")
            } catch let DBError.server(error) {
                XCTAssertEqual(error.message, "FOREIGN KEY constraint failed")
            }
        }
        try await withConnection(options: [SQLiteDriver.OptionKey.foreignKeys: "false"]) { connection in
            _ = try await connection.executeCollecting("INSERT INTO orders (customer_id, total) VALUES (999, 1)")
            _ = try await connection.executeCollecting("DELETE FROM orders WHERE customer_id = 999")
        }
    }

    func testLowerAndUpperKnowMoreThanASCII() async throws {
        try await withConnection { connection in
            let result = try await connection.executeCollecting("SELECT lower('ÖRLD Straße'), upper('wörld'), lower(NULL)")
            XCTAssertEqual(result.rows[0][0], .string("örld straße"))
            XCTAssertEqual(result.rows[0][1], .string("WÖRLD"))
            XCTAssertEqual(result.rows[0][2], .null)
        }
    }

    // MARK: - Through the session

    func testReadOnlyIsHeldByTheFileNotTheClient() async throws {
        try await SQLiteFixture.prepare()
        var config = SQLiteDriver.connectionConfig(forFileAt: SQLiteFixture.path)
        config.readOnly = true
        let session = ConnectionSession(
            config: config, registry: DriverRegistry([.sqlite: SQLiteDriver.self]),
            secrets: EphemeralSecretStore(), logger: SQLiteFixture.logger)
        _ = try await session.connect()
        let (lease, connection) = try await session.lease()
        do {
            // Not a statement the client would recognise as a write.
            _ = try await connection.executeCollecting("WITH x AS (SELECT 1) INSERT INTO smoke (id, name) VALUES (99, 'x')")
            XCTFail("the guard must hold on the file")
        } catch let DBError.server(error) {
            XCTAssertEqual(error.message, "attempt to write a readonly database")
        }
        await session.release(lease)

        await session.setReadOnlyOverride(true)
        let (unlocked, writable) = try await session.lease()
        _ = try await writable.executeCollecting("INSERT INTO smoke (id, name) VALUES (99, 'x')")
        _ = try await writable.executeCollecting("DELETE FROM smoke WHERE id = 99")
        await session.release(unlocked)
        await session.disconnect()
    }

    func testAStructureChangeSQLiteCannotExpressRebuildsTheTableInOneTransaction() async throws {
        try await SQLiteFixture.prepare()
        let config = SQLiteDriver.connectionConfig(forFileAt: SQLiteFixture.path)
        let session = ConnectionSession(
            config: config, registry: DriverRegistry([.sqlite: SQLiteDriver.self]),
            secrets: EphemeralSecretStore(), logger: SQLiteFixture.logger)
        _ = try await session.connect()
        let (lease, connection) = try await session.lease()
        _ = try await connection.executeCollecting("DROP TABLE IF EXISTS rebuild_me")
        _ = try await connection.executeCollecting(
            "CREATE TABLE rebuild_me (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, qty INTEGER DEFAULT 1)")
        _ = try await connection.executeCollecting("CREATE INDEX rebuild_me_name ON rebuild_me (name)")
        _ = try await connection.executeCollecting("INSERT INTO rebuild_me (name, qty) VALUES ('a', 2), ('b', 3)")
        let loaded = try await TableDefinitionLoader.load(table("rebuild_me"), introspector: connection.introspector)
        let current = try XCTUnwrap(loaded)
        await session.release(lease)

        // Change a column's type and make another NOT NULL: neither is an ALTER TABLE SQLite has.
        var edited = current
        edited.columns[1].type = "VARCHAR(40)"
        edited.columns[1].isNullable = false
        edited.columns[2].type = "REAL"
        let generator = DDLGenerator(dialect: .sqlite)
        XCTAssertTrue(generator.sqliteNeedsRebuild(from: current, to: edited))
        let statements = generator.alter(from: current, to: edited)
        let sql = statements.map(\.sql).joined(separator: ";\n")
        XCTAssertTrue(sql.contains("PRAGMA defer_foreign_keys = ON"), sql)
        XCTAssertTrue(sql.contains("CREATE TABLE \"rebuild_me__tinker_rebuild\""), sql)
        XCTAssertTrue(sql.contains("\"id\" INTEGER PRIMARY KEY AUTOINCREMENT"), sql)
        XCTAssertTrue(sql.contains("INSERT INTO \"rebuild_me__tinker_rebuild\" (\"id\", \"name\", \"qty\")"), sql)
        XCTAssertTrue(sql.contains("DROP TABLE \"rebuild_me\""), sql)
        XCTAssertTrue(sql.contains("RENAME TO \"rebuild_me\""), sql)
        XCTAssertTrue(sql.contains("CREATE INDEX \"rebuild_me_name\" ON \"rebuild_me\" (\"name\")"), sql)

        let executor = DDLExecutor(session: session, dialect: .sqlite)
        XCTAssertTrue(executor.isTransactional)
        let result = try await executor.run(statements)
        XCTAssertTrue(result.isSuccess, result.errorText ?? "")

        let (check, verify) = try await session.lease()
        let columns = try await verify.introspector.columns(of: table("rebuild_me"))
        XCTAssertEqual(columns.map(\.nativeType), ["INTEGER", "VARCHAR(40)", "REAL"])
        XCTAssertEqual(columns[1].isNullable, false)
        XCTAssertEqual(columns[0].isAutoIncrement, true)
        let rows = try await verify.executeCollecting("SELECT id, name, qty FROM rebuild_me ORDER BY id")
        XCTAssertEqual(rows.rows, [[.int(1), .string("a"), .double(2)], [.int(2), .string("b"), .double(3)]])
        let rebuiltIndexes = try await verify.introspector.indexes(of: table("rebuild_me"))
        XCTAssertEqual(rebuiltIndexes.map(\.name), ["rebuild_me_name"])

        // A change SQLite can express stays an ALTER TABLE.
        var renamed = edited
        renamed.columns[1].name = "title"
        renamed.columns.append(ColumnDefinition(name: "note", type: "TEXT"))
        XCTAssertFalse(generator.sqliteNeedsRebuild(from: edited, to: renamed))
        let simple = generator.alter(from: edited, to: renamed).map(\.sql)
        XCTAssertEqual(
            simple,
            [
                "ALTER TABLE \"rebuild_me\" RENAME COLUMN \"name\" TO \"title\"",
                "ALTER TABLE \"rebuild_me\" ADD COLUMN \"note\" TEXT",
            ], simple.joined(separator: "\n"))
        _ = try await verify.executeCollecting("DROP TABLE rebuild_me")
        await session.release(check)
        await session.disconnect()
    }

    func testLargeResultStreamsInBatchesWithoutBeingHeld() async throws {
        try await withConnection { connection in
            var rows = 0
            var batches = 0
            var largest = 0
            for try await event in connection.execute("SELECT id, name, amount, flag, created FROM big_table WHERE id <= 200000", parameters: []) {
                if case let .rows(batch) = event {
                    rows += batch.count
                    batches += 1
                    largest = max(largest, batch.count)
                }
            }
            XCTAssertEqual(rows, 200_000)
            XCTAssertLessThanOrEqual(largest, RowBatching.maxRows)
            XCTAssertGreaterThanOrEqual(batches, 400)
        }
    }

    func testSpatialColumnsDecodeToPlaceableShapes() async throws {
        try await withConnection { connection in
            let result = try await connection.executeCollecting("SELECT geom, shape FROM spatial_places WHERE id = 1")
            let geometry = try XCTUnwrap(GeometryParser.parse(result.rows[0][0], dialect: .sqlite))
            guard case let .point(point) = geometry.shape else { return XCTFail("expected a point, got \(geometry)") }
            XCTAssertEqual(point.longitude, 106.8272, accuracy: 0.0001)
            XCTAssertEqual(point.latitude, -6.1754, accuracy: 0.0001)
            XCTAssertNotNil(GeometryParser.parse(result.rows[0][1], dialect: .sqlite))
        }
    }
}

// MARK: - Unit tests

final class SQLiteCodecTests: XCTestCase {
    func testDeclaredTypesReduceToTheKindsTheAppReads() {
        typealias D = SQLiteValueCodec.DeclaredType
        XCTAssertEqual(D("INTEGER"), .integer)
        XCTAssertEqual(D("int"), .integer)
        XCTAssertEqual(D("BIGINT UNSIGNED"), .integer)
        XCTAssertEqual(D("BOOLEAN"), .bool)
        XCTAssertEqual(D("bool"), .bool)
        XCTAssertEqual(D("DATETIME"), .timestamp)
        XCTAssertEqual(D("TIMESTAMP WITH TIME ZONE"), .timestamp)
        XCTAssertEqual(D("DATE"), .date)
        XCTAssertEqual(D("TIME"), .time)
        XCTAssertEqual(D("JSON"), .json)
        XCTAssertEqual(D("UUID"), .uuid)
        XCTAssertEqual(D("DECIMAL(10,2)"), .numeric)
        XCTAssertEqual(D("NUMERIC"), .numeric)
        XCTAssertEqual(D("DECIMAL(10,2)").kind, .double, "numeric affinity holds a REAL, never an exact decimal")
        XCTAssertEqual(D("REAL"), .real)
        XCTAssertEqual(D("DOUBLE PRECISION"), .real)
        XCTAssertEqual(D("VARCHAR(255)"), .text)
        XCTAssertEqual(D("CLOB"), .text)
        XCTAssertEqual(D("BLOB"), .blob)
        XCTAssertEqual(D(nil), .other)
        XCTAssertEqual(D(""), .other)
        XCTAssertEqual(D("ANY"), .other)
        XCTAssertEqual(D("DATETIME").kind, .timestamp)
        XCTAssertEqual(D("other").kind, .string)
    }

    func testTemporalTextIsParsedWithoutFoundationDate() {
        XCTAssertEqual(TemporalParser.date("2024-03-10"), DBDate(year: 2024, month: 3, day: 10))
        XCTAssertNil(TemporalParser.date("2024-13-10"))
        XCTAssertNil(TemporalParser.date("10/03/2024"))
        XCTAssertEqual(TemporalParser.time("02:30"), DBTime(hour: 2, minute: 30, second: 0))
        XCTAssertEqual(TemporalParser.time("02:30:15.5"), DBTime(hour: 2, minute: 30, second: 15, microsecond: 500_000))
        XCTAssertEqual(
            TemporalParser.time("02:30:15+07:00"), DBTime(hour: 2, minute: 30, second: 15, tzOffsetSeconds: 7 * 3_600))
        XCTAssertEqual(TemporalParser.time("23:59:59Z")?.tzOffsetSeconds, 0)
        XCTAssertNil(TemporalParser.time("25:00"))
        let stamp = TemporalParser.timestamp("2024-03-10T02:30:00.123456-05:30")
        XCTAssertEqual(stamp?.date, DBDate(year: 2024, month: 3, day: 10))
        XCTAssertEqual(stamp?.time.microsecond, 123_456)
        XCTAssertEqual(stamp?.time.tzOffsetSeconds, -(5 * 3_600 + 30 * 60))
        XCTAssertEqual(stamp?.hasTimeZone, true)
        XCTAssertEqual(stamp?.serverText, "2024-03-10T02:30:00.123456-05:30")
        XCTAssertEqual(TemporalParser.timestamp("2024-03-10 02:30:00")?.hasTimeZone, false)
        XCTAssertNil(TemporalParser.timestamp("2024-03-10"))
    }

    func testErrorOffsetsBecomeCharacterPositions() {
        XCTAssertEqual(SQLiteErrorMapper.position(ofByte: 0, in: "SELECT"), 1)
        XCTAssertEqual(SQLiteErrorMapper.position(ofByte: -1, in: "SELECT"), nil)
        // "é" is two bytes; the position counts it as one character.
        XCTAssertEqual(SQLiteErrorMapper.position(ofByte: 3, in: "'é' x"), 3)
        XCTAssertEqual(SQLiteErrorMapper.map(code: SQLITE_INTERRUPT, message: "interrupted", offset: -1, sql: nil, timedOut: nil), .cancelled)
        XCTAssertEqual(
            SQLiteErrorMapper.map(code: SQLITE_INTERRUPT, message: "interrupted", offset: -1, sql: nil, timedOut: .seconds(2)),
            .timeout(after: .seconds(2)))
    }

    func testDDLReaderParsesWhatSQLiteKeepsOnlyAsText() {
        let ddl = """
            CREATE TABLE t (
                id INTEGER PRIMARY KEY,
                qty INTEGER CHECK (qty > 0),
                label TEXT,
                CONSTRAINT label_ok CHECK (label IS NULL OR length(label) > 0),
                CONSTRAINT parent_fk FOREIGN KEY (id) REFERENCES p (id)
            )
            """
        let checks = SQLiteDDLReader.checkConstraints(in: ddl)
        XCTAssertEqual(checks.map(\.name), ["check_1", "label_ok"])
        XCTAssertEqual(checks.map(\.expression), ["qty > 0", "label IS NULL OR length(label) > 0"])
        XCTAssertEqual(SQLiteDDLReader.constraintNames(in: ddl, kind: "FOREIGN"), ["parent_fk"])
        XCTAssertEqual(
            SQLiteDDLReader.partialIndexPredicate("CREATE INDEX i ON t (a) WHERE a > 0 AND b IS NOT NULL;"),
            "a > 0 AND b IS NOT NULL")
        XCTAssertNil(SQLiteDDLReader.partialIndexPredicate("CREATE INDEX i ON t (a)"))

        let trigger = SQLiteDDLReader.trigger(
            named: "tr",
            from: "CREATE TRIGGER tr AFTER INSERT ON t FOR EACH ROW WHEN (NEW.qty > 10) BEGIN UPDATE t SET label = 'big' WHERE id = NEW.id; END")
        XCTAssertEqual(trigger?.timing, .after)
        XCTAssertEqual(trigger?.events, [.insert])
        XCTAssertEqual(trigger?.condition, "NEW.qty > 10")
        XCTAssertEqual(trigger?.body, "BEGIN UPDATE t SET label = 'big' WHERE id = NEW.id; END")
        let instead = SQLiteDDLReader.trigger(named: "v", from: "CREATE TRIGGER v INSTEAD OF DELETE ON some_view BEGIN SELECT 1; END")
        XCTAssertEqual(instead?.timing, .insteadOf)
        XCTAssertEqual(instead?.events, [.delete])
    }
}
