import AppKit
import DBCore
import DBGrid
import DBSQL
import Foundation

/// Opens a scene on launch when `--ui-demo <scene>` is passed, for screenshots and review.
///
/// It only drives the same controllers a click would, on the first stored connection, so
/// it can never reach a state the user could not. Ignored entirely without the argument.
@MainActor
enum UIDemo {
    static var requestedScene: String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--ui-demo"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// The schema a tree row stands for: a schema row's own, or a MySQL database's pseudo-schema.
    static func demoSchemaRef(_ item: SidebarItem) -> SchemaRef? {
        switch item.kind {
        case let .schema(_, ref): ref
        case let .database(_, name): SchemaRef.mysql(name)
        default: nil
        }
    }

    static func apply(to controller: WorkspaceController) async {
        guard let scene = requestedScene else { return }
        let environment = controller.environment
        let sidebar = controller.sidebar
        let workspace = controller.workspace
        let wanted = scene.split(separator: "+").map(String.init)
        // A named connection may be chosen with `--ui-demo-connection <name>`.
        let arguments = CommandLine.arguments
        var config = environment.connections.first
        if let index = arguments.firstIndex(of: "--ui-demo-connection"), index + 1 < arguments.count {
            config = environment.connections.first { $0.name == arguments[index + 1] } ?? config
        }
        guard let config else { return }

        // Expand the tree the way a double-click would, so tables become known.
        guard let root = sidebar.find(id: config.id.uuidString) else { return }
        await sidebar.expand(root)
        let databases = sidebar.find(id: root.id)?.children ?? []
        // The map scene wants the seeded test database whatever the connection defaults to.
        let preferredDatabase = wanted.contains("map") ? "tinker_test" : (config.database ?? "")
        guard let database = databases.first(where: { $0.title == preferredDatabase }) ?? databases.first else {
            return
        }
        await sidebar.expand(database)
        guard let firstChild = sidebar.find(id: database.id)?.children?.first else { return }
        // PostgreSQL shows schemas under a database; MySQL shows the folders directly.
        let schema: SidebarItem
        if case .schema = firstChild.kind {
            schema = firstChild
            await sidebar.expand(schema)
        } else {
            schema = database
        }
        for folder in sidebar.find(id: schema.id)?.children ?? [] { sidebar.markExpanded(folder.id) }
        let tables = sidebar.knownTables.filter { $0.connection == config.id }.map(\.table)
        let preferred = tables.first { $0.name == "orders" } ?? tables.first { $0.kind == .table } ?? tables.first

        for item in wanted {
            switch item {
            case "table":
                if let preferred { controller.openTable(preferred.ref, connectionID: config.id) }
            case "inspector":
                workspace.isInspectorVisible = true
            case "datepicker":
                if let preferred {
                    let tab = controller.openTable(preferred.ref, connectionID: config.id)
                    workspace.isInspectorVisible = true
                    if let table = controller.tableController(for: tab) {
                        try? await Task.sleep(for: .milliseconds(900))
                        if let column = table.model?.columns.firstIndex(where: {
                            $0.kind == .timestamp || $0.kind == .date
                        }) {
                            table.selection = GridSelection(row: 0, column: column)
                            table.bumpRevision()
                        }
                    }
                }
            case "structure":
                if let preferred { controller.openTable(preferred.ref, connectionID: config.id) }
                UserDefaults.standard.set(true, forKey: "uiDemo.structure")
            case "query":
                let sql = """
                    SELECT c.id, c.name, count(o.id) AS orders, sum(o.total) AS revenue
                    FROM customers c
                    LEFT JOIN orders o ON o.customer_id = c.id
                    GROUP BY c.id, c.name
                    ORDER BY revenue DESC NULLS LAST;

                    SELECT * FROM all_types;
                    """
                let tab = controller.newQueryTab(connectionID: config.id, sql: sql)
                if let query = controller.queryController(for: tab) {
                    try? await Task.sleep(for: .milliseconds(400))
                    query.run(all: true)
                }
            case "bigquery":
                let tab = controller.newQueryTab(connectionID: config.id, sql: "SELECT * FROM big_table ORDER BY id;")
                if let query = controller.queryController(for: tab) {
                    try? await Task.sleep(for: .milliseconds(400))
                    query.run(all: true)
                }
            case "editquery":
                let tab = controller.newQueryTab(connectionID: config.id, sql: "SELECT * FROM customers ORDER BY id;")
                if let query = controller.queryController(for: tab) {
                    try? await Task.sleep(for: .milliseconds(400))
                    query.run(all: true)
                    try? await Task.sleep(for: .milliseconds(1500))
                    if let grid = query.selectedResult?.grid, grid.isEditable, grid.columns.count > 1 {
                        query.gridDidCommitEdit(row: 0, column: 1, text: "Edited in the result grid")
                        query.selection = GridSelection(row: 0, column: 1)
                    }
                }
            case "completion", "completion-columns":
                // `completion` shows the tables offered after FROM with nothing typed;
                // `completion-columns` the first table's columns after `t.`.
                let sql =
                    item == "completion"
                    ? "SELECT * FROM "
                    : "SELECT * FROM \(preferred?.name ?? "orders") t WHERE t."
                let tab = controller.newQueryTab(connectionID: config.id, sql: sql)
                if let query = controller.queryController(for: tab) {
                    await query.loadSessionChoices()
                    if config.dialect == .mysql, let name = demoSchemaRef(schema)?.schema {
                        await query.selectDatabase(name)
                    }
                    await query.loadCompletionSources()
                    query.editorDidChangeText(sql)
                    query.caretOffset = sql.utf16.count
                    try? await Task.sleep(for: .milliseconds(1200))
                    NSApp.activate(ignoringOtherApps: true)
                    NotificationCenter.default.post(name: .tinkerOfferCompletion, object: nil)
                }
            case "objects":
                if let ref = demoSchemaRef(schema) { _ = workspace.openObjects(ref, connectionID: config.id) }
            case "server":
                controller.openServerActivity(connectionID: config.id)
            case "newuser":
                controller.openUsers(connectionID: config.id, database: config.database)
                if let tab = workspace.selectedTab { controller.serverController(for: tab).wantsNewUserSheet = true }
            case "users":
                controller.openUsers(connectionID: config.id, database: config.database)
                if let tab = workspace.selectedTab {
                    let server = controller.serverController(for: tab)
                    try? await Task.sleep(for: .milliseconds(1200))
                    if let me = server.users.first(where: { $0.name == config.user }) {
                        server.selectedUserID = me.id
                        await server.loadGrants(for: me)
                    }
                }
            case "builder":
                if let ref = demoSchemaRef(schema) {
                    let id = config.id
                    let tab = controller.openQueryBuilder(ref, connectionID: id)
                    let builder = controller.builderController(for: tab, schema: ref)
                    await builder.loadTables()
                    if let customers = builder.availableTables.first(where: { $0.name == "customers" }) {
                        await builder.add(customers.ref, at: CGPoint(x: 60, y: 60))
                    }
                    if let orders = builder.availableTables.first(where: { $0.name == "orders" }) {
                        await builder.add(orders.ref, at: CGPoint(x: 420, y: 140))
                    }
                    builder.selectStar(ofTableNamed: "customers")
                    builder.pane = .select
                    builder.runPreview()
                }
            case "source":
                if let view = tables.first(where: { $0.kind == .view }) {
                    controller.openSource(SourceObject(kind: .view(view.ref)), connectionID: config.id)
                }
            case "builder-blank":
                // The path a connection with no default database takes: the builder
                // starts on nothing and falls back to the first schema the server lists.
                controller.openQueryBuilder(SchemaRef(database: "", schema: ""), connectionID: config.id)
            case "newtable":
                if let ref = demoSchemaRef(schema) {
                    workspace.newTableContext = (config.id, ref)
                    workspace.isNewTablePresented = true
                }
            case "transfer", "datasync", "structsync", "transfer2", "datasync3", "structsync3":
                let name = item.trimmingCharacters(in: .decimalDigits)
                let kind: ToolKind =
                    name == "transfer" ? .dataTransfer : name == "datasync" ? .dataSync : .structureSync
                if let step = Int(item.suffix(1)) {
                    // Another database on the same server stands in as the target.
                    let others =
                        (try? await environment.session(for: config.id)?.introspection(.databases) {
                            try await $0.databases()
                        })
                    let other = (others ?? nil)?.map(\.name).first { $0 != config.database } ?? config.database ?? ""
                    UserDefaults.standard.set(other, forKey: "uiDemo.toolTargetDatabase")
                    UserDefaults.standard.set(step, forKey: "uiDemo.toolStep")
                }
                workspace.pendingTool = ToolRequest(kind: kind, connectionID: config.id, schema: demoSchemaRef(schema))
            case "map":
                if let places = tables.first(where: { $0.name == "spatial_places" }) {
                    controller.openTable(places.ref, connectionID: config.id)
                    UserDefaults.standard.set(true, forKey: "uiDemo.map")
                }
            case "palette":
                workspace.isCommandPalettePresented = true
            case "snippets":
                workspace.isSnippetsPresented = true
            case "history":
                workspace.isHistoryPresented = true
            case "quickopen":
                workspace.isQuickOpenPresented = true
            case "connection":
                workspace.editingConnection = config
            case "newconnection":
                workspace.presentNewConnection()
            case "export":
                workspace.isExportPresented = true
            case "import":
                if let preferred {
                    workspace.pendingTableOperation = TableOperationRequest(
                        kind: .importCSV, table: preferred.ref, connectionID: config.id)
                }
            case "dump":
                if let ref = demoSchemaRef(schema) {
                    workspace.pendingDump = DumpRequest(connectionID: config.id, schema: ref, tables: nil)
                }
            case "dumpchoose":
                controller.presentDump()
            case "importchoose":
                controller.presentScriptImport()
            case "importsql":
                workspace.pendingScriptImport = ScriptImportRequest(connectionID: config.id, database: config.database)
            case "paste":
                if let preferred, let ref = demoSchemaRef(schema) {
                    let copied = CopiedObjects(
                        connectionID: config.id, connectionName: config.name, dialect: config.dialect,
                        schema: ref, tables: [preferred])
                    workspace.objectClipboard = copied
                    workspace.pendingPaste = PasteRequest(
                        source: copied, targetConnectionID: config.id, targetSchema: ref)
                }
            case "rename":
                if let preferred {
                    workspace.pendingTableOperation = TableOperationRequest(
                        kind: .rename, table: preferred.ref, connectionID: config.id)
                }
            case "maintenance":
                if let preferred, let action = MaintenanceAction.available(for: config.dialect).first {
                    workspace.pendingTableOperation = TableOperationRequest(
                        kind: .maintenance(action), table: preferred.ref, connectionID: config.id)
                }
            case "filter":
                if let preferred {
                    let tab = controller.openTable(preferred.ref, connectionID: config.id)
                    if let table = controller.tableController(for: tab) {
                        try? await Task.sleep(for: .milliseconds(600))
                        table.filterRules = [
                            FilterRule(
                                column: table.columnsInfo.first?.name ?? "id", op: .greaterThan, values: [.string("2")])
                        ]
                        await table.applyFilter(table.filterRules)
                    }
                }
            case "firstrun":
                break
            default:
                break
            }
        }
    }
}
