import DBCore
import DBSQL
import SwiftUI

/// The connections and schema tree (SPEC §11.1).
public struct SidebarView: View {
    @Bindable var workspace: WorkspaceModel
    @Bindable var sidebar: SidebarModel
    let onOpenTable: (TableRef, UUID, Bool) -> Void
    let onNewQuery: (UUID, String) -> Void

    @State private var searchText = ""

    public var body: some View {
        List(selection: $workspace.sidebarSelection) {
            ForEach(filteredRoots) { item in
                SidebarRow(
                    item: item,
                    sidebar: sidebar,
                    workspace: workspace,
                    onOpenTable: onOpenTable,
                    onNewQuery: onNewQuery
                )
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $searchText, placement: .sidebar, prompt: "Filter connections")
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 6) {
                Button {
                    workspace.editingConnection = ConnectionConfig(
                        name: "New Connection", dialect: .postgresql,
                        host: "localhost", port: 5_432, user: NSUserName()
                    )
                    workspace.isEditingNewConnection = true
                } label: {
                    Label("New Connection", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add a connection")
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)
        }
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

/// One row of the tree, expanded on demand.
struct SidebarRow: View {
    let item: SidebarItem
    @Bindable var sidebar: SidebarModel
    @Bindable var workspace: WorkspaceModel
    let onOpenTable: (TableRef, UUID, Bool) -> Void
    let onNewQuery: (UUID, String) -> Void

    var body: some View {
        Group {
            if item.isExpandable {
                DisclosureGroup(isExpanded: expansionBinding) {
                    ForEach(item.children ?? []) { child in
                        SidebarRow(
                            item: child, sidebar: sidebar, workspace: workspace,
                            onOpenTable: onOpenTable, onNewQuery: onNewQuery
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

    @ViewBuilder
    var label: some View {
        // Eight points between the icon and its text, and a little air after the
        // disclosure triangle: at six the glyphs crowd the label.
        HStack(spacing: 8) {
            if case let .connection(id) = item.kind {
                let config = workspace.environment.connections.first { $0.id == id }
                Circle()
                    .fill(sidebar.state(of: id).indicatorColor)
                    .frame(width: 8, height: 8)
                // Which engine this is, so a MySQL row is not a PostgreSQL row with a
                // different name.
                if let config {
                    EngineMark(dialect: config.dialect)
                }
                if let color = config?.color {
                    Circle().fill(color.swiftUIColor).frame(width: 6, height: 6)
                }
            } else {
                Image(systemName: item.symbolName)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
            }
            Text(item.title)
                .lineLimit(1)
            if let subtitle = item.subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            if case let .connection(id) = item.kind,
               workspace.environment.connections.first(where: { $0.id == id })?.isProduction == true {
                Text("prod")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color(nsColor: DesignTokens.Colors.productionBadge).opacity(0.85))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 4)
        .contentShape(Rectangle())
        // A simultaneous gesture, because the list row and the disclosure control both
        // want the click and a plain `onTapGesture` loses to them.
        .simultaneousGesture(TapGesture(count: 2).onEnded { handleDoubleClick() })
        .simultaneousGesture(TapGesture(count: 1).onEnded { workspace.sidebarSelection = item.id })
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
            // one node at a time (SPEC §11.4).
            _ = workspace.openObjects(ref, connectionID: id)
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
            Button("Open Objects") { _ = workspace.openObjects(ref, connectionID: id) }
            Button(sidebar.isExpanded(item.id) ? "Collapse" : "Expand") { toggleExpansion() }
        case .database, .tableFolder, .routineFolder, .group:
            Button(sidebar.isExpanded(item.id) ? "Collapse" : "Expand") { toggleExpansion() }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    func connectionMenu(_ id: UUID) -> some View {
        if let config = workspace.environment.connections.first(where: { $0.id == id }) {
            Button("Edit…") { workspace.editingConnection = config }
            Button("Duplicate") { Task { await workspace.environment.duplicate(config) } }
            Button("New Query") { onNewQuery(id, "") }
            Divider()
            Button("Refresh") { Task { await sidebar.refresh(connectionID: id) } }
            Button("Disconnect") {
                Task { await workspace.environment.session(for: id)?.disconnect() }
            }
            Divider()
            Button("Delete…", role: .destructive) {
                workspace.confirmation = DestructiveConfirmation(
                    title: "Delete “\(config.name)”?",
                    message: "The connection, its saved password and everything remembered about it are removed. The database itself is untouched.",
                    action: { await workspace.environment.delete(config) }
                )
            }
        }
    }

    @ViewBuilder
    func tableMenu(connectionID: UUID, info: TableInfo) -> some View {
        let isProduction = workspace.environment.connections
            .first { $0.id == connectionID }?.isProduction ?? false
        Button("Open") { onOpenTable(info.ref, connectionID, false) }
        Button("Open in New Tab") { onOpenTable(info.ref, connectionID, true) }
        Button("New Query") {
            onNewQuery(connectionID, "SELECT * FROM \(info.ref.schema).\(info.ref.name) LIMIT 100")
        }
        Divider()
        Button("Copy Name") { copy(info.ref.name) }
        Button("Copy Qualified Name") { copy("\(info.ref.schema).\(info.ref.name)") }
        Button("Copy DDL") {
            Task { @MainActor in
                guard let session = workspace.environment.session(for: connectionID) else { return }
                let ref = info.ref
                if let ddl = try? await session.introspection(.ddl(ref), load: { try await $0.tableDDL(ref) }) {
                    copy(ddl)
                }
            }
        }
        Divider()
        Button("Truncate…", role: .destructive) {
            workspace.confirmation = DestructiveConfirmation(
                title: "Truncate “\(info.ref.name)”?",
                message: "Every row is deleted. This cannot be undone.",
                requiredTypedName: isProduction ? info.ref.name : nil,
                confirmTitle: "Truncate",
                action: { await runDDL("TRUNCATE TABLE", info: info, connectionID: connectionID) }
            )
        }
        Button("Drop…", role: .destructive) {
            workspace.confirmation = DestructiveConfirmation(
                title: "Drop “\(info.ref.name)”?",
                message: "The table and all of its data are removed. This cannot be undone.",
                requiredTypedName: isProduction ? info.ref.name : nil,
                confirmTitle: "Drop",
                action: { await runDDL("DROP TABLE", info: info, connectionID: connectionID) }
            )
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
            let name = DBSQLIdentifier.qualified(info.ref, dialect: dialect)
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

/// A tiny alias so the view file does not import the whole SQL module namespace.
enum DBSQLIdentifier {
    static func qualified(_ table: TableRef, dialect: SQLDialect) -> String {
        Identifier.qualified(table, dialect: dialect)
    }
}
