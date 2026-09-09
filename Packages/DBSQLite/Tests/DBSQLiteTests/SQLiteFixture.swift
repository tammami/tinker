import DBCore
import DBSQL
import DBTestKit
import Foundation
import Logging

@testable import DBSQLite

/// The temporary database every test here opens, with `testenv/fixtures/sqlite/*.sql`
/// loaded into it once per process. No server, no environment variable: these tests
/// always run.
enum SQLiteFixture {
    static var logger: Logger {
        var logger = Logger(label: "test.sqlite")
        logger.logLevel = .critical
        return logger
    }

    static var path: String { TestEnvironment.sqliteDatabaseURL.path }

    private static let preparation = Preparation()

    static func prepare() async throws {
        try await preparation.run()
    }

    /// A config for the shared fixture file.
    static func config(options: [String: String] = [:], statementTimeout: Duration? = nil) -> ResolvedConnectionConfig {
        ResolvedConnectionConfig(
            configID: UUID(), dialect: .sqlite, host: "", port: 0, user: "", database: path,
            tls: TLSConfig(mode: .disable), options: options, statementTimeout: statementTimeout)
    }

    /// An open connection to the prepared fixture file.
    static func connect(options: [String: String] = [:], statementTimeout: Duration? = nil) async throws -> any SQLConnection {
        try await prepare()
        return try await SQLiteDriver.connect(config(options: options, statementTimeout: statementTimeout), logger: logger)
    }

    /// A fresh, empty database file of its own under the temporary directory.
    static func scratchPath(_ name: String = UUID().uuidString) -> String {
        TestEnvironment.sqliteDatabaseURL.deletingLastPathComponent().appendingPathComponent("\(name).sqlite").path
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
            let connection = try await SQLiteDriver.connect(SQLiteFixture.config(), logger: SQLiteFixture.logger)
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
