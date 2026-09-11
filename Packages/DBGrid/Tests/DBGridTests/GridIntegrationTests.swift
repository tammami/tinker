import DBCore
import DBMySQL
import DBPostgres
import DBSQLite
import DBSQL
import DBTestKit
import Logging
import XCTest

@testable import DBGrid

/// The grid's data path against every configured server: paging, sorting, filtering,
/// editing and the commit rules that protect the user's data (SPEC §12.6).
///
/// Both engines run the same checks, which is how SPEC §16 Phase 6's "identical feature
/// matrix, zero UI changes" requirement is verified: the grid is handed a different driver
/// and nothing else changes.
@MainActor
final class GridIntegrationTests: XCTestCase {
    var logger: Logger {
        var logger = Logger(label: "test.grid")
        logger.logLevel = .critical
        return logger
    }

    /// Every configured server of every engine. SQLite is a temporary file and is always
    /// there, so this never skips.
    static var registry: DriverRegistry {
        DriverRegistry([.postgresql: PostgresDriver.self, .mysql: MySQLDriver.self, .sqlite: SQLiteDriver.self])
    }

    func allServers() async throws -> [TestServer] {
        let postgres = try TestEnvironment.servers(for: .postgresql)
        let mysql = try TestEnvironment.servers(for: .mysql)
        let sqlite = try TestEnvironment.servers(for: .sqlite)
        if !sqlite.isEmpty { try await SQLiteFixtures.prepare() }
        let all = postgres + mysql + sqlite
        if all.isEmpty {
            throw XCTSkip("no test server is configured and SQLite is disabled")
        }
        return all
    }

    func withSession(
        _ body: (ConnectionSession, TestServer) async throws -> Void
    ) async throws {
        for server in try await allServers() {
            let dialect = server.engine.dialect
            let config = ConnectionConfig(
                name: "grid-test", dialect: dialect,
                host: server.host, port: server.port, user: server.user,
                database: server.database
            )
            let secrets = EphemeralSecretStore()
            var withPassword = config
            if let password = server.password {
                let reference = SecretRef.forConnection(config.id, field: "password")
                try await secrets.setSecret(password, for: reference)
                withPassword.passwordRef = reference
            }
            let session = ConnectionSession(
                config: withPassword,
                registry: Self.registry,
                secrets: secrets,
                logger: logger
            )
            do {
                try await body(session, server)
            } catch {
                await session.disconnect()
                throw error
            }
            await session.disconnect()
        }
    }

    func makeModel(
        session: ConnectionSession,
        table: TableRef,
        identity: [String],
        identityKind: DBValueKind? = .int
    ) -> GridModel {
        let dialect = session.config.dialect
        return GridModel(
            source: .table(table),
            dialect: dialect,
            loader: SessionGridLoader(session: session, table: table, dialect: dialect),
            identityColumns: identity,
            identityKind: identityKind
        )
    }

    /// A table reference for whichever engine the session speaks: MySQL has no schema
    /// layer, so its pseudo-schema is the database's own name.
    func table(_ name: String, in server: TestServer) -> TableRef {
        server.table(name)
    }

    /// The statement for the server's engine.
    func sql(_ server: TestServer, pg: String, mysql: String, sqlite: String) -> String {
        switch server.engine {
        case .postgresql: pg
        case .mysql: mysql
        case .sqlite: sqlite
        }
    }

    // MARK: - Value fidelity through the grid (SPEC §5, §17.1)

