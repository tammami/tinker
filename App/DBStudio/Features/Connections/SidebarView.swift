import DBCore
import DBSQL
import SwiftUI
import UniformTypeIdentifiers

/// The connections and schema tree.
public struct SidebarView: View {
    @Bindable var workspace: WorkspaceModel
    @Bindable var sidebar: SidebarModel
    let onOpenTable: (TableRef, UUID, Bool) -> Void
    let onNewQuery: (UUID, String) -> Void
    let onOpenSource: (SourceObject, UUID) -> Void
    let onOpenActivity: (UUID) -> Void
    let onOpenBuilder: (SchemaRef, UUID) -> Void
    /// Disconnecting and deleting close the connection's tabs, which the controller owns.
    let onDisconnect: (UUID) -> Void
    let onCloseTabs: (UUID) -> Void
    let onCloseDatabase: (UUID, String, SidebarItem.ID) -> Void
    let onOpenUsers: (UUID, String?) -> Void

    @State private var searchText = ""

    public var body: some View {
        List(selection: $workspace.sidebarSelection) {
            if filteredRoots.isEmpty, !searchText.isEmpty {
                Text("No connection or object matches “\(searchText)”")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, DesignTokens.Spacing.sm)
            }
            ForEach(filteredRoots) { item in
                SidebarRow(
                    item: item,
                    sidebar: sidebar,
                    workspace: workspace,
                    onOpenTable: onOpenTable,
                    onNewQuery: onNewQuery,
                    onOpenSource: onOpenSource,
                    onOpenActivity: onOpenActivity,
                    onOpenBuilder: onOpenBuilder,
                    onDisconnect: onDisconnect,
                    onCloseTabs: onCloseTabs,
                    onCloseDatabase: onCloseDatabase,
                    onOpenUsers: onOpenUsers
                )
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $searchText, placement: .sidebar, prompt: "Filter connections and tables")
        .sheet(item: $workspace.folderEditor) { editor in
            FolderNameSheet(editor: editor, environment: workspace.environment) { workspace.folderEditor = nil }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Menu {
                        Button {
                            workspace.presentNewConnection()
                        } label: {
                            Label("New Connection…", systemImage: Icon.connection)
                        }
                        .keyboardShortcut("n", modifiers: [.command, .option])
                        Button {
                            workspace.folderEditor = FolderEditor(kind: .create(parent: []))
                        } label: {
                            Label("New Folder…", systemImage: Icon.group)
                        }
                    } label: {
                        Label("New", systemImage: Icon.add)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Add a connection or a folder")
                    Spacer()
                    Text(connectionSummary)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                .padding(.horizontal, DesignTokens.Spacing.md)
                .frame(height: DesignTokens.Metrics.barHeight)
                .background(.bar)
            }
        }
    }

    private var connectionSummary: String {
        let total = workspace.environment.connections.count
        let live = workspace.environment.connections.count { sidebar.state(of: $0.id).isUsable }
        guard total > 0 else { return "" }
        return live > 0 ? "\(live) of \(total) connected" : "\(total) connection\(total == 1 ? "" : "s")"
    }

    var filteredRoots: [SidebarItem] {
        guard !searchText.isEmpty else { return sidebar.roots }
        let needle = searchText.lowercased()
        func filter(_ items: [SidebarItem]) -> [SidebarItem] {
            items.compactMap { item in
                let children = filter(item.children ?? [])
                if item.title.lowercased().contains(needle) || !children.isEmpty {
                    var copy = item
                    if item.children != nil { copy.children = children.isEmpty ? item.children : children }
                    return copy
                }
                return nil
            }
        }
        return filter(sidebar.roots)
    }
}

extension WorkspaceModel {
    /// Opens the connection sheet on a fresh PostgreSQL configuration.
    public func presentNewConnection() {
        editingConnection = ConnectionConfig(
            name: "New Connection", dialect: .postgresql,
            host: "localhost", port: 5_432, user: NSUserName()
        )
        isEditingNewConnection = true
    }
}

