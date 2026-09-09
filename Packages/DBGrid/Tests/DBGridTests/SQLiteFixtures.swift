import DBCore
import DBSQL
import DBSQLite
import DBTestKit
import Foundation
import Logging

/// Loads `testenv/fixtures/sqlite/*.sql` into the process's temporary SQLite database,
/// once. PostgreSQL and MySQL are prepared by `testenv/prepare.sh`; SQLite needs no
/// server, so the suite prepares its own file and never skips.
enum SQLiteFixtures {
    private static let preparation = Preparation()

    /// Ensures the fixtures are loaded; returns immediately on every call after the first.
    static func prepare() async throws {
        try await preparation.run()
    }

    private actor Preparation {
        private var task: Task<Void, any Error>?

        func run() async throws {
            if let task { return try await task.value }
            let task = Task { try await Preparation.load() }
            self.task = task
            try await task.value
        }

        private static func load() async throws {
            let url = TestEnvironment.sqliteDatabaseURL
            try? FileManager.default.removeItem(at: url)
            try SQLiteDriver.createDatabase(at: url.path)
            var logger = Logger(label: "test.sqlite.fixtures")
            logger.logLevel = .critical
            let config = SQLiteDriver.connectionConfig(forFileAt: url.path)
            let resolved = ResolvedConnectionConfig(
                configID: config.id, dialect: .sqlite, host: "", port: 0, user: "", database: url.path,
                tls: TLSConfig(mode: .disable), options: config.options)
            let connection = try await SQLiteDriver.connect(resolved, logger: logger)
            defer { Task { await connection.close() } }
            for script in try TestEnvironment.fixtureScripts(for: .sqlite) {
                let sql = try String(contentsOf: script, encoding: .utf8)
                for statement in StatementSplitter.split(sql, dialect: .sqlite) {
                    _ = try await connection.executeCollecting(statement.text)
                }
            }
            TestLog.note("sqlite fixtures loaded into \(url.path)")
        }
    }
}