    /// Text with every awkward character, and a decimal with trailing zeros, typed into
    /// the grid, committed through bound parameters, and read back exactly: quotes and
    /// backslashes are not doubled or eaten, newlines survive, `1.1000` stays `1.1000`
    /// where the engine has an exact decimal.
    func testAwkwardTextAndDecimalScaleSurviveTheGridCommit() async throws {
        try await withSession { session, server in
            let awkward = "it's \"quoted\" \\ back\\slash\nline two\ttab -- not a comment; ünïcödé 日本語 🚀"
            try await session.withLease { setup in
                _ = try await setup.executeCollecting("DROP TABLE IF EXISTS grid_fidelity_probe")
                _ = try await setup.executeCollecting(
                    self.sql(
                        server,
                        pg: "CREATE TABLE grid_fidelity_probe (id integer PRIMARY KEY, t text, d numeric(12,4))",
                        mysql: "CREATE TABLE grid_fidelity_probe (id INT PRIMARY KEY, t TEXT, d DECIMAL(12,4))",
                        sqlite: "CREATE TABLE grid_fidelity_probe (id INTEGER PRIMARY KEY, t TEXT, d TEXT)"))
            }
            let table = self.table("grid_fidelity_probe", in: server)
            let model = self.makeModel(session: session, table: table, identity: ["id"])
            await model.load(page: 0)
            let insert = try XCTUnwrap(model.addRow())
            model.edits.setInsertValue(.int(1), id: insert.id, column: "id")
            model.edits.setInsertValue(.string(awkward), id: insert.id, column: "t")
            model.edits.setInsertValue(.decimal("1.1000"), id: insert.id, column: "d")
            let result = try await model.commit(using: SessionStatementRunner(session: session))
            XCTAssertEqual(result.statementCount, 1)

            let read = try await session.withLease { connection in
                try await connection.executeCollecting("SELECT t, d FROM grid_fidelity_probe WHERE id = 1")
            }
            XCTAssertEqual(read.rows.first?.first, .string(awkward), "the text came back changed on \(server.engine)")
            switch server.engine {
            case .postgresql, .mysql:
                XCTAssertEqual(read.rows.first?.last, .decimal("1.1000"), "the scale is the column's, not the value's")
            case .sqlite:
                // SQLite has no exact decimal (ADR-0037); a TEXT column keeps the text.
                XCTAssertEqual(read.rows.first?.last?.text, "1.1000")
            }

            // And an edit of the same cell through the UPDATE path, keyed by the original id.
            await model.reload()
            let row = (0 ..< model.rowCount).first { model.value(row: $0, column: 0) == .int(1) } ?? 0
            model.setValue(.string(awkward + " again"), row: row, column: 1)
            _ = try await model.commit(using: SessionStatementRunner(session: session))
            let again = try await session.withLease { connection in
                try await connection.executeCollecting("SELECT t FROM grid_fidelity_probe WHERE id = 1")
            }
            XCTAssertEqual(again.rows.first?.first, .string(awkward + " again"))
            try await session.withLease { cleanup in
                _ = try await cleanup.executeCollecting("DROP TABLE grid_fidelity_probe")
            }
        }
    }

    // MARK: - Recovery (SPEC §9.6)

    /// A pooled connection killed from outside — a DBA, a failover, a VPN drop — is found
    /// dead by the next lease and replaced; the session carries on with no help.
    func testAKilledBackendIsReplacedOnTheNextLease() async throws {
        try await withSession { session, server in
            guard server.engine != .sqlite else { return }  // a file has no backend to kill
            let (lease, connection) = try await session.lease()
            let victim = connection.backendID
            await session.release(lease)
            let pooledBefore = await session.pooledConnectionCount
            XCTAssertEqual(pooledBefore, 1)

            let killer = try await Self.registry.connect(server.resolvedConfig(), logger: logger)
            switch server.engine {
            case .postgresql:
                _ = try await killer.executeCollecting("SELECT pg_terminate_backend(\(Int32(victim) ?? -1))")
            case .mysql:
                _ = try await killer.executeCollecting("KILL CONNECTION \(Int(victim) ?? -1)")
            case .sqlite:
                break
            }
            await killer.close()
            // The kill is asynchronous on the server; give the socket a moment to close.
            try await Task.sleep(for: .milliseconds(300))

            let (again, replacement) = try await session.lease()
            XCTAssertNotEqual(replacement.backendID, victim, "the dead connection was handed out again")
            let answer = try await replacement.executeCollecting("SELECT 1")
            XCTAssertEqual(answer.firstText, "1")
            await session.release(again)
            let pooledAfter = await session.pooledConnectionCount
            XCTAssertEqual(pooledAfter, 1, "the dead connection should have been dropped, not kept beside the new one")
            let state = await session.state
            XCTAssertEqual(state, .connected)
        }
    }