/// One row of the tree, expanded on demand.
struct SidebarRow: View {
    let item: SidebarItem
    @Bindable var sidebar: SidebarModel
    @Bindable var workspace: WorkspaceModel
    let onOpenTable: (TableRef, UUID, Bool) -> Void
    let onNewQuery: (UUID, String) -> Void
    let onOpenSource: (SourceObject, UUID) -> Void
    let onOpenActivity: (UUID) -> Void
    let onOpenBuilder: (SchemaRef, UUID) -> Void
    let onDisconnect: (UUID) -> Void
    let onCloseTabs: (UUID) -> Void
    let onCloseDatabase: (UUID, String, SidebarItem.ID) -> Void
    let onOpenUsers: (UUID, String?) -> Void

    var body: some View {
        // The context menu sits on the row's own label, not on the disclosure group: a menu
        // on the group would cover every child row and answer for them.
        Group {
            if item.isExpandable {
                DisclosureGroup(isExpanded: expansionBinding) {
                    ForEach(item.children ?? []) { child in
                        SidebarRow(
                            item: child, sidebar: sidebar, workspace: workspace,
                            onOpenTable: onOpenTable, onNewQuery: onNewQuery,
                            onOpenSource: onOpenSource, onOpenActivity: onOpenActivity,
                            onOpenBuilder: onOpenBuilder, onDisconnect: onDisconnect,
                            onCloseTabs: onCloseTabs, onCloseDatabase: onCloseDatabase,
                            onOpenUsers: onOpenUsers
                        )
                    }
                } label: {
                    label.contextMenu { contextMenu }
                }
            } else {
                label.contextMenu { contextMenu }
            }
        }
        .tag(item.id)
    }

    var expansionBinding: Binding<Bool> {
        Binding(
            get: { sidebar.isExpanded(item.id) },
            set: { expanded in
                // The state change is synchronous so the triangle stays open; the query
                // that fills the children runs after.
                guard expanded else {
                    sidebar.collapse(item.id)
                    return
                }
                sidebar.markExpanded(item.id)
                if case let .connection(id) = item.kind { sidebar.watchState(of: id) }
                Task { await sidebar.loadChildrenIfNeeded(item) }
            }
        )
    }

    private var config: ConnectionConfig? {
        guard case let .connection(id) = item.kind else { return nil }
        return workspace.environment.connections.first { $0.id == id }
    }

