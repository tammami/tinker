import AppKit
import DBCore
import DBGrid
import DBSQL
import DBStore
import Foundation
import Observation
import SwiftUI

/// Owns one table tab: its grid model, its selection, and everything the toolbar and
/// context menus act on.
@MainActor
@Observable
public final class TableTabController: DataGridDelegate {
    public private(set) var model: GridModel?
    public var selection = GridSelection()
    /// Bumped whenever the grid's contents changed, which is what makes the view reload.
    public private(set) var revision = 0
    public var columnWidths: [String: Double] = [:]
    public var filterRules: [FilterRule] = []
    public var statusText = ""
    public var errorText: String?
    public var isLoading = false
    public var columnsInfo: [ColumnInfo] = []

    public let table: TableRef
    public let connectionID: UUID
    private let environment: AppEnvironment
    private let dialect: SQLDialect
    private var saveWidthsTask: Task<Void, Never>?

    public init(
        table: TableRef,
        connectionID: UUID,
        dialect: SQLDialect,
        environment: AppEnvironment
    ) {
        self.table = table
        self.connectionID = connectionID
        self.dialect = dialect
        self.environment = environment
    }

    var session: ConnectionSession? { environment.session(for: connectionID) }

    @ObservationIgnored private var structureController: StructureController?

    /// The Structure tab's controller, built the first time the user asks for it so
    /// opening a table still costs one round of introspection rather than two.
    public var structure: StructureController {
        if let structureController { return structureController }
        let controller = StructureController(
            table: table, connectionID: connectionID, dialect: dialect, environment: environment
        )
        structureController = controller
        return controller
    }

    /// True when the connection is marked as production, which the preview sheet uses to
    /// delay its Execute button.
    public var isProduction: Bool {
        environment.connections.first { $0.id == connectionID }?.isProduction ?? false
    }

    /// Re-reads the grid after the designer changed the table underneath it, so a new
    /// primary key makes the grid editable without the tab being reopened (SPEC §15b.5).
    public func reloadAfterStructureChange() async {
        await start()
    }

    /// Reads the table's shape, restores remembered preferences, and loads the first page.
    public func start() async {
        guard let session else {
            errorText = "This connection is no longer configured"
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let table = table
            let columns = try await session.introspection(.columns(table)) {
                try await $0.columns(of: table)
            }
            let identity = try await session.introspection(.primaryKey(table)) {
                try await $0.rowIdentity(of: table)
            } ?? []
            let estimate = try? await session.introspection(.rowCount(table)) {
                try await $0.approximateRowCount(table)
            }
            columnsInfo = columns

            let preferences = await environment.gridPreferences(
                connectionID: connectionID, table: table.id
            )
            columnWidths = preferences.columnWidths
            filterRules = preferences.filter.compactMap { stored in
                guard let op = FilterOperator(rawValue: stored.op) else { return nil }
                return FilterRule(column: stored.column, op: op, values: stored.values)
            }

            let identityKind = identity.count == 1
                ? columns.first { $0.name == identity[0] }?.kind
                : nil
            let model = GridModel(
                source: .table(table),
                dialect: dialect,
                loader: SessionGridLoader(session: session, table: table, dialect: dialect),
                columns: columns.map { column in
                    ColumnMeta(
                        id: column.ordinal - 1,
                        name: column.name,
                        nativeTypeName: column.nativeType,
                        kind: column.kind,
                        isNullable: column.isNullable,
                        isPrimaryKey: column.isPrimaryKey
                    )
                },
                identityColumns: identity,
                identityKind: identityKind
            )
            model.estimatedTotal = estimate ?? nil
            model.sort = preferences.sort.map {
                PagePlanner.SortTerm(column: $0.column, ascending: $0.ascending)
            }
            model.filter = filterRules
            self.model = model
            await model.load(page: 0)
            bumpRevision()
            updateStatus()
        } catch {
            errorText = (error as? DBError)?.errorDescription ?? String(describing: error)
        }
    }

    public func bumpRevision() {
        revision &+= 1
    }

