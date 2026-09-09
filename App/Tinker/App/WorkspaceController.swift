import AppKit
import DBCore
import DBGrid
import DBSQL
import Foundation
import Observation

/// Everything one workspace window owns, and every command the menus can run against it.
///
/// This is a class rather than view state so that a menu item always reaches the live
/// objects; closures captured out of a `View` struct go stale as soon as the view is
/// rebuilt, and that is a whole category of "the menu item does nothing".
@MainActor
@Observable
public final class WorkspaceController {
    public let environment: AppEnvironment
    public let settings: AppSettings
    public let workspace: WorkspaceModel
    public let sidebar: SidebarModel

    public private(set) var tableControllers: [UUID: TableTabController] = [:]
    public private(set) var queryControllers: [UUID: QueryTabController] = [:]
    /// One per Objects tab.
    public var objectsControllers: [UUID: ObjectsController] = [:]
    /// One per Server tab.
    public private(set) var serverControllers: [UUID: ServerActivityController] = [:]
    /// One per definition tab.
    public private(set) var sourceControllers: [UUID: SourceController] = [:]
    /// One per query builder tab.
    public private(set) var builderControllers: [UUID: QueryBuilderController] = [:]
    /// Toggled by the sidebar command; the split view reads it.
    public var isSidebarVisible = true

    public init(environment: AppEnvironment, settings: AppSettings) {
        self.environment = environment
        self.settings = settings
        workspace = WorkspaceModel(environment: environment)
        sidebar = SidebarModel(environment: environment)
        workspace.onFollowReference = { [weak self] table, connectionID, filter in
            self?.openTable(table, connectionID: connectionID, filter: filter)
        }
    }

    private func dialect(for connectionID: UUID) -> SQLDialect {
        environment.connections.first { $0.id == connectionID }?.dialect ?? .postgresql
    }

    /// Opens a table with a filter already applied, which is how a foreign key is followed.
    public func openTable(_ table: TableRef, connectionID: UUID, filter: [FilterRule]) {
        let tab = openTable(table, connectionID: connectionID, forceNew: false)
        guard let controller = tableControllers[tab.id] else { return }
        workspace.isFilterBarVisible = true
        Task {
            if controller.model == nil { await controller.start() }
            await controller.applyFilter(filter)
        }
    }

    @discardableResult
    public func openServerActivity(connectionID: UUID) -> WorkspaceTab {
        let tab = workspace.openServerActivity(connectionID: connectionID)
        if serverControllers[tab.id] == nil {
            serverControllers[tab.id] = ServerActivityController(
                connectionID: connectionID, dialect: dialect(for: connectionID), environment: environment
            )
        }
        return tab
    }

    /// The Server tab on its Users pane, with the grant picker on `database`.
    public func openUsers(connectionID: UUID, database: String?) {
        let tab = openServerActivity(connectionID: connectionID)
        let controller = serverController(for: tab)
        controller.initialPane = "users"
        controller.focusDatabase = database
        Task { await controller.loadUsers() }
    }

    public func serverController(for tab: WorkspaceTab) -> ServerActivityController {
        if let existing = serverControllers[tab.id] { return existing }
        let made = ServerActivityController(
            connectionID: tab.connectionID, dialect: dialect(for: tab.connectionID), environment: environment
        )
        serverControllers[tab.id] = made
        return made
    }

    @discardableResult
    public func openSource(_ object: SourceObject, connectionID: UUID) -> WorkspaceTab {
        let tab = workspace.openSource(object, connectionID: connectionID)
        _ = sourceController(for: tab, object: object)
        return tab
    }

    @discardableResult
    public func openQueryBuilder(_ schema: SchemaRef, connectionID: UUID) -> WorkspaceTab {
        let tab = workspace.openQueryBuilder(schema, connectionID: connectionID)
        _ = builderController(for: tab, schema: schema)
        return tab
    }

    public func builderController(for tab: WorkspaceTab, schema: SchemaRef) -> QueryBuilderController {
        if let existing = builderControllers[tab.id] { return existing }
        let made = QueryBuilderController(
            schema: schema, connectionID: tab.connectionID,
            dialect: dialect(for: tab.connectionID), environment: environment
        )
        builderControllers[tab.id] = made
        return made
    }

