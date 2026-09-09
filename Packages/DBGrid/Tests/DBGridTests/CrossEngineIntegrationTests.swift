import DBCore
import DBMySQL
import DBPostgres
import DBSQL
import DBSQLite
import DBTestKit
import Logging
import XCTest

@testable import DBGrid

/// Transfer and synchronisation between engines: every ordered pair of configured servers
/// that speak different dialects. SQLite is always one of them, so with one server
/// configured the pair runs in both directions.
extension ScriptTransferIntegrationTests {
    /// A session per server, connected.
    func openSessions() async throws -> [(session: ConnectionSession, server: TestServer)] {
        var sessions: [(ConnectionSession, TestServer)] = []
        for server in try await allServers() {
            let config = ConnectionConfig(
                name: "cross-\(server.engine.rawValue)", dialect: server.engine.dialect, host: server.host,
                port: server.port, user: server.user, database: server.database)
            let secrets = EphemeralSecretStore()
            var withPassword = config
            if let password = server.password {
                let reference = SecretRef.forConnection(config.id, field: "password")
                try await secrets.setSecret(password, for: reference)
                withPassword.passwordRef = reference
            }
            let session = ConnectionSession(
                config: withPassword, registry: Self.registry, secrets: secrets, logger: logger)
            _ = try await session.connect()
            sessions.append((session, server))
        }
        return sessions
    }

    func testATransferCrossesEnginesWithItsKeysAndRows() async throws {
        let sessions = try await openSessions()
        defer { Task { for entry in sessions { await entry.session.disconnect() } } }
        let pairs = sessions.flatMap { source in
            sessions.filter { $0.server.engine != source.server.engine }.map { (source: source, target: $0) }
        }
        if pairs.isEmpty { throw XCTSkip("one engine only; a cross-engine transfer needs two") }

        for pair in pairs {
            let sourceDialect = pair.source.server.engine.dialect
            let targetDialect = pair.target.server.engine.dialect
            let (sourceLease, source) = try await pair.source.session.lease()
            let (targetLease, target) = try await pair.target.session.lease()
            defer {
                Task {
                    await pair.source.session.release(sourceLease)
                    await pair.target.session.release(targetLease)
                }
            }
            try await createFixture(dialect: sourceDialect, on: source)
            try await dropFixture(dialect: targetDialect, on: target)

            let selection = try await selection(
                prefix: "xfer_", schema: pair.source.server.fixtureSchema, introspector: source.introspector)
            XCTAssertTrue(selection.tables.contains { $0.name == "xfer_view" }, "the view is in the selection")
            var options = DumpOptions.preferred(for: targetDialect)
            options.includeDrop = true
            let outcome = try await TransferRunner.run(
                selection, from: source, to: target, dialect: sourceDialect, targetDialect: targetDialect,
                options: options, renaming: DumpRenaming(schema: pair.target.server.fixtureSchema)
            ) { _ in }
            let label = "\(sourceDialect.rawValue) → \(targetDialect.rawValue)"
            XCTAssertTrue(
                outcome.execution.failures.isEmpty,
                "\(label): " + outcome.execution.failures.map(\.description).joined(separator: "\n"))
            XCTAssertEqual(outcome.dump.rows, 7, label)
            XCTAssertTrue(outcome.dump.notes.contains { $0.contains("view") }, "\(label): the view stays behind, and says so")

            let parents = try await count("xfer_parent", on: target)
            let children = try await count("xfer_child", on: target)
            XCTAssertEqual(parents, 3, label)
            XCTAssertEqual(children, 4, label)

            let rows = try await target.executeCollecting(
                "SELECT id, parent_id, note, payload, amount, flag FROM xfer_child ORDER BY id")
            XCTAssertEqual(rows.rows.count, 4, label)
            XCTAssertEqual(rows.rows[0][2], .string("first"), label)
            XCTAssertEqual(rows.rows[0][3], .bytes(Data([0x00, 0xFF, 0x10])), label)
            XCTAssertEqual(Decimal(string: rows.rows[0][4].text ?? ""), Decimal(string: "12.5"), label)
            XCTAssertTrue(rows.rows[1][2].isNull, label)
            XCTAssertEqual(rows.rows[2][2], .string("tab\there"), label)
            XCTAssertEqual(rows.rows[3][2], .string("ünïcödé — 日本語"), label)
            // flag: a boolean on every engine, spelled as the target spells it.
            let flag = rows.rows[0][5]
            XCTAssertTrue(flag == .bool(true) || flag == .int(1), "\(label): flag arrived as \(flag)")
            let names = try await target.executeCollecting("SELECT name FROM xfer_parent ORDER BY id")
            XCTAssertEqual(names.rows[2][0], .string("Line\nBreak\tTab\\Slash 'quote'"), label)

            // The structure crossed too: a key on the child, and the parent's key.
            let child = pair.target.server.table("xfer_child")
            let keys = try await target.introspector.foreignKeys(of: child)
            XCTAssertEqual(keys.count, 1, label)
            XCTAssertEqual(keys.first?.referencedTable.name, "xfer_parent", label)
            let parentKey = try await target.introspector.primaryKey(of: pair.target.server.table("xfer_parent"))
            XCTAssertEqual(parentKey, ["id"], label)
            let columns = try await target.introspector.columns(of: child)
            XCTAssertEqual(columns.map(\.name), ["id", "parent_id", "note", "payload", "amount", "flag", "created"] + (sourceDialect == .postgresql ? ["tags"] : []), label)

            // A second insert on the target keeps numbering after the copied rows.
            _ = try await target.executeCollecting("INSERT INTO xfer_parent (name) VALUES ('after')")
            let next = try await target.executeCollecting("SELECT max(id) FROM xfer_parent")
            XCTAssertEqual(Int64(next.firstText ?? ""), 4, "\(label): the identity resumes after the copied rows")

            TestLog.note("cross-engine transfer \(label): \(outcome.dump.rows) rows, notes: \(outcome.dump.notes.joined(separator: " | "))")
            try await dropFixture(dialect: targetDialect, on: target)
            try await dropFixture(dialect: sourceDialect, on: source)
        }
    }
}

