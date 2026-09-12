import DBCore
import DBGrid
import DBSQL
import SwiftUI

/// A table tab: the grid, its filter bar, the inspector and the status line.
public struct TableTabView: View {
    @Bindable var controller: TableTabController
    @Bindable var workspace: WorkspaceModel
    @Bindable var tab: WorkspaceTab

    /// Which half of the tab is showing.
    enum Mode: String, CaseIterable, Identifiable {
        case data = "Data"
        case structure = "Structure"
        case map = "Map"
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .data: Icon.data
            case .structure: Icon.structure
            case .map: Icon.map
            }
        }
    }

    @State private var mode: Mode = .data
    @State private var isColumnsPopoverShown = false
    /// The structure pane is built the first time it is asked for, then kept.
    @State private var hasVisitedStructure = false
    @State private var mapColumn = -1
    /// The rows on the map; nil is all of them.
    @State private var mapRows: Set<Int>?

    /// Geometry columns in the grid, looked for once per revision.
    private var geometryColumns: [Int] {
        guard let model = controller.model else { return [] }
        return GeometryColumns.detect(in: model, dialect: model.dialect)
    }

    public var body: some View {
        VStack(spacing: 0) {
            modeBar
            Divider()

            // Both panes stay alive; switching only changes which one is shown, so the grid
            // neither flashes nor loses its place when Structure is visited and left.
            ZStack {
                dataContent
                    .opacity(mode == .data ? 1 : 0)
                    .allowsHitTesting(mode == .data)
                    .accessibilityHidden(mode != .data)
                if hasVisitedStructure {
                    StructureView(
                        controller: controller.structure,
                        isProduction: controller.isProduction
                    )
                    // The grid's own idea of the table is stale once the structure changed.
                    .onChange(of: controller.structure.statusText) { _, status in
                        guard status != nil else { return }
                        Task { await controller.reloadAfterStructureChange() }
                    }
                    .opacity(mode == .structure ? 1 : 0)
                    .allowsHitTesting(mode == .structure)
                    .accessibilityHidden(mode != .structure)
                }
                if mode == .map, let model = controller.model {
                    let columns = geometryColumns
                    MapPaneView(
                        grid: model,
                        dialect: model.dialect,
                        revision: controller.revision,
                        column: Binding(
                            get: { columns.contains(mapColumn) ? mapColumn : (columns.first ?? 0) },
                            set: { mapColumn = $0 }
                        ),
                        columns: columns,
                        rows: $mapRows,
                        onSelectRow: { row in
                            controller.selection = GridSelection(row: row, column: 0, mode: .rows)
                            controller.bumpRevision()
                        }
                    )
                }
            }
        }
        .onChange(of: mode) { _, new in
            if new == .structure { hasVisitedStructure = true }
        }
        // The rows on the map belong to one page of one grid: a new grid, page, filter or
        // sort puts every row back on the map.
        .onChange(of: controller.model.map(ObjectIdentifier.init)) { _, _ in mapRows = nil }
        .onChange(of: controller.model?.pageOffset) { _, _ in mapRows = nil }
        .onChange(of: controller.model?.sort) { _, _ in mapRows = nil }
        .onChange(of: controller.filterRules) { _, _ in mapRows = nil }
        .onChange(of: controller.quickSearch) { _, _ in mapRows = nil }
        // "Show on Map" from a cell: that one row, from that column.
        .onChange(of: controller.mapRequest) { _, request in
            guard let request else { return }
            mapColumn = request.column
            mapRows = [request.row]
            mode = .map
        }
        .onAppear {
            controller.autoCommit = tab.autoCommit
            if UserDefaults.standard.bool(forKey: "uiDemo.structure") {
                UserDefaults.standard.removeObject(forKey: "uiDemo.structure")
                mode = .structure
                hasVisitedStructure = true
            }
            if UserDefaults.standard.bool(forKey: "uiDemo.map") {
                UserDefaults.standard.removeObject(forKey: "uiDemo.map")
                Task {
                    try? await Task.sleep(for: .milliseconds(1_200))
                    mode = .map
                }
            }
            if UserDefaults.standard.bool(forKey: "uiDemo.mapRow") {
                UserDefaults.standard.removeObject(forKey: "uiDemo.mapRow")
                Task {
                    try? await Task.sleep(for: .milliseconds(1_200))
                    if let column = geometryColumns.first { controller.mapRequest = MapRequest(row: 2, column: column) }
                }
            }
            if UserDefaults.standard.bool(forKey: "uiDemo.referencePick") {
                UserDefaults.standard.removeObject(forKey: "uiDemo.referencePick")
                Task {
                    // Re-post a few times: the transient popover needs a key window, which
                    // is not guaranteed the instant the tab appears while the app launches.
                    for _ in 0 ..< 8 {
                        try? await Task.sleep(for: .milliseconds(700))
                        guard let model = controller.model,
                            let column = model.columns.firstIndex(where: { controller.gridColumnReferences($0.id) })
                        else { continue }
                        controller.selection = GridSelection(row: 0, column: column)
                        NotificationCenter.default.post(
                            name: .tinkerPresentReferencePicker, object: controller,
                            userInfo: ["row": 0, "column": column, "demo": true])
                    }
                }
            }
            if UserDefaults.standard.bool(forKey: "uiDemo.mapPeek") {
                UserDefaults.standard.removeObject(forKey: "uiDemo.mapPeek")
                Task {
                    try? await Task.sleep(for: .milliseconds(1_200))
                    guard let column = geometryColumns.first else { return }
                    NotificationCenter.default.post(
                        name: .tinkerPeekOnMap, object: controller, userInfo: ["row": 2, "column": column])
                }
            }
            controller.onRequestInspector = { tab.isInspectorVisible = true }
            controller.onFollowReference = { table, rules in
                workspace.followReference(to: table, connectionID: tab.connectionID, filter: rules)
            }
        }
    }

    /// What an empty grid shows: a filter that matched nothing offers to clear itself; an
    /// empty table offers a first row when it can take one.
    @ViewBuilder
    private func emptyRowsState(_ model: GridModel) -> some View {
        let filtered =
            !controller.filterRules.isEmpty || !controller.quickSearch.trimmingCharacters(in: .whitespaces).isEmpty
        VStack {
            Spacer(minLength: DesignTokens.Spacing.xl)
            EmptyStateView(
                icon: filtered ? Icon.filter : Icon.table,
                title: filtered ? "No rows match these conditions" : "This table has no rows",
                message: filtered
                    ? "Loosen the filter or the search to see rows again."
                    : (model.isEditable ? "Add a row to start filling it in." : nil),
                fills: false
            ) {
                if filtered {
                    Button("Clear Filter") {
                        controller.quickSearch = ""
                        controller.applyFilterLive([])
                        Task { await controller.applyQuickSearch("") }
                    }
                } else if model.isEditable {
                    Button("Add Row") { controller.addRow() }
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(true)
    }

    /// The tab's own header: what this is, Data or Structure, and the grid's tools.
    private var modeBar: some View {
        PaneBar {
            HStack(spacing: DesignTokens.Spacing.xs + 2) {
                Image(systemName: Icon.table).foregroundStyle(Color.accentColor)
                Text(controller.table.name).font(.system(size: DesignTokens.Typography.body, weight: .semibold))
                Text(controller.table.schema).font(.caption).foregroundStyle(.tertiary)
            }
            .help(controller.table.id)

            BarDivider()

            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases.filter { $0 != .map || !geometryColumns.isEmpty }) { mode in
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

                Toggle(isOn: $tab.isInspectorVisible) {
                    Label("Inspector", systemImage: Icon.inspector)
                }
                .toggleStyle(.button)
                .buttonStyle(.borderless)
                .help("Show or hide the inspector (⌘⌥I)")

                Button {
                    isColumnsPopoverShown = true
                } label: {
                    Label(
                        controller.hiddenColumns.isEmpty
                            ? "Columns" : "Columns (\(controller.hiddenColumns.count) hidden)", systemImage: Icon.column
                    )
                }
                .buttonStyle(.borderless)
                .help("Choose which columns the grid shows")
                .popover(isPresented: $isColumnsPopoverShown, arrowEdge: .bottom) {
                    ColumnsPopover(controller: controller)
                }

                BarDivider()

                // A production connection has no auto-commit: every write goes through the
                // commit sheet, so the checkbox would only mislead and is not shown.
                if !controller.isProduction {
                    // Bound to the property itself, so the click shows at once; the write it
                    // may owe happens after.
                    Toggle("Auto-commit", isOn: $controller.autoCommit)
                        .toggleStyle(.checkbox)
                        .onChange(of: controller.autoCommit) { _, enabled in
                            tab.autoCommit = enabled
                            controller.autoCommitDidChange()
                        }
                        .help("On writes each edit as you make it; off keeps edits pending until Commit")

                    BarDivider()
                }

                IconButton(icon: Icon.add, label: "Add row (⌘⌥A)") { controller.addRow() }
                    .disabled(!(controller.model?.isEditable ?? false))
                IconButton(icon: Icon.remove, label: "Delete selected rows (⌘−)") {
                    controller.deleteSelectedRows()
                }
                .disabled(!(controller.model?.isEditable ?? false))
                IconButton(icon: Icon.refresh, label: "Reload rows (F5)") {
                    Task { await controller.refresh() }
                }
                IconButton(icon: Icon.export, label: "Export… (⌘⌥E)") {
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
                        hiddenColumns: controller.hiddenColumns,
                        revision: controller.revision,
                        delegate: controller
                    )
                    // An empty grid says why it is empty and what to do about it, rather
                    // than leaving striped rows to be read as "still loading".
                    .overlay {
                        if !controller.isLoading, controller.errorText == nil, model.displayRowCount == 0,
                            model.isExhausted || model.totalCount == 0
                        {
                            emptyRowsState(model)
                        }
                    }
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

                if tab.isInspectorVisible, let model = controller.model {
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
                        },
                        isColumnEditable: { model.isColumnEditable($0) },
                        canPickReference: { column in controller.gridColumnReferences(column) },
                        onPickReference: { column in controller.requestReferencePicker(column: column) }
                    )
                    .id(controller.revision)
                }
            }

            Divider()
            statusBar
        }
        .task(id: tab.id) {
            // Once. A pane that comes back into view must not reload the grid it kept.
            if controller.model == nil { await controller.start() }
        }
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
            if let model = controller.model {
                let rows = controller.selection.selectedRowCount(totalRows: model.displayRowCount)
                if controller.selection.mode == .rows, rows > 0 {
                    Text("\(rows) row\(rows == 1 ? "" : "s") selected").monospacedDigit()
                } else if controller.selection.rowSpan > 1 || controller.selection.columnSpan > 1 {
                    Text("\(controller.selection.rowSpan)×\(controller.selection.columnSpan) selected")
                        .monospacedDigit()
                }
            }
            if let model = controller.model {
                if controller.autoCommitsEdits {
                    autoCommitStatus(model)
                } else if model.edits.pendingStatementCount > 0 {
                    Button("Discard") { controller.discardEdits() }
                        .controlSize(.small)
                        .disabled(controller.isWriting)
                    Button {
                        presentCommitPreview()
                    } label: {
                        Label("Commit \(model.edits.pendingStatementCount)…", systemImage: Icon.commit)
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    // ⌘⇧S belongs to File › Commit, which reaches this tab through the
                    // workspace; a second registration here made the key ambiguous.
                    .disabled(controller.isWriting)
                }
            }
        }
    }

    /// With auto-commit on there is nothing to confirm: a write in flight says so, a
    /// write the server refused offers a retry, and a new row says when it will go.
    @ViewBuilder
    private func autoCommitStatus(_ model: GridModel) -> some View {
        if controller.isWriting {
            ProgressView().controlSize(.small)
            Text("Saving…")
        } else if model.edits.pendingStatementCount(.loadedRowsOnly) > 0 {
            if let reason = controller.errorText {
                Text(reason).foregroundStyle(.red).lineLimit(1).truncationMode(.middle)
            }
            Button("Discard") { controller.discardEdits() }
                .controlSize(.small)
            Button {
                Task { await controller.commit(.loadedRowsOnly) }
            } label: {
                Label("Retry", systemImage: Icon.commit)
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .help("The last write was refused; the edit is still here")
        } else if !model.edits.pendingInserts.isEmpty {
            Text("New row saves when you leave it")
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

/// The list of a table's columns with a checkbox each: what the grid shows.
struct ColumnsPopover: View {
    @Bindable var controller: TableTabController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Columns").font(.headline)
                Spacer()
                Button("Show All") { controller.showAllColumns() }
                    .controlSize(.small)
                    .disabled(controller.hiddenColumns.isEmpty)
            }
            .padding(.horizontal, DesignTokens.Spacing.lg)
            .padding(.vertical, DesignTokens.Spacing.md)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    ForEach(controller.columnsInfo) { column in
                        Toggle(
                            isOn: Binding(
                                get: { !controller.hiddenColumns.contains(column.name) },
                                set: { shown in controller.setColumn(column.name, hidden: !shown) }
                            )
                        ) {
                            HStack(spacing: DesignTokens.Spacing.sm) {
                                Text(column.name).lineLimit(1)
                                Text(column.nativeType).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                                if column.isPrimaryKey { Badge(text: "PK", color: .accentColor) }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .padding(DesignTokens.Spacing.lg)
            }
            .frame(maxHeight: 360)
            Divider()
            Text("Hidden columns are remembered for this table. Right-click a column heading to hide it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, DesignTokens.Spacing.lg)
                .padding(.vertical, DesignTokens.Spacing.sm)
        }
        .frame(width: 320)
    }
}
