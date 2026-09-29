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
