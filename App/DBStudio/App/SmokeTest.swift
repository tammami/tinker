import DBCore
import DBGrid
import DBSQL
import Foundation

/// A headless run of the app's own wiring, for `Scripts/ci.sh`.
///
/// SPEC §17 asks for a UI smoke test covering launch, connect, open a table, run a query
/// and cancel one. Driving the real UI needs macOS Accessibility permission, which a build
/// machine cannot grant itself, so this exercises the same objects the views drive —
/// `AppEnvironment`, `ConnectionSession`, `TableTabController`, `QueryTabController` —
/// against the connection the store already holds. Recorded in DECISIONS.md (ADR-0019).
@MainActor
enum SmokeTest {
    static var isRequested: Bool {
        CommandLine.arguments.contains("--smoke-test")
    }

    /// Runs the checks and exits the process with 0 on success, 1 on the first failure.
    static func run() async -> Never {
        var failures: [String] = []

        func check(_ description: String, _ condition: Bool) {
            let mark = condition ? "✓" : "✗"
            FileHandle.standardError.write(Data("\(mark) \(description)\n".utf8))
            if !condition { failures.append(description) }
        }

        let environment = AppEnvironment()
        await environment.load()
        check("store opens", environment.startupError == nil)
        guard let config = environment.connections.first else {
            FileHandle.standardError.write(Data(
                "no connection configured; add one in the app first\n".utf8
            ))
            exit(2)
        }
        check("a connection is configured", true)

        guard let session = environment.session(for: config.id) else {
            check("session created", false)
            exit(1)
        }

        do {
            let version = try await session.connect()
            check("connects to \(version.rawString)", true)

            // A query tab: run a statement and read its rows.
            let query = QueryTabController(
                connectionID: config.id, dialect: config.dialect, environment: environment
            )
            query.sql = "SELECT 1 AS one, 'two' AS two"
            query.run(all: true)
            try await waitUntil(timeout: .seconds(20)) { !query.isRunning && !query.results.isEmpty }
            let result = query.results.first
            check("query returns a result", result?.error == nil)
            check("query returns one row", result?.grid?.rowCount == 1)
            check("query returns two columns", result?.grid?.columns.count == 2)

            // Cancellation: a long statement must stop quickly and leave the tab usable.
            let cancelTab = QueryTabController(
                connectionID: config.id, dialect: config.dialect, environment: environment
            )
            cancelTab.sql = "SELECT pg_sleep(30)"
            let started = ContinuousClock.now
            cancelTab.run(all: false)
            try await Task.sleep(for: .milliseconds(500))
            cancelTab.cancel()
            try await waitUntil(timeout: .seconds(10)) { !cancelTab.isRunning }
            let elapsed = started.duration(to: .now)
            check("cancel returns within 5s (took \(elapsed))", elapsed < .seconds(5))
            await cancelTab.releaseHeldConnection()

            // A table tab: introspect, page and read a value.
            let databases = try await session.introspection(.databases) { try await $0.databases() }
            let database = databases.first { $0.isCurrent }?.name ?? config.database ?? ""
            let schemas = try await session.introspection(.schemas(database: database)) {
                try await $0.schemas(in: database)
            }
            guard let schema = schemas.first(where: { !$0.isSystem }) else {
                check("a non-system schema exists", false)
                exit(1)
            }
            let tables = try await session.introspection(.tables(schema.ref)) {
                try await $0.tables(in: schema.ref)
            }
            guard let table = tables.first(where: { $0.kind == .table }) else {
                check("a table exists", false)
                exit(1)
            }
            let tab = TableTabController(
                table: table.ref, connectionID: config.id,
                dialect: config.dialect, environment: environment
            )
            await tab.start()
            check("opens table \(table.name)", tab.errorText == nil)
            check("table has columns", !(tab.model?.columns.isEmpty ?? true))
            check("status line is populated", !tab.statusText.isEmpty)

            await query.releaseHeldConnection()
            await environment.disconnectAll()
        } catch {
            check("no error: \(error)", false)
        }

        if failures.isEmpty {
            FileHandle.standardError.write(Data("smoke test passed\n".utf8))
            exit(0)
        }
        FileHandle.standardError.write(Data("smoke test failed: \(failures.joined(separator: ", "))\n".utf8))
        exit(1)
    }

    /// Polls `condition` until it holds or the timeout expires.
    static func waitUntil(
        timeout: Duration,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
