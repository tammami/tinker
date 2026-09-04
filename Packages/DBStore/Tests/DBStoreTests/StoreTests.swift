import DBCore
import Foundation
import XCTest

@testable import DBStore

final class DBStoreTests: XCTestCase {
    var directory: URL!
    var storePath: String!

    override func setUp() async throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tinker-store-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storePath = directory.appendingPathComponent("store.sqlite").path
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func makeStore() async throws -> DBStore {
        try await DBStore(path: storePath)
    }

    func makeConfig(name: String = "prod", production: Bool = false) -> ConnectionConfig {
        var config = ConnectionConfig(
            name: name, color: .red, groupPath: ["Work", "Prod"],
            dialect: .postgresql, host: "db.example", port: 5432, user: "app",
            database: "app", isProduction: production
        )
        config.passwordRef = SecretRef.forConnection(config.id, field: "password")
        return config
    }

    // MARK: - Schema

    func testMigrationsRunOnceAndAreRecorded() async throws {
        let store = try await makeStore()
        let version = try await store.database.userVersion
        XCTAssertEqual(version, StoreSchema.latestVersion)
        await store.close()

        // Reopening applies nothing further and keeps the data.
        let reopened = try await makeStore()
        let again = try await reopened.database.userVersion
        XCTAssertEqual(again, StoreSchema.latestVersion)
        await reopened.close()
    }

    func testEveryTableFromTheSpecExists() async throws {
        let store = try await makeStore()
        let rows = try await store.database.query(
            "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"
        )
        let names = Set(rows.compactMap { $0["name"].textValue })
        for expected in ["connections", "groups", "query_history", "grid_prefs", "settings"] {
            XCTAssertTrue(names.contains(expected), "missing table \(expected); have \(names.sorted())")
        }
        await store.close()
    }

    func testWALModeIsOn() async throws {
        let store = try await makeStore()
        let rows = try await store.database.query("PRAGMA journal_mode")
        XCTAssertEqual(rows.first?[0].textValue?.lowercased(), "wal")
        await store.close()
    }

    // MARK: - Connections

    func testConnectionsRoundTripAcrossReopen() async throws {
        let store = try await makeStore()
        var config = makeConfig()
        config.ssh = SSHConfig(
            host: "bastion", port: 2_222, user: "me",
            auth: .privateKey(path: "~/.ssh/id_ed25519", passphrase: nil),
            jumpHost: SSHConfig(host: "jump", user: "me", auth: .agent),
            knownHostsPolicy: .strict
        )
        config.statementTimeout = .seconds(30)
        config.options = ["application_name": "Tinker"]
        try await store.save(config)
        await store.close()

        let reopened = try await makeStore()
        let loaded = try await reopened.connections()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first, config)
        XCTAssertEqual(loaded.first?.ssh?.jumpHost?.value.host, "jump")
        XCTAssertEqual(loaded.first?.statementTimeout, .seconds(30))

