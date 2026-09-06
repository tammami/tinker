import DBCore
import DBGrid
import DBSQL
import SwiftUI

/// A query tab: editor above, one result tab per statement below.
public struct QueryTabView: View {
    @Bindable var controller: QueryTabController
    @Bindable var workspace: WorkspaceModel
    let tab: WorkspaceTab
    let fontName: String
    let fontSize: Double

    @State private var resultPane: ResultPane = .result

    public var body: some View {
        VSplitView {
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
            // The editor pane fills the split view's width. Without this it is laid out at
            // the ideal width of what is beside it and sits centred in a narrow column.
            .frame(maxWidth: .infinity, minHeight: 120, idealHeight: 260)

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
            .frame(maxWidth: .infinity, minHeight: 140)
        }
        .task(id: tab.id) {
            controller.sql = tab.sql
            controller.autoCommit = tab.autoCommit
            await controller.loadSessionChoices()
            await controller.loadCompletionSources()
        }
        .onChange(of: controller.sql) { _, new in tab.sql = new }
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
            .onAppear { controller.onRequestInspector = { workspace.isInspectorVisible = true } }
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
            .help("Run only the highlighted text (⌘⇧R)")

            Button {
                controller.run(all: true)
            } label: {
                Label("Run All", systemImage: Icon.runAll)
            }
            .disabled(controller.isRunning)
            .help("Run every statement on the page (⌘⌥R)")

            Button {
                controller.explain(analyze: false)
            } label: {
                Label("Explain", systemImage: Icon.explain)
            }
            .disabled(controller.isRunning)
            .help("Show the plan for the statement under the cursor (⌘⇧E)")
            .contextMenu {
                Button("Explain") { controller.explain(analyze: false) }
                Button("Explain Analyze (runs the statement)") { controller.explain(analyze: true) }
            }

            Button {
                controller.formatSQL()
            } label: {
                Label("Beautify", systemImage: Icon.format)
            }
            .help("Lay the SQL out one clause per line (⌘⇧I)")

            if controller.isRunning {
                Button {
                    controller.cancel()
                } label: {
                    Label("Stop", systemImage: Icon.stop)
                }
                .help("Cancel on the server (⌘.)")
                ProgressView().controlSize(.small)
                Text(QueryTabController.format(controller.elapsed))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            BarDivider()

            // The tab's session: statements resolve unqualified names here. Both pop-ups
            // keep a fixed width, so the bar reads the same whatever they are called.
            BarPopUp(
                items: controller.availableConnections.map {
                    BarPopUp.Item(id: $0.id, title: $0.name, icon: Icon.connection)
                },
                selection: Binding(
                    get: { controller.connectionID },
                    set: { id in Task { await controller.selectConnection(id) } }
                )
            )
            .frame(width: 170)
            .help("The connection this tab runs on")

            BarPopUp(
                items: (controller.sessionDatabase == nil ? [BarPopUp.Item(id: "", title: "Choose…")] : [])
                    + controller.availableDatabases.map { BarPopUp.Item(id: $0, title: $0) },
                selection: Binding(
                    get: { controller.sessionDatabase ?? "" },
                    set: { name in Task { await controller.selectDatabase(name) } }
                )
            )
            .frame(width: 160)
            .help(
                controller.dialect == .mysql
                    ? "The database unqualified names resolve against (USE)"
                    : "The schema unqualified names resolve against (search_path)"
            )

            BarDivider()

            // Bound to the property itself: a checkbox whose binding only changes its value
            // later, on another turn of the run loop, snaps back to what it read and never
            // shows the click. The commit that turning it on may owe happens after.
            Toggle("Auto-commit", isOn: $controller.autoCommit)
                .toggleStyle(.checkbox)
                .onChange(of: controller.autoCommit) { _, enabled in
                    tab.autoCommit = enabled
                    Task { await controller.setAutoCommit(enabled) }
                }
                .help("Off holds a transaction open until you commit or roll back")

            if controller.isInTransaction {
                Badge(text: "TRANSACTION OPEN", color: .orange)
                Button("Commit") { Task { await controller.commitTransaction() } }
                Button("Rollback") { Task { await controller.rollbackTransaction() } }
            }

            Spacer()

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

    /// Which pane of a result is showing.
    enum ResultPane: String, CaseIterable, Identifiable {
        case result = "Rows"
        case text = "Text"
        case map = "Map"
        case message = "Message"
        case profile = "Profile"
        case status = "Status"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .result: Icon.data
            case .text: Icon.text
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
                ForEach(ResultPane.allCases.filter { $0 != .map || !resultGeometryColumns.isEmpty }) { pane in
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
            controller.selectedResultID = result.id
        } label: {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: result.error != nil ? Icon.error : (result.grid == nil ? Icon.success : Icon.data))
                    .font(.system(size: 10))
                    .foregroundStyle(result.error != nil ? .red : (isSelected ? Color.accentColor : .secondary))
                Text(result.label).lineLimit(1).font(.system(size: 11, weight: isSelected ? .medium : .regular))
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
            case .text: textPane(result)
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
    private func textPane(_ result: QueryResultTab) -> some View {
        Group {
            if let grid = result.grid {
                TextResultView(grid: grid, revision: controller.revision, fontName: fontName, fontSize: fontSize)
            } else {
                EmptyStateView(icon: Icon.text, title: result.message ?? "No rows")
            }
        }
    }

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
            if let grid = result.grid {
                HStack(spacing: 0) {
                    DataGridView(
                        model: grid,
                        selection: $controller.selection,
                        revision: controller.revision,
                        delegate: controller
                    )
                    if workspace.isInspectorVisible {
                        Divider()
                        CellInspectorView(
                            columns: grid.columns,
                            focusedColumn: controller.selection.focusColumn,
                            focusedRow: controller.selection.focusRow,
                            rowValues: controller.rowValues(controller.selection.focusRow),
                            rowState: grid.rowChangeState(controller.selection.focusRow),
                            isEditable: grid.isEditable,
                            hasReference: { _ in false },
                            onCommit: { column, text in
                                controller.gridDidCommitEdit(
                                    row: controller.selection.focusRow, column: column, text: text)
                            },
                            onSetNull: { column in
                                grid.setValue(.null, row: controller.selection.focusRow, column: column)
                                controller.bumpRevision()
                            },
                            onFollow: { _ in }
                        )
                        .id(controller.revision)
                    }
                }
                if grid.hasReachedMemoryCap {
                    InlineBanner(
                        kind: .warning,
                        message: "Showing the first 200,000 rows. Export to a file to get the rest.",
                        onDismiss: {}
                    )
                    .overlay(alignment: .trailing) {
                        Button("Export…") { workspace.isExportPresented = true }
                            .controlSize(.small)
                            .padding(.trailing, 44)
                    }
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
                if let grid = result.grid, controller.autoCommit {
                    // Nothing to confirm: a write in flight says so, a refused one offers a
                    // retry, and a new row says when it will go.
                    if controller.isWritingEdits {
                        ProgressView().controlSize(.small)
                        Text("Saving…")
                    } else if grid.edits.pendingStatementCount(.loadedRowsOnly) > 0 {
                        Button("Discard") { controller.discardEdits() }
                            .controlSize(.small)
                        Button {
                            Task { await controller.commitEdits() }
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
                    Button {
                        presentCommitPreview(grid)
                    } label: {
                        Label("Commit \(grid.edits.pendingStatementCount)…", systemImage: Icon.commit)
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
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

/// Rows rendered as monospaced, column-aligned text.
///
/// Built from the loaded rows only and capped, because a text view that holds a million
/// rows would defeat the grid's whole reason for existing.
struct TextResultView: View {
    let grid: GridModel
    let revision: Int
    let fontName: String
    let fontSize: Double

    static let rowCap = 2_000

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(rendered)
                .font(Font(DesignTokens.Fonts.editor(name: fontName, size: CGFloat(fontSize))))
                .textSelection(.enabled)
                .padding(DesignTokens.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var rendered: String {
        let limit = min(grid.displayRowCount, Self.rowCap)
        let rows = (0 ..< limit).compactMap { grid.loadedRow($0) }
        var text = ClipboardFormatter.render(
            columns: grid.columns, rows: rows, format: .text,
            options: .init(includeHeader: true, dialect: grid.dialect)
        )
        if grid.displayRowCount > limit {
            text += "\n… \(grid.displayRowCount - limit) more rows; export to get them all\n"
        }
        return text
    }
}
