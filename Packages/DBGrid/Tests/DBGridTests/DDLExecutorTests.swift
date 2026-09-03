import DBCore
import DBMySQL
import DBPostgres
import DBSQL
import DBTestKit
import Logging
import XCTest

@testable import DBGrid

/// Runs generated structure statements against the real servers and reads them back
/// (SPEC §15b.5). Nothing here trusts the generator's output on its own: every test
/// asserts what introspection reports afterwards.
final class DDLExecutorTests: XCTestCase {
    var logger: Logger {
        var logger = Logger(label: "dbstudio-test")
        logger.logLevel = .critical
        return logger
    }

    static var registry: DriverRegistry {
        DriverRegistry([.postgresql: PostgresDriver.self, .mysql: MySQLDriver.self])
    }

    /// Every configured server of either engine, so the same checks run on both.
    func withSession(
        _ body: (ConnectionSession, TestServer) async throws -> Void
    ) async throws {
        let postgres = (try? TestEnvironment.servers(for: .postgresql)) ?? []
        let mysql = (try? TestEnvironment.servers(for: .mysql)) ?? []
        let all = postgres + mysql
        if all.isEmpty {
            throw XCTSkip("neither DBSTUDIO_TEST_PG_URL nor DBSTUDIO_TEST_MYSQL_URL is set")
        }
        for server in all {
            let dialect: SQLDialect = server.engine == .postgresql ? .postgresql : .mysql
            let config = ConnectionConfig(
                name: "ddl-test", dialect: dialect,
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
                config: withPassword, registry: Self.registry, secrets: secrets, logger: logger
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

    /// A table name no fixture uses, so a failed run cannot damage anything.
    func scratchName(_ suffix: String) -> String { "designer_\(suffix)" }

    func table(_ name: String, _ server: TestServer, dialect: SQLDialect) -> TableRef {
        dialect == .postgresql
            ? TableRef(database: server.database, schema: "public", name: name)
            : TableRef(schema: SchemaRef.mysql(server.database), name: name)
    }

    func dialect(for server: TestServer) -> SQLDialect {
        server.engine == .postgresql ? .postgresql : .mysql
    }

    /// Drops the scratch table however the run left it.
    func cleanUp(_ ref: TableRef, session: ConnectionSession, dialect: SQLDialect) async {
        let executor = DDLExecutor(session: session, dialect: dialect)
        _ = try? await executor.run([
            GeneratedDDL(
                kind: .dropTable,
                sql: "DROP TABLE IF EXISTS \(Identifier.qualified(ref, dialect: dialect))",
                table: ref
            )
        ])
    }

    // MARK: - Create, then read back

    func testCreateTableRoundTripsThroughIntrospection() async throws {
        try await withSession { session, server in
            let dialect = self.dialect(for: server)
            let ref = self.table(self.scratchName("create"), server, dialect: dialect)
            await self.cleanUp(ref, session: session, dialect: dialect)

            let intType = dialect == .postgresql ? "integer" : "int"
            let textType = dialect == .postgresql ? "text" : "varchar(64)"
            let definition = TableDefinition(
                ref: ref,
                columns: [
                    ColumnDefinition(name: "id", type: intType, isNullable: false),
                    ColumnDefinition(name: "label", type: textType),
                ],
                primaryKey: ["id"]
            )

            let generator = DDLGenerator(dialect: dialect)
            let executor = DDLExecutor(session: session, dialect: dialect)
            let result = try await executor.run(generator.create(definition))
            XCTAssertTrue(result.isSuccess, result.errorText ?? "no error")

            let (lease, connection) = try await session.lease()
            defer { Task { await session.release(lease) } }
            let columns = try await connection.introspector.columns(of: ref)
            XCTAssertEqual(columns.map(\.name), ["id", "label"])
            let key = try await connection.introspector.primaryKey(of: ref)
            XCTAssertEqual(key, ["id"], "the table was created with its primary key")

            await self.cleanUp(ref, session: session, dialect: dialect)
        }
    }

    // MARK: - Primary key

    /// SPEC §15b.5: setting a primary key makes the table editable, which the grid decides
    /// from `rowIdentity`.
    func testSettingAPrimaryKeyMakesTheTableIdentifiable() async throws {
        try await withSession { session, server in
            let dialect = self.dialect(for: server)
            let ref = self.table(self.scratchName("pk"), server, dialect: dialect)
            await self.cleanUp(ref, session: session, dialect: dialect)

            let intType = dialect == .postgresql ? "integer" : "int"
            let generator = DDLGenerator(dialect: dialect)
            let executor = DDLExecutor(session: session, dialect: dialect)

            // A table with no key at all.
            var current = TableDefinition(
                ref: ref,
                columns: [ColumnDefinition(name: "id", type: intType, isNullable: false)]
            )
            _ = try await executor.run(generator.create(current))

            let (lease, connection) = try await session.lease()
            defer { Task { await session.release(lease) } }
            let before = try await connection.introspector.rowIdentity(of: ref)
            XCTAssertNil(before, "the fixture starts without an identity")

            var edited = current
            edited.primaryKey = ["id"]
            let result = try await executor.run(generator.alter(from: current, to: edited))
            XCTAssertTrue(result.isSuccess, result.errorText ?? "no error")

            let after = try await connection.introspector.rowIdentity(of: ref)
            XCTAssertEqual(after, ["id"], "the grid can now identify a row")

            // And taking it away again is a single edit.
            current = edited
            edited.primaryKey = []
            let dropped = try await executor.run(generator.alter(from: current, to: edited))
            XCTAssertTrue(dropped.isSuccess, dropped.errorText ?? "no error")
            let none = try await connection.introspector.rowIdentity(of: ref)
            XCTAssertNil(none)

            await self.cleanUp(ref, session: session, dialect: dialect)
        }
    }

    // MARK: - Indexes

    func testCreatingAndDroppingIndexesRoundTrips() async throws {
        try await withSession { session, server in
            let dialect = self.dialect(for: server)
            let ref = self.table(self.scratchName("idx"), server, dialect: dialect)
            await self.cleanUp(ref, session: session, dialect: dialect)

            let intType = dialect == .postgresql ? "integer" : "int"
            let textType = dialect == .postgresql ? "text" : "varchar(64)"
            let generator = DDLGenerator(dialect: dialect)
            let executor = DDLExecutor(session: session, dialect: dialect)

            let current = TableDefinition(
                ref: ref,
                columns: [
                    ColumnDefinition(name: "id", type: intType, isNullable: false),
                    ColumnDefinition(name: "email", type: textType, isNullable: false),
                ],
                primaryKey: ["id"]
            )
            _ = try await executor.run(generator.create(current))

            var edited = current
            edited.indexes = [
                IndexDefinition(
                    name: "designer_idx_email", columns: [IndexColumn(name: "email")], method: "btree"
                ),
                IndexDefinition(
                    name: "designer_idx_email_unique",
                    columns: [IndexColumn(name: "email")],
                    isUnique: true,
                    method: "btree"
                ),
            ]
            let added = try await executor.run(generator.alter(from: current, to: edited))
            XCTAssertTrue(added.isSuccess, added.errorText ?? "no error")

            let (lease, connection) = try await session.lease()
            defer { Task { await session.release(lease) } }
            let indexes = try await connection.introspector.indexes(of: ref)
            let byName = Dictionary(uniqueKeysWithValues: indexes.map { ($0.name, $0) })
            let plain = try XCTUnwrap(byName["designer_idx_email"])
            XCTAssertFalse(plain.isUnique)
            XCTAssertEqual(plain.columns, ["email"])
            XCTAssertEqual(plain.method?.lowercased(), "btree")
            let unique = try XCTUnwrap(byName["designer_idx_email_unique"])
            XCTAssertTrue(unique.isUnique)

            // Dropping them puts the table back where it started.
            let dropped = try await executor.run(generator.alter(from: edited, to: current))
            XCTAssertTrue(dropped.isSuccess, dropped.errorText ?? "no error")
            let remaining = try await connection.introspector.indexes(of: ref).map(\.name)
            // Not a prefix check: the table is called designer_idx, so PostgreSQL's own
            // primary-key index is designer_idx_pkey and would match one.
            XCTAssertFalse(remaining.contains("designer_idx_email"), "\(remaining)")
            XCTAssertFalse(remaining.contains("designer_idx_email_unique"), "\(remaining)")

            await self.cleanUp(ref, session: session, dialect: dialect)
        }
    }

    // MARK: - Columns

    func testColumnAddChangeRenameAndDrop() async throws {
        try await withSession { session, server in
            let dialect = self.dialect(for: server)
            let ref = self.table(self.scratchName("cols"), server, dialect: dialect)
            await self.cleanUp(ref, session: session, dialect: dialect)

            let intType = dialect == .postgresql ? "integer" : "int"
            let generator = DDLGenerator(dialect: dialect)
            let executor = DDLExecutor(session: session, dialect: dialect)

            var current = TableDefinition(
                ref: ref,
                columns: [ColumnDefinition(name: "id", type: intType, isNullable: false)],
                primaryKey: ["id"]
            )
            _ = try await executor.run(generator.create(current))

            // Add.
            let added = ColumnDefinition(
                name: "note", type: dialect == .postgresql ? "text" : "varchar(32)"
            )
            var edited = current
            edited.columns.append(added)
            var result = try await executor.run(generator.alter(from: current, to: edited))
            XCTAssertTrue(result.isSuccess, result.errorText ?? "no error")

            let (lease, connection) = try await session.lease()
            defer { Task { await session.release(lease) } }
            var columns = try await connection.introspector.columns(of: ref)
            XCTAssertEqual(columns.map(\.name), ["id", "note"])
            XCTAssertTrue(try XCTUnwrap(columns.last).isNullable)

            // Change: NOT NULL with a default, so existing rows have something to take.
            current = edited
            edited.columns[1].isNullable = false
            edited.columns[1].defaultExpression = "'x'"
            result = try await executor.run(generator.alter(from: current, to: edited))
            XCTAssertTrue(result.isSuccess, result.errorText ?? "no error")
            columns = try await connection.introspector.columns(of: ref)
            XCTAssertFalse(try XCTUnwrap(columns.last).isNullable)

            // Rename: the same column, a different name.
            current = edited
            edited.columns[1].name = "remark"
            result = try await executor.run(generator.alter(from: current, to: edited))
            XCTAssertTrue(result.isSuccess, result.errorText ?? "no error")
            columns = try await connection.introspector.columns(of: ref)
            XCTAssertEqual(columns.map(\.name), ["id", "remark"])

            // Drop.
            current = edited
            edited.columns.removeLast()
            result = try await executor.run(generator.alter(from: current, to: edited))
            XCTAssertTrue(result.isSuccess, result.errorText ?? "no error")
            columns = try await connection.introspector.columns(of: ref)
            XCTAssertEqual(columns.map(\.name), ["id"])

            await self.cleanUp(ref, session: session, dialect: dialect)
        }
    }

    // MARK: - Column order

    /// Only MySQL can move a column, and the server reports the new order back.
    func testReorderingColumnsOnMySQL() async throws {
        try await withSession { session, server in
            let dialect = self.dialect(for: server)
            guard dialect == .mysql else { return }
            let ref = self.table(self.scratchName("order"), server, dialect: dialect)
            await self.cleanUp(ref, session: session, dialect: dialect)

            let generator = DDLGenerator(dialect: dialect)
            let executor = DDLExecutor(session: session, dialect: dialect)
            let id = ColumnDefinition(name: "id", type: "int", isNullable: false)
            let name = ColumnDefinition(name: "name", type: "varchar(32)")
            let email = ColumnDefinition(name: "email", type: "varchar(32)")
            let current = TableDefinition(
                ref: ref, columns: [id, name, email], primaryKey: ["id"]
            )
            _ = try await executor.run(generator.create(current))

            var edited = current
            edited.columns = [id, email, name]
            let result = try await executor.run(generator.alter(from: current, to: edited))
            XCTAssertTrue(result.isSuccess, result.errorText ?? "no error")

            let (lease, connection) = try await session.lease()
            defer { Task { await session.release(lease) } }
            let columns = try await connection.introspector.columns(of: ref)
            XCTAssertEqual(columns.map(\.name), ["id", "email", "name"])

            await self.cleanUp(ref, session: session, dialect: dialect)
        }
    }

    // MARK: - Triggers

    func testCreatingAndDroppingATrigger() async throws {
        try await withSession { session, server in
            let dialect = self.dialect(for: server)
            let ref = self.table(self.scratchName("trig"), server, dialect: dialect)
            await self.cleanUp(ref, session: session, dialect: dialect)

            let intType = dialect == .postgresql ? "integer" : "int"
            let generator = DDLGenerator(dialect: dialect)
            let executor = DDLExecutor(session: session, dialect: dialect)
            let current = TableDefinition(
                ref: ref,
                columns: [
                    ColumnDefinition(name: "id", type: intType, isNullable: false),
                    ColumnDefinition(
                        name: "touched", type: intType, isNullable: false, defaultExpression: "0"
                    ),
                ],
                primaryKey: ["id"]
            )
            _ = try await executor.run(generator.create(current))

            var edited = current
            edited.triggers = [
                dialect == .postgresql
                    // The fixture's function is already in the schema.
                    ? TriggerInfo(
                        name: "designer_trig_bump", timing: .before, events: [.update],
                        functionCall: "\"public\".\"bump_touched\"()"
                    )
                    : TriggerInfo(
                        name: "designer_trig_bump", timing: .before, events: [.update],
                        body: "SET NEW.touched = OLD.touched + 1"
                    )
            ]
            let added = try await executor.run(generator.alter(from: current, to: edited))
            XCTAssertTrue(added.isSuccess, added.errorText ?? "no error")

            let (lease, connection) = try await session.lease()
            defer { Task { await session.release(lease) } }
            var triggers = try await connection.introspector.triggers(of: ref)
            XCTAssertEqual(triggers.map(\.name), ["designer_trig_bump"])
            XCTAssertEqual(triggers.first?.timing, .before)
            XCTAssertEqual(triggers.first?.events, [.update])

            let dropped = try await executor.run(generator.alter(from: edited, to: current))
            XCTAssertTrue(dropped.isSuccess, dropped.errorText ?? "no error")
            triggers = try await connection.introspector.triggers(of: ref)
            XCTAssertTrue(triggers.isEmpty)

            await self.cleanUp(ref, session: session, dialect: dialect)
        }
    }

    // MARK: - Partitions

    func testAddingAndRemovingAPartition() async throws {
        try await withSession { session, server in
            let dialect = self.dialect(for: server)
            let ref = self.table(self.scratchName("part"), server, dialect: dialect)
            await self.cleanUp(ref, session: session, dialect: dialect)

            let intType = dialect == .postgresql ? "integer" : "int"
            let generator = DDLGenerator(dialect: dialect)
            let executor = DDLExecutor(session: session, dialect: dialect)

            // MySQL requires every partitioning column in the primary key.
            var current = TableDefinition(
                ref: ref,
                columns: [
                    ColumnDefinition(name: "id", type: intType, isNullable: false),
                    ColumnDefinition(name: "bucket", type: intType, isNullable: false),
                ],
                primaryKey: ["id", "bucket"]
            )
            let firstBound =
                dialect == .postgresql
                ? "FOR VALUES FROM (0) TO (10)"
                : "VALUES LESS THAN (10)"
            let secondBound =
                dialect == .postgresql
                ? "FOR VALUES FROM (10) TO (20)"
                : "VALUES LESS THAN (20)"

            current.partitioning = PartitioningInfo(
                strategy: .range,
                key: "bucket",
                partitions: [PartitionInfo(name: "designer_part_p0", bound: firstBound)]
            )
            let created = try await executor.run(generator.create(current))
            XCTAssertTrue(created.isSuccess, created.errorText ?? "no error")

            var edited = current
            edited.partitioning = PartitioningInfo(
                strategy: .range,
                key: "bucket",
                partitions: current.partitioning!.partitions
                    + [PartitionInfo(name: "designer_part_p1", bound: secondBound)]
            )
            let added = try await executor.run(generator.alter(from: current, to: edited))
            XCTAssertTrue(added.isSuccess, added.errorText ?? "no error")

            let (lease, connection) = try await session.lease()
            defer { Task { await session.release(lease) } }
            let partitioning = try await connection.introspector.partitioning(of: ref)
            XCTAssertEqual(
                (partitioning?.partitions ?? []).map(\.name).sorted(),
                ["designer_part_p0", "designer_part_p1"]
            )

            // Removing one: PostgreSQL detaches it into a table of its own, MySQL drops it.
            let removed = try await executor.run(generator.alter(from: edited, to: current))
            XCTAssertTrue(removed.isSuccess, removed.errorText ?? "no error")
            let after = try await connection.introspector.partitioning(of: ref)
            XCTAssertEqual((after?.partitions ?? []).map(\.name), ["designer_part_p0"])

            if dialect == .postgresql {
                // The detached partition is still a table and has to be cleaned up too.
                let detached = self.table("designer_part_p1", server, dialect: dialect)
                await self.cleanUp(detached, session: session, dialect: dialect)
            }
            await self.cleanUp(ref, session: session, dialect: dialect)
        }
    }

    // MARK: - Failure

    /// SPEC §15b.5: a failing statement leaves PostgreSQL untouched, and on MySQL the
    /// result names exactly what had already committed.
    func testAFailedRunRollsBackOnPostgresAndReportsPartialCommitOnMySQL() async throws {
        try await withSession { session, server in
            let dialect = self.dialect(for: server)
            let ref = self.table(self.scratchName("fail"), server, dialect: dialect)
            await self.cleanUp(ref, session: session, dialect: dialect)

            let intType = dialect == .postgresql ? "integer" : "int"
            let textType = dialect == .postgresql ? "text" : "varchar(64)"
            let generator = DDLGenerator(dialect: dialect)
            let executor = DDLExecutor(session: session, dialect: dialect)

            let current = TableDefinition(
                ref: ref,
                columns: [
                    ColumnDefinition(name: "id", type: intType, isNullable: false),
                    ColumnDefinition(name: "email", type: textType, isNullable: false),
                ],
                primaryKey: ["id"]
            )
            _ = try await executor.run(generator.create(current))

            // A good statement, then one the server must refuse: an index on a column
            // that is not there.
            let good = GeneratedDDL(
                kind: .createIndex,
                sql: generator.createIndexSQL(
                    IndexDefinition(
                        name: "designer_fail_ok", columns: [IndexColumn(name: "email")], method: "btree"
                    ),
                    on: ref
                ),
                table: ref
            )
            let bad = GeneratedDDL(
                kind: .createIndex,
                sql: generator.createIndexSQL(
                    IndexDefinition(
                        name: "designer_fail_bad",
                        columns: [IndexColumn(name: "no_such_column")],
                        method: "btree"
                    ),
                    on: ref
                ),
                table: ref
            )

            let result = try await executor.run([good, bad])
            XCTAssertFalse(result.isSuccess)
            XCTAssertEqual(result.failed?.sql, bad.sql)
            // The server's own words, not ours.
            XCTAssertNotNil(result.errorText)
            XCTAssertFalse(result.errorText?.isEmpty ?? true)

            let (lease, connection) = try await session.lease()
            defer { Task { await session.release(lease) } }
            let indexes = try await connection.introspector.indexes(of: ref)
            let survived = indexes.contains { $0.name == "designer_fail_ok" }

            if dialect == .postgresql {
                XCTAssertTrue(result.didRollBack, "PostgreSQL undoes DDL on failure")
                XCTAssertTrue(result.applied.isEmpty)
                XCTAssertFalse(survived, "the good statement was rolled back with the bad one")
            } else {
                XCTAssertFalse(result.didRollBack, "MySQL commits DDL as it goes")
                XCTAssertEqual(
                    result.applied.map(\.sql), [good.sql],
                    "the result must name what already committed"
                )
                XCTAssertTrue(survived, "MySQL kept the statement that succeeded")
            }

            await self.cleanUp(ref, session: session, dialect: dialect)
        }
    }

    func testRunningNothingDoesNothing() async throws {
        try await withSession { session, server in
            let dialect = self.dialect(for: server)
            let executor = DDLExecutor(session: session, dialect: dialect)
            let result = try await executor.run([])
            XCTAssertTrue(result.isSuccess)
            XCTAssertTrue(result.applied.isEmpty)
        }
    }
}