    // MARK: - Paging

    /// SPEC §12.6: the first page of a million-row table arrives quickly.
    func testFirstPageOfAMillionRowsIsFast() async throws {
        try await withSession { session, server in
            let table = self.table("big_table", in: server)
            let model = self.makeModel(session: session, table: table, identity: ["id"])
            let started = ContinuousClock.now
            await model.load(page: 0)
            let elapsed = started.duration(to: .now)

            XCTAssertNil(model.lastError)
            XCTAssertEqual(model.rowCount, 1_000)
            XCTAssertEqual(model.columns.map(\.name), ["id", "name", "amount", "flag", "created"])
            XCTAssertNotNil(model.value(row: 0, column: 3), "the boolean column decoded")
            XCTAssertEqual(model.value(row: 0, column: 0), .int(1))
            XCTAssertLessThan(elapsed, .milliseconds(500), "first page took \(elapsed)")
            TestLog.note("grid: first page of big_table on \(server.engine.rawValue) in \(elapsed)")
        }
    }

    /// Scrolling deep into the table stays constant-cost by switching to a keyset cursor.
    func testDeepPagingUsesAKeysetCursorAndStaysCorrect() async throws {
        try await withSession { session, server in
            let table = self.table("big_table", in: server)
            let model = self.makeModel(session: session, table: table, identity: ["id"])
            for page in 0 ... 52 { await model.load(page: page) }

            XCTAssertEqual(model.strategy(forPage: 52), .keyset(column: "id"))
            // Row indices still line up with the values the fixture generated.
            XCTAssertEqual(model.value(row: 0, column: 0), .int(1))
            XCTAssertEqual(model.value(row: 50_000, column: 0), .int(50_001))
            XCTAssertEqual(model.value(row: 52_999, column: 0), .int(53_000))
        }
    }

    func testMemoryStaysBoundedWhileScrollingTheWholeTable() async throws {
        try await withSession { session, server in
            let table = self.table("big_table", in: server)
            let dialect = session.config.dialect
            let model = GridModel(
                source: .table(table), dialect: dialect,
                loader: SessionGridLoader(session: session, table: table, dialect: dialect),
                identityColumns: ["id"], identityKind: .int,
                buffer: RowBuffer(pageSize: 1_000, rowCapacity: 20_000, residentPageRadius: 5)
            )
            for page in stride(from: 0, to: 120, by: 1) {
                await model.load(page: page)
            }
            XCTAssertNil(model.lastError)
            XCTAssertLessThanOrEqual(
                model.buffer.count, 20_000,
                "the buffer held \(model.buffer.count) rows, past its cap"
            )
            // What was just loaded is still there, so scrolling never shows blanks.
            XCTAssertNotNil(
                model.buffer.row(at: 119_000),
                "on \(server.engine.rawValue), resident pages are \(model.buffer.loadedPages.sorted())"
            )
        }
    }

    // MARK: - Sorting and filtering

    func testServerSideSortAndFilter() async throws {
        try await withSession { session, server in
            let table = self.table("big_table", in: server)
            let model = self.makeModel(session: session, table: table, identity: ["id"])
            await model.load(page: 0)

            await model.setSort([PagePlanner.SortTerm(column: "id", ascending: false)])
            XCTAssertEqual(model.value(row: 0, column: 0), .int(1_000_000))

            await model.setFilter([FilterRule(column: "flag", op: .equal, values: [.bool(true)])])
            XCTAssertNil(model.lastError)
            // Every loaded row matches, and `flag` is true for even ids in the fixture.
            for row in 0 ..< 10 {
                XCTAssertEqual(model.value(row: row, column: 3), .bool(true))
            }
        }
    }

    func testFilterValuesAreBoundNotInterpolated() async throws {
        try await withSession { session, server in
            let table = self.table("big_table", in: server)
            let model = self.makeModel(session: session, table: table, identity: ["id"])
            await model.setFilter([
                FilterRule(column: "name", op: .equal, values: [.string("'; DROP TABLE big_table; --")])
            ])
            XCTAssertNil(model.lastError)
            XCTAssertEqual(model.rowCount, 0)

            // The table the injection targeted is intact.
            let (lease, connection) = try await session.lease()
            let count = try await connection.executeCollecting("SELECT count(*) FROM big_table")
            await session.release(lease)
            XCTAssertEqual(count.firstText, "1000000")
        }
    }