    /// The builder for the front tab, when it is one.
    public var activeBuilderController: QueryBuilderController? {
        guard let tab = workspace.selectedTab else { return nil }
        return builderControllers[tab.id]
    }

    public func showQueryBuilder() {
        guard let id = workspace.activeConnectionID else { return }
        openQueryBuilder(defaultSchema(for: id), connectionID: id)
    }

    /// Where a builder opened on a connection starts: the front tab's schema, else the
    /// database expanded in the sidebar, else the connection's default. The builder
    /// itself falls back to the first schema the server lists when that is still empty.
    public func defaultSchema(for connectionID: UUID) -> SchemaRef {
        guard let config = environment.connections.first(where: { $0.id == connectionID }) else {
            return SchemaRef(database: "", schema: "")
        }
        if let tab = workspace.selectedTab, tab.connectionID == connectionID, let ref = tab.tableRef {
            return ref.schemaRef
        }
        let marker = connectionID.uuidString
        if let expandedDatabase = sidebar.expanded
            .filter({ $0.contains(marker) && $0.contains("/db/") && !$0.contains("/schema/") })
            .sorted().first,
            let name = expandedDatabase.components(separatedBy: "/db/").last
        {
            return SchemaRef.pseudoSchema(config.dialect, database: name) ?? SchemaRef(database: name, schema: "public")
        }
        let database = config.database ?? ""
        return SchemaRef.pseudoSchema(config.dialect, database: database)
            ?? SchemaRef(database: database, schema: "public")
    }

    public func sourceController(for tab: WorkspaceTab, object: SourceObject) -> SourceController {
        if let existing = sourceControllers[tab.id] { return existing }
        let made = SourceController(
            object: object, connectionID: tab.connectionID,
            dialect: dialect(for: tab.connectionID), environment: environment
        )
        sourceControllers[tab.id] = made
        return made
    }

    // MARK: - Tabs

    public func tableController(for tab: WorkspaceTab) -> TableTabController? {
        tableControllers[tab.id]
    }

    public func queryController(for tab: WorkspaceTab) -> QueryTabController? {
        queryControllers[tab.id]
    }

    /// The query controller of the selected tab, which is what the Run commands act on.
    public var activeQueryController: QueryTabController? {
        guard let tab = workspace.selectedTab, tab.isQueryTab else { return nil }
        return queryControllers[tab.id]
    }

    public var activeTableController: TableTabController? {
        guard let tab = workspace.selectedTab, !tab.isQueryTab else { return nil }
        return tableControllers[tab.id]
    }

    @discardableResult
    public func openTable(_ table: TableRef, connectionID: UUID, forceNew: Bool = false) -> WorkspaceTab {
        let tab = workspace.openTable(table, connectionID: connectionID, forceNew: forceNew)
        if tableControllers[tab.id] == nil {
            let dialect = environment.connections.first { $0.id == connectionID }?.dialect ?? .postgresql
            tableControllers[tab.id] = TableTabController(
                table: table, connectionID: connectionID, dialect: dialect, environment: environment
            )
        }
        return tab
    }

    @discardableResult
    public func newQueryTab(connectionID: UUID, sql: String = "") -> WorkspaceTab {
        let tab = workspace.newQueryTab(connectionID: connectionID, sql: sql)
        let dialect = environment.connections.first { $0.id == connectionID }?.dialect ?? .postgresql
        let controller = QueryTabController(
            connectionID: connectionID, dialect: dialect, environment: environment
        )
        controller.sql = sql
        queryControllers[tab.id] = controller
        return tab
    }

    public func closeSelectedTab() {
        guard let id = workspace.selectedTabID else { return }
        closeTab(id)
    }

    /// Closes a tab and releases everything it owned: its grid, its held connection.
    public func closeTab(_ id: UUID) {
        workspace.closeTab(id)
        pruneControllers()
    }

