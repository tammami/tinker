import DBCore
import DBSQL
import SwiftUI

/// The connections and schema tree.
public struct SidebarView: View {
    @Bindable var workspace: WorkspaceModel
    @Bindable var sidebar: SidebarModel
    let onOpenTable: (TableRef, UUID, Bool) -> Void
    let onNewQuery: (UUID, String) -> Void
    let onOpenSource: (SourceObject, UUID) -> Void
    let onOpenActivity: (UUID) -> Void

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
                    onOpenActivity: onOpenActivity
                )
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $searchText, placement: .sidebar, prompt: "Filter connections and tables")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Button {
                        workspace.presentNewConnection()
                    } label: {
                        Label("New Connection", systemImage: Icon.add)
                    }
                    .buttonStyle(.borderless)
                    .help("Add a connection")
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

    var body: some View {
        Group {
            if item.isExpandable {
                DisclosureGroup(isExpanded: expansionBinding) {
                    ForEach(item.children ?? []) { child in
                        SidebarRow(
                            item: child, sidebar: sidebar, workspace: workspace,
                            onOpenTable: onOpenTable, onNewQuery: onNewQuery,
                            onOpenSource: onOpenSource, onOpenActivity: onOpenActivity
                        )
                    }
                } label: {
                    label
                }
            } else {
                label
            }
        }
        .tag(item.id)
        .contextMenu { contextMenu }
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
    }

    /// A connection row: the engine badge, the name, and the connection's own colour and
    /// state at the trailing edge where they do not push the name around.
    @ViewBuilder
    private func connectionLabel(id: UUID) -> some View {
        if let config {
            // The connection's colour is a stripe at the leading edge, where the tab strip
            // shows it too; the trailing dot is only ever the connection's state.
            RoundedRectangle(cornerRadius: 1.5)
                .fill(config.color?.swiftUIColor ?? .clear)
                .frame(width: 3, height: 14)
            EngineMark(dialect: config.dialect, size: DesignTokens.Metrics.iconWidth)
            Text(config.name)
                .lineLimit(1)
                .truncationMode(.middle)
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
            Circle()
                .fill(sidebar.state(of: id).indicatorColor)
                .frame(width: 7, height: 7)
                .help(sidebar.state(of: id).describedForStatusBar)
        } else {
            Image(systemName: Icon.connection).frame(width: DesignTokens.Metrics.iconWidth)
            Text(item.title)
        }
    }

    private var iconColor: Color {
        switch item.kind {
        case .failure: .red
        case .table(_, let info) where info.kind == .view || info.kind == .materializedView: .purple
        case .table: .accentColor
        case .routine: .orange
        case .database: .secondary
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
            Button {
                workspace.isNewTablePresented = true
            } label: {
                Label("New Table…", systemImage: Icon.add)
            }
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
        case .database, .tableFolder, .routineFolder, .group:
            Button(sidebar.isExpanded(item.id) ? "Collapse" : "Expand") { toggleExpansion() }
            if case let .database(id, _) = item.kind {
                Button { onNewQuery(id, "") } label: {
                    Label("New Query", systemImage: Icon.newQuery)
                }
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    func connectionMenu(_ id: UUID) -> some View {
        if let config = workspace.environment.connections.first(where: { $0.id == id }) {
            Button { onNewQuery(id, "") } label: { Label("New Query", systemImage: Icon.newQuery) }
                .keyboardShortcut("t", modifiers: .command)
            Button { onOpenActivity(id) } label: { Label("Server Activity", systemImage: Icon.activity) }
            Divider()
            Button { workspace.editingConnection = config } label: { Label("Edit…", systemImage: Icon.edit) }
            Button { Task { await workspace.environment.duplicate(config) } } label: {
                Label("Duplicate", systemImage: Icon.duplicate)
            }
            Divider()
            Button { Task { await sidebar.refresh(connectionID: id) } } label: {
                Label("Refresh", systemImage: Icon.refresh)
            }
            Button {
                Task { await workspace.environment.session(for: id)?.disconnect() }
            } label: {
                Label("Disconnect", systemImage: Icon.disconnect)
            }
            Divider()
            Button(role: .destructive) {
                workspace.confirmation = DestructiveConfirmation(
                    title: "Delete “\(config.name)”?",
                    message: "The connection, its saved password and everything remembered about it are removed. The database itself is untouched.",
                    action: { await workspace.environment.delete(config) }
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