    // MARK: - Editing

    func testEditingAndCommittingTwoRows() async throws {
        try await withSession { session, server in
            let (setupLease, setup) = try await session.lease()
            _ = try await setup.executeCollecting("DROP TABLE IF EXISTS grid_edit_probe")
            _ = try await setup.executeCollecting(
                self.sql(
                    server,
                    pg: "CREATE TABLE grid_edit_probe (id integer PRIMARY KEY, name text, age integer)",
                    mysql: "CREATE TABLE grid_edit_probe (id INT PRIMARY KEY, name VARCHAR(50), age INT)",
                    sqlite: "CREATE TABLE grid_edit_probe (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)")
            )
            _ = try await setup.executeCollecting(
                "INSERT INTO grid_edit_probe VALUES (1, 'a', 29), (2, 'b', 41)"
            )
            await session.release(setupLease)

            let table = self.table("grid_edit_probe", in: server)
            let model = self.makeModel(session: session, table: table, identity: ["id"])
            await model.load(page: 0)
            XCTAssertTrue(model.isEditable)

            // Three cells across two rows.
            XCTAssertTrue(model.setValue(.string("alpha"), row: 0, column: 1))
            XCTAssertTrue(model.setValue(.int(30), row: 0, column: 2))
            XCTAssertTrue(model.setValue(.string("beta"), row: 1, column: 1))

            let statements = try model.pendingStatements()
            XCTAssertEqual(statements.count, 2, "two rows should produce two UPDATEs")

            let runner = SessionStatementRunner(session: session)
            let result = try await model.commit(using: runner)
            XCTAssertEqual(result.statementCount, 2)
            XCTAssertEqual(result.totalAffectedRows, 2)
            XCTAssertTrue(model.edits.isEmpty)

            await model.reload()
            XCTAssertEqual(model.value(row: 0, column: 1), .string("alpha"))
            XCTAssertEqual(model.value(row: 0, column: 2), .int(30))
            XCTAssertEqual(model.value(row: 1, column: 1), .string("beta"))

            let (cleanupLease, cleanup) = try await session.lease()
            _ = try await cleanup.executeCollecting("DROP TABLE grid_edit_probe")
            await session.release(cleanupLease)
        }
    }

    /// SPEC §12.6: a row changed by someone else since load must not be overwritten.
    func testConcurrentModificationFailsTheCommitAndWritesNothing() async throws {
        try await withSession { session, server in
            let (setupLease, setup) = try await session.lease()
            _ = try await setup.executeCollecting("DROP TABLE IF EXISTS grid_conflict_probe")
            _ = try await setup.executeCollecting(
                self.sql(
                    server,
                    pg: "CREATE TABLE grid_conflict_probe (id integer PRIMARY KEY, name text)",
                    mysql: "CREATE TABLE grid_conflict_probe (id INT PRIMARY KEY, name VARCHAR(50))",
                    sqlite: "CREATE TABLE grid_conflict_probe (id INTEGER PRIMARY KEY, name TEXT)")
            )
            _ = try await setup.executeCollecting(
                "INSERT INTO grid_conflict_probe VALUES (1, 'original'), (2, 'other')"
            )
            await session.release(setupLease)

            let table = self.table("grid_conflict_probe", in: server)
            let model = self.makeModel(session: session, table: table, identity: ["id"])
            await model.load(page: 0)
            model.setValue(.string("mine"), row: 0, column: 1)
            model.setValue(.string("also mine"), row: 1, column: 1)

            // Someone else moves the row out from under us.
            let (otherLease, other) = try await session.lease()
            _ = try await other.executeCollecting(
                "UPDATE grid_conflict_probe SET id = 99 WHERE id = 1"
            )
            await session.release(otherLease)

            let runner = SessionStatementRunner(session: session)
            do {
                _ = try await model.commit(using: runner)
                XCTFail("expected the commit to fail")
            } catch let error as GridCommitError {
                guard case let .unexpectedAffectedRows(_, actual, _) = error else {
                    return XCTFail("expected .unexpectedAffectedRows, got \(error)")
                }
                XCTAssertEqual(actual, 0)
                XCTAssertTrue(error.description.contains("data may have changed"))
            }

            // Nothing was written, not even the statement that would have succeeded.
            let (checkLease, check) = try await session.lease()
            let rows = try await check.executeCollecting(
                "SELECT id, name FROM grid_conflict_probe ORDER BY id"
            )
            await session.release(checkLease)
            XCTAssertEqual(rows.rows.map { $0[1].text }, ["also mine".isEmpty ? "" : "other", "original"])
            XCTAssertFalse(model.edits.isEmpty, "the user's edits must survive a failed commit")

            let (cleanupLease, cleanup) = try await session.lease()
            _ = try await cleanup.executeCollecting("DROP TABLE grid_conflict_probe")
            await session.release(cleanupLease)
        }
    }