    @ViewBuilder
    var label: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            if case let .connection(id) = item.kind {
                connectionLabel(id: id)
            } else {
                Image(systemName: item.symbolName)
                    .foregroundStyle(iconColor)
                    .frame(width: DesignTokens.Metrics.iconWidth)
                    .symbolVariant(isGroup ? .fill : .none)
                Text(item.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle = item.subtitle {
                    if case .tableFolder = item.kind {
                        Spacer(minLength: DesignTokens.Spacing.xs)
                        Badge(text: subtitle)
                    } else {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .monospacedDigit()
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 22)
        .contentShape(Rectangle())
        // A simultaneous gesture, because the list row and the disclosure control both
        // want the click and a plain `onTapGesture` loses to them.
        .simultaneousGesture(TapGesture(count: 2).onEnded { handleDoubleClick() })
        .simultaneousGesture(TapGesture(count: 1).onEnded { workspace.sidebarSelection = item.id })
        .help(helpText)
        // Connections drag; folders (and the space between folders, via the connection
        // rows themselves) accept them, which is how a connection changes folder.
        .modifier(ConnectionDragModifier(item: item, workspace: workspace))
    }

    /// A connection row: the connection's own colour as a thin stripe, the engine badge,
    /// the name, and its state at the trailing edge.
    ///
    /// State is carried by more than a dot: a disconnected row is dimmed as a whole, so
    /// the identity colour (which may well be green) is never mistaken for "connected".
    @ViewBuilder
    private func connectionLabel(id: UUID) -> some View {
        if let config {
            let state = sidebar.state(of: id)
            let isLive = state.isUsable
            RoundedRectangle(cornerRadius: 1.5)
                .fill(config.color?.swiftUIColor ?? .clear)
                .frame(width: 3, height: 14)
                .help(config.color.map { "Connection colour: \($0.displayName)" } ?? "")
            EngineMark(dialect: config.dialect, size: DesignTokens.Metrics.iconWidth)
                .saturation(isLive ? 1 : 0)
                .opacity(isLive ? 1 : 0.55)
            Text(config.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isLive ? .primary : .secondary)
            if config.isProduction {
                Badge(text: "PROD", color: Color(nsColor: DesignTokens.Colors.productionBadge), isProminent: true)
            }
            if config.readOnly {
                Image(systemName: Icon.readOnly)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help("Read-only")
            }
            Spacer(minLength: DesignTokens.Spacing.xs)
            ConnectionStateDot(state: state)
        } else {
            Image(systemName: Icon.connection).frame(width: DesignTokens.Metrics.iconWidth)
            Text(item.title)
        }
    }

    private var isGroup: Bool { if case .group = item.kind { true } else { false } }

    private var iconColor: Color {
        switch item.kind {
        case .group: .accentColor
        case .failure: .red
        case .table(_, let info) where info.kind == .view || info.kind == .materializedView: .purple
        case .table: .accentColor
        case .routine: .orange
        // An open database is green, a closed one grey, so the tree says which databases
        // are in use and Close Database has an obvious target.
        case .database: sidebar.isExpanded(item.id) ? .green : .secondary
        case .schema: .teal
        default: .secondary
        }
    }

    private var helpText: String {
        switch item.kind {
        case .connection: config.map { "\($0.user)@\($0.host):\($0.port)" } ?? ""
        case let .table(_, info): info.comment ?? "\(info.kind.displayName) \(info.ref.schema).\(info.ref.name)"
        case let .routine(_, _, name, signature): "\(name)(\(signature))"
        case let .failure(_, message): message
        default: ""
        }
    }

    /// Opens whatever the row points at: a table becomes a tab, anything else toggles.
    func activate() {
        switch item.kind {
        case let .table(id, info):
            onOpenTable(info.ref, id, false)
        default:
            toggleExpansion()
        }
    }

    func toggleExpansion() {
        if sidebar.isExpanded(item.id) {
            sidebar.collapse(item.id)
        } else {
            sidebar.markExpanded(item.id)
            if case let .connection(id) = item.kind { sidebar.watchState(of: id) }
            Task { await sidebar.loadChildrenIfNeeded(item) }
        }
    }

    func handleDoubleClick() {
        workspace.sidebarSelection = item.id
        switch item.kind {
        case let .table(id, info):
            onOpenTable(info.ref, id, NSEvent.modifierFlags.contains(.option))
        case let .schema(id, ref):
            // A schema opens as a list of what it holds, rather than only expanding
            // one node at a time.
            _ = workspace.openObjects(ref, connectionID: id)
        case let .database(id, name):
            if let ref = mysqlSchema(connectionID: id, database: name) {
                _ = workspace.openObjects(ref, connectionID: id)
            } else {
                toggleExpansion()
            }
        case let .routine(id, schema, name, signature):
            onOpenSource(SourceObject(kind: .routine(
                schema: schema, name: name, signature: signature, kind: .function
            )), id)
        default:
            toggleExpansion()
        }
    }

    @ViewBuilder
    var contextMenu: some View {
        switch item.kind {
        case let .connection(id):
            connectionMenu(id)
        case let .table(id, info):
            tableMenu(connectionID: id, info: info)
        case let .schema(id, ref):
            Button { _ = workspace.openObjects(ref, connectionID: id) } label: {
                Label("Open Objects", systemImage: Icon.objects)
            }
            Button { onNewQuery(id, "") } label: {
                Label("New Query", systemImage: Icon.newQuery)
            }
            Button { onOpenBuilder(ref, id) } label: {
                Label("Query Builder", systemImage: Icon.builder)
            }
            Divider()
            newObjectItems(connectionID: id, schema: ref)
            Divider()
            Button(sidebar.isExpanded(item.id) ? "Collapse" : "Expand") { toggleExpansion() }
        case let .routine(id, schema, name, signature):
            Button {
                onOpenSource(SourceObject(kind: .routine(
                    schema: schema, name: name, signature: signature, kind: .function
                )), id)
            } label: {
                Label("Open Definition", systemImage: Icon.source)
            }
            Button { copy(name) } label: { Label("Copy Name", systemImage: Icon.copy) }
        case let .tableFolder(id, ref, kind):
            // The folder says what it holds, so what it holds comes first; the rest follow
            // once, below a rule.
            let isViews = kind == .view || kind == .materializedView
            newObjectItems(connectionID: id, schema: ref, first: isViews ? .view : .table)
            Divider()
            collapseItem
        case let .routineFolder(id, ref):
            newObjectItems(connectionID: id, schema: ref, first: .function)
            Divider()
            collapseItem
        case let .database(id, name):
            Button { onNewQuery(id, "") } label: {
                Label("New Query", systemImage: Icon.newQuery)
            }
            if let ref = mysqlSchema(connectionID: id, database: name) {
                // On MySQL the database is the schema, so its actions live here.
                Button { _ = workspace.openObjects(ref, connectionID: id) } label: {
                    Label("Open Objects", systemImage: Icon.objects)
                }
                Button { onOpenBuilder(ref, id) } label: {
                    Label("Query Builder", systemImage: Icon.builder)
                }
                Divider()
                newObjectItems(connectionID: id, schema: ref)
            }
            Button { onOpenUsers(id, name) } label: {
                Label("Users & Privileges…", systemImage: Icon.user)
            }
            Divider()
            if !sidebar.isExpanded(item.id) {
                Button("Open Database") { toggleExpansion() }
            }
            // Closes this database like Navicat does: its tabs go (after asking) and
            // everything opened beneath it folds; the connection itself stays up.
            Button { onCloseDatabase(id, name, item.id) } label: {
                Label("Close Database", systemImage: Icon.collapse)
            }
        case let .group(path):
            Button {
                workspace.folderEditor = FolderEditor(kind: .create(parent: path))
            } label: {
                Label("New Folder Inside…", systemImage: Icon.group)
            }
            Button {
                workspace.editingConnection = ConnectionConfig(
                    name: "New Connection", groupPath: path, dialect: .postgresql,
                    host: "localhost", port: 5_432, user: NSUserName()
                )
                workspace.isEditingNewConnection = true
            } label: {
                Label("New Connection Here…", systemImage: Icon.connection)
            }
            Divider()
            Button {
                workspace.folderEditor = FolderEditor(kind: .rename(path: path))
            } label: {
                Label("Rename Folder…", systemImage: Icon.rename)
            }
            Button(role: .destructive) {
                let count = workspace.environment.connections.count { $0.groupPath.starts(with: path) }
                workspace.confirmation = DestructiveConfirmation(
                    title: "Remove folder “\(path.last ?? "")”?",
                    message: count == 0
                        ? "The folder is empty."
                        : "Its \(count) connection\(count == 1 ? "" : "s") are kept and move up one level. Nothing on any server changes.",
                    confirmTitle: "Remove Folder",
                    action: { await workspace.environment.removeGroup(path) }
                )
            } label: {
                Label("Remove Folder…", systemImage: Icon.delete)
            }
            Divider()
            collapseItem
        default:
            EmptyView()
        }
    }

    /// The pseudo-schema a MySQL database is, or nil on PostgreSQL where schemas are rows.
    private func mysqlSchema(connectionID: UUID, database: String) -> SchemaRef? {
        guard workspace.environment.connections.first(where: { $0.id == connectionID })?.dialect == .mysql else {
            return nil
        }
        return SchemaRef.mysql(database)
    }

    /// Collapse closes the whole branch, not just the one triangle.
    @ViewBuilder
    private var collapseItem: some View {
        if sidebar.isExpanded(item.id) {
            Button { sidebar.collapseSubtree(item.id) } label: {
                Label("Collapse", systemImage: Icon.collapse)
            }
        } else {
            Button("Expand") { toggleExpansion() }
        }
    }

    enum NewObject { case table, view, function, procedure }

    /// New Table, New View, New Function, New Procedure: the same four everywhere a
    /// schema or one of its folders is right-clicked, each exactly once. `first` is the
    /// one the folder is about; it leads and the others follow below a rule.
    @ViewBuilder
    func newObjectItems(connectionID id: UUID, schema ref: SchemaRef, first: NewObject? = nil) -> some View {
        let order: [NewObject] = [.table, .view, .function, .procedure]
        let ordered = first.map { lead in [lead] + order.filter { $0 != lead } } ?? order
        ForEach(Array(ordered.enumerated()), id: \.offset) { index, kind in
            if index == 1, first != nil { Divider() }
            switch kind {
            case .table:
                Button { presentNewTable(connectionID: id, schema: ref) } label: {
                    Label("New Table…", systemImage: Icon.table)
                }
            case .view:
                Button { onOpenBuilder(ref, id) } label: {
                    Label("New View…", systemImage: Icon.view)
                }
            case .function:
                Button { newRoutine(connectionID: id, schema: ref, procedure: false) } label: {
                    Label("New Function…", systemImage: Icon.function)
                }
            case .procedure:
                Button { newRoutine(connectionID: id, schema: ref, procedure: true) } label: {
                    Label("New Procedure…", systemImage: Icon.procedure)
                }
            }
        }
    }

    func presentNewTable(connectionID: UUID, schema: SchemaRef) {
        workspace.newTableContext = (connectionID, schema)
        workspace.isNewTablePresented = true
    }

    /// Opens a query tab holding a `CREATE FUNCTION` / `CREATE PROCEDURE` skeleton in the
    /// engine's own syntax, ready to edit and run.
    func newRoutine(connectionID: UUID, schema: SchemaRef, procedure: Bool) {
        let dialect = workspace.environment.connections.first { $0.id == connectionID }?.dialect ?? .postgresql
        onNewQuery(connectionID, RoutineTemplates.skeleton(procedure: procedure, schema: schema, dialect: dialect))
    }

    @ViewBuilder
    func connectionMenu(_ id: UUID) -> some View {
        if let config = workspace.environment.connections.first(where: { $0.id == id }) {
            Button { onNewQuery(id, "") } label: { Label("New Query", systemImage: Icon.newQuery) }
                .keyboardShortcut("t", modifiers: .command)
            Button {
                onOpenBuilder(SchemaRef(database: "", schema: ""), id)
            } label: {
                Label("Query Builder", systemImage: Icon.builder)
            }
            Button { onOpenActivity(id) } label: { Label("Server Activity", systemImage: Icon.activity) }
            Button { onOpenUsers(id, config.database) } label: { Label("Users & Privileges…", systemImage: Icon.user) }
            Divider()
            Button { workspace.editingConnection = config } label: { Label("Edit…", systemImage: Icon.edit) }
            Button { Task { await workspace.environment.duplicate(config) } } label: {
                Label("Duplicate", systemImage: Icon.duplicate)
            }
            Menu {
                Button("No Folder") { Task { await workspace.environment.move(config, toGroup: []) } }
                    .disabled(config.groupPath.isEmpty)
                let folders = workspace.environment.allGroupPaths
                if !folders.isEmpty { Divider() }
                ForEach(folders, id: \.self) { path in
                    Button(path.joined(separator: " › ")) {
                        Task { await workspace.environment.move(config, toGroup: path) }
                    }
                    .disabled(path == config.groupPath)
                }
                Divider()
                Button("New Folder…") {
                    workspace.folderEditor = FolderEditor(kind: .create(parent: [], moving: config.id))
                }
            } label: {
                Label("Move to Folder", systemImage: Icon.group)
            }
            Divider()
            Button { Task { await sidebar.refresh(connectionID: id) } } label: {
                Label("Refresh", systemImage: Icon.refresh)
            }
            Button {
                onDisconnect(id)
            } label: {
                Label("Disconnect", systemImage: Icon.disconnect)
            }
            .disabled(!sidebar.state(of: id).isUsable && workspace.tabs(for: id).isEmpty)
            Divider()
            Button(role: .destructive) {
                let open = workspace.tabs(for: id).count
                workspace.confirmation = DestructiveConfirmation(
                    title: "Delete “\(config.name)”?",
                    message: "The connection, its saved password and everything remembered about it are removed."
                        + (open > 0 ? " Its \(open) open tab\(open == 1 ? "" : "s") will be closed." : "")
                        + " The database itself is untouched.",
                    action: {
                        onCloseTabs(id)
                        await workspace.environment.delete(config)
                    }
                )
            } label: {
                Label("Delete…", systemImage: Icon.delete)
            }
        }
    }

    @ViewBuilder
    func tableMenu(connectionID: UUID, info: TableInfo) -> some View {
        let isProduction = workspace.environment.connections
            .first { $0.id == connectionID }?.isProduction ?? false
        let dialect = workspace.environment.connections
            .first { $0.id == connectionID }?.dialect ?? .postgresql
        Button { onOpenTable(info.ref, connectionID, false) } label: {
            Label("Open", systemImage: Icon.table)
        }
        Button { onOpenTable(info.ref, connectionID, true) } label: {
            Label("Open in New Tab", systemImage: Icon.openInNewTab)
        }
        if info.kind == .view || info.kind == .materializedView {
            Button { onOpenSource(SourceObject(kind: .view(info.ref)), connectionID) } label: {
                Label("Open Definition", systemImage: Icon.source)
            }
        }
        Button {
            onNewQuery(connectionID, "SELECT * FROM \(Identifier.qualified(info.ref, dialect: dialect)) LIMIT 100;")
        } label: {
            Label("Query Rows", systemImage: Icon.newQuery)
        }
        Divider()
        Button { copy(info.ref.name) } label: { Label("Copy Name", systemImage: Icon.copy) }
        Button { copy(Identifier.qualified(info.ref, dialect: dialect)) } label: {
            Label("Copy Qualified Name", systemImage: Icon.copy)
        }
        Button {
            Task { @MainActor in
                guard let session = workspace.environment.session(for: connectionID) else { return }
                let ref = info.ref
                if let ddl = try? await session.introspection(.ddl(ref), load: { try await $0.tableDDL(ref) }) {
                    copy(ddl)
                }
            }
        } label: {
            Label("Copy CREATE Statement", systemImage: Icon.source)
        }
        if info.kind.isEditable {
            Divider()
            Button {
                workspace.pendingTableOperation = TableOperationRequest(
                    kind: .rename, table: info.ref, connectionID: connectionID
                )
            } label: {
                Label("Rename…", systemImage: Icon.rename)
            }
            Button {
                workspace.pendingTableOperation = TableOperationRequest(
                    kind: .duplicate, table: info.ref, connectionID: connectionID
                )
            } label: {
                Label("Duplicate…", systemImage: Icon.duplicate)
            }
            Button {
                workspace.pendingTableOperation = TableOperationRequest(
                    kind: .importCSV, table: info.ref, connectionID: connectionID
                )
            } label: {
                Label("Import from CSV…", systemImage: Icon.importData)
            }
            Menu {
                ForEach(MaintenanceAction.available(for: dialect), id: \.self) { action in
                    Button(action.title) {
                        workspace.pendingTableOperation = TableOperationRequest(
                            kind: .maintenance(action), table: info.ref, connectionID: connectionID
                        )
                    }
                }
            } label: {
                Label("Maintenance", systemImage: Icon.maintenance)
            }
            Divider()
            Button(role: .destructive) {
                workspace.confirmation = DestructiveConfirmation(
                    title: "Truncate “\(info.ref.name)”?",
                    message: "Every row is deleted. This cannot be undone.",
                    requiredTypedName: isProduction ? info.ref.name : nil,
                    confirmTitle: "Truncate",
                    action: { await runDDL("TRUNCATE TABLE", info: info, connectionID: connectionID) }
                )
            } label: {
                Label("Truncate…", systemImage: Icon.delete)
            }
        }
        Button(role: .destructive) {
            let verb = info.kind == .view ? "DROP VIEW"
                : info.kind == .materializedView ? "DROP MATERIALIZED VIEW" : "DROP TABLE"
            workspace.confirmation = DestructiveConfirmation(
                title: "Drop “\(info.ref.name)”?",
                message: "The \(info.kind.displayName.lowercased()) and all of its data are removed. This cannot be undone.",
                requiredTypedName: isProduction ? info.ref.name : nil,
                confirmTitle: "Drop",
                action: { await runDDL(verb, info: info, connectionID: connectionID) }
            )
        } label: {
            Label("Drop…", systemImage: Icon.delete)
        }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @MainActor
    func runDDL(_ verb: String, info: TableInfo, connectionID: UUID) async {
        guard let session = workspace.environment.session(for: connectionID) else { return }
        do {
            let (lease, connection) = try await session.lease()
            defer { Task { await session.release(lease) } }
            let dialect = session.config.dialect
            let name = Identifier.qualified(info.ref, dialect: dialect)
            _ = try await connection.executeCollecting("\(verb) \(name)")
            await session.invalidateIntrospection()
            await sidebar.refresh(connectionID: connectionID)
        } catch {
            workspace.confirmation = DestructiveConfirmation(
                title: "\(verb) failed",
                message: (error as? DBError)?.errorDescription ?? String(describing: error),
                confirmTitle: "OK",
                action: {}
            )
        }
    }
}

/// The state of a connection as a dot: filled and coloured while it is doing something,
/// hollow when it is disconnected, so "off" never looks like a colour.
struct ConnectionStateDot: View {
    let state: ConnectionState

    var body: some View {
        Group {
            switch state {
            case .disconnected:
                Circle().strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1.5)
            case .connecting:
                Circle().fill(Color.yellow)
            case .connected:
                Circle().fill(Color.green)
            case .degraded:
                Circle().fill(Color.red)
            }
        }
        .frame(width: 8, height: 8)
        .help(state.describedForStatusBar)
        .accessibilityLabel(state.describedForStatusBar)
    }
}


/// The starting text of a new routine, in each engine's own words.
enum RoutineTemplates {
    static func skeleton(procedure: Bool, schema: SchemaRef, dialect: SQLDialect) -> String {
        let name = Identifier.qualify([schema.schema, procedure ? "new_procedure" : "new_function"], dialect: dialect)
        switch (dialect, procedure) {
        case (.postgresql, false):
            return """
            CREATE OR REPLACE FUNCTION \(name)(a integer, b integer)
            RETURNS integer
            LANGUAGE sql
            AS $$
                SELECT a + b;
            $$;
            """
        case (.postgresql, true):
            return """
            CREATE OR REPLACE PROCEDURE \(name)(target_id integer)
            LANGUAGE plpgsql
            AS $$
            BEGIN
                -- statements
            END;
            $$;
            """
        case (.mysql, false):
            return """
            DELIMITER $$
            CREATE FUNCTION \(name)(a INT, b INT)
            RETURNS INT
            DETERMINISTIC
            BEGIN
                RETURN a + b;
            END $$
            DELIMITER ;
            """
        case (.mysql, true):
            return """
            DELIMITER $$
            CREATE PROCEDURE \(name)(IN target_id INT)
            BEGIN
                -- statements
            END $$
            DELIMITER ;
            """
        }
    }
}


/// Connections can be dragged; folders take the drop. Everything else is inert.
struct ConnectionDragModifier: ViewModifier {
    let item: SidebarItem
    let workspace: WorkspaceModel

    func body(content: Content) -> some View {
        switch item.kind {
        case let .connection(id):
            content
                .onDrag { NSItemProvider(object: id.uuidString as NSString) }
        case let .group(path):
            content
                .onDrop(of: [.plainText, .utf8PlainText, .text], delegate: FolderDropDelegate(path: path, workspace: workspace))
        default:
            content
        }
    }
}

/// Moves a dropped connection into the folder it landed on.
struct FolderDropDelegate: DropDelegate {
    let path: [String]
    let workspace: WorkspaceModel

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.plainText, .utf8PlainText, .text])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.plainText, .utf8PlainText, .text]).first else { return false }
        let workspace = workspace
        let path = path
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String, let id = UUID(uuidString: text) else { return }
            Task { @MainActor in
                guard let config = workspace.environment.connections.first(where: { $0.id == id }) else { return }
                await workspace.environment.move(config, toGroup: path)
            }
        }
        return true
    }
}