    public func updateStatus() {
        guard let model else { return }
        var parts: [String] = []
        if let total = model.totalCount {
            parts.append("\(total) row\(total == 1 ? "" : "s")")
        } else if let estimate = model.estimatedTotal {
            parts.append("~\(estimate) rows")
        } else {
            parts.append("\(model.rowCount) loaded")
        }
        if let reason = model.readOnlyReason { parts.append(reason) }
        if model.edits.pendingStatementCount > 0 {
            parts.append("\(model.edits.pendingStatementCount) pending change\(model.edits.pendingStatementCount == 1 ? "" : "s")")
        }
        parts.append(model.strategy(forPage: max(0, selection.focusRow / 1_000)).explanation)
        statusText = parts.joined(separator: " • ")
    }

    // MARK: - Commands

    public func refresh() async {
        guard let model else { return }
        await session?.invalidateIntrospection(.rowCount(table))
        await model.reload()
        bumpRevision()
        updateStatus()
    }

    public func applyFilter(_ rules: [FilterRule]) async {
        filterRules = rules
        await model?.setFilter(rules)
        bumpRevision()
        updateStatus()
        await persistPreferences()
    }

    public func gridDidClickColumnHeader(column: Int, additive: Bool) {
        Task { await cycleSort(columnIndex: column, additive: additive) }
    }

    public func cycleSort(columnIndex: Int, additive: Bool) async {
        guard let model, model.columns.indices.contains(columnIndex) else { return }
        await model.cycleSort(column: model.columns[columnIndex].name, additive: additive)
        bumpRevision()
        updateStatus()
        await persistPreferences()
    }

    public func addRow() {
        model?.addRow()
        bumpRevision()
        updateStatus()
    }

    public func deleteSelectedRows() {
        guard let model else { return }
        let rows = selection.rows(totalRows: model.displayRowCount)
        model.markDeleted(rows: rows)
        bumpRevision()
        updateStatus()
    }

    public func setSelectionNull() {
        guard let model else { return }
        for row in selection.rows(totalRows: model.displayRowCount) {
            for column in selection.columns(totalColumns: model.columns.count) {
                model.setValue(.null, row: row, column: column)
            }
        }
        bumpRevision()
        updateStatus()
    }

    public func discardEdits() {
        model?.edits.discardAll()
        bumpRevision()
        updateStatus()
    }

    /// The statements a commit would run, for the preview sheet.
    public func pendingStatements() -> [GeneratedStatement] {
        (try? model?.pendingStatements()) ?? []
    }

    /// Runs the commit and refreshes what changed.
    public func commit() async -> String? {
        guard let model, let session else { return nil }
        if await session.isReadOnly { return "This connection is read-only" }
        do {
            let runner = SessionStatementRunner(session: session)
            let result = try await model.commit(using: runner)
            await model.reload()
            bumpRevision()
            updateStatus()
            return result.statementCount == 0
                ? nil
                : "Committed \(result.statementCount) statement\(result.statementCount == 1 ? "" : "s")"
        } catch let error as GridCommitError {
            errorText = error.description
            return error.description
        } catch {
            let message = (error as? DBError)?.errorDescription ?? String(describing: error)
            errorText = message
            return message
        }
    }

    // MARK: - Clipboard

    public func selectedRowsAndColumns() -> (columns: [ColumnMeta], rows: [[DBValue]]) {
        guard let model else { return ([], []) }
        let columnIndices = selection.columns(totalColumns: model.columns.count)
        let rowIndices = selection.rows(totalRows: model.displayRowCount)
        let columns = columnIndices.compactMap { index in
            model.columns.indices.contains(index) ? model.columns[index] : nil
        }
        let rows = rowIndices.map { row in
            columnIndices.map { column in model.value(row: row, column: column) ?? .null }
        }
        return (columns, rows)
    }

