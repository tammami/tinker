import DBCore
import DBSQLite
import DBStore
import Foundation
import XCTest

@testable import Tinker

/// An edit to a query tab's result on a production connection is committed once, by Execute
/// on the commit sheet (ADR-0075). `commitEdits` is what that button calls.
///
/// Runs on a SQLite file of its own and a throwaway store, so it reaches no server. What a
/// commit landed is read through another connection, which an open transaction hides it from.
@MainActor
final class ProductionGridEditTests: XCTestCase {
    private var directory: URL!
    private var environment: AppEnvironment!
    private var config: ConnectionConfig!
    private var query: QueryTabController!
    private var asked: DestructiveConfirmation?

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("tinker-prod-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        environment = AppEnvironment(
            secrets: EphemeralSecretStore(), storePath: directory.appendingPathComponent("store.sqlite").path)
        await environment.load()
        config = ConnectionConfig(
            name: "prod-test", dialect: .sqlite, host: "", port: 0, user: "",
            database: directory.appendingPathComponent("data.sqlite").path,
            options: [SQLiteDriver.OptionKey.createIfMissing: "true"], isProduction: true)
        await environment.save(config)
        let session = try XCTUnwrap(environment.session(for: config.id))
        _ = try await session.connect()
        try await session.withLease { connection in
            _ = try await connection.executeCollecting("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)")
            _ = try await connection.executeCollecting("INSERT INTO items VALUES (1, 'original')")
        }
        query = QueryTabController(connectionID: config.id, dialect: .sqlite, environment: environment)
        query.confirm = { [weak self] in self?.asked = $0 }
    }

    override func tearDown() async throws {
        await query.rollbackTransaction()
        for session in environment.sessions(for: config.id) { await session.disconnect() }
        query = nil
        environment = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func waitUntil(
        _ what: String, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool
    ) async throws {
        for _ in 0 ..< 500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
    }

    /// The name as a connection other than the tab's sees it.
    private func committedName() async throws -> String? {
        let session = try XCTUnwrap(environment.session(for: config.id))
        let result = try await session.withLease { connection in
            try await connection.executeCollecting("SELECT name FROM items WHERE id = 1")
        }
        return result.firstText
    }

    /// Waits for the statement's own result: the run starts on a task of its own, so
    /// `isRunning` alone can read false before it has begun.
    private func run(_ sql: String) async throws {
        query.sql = sql
        query.caretOffset = 0
        query.run(all: true)
        try await waitUntil("the statement to finish") { !query.isRunning && query.results.first?.statement == sql }
    }

    /// Reads the row into an editable result and edits its name.
    private func editName(to text: String) async throws {
        try await run("SELECT id, name FROM items ORDER BY id")
        let grid = try XCTUnwrap(query.results.first?.grid)
        XCTAssertTrue(grid.isEditable, grid.readOnlyReason ?? "")
        let column = try XCTUnwrap(grid.columns.firstIndex { $0.name == "name" })
        query.gridDidCommitEdit(row: 0, column: column, text: text)
    }

    /// The edit waits for the sheet, and Execute on the sheet is the whole commit: nothing
    /// is left open, other connections see it, and no row stays locked.
    func testExecuteCommitsAnEditOnceAndLeavesNoTransaction() async throws {
        try await editName(to: "edited")
        XCTAssertEqual(query.pendingEditCount, 1, "nothing is written before the sheet")
        let waiting = try await committedName()
        XCTAssertEqual(waiting, "original")

        _ = await query.commitEdits()

        XCTAssertFalse(query.isInTransaction, "no second Commit to press")
        XCTAssertEqual(query.pendingEditCount, 0)
        let landed = try await committedName()
        XCTAssertEqual(landed, "edited")
    }

    /// The checkbox is not shown on production, so with nothing open, an edit is not held
    /// on the word of a setting the user cannot see. (Reads with it off do open a read
    /// transaction, ADR-0057, the page reload after this write included; that holds no write.)
    func testWithNothingOpenAnEditCommitsWhateverTheHiddenCheckboxSays() async throws {
        try await editName(to: "edited")
        query.autoCommit = false

        _ = await query.commitEdits()

        let landed = try await committedName()
        XCTAssertEqual(landed, "edited")
    }

    /// A statement the user ran is still held, and an edit made alongside it joins that
    /// transaction: the user opened it and it is theirs to end, so Rollback takes both.
    func testAnEditJoinsATransactionAStatementAlreadyHolds() async throws {
        query.sql = "UPDATE items SET name = 'statement' WHERE id = 1"
        query.caretOffset = 0
        query.run(all: true)
        try await waitUntil("the production prompt") { asked != nil }
        await asked?.action()
        try await waitUntil("the statement to finish") { !query.isRunning }
        XCTAssertTrue(query.isInTransaction, "a statement that writes on production is held")

        try await editName(to: "edited")
        _ = await query.commitEdits()

        XCTAssertTrue(query.isInTransaction, "the edit must not commit the user's transaction")
        let waiting = try await committedName()
        XCTAssertEqual(waiting, "original")

        await query.rollbackTransaction()
        let afterRollback = try await committedName()
        XCTAssertEqual(afterRollback, "original", "Rollback takes the edit and the statement")
    }

    /// With the write committed, Undo is the way back. On production it asks first, and
    /// what it writes is committed too.
    func testAnEditOnProductionCanBePutBackAfterAsking() async throws {
        try await editName(to: "edited")
        _ = await query.commitEdits()
        XCTAssertNil(query.putBackRefusal)
        let record = try XCTUnwrap(query.writeLog.undoable)

        query.revert(record)
        try await Task.sleep(for: .milliseconds(100))
        let stillEdited = try await committedName()
        XCTAssertEqual(stillEdited, "edited", "nothing is put back before the answer")
        let prompt = try XCTUnwrap(asked)

        await prompt.action()
        try await waitUntil("the put-back") { !query.isWritingEdits && query.writeLog.undoable == nil }

        XCTAssertFalse(query.isInTransaction)
        let restored = try await committedName()
        XCTAssertEqual(restored, "original")
    }

    /// With no way to ask, a production write does not run, as for a statement.
    func testAPutBackOnProductionDoesNotRunWithNoWayToAsk() async throws {
        try await editName(to: "edited")
        _ = await query.commitEdits()
        let record = try XCTUnwrap(query.writeLog.undoable)
        query.confirm = nil

        query.revert(record)
        try await Task.sleep(for: .milliseconds(100))

        let unchanged = try await committedName()
        XCTAssertEqual(unchanged, "edited")
    }
}