        let byID = try await reopened.connection(id: config.id)
        XCTAssertEqual(byID, config)
        await reopened.close()
    }

    func testUpdatingAConnectionKeepsItsPlace() async throws {
        let store = try await makeStore()
        let first = makeConfig(name: "a")
        let second = makeConfig(name: "b")
        try await store.save(first)
        try await store.save(second)

        var edited = first
        edited.name = "a (edited)"
        try await store.save(edited)

        let loaded = try await store.connections()
        XCTAssertEqual(loaded.map(\.name), ["a (edited)", "b"])
        await store.close()
    }

    func testReorderingPersists() async throws {
        let store = try await makeStore()
        let configs = [makeConfig(name: "a"), makeConfig(name: "b"), makeConfig(name: "c")]
        for config in configs { try await store.save(config) }
        try await store.reorderConnections([configs[2].id, configs[0].id, configs[1].id])
        let loaded = try await store.connections()
        XCTAssertEqual(loaded.map(\.name), ["c", "a", "b"])
        await store.close()
    }

    func testDeletingAConnectionRemovesItsPreferencesAndHistory() async throws {
        let store = try await makeStore()
        let config = makeConfig()
        try await store.save(config)
        try await store.saveGridPreferences(
            GridPreferences(columnWidths: ["id": 80]), connectionID: config.id, table: "public.users"
        )
        try await store.record(QueryHistoryEntry(connectionID: config.id, sql: "SELECT 1", succeeded: true))

        try await store.deleteConnection(id: config.id)
        let remaining = try await store.connections()
        XCTAssertTrue(remaining.isEmpty)
        let preferences = try await store.gridPreferences(connectionID: config.id, table: "public.users")
        XCTAssertTrue(preferences.isEmpty)
        let history = try await store.history(connectionID: config.id)
        XCTAssertTrue(history.isEmpty)
        await store.close()
    }

    /// SPEC §11.3: no password may ever appear in the store file.
    func testNoSecretReachesTheStoreFile() async throws {
        let store = try await makeStore()
        let secret = "s3cr3t-should-never-be-written-\(UUID().uuidString)"
        var config = makeConfig()
        config.name = "prod"
        try await store.save(config)
        try await store.record(
            QueryHistoryEntry(
                connectionID: config.id, sql: "SELECT 1", succeeded: true
            ))
        try await store.setSetting(["theme": "dark"], for: "appearance")
        await store.close()

        // Every file the store writes, WAL and shared-memory segments included.
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let data = try Data(contentsOf: directory.appendingPathComponent(file))
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertFalse(text.contains(secret), "\(file) contains a secret")
            XCTAssertFalse(text.contains("hunter2"), "\(file) contains a password")
        }
        // The reference itself is stored, and it names the Keychain rather than a value.
        let contents = try Data(contentsOf: URL(fileURLWithPath: storePath))
        let storeText = String(decoding: contents, as: UTF8.self)
        XCTAssertTrue(storeText.contains("com.tinker.connection"))
    }

    // MARK: - Groups

    func testGroupsRoundTrip() async throws {
        let store = try await makeStore()
        try await store.save(StoredGroup(path: ["Work"], isExpanded: true, sortOrder: 0))
        try await store.save(StoredGroup(path: ["Work", "Prod"], isExpanded: false, sortOrder: 1))
        let groups = try await store.groups()
        XCTAssertEqual(groups.map(\.path), [["Work"], ["Work", "Prod"]])
        XCTAssertEqual(groups.map(\.isExpanded), [true, false])

        try await store.save(StoredGroup(path: ["Work"], isExpanded: false, sortOrder: 0))
        let updated = try await store.groups()
        XCTAssertEqual(updated.first?.isExpanded, false)

        try await store.deleteGroup(path: ["Work", "Prod"])
        let afterDelete = try await store.groups()
        XCTAssertEqual(afterDelete.count, 1)
        await store.close()
    }

    // MARK: - Query history

    func testHistoryRecordsAndSearches() async throws {
        let store = try await makeStore()
        let connectionID = UUID()
        try await store.record(
            QueryHistoryEntry(
                connectionID: connectionID, database: "app", sql: "SELECT * FROM users",
                startedAt: Date(timeIntervalSince1970: 1_000), duration: .milliseconds(12),
                rowCount: 3, succeeded: true
            ))
        try await store.record(
            QueryHistoryEntry(
                connectionID: connectionID, sql: "DROP TABLE nope",
                startedAt: Date(timeIntervalSince1970: 2_000),
                error: "relation \"nope\" does not exist", succeeded: false
            ))

        let all = try await store.history()
        XCTAssertEqual(all.count, 2)
        // Newest first.
        XCTAssertEqual(all.first?.sql, "DROP TABLE nope")
        XCTAssertFalse(all.first?.succeeded ?? true)
        XCTAssertEqual(all.first?.error, "relation \"nope\" does not exist")
        XCTAssertEqual(all.last?.duration, .milliseconds(12))
        XCTAssertEqual(all.last?.rowCount, 3)
        XCTAssertEqual(all.last?.database, "app")

        let matching = try await store.history(matching: "users")
        XCTAssertEqual(matching.count, 1)
        let otherConnection = try await store.history(connectionID: UUID())
        XCTAssertTrue(otherConnection.isEmpty)
        await store.close()
    }

    func testHistoryIsCappedAtTenThousandEntries() async throws {
        let store = try await makeStore()
        let connectionID = UUID()
        // Insert past the cap in one transaction, then record one more so the trim runs.
        let statements = (0 ..< (DBStore.queryHistoryLimit + 5)).map { index in
            """
            INSERT INTO query_history (connection_id, sql, started_at, success)
            VALUES ('\(connectionID.uuidString)', 'SELECT \(index)', \(Double(index)), 1)
            """
        }
        try await store.database.executeBatch(statements)
        try await store.record(
            QueryHistoryEntry(
                connectionID: connectionID, sql: "SELECT newest",
                startedAt: Date(timeIntervalSince1970: 1_000_000), succeeded: true
            ))

        let count = try await store.historyCount()
        XCTAssertEqual(count, DBStore.queryHistoryLimit)
        // The newest entry survived and the oldest did not.
        let newest = try await store.history(limit: 1)
        XCTAssertEqual(newest.first?.sql, "SELECT newest")
        let oldest = try await store.history(matching: "SELECT 0", limit: 1)
        XCTAssertTrue(oldest.isEmpty, "the oldest entries should have been trimmed")
        await store.close()
    }

    func testClearHistory() async throws {
        let store = try await makeStore()
        try await store.record(QueryHistoryEntry(connectionID: UUID(), sql: "SELECT 1", succeeded: true))
        try await store.clearHistory()
        let count = try await store.historyCount()
        XCTAssertEqual(count, 0)
        await store.close()
    }

    // MARK: - Grid preferences

    func testGridPreferencesRoundTrip() async throws {
        let store = try await makeStore()
        let connectionID = UUID()
        let preferences = GridPreferences(
            columnWidths: ["id": 80.5, "name": 220],
            sort: [GridSortTerm(column: "name", ascending: false)],
            filter: [StoredFilterRule(column: "status", op: "equal", values: [.string("on"), .null])]
        )
        try await store.saveGridPreferences(preferences, connectionID: connectionID, table: "public.users")
        let loaded = try await store.gridPreferences(connectionID: connectionID, table: "public.users")
        XCTAssertEqual(loaded, preferences)

        // Preferences are per table per connection.
        let other = try await store.gridPreferences(connectionID: connectionID, table: "public.orders")
        XCTAssertTrue(other.isEmpty)
        await store.close()
    }

    func testGridPreferencesAreOverwrittenNotDuplicated() async throws {
        let store = try await makeStore()
        let connectionID = UUID()
        try await store.saveGridPreferences(
            GridPreferences(columnWidths: ["id": 80]), connectionID: connectionID, table: "t"
        )
        try await store.saveGridPreferences(
            GridPreferences(columnWidths: ["id": 120]), connectionID: connectionID, table: "t"
        )
        let loaded = try await store.gridPreferences(connectionID: connectionID, table: "t")
        XCTAssertEqual(loaded.columnWidths["id"], 120)
        let rows = try await store.database.query("SELECT COUNT(*) FROM grid_prefs")
        XCTAssertEqual(rows.first?[0].intValue, 1)
        await store.close()
    }

    // MARK: - Settings

    func testSettingsRoundTripAndDefault() async throws {
        let store = try await makeStore()
        let fallback = try await store.setting("editor.font", default: "SF Mono 13")
        XCTAssertEqual(fallback, "SF Mono 13")

        try await store.setSetting("Menlo 12", for: "editor.font")
        let stored = try await store.setting("editor.font", default: "SF Mono 13")
        XCTAssertEqual(stored, "Menlo 12")

        try await store.setSetting(["nullDisplay": "NULL", "confirmOnProd": "true"], for: "grid")
        let map = try await store.setting("grid", as: [String: String].self, default: [:])
        XCTAssertEqual(map["nullDisplay"], "NULL")

        try await store.removeSetting("editor.font")
        let removed = try await store.setting("editor.font", default: "SF Mono 13")
        XCTAssertEqual(removed, "SF Mono 13")
        await store.close()
    }

    func testASettingWrittenByANewerBuildFallsBackInsteadOfCrashing() async throws {
        let store = try await makeStore()
        try await store.database.execute(
            "INSERT INTO settings (key, value) VALUES (?, ?)",
            [.text("editor.font"), .text("{\"unexpected\": true}")]
        )
        let value = try await store.setting("editor.font", default: "SF Mono 13")
        XCTAssertEqual(value, "SF Mono 13")
        await store.close()
    }
}

