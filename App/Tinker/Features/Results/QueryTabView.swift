import DBCore
import DBGrid
import DBSQL
import SwiftUI

/// A query tab: editor above, one result tab per statement below.
public struct QueryTabView: View {
    @Bindable var controller: QueryTabController
    @Bindable var workspace: WorkspaceModel
    @Bindable var tab: WorkspaceTab
    let fontName: String
    let fontSize: Double
    @Bindable var settings: AppSettings

    @State private var resultPane: ResultPane = .result
    @State private var isWriteLogShown = false
    /// `--ui-demo chart` asked for the Chart pane. Read once when the tab appears and
    /// cleared there, so a scene whose statement failed cannot leave the flag behind for
    /// the next ordinary launch to pick up.
    @State private var wantsChartDemo = false
    @State private var chartKind: ChartKind = .bar
    @State private var chartCategory = -1
    @State private var chartValue = -1
    @State private var chartAggregate: ChartAggregate = .none

    /// The connection pop-up's items: folder-qualified titles, so two connections called
    /// the same — one per folder — read apart.
    private var connectionItems: [BarPopUp<UUID>.Item] {
        let titles = ConnectionConfig.distinctTitles(for: controller.availableConnections)
        return controller.availableConnections.map {
            BarPopUp.Item(id: $0.id, title: titles[$0.id] ?? $0.name, icon: Icon.connection)
        }
    }

    /// What the session-database pop-up means on each engine.
    private var sessionDatabaseHelp: String {
        switch controller.dialect {
        case .mysql: "The database unqualified names resolve against (USE)"
        case .postgresql:
            "The database and schema this tab runs on: another database opens its own connection, "
                + "and the schema is what unqualified names resolve against (search_path)"
        case .sqlite: "The database file's one schema; unqualified names resolve in it"
        }
    }

    /// The session pop-up's rows. Until the list has been read — a tab is not worth a
    /// connection until it is used — the pop-up holds one row saying so, and the same
    /// stands in when the session is on nothing the list names.
    private var sessionItems: [BarPopUp<QueryTabController.SessionChoiceID>.Item] {
        var items = controller.sessionChoices.map {
            BarPopUp.Item(id: $0.id, title: $0.title, icon: $0.icon)
        }
        let selected = controller.selectedSessionChoice
        if !items.contains(where: { $0.id == selected }) {
            items.insert(
                BarPopUp.Item(
                    id: selected, title: controller.isLoadingSessionChoices ? "Loading…" : "Choose…"),
                at: 0
            )
        }
        return items
    }

    public var body: some View {
        // Results below the editor, or beside it. The same two panes either way; only the
        // splitter's axis and which dimension carries the minimum change.
        Group {
            if settings.splitQuerySideBySide {
                HSplitView {
                    editorPane
                    resultsPane
                }
            } else {
                VSplitView {
                    editorPane
                    resultsPane
                }
            }
        }
        .task(id: tab.id) {
            if UserDefaults.standard.bool(forKey: "uiDemo.chart") {
                UserDefaults.standard.removeObject(forKey: "uiDemo.chart")
                wantsChartDemo = true
            }
            controller.sql = tab.sql
            controller.autoCommit = tab.autoCommit
            // The connection pop-up needs nothing from any server. The database pop-up
            // does, and waits for the tab to be used: its menu opened, a statement run, or
            // a word typed. A tab that is only created no longer wakes a server.
            controller.loadConnectionChoices()
        }
        .onChange(of: controller.sql) { _, new in tab.sql = new }
        // The rows on the map belong to one result: another result, or a re-run, puts
        // every row back.
        .onChange(of: controller.selectedResultID) { _, _ in resetPaneChoices() }
        .onChange(of: controller.results.map(\.id)) { _, _ in
            resetPaneChoices()
            showChartPaneIfDemoAsked()
        }
        // The rows arrive after the result tab does, and the Chart pane is offered only
        // once there is something in them to measure.
        .onChange(of: controller.revision) { _, _ in showChartPaneIfDemoAsked() }
        // "Show on Map" from a result cell: that one row, from that column.
        .onChange(of: controller.mapRequest) { _, request in
            guard let request else { return }
            mapColumn = request.column
            mapRows = [request.row]
            resultPane = .map
        }
        .onDisappear {
            let controller = controller
            Task { await controller.releaseHeldConnection() }
        }
    }