    func testInsertAndDelete() async throws {
        try await withSession { session, server in
            let (setupLease, setup) = try await session.lease()
            _ = try await setup.executeCollecting("DROP TABLE IF EXISTS grid_insert_probe")
            _ = try await setup.executeCollecting(
                self.sql(
                    server,
                    pg: """
                    CREATE TABLE grid_insert_probe (
                        id integer GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
                        name text NOT NULL DEFAULT 'unnamed'
                    )
                    """,
                    mysql: """
                    CREATE TABLE grid_insert_probe (
                        id INT AUTO_INCREMENT PRIMARY KEY,
                        name VARCHAR(50) NOT NULL DEFAULT 'unnamed'
                    )
                    """,
                    sqlite: """
                    CREATE TABLE grid_insert_probe (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        name TEXT NOT NULL DEFAULT 'unnamed'
                    )
                    """)
            )
            _ = try await setup.executeCollecting("INSERT INTO grid_insert_probe (name) VALUES ('first')")
            await session.release(setupLease)

            let table = self.table("grid_insert_probe", in: server)
            let model = self.makeModel(session: session, table: table, identity: ["id"])
            await model.load(page: 0)

            let insert = try XCTUnwrap(model.addRow())
            model.edits.setInsertValue(.string("second"), id: insert.id, column: "name")
            model.markDeleted(rows: [0])

            let runner = SessionStatementRunner(session: session)
            let result = try await model.commit(using: runner)
            XCTAssertEqual(result.statementCount, 2)

            await model.reload()
            XCTAssertEqual(model.rowCount, 1)
            XCTAssertEqual(model.value(row: 0, column: 1), .string("second"))

            let (cleanupLease, cleanup) = try await session.lease()
            _ = try await cleanup.executeCollecting("DROP TABLE grid_insert_probe")
            await session.release(cleanupLease)
        }
    }

    /// SPEC §12.6: composite, UUID and missing keys each behave per spec.
    func testKeyShapes() async throws {
        try await withSession { session, server in
            let composite = self.makeModel(
                session: session, table: self.table("composite_pk", in: server),
                identity: ["org_id", "user_id"], identityKind: nil
            )
            await composite.load(page: 0)
            XCTAssertTrue(composite.isEditable)
            composite.setValue(.string("editor"), row: 0, column: 2)
            let compositeStatements = try composite.pendingStatements()
            XCTAssertEqual(compositeStatements.count, 1)
            let expectedPredicate = self.sql(
                server,
                pg: "\"org_id\" = $2 AND \"user_id\" = $3",
                mysql: "`org_id` = ? AND `user_id` = ?",
                sqlite: "\"org_id\" = ? AND \"user_id\" = ?")
            XCTAssertTrue(
                compositeStatements[0].sql.contains(expectedPredicate),
                compositeStatements[0].sql
            )
            // A composite key cannot drive a keyset cursor.
            XCTAssertEqual(composite.strategy(forPage: 100), .offset)

            let uuid = self.makeModel(
                session: session, table: self.table("uuid_pk", in: server),
                identity: ["id"], identityKind: .uuid
            )
            await uuid.load(page: 0)
            uuid.setValue(.string("renamed"), row: 0, column: 1)
            let uuidStatements = try uuid.pendingStatements()
            XCTAssertEqual(uuidStatements.count, 1)
            // PostgreSQL has a `uuid` type; MySQL stores one as `char(36)`. Either way the
            // WHERE clause binds the row's own identifier, not a rewritten form of it.
            let boundKey = try XCTUnwrap(uuidStatements[0].parameters.last)
            XCTAssertEqual(boundKey.text, "11111111-1111-1111-1111-111111111111")
            if server.engine == .postgresql {
                guard case .uuid = boundKey else {
                    return XCTFail("PostgreSQL should bind a UUID, got \(boundKey)")
                }
            }
            XCTAssertEqual(uuid.strategy(forPage: 100), .offset)

            let none = self.makeModel(
                session: session, table: self.table("no_pk", in: server), identity: [], identityKind: nil
            )
            await none.load(page: 0)
            XCTAssertFalse(none.isEditable)
            XCTAssertEqual(none.readOnlyReason, "No primary key — read only")
            XCTAssertFalse(none.setValue(.int(1), row: 0, column: 0))
        }
    }

