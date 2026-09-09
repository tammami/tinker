import DBCore
import DBMySQL
import DBPostgres
import DBSQLite
import DBSQL
import DBTestKit
import Logging
import XCTest

@testable import DBGrid

/// Dump, import and copy–paste against the real servers: what goes out must come back
/// identical, on PostgreSQL through COPY and on MySQL through INSERT batches.
final class ScriptTransferIntegrationTests: XCTestCase {
    var logger: Logger {
        var logger = Logger(label: "test.transfer")
        logger.logLevel = .critical
        return logger
    }

    static var registry: DriverRegistry {
        DriverRegistry([.postgresql: PostgresDriver.self, .mysql: MySQLDriver.self, .sqlite: SQLiteDriver.self])
    }

    func allServers() async throws -> [TestServer] {
        let sqlite = try TestEnvironment.servers(for: .sqlite)
        if !sqlite.isEmpty { try await SQLiteFixtures.prepare() }
        let all =
            ((try? TestEnvironment.servers(for: .postgresql)) ?? [])
            + ((try? TestEnvironment.servers(for: .mysql)) ?? []) + sqlite
        if all.isEmpty { throw XCTSkip("no test server is configured and SQLite is disabled") }
        return all
    }

    func withSession(_ body: (ConnectionSession, TestServer, SQLDialect) async throws -> Void) async throws {
        for server in try await allServers() {
            let dialect = server.engine.dialect
            let config = ConnectionConfig(
                name: "transfer-test", dialect: dialect, host: server.host, port: server.port, user: server.user,
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

    func count(_ table: String, on connection: any SQLConnection) async throws -> Int64 {
        let result = try await connection.executeCollecting("SELECT count(*) FROM \(table)")
        guard let value = result.rows.first?.first else { return -1 }
        switch value {
        case let .int(number): return number
        case let .uint(number): return Int64(number)
        default: return Int64(value.text ?? "") ?? -1
        }
    }

    /// The fixture: a parent, a child that references it, awkward values, and a view.
    func createFixture(dialect: SQLDialect, on connection: any SQLConnection) async throws {
        try await dropFixture(dialect: dialect, on: connection)
        switch dialect {
        case .postgresql:
            try await run(
                [
                    "CREATE TABLE xfer_parent (id serial PRIMARY KEY, name text NOT NULL, kind text DEFAULT 'plain')",
                    """
                    CREATE TABLE xfer_child (
                        id bigserial PRIMARY KEY,
                        parent_id integer NOT NULL REFERENCES xfer_parent(id),
                        note text,
                        payload bytea,
                        amount numeric(12,4),
                        flag boolean,
                        created timestamptz DEFAULT now(),
                        tags text[]
                    )
                    """,
                    "CREATE INDEX xfer_child_note_idx ON xfer_child (note)",
                    "CREATE VIEW xfer_view AS SELECT p.name, count(c.id) AS children FROM xfer_parent p LEFT JOIN xfer_child c ON c.parent_id = p.id GROUP BY p.name",
                    "INSERT INTO xfer_parent (name) VALUES ('Ada'), ('Grace'), (E'Line\\nBreak\\tTab\\\\Slash ''quote''')",
                    """
                    INSERT INTO xfer_child (parent_id, note, payload, amount, flag, tags) VALUES
                        (1, 'first', '\\x00ff10'::bytea, 12.5000, true, ARRAY['a','b']),
                        (2, NULL, NULL, NULL, false, NULL),
                        (3, E'tab\\there', '\\xdeadbeef'::bytea, -0.0001, NULL, ARRAY['x']),
                        (1, 'ünïcödé — 日本語', NULL, 99999999.9999, true, '{}')
                    """,
                ], on: connection)
        case .mysql:
            try await run(
                [
                    "CREATE TABLE xfer_parent (id int AUTO_INCREMENT PRIMARY KEY, name varchar(200) NOT NULL, kind varchar(20) DEFAULT 'plain')",
                    """
                    CREATE TABLE xfer_child (
                        id bigint AUTO_INCREMENT PRIMARY KEY,
                        parent_id int NOT NULL,
                        note text,
                        payload blob,
                        amount decimal(12,4),
                        flag tinyint(1),
                        created timestamp NULL DEFAULT CURRENT_TIMESTAMP,
                        CONSTRAINT xfer_child_parent FOREIGN KEY (parent_id) REFERENCES xfer_parent(id),
                        INDEX xfer_child_note_idx (note(50))
                    )
                    """,
                    "CREATE VIEW xfer_view AS SELECT p.name, count(c.id) AS children FROM xfer_parent p LEFT JOIN xfer_child c ON c.parent_id = p.id GROUP BY p.name",
                    "INSERT INTO xfer_parent (name) VALUES ('Ada'), ('Grace'), ('Line\\nBreak\\tTab\\\\Slash ''quote''')",
                    """
                    INSERT INTO xfer_child (parent_id, note, payload, amount, flag) VALUES
                        (1, 'first', X'00FF10', 12.5000, 1),
                        (2, NULL, NULL, NULL, 0),
                        (3, 'tab\\there', X'DEADBEEF', -0.0001, NULL),
                        (1, 'ünïcödé — 日本語', NULL, 99999999.9999, 1)
                    """,
                ], on: connection)
        case .sqlite:
            try await run(
                [
                    "CREATE TABLE xfer_parent (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, kind TEXT DEFAULT 'plain')",
                    """
                    CREATE TABLE xfer_child (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        parent_id INTEGER NOT NULL,
                        note TEXT,
                        payload BLOB,
                        amount DECIMAL(12,4),
                        flag BOOLEAN,
                        created DATETIME DEFAULT CURRENT_TIMESTAMP,
                        CONSTRAINT xfer_child_parent FOREIGN KEY (parent_id) REFERENCES xfer_parent(id)
                    )
                    """,
                    "CREATE INDEX xfer_child_note_idx ON xfer_child (note)",
                    "CREATE VIEW xfer_view AS SELECT p.name, count(c.id) AS children FROM xfer_parent p LEFT JOIN xfer_child c ON c.parent_id = p.id GROUP BY p.name",
                    // SQLite knows no escapes inside a literal: control characters come from char().
                    "INSERT INTO xfer_parent (name) VALUES ('Ada'), ('Grace'), ('Line' || char(10) || 'Break' || char(9) || 'Tab\\Slash ''quote''')",
                    """
                    INSERT INTO xfer_child (parent_id, note, payload, amount, flag) VALUES
                        (1, 'first', X'00FF10', '12.5000', 1),
                        (2, NULL, NULL, NULL, 0),
                        (3, 'tab' || char(9) || 'here', X'DEADBEEF', '-0.0001', NULL),
                        (1, 'ünïcödé — 日本語', NULL, '99999999.9999', 1)
                    """,
                ], on: connection)
        }
    }

    func dropFixture(dialect: SQLDialect, on connection: any SQLConnection) async throws {
        let cascade = dialect == .postgresql ? " CASCADE" : ""
        for name in ["xfer_view", "xfer_view_copy"] {
            _ = try? await connection.executeCollecting("DROP VIEW IF EXISTS \(name)\(cascade)")
        }
        for name in [
            "xfer_child", "xfer_parent", "xfer_child_copy", "xfer_parent_copy", "xfer_big", "xfer_big_copy",
            "xfer_script",
        ] {
            _ = try? await connection.executeCollecting("DROP TABLE IF EXISTS \(name)\(cascade)")
        }
    }

    func selection(
        prefix: String, schema: SchemaRef, introspector: any SchemaIntrospector
    ) async throws -> DumpSelection {
        let tables = try await introspector.tables(in: schema).filter {
            $0.name.hasPrefix(prefix) && !$0.name.hasSuffix("_copy")
        }
        return DumpSelection(schema: schema, tables: tables)
    }

    func snapshot(on connection: any SQLConnection) async throws -> [[DBValue]] {
        let parents = try await connection.executeCollecting("SELECT id, name, kind FROM xfer_parent ORDER BY id")
        let children = try await connection.executeCollecting(
            "SELECT id, parent_id, note, payload, amount, flag FROM xfer_child ORDER BY id")
        return parents.rows + children.rows
    }

    // MARK: - Tests

    func testDumpToFileAndImportRestoresEverything() async throws {
        try await withSession { session, server, dialect in
            _ = try await session.connect()
            let (lease, connection) = try await session.lease()
            defer { Task { await session.release(lease) } }
            for compress in [false, true] {
                try await createFixture(dialect: dialect, on: connection)
                let before = try await snapshot(on: connection)
                XCTAssertEqual(before.count, 7)
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("xfer-\(UUID().uuidString).sql" + (compress ? ".gz" : ""))
                defer { try? FileManager.default.removeItem(at: url) }

                // Dump.
                var options = DumpOptions.preferred(for: dialect)
                options.includeDrop = true
                let dumper = DatabaseDumper(dialect: dialect, options: options)
                let selection = try await selection(
                    prefix: "xfer_", schema: schema(server), introspector: connection.introspector)
                XCTAssertEqual(selection.tables.count, 3, "two tables and a view")
                let channel = ScriptChannel()
                let writer = try ScriptFileWriter(url: url, dialect: dialect, compress: compress)
                async let dumped = dumper.run(selection, on: connection, into: channel) { _ in }
                while let chunk = try await channel.next() { try writer.write(chunk) }
                try writer.finish()
                let outcome = try await dumped
                XCTAssertEqual(outcome.tables, 2)
                XCTAssertEqual(outcome.rows, 7)

                // The file is what the engine's own client would accept.
                if !compress {
                    let text = try String(contentsOf: url, encoding: .utf8)
                    XCTAssertTrue(text.contains("xfer_view"), "the view is in the dump")
                    if dialect == .postgresql {
                        XCTAssertTrue(text.contains("FROM stdin;\n"), "PostgreSQL data goes as COPY")
                        XCTAssertTrue(text.contains("\\.\n"), "COPY blocks end the way pg_dump ends them")
                        XCTAssertTrue(text.contains("serial"), "serial columns restore their sequences")
                    } else {
                        XCTAssertTrue(text.contains("INSERT INTO"), "MySQL data goes as INSERT")
                        XCTAssertFalse(text.contains("DEFINER="), "definers are left out")
                    }
                }

                // Wipe, then import.
                try await dropFixture(dialect: dialect, on: connection)
                let restored = try await ScriptImportRunner.run(
                    url: url, dialect: dialect, options: ScriptExecutionOptions(), on: connection
                ) { _ in }
                XCTAssertTrue(restored.failures.isEmpty, restored.failures.map(\.description).joined(separator: "\n"))
                XCTAssertGreaterThan(restored.statements, 5)
                let after = try await snapshot(on: connection)
                XCTAssertEqual(after, before, "every value survives the round trip (\(compress ? "gzip" : "plain"))")
                let viewRows = try await connection.executeCollecting("SELECT * FROM xfer_view ORDER BY 1")
                XCTAssertEqual(viewRows.rows.count, 3, "the view came back")

                // Sequences continue after the restored rows.
                _ = try await connection.executeCollecting("INSERT INTO xfer_parent (name) VALUES ('Linus')")
                let next = try await connection.executeCollecting("SELECT max(id) FROM xfer_parent")
                XCTAssertEqual(next.rows.first?.first?.text, "4")
            }
            try await dropFixture(dialect: dialect, on: connection)
        }
    }

    func testCopyPasteBetweenConnectionsRenamesTables() async throws {
        try await withSession { session, server, dialect in
            _ = try await session.connect()
            let (sourceLease, source) = try await session.lease()
            let (targetLease, target) = try await session.lease()
            defer {
                Task {
                    await session.release(sourceLease)
                    await session.release(targetLease)
                }
            }
            try await createFixture(dialect: dialect, on: source)
            let before = try await snapshot(on: source)

            var options = DumpOptions.preferred(for: dialect)
            options.includeDrop = true
            let renaming = DumpRenaming(tableNames: [
                "xfer_parent": "xfer_parent_copy", "xfer_child": "xfer_child_copy", "xfer_view": "xfer_view_copy",
            ])
            let selection = try await selection(
                prefix: "xfer_", schema: schema(server), introspector: source.introspector)
            let outcome = try await TransferRunner.run(
                selection, from: source, to: target, dialect: dialect, options: options, renaming: renaming
            ) { _ in }
            XCTAssertTrue(
                outcome.execution.failures.isEmpty,
                outcome.execution.failures.map(\.description).joined(separator: "\n"))
            XCTAssertEqual(outcome.dump.rows, 7)

            let parents = try await source.executeCollecting("SELECT id, name, kind FROM xfer_parent_copy ORDER BY id")
            let children = try await source.executeCollecting(
                "SELECT id, parent_id, note, payload, amount, flag FROM xfer_child_copy ORDER BY id")
            XCTAssertEqual(parents.rows + children.rows, before, "the pasted copy holds the same rows")
            let originals = try await snapshot(on: source)
            XCTAssertEqual(originals, before, "the source is untouched")
            let viewRows = try await source.executeCollecting("SELECT * FROM xfer_view_copy")
            XCTAssertEqual(viewRows.rows.count, 3, "the view was renamed too")
            try await dropFixture(dialect: dialect, on: source)
        }
    }

    func testLargeTableStreamsWithoutBeingHeld() async throws {
        try await withSession { session, server, dialect in
            _ = try await session.connect()
            let (lease, connection) = try await session.lease()
            defer { Task { await session.release(lease) } }
            try await dropFixture(dialect: dialect, on: connection)
            let rows = 200_000
            switch dialect {
            case .postgresql:
                try await run(
                    [
                        "CREATE TABLE xfer_big (id integer PRIMARY KEY, label text, amount numeric(10,2))",
                        "INSERT INTO xfer_big SELECT g, 'row ' || g, g * 1.5 FROM generate_series(1, \(rows)) g",
                    ], on: connection)
            case .mysql:
                try await run(
                    [
                        "CREATE TABLE xfer_big (id int PRIMARY KEY, label varchar(40), amount decimal(10,2))",
                        "SET SESSION cte_max_recursion_depth = \(rows + 10)",
                        "INSERT INTO xfer_big WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM s WHERE n < \(rows)) SELECT n, CONCAT('row ', n), n * 1.5 FROM s",
                    ], on: connection)
            case .sqlite:
                try await run(
                    [
                        "CREATE TABLE xfer_big (id INTEGER PRIMARY KEY, label TEXT, amount NUMERIC(10,2))",
                        "INSERT INTO xfer_big WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM s WHERE n < \(rows)) SELECT n, 'row ' || n, n * 1.5 FROM s",
                    ], on: connection)
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(
                "xfer-big-\(UUID().uuidString).sql.gz")
            defer { try? FileManager.default.removeItem(at: url) }

            // How long the server takes to hand the rows over at all, for comparison.
            let selectStarted = ContinuousClock.now
            var streamed = 0
            for try await event in connection.execute("SELECT id, label, amount FROM xfer_big", parameters: []) {
                if case let .rows(batch) = event { streamed += batch.count }
            }
            let selectTime = selectStarted.duration(to: .now)
            XCTAssertEqual(streamed, rows)

            let started = ContinuousClock.now
            let dumper = DatabaseDumper(dialect: dialect, options: .preferred(for: dialect))
            let selection = try await selection(
                prefix: "xfer_big", schema: schema(server), introspector: connection.introspector)
            let channel = ScriptChannel()
            let writer = try ScriptFileWriter(url: url, dialect: dialect, compress: true)
            async let dumped = dumper.run(selection, on: connection, into: channel) { _ in }
            while let chunk = try await channel.next() { try writer.write(chunk) }
            try writer.finish()
            _ = try await dumped
            let dumpTime = started.duration(to: .now)

            try await dropFixture(dialect: dialect, on: connection)
            let importStarted = ContinuousClock.now
            let reports = ReportCounter()
            let outcome = try await ScriptImportRunner.run(
                url: url, dialect: dialect, options: ScriptExecutionOptions(), on: connection
            ) { _ in reports.increment() }
            let importTime = importStarted.duration(to: .now)
            XCTAssertTrue(outcome.failures.isEmpty, outcome.failures.map(\.description).joined(separator: "\n"))
            XCTAssertEqual(outcome.rows, Int64(rows))
            let restoredRows = try await count("xfer_big", on: connection)
            XCTAssertEqual(restoredRows, Int64(rows))
            XCTAssertGreaterThan(reports.count, 1, "progress is reported along the way")
            TestLog.note(
                "\(dialect): plain SELECT streamed \(rows) rows in \(selectTime); dumped in \(dumpTime), imported in \(importTime), file \(writer.bytesWritten) bytes"
            )
            try await dropFixture(dialect: dialect, on: connection)
        }
    }

    func testFailuresCarryTheServerMessageAndTheLine() async throws {
        try await withSession { session, _, dialect in
            _ = try await session.connect()
            let (lease, connection) = try await session.lease()
            defer { Task { await session.release(lease) } }
            try await dropFixture(dialect: dialect, on: connection)
            let script = """
                CREATE TABLE xfer_script (id int PRIMARY KEY, name varchar(20));
                INSERT INTO xfer_script VALUES (1, 'one');
                INSERT INTO xfer_script VALUES (1, 'duplicate');
                INSERT INTO xfer_script VALUES (2, 'two');
                """
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(
                "xfer-fail-\(UUID().uuidString).sql")
            defer { try? FileManager.default.removeItem(at: url) }
            try Data(script.utf8).write(to: url)

            // Stop on the first error: the batch rolls back and the failure is precise.
            do {
                _ = try await ScriptImportRunner.run(
                    url: url, dialect: dialect, options: ScriptExecutionOptions(), on: connection
                ) { _ in }
                XCTFail("a duplicate key must stop the import")
            } catch let ScriptExecutionError.stopped(failure, outcome) {
                XCTAssertEqual(failure.line, 3)
                XCTAssertEqual(failure.statementNumber, 3)
                // Each engine's own words for the same violation.
                let expectedWords = dialect == .sqlite ? "unique constraint failed" : "duplicate"
                XCTAssertTrue(failure.message.lowercased().contains(expectedWords), failure.message)
                XCTAssertEqual(outcome.statements, 2)
            }
            // MySQL's DDL commits on its own; PostgreSQL rolled the table back with the batch.
            if dialect == .postgresql {
                do {
                    _ = try await count("xfer_script", on: connection)
                    XCTFail("the table was created inside the batch that rolled back")
                } catch {}
            }
            try await dropFixture(dialect: dialect, on: connection)

            // Continue: the good statements run, the bad one is remembered.
            var lenient = ScriptExecutionOptions()
            lenient.stopOnError = false
            let outcome = try await ScriptImportRunner.run(url: url, dialect: dialect, options: lenient, on: connection)
            { _ in }
            XCTAssertEqual(outcome.failures.count, 1)
            XCTAssertEqual(outcome.failures.first?.line, 3)
            XCTAssertEqual(outcome.statements, 3)
            let survivors = try await count("xfer_script", on: connection)
            XCTAssertEqual(survivors, 2)
            try await dropFixture(dialect: dialect, on: connection)
        }
    }

    func testEngineDumpsFromTheServersOwnToolsImport() async throws {
        try await withSession { session, server, dialect in
            _ = try await session.connect()
            let (lease, connection) = try await session.lease()
            defer { Task { await session.release(lease) } }
            try await dropFixture(dialect: dialect, on: connection)
            let script: String
            switch dialect {
            case .postgresql:
                script = """
                    --
                    -- PostgreSQL database dump
                    --
                    \\restrict abcdef
                    SET statement_timeout = 0;
                    SELECT pg_catalog.set_config('search_path', '', false);
                    SET check_function_bodies = false;

                    CREATE TABLE public.xfer_script (
                        id integer NOT NULL,
                        name text,
                        note text
                    );

                    COPY public.xfer_script (id, name, note) FROM stdin;
                    1\tMonas\t\\N
                    2\tKota\\tTua\tline\\nbreak
                    3\tBack\\\\slash\t
                    \\.

                    ALTER TABLE ONLY public.xfer_script ADD CONSTRAINT xfer_script_pkey PRIMARY KEY (id);
                    \\unrestrict abcdef
                    """
            case .mysql:
                script = """
                    -- MySQL dump 10.13
                    /*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
                    /*!40101 SET NAMES utf8mb4 */;
                    /*!40014 SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0 */;
                    DROP TABLE IF EXISTS `xfer_script`;
                    /*!40101 SET @saved_cs_client     = @@character_set_client */;
                    CREATE TABLE `xfer_script` (
                      `id` int NOT NULL,
                      `name` varchar(50) DEFAULT NULL,
                      `note` text,
                      PRIMARY KEY (`id`)
                    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
                    /*!40101 SET character_set_client = @saved_cs_client */;
                    LOCK TABLES `xfer_script` WRITE;
                    /*!40000 ALTER TABLE `xfer_script` DISABLE KEYS */;
                    INSERT INTO `xfer_script` VALUES (1,'Monas',NULL),(2,'Kota\\tTua','line\\nbreak'),(3,'Back\\\\slash','');
                    /*!40000 ALTER TABLE `xfer_script` ENABLE KEYS */;
                    UNLOCK TABLES;
                    /*!40014 SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS */;
                    """
            case .sqlite:
                // What `sqlite3 file .dump` writes, with a trigger: its body holds
                // semicolons and a CASE … END, and must arrive as one statement.
                script = """
                    PRAGMA foreign_keys=OFF;
                    BEGIN TRANSACTION;
                    CREATE TABLE xfer_script (
                      id INTEGER NOT NULL,
                      name TEXT,
                      note TEXT,
                      PRIMARY KEY (id)
                    );
                    INSERT INTO xfer_script VALUES(1,'Monas',NULL);
                    INSERT INTO xfer_script VALUES(2,'Kota' || char(9) || 'Tua','line' || char(10) || 'break');
                    INSERT INTO xfer_script VALUES(3,'Back\\slash','');
                    CREATE TRIGGER xfer_script_touch AFTER UPDATE ON xfer_script
                    BEGIN
                      UPDATE xfer_script SET note = CASE WHEN NEW.note IS NULL THEN '' ELSE NEW.note END WHERE id = NEW.id;
                    END;
                    COMMIT;
                    """
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(
                "xfer-engine-\(UUID().uuidString).sql")
            defer { try? FileManager.default.removeItem(at: url) }
            try Data(script.utf8).write(to: url)
            let outcome = try await ScriptImportRunner.run(
                url: url, dialect: dialect, options: ScriptExecutionOptions(), on: connection
            ) { _ in }
            XCTAssertTrue(outcome.failures.isEmpty, outcome.failures.map(\.description).joined(separator: "\n"))
            let rows = try await connection.executeCollecting("SELECT id, name, note FROM xfer_script ORDER BY id")
            XCTAssertEqual(rows.rows.count, 3)
            XCTAssertEqual(rows.rows[1][1].text, "Kota\tTua")
            XCTAssertEqual(rows.rows[1][2].text, "line\nbreak")
            XCTAssertEqual(rows.rows[2][1].text, "Back\\slash")
            XCTAssertTrue(rows.rows[0][2].isNull)
            try await dropFixture(dialect: dialect, on: connection)
        }
    }
}

/// Counts progress reports arriving from the import's own tasks.
private final class ReportCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}