    public func closeOtherTabs(_ id: UUID) {
        workspace.closeOtherTabs(id)
        pruneControllers()
    }

    /// Closes a connection's tabs and disconnects it, asking first when tabs are open.
    ///
    /// A tab may hold uncommitted grid edits or an open transaction; closing it throws
    /// those away, so the person is told what will go before anything does.
    public func disconnect(_ connectionID: UUID) {
        guard let config = environment.connections.first(where: { $0.id == connectionID }) else { return }
        let open = workspace.tabs(for: connectionID)
        let unsaved = open.filter { hasUnsavedWork($0) }.count
        guard !open.isEmpty else {
            sidebar.collapseConnection(connectionID)
            Task { await environment.disconnect(connectionID) }
            return
        }
        var message = "\(open.count) open tab\(open.count == 1 ? "" : "s") on this connection will be closed."
        if unsaved > 0 {
            message +=
                " \(unsaved) of them \(unsaved == 1 ? "has" : "have") uncommitted changes or an open transaction, which will be lost."
        }
        workspace.confirmation = DestructiveConfirmation(
            title: "Disconnect from “\(config.name)”?",
            message: message,
            confirmTitle: "Disconnect",
            action: { [weak self] in
                guard let self else { return }
                closeTabs(for: connectionID)
                sidebar.collapseConnection(connectionID)
                await environment.disconnect(connectionID)
            }
        )
    }

    /// Closes a database: its tabs go, after asking, and its branch of the tree folds.
    ///
    /// On MySQL a database is one of many on the connection, so the connection stays up.
    /// On PostgreSQL a query tab's session database is the connection's own.
    public func closeDatabase(connectionID: UUID, name: String, sidebarItemID: SidebarItem.ID) {
        let dialect = dialect(for: connectionID)
        let open = workspace.tabs(for: connectionID, database: name) { [weak self] tab in
            guard let self, let query = queryControllers[tab.id] else { return nil }
            switch dialect {
            // A query tab on MySQL or SQLite belongs to the database its session is on.
            case .mysql, .sqlite: return query.sessionDatabase
            case .postgresql: return environment.connections.first { $0.id == connectionID }?.database
            }
        }
        let fold = { [weak self] in self?.sidebar.collapseSubtree(sidebarItemID) }
        guard !open.isEmpty else {
            fold()
            return
        }
        let unsaved = open.filter { hasUnsavedWork($0) }.count
        var message = "\(open.count) open tab\(open.count == 1 ? "" : "s") on this database will be closed."
        if unsaved > 0 {
            message +=
                " \(unsaved) of them \(unsaved == 1 ? "has" : "have") uncommitted changes or an open transaction, which will be lost."
        }
        workspace.confirmation = DestructiveConfirmation(
            title: "Close “\(name)”?",
            message: message,
            confirmTitle: "Close Database",
            action: { [weak self] in
                guard let self else { return }
                workspace.closeTabs(Set(open.map(\.id)))
                pruneControllers()
                fold()
            }
        )
    }

    /// Closes every tab of a connection and frees what they owned.
    public func closeTabs(for connectionID: UUID) {
        workspace.closeTabs(for: connectionID)
        pruneControllers()
    }

    /// Whether a tab holds edits or an open transaction.
    public func hasUnsavedWork(_ tab: WorkspaceTab) -> Bool {
        if let controller = queryControllers[tab.id] { return controller.isInTransaction || controller.hasPendingEdits }
        if let controller = tableControllers[tab.id] {
            return (controller.model?.edits.pendingStatementCount ?? 0) > 0
        }
        return false
    }

    /// Drops the controllers of tabs that are no longer open, so a closed tab's grid is
    /// released rather than kept for the life of the window.
    public func pruneControllers() {
        let open = Set(workspace.tabs.map(\.id))
        for id in queryControllers.keys where !open.contains(id) {
            if let controller = queryControllers.removeValue(forKey: id) {
                Task { await controller.releaseHeldConnection() }
            }
        }
        tableControllers = tableControllers.filter { open.contains($0.key) }
        objectsControllers = objectsControllers.filter { open.contains($0.key) }
        serverControllers.filter { !open.contains($0.key) }.values.forEach { $0.stopPolling() }
        serverControllers = serverControllers.filter { open.contains($0.key) }
        sourceControllers = sourceControllers.filter { open.contains($0.key) }
        builderControllers = builderControllers.filter { open.contains($0.key) }
    }

