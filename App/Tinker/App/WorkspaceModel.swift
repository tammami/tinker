import DBCore
import DBGrid
import DBSQL
import DBStore
import Foundation
import Observation
import SwiftUI

/// One tab in a workspace window: either a table's data grid or a SQL editor.
@MainActor
@Observable
public final class WorkspaceTab: Identifiable {
    public enum Kind: Sendable {
        case table(TableRef)
        case query
        /// Everything a schema holds, listed.
        case objects(SchemaRef)
        /// The server's sessions, users and variables.
        case serverActivity
        /// The definition of a view or routine, read from the catalog.
        case source(SourceObject)
        /// The visual query builder, on one schema.
        case queryBuilder(SchemaRef)
    }

    public let id = UUID()
    public let kind: Kind
    public let connectionID: UUID
    public var title: String
    /// The grid shown by a table tab, or by a query tab's selected result.
    public var grid: GridModel?
    /// The editor's text, for a query tab.
    public var sql: String = ""
    /// One result per statement the editor ran (SPEC §13.2).
    public var results: [QueryResultTab] = []
    public var selectedResultID: UUID?
    public var isRunning = false
    public var runningElapsed: Duration = .zero
    /// Off means the tab holds its transaction open until the user commits.
    public var autoCommit = true
    public var errorBanner: QueryErrorBanner?
    public var statusMessage: String = ""

    public init(kind: Kind, connectionID: UUID, title: String) {
        self.kind = kind
        self.connectionID = connectionID
        self.title = title
    }

    public var isQueryTab: Bool { if case .query = kind { true } else { false } }

    public var tableRef: TableRef? {
        if case let .table(table) = kind { table } else { nil }
    }

    public var selectedResult: QueryResultTab? {
        results.first { $0.id == selectedResultID } ?? results.first
    }

    /// The symbol the tab strip and the command palette draw for this tab.
    public var icon: String {
        switch kind {
        case .table: Icon.table
        case .query: Icon.query
        case .objects: Icon.objects
        case .serverActivity: Icon.activity
        case .source: Icon.source
        case .queryBuilder: Icon.builder
        }
    }
}

/// A catalog object whose definition can be opened as text: a view or a routine.
public struct SourceObject: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case view(TableRef)
        case routine(schema: SchemaRef, name: String, signature: String, kind: RoutineKind)
    }

    public let kind: Kind

    public init(kind: Kind) { self.kind = kind }

    public var name: String {
        switch kind {
        case let .view(ref): ref.name
        case let .routine(_, name, _, _): name
        }
    }

    public var schema: SchemaRef {
        switch kind {
        case let .view(ref): ref.schemaRef
        case let .routine(schema, _, _, _): schema
        }
    }
}

/// One statement's result inside a query tab.
@MainActor
@Observable
public final class QueryResultTab: Identifiable {
    public let id = UUID()
    public let label: String
    public let statement: String
    public var grid: GridModel?
    /// For statements that return no rows, the message the status line shows.
    public var message: String?
    public var error: QueryErrorBanner?
    public var completion: QueryCompletion?
    /// The row count of a paged result, once Last page asked for it.
    public var exactTotal: Int64?

    /// The panes beside the rows (SPEC §13.2a), read when opened rather than after every
    /// statement: both cost a round trip and a pane nobody looks at should cost nothing.
    public var profile: [[String]]?
    public var profileColumns: [String] = []
    public var profileNote: String?
    public var status: [[String]]?
    public var statusColumns: [String] = []
    public var statusNote: String?

    public init(label: String, statement: String) {
        self.label = label
        self.statement = statement
    }
}

/// A server error shown above the results, with everything needed to act on it.
public struct QueryErrorBanner: Sendable, Hashable, Identifiable {
    public let id = UUID()
    public let message: String
    public let detail: String?
    public let hint: String?
    public let sqlState: String?
    /// One-based character offset into the statement, when the server reported one.
    public let position: Int?
    public let statement: String

    public init(error: any Error, statement: String) {
        self.statement = statement
        if let dbError = error as? DBError, case let .server(serverError) = dbError {
            message = serverError.message
            detail = serverError.detail
            hint = serverError.hint
            sqlState = serverError.sqlState
            position = serverError.position
        } else if let dbError = error as? DBError {
            message = dbError.errorDescription ?? String(describing: error)
            detail = nil
            hint = nil
            sqlState = nil
            position = nil
        } else {
            message = String(describing: error)
            detail = nil
            hint = nil
            sqlState = nil
            position = nil
        }
    }

