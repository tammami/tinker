import DBCore
import DBSQLite
import DBStore
import Foundation
import XCTest

@testable import Tinker

/// The tree after a table operation: a DROP, TRUNCATE or paste ends in `refresh`, and the
/// branches that were open must come back open and filled, however many refreshes pile up.
///
/// Runs on a SQLite file of its own and a throwaway store, so it reaches no server.
@MainActor
final class SidebarRefreshTests: XCTestCase {
    private var directory: URL!
    private var environment: AppEnvironment!
    private var sidebar: SidebarModel!
    private var config: ConnectionConfig!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("tinker-sidebar-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        environment = AppEnvironment(
            secrets: EphemeralSecretStore(), storePath: directory.appendingPathComponent("store.sqlite").path)
        await environment.load()
        config = ConnectionConfig(
            name: "sidebar-test", dialect: .sqlite, host: "", port: 0, user: "",
            database: directory.appendingPathComponent("data.sqlite").path,
            options: [SQLiteDriver.OptionKey.createIfMissing: "true"])
        await environment.save(config)
        let session = try XCTUnwrap(environment.session(for: config.id))
        _ = try await session.connect()
        try await session.withLease { connection in
            for name in ["alpha", "beta", "gamma"] {
                _ = try await connection.executeCollecting("CREATE TABLE \(name) (id INTEGER PRIMARY KEY)")
            }
        }
        sidebar = SidebarModel(environment: environment)
    }

    override func tearDown() async throws {
        for session in environment.sessions(for: config.id) { await session.disconnect() }
        // The store keeps its file open for the life of the environment; let both go first.
        sidebar = nil
        environment = nil
        try? FileManager.default.removeItem(at: directory)
    }

    /// Opens the connection, its database and the Tables folder; returns their ids.
    private func openToTables() async throws -> [SidebarItem.ID] {
        let connection = try XCTUnwrap(sidebar.find(id: config.id.uuidString))
        await sidebar.expand(connection)
        let database = try XCTUnwrap(sidebar.find(id: connection.id)?.children?.first)
        await sidebar.expand(database)
        let folder = try XCTUnwrap(
            sidebar.find(id: database.id)?.children?.first { if case .tableFolder = $0.kind { true } else { false } })
        await sidebar.expand(folder)
        return [connection.id, database.id, folder.id]
    }

    private func tables(under folder: SidebarItem.ID) -> [String] {
        (sidebar.find(id: folder)?.children ?? []).map(\.title)
    }

    private func execute(_ sql: String) async throws {
        let session = try XCTUnwrap(environment.session(for: config.id))
        try await session.withLease { _ = try await $0.executeCollecting(sql) }
    }

    /// Waits for the state stream to reach the row; it arrives on a task of its own.
    private func waitForState(
        _ expected: ConnectionState, of sidebar: SidebarModel, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let id: UUID = try XCTUnwrap(config).id
        for _ in 0 ..< 200 {
            if sidebar.state(of: id) == expected { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("still \(sidebar.state(of: id)), expected \(expected)", file: file, line: line)
    }

    /// What Save in the connection editor does, in its order.
    private func saveEdit() async throws {
        var edited = try XCTUnwrap(config)
        edited.color = .orange
        await environment.save(edited)
        await environment.invalidateSession(for: edited.id)
        sidebar.followReplacedSessions()
        sidebar.rebuildRoots()
        await sidebar.refresh(connectionID: edited.id)
    }

    /// An open connection is edited: the tree connects the new session and the row says so.
    /// It used to go on reporting the old session, a hollow dot on a live connection.
    func testAnEditedOpenConnectionReportsItsNewSession() async throws {
        _ = try await openToTables()
        try await waitForState(.connected, of: sidebar)
        let old = try XCTUnwrap(environment.session(for: config.id))

        try await saveEdit()

        let new = try XCTUnwrap(environment.session(for: config.id))
        XCTAssertFalse(old === new, "the edit replaces the session")
        let newState = await new.state
        XCTAssertEqual(newState, .connected, "the refresh connects an open row's session")
        try await waitForState(.connected, of: sidebar)
    }

    /// A closed connection is edited and connected later, by a query tab say, with no tree
    /// load to start a watcher. The row still follows it, both ways.
    func testAnEditedClosedConnectionIsFollowedWhenItConnects() async throws {
        sidebar.watchState(of: config.id)
        try await saveEdit()
        try await waitForState(.disconnected, of: sidebar)

        let session = try XCTUnwrap(environment.session(for: config.id))
        _ = try await session.connect()
        try await waitForState(.connected, of: sidebar)

        await session.disconnect()
        try await waitForState(.disconnected, of: sidebar)
    }

    /// Another window has its own sidebar over the same sessions, and is not the one that
    /// saved. It catches up when told, and goes on following the new session.
    func testAnotherWindowsSidebarFollowsTheReplacement() async throws {
        let other = SidebarModel(environment: environment)
        other.watchState(of: config.id)
        _ = try await openToTables()
        try await waitForState(.connected, of: other)

        try await saveEdit()
        other.followReplacedSessions()

        try await waitForState(.connected, of: other)
        let session = try XCTUnwrap(environment.session(for: config.id))
        await session.disconnect()
        try await waitForState(.disconnected, of: other)
    }

    /// A deleted connection gets no fresh session from anyone following replacements.
    func testDeletingAConnectionLeavesNoSessionBehind() async throws {
        _ = try await openToTables()
        let generations = environment.sessionGenerations
        await environment.delete(try XCTUnwrap(config))
        XCTAssertEqual(environment.sessionGenerations, generations)
        sidebar.followReplacedSessions()
        sidebar.rebuildRoots()
        XCTAssertTrue(environment.sessions(for: config.id).isEmpty)
        XCTAssertEqual(sidebar.state(of: config.id), .disconnected)
    }

    /// The sweep of row views the list leaves behind runs when this moves, so opening and
    /// closing a row has to move it, a folder included: folders keep their state apart.
    func testTheTreeGenerationMovesWhenRowsCanChange() async throws {
        let ids = try await openToTables()
        var seen = sidebar.treeGeneration
        func moved(_ what: String) {
            XCTAssertNotEqual(sidebar.treeGeneration, seen, what)
            seen = sidebar.treeGeneration
        }
        sidebar.collapse(ids[2])
        moved("closing a row")
        sidebar.markExpanded(ids[2])
        moved("opening a row")
        sidebar.collapse("group/Office")
        moved("closing a folder")
        sidebar.rebuildRoots()
        moved("rebuilding the tree")
    }

    /// Every open row still has its children after a refresh. The old refresh walked the
    /// open rows in `Set` order — random per launch — and a database visited before its
    /// connection was skipped, left open with nothing under it.
    func testEveryOpenBranchIsFilledAfterARefresh() async throws {
        let ids = try await openToTables()
        XCTAssertEqual(tables(under: ids[2]), ["alpha", "beta", "gamma"])
        try await execute("DROP TABLE beta")
        for _ in 0 ..< 10 {
            await sidebar.refresh(connectionID: config.id)
            for id in ids {
                XCTAssertTrue(sidebar.isExpanded(id), id)
                XCTAssertFalse((sidebar.find(id: id)?.children ?? []).isEmpty, "\(id) is open and empty")
            }
            XCTAssertEqual(tables(under: ids[2]), ["alpha", "gamma"])
        }
    }

    /// Refreshes asked for together — one per operation — all finish, and the tree ends
    /// up showing the last change.
    func testRefreshesAskedForTogetherAllLandOnTheLatestTree() async throws {
        let ids = try await openToTables()
        try await execute("DROP TABLE alpha")
        let sidebar: SidebarModel = try XCTUnwrap(self.sidebar)
        let connectionID: UUID = try XCTUnwrap(config).id
        async let first: Void = sidebar.refresh(connectionID: connectionID)
        async let second: Void = sidebar.refresh(connectionID: connectionID)
        try await execute("CREATE TABLE delta (id INTEGER PRIMARY KEY)")
        async let third: Void = sidebar.refresh(connectionID: connectionID)
        _ = await (first, second, third)
        XCTAssertEqual(tables(under: ids[2]), ["beta", "delta", "gamma"])
        for id in ids { XCTAssertFalse((sidebar.find(id: id)?.children ?? []).isEmpty, id) }
    }

    /// A refresh while the connection is closed forgets what was loaded; opening the
    /// connection again brings its open database back filled, not open and empty.
    func testAClosedConnectionReopensWithItsOpenDatabaseFilled() async throws {
        let ids = try await openToTables()
        sidebar.collapse(ids[0])
        try await execute("DROP TABLE gamma")
        await sidebar.refresh(connectionID: config.id)
        let connection = try XCTUnwrap(sidebar.find(id: ids[0]))
        await sidebar.expand(connection)
        XCTAssertTrue(sidebar.isExpanded(ids[1]))
        XCTAssertFalse((sidebar.find(id: ids[1])?.children ?? []).isEmpty, "the database came back empty")
        XCTAssertEqual(tables(under: ids[2]), ["alpha", "beta"])
    }

    /// A connection has no chevron until it is opened; closing its triangle keeps it
    /// open, Disconnect does not. Nothing about a refresh opens it.
    func testAConnectionIsBrowsedOnlyOnceItIsOpened() async throws {
        let id = try XCTUnwrap(config).id
        XCTAssertFalse(sidebar.isOpened(id), "a single click only selects")
        await sidebar.refresh(connectionID: id)
        XCTAssertFalse(sidebar.isOpened(id))
        let ids = try await openToTables()
        XCTAssertTrue(sidebar.isOpened(id), "the double-click's expand opens it")
        sidebar.collapse(ids[0])
        XCTAssertTrue(sidebar.isOpened(id), "the chevron stays to open it again")
        sidebar.collapseConnection(id)
        XCTAssertFalse(sidebar.isOpened(id), "Disconnect takes the chevron away")
    }

    /// A Tables folder opened while the search shows only some of its tables still holds
    /// all of them once the search is cleared. The filter hands the row its own copy with
    /// just the matches, and that copy used to be cached as the folder's contents.
    func testAFolderOpenedWhileFilteringKeepsEveryTable() async throws {
        let connection = try XCTUnwrap(sidebar.find(id: config.id.uuidString))
        await sidebar.expand(connection)
        let database = try XCTUnwrap(sidebar.find(id: connection.id)?.children?.first)
        await sidebar.expand(database)
        var filtered = try XCTUnwrap(
            sidebar.find(id: database.id)?.children?.first { if case .tableFolder = $0.kind { true } else { false } })
        filtered.children = filtered.children?.filter { $0.title == "beta" }
        await sidebar.expand(filtered)
        XCTAssertEqual(tables(under: filtered.id), ["alpha", "beta", "gamma"])
        sidebar.collapse(filtered.id)
        await sidebar.expand(filtered)
        XCTAssertEqual(tables(under: filtered.id), ["alpha", "beta", "gamma"])
    }

    /// Opening and closing still work during a refresh and after one.
    func testRowsStillOpenAndCloseAroundARefresh() async throws {
        let ids = try await openToTables()
        let sidebar: SidebarModel = try XCTUnwrap(self.sidebar)
        let connectionID: UUID = try XCTUnwrap(config).id
        async let refreshing: Void = sidebar.refresh(connectionID: connectionID)
        sidebar.collapse(ids[1])
        await refreshing
        XCTAssertFalse(sidebar.isExpanded(ids[1]))
        let database = try XCTUnwrap(sidebar.find(id: ids[1]))
        await sidebar.expand(database)
        XCTAssertTrue(sidebar.isExpanded(ids[1]))
        XCTAssertFalse((sidebar.find(id: ids[1])?.children ?? []).isEmpty)
    }
}
