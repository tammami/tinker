import DBCore
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
        guard let root = sidebar.roots.first(where: { $0.connectionID == config.id }) else { return }
        await sidebar.expand(root)
        let databases = sidebar.find(id: root.id)?.children ?? []
        guard let database = databases.first(where: { $0.title == (config.database ?? "") }) ?? databases.first else { return }
        await sidebar.expand(database)
        guard let schema = sidebar.find(id: database.id)?.children?.first else { return }
        await sidebar.expand(schema)
        for folder in sidebar.find(id: schema.id)?.children ?? [] { sidebar.markExpanded(folder.id) }
        let tables = sidebar.knownTables.filter { $0.connection == config.id }.map(\.table)
        let preferred = tables.first { $0.name == "orders" } ?? tables.first { $0.kind == .table } ?? tables.first

        for item in wanted {
            switch item {
            case "table":
                if let preferred { controller.openTable(preferred.ref, connectionID: config.id) }
            case "inspector":
                workspace.isInspectorVisible = true
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
            case "objects":
                if case let .schema(id, ref) = schema.kind { _ = workspace.openObjects(ref, connectionID: id) }
            case "server":
                controller.openServerActivity(connectionID: config.id)
            case "source":
                if let view = tables.first(where: { $0.kind == .view }) {
                    controller.openSource(SourceObject(kind: .view(view.ref)), connectionID: config.id)
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
                    workspace.pendingTableOperation = TableOperationRequest(kind: .importCSV, table: preferred.ref, connectionID: config.id)
                }
            case "rename":
                if let preferred {
                    workspace.pendingTableOperation = TableOperationRequest(kind: .rename, table: preferred.ref, connectionID: config.id)
                }
            case "maintenance":
                if let preferred, let action = MaintenanceAction.available(for: config.dialect).first {
                    workspace.pendingTableOperation = TableOperationRequest(kind: .maintenance(action), table: preferred.ref, connectionID: config.id)
                }
            case "filter":
                if let preferred {
                    let tab = controller.openTable(preferred.ref, connectionID: config.id)
                    if let table = controller.tableController(for: tab) {
                        try? await Task.sleep(for: .milliseconds(600))
                        table.filterRules = [FilterRule(column: table.columnsInfo.first?.name ?? "id", op: .greaterThan, values: [.string("2")])]
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
