import XCTest

@testable import DBCore

/// Titles for pickers that tell connections apart when their names repeat.
final class ConnectionTitlesTests: XCTestCase {
    private func config(
        _ name: String, folders: [String] = [], host: String = "localhost", user: String = "root",
        production: Bool = false, dialect: SQLDialect = .mysql
    ) -> ConnectionConfig {
        ConnectionConfig(
            name: name, groupPath: folders, dialect: dialect, host: host, port: 3306, user: user,
            isProduction: production)
    }

    func testQualifiedNameLeadsWithFolders() {
        XCTAssertEqual(config("MySQL").qualifiedName, "MySQL")
        XCTAssertEqual(config("MySQL", folders: ["Office"]).qualifiedName, "Office › MySQL")
        XCTAssertEqual(config("PG", folders: ["Clients", "Acme"]).qualifiedName, "Clients › Acme › PG")
    }

    func testSameNameInDifferentFoldersReadsDifferently() {
        let local = config("MySQL", folders: ["Localhost"])
        let office = config("MySQL", folders: ["Office"], host: "10.0.0.5", production: true)
        let titles = ConnectionConfig.distinctTitles(for: [local, office])
        XCTAssertEqual(titles[local.id], "Localhost › MySQL")
        XCTAssertEqual(titles[office.id], "Office › MySQL · PROD")
    }

    func testSameNameInSameFolderAddsTheEndpoint() {
        let a = config("MySQL", folders: ["Office"], host: "db1")
        let b = config("MySQL", folders: ["Office"], host: "db2", user: "app")
        let other = config("PostgreSQL", folders: ["Office"], dialect: .postgresql)
        let titles = ConnectionConfig.distinctTitles(for: [a, b, other])
        XCTAssertEqual(titles[a.id], "Office › MySQL — root@db1:3306")
        XCTAssertEqual(titles[b.id], "Office › MySQL — app@db2:3306")
        XCTAssertEqual(titles[other.id], "Office › PostgreSQL")
        XCTAssertEqual(Set(titles.values).count, 3)
    }

    func testSQLiteEndpointIsTheFileName() {
        let file = ConnectionConfig(
            name: "app.db", dialect: .sqlite, host: "", port: 0, user: "", database: "/Users/me/data/app.db")
        XCTAssertEqual(file.endpointSummary, "app.db")
        XCTAssertEqual(config("MySQL", user: "").endpointSummary, "localhost:3306")
    }
}