extension SyncIntegrationTests {
    func openSessions() async throws -> [(session: ConnectionSession, server: TestServer)] {
        let sqlite = try TestEnvironment.servers(for: .sqlite)
        if !sqlite.isEmpty { try await SQLiteFixtures.prepare() }
        let servers =
            ((try? TestEnvironment.servers(for: .postgresql)) ?? [])
            + ((try? TestEnvironment.servers(for: .mysql)) ?? []) + sqlite
        var sessions: [(ConnectionSession, TestServer)] = []
        for server in servers {
            let config = ConnectionConfig(
                name: "cross-\(server.engine.rawValue)", dialect: server.engine.dialect, host: server.host,
                port: server.port, user: server.user, database: server.database)
            let secrets = EphemeralSecretStore()
            var withPassword = config
            if let password = server.password {
                let reference = SecretRef.forConnection(config.id, field: "password")
                try await secrets.setSecret(password, for: reference)
                withPassword.passwordRef = reference
            }
            let session = ConnectionSession(
                config: withPassword, registry: Self.registry, secrets: secrets, logger: logger)
            _ = try await session.connect()
            sessions.append((session, server))
        }
        return sessions
    }

    /// Structure synchronisation writes the target's CREATE for a source table on another
    /// engine, and data synchronisation then fills and reconciles it.
    func testStructureAndDataSynchronizationCrossEngines() async throws {
        let sessions = try await openSessions()
        defer { Task { for entry in sessions { await entry.session.disconnect() } } }
        let pairs = sessions.flatMap { source in
            sessions.filter { $0.server.engine != source.server.engine }.map { (source: source, target: $0) }
        }
        if pairs.isEmpty { throw XCTSkip("one engine only; a cross-engine synchronisation needs two") }

        for pair in pairs {
            let sourceDialect = pair.source.server.engine.dialect
            let targetDialect = pair.target.server.engine.dialect
            let label = "\(sourceDialect.rawValue) → \(targetDialect.rawValue)"
            let (sourceLease, source) = try await pair.source.session.lease()
            let (targetLease, target) = try await pair.target.session.lease()
            let (writerLease, writer) = try await pair.target.session.lease()
            defer {
                Task {
                    await pair.source.session.release(sourceLease)
                    await pair.target.session.release(targetLease)
                    await pair.target.session.release(writerLease)
                }
            }
            await drop(on: source)
            await drop(on: target)
            let textType: String =
                switch sourceDialect {
                case .postgresql: "text"
                case .mysql: "varchar(100)"
                case .sqlite: "TEXT"
                }
            let intType = sourceDialect == .sqlite ? "INTEGER" : "int"
            try await run(
                [
                    "CREATE TABLE sync_src (id \(intType) PRIMARY KEY, code \(textType) NOT NULL, name \(textType), amount decimal(10,2))",
                    "INSERT INTO sync_src VALUES (1,'a','same',1.00),(2,'b','changed',2.50),(3,'c',NULL,3.00),(5,'e','new',5.00),(6,'f','also new',NULL)",
                ], on: source)

            // Structure: the target has no such table, so the comparison writes its CREATE.
            let sourceSchema = pair.source.server.fixtureSchema
            let targetSchema = pair.target.server.fixtureSchema
            let compared = try await SchemaSynchronizer(dialect: targetDialect, sourceDialect: sourceDialect).compare(
                sourceSchema: sourceSchema, targetSchema: targetSchema, tables: ["sync_src"],
                source: source.introspector, target: target.introspector)
            XCTAssertEqual(compared.items.map(\.kind), [.create], label)
            let statements = compared.statements(includingDestructive: false, droppingExtraTables: false)
            for statement in statements {
                _ = try await writer.executeCollecting(statement.sql)
            }
            let created = try await target.introspector.columns(of: pair.target.server.table("sync_src"))
            XCTAssertEqual(created.map(\.name), ["id", "code", "name", "amount"], label)

            // Once created, the structures compare as identical across the engines.
            let again = try await SchemaSynchronizer(dialect: targetDialect, sourceDialect: sourceDialect).compare(
                sourceSchema: sourceSchema, targetSchema: targetSchema, tables: ["sync_src"],
                source: source.introspector, target: target.introspector)
            XCTAssertEqual(again.items.map(\.kind), [.identical], "\(label): " + again.items.flatMap { $0.statements.map(\.sql) }.joined(separator: "\n"))

            // Data: five inserts, applied, then nothing left to do.
            let pairsToSync = [(source: pair.source.server.table("sync_src"), target: pair.target.server.table("sync_src"))]
            let synchronizer = DataSynchronizer(dialect: targetDialect, sourceDialect: sourceDialect)
            let first = try await synchronizer.run(pairsToSync, source: source, target: target, writer: writer) { _ in }
            XCTAssertEqual(first.first?.inserts, 5, label)
            XCTAssertEqual(first.first?.applied, 5, label)
            let count = try await target.executeCollecting("SELECT count(*) FROM sync_src").firstText
            XCTAssertEqual(count, "5", label)
            let settled = try await synchronizer.run(pairsToSync, source: source, target: target, writer: nil) { _ in }
            XCTAssertEqual(settled.first?.differences, 0, "\(label): " + (settled.first?.samples.map(\.detail).joined(separator: "; ") ?? ""))

            // A change on the target is found and put back.
            _ = try await writer.executeCollecting("UPDATE sync_src SET name = 'drifted' WHERE id = 2")
            _ = try await writer.executeCollecting("DELETE FROM sync_src WHERE id = 6")
            let drifted = try await synchronizer.run(pairsToSync, source: source, target: target, writer: writer) { _ in }
            XCTAssertEqual(drifted.first?.updates, 1, label)
            XCTAssertEqual(drifted.first?.inserts, 1, label)
            let restored = try await target.executeCollecting("SELECT name FROM sync_src WHERE id = 2").firstText
            XCTAssertEqual(restored, "changed", label)
            TestLog.note("cross-engine sync \(label): create + 5 inserts + 1 update + 1 insert")
            await drop(on: source)
            await drop(on: target)
        }
    }
}