    // MARK: - Commands the menus call

    public func newQueryTab() {
        guard let id = workspace.activeConnectionID else { return }
        newQueryTab(connectionID: id)
    }

    public func run(all: Bool) {
        guard let controller = activeQueryController else { return }
        controller.editorDidRequestRun(all ? .all : .current, selection: controller.selectedRange)
    }

    public func runCurrentStatement() {
        activeQueryController?.editorDidRequestRun(.current, selection: nil)
    }

    public func runSelection() {
        activeQueryController?.runSelection()
    }

    public func cancel() {
        activeQueryController?.cancel()
    }

    public func commit() {
        if let controller = activeQueryController {
            // Edits on a result come first; with none pending, Commit means the transaction.
            let statements = controller.pendingStatements()
            if !statements.isEmpty, let tab = workspace.selectedTab, let config = workspace.activeConnection {
                workspace.commitPreview = CommitPreview(
                    statements: statements, dialect: controller.dialect,
                    connectionName: config.name, isProduction: config.isProduction, tab: tab)
                return
            }
            Task { await controller.commitTransaction() }
            return
        }
        guard let tab = workspace.selectedTab,
            let controller = tableControllers[tab.id],
            let model = controller.model,
            let config = workspace.activeConnection
        else { return }
        let statements = controller.pendingStatements()
        guard !statements.isEmpty else { return }
        workspace.commitPreview = CommitPreview(
            statements: statements, dialect: model.dialect,
            connectionName: config.name, isProduction: config.isProduction, tab: tab
        )
    }

    public func rollback() {
        if let controller = activeQueryController {
            Task { await controller.rollbackTransaction() }
            return
        }
        // Refused while a write is on the server; the controller says so by doing nothing.
        activeTableController?.discardEdits()
    }

    public func refresh() {
        if let controller = activeTableController {
            Task { await controller.refresh() }
            return
        }
        guard let id = workspace.activeConnectionID else { return }
        Task { await sidebar.refresh(connectionID: id) }
    }

    public func formatSQL() {
        activeQueryController?.formatSQL()
    }

    public func explain(analyze: Bool) {
        activeQueryController?.explain(analyze: analyze)
    }

    public func showCommandPalette() { workspace.isCommandPalettePresented = true }
    public func showSnippets() { workspace.isSnippetsPresented = true }

    /// Opens a Tools wizard with the active connection and its schema as the source.
    public func presentTool(_ kind: ToolKind) {
        let id = workspace.activeConnectionID
        let fromTab: SchemaRef? = workspace.selectedTab?.tableRef?.schemaRef
        workspace.pendingTool = ToolRequest(
            kind: kind, connectionID: id, schema: fromTab ?? id.map { defaultSchema(for: $0) })
    }

    public func presentDump() {
        // From the menu there may be no active connection; the sheet asks either way,
        // with the active one (or the first) only as a starting point.
        guard let id = workspace.activeConnectionID ?? environment.connections.first?.id else { return }
        let schema = workspace.selectedTab?.tableRef?.schemaRef ?? defaultSchema(for: id)
        workspace.pendingDump = DumpRequest(connectionID: id, schema: schema, tables: nil, choosesSource: true)
    }

    public func presentScriptImport() {
        guard let id = workspace.activeConnectionID ?? environment.connections.first?.id else { return }
        workspace.pendingScriptImport = ScriptImportRequest(
            connectionID: id, database: workspace.activeConnection?.database, choosesTarget: true)
    }

    public func showServerActivity() {
        guard let id = workspace.activeConnectionID else { return }
        openServerActivity(connectionID: id)
    }

    /// Asks the front table tab to import a CSV file.
    public func importCSV() {
        guard let tab = workspace.selectedTab, let table = tab.tableRef else { return }
        workspace.pendingTableOperation = TableOperationRequest(
            kind: .importCSV, table: table, connectionID: tab.connectionID
        )
    }