    func testExactCountMatchesTheFixture() async throws {
        try await withSession { session, server in
            let table = self.table("big_table", in: server)
            let model = self.makeModel(session: session, table: table, identity: ["id"])
            await model.loadExactCount()
            XCTAssertEqual(model.totalCount, 1_000_000)
        }
    }
}

// MARK: - Quick search and CSV import

extension GridIntegrationTests {
    /// The quick search is one bound pattern per column, ORed, on top of the row filter.
    func testQuickSearchAcrossColumnsFindsRowsOnBothEngines() async throws {
        try await withSession { session, server in
            let table = self.table("smoke", in: server)
            let model = self.makeModel(session: session, table: table, identity: ["id"])
            await model.setFilter([FilterRule.search("ÖRL", in: ["id", "name"])])
            XCTAssertNil(model.lastError.map { String(describing: $0) })
            // PostgreSQL's ILIKE folds case; MySQL's default collation does too.
            XCTAssertEqual(model.rowCount, 1)
            XCTAssertEqual(model.value(row: 0, column: 1), .string("wörld"))

            await model.setFilter([
                FilterRule(column: "id", op: .greaterThan, values: [.int(1)]),
                FilterRule.search("l", in: ["name"]),
            ])
            XCTAssertNil(model.lastError.map { String(describing: $0) })
            XCTAssertEqual(model.rowCount, 1, "only wörld has an l and an id above 1")

            await model.setFilter([FilterRule.search("50%", in: ["name"])])
            XCTAssertEqual(model.rowCount, 0, "the percent sign is literal, not a wildcard")
        }
    }

    /// A CSV lands in one transaction, bad rows roll it back, and NULLs are honoured.
    func testCSVImportInsertsEveryRowOrNothing() async throws {
        try await withSession { session, server in
            let dialect = session.config.dialect
            let table = self.table("csv_import_test", in: server)
            let name = Identifier.qualified(table, dialect: dialect)
            let (lease, connection) = try await session.lease()
            defer { Task { await session.release(lease) } }
            _ = try await connection.executeCollecting("DROP TABLE IF EXISTS \(name)")
            _ = try await connection.executeCollecting(
                "CREATE TABLE \(name) (id integer PRIMARY KEY, label varchar(50), price numeric(10,2), active boolean)"
            )
            // Dropped on the same connection before it is returned: a statement left to a
            // detached task after the lease closes trips the driver's own assertion.
            do {
                try await self.importAndCheck(table: table, name: name, dialect: dialect, connection: connection)
            } catch {
                _ = try? await connection.executeCollecting("DROP TABLE IF EXISTS \(name)")
                throw error
            }
            _ = try await connection.executeCollecting("DROP TABLE IF EXISTS \(name)")
        }
    }

