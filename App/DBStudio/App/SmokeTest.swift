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
            FileHandle.standardError.write(
                Data(
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

            // Run Selected: only the highlighted statement runs, not the one beside it.
            let partial = QueryTabController(
                connectionID: config.id, dialect: config.dialect, environment: environment
            )
            partial.sql = "SELECT 1 AS first;\nSELECT 2 AS second;"
            let secondStart = partial.sql.utf16.count - "SELECT 2 AS second;".utf16.count
            partial.editorDidRequestRun(.all, selection: secondStart ..< partial.sql.utf16.count)
            try await waitUntil(timeout: .seconds(20)) { !partial.isRunning && !partial.results.isEmpty }
            check("run selection runs one statement", partial.results.count == 1)
            check(
                "run selection runs the highlighted one", partial.results.first?.grid?.columns.first?.name == "second")
            partial.editorDidRequestRun(.all, selection: nil)
            try await waitUntil(timeout: .seconds(20)) { !partial.isRunning && partial.results.count == 2 }
            check("run with no selection runs the whole page", partial.results.count == 2)
            check("and shows the first result first", partial.selectedResult?.grid?.columns.first?.name == "first")
            partial.caretOffset = partial.sql.utf16.count
            partial.editorDidRequestRun(.current, selection: nil)
            try await waitUntil(timeout: .seconds(20)) { !partial.isRunning && partial.results.count == 1 }
            check("run current runs only the statement at the caret", partial.results.first?.grid?.columns.first?.name == "second")
            await partial.releaseHeldConnection()

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

            // The quick search: one bound pattern per column, applied after a pause.
            let before = tab.model?.rowCount ?? 0
            await tab.applyQuickSearch("zzz-no-such-value-zzz")
            check(
                "quick search narrows \(before) rows to \(tab.model?.rowCount ?? -1)",
                tab.model?.rowCount == 0 && tab.errorText == nil)
            await tab.applyQuickSearch("")
            check("clearing the search restores the rows", tab.model?.rowCount == before)

            // The sidebar tree, level by level, exactly as the view expands it.
            let sidebar = SidebarModel(environment: environment)
            sidebar.rebuildRoots()
            check("sidebar lists the connection", !sidebar.roots.isEmpty)
            // The connection may sit inside a folder, so it is looked up, not taken from the top.
            guard let connectionItem = sidebar.find(id: config.id.uuidString) else {
                check("sidebar has a connection row", false)
                exit(1)
            }
            await sidebar.expand(connectionItem)
            let databaseItems = sidebar.find(id: connectionItem.id)?.children ?? []
            check("connection expands to \(databaseItems.count) database(s)", !databaseItems.isEmpty)

            guard
                let databaseItem = databaseItems.first(where: { $0.title == database })
                    ?? databaseItems.first
            else {
                check("a database row exists", false)
                exit(1)
            }
            await sidebar.expand(databaseItem)
            let schemaItems = sidebar.find(id: databaseItem.id)?.children ?? []
            check("database expands to \(schemaItems.count) schema(s)", !schemaItems.isEmpty)

            guard let schemaItem = schemaItems.first else {
                check("a schema row exists", false)
                exit(1)
            }
            await sidebar.expand(schemaItem)
            let folders = sidebar.find(id: schemaItem.id)?.children ?? []
            check("schema expands to \(folders.count) folder(s)", !folders.isEmpty)

            let tableRows = folders.flatMap { $0.children ?? [] }.filter { $0.tableRef != nil }
            check("folders hold \(tableRows.count) table row(s)", !tableRows.isEmpty)
            check("quick open sees \(sidebar.knownTables.count) table(s)", !sidebar.knownTables.isEmpty)

            // Expanding a folder is the step the view performs and this check used to
            // skip: it read the folders' children without ever opening one. Doing so
            // asked the loader for children a folder already had, and the empty result it
            // returned replaced them, so the folder drew open and empty in the real app.
            guard
                let tableFolder = folders.first(where: {
                    ($0.children ?? []).contains { $0.tableRef != nil }
                })
            else {
                check("a folder holds tables", false)
                exit(1)
            }
            let beforeExpand = (tableFolder.children ?? []).count
            await sidebar.expand(tableFolder)
            let afterExpand = (sidebar.find(id: tableFolder.id)?.children ?? []).count
            check(
                "expanding \(tableFolder.title) keeps its \(beforeExpand) table(s), got \(afterExpand)",
                afterExpand == beforeExpand
            )

            // Close Database folds the branch and forgets its children; Disconnect folds the lot.
            sidebar.collapseSubtree(databaseItem.id)
            check(
                "close database folds the branch",
                !sidebar.isExpanded(databaseItem.id) && !sidebar.isExpanded(schemaItem.id))
            check("quick open forgets a closed database's tables", sidebar.knownTables.isEmpty)
            check("close database keeps the connection open", sidebar.isExpanded(connectionItem.id))
            check("a closed branch holds nothing", (sidebar.find(id: databaseItem.id)?.children ?? []).isEmpty)
            sidebar.collapseConnection(config.id)
            check("disconnect folds the connection", sidebar.expanded.isEmpty && sidebar.knownTables.isEmpty)
            await sidebar.expand(connectionItem)
            check("reopening reads the databases again", !(sidebar.find(id: connectionItem.id)?.children ?? []).isEmpty)

            // Folders: made, renamed and removed through the environment, mirrored by the tree.
            await environment.createGroup(["Smoke Folder"])
            sidebar.rebuildRoots()
            check("a new folder appears in the tree", sidebar.roots.contains { $0.title == "Smoke Folder" })
            await environment.renameGroup(["Smoke Folder"], to: "Smoke Renamed")
            sidebar.rebuildRoots()
            check(
                "renaming a folder renames its row",
                sidebar.roots.contains { $0.title == "Smoke Renamed" }
                    && !sidebar.roots.contains { $0.title == "Smoke Folder" })
            await environment.createGroup(["Smoke Renamed", "Inner"])
            sidebar.rebuildRoots()
            check(
                "a nested folder sits inside its parent",
                sidebar.roots.first { $0.title == "Smoke Renamed" }?.children?.contains { $0.title == "Inner" } ?? false
            )
            await environment.removeGroup(["Smoke Renamed"])
            sidebar.rebuildRoots()
            check(
                "removing a folder moves its subfolders up a level",
                !sidebar.roots.contains { $0.title == "Smoke Renamed" }
                    && sidebar.roots.contains { $0.title == "Inner" })
            await environment.removeGroup(["Inner"])
            sidebar.rebuildRoots()
            check("removing the last folder leaves none", !sidebar.roots.contains { $0.title == "Inner" })
            check(
                "the connections are untouched",
                environment.connections.allSatisfy { !$0.groupPath.contains("Smoke Renamed") })

            // The action a double-click performs.
            let workspace = WorkspaceModel(environment: environment)
            guard let firstTable = tableRows.first?.tableRef else {
                check("a table row carries a reference", false)
                exit(1)
            }
            let opened = workspace.openTable(firstTable, connectionID: config.id)
            check("double-click opens a tab for \(firstTable.name)", workspace.tabs.count == 1)
            check("the tab is selected", workspace.selectedTabID == opened.id)

            // Close Database picks out the tabs of one database and closes only those.
            let other = TableRef(database: "some_other_db", schema: "public", name: "t")
            _ = workspace.openTable(other, connectionID: config.id)
            let inDatabase = workspace.tabs(for: config.id, database: firstTable.database) { _ in nil }
            check("close database finds the tabs of \(firstTable.database)", inDatabase.map(\.id) == [opened.id])
            workspace.closeTabs(Set(inDatabase.map(\.id)))
            check("close database leaves the other database's tab", workspace.tabs.map(\.tableRef) == [other])

            await query.releaseHeldConnection()

            // Every feature, end to end, on a scratch table.
            await featurePass(environment: environment, config: config, session: session, check: check)
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
