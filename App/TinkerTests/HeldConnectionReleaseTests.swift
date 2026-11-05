import DBCore
import DBSQLite
import DBStore
import Foundation
import XCTest

@testable import Tinker

/// A query tab gives its connection back when idle, and that takes a moment. Whatever the tab
/// does next must not land on the connection on its way out.
///
/// Runs on a SQLite file of its own and a throwaway store, so it reaches no server. What a
/// commit landed is read through another connection, which an open transaction hides it from.
@MainActor
final class HeldConnectionReleaseTests: XCTestCase {
    private var directory: URL!
    private var environment: AppEnvironment!
    private var config: ConnectionConfig!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("tinker-held-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        environment = AppEnvironment(
            secrets: EphemeralSecretStore(), storePath: directory.appendingPathComponent("store.sqlite").path)
        await environment.load()
        config = ConnectionConfig(
            name: "held-test", dialect: .sqlite, host: "", port: 0, user: "",
            database: directory.appendingPathComponent("data.sqlite").path,
            options: [SQLiteDriver.OptionKey.createIfMissing: "true"])
        await environment.save(config)
        let session = try XCTUnwrap(environment.session(for: config.id))
        _ = try await session.connect()
        try await session.withLease { connection in
            _ = try await connection.executeCollecting("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)")
            _ = try await connection.executeCollecting("INSERT INTO items VALUES (1, 'original')")
        }
    }

    override func tearDown() async throws {
        for session in environment.sessions(for: config.id) { await session.disconnect() }
        environment = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func committedName() async throws -> String? {
        let session = try XCTUnwrap(environment.session(for: config.id))
        let result = try await session.withLease { connection in
            try await connection.executeCollecting("SELECT name FROM items WHERE id = 1")
        }
        return result.firstText
    }

    private func openResult(in query: QueryTabController) async throws -> Int {
        query.sql = "SELECT id, name FROM items ORDER BY id"
        query.caretOffset = 0
        query.run(all: true)
        for _ in 0 ..< 500 {
            if !query.isRunning, query.results.first?.statement == query.sql { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let grid = try XCTUnwrap(query.results.first?.grid)
        XCTAssertTrue(grid.isEditable, grid.readOnlyReason ?? "")
        return try XCTUnwrap(grid.columns.firstIndex { $0.name == "name" })
    }

    /// Auto-commit is turned off and an edit written straight after a write, while the tab
    /// is giving that write's connection back. The edit opened its transaction on the
    /// departing connection and Commit then found no connection to send it on: the edit was
    /// lost with "Committed" on screen, and its row stayed locked.
    func testAnEditWrittenAsTheConnectionGoesBackReachesItsCommit() async throws {
        for attempt in 0 ..< 40 {
            let query = QueryTabController(connectionID: config.id, dialect: .sqlite, environment: environment)
            let name = try await openResult(in: query)

            query.gridDidCommitEdit(row: 0, column: name, text: "written \(attempt)")
            _ = await query.commitEdits()
            await query.setAutoCommit(false)
            query.gridDidCommitEdit(row: 0, column: name, text: "held \(attempt)")
            _ = await query.commitEdits()

            XCTAssertTrue(query.isInTransaction, "attempt \(attempt)")
            await query.commitTransaction()
            let committed = try await committedName()
            XCTAssertEqual(committed, "held \(attempt)", "attempt \(attempt)")
            await query.setAutoCommit(true)
            await query.releaseHeldConnection()
            if committed != "held \(attempt)" { return }
        }
    }
}
