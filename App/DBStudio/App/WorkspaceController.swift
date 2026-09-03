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
    /// Toggled by the sidebar command; the split view reads it.
    public var isSidebarVisible = true

    public init(environment: AppEnvironment, settings: AppSettings) {
        self.environment = environment
        self.settings = settings
        workspace = WorkspaceModel(environment: environment)
        sidebar = SidebarModel(environment: environment)
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
        if let controller = queryControllers.removeValue(forKey: id) {
            Task { await controller.releaseHeldConnection() }
        }
        tableControllers.removeValue(forKey: id)
        workspace.closeTab(id)
    }

    // MARK: - Commands the menus call

    public func newQueryTab() {
        guard let id = workspace.activeConnectionID else { return }
        newQueryTab(connectionID: id)
    }

    public func run(all: Bool) {
        activeQueryController?.run(all: all)
    }

    public func cancel() {
        activeQueryController?.cancel()
    }

    public func commit() {
        if let controller = activeQueryController {
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

    public func toggleReadOnly() {
        guard let id = workspace.activeConnectionID,
              let session = environment.session(for: id)
        else { return }
        Task {
            let current = await session.isReadOnly
            await session.setReadOnlyOverride(current)
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
    public func setNull() { activeTableController?.setSelectionNull() }
    public func addRow() { activeTableController?.addRow() }
    public func deleteRows() { activeTableController?.deleteSelectedRows() }

    public func cycleResultTab(forward: Bool) {
        guard let controller = activeQueryController, !controller.results.isEmpty else { return }
        let index = controller.results.firstIndex { $0.id == controller.selectedResultID } ?? 0
        let next = forward
            ? (index + 1) % controller.results.count
            : (index - 1 + controller.results.count) % controller.results.count
        controller.selectedResultID = controller.results[next].id
    }

    public func openSQLFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8),
              let id = workspace.activeConnectionID
        else { return }
        let tab = newQueryTab(connectionID: id, sql: text)
        tab.title = url.lastPathComponent
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
