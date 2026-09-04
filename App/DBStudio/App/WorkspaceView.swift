import DBCore
import DBGrid
import DBSQL
import SwiftUI
import UniformTypeIdentifiers

/// One workspace window: sidebar, tab bar, tab content, status bar.
public struct WorkspaceView: View {
    @State private var controller: WorkspaceController
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var isFirstRunPresented = false

    let environment: AppEnvironment
    @Bindable var settings: AppSettings

    public init(environment: AppEnvironment, settings: AppSettings) {
        self.environment = environment
        self.settings = settings
        _controller = State(
            initialValue: WorkspaceController(
                environment: environment, settings: settings
            ))
    }

    /// `@Bindable` on the model, so the sheets that need a binding still have one.
    var workspace: WorkspaceModel { controller.workspace }
    var boundWorkspace: Bindable<WorkspaceModel> { Bindable(controller.workspace) }
    var sidebar: SidebarModel { controller.sidebar }
    var tableControllers: [UUID: TableTabController] { controller.tableControllers }
    var queryControllers: [UUID: QueryTabController] { controller.queryControllers }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                workspace: workspace,
                sidebar: sidebar,
                onOpenTable: openTable,
                onNewQuery: newQuery,
                onOpenSource: { object, id in controller.openSource(object, connectionID: id) },
                onOpenActivity: { id in controller.openServerActivity(connectionID: id) },
                onOpenBuilder: { schema, id in
                    controller.openQueryBuilder(
                        schema.schema.isEmpty ? controller.defaultSchema(for: id) : schema, connectionID: id)
                },
                onDisconnect: { id in controller.disconnect(id) },
                onCloseTabs: { id in controller.closeTabs(for: id) },
                onCloseDatabase: { id, name, itemID in
                    controller.closeDatabase(connectionID: id, name: name, sidebarItemID: itemID)
                },
                onOpenUsers: { id, database in controller.openUsers(connectionID: id, database: database) }
            )
            .navigationSplitViewColumnWidth(
                min: DesignTokens.Metrics.sidebarMinWidth,
                ideal: DesignTokens.Metrics.sidebarIdealWidth,
                max: 460
            )
        } detail: {
            VStack(spacing: 0) {
                TabBarView(
                    workspace: workspace,
                    hasUnsavedWork: hasUnsavedWork,
                    onClose: { controller.closeTab($0) },
                    onCloseOthers: { controller.closeOtherTabs($0) }
                ) {
                    if let id = workspace.activeConnectionID { newQuery(id, "") }
                }
                Divider()
                content
                Divider()
                statusBar
            }
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .navigationTitle(workspace.displayedConnection?.name ?? Product.name)
        .navigationSubtitle(subtitle)
        .toolbar { toolbarContent }
        .onAppear { CommandCenter.shared.activate(controller) }
        .onChange(of: controller.isSidebarVisible) { _, visible in
            columnVisibility = visible ? .all : .detailOnly
        }
        .onDisappear { CommandCenter.shared.deactivate(controller) }
        .task {
            await environment.load()
            sidebar.rebuildRoots()
            for config in environment.connections { sidebar.watchState(of: config.id) }
            // Shown once, and only when there is nothing to connect to yet.
            let seen = await environment.setting("firstRun.seen", default: false)
            if !seen, environment.connections.isEmpty { isFirstRunPresented = true }
            await UIDemo.apply(to: controller)
        }
        .onChange(of: environment.connections) { _, _ in sidebar.rebuildRoots() }
        .onChange(of: environment.groups) { _, _ in sidebar.rebuildRoots() }
        .sheet(item: boundWorkspace.editingConnection) { config in
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
        .sheet(item: boundWorkspace.commitPreview) { preview in
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
        .sheet(item: boundWorkspace.confirmation) { confirmation in
            DestructiveConfirmationView(confirmation: confirmation) {
                workspace.confirmation = nil
            }
        }
        .sheet(isPresented: boundWorkspace.isQuickOpenPresented) {
            QuickOpenView(workspace: workspace, sidebar: sidebar) { table, connectionID in
                openTable(table, connectionID, false)
            }
        }
        .sheet(isPresented: boundWorkspace.isCommandPalettePresented) {
            CommandPaletteView(controller: controller)
        }
        .sheet(isPresented: boundWorkspace.isSnippetsPresented) {
            SnippetsView(
                environment: environment,
                dialect: workspace.activeConnection?.dialect ?? .postgresql,
                onInsert: { text in
                    workspace.isSnippetsPresented = false
                    insertIntoEditor(text)
                },
                onDismiss: { workspace.isSnippetsPresented = false }
            )
        }
        .sheet(item: boundWorkspace.pendingTableOperation) { request in
            TableOperationSheet(
                request: request,
                environment: environment,
                onFinished: { opened in
                    workspace.pendingTableOperation = nil
                    if let opened { openTable(opened, request.connectionID, false) }
                    controller.refresh()
                    Task { await sidebar.refresh(connectionID: request.connectionID) }
                },
                onCancel: { workspace.pendingTableOperation = nil }
            )
        }
        .sheet(item: boundWorkspace.pendingDump) { request in
            DumpSheet(request: request, environment: environment) { workspace.pendingDump = nil }
        }
        .sheet(item: boundWorkspace.pendingScriptImport) { request in
            ImportScriptSheet(request: request, environment: environment) {
                workspace.pendingScriptImport = nil
                controller.refresh()
                Task { await sidebar.refresh(connectionID: request.connectionID) }
            }
        }
        .sheet(item: boundWorkspace.pendingPaste) { request in
            PasteSheet(request: request, environment: environment) {
                workspace.pendingPaste = nil
                controller.refresh()
                Task { await sidebar.refresh(connectionID: request.targetConnectionID) }
            }
        }
        .sheet(isPresented: boundWorkspace.isNewTablePresented) {
            if let context = designerContext {
                NewTableSheet(
                    connectionID: context.connectionID,
                    schema: context.schema,
                    dialect: context.dialect,
                    environment: environment,
                    isProduction: context.isProduction,
                    onCreated: { table in
                        workspace.isNewTablePresented = false
                        workspace.newTableContext = nil
                        openTable(table, context.connectionID, false)
                        Task { await sidebar.refresh(connectionID: context.connectionID) }
                    },
                    onCancel: {
                        workspace.isNewTablePresented = false
                        workspace.newTableContext = nil
                    }
                )
            } else {
                noConnectionSheet("New table") { workspace.isNewTablePresented = false }
            }
        }
        .sheet(isPresented: boundWorkspace.isStructureSyncPresented) {
            if let context = designerContext, let table = selectedTableRef {
                StructureSyncSheet(
                    source: table,
                    sourceConnectionID: context.connectionID,
                    dialect: context.dialect,
                    environment: environment,
                    onGenerate: { connectionID, script in
                        workspace.isStructureSyncPresented = false
                        newQuery(connectionID, script)
                    },
                    onCancel: { workspace.isStructureSyncPresented = false }
                )
            } else {
                noConnectionSheet("Structure sync needs a table tab open") {
                    workspace.isStructureSyncPresented = false
                }
            }
        }
        .sheet(isPresented: boundWorkspace.isHistoryPresented) {
            HistoryView(
                environment: environment,
                connectionID: workspace.activeConnectionID,
                onInsert: { sql in
                    workspace.isHistoryPresented = false
                    insertIntoEditor(sql)
                },
                onDismiss: { workspace.isHistoryPresented = false }
            )
        }
        .sheet(isPresented: boundWorkspace.isExportPresented) { exportSheet }
        .sheet(isPresented: $isFirstRunPresented) {
            FirstRunView(
                onAddConnection: { workspace.presentNewConnection() },
                onDismiss: {
                    isFirstRunPresented = false
                    Task { await environment.setSetting(true, for: "firstRun.seen") }
                },
                onSetDiagnostics: { enabled in
                    Task { await environment.setSetting(enabled, for: CrashReporter.optInSettingKey) }
                }
            )
        }
    }

    /// Puts text in the front editor, or opens a new tab with it.
    private func insertIntoEditor(_ sql: String) {
        if let tab = workspace.selectedTab, tab.isQueryTab,
            let controller = queryControllers[tab.id]
        {
            controller.insertAtCaret(sql)
        } else if let id = workspace.activeConnectionID {
            newQuery(id, sql)
        }
    }

    private var subtitle: String {
        guard let config = workspace.displayedConnection else { return Product.tagline }
        var parts = ["\(config.user)@\(config.host)"]
        if let database = config.database { parts.append(database) }
        return parts.joined(separator: " · ")
    }

    /// The window toolbar.
    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                if let id = workspace.activeConnectionID { newQuery(id, "") }
            } label: {
                Label("New Query", systemImage: Icon.newQuery)
            }
            .help("New query tab (⌘T)")
            .disabled(workspace.activeConnectionID == nil)
        }

        ToolbarItemGroup(placement: .principal) {
            ControlGroup {
                Button {
                    controller.run(all: false)
                } label: {
                    Label("Run", systemImage: Icon.run)
                }
                .help("Run the statement under the cursor, or the highlighted block (⌘R)")
                .disabled(queryController == nil || queryController?.isRunning == true)

                Button {
                    controller.run(all: true)
                } label: {
                    Label("Run All", systemImage: Icon.runAll)
                }
                .help("Run every statement on the page (⌘⌥R)")
                .disabled(queryController == nil || queryController?.isRunning == true)

                Button {
                    queryController?.cancel()
                } label: {
                    Label("Stop", systemImage: Icon.stop)
                }
                .help("Cancel on the server (⌘.)")
                .disabled(queryController?.isRunning != true)

                Button {
                    queryController?.explain(analyze: false)
                } label: {
                    Label("Explain", systemImage: Icon.explain)
                }
                .help("Show the plan for the statement under the cursor (⌘⇧E)")
                .disabled(queryController == nil || queryController?.isRunning == true)
            }

            ControlGroup {
                Button {
                    controller.commit()
                } label: {
                    Label("Commit", systemImage: Icon.commit)
                }
                .help("Commit (⌘⇧S)")
                .disabled(!hasPendingWork)

                Button {
                    controller.rollback()
                } label: {
                    Label("Rollback", systemImage: Icon.rollback)
                }
                .help("Roll back (⌘⇧⌫)")
                .disabled(!hasPendingWork)
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                controller.refresh()
            } label: {
                Label("Refresh", systemImage: Icon.refresh)
            }
            .help("Refresh (F5)")

            Button {
                workspace.isCommandPalettePresented = true
            } label: {
                Label("Commands", systemImage: Icon.command)
            }
            .help("Command palette (⌘K)")

            Button {
                workspace.isQuickOpenPresented = true
            } label: {
                Label("Find Table", systemImage: Icon.search)
            }
            .help("Quick-open a table (⌘⇧O)")

            Button {
                workspace.isInspectorVisible.toggle()
            } label: {
                Label("Inspector", systemImage: Icon.inspector)
            }
            .help("Show or hide the inspector (⌘⌥I)")
            .disabled(!(workspace.selectedTab.map { !$0.isQueryTab && $0.tableRef != nil } ?? false))
        }
    }

    var queryController: QueryTabController? {
        guard let tab = workspace.selectedTab, tab.isQueryTab else { return nil }
        return queryControllers[tab.id]
    }

    /// True when there is something a commit or rollback would act on.
    var hasPendingWork: Bool {
        guard let tab = workspace.selectedTab else { return false }
        return hasUnsavedWork(tab)
    }

    func hasUnsavedWork(_ tab: WorkspaceTab) -> Bool {
        return controller.hasUnsavedWork(tab)
    }

    // MARK: - Content

    /// Every open tab's view stays alive and only the front one is shown. Rebuilding a
    /// tab's grid or editor on each switch flashed the content and threw away the editor's
    /// undo history and the grid's scroll position.
    @ViewBuilder
    var content: some View {
        if workspace.tabs.isEmpty {
            welcome
        } else {
            ZStack {
                ForEach(workspace.tabs) { tab in
                    let isFront = workspace.selectedTabID == tab.id
                    tabContent(tab)
                        .opacity(isFront ? 1 : 0)
                        .allowsHitTesting(isFront)
                        .accessibilityHidden(!isFront)
                        .zIndex(isFront ? 1 : 0)
                }
            }
        }
    }

    @ViewBuilder
    private func tabContent(_ tab: WorkspaceTab) -> some View {
        switch tab.kind {
        case .table:
            if let controller = tableControllers[tab.id] {
                TableTabView(controller: controller, workspace: workspace, tab: tab)
                    .id(tab.id)
            }
        case let .objects(schema):
            ObjectsView(
                controller: objectsController(for: tab, schema: schema),
                onOpen: { table in openTable(table, tab.connectionID, false) },
                onOpenSource: { object in controller.openSource(object, connectionID: tab.connectionID) }
            )
            .id(tab.id)
        case .query:
            if let controller = queryControllers[tab.id] {
                QueryTabView(
                    controller: controller,
                    workspace: workspace,
                    tab: tab,
                    fontName: settings.editorFontName,
                    fontSize: settings.editorFontSize
                )
                .id(tab.id)
            }
        case .serverActivity:
            ServerActivityView(controller: controller.serverController(for: tab))
                .id(tab.id)
        case let .source(object):
            SourceView(
                controller: controller.sourceController(for: tab, object: object),
                fontName: settings.editorFontName,
                fontSize: settings.editorFontSize,
                onEditInQuery: { sql in newQuery(tab.connectionID, sql) }
            )
            .id(tab.id)
        case let .queryBuilder(schema):
            QueryBuilderView(
                controller: controller.builderController(for: tab, schema: schema),
                fontName: settings.editorFontName,
                fontSize: settings.editorFontSize,
                onOpenInQuery: { sql in newQuery(tab.connectionID, sql) },
                onOpenTable: { table in openTable(table, tab.connectionID, false) },
                onSchemaChanged: { Task { await sidebar.refresh(connectionID: tab.connectionID) } }
            )
            .id(tab.id)
        }
    }

    /// What an empty window says: the two things a person can do next.
    private var welcome: some View {
        VStack(spacing: DesignTokens.Spacing.lg) {
            if environment.connections.isEmpty {
                EmptyStateView(
                    icon: Icon.connection,
                    title: "No connections yet",
                    message: "Add a PostgreSQL or MySQL server to start browsing tables and running queries."
                ) {
                    Button {
                        workspace.presentNewConnection()
                    } label: {
                        Label("Add a Connection…", systemImage: Icon.add)
                    }
                    .keyboardShortcut(.defaultAction)
                }
            } else {
                EmptyStateView(
                    icon: Icon.welcome,
                    title: "Ready when you are",
                    message: "Open a table from the sidebar, or start a query on the current connection.",
                    fills: false
                ) {
                    Button {
                        if let id = workspace.activeConnectionID { newQuery(id, "") }
                    } label: {
                        Label("New Query", systemImage: Icon.newQuery)
                    }
                    .keyboardShortcut("t", modifiers: .command)
                    Button {
                        workspace.isQuickOpenPresented = true
                    } label: {
                        Label("Find a Table", systemImage: Icon.search)
                    }
                    Button {
                        workspace.isCommandPalettePresented = true
                    } label: {
                        Label("Commands", systemImage: Icon.command)
                    }
                }
                HStack(spacing: DesignTokens.Spacing.lg) {
                    shortcutHint("⌘T", "New query")
                    shortcutHint("⌘K", "Commands")
                    shortcutHint("⌘⇧O", "Find table")
                    shortcutHint("⌘R", "Run")
                }
                Text(Product.credit)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, DesignTokens.Spacing.lg)
            }
            if let error = environment.startupError {
                InlineBanner(kind: .error, message: error, onDismiss: {})
                    .frame(maxWidth: 520)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func shortcutHint(_ keys: String, _ label: String) -> some View {
        KeyHint(keys: keys, label: label)
    }

    var statusBar: some View {
        StatusBarView {
            if let config = workspace.displayedConnection {
                HStack(spacing: DesignTokens.Spacing.xs + 2) {
                    Circle()
                        .fill(sidebar.state(of: config.id).indicatorColor)
                        .frame(width: 7, height: 7)
                    Text(config.name).foregroundStyle(.primary)
                }
                if let database = config.database {
                    Label(database, systemImage: Icon.database)
                }
                Text(sidebar.state(of: config.id).describedForStatusBar)
                if config.readOnly {
                    Label("Read-only", systemImage: Icon.readOnly).foregroundStyle(.orange)
                }
                if config.isProduction {
                    Label("Production", systemImage: Icon.production).foregroundStyle(.red)
                }
            } else {
                Text("No connection selected · \(Product.credit)")
            }
            Spacer()
            if let tab = workspace.selectedTab, tab.isQueryTab,
                let controller = queryControllers[tab.id], controller.isInTransaction
            {
                Label("Transaction open", systemImage: Icon.transaction).foregroundStyle(.orange)
            }
            if let tab = workspace.selectedTab, let controller = tableControllers[tab.id],
                let model = controller.model, model.edits.pendingStatementCount > 0
            {
                Label(
                    "\(model.edits.pendingStatementCount) pending change\(model.edits.pendingStatementCount == 1 ? "" : "s")",
                    systemImage: Icon.edit
                )
                .foregroundStyle(.orange)
            }
        }
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
            noConnectionSheet("Nothing to export") { workspace.isExportPresented = false }
        }
    }

    func gridForActiveTab(_ tab: WorkspaceTab) -> GridModel? {
        switch tab.kind {
        case .table: tableControllers[tab.id]?.model
        case .query: queryControllers[tab.id]?.selectedResult?.grid
        // The other tabs are not grids; copy and export act on grids.
        case .objects, .serverActivity, .source, .queryBuilder: nil
        }
    }

    func selectionRows(tab: WorkspaceTab, grid: GridModel) -> [[DBValue]] {
        let selection: GridSelection =
            switch tab.kind {
            case .table: tableControllers[tab.id]?.selection ?? GridSelection()
            case .query: queryControllers[tab.id]?.selection ?? GridSelection()
            case .objects, .serverActivity, .source, .queryBuilder: GridSelection()
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
        controller.openTable(table, connectionID: connectionID, forceNew: forceNew)
    }

    /// One controller per Objects tab, kept for as long as the tab is.
    func objectsController(for tab: WorkspaceTab, schema: SchemaRef) -> ObjectsController {
        if let existing = controller.objectsControllers[tab.id] { return existing }
        let dialect =
            environment.connections
            .first { $0.id == tab.connectionID }?.dialect ?? .postgresql
        let made = ObjectsController(
            schema: schema, connectionID: tab.connectionID,
            dialect: dialect, environment: environment
        )
        controller.objectsControllers[tab.id] = made
        return made
    }

    func newQuery(_ connectionID: UUID, _ sql: String) {
        controller.newQueryTab(connectionID: connectionID, sql: sql)
    }

    // MARK: - Table designer

    /// Where a new table would go: the schema of whatever is open, or the connection's own.
    var designerContext: (connectionID: UUID, schema: SchemaRef, dialect: SQLDialect, isProduction: Bool)? {
        // Asked for from the sidebar: that folder's schema, whatever tab is in front.
        if let context = workspace.newTableContext,
            let config = environment.connections.first(where: { $0.id == context.connectionID })
        {
            return (context.connectionID, context.schema, config.dialect, config.isProduction)
        }
        guard
            let connectionID = workspace.selectedTab?.connectionID
                ?? workspace.tabs.first?.connectionID
                ?? environment.connections.first?.id,
            let config = environment.connections.first(where: { $0.id == connectionID })
        else { return nil }

        let schema =
            selectedTableRef?.schemaRef
            ?? SchemaRef(
                database: config.database ?? "",
                // MySQL's schema layer is the database itself; PostgreSQL's default is public.
                schema: config.dialect == .mysql ? (config.database ?? "") : "public"
            )
        return (connectionID, schema, config.dialect, config.isProduction)
    }

    /// The table the front tab shows, when it is a table tab.
    var selectedTableRef: TableRef? {
        guard let tab = workspace.selectedTab, case let .table(ref) = tab.kind else { return nil }
        return ref
    }

    func noConnectionSheet(_ message: String, dismiss: @escaping () -> Void) -> some View {
        SheetFrame(
            title: message, icon: Icon.info, subtitle: "Open a connection first.",
            width: DesignTokens.Metrics.compactSheetWidth
        ) {
            EmptyView()
        } footer: {
            Spacer()
            Button("OK", action: dismiss).keyboardShortcut(.defaultAction)
        }
    }
}