    /// The full text a user would paste into a bug report.
    public var copyText: String {
        var lines: [String] = []
        if let sqlState { lines.append("[\(sqlState)] \(message)") } else { lines.append(message) }
        if let detail { lines.append("DETAIL: \(detail)") }
        if let hint { lines.append("HINT: \(hint)") }
        if let position { lines.append("POSITION: \(position)") }
        lines.append("")
        lines.append(statement)
        return lines.joined(separator: "\n")
    }
}

/// One window's worth of state: which connections are expanded, which tabs are open.
@MainActor
@Observable
public final class WorkspaceModel {
    public var tabs: [WorkspaceTab] = []
    public var selectedTabID: UUID?
    public var sidebarSelection: SidebarItem.ID?
    /// The sidebar's filter text, matched fuzzily against every row's name.
    public var sidebarFilter = ""
    /// A row shown as the drop target it would be mid-drag, for screenshots of the
    /// highlight (`--ui-demo dragdrop`); nil in ordinary use.
    public var demoDropTargetID: SidebarItem.ID?
    /// The connection being dragged in the sidebar, while the drag lasts. A drop target
    /// reads it to decide, before the pasteboard is loaded, whether it can take the drop.
    @ObservationIgnored public var draggedConnectionID: UUID?
    public var isSidebarVisible = true
    public var isInspectorVisible = false
    public var quickOpenQuery = ""
    public var isQuickOpenPresented = false
    /// The table designer's two entry points.
    public var isNewTablePresented = false
    /// Where a new table goes when the request came from the sidebar rather than a tab.
    public var newTableContext: (connectionID: UUID, schema: SchemaRef)?
    public var isStructureSyncPresented = false
    public var isHistoryPresented = false
    public var isExportPresented = false
    public var isSettingsPresented = false
    /// On by default: a table tab is for finding rows, and a filter behind a shortcut is
    /// a filter most people never find.
    public var isFilterBarVisible = true
    /// The connection whose editor sheet is open, or nil.
    public var editingConnection: ConnectionConfig?
    public var isEditingNewConnection = false
    public var commitPreview: CommitPreview?
    public var confirmation: DestructiveConfirmation?
    /// A rename, duplicate, import or maintenance request awaiting its sheet.
    public var pendingTableOperation: TableOperationRequest?
    /// Dump, SQL-file import and paste requests awaiting their sheets.
    public var pendingDump: DumpRequest?
    public var pendingScriptImport: ScriptImportRequest?
    public var pendingPaste: PasteRequest?
    /// A Tools-menu wizard awaiting its sheet.
    public var pendingTool: ToolRequest?
    /// What Copy picked up in the tree, until the next Copy.
    public var objectClipboard: CopiedObjects?
    /// The command palette (⌘K).
    public var isCommandPalettePresented = false
    /// The folder sheet, when a folder is being made or renamed.
    public var folderEditor: FolderEditor?
    /// The snippet library (⌘⇧K).
    public var isSnippetsPresented = false

    public let environment: AppEnvironment
    /// Installed by the workspace controller, which owns the tab controllers a followed
    /// reference has to reach.
    @ObservationIgnored public var onFollowReference: ((TableRef, UUID, [FilterRule]) -> Void)?

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    /// Opens the table a foreign key points at, filtered to the referenced row.
    public func followReference(to table: TableRef, connectionID: UUID, filter: [FilterRule]) {
        onFollowReference?(table, connectionID, filter)
    }

    public var selectedTab: WorkspaceTab? {
        tabs.first { $0.id == selectedTabID }
    }

    /// The connection the current tab belongs to, which is what the toolbar acts on.
    ///
    /// Falls back to the sidebar's selection, then to the first configured connection, so
    /// that ⌘T works immediately after launch rather than doing nothing.
    public var activeConnectionID: UUID? {
        selectedTab?.connectionID
            ?? sidebarSelection.flatMap(SidebarItem.connectionID(from:))
            ?? environment.connections.first?.id
    }

    public var activeConnection: ConnectionConfig? {
        activeConnectionID.flatMap { id in environment.connections.first { $0.id == id } }
    }

