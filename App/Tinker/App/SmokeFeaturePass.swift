import DBCore
import DBGrid
import DBSQL
import DBStore
import Foundation

/// The second half of the smoke test: every feature, end to end, against the real server.
///
/// It drives the same controllers the views drive — table tab, query tab, structure,
/// builder, objects, definitions, server, snippets, export, import, table operations —
/// on a scratch table it creates and drops, so a broken feature fails CI rather than
/// waiting for a person to click on it.
@MainActor
extension SmokeTest {
    typealias Check = @MainActor (String, Bool) -> Void

    static func featurePass(
        environment: AppEnvironment,
        config: ConnectionConfig,
        session: ConnectionSession,
        check: Check
    ) async {
        guard config.dialect == .postgresql else {
            check("feature pass needs a PostgreSQL connection first in the store", false)
            return
        }
        let dialect = config.dialect
        let schema = SchemaRef(database: config.database ?? "", schema: "public")
        let scratch = TableRef(schema: schema, name: "smoke_features")
        let scratchName = Identifier.qualified(scratch, dialect: dialect)

        /// Runs statements on a fresh lease and returns the last result.
        @discardableResult
        func sql(_ statements: String...) async throws -> QueryResult? {
            let (lease, connection) = try await session.lease()
            defer { Task { await session.release(lease) } }
            var last: QueryResult?
            for statement in statements { last = try await connection.executeCollecting(statement) }
            return last
        }
        func count(_ table: String = "") async -> Int {
            let name = table.isEmpty ? scratchName : table
            return Int((try? await sql("SELECT count(*) FROM \(name)"))??.firstText ?? "") ?? -1
        }

        do {
            // MARK: Scratch table
            try await sql(
                "DROP TABLE IF EXISTS \(scratchName)",
                """
                CREATE TABLE \(scratchName) (
                    id serial PRIMARY KEY, name text NOT NULL, amount numeric(10,2), created timestamptz DEFAULT now()
                )
                """,
                "INSERT INTO \(scratchName) (name, amount) VALUES ('Grace', 5.25), ('Ada', 30.50), ('Linus', 12.00)"
            )
            await session.invalidateIntrospection()
            // Preferences from an earlier run (a sort, a hidden column) would skew the checks.
            await environment.saveGridPreferences(.empty, connectionID: config.id, table: scratch.id)
            let initialCount = await count()
            check("scratch table has 3 rows", initialCount == 3)

            // MARK: Table tab: read, sort, filter, search, page
            let table = TableTabController(
                table: scratch, connectionID: config.id, dialect: dialect, environment: environment)
            await table.start()
            check("table tab reads 4 columns", table.model?.columns.count == 4)
            check("table tab reads 3 rows", table.model?.rowCount == 3)
            check("table tab is editable (has a primary key)", table.model?.isEditable == true)
            let nameColumn = table.model?.columns.firstIndex { $0.name == "name" } ?? 1
            await table.cycleSort(columnIndex: nameColumn, additive: false)
            check("sorting by name puts Ada first", table.model?.value(row: 0, column: nameColumn) == .string("Ada"))
            await table.cycleSort(columnIndex: nameColumn, additive: false)
            check("sorting again reverses it", table.model?.value(row: 0, column: nameColumn) == .string("Linus"))
            await table.applyFilter([FilterRule(column: "amount", op: .greaterThan, values: [.string("10")])])
            check("a filter narrows to 2 rows", table.model?.rowCount == 2 && table.errorText == nil)
            await table.applyQuickSearch("lin")
            check("quick search on top of the filter finds Linus", table.model?.rowCount == 1)
            await table.applyQuickSearch("")
            await table.applyFilter([])
            check("clearing filter and search restores 3 rows", table.model?.rowCount == 3)
            table.setColumn("created", hidden: true)
            try await Task.sleep(for: .milliseconds(200))
            let again = TableTabController(
                table: scratch, connectionID: config.id, dialect: dialect, environment: environment)
            await again.start()
            check("a hidden column is remembered for the table", again.hiddenColumns.contains("created"))
            again.showAllColumns()
            try await Task.sleep(for: .milliseconds(200))

            // MARK: Table tab: edit, insert, commit, delete
            // Off, so the edits below stay pending until the explicit commit.
            table.autoCommit = false
            let adaRow = (0 ..< 3).first { table.model?.value(row: $0, column: nameColumn) == .string("Ada") } ?? 0
            _ = table.model?.setValue(.string("Ada Lovelace"), row: adaRow, column: nameColumn)
            table.addRow()
            let newRow = (table.model?.displayRowCount ?? 1) - 1
            _ = table.model?.setValue(.string("Margaret"), row: newRow, column: nameColumn)
            check("edits produce 2 pending statements", table.pendingStatements().count == 2)
            let commitMessage = await table.commit()
            check(
                "commit succeeds: \(commitMessage ?? "")",
                table.errorText == nil && commitMessage?.hasPrefix("Committed") == true)
            let afterCommit = await count()
            let renamedRows =
                (try? await sql("SELECT name FROM \(scratchName) WHERE name = 'Ada Lovelace'"))??.rows.count ?? 0
            check("commit wrote the update and the insert", afterCommit == 4 && renamedRows == 1)
            let margaretRow = (0 ..< (table.model?.displayRowCount ?? 0)).first {
                table.model?.value(row: $0, column: nameColumn) == .string("Margaret")
            }
            if let margaretRow {
                table.selection = GridSelection(row: margaretRow, column: 0, mode: .rows)
                table.deleteSelectedRows()
                let deleteMessage = await table.commit()
                let afterDelete = await count()
                check("deleting a row commits: \(deleteMessage ?? "")", table.errorText == nil && afterDelete == 3)
            } else {
                check("the inserted row is shown after commit", false)
            }
            // MARK: Table tab: auto-commit writes each edit as it is made
            table.autoCommit = true
            let byronRow = (0 ..< (table.model?.displayRowCount ?? 0)).first {
                table.model?.value(row: $0, column: nameColumn) == .string("Ada Lovelace")
            }
            if let byronRow {
                table.gridDidCommitEdit(row: byronRow, column: nameColumn, text: "Ada Byron")
                try await waitUntil(timeout: .seconds(20)) { !table.isWriting && table.pendingStatements().isEmpty }
                let byrons = (try? await sql("SELECT name FROM \(scratchName) WHERE name = 'Ada Byron'"))??.rows.count
                check(
                    "auto-commit writes a cell edit when it ends (\(table.errorText ?? "no error"))",
                    byrons == 1 && table.errorText == nil)
            } else {
                check("the renamed row is on the page", false)
            }
            table.addRow()
            let graceRow = (table.model?.displayRowCount ?? 1) - 1
            // The seed already holds a Grace; the new row gets a name of its own.
            table.gridDidCommitEdit(row: graceRow, column: nameColumn, text: "Grace Hopper")
            check(
                "a new row waits while it is being filled in", table.pendingStatements().count == 1 && !table.isWriting)
            table.gridDidChangeSelection(GridSelection(row: 0, column: 0, mode: .rows))
            try await waitUntil(timeout: .seconds(20)) { !table.isWriting && table.pendingStatements().isEmpty }
            let afterGrace = await count()
            let graces = (try? await sql("SELECT name FROM \(scratchName) WHERE name = 'Grace Hopper'"))??.rows.count
            check(
                "leaving the new row writes it (\(table.errorText ?? "no error"); rows=\(afterGrace), new=\(graces ?? -1))",
                afterGrace == 4 && graces == 1 && table.errorText == nil)
            let writtenGrace = (0 ..< (table.model?.displayRowCount ?? 0)).first {
                table.model?.value(row: $0, column: nameColumn) == .string("Grace Hopper")
            }
            if let writtenGrace {
                table.selection = GridSelection(row: writtenGrace, column: 0, mode: .rows)
                table.deleteSelectedRows()
                try await waitUntil(timeout: .seconds(20)) { !table.isWriting && table.pendingStatements().isEmpty }
                let afterAutoDelete = await count()
                check("auto-commit deletes at once (\(table.errorText ?? "no error"))", afterAutoDelete == 3)
            } else {
                check("the written row is shown after the write", false)
            }
            table.autoCommit = false

            table.selection = GridSelection(row: 0, column: 0, mode: .rows)
            let (copiedColumns, copiedRows) = table.selectedRowsAndColumns()
            let text = ClipboardFormatter.render(
                columns: copiedColumns, rows: copiedRows, format: .text,
                options: .init(includeHeader: true, dialect: dialect))
            check("copy as aligned text renders the header and a row", text.contains("name") && copiedRows.count == 1)

            // MARK: Row selection arithmetic
            var selection = GridSelection(row: 1, column: 0, mode: .rows)
            selection.focusRow = 3
            selection.toggleRow(7)
            check("⌘-click adds a row outside the span", selection.rows(totalRows: 10) == [1, 2, 3, 7])
            selection.toggleRow(2)
            check("⌘-click removes a row inside the span", selection.rows(totalRows: 10) == [1, 3, 7])
            selection.toggleRow(7)
            check("⌘-click removes an added row", selection.rows(totalRows: 10) == [1, 3])
            selection.selectAll(rowCount: 4, columnCount: 2)
            check(
                "select all covers every row and drops extras",
                selection.rows(totalRows: 4) == [0, 1, 2, 3] && selection.columnSpan == 2)

            // MARK: Foreign keys and paging on the fixtures
            let orders = TableRef(schema: schema, name: "orders")
            let ordersTab = TableTabController(
                table: orders, connectionID: config.id, dialect: dialect, environment: environment)
            await ordersTab.start()
            let customerColumn = ordersTab.model?.columns.firstIndex { $0.name == "customer_id" } ?? -1
            let target = customerColumn >= 0 ? ordersTab.referenceTarget(row: 0, column: customerColumn) : nil
            check(
                "a foreign key cell knows the row it points at",
                target?.table.name == "customers" && target?.filter.first?.column == "id")
            let big = TableTabController(
                table: TableRef(schema: schema, name: "big_table"), connectionID: config.id, dialect: dialect,
                environment: environment)
            await big.start()
            check("a big table pages", big.model?.isPaged == true && big.canGoForward)
            await big.goToNextPage()
            check("next page is page 2", big.currentPage == 2 && big.errorText == nil)
            await big.goToLastPage()
            check("last page has no next", !big.canGoForward && big.exactTotal == 1_000_000)

            // MARK: Export and import
            let exportURL = FileManager.default.temporaryDirectory.appendingPathComponent(
                "smoke-\(UUID().uuidString).csv")
            defer { try? FileManager.default.removeItem(at: exportURL) }
            if let grid = table.model {
                var options = ExportOptions()
                options.format = .csv
                options.dialect = dialect
                options.table = scratch
                let exporter = try RowExporter(url: exportURL, options: options)
                exporter.begin(columns: grid.columns)
                exporter.write(rows: (0 ..< grid.rowCount).compactMap { grid.loadedRow($0) })
                try exporter.finish()
                let exported = try String(contentsOf: exportURL, encoding: .utf8)
                check(
                    "CSV export holds the header and the rows",
                    exported.hasPrefix("id,name,amount,created") && exported.contains("Ada Lovelace"))
            } else {
                check("grid available for export", false)
            }
            let columns = try await session.introspection(.columns(scratch)) { try await $0.columns(of: scratch) }
            let csv = "name,amount\nImported One,1.10\nImported Two,2.20\n"
            var reader = CSVReader(data: Data(csv.utf8))
            let plan = CSVImportPlan.matched(header: reader.next() ?? [], to: columns, table: scratch)
            reader = CSVReader(data: Data(csv.utf8))
            do {
                let (lease, connection) = try await session.lease()
                let imported = try await CSVImporter(plan: plan, columns: columns, dialect: dialect).run(
                    reader: &reader, on: connection)
                await session.release(lease)
                let afterImport = await count()
                check("CSV import inserts 2 rows", imported == 2 && afterImport == 5)
            }

            // MARK: Query tab: explain, transaction, history, completion, format
            let query = QueryTabController(connectionID: config.id, dialect: dialect, environment: environment)
            await query.loadSessionChoices()
            await query.loadCompletionSources()
            query.sql = "SELECT * FROM smoke_features"
            query.caretOffset = 3
            query.explain(analyze: false)
            try await waitUntil(timeout: .seconds(20)) { !query.isRunning && !query.results.isEmpty }
            check(
                "explain returns a plan",
                (query.results.first?.grid?.rowCount ?? 0) > 0 && query.results.first?.error == nil)
            await query.setAutoCommit(false)
            query.sql = "INSERT INTO smoke_features (name) VALUES ('tx only')"
            query.caretOffset = 0
            query.run(all: true)
            // The explain's result is still there, so wait for the insert's own.
            try await waitUntil(timeout: .seconds(20)) {
                !query.isRunning && query.results.first?.statement.hasPrefix("INSERT") == true
            }
            check(
                "a write with auto-commit off opens a transaction (inTransaction=\(query.isInTransaction), error=\(query.results.first?.error?.message ?? "none"), status=\(query.statusText))",
                query.isInTransaction && query.results.first?.error == nil)
            await query.rollbackTransaction()
            let afterRollback = await count()
            check("rollback leaves the table as it was", !query.isInTransaction && afterRollback == 5)
            await query.setAutoCommit(true)
            let history = await environment.history(connectionID: config.id)
            check("history records what ran", history.contains { $0.sql.contains("smoke_features") })
            let keywords = query.editorCompletionCandidates(prefix: "sel", statement: "sel", caretOffset: 3)
            check("completion offers SELECT for sel", keywords.contains { $0.text == "SELECT" })
            let fromTables = query.editorCompletionCandidates(
                prefix: "", statement: "SELECT * FROM ", caretOffset: "SELECT * FROM ".utf16.count)
            check(
                "FROM with nothing typed offers the schema's tables",
                fromTables.contains { $0.text == "smoke_features" } && !fromTables.contains { $0.kind == .keyword })
            let tables = query.editorCompletionCandidates(
                prefix: "smoke_f", statement: "SELECT * FROM smoke_f", caretOffset: "SELECT * FROM smoke_f".utf16.count)
            check("completion offers the scratch table", tables.contains { $0.text == "smoke_features" })
            // The editor path: typing names the table, the columns are read on their own.
            query.editorDidChangeText("SELECT  FROM smoke_features s")
            query.editorDidChangeSelection(offset: 7, length: 0)
            try await waitUntil(timeout: .seconds(10)) {
                query.editorCompletionCandidates(prefix: "", statement: query.sql, caretOffset: 7)
                    .contains { $0.text == "name" }
            }
            let selectList = query.editorCompletionCandidates(prefix: "", statement: query.sql, caretOffset: 7)
            check(
                "SELECT with nothing typed offers the FROM table's columns",
                selectList.first?.kind == .column && selectList.contains { $0.text == "name" })
            let aliased = query.editorCompletionCandidates(
                prefix: "s.na", statement: "SELECT s.na FROM smoke_features s", caretOffset: 11)
            check("completion resolves an alias to its columns", aliased.contains { $0.text == "name" })
            let whereList = query.editorCompletionCandidates(
                prefix: "", statement: "SELECT * FROM smoke_features WHERE ",
                caretOffset: "SELECT * FROM smoke_features WHERE ".utf16.count)
            check("WHERE offers the table's columns first", whereList.first?.kind == .column)
            query.sql = "select id,name from smoke_features where id=1"
            query.formatSQL()
            check("format SQL upper-cases keywords", query.sql.contains("SELECT") && query.sql.contains("WHERE"))
            query.sql = "SELECT 1;"
            query.caretOffset = query.sql.utf16.count
            query.insertAtCaret("SELECT 2;")
            check("insert at caret appends on a new line", query.sql == "SELECT 1;\nSELECT 2;")
            await query.selectDatabase("public")
            check("switching the search path reports it", query.statusText == "Using public")

            // MARK: Production: no auto-commit, and a write asks before it runs
            var production = config
            production.isProduction = true
            await environment.save(production)
            check("a production connection never auto-commits grid edits", !table.autoCommitsEdits)
            var asked: DestructiveConfirmation?
            query.onConfirmProduction = { asked = $0 }
            query.sql = "DELETE FROM smoke_features WHERE id = -1"
            query.caretOffset = 0
            query.run(all: true)
            try? await Task.sleep(for: .milliseconds(200))
            check(
                "a destructive statement on production asks for the connection's name",
                asked?.requiredTypedName == config.name && !query.isRunning)
            query.sql = "SELECT 1"
            asked = nil
            query.run(all: true)
            try await waitUntil(timeout: .seconds(20)) {
                !query.isRunning && query.results.first?.statement == "SELECT 1"
            }
            check("a read on production runs without asking", asked == nil)
            query.onConfirmProduction = nil
            await environment.save(config)
            check("the connection is back off production", !table.isProduction)

            // MARK: Query results page and edit like a table
            query.sql = "SELECT id, name, amount FROM smoke_features ORDER BY id"
            query.caretOffset = 0
            query.run(all: true)
            try await waitUntil(timeout: .seconds(20)) {
                !query.isRunning && query.results.first?.statement.hasPrefix("SELECT id") == true
            }
            let resultGrid = query.results.first?.grid
            check(
                "a one-table SELECT pages on the server and is editable (\(resultGrid?.readOnlyReason ?? "editable"))",
                resultGrid?.isPaged == true && resultGrid?.isEditable == true)
            if let resultGrid, let nameColumn = resultGrid.columns.firstIndex(where: { $0.name == "name" }) {
                query.gridDidCommitEdit(row: 0, column: nameColumn, text: "Edited via query")
                check("an edit on a result is pending until committed", query.pendingEditCount == 1)
                let message = await query.commitEdits()
                let edited = (try? await sql("SELECT name FROM \(scratchName) ORDER BY id LIMIT 1"))??.firstText
                check(
                    "committing result edits writes by key and re-reads the page (\(message ?? ""))",
                    edited == "Edited via query"
                        && resultGrid.value(row: 0, column: nameColumn) == .string("Edited via query"))
                // Auto-commit off: the edit joins the tab's transaction until that commits.
                await query.setAutoCommit(false)
                query.gridDidCommitEdit(row: 0, column: nameColumn, text: "Grace")
                _ = await query.commitEdits()
                let uncommitted = (try? await sql("SELECT name FROM \(scratchName) ORDER BY id LIMIT 1"))??.firstText
                check(
                    "with auto-commit off the edit waits in the open transaction",
                    query.isInTransaction && uncommitted == "Edited via query")
                await query.commitTransaction()
                let committed = (try? await sql("SELECT name FROM \(scratchName) ORDER BY id LIMIT 1"))??.firstText
                check("committing the transaction lands the result edit", committed == "Grace")
                await query.setAutoCommit(true)
            }
            query.sql = "SELECT s.id FROM smoke_features s JOIN smoke_features t ON t.id = s.id"
            query.caretOffset = 0
            query.run(all: true)
            try await waitUntil(timeout: .seconds(20)) {
                !query.isRunning && query.results.first?.statement.contains("JOIN") == true
            }
            check("a join result stays read-only", query.results.first?.grid?.isEditable == false)
            await query.releaseHeldConnection()

            // MARK: Structure: create, alter, drop
            let created = TableRef(schema: schema, name: "smoke_created")
            try await sql("DROP TABLE IF EXISTS \(Identifier.qualified(created, dialect: dialect))")
            let designer = StructureController(
                table: created, connectionID: config.id, dialect: dialect, environment: environment, mode: .create)
            designer.edited?.columns.append(ColumnDefinition(name: "title", type: "text", isNullable: false))
            check(
                "the designer generates CREATE TABLE",
                designer.pendingStatements.contains { $0.sql.contains("CREATE TABLE") })
            await designer.execute()
            check(
                "the designer creates the table: \(designer.errorText ?? "ok")",
                designer.didCreate && designer.errorText == nil)
            await session.invalidateIntrospection()
            let editor = StructureController(
                table: created, connectionID: config.id, dialect: dialect, environment: environment)
            await editor.load()
            check("the structure tab reads 2 columns", editor.edited?.columns.count == 2)
            editor.isEditing = true
            editor.edited?.columns.append(ColumnDefinition(name: "note", type: "text", isNullable: true))
            check(
                "adding a column generates ALTER TABLE",
                editor.pendingStatements.contains { $0.sql.contains("ALTER TABLE") })
            await editor.execute()
            check("the alter runs: \(editor.errorText ?? "ok")", editor.errorText == nil)
            await editor.load(force: true)
            check("the structure tab now reads 3 columns", editor.edited?.columns.count == 3)
            check(
                "the structure read is quick on a warm connection (\(editor.lastLoadDuration ?? .zero))",
                (editor.lastLoadDuration ?? .seconds(99)) < .seconds(2))
            // Two callers at once share one read rather than starting two.
            let twin = StructureController(
                table: created, connectionID: config.id, dialect: dialect, environment: environment)
            async let firstLoad: Void = twin.load()
            async let secondLoad: Void = twin.load()
            _ = await (firstLoad, secondLoad)
            check("a structure read in flight is shared, not repeated", twin.edited?.columns.count == 3)
            // The designer takes every type apart and puts it back; an untouched column must
            // come out spelt exactly as the server spelt it, or it would generate DDL.
            let roundTrips = (editor.edited?.columns ?? []).allSatisfy {
                ColumnTypeSpec.parse($0.type).render(dialect: dialect) == $0.type
            }
            check("column types survive the designer's parse and render", roundTrips)
            editor.selectedColumnID = editor.edited?.columns.first?.id
            editor.moveSelection(by: 1)
            check("arrow keys move the column selection", editor.selectedColumnIndex == 1)

            // MARK: Objects, definitions, server
            let objects = ObjectsController(
                schema: schema, connectionID: config.id, dialect: dialect, environment: environment)
            await objects.load()
            check(
                "objects lists the scratch table and a function",
                objects.objects.contains { $0.name == "smoke_features" }
                    && objects.routines.contains { $0.name == "add_numbers" })
            let viewSource = SourceController(
                object: SourceObject(kind: .view(TableRef(schema: schema, name: "customer_totals"))),
                connectionID: config.id, dialect: dialect, environment: environment)
            await viewSource.load()
            check("a view's definition opens", viewSource.source?.contains("CREATE OR REPLACE VIEW") == true)
            let routineSource = SourceController(
                object: SourceObject(
                    kind: .routine(
                        schema: schema, name: "add_numbers", signature: "a integer, b integer", kind: .function)),
                connectionID: config.id, dialect: dialect, environment: environment)
            await routineSource.load()
            check("a function's definition opens", routineSource.source?.contains("add_numbers") == true)
            let server = ServerActivityController(connectionID: config.id, dialect: dialect, environment: environment)
            await server.loadSessions()
            check(
                "server sessions include this one",
                server.sessions.contains(where: \.isCurrent) && server.errorText == nil)
            await server.loadUsers()
            let me = server.users.first { $0.name == config.user }
            check("server users include the connected role", me != nil)
            if let me {
                await server.loadGrants(for: me)
                check("the role's grants are listed", !server.grantLines.isEmpty)
            }
            await server.loadVariables()
            check("server variables are listed", server.variables.contains { $0.name == "max_connections" })

            // MARK: Builder: join, preview, create view
            let builder = QueryBuilderController(
                schema: schema, connectionID: config.id, dialect: dialect, environment: environment)
            await builder.loadTables()
            await builder.add(TableRef(schema: schema, name: "customers"), at: CGPoint(x: 0, y: 0))
            await builder.add(orders, at: CGPoint(x: 300, y: 0))
            check("dropping a related table joins it by its foreign key", builder.model.joins.count == 1)
            builder.selectStar(ofTableNamed: "customers")
            builder.runPreview()
            try await waitUntil(timeout: .seconds(20)) {
                !builder.preview.isRunning && !builder.preview.results.isEmpty
            }
            check("the builder's preview returns rows", (builder.preview.results.first?.grid?.rowCount ?? 0) > 0)
            let view = await builder.createView(named: "smoke_builder_view")
            check("the builder creates a view: \(builder.errorText ?? "ok")", view != nil)
            await builder.preview.releaseHeldConnection()

            // MARK: Snippets
            let snippetID = await environment.saveSnippet(
                Snippet(name: "Smoke", body: "SELECT ${1:x};", dialect: dialect.rawValue))
            let snippets = await environment.snippets(dialect: dialect)
            check("a saved snippet is listed", snippets.contains { $0.id == snippetID })
            await environment.deleteSnippet(id: snippetID)
            let afterDelete = await environment.snippets(dialect: dialect)
            check("a deleted snippet is gone", !afterDelete.contains { $0.id == snippetID })

            // MARK: Table operations
            try await sql(TableOperations.rename(scratch, to: "smoke_features_renamed", dialect: dialect))
            check(
                "rename moves the rows with the table",
                await count(
                    Identifier.qualified(TableRef(schema: schema, name: "smoke_features_renamed"), dialect: dialect))
                    == 5)
            try await sql(
                TableOperations.rename(
                    TableRef(schema: schema, name: "smoke_features_renamed"), to: "smoke_features", dialect: dialect))
            for statement in TableOperations.duplicate(
                scratch, to: "smoke_features_copy", includeData: true, dialect: dialect)
            { try await sql(statement) }
            check(
                "duplicate with data copies every row",
                await count(
                    Identifier.qualified(TableRef(schema: schema, name: "smoke_features_copy"), dialect: dialect)) == 5)
            if let analyze = TableOperations.maintenance(.analyze, on: scratch, dialect: dialect) {
                try await sql(analyze)
                check("analyze runs", true)
            }

            // MARK: Dump, import and paste
            do {
                let dumpURL = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "smoke-\(UUID().uuidString).sql.gz")
                defer { try? FileManager.default.removeItem(at: dumpURL) }
                let rowsBefore = await count()
                let (lease, connection) = try await session.lease()
                let tables = try await connection.introspector.tables(in: schema).filter { $0.name == scratch.name }
                let selection = DumpSelection(schema: schema, tables: tables)
                var options = DumpOptions.preferred(for: dialect)
                options.includeDrop = true
                let writer = try ScriptFileWriter(url: dumpURL, dialect: dialect, compress: true)
                let channel = ScriptChannel()
                async let dumped = DatabaseDumper(dialect: dialect, options: options).run(
                    selection, on: connection, into: channel
                ) { _ in }
                while let chunk = try await channel.next() { try writer.write(chunk) }
                try writer.finish()
                let dumpOutcome = try await dumped
                check(
                    "dump writes the scratch table as gzip COPY (\(dumpOutcome.rows) rows, \(writer.bytesWritten) bytes)",
                    dumpOutcome.rows == Int64(rowsBefore) && writer.bytesWritten > 0)

                // The duplicate made earlier borrows the scratch table's sequence; it goes first.
                _ = try await connection.executeCollecting(
                    "DROP TABLE IF EXISTS \(Identifier.qualified(TableRef(schema: schema, name: "smoke_features_copy"), dialect: dialect))"
                )
                _ = try await connection.executeCollecting("DROP TABLE \(scratchName)")
                let imported = try await ScriptImportRunner.run(
                    url: dumpURL, dialect: dialect, options: ScriptExecutionOptions(), on: connection
                ) { _ in }
                await session.invalidateIntrospection()
                let rowsAfter = await count()
                check(
                    "importing the dump restores the table (\(imported.rows) rows, \(imported.statements) statements)",
                    imported.failures.isEmpty && rowsAfter == rowsBefore)

                // Paste: the same table next to itself under another name, connection to connection.
                let pastedRef = TableRef(schema: schema, name: "smoke_features_pasted")
                let pastedName = Identifier.qualified(pastedRef, dialect: dialect)
                _ = try? await connection.executeCollecting("DROP TABLE IF EXISTS \(pastedName)")
                let (targetLease, target) = try await session.lease()
                let pasted = try await TransferRunner.run(
                    selection, from: connection, to: target, dialect: dialect, options: options,
                    renaming: DumpRenaming(tableNames: [scratch.name: pastedRef.name])
                ) { _ in }
                await session.release(targetLease)
                let pastedCount = await count(pastedName)
                check(
                    "paste copies structure and data under a new name (\(pastedCount) rows)",
                    pasted.execution.failures.isEmpty && pastedCount == rowsBefore)
                _ = try? await connection.executeCollecting("DROP TABLE IF EXISTS \(pastedName)")

                // JSON Lines into the scratch table: keys map onto columns, numbers keep their text.
                let jsonURL = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "smoke-\(UUID().uuidString).jsonl")
                defer { try? FileManager.default.removeItem(at: jsonURL) }
                try Data(
                    "{\"name\": \"Json One\", \"amount\": 1.25}\n{\"name\": \"Json Two\", \"amount\": null}\n".utf8
                )
                .write(to: jsonURL)
                var reader = JSONRecordReader(data: try Data(contentsOf: jsonURL, options: .mappedIfSafe))
                let columns = try await connection.introspector.columns(of: scratch)
                let plan = CSVImportPlan(
                    table: scratch,
                    mapping: CSVImportPlan.matched(header: reader.header, to: columns, table: scratch).mapping,
                    hasHeader: false, commitEveryRows: 1)
                let insertedFromJSON = try await CSVImporter(plan: plan, columns: columns, dialect: dialect)
                    .run(reader: &reader, on: connection)
                await session.release(lease)
                let jsonRows =
                    (try? await sql("SELECT amount FROM \(scratchName) WHERE name LIKE 'Json%' ORDER BY name"))??.rows
                    ?? []
                check(
                    "JSON Lines import maps keys to columns and keeps NULL (\(insertedFromJSON) rows)",
                    insertedFromJSON == 2 && jsonRows.count == 2 && jsonRows[0][0].text == "1.25"
                        && jsonRows[1][0].isNull)
            }

