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
    public var isSidebarVisible = true
    public var isInspectorVisible = false
    public var quickOpenQuery = ""
    public var isQuickOpenPresented = false
    /// The table designer's two entry points (SPEC §15b.3, §15b.4).
    public var isNewTablePresented = false
    public var isStructureSyncPresented = false
    public var isHistoryPresented = false
    public var isExportPresented = false
    public var isSettingsPresented = false
    public var isFilterBarVisible = false
    /// The connection whose editor sheet is open, or nil.
    public var editingConnection: ConnectionConfig?
    public var isEditingNewConnection = false
    public var commitPreview: CommitPreview?
    public var confirmation: DestructiveConfirmation?

    public let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
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

    // MARK: - Tabs

    public func open(_ tab: WorkspaceTab) {
        tabs.append(tab)
        selectedTabID = tab.id
    }

    /// Opens a table, focusing the tab that already shows it unless `forceNew`.
    public func openTable(_ table: TableRef, connectionID: UUID, forceNew: Bool = false) -> WorkspaceTab {
        if !forceNew, let existing = tabs.first(where: {
            $0.connectionID == connectionID && $0.tableRef == table
        }) {
            selectedTabID = existing.id
            return existing
        }
        let tab = WorkspaceTab(kind: .table(table), connectionID: connectionID, title: table.name)
        open(tab)
        return tab
    }

    @discardableResult
    public func newQueryTab(connectionID: UUID, sql: String = "") -> WorkspaceTab {
        let number = tabs.filter(\.isQueryTab).count + 1
        let tab = WorkspaceTab(kind: .query, connectionID: connectionID, title: "SQL \(number)")
        tab.sql = sql
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

/// A pending commit awaiting the user's confirmation (SPEC §12.3).
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

    public init(
        title: String,
        message: String,
        requiredTypedName: String? = nil,
        confirmTitle: String = "Delete",
        action: @escaping @MainActor () async -> Void
    ) {
        self.title = title
        self.message = message
        self.requiredTypedName = requiredTypedName
        self.confirmTitle = confirmTitle
        self.action = action
    }
}