    /// The connection the window says it is on: the front tab's, or the one chosen in the
    /// sidebar. Nothing before either happens — unlike `activeConnection`, which falls back
    /// to the first configured one so that commands have somewhere to go.
    public var displayedConnection: ConnectionConfig? {
        let id = selectedTab?.connectionID ?? sidebarSelection.flatMap(SidebarItem.connectionID(from:))
        return id.flatMap { id in environment.connections.first { $0.id == id } }
    }

    // MARK: - Tabs

    public func open(_ tab: WorkspaceTab) {
        tabs.append(tab)
        selectedTabID = tab.id
    }

    /// Opens a table, focusing the tab that already shows it unless `forceNew`.
    public func openTable(_ table: TableRef, connectionID: UUID, forceNew: Bool = false) -> WorkspaceTab {
        if !forceNew,
            let existing = tabs.first(where: {
                $0.connectionID == connectionID && $0.tableRef == table
            })
        {
            selectedTabID = existing.id
            return existing
        }
        let tab = WorkspaceTab(kind: .table(table), connectionID: connectionID, title: table.name)
        open(tab)
        return tab
    }

    @discardableResult
    /// Opens, or brings forward, the Objects list for a schema (SPEC §11.4).
    public func openObjects(_ schema: SchemaRef, connectionID: UUID) -> WorkspaceTab {
        if let existing = tabs.first(where: {
            if case let .objects(ref) = $0.kind { return ref == schema && $0.connectionID == connectionID }
            return false
        }) {
            selectedTabID = existing.id
            return existing
        }
        let tab = WorkspaceTab(
            kind: .objects(schema), connectionID: connectionID, title: schema.schema
        )
        tabs.append(tab)
        selectedTabID = tab.id
        return tab
    }

    public func newQueryTab(connectionID: UUID, sql: String = "") -> WorkspaceTab {
        let number = tabs.filter(\.isQueryTab).count + 1
        let tab = WorkspaceTab(kind: .query, connectionID: connectionID, title: "SQL \(number)")
        tab.sql = sql
        open(tab)
        return tab
    }

    /// The tabs that belong to a connection, in strip order.
    public func tabs(for connectionID: UUID) -> [WorkspaceTab] {
        tabs.filter { $0.connectionID == connectionID }
    }

    /// The tabs that work inside one database of a connection. A query tab counts when its
    /// session is on that database; `queryDatabase` answers that from the tab's controller.
    public func tabs(
        for connectionID: UUID, database: String, queryDatabase: (WorkspaceTab) -> String?
    ) -> [WorkspaceTab] {
        tabs.filter { tab in
            guard tab.connectionID == connectionID else { return false }
            switch tab.kind {
            case let .table(ref): return ref.database == database
            case let .objects(schema), let .queryBuilder(schema): return schema.database == database
            case let .source(object): return object.schema.database == database
            case .query: return queryDatabase(tab) == database
            case .serverActivity: return false
            }
        }
    }

    public func closeTabs(_ ids: Set<UUID>) {
        let selectedIndex = tabs.firstIndex { $0.id == selectedTabID } ?? 0
        tabs.removeAll { ids.contains($0.id) }
        if !tabs.contains(where: { $0.id == selectedTabID }) {
            selectedTabID = tabs.isEmpty ? nil : tabs[min(selectedIndex, tabs.count - 1)].id
        }
    }

    /// Closes every tab of a connection, keeping the selection on a neighbour if any tab remains.
    public func closeTabs(for connectionID: UUID) {
        let selectedIndex = tabs.firstIndex { $0.id == selectedTabID } ?? 0
        tabs.removeAll { $0.connectionID == connectionID }
        if !tabs.contains(where: { $0.id == selectedTabID }) {
            selectedTabID = tabs.isEmpty ? nil : tabs[min(selectedIndex, tabs.count - 1)].id
        }
    }

    /// Closes every tab but one.
    public func closeOtherTabs(_ id: UUID) {
        tabs.removeAll { $0.id != id }
        selectedTabID = id
    }

    /// Opens, or brings forward, the server activity tab for a connection.
    @discardableResult
    public func openServerActivity(connectionID: UUID) -> WorkspaceTab {
        if let existing = tabs.first(where: {
            if case .serverActivity = $0.kind { return $0.connectionID == connectionID }
            return false
        }) {
            selectedTabID = existing.id
            return existing
        }
        let tab = WorkspaceTab(kind: .serverActivity, connectionID: connectionID, title: "Server")
        open(tab)
        return tab
    }