    /// ⌘F: the editor's find bar in a query tab; the search field of any other tab.
    public func findInEditor(replace: Bool) {
        if let tab = workspace.selectedTab, tab.isQueryTab {
            let tag =
                replace
                ? NSTextFinder.Action.showReplaceInterface.rawValue
                : NSTextFinder.Action.showFindInterface.rawValue
            let item = NSMenuItem()
            item.tag = tag
            NSApp.sendAction(#selector(NSTextView.performFindPanelAction(_:)), to: nil, from: item)
            return
        }
        if workspace.selectedTab?.tableRef != nil { workspace.isFilterBarVisible = true }
        NotificationCenter.default.post(name: .tinkerFocusSearch, object: nil)
    }

    public func toggleReadOnly() {
        guard let id = workspace.activeConnectionID,
            let session = environment.session(for: id),
            let config = environment.connections.first(where: { $0.id == id })
        else { return }
        let apply: @MainActor () async -> Void = { [environment] in
            // Every session of the connection unlocks or locks together, including any
            // opened later on another of its databases.
            let current = await session.isReadOnly
            await environment.setReadOnlyOverride(for: id, current)
        }
        Task {
            // Unlocking a production connection is the one toggle worth a typed name.
            guard config.isProduction, await session.isReadOnly else {
                await apply()
                return
            }
            workspace.confirmation = DestructiveConfirmation(
                title: "Unlock writes on “\(config.name)”?",
                message:
                    "This is a production connection marked read-only. Unlocking lets every tab on it write until the app quits or you lock it again with ⌘⇧L.",
                requiredTypedName: config.name,
                confirmTitle: "Unlock",
                action: apply
            )
        }
    }

    public func copySelection(_ format: ClipboardFormat) {
        if let controller = activeTableController {
            controller.copySelection(format: format, nullText: settings.nullDisplayText)
        } else {
            activeQueryController?.copySelection(format: format)
        }
    }

    public func paste() { activeTableController?.paste() }
    public func setNull() {
        if let query = activeQueryController {
            query.setSelectionNull()
        } else {
            activeTableController?.setSelectionNull()
        }
    }
    public func addRow() {
        if let query = activeQueryController { query.addRow() } else { activeTableController?.addRow() }
    }
    public func deleteRows() {
        if let query = activeQueryController {
            query.deleteSelectedRows()
        } else {
            activeTableController?.deleteSelectedRows()
        }
    }

    public func cycleResultTab(forward: Bool) {
        guard let controller = activeQueryController, !controller.results.isEmpty else { return }
        let index = controller.results.firstIndex { $0.id == controller.selectedResultID } ?? 0
        let next =
            forward
            ? (index + 1) % controller.results.count
            : (index - 1 + controller.results.count) % controller.results.count
        controller.selectedResultID = controller.results[next].id
    }

    public func openSQLFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = openSQLFile(at: url)
    }

    /// Opens a `.sql` file as a query tab on the active connection. False when there is no
    /// connection to run it on, or the file is not text.
    @discardableResult
    public func openSQLFile(at url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
            let id = workspace.activeConnectionID
        else { return false }
        let tab = newQueryTab(connectionID: id, sql: text)
        tab.title = url.lastPathComponent
        return true
    }

    /// File › Open SQLite Database…: the file becomes a connection.
    public func openSQLiteDatabase() {
        SQLiteFileOpener.chooseAndOpen(in: self)
    }

    public func saveSQLFile() {
        guard let controller = activeQueryController, let tab = workspace.selectedTab else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(tab.title).sql"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? controller.sql.write(to: url, atomically: true, encoding: .utf8)
    }

    /// The grid shown by whichever tab is selected, for export.
    public var activeGrid: GridModel? {
        guard let tab = workspace.selectedTab else { return nil }
        return tab.isQueryTab
            ? queryControllers[tab.id]?.selectedResult?.grid
            : tableControllers[tab.id]?.model
    }
}
