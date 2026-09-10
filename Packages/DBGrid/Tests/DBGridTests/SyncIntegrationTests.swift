import DBCore
import DBMySQL
import DBPostgres
import DBSQLite
import DBSQL
import DBTestKit
import Logging
import XCTest

@testable import DBGrid

/// Data and structure synchronisation against the real servers: the merge finds exactly
/// the rows that differ, applying makes the target match, and the schema comparison
/// writes the DDL for what is missing.
final class SyncIntegrationTests: XCTestCase {
    var logger: Logger {
        var logger = Logger(label: "test.sync")
        logger.logLevel = .critical
        return logger
    }

    static var registry: DriverRegistry {
        DriverRegistry([.postgresql: PostgresDriver.self, .mysql: MySQLDriver.self, .sqlite: SQLiteDriver.self])
    }

    func withSession(_ body: (ConnectionSession, TestServer, SQLDialect) async throws -> Void) async throws {
        let sqlite = try TestEnvironment.servers(for: .sqlite)
        if !sqlite.isEmpty { try await SQLiteFixtures.prepare() }
        let all =
            (try TestEnvironment.servers(for: .postgresql))
            + (try TestEnvironment.servers(for: .mysql)) + sqlite
        if all.isEmpty { throw XCTSkip("no test server configured") }
        for server in all {
            let dialect = server.engine.dialect
            let config = ConnectionConfig(
                name: "sync-test", dialect: dialect, host: server.host, port: server.port, user: server.user,
                database: server.database)
            let secrets = EphemeralSecretStore()
            var withPassword = config
            if let password = server.password {
                let reference = SecretRef.forConnection(config.id, field: "password")
                try await secrets.setSecret(password, for: reference)
                withPassword.passwordRef = reference
            }
            let session = ConnectionSession(
                config: withPassword, registry: Self.registry, secrets: secrets, logger: logger)
            do {
                try await body(session, server, dialect)
            } catch {
                await session.disconnect()
                throw error
            }
            await session.disconnect()
        }
    }

    func schema(_ server: TestServer) -> SchemaRef { server.fixtureSchema }

    func run(_ statements: [String], on connection: any SQLConnection) async throws {
        for statement in statements { _ = try await connection.executeCollecting(statement) }
    }

    func rows(_ table: String, on connection: any SQLConnection) async throws -> [[DBValue]] {
        try await connection.executeCollecting("SELECT id, code, name, amount FROM \(table) ORDER BY id").rows
    }

    func drop(on connection: any SQLConnection) async {
        for name in ["sync_src", "sync_dst", "sync_only_src", "sync_only_dst", "sync_alter"] {
            _ = try? await connection.executeCollecting("DROP TABLE IF EXISTS \(name)")
        }
    }

    func testDataSyncFindsAndAppliesExactlyTheDifferences() async throws {
        try await withSession { session, server, dialect in
            _ = try await session.connect()
            let (leaseA, source) = try await session.lease()
            let (leaseB, target) = try await session.lease()
            let (leaseC, writer) = try await session.lease()
            defer {
                Task {
                    await session.release(leaseA)
                    await session.release(leaseB)
                    await session.release(leaseC)
                }
            }
            await drop(on: source)
            let textType = dialect == .postgresql ? "text" : "varchar(100)"
            for name in ["sync_src", "sync_dst"] {
                try await run(
                    [
                        "CREATE TABLE \(name) (id int PRIMARY KEY, code \(textType) NOT NULL, name \(textType), amount decimal(10,2))"
                    ],
                    on: source)
            }
            // Source: 1..6 with a gap; target: some same, some changed, some extra.
            try await run(
                [
                    "INSERT INTO sync_src VALUES (1,'a','same',1.00),(2,'b','changed here',2.50),(3,'c',NULL,3.00),(5,'e','new',5.00),(6,'f','also new',NULL)",
                    "INSERT INTO sync_dst VALUES (1,'a','same',1.00),(2,'b','old value',2.50),(3,'c',NULL,3.00),(4,'d','gone',4.00),(7,'g','gone too',7.00)",
                ], on: source)
            let src = TableRef(schema: schema(server), name: "sync_src")
            let dst = TableRef(schema: schema(server), name: "sync_dst")

            let preview = try await DataSynchronizer(dialect: dialect).run(
                [(source: src, target: dst)], source: source, target: target, writer: nil
            ) { _ in }
            XCTAssertEqual(preview.count, 1)
            let report = try XCTUnwrap(preview.first)
            XCTAssertNil(report.error)
            XCTAssertEqual(report.keyColumns, ["id"])
            XCTAssertEqual(report.inserts, 2, "5 and 6")
            XCTAssertEqual(report.updates, 1, "2")
            XCTAssertEqual(report.deletes, 2, "4 and 7")
            XCTAssertEqual(report.applied, 0, "a preview writes nothing")
            XCTAssertTrue(
                report.samples.contains { $0.kind == .update && $0.detail.contains("old value → changed here") },
                "\(report.samples)")
            let untouched = try await rows("sync_dst", on: source)
            XCTAssertEqual(untouched.count, 5)

            let applied = try await DataSynchronizer(dialect: dialect).run(
                [(source: src, target: dst)], source: source, target: target, writer: writer
            ) { _ in }
            XCTAssertNil(applied.first?.error)
            XCTAssertEqual(applied.first?.applied, 5)
            let after = try await rows("sync_dst", on: source)
            let expected = try await rows("sync_src", on: source)
            XCTAssertEqual(after, expected, "the target now matches the source")

            let again = try await DataSynchronizer(dialect: dialect).run(
                [(source: src, target: dst)], source: source, target: target, writer: nil
            ) { _ in }
            XCTAssertTrue(again.first?.isIdentical == true)
            await drop(on: source)
        }
    }