    /// Opens a new query builder tab on a schema.
    @discardableResult
    public func openQueryBuilder(_ schema: SchemaRef, connectionID: UUID) -> WorkspaceTab {
        let number = tabs.filter { if case .queryBuilder = $0.kind { true } else { false } }.count + 1
        let tab = WorkspaceTab(kind: .queryBuilder(schema), connectionID: connectionID, title: "Builder \(number)")
        open(tab)
        return tab
    }

    /// Opens, or brings forward, the definition of a view or routine.
    @discardableResult
    public func openSource(_ object: SourceObject, connectionID: UUID) -> WorkspaceTab {
        if let existing = tabs.first(where: {
            if case let .source(other) = $0.kind { return other == object && $0.connectionID == connectionID }
            return false
        }) {
            selectedTabID = existing.id
            return existing
        }
        let tab = WorkspaceTab(kind: .source(object), connectionID: connectionID, title: object.name)
        open(tab)
        return tab
    }

    public func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if selectedTabID == id {
            selectedTabID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
        }
    }

    public func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectedTabID = tabs[index].id
    }

    public func cycleTab(forward: Bool) {
        guard !tabs.isEmpty, let current = selectedTabID,
            let index = tabs.firstIndex(where: { $0.id == current })
        else {
            selectedTabID = tabs.first?.id
            return
        }
        let next = forward ? (index + 1) % tabs.count : (index - 1 + tabs.count) % tabs.count
        selectedTabID = tabs[next].id
    }

    public func moveTab(from source: Int, to destination: Int) {
        guard tabs.indices.contains(source), destination >= 0, destination <= tabs.count else { return }
        let tab = tabs.remove(at: source)
        tabs.insert(tab, at: min(destination, tabs.count))
    }
}

/// What the table context menu asked for; the workspace opens the matching sheet.
public struct TableOperationRequest: Identifiable, Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case rename
        case duplicate
        case importCSV
        case maintenance(MaintenanceAction)
    }

    public let id = UUID()
    public let kind: Kind
    public let table: TableRef
    public let connectionID: UUID

    public init(kind: Kind, table: TableRef, connectionID: UUID) {
        self.kind = kind
        self.table = table
        self.connectionID = connectionID
    }
}

/// A pending commit awaiting the user's confirmation.
@MainActor
public struct CommitPreview: Identifiable {
    public let id = UUID()
    public let statements: [GeneratedStatement]
    public let dialect: SQLDialect
    public let connectionName: String
    public let isProduction: Bool
    public let tab: WorkspaceTab

    public init(
        statements: [GeneratedStatement],
        dialect: SQLDialect,
        connectionName: String,
        isProduction: Bool,
        tab: WorkspaceTab
    ) {
        self.statements = statements
        self.dialect = dialect
        self.connectionName = connectionName
        self.isProduction = isProduction
        self.tab = tab
    }

    public var summary: String {
        let counts = Dictionary(grouping: statements, by: \.kind).mapValues(\.count)
        let parts = GeneratedStatement.Kind.allCases.compactMap { kind -> String? in
            guard let count = counts[kind], count > 0 else { return nil }
            return "\(count) \(kind.rawValue.uppercased())\(count == 1 ? "" : "S")"
        }
        return parts.joined(separator: ", ")
    }
}

/// A destructive action that needs confirmation before it runs (SPEC §11.1).
@MainActor
public struct DestructiveConfirmation: Identifiable {
    public let id = UUID()
    public let title: String
    public let message: String
    /// When set, the user must type this exact name before the action is enabled.
    public let requiredTypedName: String?
    public let confirmTitle: String
    public let action: @MainActor () async -> Void
    /// Runs when the user declines, for a caller that has to answer either way (AppKit
    /// waiting on whether it may quit).
    public let onCancel: (@MainActor () -> Void)?

    public init(
        title: String,
        message: String,
        requiredTypedName: String? = nil,
        confirmTitle: String = "Delete",
        action: @escaping @MainActor () async -> Void,
        onCancel: (@MainActor () -> Void)? = nil
    ) {
        self.title = title
        self.message = message
        self.requiredTypedName = requiredTypedName
        self.confirmTitle = confirmTitle
        self.action = action
        self.onCancel = onCancel
    }
}