    // MARK: - Editor bar

    /// Run controls on the left, the tab's session in the middle, the transaction on the
    /// right: what to do, where it goes, and what state it leaves behind.
    var editorToolbar: some View {
        toolbarContent
            .onAppear {
                controller.onRequestInspector = { tab.isInspectorVisible = true }
                controller.onFollowReference = { table, rules in
                    workspace.followReference(to: table, connectionID: controller.connectionID, filter: rules)
                }
            }
    }

    var toolbarContent: some View {
        PaneBar {
            Button {
                controller.editorDidRequestRun(.current, selection: controller.selectedRange)
            } label: {
                Label("Run", systemImage: Icon.run)
            }
            .disabled(controller.isRunning)
            .help("Run the statement under the cursor, or the highlighted block (⌘R)")

            Button {
                controller.runSelection()
            } label: {
                Label("Run Selected", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            .disabled(controller.isRunning || !controller.hasSelection)
            .help("Run only the highlighted text (⌘⌃R)")

            Button {
                controller.run(all: true)
            } label: {
                Label("Run All", systemImage: Icon.runAll)
            }
            .disabled(controller.isRunning)
            .help("Run every statement on the page (⌘⌥R)")

            BarDivider()

            // Running a statement is what the bar is for, so those three carry their
            // names. What shapes the page rather than running it — the plan, the layout,
            // where the results sit — is an icon with its shortcut in the tooltip: each
            // is a keystroke and a menu item as well, and three more labels crowded out
            // the connection and database this tab runs on.
            IconButton(icon: Icon.explain, label: "Explain the statement under the cursor (⌘⇧E)") {
                controller.explain(analyze: false)
            }
            .disabled(controller.isRunning)
            .contextMenu {
                Button("Explain") { controller.explain(analyze: false) }
                Button("Explain Analyze (runs the statement)") { controller.explain(analyze: true) }
            }

            IconButton(icon: Icon.format, label: "Beautify: one clause per line, or just the selection (⌘⇧I)") {
                controller.formatSQL()
            }

            IconButton(
                icon: settings.splitQuerySideBySide ? Icon.splitSideBySide : Icon.splitStacked,
                label: settings.splitQuerySideBySide
                    ? "Put the results back below the editor" : "Put the results beside the editor"
            ) {
                settings.splitQuerySideBySide.toggle()
                Task { await settings.save() }
            }

            if controller.isRunning {
                Button {
                    controller.cancel()
                } label: {
                    Label("Stop", systemImage: Icon.stop)
                }
                .help("Cancel on the server (⌘.)")
                ProgressView().controlSize(.small)
                // Its own view: `elapsed` changes ten times a second while a statement
                // runs, and reading it here re-rendered the whole tab — editor bridge
                // included — on every tick.
                ElapsedLabel(controller: controller)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            BarDivider()

            // The tab's session: statements resolve unqualified names here. Both pop-ups
            // keep a fixed width, so the bar reads the same whatever they are called.
            BarPopUp(
                items: connectionItems,
                selection: Binding(
                    get: { controller.connectionID },
                    set: { id in Task { await controller.selectConnection(id) } }
                ),
                onWillOpen: { controller.loadConnectionChoices() }
            )
            .frame(width: 170)
            .help("The connection this tab runs on")

            BarPopUp(
                items: sessionItems,
                selection: Binding(
                    get: { controller.selectedSessionChoice },
                    set: { id in Task { await controller.selectSessionChoice(id) } }
                ),
                // Asking for the list is what reads it, which is why a tab that was only
                // opened never connects.
                onWillOpen: {
                    Task { await controller.loadSessionChoicesIfNeeded(retryAfterFailure: true) }
                }
            )
            .frame(width: 200)
            .help(sessionDatabaseHelp)

            BarDivider()

            // Bound to the property itself: a checkbox whose binding only changes its value
            // later, on another turn of the run loop, snaps back to what it read and never
            // shows the click. The commit that turning it on may owe happens after.
            if controller.isProduction {
                // Production never auto-commits: every write waits for Commit, so the
                // checkbox would only promise something the tab does not do.
                Badge(text: "MANUAL COMMIT", color: .red)
                    .help("A production connection holds every write in a transaction until you commit or roll back")
            } else {
                Toggle("Auto-commit", isOn: $controller.autoCommit)
                    .toggleStyle(.checkbox)
                    .onChange(of: controller.autoCommit) { _, enabled in
                        tab.autoCommit = enabled
                        Task { await controller.setAutoCommit(enabled) }
                    }
                    .help(
                        "Off holds a transaction open until you commit or roll back, "
                            + "from the next statement and including reads")
            }

            if controller.isInTransaction {
                // Two tiers, because the two are not the same thing to lose: one holds
                // changes that Commit would keep, the other only the read view the server
                // gave. Both stay orange and both keep Commit and Rollback (SPEC §13.2) —
                // a transaction with nothing written still holds locks, and committing it
                // is the honest way to let them go.
                Badge(
                    text: controller.transactionHasWrites ? "TRANSACTION OPEN" : "TRANSACTION · NO WRITES",
                    color: .orange
                )
                .help(controller.transactionHelp)
                Button("Commit") { Task { await controller.commitTransaction() } }
                Button("Rollback") { Task { await controller.rollbackTransaction() } }
            }

            // What the last edit to a result grid wrote, and the way back from it: a
            // result grid writes to a real table, so a slip here is as permanent as one in
            // a table tab (ADR-0060).
            if let latest = controller.writeLog.latest, !controller.isWritingEdits {
                Button {
                    isWriteLogShown = true
                } label: {
                    Label(latest.summary, systemImage: Icon.history)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("What this tab has written")
                .popover(isPresented: $isWriteLogShown, arrowEdge: .bottom) {
                    WriteLogPopover(owner: controller)
                }
                if let undoable = controller.writeLog.undoable, undoable.id == latest.id {
                    Button("Undo") { controller.revert(undoable) }
                        .help("Put back what this write replaced (⌘Z)")
                }
            }

            Spacer()

            // The query tab has an inspector of its own, so it has its own switch for it;
            // without one it could only be turned off from whichever table tab turned it on.
            Toggle(isOn: $tab.isInspectorVisible) {
                Label("Inspector", systemImage: Icon.inspector)
            }
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .disabled(controller.selectedResult?.grid == nil)
            .help("Show or hide the inspector for the selected result (⌘⌥I)")

            // Export sits where the eye lands after a query: the result's rows to a file.
            Button {
                workspace.isExportPresented = true
            } label: {
                Label("Export", systemImage: Icon.export)
            }
            .disabled(controller.selectedResult?.grid == nil)
            .help("Write the selected result to CSV, Excel, JSON or SQL (⌘⌥E)")

            IconButton(icon: Icon.snippet, label: "Snippets (⌘⇧K)") {
                workspace.isSnippetsPresented = true
            }
            IconButton(icon: Icon.history, label: "History (⌘Y)") {
                workspace.isHistoryPresented = true
            }
        }
        .controlSize(.small)
    }

    // MARK: - Results

    /// Another result's columns are not this one's, so the pane's column choices go back to
    /// being unset and the chart picks its own again.
    private func resetPaneChoices() {
        mapRows = nil
        chartCategory = -1
        chartValue = -1
        // The new result may not offer the pane the old one was showing; a segmented
        // control with no matching tag draws with nothing selected.
        if !visiblePanes.contains(resultPane) { resultPane = .result }
    }

    /// `--ui-demo chart` opens on the Chart pane rather than on Rows. It waits for a
    /// result the pane is offered for, and then does what a click on Chart would do.
    private func showChartPaneIfDemoAsked() {
        guard wantsChartDemo, visiblePanes.contains(.chart) else { return }
        wantsChartDemo = false
        resultPane = .chart
    }

    /// The panes this result can actually fill. Chart and Map are offered only where there
    /// is something to draw.
    private var visiblePanes: [ResultPane] {
        ResultPane.allCases.filter { pane in
            switch pane {
            case .map: !resultGeometryColumns.isEmpty
            case .chart: !resultChartKinds.isEmpty
            default: true
            }
        }
    }

    /// The shapes the shown result supports; empty hides the Chart tab entirely.
    private var resultChartKinds: [ChartKind] {
        guard let grid = controller.selectedResult?.grid else { return [] }
        return ChartSpec.kinds(columns: grid.columns)
    }

    @ViewBuilder
    private func chartPane(_ result: QueryResultTab) -> some View {
        if let grid = result.grid {
            ChartPaneView(
                grid: grid,
                revision: controller.revision,
                kind: $chartKind,
                categoryColumn: $chartCategory,
                valueColumn: $chartValue,
                aggregate: $chartAggregate
            )
        } else {
            EmptyStateView(
                icon: Icon.chart, title: "No rows", message: "This statement returned nothing to draw.")
        }
    }

    private var editorPane: some View {
        VStack(spacing: 0) {
            editorToolbar
            Divider()
            SQLEditorView(
                text: $controller.sql,
                dialect: controller.dialect,
                fontName: fontName,
                fontSize: fontSize,
                errorPosition: controller.errorBanner?.position,
                isFront: workspace.selectedTabID == tab.id,
                delegate: controller
            )
        }
        // The pane fills the split view's other axis. Without this it is laid out at the
        // ideal size of what is beside it and sits centred in a narrow column.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(
            minWidth: settings.splitQuerySideBySide ? 320 : nil,
            idealWidth: settings.splitQuerySideBySide ? 520 : nil,
            minHeight: settings.splitQuerySideBySide ? nil : 120,
            idealHeight: settings.splitQuerySideBySide ? nil : 260)
    }

    private var resultsPane: some View {
        VStack(spacing: 0) {
            if let banner = controller.errorBanner {
                InlineBanner(
                    kind: .error,
                    message: banner.sqlState.map { "[\($0)] \(banner.message)" } ?? banner.message,
                    detail: banner.detail,
                    hint: banner.hint,
                    onCopy: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(banner.copyText, forType: .string)
                    },
                    onDismiss: { controller.errorBanner = nil }
                )
                Divider()
            }
            resultHeader
            Divider()
            resultContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(
            minWidth: settings.splitQuerySideBySide ? 360 : nil,
            minHeight: settings.splitQuerySideBySide ? nil : 140)
    }

    /// Which pane of a result is showing.
    enum ResultPane: String, CaseIterable, Identifiable {
        case result = "Rows"
        case chart = "Chart"
        case map = "Map"
        case message = "Message"
        case profile = "Profile"
        case status = "Status"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .result: Icon.data
            case .chart: Icon.chart
            case .map: Icon.map
            case .message: Icon.message
            case .profile: Icon.profile
            case .status: Icon.status
            }
        }
    }

    @State private var mapColumn = -1
    /// The rows on the map; nil is all of them.
    @State private var mapRows: Set<Int>?

    /// Geometry columns in the selected result, when it has any.
    private var resultGeometryColumns: [Int] {
        guard let grid = controller.selectedResult?.grid else { return [] }
        return GeometryColumns.detect(in: grid, dialect: controller.dialect)
    }

    /// The result strip: one chip per statement on the left, the pane picker on the right.
    var resultHeader: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    ForEach(controller.results) { result in
                        resultChip(result)
                    }
                }
                .padding(.horizontal, DesignTokens.Spacing.sm)
            }
            Spacer(minLength: DesignTokens.Spacing.sm)
            Picker("Pane", selection: $resultPane) {
                ForEach(visiblePanes) { pane in
                    Label(pane.rawValue, systemImage: pane.icon).tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .padding(.trailing, DesignTokens.Spacing.sm)
        }
        .frame(height: DesignTokens.Metrics.resultTabHeight)
        .background(.bar)
    }

    private func resultChip(_ result: QueryResultTab) -> some View {
        let isSelected = controller.selectedResultID == result.id
        return Button {
            controller.showResult(result.id)
        } label: {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: result.error != nil ? Icon.error : (result.grid == nil ? Icon.success : Icon.data))
                    .font(.system(size: DesignTokens.Typography.chipIcon))
                    .foregroundStyle(result.error != nil ? .red : (isSelected ? Color.accentColor : .secondary))
                Text(result.label).lineLimit(1).font(
                    .system(size: DesignTokens.Typography.chip, weight: isSelected ? .medium : .regular))
                if let grid = result.grid {
                    Badge(text: "\(grid.displayRowCount)")
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .frame(height: 22)
            .background(isSelected ? Color.accentColor.opacity(0.14) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Metrics.smallCornerRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(result.statement)
    }

    @ViewBuilder
    var resultContent: some View {
        if let result = controller.selectedResult {
            switch resultPane {
            case .message: messagePane(result)
            case .result: rowsPane(result)
            case .chart: chartPane(result)
            case .map: mapPane(result)
            case .profile:
                tablePane(
                    columns: result.profileColumns, rows: result.profile, note: result.profileNote
                )
                .task(id: result.id) { await controller.loadProfile(for: result) }
            case .status:
                tablePane(
                    columns: result.statusColumns, rows: result.status, note: result.statusNote
                )
                .task(id: result.id) { await controller.loadStatus(for: result) }
            }
        } else {
            EmptyStateView(
                icon: Icon.run,
                title: "No results yet",
                message:
                    "Run the statement under the cursor with ⌘R, the highlighted text with ⌘⇧R, or the whole page with ⌘⌥R."
            )
        }
    }

    /// The statement and what the server said about it.
    private func messagePane(_ result: QueryResultTab) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    Text("Statement").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(result.statement)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    Text("Server").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(result.error?.message ?? result.message ?? "OK")
                        .font(.callout)
                        .foregroundStyle(result.error == nil ? Color.primary : Color.red)
                        .textSelection(.enabled)
                }
                if let completion = result.completion {
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        if let tag = completion.serverTag { Badge(text: tag) }
                        Text(Self.seconds(completion.durationTotal))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        if let server = completion.durationServer {
                            Text("server \(Self.seconds(server))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    if !completion.notices.isEmpty {
                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                            Text("Notices").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(Array(completion.notices.enumerated()), id: \.offset) { _, notice in
                                Text(notice).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignTokens.Spacing.lg)
        }
    }

    /// The result's geometry column on a map.
    @ViewBuilder
    private func mapPane(_ result: QueryResultTab) -> some View {
        if let grid = result.grid {
            let columns = resultGeometryColumns
            MapPaneView(
                grid: grid,
                dialect: controller.dialect,
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
        } else {
            EmptyStateView(icon: Icon.map, title: "No rows to map")
        }
    }

    /// The rows as aligned plain text, the way a terminal client prints them.
    /// A pane that is just a table of strings: Profile and Status both are.
    @ViewBuilder
    private func tablePane(
        columns: [String], rows: [[String]]?, note: String?
    ) -> some View {
        if let note {
            EmptyStateView(icon: Icon.info, title: "Not available", message: note)
        } else if let rows, !rows.isEmpty {
            SimpleTable(
                columns: columns.map { SimpleTable.Column(title: $0, width: 200) },
                rows: rows
            )
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    static func seconds(_ duration: Duration) -> String {
        let ms =
            Double(duration.components.attoseconds) / 1e15
            + Double(duration.components.seconds) * 1000
        return ms < 1_000 ? String(format: "%.0f ms", ms) : String(format: "%.3f s", ms / 1000)
    }

    @ViewBuilder
    private func rowsPane(_ result: QueryResultTab) -> some View {
        VStack(spacing: 0) {
            if result.grids.count > 1 {
                // One pane per result set (SPEC §13.2a); this picks which one is shown.
                PaneBar {
                    Picker(
                        "Result set",
                        selection: Binding(
                            get: { result.shownGridIndex },
                            set: { index in
                                result.shownGridIndex = index
                                controller.bumpRevision()
                            })
                    ) {
                        ForEach(result.grids.indices, id: \.self) { index in
                            Text("Set \(index + 1) · \(result.grids[index].displayRowCount) rows").tag(index)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                }
                Divider()
            }
            if let grid = result.grid {
                HStack(spacing: 0) {
                    DataGridView(
                        model: grid,
                        selection: $controller.selection,
                        revision: controller.revision,
                        delegate: controller
                    )
                    if tab.isInspectorVisible {
                        Divider()
                        CellInspectorView(
                            columns: grid.columns,
                            focusedColumn: controller.selection.focusColumn,
                            focusedRow: controller.selection.focusRow,
                            rowValues: controller.rowValues(controller.selection.focusRow),
                            rowState: grid.rowChangeState(controller.selection.focusRow),
                            isEditable: grid.isEditable,
                            hasReference: { column in
                                controller.gridHasReference(row: controller.selection.focusRow, column: column)
                            },
                            onCommit: { column, text in
                                controller.gridDidCommitEdit(
                                    row: controller.selection.focusRow, column: column, text: text)
                            },
                            onSetNull: { column in
                                grid.setValue(.null, row: controller.selection.focusRow, column: column)
                                controller.bumpRevision()
                            },
                            onFollow: { column in
                                controller.gridDidRequestFollowReference(
                                    row: controller.selection.focusRow, column: column)
                            },
                            isColumnEditable: { grid.isColumnEditable($0) },
                            canPickReference: { column in controller.gridColumnReferences(column) },
                            onPickReference: { column in controller.requestReferencePicker(column: column) },
                            choices: { column in controller.gridChoices(column) }
                        )
                        .id(controller.revision)
                    }
                }
                if let prompt = controller.memoryCapPrompt {
                    // The stream is paused on the server side while this shows (SPEC §12.1).
                    InlineBanner(
                        kind: .warning,
                        message: "\(prompt.rows) rows are in memory and more are waiting on the server.",
                        onDismiss: { controller.resolveMemoryCap(.stop) }
                    )
                    .overlay(alignment: .trailing) {
                        HStack(spacing: DesignTokens.Spacing.sm) {
                            Button("Load 200,000 more") { controller.resolveMemoryCap(.loadMore) }
                            Button("Export the rest…") {
                                let panel = NSSavePanel()
                                panel.nameFieldStringValue = "rest.csv"
                                panel.canCreateDirectories = true
                                if panel.runModal() == .OK, let url = panel.url {
                                    controller.resolveMemoryCap(.exportRest(url))
                                }
                            }
                            Button("Stop") { controller.resolveMemoryCap(.stop) }
                        }
                        .controlSize(.small)
                        .padding(.trailing, 44)
                    }
                } else if grid.hasReachedMemoryCap {
                    InlineBanner(
                        kind: .info,
                        message: "Showing the first \(grid.rowCount) rows; the statement was stopped on the server.",
                        onDismiss: {}
                    )
                }
            } else {
                EmptyStateView(
                    icon: result.error == nil ? Icon.success : Icon.error,
                    title: result.error == nil ? "Done" : "Failed",
                    message: result.error?.message ?? result.message
                )
            }
            Divider()
            StatusBarView {
                if result.grid?.isPaged == true { pager }
                // What produced the rows on screen, so it is never in doubt.
                Text(result.statement.split(whereSeparator: \.isNewline).joined(separator: " "))
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                Spacer()
                if let completion = result.completion {
                    Label(Self.seconds(completion.durationTotal), systemImage: Icon.profile)
                        .monospacedDigit()
                }
                if let grid = result.grid, grid.isPaged, let range = grid.pageRange {
                    Text(
                        "Rows \(range.lowerBound)–\(range.upperBound)"
                            + (result.exactTotal.map { " of \($0)" }
                                ?? (grid.isExhausted ? " of \(grid.totalCount ?? Int64(grid.rowCount))" : ""))
                    )
                    .monospacedDigit()
                } else if let grid = result.grid {
                    Text("\(grid.displayRowCount) row\(grid.displayRowCount == 1 ? "" : "s")")
                        .monospacedDigit()
                }
                if let grid = result.grid, grid.isPaged, let reason = grid.readOnlyReason {
                    Text(reason).foregroundStyle(.secondary).lineLimit(1)
                }
                if let grid = result.grid, controller.autoCommitsEdits {
                    // Nothing to confirm: a write in flight says so, a refused one offers a
                    // retry, and a new row says when it will go.
                    if controller.isWritingEdits {
                        ProgressView().controlSize(.small)
                        Text("Saving…")
                    } else if grid.edits.pendingStatementCount(.loadedRowsOnly) > 0 {
                        Button("Discard") { controller.discardEdits() }
                            .controlSize(.small)
                        Button {
                            Task { await controller.commitEdits(.loadedRowsOnly) }
                        } label: {
                            Label("Retry", systemImage: Icon.commit)
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .help("The last write was refused; the edit is still here")
                    } else if !grid.edits.pendingInserts.isEmpty {
                        Text("New row saves when you leave it")
                    }
                } else if let grid = result.grid, grid.edits.pendingStatementCount > 0 {
                    Button("Discard") { controller.discardEdits() }
                        .controlSize(.small)
                        .disabled(controller.isWritingEdits)
                    Button {
                        presentCommitPreview(grid)
                    } label: {
                        Label("Commit \(grid.edits.pendingStatementCount)…", systemImage: Icon.commit)
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.isWritingEdits)
                }
                if result.grid != nil {
                    if controller.selection.rowSpan > 1 || controller.selection.columnSpan > 1 {
                        Text("\(controller.selection.rowSpan)×\(controller.selection.columnSpan) selected")
                            .monospacedDigit()
                    }
                }
            }
        }
    }
}

extension QueryTabView {
    /// The edits a result holds, shown as the statements they become before they run.
    func presentCommitPreview(_ grid: GridModel) {
        guard let config = workspace.environment.connections.first(where: { $0.id == tab.connectionID }) else { return }
        let statements = controller.pendingStatements()
        guard !statements.isEmpty else { return }
        workspace.commitPreview = CommitPreview(
            statements: statements, dialect: grid.dialect, connectionName: config.name,
            isProduction: config.isProduction, tab: tab)
    }

    /// First / previous / next / last for a paged result, as on a table tab.
    var pager: some View {
        HStack(spacing: 0) {
            IconButton(icon: Icon.firstPage, label: "First page") { Task { await controller.goToFirstPage() } }
                .disabled(!controller.canGoBack)
            IconButton(icon: Icon.previousPage, label: "Previous page") { Task { await controller.goToPreviousPage() } }
                .disabled(!controller.canGoBack)
            Text("Page \(controller.currentPage)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.primary)
                .frame(minWidth: 52)
            IconButton(icon: Icon.nextPage, label: "Next page") { Task { await controller.goToNextPage() } }
                .disabled(!controller.canGoForward)
            IconButton(icon: Icon.lastPage, label: "Last page — counts the rows to find it") {
                Task { await controller.goToLastPage() }
            }
            .disabled(!controller.canGoForward)
            BarDivider()
        }
    }
}

/// The running time of the current statement. Kept in a view of its own so that only
/// this label re-renders on each tick of the timer, not the tab around it.
private struct ElapsedLabel: View {
    let controller: QueryTabController

    var body: some View {
        Text(QueryTabController.format(controller.elapsed))
    }
}