    private func importAndCheck(
        table: TableRef, name: String, dialect: SQLDialect, connection: any SQLConnection
    ) async throws {
        do {
            let columns = try await connection.introspector.columns(of: table)
            let csv = """
                id,label,price,active,ignored
                1,"Pen, blue",1.50,true,x
                2,Notebook,,false,y
                3,\\N,12.00,1,z
                """
            var reader = CSVReader(data: Data(csv.utf8))
            var plan = CSVImportPlan.matched(header: reader.next() ?? [], to: columns, table: table)
            plan.nullText = "\\N"
            reader = CSVReader(data: Data(csv.utf8))
            let importer = CSVImporter(plan: plan, columns: columns, dialect: dialect)
            XCTAssertEqual(plan.mapping, ["id", "label", "price", "active", nil])

            let inserted = try await importer.run(reader: &reader, on: connection)
            XCTAssertEqual(inserted, 3)
            let rows = try await connection.executeCollecting(
                "SELECT id, label, price, active FROM \(name) ORDER BY id")
            XCTAssertEqual(rows.rows.count, 3)
            XCTAssertEqual(rows.rows[0][1], .string("Pen, blue"))
            // SQLite has no decimal type: NUMERIC(10,2) stores the REAL 1.5 and hands it back.
            XCTAssertEqual(rows.rows[0][2].text, dialect == .sqlite ? "1.5" : "1.50")
            XCTAssertEqual(rows.rows[1][2], .null)
            XCTAssertEqual(rows.rows[2][1], .null)
            XCTAssertTrue(["true", "1"].contains(rows.rows[2][3].text ?? ""), "\(rows.rows[2][3])")

            // A bad value in the second record: the first must not survive either.
            let bad = "id,label,price,active\n10,ok,1,true\neleven,bad,1,true\n"
            var badReader = CSVReader(data: Data(bad.utf8))
            do {
                _ = try await importer.run(reader: &badReader, on: connection)
                XCTFail("expected the import to be refused")
            } catch let error as CSVImportError {
                XCTAssertEqual(error.record, 3)
                XCTAssertEqual(error.column, "id")
            }
            let after = try await connection.executeCollecting("SELECT count(*) FROM \(name)")
            XCTAssertEqual(after.firstText, "3", "the failed import left no rows behind")
            let stillOpen = await connection.isInTransaction
            XCTAssertFalse(stillOpen)
        }
    }
}

// MARK: - Query builder

extension GridIntegrationTests {
    /// What the canvas generates must be a statement both servers accept as-is.
    func testQueryBuilderSQLRunsOnBothEngines() async throws {
        try await withSession { session, server in
            let dialect = session.config.dialect
            var model = QueryBuilderModel()
            let customers = model.add(self.table("customers", in: server))
            let orders = model.add(self.table("orders", in: server))
            model.joins.append(
                .init(
                    kind: .left, leftTable: customers, leftColumn: "id", rightTable: orders, rightColumn: "customer_id")
            )
            model.fields = [
                .init(table: customers, column: "name"),
                .init(table: orders, column: "total", aggregate: .sum, alias: "revenue"),
                .init(table: orders, column: "id", aggregate: .count, alias: "orders"),
            ]
            model.conditions = [.init(table: customers, column: "name", op: .contains, values: [.string("a")])]
            model.groupBy = [.init(table: customers, column: "name")]
            model.orderBy = [.init(table: customers, column: "name")]
            model.limit = 10
            let sql = try XCTUnwrap(model.sql(dialect: dialect))

            let (lease, connection) = try await session.lease()
            defer { Task { await session.release(lease) } }
            let result = try await connection.executeCollecting(sql)
            XCTAssertEqual(result.columns.map(\.name), ["name", "revenue", "orders"])
            XCTAssertFalse(result.rows.isEmpty, sql)

            // The same statement as a view, created and dropped on the spot.
            let viewRef = self.table("qb_test_view", in: server)
            let create = try XCTUnwrap(model.createViewSQL(name: viewRef, dialect: dialect))
            _ = try await connection.executeCollecting(create)
            let fromView = try await connection.executeCollecting(
                "SELECT count(*) FROM \(Identifier.qualified(viewRef, dialect: dialect))")
            XCTAssertEqual(fromView.firstText, String(result.rows.count))
            _ = try await connection.executeCollecting("DROP VIEW \(Identifier.qualified(viewRef, dialect: dialect))")
        }
    }
}
