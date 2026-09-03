import DBCore
import DBGrid
import DBSQL
import SwiftUI

/// A table tab: the grid, its filter bar, the inspector and the status line.
public struct TableTabView: View {
    @Bindable var controller: TableTabController
    @Bindable var workspace: WorkspaceModel
    let tab: WorkspaceTab

    /// Which half of the tab is showing.
    enum Mode: String, CaseIterable, Identifiable {
        case data = "Data"
        case structure = "Structure"
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .data: Icon.data
            case .structure: Icon.structure
            }
        }
    }

    @State private var mode: Mode = .data

    public var body: some View {
        VStack(spacing: 0) {
            modeBar
            Divider()

            switch mode {
            case .structure:
                StructureView(
                    controller: controller.structure,
                    isProduction: controller.isProduction
                )
                // The grid's own idea of the table is stale once the structure changed.
                .onChange(of: controller.structure.statusText) { _, status in
                    guard status != nil else { return }
                    Task { await controller.reloadAfterStructureChange() }
                }
            case .data:
                dataContent
            }
        }
        .onAppear {
            if UserDefaults.standard.bool(forKey: "uiDemo.structure") {
                UserDefaults.standard.removeObject(forKey: "uiDemo.structure")
                mode = .structure
            }
            controller.onRequestInspector = { workspace.isInspectorVisible = true }
            controller.onFollowReference = { table, rules in
                workspace.followReference(to: table, connectionID: tab.connectionID, filter: rules)
            }
        }
    }

    /// The tab's own header: what this is, Data or Structure, and the grid's tools.
    private var modeBar: some View {
        PaneBar {
            HStack(spacing: DesignTokens.Spacing.xs + 2) {
                Image(systemName: Icon.table).foregroundStyle(Color.accentColor)
                Text(controller.table.name).font(.system(size: 13, weight: .semibold))
                Text(controller.table.schema).font(.caption).foregroundStyle(.tertiary)
            }
            .help(controller.table.id)

            BarDivider()

            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases) { mode in
                    Label(mode.rawValue, systemImage: mode.icon).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Spacer()

            if mode == .data {
                Toggle(isOn: $workspace.isFilterBarVisible) {
                    Label("Filter", systemImage: Icon.filter)
                }
                .toggleStyle(.button)
                .buttonStyle(.borderless)
                .help("Show or hide the filter bar (⌘⇧F)")

                Toggle(isOn: $workspace.isInspectorVisible) {
                    Label("Inspector", systemImage: Icon.inspector)
                }
                .toggleStyle(.button)
                .buttonStyle(.borderless)
                .help("Show or hide the inspector (⌘⌥I)")

                BarDivider()

                IconButton(icon: Icon.add, label: "Add row (⌘+)") { controller.addRow() }
                    .disabled(!(controller.model?.isEditable ?? false))
                IconButton(icon: Icon.remove, label: "Delete selected rows (⌘−)") {
                    controller.deleteSelectedRows()
                }
                .disabled(!(controller.model?.isEditable ?? false))
                IconButton(icon: Icon.refresh, label: "Reload rows (⌘R)") {
                    Task { await controller.refresh() }
                }
                IconButton(icon: Icon.export, label: "Export… (⌘E)") {
                    workspace.isExportPresented = true
                }
                IconButton(icon: Icon.importData, label: "Import from CSV…") {
                    workspace.pendingTableOperation = TableOperationRequest(
                        kind: .importCSV, table: controller.table, connectionID: tab.connectionID
                    )
                }
                .disabled(!(controller.model?.isEditable ?? false))
            }
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private var dataContent: some View {
        VStack(spacing: 0) {
            if workspace.isFilterBarVisible, let model = controller.model {
                FilterBarView(
                    columns: model.columns,
                    dialect: model.dialect,
                    rules: $controller.filterRules,
                    quickSearch: $controller.quickSearch,
                    onApply: { rules in controller.applyFilterLive(rules) },
                    onQuickSearch: { text in Task { await controller.applyQuickSearch(text) } }
                )
                Divider()
            }

            if let error = controller.errorText {
                InlineBanner(kind: .error, message: error) { controller.errorText = nil }
                Divider()
            }

            HStack(spacing: 0) {
                if let model = controller.model {
                    DataGridView(
                        model: model,
                        selection: $controller.selection,
                        columnWidths: controller.columnWidths,
                        revision: controller.revision,
                        delegate: controller
                    )
                } else if controller.isLoading {
                    VStack(spacing: DesignTokens.Spacing.md) {
                        ProgressView()
                        Text("Loading \(controller.table.name)…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    EmptyStateView(icon: Icon.table, title: "Nothing loaded") {
                        Button("Try Again") { Task { await controller.start() } }
                    }
                }

                if workspace.isInspectorVisible, let model = controller.model {
                    Divider()
                    CellInspectorView(
                        columns: model.columns,
                        focusedColumn: controller.selection.focusColumn,
                        focusedRow: controller.selection.focusRow,
                        rowValues: controller.rowValues(controller.selection.focusRow),
                        rowState: model.rowChangeState(controller.selection.focusRow),
                        isEditable: model.isEditable,
                        hasReference: { column in
                            controller.gridHasReference(row: controller.selection.focusRow, column: column)
                        },
                        onCommit: { column, text in
                            controller.gridDidCommitEdit(
                                row: controller.selection.focusRow, column: column, text: text
                            )
                        },
                        onSetNull: { column in
                            model.setValue(.null, row: controller.selection.focusRow, column: column)
                            controller.bumpRevision()
                            controller.updateStatus()
                        },
                        onFollow: { column in
                            controller.gridDidRequestFollowReference(
                                row: controller.selection.focusRow, column: column
                            )
                        }
                    )
                    .id(controller.revision)
                }
            }

            Divider()
            statusBar
        }
        .task(id: tab.id) { await controller.start() }
    }

    /// First / previous / next / last and the page number.
    @ViewBuilder
    var pager: some View {
        if controller.model?.isPaged == true {
            HStack(spacing: 0) {
                IconButton(icon: Icon.firstPage, label: "First page") {
                    Task { await controller.goToFirstPage() }
                }
                .disabled(!controller.canGoBack)
                IconButton(icon: Icon.previousPage, label: "Previous page") {
                    Task { await controller.goToPreviousPage() }
                }
                .disabled(!controller.canGoBack)
                Text("Page \(controller.currentPage)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.primary)
                    .frame(minWidth: 52)
                IconButton(icon: Icon.nextPage, label: "Next page") {
                    Task { await controller.goToNextPage() }
                }
                .disabled(!controller.canGoForward)
                IconButton(icon: Icon.lastPage, label: "Last page — counts the matching rows to find it") {
                    Task { await controller.goToLastPage() }
                }
                .disabled(!controller.canGoForward)
            }
            BarDivider()
        }
    }

    var statusBar: some View {
        StatusBarView {
            pager
            Text(controller.statusText)
            Spacer()
            if controller.selection.rowSpan > 1 || controller.selection.columnSpan > 1 {
                Text("\(controller.selection.rowSpan)×\(controller.selection.columnSpan) selected")
                    .monospacedDigit()
            }
            if let model = controller.model, model.edits.pendingStatementCount > 0 {
                Button("Discard") { controller.discardEdits() }
                    .controlSize(.small)
                Button {
                    presentCommitPreview()
                } label: {
                    Label("Commit \(model.edits.pendingStatementCount)…", systemImage: Icon.commit)
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }
        }
    }

    func presentCommitPreview() {
        guard let model = controller.model,
              let config = workspace.environment.connections.first(where: { $0.id == tab.connectionID })
        else { return }
        let statements = controller.pendingStatements()
        guard !statements.isEmpty else { return }
        workspace.commitPreview = CommitPreview(
            statements: statements,
            dialect: model.dialect,
            connectionName: config.name,
            isProduction: config.isProduction,
            tab: tab
        )
    }
}
