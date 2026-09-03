import DBCore
import Foundation
import XCTest

@testable import DBStore

final class SnippetTests: XCTestCase {
    func temporaryStore() async throws -> DBStore {
        let path = NSTemporaryDirectory() + "dbstudio-snippets-\(UUID().uuidString).sqlite"
        return try await DBStore(path: path)
    }

    func testMigrationReachesTheSnippetVersion() async throws {
        let store = try await temporaryStore()
        let version = try await store.database.userVersion
        XCTAssertEqual(version, StoreSchema.latestVersion)
        XCTAssertGreaterThanOrEqual(version, 3)
        await store.close()
    }

    func testHiddenColumnsRoundTripAndDefaultToNone() async throws {
        let store = try await temporaryStore()
        let id = UUID()
        let none = try await store.gridPreferences(connectionID: id, table: "db.public.t")
        XCTAssertTrue(none.hiddenColumns.isEmpty)
        try await store.saveGridPreferences(
            GridPreferences(columnWidths: ["id": 80], hiddenColumns: ["secret", "blob"]),
            connectionID: id, table: "db.public.t"
        )
        let read = try await store.gridPreferences(connectionID: id, table: "db.public.t")
        XCTAssertEqual(read.hiddenColumns, ["secret", "blob"])
        XCTAssertEqual(read.columnWidths["id"], 80)
        await store.close()
    }

    func testSaveListFilterUpdateAndDelete() async throws {
        let store = try await temporaryStore()
        let any = try await store.saveSnippet(Snippet(name: "Count", body: "SELECT count(*) FROM ${1:t};"))
        let pg = try await store.saveSnippet(
            Snippet(name: "Activity", body: "SELECT * FROM pg_stat_activity;", dialect: "postgresql"))
        _ = try await store.saveSnippet(Snippet(name: "Processes", body: "SHOW PROCESSLIST;", dialect: "mysql"))

        let all = try await store.snippets()
        XCTAssertEqual(all.map(\.name), ["Activity", "Count", "Processes"])

        let forPostgres = try await store.snippets(dialect: "postgresql")
        XCTAssertEqual(forPostgres.map(\.id), [pg, any])

        var edited = try XCTUnwrap(forPostgres.first)
        edited.body = "SELECT pid FROM pg_stat_activity;"
        let sameID = try await store.saveSnippet(edited)
        XCTAssertEqual(sameID, pg)
        let reread = try await store.snippets(dialect: "postgresql")
        XCTAssertEqual(reread.first?.body, edited.body)

        try await store.deleteSnippet(id: any)
        let remaining = try await store.snippets()
        XCTAssertEqual(remaining.count, 2)
        await store.close()
    }
}