            // MARK: Cleanup
            try await sql(
                "DROP VIEW IF EXISTS \(Identifier.qualified(TableRef(schema: schema, name: "smoke_builder_view"), dialect: dialect))",
                "DROP TABLE IF EXISTS \(Identifier.qualified(TableRef(schema: schema, name: "smoke_features_copy"), dialect: dialect))",
                "DROP TABLE IF EXISTS \(Identifier.qualified(created, dialect: dialect))",
                "DROP TABLE IF EXISTS \(scratchName)"
            )
            await session.invalidateIntrospection()
            await environment.saveGridPreferences(.empty, connectionID: config.id, table: scratch.id)
            check("scratch objects are dropped", true)
        } catch {
            check("feature pass error: \(error)", false)
            _ = try? await sql(
                "DROP VIEW IF EXISTS \(Identifier.qualified(TableRef(schema: schema, name: "smoke_builder_view"), dialect: dialect))",
                "DROP TABLE IF EXISTS \(Identifier.qualified(TableRef(schema: schema, name: "smoke_features_copy"), dialect: dialect))",
                "DROP TABLE IF EXISTS \(Identifier.qualified(TableRef(schema: schema, name: "smoke_created"), dialect: dialect))",
                "DROP TABLE IF EXISTS \(scratchName)"
            )
        }
    }
}