final class SQLiteDatabaseTests: XCTestCase {
    func testValuesRoundTripThroughEveryColumnType() async throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try await database.execute("CREATE TABLE t (i INTEGER, r REAL, s TEXT, b BLOB, n TEXT)")
        try await database.execute(
            "INSERT INTO t VALUES (?, ?, ?, ?, ?)",
            [.integer(-9_223_372_036_854_775_808), .real(1.5), .text("çé日本"), .blob(Data([0, 255])), .null]
        )
        let rows = try await database.query("SELECT i, r, s, b, n FROM t")
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row["i"], .integer(-9_223_372_036_854_775_808))
        XCTAssertEqual(row["r"], .real(1.5))
        XCTAssertEqual(row["s"], .text("çé日本"))
        XCTAssertEqual(row["b"], .blob(Data([0, 255])))
        XCTAssertEqual(row["n"], .null)
        await database.close()
    }

    func testParametersAreBoundNotInterpolated() async throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try await database.execute("CREATE TABLE t (s TEXT)")
        let hostile = "'); DROP TABLE t; --"
        try await database.execute("INSERT INTO t VALUES (?)", [.text(hostile)])
        let rows = try await database.query("SELECT s FROM t")
        XCTAssertEqual(rows.first?["s"], .text(hostile))
        await database.close()
    }

    func testTransactionRollsBackOnError() async throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try await database.execute("CREATE TABLE t (a INTEGER PRIMARY KEY)")
        try await database.execute("INSERT INTO t VALUES (1)")
        do {
            try await database.executeBatch(["INSERT INTO t VALUES (2)", "INSERT INTO t VALUES (1)"])
            XCTFail("expected the duplicate key to fail")
        } catch {
            let rows = try await database.query("SELECT COUNT(*) FROM t")
            XCTAssertEqual(rows.first?[0].intValue, 1, "the batch should have rolled back entirely")
        }
        await database.close()
    }

    func testErrorsCarryTheStatement() async throws {
        let database = try SQLiteDatabase(path: ":memory:")
        do {
            _ = try await database.query("SELECT * FROM missing_table")
            XCTFail("expected a failure")
        } catch let error as StoreError {
            XCTAssertTrue(error.description.contains("missing_table"), error.description)
        }
        await database.close()
    }
}