    func testDataSyncUsesTextKeysInBinaryOrder() async throws {
        try await withSession { session, server, dialect in
            _ = try await session.connect()
            let (leaseA, source) = try await session.lease()
            let (leaseB, target) = try await session.lease()
            defer {
                Task {
                    await session.release(leaseA)
                    await session.release(leaseB)
                }
            }
            await drop(on: source)
            // MySQL's default collation folds case, so b and B could not both be keys.
            let keyType =
                switch dialect {
                case .postgresql, .sqlite: "text"
                case .mysql: "varchar(50) COLLATE utf8mb4_bin"
                }
            let textType = dialect == .postgresql ? "text" : "varchar(50)"
            for name in ["sync_src", "sync_dst"] {
                try await run(
                    [
                        "CREATE TABLE \(name) (code \(keyType) PRIMARY KEY, id int, name \(textType), amount decimal(10,2))"
                    ], on: source)
            }
            // Mixed case and accents: collations order these differently from bytes.
            try await run(
                [
                    "INSERT INTO sync_src VALUES ('b',1,'x',1),('B',2,'x',1),('a',3,'x',1),('é',4,'x',1),('Z',5,'x',1),('_u',6,'x',1)",
                    "INSERT INTO sync_dst VALUES ('b',1,'x',1),('a',3,'x',1),('é',4,'changed',1),('z',9,'x',1)",
                ], on: source)
            let src = TableRef(schema: schema(server), name: "sync_src")
            let dst = TableRef(schema: schema(server), name: "sync_dst")
            let reports = try await DataSynchronizer(dialect: dialect).run(
                [(source: src, target: dst)], source: source, target: target, writer: nil
            ) { _ in }
            let report = try XCTUnwrap(reports.first)
            XCTAssertNil(report.error, report.error ?? "")
            XCTAssertEqual(report.inserts, 3, "B, Z, _u")
            XCTAssertEqual(report.updates, 1, "é")
            XCTAssertEqual(report.deletes, 1, "z")
            await drop(on: source)
        }
    }

    func testStructureSyncWritesCreatesAltersAndDrops() async throws {
        try await withSession { session, server, dialect in
            _ = try await session.connect()
            let (lease, connection) = try await session.lease()
            defer { Task { await session.release(lease) } }
            await drop(on: connection)
            let textType = dialect == .postgresql ? "text" : "varchar(100)"
            // The "source" and "target" are two schemas' worth of tables told apart by a
            // name filter, since the test database has one schema.
            try await run(
                [
                    "CREATE TABLE sync_only_src (id int PRIMARY KEY, name \(textType))",
                    "CREATE TABLE sync_alter (id int PRIMARY KEY, name \(textType))",
                ], on: connection)
            let ref = schema(server)
            let result = try await SchemaSynchronizer(dialect: dialect).compare(
                sourceSchema: ref, targetSchema: ref, tables: ["sync_only_src", "sync_alter"],
                source: connection.introspector, target: connection.introspector)
            XCTAssertEqual(result.items.map(\.kind), [.identical, .identical], "a schema matches itself")

            // Against a target schema where the table is missing, a create is generated.
            let missing =
                switch dialect {
                case .postgresql: SchemaRef(database: ref.database, schema: "sync_missing_schema")
                case .mysql: SchemaRef.mysql("sync_missing_db")
                case .sqlite: SchemaRef(database: ref.database, schema: "sync_missing_schema")
                }
            let created = try await SchemaSynchronizer(dialect: dialect).compare(
                sourceSchema: ref, targetSchema: missing, tables: ["sync_only_src"],
                source: connection.introspector, target: connection.introspector)
            XCTAssertEqual(created.items.count, 1)
            XCTAssertEqual(created.items.first?.kind, .create)
            let script = created.script(includingDestructive: false, droppingExtraTables: false)
            XCTAssertTrue(script.contains("CREATE TABLE"), script)
            XCTAssertTrue(script.contains("sync_only_src"), script)
            XCTAssertTrue(
                created.statements(includingDestructive: false, droppingExtraTables: false).allSatisfy {
                    !$0.isDestructive
                })
            await drop(on: connection)
        }
    }
}