/// What the folder sheet is doing: making a folder (perhaps to move a connection into),
/// or renaming one.
public struct FolderEditor: Identifiable {
    public enum Kind {
        case create(parent: [String], moving: UUID? = nil)
        case rename(path: [String])
    }

    public let id = UUID()
    public let kind: Kind

    public init(kind: Kind) { self.kind = kind }
}

/// Names a folder. Folders are paths, so a name may not contain the separator.
struct FolderNameSheet: View {
    let editor: FolderEditor
    let environment: AppEnvironment
    let onDismiss: () -> Void

    @State private var name = ""

    private var isRename: Bool { if case .rename = editor.kind { true } else { false } }
    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
    private var isValid: Bool { !trimmed.isEmpty && !trimmed.contains("/") && !trimmed.contains("›") }

    var body: some View {
        SheetFrame(
            title: isRename ? "Rename Folder" : "New Folder",
            icon: Icon.group,
            subtitle: subtitle,
            width: DesignTokens.Metrics.compactSheetWidth
        ) {
            FieldRow(label: "Name", labelWidth: 60) {
                TextField("Office", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if isValid { save() } }
            }
        } footer: {
            Spacer()
            Button("Cancel", action: onDismiss).keyboardShortcut(.cancelAction)
            Button(isRename ? "Rename" : "Create") { save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
        }
        .onAppear {
            if case let .rename(path) = editor.kind { name = path.last ?? "" }
        }
    }

    private var subtitle: String {
        switch editor.kind {
        case let .create(parent, moving):
            var text = parent.isEmpty ? "A folder at the top level of the sidebar." : "Inside \(parent.joined(separator: " › "))."
            if moving != nil { text += " The connection moves into it." }
            return text
        case .rename:
            return "Connections inside keep their place."
        }
    }

    private func save() {
        let environment = environment
        let editor = editor
        let trimmed = trimmed
        Task { @MainActor in
            switch editor.kind {
            case let .create(parent, moving):
                let path = parent + [trimmed]
                await environment.createGroup(path)
                if let moving, let config = environment.connections.first(where: { $0.id == moving }) {
                    await environment.move(config, toGroup: path)
                }
            case let .rename(path):
                await environment.renameGroup(path, to: trimmed)
            }
            onDismiss()
        }
    }
}