    public func copySelection(format: ClipboardFormat, nullText: String = "") {
        let (columns, rows) = selectedRowsAndColumns()
        guard !rows.isEmpty else { return }
        let text = ClipboardFormatter.render(
            columns: columns, rows: rows, format: format,
            options: .init(
                nullText: nullText,
                includeHeader: format == .csv || format == .markdown,
                dialect: dialect,
                table: table
            )
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Pastes tab-separated text into the grid starting at the focused cell, adding rows
    /// when the paste runs past the end (SPEC §12.4).
    public func paste() {
        guard let model, model.isEditable,
              let text = NSPasteboard.general.string(forType: .string)
        else { return }
        let rows = ClipboardFormatter.parseTSV(text)
        guard !rows.isEmpty else { return }
        let startRow = selection.focusRow
        let startColumn = selection.focusColumn
        var invalid = 0

        for (rowOffset, values) in rows.enumerated() {
            let targetRow = startRow + rowOffset
            if targetRow >= model.displayRowCount { model.addRow() }
            for (columnOffset, text) in values.enumerated() {
                let targetColumn = startColumn + columnOffset
                guard model.columns.indices.contains(targetColumn) else { continue }
                let kind = model.columns[targetColumn].kind
                guard let value = Self.coerce(text, to: kind) else {
                    invalid += 1
                    continue
                }
                model.setValue(value, row: targetRow, column: targetColumn)
            }
        }
        bumpRevision()
        updateStatus()
        if invalid > 0 {
            errorText = "\(invalid) pasted value\(invalid == 1 ? "" : "s") did not fit the column type and " +
                "\(invalid == 1 ? "was" : "were") left unchanged"
        }
    }

    /// Turns typed text into a value of the column's kind, or nil when it does not fit.
    ///
    /// An empty string is NULL; everything the server parses itself — dates, JSON, arrays
    /// — passes through as text so the server does the coercion (SPEC §7.1).
    public static func coerce(_ text: String, to kind: DBValueKind) -> DBValue? {
        if text.isEmpty { return .null }
        switch kind {
        case .bool:
            switch text.lowercased() {
            case "t", "true", "1", "yes", "y": return .bool(true)
            case "f", "false", "0", "no", "n": return .bool(false)
            default: return nil
            }
        case .int:
            return Int64(text).map { .int($0) }
        case .uint:
            return UInt64(text).map { .uint($0) }
        case .double:
            return Double(text).map { .double($0) }
        case .decimal:
            // Validated but never parsed, so every digit survives.
            let allowed = text.allSatisfy { $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" || $0 == "e" || $0 == "E" }
            return allowed ? .decimal(text) : nil
        case .uuid:
            return UUID(uuidString: text).map { .uuid($0) }
        case .bytes:
            let hex = text.hasPrefix("\\x") ? String(text.dropFirst(2)) : text
            guard hex.count % 2 == 0, hex.allSatisfy(\.isHexDigit) else { return nil }
            var data = Data()
            var index = hex.startIndex
            while index < hex.endIndex {
                let next = hex.index(index, offsetBy: 2)
                guard let byte = UInt8(hex[index ..< next], radix: 16) else { return nil }
                data.append(byte)
                index = next
            }
            return .bytes(data)
        case .json:
            return .json(text)
        case .string:
            return .string(text)
        case .null:
            return .null
        case .date, .time, .timestamp, .array, .raw:
            return .raw(typeName: kind.rawValue, text: text, bytes: nil)
        }
    }

    // MARK: - Preferences

    func persistPreferences() async {
        guard let model else { return }
        let preferences = GridPreferences(
            columnWidths: columnWidths,
            sort: model.sort.map { GridSortTerm(column: $0.column, ascending: $0.ascending) },
            filter: filterRules.map { StoredFilterRule(column: $0.column, op: $0.op.rawValue, values: $0.values) }
        )
        await environment.saveGridPreferences(
            preferences, connectionID: connectionID, table: table.id
        )
    }

    // MARK: - DataGridDelegate

    public func gridDidChangeSelection(_ selection: GridSelection) {
        self.selection = selection
        updateStatus()
    }

    public func gridDidRequestLoad(range: Range<Int>) {
        guard let model else { return }
        Task { @MainActor in
            let before = model.rowCount
            await model.ensureLoaded(range: range)
            if model.rowCount != before || model.lastError != nil {
                bumpRevision()
                updateStatus()
            }
        }
    }

    public func gridDidCommitEdit(row: Int, column: Int, text: String) {
        guard let model, model.columns.indices.contains(column) else { return }
        guard let value = Self.coerce(text, to: model.columns[column].kind) else {
            errorText = "\"\(text)\" is not a valid \(model.columns[column].nativeTypeName)"
            return
        }
        model.setValue(value, row: row, column: column)
        bumpRevision()
        updateStatus()
    }

    public func gridDidRequestInspector() {}

    public func gridDidChangeColumnWidths(_ widths: [String: Double]) {
        columnWidths = widths
        // Column dragging fires continuously; persist once the user stops.
        saveWidthsTask?.cancel()
        saveWidthsTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.persistPreferences()
        }
    }
}
