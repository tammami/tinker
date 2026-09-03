import DBCore
import DBGrid
import DBSQL
import SwiftUI
import UniformTypeIdentifiers

/// One workspace window: sidebar, tab bar, tab content, status bar (SPEC §10.1).
public struct WorkspaceView: View {
    @State private var workspace: WorkspaceModel
    @State private var sidebar: SidebarModel
    @State private var tableControllers: [UUID: TableTabController] = [:]
    @State private var queryControllers: [UUID: QueryTabController] = [:]
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    let environment: AppEnvironment
    @Bindable var settings: AppSettings

    public init(environment: AppEnvironment, settings: AppSettings) {
        self.environment = environment
        self.settings = settings
        let workspace = WorkspaceModel(environment: environment)
        _workspace = State(initialValue: workspace)
        _sidebar = State(initialValue: SidebarModel(environment: environment))
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                workspace: workspace,
                sidebar: sidebar,
                onOpenTable: openTable,
                onNewQuery: newQuery
            )
            .navigationSplitViewColumnWidth(
                min: DesignTokens.Metrics.sidebarMinWidth, ideal: 260, max: 420
            )
        } detail: {
            VStack(spacing: 0) {
                TabBarView(workspace: workspace) {
                    if let id = workspace.activeConnectionID { newQuery(id, "") }
                }
                Divider()
                content
                Divider()
                statusBar
            }
        }
        .navigationTitle(workspace.activeConnection?.name ?? "DBStudio")
        .toolbar { toolbarContent }
        .focusedSceneValue(\.workspaceCommands, commands)
        .task {
            await environment.load()
            sidebar.rebuildRoots()
            for config in environment.connections { sidebar.watchState(of: config.id) }
        }
        .onChange(of: environment.connections.count) { _, _ in sidebar.rebuildRoots() }
        .sheet(item: $workspace.editingConnection) { config in
            ConnectionEditorView(
                config: config,
                isNew: workspace.isEditingNewConnection,
                environment: environment,
                onSave: { edited in
                    workspace.editingConnection = nil
                    workspace.isEditingNewConnection = false
                    Task {
                        await environment.save(edited)
                        await environment.invalidateSession(for: edited.id)
                        sidebar.rebuildRoots()
                        await sidebar.refresh(connectionID: edited.id)
                    }
                },
                onCancel: {
                    workspace.editingConnection = nil
                    workspace.isEditingNewConnection = false
                }
            )
        }
        .sheet(item: $workspace.commitPreview) { preview in
            CommitPreviewView(
                preview: preview,
                onExecute: {
                    guard let controller = tableControllers[preview.tab.id] else { return }
                    _ = await controller.commit()
                    workspace.commitPreview = nil
                },
                onCancel: { workspace.commitPreview = nil }
            )
        }
        .sheet(item: $workspace.confirmation) { confirmation in
            DestructiveConfirmationView(confirmation: confirmation) {
                workspace.confirmation = nil
            }
        }
        .sheet(isPresented: $workspace.isQuickOpenPresented) {
            QuickOpenView(workspace: workspace, sidebar: sidebar) { table, connectionID in
                openTable(table, connectionID, false)
            }
        }
        .sheet(isPresented: $workspace.isHistoryPresented) {
            HistoryView(
                environment: environment,
                connectionID: workspace.activeConnectionID,
                onInsert: { sql in
                    workspace.isHistoryPresented = false
                    if let tab = workspace.selectedTab, tab.isQueryTab,
                       let controller = queryControllers[tab.id] {
                        controller.sql = sql
                    } else if let id = workspace.activeConnectionID {
                        newQuery(id, sql)
                    }
                },
                onDismiss: { workspace.isHistoryPresented = false }
            )
        }
        .sheet(isPresented: $workspace.isExportPresented) { exportSheet }
    }

    /// The window toolbar (SPEC §10.1).
    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                if let id = workspace.activeConnectionID { newQuery(id, "") }
            } label: {
                Label("New Query", systemImage: "plus.square.on.square")
            }
            .help("New query tab (⌘T)")
            .disabled(workspace.activeConnectionID == nil)
        }

        ToolbarItemGroup {
            Button {
                queryController?.run(all: false)
            } label: {
                Label("Run", systemImage: "play.fill")
            }
            .help("Run the statement under the cursor (⌘↩)")
            .disabled(queryController == nil || queryController?.isRunning == true)

            Button {
                queryController?.cancel()
            } label: {
                Label("Cancel", systemImage: "stop.fill")
            }
            .help("Cancel on the server (⌘.)")
            .disabled(queryController?.isRunning != true)

            Button {
                commands.commit()
            } label: {
                Label("Commit", systemImage: "checkmark.circle")
            }
            .help("Commit (⌘⇧S)")
            .disabled(!hasPendingWork)

            Button {
                commands.rollback()
            } label: {
                Label("Rollback", systemImage: "arrow.uturn.backward.circle")
            }
            .help("Roll back (⌘⇧R)")
            .disabled(!hasPendingWork)

            Button {
                commands.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Refresh (⌘R)")

            Button {
                workspace.isQuickOpenPresented = true
            } label: {
                Label("Find Table", systemImage: "magnifyingglass")
            }
            .help("Quick-open a table (⌘⇧O)")
        }
    }

    var queryController: QueryTabController? {
        guard let tab = workspace.selectedTab, tab.isQueryTab else { return nil }
        return queryControllers[tab.id]
    }

    /// True when there is something a commit or rollback would act on.
    var hasPendingWork: Bool {
        guard let tab = workspace.selectedTab else { return false }
        if let controller = queryControllers[tab.id] { return controller.isInTransaction }
        if let controller = tableControllers[tab.id] {
            return (controller.model?.edits.pendingStatementCount ?? 0) > 0
        }
        return false
    }

    // MARK: - Content

    @ViewBuilder
    var content: some View {
        if let tab = workspace.selectedTab {
            switch tab.kind {
            case .table:
                if let controller = tableControllers[tab.id] {
                    TableTabView(controller: controller, workspace: workspace, tab: tab)
                }
            case .query:
                if let controller = queryControllers[tab.id] {
                    QueryTabView(
                        controller: controller,
                        workspace: workspace,
                        tab: tab,
                        fontName: settings.editorFontName,
                        fontSize: settings.editorFontSize
                    )
                }
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "cylinder.split.1x2")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
                if environment.connections.isEmpty {
                    Text("No connections yet.").foregroundStyle(.secondary)
                    Button("Add a Connection…") {
                        workspace.editingConnection = ConnectionConfig(
                            name: "New Connection", dialect: .postgresql,
                            host: "localhost", port: 5_432, user: NSUserName()
                        )
                        workspace.isEditingNewConnection = true
                    }
                } else {
                    Text("Open a table from the sidebar, or start a query.")
                        .foregroundStyle(.secondary)
                    Button("New Query Tab") {
                        if let id = workspace.activeConnectionID { newQuery(id, "") }
                    }
                    .keyboardShortcut("t", modifiers: .command)
                }
                if let error = environment.startupError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    var statusBar: some View {
        HStack(spacing: 12) {
            if let config = workspace.activeConnection {
                if let color = config.color {
                    Circle().fill(color.swiftUIColor).frame(width: 7, height: 7)
                }
                Text(config.name)
                if let database = config.database {
                    Text(database).foregroundStyle(.secondary)
                }
                Text(sidebar.state(of: config.id).describedForStatusBar)
                    .foregroundStyle(.secondary)
                if config.readOnly {
                    Label("read-only", systemImage: "lock")
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            if let tab = workspace.selectedTab, tab.isQueryTab,
               let controller = queryControllers[tab.id], controller.isInTransaction {
                Text("Transaction open").foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(.bar)
    }

    @ViewBuilder
    var exportSheet: some View {
        if let tab = workspace.selectedTab, let grid = gridForActiveTab(tab) {
            ExportView(
                columns: grid.columns,
                dialect: grid.dialect,
                table: tab.tableRef,
                hasSelection: true,
                loadedRowCount: grid.rowCount,
                streamAll: { write in await streamEverything(tab: tab, grid: grid, write: write) },
                selectionRows: { selectionRows(tab: tab, grid: grid) },
                loadedRows: { (0 ..< grid.rowCount).compactMap { grid.loadedRow($0) } },
                onDismiss: { workspace.isExportPresented = false }
            )
        } else {
            Text("Nothing to export").padding(30)
        }
    }

    func gridForActiveTab(_ tab: WorkspaceTab) -> GridModel? {
        switch tab.kind {
        case .table: tableControllers[tab.id]?.model
        case .query: queryControllers[tab.id]?.selectedResult?.grid
        }
    }

    func selectionRows(tab: WorkspaceTab, grid: GridModel) -> [[DBValue]] {
        let selection: GridSelection = switch tab.kind {
        case .table: tableControllers[tab.id]?.selection ?? GridSelection()
        case .query: queryControllers[tab.id]?.selection ?? GridSelection()
        }
        let columns = selection.columns(totalColumns: grid.columns.count)
        return selection.rows(totalRows: grid.displayRowCount).map { row in
            columns.map { grid.value(row: row, column: $0) ?? .null }
        }
    }

    /// Re-runs the table or query against the server and hands each batch to the exporter,
    /// so the whole result never has to be in memory at once.
    func streamEverything(
        tab: WorkspaceTab,
        grid: GridModel,
        write: @escaping @MainActor ([[DBValue]]) -> Void
    ) async {
        guard let session = environment.session(for: tab.connectionID) else { return }
        let sql: String
        switch grid.source {
        case let .table(table):
            sql = "SELECT * FROM \(Identifier.qualified(table, dialect: grid.dialect))"
        case let .query(statement):
            sql = statement
        }
        guard let (lease, connection) = try? await session.lease() else { return }
        defer { Task { await session.release(lease) } }
        do {
            for try await event in connection.execute(sql, parameters: []) {
                if case let .rows(batch) = event { write(batch.rows) }
            }
        } catch {
            // The export sheet reports the failure; the lease is returned either way.
            workspace.confirmation = DestructiveConfirmation(
                title: "Export failed",
                message: (error as? DBError)?.errorDescription ?? String(describing: error),
                confirmTitle: "OK",
                action: {}
            )
        }
    }

    // MARK: - Opening tabs

    func openTable(_ table: TableRef, _ connectionID: UUID, _ forceNew: Bool) {
        let tab = workspace.openTable(table, connectionID: connectionID, forceNew: forceNew)
        guard tableControllers[tab.id] == nil else { return }
        let dialect = environment.connections.first { $0.id == connectionID }?.dialect ?? .postgresql
        tableControllers[tab.id] = TableTabController(
            table: table, connectionID: connectionID, dialect: dialect, environment: environment
        )
    }

    func newQuery(_ connectionID: UUID, _ sql: String) {
        let tab = workspace.newQueryTab(connectionID: connectionID, sql: sql)
        let dialect = environment.connections.first { $0.id == connectionID }?.dialect ?? .postgresql
        let controller = QueryTabController(
            connectionID: connectionID, dialect: dialect, environment: environment
        )
        controller.sql = sql
        queryControllers[tab.id] = controller
    }

    // MARK: - Commands

    var commands: WorkspaceCommands {
        WorkspaceCommands(
            newQueryTab: {
                if let id = workspace.activeConnectionID { newQuery(id, "") }
            },
            run: { all in
                guard let tab = workspace.selectedTab, let controller = queryControllers[tab.id] else { return }
                controller.run(all: all)
            },
            cancel: {
                guard let tab = workspace.selectedTab, let controller = queryControllers[tab.id] else { return }
                controller.cancel()
            },
            commit: {
                guard let tab = workspace.selectedTab else { return }
                if let controller = queryControllers[tab.id] {
                    Task { await controller.commitTransaction() }
                } else if let controller = tableControllers[tab.id],
                          let config = workspace.activeConnection {
                    let statements = controller.pendingStatements()
                    guard !statements.isEmpty, let model = controller.model else { return }
                    workspace.commitPreview = CommitPreview(
                        statements: statements, dialect: model.dialect,
                        connectionName: config.name, isProduction: config.isProduction, tab: tab
                    )
                }
            },
            rollback: {
                guard let tab = workspace.selectedTab else { return }
                if let controller = queryControllers[tab.id] {
                    Task { await controller.rollbackTransaction() }
                } else {
                    tableControllers[tab.id]?.discardEdits()
                }
            },
            refresh: {
                guard let tab = workspace.selectedTab else {
                    if let id = workspace.activeConnectionID {
                        Task { await sidebar.refresh(connectionID: id) }
                    }
                    return
                }
                if let controller = tableControllers[tab.id] {
                    Task { await controller.refresh() }
                } else {
                    Task { await sidebar.refresh(connectionID: tab.connectionID) }
                }
            },
            quickOpen: { workspace.isQuickOpenPresented = true },
            toggleFilter: { workspace.isFilterBarVisible.toggle() },
            toggleSidebar: {
                columnVisibility = columnVisibility == .all ? .detailOnly : .all
            },
            toggleInspector: { workspace.isInspectorVisible.toggle() },
            closeTab: {
                if let id = workspace.selectedTabID { workspace.closeTab(id) }
            },
            selectTab: { workspace.selectTab(at: $0) },
            cycleTab: { workspace.cycleTab(forward: $0) },
            formatSQL: {
                guard let tab = workspace.selectedTab else { return }
                queryControllers[tab.id]?.formatSQL()
            },
            toggleReadOnly: {
                guard let id = workspace.activeConnectionID,
                      let session = environment.session(for: id) else { return }
                Task {
                    let current = await session.isReadOnly
                    await session.setReadOnlyOverride(current)
                }
            },
            export: { workspace.isExportPresented = true },
            copy: { format in
                guard let tab = workspace.selectedTab else { return }
                if let controller = tableControllers[tab.id] {
                    controller.copySelection(format: format, nullText: settings.nullDisplayText)
                } else {
                    queryControllers[tab.id]?.copySelection(format: format)
                }
            },
            paste: {
                guard let tab = workspace.selectedTab else { return }
                tableControllers[tab.id]?.paste()
            },
            setNull: {
                guard let tab = workspace.selectedTab else { return }
                tableControllers[tab.id]?.setSelectionNull()
            },
            addRow: {
                guard let tab = workspace.selectedTab else { return }
                tableControllers[tab.id]?.addRow()
            },
            deleteRows: {
                guard let tab = workspace.selectedTab else { return }
                tableControllers[tab.id]?.deleteSelectedRows()
            },
            showHistory: { workspace.isHistoryPresented = true },
            openSQLFile: { openSQLFile() },
            saveSQLFile: { saveSQLFile() },
            cycleResultTab: { forward in
                guard let tab = workspace.selectedTab,
                      let controller = queryControllers[tab.id],
                      !controller.results.isEmpty
                else { return }
                let index = controller.results.firstIndex { $0.id == controller.selectedResultID } ?? 0
                let next = forward
                    ? (index + 1) % controller.results.count
                    : (index - 1 + controller.results.count) % controller.results.count
                controller.selectedResultID = controller.results[next].id
            }
        )
    }

    func openSQLFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "sql") ?? .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8),
              let id = workspace.activeConnectionID
        else { return }
        newQuery(id, text)
        workspace.selectedTab?.title = url.lastPathComponent
    }

    func saveSQLFile() {
        guard let tab = workspace.selectedTab, let controller = queryControllers[tab.id] else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(tab.title).sql"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? controller.sql.write(to: url, atomically: true, encoding: .utf8)
    }
}
