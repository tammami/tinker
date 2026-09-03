import DBCore
import DBPostgres
import DBSQL
import DBTestKit
import Logging
import XCTest
@testable import DBGrid

/// The grid's data path against a real PostgreSQL: paging, sorting, filtering, editing and
/// the commit rules that protect the user's data (SPEC §12.6).
@MainActor
final class GridIntegrationTests: XCTestCase {
    var logger: Logger {
        var logger = Logger(label: "test.grid")
        logger.logLevel = .critical
        return logger
    }

    func withSession(
        _ body: (ConnectionSession, TestServer) async throws -> Void
    ) async throws {
        let servers = try TestEnvironment.requireServers(for: .postgresql)
        for server in servers {
            let config = ConnectionConfig(
                name: "grid-test", dialect: .postgresql,
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
                registry: DriverRegistry([.postgresql: PostgresDriver.self]),
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
        GridModel(
            source: .table(table),
            dialect: .postgresql,
            loader: SessionGridLoader(session: session, table: table, dialect: .postgresql),
            identityColumns: identity,
            identityKind: identityKind
        )
    }

    // MARK: - Paging

    /// SPEC §12.6: the first page of a million-row table arrives quickly.
    func testFirstPageOfAMillionRowsIsFast() async throws {
        try await withSession { session, server in
            let table = TableRef(database: server.database, schema: "public", name: "big_table")
            let model = self.makeModel(session: session, table: table, identity: ["id"])
            let started = ContinuousClock.now
            await model.load(page: 0)
            let elapsed = started.duration(to: .now)

            XCTAssertNil(model.lastError)
            XCTAssertEqual(model.rowCount, 1_000)
            XCTAssertEqual(model.columns.map(\.name), ["id", "name", "amount", "flag", "created"])
            XCTAssertEqual(model.value(row: 0, column: 0), .int(1))
            XCTAssertLessThan(elapsed, .milliseconds(500), "first page took \(elapsed)")
            TestLog.note("grid: first page of big_table in \(elapsed)")
        }
    }

    /// Scrolling deep into the table stays constant-cost by switching to a keyset cursor.
    func testDeepPagingUsesAKeysetCursorAndStaysCorrect() async throws {
        try await withSession { session, server in
            let table = TableRef(database: server.database, schema: "public", name: "big_table")
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
            let table = TableRef(database: server.database, schema: "public", name: "big_table")
            let model = GridModel(
                source: .table(table), dialect: .postgresql,
                loader: SessionGridLoader(session: session, table: table, dialect: .postgresql),
                identityColumns: ["id"], identityKind: .int,
                buffer: RowBuffer(pageSize: 1_000, rowCapacity: 20_000, residentPageRadius: 5)
            )
            for page in stride(from: 0, to: 120, by: 1) {
                await model.load(page: page)
            }
            XCTAssertLessThanOrEqual(
                model.buffer.count, 20_000,
                "the buffer held \(model.buffer.count) rows, past its cap"
            )
            // What was just loaded is still there, so scrolling never shows blanks.
            XCTAssertNotNil(model.buffer.row(at: 119_000))
        }
    }

    // MARK: - Sorting and filtering

    func testServerSideSortAndFilter() async throws {
        try await withSession { session, server in
            let table = TableRef(database: server.database, schema: "public", name: "big_table")
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
            let table = TableRef(database: server.database, schema: "public", name: "big_table")
            let model = self.makeModel(session: session, table: table, identity: ["id"])
            await model.setFilter([
                FilterRule(column: "name", op: .equal, values: [.string("'; DROP TABLE big_table; --")]),
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
            _ = try await setup.executeCollecting("""
                CREATE TABLE grid_edit_probe (
                    id integer PRIMARY KEY, name text, age integer
                )
                """)
            _ = try await setup.executeCollecting(
                "INSERT INTO grid_edit_probe VALUES (1, 'a', 29), (2, 'b', 41)"
            )
            await session.release(setupLease)

            let table = TableRef(database: server.database, schema: "public", name: "grid_edit_probe")
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
                "CREATE TABLE grid_conflict_probe (id integer PRIMARY KEY, name text)"
            )
            _ = try await setup.executeCollecting(
                "INSERT INTO grid_conflict_probe VALUES (1, 'original'), (2, 'other')"
            )
            await session.release(setupLease)

            let table = TableRef(database: server.database, schema: "public", name: "grid_conflict_probe")
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
            _ = try await setup.executeCollecting("""
                CREATE TABLE grid_insert_probe (
                    id integer GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
                    name text NOT NULL DEFAULT 'unnamed'
                )
                """)
            _ = try await setup.executeCollecting("INSERT INTO grid_insert_probe (name) VALUES ('first')")
            await session.release(setupLease)

            let table = TableRef(database: server.database, schema: "public", name: "grid_insert_probe")
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
            func table(_ name: String) -> TableRef {
                TableRef(database: server.database, schema: "public", name: name)
            }

            let composite = self.makeModel(
                session: session, table: table("composite_pk"),
                identity: ["org_id", "user_id"], identityKind: nil
            )
            await composite.load(page: 0)
            XCTAssertTrue(composite.isEditable)
            composite.setValue(.string("editor"), row: 0, column: 2)
            let compositeStatements = try composite.pendingStatements()
            XCTAssertEqual(compositeStatements.count, 1)
            XCTAssertTrue(
                compositeStatements[0].sql.contains("\"org_id\" = $2 AND \"user_id\" = $3"),
                compositeStatements[0].sql
            )
            // A composite key cannot drive a keyset cursor.
            XCTAssertEqual(composite.strategy(forPage: 100), .offset)

            let uuid = self.makeModel(
                session: session, table: table("uuid_pk"), identity: ["id"], identityKind: .uuid
            )
            await uuid.load(page: 0)
            uuid.setValue(.string("renamed"), row: 0, column: 1)
            let uuidStatements = try uuid.pendingStatements()
            XCTAssertEqual(uuidStatements.count, 1)
            guard case .uuid? = uuidStatements[0].parameters.last else {
                return XCTFail("the WHERE clause should bind a UUID, got \(uuidStatements[0].parameters)")
            }
            XCTAssertEqual(uuid.strategy(forPage: 100), .offset)

            let none = self.makeModel(
                session: session, table: table("no_pk"), identity: [], identityKind: nil
            )
            await none.load(page: 0)
            XCTAssertFalse(none.isEditable)
            XCTAssertEqual(none.readOnlyReason, "No primary key — read only")
            XCTAssertFalse(none.setValue(.int(1), row: 0, column: 0))
        }
    }

    func testExactCountMatchesTheFixture() async throws {
        try await withSession { session, server in
            let table = TableRef(database: server.database, schema: "public", name: "big_table")
            let model = self.makeModel(session: session, table: table, identity: ["id"])
            await model.loadExactCount()
            XCTAssertEqual(model.totalCount, 1_000_000)
        }
    }
}
