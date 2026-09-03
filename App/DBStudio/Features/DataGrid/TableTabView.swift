import DBCore
import DBGrid
import DBSQL
import SwiftUI

/// A table tab: the grid, its filter bar, the cell inspector and the status line.
public struct TableTabView: View {
    @Bindable var controller: TableTabController
    @Bindable var workspace: WorkspaceModel
    let tab: WorkspaceTab

    /// Which half of the tab is showing (SPEC §15b.1).
    enum Mode: String, CaseIterable, Identifiable {
        case data = "Data"
        case structure = "Structure"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .data

    /// The picker's own identity has to follow the tab, or switching tabs carries the
    /// previous tab's choice across with it.
    private var modeBinding: Binding<Mode> {
        Binding(get: { mode }, set: { mode = $0 })
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: modeBinding) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
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
    }

    @ViewBuilder
    private var dataContent: some View {
        VStack(spacing: 0) {
            if workspace.isFilterBarVisible, let model = controller.model {
                FilterBarView(
                    columns: model.columns,
                    dialect: model.dialect,
                    rules: $controller.filterRules,
                    onApply: { rules in Task { await controller.applyFilter(rules) } }
                )
                Divider()
            }

            if let error = controller.errorText {
                ErrorBanner(message: error) { controller.errorText = nil }
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
                } else {
                    ProgressView("Loading \(controller.table.name)…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if workspace.isInspectorVisible, let model = controller.model {
                    Divider()
                    CellInspectorView(
                        columnName: focusedColumn(model)?.name ?? "",
                        nativeType: focusedColumn(model)?.nativeTypeName ?? "",
                        value: model.value(
                            row: controller.selection.focusRow,
                            column: controller.selection.focusColumn
                        ),
                        isEditable: model.isEditable,
                        onCommit: { text in
                            controller.gridDidCommitEdit(
                                row: controller.selection.focusRow,
                                column: controller.selection.focusColumn,
                                text: text
                            )
                        }
                    )
                }
            }

            Divider()
            statusBar
        }
        .task(id: tab.id) { await controller.start() }
    }

    /// First / previous / next / last and the page number (SPEC §12.7).
    @ViewBuilder
    var pager: some View {
        if controller.model?.isPaged == true {
            HStack(spacing: 2) {
                Button { Task { await controller.goToFirstPage() } } label: {
                    Image(systemName: "chevron.left.to.line")
                }
                .disabled(!controller.canGoBack)
                .help("First page")

                Button { Task { await controller.goToPreviousPage() } } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!controller.canGoBack)
                .help("Previous page")

                Text("\(controller.currentPage)")
                    .font(.caption.monospacedDigit())
                    .frame(minWidth: 22)

                Button { Task { await controller.goToNextPage() } } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(!controller.canGoForward)
                .help("Next page")

                Button { Task { await controller.goToLastPage() } } label: {
                    Image(systemName: "chevron.right.to.line")
                }
                .disabled(!controller.canGoForward)
                .help("Last page — counts the matching rows to find it")
            }
            .buttonStyle(.borderless)
            Divider().frame(height: 12)
        }
    }

    func focusedColumn(_ model: GridModel) -> ColumnMeta? {
        model.columns.indices.contains(controller.selection.focusColumn)
            ? model.columns[controller.selection.focusColumn]
            : nil
    }

    var statusBar: some View {
        HStack(spacing: 10) {
            pager
            Text(controller.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if let model = controller.model, model.edits.pendingStatementCount > 0 {
                Button("Discard") { controller.discardEdits() }
                    .controlSize(.small)
                Button("Commit \(model.edits.pendingStatementCount)…") { presentCommitPreview() }
                    .controlSize(.small)
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(.bar)
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

/// The inline, non-modal error banner the spec requires for server errors (SPEC §10.3).
public struct ErrorBanner: View {
    let message: String
    var detail: String?
    var hint: String?
    var onCopy: (() -> Void)?
    let onDismiss: () -> Void

    public init(
        message: String,
        detail: String? = nil,
        hint: String? = nil,
        onCopy: (() -> Void)? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.message = message
        self.detail = detail
        self.hint = hint
        self.onCopy = onCopy
        self.onDismiss = onDismiss
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Rectangle()
                .fill(Color.red)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 3) {
                Text(message)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let hint {
                    Text(hint).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Spacer()
            if let onCopy {
                Button("Copy", action: onCopy).controlSize(.small)
            }
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08))
    }
}
